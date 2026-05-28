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
};
pub const MapEntry = struct { key: Value, value: Value };
pub const MapHashedObj = struct { entries: []MapEntry, len: usize, buckets: []i32 };
pub const NativeFuncObj = struct { id: u8, arity: u8 };
pub const FieldTypeTag = enum {
    any,
    null_t,
    int,
    float,
    rune_t,
    boolean,
    string,
    error_t,
    array,
    map,
    struct_t,
    interface_t,
    named_t,
};
pub const FieldTypeAlt = struct {
    typ: FieldTypeTag,
    struct_name: []const u8 = "",
    interface_name: []const u8 = "",
    named_name: []const u8 = "",
};
pub const FieldTypeSpec = struct {
    alts: []FieldTypeAlt,
};
pub const StructFieldSpec = struct {
    name: []const u8,
    typ: FieldTypeSpec,
};
pub const StructTypeObj = struct { name: []const u8, fields: []StructFieldSpec };
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
pub const InterfaceTypeObj = struct { name: []const u8, methods: []InterfaceMethodSpec };
pub const NamedTypeBase = enum { int, float, string, bool, rune };
pub const NamedTypeObj = struct {
    name: []const u8,
    base: NamedTypeBase,
    has_range: bool,
    min: f64,
    max: f64,
};
pub const NamedValueObj = struct { typ: *Object, value: Value };
pub const EnumTypeObj = struct { name: []const u8, members: []const []const u8 };
pub const EnumValueObj = struct { typ: *Object, name: []const u8, ordinal: i64 };
pub const StructInstanceObj = struct { typ: *Object, fields: []MapEntry };
pub const CellObj = struct { value: Value };
pub const ClosureObj = struct { func: *Object, upvalues: []*Object };
pub const IterKind = enum { array, string, map };
pub const IterObj = struct {
    kind: IterKind,
    index: usize,
    rune_index: usize = 0,
    array: []Value = &[_]Value{},
    string: []const u8 = "",
    string_managed: bool = false,
    map: []MapEntry = &[_]MapEntry{},
};

pub const ObjTag = enum { array, array_managed, map, map_managed, map_hashed, dyn_string, function, closure, cell, native_function, struct_type, interface_type, named_type, named_value, enum_type, enum_value, struct_instance, iterator };
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
    struct_type: StructTypeObj,
    interface_type: InterfaceTypeObj,
    named_type: NamedTypeObj,
    named_value: NamedValueObj,
    enum_type: EnumTypeObj,
    enum_value: EnumValueObj,
    struct_instance: StructInstanceObj,
    iterator: IterObj,
};

pub const VTag = enum { number, rune, boolean, string, error_value, object, null };
pub const Value = union(VTag) {
    number: f64,
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
        if (@as(VTag, a) != @as(VTag, b)) return false;
        return switch (a) {
            .number => |x| x == b.number,
            .rune => |x| x == b.rune,
            .boolean => |x| x == b.boolean,
            .string => |x| common.streq(x, b.string),
            .error_value => |x| common.streq(x, b.error_value),
            .object => |x| x == b.object,
            .null => true,
        };
    }
};
