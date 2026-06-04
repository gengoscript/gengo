const common = @import("common.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");

pub const Token = token.Token;
pub const NamedTypeBase = value_mod.NamedTypeBase;
pub const FieldTypeSpec = value_mod.FieldTypeSpec;

pub const MaxLocals = 64;
pub const MaxScopes = 8;
pub const MaxLoopDepth = 16;
pub const MaxLoopBreaks = 128;
pub const MaxTypeAlts = 8;
pub const MaxStructTypes = 128;
pub const MaxInterfaceTypes = 128;
pub const MaxNamedTypes = 256;
pub const MaxVariantTypes = 128;
pub const MaxSwitchJumps = 256;
pub const MaxUpvalues = 64;
pub const MaxGlobalConsts = 512;

pub const Prec = enum(u8) {
    none,
    assign,
    or_,
    and_,
    eq_,
    bit_or,
    bit_xor,
    bit_and,
    shift,
    cmp,
    term,
    factor,
    power,
    unary,
    call,
    primary,
    pub fn next(self: Prec) Prec {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

pub const PrimType = enum {
    int,
    float,
    bool,
    string,
    rune,
};

pub const TypeCheck = union(enum) {
    none: void,
    prim: PrimType,
    named: []const u8,
    assert_arr: void,
    assert_map: void,
    assert_err: void,
};

pub const Local = struct {
    name: []const u8,
    is_const: bool = false,
    from_std: bool = false,
    type_check: TypeCheck = .{ .none = {} },
};
pub const Upvalue = struct { name: []const u8, index: u8, from_upvalue: bool };
pub const FuncInfo = struct {
    locals: [MaxLocals]Local = undefined,
    local_count: u8 = 0,
    upvalues: [MaxUpvalues]Upvalue = undefined,
    upvalue_count: u8 = 0,
    named_return_base: u8 = 0,
    named_return_count: u8 = 0,
    is_named: bool = false,
    has_typed_returns: bool = false,
};

pub const LoopCtx = struct {
    continue_target: usize,
    local_keep: u8,
    body_keep: u8,
    iter_pops: u8,
    break_offsets: [MaxLoopBreaks]usize = undefined,
    break_count: usize = 0,
};

pub const AssignTargetStep = union(enum) {
    dot_name: []const u8,
    index_number: f64,
    index_string: []const u8,
};

pub const AssignTarget = struct {
    root: Token,
    step_start: u16,
    step_count: u8,
};

pub const MultiAssignValueScratch = "__gengo_tmp_value";

// --- TypeRegistry ---

const StructTypeInfo = struct { name: []const u8 };
const InterfaceTypeInfo = struct { name: []const u8 };
const VariantTypeInfo = struct { name: []const u8 };
pub const NamedTypeInfo = struct {
    name: []const u8,
    base: NamedTypeBase,
    has_range: bool = false,
    is_cycle: bool = false,
    min: f64 = 0,
    max: f64 = 0,
    parent_name: ?[]const u8 = null,
    elem_spec: ?FieldTypeSpec = null,
    key_spec: ?FieldTypeSpec = null,
    val_spec: ?FieldTypeSpec = null,
};
const GlobalConstInfo = struct { name: []const u8 };

pub const TypeRegistry = struct {
    struct_types: [MaxStructTypes]StructTypeInfo = undefined,
    struct_type_count: usize = 0,
    interface_types: [MaxInterfaceTypes]InterfaceTypeInfo = undefined,
    interface_type_count: usize = 0,
    named_types: [MaxNamedTypes]NamedTypeInfo = undefined,
    named_type_count: usize = 0,
    variant_types: [MaxVariantTypes]VariantTypeInfo = undefined,
    variant_type_count: usize = 0,
    global_consts: [MaxGlobalConsts]GlobalConstInfo = undefined,
    global_const_count: usize = 0,

    pub fn reset(self: *TypeRegistry) void {
        self.struct_type_count = 0;
        self.interface_type_count = 0;
        self.named_type_count = 0;
        self.variant_type_count = 0;
        self.global_const_count = 0;
    }

    pub fn hasStructType(self: *TypeRegistry, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.struct_type_count) : (i += 1) {
            if (common.streq(self.struct_types[i].name, name)) return true;
        }
        return false;
    }

    pub fn hasStructTypeLocal(self: *TypeRegistry, name: []const u8) bool {
        return self.hasStructType(name);
    }

    pub fn hasInterfaceType(self: *TypeRegistry, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.interface_type_count) : (i += 1) {
            if (common.streq(self.interface_types[i].name, name)) return true;
        }
        return false;
    }

    pub fn hasGlobalConst(self: *TypeRegistry, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.global_const_count) : (i += 1) {
            if (common.streq(self.global_consts[i].name, name)) return true;
        }
        return false;
    }

    pub fn addGlobalConst(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasGlobalConst(name)) return;
        if (self.global_const_count >= MaxGlobalConsts) return error.TooManyGlobals;
        self.global_consts[self.global_const_count] = .{ .name = name };
        self.global_const_count += 1;
    }

    pub fn addStructType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasStructType(name)) return error.DuplicateStructType;
        if (self.struct_type_count >= MaxStructTypes) return error.TooManyStructTypes;
        self.struct_types[self.struct_type_count] = .{ .name = name };
        self.struct_type_count += 1;
    }

    pub fn addInterfaceType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasInterfaceType(name)) return error.DuplicateInterfaceType;
        if (self.interface_type_count >= MaxInterfaceTypes) return error.TooManyInterfaceTypes;
        self.interface_types[self.interface_type_count] = .{ .name = name };
        self.interface_type_count += 1;
    }

    pub fn hasNamedType(self: *TypeRegistry, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.named_type_count) : (i += 1) {
            if (common.streq(self.named_types[i].name, name)) return true;
        }
        return false;
    }

    pub fn getNamedTypeInfo(self: *TypeRegistry, name: []const u8) ?NamedTypeInfo {
        var i: usize = 0;
        while (i < self.named_type_count) : (i += 1) {
            if (common.streq(self.named_types[i].name, name)) return self.named_types[i];
        }
        return null;
    }

    pub fn addNamedType(self: *TypeRegistry, info: NamedTypeInfo) !void {
        if (self.hasNamedType(info.name)) return error.DuplicateNamedType;
        if (self.named_type_count >= MaxNamedTypes) return error.TooManyNamedTypes;
        self.named_types[self.named_type_count] = info;
        self.named_type_count += 1;
    }

    pub fn hasVariantType(self: *TypeRegistry, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.variant_type_count) : (i += 1) {
            if (common.streq(self.variant_types[i].name, name)) return true;
        }
        return false;
    }

    pub fn addVariantType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasVariantType(name)) return error.DuplicateVariantType;
        if (self.variant_type_count >= MaxVariantTypes) return error.TooManyVariantTypes;
        self.variant_types[self.variant_type_count] = .{ .name = name };
        self.variant_type_count += 1;
    }
};
