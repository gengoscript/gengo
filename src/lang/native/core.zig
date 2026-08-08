const std = @import("std");
const common = @import("../common.zig");
const heap = @import("../../runtime/heap.zig");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const vmmap = @import("../vm_map.zig");
const vmarr = @import("../vm_array.zig");
const vmtyp = @import("../vm_types.zig");
const vmstr = @import("../vm_string.zig");
const vmbigint = @import("../vm_bigint.zig");
const vm = @import("../vm.zig");
const vmod = @import("../value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const StructFieldSpec = vmod.StructFieldSpec;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = vmod.NativeFuncObj;
const host_abi_mod = @import("host_abi.zig");
const MaxNativeArgs = @import("native_ids.zig").MaxNativeArgs;
const chunk = @import("../chunk.zig");
const staticSS = vmod.staticSS;

pub fn nativeLen(ctx: VMContext, v: Value) !Value {
    const uv = vms.unboxNamed(v);
    const n: usize = switch (uv) {
        .string => |s| try vmstr.utf8RuneCountCached(ctx, s.bytes),
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| try vmstr.utf8RuneCountCached(ctx, s),
            .string_view => |sv| try vmstr.utf8RuneCountCached(ctx, sv.bytes),
            .array, .array_managed, .array_view, .array_capacity => (try vms.asArraySlice(obj)).len,
            .map, .map_managed, .map_hashed => (try vms.asMapSlice(obj)).len,
            .struct_instance => |s| s.fields.len,
            .small_struct_instance => |s| s.count,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .int = @intCast(n) };
}

pub fn nativeByteLen(ctx: VMContext, v: Value) !Value {
    _ = ctx;
    const uv = vms.unboxNamed(v);
    const n: usize = switch (uv) {
        .string => |s| s.bytes.len,
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| s.len,
            .string_view => |sv| sv.bytes.len,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .int = @intCast(n) };
}

pub fn nativeDelete(m_obj: *Object, key: Value) !Value {
    return vmmap.mapDelete(m_obj, key);
}

pub fn nativeHas(m_obj: *Object, key: Value) !Value {
    return .{ .boolean = try vmmap.mapHas(m_obj, key) };
}

fn nativeMapExtract(ctx: VMContext, m_obj: *Object, comptime field: std.meta.FieldEnum(MapEntry)) !Value {
    if (!vms.isMapObject(m_obj)) return error.TypeError;
    const items_len = (try vms.asMapSlice(m_obj)).len;
    const obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    const out = try vmgc.vmAllocManagedSlice(ctx, Value, items_len);
    // Re-derive after the allocation above, which can compact and
    // relocate m_obj's backing.
    const items = try vms.asMapSlice(m_obj);
    for (items, 0..) |entry, i| out[i] = @field(entry, @tagName(field));
    obj.* = .{ .array_managed = out[0..items_len] };
    return .{ .object = obj };
}

pub fn nativeKeys(ctx: VMContext, m_obj: *Object) !Value {
    return nativeMapExtract(ctx, m_obj, .key);
}
pub fn nativeValues(ctx: VMContext, m_obj: *Object) !Value {
    return nativeMapExtract(ctx, m_obj, .value);
}

pub fn nativeContains(arr_obj: *Object, needle: Value) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = try vms.asArraySlice(arr_obj);
    for (items) |item| {
        const eq = try nativeDeepEqual(item, needle);
        if (eq == .boolean and eq.boolean) return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

pub fn nativeRemove(ctx: VMContext, arr_obj: *Object, idx_val: Value) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items_len = (try vms.asArraySlice(arr_obj)).len;
    const idx = try vms.vmIndexFromVal(idx_val);
    if (idx >= items_len) return error.IndexOutOfBounds;
    const obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    if (items_len > 1) {
        const out = try vmgc.vmAllocManagedSlice(ctx, Value, items_len - 1);
        // Re-derive after the allocation above, which can compact and
        // relocate arr_obj's backing.
        const items = try vms.asArraySlice(arr_obj);
        @memcpy(out[0..idx], items[0..idx]);
        @memcpy(out[idx .. items_len - 1], items[idx + 1 .. items_len]);
        obj.* = .{ .array_managed = out[0 .. items_len - 1] };
    }
    return .{ .object = obj };
}

pub fn nativeAppend(ctx: VMContext, start: usize, argc: u8) !Value {
    if (argc < 1) return error.ArityMismatch;
    const first = ctx.vs.stack[start];
    const is_named = first == .object and first.object.* == .named_value and
        first.object.named_value.typ.* == .named_type and
        first.object.named_value.typ.named_type.base == .array_t;
    const arr_val = if (is_named) first.object.named_value.value else first;
    if (arr_val != .object or !vms.isArrayObject(arr_val.object)) return error.TypeError;
    if (is_named) {
        if (first.object.named_value.typ.named_type.elem_spec) |es| {
            for (ctx.vs.stack[start + 1 .. start + argc]) |v| {
                if (!vmtyp.matchesTypeSpec(ctx, v, es)) return error.TypeError;
                // matchesTypeSpec only checks a bare scalar's type tag, not a
                // named_t element spec's own range/predicate — core.append
                // on a predicate-bearing named array type could otherwise
                // silently append a value violating that predicate.
                try vm.validateErasedNamedValueForSpec(ctx, es, v);
            }
        }
    }
    const elems = ctx.vs.stack[start + 1 .. start + argc];
    const result = try vmarr.arrayAppend(ctx, arr_val.object, elems);
    if (is_named) {
        try ctx.vs.pushTempRoot(result);
        defer ctx.vs.popTempRoot();
        return try vmtyp.makeNamedValue(ctx, first.object.named_value.typ, result);
    }
    return result;
}

pub fn nativeIsError(v: Value) Value {
    return .{ .boolean = v == .error_value };
}

pub fn nativeGcStats(ctx: VMContext) !Value {
    const obj = try vmgc.allocTempRooted(ctx, .{ .map = &[_]MapEntry{} });
    defer ctx.vs.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 3);
    obj.* = .{ .map = items[0..0] };
    items[0] = .{ .key = .{ .string = try ctx.cs.internStr("heap_used_bytes") }, .value = .{ .int = @intCast(ctx.hs.usedBytes()) } };
    items[1] = .{ .key = .{ .string = try ctx.cs.internStr("heap_size_bytes") }, .value = .{ .int = @intCast(ctx.hs.heap.len) } };
    items[2] = .{ .key = .{ .string = try ctx.cs.internStr("live_objects") }, .value = .{ .int = @intCast(ctx.hs.liveObjectCount()) } };
    obj.* = .{ .map = items[0..3] };
    return .{ .object = obj };
}

pub fn nativeGcStatsExt(ctx: VMContext) !Value {
    const obj = try vmgc.allocTempRooted(ctx, .{ .map = &[_]MapEntry{} });
    defer ctx.vs.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 8);
    obj.* = .{ .map = items[0..0] };
    items[0] = .{ .key = .{ .string = try ctx.cs.internStr("heap_used_bytes") }, .value = .{ .int = @intCast(ctx.hs.usedBytes()) } };
    items[1] = .{ .key = .{ .string = try ctx.cs.internStr("heap_size_bytes") }, .value = .{ .int = @intCast(ctx.hs.heap.len) } };
    items[2] = .{ .key = .{ .string = try ctx.cs.internStr("live_objects") }, .value = .{ .int = @intCast(ctx.hs.liveObjectCount()) } };
    items[3] = .{ .key = .{ .string = try ctx.cs.internStr("gc_runs") }, .value = .{ .int = @intCast(ctx.vs.gc_runs) } };
    items[4] = .{ .key = .{ .string = try ctx.cs.internStr("gc_time_ns") }, .value = .{ .int = @intCast(ctx.vs.gc_time_ns) } };
    items[5] = .{ .key = .{ .string = try ctx.cs.internStr("alloc_object_calls") }, .value = .{ .int = @intCast(ctx.vs.alloc_object_calls) } };
    items[6] = .{ .key = .{ .string = try ctx.cs.internStr("alloc_managed_slice_calls") }, .value = .{ .int = @intCast(ctx.vs.alloc_managed_slice_calls) } };
    items[7] = .{ .key = .{ .string = try ctx.cs.internStr("alloc_managed_bytes_calls") }, .value = .{ .int = @intCast(ctx.vs.alloc_managed_bytes_calls) } };
    obj.* = .{ .map = items[0..8] };
    return .{ .object = obj };
}

// @intFromFloat panics on NaN, +/-Infinity, or any magnitude outside i64's
// range, so every float-to-int conversion here must reject those first and
// raise a catchable error instead.
fn floatToIntChecked(n: f64) !i64 {
    const tr = @trunc(n);
    if (!std.math.isFinite(tr) or tr < @as(f64, @floatFromInt(std.math.minInt(i64))) or tr >= @as(f64, @floatFromInt(std.math.maxInt(i64))) + 1.0) {
        return error.RangeError;
    }
    return @intFromFloat(tr);
}

pub fn nativeConvToInt(ctx: VMContext, v: Value) !Value {
    _ = ctx;
    switch (v) {
        .int => |n| return .{ .int = n },
        .float => |n| return .{ .int = try floatToIntChecked(n) },
        .rune => |r| return .{ .int = @intCast(r) },
        .boolean => |b| return .{ .int = if (b) 1 else 0 },
        .string => |s| {
            const n = common.parseFloat(s.bytes) orelse return error.TypeError;
            return .{ .int = try floatToIntChecked(n) };
        },
        .object => |o| {
            // cast_int (the `int(...)` builtin) already delegates to
            // vmbigint.toInt for a bigint operand — std.conv.to_int used to
            // be inconsistent with it, falling through to stringBytesFromObj
            // (which rejects any non-string object) and raising a spurious
            // TypeError instead.
            if (o.* == .bigint) return .{ .int = try vmbigint.toInt(v) };
            const s = try vmstr.stringBytesFromObj(o);
            const n = common.parseFloat(s) orelse return error.TypeError;
            return .{ .int = try floatToIntChecked(n) };
        },
        else => return error.TypeError,
    }
}

pub fn nativeConvToFloat(ctx: VMContext, v: Value) !Value {
    _ = ctx;
    switch (v) {
        .int => |n| return .{ .float = @floatFromInt(n) },
        .float => |n| return .{ .float = n },
        .rune => |r| return .{ .float = @floatFromInt(r) },
        .boolean => |b| return .{ .float = if (b) 1 else 0 },
        .string => |s| {
            const n = common.parseFloat(s.bytes) orelse return error.TypeError;
            return .{ .float = n };
        },
        .object => |o| {
            if (o.* == .bigint) return .{ .float = vmbigint.toFloat(v) };
            const s = try vmstr.stringBytesFromObj(o);
            const n = common.parseFloat(s) orelse return error.TypeError;
            return .{ .float = n };
        },
        else => return error.TypeError,
    }
}

pub fn nativeConvToBool(ctx: VMContext, v: Value) !Value {
    return .{
        .boolean = switch (v) {
            .boolean => |b| b,
            .int => |n| n != 0.0,
            .float => |n| n != 0.0,
            .decimal => |d| d != 0,
            .rune => |r| r != 0,
            .string => |s| s.bytes.len != 0,
            .error_value => |e| e.bytes.len != 0,
            .null => false,
            // A heap-backed string must convert like a literal one; named values
            // convert through their underlying value.
            .inline_variant => true,
            .actor_ref => |r| r.index != 0 or r.generation != 0,
            .object => |obj| switch (obj.*) {
                .dyn_string => |s| s.len != 0,
                .string_view => |sv| sv.bytes.len != 0,
                .named_value => |nv| (try nativeConvToBool(ctx, nv.value)).boolean,
                .named_error_value => |nev| nev.msg.bytes.len != 0,
                else => true,
            },
        },
    };
}

pub fn nativeConvToString(ctx: VMContext, v: Value) !Value {
    if (vmod.decimalRawAndScale(v)) |drs| {
        var buf: [64]u8 = undefined;
        const s = vmod.formatDecimalString(drs.raw, drs.scale, &buf);
        return vmgc.makeDynString(ctx, s);
    }
    return switch (v) {
        .string => |s| vmgc.makeDynString(ctx, s.bytes),
        .object => |o| {
            if (o.* == .bigint) return vmbigint.toDynString(ctx, .{ .object = o });
            if (o.* == .named_error_value) return vmgc.makeDynString(ctx, o.named_error_value.msg.bytes);
            return vmgc.makeDynString(ctx, try vmstr.stringBytesFromObj(o));
        },
        .boolean => |b| vmgc.makeDynString(ctx, if (b) "true" else "false"),
        .int => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(ctx, s);
        },
        .float => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(ctx, s);
        },
        .decimal => unreachable,
        .rune => |r| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(r, buf[0..]) catch return error.TypeError;
            return vmgc.makeDynString(ctx, buf[0..n]);
        },
        .null => vmgc.makeDynString(ctx, "null"),
        .error_value => |e| vmgc.makeDynString(ctx, e.bytes),
        .inline_variant => |iv| blk: {
            const ordinal = vmod.inlineVariantOrdinal(iv);
            const iv_typ = vmod.objectAtIdx(iv.typ_idx);
            const arm = iv_typ.variant_type.arms[ordinal];
            const payload = vmod.inlineVariantPayload(iv);
            var buf: [1024]u8 = undefined;
            var pos: usize = 0;
            const tn = iv_typ.variant_type.name;
            if (pos + tn.len > buf.len) return error.RangeError;
            @memcpy(buf[pos..][0..tn.len], tn);
            pos += tn.len;
            if (pos >= buf.len) return error.RangeError;
            buf[pos] = '.';
            pos += 1;
            if (pos + arm.name.len > buf.len) return error.RangeError;
            @memcpy(buf[pos..][0..arm.name.len], arm.name);
            pos += arm.name.len;
            if (payload != .null) {
                const inner_v = try nativeConvToString(ctx, payload);
                const inner_s = try vms.asStringValue(inner_v);
                if (pos >= buf.len) return error.RangeError;
                buf[pos] = '(';
                pos += 1;
                if (pos + inner_s.len > buf.len) return error.RangeError;
                @memcpy(buf[pos..][0..inner_s.len], inner_s);
                pos += inner_s.len;
                if (pos >= buf.len) return error.RangeError;
                buf[pos] = ')';
                pos += 1;
            }
            break :blk vmgc.makeDynString(ctx, buf[0..pos]);
        },
        .actor_ref => |r| blk: {
            var buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "actor<{d}:{d}>", .{ r.index, r.generation }) catch return error.TypeError;
            break :blk vmgc.makeDynString(ctx, s);
        },
    };
}

pub fn nativeTypeNameValue(ctx: VMContext, v: Value) !Value {
    return switch (v) {
        .int => .{ .string = staticSS("int") },
        .float => .{ .string = staticSS("float") },
        .decimal => .{ .string = staticSS("decimal") },
        .rune => .{ .string = staticSS("rune") },
        .boolean => .{ .string = staticSS("bool") },
        .string => .{ .string = staticSS("string") },
        .error_value => .{ .string = staticSS("error") },
        .null => .{ .string = staticSS("null") },
        .object => |obj| switch (obj.*) {
            .dyn_string, .string_view => .{ .string = staticSS("string") },
            .array, .array_managed, .array_view, .array_capacity => .{ .string = staticSS("array") },
            .map, .map_managed, .map_hashed => .{ .string = staticSS("map") },
            .native_function => .{ .string = staticSS("native_func") },
            .host_module_function => .{ .string = staticSS("host_func") },
            .function, .closure, .named_type_fn, .enum_type_fn => .{ .string = staticSS("func") },
            .struct_type => |st| .{ .string = try ctx.cs.internStr(st.name) },
            .interface_type => |it| .{ .string = try ctx.cs.internStr(it.name) },
            .named_type => |nt| .{ .string = try ctx.cs.internStr(nt.name) },
            .named_value => |nv| blk: {
                const root_nt = rootNamedType(ctx, nv.typ).named_type;
                if (root_nt.is_anonymous) {
                    break :blk switch (root_nt.base) {
                        .array_t => .{ .string = staticSS("array") },
                        .map_t => .{ .string = staticSS("map") },
                        else => .{ .string = try ctx.cs.internStr(root_nt.name) },
                    };
                }
                break :blk .{ .string = try ctx.cs.internStr(root_nt.name) };
            },
            .enum_type => |et| .{ .string = try ctx.cs.internStr(et.name) },
            .enum_value => |ev| .{ .string = try ctx.cs.internStr(ev.typ.enum_type.name) },
            .struct_instance => |inst| .{ .string = try ctx.cs.internStr(inst.typ.struct_type.name) },
            .small_struct_instance => |ssi| .{ .string = try ctx.cs.internStr(ssi.typ.struct_type.name) },
            .iterator => .{ .string = staticSS("iterator") },
            .variant_type => |vt| .{ .string = try ctx.cs.internStr(vt.name) },
            .variant_value => |vv| .{ .string = try ctx.cs.internStr(vv.typ.variant_type.name) },
            .variant_ctor => |vc| .{ .string = try ctx.cs.internStr(vc.typ.variant_type.name) },
            .string_builder => .{ .string = staticSS("string_builder") },
            .bigint => .{ .string = staticSS("bigint") },
            .cell => .{ .string = staticSS("cell") },
            .named_error_type => |net| .{ .string = try ctx.cs.internStr(net.name) },
            .named_error_value => |nev| .{ .string = try ctx.cs.internStr(nev.typ.named_error_type.name) },
            .task_type => |tt| .{ .string = try ctx.cs.internStr(tt.name) },
        },
        .inline_variant => |iv| .{ .string = try ctx.cs.internStr(vmod.objectAtIdx(iv.typ_idx).variant_type.name) },
        .actor_ref => .{ .string = staticSS("actor") },
    };
}

pub fn nativeIsInt(ctx: VMContext, v: Value) Value {
    return .{ .boolean = switch (v) {
        .int => true,
        .float => |n| isIntegralNumber(n),
        .object => isNamedBase(ctx, v, .int),
        else => false,
    } };
}

pub fn nativeIsFloat(ctx: VMContext, v: Value) Value {
    return .{ .boolean = switch (v) {
        .int => false,
        .float => |n| !isIntegralNumber(n),
        .object => isNamedBase(ctx, v, .float),
        else => false,
    } };
}

pub fn nativeIsString(ctx: VMContext, v: Value) Value {
    return .{ .boolean = vms.isStringValue(v) or isNamedBase(ctx, v, .string) };
}

pub fn nativeIsArray(ctx: VMContext, v: Value) Value {
    return .{ .boolean = (v == .object and vms.isArrayObject(v.object)) or isNamedBase(ctx, v, .array_t) };
}

pub fn nativeIsMap(ctx: VMContext, v: Value) Value {
    return .{ .boolean = (v == .object and vms.isMapObject(v.object)) or isNamedBase(ctx, v, .map_t) };
}

pub fn nativeIsStruct(v: Value) Value {
    return .{ .boolean = v == .object and (v.object.* == .struct_instance or v.object.* == .small_struct_instance) };
}

pub fn nativeIsNull(v: Value) Value {
    return .{ .boolean = v == .null };
}

fn isIntegralNumber(n: f64) bool {
    return @trunc(n) == n;
}

fn rootNamedType(ctx: VMContext, typ_obj: *Object) *Object {
    var cur = typ_obj;
    while (vmtyp.resolveParentType(ctx, cur)) |parent| cur = parent;
    return cur;
}

fn isNamedBase(ctx: VMContext, v: Value, base: @import("../value.zig").NamedTypeBase) bool {
    if (!(v == .object and v.object.* == .named_value)) return false;
    return rootNamedType(ctx, v.object.named_value.typ).named_type.base == base;
}

const MaxDeepVisits = 1024;

const DeepEqVisit = struct { a: *Object, b: *Object };
const CloneVisit = struct { src: *Object, dst: *Object };

pub fn makeTuple2(ctx: VMContext, a: Value, b: Value) !Value {
    const obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(ctx, Value, 2);
    items[0] = a;
    items[1] = b;
    obj.* = .{ .array_managed = items[0..2] };
    return .{ .object = obj };
}

pub fn nativeDeepEqual(a: Value, b: Value) !Value {
    var visits: [MaxDeepVisits]DeepEqVisit = undefined;
    var visit_len: usize = 0;
    return .{ .boolean = try deepEqualValue(a, b, visits[0..], &visit_len) };
}

pub fn nativeClone(ctx: VMContext, v: Value) !Value {
    var visits: [MaxDeepVisits]CloneVisit = undefined;
    var visit_len: usize = 0;
    return cloneValue(ctx, v, visits[0..], &visit_len);
}

fn hasVisitedPair(a: *Object, b: *Object, visits: []const DeepEqVisit, visit_len: usize) bool {
    for (visits[0..visit_len]) |p| {
        if ((p.a == a and p.b == b) or (p.a == b and p.b == a)) return true;
    }
    return false;
}

fn appendVisitedPair(a: *Object, b: *Object, visits: []DeepEqVisit, visit_len: *usize) !void {
    if (visit_len.* >= visits.len) return error.OutOfMemory;
    visits[visit_len.*] = .{ .a = a, .b = b };
    visit_len.* += 1;
}

fn deepEqualMap(a_entries: []const MapEntry, b_entries: []const MapEntry, visits: []DeepEqVisit, visit_len: *usize) anyerror!bool {
    if (a_entries.len != b_entries.len) return false;
    // Heap-allocate the "already matched" bitset so there is no hard cap on
    // map size.  deep_equal on a map with > 128 entries previously returned
    // error.OutOfMemory, which surfaced as a runtime panic in scripts.
    const alloc = std.heap.page_allocator;
    const used = try alloc.alloc(bool, b_entries.len);
    defer alloc.free(used);
    @memset(used, false);
    for (a_entries) |ae| {
        var matched = false;
        for (b_entries, used) |be, *u| {
            if (u.*) continue;
            if (!try deepEqualValue(ae.key, be.key, visits, visit_len)) continue;
            if (!try deepEqualValue(ae.value, be.value, visits, visit_len)) continue;
            u.* = true;
            matched = true;
            break;
        }
        if (!matched) return false;
    }
    return true;
}

fn deepEqualObject(a: *Object, b: *Object, visits: []DeepEqVisit, visit_len: *usize) anyerror!bool {
    if (a == b) return true;
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) {
        if ((a.* == .array or a.* == .array_managed) and (b.* == .array or b.* == .array_managed)) {} else if (vms.isMapObject(a) and vms.isMapObject(b)) {
            return try deepEqualMap(try vms.asMapSlice(a), try vms.asMapSlice(b), visits, visit_len);
        } else {
            return false;
        }
    }
    if (hasVisitedPair(a, b, visits, visit_len.*)) return true;
    switch (a.*) {
        .array, .array_managed, .array_view, .array_capacity => {
            try appendVisitedPair(a, b, visits, visit_len);
            const aa = try vms.asArraySlice(a);
            const bb = try vms.asArraySlice(b);
            if (aa.len != bb.len) return false;
            for (aa, 0..) |item, i| {
                if (!try deepEqualValue(item, bb[i], visits, visit_len)) return false;
            }
            return true;
        },
        .map, .map_managed, .map_hashed => {
            try appendVisitedPair(a, b, visits, visit_len);
            return deepEqualMap(try vms.asMapSlice(a), try vms.asMapSlice(b), visits, visit_len);
        },
        .dyn_string => return common.streq(a.dyn_string, b.dyn_string),
        .string_view => return common.streq(a.string_view.bytes, b.string_view.bytes),
        .function, .closure, .iterator => return a == b,
        .cell => return try deepEqualValue(a.cell.value, b.cell.value, visits, visit_len),
        .native_function => |anf| {
            const bnf = b.native_function;
            return anf.id == bnf.id and anf.arity == bnf.arity;
        },
        .host_module_function => |ahf| {
            const bhf = b.host_module_function;
            return ahf.call_id == bhf.call_id and ahf.arity == bhf.arity;
        },
        .struct_type => |ast| return common.streq(ast.qualified_name, b.struct_type.qualified_name),
        .interface_type => |ait| return common.streq(ait.qualified_name, b.interface_type.qualified_name),
        .named_type => |ant| return common.streq(ant.qualified_name, b.named_type.qualified_name),
        .named_value => |anv| {
            if (anv.typ != b.named_value.typ) return false;
            try appendVisitedPair(a, b, visits, visit_len);
            return try deepEqualValue(anv.value, b.named_value.value, visits, visit_len);
        },
        .enum_type => |aet| return common.streq(aet.qualified_name, b.enum_type.qualified_name),
        .enum_value => |aev| {
            const bev = b.enum_value;
            return aev.typ == bev.typ and aev.ordinal == bev.ordinal;
        },
        .struct_instance => |asi| {
            if (b.* != .struct_instance) return false;
            const bsi = b.struct_instance;
            if (asi.typ != bsi.typ) return false;
            try appendVisitedPair(a, b, visits, visit_len);
            if (asi.fields.len != bsi.fields.len) return false;
            for (asi.fields, bsi.fields) |af, bf| {
                if (!try deepEqualValue(af.value, bf.value, visits, visit_len)) return false;
            }
            return true;
        },
        .small_struct_instance => |assi| {
            if (b.* != .small_struct_instance) return false;
            const bssi = b.small_struct_instance;
            if (assi.typ != bssi.typ) return false;
            try appendVisitedPair(a, b, visits, visit_len);
            if (assi.count != bssi.count) return false;
            for (0..@as(usize, assi.count)) |i| {
                if (!try deepEqualValue(assi.v[i], bssi.v[i], visits, visit_len)) return false;
            }
            return true;
        },
        .variant_type => |avt| return common.streq(avt.qualified_name, b.variant_type.qualified_name),
        .variant_value => |avv| {
            const bvv = b.variant_value;
            if (avv.typ != bvv.typ or !common.streq(avv.tag, bvv.tag)) return false;
            if (avv.shared_values.len != bvv.shared_values.len) return false;
            if (avv.arm_fields.len != bvv.arm_fields.len) return false;
            try appendVisitedPair(a, b, visits, visit_len);
            if (!try deepEqualValue(avv.payload, bvv.payload, visits, visit_len)) return false;
            for (avv.shared_values, bvv.shared_values) |x, y| {
                if (!try deepEqualValue(x, y, visits, visit_len)) return false;
            }
            for (avv.arm_fields, bvv.arm_fields) |x, y| {
                if (!try deepEqualValue(x, y, visits, visit_len)) return false;
            }
            return true;
        },
        .variant_ctor => |avc| {
            const bvc = b.variant_ctor;
            return avc.typ == bvc.typ and avc.ordinal == bvc.ordinal and common.streq(avc.tag, bvc.tag);
        },
        .named_type_fn => |anf| {
            const bnf = b.named_type_fn;
            return anf.typ == bnf.typ and anf.kind == bnf.kind;
        },
        .enum_type_fn => |aef| return aef.typ == b.enum_type_fn.typ,
        .string_builder => |asb| return common.streq(asb.buf[0..asb.len], b.string_builder.buf[0..b.string_builder.len]),
        .bigint => |abi| return abi.toConst().eql(b.bigint.toConst()),
        .named_error_type => |anet| return common.streq(anet.name, b.named_error_type.name),
        .named_error_value => |anev| {
            const bnev = b.named_error_value;
            return anev.typ == bnev.typ and common.streq(anev.msg.bytes, bnev.msg.bytes);
        },
        .task_type => |att| return common.streq(att.qualified_name, b.task_type.qualified_name),
    }
}

fn strBytesFromObj(o: *Object) ?[]const u8 {
    return switch (o.*) {
        .dyn_string => |s| s,
        .string_view => |sv| sv.bytes,
        else => null,
    };
}

fn deepEqualValue(a: Value, b: Value, visits: []DeepEqVisit, visit_len: *usize) anyerror!bool {
    if (a == .string and b == .object) {
        if (strBytesFromObj(b.object)) |bs| return common.streq(a.string.bytes, bs);
    }
    if (b == .string and a == .object) {
        if (strBytesFromObj(a.object)) |as| return common.streq(as, b.string.bytes);
    }
    if (a == .object and b == .object) return deepEqualObject(a.object, b.object, visits, visit_len);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .int => |x| x == b.int,
        .float => |x| x == b.float,
        .decimal => |x| x == b.decimal,
        .rune => |x| x == b.rune,
        .boolean => |x| x == b.boolean,
        .string => |x| common.streq(x.bytes, b.string.bytes),
        .error_value => |x| common.streq(x.bytes, b.error_value.bytes),
        .null => true,
        .object => unreachable,
        .inline_variant => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.inline_variant)),
        .actor_ref => |x| x.index == b.actor_ref.index and x.generation == b.actor_ref.generation,
    };
}

fn cloneFindExisting(src: *Object, visits: []const CloneVisit, visit_len: usize) ?*Object {
    for (visits[0..visit_len]) |v| {
        if (v.src == src) return v.dst;
    }
    return null;
}

fn cloneRemember(src: *Object, dst: *Object, visits: []CloneVisit, visit_len: *usize) !void {
    if (visit_len.* >= visits.len) return error.OutOfMemory;
    visits[visit_len.*] = .{ .src = src, .dst = dst };
    visit_len.* += 1;
}

fn cloneValue(ctx: VMContext, v: Value, visits: []CloneVisit, visit_len: *usize) anyerror!Value {
    return switch (v) {
        .string => |s| try vmgc.makeDynString(ctx, s.bytes),
        .object => |obj| try cloneObject(ctx, obj, visits, visit_len),
        else => v,
    };
}

fn cloneObject(ctx: VMContext, src: *Object, visits: []CloneVisit, visit_len: *usize) anyerror!Value {
    if (cloneFindExisting(src, visits, visit_len.*)) |cached| return .{ .object = cached };
    switch (src.*) {
        .array, .array_managed, .array_view, .array_capacity => {
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
            defer ctx.vs.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            const items_len = (try vms.asArraySlice(src)).len;
            const out = try vmgc.vmAllocManagedSlice(ctx, Value, items_len);
            for (out) |*slot| slot.* = .null;
            out_obj.* = .{ .array_managed = out[0..items_len] };
            // Re-derive src's slice fresh each iteration: cloneValue
            // recurses and can allocate, so a slice captured once before
            // (or even at the top of) this loop can go stale partway
            // through it.
            for (0..items_len) |i| {
                const item = (try vms.asArraySlice(src))[i];
                out[i] = try cloneValue(ctx, item, visits, visit_len);
            }
            return .{ .object = out_obj };
        },
        .map, .map_managed, .map_hashed => {
            const entries_len = (try vms.asMapSlice(src)).len;
            const out_map = try vmgc.allocTempRootedManagedMap(ctx, entries_len);
            defer ctx.vs.popTempRoot();
            try cloneRemember(src, out_map.obj, visits, visit_len);
            for (0..entries_len) |i| {
                const entry = (try vms.asMapSlice(src))[i];
                const k = try cloneValue(ctx, entry.key, visits, visit_len);
                try ctx.vs.pushTempRoot(k);
                const v = try cloneValue(ctx, entry.value, visits, visit_len);
                ctx.vs.popTempRoot();
                out_map.set(i, .{ .key = k, .value = v });
            }
            return .{ .object = out_map.obj };
        },
        .dyn_string => |s| return vmgc.makeDynString(ctx, s),
        .string_view => |sv| return vmgc.makeDynString(ctx, sv.bytes),
        .string_builder => |sb| {
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .string_builder = .{ .buf = &[_]u8{}, .len = 0 } });
            defer ctx.vs.popTempRoot();
            if (sb.len != 0) {
                const new_buf = try vmgc.vmAllocManagedBytes(ctx, sb.len);
                @memcpy(new_buf[0..sb.len], sb.buf[0..sb.len]);
                out_obj.* = .{ .string_builder = .{ .buf = new_buf, .len = sb.len } };
            }
            return .{ .object = out_obj };
        },
        .function, .closure, .native_function, .host_module_function, .struct_type, .interface_type, .named_type, .enum_type, .iterator, .variant_type, .variant_ctor, .named_type_fn, .enum_type_fn, .cell, .bigint, .task_type => return .{ .object = src },
        .named_value => |nv| {
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
            defer ctx.vs.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            out_obj.* = .{ .named_value = .{ .typ = nv.typ, .value = try cloneValue(ctx, nv.value, visits, visit_len) } };
            return .{ .object = out_obj };
        },
        .enum_value => |ev| {
            const out_obj = try vmgc.vmAllocObject(ctx);
            out_obj.* = .{ .enum_value = ev };
            return .{ .object = out_obj };
        },
        .struct_instance => |inst| {
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
            defer ctx.vs.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            const fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, inst.fields.len);
            for (fields) |*slot| slot.* = .{ .key = .null, .value = .null };
            out_obj.* = .{ .struct_instance = .{ .typ = inst.typ, .fields = fields } };
            for (inst.fields, 0..) |field, i| {
                fields[i].key = field.key;
                fields[i].value = try cloneValue(ctx, field.value, visits, visit_len);
            }
            return .{ .object = out_obj };
        },
        .small_struct_instance => |ssi| {
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
            defer ctx.vs.popTempRoot();
            out_obj.* = .{ .small_struct_instance = .{ .typ = ssi.typ, .count = ssi.count, .v = ssi.v } };
            try cloneRemember(src, out_obj, visits, visit_len);
            for (0..@as(usize, ssi.count)) |i| {
                out_obj.small_struct_instance.v[i] = try cloneValue(ctx, ssi.v[i], visits, visit_len);
            }
            return .{ .object = out_obj };
        },
        .variant_value => |vv| {
            const out_obj = try vmgc.vmAllocObject(ctx);
            out_obj.* = .{ .variant_value = .{ .typ = vv.typ, .tag = vv.tag, .ordinal = vv.ordinal, .payload = .null, .shared_values = &[_]Value{}, .arm_fields = &[_]Value{} } };
            try ctx.vs.pushTempRoot(.{ .object = out_obj });
            defer ctx.vs.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            var shared = try vmgc.vmAllocManagedSlice(ctx, Value, vv.shared_values.len);
            out_obj.variant_value.shared_values = shared[0..0]; // publish immediately
            for (vv.shared_values, 0..) |sv, i| {
                shared[i] = try cloneValue(ctx, sv, visits, visit_len);
                out_obj.variant_value.shared_values = shared[0 .. i + 1]; // grow visible
            }
            var arm = try vmgc.vmAllocManagedSlice(ctx, Value, vv.arm_fields.len);
            out_obj.variant_value.arm_fields = arm[0..0]; // publish immediately
            for (vv.arm_fields, 0..) |af, i| {
                arm[i] = try cloneValue(ctx, af, visits, visit_len);
                out_obj.variant_value.arm_fields = arm[0 .. i + 1]; // grow visible
            }
            out_obj.variant_value.payload = try cloneValue(ctx, vv.payload, visits, visit_len);
            return .{ .object = out_obj };
        },
        .named_error_value => |nev| {
            const out_obj = try vmgc.vmAllocObject(ctx);
            out_obj.* = .{ .named_error_value = .{ .typ = nev.typ, .msg = nev.msg } };
            return .{ .object = out_obj };
        },
        .named_error_type => return .{ .object = src },
    }
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .core_append => {
            const start = ctx.vs.stack_top - argc;
            try host_abi_mod.callNativeVariadic(ctx, argc, start, nativeAppend);
        },
        .core_bytelen => {
            if (argc != nf.arity) return error.ArityMismatch;
            try host_abi_mod.callNative1(ctx, argc, nativeByteLen);
        },
        .core_clone => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeClone(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_contains => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.unboxNamed(ctx.vs.vmTop(1));
            const needle = ctx.vs.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const out = try nativeContains(arr_val.object, needle);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_deep_equal => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeDeepEqual(ctx.vs.vmTop(1), ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_delete => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(ctx.vs.vmTop(1));
            const key = ctx.vs.vmTop(0);
            if (m_val != .object) return error.TypeError;
            const out = try nativeDelete(m_val.object, key);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const msg = try vms.asStringValue(ctx.vs.vmTop(0));
            // internStrCopy (heap.bump(), no GC/compaction involved) rather
            // than vmAllocManagedBytes + internStr: an interned reference
            // is held indefinitely, but chunk.internStr only stores a raw
            // reference — it isn't a GC root — so backing it with ordinary
            // managed memory left it reclaimable by sweep/compaction
            // despite still being referenced.
            const interned = try ctx.cs.internStrCopy(msg);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .error_value = interned });
        },
        .core_gc => {
            if (argc != nf.arity) return error.ArityMismatch;
            vmgc.collectGarbage(ctx);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.null);
        },
        .core_gc_live_objects => {
            if (argc != nf.arity) return error.ArityMismatch;
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .int = @intCast(ctx.hs.liveObjectCount()) });
        },
        .core_gc_stats => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStats(ctx);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_gc_stats_ext => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStatsExt(ctx);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_has => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(ctx.vs.vmTop(1));
            const key = ctx.vs.vmTop(0);
            if (m_val != .object) return error.TypeError;
            const out = try nativeHas(m_val.object, key);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_is_array => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsArray(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_is_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = ctx.vs.vmTop(0);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = arg == .error_value or (arg == .object and arg.object.* == .named_error_value) });
        },
        .core_is_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsFloat(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_is_int => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsInt(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_is_map => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsMap(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_is_null => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsNull(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_is_string => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsString(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_is_struct => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsStruct(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_keys => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(ctx.vs.vmTop(0));
            if (m_val != .object) return error.TypeError;
            const out = try nativeKeys(ctx, m_val.object);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_len => {
            if (argc != nf.arity) return error.ArityMismatch;
            try host_abi_mod.callNative1(ctx, argc, nativeLen);
        },
        .core_recover => {
            if (argc != nf.arity) return error.ArityMismatch;
            ctx.vs.vmPopArgs(argc);
            if (ctx.vs.is_panicking and !ctx.vs.recovered) {
                const pv = ctx.vs.panic_value;
                ctx.vs.recovered = true;
                try ctx.vs.vmPush(pv);
            } else {
                try ctx.vs.vmPush(.null);
            }
        },
        .core_remove => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.unboxNamed(ctx.vs.vmTop(1));
            const idx_val = ctx.vs.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const out = try nativeRemove(ctx, arr_val.object, idx_val);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_type_of => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeTypeNameValue(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .core_values => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(ctx.vs.vmTop(0));
            if (m_val != .object) return error.TypeError;
            const out = try nativeValues(ctx, m_val.object);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        else => {},
    }
}
