const std = @import("std");
const common = @import("common.zig");

pub const FuncObj = struct {
    ip: usize,
    arity: u8,
    is_variadic: bool,
    variadic_type: FieldTypeSpec,
    capture_slots: []const u8,
    param_types: []FieldTypeSpec,
    has_typed_params: bool,
    return_types: []FieldTypeSpec,
    has_typed_returns: bool,
    name: []const u8 = "",
    named_return_count: u8 = 0,
};
pub const MapEntry = struct { key: Value, value: Value };
pub const MapHashedObj = struct { entries: []MapEntry, len: usize, buckets: []i32 };
pub const NativeFuncObj = struct { id: u8, arity: u8 };
pub const HostModuleFuncObj = struct { call_id: u16, arity: u8 };
pub const FieldTypeTag = enum {
    any,
    null_t,
    int,
    float,
    decimal_t,
    rune_t,
    boolean,
    string,
    error_t,
    array,
    map,
    struct_t,
    interface_t,
    named_t,
    variant_t,
    func_t,
};
pub const FieldTypeAlt = struct {
    typ: FieldTypeTag,
    struct_name: []const u8 = "",
    interface_name: []const u8 = "",
    named_name: []const u8 = "",
    elem_spec: ?FieldTypeSpec = null,      // for array[T]
    key_spec: ?FieldTypeSpec = null,       // for map[K,V]
    val_spec: ?FieldTypeSpec = null,       // for map[K,V]
    func_params: ?[]const FieldTypeSpec = null,  // for func(T...) R
    func_returns: ?[]const FieldTypeSpec = null, // for func(T...) R
};
pub const FieldTypeSpec = struct {
    alts: []FieldTypeAlt,
};
pub const StructFieldSpec = struct {
    name: []const u8,
    typ: FieldTypeSpec,
    is_const: bool = false,
};
pub const StructTypeObj = struct { name: []const u8, qualified_name: []const u8, fields: []StructFieldSpec };
pub const InterfaceMethodSpec = struct {
    name: []const u8,
    arity: u8,
    is_variadic: bool,
    variadic_type: FieldTypeSpec,
    param_types: []FieldTypeSpec,
    return_types: []FieldTypeSpec,
    has_typed_params: bool,
    has_typed_returns: bool,
};
pub const InterfaceTypeObj = struct { name: []const u8, qualified_name: []const u8, methods: []InterfaceMethodSpec };
pub const VariantArmSpec = struct {
    name: []const u8,
    has_payload: bool = false,
    payload_name: []const u8 = "",
    payload_type: ?FieldTypeSpec = null,
    fields: []const StructFieldSpec = &[_]StructFieldSpec{},
};
pub const VariantTypeObj = struct { name: []const u8, qualified_name: []const u8, arms: []const VariantArmSpec, shared_fields: []const StructFieldSpec = &[_]StructFieldSpec{} };
pub const VariantValueObj = struct { typ: *Object, tag: []const u8, ordinal: usize, payload: Value, shared_values: []const Value = &[_]Value{}, arm_fields: []const Value = &[_]Value{} };
pub const VariantCtorObj = struct { typ: *Object, tag: []const u8, ordinal: usize, payload_type: ?FieldTypeSpec };
pub const NamedTypeFnKind = enum { succ, pred };
pub const NamedTypeFnObj = struct { typ: *Object, kind: NamedTypeFnKind };

pub const NamedTypeBase = enum { int, float, decimal, string, bool, rune, array_t, map_t, enum_t };
pub const NamedTypeObj = struct {
    name: []const u8,
    qualified_name: []const u8,
    base: NamedTypeBase,
    has_range: bool = false,
    is_cycle: bool = false,
    scale: u8 = 0,
    min: f64 = 0,
    max: f64 = 0,
    parent_name: ?[]const u8 = null,   // non-null for subtype declarations
    parent_obj: ?*Object = null,       // lazily resolved from parent_name at runtime
    elem_spec: ?FieldTypeSpec = null,  // for array_t: element type
    key_spec: ?FieldTypeSpec = null,   // for map_t: key type
    val_spec: ?FieldTypeSpec = null,   // for map_t: value type
    predicate: ?*Object = null,          // predicate closure (null if unconstrained)
};
pub const NamedValueObj = struct { typ: *Object, value: Value };
pub const EnumTypeObj = struct {
    name: []const u8,
    qualified_name: []const u8,
    members: []const []const u8,
    parent_name: ?[]const u8 = null,  // non-null marks enum subtype
    parent: ?*Object = null,           // lazily resolved parent pointer
};
pub const EnumValueObj = struct { typ: *Object, name: []const u8, ordinal: i64 };
pub const StructInstanceObj = struct { typ: *Object, fields: []MapEntry };
pub const CellObj = struct { value: Value };
pub const ClosureObj = struct { func: *Object, upvalues: []*Object };
pub const IterKind = enum { array, string, map, range };
pub const IterObj = struct {
    kind: IterKind,
    index: usize,
    rune_index: usize = 0,
    array: []Value = &[_]Value{},
    string: []const u8 = "",
    string_managed: bool = false,
    map: []MapEntry = &[_]MapEntry{},
    source: ?*Object = null,
    range_current: f64 = 0,
    range_max: f64 = 0,
};

pub const StringBuilderObj = struct {
    buf: []u8,   // managed bytes (full class-size block)
    len: usize,  // bytes actually written
};

pub const ObjTag = enum { array, array_managed, map, map_managed, map_hashed, dyn_string, function, closure, cell, native_function, host_module_function, struct_type, interface_type, named_type, named_value, enum_type, enum_value, struct_instance, iterator, variant_type, variant_value, variant_ctor, named_type_fn, string_builder };
pub const Object = union(ObjTag) {
    array: []Value,
    array_managed: []Value,
    map: []MapEntry,
    map_managed: []MapEntry,
    map_hashed: MapHashedObj,
    dyn_string: []u8,
    function: FuncObj,
    closure: ClosureObj,
    cell: CellObj,
    native_function: NativeFuncObj,
    host_module_function: HostModuleFuncObj,
    struct_type: StructTypeObj,
    interface_type: InterfaceTypeObj,
    named_type: NamedTypeObj,
    named_value: NamedValueObj,
    enum_type: EnumTypeObj,
    enum_value: EnumValueObj,
    struct_instance: StructInstanceObj,
    iterator: IterObj,
    variant_type: VariantTypeObj,
    variant_value: VariantValueObj,
    variant_ctor: VariantCtorObj,
    named_type_fn: NamedTypeFnObj,
    string_builder: StringBuilderObj,
};

pub const VTag = enum { int, float, decimal, rune, boolean, string, error_value, object, null };

/// A Value is a tagged union.  The `.string` variant is a raw ptr+len with
/// no GC tracking; it MUST only point at immortal bytes (source-code string
/// literals, lexer interned strings, or the chunk constant pool).  Any
/// heap-backed or transient text MUST be stored as a `.dyn_string` Object.
/// Violating this invariant causes use-after-free or aliasing bugs when the
/// GC or a native reuses the backing memory.
pub const Value = union(VTag) {
    int: f64,
    float: f64,
    decimal: i64,
    rune: u21,
    boolean: bool,
    string: []const u8,
    error_value: []const u8,
    object: *Object,
    null,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .rune => |r| r != 0,
            .decimal => |d| d != 0,
            .int => |n| n != 0.0,
            .float => |n| n != 0.0,
            .null => false,
            else => true,
        };
    }

    pub fn equals(a: Value, b: Value) bool {
        if (a == .string and b == .object and b.object.* == .dyn_string) return common.streq(a.string, b.object.dyn_string);
        if (b == .string and a == .object and a.object.* == .dyn_string) return common.streq(a.object.dyn_string, b.string);
        if (a == .object and b == .object and a.object.* == .dyn_string and b.object.* == .dyn_string) return common.streq(a.object.dyn_string, b.object.dyn_string);
        if (a == .object and b == .object and a.object.* == .enum_value and b.object.* == .enum_value) {
            return a.object.enum_value.typ == b.object.enum_value.typ and a.object.enum_value.ordinal == b.object.enum_value.ordinal;
        }
        if (a == .object and b == .object and a.object.* == .named_value and b.object.* == .named_value) {
            const an = a.object.named_value;
            const bn = b.object.named_value;
            if (an.typ != bn.typ) return false;
            return equals(an.value, bn.value);
        }
        if (a == .object and b == .object and a.object.* == .variant_value and b.object.* == .variant_value) {
            const av = a.object.variant_value;
            const bv = b.object.variant_value;
            if (av.typ != bv.typ) return false;
            if (!common.streq(av.tag, bv.tag)) return false;
            return equals(av.payload, bv.payload);
        }
        if (@as(VTag, a) != @as(VTag, b)) {
            if ((a == .int and b == .float) or (a == .float and b == .int)) {
                const an = if (a == .int) a.int else a.float;
                const bn = if (b == .int) b.int else b.float;
                return an == bn;
            }
            return false;
        }
        return switch (a) {
            .int => |x| x == b.int,
            .float => |x| x == b.float,
            .decimal => |x| x == b.decimal,
            .rune => |x| x == b.rune,
            .boolean => |x| x == b.boolean,
            .string => |x| common.streq(x, b.string),
            .error_value => |x| common.streq(x, b.error_value),
            .object => |x| x == b.object,
            .null => true,
        };
    }
};

pub fn decimalScaledToFloat(raw: i64, scale: u8) f64 {
    if (scale == 0) return @floatFromInt(raw);
    const factor = std.math.pow(f64, 10.0, @floatFromInt(scale));
    return @as(f64, @floatFromInt(raw)) / factor;
}

pub fn decimalLogicalNumber(v: Value) ?f64 {
    return switch (v) {
        .decimal => |d| decimalScaledToFloat(d, 0),
        .object => |obj| switch (obj.*) {
            .named_value => |nv| {
                if (nv.typ.* == .named_type and nv.typ.named_type.base == .decimal and nv.value == .decimal) {
                    return decimalScaledToFloat(nv.value.decimal, nv.typ.named_type.scale);
                }
                return decimalLogicalNumber(nv.value);
            },
            else => null,
        },
        else => null,
    };
}

pub fn decimalRawAndScale(v: Value) ?struct { raw: i64, scale: u8 } {
    return switch (v) {
        .decimal => |d| .{ .raw = d, .scale = 0 },
        .object => |obj| switch (obj.*) {
            .named_value => |nv| {
                if (nv.typ.* == .named_type and nv.typ.named_type.base == .decimal and nv.value == .decimal) {
                    return .{ .raw = nv.value.decimal, .scale = nv.typ.named_type.scale };
                }
                return decimalRawAndScale(nv.value);
            },
            else => null,
        },
        else => null,
    };
}

pub fn formatDecimalString(raw: i64, scale: u8, buf: []u8) []u8 {
    if (scale == 0) {
        return std.fmt.bufPrint(buf, "{d}", .{raw}) catch &[_]u8{};
    }
    const negative = raw < 0;
    const raw128: i128 = raw;
    const abs_raw: i128 = if (raw128 < 0) -raw128 else raw128;
    var factor: i128 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) factor *= 10;
    const int_part = @divTrunc(abs_raw, factor);
    const frac_raw = @mod(abs_raw, factor);
    var pos: usize = 0;
    if (negative) {
        buf[pos] = '-';
        pos += 1;
    }
    const int_str = std.fmt.bufPrint(buf[pos..], "{d}", .{@as(i64, @intCast(int_part))}) catch "";
    pos += int_str.len;
    buf[pos] = '.';
    pos += 1;
    var frac_buf: [20]u8 = undefined;
    const frac_digits = std.fmt.bufPrint(&frac_buf, "{d}", .{@as(i64, @intCast(frac_raw))}) catch "";
    const pad_len = scale - frac_digits.len;
    var j: usize = 0;
    while (j < pad_len) : (j += 1) {
        buf[pos] = '0';
        pos += 1;
    }
    @memcpy(buf[pos..pos + frac_digits.len], frac_digits);
    pos += frac_digits.len;
    while (pos > 0 and buf[pos - 1] == '0') pos -= 1;
    if (pos > 0 and buf[pos - 1] == '.') pos -= 1;
    return buf[0..pos];
}
