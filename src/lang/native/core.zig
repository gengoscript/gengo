const std = @import("std");
const common = @import("../common.zig");
const heap = @import("../../runtime/heap.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const vmmap = @import("../vm_map.zig");
const vmtyp = @import("../vm_types.zig");
const vmstr = @import("../vm_string.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;
const StructFieldSpec = @import("../value.zig").StructFieldSpec;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const host_abi = @import("../../runtime/host_abi.zig");
const host_abi_mod = @import("host_abi.zig");
const MaxNativeArgs = @import("native_ids.zig").MaxNativeArgs;

pub fn nativeLen(v: Value) !Value {
    const uv = vms.unboxNamed(v);
    const n: usize = switch (uv) {
        .string => |s| try vmstr.utf8RuneCountCached(s),
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| try vmstr.utf8RuneCountCached(s),
            .array, .array_managed => vms.asArraySlice(obj).len,
            .map, .map_managed, .map_hashed => vms.asMapSlice(obj).len,
            .struct_instance => |s| s.fields.len,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .number = @floatFromInt(n) };
}

pub fn nativeByteLen(v: Value) !Value {
    const n: usize = switch (v) {
        .string => |s| s.len,
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| s.len,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .number = @floatFromInt(n) };
}

pub fn nativeDelete(m_obj: *Object, key: Value) !Value {
    switch (m_obj.*) {
        .map => {
            const items = m_obj.map;
            var fi: usize = 0;
            while (fi < items.len) : (fi += 1) {
                if (vmmap.mapKeyEquals(items[fi].key, key)) {
                    const removed = items[fi].value;
                    items[fi] = items[items.len - 1];
                    m_obj.* = .{ .map = items[0 .. items.len - 1] };
                    return removed;
                }
            }
            return .null;
        },
        .map_managed => {
            const items = m_obj.map_managed;
            var fi: usize = 0;
            while (fi < items.len) : (fi += 1) {
                if (vmmap.mapKeyEquals(items[fi].key, key)) {
                    const removed = items[fi].value;
                    items[fi] = items[items.len - 1];
                    m_obj.* = .{ .map_managed = items[0 .. items.len - 1] };
                    return removed;
                }
            }
            return .null;
        },
        .map_hashed => {
            const hm = &m_obj.map_hashed;
            const idx = vmmap.mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key) orelse return .null;
            const removed = hm.entries[idx].value;
            hm.entries[idx] = hm.entries[hm.len - 1];
            hm.len -= 1;
            vmmap.mapBuildHashedBuckets(hm.entries[0..hm.len], hm.buckets);
            return removed;
        },
        else => return error.TypeError,
    }
}

pub fn nativeHas(m_obj: *Object, key: Value) !Value {
    const items = vms.asMapSlice(m_obj);
    for (items) |entry| {
        if (vmmap.mapKeyEquals(entry.key, key)) return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

pub fn nativeKeys(m_obj: *Object) !Value {
    if (!vms.isMapObject(m_obj)) return error.TypeError;
    const items = vms.asMapSlice(m_obj);
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const out = try vmgc.vmAllocManagedSlice(Value, items.len);
    for (items, 0..) |entry, i| out[i] = entry.key;
    obj.* = .{ .array_managed = out[0..items.len] };
    return .{ .object = obj };
}

pub fn nativeValues(m_obj: *Object) !Value {
    if (!vms.isMapObject(m_obj)) return error.TypeError;
    const items = vms.asMapSlice(m_obj);
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const out = try vmgc.vmAllocManagedSlice(Value, items.len);
    for (items, 0..) |entry, i| out[i] = entry.value;
    obj.* = .{ .array_managed = out[0..items.len] };
    return .{ .object = obj };
}

pub fn nativeContains(arr_obj: *Object, needle: Value) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = vms.asArraySlice(arr_obj);
    for (items) |item| {
        const eq = try nativeDeepEqual(item, needle);
        if (eq == .boolean and eq.boolean) return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

pub fn nativeRemove(arr_obj: *Object, idx_val: Value) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = vms.asArraySlice(arr_obj);
    const idx = try vms.vmIndexFromVal(idx_val);
    if (idx >= items.len) return error.IndexOutOfBounds;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
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
            var ei: usize = 1;
            while (ei < argc) : (ei += 1) {
                if (!vmtyp.matchesTypeSpec(vms.vmState().stack[start + ei], es)) return error.TypeError;
            }
        }
    }
    const base = vms.asArraySlice(arr_val.object);
    const extra: usize = argc - 1;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const out = try vmgc.vmAllocManagedSlice(Value, base.len + extra);
    @memcpy(out[0..base.len], base);
    var i: usize = 0;
    while (i < extra) : (i += 1) {
        out[base.len + i] = vms.vmState().stack[start + 1 + i];
    }
    obj.* = .{ .array_managed = out[0 .. base.len + extra] };
    if (is_named) return vmtyp.makeNamedValue(first.object.named_value.typ, .{ .object = obj });
    return .{ .object = obj };
}

pub fn nativeErrorMsg(msg: []const u8) Value {
    return .{ .error_value = msg };
}

pub fn nativeIsError(v: Value) Value {
    return .{ .boolean = v == .error_value };
}

pub fn nativeGc() void {
    vmgc.vmCollectGarbage();
}

pub fn nativeGcLiveObjects() Value {
    return .{ .number = @floatFromInt(heap.liveObjectCount()) };
}

pub fn nativeGcStats() !Value {
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const items = heap.bump(MapEntry, 3) orelse return error.OutOfMemory;
    items[0] = .{ .key = .{ .string = "heap_used_bytes" }, .value = .{ .number = @floatFromInt(heap.usedBytes()) } };
    items[1] = .{ .key = .{ .string = "heap_size_bytes" }, .value = .{ .number = @floatFromInt(heap.HeapSize) } };
    items[2] = .{ .key = .{ .string = "live_objects" }, .value = .{ .number = @floatFromInt(heap.liveObjectCount()) } };
    obj.* = .{ .map = items[0..3] };
    return .{ .object = obj };
}

pub fn nativeGcStatsExt() !Value {
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const items = heap.bump(MapEntry, 8) orelse return error.OutOfMemory;
    items[0] = .{ .key = .{ .string = "heap_used_bytes" }, .value = .{ .number = @floatFromInt(heap.usedBytes()) } };
    items[1] = .{ .key = .{ .string = "heap_size_bytes" }, .value = .{ .number = @floatFromInt(heap.HeapSize) } };
    items[2] = .{ .key = .{ .string = "live_objects" }, .value = .{ .number = @floatFromInt(heap.liveObjectCount()) } };
    items[3] = .{ .key = .{ .string = "gc_runs" }, .value = .{ .number = @floatFromInt(vms.vmState().gc_runs) } };
    items[4] = .{ .key = .{ .string = "gc_time_ns" }, .value = .{ .number = @floatFromInt(vms.vmState().gc_time_ns) } };
    items[5] = .{ .key = .{ .string = "alloc_object_calls" }, .value = .{ .number = @floatFromInt(vms.vmState().alloc_object_calls) } };
    items[6] = .{ .key = .{ .string = "alloc_managed_slice_calls" }, .value = .{ .number = @floatFromInt(vms.vmState().alloc_managed_slice_calls) } };
    items[7] = .{ .key = .{ .string = "alloc_managed_bytes_calls" }, .value = .{ .number = @floatFromInt(vms.vmState().alloc_managed_bytes_calls) } };
    obj.* = .{ .map = items[0..8] };
    return .{ .object = obj };
}

pub fn nativeConvToInt(v: Value) !Value {
    switch (v) {
        .number => |n| { const tr = @trunc(n); return .{ .number = tr }; },
        .rune => |r| return .{ .number = @floatFromInt(r) },
        .boolean => |b| return .{ .number = if (b) 1 else 0 },
        .string => |s| { const n = common.parseFloat(s) orelse return error.TypeError; const tr = @trunc(n); return .{ .number = tr }; },
        .object => |o| {
            if (o.* == .dyn_string) {
                const n = common.parseFloat(o.dyn_string) orelse return error.TypeError;
                const tr = @trunc(n);
                return .{ .number = tr };
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    }
}

pub fn nativeConvToFloat(v: Value) !Value {
    switch (v) {
        .number => |n| return .{ .number = n },
        .rune => |r| return .{ .number = @floatFromInt(r) },
        .boolean => |b| return .{ .number = if (b) 1 else 0 },
        .string => |s| { const n = common.parseFloat(s) orelse return error.TypeError; return .{ .number = n }; },
        .object => |o| {
            if (o.* == .dyn_string) {
                const n = common.parseFloat(o.dyn_string) orelse return error.TypeError;
                return .{ .number = n };
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    }
}

pub fn nativeConvToBool(v: Value) !Value {
    return .{ .boolean = switch (v) {
        .boolean => |b| b,
        .number => |n| n != 0.0,
        .decimal => |d| d != 0,
        .rune => |r| r != 0,
        .string => |s| s.len != 0,
        .error_value => |e| e.len != 0,
        .null => false,
        .object => true,
    } };
}

pub fn nativeConvToString(v: Value) !Value {
    return switch (v) {
        .string => |s| vmgc.makeDynString(s),
        .object => |o| {
            if (o.* == .dyn_string) return vmgc.makeDynString(o.dyn_string);
            return error.TypeError;
        },
        .boolean => |b| vmgc.makeDynString(if (b) "true" else "false"),
        .number => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .decimal => |d| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{d}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .rune => |r| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(r, buf[0..]) catch return error.TypeError;
            return vmgc.makeDynString(buf[0..n]);
        },
        .null => vmgc.makeDynString("null"),
        .error_value => |e| vmgc.makeDynString(e),
    };
}

pub fn nativeTypeNameValue(v: Value) Value {
    return switch (v) {
        .number => |n| .{ .string = if (isIntegralNumber(n)) "int" else "float" },
        .decimal => .{ .string = "decimal" },
        .rune => .{ .string = "rune" },
        .boolean => .{ .string = "bool" },
        .string => .{ .string = "string" },
        .error_value => .{ .string = "error" },
        .null => .{ .string = "null" },
        .object => |obj| switch (obj.*) {
            .dyn_string => .{ .string = "string" },
            .array, .array_managed => .{ .string = "array" },
            .map, .map_managed, .map_hashed => .{ .string = "map" },
            .native_function => .{ .string = "native_func" },
            .host_module_function => .{ .string = "host_func" },
            .function, .closure, .named_type_fn => .{ .string = "func" },
            .struct_type => |st| .{ .string = st.name },
            .interface_type => |it| .{ .string = it.name },
            .named_type => |nt| .{ .string = nt.name },
            .named_value => |nv| .{ .string = rootNamedType(nv.typ).named_type.name },
            .enum_type => |et| .{ .string = et.name },
            .enum_value => |ev| .{ .string = ev.typ.enum_type.name },
            .struct_instance => |inst| .{ .string = inst.typ.struct_type.name },
            .iterator => .{ .string = "iterator" },
            .variant_type => |vt| .{ .string = vt.name },
            .variant_value => |vv| .{ .string = vv.typ.variant_type.name },
            .variant_ctor => |vc| .{ .string = vc.typ.variant_type.name },
            .string_builder => .{ .string = "string_builder" },
            .cell => .{ .string = "cell" },
        },
    };
}

pub fn nativeIsInt(v: Value) Value {
    return .{ .boolean = switch (v) {
        .number => |n| isIntegralNumber(n),
        .object => isNamedBase(v, .int),
        else => false,
    } };
}

pub fn nativeIsFloat(v: Value) Value {
    return .{ .boolean = switch (v) {
        .number => |n| !isIntegralNumber(n),
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
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
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
    var i: usize = 0;
    while (i < visit_len) : (i += 1) {
        const p = visits[i];
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
    const used = heap.bump(bool, b_entries.len) orelse return error.OutOfMemory;
    @memset(used[0..b_entries.len], false);
    for (a_entries) |ae| {
        var matched = false;
        var i: usize = 0;
        while (i < b_entries.len) : (i += 1) {
            if (used[i]) continue;
            if (!try deepEqualValue(ae.key, b_entries[i].key, visits, visit_len)) continue;
            if (!try deepEqualValue(ae.value, b_entries[i].value, visits, visit_len)) continue;
            used[i] = true;
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
            return try deepEqualMap(vms.asMapSlice(a), vms.asMapSlice(b), visits, visit_len);
        } else {
            return false;
        }
    }
    if (hasVisitedPair(a, b, visits, visit_len.*)) return true;
    switch (a.*) {
        .array, .array_managed => {
            try appendVisitedPair(a, b, visits, visit_len);
            const aa = vms.asArraySlice(a);
            const bb = vms.asArraySlice(b);
            if (aa.len != bb.len) return false;
            for (aa, 0..) |item, i| { if (!try deepEqualValue(item, bb[i], visits, visit_len)) return false; }
            return true;
        },
        .map, .map_managed, .map_hashed => {
            try appendVisitedPair(a, b, visits, visit_len);
            return deepEqualMap(vms.asMapSlice(a), vms.asMapSlice(b), visits, visit_len);
        },
        .dyn_string => return common.streq(a.dyn_string, b.dyn_string),
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
            var i: usize = 0;
            while (i < asi.fields.len) : (i += 1) {
                if (!common.streq(asi.fields[i].key.string, bsi.fields[i].key.string)) return false;
                if (!try deepEqualValue(asi.fields[i].value, bsi.fields[i].value, visits, visit_len)) return false;
            }
            return true;
        },
        .variant_type => |avt| return common.streq(avt.qualified_name, b.variant_type.qualified_name),
        .variant_value => |avv| {
            const bvv = b.variant_value;
            if (avv.typ != bvv.typ or !common.streq(avv.tag, bvv.tag)) return false;
            try appendVisitedPair(a, b, visits, visit_len);
            return try deepEqualValue(avv.payload, bvv.payload, visits, visit_len);
        },
        .variant_ctor => |avc| {
            const bvc = b.variant_ctor;
            return avc.typ == bvc.typ and avc.ordinal == bvc.ordinal and common.streq(avc.tag, bvc.tag);
        },
        .named_type_fn => |anf| { const bnf = b.named_type_fn; return anf.typ == bnf.typ and anf.kind == bnf.kind; },
        .string_builder => |asb| return common.streq(asb.buf[0..asb.len], b.string_builder.buf[0..b.string_builder.len]),
    }
}

fn deepEqualValue(a: Value, b: Value, visits: []DeepEqVisit, visit_len: *usize) anyerror!bool {
    if (a == .string and b == .object and b.object.* == .dyn_string) return common.streq(a.string, b.object.dyn_string);
    if (b == .string and a == .object and a.object.* == .dyn_string) return common.streq(a.object.dyn_string, b.string);
    if (a == .object and b == .object) return deepEqualObject(a.object, b.object, visits, visit_len);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .number => |x| x == b.number,
        .decimal => |x| x == b.decimal,
        .rune => |x| x == b.rune,
        .boolean => |x| x == b.boolean,
        .string => |x| common.streq(x, b.string),
        .error_value => |x| common.streq(x, b.error_value),
        .null => true,
        .object => unreachable,
    };
}

fn cloneFindExisting(src: *Object, visits: []const CloneVisit, visit_len: usize) ?*Object {
    var i: usize = 0;
    while (i < visit_len) : (i += 1) { if (visits[i].src == src) return visits[i].dst; }
    return null;
}

fn cloneRemember(src: *Object, dst: *Object, visits: []CloneVisit, visit_len: *usize) !void {
    if (visit_len.* >= visits.len) return error.OutOfMemory;
    visits[visit_len.*] = .{ .src = src, .dst = dst };
    visit_len.* += 1;
}

fn cloneValue(v: Value, visits: []CloneVisit, visit_len: *usize) anyerror!Value {
    return switch (v) {
        .string => |s| try vmgc.makeDynString(s),
        .object => |obj| try cloneObject(obj, visits, visit_len),
        else => v,
    };
}

fn cloneObject(src: *Object, visits: []CloneVisit, visit_len: *usize) anyerror!Value {
    if (cloneFindExisting(src, visits, visit_len.*)) |cached| return .{ .object = cached };
    switch (src.*) {
        .array, .array_managed => {
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            const items = vms.asArraySlice(src);
            const out = try vmgc.vmAllocManagedSlice(Value, items.len);
            for (out) |*slot| slot.* = .null;
            out_obj.* = .{ .array_managed = out[0..items.len] };
            for (items, 0..) |item, i| out[i] = try cloneValue(item, visits, visit_len);
            return .{ .object = out_obj };
        },
        .map, .map_managed, .map_hashed => {
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .map = &[_]MapEntry{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            const entries = vms.asMapSlice(src);
            const out = try vmgc.vmAllocManagedSlice(MapEntry, entries.len);
            for (out) |*slot| slot.* = .{ .key = .null, .value = .null };
            out_obj.* = .{ .map_managed = out[0..entries.len] };
            for (entries, 0..) |entry, i| {
                out[i].key = try cloneValue(entry.key, visits, visit_len);
                out[i].value = try cloneValue(entry.value, visits, visit_len);
            }
            return .{ .object = out_obj };
        },
        .dyn_string => |s| return vmgc.makeDynString(s),
        .function, .closure, .native_function, .host_module_function, .struct_type, .interface_type,
        .named_type, .enum_type, .iterator, .variant_type, .variant_ctor,
        .named_type_fn, .string_builder, .cell => return .{ .object = src },
        .named_value => |nv| {
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
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
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
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
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            try cloneRemember(src, out_obj, visits, visit_len);
            var shared = try vmgc.vmAllocManagedSlice(Value, vv.shared_values.len);
            for (vv.shared_values, 0..) |sv, i| shared[i] = try cloneValue(sv, visits, visit_len);
            var arm = try vmgc.vmAllocManagedSlice(Value, vv.arm_fields.len);
            for (vv.arm_fields, 0..) |af, i| arm[i] = try cloneValue(af, visits, visit_len);
            out_obj.* = .{ .variant_value = .{ .typ = vv.typ, .tag = vv.tag, .ordinal = vv.ordinal, .payload = try cloneValue(vv.payload, visits, visit_len), .shared_values = shared, .arm_fields = arm } };
            return .{ .object = out_obj };
        },
    }
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .core_append => {

            const start = vms.vmState().stack_top - argc;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CORE_APPEND) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try host_abi_mod.wireFromValue(vms.vmState().stack[start + i]);
                    }
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.core_append, args_wire[0..argc], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    var j: usize = 0;
                    while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const out = try nativeAppend(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_bytelen => {

            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CORE_BYTELEN) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.core_bytelen, arg_wire[0..], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeByteLen(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_clone => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeClone(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_contains => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const arr_val = vms.unboxNamed(vms.vmState().stack[top - 2]);
            const needle = vms.vmState().stack[top - 1];
            if (arr_val != .object) return error.TypeError;
            const out = try nativeContains(arr_val.object, needle);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_deep_equal => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const out = try nativeDeepEqual(vms.vmState().stack[top - 2], vms.vmState().stack[top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_delete => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const m_val = vms.unboxNamed(vms.vmState().stack[top - 2]);
            const key = vms.vmState().stack[top - 1];
            if (m_val != .object) return error.TypeError;
            const out = try nativeDelete(m_val.object, key);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_error => {

            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const msg = try vms.asStringValue(arg);
            const copy = heap.bump(u8, msg.len) orelse return error.OutOfMemory;
            @memcpy(copy[0..msg.len], msg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .error_value = copy[0..msg.len] });
        },
        .core_gc => {

            if (argc != nf.arity) return error.ArityMismatch;
            vmgc.collectGarbage();
            _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .core_gc_live_objects => {

            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @floatFromInt(heap.liveObjectCount()) });
        },
        .core_gc_stats => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStats();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_gc_stats_ext => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStatsExt();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_has => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const m_val = vms.unboxNamed(vms.vmState().stack[top - 2]);
            const key = vms.vmState().stack[top - 1];
            if (m_val != .object) return error.TypeError;
            const out = try nativeHas(m_val.object, key);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_array => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsArray(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_error => {

            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = arg == .error_value });
        },
        .core_is_float => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsFloat(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_int => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsInt(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_map => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsMap(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_null => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsNull(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_string => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsString(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_struct => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsStruct(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_keys => {

            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (m_val != .object) return error.TypeError;
            const out = try nativeKeys(m_val.object);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_len => {

            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CORE_LEN) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.core_len, arg_wire[0..], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeLen(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_recover => {

            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vms.vmPop();
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
            const top = vms.vmState().stack_top;
            const arr_val = vms.unboxNamed(vms.vmState().stack[top - 2]);
            const idx_val = vms.vmState().stack[top - 1];
            if (arr_val != .object) return error.TypeError;
            const out = try nativeRemove(arr_val.object, idx_val);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_type_of => {

            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = nativeTypeNameValue(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_values => {

            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (m_val != .object) return error.TypeError;
            const out = try nativeValues(m_val.object);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        else => {},
    }
}
