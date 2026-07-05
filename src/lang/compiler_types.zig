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
pub const MaxTestBlocks = 256;
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
    bigint,
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
    anon_typed: u16,
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

// ── Hash-index types for O(1) symbol lookup ─────────────────────────────────
//
// Two separate open-addressed hash tables keep type names (struct/interface/
// named/variant) and global function names in disjoint namespaces, avoiding
// any cross-kind collision between e.g. a type named "Foo" and a function also
// named "Foo".  Global consts remain a linear scan (small count, rare path).
//
// TypeHashSize = 2048: load factor < 0.32 at the combined type ceiling of
// MaxStructTypes+MaxInterfaceTypes+MaxNamedTypes+MaxVariantTypes = 640.
// FuncHashSize = 1024: load factor < 0.50 at MaxGlobalFuncs = 512.

const TypeSymbolKind = enum(u8) { struct_type, interface_type, named_type, variant_type };
const TypeHashSize = 2048;
const FuncHashSize = 1024;

const TypeHashEntry = struct {
    sub_idx: u16 = 0, // index into the kind's sub-array
    kind: TypeSymbolKind = .struct_type,
    occupied: bool = false,
};
const FuncHashEntry = struct {
    sub_idx: u16 = 0,
    occupied: bool = false,
};

// Comptime-zero arrays used as default field values so that TypeRegistry = .{}
// gives properly initialised (all-empty) hash tables without an explicit reset.
const empty_type_buckets = [1]TypeHashEntry{.{}} ** TypeHashSize;
const empty_func_buckets = [1]FuncHashEntry{.{}} ** FuncHashSize;
// ─────────────────────────────────────────────────────────────────────────────

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

    // Hash indexes — initialised to all-empty via comptime defaults above.
    type_buckets: [TypeHashSize]TypeHashEntry = empty_type_buckets,
    func_buckets: [FuncHashSize]FuncHashEntry = empty_func_buckets,

    pub fn reset(self: *TypeRegistry) void {
        self.struct_type_count = 0;
        self.interface_type_count = 0;
        self.named_type_count = 0;
        self.variant_type_count = 0;
        self.global_const_count = 0;
        self.global_func_count = 0;
        @memset(self.type_buckets[0..], .{});
        @memset(self.func_buckets[0..], .{});
    }

    // ── Hash helpers ──────────────────────────────────────────────────────────

    fn nameAtTypeSlot(self: *const TypeRegistry, idx: usize) []const u8 {
        const e = self.type_buckets[idx];
        return switch (e.kind) {
            .struct_type => self.struct_types[e.sub_idx].name,
            .interface_type => self.interface_types[e.sub_idx].name,
            .named_type => self.named_types[e.sub_idx].name,
            .variant_type => self.variant_types[e.sub_idx].name,
        };
    }

    fn typeSlotFor(self: *const TypeRegistry, name: []const u8) ?usize {
        const mask: usize = TypeHashSize - 1;
        var idx: usize = @intCast(common.hashBytes(name) & mask);
        for (0..TypeHashSize) |_| {
            const e = self.type_buckets[idx];
            if (!e.occupied) return null;
            if (common.streq(self.nameAtTypeSlot(idx), name)) return idx;
            idx = (idx + 1) & mask;
        }
        return null;
    }

    fn typeSlotForInsert(self: *const TypeRegistry, name: []const u8) ?usize {
        const mask: usize = TypeHashSize - 1;
        var idx: usize = @intCast(common.hashBytes(name) & mask);
        for (0..TypeHashSize) |_| {
            const e = self.type_buckets[idx];
            if (!e.occupied or common.streq(self.nameAtTypeSlot(idx), name)) return idx;
            idx = (idx + 1) & mask;
        }
        return null;
    }

    fn insertTypeSlot(self: *TypeRegistry, name: []const u8, kind: TypeSymbolKind, sub_idx: usize) void {
        const slot = self.typeSlotForInsert(name) orelse return;
        if (!self.type_buckets[slot].occupied) {
            self.type_buckets[slot] = .{ .sub_idx = @intCast(sub_idx), .kind = kind, .occupied = true };
        }
    }

    fn funcSlotFor(self: *const TypeRegistry, name: []const u8) ?usize {
        const mask: usize = FuncHashSize - 1;
        var idx: usize = @intCast(common.hashBytes(name) & mask);
        for (0..FuncHashSize) |_| {
            const e = self.func_buckets[idx];
            if (!e.occupied) return null;
            if (common.streq(self.global_funcs[e.sub_idx].name, name)) return idx;
            idx = (idx + 1) & mask;
        }
        return null;
    }

    fn funcSlotForInsert(self: *const TypeRegistry, name: []const u8) ?usize {
        const mask: usize = FuncHashSize - 1;
        var idx: usize = @intCast(common.hashBytes(name) & mask);
        for (0..FuncHashSize) |_| {
            const e = self.func_buckets[idx];
            if (!e.occupied or common.streq(self.global_funcs[e.sub_idx].name, name)) return idx;
            idx = (idx + 1) & mask;
        }
        return null;
    }

    // ── Public API ────────────────────────────────────────────────────────────

    pub fn hasStructType(self: *const TypeRegistry, name: []const u8) bool {
        const slot = self.typeSlotFor(name) orelse return false;
        return self.type_buckets[slot].kind == .struct_type;
    }

    pub fn hasStructTypeLocal(self: *const TypeRegistry, name: []const u8) bool {
        return self.hasStructType(name);
    }

    pub fn hasInterfaceType(self: *const TypeRegistry, name: []const u8) bool {
        const slot = self.typeSlotFor(name) orelse return false;
        return self.type_buckets[slot].kind == .interface_type;
    }

    pub fn hasGlobalConst(self: *const TypeRegistry, name: []const u8) bool {
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
        const sub_idx = self.struct_type_count;
        self.struct_types[sub_idx] = .{ .name = name };
        self.struct_type_count += 1;
        self.insertTypeSlot(name, .struct_type, sub_idx);
    }

    pub fn addInterfaceType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasInterfaceType(name)) return error.DuplicateInterfaceType;
        if (self.interface_type_count >= MaxInterfaceTypes) return error.TooManyInterfaceTypes;
        const sub_idx = self.interface_type_count;
        self.interface_types[sub_idx] = .{ .name = name };
        self.interface_type_count += 1;
        self.insertTypeSlot(name, .interface_type, sub_idx);
    }

    pub fn hasNamedType(self: *const TypeRegistry, name: []const u8) bool {
        const slot = self.typeSlotFor(name) orelse return false;
        return self.type_buckets[slot].kind == .named_type;
    }

    pub fn getNamedTypeInfo(self: *const TypeRegistry, name: []const u8) ?NamedTypeInfo {
        const slot = self.typeSlotFor(name) orelse return null;
        const e = self.type_buckets[slot];
        if (e.kind != .named_type) return null;
        return self.named_types[e.sub_idx];
    }

    pub fn addNamedType(self: *TypeRegistry, info: NamedTypeInfo) !void {
        if (self.hasNamedType(info.name)) return error.DuplicateNamedType;
        if (self.named_type_count >= MaxNamedTypes) return error.TooManyNamedTypes;
        const sub_idx = self.named_type_count;
        self.named_types[sub_idx] = info;
        self.named_type_count += 1;
        self.insertTypeSlot(info.name, .named_type, sub_idx);
    }

    pub fn hasVariantType(self: *const TypeRegistry, name: []const u8) bool {
        const slot = self.typeSlotFor(name) orelse return false;
        return self.type_buckets[slot].kind == .variant_type;
    }

    pub fn hasAnyTypeName(self: *const TypeRegistry, name: []const u8) bool {
        return self.typeSlotFor(name) != null;
    }

    pub fn addVariantType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasVariantType(name)) return error.DuplicateVariantType;
        if (self.variant_type_count >= MaxVariantTypes) return error.TooManyVariantTypes;
        const sub_idx = self.variant_type_count;
        self.variant_types[sub_idx] = .{ .name = name };
        self.variant_type_count += 1;
        self.insertTypeSlot(name, .variant_type, sub_idx);
    }

    pub fn hasGlobalFunc(self: *const TypeRegistry, name: []const u8) bool {
        return self.funcSlotFor(name) != null;
    }

    pub fn addGlobalFunc(self: *TypeRegistry, name: []const u8) !void {
        if (self.global_func_count >= MaxGlobalFuncs) return error.TooManyGlobalFuncs;
        const sub_idx = self.global_func_count;
        self.global_funcs[sub_idx] = .{ .name = name };
        self.global_func_count += 1;
        const slot = self.funcSlotForInsert(name) orelse return;
        if (!self.func_buckets[slot].occupied) {
            self.func_buckets[slot] = .{ .sub_idx = @intCast(sub_idx), .occupied = true };
        }
    }
};
