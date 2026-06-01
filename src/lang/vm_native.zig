const std = @import("std");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const host_abi = @import("../runtime/host_abi.zig");
const io = @import("../runtime/io.zig");
const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const vmmap = @import("vm_map.zig");
const vmtyp = @import("vm_types.zig");
const vmstr = @import("vm_string.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;
const NativeFuncObj = @import("value.zig").NativeFuncObj;

const NativeFnId = enum(u8) {
    io_println = 1,
    io_print = 46,
    io_printf = 15,
    core_len = 2,
    core_append = 3,
    core_error = 4,
    core_is_error = 5,
    core_gc = 6,
    core_gc_live_objects = 7,
    core_gc_stats = 8,
    core_bytelen = 9,
    conv_to_int = 10,
    conv_to_float = 11,
    conv_to_bool = 12,
    conv_to_string = 13,
    core_gc_stats_ext = 14,
    core_delete = 30,
    core_has = 31,
    core_keys = 32,
    core_values = 33,
    core_contains = 34,
    core_remove = 35,
    str_split = 36,
    str_join = 37,
    str_trim = 38,
    str_upper = 39,
    str_lower = 40,
    str_starts_with = 41,
    str_ends_with = 42,
    str_index_of = 43,
    core_recover = 44,
    str_builder_new = 45,
    math_abs = 16,
    math_sqrt = 17,
    math_floor = 18,
    math_ceil = 19,
    math_round = 20,
    math_sin = 21,
    math_cos = 22,
    math_tan = 23,
    math_log = 24,
    math_log2 = 25,
    math_log10 = 26,
    math_pow = 27,
    math_min = 28,
    math_max = 29,
};
const MaxNativeArgs = 255;

fn makeNative(id: NativeFnId, arity: u8) !Value {
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .native_function = .{ .id = @intFromEnum(id), .arity = arity } };
    return .{ .object = obj };
}

pub fn buildStdModule() !*Object {
    if (vms.vmState().std_module) |m| return m;

    const io_items = heap.bump(MapEntry, 3) orelse return error.OutOfMemory;
    io_items[0] = .{
        .key = .{ .string = "println" },
        .value = try makeNative(.io_println, 255),
    };
    io_items[1] = .{
        .key = .{ .string = "printf" },
        .value = try makeNative(.io_printf, 255),
    };
    io_items[2] = .{
        .key = .{ .string = "print" },
        .value = try makeNative(.io_print, 255),
    };
    const io_obj = try vmgc.vmAllocObject();
    io_obj.* = .{ .map = io_items[0..3] };

    const core_items = heap.bump(MapEntry, 16) orelse return error.OutOfMemory;
    core_items[0] = .{
        .key = .{ .string = "len" },
        .value = try makeNative(.core_len, 1),
    };
    core_items[1] = .{
        .key = .{ .string = "append" },
        .value = try makeNative(.core_append, 255),
    };
    core_items[2] = .{
        .key = .{ .string = "error" },
        .value = try makeNative(.core_error, 1),
    };
    core_items[3] = .{
        .key = .{ .string = "is_error" },
        .value = try makeNative(.core_is_error, 1),
    };
    core_items[4] = .{
        .key = .{ .string = "gc" },
        .value = try makeNative(.core_gc, 0),
    };
    core_items[5] = .{
        .key = .{ .string = "gc_live_objects" },
        .value = try makeNative(.core_gc_live_objects, 0),
    };
    core_items[6] = .{
        .key = .{ .string = "gc_stats" },
        .value = try makeNative(.core_gc_stats, 0),
    };
    core_items[7] = .{
        .key = .{ .string = "bytelen" },
        .value = try makeNative(.core_bytelen, 1),
    };
    core_items[8] = .{
        .key = .{ .string = "gc_stats_ext" },
        .value = try makeNative(.core_gc_stats_ext, 0),
    };
    core_items[9] = .{
        .key = .{ .string = "delete" },
        .value = try makeNative(.core_delete, 2),
    };
    core_items[10] = .{
        .key = .{ .string = "has" },
        .value = try makeNative(.core_has, 2),
    };
    core_items[11] = .{
        .key = .{ .string = "keys" },
        .value = try makeNative(.core_keys, 1),
    };
    core_items[12] = .{
        .key = .{ .string = "values" },
        .value = try makeNative(.core_values, 1),
    };
    core_items[13] = .{
        .key = .{ .string = "contains" },
        .value = try makeNative(.core_contains, 2),
    };
    core_items[14] = .{
        .key = .{ .string = "remove" },
        .value = try makeNative(.core_remove, 2),
    };
    core_items[15] = .{
        .key = .{ .string = "recover" },
        .value = try makeNative(.core_recover, 0),
    };
    const core_obj = try vmgc.vmAllocObject();
    core_obj.* = .{ .map = core_items[0..16] };

    const conv_items = heap.bump(MapEntry, 4) orelse return error.OutOfMemory;
    conv_items[0] = .{
        .key = .{ .string = "to_int" },
        .value = try makeNative(.conv_to_int, 1),
    };
    conv_items[1] = .{
        .key = .{ .string = "to_float" },
        .value = try makeNative(.conv_to_float, 1),
    };
    conv_items[2] = .{
        .key = .{ .string = "to_bool" },
        .value = try makeNative(.conv_to_bool, 1),
    };
    conv_items[3] = .{
        .key = .{ .string = "to_string" },
        .value = try makeNative(.conv_to_string, 1),
    };
    const conv_obj = try vmgc.vmAllocObject();
    conv_obj.* = .{ .map = conv_items[0..4] };

    const math_items = heap.bump(MapEntry, 17) orelse return error.OutOfMemory;
    math_items[0]  = .{ .key = .{ .string = "abs"   }, .value = try makeNative(.math_abs,   1) };
    math_items[1]  = .{ .key = .{ .string = "sqrt"  }, .value = try makeNative(.math_sqrt,  1) };
    math_items[2]  = .{ .key = .{ .string = "floor" }, .value = try makeNative(.math_floor, 1) };
    math_items[3]  = .{ .key = .{ .string = "ceil"  }, .value = try makeNative(.math_ceil,  1) };
    math_items[4]  = .{ .key = .{ .string = "round" }, .value = try makeNative(.math_round, 1) };
    math_items[5]  = .{ .key = .{ .string = "sin"   }, .value = try makeNative(.math_sin,   1) };
    math_items[6]  = .{ .key = .{ .string = "cos"   }, .value = try makeNative(.math_cos,   1) };
    math_items[7]  = .{ .key = .{ .string = "tan"   }, .value = try makeNative(.math_tan,   1) };
    math_items[8]  = .{ .key = .{ .string = "log"   }, .value = try makeNative(.math_log,   1) };
    math_items[9]  = .{ .key = .{ .string = "log2"  }, .value = try makeNative(.math_log2,  1) };
    math_items[10] = .{ .key = .{ .string = "log10" }, .value = try makeNative(.math_log10, 1) };
    math_items[11] = .{ .key = .{ .string = "pow"   }, .value = try makeNative(.math_pow,   2) };
    math_items[12] = .{ .key = .{ .string = "min"   }, .value = try makeNative(.math_min,   2) };
    math_items[13] = .{ .key = .{ .string = "max"   }, .value = try makeNative(.math_max,   2) };
    math_items[14] = .{ .key = .{ .string = "pi"    }, .value = .{ .number = std.math.pi } };
    math_items[15] = .{ .key = .{ .string = "e"     }, .value = .{ .number = std.math.e  } };
    math_items[16] = .{ .key = .{ .string = "inf"   }, .value = .{ .number = std.math.inf(f64) } };
    const math_obj = try vmgc.vmAllocObject();
    math_obj.* = .{ .map = math_items[0..17] };

    const str_items = heap.bump(MapEntry, 9) orelse return error.OutOfMemory;
    str_items[0] = .{ .key = .{ .string = "split" },       .value = try makeNative(.str_split,       2) };
    str_items[1] = .{ .key = .{ .string = "join" },        .value = try makeNative(.str_join,        2) };
    str_items[2] = .{ .key = .{ .string = "trim" },        .value = try makeNative(.str_trim,        1) };
    str_items[3] = .{ .key = .{ .string = "upper" },       .value = try makeNative(.str_upper,       1) };
    str_items[4] = .{ .key = .{ .string = "lower" },       .value = try makeNative(.str_lower,       1) };
    str_items[5] = .{ .key = .{ .string = "starts_with" }, .value = try makeNative(.str_starts_with, 2) };
    str_items[6] = .{ .key = .{ .string = "ends_with" },   .value = try makeNative(.str_ends_with,   2) };
    str_items[7] = .{ .key = .{ .string = "index_of" },    .value = try makeNative(.str_index_of,    2) };
    str_items[8] = .{ .key = .{ .string = "builder" },     .value = try makeNative(.str_builder_new, 0) };
    const str_obj = try vmgc.vmAllocObject();
    str_obj.* = .{ .map = str_items[0..9] };

    const std_items = heap.bump(MapEntry, 5) orelse return error.OutOfMemory;
    std_items[0] = .{
        .key = .{ .string = "io" },
        .value = .{ .object = io_obj },
    };
    std_items[1] = .{
        .key = .{ .string = "core" },
        .value = .{ .object = core_obj },
    };
    std_items[2] = .{
        .key = .{ .string = "conv" },
        .value = .{ .object = conv_obj },
    };
    std_items[3] = .{
        .key = .{ .string = "math" },
        .value = .{ .object = math_obj },
    };
    std_items[4] = .{
        .key = .{ .string = "string" },
        .value = .{ .object = str_obj },
    };

    const std_obj = try vmgc.vmAllocObject();
    std_obj.* = .{ .map = std_items[0..5] };
    vms.vmState().std_module = std_obj;
    return std_obj;
}

fn nativeLen(v: Value) !Value {
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

fn nativeByteLen(v: Value) !Value {
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

fn nativePrintf(start: usize, argc: u8) !void {
    if (argc < 1) return error.ArityMismatch;
    const fmt_v = vms.vmState().stack[start];
    const fmt = try vms.asStringValue(fmt_v);
    var ai: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            io.write(fmt[i .. i + 1]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) return error.TypeError;
        if (fmt[i] == '%') {
            io.write("%");
            i += 1;
            continue;
        }
        if (ai >= @as(usize, argc)) return error.ArityMismatch;
        const arg = vms.vmState().stack[start + ai];
        ai += 1;
        // Skip flags: -, +, space, 0, #
        while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '0' or fmt[i] == '#')) i += 1;
        // Skip width digits
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        // Optional .precision
        var precision: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            var prec: usize = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
                prec = prec * 10 + (fmt[i] - '0');
                i += 1;
            }
            precision = prec;
        }
        if (i >= fmt.len) return error.TypeError;
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            'v' => io.printValue(arg),
            's' => io.write(try vms.asStringValue(arg)),
            'd' => io.writeInt(try vms.valueAsInt(arg)),
            'f' => {
                const n = try vms.valueAsNumber(arg);
                if (precision) |prec| io.writeF64Prec(n, prec) else io.writeF64(n);
            },
            't' => {
                if (arg != .boolean) return error.TypeError;
                io.write(if (arg.boolean) "true" else "false");
            },
            else => return error.TypeError,
        }
    }
    if (ai != @as(usize, argc)) return error.ArityMismatch;
}

fn nativeDelete(m_obj: *Object, key: Value) !Value {
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

fn nativeHas(m_obj: *Object, key: Value) !Value {
    if (!vms.isMapObject(m_obj)) return error.TypeError;
    const items = vms.asMapSlice(m_obj);
    for (items) |entry| {
        if (vmmap.mapKeyEquals(entry.key, key)) return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn nativeKeys(m_obj: *Object) !Value {
    if (!vms.isMapObject(m_obj)) return error.TypeError;
    const items = vms.asMapSlice(m_obj);
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    if (items.len > 0) {
        const out = try vmgc.vmAllocManagedSlice(Value, items.len);
        for (items, 0..) |entry, i| out[i] = entry.key;
        obj.* = .{ .array_managed = out[0..items.len] };
    }
    return .{ .object = obj };
}

fn nativeValues(m_obj: *Object) !Value {
    if (!vms.isMapObject(m_obj)) return error.TypeError;
    const items = vms.asMapSlice(m_obj);
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    if (items.len > 0) {
        const out = try vmgc.vmAllocManagedSlice(Value, items.len);
        for (items, 0..) |entry, i| out[i] = entry.value;
        obj.* = .{ .array_managed = out[0..items.len] };
    }
    return .{ .object = obj };
}

fn nativeContains(arr_obj: *Object, needle: Value) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = vms.asArraySlice(arr_obj);
    for (items) |v| {
        if (Value.equals(v, needle)) return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn nativeRemove(arr_obj: *Object, idx_val: Value) !Value {
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

fn nativeStrSplit(s: []const u8, sep: []const u8) !Value {
    var count: usize = undefined;
    if (sep.len == 0) {
        count = try vmstr.utf8RuneCount(s);
    } else {
        count = 1;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
            count += 1;
            i = pos + sep.len;
        }
    }
    const arr_obj = try vmgc.vmAllocObject();
    arr_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = arr_obj });
    defer vms.popTempRoot();
    if (count > 0) {
        const pieces = try vmgc.vmAllocManagedSlice(Value, count);
        if (sep.len == 0) {
            var i: usize = 0;
            var pi: usize = 0;
            while (i < s.len) {
                const w = try vmstr.utf8NextRuneByteLen(s, i);
                pieces[pi] = .{ .string = s[i .. i + w] };
                i += w;
                pi += 1;
            }
        } else {
            var i: usize = 0;
            var pi: usize = 0;
            while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
                pieces[pi] = .{ .string = s[i..pos] };
                pi += 1;
                i = pos + sep.len;
            }
            pieces[pi] = .{ .string = s[i..] };
        }
        arr_obj.* = .{ .array_managed = pieces[0..count] };
    }
    return .{ .object = arr_obj };
}

fn nativeStrJoin(arr_obj: *Object, sep: []const u8) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = vms.asArraySlice(arr_obj);
    if (items.len == 0) return vmgc.makeDynString("");
    var total: usize = sep.len * (items.len - 1);
    for (items) |v| total += (try vms.asStringValue(v)).len;
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);
    var pos: usize = 0;
    for (items, 0..) |v, idx| {
        const piece = try vms.asStringValue(v);
        @memcpy(buf[pos .. pos + piece.len], piece);
        pos += piece.len;
        if (idx + 1 < items.len) {
            @memcpy(buf[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
    }
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

fn nativeStrTrim(s: []const u8) !Value {
    return vmgc.makeDynString(std.mem.trim(u8, s, " \t\n\r"));
}

fn nativeStrUpper(s: []const u8) !Value {
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(s.len);
    for (s, 0..) |b, i| buf[i] = std.ascii.toUpper(b);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
}

fn nativeStrLower(s: []const u8) !Value {
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(s.len);
    for (s, 0..) |b, i| buf[i] = std.ascii.toLower(b);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
}

fn nativeStrStartsWith(s: []const u8, prefix: []const u8) Value {
    return .{ .boolean = std.mem.startsWith(u8, s, prefix) };
}

fn nativeStrEndsWith(s: []const u8, suffix: []const u8) Value {
    return .{ .boolean = std.mem.endsWith(u8, s, suffix) };
}

fn nativeStrIndexOf(s: []const u8, sub: []const u8) !Value {
    const byte_idx = std.mem.indexOf(u8, s, sub) orelse return .{ .number = -1.0 };
    const rune_idx = try vmstr.utf8RuneCount(s[0..byte_idx]);
    return .{ .number = @floatFromInt(rune_idx) };
}

fn nativeAppend(start: usize, argc: u8) !Value {
    if (argc < 1) return error.ArityMismatch;
    const first = vms.vmState().stack[start];
    // Unbox named array types and check element constraints
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

fn nativeGcStats() !Value {
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const items = heap.bump(MapEntry, 3) orelse return error.OutOfMemory;
    items[0] = .{
        .key = .{ .string = "heap_used_bytes" },
        .value = .{ .number = @floatFromInt(heap.usedBytes()) },
    };
    items[1] = .{
        .key = .{ .string = "heap_size_bytes" },
        .value = .{ .number = @floatFromInt(heap.HeapSize) },
    };
    items[2] = .{
        .key = .{ .string = "live_objects" },
        .value = .{ .number = @floatFromInt(heap.liveObjectCount()) },
    };
    obj.* = .{ .map = items[0..3] };
    return .{ .object = obj };
}

fn nativeGcStatsExt() !Value {
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const items = heap.bump(MapEntry, 8) orelse return error.OutOfMemory;
    items[0] = .{
        .key = .{ .string = "heap_used_bytes" },
        .value = .{ .number = @floatFromInt(heap.usedBytes()) },
    };
    items[1] = .{
        .key = .{ .string = "heap_size_bytes" },
        .value = .{ .number = @floatFromInt(heap.HeapSize) },
    };
    items[2] = .{
        .key = .{ .string = "live_objects" },
        .value = .{ .number = @floatFromInt(heap.liveObjectCount()) },
    };
    items[3] = .{
        .key = .{ .string = "gc_runs" },
        .value = .{ .number = @floatFromInt(vms.vmState().gc_runs) },
    };
    items[4] = .{
        .key = .{ .string = "gc_time_ns" },
        .value = .{ .number = @floatFromInt(vms.vmState().gc_time_ns) },
    };
    items[5] = .{
        .key = .{ .string = "alloc_object_calls" },
        .value = .{ .number = @floatFromInt(vms.vmState().alloc_object_calls) },
    };
    items[6] = .{
        .key = .{ .string = "alloc_managed_slice_calls" },
        .value = .{ .number = @floatFromInt(vms.vmState().alloc_managed_slice_calls) },
    };
    items[7] = .{
        .key = .{ .string = "alloc_managed_bytes_calls" },
        .value = .{ .number = @floatFromInt(vms.vmState().alloc_managed_bytes_calls) },
    };
    obj.* = .{ .map = items[0..8] };
    return .{ .object = obj };
}

pub fn nativeConvToInt(v: Value) !Value {
    switch (v) {
        .number => |n| {
            const tr = @trunc(n);
            return .{ .number = tr };
        },
        .rune => |r| return .{ .number = @floatFromInt(r) },
        .boolean => |b| return .{ .number = if (b) 1 else 0 },
        .string => |s| {
            const n = common.parseFloat(s) orelse return error.TypeError;
            const tr = @trunc(n);
            return .{ .number = tr };
        },
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
        .string => |s| {
            const n = common.parseFloat(s) orelse return error.TypeError;
            return .{ .number = n };
        },
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
    switch (v) {
        .boolean => |b| return .{ .boolean = b },
        .number => |n| return .{ .boolean = n != 0.0 },
        .rune => |r| return .{ .boolean = r != 0 },
        .string => |s| return .{ .boolean = s.len != 0 },
        .error_value => |e| return .{ .boolean = e.len != 0 },
        .null => return .{ .boolean = false },
        .object => return .{ .boolean = true },
    }
}

pub fn nativeConvToString(v: Value) !Value {
    switch (v) {
        .string => |s| return vmgc.makeDynString(s),
        .object => |o| {
            if (o.* == .dyn_string) return vmgc.makeDynString(o.dyn_string);
            return error.TypeError;
        },
        .boolean => |b| return vmgc.makeDynString(if (b) "true" else "false"),
        .number => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .rune => |r| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(r, buf[0..]) catch return error.TypeError;
            return vmgc.makeDynString(buf[0..n]);
        },
        .null => return vmgc.makeDynString("null"),
        .error_value => |e| return vmgc.makeDynString(e),
    }
}

// ── Host ABI bridge ───────────────────────────────────────────────────────────

fn wireFromValue(v: Value) !host_abi.ValueWire {
    return switch (v) {
        .null => .{
            .tag = @intFromEnum(host_abi.WireTag.null),
            .flags = 0,
            .reserved = 0,
            .payload = 0,
            .len = 0,
            .reserved2 = 0,
        },
        .boolean => |b| .{
            .tag = @intFromEnum(host_abi.WireTag.boolean),
            .flags = 0,
            .reserved = 0,
            .payload = if (b) 1 else 0,
            .len = 0,
            .reserved2 = 0,
        },
        .number => |n| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = 0,
            .reserved = 0,
            .payload = @bitCast(n),
            .len = 0,
            .reserved2 = 0,
        },
        .rune => |r| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = 0,
            .reserved = 0,
            .payload = @bitCast(@as(f64, @floatFromInt(r))),
            .len = 0,
            .reserved2 = 0,
        },
        .string => |s| .{
            .tag = @intFromEnum(host_abi.WireTag.string),
            .flags = 0,
            .reserved = 0,
            .payload = @intFromPtr(s.ptr),
            .len = @intCast(s.len),
            .reserved2 = 0,
        },
        .object => |o| if (o.* == .dyn_string) .{
            .tag = @intFromEnum(host_abi.WireTag.string),
            .flags = 0,
            .reserved = 0,
            .payload = @intFromPtr(o.dyn_string.ptr),
            .len = @intCast(o.dyn_string.len),
            .reserved2 = 0,
        } else return error.UnsupportedHostValueType,
        else => return error.UnsupportedHostValueType,
    };
}

fn valueFromWire(w: host_abi.ValueWire) !Value {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    return switch (tag) {
        .null => .null,
        .boolean => .{ .boolean = w.payload != 0 },
        .number => .{ .number = @bitCast(w.payload) },
        .string => return error.UnsupportedHostReturnType,
    };
}

fn wireNumberToU64(w: host_abi.ValueWire) !u64 {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    if (tag != .number) return error.HostNativeBadReturnType;
    const n: f64 = @bitCast(w.payload);
    if (n < 0) return error.HostNativeBadReturnValue;
    const tr = @trunc(n);
    if (tr != n) return error.HostNativeBadReturnValue;
    return @intFromFloat(tr);
}

fn ensureHostReady() !void {
    if (vms.vmState().policy.native_backend != .host) return;
    if (vms.vmState().host_checked) return;

    var out: host_abi.ValueWire = .{
        .tag = @intFromEnum(host_abi.WireTag.null),
        .flags = 0,
        .reserved = 0,
        .payload = 0,
        .len = 0,
        .reserved2 = 0,
    };

    var empty: [0]host_abi.ValueWire = .{};
    const st_ver = host_abi.nativeCall(.abi_version, empty[0..], &out);
    switch (st_ver) {
        .ok => {},
        .unsupported => {
            vms.vmState().host_caps = 0;
            vms.vmState().host_checked = true;
            return;
        },
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
    const version = try wireNumberToU64(out);
    if (version != host_abi.ABI_VERSION) return error.HostAbiVersionMismatch;

    const st_caps = host_abi.nativeCall(.host_caps, empty[0..], &out);
    switch (st_caps) {
        .ok => {},
        .unsupported => return error.HostNativeUnsupported,
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
    vms.vmState().host_caps = try wireNumberToU64(out);
    vms.vmState().host_checked = true;
}

// ── Native function dispatch ──────────────────────────────────────────────────

const vmperf = @import("vm_perf.zig");

pub fn callNative(nf: NativeFuncObj, argc: u8) !void {
    vmperf.countHostcall(nf.id);
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .io_println => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            if (vms.vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_IO_PRINTLN) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    const start = vms.vmState().stack_top - argc;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try wireFromValue(vms.vmState().stack[start + i]);
                    }
                    var out: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.io_println, args_wire[0..argc], &out);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    var j: usize = 0;
                    while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(.null);
                    return;
                }
            }
            const start = vms.vmState().stack_top - argc;
            var i: usize = 0;
            while (i < @as(usize, argc)) : (i += 1) io.printValue(vms.vmState().stack[start + i]);
            io.write("\n");
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .io_print => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            var i: usize = 0;
            while (i < @as(usize, argc)) : (i += 1) io.printValue(vms.vmState().stack[start + i]);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .io_printf => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            try nativePrintf(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .core_len => {
            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CORE_LEN) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try wireFromValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
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
                    const out = try valueFromWire(out_wire);
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
        .core_append => {
            const start = vms.vmState().stack_top - argc;
            if (vms.vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CORE_APPEND) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try wireFromValue(vms.vmState().stack[start + i]);
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
                    const out = try valueFromWire(out_wire);
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
        .core_is_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = arg == .error_value });
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
        .core_keys => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (m_val != .object) return error.TypeError;
            const out = try nativeKeys(m_val.object);
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
        .core_bytelen => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeByteLen(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_int => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeConvToInt(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeConvToFloat(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_bool => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeConvToBool(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_string => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeConvToString(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .math_abs => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @abs(n) });
        },
        .math_sqrt => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @sqrt(n) });
        },
        .math_floor => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @floor(n) });
        },
        .math_ceil => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @ceil(n) });
        },
        .math_round => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @round(n) });
        },
        .math_sin => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @sin(n) });
        },
        .math_cos => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @cos(n) });
        },
        .math_tan => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.tan(n) });
        },
        .math_log => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @log(n) });
        },
        .math_log2 => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @log2(n) });
        },
        .math_log10 => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @log10(n) });
        },
        .math_pow => {
            if (argc != nf.arity) return error.ArityMismatch;
            const b = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const a = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.pow(f64, a, b) });
        },
        .math_min => {
            if (argc != nf.arity) return error.ArityMismatch;
            const b = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const a = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @min(a, b) });
        },
        .math_max => {
            if (argc != nf.arity) return error.ArityMismatch;
            const b = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const a = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @max(a, b) });
        },
        .str_split => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrSplit(s, sep);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_join => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const arr_val = vms.vmState().stack[top - 2];
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            if (arr_val != .object) return error.TypeError;
            const out = try nativeStrJoin(arr_val.object, sep);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_trim => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try nativeStrTrim(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_upper => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try nativeStrUpper(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_lower => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try nativeStrLower(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_starts_with => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const prefix = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(nativeStrStartsWith(s, prefix));
        },
        .str_ends_with => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const suffix = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(nativeStrEndsWith(s, suffix));
        },
        .str_index_of => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrIndexOf(s, sub);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_builder_new => {
            if (argc != 0) return error.ArityMismatch;
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .string_builder = .{ .buf = &[_]u8{}, .len = 0 } };
            _ = try vms.vmPop();
            try vms.vmPush(.{ .object = obj });
        },
    }
}
