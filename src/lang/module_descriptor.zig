const std = @import("std");
const common = @import("common.zig");
const ct = @import("compiler_types.zig");
const value_mod = @import("value.zig");
const NativeFnId = @import("native/native_ids.zig").NativeFnId;

pub const ModuleTypeInfo = struct {
    kind: ct.ExportTypeKind,
    qualified_name: []const u8,
};

pub const ArgQualifiedName = "@mod:std.Arg";
pub const TimeQualifiedName = "@std.time.obj";
pub const RegexpQualifiedName = "@std.regexp.obj";
pub const JsonValueQualifiedName = "@std.json.Value";

pub const NativeMethod = struct {
    name: []const u8,
    global_name: []const u8,
    id: NativeFnId,
    arity: u8,
};

pub const StdExportKind = enum { namespace, function, value };

pub const StdTopLevelMember = enum {
    io,
    fmt,
    core,
    conv,
    math,
    rand,
    string,
    json,
    template,
    time,
    hex,
    base64,
    regexp,
    sort,
    array,
    bytes,
    crypto,
    arg_type,
    time_type,
    regexp_type,
    json_value_type,
};

pub const StdNamespaceExport = struct {
    name: []const u8,
    kind: StdExportKind,
    native_id: ?NativeFnId = null,
    arity: u8 = 0,
    int_value: i64 = 0,
    float_value: f64 = 0,
    is_type_object: bool = false,
    top_level_member: ?StdTopLevelMember = null,
};

pub const stdExports = [_]StdNamespaceExport{
    .{ .name = "io", .kind = .namespace, .top_level_member = .io },
    .{ .name = "fmt", .kind = .namespace, .top_level_member = .fmt },
    .{ .name = "core", .kind = .namespace, .top_level_member = .core },
    .{ .name = "conv", .kind = .namespace, .top_level_member = .conv },
    .{ .name = "math", .kind = .namespace, .top_level_member = .math },
    .{ .name = "rand", .kind = .namespace, .top_level_member = .rand },
    .{ .name = "string", .kind = .namespace, .top_level_member = .string },
    .{ .name = "json", .kind = .namespace, .top_level_member = .json },
    .{ .name = "template", .kind = .namespace, .top_level_member = .template },
    .{ .name = "time", .kind = .namespace, .top_level_member = .time },
    .{ .name = "hex", .kind = .namespace, .top_level_member = .hex },
    .{ .name = "base64", .kind = .namespace, .top_level_member = .base64 },
    .{ .name = "regexp", .kind = .namespace, .top_level_member = .regexp },
    .{ .name = "sort", .kind = .namespace, .top_level_member = .sort },
    .{ .name = "array", .kind = .namespace, .top_level_member = .array },
    .{ .name = "bytes", .kind = .namespace, .top_level_member = .bytes },
    .{ .name = "crypto", .kind = .namespace, .top_level_member = .crypto },
    .{ .name = "Arg", .kind = .value, .is_type_object = true, .top_level_member = .arg_type },
    .{ .name = "Time", .kind = .value, .is_type_object = true, .top_level_member = .time_type },
    .{ .name = "Regexp", .kind = .value, .is_type_object = true, .top_level_member = .regexp_type },
    .{ .name = "JSONValue", .kind = .value, .is_type_object = true, .top_level_member = .json_value_type },
};

pub const timeExports = [_]StdNamespaceExport{
    .{ .name = "now", .kind = .function, .native_id = .time_now, .arity = 0 },
    .{ .name = "from_unix", .kind = .function, .native_id = .time_from_unix, .arity = 1 },
    .{ .name = "from_unix_ms", .kind = .function, .native_id = .time_from_unix_ms, .arity = 1 },
    .{ .name = "parse", .kind = .function, .native_id = .time_parse, .arity = 2 },
    .{ .name = "since", .kind = .function, .native_id = .time_since, .arity = 1 },
    .{ .name = "until", .kind = .function, .native_id = .time_until, .arity = 1 },
    .{ .name = "parse_duration", .kind = .function, .native_id = .time_parse_duration, .arity = 1 },
    .{ .name = "sleep", .kind = .function, .native_id = .time_sleep, .arity = 1 },
    .{ .name = "ms", .kind = .value, .int_value = 1 },
    .{ .name = "second", .kind = .value, .int_value = 1_000 },
    .{ .name = "minute", .kind = .value, .int_value = 60_000 },
    .{ .name = "hour", .kind = .value, .int_value = 3_600_000 },
    .{ .name = "day", .kind = .value, .int_value = 86_400_000 },
};

pub const fmtExports = [_]StdNamespaceExport{
    .{ .name = "format", .kind = .function, .native_id = .io_sprintf, .arity = 255 },
    .{ .name = "stringify", .kind = .function, .native_id = .fmt_stringify, .arity = 1 },
};

pub const ioExports = [_]StdNamespaceExport{
    .{ .name = "println", .kind = .function, .native_id = .io_println, .arity = 255 },
    .{ .name = "printf", .kind = .function, .native_id = .io_printf, .arity = 255 },
    .{ .name = "print", .kind = .function, .native_id = .io_print, .arity = 255 },
    .{ .name = "eprint", .kind = .function, .native_id = .io_eprint, .arity = 255 },
    .{ .name = "eprintf", .kind = .function, .native_id = .io_eprintf, .arity = 255 },
    .{ .name = "eprintln", .kind = .function, .native_id = .io_eprintln, .arity = 255 },
    .{ .name = "read", .kind = .function, .native_id = .io_read, .arity = 0 },
    .{ .name = "readline", .kind = .function, .native_id = .io_readline, .arity = 0 },
};

pub const convExports = [_]StdNamespaceExport{
    .{ .name = "to_int", .kind = .function, .native_id = .conv_to_int, .arity = 1 },
    .{ .name = "to_float", .kind = .function, .native_id = .conv_to_float, .arity = 1 },
    .{ .name = "to_bool", .kind = .function, .native_id = .conv_to_bool, .arity = 1 },
    .{ .name = "to_string", .kind = .function, .native_id = .conv_to_string, .arity = 1 },
};

pub const mathExports = [_]StdNamespaceExport{
    .{ .name = "abs", .kind = .function, .native_id = .math_abs, .arity = 1 },
    .{ .name = "sqrt", .kind = .function, .native_id = .math_sqrt, .arity = 1 },
    .{ .name = "floor", .kind = .function, .native_id = .math_floor, .arity = 1 },
    .{ .name = "ceil", .kind = .function, .native_id = .math_ceil, .arity = 1 },
    .{ .name = "round", .kind = .function, .native_id = .math_round, .arity = 1 },
    .{ .name = "sin", .kind = .function, .native_id = .math_sin, .arity = 1 },
    .{ .name = "cos", .kind = .function, .native_id = .math_cos, .arity = 1 },
    .{ .name = "tan", .kind = .function, .native_id = .math_tan, .arity = 1 },
    .{ .name = "log", .kind = .function, .native_id = .math_log, .arity = 1 },
    .{ .name = "log2", .kind = .function, .native_id = .math_log2, .arity = 1 },
    .{ .name = "log10", .kind = .function, .native_id = .math_log10, .arity = 1 },
    .{ .name = "pow", .kind = .function, .native_id = .math_pow, .arity = 2 },
    .{ .name = "min", .kind = .function, .native_id = .math_min, .arity = 2 },
    .{ .name = "max", .kind = .function, .native_id = .math_max, .arity = 2 },
    .{ .name = "acos", .kind = .function, .native_id = .math_acos, .arity = 1 },
    .{ .name = "asin", .kind = .function, .native_id = .math_asin, .arity = 1 },
    .{ .name = "atan", .kind = .function, .native_id = .math_atan, .arity = 1 },
    .{ .name = "atan2", .kind = .function, .native_id = .math_atan2, .arity = 2 },
    .{ .name = "cosh", .kind = .function, .native_id = .math_cosh, .arity = 1 },
    .{ .name = "sinh", .kind = .function, .native_id = .math_sinh, .arity = 1 },
    .{ .name = "tanh", .kind = .function, .native_id = .math_tanh, .arity = 1 },
    .{ .name = "exp", .kind = .function, .native_id = .math_exp, .arity = 1 },
    .{ .name = "exp2", .kind = .function, .native_id = .math_exp2, .arity = 1 },
    .{ .name = "trunc", .kind = .function, .native_id = .math_trunc, .arity = 1 },
    .{ .name = "cbrt", .kind = .function, .native_id = .math_cbrt, .arity = 1 },
    .{ .name = "hypot", .kind = .function, .native_id = .math_hypot, .arity = 2 },
    .{ .name = "mod", .kind = .function, .native_id = .math_mod, .arity = 2 },
    .{ .name = "nan", .kind = .function, .native_id = .math_nan, .arity = 0 },
    .{ .name = "is_nan", .kind = .function, .native_id = .math_is_nan, .arity = 1 },
    .{ .name = "is_inf", .kind = .function, .native_id = .math_is_inf, .arity = 2 },
    .{ .name = "pi", .kind = .value, .float_value = std.math.pi },
    .{ .name = "e", .kind = .value, .float_value = std.math.e },
    .{ .name = "phi", .kind = .value, .float_value = 1.618033988749895 },
    .{ .name = "clamp", .kind = .function, .native_id = .math_clamp, .arity = 3 },
    .{ .name = "sign", .kind = .function, .native_id = .math_sign, .arity = 1 },
    .{ .name = "inf", .kind = .value, .float_value = std.math.inf(f64) },
};

pub const stringExports = [_]StdNamespaceExport{
    .{ .name = "split", .kind = .function, .native_id = .str_split, .arity = 2 },
    .{ .name = "join", .kind = .function, .native_id = .str_join, .arity = 2 },
    .{ .name = "trim", .kind = .function, .native_id = .str_trim, .arity = 1 },
    .{ .name = "upper", .kind = .function, .native_id = .str_upper, .arity = 1 },
    .{ .name = "lower", .kind = .function, .native_id = .str_lower, .arity = 1 },
    .{ .name = "contains", .kind = .function, .native_id = .str_contains, .arity = 2 },
    .{ .name = "starts_with", .kind = .function, .native_id = .str_starts_with, .arity = 2 },
    .{ .name = "ends_with", .kind = .function, .native_id = .str_ends_with, .arity = 2 },
    .{ .name = "index_of", .kind = .function, .native_id = .str_index_of, .arity = 2 },
    .{ .name = "replace", .kind = .function, .native_id = .str_replace, .arity = 3 },
    .{ .name = "last_index_of", .kind = .function, .native_id = .str_last_index_of, .arity = 2 },
    .{ .name = "repeat", .kind = .function, .native_id = .str_repeat, .arity = 2 },
    .{ .name = "split_once", .kind = .function, .native_id = .str_split_once, .arity = 2 },
    .{ .name = "builder", .kind = .function, .native_id = .str_builder_new, .arity = 0 },
    .{ .name = "count", .kind = .function, .native_id = .str_count, .arity = 2 },
    .{ .name = "fields", .kind = .function, .native_id = .str_fields, .arity = 1 },
    .{ .name = "pad_left", .kind = .function, .native_id = .str_pad_left, .arity = 3 },
    .{ .name = "pad_right", .kind = .function, .native_id = .str_pad_right, .arity = 3 },
    .{ .name = "equal_fold", .kind = .function, .native_id = .str_equal_fold, .arity = 2 },
    .{ .name = "contains_any", .kind = .function, .native_id = .str_contains_any, .arity = 2 },
    .{ .name = "trim_left", .kind = .function, .native_id = .str_trim_left, .arity = 2 },
    .{ .name = "trim_right", .kind = .function, .native_id = .str_trim_right, .arity = 2 },
    .{ .name = "trim_prefix", .kind = .function, .native_id = .str_trim_prefix, .arity = 2 },
    .{ .name = "trim_suffix", .kind = .function, .native_id = .str_trim_suffix, .arity = 2 },
    .{ .name = "split_n", .kind = .function, .native_id = .str_split_n, .arity = 3 },
};

pub const bytesExports = [_]StdNamespaceExport{
    .{ .name = "u8", .kind = .function, .native_id = .bytes_u8, .arity = 1 },
    .{ .name = "pack", .kind = .function, .native_id = .bytes_pack, .arity = 1 },
    .{ .name = "repeat", .kind = .function, .native_id = .bytes_repeat, .arity = 2 },
    .{ .name = "unpack", .kind = .function, .native_id = .bytes_unpack, .arity = 1 },
    .{ .name = "at", .kind = .function, .native_id = .bytes_at, .arity = 2 },
    .{ .name = "slice", .kind = .function, .native_id = .bytes_slice, .arity = 3 },
    .{ .name = "len", .kind = .function, .native_id = .bytes_len, .arity = 1 },
    .{ .name = "u16be", .kind = .function, .native_id = .bytes_u16be, .arity = 1 },
    .{ .name = "u32be", .kind = .function, .native_id = .bytes_u32be, .arity = 1 },
    .{ .name = "u64be", .kind = .function, .native_id = .bytes_u64be, .arity = 1 },
    .{ .name = "u16le", .kind = .function, .native_id = .bytes_u16le, .arity = 1 },
    .{ .name = "u32le", .kind = .function, .native_id = .bytes_u32le, .arity = 1 },
    .{ .name = "u64le", .kind = .function, .native_id = .bytes_u64le, .arity = 1 },
    .{ .name = "u16be_at", .kind = .function, .native_id = .bytes_u16be_at, .arity = 2 },
    .{ .name = "u32be_at", .kind = .function, .native_id = .bytes_u32be_at, .arity = 2 },
    .{ .name = "u64be_at", .kind = .function, .native_id = .bytes_u64be_at, .arity = 2 },
    .{ .name = "u16le_at", .kind = .function, .native_id = .bytes_u16le_at, .arity = 2 },
    .{ .name = "u32le_at", .kind = .function, .native_id = .bytes_u32le_at, .arity = 2 },
    .{ .name = "u64le_at", .kind = .function, .native_id = .bytes_u64le_at, .arity = 2 },
    .{ .name = "index_of", .kind = .function, .native_id = .bytes_index_of, .arity = 2 },
    .{ .name = "contains", .kind = .function, .native_id = .bytes_contains, .arity = 2 },
    .{ .name = "starts_with", .kind = .function, .native_id = .bytes_starts_with, .arity = 2 },
    .{ .name = "ends_with", .kind = .function, .native_id = .bytes_ends_with, .arity = 2 },
    .{ .name = "count", .kind = .function, .native_id = .bytes_count, .arity = 2 },
    .{ .name = "replace", .kind = .function, .native_id = .bytes_replace, .arity = 3 },
    .{ .name = "f32be", .kind = .function, .native_id = .bytes_f32be, .arity = 1 },
    .{ .name = "f32le", .kind = .function, .native_id = .bytes_f32le, .arity = 1 },
    .{ .name = "f64be", .kind = .function, .native_id = .bytes_f64be, .arity = 1 },
    .{ .name = "f64le", .kind = .function, .native_id = .bytes_f64le, .arity = 1 },
    .{ .name = "f32be_at", .kind = .function, .native_id = .bytes_f32be_at, .arity = 2 },
    .{ .name = "f32le_at", .kind = .function, .native_id = .bytes_f32le_at, .arity = 2 },
    .{ .name = "f64be_at", .kind = .function, .native_id = .bytes_f64be_at, .arity = 2 },
    .{ .name = "f64le_at", .kind = .function, .native_id = .bytes_f64le_at, .arity = 2 },
};

pub const hexExports = [_]StdNamespaceExport{
    .{ .name = "encode", .kind = .function, .native_id = .hex_encode, .arity = 1 },
    .{ .name = "decode", .kind = .function, .native_id = .hex_decode, .arity = 1 },
};

pub const base64Exports = [_]StdNamespaceExport{
    .{ .name = "encode", .kind = .function, .native_id = .base64_encode, .arity = 1 },
    .{ .name = "decode", .kind = .function, .native_id = .base64_decode, .arity = 1 },
    .{ .name = "url_encode", .kind = .function, .native_id = .base64_url_encode, .arity = 1 },
    .{ .name = "url_decode", .kind = .function, .native_id = .base64_url_decode, .arity = 1 },
};

pub const sortExports = [_]StdNamespaceExport{
    .{ .name = "asc", .kind = .function, .native_id = .sort_asc, .arity = 1 },
    .{ .name = "desc", .kind = .function, .native_id = .sort_desc, .arity = 1 },
    .{ .name = "by", .kind = .function, .native_id = .sort_by, .arity = 2 },
};

pub const arrayExports = [_]StdNamespaceExport{
    .{ .name = "filter", .kind = .function, .native_id = .array_filter, .arity = 2 },
    .{ .name = "map", .kind = .function, .native_id = .array_map, .arity = 2 },
    .{ .name = "reduce", .kind = .function, .native_id = .array_reduce, .arity = 3 },
    .{ .name = "slice", .kind = .function, .native_id = .array_slice, .arity = 3 },
    .{ .name = "zip", .kind = .function, .native_id = .array_zip, .arity = 2 },
    .{ .name = "flat", .kind = .function, .native_id = .array_flat, .arity = 1 },
    .{ .name = "find", .kind = .function, .native_id = .array_find, .arity = 2 },
    .{ .name = "find_index", .kind = .function, .native_id = .array_find_index, .arity = 2 },
    .{ .name = "all", .kind = .function, .native_id = .array_all, .arity = 2 },
    .{ .name = "any", .kind = .function, .native_id = .array_any, .arity = 2 },
    .{ .name = "chunk", .kind = .function, .native_id = .array_chunk, .arity = 2 },
};

pub const randExports = [_]StdNamespaceExport{
    .{ .name = "float", .kind = .function, .native_id = .rand_float, .arity = 0 },
    .{ .name = "intn", .kind = .function, .native_id = .rand_intn, .arity = 1 },
    .{ .name = "between", .kind = .function, .native_id = .rand_between, .arity = 2 },
    .{ .name = "seed", .kind = .function, .native_id = .rand_seed, .arity = 1 },
    .{ .name = "choice", .kind = .function, .native_id = .rand_choice, .arity = 1 },
    .{ .name = "perm", .kind = .function, .native_id = .rand_perm, .arity = 1 },
    .{ .name = "norm_float", .kind = .function, .native_id = .rand_norm_float, .arity = 0 },
};

pub const cryptoExports = [_]StdNamespaceExport{
    .{ .name = "sha256", .kind = .function, .native_id = .crypto_sha256, .arity = 1 },
    .{ .name = "sha512", .kind = .function, .native_id = .crypto_sha512, .arity = 1 },
    .{ .name = "blake3", .kind = .function, .native_id = .crypto_blake3, .arity = 1 },
    .{ .name = "md5", .kind = .function, .native_id = .crypto_md5, .arity = 1 },
    .{ .name = "sha1", .kind = .function, .native_id = .crypto_sha1, .arity = 1 },
    .{ .name = "hmac_sha256", .kind = .function, .native_id = .crypto_hmac_sha256, .arity = 2 },
    .{ .name = "hmac_sha512", .kind = .function, .native_id = .crypto_hmac_sha512, .arity = 2 },
    .{ .name = "aes_gcm_seal", .kind = .function, .native_id = .crypto_aes_gcm_seal, .arity = 3 },
    .{ .name = "aes_gcm_open", .kind = .function, .native_id = .crypto_aes_gcm_open, .arity = 3 },
    .{ .name = "chacha20poly1305_seal", .kind = .function, .native_id = .crypto_chacha20poly1305_seal, .arity = 3 },
    .{ .name = "chacha20poly1305_open", .kind = .function, .native_id = .crypto_chacha20poly1305_open, .arity = 3 },
    .{ .name = "constant_time_equal", .kind = .function, .native_id = .crypto_constant_time_equal, .arity = 2 },
    .{ .name = "rand_bytes", .kind = .function, .native_id = .crypto_rand_bytes, .arity = 1 },
    .{ .name = "argon2id", .kind = .function, .native_id = .crypto_argon2id, .arity = 6 },
    .{ .name = "bcrypt_hash", .kind = .function, .native_id = .crypto_bcrypt_hash, .arity = 2 },
    .{ .name = "bcrypt_verify", .kind = .function, .native_id = .crypto_bcrypt_verify, .arity = 2 },
    .{ .name = "hkdf_sha256", .kind = .function, .native_id = .crypto_hkdf_sha256, .arity = 4 },
    .{ .name = "xchacha20poly1305_seal", .kind = .function, .native_id = .crypto_xchacha20poly1305_seal, .arity = 3 },
    .{ .name = "xchacha20poly1305_open", .kind = .function, .native_id = .crypto_xchacha20poly1305_open, .arity = 3 },
    .{ .name = "ed25519_sign", .kind = .function, .native_id = .crypto_ed25519_sign, .arity = 2 },
    .{ .name = "ed25519_verify", .kind = .function, .native_id = .crypto_ed25519_verify, .arity = 3 },
    .{ .name = "x25519", .kind = .function, .native_id = .crypto_x25519, .arity = 2 },
};

pub const templateExports = [_]StdNamespaceExport{
    .{ .name = "parse", .kind = .function, .native_id = .template_parse, .arity = 1 },
    .{ .name = "execute", .kind = .function, .native_id = .template_execute, .arity = 2 },
    .{ .name = "add_func", .kind = .function, .native_id = .template_add_func, .arity = 3 },
    .{ .name = "render", .kind = .function, .native_id = .template_render, .arity = 2 },
    .{ .name = "valid", .kind = .function, .native_id = .template_valid, .arity = 1 },
};

pub const coreExports = [_]StdNamespaceExport{
    .{ .name = "len", .kind = .function, .native_id = .core_len, .arity = 1 }, .{ .name = "append", .kind = .function, .native_id = .core_append, .arity = 255 }, .{ .name = "error", .kind = .function, .native_id = .core_error, .arity = 1 }, .{ .name = "is_error", .kind = .function, .native_id = .core_is_error, .arity = 1 }, .{ .name = "type_of", .kind = .function, .native_id = .core_type_of, .arity = 1 }, .{ .name = "is_int", .kind = .function, .native_id = .core_is_int, .arity = 1 }, .{ .name = "is_float", .kind = .function, .native_id = .core_is_float, .arity = 1 }, .{ .name = "is_string", .kind = .function, .native_id = .core_is_string, .arity = 1 }, .{ .name = "is_array", .kind = .function, .native_id = .core_is_array, .arity = 1 }, .{ .name = "is_map", .kind = .function, .native_id = .core_is_map, .arity = 1 }, .{ .name = "is_struct", .kind = .function, .native_id = .core_is_struct, .arity = 1 }, .{ .name = "is_null", .kind = .function, .native_id = .core_is_null, .arity = 1 }, .{ .name = "deep_equal", .kind = .function, .native_id = .core_deep_equal, .arity = 2 }, .{ .name = "clone", .kind = .function, .native_id = .core_clone, .arity = 1 }, .{ .name = "gc", .kind = .function, .native_id = .core_gc, .arity = 0 }, .{ .name = "gc_live_objects", .kind = .function, .native_id = .core_gc_live_objects, .arity = 0 }, .{ .name = "gc_stats", .kind = .function, .native_id = .core_gc_stats, .arity = 0 }, .{ .name = "bytelen", .kind = .function, .native_id = .core_bytelen, .arity = 1 }, .{ .name = "gc_stats_ext", .kind = .function, .native_id = .core_gc_stats_ext, .arity = 0 }, .{ .name = "delete", .kind = .function, .native_id = .core_delete, .arity = 2 }, .{ .name = "has", .kind = .function, .native_id = .core_has, .arity = 2 }, .{ .name = "keys", .kind = .function, .native_id = .core_keys, .arity = 1 }, .{ .name = "values", .kind = .function, .native_id = .core_values, .arity = 1 }, .{ .name = "contains", .kind = .function, .native_id = .core_contains, .arity = 2 }, .{ .name = "remove", .kind = .function, .native_id = .core_remove, .arity = 2 }, .{ .name = "recover", .kind = .function, .native_id = .core_recover, .arity = 0 },
};

pub const regexpExports = [_]StdNamespaceExport{
    .{ .name = "match", .kind = .function, .native_id = .re_match, .arity = 2 },
    .{ .name = "find", .kind = .function, .native_id = .re_find, .arity = 2 },
    .{ .name = "find_all", .kind = .function, .native_id = .re_find_all, .arity = 2 },
    .{ .name = "replace", .kind = .function, .native_id = .re_replace, .arity = 3 },
    .{ .name = "split", .kind = .function, .native_id = .re_split, .arity = 2 },
    .{ .name = "compile", .kind = .function, .native_id = .re_compile, .arity = 1 },
};

pub const jsonExports = [_]StdNamespaceExport{
    .{ .name = "parse", .kind = .function, .native_id = .json_parse, .arity = 1 },
    .{ .name = "parse_value", .kind = .function, .native_id = .json_parse_value, .arity = 1 },
    .{ .name = "stringify", .kind = .function, .native_id = .json_stringify, .arity = 1 },
    .{ .name = "valid", .kind = .function, .native_id = .json_valid, .arity = 1 },
    .{ .name = "indent", .kind = .function, .native_id = .json_indent, .arity = 2 },
    .{ .name = "Value", .kind = .value, .is_type_object = true },
};

const NativeNamedType = struct {
    module_path: []const u8,
    name: []const u8,
    qualified_name: []const u8,
    base: value_mod.NamedTypeBase,
    methods: []const NativeMethod = &.{},
};

pub const timeMethods = [_]NativeMethod{
    .{ .name = "unix", .global_name = "@std.time.obj.unix", .id = .time_unix, .arity = 1 },
    .{ .name = "unix_ms", .global_name = "@std.time.obj.unix_ms", .id = .time_unix_ms, .arity = 1 },
    .{ .name = "parts", .global_name = "@std.time.obj.parts", .id = .time_parts, .arity = 1 },
    .{ .name = "format", .global_name = "@std.time.obj.format", .id = .time_format, .arity = 2 },
    .{ .name = "add_ms", .global_name = "@std.time.obj.add_ms", .id = .time_add_ms, .arity = 2 },
    .{ .name = "add_s", .global_name = "@std.time.obj.add_s", .id = .time_add_s, .arity = 2 },
    .{ .name = "add_m", .global_name = "@std.time.obj.add_m", .id = .time_add_m, .arity = 2 },
    .{ .name = "add_h", .global_name = "@std.time.obj.add_h", .id = .time_add_h, .arity = 2 },
    .{ .name = "sub", .global_name = "@std.time.obj.sub", .id = .time_sub, .arity = 2 },
    .{ .name = "before", .global_name = "@std.time.obj.before", .id = .time_before, .arity = 2 },
    .{ .name = "after", .global_name = "@std.time.obj.after", .id = .time_after, .arity = 2 },
    .{ .name = "equal", .global_name = "@std.time.obj.equal", .id = .time_equal, .arity = 2 },
    .{ .name = "is_zero", .global_name = "@std.time.obj.is_zero", .id = .time_is_zero, .arity = 1 },
    .{ .name = "since", .global_name = "@std.time.obj.since", .id = .time_since, .arity = 1 },
    .{ .name = "until", .global_name = "@std.time.obj.until", .id = .time_until, .arity = 1 },
    .{ .name = "add_date", .global_name = "@std.time.obj.add_date", .id = .time_add_date, .arity = 4 },
    .{ .name = "iso_week", .global_name = "@std.time.obj.iso_week", .id = .time_iso_week, .arity = 1 },
};

pub const regexpMethods = [_]NativeMethod{
    .{ .name = "match", .global_name = "@std.regexp.obj.match", .id = .re_obj_match, .arity = 2 },
    .{ .name = "find", .global_name = "@std.regexp.obj.find", .id = .re_obj_find, .arity = 2 },
    .{ .name = "find_all", .global_name = "@std.regexp.obj.find_all", .id = .re_obj_find_all, .arity = 2 },
    .{ .name = "replace", .global_name = "@std.regexp.obj.replace", .id = .re_obj_replace, .arity = 3 },
    .{ .name = "split", .global_name = "@std.regexp.obj.split", .id = .re_obj_split, .arity = 2 },
};

const named_types = [_]NativeNamedType{
    .{
        .module_path = "std",
        .name = "Time",
        .qualified_name = TimeQualifiedName,
        .base = .int,
        .methods = &timeMethods,
    },
    .{
        .module_path = "std",
        .name = "Regexp",
        .qualified_name = RegexpQualifiedName,
        .base = .string,
        .methods = &regexpMethods,
    },
};

const variants = [_]ModuleTypeInfo{
    .{ .kind = .variant_t, .qualified_name = ArgQualifiedName },
    .{ .kind = .variant_t, .qualified_name = JsonValueQualifiedName },
};

pub fn resolveType(module_path: []const u8, name: []const u8) ?ModuleTypeInfo {
    for (named_types) |typ| {
        if (common.streq(module_path, typ.module_path) and common.streq(name, typ.name)) {
            return .{ .kind = .named_t, .qualified_name = typ.qualified_name };
        }
    }
    if (common.streq(module_path, "std") and common.streq(name, "Arg")) return variants[0];
    if (common.streq(module_path, "std") and common.streq(name, "JSONValue")) return variants[1];
    return null;
}

fn exportsForStdNamespace(namespace: []const u8) ?[]const StdNamespaceExport {
    return if (namespace.len == 0)
        &stdExports
    else if (common.streq(namespace, "time"))
        &timeExports
    else if (common.streq(namespace, "fmt"))
        &fmtExports
    else if (common.streq(namespace, "io"))
        &ioExports
    else if (common.streq(namespace, "conv"))
        &convExports
    else if (common.streq(namespace, "math"))
        &mathExports
    else if (common.streq(namespace, "string"))
        &stringExports
    else if (common.streq(namespace, "bytes"))
        &bytesExports
    else if (common.streq(namespace, "hex"))
        &hexExports
    else if (common.streq(namespace, "base64"))
        &base64Exports
    else if (common.streq(namespace, "sort"))
        &sortExports
    else if (common.streq(namespace, "array"))
        &arrayExports
    else if (common.streq(namespace, "rand"))
        &randExports
    else if (common.streq(namespace, "crypto"))
        &cryptoExports
    else if (common.streq(namespace, "template"))
        &templateExports
    else if (common.streq(namespace, "core"))
        &coreExports
    else if (common.streq(namespace, "regexp"))
        &regexpExports
    else if (common.streq(namespace, "json"))
        &jsonExports
    else
        null;
}

pub fn lookupStdNamespaceExport(namespace: []const u8, name: []const u8) ?StdExportKind {
    const exports = exportsForStdNamespace(namespace) orelse return null;
    for (exports) |entry| {
        if (common.streq(entry.name, name)) return entry.kind;
    }
    return null;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    var buf: [32 + 1][32 + 1]usize = undefined;
    const na = @min(a.len, 32);
    const nb = @min(b.len, 32);
    for (0..na + 1) |i| buf[i][0] = i;
    for (0..nb + 1) |j| buf[0][j] = j;
    for (1..na + 1) |i| {
        for (1..nb + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            buf[i][j] = @min(@min(buf[i - 1][j] + 1, buf[i][j - 1] + 1), buf[i - 1][j - 1] + cost);
        }
    }
    return buf[na][nb];
}

pub fn closestStdNamespaceExport(namespace: []const u8, name: []const u8) ?[]const u8 {
    const exports = exportsForStdNamespace(namespace) orelse return null;
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
    for (exports) |entry| {
        const distance = editDistance(entry.name, name);
        if (distance < best_dist) {
            best_dist = distance;
            best = entry.name;
        }
    }
    return best;
}

pub fn seedCompilerRegistry(registry: *ct.TypeRegistry) !void {
    for (named_types) |typ| {
        if (!registry.hasNamedType(typ.qualified_name)) {
            try registry.addNamedType(.{ .name = typ.qualified_name, .base = typ.base });
        }
        for (typ.methods) |method| {
            if (!registry.hasGlobalFunc(method.global_name)) {
                try registry.addGlobalFunc(method.global_name);
            }
        }
    }
}

test "std Time resolves to its runtime type identity" {
    const typ = resolveType("std", "Time") orelse return error.NotFound;
    try std.testing.expectEqual(ct.ExportTypeKind.named_t, typ.kind);
    try std.testing.expectEqualStrings(TimeQualifiedName, typ.qualified_name);
}

test "std Time method descriptor exposes the runtime dispatch table" {
    try std.testing.expectEqual(@as(usize, 17), timeMethods.len);
    try std.testing.expectEqualStrings("add_ms", timeMethods[4].name);
}

test "std regexp descriptor exposes the runtime namespace table" {
    try std.testing.expectEqual(@as(usize, 6), regexpExports.len);
    try std.testing.expectEqualStrings("compile", regexpExports[5].name);
}

test "std io descriptor preserves variadic print functions" {
    try std.testing.expectEqual(@as(usize, 8), ioExports.len);
    try std.testing.expectEqual(@as(u8, 255), ioExports[0].arity);
}

test "std conv descriptor exposes all conversion functions" {
    try std.testing.expectEqual(@as(usize, 4), convExports.len);
    try std.testing.expectEqualStrings("to_string", convExports[3].name);
}

test "std hex descriptor exposes encode and decode" {
    try std.testing.expectEqual(@as(usize, 2), hexExports.len);
}

test "std descriptor resolves top-level namespaces and suggestions" {
    try std.testing.expectEqual(.namespace, lookupStdNamespaceExport("", "time").?);
    try std.testing.expectEqualStrings("time", closestStdNamespaceExport("", "tim").?);
}
