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
    // Trailing default values for the last `default_count` parameters.
    // defaults[0] corresponds to param[arity - default_count].
    defaults: []const Value = &[_]Value{},
    default_count: u8 = 0,
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
    key: Value = .null,
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
pub const VariantValueObj = struct { typ: *Object, tag: []const u8, ordinal: usize, payload: Value, shared_values: []Value = &[_]Value{}, arm_fields: []Value = &[_]Value{} };
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
    parent_name: ?[]const u8 = null,
    parent_obj: ?*Object = null,
    elem_spec: ?FieldTypeSpec = null,
    key_spec: ?FieldTypeSpec = null,
    val_spec: ?FieldTypeSpec = null,
    predicate: ?*Object = null,
    predicate_msg: ?[]const u8 = null,
    has_default: bool = false,
    default_val: Value = undefined,
};
pub const NamedValueObj = struct { typ: *Object, value: Value };
pub const EnumTypeObj = struct {
    name: []const u8,
    qualified_name: []const u8,
    members: []const []const u8,
    member_ints: ?[]const i64 = null,  // explicit representation values; null = use ordinal position
    parent_name: ?[]const u8 = null,   // non-null marks enum subtype
    parent: ?*Object = null,           // lazily resolved parent pointer
};
pub const EnumValueObj = struct { typ: *Object, name: []const u8, ordinal: i64 };
pub const EnumTypeFnKind = enum { from_int, succ, pred };
pub const EnumTypeFnObj = struct { typ: *Object, kind: EnumTypeFnKind = .from_int };
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

pub const StringViewObj = struct {
    bytes: []const u8,  // view into the source dyn_string's backing buffer
    source: *Object,    // keeps the dyn_string alive so its backing buffer is not freed
};

// Growable array backed by a shared array_managed Object.
// backing must always be an .array_managed Object; backing.len is the capacity.
// Items 0..len are live; items len..capacity are always .null (safe for GC marking).
pub const ArrayCapObj = struct { backing: *Object, len: usize };

pub const ObjTag = enum { array, array_managed, array_capacity, map, map_managed, map_hashed, dyn_string, function, closure, cell, native_function, host_module_function, struct_type, interface_type, named_type, named_value, enum_type, enum_value, enum_type_fn, struct_instance, iterator, variant_type, variant_value, variant_ctor, named_type_fn, string_builder, string_view };
pub const Object = union(ObjTag) {
    array: []Value,
    array_managed: []Value,
    array_capacity: ArrayCapObj,
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
    enum_type_fn: EnumTypeFnObj,
    struct_instance: StructInstanceObj,
    iterator: IterObj,
    variant_type: VariantTypeObj,
    variant_value: VariantValueObj,
    variant_ctor: VariantCtorObj,
    named_type_fn: NamedTypeFnObj,
    string_builder: StringBuilderObj,
    string_view: StringViewObj,
};

pub const VTag = enum { int, float, decimal, rune, boolean, string, error_value, object, null };

/// Indirection wrapper that makes string payloads 8 bytes (pointer-sized) so
/// the entire Value fits in 16 bytes.  Lives in chunk.g_state.str_slices[].
/// The `.bytes` slice itself MUST point at immortal data (source literals,
/// interned names, constant-pool text) — same constraint as the old []const u8.
pub const StringSlice = struct { bytes: []const u8 };

/// Returns a stable pointer to a comptime-allocated StringSlice for a string
/// literal. No pool allocation, no errors. Use for permanent static strings.
pub fn staticSS(comptime s: []const u8) *const StringSlice {
    const S = struct { const v: StringSlice = .{ .bytes = s }; };
    return &S.v;
}

/// A Value is a tagged union (16 bytes: 8-byte tag word + 8-byte payload).
/// The `.string` and `.error_value` variants store a *const StringSlice so
/// their payload fits in 8 bytes.  The StringSlice lives in a bump pool
/// (chunk.g_state.str_slices); obtain one via chunk.internStr().
/// The bytes the StringSlice points to MUST be immortal — same invariant as
/// the old []const u8 variants.
pub const Value = union(VTag) {
    int: i64,
    float: f64,
    decimal: i64,
    rune: u21,
    boolean: bool,
    string: *const StringSlice,
    error_value: *const StringSlice,
    object: *Object,
    null,

    pub fn asBool(self: Value) error{TypeError}!bool {
        if (self == .boolean) return self.boolean;
        // Named types over bool participate in conditions through their
        // base, the same way named ints participate in arithmetic.
        if (self == .object and self.object.* == .named_value) {
            const underlying = self.object.named_value.value;
            if (underlying == .boolean) return underlying.boolean;
        }
        return error.TypeError;
    }

    fn stringViewOrDynBytes(obj: *Object) []const u8 {
        return switch (obj.*) {
            .dyn_string => |s| s,
            .string_view => |sv| sv.bytes,
            else => "",
        };
    }

    pub fn equals(a: Value, b: Value) bool {
        if (a == .string and b == .object) {
            const btag = @as(ObjTag, b.object.*);
            if (btag == .dyn_string or btag == .string_view) return common.streq(a.string.bytes, stringViewOrDynBytes(b.object));
        }
        if (b == .string and a == .object) {
            const atag = @as(ObjTag, a.object.*);
            if (atag == .dyn_string or atag == .string_view) return common.streq(stringViewOrDynBytes(a.object), b.string.bytes);
        }
        if (a == .object and b == .object) {
            const atag = @as(ObjTag, a.object.*);
            const btag = @as(ObjTag, b.object.*);
            if ((atag == .dyn_string or atag == .string_view) and (btag == .dyn_string or btag == .string_view)) {
                return common.streq(stringViewOrDynBytes(a.object), stringViewOrDynBytes(b.object));
            }
        }
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
            if (!equals(av.payload, bv.payload)) return false;
            if (av.shared_values.len != bv.shared_values.len) return false;
            for (av.shared_values, bv.shared_values) |x, y| if (!equals(x, y)) return false;
            if (av.arm_fields.len != bv.arm_fields.len) return false;
            for (av.arm_fields, bv.arm_fields) |x, y| if (!equals(x, y)) return false;
            return true;
        }
        if (@as(VTag, a) != @as(VTag, b)) {
            if ((a == .int and b == .float) or (a == .float and b == .int)) {
                const an: f64 = if (a == .int) @floatFromInt(a.int) else a.float;
                const bn: f64 = if (b == .int) @floatFromInt(b.int) else b.float;
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
            .string => |x| common.streq(x.bytes, b.string.bytes),
            .error_value => |x| common.streq(x.bytes, b.error_value.bytes),
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
    for (0..scale) |_| factor *= 10;
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
    for (0..pad_len) |_| { buf[pos] = '0'; pos += 1; }
    @memcpy(buf[pos..pos + frac_digits.len], frac_digits);
    pos += frac_digits.len;
    while (pos > 0 and buf[pos - 1] == '0') pos -= 1;
    if (pos > 0 and buf[pos - 1] == '.') pos -= 1;
    return buf[0..pos];
}
