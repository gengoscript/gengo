const common = @import("common.zig");

const EntryKind = enum { namespace, function, value };

const Entry = struct {
    name: []const u8,
    kind: EntryKind,
};

const Namespace = struct {
    name: []const u8,
    entries: []const Entry,
};

fn findEntry(namespace: []const Entry, field: []const u8) ?EntryKind {
    for (namespace) |e| {
        if (common.streq(e.name, field)) return e.kind;
    }
    return null;
}

pub const top_level_entries = [_]Entry{
    .{ .name = "io", .kind = .namespace },
    .{ .name = "fmt", .kind = .namespace },
    .{ .name = "core", .kind = .namespace },
    .{ .name = "conv", .kind = .namespace },
    .{ .name = "math", .kind = .namespace },
    .{ .name = "rand", .kind = .namespace },
    .{ .name = "string", .kind = .namespace },
    .{ .name = "json", .kind = .namespace },
    .{ .name = "template", .kind = .namespace },
    .{ .name = "time", .kind = .namespace },
    .{ .name = "hex", .kind = .namespace },
    .{ .name = "base64", .kind = .namespace },
    .{ .name = "regexp", .kind = .namespace },
    .{ .name = "sort", .kind = .namespace },
    .{ .name = "array", .kind = .namespace },
    .{ .name = "bytes", .kind = .namespace },
    .{ .name = "Time",      .kind = .value },
    .{ .name = "Regexp",    .kind = .value },
    .{ .name = "JSONValue", .kind = .value },
};

pub const fmt_entries = [_]Entry{
    .{ .name = "format",    .kind = .function },
    .{ .name = "stringify", .kind = .function },
};

pub const io_entries = [_]Entry{
    .{ .name = "println",  .kind = .function },
    .{ .name = "printf",   .kind = .function },
    .{ .name = "print",    .kind = .function },
    .{ .name = "eprint",   .kind = .function },
    .{ .name = "eprintf",  .kind = .function },
    .{ .name = "eprintln", .kind = .function },
    .{ .name = "read",     .kind = .function },
    .{ .name = "readline", .kind = .function },
};

pub const core_entries = [_]Entry{
    .{ .name = "len", .kind = .function },
    .{ .name = "append", .kind = .function },
    .{ .name = "error", .kind = .function },
    .{ .name = "is_error", .kind = .function },
    .{ .name = "type_of", .kind = .function },
    .{ .name = "is_int", .kind = .function },
    .{ .name = "is_float", .kind = .function },
    .{ .name = "is_string", .kind = .function },
    .{ .name = "is_array", .kind = .function },
    .{ .name = "is_map", .kind = .function },
    .{ .name = "is_struct", .kind = .function },
    .{ .name = "is_null", .kind = .function },
    .{ .name = "deep_equal", .kind = .function },
    .{ .name = "clone", .kind = .function },
    .{ .name = "gc", .kind = .function },
    .{ .name = "gc_live_objects", .kind = .function },
    .{ .name = "gc_stats", .kind = .function },
    .{ .name = "bytelen", .kind = .function },
    .{ .name = "gc_stats_ext", .kind = .function },
    .{ .name = "delete", .kind = .function },
    .{ .name = "has", .kind = .function },
    .{ .name = "keys", .kind = .function },
    .{ .name = "values", .kind = .function },
    .{ .name = "contains", .kind = .function },
    .{ .name = "remove", .kind = .function },
    .{ .name = "recover", .kind = .function },
};

pub const conv_entries = [_]Entry{
    .{ .name = "to_int", .kind = .function },
    .{ .name = "to_float", .kind = .function },
    .{ .name = "to_bool", .kind = .function },
    .{ .name = "to_string", .kind = .function },
};

pub const math_entries = [_]Entry{
    .{ .name = "abs", .kind = .function },
    .{ .name = "sqrt", .kind = .function },
    .{ .name = "floor", .kind = .function },
    .{ .name = "ceil", .kind = .function },
    .{ .name = "round", .kind = .function },
    .{ .name = "sin", .kind = .function },
    .{ .name = "cos", .kind = .function },
    .{ .name = "tan", .kind = .function },
    .{ .name = "log", .kind = .function },
    .{ .name = "log2", .kind = .function },
    .{ .name = "log10", .kind = .function },
    .{ .name = "pow", .kind = .function },
    .{ .name = "min", .kind = .function },
    .{ .name = "max", .kind = .function },
    .{ .name = "acos", .kind = .function },
    .{ .name = "asin", .kind = .function },
    .{ .name = "atan", .kind = .function },
    .{ .name = "atan2", .kind = .function },
    .{ .name = "cosh", .kind = .function },
    .{ .name = "sinh", .kind = .function },
    .{ .name = "tanh", .kind = .function },
    .{ .name = "exp", .kind = .function },
    .{ .name = "exp2", .kind = .function },
    .{ .name = "trunc", .kind = .function },
    .{ .name = "cbrt", .kind = .function },
    .{ .name = "hypot", .kind = .function },
    .{ .name = "mod", .kind = .function },
    .{ .name = "nan", .kind = .function },
    .{ .name = "is_nan", .kind = .function },
    .{ .name = "is_inf", .kind = .function },
    .{ .name = "pi", .kind = .value },
    .{ .name = "e", .kind = .value },
    .{ .name = "phi", .kind = .value },
    .{ .name = "clamp", .kind = .function },
    .{ .name = "sign", .kind = .function },
    .{ .name = "inf", .kind = .value },
};

pub const rand_entries = [_]Entry{
    .{ .name = "float", .kind = .function },
    .{ .name = "intn", .kind = .function },
    .{ .name = "between", .kind = .function },
    .{ .name = "seed", .kind = .function },
    .{ .name = "choice", .kind = .function },
    .{ .name = "perm", .kind = .function },
    .{ .name = "norm_float", .kind = .function },
};

pub const string_entries = [_]Entry{
    .{ .name = "split", .kind = .function },
    .{ .name = "join", .kind = .function },
    .{ .name = "trim", .kind = .function },
    .{ .name = "upper", .kind = .function },
    .{ .name = "lower", .kind = .function },
    .{ .name = "contains", .kind = .function },
    .{ .name = "starts_with", .kind = .function },
    .{ .name = "ends_with", .kind = .function },
    .{ .name = "index_of", .kind = .function },
    .{ .name = "replace", .kind = .function },
    .{ .name = "last_index_of", .kind = .function },
    .{ .name = "repeat", .kind = .function },
    .{ .name = "split_once", .kind = .function },
    .{ .name = "builder", .kind = .function },
    .{ .name = "count", .kind = .function },
    .{ .name = "fields", .kind = .function },
    .{ .name = "pad_left", .kind = .function },
    .{ .name = "pad_right", .kind = .function },
    .{ .name = "equal_fold", .kind = .function },
    .{ .name = "contains_any", .kind = .function },
};

pub const json_entries = [_]Entry{
    .{ .name = "parse",       .kind = .function },
    .{ .name = "parse_value", .kind = .function },
    .{ .name = "stringify",   .kind = .function },
    .{ .name = "valid",       .kind = .function },
    .{ .name = "Value",       .kind = .value },
};

pub const template_entries = [_]Entry{
    .{ .name = "parse", .kind = .function },
    .{ .name = "execute", .kind = .function },
    .{ .name = "add_func", .kind = .function },
    .{ .name = "render", .kind = .function },
    .{ .name = "valid", .kind = .function },
};

pub const time_entries = [_]Entry{
    .{ .name = "now", .kind = .function },
    .{ .name = "from_unix", .kind = .function },
    .{ .name = "from_unix_ms", .kind = .function },
    .{ .name = "parse", .kind = .function },
    .{ .name = "since", .kind = .function },
    .{ .name = "until", .kind = .function },
    .{ .name = "ms", .kind = .value },
    .{ .name = "second", .kind = .value },
    .{ .name = "minute", .kind = .value },
    .{ .name = "hour", .kind = .value },
    .{ .name = "day", .kind = .value },
};

pub const hex_entries = [_]Entry{
    .{ .name = "encode", .kind = .function },
    .{ .name = "decode", .kind = .function },
};

pub const base64_entries = [_]Entry{
    .{ .name = "encode", .kind = .function },
    .{ .name = "decode", .kind = .function },
    .{ .name = "url_encode", .kind = .function },
    .{ .name = "url_decode", .kind = .function },
};

pub const regexp_entries = [_]Entry{
    .{ .name = "match", .kind = .function },
    .{ .name = "find", .kind = .function },
    .{ .name = "find_all", .kind = .function },
    .{ .name = "replace", .kind = .function },
    .{ .name = "split", .kind = .function },
    .{ .name = "compile", .kind = .function },
};

pub const bytes_entries = [_]Entry{
    .{ .name = "u8",          .kind = .function },
    .{ .name = "pack",        .kind = .function },
    .{ .name = "repeat",      .kind = .function },
    .{ .name = "unpack",      .kind = .function },
    .{ .name = "at",          .kind = .function },
    .{ .name = "slice",       .kind = .function },
    .{ .name = "len",         .kind = .function },
    .{ .name = "u16be",       .kind = .function },
    .{ .name = "u32be",       .kind = .function },
    .{ .name = "u64be",       .kind = .function },
    .{ .name = "u16le",       .kind = .function },
    .{ .name = "u32le",       .kind = .function },
    .{ .name = "u64le",       .kind = .function },
    .{ .name = "u16be_at",    .kind = .function },
    .{ .name = "u32be_at",    .kind = .function },
    .{ .name = "u64be_at",    .kind = .function },
    .{ .name = "u16le_at",    .kind = .function },
    .{ .name = "u32le_at",    .kind = .function },
    .{ .name = "u64le_at",    .kind = .function },
    .{ .name = "index_of",    .kind = .function },
    .{ .name = "contains",    .kind = .function },
    .{ .name = "starts_with", .kind = .function },
    .{ .name = "ends_with",   .kind = .function },
    .{ .name = "count",       .kind = .function },
    .{ .name = "replace",     .kind = .function },
};

pub const namespaces = [_]Namespace{
    .{ .name = "io",  .entries = &io_entries },
    .{ .name = "fmt", .entries = &fmt_entries },
    .{ .name = "core", .entries = &core_entries },
    .{ .name = "conv", .entries = &conv_entries },
    .{ .name = "math", .entries = &math_entries },
    .{ .name = "rand", .entries = &rand_entries },
    .{ .name = "string", .entries = &string_entries },
    .{ .name = "json", .entries = &json_entries },
    .{ .name = "template", .entries = &template_entries },
    .{ .name = "time", .entries = &time_entries },
    .{ .name = "hex", .entries = &hex_entries },
    .{ .name = "base64", .entries = &base64_entries },
    .{ .name = "regexp", .entries = &regexp_entries },
    .{ .name = "sort", .entries = &sort_entries },
    .{ .name = "array", .entries = &array_entries },
    .{ .name = "bytes", .entries = &bytes_entries },
};

pub const sort_entries = [_]Entry{
    .{ .name = "asc", .kind = .function },
    .{ .name = "desc", .kind = .function },
    .{ .name = "by", .kind = .function },
};

pub const array_entries = [_]Entry{
    .{ .name = "filter", .kind = .function },
    .{ .name = "map", .kind = .function },
    .{ .name = "reduce", .kind = .function },
    .{ .name = "slice", .kind = .function },
    .{ .name = "zip", .kind = .function },
    .{ .name = "flat", .kind = .function },
};

pub fn lookup(namespace: []const u8, field: []const u8) ?EntryKind {
    if (common.streq(namespace, "")) {
        return findEntry(&top_level_entries, field);
    }
    for (&namespaces) |ns| {
        if (common.streq(ns.name, namespace)) {
            return findEntry(ns.entries, field);
        }
    }
    return null;
}
