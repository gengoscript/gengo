const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common.zig");
const heap = @import("../../runtime/heap.zig");
const host_abi = @import("../../runtime/host_abi.zig");
const io = @import("../../runtime/io.zig");
const globals = @import("../globals.zig");
const module_compile = @import("../module_compile.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const vmmap = @import("../vm_map.zig");
const vmtyp = @import("../vm_types.zig");
const vmstr = @import("../vm_string.zig");
const vmperf = @import("../vm_perf.zig");
const vm = @import("../vm.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const HostModuleFuncObj = @import("../value.zig").HostModuleFuncObj;
const FieldTypeAlt = @import("../value.zig").FieldTypeAlt;
const FieldTypeSpec = @import("../value.zig").FieldTypeSpec;
const StructFieldSpec = @import("../value.zig").StructFieldSpec;
const StructTypeObj = @import("../value.zig").StructTypeObj;

const rand_mod = @import("rand.zig");
const encode_mod = @import("encode.zig");
const time_mod = @import("time.zig");
const core_mod = @import("core.zig");
const string_mod = @import("string.zig");
const io_mod = @import("io.zig");
const json_mod = @import("json.zig");
const template_mod = @import("template.zig");
const regexp_mod = @import("regexp.zig");
const host_abi_mod = @import("host_abi.zig");

const TemplateTypeQualifiedName = "@std.template.obj";
const TimeTypeQualifiedName = "@std.time.obj";
const RegexpTypeQualifiedName = "@std.regexp.obj";

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
    time_now = 74,
    time_from_unix = 75,
    time_from_unix_ms = 76,
    time_parse = 77,
    time_unix = 78,
    time_unix_ms = 80,
    time_parts = 81,
    time_format = 82,
    time_add_ms = 83,
    time_add_s = 84,
    time_add_m = 85,
    time_add_h = 86,
    time_sub = 87,
    time_before = 88,
    time_after = 89,
    time_equal = 90,
    time_is_zero = 91,
    io_sprintf = 92,
    math_acos = 93,
    math_asin = 94,
    math_atan = 95,
    math_atan2 = 96,
    math_cosh = 97,
    math_sinh = 98,
    math_tanh = 99,
    math_exp = 100,
    math_exp2 = 101,
    math_trunc = 102,
    math_cbrt = 103,
    math_hypot = 104,
    math_mod = 105,
    math_nan = 106,
    math_is_nan = 107,
    math_is_inf = 108,
    hex_encode = 109,
    hex_decode = 110,
    base64_encode = 111,
    base64_decode = 112,
    base64_url_encode = 113,
    base64_url_decode = 114,
    str_count = 115,
    str_fields = 116,
    str_pad_left = 117,
    str_pad_right = 118,
    str_equal_fold = 119,
    str_contains = 148,
    str_contains_any = 120,
    rand_perm = 121,
    rand_norm_float = 122,
    time_since = 123,
    time_until = 124,
    time_add_date = 125,
    re_match = 126,
    re_find = 127,
    re_find_all = 128,
    re_replace = 129,
    re_split = 130,
    re_compile = 131,
    re_obj_match = 132,
    re_obj_find = 133,
    re_obj_find_all = 134,
    re_obj_replace = 135,
    re_obj_split = 136,
    math_clamp = 137,
    math_sign = 138,
    sort_asc = 139,
    sort_desc = 140,
    sort_by = 141,
    array_filter = 142,
    array_map = 143,
    array_reduce = 144,
    array_slice = 145,
    array_zip = 146,
    array_flat = 147,
};
const MaxNativeArgs = 255;
const NamespaceEntry = struct {
    name: []const u8,
    value: Value,
};

fn valueLessThan(a: Value, b: Value) !bool {
    if (a == .number and b == .number) return a.number < b.number;
    if (a == .string and b == .string) return std.mem.lessThan(u8, a.string, b.string);
    if (a == .boolean and b == .boolean) return !a.boolean and b.boolean;
    return @intFromEnum(a) < @intFromEnum(b);
}

fn valueGreaterThan(a: Value, b: Value) !bool {
    if (a == .number and b == .number) return a.number > b.number;
    if (a == .string and b == .string) return std.mem.lessThan(u8, b.string, a.string);
    if (a == .boolean and b == .boolean) return a.boolean and !b.boolean;
    return @intFromEnum(a) > @intFromEnum(b);
}

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

pub fn buildStdModule() !*Object {
    if (vms.vmState().std_module) |m| return m;

    const io_entries = [_]NamespaceEntry{
        .{ .name = "sprintf", .value = try makeNative(.io_sprintf, 255) },
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
        .{ .name = "acos", .value = try makeNative(.math_acos, 1) },
        .{ .name = "asin", .value = try makeNative(.math_asin, 1) },
        .{ .name = "atan", .value = try makeNative(.math_atan, 1) },
        .{ .name = "atan2", .value = try makeNative(.math_atan2, 2) },
        .{ .name = "cosh", .value = try makeNative(.math_cosh, 1) },
        .{ .name = "sinh", .value = try makeNative(.math_sinh, 1) },
        .{ .name = "tanh", .value = try makeNative(.math_tanh, 1) },
        .{ .name = "exp", .value = try makeNative(.math_exp, 1) },
        .{ .name = "exp2", .value = try makeNative(.math_exp2, 1) },
        .{ .name = "trunc", .value = try makeNative(.math_trunc, 1) },
        .{ .name = "cbrt", .value = try makeNative(.math_cbrt, 1) },
        .{ .name = "hypot", .value = try makeNative(.math_hypot, 2) },
        .{ .name = "mod", .value = try makeNative(.math_mod, 2) },
        .{ .name = "nan", .value = try makeNative(.math_nan, 0) },
        .{ .name = "is_nan", .value = try makeNative(.math_is_nan, 1) },
        .{ .name = "is_inf", .value = try makeNative(.math_is_inf, 2) },
        .{ .name = "pi", .value = .{ .number = std.math.pi } },
        .{ .name = "e", .value = .{ .number = std.math.e } },
        .{ .name = "phi", .value = .{ .number = 1.618033988749895 } },
        .{ .name = "clamp", .value = try makeNative(.math_clamp, 3) },
        .{ .name = "sign", .value = try makeNative(.math_sign, 1) },
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
        .{ .name = "perm", .value = try makeNative(.rand_perm, 1) },
        .{ .name = "norm_float", .value = try makeNative(.rand_norm_float, 0) },
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
        .{ .name = "contains", .value = try makeNative(.str_contains, 2) },
        .{ .name = "starts_with", .value = try makeNative(.str_starts_with, 2) },
        .{ .name = "ends_with", .value = try makeNative(.str_ends_with, 2) },
        .{ .name = "index_of", .value = try makeNative(.str_index_of, 2) },
        .{ .name = "replace", .value = try makeNative(.str_replace, 3) },
        .{ .name = "last_index_of", .value = try makeNative(.str_last_index_of, 2) },
        .{ .name = "repeat", .value = try makeNative(.str_repeat, 2) },
        .{ .name = "split_once", .value = try makeNative(.str_split_once, 2) },
        .{ .name = "builder", .value = try makeNative(.str_builder_new, 0) },
        .{ .name = "count", .value = try makeNative(.str_count, 2) },
        .{ .name = "fields", .value = try makeNative(.str_fields, 1) },
        .{ .name = "pad_left", .value = try makeNative(.str_pad_left, 3) },
        .{ .name = "pad_right", .value = try makeNative(.str_pad_right, 3) },
        .{ .name = "equal_fold", .value = try makeNative(.str_equal_fold, 2) },
        .{ .name = "contains_any", .value = try makeNative(.str_contains_any, 2) },
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

    const time_type_obj = try time_mod.timeGetType();
    try vms.pushTempRoot(.{ .object = time_type_obj });
    defer vms.popTempRoot();

    const time_entries = [_]NamespaceEntry{
        .{ .name = "now", .value = try makeNative(.time_now, 0) },
        .{ .name = "from_unix", .value = try makeNative(.time_from_unix, 1) },
        .{ .name = "from_unix_ms", .value = try makeNative(.time_from_unix_ms, 1) },
        .{ .name = "parse", .value = try makeNative(.time_parse, 2) },
        .{ .name = "since", .value = try makeNative(.time_since, 1) },
        .{ .name = "until", .value = try makeNative(.time_until, 1) },
        .{ .name = "ms", .value = .{ .number = 1 } },
        .{ .name = "second", .value = .{ .number = 1000 } },
        .{ .name = "minute", .value = .{ .number = 60_000 } },
        .{ .name = "hour", .value = .{ .number = 3_600_000 } },
        .{ .name = "day", .value = .{ .number = 86_400_000 } },
        .{ .name = "__type", .value = .{ .object = time_type_obj } },
    };
    const time_obj = try makeNamespace("time", "@module_type:std.time", &time_entries);
    try vms.pushTempRoot(.{ .object = time_obj });
    defer vms.popTempRoot();

    const hex_entries = [_]NamespaceEntry{
        .{ .name = "encode", .value = try makeNative(.hex_encode, 1) },
        .{ .name = "decode", .value = try makeNative(.hex_decode, 1) },
    };
    const hex_obj = try makeNamespace("hex", "@module_type:std.hex", &hex_entries);
    try vms.pushTempRoot(.{ .object = hex_obj });
    defer vms.popTempRoot();

    const base64_entries = [_]NamespaceEntry{
        .{ .name = "encode", .value = try makeNative(.base64_encode, 1) },
        .{ .name = "decode", .value = try makeNative(.base64_decode, 1) },
        .{ .name = "url_encode", .value = try makeNative(.base64_url_encode, 1) },
        .{ .name = "url_decode", .value = try makeNative(.base64_url_decode, 1) },
    };
    const base64_obj = try makeNamespace("base64", "@module_type:std.base64", &base64_entries);
    try vms.pushTempRoot(.{ .object = base64_obj });
    defer vms.popTempRoot();

    const regexp_type_obj = try regexp_mod.reGetType();
    try vms.pushTempRoot(.{ .object = regexp_type_obj });
    defer vms.popTempRoot();

    const regexp_entries = [_]NamespaceEntry{
        .{ .name = "match", .value = try makeNative(.re_match, 2) },
        .{ .name = "find", .value = try makeNative(.re_find, 2) },
        .{ .name = "find_all", .value = try makeNative(.re_find_all, 2) },
        .{ .name = "replace", .value = try makeNative(.re_replace, 3) },
        .{ .name = "split", .value = try makeNative(.re_split, 2) },
        .{ .name = "compile", .value = try makeNative(.re_compile, 1) },
        .{ .name = "__type", .value = .{ .object = regexp_type_obj } },
    };
    const regexp_obj = try makeNamespace("regexp", "@module_type:std.regexp", &regexp_entries);
    try vms.pushTempRoot(.{ .object = regexp_obj });
    defer vms.popTempRoot();

    const sort_entries = [_]NamespaceEntry{
        .{ .name = "asc", .value = try makeNative(.sort_asc, 1) },
        .{ .name = "desc", .value = try makeNative(.sort_desc, 1) },
        .{ .name = "by", .value = try makeNative(.sort_by, 2) },
    };
    const sort_obj = try makeNamespace("sort", "@module_type:std.sort", &sort_entries);
    try vms.pushTempRoot(.{ .object = sort_obj });
    defer vms.popTempRoot();

    const array_entries = [_]NamespaceEntry{
        .{ .name = "filter", .value = try makeNative(.array_filter, 2) },
        .{ .name = "map", .value = try makeNative(.array_map, 2) },
        .{ .name = "reduce", .value = try makeNative(.array_reduce, 3) },
        .{ .name = "slice", .value = try makeNative(.array_slice, 3) },
        .{ .name = "zip", .value = try makeNative(.array_zip, 2) },
        .{ .name = "flat", .value = try makeNative(.array_flat, 1) },
    };
    const array_obj = try makeNamespace("array", "@module_type:std.array", &array_entries);
    try vms.pushTempRoot(.{ .object = array_obj });
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
        .{ .name = "time", .value = .{ .object = time_obj } },
        .{ .name = "hex", .value = .{ .object = hex_obj } },
        .{ .name = "base64", .value = .{ .object = base64_obj } },
        .{ .name = "regexp", .value = .{ .object = regexp_obj } },
        .{ .name = "sort", .value = .{ .object = sort_obj } },
        .{ .name = "array", .value = .{ .object = array_obj } },
        .{ .name = "Time", .value = .{ .object = time_type_obj } },
        .{ .name = "Regexp", .value = .{ .object = regexp_type_obj } },
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
    {
        const time_methods = [_]struct { name: []const u8, id: NativeFnId, arity: u8 }{
            .{ .name = "unix",      .id = .time_unix,      .arity = 1 },
            .{ .name = "unix_ms",   .id = .time_unix_ms,   .arity = 1 },
            .{ .name = "parts",     .id = .time_parts,     .arity = 1 },
            .{ .name = "format",    .id = .time_format,    .arity = 2 },
            .{ .name = "add_ms",    .id = .time_add_ms,    .arity = 2 },
            .{ .name = "add_s",     .id = .time_add_s,     .arity = 2 },
            .{ .name = "add_m",     .id = .time_add_m,     .arity = 2 },
            .{ .name = "add_h",     .id = .time_add_h,     .arity = 2 },
            .{ .name = "sub",       .id = .time_sub,       .arity = 2 },
            .{ .name = "before",    .id = .time_before,    .arity = 2 },
            .{ .name = "after",     .id = .time_after,     .arity = 2 },
            .{ .name = "equal",     .id = .time_equal,     .arity = 2 },
            .{ .name = "is_zero",   .id = .time_is_zero,   .arity = 1 },
            .{ .name = "since",     .id = .time_since,     .arity = 1 },
            .{ .name = "until",     .id = .time_until,     .arity = 1 },
            .{ .name = "add_date",  .id = .time_add_date,  .arity = 4 },
        };
        for (time_methods) |m| {
            const needed = TimeTypeQualifiedName.len + 1 + m.name.len;
            const kbuf = (heap.bump(u8, needed) orelse return)[0..needed];
            @memcpy(kbuf[0..TimeTypeQualifiedName.len], TimeTypeQualifiedName);
            kbuf[TimeTypeQualifiedName.len] = '.';
            @memcpy(kbuf[TimeTypeQualifiedName.len + 1 .. needed], m.name);
            if (!globals.has(kbuf)) {
                const n = try makeNative(m.id, m.arity);
                try globals.def(kbuf, n);
            }
        }
    }
    {
        const regexp_methods = [_]struct { name: []const u8, id: NativeFnId, arity: u8 }{
            .{ .name = "match",    .id = .re_obj_match,    .arity = 2 },
            .{ .name = "find",     .id = .re_obj_find,     .arity = 2 },
            .{ .name = "find_all", .id = .re_obj_find_all, .arity = 2 },
            .{ .name = "replace",  .id = .re_obj_replace,  .arity = 3 },
            .{ .name = "split",    .id = .re_obj_split,    .arity = 2 },
        };
        for (regexp_methods) |m| {
            const needed = RegexpTypeQualifiedName.len + 1 + m.name.len;
            const kbuf = (heap.bump(u8, needed) orelse return)[0..needed];
            @memcpy(kbuf[0..RegexpTypeQualifiedName.len], RegexpTypeQualifiedName);
            kbuf[RegexpTypeQualifiedName.len] = '.';
            @memcpy(kbuf[RegexpTypeQualifiedName.len + 1 .. needed], m.name);
            if (!globals.has(kbuf)) {
                const n = try makeNative(m.id, m.arity);
                try globals.def(kbuf, n);
            }
        }
    }
}

pub fn installHostModules(host_modules: []const module_compile.HostModuleDesc) !void {
    for (host_modules) |hm| {
        const global_name_buf = (heap.bump(u8, 9 + hm.name.len) orelse return)[0..9 + hm.name.len];
        global_name_buf[0] = '@';
        @memcpy(global_name_buf[1..8], "module:");
        @memcpy(global_name_buf[8..][0..hm.name.len], hm.name);
        const global_name = global_name_buf[0..8 + hm.name.len];
        if (globals.has(global_name)) continue;

        const entries = hm.functions;
        const any_alts = heap.bump(FieldTypeAlt, 1) orelse return;
        any_alts[0] = .{ .typ = .any };
        const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

        const field_specs = (heap.bump(StructFieldSpec, entries.len) orelse return)[0..entries.len];
        for (field_specs, 0..) |*fs, i| {
            fs.* = .{ .name = entries[i].name, .typ = any_spec, .is_const = true };
        }

        const qual_name_buf = (heap.bump(u8, 13 + hm.name.len) orelse return)[0..13 + hm.name.len];
        @memcpy(qual_name_buf[0..13], "@module_type:");
        @memcpy(qual_name_buf[13..][0..hm.name.len], hm.name);
        const qualified_name = qual_name_buf[0..13 + hm.name.len];

        const typ_obj = try vmgc.vmAllocObject();
        try vms.pushTempRoot(.{ .object = typ_obj });
        defer vms.popTempRoot();
        typ_obj.* = .{ .struct_type = StructTypeObj{
            .name = hm.name,
            .qualified_name = qualified_name,
            .fields = field_specs[0..entries.len],
        } };

        const inst_fields = try vmgc.vmAllocManagedSlice(MapEntry, entries.len);
        const inst_obj = try vmgc.vmAllocObject();
        try vms.pushTempRoot(.{ .object = inst_obj });
        defer vms.popTempRoot();
        inst_obj.* = .{ .struct_instance = .{ .typ = typ_obj, .fields = inst_fields } };

        for (inst_fields, 0..) |*fld, i| {
            const func_obj = try vmgc.vmAllocObject();
            func_obj.* = .{ .host_module_function = .{
                .call_id = entries[i].call_id,
                .arity = entries[i].arity,
            } };
            fld.* = .{
                .key = .{ .string = entries[i].name },
                .value = .{ .object = func_obj },
            };
        }

        try globals.def(global_name, .{ .object = inst_obj });
    }
}

pub fn callHostModule(hmf: HostModuleFuncObj, argc: u8) !void {
    if (hmf.arity != 255 and hmf.arity != argc) return error.ArityMismatch;
    if (argc > MaxNativeArgs) return error.ArityMismatch;
    if (vms.vmState().policy.native_backend != .host) return error.HostNativeUnsupported;
    try host_abi_mod.ensureHostReady();
    const start = vms.vmState().stack_top - argc;
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
    const st = host_abi.nativeCallRaw(hmf.call_id, args_wire[0..argc], &out_wire);
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
    const out = try host_abi_mod.valueFromWire(out_wire);
    try vms.vmPush(out);
}

pub fn callNative(nf: NativeFuncObj, argc: u8) !void {
    vmperf.countHostcall(nf.id);
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .io_println => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_IO_PRINTLN) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    const start = vms.vmState().stack_top - argc;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try host_abi_mod.wireFromValue(vms.vmState().stack[start + i]);
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
            try io_mod.nativePrintf(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .io_sprintf => {
            const start = vms.vmState().stack_top - argc;
            const out = try io_mod.nativeSprintf(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
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
            const out = try core_mod.nativeLen(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
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
            const out = try core_mod.nativeAppend(start, argc);
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
            const out = core_mod.nativeTypeNameValue(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_int => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = core_mod.nativeIsInt(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = core_mod.nativeIsFloat(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_string => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = core_mod.nativeIsString(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_array => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = core_mod.nativeIsArray(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_map => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = core_mod.nativeIsMap(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_struct => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = core_mod.nativeIsStruct(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_is_null => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = core_mod.nativeIsNull(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_deep_equal => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const out = try core_mod.nativeDeepEqual(vms.vmState().stack[top - 2], vms.vmState().stack[top - 1]);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_clone => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try core_mod.nativeClone(vms.vmState().stack[vms.vmState().stack_top - 1]);
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
            const out = try core_mod.nativeGcStats();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_gc_stats_ext => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try core_mod.nativeGcStatsExt();
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
            const out = try core_mod.nativeDelete(m_val.object, key);
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
            const out = try core_mod.nativeHas(m_val.object, key);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_keys => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (m_val != .object) return error.TypeError;
            const out = try core_mod.nativeKeys(m_val.object);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_values => {
            if (argc != nf.arity) return error.ArityMismatch;
            const m_val = vms.unboxNamed(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (m_val != .object) return error.TypeError;
            const out = try core_mod.nativeValues(m_val.object);
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
            const out = try core_mod.nativeContains(arr_val.object, needle);
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
            const out = try core_mod.nativeRemove(arr_val.object, idx_val);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
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
            const out = try core_mod.nativeByteLen(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_int => {
            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_INT) != 0) {
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
                    const st = host_abi.nativeCall(.conv_to_int, arg_wire[0..], &out_wire);
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
            const out = try core_mod.nativeConvToInt(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_FLOAT) != 0) {
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
                    const st = host_abi.nativeCall(.conv_to_float, arg_wire[0..], &out_wire);
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
            const out = try core_mod.nativeConvToFloat(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_bool => {
            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_BOOL) != 0) {
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
                    const st = host_abi.nativeCall(.conv_to_bool, arg_wire[0..], &out_wire);
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
            const out = try core_mod.nativeConvToBool(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_string => {
            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_STRING) != 0) {
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
                    const st = host_abi.nativeCall(.conv_to_string, arg_wire[0..], &out_wire);
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
            const out = try core_mod.nativeConvToString(arg);
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
        .math_acos => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.acos(n) });
        },
        .math_asin => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.asin(n) });
        },
        .math_atan => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.atan(n) });
        },
        .math_atan2 => {
            if (argc != nf.arity) return error.ArityMismatch;
            const x = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const y = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.atan2(y, x) });
        },
        .math_cosh => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.cosh(n) });
        },
        .math_sinh => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.sinh(n) });
        },
        .math_tanh => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.tanh(n) });
        },
        .math_exp => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.exp(n) });
        },
        .math_exp2 => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.exp2(n) });
        },
        .math_trunc => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @trunc(n) });
        },
        .math_cbrt => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.cbrt(n) });
        },
        .math_hypot => {
            if (argc != nf.arity) return error.ArityMismatch;
            const q = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const p = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.hypot(p, q) });
        },
        .math_mod => {
            if (argc != nf.arity) return error.ArityMismatch;
            const y = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const x = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @mod(x, y) });
        },
        .math_nan => {
            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.nan(f64) });
        },
        .math_is_nan => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = std.math.isNan(n) });
        },
        .math_is_inf => {
            if (argc != nf.arity) return error.ArityMismatch;
            const sign_v = vms.vmState().stack[vms.vmState().stack_top - 1];
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            const sign = try vms.valueAsInt(sign_v);
            const result = if (sign == 0) std.math.isInf(n) else if (sign > 0) std.math.isPositiveInf(n) else std.math.isNegativeInf(n);
            try vms.vmPush(.{ .boolean = result });
        },
        .str_split => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try string_mod.nativeStrSplit(s, sep);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_join => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const arr_val = vms.vmState().stack[top - 2];
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            if (arr_val != .object) return error.TypeError;
            const out = try string_mod.nativeStrJoin(arr_val.object, sep);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_trim => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try string_mod.nativeStrTrim(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_upper => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try string_mod.nativeStrUpper(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_lower => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try string_mod.nativeStrLower(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_contains => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(string_mod.nativeStrContains(s, sub));
        },
        .str_starts_with => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const prefix = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(string_mod.nativeStrStartsWith(s, prefix));
        },
        .str_ends_with => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const suffix = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(string_mod.nativeStrEndsWith(s, suffix));
        },
        .str_index_of => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try string_mod.nativeStrIndexOf(s, sub);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_replace => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 3]);
            const old = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const new = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try string_mod.nativeStrReplace(s, old, new);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_last_index_of => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try string_mod.nativeStrLastIndexOf(s, sub);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_repeat => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const out = try string_mod.nativeStrRepeat(s, vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_split_once => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try string_mod.nativeStrSplitOnce(s, sep);
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
            try vms.vmPush(rand_mod.nativeRandFloat());
        },
        .rand_intn => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try rand_mod.nativeRandIntn(n_val);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .rand_between => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const out = try rand_mod.nativeRandBetween(vms.vmState().stack[top - 2], vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .rand_seed => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            try rand_mod.nativeRandSeed(n_val);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .rand_choice => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.unboxNamed(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (arr_val != .object) return error.TypeError;
            const out = try rand_mod.nativeRandChoice(arr_val.object);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_parse => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try json_mod.jsonParseNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_stringify => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try json_mod.jsonStringifyNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_valid => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try json_mod.jsonValidNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .hex_encode => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try encode_mod.nativeHexEncode(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .hex_decode => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try encode_mod.nativeHexDecode(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .base64_encode => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try encode_mod.nativeBase64Encode(s, false);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .base64_decode => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try encode_mod.nativeBase64Decode(s, false);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .base64_url_encode => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try encode_mod.nativeBase64Encode(s, true);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .base64_url_decode => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try encode_mod.nativeBase64Decode(s, true);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_count => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(string_mod.nativeStrCount(s, sub));
        },
        .str_fields => {
            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try string_mod.nativeStrFields(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_pad_left => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 3]);
            const n_v = vms.vmState().stack[top - 2];
            const pad = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try string_mod.nativeStrPadLeft(s, n_v, pad);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_pad_right => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 3]);
            const n_v = vms.vmState().stack[top - 2];
            const pad = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try string_mod.nativeStrPadRight(s, n_v, pad);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_equal_fold => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const t = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(string_mod.nativeStrEqualFold(s, t));
        },
        .str_contains_any => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const chars = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(string_mod.nativeStrContainsAny(s, chars));
        },
        .rand_perm => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n_v = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try rand_mod.nativeRandPerm(n_v);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .rand_norm_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(rand_mod.nativeRandNormFloat());
        },
        .template_parse => {
            if (argc != nf.arity) return error.ArityMismatch;
            const src_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const src = try vms.asStringValue(src_val);
            const out = try template_mod.tplParse(src_val, src);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_execute => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const tmpl_val = vms.vmState().stack[top - 2];
            const data = vms.vmState().stack[top - 1];
            if (tmpl_val != .object) return error.TypeError;
            const out = try template_mod.tplExec(tmpl_val.object, data);
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
            try template_mod.tplAddFunc(tmpl_val.object, name, func_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .template_render => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const src_val = vms.vmState().stack[top - 2];
            const data = vms.vmState().stack[top - 1];
            const src = try vms.asStringValue(src_val);
            const out = try template_mod.tplRender(src_val, src, data);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_valid => {
            if (argc != nf.arity) return error.ArityMismatch;
            const src = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const is_valid = template_mod.tplValid(src);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = is_valid });
        },
        .time_now => {
            if (argc != 0) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(try time_mod.timeBuildObj(time_mod.timeNowMs()));
        },
        .time_from_unix => {
            if (argc != nf.arity) return error.ArityMismatch;
            const sec = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (@trunc(sec) != sec) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try time_mod.timeBuildObj(sec * 1000));
        },
        .time_from_unix_ms => {
            if (argc != nf.arity) return error.ArityMismatch;
            const ms = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (@trunc(ms) != ms) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try time_mod.timeBuildObj(ms));
        },
        .time_parse => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const fmt = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try time_mod.timeParseStr(s, fmt);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .time_unix => {
            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try time_mod.timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @floor(ms / 1000) });
        },
        .time_unix_ms => {
            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try time_mod.timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = ms });
        },
        .time_parts => {
            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try time_mod.timeGetMs(recv);
            const p = time_mod.timeEpochMsToParts(ms);
            const field_count = 8;
            const entries = try vmgc.vmAllocManagedSlice(MapEntry, field_count);
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .map = &[_]MapEntry{} };
            try vms.pushTempRoot(.{ .object = obj });
            defer vms.popTempRoot();
            entries[0] = .{ .key = .{ .string = "year" }, .value = .{ .number = @floatFromInt(p.year) } };
            entries[1] = .{ .key = .{ .string = "month" }, .value = .{ .number = @floatFromInt(p.month) } };
            entries[2] = .{ .key = .{ .string = "day" }, .value = .{ .number = @floatFromInt(p.day) } };
            entries[3] = .{ .key = .{ .string = "hour" }, .value = .{ .number = @floatFromInt(p.hour) } };
            entries[4] = .{ .key = .{ .string = "min" }, .value = .{ .number = @floatFromInt(p.min) } };
            entries[5] = .{ .key = .{ .string = "sec" }, .value = .{ .number = @floatFromInt(p.sec) } };
            entries[6] = .{ .key = .{ .string = "ms" }, .value = .{ .number = @floatFromInt(p.ms) } };
            entries[7] = .{ .key = .{ .string = "weekday" }, .value = .{ .number = @floatFromInt(p.weekday) } };
            obj.* = .{ .map_managed = entries[0..field_count] };
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = obj });
        },
        .time_format => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const fmt = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const ms = try time_mod.timeGetMs(recv);
            const out = try time_mod.timeFormatStr(ms, fmt);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .time_add_ms => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const n = try vms.valueAsNumber(vms.vmState().stack[top - 1]);
            const ms = try time_mod.timeGetMs(recv);
            if (@trunc(n) != n) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try time_mod.timeBuildObj(ms + n));
        },
        .time_add_s => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const n = try vms.valueAsNumber(vms.vmState().stack[top - 1]);
            const ms = try time_mod.timeGetMs(recv);
            if (@trunc(n) != n) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try time_mod.timeBuildObj(ms + n * 1000));
        },
        .time_add_m => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const n = try vms.valueAsNumber(vms.vmState().stack[top - 1]);
            const ms = try time_mod.timeGetMs(recv);
            if (@trunc(n) != n) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try time_mod.timeBuildObj(ms + n * 60_000));
        },
        .time_add_h => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const n = try vms.valueAsNumber(vms.vmState().stack[top - 1]);
            const ms = try time_mod.timeGetMs(recv);
            if (@trunc(n) != n) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try time_mod.timeBuildObj(ms + n * 3_600_000));
        },
        .time_sub => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try time_mod.timeGetMs(recv);
            const ms_b = try time_mod.timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = ms_a - ms_b });
        },
        .time_before => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try time_mod.timeGetMs(recv);
            const ms_b = try time_mod.timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = ms_a < ms_b });
        },
        .time_after => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try time_mod.timeGetMs(recv);
            const ms_b = try time_mod.timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = ms_a > ms_b });
        },
        .time_equal => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try time_mod.timeGetMs(recv);
            const ms_b = try time_mod.timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = ms_a == ms_b });
        },
        .time_is_zero => {
            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try time_mod.timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = ms == 0 });
        },
        .time_since => {
            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try time_mod.timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = time_mod.timeNowMs() - ms });
        },
        .time_until => {
            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try time_mod.timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = ms - time_mod.timeNowMs() });
        },
        .time_add_date => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 4];
            const y_v = vms.vmState().stack[top - 3];
            const m_v = vms.vmState().stack[top - 2];
            const d_v = vms.vmState().stack[top - 1];
            const ms = try time_mod.timeGetMs(recv);
            const y = try vms.valueAsInt(y_v);
            const m = try vms.valueAsInt(m_v);
            const d = try vms.valueAsInt(d_v);
            const out = try time_mod.timeAddDate(ms, @intCast(y), @intCast(m), @intCast(d));
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .re_match => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const result = try regexp_mod.nativeReMatch(pattern_val, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_find => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const result = try regexp_mod.nativeReFind(pattern_val, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_find_all => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const result = try regexp_mod.nativeReFindAll(pattern_val, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_replace => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 3];
            const s_val = vms.vmState().stack[top - 2];
            const repl_val = vms.vmState().stack[top - 1];
            const result = try regexp_mod.nativeReReplace(pattern_val, s_val, repl_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_split => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const result = try regexp_mod.nativeReSplit(pattern_val, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_compile => {
            if (argc != nf.arity) return error.ArityMismatch;
            const pattern_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const result = try regexp_mod.nativeReCompile(pattern_val);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_match => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const pattern = try regexp_mod.reGetPattern(recv);
            const result = try regexp_mod.nativeReMatch(.{ .string = pattern }, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_find => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const pattern = try regexp_mod.reGetPattern(recv);
            const result = try regexp_mod.nativeReFind(.{ .string = pattern }, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_find_all => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const pattern = try regexp_mod.reGetPattern(recv);
            const result = try regexp_mod.nativeReFindAll(.{ .string = pattern }, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_replace => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 3];
            const s_val = vms.vmState().stack[top - 2];
            const repl_val = vms.vmState().stack[top - 1];
            const pattern = try regexp_mod.reGetPattern(recv);
            const result = try regexp_mod.nativeReReplace(.{ .string = pattern }, s_val, repl_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_split => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const pattern = try regexp_mod.reGetPattern(recv);
            const result = try regexp_mod.nativeReSplit(.{ .string = pattern }, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .math_clamp => {
            if (argc != nf.arity) return error.ArityMismatch;
            const max = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const min = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            const v = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 3]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @min(@max(v, min), max) });
        },
        .math_sign => {
            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            const sign: f64 = if (n > 0) 1.0 else if (n < 0) -1.0 else 0.0;
            try vms.vmPush(.{ .number = sign });
        },
        .sort_asc => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            var items = try vms.cloneArraySlice(arr_obj);
            const n = items.len;
            if (n > 1) {
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    const key = items[i];
                    var j: usize = i;
                    while (j > 0 and try valueGreaterThan(items[j - 1], key)) : (j -= 1) {
                        items[j] = items[j - 1];
                    }
                    items[j] = key;
                }
            }
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array_managed = items[0..n] };
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .sort_desc => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            var items = try vms.cloneArraySlice(arr_obj);
            const n = items.len;
            if (n > 1) {
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    const key = items[i];
                    var j: usize = i;
                    while (j > 0 and try valueLessThan(items[j - 1], key)) : (j -= 1) {
                        items[j] = items[j - 1];
                    }
                    items[j] = key;
                }
            }
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array_managed = items[0..n] };
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .sort_by => {
            if (argc != nf.arity) return error.ArityMismatch;
            const fn_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            var items = try vms.cloneArraySlice(arr_obj);
            const n = items.len;
            if (n > 1) {
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    const key = items[i];
                    var j: usize = i;
                    while (j > 0) : (j -= 1) {
                        const cmp = try vm.callFunction(fn_val, &.{ items[j - 1], key });
                        const less = if (cmp == .number) cmp.number < 0 else cmp.isTruthy();
                        if (less) break;
                        items[j] = items[j - 1];
                    }
                    items[j] = key;
                }
            }
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array_managed = items[0..n] };
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_filter => {
            if (argc != nf.arity) return error.ArityMismatch;
            const fn_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            var count: usize = 0;
            for (items) |item| {
                const ok = try vm.callFunction(fn_val, &.{item});
                if (ok.isTruthy()) count += 1;
            }
            if (count > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, count);
                var idx: usize = 0;
                for (items) |item| {
                    const ok = try vm.callFunction(fn_val, &.{item});
                    if (ok.isTruthy()) {
                        out[idx] = item;
                        idx += 1;
                    }
                }
                out_obj.* = .{ .array_managed = out[0..count] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_map => {
            if (argc != nf.arity) return error.ArityMismatch;
            const fn_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            if (items.len > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, items.len);
                for (items, 0..) |item, i| {
                    out[i] = try vm.callFunction(fn_val, &.{item});
                }
                out_obj.* = .{ .array_managed = out[0..items.len] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_reduce => {
            if (argc != nf.arity) return error.ArityMismatch;
            const init_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const fn_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 3];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            var acc = init_val;
            try vms.pushTempRoot(acc);
            defer vms.popTempRoot();
            for (items) |item| {
                acc = try vm.callFunction(fn_val, &.{ acc, item });
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(acc);
        },
        .array_slice => {
            if (argc != nf.arity) return error.ArityMismatch;
            const to_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const from_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 3];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            const from = try vms.valueAsInt(from_val);
            const to = try vms.valueAsInt(to_val);
            if (from < 0 or to > @as(i64, @intCast(items.len)) or from > to) return error.IndexOutOfBounds;
            const from_u: usize = @intCast(from);
            const to_u: usize = @intCast(to);
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            const slice_len = to_u - from_u;
            if (slice_len > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, slice_len);
                @memcpy(out[0..slice_len], items[from_u..to_u]);
                out_obj.* = .{ .array_managed = out[0..slice_len] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_zip => {
            if (argc != nf.arity) return error.ArityMismatch;
            const b_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const a_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            if (a_val != .object or b_val != .object) return error.TypeError;
            const a_obj = a_val.object;
            const b_obj = b_val.object;
            if (!vms.isArrayObject(a_obj) or !vms.isArrayObject(b_obj)) return error.TypeError;
            const a_items = vms.asArraySlice(a_obj);
            const b_items = vms.asArraySlice(b_obj);
            const pair_count = @min(a_items.len, b_items.len);
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            if (pair_count > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, pair_count);
                for (0..pair_count) |i| {
                    const pair = try vmgc.vmAllocObject();
                    const pair_items = try vmgc.vmAllocManagedSlice(Value, 2);
                    pair_items[0] = a_items[i];
                    pair_items[1] = b_items[i];
                    pair.* = .{ .array_managed = pair_items[0..2] };
                    out[i] = .{ .object = pair };
                }
                out_obj.* = .{ .array_managed = out[0..pair_count] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_flat => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            var total: usize = 0;
            for (items) |item| {
                if (item == .object and vms.isArrayObject(item.object)) {
                    total += vms.asArraySlice(item.object).len;
                } else {
                    total += 1;
                }
            }
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            if (total > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, total);
                var idx: usize = 0;
                for (items) |item| {
                    if (item == .object and vms.isArrayObject(item.object)) {
                        const sub = vms.asArraySlice(item.object);
                        @memcpy(out[idx..][0..sub.len], sub);
                        idx += sub.len;
                    } else {
                        out[idx] = item;
                        idx += 1;
                    }
                }
                out_obj.* = .{ .array_managed = out[0..total] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
    }
}
