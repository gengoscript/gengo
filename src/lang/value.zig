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
    is_anonymous: bool = false,
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

/// Inline representation for scalar named types (int, float, decimal, rune, bool).
/// Avoids a GC allocation per construction.  `bits` holds the raw bit pattern
/// of the scalar value; interpret via `typ.named_type.base`.
pub const NamedScalarValue = struct { typ: *Object, bits: u64 };

pub fn namedScalarInner(ns: NamedScalarValue) Value {
    return switch (ns.typ.named_type.base) {
        .int     => .{ .int     = @bitCast(ns.bits) },
        .float   => .{ .float   = @bitCast(ns.bits) },
        .decimal => .{ .decimal = @bitCast(ns.bits) },
        .rune    => .{ .rune    = @intCast(ns.bits)  },
        .bool    => .{ .boolean = ns.bits != 0       },
        else     => unreachable,
    };
}
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

pub const BigIntObj = struct {
    limbs: []std.math.big.Limb, // GC-managed; .len = allocated capacity
    len: usize,                  // live limb count
    positive: bool,              // true = non-negative

    pub fn toConst(self: BigIntObj) std.math.big.int.Const {
        return .{ .limbs = self.limbs[0..self.len], .positive = self.positive };
    }
};

pub const StringViewObj = struct {
    bytes: []const u8, // view into a dyn_string's backing buffer, or immortal bytes when source=null
    source: ?*Object,  // keeps the parent dyn_string alive; null when bytes are immortal
};

pub const ArrayViewObj = struct {
    items: []Value,   // view into the source array object's backing storage
    source: *Object,  // keeps the source array alive so the slice does not dangle
};

// Growable array backed by a shared array_managed Object.
// backing must always be an .array_managed Object; backing.len is the capacity.
// Items 0..len are live; items len..capacity are always .null (safe for GC marking).
pub const ArrayCapObj = struct { backing: *Object, len: usize };

pub const ObjTag = enum { array, array_managed, array_view, array_capacity, map, map_managed, map_hashed, dyn_string, function, closure, cell, native_function, host_module_function, struct_type, interface_type, named_type, named_value, enum_type, enum_value, enum_type_fn, struct_instance, iterator, variant_type, variant_value, variant_ctor, named_type_fn, string_builder, string_view, bigint };
pub const Object = union(ObjTag) {
    array: []Value,
    array_managed: []Value,
    array_view: ArrayViewObj,
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
    bigint: BigIntObj,
};

pub const VTag = enum { int, float, decimal, rune, boolean, string, error_value, object, null, named_scalar, inline_variant };

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

/// Inline variant value: scalar payload variants without a GC allocation.
/// bits layout (64 bits):
///   [63:60] payload_kind — 0=null, 1=int, 2=bool, 3=rune, 4=decimal
///   [59:48] ordinal      — arm index (0..4095)
///   [47:0]  payload_raw  — 48-bit payload (signed for int/decimal)
pub const InlineVariantValue = struct { typ: *Object, bits: u64 };

/// A Value is a tagged union (24 bytes: tag + 16-byte payload for named_scalar/inline_variant).
/// The `.string` and `.error_value` variants store a *const StringSlice so
/// their scalar payloads fit in 8 bytes.  The StringSlice lives in a bump pool
/// (chunk.g_state.str_slices); obtain one via chunk.internStr().
/// The bytes the StringSlice points to MUST be immortal.
/// `.named_scalar` stores scalar named-type values inline without a GC allocation.
/// `.inline_variant` stores simple variant arm values inline without a GC allocation.
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
    named_scalar: NamedScalarValue,
    inline_variant: InlineVariantValue,

    /// Helper result type for named-value access independent of representation.
    pub const NamedRef = struct { typ: *Object, inner: Value };

    /// Return (typ, inner) for any named value (inline or GC). Null if not named.
    pub fn asNamed(self: Value) ?NamedRef {
        if (self == .named_scalar) {
            const ns = self.named_scalar;
            return .{ .typ = ns.typ, .inner = namedScalarInner(ns) };
        }
        if (self == .object and self.object.* == .named_value) {
            const nv = self.object.named_value;
            return .{ .typ = nv.typ, .inner = nv.value };
        }
        return null;
    }

    pub fn isNamed(self: Value) bool {
        return self == .named_scalar or (self == .object and self.object.* == .named_value);
    }

    pub fn namedTyp(self: Value) ?*Object {
        if (self == .named_scalar) return self.named_scalar.typ;
        if (self == .object and self.object.* == .named_value) return self.object.named_value.typ;
        return null;
    }

    pub fn namedInner(self: Value) ?Value {
        if (self == .named_scalar) return namedScalarInner(self.named_scalar);
        if (self == .object and self.object.* == .named_value) return self.object.named_value.value;
        return null;
    }

    /// Helper result type for variant access independent of representation.
    pub const VariantRef = struct { typ: *Object, ordinal: usize, payload: Value };

    /// Return (typ, ordinal, payload) for any variant value (inline or GC). Null if not a variant value.
    pub fn asVariant(self: Value) ?VariantRef {
        if (self == .inline_variant) {
            const iv = self.inline_variant;
            return .{ .typ = iv.typ, .ordinal = inlineVariantOrdinal(iv), .payload = inlineVariantPayload(iv) };
        }
        if (self == .object and self.object.* == .variant_value) {
            const vv = self.object.variant_value;
            return .{ .typ = vv.typ, .ordinal = vv.ordinal, .payload = vv.payload };
        }
        return null;
    }

    pub fn isVariant(self: Value) bool {
        return self == .inline_variant or (self == .object and self.object.* == .variant_value);
    }

    pub fn asBool(self: Value) error{TypeError}!bool {
        if (self == .boolean) return self.boolean;
        // Named types over bool participate in conditions through their
        // base, the same way named ints participate in arithmetic.
        if (self == .named_scalar) {
            if (self.named_scalar.typ.named_type.base == .bool) return self.named_scalar.bits != 0;
        }
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
        // Named value equality (handles inline and GC forms).
        if (a.asNamed()) |an| {
            if (b.asNamed()) |bn| {
                if (an.typ != bn.typ) return false;
                return equals(an.inner, bn.inner);
            }
            return false;
        }
        // Variant equality: compare type pointer + ordinal + payload (handles inline and GC).
        if (a.asVariant()) |ar| {
            if (b.asVariant()) |br| {
                if (ar.typ != br.typ or ar.ordinal != br.ordinal) return false;
                if (!equals(ar.payload, br.payload)) return false;
                // GC variants may also carry shared_values and arm_fields.
                if (a == .object and b == .object) {
                    const av = a.object.variant_value;
                    const bv = b.object.variant_value;
                    if (av.shared_values.len != bv.shared_values.len) return false;
                    for (av.shared_values, bv.shared_values) |x, y| if (!equals(x, y)) return false;
                    if (av.arm_fields.len != bv.arm_fields.len) return false;
                    for (av.arm_fields, bv.arm_fields) |x, y| if (!equals(x, y)) return false;
                }
                return true;
            }
            return false;
        }
        if (a == .object and b == .object and a.object.* == .bigint and b.object.* == .bigint) {
            return a.object.bigint.toConst().eql(b.object.bigint.toConst());
        }
        if ((a == .int and b == .object and b.object.* == .bigint) or
            (a == .object and a.object.* == .bigint and b == .int))
        {
            const bi = if (a == .object) a.object.bigint else b.object.bigint;
            const n: i64 = if (a == .int) a.int else b.int;
            return bi.toConst().orderAgainstScalar(n) == .eq;
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
            .named_scalar => unreachable, // handled above by asNamed()
            .inline_variant => unreachable, // handled above by asVariant()
        };
    }
};

pub fn decimalScaledToFloat(raw: i64, scale: u8) f64 {
    if (scale == 0) return @floatFromInt(raw);
    const factor = std.math.pow(f64, 10.0, @floatFromInt(scale));
    return @as(f64, @floatFromInt(raw)) / factor;
}

pub fn decimalLogicalNumber(v: Value) ?f64 {
    if (v == .named_scalar and v.named_scalar.typ.named_type.base == .decimal)
        return decimalScaledToFloat(@bitCast(v.named_scalar.bits), v.named_scalar.typ.named_type.scale);
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
    if (v == .named_scalar and v.named_scalar.typ.named_type.base == .decimal)
        return .{ .raw = @bitCast(v.named_scalar.bits), .scale = v.named_scalar.typ.named_type.scale };
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

/// Decode the ordinal from an InlineVariantValue.
pub fn inlineVariantOrdinal(iv: InlineVariantValue) usize {
    return @intCast((iv.bits >> 48) & 0x0FFF);
}

/// Decode the payload Value from an InlineVariantValue.
pub fn inlineVariantPayload(iv: InlineVariantValue) Value {
    const kind: u4 = @truncate(iv.bits >> 60);
    const raw48: u64 = iv.bits & 0x0000_FFFF_FFFF_FFFF;
    return switch (kind) {
        0 => .null,
        1 => blk: { // int — sign-extend from 48 bits
            const v: i64 = if (raw48 & (@as(u64, 1) << 47) != 0)
                @bitCast(raw48 | 0xFFFF_0000_0000_0000)
            else
                @bitCast(raw48);
            break :blk .{ .int = v };
        },
        2 => .{ .boolean = raw48 != 0 },
        3 => .{ .rune = @truncate(raw48) },
        4 => blk: { // decimal — sign-extend from 48 bits
            const v: i64 = if (raw48 & (@as(u64, 1) << 47) != 0)
                @bitCast(raw48 | 0xFFFF_0000_0000_0000)
            else
                @bitCast(raw48);
            break :blk .{ .decimal = v };
        },
        else => .null,
    };
}

/// Try to build an inline_variant Value. Returns null if the combination cannot
/// be represented inline (ordinal ≥ 4096, float/string/object payload, or int/
/// decimal value outside the ±140T i48 range).
pub fn tryMakeInlineVariant(typ: *Object, ordinal: usize, payload: Value) ?Value {
    if (ordinal > 0xFFF) return null;
    const ord_bits: u64 = @as(u64, ordinal) << 48;
    const bits: u64 = switch (payload) {
        .null => ord_bits,
        .boolean => |b| (@as(u64, 2) << 60) | ord_bits | @as(u64, if (b) 1 else 0),
        .rune => |r| (@as(u64, 3) << 60) | ord_bits | @as(u64, r),
        .int => |n| blk: {
            if (n < -(1 << 47) or n > ((1 << 47) - 1)) return null;
            break :blk (@as(u64, 1) << 60) | ord_bits | (@as(u64, @bitCast(n)) & 0x0000_FFFF_FFFF_FFFF);
        },
        .decimal => |n| blk: {
            if (n < -(1 << 47) or n > ((1 << 47) - 1)) return null;
            break :blk (@as(u64, 4) << 60) | ord_bits | (@as(u64, @bitCast(n)) & 0x0000_FFFF_FFFF_FFFF);
        },
        else => return null,
    };
    return .{ .inline_variant = .{ .typ = typ, .bits = bits } };
}
