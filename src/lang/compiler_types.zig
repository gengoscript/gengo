const common = @import("common.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");

pub const Token = token.Token;
pub const NamedTypeBase = value_mod.NamedTypeBase;
pub const FieldTypeSpec = value_mod.FieldTypeSpec;

pub const ExportTypeKind = enum(u8) {
    func_or_var,
    struct_t,
    interface_t,
    named_t,
    variant_t,
};

pub const MaxLocals = 64;
pub const MaxScopes = 8;
pub const MaxLoopDepth = 16;
pub const MaxLoopBreaks = 128;
pub const MaxLoopVars = 2;
pub const MaxTypeAlts = 8;
pub const MaxStructTypes = 128;
pub const MaxInterfaceTypes = 128;
pub const MaxNamedTypes = 256;
pub const MaxVariantTypes = 128;
pub const MaxSwitchJumps = 256;
pub const MaxUpvalues = 64;
pub const MaxGlobalConsts = 512;
pub const MaxGlobalFuncs = 512;
pub const MaxExprDepth = 256;

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
    decimal,
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
    interface_type: []const u8,
    struct_type: []const u8,
};

pub const Local = struct {
    name: []const u8,
    is_const: bool = false,
    from_std: bool = false,
    import_module_path: ?[]const u8 = null,
    is_captured: bool = false,
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
    loop_var_count: u8 = 0,
    loop_var_slots: [MaxLoopVars]u8 = undefined,
    loop_var_names: [MaxLoopVars][]const u8 = undefined,
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
    scale: u8 = 0,
    min: f64 = 0,
    max: f64 = 0,
    parent_name: ?[]const u8 = null,
    predicate_msg: ?[]const u8 = null,
    elem_spec: ?FieldTypeSpec = null,
    key_spec: ?FieldTypeSpec = null,
    val_spec: ?FieldTypeSpec = null,
    enum_members: ?[]const []const u8 = null,
    has_default: bool = false,
    default_val: value_mod.Value = undefined,
};
const GlobalConstInfo = struct { name: []const u8 };
const GlobalFuncInfo = struct { name: []const u8 };

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
    global_funcs: [MaxGlobalFuncs]GlobalFuncInfo = undefined,
    global_func_count: usize = 0,

    pub fn reset(self: *TypeRegistry) void {
        self.struct_type_count = 0;
        self.interface_type_count = 0;
        self.named_type_count = 0;
        self.variant_type_count = 0;
        self.global_const_count = 0;
        self.global_func_count = 0;
    }

    pub fn hasStructType(self: *TypeRegistry, name: []const u8) bool {
        for (self.struct_types[0..self.struct_type_count]) |t| {
            if (common.streq(t.name, name)) return true;
        }
        return false;
    }

    pub fn hasStructTypeLocal(self: *TypeRegistry, name: []const u8) bool {
        return self.hasStructType(name);
    }

    pub fn hasInterfaceType(self: *TypeRegistry, name: []const u8) bool {
        for (self.interface_types[0..self.interface_type_count]) |t| {
            if (common.streq(t.name, name)) return true;
        }
        return false;
    }

    pub fn hasGlobalConst(self: *TypeRegistry, name: []const u8) bool {
        for (self.global_consts[0..self.global_const_count]) |c| {
            if (common.streq(c.name, name)) return true;
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
        for (self.named_types[0..self.named_type_count]) |t| {
            if (common.streq(t.name, name)) return true;
        }
        return false;
    }

    pub fn getNamedTypeInfo(self: *TypeRegistry, name: []const u8) ?NamedTypeInfo {
        for (self.named_types[0..self.named_type_count]) |t| {
            if (common.streq(t.name, name)) return t;
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
        for (self.variant_types[0..self.variant_type_count]) |t| {
            if (common.streq(t.name, name)) return true;
        }
        return false;
    }

    pub fn hasAnyTypeName(self: *TypeRegistry, name: []const u8) bool {
        return self.hasStructType(name) or self.hasInterfaceType(name) or
            self.hasNamedType(name) or self.hasVariantType(name);
    }

    pub fn addVariantType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasVariantType(name)) return error.DuplicateVariantType;
        if (self.variant_type_count >= MaxVariantTypes) return error.TooManyVariantTypes;
        self.variant_types[self.variant_type_count] = .{ .name = name };
        self.variant_type_count += 1;
    }

    pub fn hasGlobalFunc(self: *TypeRegistry, name: []const u8) bool {
        for (self.global_funcs[0..self.global_func_count]) |f| {
            if (common.streq(f.name, name)) return true;
        }
        return false;
    }

    pub fn addGlobalFunc(self: *TypeRegistry, name: []const u8) !void {
        if (self.global_func_count >= MaxGlobalFuncs) return error.TooManyGlobalFuncs;
        self.global_funcs[self.global_func_count] = .{ .name = name };
        self.global_func_count += 1;
    }
};
