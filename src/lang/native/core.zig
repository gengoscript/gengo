const std = @import("std");
const common = @import("../common.zig");
const heap = @import("../../runtime/heap.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const vmmap = @import("../vm_map.zig");
const vmtyp = @import("../vm_types.zig");
const vmstr = @import("../vm_string.zig");
const vmbigint = @import("../vm_bigint.zig");
const vmod = @import("../value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const StructFieldSpec = vmod.StructFieldSpec;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = vmod.NativeFuncObj;
const host_abi = @import("../../runtime/host_abi.zig");
const host_abi_mod = @import("host_abi.zig");
const MaxNativeArgs = @import("native_ids.zig").MaxNativeArgs;
const chunk = @import("../chunk.zig");
const staticSS = vmod.staticSS;

pub fn nativeLen(v: Value) !Value {
    const uv = vms.unboxNamed(v);
    const n: usize = switch (uv) {
        .string => |s| try vmstr.utf8RuneCountCached(s.bytes),
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| try vmstr.utf8RuneCountCached(s),
            .string_view => |sv| try vmstr.utf8RuneCountCached(sv.bytes),
            .array, .array_managed, .array_view, .array_capacity => (try vms.asArraySlice(obj)).len,
            .map, .map_managed, .map_hashed => (try vms.asMapSlice(obj)).len,
            .struct_instance => |s| s.fields.len,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .int = @intCast(n) };
}

pub fn nativeByteLen(v: Value) !Value {
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

fn nativeMapExtract(m_obj: *Object, comptime field: std.meta.FieldEnum(MapEntry)) !Value {
    if (!vms.isMapObject(m_obj)) return error.TypeError;
    const items = try vms.asMapSlice(m_obj);
    const obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
    defer vms.popTempRoot();
    const out = try vmgc.vmAllocManagedSlice(Value, items.len);
    for (items, 0..) |entry, i| out[i] = @field(entry, @tagName(field));
    obj.* = .{ .array_managed = out[0..items.len] };
    return .{ .object = obj };
}

pub fn nativeKeys(m_obj: *Object) !Value { return nativeMapExtract(m_obj, .key); }
pub fn nativeValues(m_obj: *Object) !Value { return nativeMapExtract(m_obj, .value); }

pub fn nativeContains(arr_obj: *Object, needle: Value) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = try vms.asArraySlice(arr_obj);
    for (items) |item| {
        const eq = try nativeDeepEqual(item, needle);
        if (eq == .boolean and eq.boolean) return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

pub fn nativeRemove(arr_obj: *Object, idx_val: Value) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = try vms.asArraySlice(arr_obj);
    const idx = try vms.vmIndexFromVal(idx_val);
    if (idx >= items.len) return error.IndexOutOfBounds;
    const obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
    defer vms.popTempRoot();
    if (items.len > 1) {
        const out = try vmgc.vmAllocManagedSlice(Value, items.len - 1);
        @memcpy(out[0..idx], items[0..idx]);
        @memcpy(out[idx .. items.len - 1], items[idx + 1 .. items.len]);
        obj.* = .{ .array_managed = out[0 .. items.len - 1] };
    }
    return .{ .object = obj };
}

pub fn nativeAppend(start: usize, argc: u8) !Value {
    if (argc < 1) return error.ArityMismatch;
    const first = vms.vmState().stack[start];
    const is_named = first == .object and first.object.* == .named_value and
        first.object.named_value.typ.* == .named_type and
        first.object.named_value.typ.named_type.base == .array_t;
    const arr_val = if (is_named) first.object.named_value.value else first;
    if (arr_val != .object or !vms.isArrayObject(arr_val.object)) return error.TypeError;
    if (is_named) {
        if (first.object.named_value.typ.named_type.elem_spec) |es| {
            for (vms.vmState().stack[start + 1 .. start + argc]) |v| {
                if (!vmtyp.matchesTypeSpec(v, es)) return error.TypeError;
            }
        }
    }
    const base = try vms.asArraySlice(arr_val.object);
    const extra: usize = argc - 1;
    const new_len = base.len + extra;

    // Fast path: reuse backing buffer when the array already has spare capacity.
    // array_capacity.backing is an array_managed Object whose slice.len is the capacity.
    if (arr_val.object.* == .array_capacity) {
        const ac = arr_val.object.array_capacity;
        const cap = ac.backing.array_managed.len;
        if (new_len <= cap) {
            @memcpy(ac.backing.array_managed[ac.len .. ac.len + extra], vms.vmState().stack[start + 1 .. start + 1 + extra]);
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .array_capacity = .{ .backing = ac.backing, .len = new_len } };
            if (is_named) {
                try vms.pushTempRoot(.{ .object = obj });
                defer vms.popTempRoot();
                return try vmtyp.makeNamedValue(first.object.named_value.typ, .{ .object = obj });
            }
            return .{ .object = obj };
        }
    }

    // Slow path: allocate a new backing buffer with 2x growth, capped at the
    // heap's largest single block so we never trigger AllocationTooLarge early.
    const ideal_cap = @max(new_len * 2, new_len + 4);
    const max_cap_values = heap.maxManagedAlloc() / @sizeOf(Value);
    const new_cap = if (ideal_cap <= max_cap_values) ideal_cap else @max(new_len, max_cap_values);
    const backing_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
    defer vms.popTempRoot();
    const out = try vmgc.vmAllocManagedSlice(Value, new_cap);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len .. base.len + extra], vms.vmState().stack[start + 1 .. start + 1 + extra]);
    // Zero-fill spare capacity so the GC never traces stale pointers.
    @memset(out[new_len..new_cap], .null);
    backing_obj.* = .{ .array_managed = out };
    const obj = try vmgc.vmAllocObject(); // backing_obj is temp-rooted
    obj.* = .{ .array_capacity = .{ .backing = backing_obj, .len = new_len } };
    if (is_named) {
        try vms.pushTempRoot(.{ .object = obj });
        defer vms.popTempRoot();
        return try vmtyp.makeNamedValue(first.object.named_value.typ, .{ .object = obj });
    }
    return .{ .object = obj };
}

pub fn nativeErrorMsg(msg: []const u8) Value {
    return .{ .error_value = try chunk.internStr(msg) };
}

pub fn nativeIsError(v: Value) Value {
    return .{ .boolean = v == .error_value };
}

pub fn nativeGcStats() !Value {
    const obj = try vmgc.allocTempRooted(.{ .map = &[_]MapEntry{} });
    defer vms.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(MapEntry, 3);
    obj.* = .{ .map = items[0..0] };
    items[0] = .{ .key = .{ .string = try chunk.internStr("heap_used_bytes") }, .value = .{ .int = @intCast(heap.usedBytes()) } };
    items[1] = .{ .key = .{ .string = try chunk.internStr("heap_size_bytes") }, .value = .{ .int = @intCast(heap.g_state.heap.len) } };
    items[2] = .{ .key = .{ .string = try chunk.internStr("live_objects") }, .value = .{ .int = @intCast(heap.liveObjectCount()) } };
    obj.* = .{ .map = items[0..3] };
    return .{ .object = obj };
}

pub fn nativeGcStatsExt() !Value {
    const obj = try vmgc.allocTempRooted(.{ .map = &[_]MapEntry{} });
    defer vms.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(MapEntry, 8);
    obj.* = .{ .map = items[0..0] };
    items[0] = .{ .key = .{ .string = try chunk.internStr("heap_used_bytes") }, .value = .{ .int = @intCast(heap.usedBytes()) } };
    items[1] = .{ .key = .{ .string = try chunk.internStr("heap_size_bytes") }, .value = .{ .int = @intCast(heap.g_state.heap.len) } };
    items[2] = .{ .key = .{ .string = try chunk.internStr("live_objects") }, .value = .{ .int = @intCast(heap.liveObjectCount()) } };
    items[3] = .{ .key = .{ .string = try chunk.internStr("gc_runs") }, .value = .{ .int = @intCast(vms.vmState().gc_runs) } };
    items[4] = .{ .key = .{ .string = try chunk.internStr("gc_time_ns") }, .value = .{ .int = @intCast(vms.vmState().gc_time_ns) } };
    items[5] = .{ .key = .{ .string = try chunk.internStr("alloc_object_calls") }, .value = .{ .int = @intCast(vms.vmState().alloc_object_calls) } };
    items[6] = .{ .key = .{ .string = try chunk.internStr("alloc_managed_slice_calls") }, .value = .{ .int = @intCast(vms.vmState().alloc_managed_slice_calls) } };
    items[7] = .{ .key = .{ .string = try chunk.internStr("alloc_managed_bytes_calls") }, .value = .{ .int = @intCast(vms.vmState().alloc_managed_bytes_calls) } };
    obj.* = .{ .map = items[0..8] };
    return .{ .object = obj };
}

pub fn nativeConvToInt(v: Value) !Value {
    switch (v) {
        .int => |n| return .{ .int = n },
        .float => |n| return .{ .int = @intFromFloat(n) },
        .rune => |r| return .{ .int = @intCast(r) },
        .boolean => |b| return .{ .int = if (b) 1 else 0 },
        .string => |s| { const n = common.parseFloat(s.bytes) orelse return error.TypeError; return .{ .int = @intFromFloat(n) }; },
        .object => |o| {
            const s = try vmstr.stringBytesFromObj(o);
            const n = common.parseFloat(s) orelse return error.TypeError;
            const tr = @trunc(n);
            return .{ .int = @intFromFloat(tr) };
        },
        else => return error.TypeError,
    }
}

pub fn nativeConvToFloat(v: Value) !Value {
    switch (v) {
        .int => |n| return .{ .float = @floatFromInt(n) },
        .float => |n| return .{ .float = n },
        .rune => |r| return .{ .float = @floatFromInt(r) },
        .boolean => |b| return .{ .float = if (b) 1 else 0 },
        .string => |s| { const n = common.parseFloat(s.bytes) orelse return error.TypeError; return .{ .float = n }; },
        .object => |o| {
            const s = try vmstr.stringBytesFromObj(o);
            const n = common.parseFloat(s) orelse return error.TypeError;
            return .{ .float = n };
        },
        else => return error.TypeError,
    }
}

pub fn nativeConvToBool(v: Value) !Value {
    return .{ .boolean = switch (v) {
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
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| s.len != 0,
            .string_view => |sv| sv.bytes.len != 0,
            .named_value => |nv| (try nativeConvToBool(nv.value)).boolean,
            else => true,
        },
    } };
}

pub fn nativeConvToString(v: Value) !Value {
    if (vmod.decimalRawAndScale(v)) |drs| {
        var buf: [64]u8 = undefined;
        const s = vmod.formatDecimalString(drs.raw, drs.scale, &buf);
        return vmgc.makeDynString(s);
    }
    return switch (v) {
        .string => |s| vmgc.makeDynString(s.bytes),
        .object => |o| {
            if (o.* == .bigint) return vmbigint.toDynString(.{ .object = o });
            return vmgc.makeDynString(try vmstr.stringBytesFromObj(o));
        },
        .boolean => |b| vmgc.makeDynString(if (b) "true" else "false"),
        .int => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .float => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .decimal => unreachable,
        .rune => |r| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(r, buf[0..]) catch return error.TypeError;
            return vmgc.makeDynString(buf[0..n]);
        },
        .null => vmgc.makeDynString("null"),
        .error_value => |e| vmgc.makeDynString(e.bytes),
    };
}

pub fn nativeTypeNameValue(v: Value) !Value {
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
            .struct_type => |st| .{ .string = try chunk.internStr(st.name) },
            .interface_type => |it| .{ .string = try chunk.internStr(it.name) },
            .named_type => |nt| .{ .string = try chunk.internStr(nt.name) },
            .named_value => |nv| blk: {
                const root_nt = rootNamedType(nv.typ).named_type;
                if (root_nt.is_anonymous) {
                    break :blk switch (root_nt.base) {
                        .array_t => .{ .string = staticSS("array") },
                        .map_t => .{ .string = staticSS("map") },
                        else => .{ .string = try chunk.internStr(root_nt.name) },
                    };
                }
                break :blk .{ .string = try chunk.internStr(root_nt.name) };
            },
            .enum_type => |et| .{ .string = try chunk.internStr(et.name) },
            .enum_value => |ev| .{ .string = try chunk.internStr(ev.typ.enum_type.name) },
            .struct_instance => |inst| .{ .string = try chunk.internStr(inst.typ.struct_type.name) },
            .iterator => .{ .string = staticSS("iterator") },
            .variant_type => |vt| .{ .string = try chunk.internStr(vt.name) },
            .variant_value => |vv| .{ .string = try chunk.internStr(vv.typ.variant_type.name) },
            .variant_ctor => |vc| .{ .string = try chunk.internStr(vc.typ.variant_type.name) },
            .string_builder => .{ .string = staticSS("string_builder") },
            .bigint => .{ .string = staticSS("bigint") },
            .cell => .{ .string = staticSS("cell") },
        },
    };
}

pub fn nativeIsInt(v: Value) Value {
    return .{ .boolean = switch (v) {
        .int => true,
        .float => |n| isIntegralNumber(n),
        .object => isNamedBase(v, .int),
        else => false,
    } };
}

pub fn nativeIsFloat(v: Value) Value {
    return .{ .boolean = switch (v) {
        .int => false,
        .float => |n| !isIntegralNumber(n),
        .object => isNamedBase(v, .float),
        else => false,
    } };
}

pub fn nativeIsString(v: Value) Value {
    return .{ .boolean = vms.isStringValue(v) or isNamedBase(v, .string) };
}

pub fn nativeIsArray(v: Value) Value {
    return .{ .boolean = (v == .object and vms.isArrayObject(v.object)) or isNamedBase(v, .array_t) };
}

pub fn nativeIsMap(v: Value) Value {
    return .{ .boolean = (v == .object and vms.isMapObject(v.object)) or isNamedBase(v, .map_t) };
}

pub fn nativeIsStruct(v: Value) Value {
    return .{ .boolean = v == .object and v.object.* == .struct_instance };
}

pub fn nativeIsNull(v: Value) Value {
    return .{ .boolean = v == .null };
}

fn isIntegralNumber(n: f64) bool {
    return @trunc(n) == n;
}

fn rootNamedType(typ_obj: *Object) *Object {
    var cur = typ_obj;
    while (vmtyp.resolveParentType(cur)) |parent| cur = parent;
    return cur;
}

fn isNamedBase(v: Value, base: @import("../value.zig").NamedTypeBase) bool {
    if (!(v == .object and v.object.* == .named_value)) return false;
    return rootNamedType(v.object.named_value.typ).named_type.base == base;
}

const MaxDeepVisits = 1024;

const DeepEqVisit = struct { a: *Object, b: *Object };
const CloneVisit = struct { src: *Object, dst: *Object };

pub fn makeTuple2(a: Value, b: Value) !Value {
    const obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
    defer vms.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(Value, 2);
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

pub fn nativeClone(v: Value) !Value {
    var visits: [MaxDeepVisits]CloneVisit = undefined;
    var visit_len: usize = 0;
    return cloneValue(v, visits[0..], &visit_len);
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

const MaxDeepEqMapScratch = 128;
fn deepEqualMap(a_entries: []const MapEntry, b_entries: []const MapEntry, visits: []DeepEqVisit, visit_len: *usize) anyerror!bool {
    if (a_entries.len != b_entries.len) return false;
    if (b_entries.len > MaxDeepEqMapScratch) return error.OutOfMemory;
    var used_buf: [MaxDeepEqMapScratch]bool = undefined;
    const used = used_buf[0..b_entries.len];
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
        if ((a.* == .array or a.* == .array_managed) and (b.* == .array or b.* == .array_managed)) {
        } else if (vms.isMapObject(a) and vms.isMapObject(b)) {
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
            for (aa, 0..) |item, i| { if (!try deepEqualValue(item, bb[i], visits, visit_len)) return false; }
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
        .native_function => |anf| { const bnf = b.native_function; return anf.id == bnf.id and anf.arity == bnf.arity; },
        .host_module_function => |ahf| { const bhf = b.host_module_function; return ahf.call_id == bhf.call_id and ahf.arity == bhf.arity; },
        .struct_type => |ast| return common.streq(ast.qualified_name, b.struct_type.qualified_name),
        .interface_type => |ait| return common.streq(ait.qualified_name, b.interface_type.qualified_name),
        .named_type => |ant| return common.streq(ant.qualified_name, b.named_type.qualified_name),
        .named_value => |anv| {
            if (anv.typ != b.named_value.typ) return false;
            try appendVisitedPair(a, b, visits, visit_len);
            return try deepEqualValue(anv.value, b.named_value.value, visits, visit_len);
        },
        .enum_type => |aet| return common.streq(aet.qualified_name, b.enum_type.qualified_name),
        .enum_value => |aev| { const bev = b.enum_value; return aev.typ == bev.typ and aev.ordinal == bev.ordinal; },
        .struct_instance => |asi| {
            const bsi = b.struct_instance;
            if (asi.typ != bsi.typ) return false;
            try appendVisitedPair(a, b, visits, visit_len);
            if (asi.fields.len != bsi.fields.len) return false;
            for (asi.fields, bsi.fields) |af, bf| {
                const ak = vms.asStringValue(af.key) catch return false;
                const bk = vms.asStringValue(bf.key) catch return false;
                if (!common.streq(ak, bk)) return false;
                if (!try deepEqualValue(af.value, bf.value, visits, visit_len)) return false;
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
        .named_type_fn => |anf| { const bnf = b.named_type_fn; return anf.typ == bnf.typ and anf.kind == bnf.kind; },
        .enum_type_fn => |aef| return aef.typ == b.enum_type_fn.typ,
        .string_builder => |asb| return common.streq(asb.buf[0..asb.len], b.string_builder.buf[0..b.string_builder.len]),
        .bigint => |abi| return abi.toConst().eql(b.bigint.toConst()),
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
    };
}

fn cloneFindExisting(src: *Object, visits: []const CloneVisit, visit_len: usize) ?*Object {
    for (visits[0..visit_len]) |v| { if (v.src == src) return v.dst; }
    return null;
}

fn cloneRemember(src: *Object, dst: *Object, visits: []CloneVisit, visit_len: *usize) !void {
    if (visit_len.* >= visits.len) return error.OutOfMemory;
    visits[visit_len.*] = .{ .src = src, .dst = dst };
    visit_len.* += 1;
}

fn cloneValue(v: Value, visits: []CloneVisit, visit_len: *usize) anyerror!Value {
    return switch (v) {
        .string => |s| try vmgc.makeDynString(s.bytes),
        .object => |obj| try cloneObject(obj, visits, visit_len),
        else => v,
    };
}

fn cloneObject(src: *Object, visits: []CloneVisit, visit_len: *usize) anyerror!Value {
    if (cloneFindExisting(src, visits, visit_len.*)) |cached| return .{ .object = cached };
    switch (src.*) {
        .array, .array_managed, .array_view, .array_capacity => {
            const out_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
            defer vms.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            const items = try vms.asArraySlice(src);
            const out = try vmgc.vmAllocManagedSlice(Value, items.len);
            for (out) |*slot| slot.* = .null;
            out_obj.* = .{ .array_managed = out[0..items.len] };
            for (items, 0..) |item, i| out[i] = try cloneValue(item, visits, visit_len);
            return .{ .object = out_obj };
        },
        .map, .map_managed, .map_hashed => {
            const entries = try vms.asMapSlice(src);
            const out_map = try vmgc.allocTempRootedManagedMap(entries.len);
            defer vms.popTempRoot();
            try cloneRemember(src, out_map.obj, visits, visit_len);
            for (entries, 0..) |entry, i| {
                const k = try cloneValue(entry.key, visits, visit_len);
                try vms.pushTempRoot(k);
                out_map.entries[i].key = k;
                out_map.entries[i].value = try cloneValue(entry.value, visits, visit_len);
                vms.popTempRoot();
                out_map.publish(i + 1);
            }
            return .{ .object = out_map.obj };
        },
        .dyn_string => |s| return vmgc.makeDynString(s),
        .string_view => |sv| return vmgc.makeDynString(sv.bytes),
        .string_builder => |sb| {
            const out_obj = try vmgc.allocTempRooted(.{ .string_builder = .{ .buf = &[_]u8{}, .len = 0 } });
            if (sb.len == 0) {
            } else {
                const new_buf = try vmgc.vmAllocManagedBytes(sb.len);
                @memcpy(new_buf[0..sb.len], sb.buf[0..sb.len]);
                out_obj.* = .{ .string_builder = .{ .buf = new_buf, .len = sb.len } };
                vms.popTempRoot();
            }
            return .{ .object = out_obj };
        },
        .function, .closure, .native_function, .host_module_function, .struct_type, .interface_type,
        .named_type, .enum_type, .iterator, .variant_type, .variant_ctor,
        .named_type_fn, .enum_type_fn, .cell, .bigint => return .{ .object = src },
        .named_value => |nv| {
            const out_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
            defer vms.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            out_obj.* = .{ .named_value = .{ .typ = nv.typ, .value = try cloneValue(nv.value, visits, visit_len) } };
            return .{ .object = out_obj };
        },
        .enum_value => |ev| {
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .enum_value = ev };
            return .{ .object = out_obj };
        },
        .struct_instance => |inst| {
            const out_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
            defer vms.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            const fields = try vmgc.vmAllocManagedSlice(MapEntry, inst.fields.len);
            for (fields) |*slot| slot.* = .{ .key = .null, .value = .null };
            out_obj.* = .{ .struct_instance = .{ .typ = inst.typ, .fields = fields } };
            for (inst.fields, 0..) |field, i| {
                fields[i].key = field.key;
                fields[i].value = try cloneValue(field.value, visits, visit_len);
            }
            return .{ .object = out_obj };
        },
        .variant_value => |vv| {
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .variant_value = .{ .typ = vv.typ, .tag = vv.tag, .ordinal = vv.ordinal, .payload = .null, .shared_values = &[_]Value{}, .arm_fields = &[_]Value{} } };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            var shared = try vmgc.vmAllocManagedSlice(Value, vv.shared_values.len);
            out_obj.variant_value.shared_values = shared[0..0]; // publish immediately
            for (vv.shared_values, 0..) |sv, i| {
                shared[i] = try cloneValue(sv, visits, visit_len);
                out_obj.variant_value.shared_values = shared[0 .. i + 1]; // grow visible
            }
            var arm = try vmgc.vmAllocManagedSlice(Value, vv.arm_fields.len);
            out_obj.variant_value.arm_fields = arm[0..0]; // publish immediately
            for (vv.arm_fields, 0..) |af, i| {
                arm[i] = try cloneValue(af, visits, visit_len);
                out_obj.variant_value.arm_fields = arm[0 .. i + 1]; // grow visible
            }
            out_obj.variant_value.payload = try cloneValue(vv.payload, visits, visit_len);
            return .{ .object = out_obj };
        },
    }
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .core_append => {
            const start = vms.vmState().stack_top - argc;
            try host_abi_mod.dispatchHostCallVariadic(host_abi.CAP_CORE_APPEND, .core_append, argc, start, nativeAppend);
        },
        .core_bytelen => {
            if (argc != nf.arity) return error.ArityMismatch;
            try host_abi_mod.dispatchHostCall1(host_abi.CAP_CORE_BYTELEN, .core_bytelen, argc, nativeByteLen);
        },
        .core_clone => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeClone(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_contains => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.unboxNamed(vms.vmTop(1));
            const needle = vms.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const out = try nativeContains(arr_val.object, needle);
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_deep_equal => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeDeepEqual(vms.vmTop(1), vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_delete => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmTop(1));
            const key = vms.vmTop(0);
            if (m_val != .object) return error.TypeError;
            const out = try nativeDelete(m_val.object, key);
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const msg = try vms.asStringValue(vms.vmTop(0));
            const copy = try vmgc.vmAllocManagedBytes(msg.len);
            @memcpy(copy[0..msg.len], msg);
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .error_value = try chunk.internStr(copy[0..msg.len]) });
        },
        .core_gc => {
            if (argc != nf.arity) return error.ArityMismatch;
            vmgc.collectGarbage();
            vms.vmPopArgs(argc);
            try vms.vmPush(.null);
        },
        .core_gc_live_objects => {
            if (argc != nf.arity) return error.ArityMismatch;
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .int = @intCast(heap.liveObjectCount()) });
        },
        .core_gc_stats => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStats();
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_gc_stats_ext => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStatsExt();
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_has => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmTop(1));
            const key = vms.vmTop(0);
            if (m_val != .object) return error.TypeError;
            const out = try nativeHas(m_val.object, key);
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_is_array => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsArray(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_is_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmTop(0);
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .boolean = arg == .error_value });
        },
        .core_is_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsFloat(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_is_int => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsInt(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_is_map => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsMap(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_is_null => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsNull(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_is_string => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsString(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_is_struct => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsStruct(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_keys => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmTop(0));
            if (m_val != .object) return error.TypeError;
            const out = try nativeKeys(m_val.object);
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_len => {
            if (argc != nf.arity) return error.ArityMismatch;
            try host_abi_mod.dispatchHostCall1(host_abi.CAP_CORE_LEN, .core_len, argc, nativeLen);
        },
        .core_recover => {
            if (argc != nf.arity) return error.ArityMismatch;
            vms.vmPopArgs(argc);
            if (vms.vmState().is_panicking and !vms.vmState().recovered) {
                const pv = vms.vmState().panic_value;
                vms.vmState().recovered = true;
                try vms.vmPush(pv);
            } else {
                try vms.vmPush(.null);
            }
        },
        .core_remove => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.unboxNamed(vms.vmTop(1));
            const idx_val = vms.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const out = try nativeRemove(arr_val.object, idx_val);
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_type_of => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeTypeNameValue(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .core_values => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmTop(0));
            if (m_val != .object) return error.TypeError;
            const out = try nativeValues(m_val.object);
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        else => {},
    }
}
