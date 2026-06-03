const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const host_abi = @import("../runtime/host_abi.zig");
const io = @import("../runtime/io.zig");
const globals = @import("globals.zig");
const module_compile = @import("module_compile.zig");
const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const vmmap = @import("vm_map.zig");
const vmtyp = @import("vm_types.zig");
const vmstr = @import("vm_string.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;
const NativeFuncObj = @import("value.zig").NativeFuncObj;
const FieldTypeAlt = @import("value.zig").FieldTypeAlt;
const FieldTypeSpec = @import("value.zig").FieldTypeSpec;
const StructFieldSpec = @import("value.zig").StructFieldSpec;
const StructTypeObj = @import("value.zig").StructTypeObj;

const TemplateTypeQualifiedName = "@std.template.obj";

const TplOp = enum(u8) {
    text = 0,
    field = 1,
    chain = 2,
    var_ref = 3,
    root_ref = 4,
    call_fn = 5,
    if_begin = 6,
    if_else = 7,
    end = 8,
    range_begin = 9,
    range_else = 10,
    with_begin = 11,
    break_inst = 12,
    continue_inst = 13,
    assign = 14,
};

const TplCtrl = enum(u8) { if_block, range_block, with_block };

const TplCtrlEntry = struct {
    kind: TplCtrl,
    if_idx: usize,
    else_idx: usize,
};

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
    core_type_of = 47,
    core_is_int = 48,
    core_is_float = 49,
    core_is_string = 50,
    core_is_array = 51,
    core_is_map = 52,
    core_is_struct = 53,
    core_is_null = 54,
    core_deep_equal = 55,
    core_clone = 56,
    str_split = 36,
    str_join = 37,
    str_trim = 38,
    str_upper = 39,
    str_lower = 40,
    str_starts_with = 41,
    str_ends_with = 42,
    str_index_of = 43,
    str_replace = 57,
    str_last_index_of = 58,
    str_repeat = 59,
    str_split_once = 60,
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
    rand_float = 61,
    rand_intn = 62,
    rand_between = 63,
    rand_seed = 64,
    rand_choice = 65,
    json_parse = 66,
    json_stringify = 67,
    json_valid = 68,
    template_parse = 69,
    template_execute = 70,
    template_add_func = 71,
    template_render = 72,
    template_valid = 73,
};
const MaxNativeArgs = 255;
const NamespaceEntry = struct {
    name: []const u8,
    value: Value,
};

fn makeNative(id: NativeFnId, arity: u8) !Value {
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .native_function = .{ .id = @intFromEnum(id), .arity = arity } };
    return .{ .object = obj };
}

fn makeNamespace(display_name: []const u8, qualified_name: []const u8, entries: []const NamespaceEntry) !*Object {
    const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
    any_alts[0] = .{ .typ = .any };
    const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

    const field_specs = heap.bump(StructFieldSpec, entries.len) orelse return error.OutOfMemory;
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        field_specs[i] = .{ .name = entries[i].name, .typ = any_spec, .is_const = true };
    }

    const typ_obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = typ_obj });
    defer vms.popTempRoot();
    typ_obj.* = .{ .struct_type = StructTypeObj{
        .name = display_name,
        .qualified_name = qualified_name,
        .fields = field_specs[0..entries.len],
    } };

    const inst_fields = try vmgc.vmAllocManagedSlice(MapEntry, entries.len);
    const inst_obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = inst_obj });
    defer vms.popTempRoot();
    inst_obj.* = .{ .struct_instance = .{ .typ = typ_obj, .fields = inst_fields } };

    i = 0;
    while (i < entries.len) : (i += 1) {
        inst_fields[i] = .{
            .key = .{ .string = entries[i].name },
            .value = entries[i].value,
        };
    }
    return inst_obj;
}

var g_prng: std.Random.DefaultPrng = undefined;
var g_prng_ready: bool = false;

fn randRng() std.Random {
    if (!g_prng_ready) {
        var seed: u64 = undefined;
        const seed_bytes = std.mem.asBytes(&seed);
        if (comptime builtin.os.tag == .wasi) {
            _ = std.os.wasi.random_get(seed_bytes.ptr, seed_bytes.len);
        } else if (comptime builtin.os.tag == .linux) {
            _ = std.os.linux.getrandom(seed_bytes.ptr, seed_bytes.len, 0);
        } else {
            seed = @intFromPtr(&g_prng) ^ 0xdeadbeef_cafebabe;
        }
        g_prng = std.Random.DefaultPrng.init(seed);
        g_prng_ready = true;
    }
    return g_prng.random();
}

fn nativeRandFloat() Value {
    return .{ .number = randRng().float(f64) };
}

fn nativeRandIntn(n_val: Value) !Value {
    const n = try vms.valueAsInt(n_val);
    if (n <= 0) return error.RangeError;
    return .{ .number = @floatFromInt(randRng().intRangeLessThan(i64, 0, n)) };
}

fn nativeRandBetween(lo_val: Value, hi_val: Value) !Value {
    const lo = try vms.valueAsInt(lo_val);
    const hi = try vms.valueAsInt(hi_val);
    if (lo > hi) return error.RangeError;
    return .{ .number = @floatFromInt(randRng().intRangeAtMost(i64, lo, hi)) };
}

fn nativeRandSeed(n_val: Value) !void {
    const n = try vms.valueAsInt(n_val);
    const seed: u64 = @bitCast(n);
    g_prng = std.Random.DefaultPrng.init(seed);
    g_prng_ready = true;
}

fn nativeRandChoice(arr_obj: *Object) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = vms.asArraySlice(arr_obj);
    if (items.len == 0) return error.RangeError;
    const idx = randRng().intRangeLessThan(usize, 0, items.len);
    return items[idx];
}

pub fn buildStdModule() !*Object {
    if (vms.vmState().std_module) |m| return m;

    const io_entries = [_]NamespaceEntry{
        .{ .name = "println", .value = try makeNative(.io_println, 255) },
        .{ .name = "printf", .value = try makeNative(.io_printf, 255) },
        .{ .name = "print", .value = try makeNative(.io_print, 255) },
    };
    const io_obj = try makeNamespace("io", "@module_type:std.io", &io_entries);
    try vms.pushTempRoot(.{ .object = io_obj });
    defer vms.popTempRoot();

    const core_entries = [_]NamespaceEntry{
        .{ .name = "len", .value = try makeNative(.core_len, 1) },
        .{ .name = "append", .value = try makeNative(.core_append, 255) },
        .{ .name = "error", .value = try makeNative(.core_error, 1) },
        .{ .name = "is_error", .value = try makeNative(.core_is_error, 1) },
        .{ .name = "type_of", .value = try makeNative(.core_type_of, 1) },
        .{ .name = "is_int", .value = try makeNative(.core_is_int, 1) },
        .{ .name = "is_float", .value = try makeNative(.core_is_float, 1) },
        .{ .name = "is_string", .value = try makeNative(.core_is_string, 1) },
        .{ .name = "is_array", .value = try makeNative(.core_is_array, 1) },
        .{ .name = "is_map", .value = try makeNative(.core_is_map, 1) },
        .{ .name = "is_struct", .value = try makeNative(.core_is_struct, 1) },
        .{ .name = "is_null", .value = try makeNative(.core_is_null, 1) },
        .{ .name = "deep_equal", .value = try makeNative(.core_deep_equal, 2) },
        .{ .name = "clone", .value = try makeNative(.core_clone, 1) },
        .{ .name = "gc", .value = try makeNative(.core_gc, 0) },
        .{ .name = "gc_live_objects", .value = try makeNative(.core_gc_live_objects, 0) },
        .{ .name = "gc_stats", .value = try makeNative(.core_gc_stats, 0) },
        .{ .name = "bytelen", .value = try makeNative(.core_bytelen, 1) },
        .{ .name = "gc_stats_ext", .value = try makeNative(.core_gc_stats_ext, 0) },
        .{ .name = "delete", .value = try makeNative(.core_delete, 2) },
        .{ .name = "has", .value = try makeNative(.core_has, 2) },
        .{ .name = "keys", .value = try makeNative(.core_keys, 1) },
        .{ .name = "values", .value = try makeNative(.core_values, 1) },
        .{ .name = "contains", .value = try makeNative(.core_contains, 2) },
        .{ .name = "remove", .value = try makeNative(.core_remove, 2) },
        .{ .name = "recover", .value = try makeNative(.core_recover, 0) },
    };
    const core_obj = try makeNamespace("core", "@module_type:std.core", &core_entries);
    try vms.pushTempRoot(.{ .object = core_obj });
    defer vms.popTempRoot();

    const conv_entries = [_]NamespaceEntry{
        .{ .name = "to_int", .value = try makeNative(.conv_to_int, 1) },
        .{ .name = "to_float", .value = try makeNative(.conv_to_float, 1) },
        .{ .name = "to_bool", .value = try makeNative(.conv_to_bool, 1) },
        .{ .name = "to_string", .value = try makeNative(.conv_to_string, 1) },
    };
    const conv_obj = try makeNamespace("conv", "@module_type:std.conv", &conv_entries);
    try vms.pushTempRoot(.{ .object = conv_obj });
    defer vms.popTempRoot();

    const math_entries = [_]NamespaceEntry{
        .{ .name = "abs", .value = try makeNative(.math_abs, 1) },
        .{ .name = "sqrt", .value = try makeNative(.math_sqrt, 1) },
        .{ .name = "floor", .value = try makeNative(.math_floor, 1) },
        .{ .name = "ceil", .value = try makeNative(.math_ceil, 1) },
        .{ .name = "round", .value = try makeNative(.math_round, 1) },
        .{ .name = "sin", .value = try makeNative(.math_sin, 1) },
        .{ .name = "cos", .value = try makeNative(.math_cos, 1) },
        .{ .name = "tan", .value = try makeNative(.math_tan, 1) },
        .{ .name = "log", .value = try makeNative(.math_log, 1) },
        .{ .name = "log2", .value = try makeNative(.math_log2, 1) },
        .{ .name = "log10", .value = try makeNative(.math_log10, 1) },
        .{ .name = "pow", .value = try makeNative(.math_pow, 2) },
        .{ .name = "min", .value = try makeNative(.math_min, 2) },
        .{ .name = "max", .value = try makeNative(.math_max, 2) },
        .{ .name = "pi", .value = .{ .number = std.math.pi } },
        .{ .name = "e", .value = .{ .number = std.math.e } },
        .{ .name = "inf", .value = .{ .number = std.math.inf(f64) } },
    };
    const math_obj = try makeNamespace("math", "@module_type:std.math", &math_entries);
    try vms.pushTempRoot(.{ .object = math_obj });
    defer vms.popTempRoot();

    const rand_entries = [_]NamespaceEntry{
        .{ .name = "float", .value = try makeNative(.rand_float, 0) },
        .{ .name = "intn", .value = try makeNative(.rand_intn, 1) },
        .{ .name = "between", .value = try makeNative(.rand_between, 2) },
        .{ .name = "seed", .value = try makeNative(.rand_seed, 1) },
        .{ .name = "choice", .value = try makeNative(.rand_choice, 1) },
    };
    const rand_obj = try makeNamespace("rand", "@module_type:std.rand", &rand_entries);
    try vms.pushTempRoot(.{ .object = rand_obj });
    defer vms.popTempRoot();

    const string_entries = [_]NamespaceEntry{
        .{ .name = "split", .value = try makeNative(.str_split, 2) },
        .{ .name = "join", .value = try makeNative(.str_join, 2) },
        .{ .name = "trim", .value = try makeNative(.str_trim, 1) },
        .{ .name = "upper", .value = try makeNative(.str_upper, 1) },
        .{ .name = "lower", .value = try makeNative(.str_lower, 1) },
        .{ .name = "starts_with", .value = try makeNative(.str_starts_with, 2) },
        .{ .name = "ends_with", .value = try makeNative(.str_ends_with, 2) },
        .{ .name = "index_of", .value = try makeNative(.str_index_of, 2) },
        .{ .name = "replace", .value = try makeNative(.str_replace, 3) },
        .{ .name = "last_index_of", .value = try makeNative(.str_last_index_of, 2) },
        .{ .name = "repeat", .value = try makeNative(.str_repeat, 2) },
        .{ .name = "split_once", .value = try makeNative(.str_split_once, 2) },
        .{ .name = "builder", .value = try makeNative(.str_builder_new, 0) },
    };
    const string_obj = try makeNamespace("string", "@module_type:std.string", &string_entries);
    try vms.pushTempRoot(.{ .object = string_obj });
    defer vms.popTempRoot();

    const json_entries = [_]NamespaceEntry{
        .{ .name = "parse", .value = try makeNative(.json_parse, 1) },
        .{ .name = "stringify", .value = try makeNative(.json_stringify, 1) },
        .{ .name = "valid", .value = try makeNative(.json_valid, 1) },
    };
    const json_obj = try makeNamespace("json", "@module_type:std.json", &json_entries);
    try vms.pushTempRoot(.{ .object = json_obj });
    defer vms.popTempRoot();

    const template_entries = [_]NamespaceEntry{
        .{ .name = "parse", .value = try makeNative(.template_parse, 1) },
        .{ .name = "execute", .value = try makeNative(.template_execute, 2) },
        .{ .name = "add_func", .value = try makeNative(.template_add_func, 3) },
        .{ .name = "render", .value = try makeNative(.template_render, 2) },
        .{ .name = "valid", .value = try makeNative(.template_valid, 1) },
    };
    const template_obj = try makeNamespace("template", "@module_type:std.template", &template_entries);
    try vms.pushTempRoot(.{ .object = template_obj });
    defer vms.popTempRoot();

    const std_entries = [_]NamespaceEntry{
        .{ .name = "io", .value = .{ .object = io_obj } },
        .{ .name = "core", .value = .{ .object = core_obj } },
        .{ .name = "conv", .value = .{ .object = conv_obj } },
        .{ .name = "math", .value = .{ .object = math_obj } },
        .{ .name = "rand", .value = .{ .object = rand_obj } },
        .{ .name = "string", .value = .{ .object = string_obj } },
        .{ .name = "json", .value = .{ .object = json_obj } },
        .{ .name = "template", .value = .{ .object = template_obj } },
    };
    const std_obj = try makeNamespace("std", "@module_type:std", &std_entries);
    vms.vmState().std_module = std_obj;
    return std_obj;
}

pub fn installStdGlobal() !void {
    if (globals.has(module_compile.StdModuleGlobalName)) return;
    const std_obj = try buildStdModule();
    try globals.def(module_compile.StdModuleGlobalName, .{ .object = std_obj });
    {
        const exec_buf = (heap.bump(u8, 64) orelse return)[0..64];
        const exec_key = std.fmt.bufPrint(exec_buf, "{s}.{s}", .{ TemplateTypeQualifiedName, "execute" }) catch return;
        if (!globals.has(exec_key)) {
            const exec_native = try makeNative(.template_execute, 2);
            try globals.def(exec_key, exec_native);
        }
        const af_buf = (heap.bump(u8, 64) orelse return)[0..64];
        const af_key = std.fmt.bufPrint(af_buf, "{s}.{s}", .{ TemplateTypeQualifiedName, "add_func" }) catch return;
        if (!globals.has(af_key)) {
            const af_native = try makeNative(.template_add_func, 3);
            try globals.def(af_key, af_native);
        }
    }
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
    obj.* = .{ .dyn_string = &[_]u8{} }; // safe tag before GC can run
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
    obj.* = .{ .dyn_string = &[_]u8{} }; // safe tag before GC can run
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(s.len);
    for (s, 0..) |b, i| buf[i] = std.ascii.toUpper(b);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
}

fn nativeStrLower(s: []const u8) !Value {
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} }; // safe tag before GC can run
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

const MaxDeepVisits = 1024;

const DeepEqVisit = struct {
    a: *Object,
    b: *Object,
};

const CloneVisit = struct {
    src: *Object,
    dst: *Object,
};

fn makeTuple2(a: Value, b: Value) !Value {
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

fn isIntegralNumber(n: f64) bool {
    return @trunc(n) == n;
}

fn rootNamedType(typ_obj: *Object) *Object {
    var cur = typ_obj;
    while (vmtyp.resolveParentType(cur)) |parent| cur = parent;
    return cur;
}

fn isNamedBase(v: Value, base: @import("value.zig").NamedTypeBase) bool {
    if (!(v == .object and v.object.* == .named_value)) return false;
    return rootNamedType(v.object.named_value.typ).named_type.base == base;
}

fn nativeTypeNameValue(v: Value) Value {
    return switch (v) {
        .number => |n| .{ .string = if (isIntegralNumber(n)) "int" else "float" },
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

fn nativeIsInt(v: Value) Value {
    return .{ .boolean = switch (v) {
        .number => |n| isIntegralNumber(n),
        .object => isNamedBase(v, .int),
        else => false,
    } };
}

fn nativeIsFloat(v: Value) Value {
    return .{ .boolean = switch (v) {
        .number => |n| !isIntegralNumber(n),
        .object => isNamedBase(v, .float),
        else => false,
    } };
}

fn nativeIsString(v: Value) Value {
    return .{ .boolean = vms.isStringValue(v) or isNamedBase(v, .string) };
}

fn nativeIsArray(v: Value) Value {
    return .{ .boolean = (v == .object and vms.isArrayObject(v.object)) or isNamedBase(v, .array_t) };
}

fn nativeIsMap(v: Value) Value {
    return .{ .boolean = (v == .object and vms.isMapObject(v.object)) or isNamedBase(v, .map_t) };
}

fn nativeIsStruct(v: Value) Value {
    return .{ .boolean = v == .object and v.object.* == .struct_instance };
}

fn nativeIsNull(v: Value) Value {
    return .{ .boolean = v == .null };
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
            // handled below
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
            for (aa, 0..) |item, i| {
                if (!try deepEqualValue(item, bb[i], visits, visit_len)) return false;
            }
            return true;
        },
        .map, .map_managed, .map_hashed => {
            try appendVisitedPair(a, b, visits, visit_len);
            return deepEqualMap(vms.asMapSlice(a), vms.asMapSlice(b), visits, visit_len);
        },
        .dyn_string => return common.streq(a.dyn_string, b.dyn_string),
        .function, .closure, .iterator => return a == b,
        .cell => return try deepEqualValue(a.cell.value, b.cell.value, visits, visit_len),
        .native_function => |anf| {
            const bnf = b.native_function;
            return anf.id == bnf.id and anf.arity == bnf.arity;
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
        .named_type_fn => |anf| {
            const bnf = b.named_type_fn;
            return anf.typ == bnf.typ and anf.kind == bnf.kind;
        },
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
        .rune => |x| x == b.rune,
        .boolean => |x| x == b.boolean,
        .string => |x| common.streq(x, b.string),
        .error_value => |x| common.streq(x, b.error_value),
        .null => true,
        .object => unreachable,
    };
}

fn nativeDeepEqual(a: Value, b: Value) !Value {
    var visits: [MaxDeepVisits]DeepEqVisit = undefined;
    var visit_len: usize = 0;
    return .{ .boolean = try deepEqualValue(a, b, visits[0..], &visit_len) };
}

fn cloneFindExisting(src: *Object, visits: []const CloneVisit, visit_len: usize) ?*Object {
    var i: usize = 0;
    while (i < visit_len) : (i += 1) {
        if (visits[i].src == src) return visits[i].dst;
    }
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
        .function,
        .closure,
        .native_function,
        .struct_type,
        .interface_type,
        .named_type,
        .enum_type,
        .iterator,
        .variant_type,
        .variant_ctor,
        .named_type_fn,
        .string_builder,
        => return .{ .object = src },
        .cell => return .{ .object = src },
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
            out_obj.* = .{ .variant_value = .{
                .typ = vv.typ,
                .tag = vv.tag,
                .ordinal = vv.ordinal,
                .payload = try cloneValue(vv.payload, visits, visit_len),
            } };
            return .{ .object = out_obj };
        },
    }
}

fn nativeClone(v: Value) !Value {
    var visits: [MaxDeepVisits]CloneVisit = undefined;
    var visit_len: usize = 0;
    return cloneValue(v, visits[0..], &visit_len);
}

fn nativeStrReplace(s: []const u8, old: []const u8, new: []const u8) !Value {
    if (old.len == 0) return vmgc.makeDynString(s);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, old)) |pos| {
        count += 1;
        i = pos + old.len;
    }
    if (count == 0) return vmgc.makeDynString(s);
    const total = s.len + count * new.len - count * old.len;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);
    var src_i: usize = 0;
    var dst_i: usize = 0;
    while (std.mem.indexOfPos(u8, s, src_i, old)) |pos| {
        @memcpy(buf[dst_i .. dst_i + (pos - src_i)], s[src_i..pos]);
        dst_i += pos - src_i;
        @memcpy(buf[dst_i .. dst_i + new.len], new);
        dst_i += new.len;
        src_i = pos + old.len;
    }
    @memcpy(buf[dst_i .. dst_i + (s.len - src_i)], s[src_i..]);
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

fn nativeStrLastIndexOf(s: []const u8, sub: []const u8) !Value {
    const byte_idx = std.mem.lastIndexOf(u8, s, sub) orelse return .{ .number = -1.0 };
    const rune_idx = try vmstr.utf8RuneCount(s[0..byte_idx]);
    return .{ .number = @floatFromInt(rune_idx) };
}

fn nativeStrRepeat(s: []const u8, count_v: Value) !Value {
    const n = try vms.valueAsInt(count_v);
    if (n < 0) return error.RangeError;
    if (n == 0) return vmgc.makeDynString("");
    const count: usize = @intCast(n);
    const total = s.len * count;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);
    var pos: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(buf[pos .. pos + s.len], s);
        pos += s.len;
    }
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

fn nativeStrSplitOnce(s: []const u8, sep: []const u8) !Value {
    const pos = std.mem.indexOf(u8, s, sep) orelse return makeTuple2(.null, .null);
    return makeTuple2(.{ .string = s[0..pos] }, .{ .string = s[pos + sep.len ..] });
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

// ── Template engine helpers ───────────────────────────────────────────────────

fn tplIsStringVal(v: Value) bool {
    return v == .string or (v == .object and v.object.* == .dyn_string);
}

fn tplAsStringVal(v: Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .object => |o| if (o.* == .dyn_string) o.dyn_string else error.TypeError,
        else => error.TypeError,
    };
}

fn tplResolveField(data: Value, field: []const u8) !Value {
    if (data != .object) return .null;
    const obj = data.object;
    switch (obj.*) {
        .map, .map_managed, .map_hashed => {
            const items = tplAsMapSlice(obj);
            for (items) |entry| {
                if (tplIsStringVal(entry.key)) {
                    const k = try tplAsStringVal(entry.key);
                    if (std.mem.eql(u8, k, field)) return entry.value;
                }
            }
            return .null;
        },
        .struct_instance => {
            const fields = obj.struct_instance.fields;
            for (fields) |f| {
                if (f.key == .string and std.mem.eql(u8, f.key.string, field)) return f.value;
            }
            return .null;
        },
        else => return .null,
    }
}

fn tplFieldValue(obj: *Object, name: []const u8) Value {
    const fields = obj.struct_instance.fields;
    for (fields) |f| {
        if (f.key == .string and std.mem.eql(u8, f.key.string, name)) return f.value;
    }
    return .null;
}

fn tplIsArray(obj: *Object) bool {
    return obj.* == .array or obj.* == .array_managed;
}

fn tplAsArraySlice(obj: *Object) []Value {
    return switch (obj.*) {
        .array => |a| a,
        .array_managed => |a| a,
        else => &[_]Value{},
    };
}

fn tplAsMapSlice(obj: *Object) []MapEntry {
    return switch (obj.*) {
        .map => |m| m,
        .map_managed => |m| m,
        .map_hashed => |m| m.entries[0..m.len],
        else => &[_]MapEntry{},
    };
}

fn tplEvalExpr(arg: Value, dot: Value, _funcs_val: Value) !Value {
    _ = _funcs_val;
    if (arg == .null) return dot;
    if (arg == .string) {
        return try tplResolveField(dot, arg.string);
    }
    if (arg == .object and tplIsArray(arg.object)) {
        const items = tplAsArraySlice(arg.object);
        var cur = dot;
        for (items) |item| {
            const name = try tplAsStringVal(item);
            cur = try tplResolveField(cur, name);
        }
        return cur;
    }
    return .null;
}

fn tplValToDynStr(v: Value) !Value {
    return switch (v) {
        .null => vmgc.makeDynString("null"),
        .boolean => |b| vmgc.makeDynString(if (b) "true" else "false"),
        .number => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .string => |s| vmgc.makeDynString(s),
        .object => |o| {
            if (o.* == .dyn_string) return vmgc.makeDynString(o.dyn_string);
            return vmgc.makeDynString("?");
        },
        else => vmgc.makeDynString("?"),
    };
}

fn tplAppendToBuilder(sb_obj: *Object, s: []const u8) !void {
    if (s.len == 0) return;
    const needed = sb_obj.string_builder.len + s.len;
    if (needed > sb_obj.string_builder.buf.len) {
        const new_buf = try vmgc.vmAllocManagedBytes(needed);
        @memcpy(new_buf[0..sb_obj.string_builder.len], sb_obj.string_builder.buf[0..sb_obj.string_builder.len]);
        heap.freeBytesManaged(sb_obj.string_builder.buf);
        sb_obj.string_builder.buf = new_buf;
    }
    @memcpy(sb_obj.string_builder.buf[sb_obj.string_builder.len..needed], s);
    sb_obj.string_builder.len = needed;
}

fn tplBuilderToStr(sb_obj: *Object) !Value {
    return vmgc.makeDynString(sb_obj.string_builder.buf[0..sb_obj.string_builder.len]);
}

fn tplCountInsts(src: []const u8) !usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.indexOfPos(u8, src, i, "{{")) |start| {
            if (start > i) count += 1;
            const end = std.mem.indexOfPos(u8, src, start + 2, "}}") orelse return error.InvalidTemplate;
            count += 1;
            i = end + 2;
        } else {
            count += 1;
            break;
        }
    }
    return count;
}

fn tplSplitPath(s: []const u8, sep: []const u8) !Value {
    var count: usize = 1;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
        count += 1;
        i = pos + sep.len;
    }
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const arr = try vmgc.vmAllocManagedSlice(Value, count);
    var idx: usize = 0;
    i = 0;
    while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
        arr[idx] = .{ .string = s[i..pos] };
        idx += 1;
        i = pos + sep.len;
    }
    arr[idx] = .{ .string = s[i..] };
    obj.* = .{ .array_managed = arr[0..count] };
    return .{ .object = obj };
}

fn tplEncodeExpr(expr: []const u8) !Value {
    const trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return .null;
    if (std.mem.eql(u8, trimmed, ".")) return .null;
    if (trimmed[0] == '$') return .{ .string = trimmed[1..] };
    if (trimmed[0] == '.') {
        const path = trimmed[1..];
        if (std.mem.indexOf(u8, path, ".")) |_| {
            return try tplSplitPath(path, ".");
        }
        return .{ .string = path };
    }
    return .{ .string = trimmed };
}

fn tplParseTag(tag: []const u8) !struct { op: TplOp, arg: Value } {
    const trimmed = std.mem.trim(u8, tag, " \t\n\r");
    if (trimmed.len == 0) return error.InvalidTemplate;

    if (std.mem.eql(u8, trimmed, "end")) return .{ .op = .end, .arg = .null };
    if (std.mem.eql(u8, trimmed, "else")) return .{ .op = .if_else, .arg = .null };
    if (std.mem.eql(u8, trimmed, "break")) return .{ .op = .break_inst, .arg = .null };
    if (std.mem.eql(u8, trimmed, "continue")) return .{ .op = .continue_inst, .arg = .null };
    if (std.mem.eql(u8, trimmed, ".")) return .{ .op = .root_ref, .arg = .null };

    if (std.mem.startsWith(u8, trimmed, "if ")) {
        const expr = std.mem.trim(u8, trimmed[3..], " \t");
        return .{ .op = .if_begin, .arg = try tplEncodeExpr(expr) };
    }
    if (std.mem.startsWith(u8, trimmed, "range ")) {
        const expr = std.mem.trim(u8, trimmed[6..], " \t");
        return .{ .op = .range_begin, .arg = try tplEncodeExpr(expr) };
    }
    if (std.mem.startsWith(u8, trimmed, "with ")) {
        const expr = std.mem.trim(u8, trimmed[5..], " \t");
        return .{ .op = .with_begin, .arg = try tplEncodeExpr(expr) };
    }
    if (trimmed.len >= 2 and trimmed[0] == '$') {
        if (std.mem.indexOf(u8, trimmed, ":=")) |pos| {
            const vname = std.mem.trim(u8, trimmed[1..pos], " \t");
            return .{ .op = .assign, .arg = .{ .string = vname } };
        }
        const vname = trimmed[1..];
        return .{ .op = .var_ref, .arg = .{ .string = vname } };
    }
    if (trimmed[0] == '.') {
        const path = trimmed[1..];
        if (std.mem.indexOf(u8, path, ".")) |_| {
            return .{ .op = .chain, .arg = try tplSplitPath(path, ".") };
        }
        return .{ .op = .field, .arg = .{ .string = path } };
    }
    const space_pos = std.mem.indexOfAny(u8, trimmed, " \t");
    if (space_pos) |pos| {
        const fname = trimmed[0..pos];
        return .{ .op = .call_fn, .arg = .{ .string = fname } };
    }

    return error.InvalidTemplate;
}

fn tplBuildObj(src_val: Value, ops: []Value, args: []Value, jmp: []Value) !*Object {
    const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
    any_alts[0] = .{ .typ = .any };
    const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

    const field_specs = heap.bump(StructFieldSpec, 5) orelse return error.OutOfMemory;
    field_specs[0] = .{ .name = "__ops", .typ = any_spec, .is_const = true };
    field_specs[1] = .{ .name = "__args", .typ = any_spec, .is_const = true };
    field_specs[2] = .{ .name = "__jmp", .typ = any_spec, .is_const = true };
    field_specs[3] = .{ .name = "__src", .typ = any_spec, .is_const = true };
    field_specs[4] = .{ .name = "funcs", .typ = any_spec, .is_const = false };

    const typ_obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = typ_obj });
    defer vms.popTempRoot();
    typ_obj.* = .{ .struct_type = StructTypeObj{
        .name = "Template",
        .qualified_name = TemplateTypeQualifiedName,
        .fields = field_specs[0..5],
    } };

    const inst_fields = try vmgc.vmAllocManagedSlice(MapEntry, 5);
    const inst_obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = inst_obj });
    defer vms.popTempRoot();
    inst_obj.* = .{ .struct_instance = .{ .typ = typ_obj, .fields = inst_fields } };

    const ops_obj = try vmgc.vmAllocObject();
    ops_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = ops_obj });
    defer vms.popTempRoot();
    ops_obj.* = .{ .array_managed = ops };

    const args_obj = try vmgc.vmAllocObject();
    args_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = args_obj });
    defer vms.popTempRoot();
    args_obj.* = .{ .array_managed = args };

    const jmp_obj = try vmgc.vmAllocObject();
    jmp_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = jmp_obj });
    defer vms.popTempRoot();
    jmp_obj.* = .{ .array_managed = jmp };

    const funcs_obj = try vmgc.vmAllocObject();
    funcs_obj.* = .{ .map = &[_]MapEntry{} };

    inst_fields[0] = .{ .key = .{ .string = "__ops" }, .value = .{ .object = ops_obj } };
    inst_fields[1] = .{ .key = .{ .string = "__args" }, .value = .{ .object = args_obj } };
    inst_fields[2] = .{ .key = .{ .string = "__jmp" }, .value = .{ .object = jmp_obj } };
    inst_fields[3] = .{ .key = .{ .string = "__src" }, .value = src_val };
    inst_fields[4] = .{ .key = .{ .string = "funcs" }, .value = .{ .object = funcs_obj } };

    return inst_obj;
}

fn tplParse(src_val: Value, src: []const u8) !Value {
    if (src.len == 0) {
        const obj = try tplBuildObj(src_val, &[_]Value{}, &[_]Value{}, &[_]Value{});
        return .{ .object = obj };
    }
    const inst_count = try tplCountInsts(src);
    if (inst_count == 0) {
        const obj = try tplBuildObj(src_val, &[_]Value{}, &[_]Value{}, &[_]Value{});
        return .{ .object = obj };
    }
    const ops = try vmgc.vmAllocManagedSlice(Value, inst_count);
    const args = try vmgc.vmAllocManagedSlice(Value, inst_count);
    const jmp = try vmgc.vmAllocManagedSlice(Value, inst_count);

    var idx: usize = 0;
    var pos: usize = 0;
    var ctrl_stack: [64]TplCtrlEntry = undefined;
    var ctrl_top: usize = 0;

    while (pos < src.len) {
        if (std.mem.indexOfPos(u8, src, pos, "{{")) |start| {
            if (start > pos) {
                ops[idx] = .{ .number = @floatFromInt(@intFromEnum(TplOp.text)) };
                args[idx] = .{ .string = src[pos..start] };
                jmp[idx] = .{ .number = -1 };
                idx += 1;
            }
            const end = std.mem.indexOfPos(u8, src, start + 2, "}}") orelse return error.InvalidTemplate;
            const tag = src[start + 2 .. end];
            const trimmed_tag = std.mem.trim(u8, tag, " \t\n\r");
            if (std.mem.startsWith(u8, trimmed_tag, "/*")) {
                pos = end + 2;
                continue;
            }
            const parsed = try tplParseTag(tag);

            if (parsed.op == .end) {
                var scope_pop: f64 = 0;
                if (ctrl_top > 0) {
                    ctrl_top -= 1;
                    const entry = ctrl_stack[ctrl_top];
                    switch (entry.kind) {
                        .if_block => {
                            if (entry.else_idx != std.math.maxInt(usize)) {
                                jmp[entry.if_idx] = .{ .number = @floatFromInt(entry.else_idx + 1) };
                                jmp[entry.else_idx] = .{ .number = @floatFromInt(idx) };
                            } else {
                                jmp[entry.if_idx] = .{ .number = @floatFromInt(idx) };
                            }
                            scope_pop = 0;
                        },
                        .range_block => {
                            if (entry.else_idx != std.math.maxInt(usize)) {
                                jmp[entry.else_idx] = .{ .number = @floatFromInt(idx) };
                            }
                            jmp[entry.if_idx] = .{ .number = @floatFromInt(idx) };
                            scope_pop = -1;
                        },
                        .with_block => {
                            jmp[entry.if_idx] = .{ .number = @floatFromInt(idx) };
                            scope_pop = -1;
                        },
                    }
                }
                ops[idx] = .{ .number = @floatFromInt(@intFromEnum(TplOp.end)) };
                args[idx] = .null;
                jmp[idx] = .{ .number = scope_pop };
                idx += 1;
            } else if (parsed.op == .if_else) {
                if (ctrl_top > 0) ctrl_stack[ctrl_top - 1].else_idx = idx;
                ops[idx] = .{ .number = @floatFromInt(@intFromEnum(TplOp.if_else)) };
                args[idx] = .null;
                jmp[idx] = .{ .number = -1 };
                idx += 1;
            } else if (parsed.op == .range_else) {
                if (ctrl_top > 0) ctrl_stack[ctrl_top - 1].else_idx = idx;
                ops[idx] = .{ .number = @floatFromInt(@intFromEnum(TplOp.range_else)) };
                args[idx] = .null;
                jmp[idx] = .{ .number = -1 };
                idx += 1;
            } else {
                if (parsed.op == .if_begin) {
                    ctrl_stack[ctrl_top] = .{ .kind = .if_block, .if_idx = idx, .else_idx = std.math.maxInt(usize) };
                    ctrl_top += 1;
                } else if (parsed.op == .range_begin) {
                    ctrl_stack[ctrl_top] = .{ .kind = .range_block, .if_idx = idx, .else_idx = std.math.maxInt(usize) };
                    ctrl_top += 1;
                } else if (parsed.op == .with_begin) {
                    ctrl_stack[ctrl_top] = .{ .kind = .with_block, .if_idx = idx, .else_idx = std.math.maxInt(usize) };
                    ctrl_top += 1;
                }
                ops[idx] = .{ .number = @floatFromInt(@intFromEnum(parsed.op)) };
                args[idx] = parsed.arg;
                jmp[idx] = .{ .number = -1 };
                idx += 1;
            }
            pos = end + 2;
        } else {
            ops[idx] = .{ .number = @floatFromInt(@intFromEnum(TplOp.text)) };
            args[idx] = .{ .string = src[pos..] };
            jmp[idx] = .{ .number = -1 };
            idx += 1;
            break;
        }
    }

    const obj = try tplBuildObj(src_val, ops[0..idx], args[0..idx], jmp[0..idx]);
    return .{ .object = obj };
}

fn tplExec(tmpl: *Object, data: Value) !Value {
    const ops_v = tplFieldValue(tmpl, "__ops");
    const args_v = tplFieldValue(tmpl, "__args");
    const jmp_v = tplFieldValue(tmpl, "__jmp");
    const funcs_v = tplFieldValue(tmpl, "funcs");

    if (ops_v != .object) return error.TypeError;
    const ops = tplAsArraySlice(ops_v.object);
    const args = tplAsArraySlice(args_v.object);
    const jmps = tplAsArraySlice(jmp_v.object);

    const sb_obj = try vmgc.vmAllocObject();
    sb_obj.* = .{ .string_builder = .{ .buf = &[_]u8{}, .len = 0 } };
    try vms.pushTempRoot(.{ .object = sb_obj });
    defer vms.popTempRoot();

    var ip: usize = 0;
    var dot_stack: [256]Value = undefined;
    var scope_top: usize = 0;
    dot_stack[scope_top] = data;

    while (ip < ops.len) {
        const op_v = ops[ip];
        if (op_v != .number) return error.TypeError;
        const op: TplOp = @enumFromInt(@as(u8, @intFromFloat(op_v.number)));
        const arg = args[ip];

        switch (op) {
            .text => {
                const s = try tplAsStringVal(arg);
                try tplAppendToBuilder(sb_obj, s);
                ip += 1;
            },
            .field => {
                const fname = try tplAsStringVal(arg);
                const val = try tplResolveField(dot_stack[scope_top], fname);
                const sv = try tplValToDynStr(val);
                const s = try tplAsStringVal(sv);
                try tplAppendToBuilder(sb_obj, s);
                ip += 1;
            },
            .chain => {
                const items = tplAsArraySlice(arg.object);
                var cur = dot_stack[scope_top];
                for (items) |item| {
                    const name = try tplAsStringVal(item);
                    cur = try tplResolveField(cur, name);
                }
                const sv = try tplValToDynStr(cur);
                const s = try tplAsStringVal(sv);
                try tplAppendToBuilder(sb_obj, s);
                ip += 1;
            },
            .root_ref => {
                const sv = try tplValToDynStr(dot_stack[scope_top]);
                const s = try tplAsStringVal(sv);
                try tplAppendToBuilder(sb_obj, s);
                ip += 1;
            },
            .var_ref, .call_fn, .assign, .break_inst, .continue_inst => {
                ip += 1;
            },
            .if_begin => {
                const cond = try tplEvalExpr(arg, dot_stack[scope_top], funcs_v);
                if (!cond.isTruthy()) {
                    ip = @intFromFloat(jmps[ip].number);
                } else {
                    ip += 1;
                }
            },
            .if_else => {
                ip = @intFromFloat(jmps[ip].number);
            },
            .end => {
                const jv = jmps[ip];
                if (jv == .number and jv.number < 0) {
                    const pop = @as(usize, @intFromFloat(-jv.number));
                    if (scope_top >= pop) scope_top -= pop;
                }
                ip += 1;
            },
            .range_begin => {
                ip = @intFromFloat(jmps[ip].number);
            },
            .range_else => {
                ip = @intFromFloat(jmps[ip].number);
            },
            .with_begin => {
                const wval = try tplEvalExpr(arg, dot_stack[scope_top], funcs_v);
                scope_top += 1;
                dot_stack[scope_top] = wval;
                ip += 1;
            },
        }
    }

    return try tplBuilderToStr(sb_obj);
}

// ── JSON helpers ─────────────────────────────────────────────────────────────

const JsonAllocator = struct {
    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ra: usize) ?[*]u8 {
        _ = ctx; _ = ra;
        if (ptr_align.toByteUnits() > 16) return null;
        return @ptrCast(heap.allocBytesManaged(len) orelse return null);
    }
    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ra: usize) bool {
        _ = ctx; _ = buf_align; _ = ra;
        if (new_len <= buf.len) return true;
        return false;
    }
    fn remapFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        _ = ctx; _ = buf_align; _ = ra;
        if (new_len <= buf.len) return buf.ptr;
        return null;
    }
    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ra: usize) void {
        _ = ctx; _ = buf_align; _ = ra;
        heap.freeBytesManaged(buf);
    }
    pub fn allocator() std.mem.Allocator {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .alloc = &allocFn,
                .resize = &resizeFn,
                .remap = &remapFn,
                .free = &freeFn,
            },
        };
    }
};

fn jsonValueToGengo(jv: std.json.Value) !Value {
    return switch (jv) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .number = @floatFromInt(i) },
        .float => |f| .{ .number = f },
        .number_string => |s| .{ .number = try std.fmt.parseFloat(f64, s) },
        .string => |s| try vmgc.makeDynString(s),
        .array => |arr| {
            const n = arr.items.len;
            if (n == 0) {
                const obj = try vmgc.vmAllocObject();
                obj.* = .{ .array_managed = &[_]Value{} };
                return .{ .object = obj };
            }
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = obj });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(Value, n);
            for (0..n) |i| {
                items[i] = try jsonValueToGengo(arr.items[i]);
            }
            obj.* = .{ .array_managed = items[0..n] };
            return .{ .object = obj };
        },
        .object => |obj_map| {
            const n = obj_map.keys().len;
            if (n == 0) {
                const obj = try vmgc.vmAllocObject();
                obj.* = .{ .map = &[_]MapEntry{} };
                return .{ .object = obj };
            }
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .map = &[_]MapEntry{} };
            try vms.pushTempRoot(.{ .object = obj });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(MapEntry, n);
            const keys = obj_map.keys();
            const vals = obj_map.values();
            for (0..n) |i| {
                items[i] = .{
                    .key = try vmgc.makeDynString(keys[i]),
                    .value = try jsonValueToGengo(vals[i]),
                };
            }
            obj.* = .{ .map = items[0..n] };
            const bcount = vmmap.mapBucketsForCount(n);
            const buckets = try vmgc.vmAllocManagedSlice(i32, bcount);
            vmmap.mapBuildHashedBuckets(items[0..n], buckets);
            obj.* = .{ .map_hashed = .{ .entries = items[0..n], .len = n, .buckets = buckets } };
            return .{ .object = obj };
        },
    };
}

fn jsonStringifyValue(s: *std.json.Stringify, gv: Value) !void {
    const uv = vms.unboxNamed(gv);
    switch (uv) {
        .null => try s.write(null),
        .boolean => |b| try s.write(b),
        .number => |n| try s.write(n),
        .rune => |r| try s.write(@as(i64, @intCast(r))),
        .string => |str| try s.write(str),
        .object => |obj| switch (obj.*) {
            .dyn_string => |str| try s.write(str),
            .array, .array_managed => {
                try s.beginArray();
                for (vms.asArraySlice(obj)) |item| {
                    try jsonStringifyValue(s, item);
                }
                try s.endArray();
            },
            .map, .map_managed, .map_hashed => {
                try s.beginObject();
                for (vms.asMapSlice(obj)) |entry| {
                    const key = vms.unboxNamed(entry.key);
                    const key_str = try vms.asStringValue(key);
                    try s.objectField(key_str);
                    try jsonStringifyValue(s, entry.value);
                }
                try s.endObject();
            },
            else => try s.write(null),
        },
        .error_value => try s.write(null),
    }
}

fn jsonParseNative() !Value {
    const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
    const src = try vms.asStringValue(arg);
    const alloc = JsonAllocator.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, src, .{}) catch return error.TypeError;
    defer parsed.deinit();
    return jsonValueToGengo(parsed.value);
}

fn jsonStringifyNative() !Value {
    const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
    var out: std.Io.Writer.Allocating = .init(JsonAllocator.allocator());
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    jsonStringifyValue(&s, arg) catch return error.TypeError;
    const buf = out.written();
    return vmgc.makeDynString(buf);
}

fn jsonValidNative() !Value {
    const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
    const src = try vms.asStringValue(arg);
    const alloc = JsonAllocator.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, src, .{}) catch return .{ .boolean = false };
    parsed.deinit();
    return .{ .boolean = true };
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
        .core_type_of => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = nativeTypeNameValue(arg);
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
        .core_is_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsFloat(vms.vmState().stack[vms.vmState().stack_top - 1]);
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
        .core_is_array => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsArray(vms.vmState().stack[vms.vmState().stack_top - 1]);
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
        .core_is_struct => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = nativeIsStruct(vms.vmState().stack[vms.vmState().stack_top - 1]);
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
        .core_deep_equal => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const out = try nativeDeepEqual(vms.vmState().stack[top - 2], vms.vmState().stack[top - 1]);
            _ = try vms.vmPop();
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
        .str_replace => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 3]);
            const old = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const new = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrReplace(s, old, new);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_last_index_of => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrLastIndexOf(s, sub);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_repeat => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const out = try nativeStrRepeat(s, vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_split_once => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrSplitOnce(s, sep);
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
        .rand_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(nativeRandFloat());
        },
        .rand_intn => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeRandIntn(n_val);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .rand_between => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const out = try nativeRandBetween(vms.vmState().stack[top - 2], vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .rand_seed => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            try nativeRandSeed(n_val);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .rand_choice => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.unboxNamed(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (arr_val != .object) return error.TypeError;
            const out = try nativeRandChoice(arr_val.object);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_parse => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try jsonParseNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_stringify => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try jsonStringifyNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_valid => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try jsonValidNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_parse => {
            if (argc != nf.arity) return error.ArityMismatch;
            const src_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const src = try vms.asStringValue(src_val);
            const out = try tplParse(src_val, src);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_execute => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const tmpl_val = vms.vmState().stack[top - 2];
            const data = vms.vmState().stack[top - 1];
            if (tmpl_val != .object) return error.TypeError;
            const out = try tplExec(tmpl_val.object, data);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_add_func => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const tmpl_val = vms.vmState().stack[top - 3];
            const name_val = vms.vmState().stack[top - 2];
            const func_val = vms.vmState().stack[top - 1];
            if (tmpl_val != .object) return error.TypeError;
            const name = try vms.asStringValue(name_val);
            const funcs_v = tplFieldValue(tmpl_val.object, "funcs");
            if (funcs_v != .object) return error.TypeError;
            const funcs_obj = funcs_v.object;
            switch (funcs_obj.*) {
                .map => |m| {
                    var fi: usize = 0;
                    while (fi < m.len) : (fi += 1) {
                        if (tplIsStringVal(m[fi].key)) {
                            const k = try tplAsStringVal(m[fi].key);
                            if (std.mem.eql(u8, k, name)) {
                                m[fi].value = func_val;
                                break;
                            }
                        }
                    } else {
                        const new_items = try vmgc.vmAllocManagedSlice(MapEntry, m.len + 1);
                        @memcpy(new_items[0..m.len], m);
                        new_items[m.len] = .{ .key = .{ .string = name }, .value = func_val };
                        funcs_obj.* = .{ .map_managed = new_items[0 .. m.len + 1] };
                    }
                },
                .map_managed => |m| {
                    var fi: usize = 0;
                    while (fi < m.len) : (fi += 1) {
                        if (tplIsStringVal(m[fi].key)) {
                            const k = try tplAsStringVal(m[fi].key);
                            if (std.mem.eql(u8, k, name)) {
                                m[fi].value = func_val;
                                break;
                            }
                        }
                    } else {
                        const new_items = try vmgc.vmAllocManagedSlice(MapEntry, m.len + 1);
                        @memcpy(new_items[0..m.len], m);
                        new_items[m.len] = .{ .key = .{ .string = name }, .value = func_val };
                        heap.freeManagedSlice(MapEntry, m);
                        funcs_obj.* = .{ .map_managed = new_items[0 .. m.len + 1] };
                    }
                },
                else => return error.TypeError,
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .template_render => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const src_val = vms.vmState().stack[top - 2];
            const data = vms.vmState().stack[top - 1];
            const src = try vms.asStringValue(src_val);
            const tmpl_val = try tplParse(src_val, src);
            if (tmpl_val != .object) return error.TypeError;
            const out = try tplExec(tmpl_val.object, data);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_valid => {
            if (argc != nf.arity) return error.ArityMismatch;
            const src = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const is_valid = if (tplCountInsts(src)) |_| true else |_| false;
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = is_valid });
        },
    }
}
