const std = @import("std");
const common = @import("common.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");

pub const Token = token.Token;
pub const NamedTypeBase = value_mod.NamedTypeBase;
pub const FieldTypeSpec = value_mod.FieldTypeSpec;
pub const Object = value_mod.Object;

pub const ExportTypeKind = enum(u8) {
    func_or_var,
    struct_t,
    interface_t,
    named_t,
    variant_t,
};

pub const MaxLocals = 64;
pub const MaxModuleExports = 256; // per-module export limit, independent of function locals
pub const MaxTestBlocks = 1024;
pub const MaxScopes = 8;
pub const MaxLoopDepth = 32;
pub const MaxLoopBreaks = 512;
pub const MaxLoopVars = 2;
pub const MaxTypeAlts = 8;
pub const MaxTypes = 1024; // struct + interface + variant combined
pub const MaxNamedTypes = 512;
pub const MaxSwitchJumps = 1024;
pub const MaxUpvalues = 64;
pub const MaxGlobals = 1024; // funcs + consts combined
pub const MaxExprDepth = 512;
pub const MaxTypeParams = 8;
pub const MaxGenericTypes = 64;
pub const MaxGenericFuncs = 64;
pub const MaxInstantiations = 256;
pub const MaxTypeAliases = 128;

pub const GenericParam = struct {
    name: []const u8,
    constraint: []const u8 = "",
};

pub const GenericTypeKind = enum(u8) { struct_t, variant_t };

pub const GenericTypeInfo = struct {
    name: []const u8,
    kind: GenericTypeKind,
    params: [MaxTypeParams]GenericParam = undefined,
    param_count: u8 = 0,
    template_obj: *Object,
};

pub const GenericFuncInfo = struct {
    name: []const u8 = "",
    params: [MaxTypeParams]GenericParam = undefined,
    param_count: u8 = 0,
    qname: []const u8 = "",
};

pub const TypeAliasInfo = struct {
    name: []const u8,
    target_qname: []const u8,
    target_key: []const u8,
    kind: GenericTypeKind,
};

pub const InstCacheEntry = struct {
    key: []const u8,
    qname: []const u8,
    obj: *Object,
};

pub const Prec = enum(u8) {
    none,
    assign,
    null_coalesce,
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

pub const CompileTimeConst = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
};

pub const TypeCheck = union(enum) {
    none: void,
    prim: PrimType,
    named: []const u8,
    assert_arr: ?FieldTypeSpec,
    assert_map: ?FieldTypeSpec,
    assert_err: void,
    assert_actor_ref: void,
    interface_type: []const u8,
    struct_type: []const u8,
    anon_typed: u16,
};

pub const Local = struct {
    name: []const u8,
    is_const: bool = false,
    from_std: bool = false,
    std_namespace_path: ?[]const u8 = null,
    import_module_path: ?[]const u8 = null,
    is_captured: bool = false,
    type_check: TypeCheck = .{ .none = {} },
};
pub const Upvalue = struct { name: []const u8, index: u8, from_upvalue: bool };
pub const FuncInfo = struct {
    // Slices pre-allocated by Compiler.init() from the compiler's arena.
    // Do NOT assign .{} to a FuncInfo once these are set — use reset() instead.
    locals: []Local,
    upvalues: []Upvalue,
    local_count: u8 = 0,
    upvalue_count: u8 = 0,
    named_return_base: u8 = 0,
    named_return_count: u8 = 0,
    is_named: bool = false,
    has_typed_returns: bool = false,
    // Return-proof tracking (C4). return_prim is set when the function
    // declares exactly one primitive single-alt return type; each return
    // site either proves its value against it or clears all_returns_proven.
    // body_ends_with_return guards the compiler-emitted implicit null
    // return: only when the body's last top-level statement is a return is
    // that implicit site unreachable, making the function-level proof sound.
    return_prim: ?PrimType = null,
    all_returns_proven: bool = true,
    body_ends_with_return: bool = false,
    body_block_depth: u8 = 0,

    /// Reset all count and flag fields without touching the slice pointers.
    /// Use this in place of `self.scopes[N] = .{}`.
    pub fn reset(self: *FuncInfo) void {
        self.local_count = 0;
        self.upvalue_count = 0;
        self.named_return_base = 0;
        self.named_return_count = 0;
        self.is_named = false;
        self.has_typed_returns = false;
        self.return_prim = null;
        self.all_returns_proven = true;
        self.body_ends_with_return = false;
        self.body_block_depth = 0;
    }
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

pub const NamedTypeInfo = struct {
    name: []const u8,
    base: NamedTypeBase,
    runtime_obj: ?*Object = null,
    runtime_const_idx: ?u16 = null,
    has_range: bool = false,
    is_cycle: bool = false,
    is_clamp: bool = false,
    has_predicate: bool = false,
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
// ── Hash-index types for O(1) symbol lookup ─────────────────────────────────
//
// Two open-addressed hash tables cover all compiler symbols:
//
//   type_buckets  — struct, interface, variant, named types.
//                   struct/interface/variant store only a name ([]const u8)
//                   in type_names[sub_idx]; named types also store rich info
//                   in named_types[sub_idx].  A single MaxTypes cap replaces
//                   the old per-category MaxStructTypes/MaxInterfaceTypes/
//                   MaxVariantTypes limits.
//
//   func_buckets  — global functions AND global consts, distinguished by the
//                   is_const flag in the entry.  A single MaxGlobals cap
//                   replaces the old separate MaxGlobalFuncs/MaxGlobalConsts.
//
// TypeHashSize = 4096: load factor < 0.37 at MaxTypes(1024)+MaxNamedTypes(512).
// FuncHashSize = 4096: load factor < 0.25 at MaxGlobals = 1024.

const TypeSymbolKind = enum(u8) { struct_type, interface_type, named_type, variant_type, named_error_type, task_type };
const TypeHashSize = 4096;
const FuncHashSize = 4096;

const TypeHashEntry = struct {
    sub_idx: u16 = 0, // → type_names[] for struct/interface/variant; → named_types[] for named_type
    kind: TypeSymbolKind = .struct_type,
    occupied: bool = false,
};
const FuncHashEntry = struct {
    sub_idx: u16 = 0, // → global_symbols[]
    is_const: bool = false,
    occupied: bool = false,
};

// ─────────────────────────────────────────────────────────────────────────────

/// Snapshot of TypeRegistry count fields; used for checkpoint/rollback during
/// error recovery.  The hash tables are rebuilt from the trimmed arrays on
/// rollback rather than saved in full, keeping the snapshot small.
pub const RegistryCp = struct {
    type_name_count: usize,
    named_type_count: usize,
    global_count: usize,
    generic_count: usize,
    generic_func_count: usize,
    inst_count: usize,
    type_alias_count: usize,
};

pub const TypeRegistry = struct {
    // All array fields are slices allocated from the Compiler's arena via init().
    // TypeRegistry must be initialized via init(), not via struct literal .{}.

    // struct/interface/variant: name only, stored in type_names[].
    type_names: [][]const u8,
    // Parallel kind array so rollback can rebuild the hash without scanning buckets.
    type_name_kinds: []TypeSymbolKind,
    type_name_count: usize = 0,
    // named types: rich info stored in named_types[].
    named_types: []NamedTypeInfo,
    named_type_count: usize = 0,
    // global funcs + consts unified; is_const distinguishes them.
    global_symbols: [][]const u8,
    // Parallel is_const array so rollback can rebuild the func hash.
    global_is_const: []bool,
    global_count: usize = 0,
    // named_return_count for functions that return multiple named values (≥2).
    global_named_return_counts: []u8,
    global_func_objs: []?*Object,

    // Hash indexes — zeroed by init().
    type_buckets: []TypeHashEntry,
    func_buckets: []FuncHashEntry,

    // For each type_names[] slot: if the entry is a variant_type, the compiled
    // *Object is stored here so switchStmt can check arm exhaustiveness.
    variant_objs: []?*Object,
    struct_objs: []?*Object,
    task_objs: []?*Object,
    interface_objs: []?*Object,

    // Generic type templates (not yet instantiated).
    generic_types: []GenericTypeInfo,
    generic_count: usize = 0,
    // Generic function templates.
    generic_funcs: []GenericFuncInfo,
    generic_func_count: usize = 0,
    // Instantiation cache: "Stack[int]" → concrete *Object, reset each compile.
    inst_cache: []InstCacheEntry,
    inst_count: usize = 0,
    // Named aliases of generic instantiations: type IntStack Stack[int]
    type_aliases: []TypeAliasInfo,
    type_alias_count: usize = 0,

    /// Allocate all slice fields from the given allocator and zero-initialize
    /// the hash tables and nullable arrays.  Must be called exactly once before
    /// any other TypeRegistry method.
    pub fn init(self: *TypeRegistry, alloc: std.mem.Allocator) !void {
        self.type_names = try alloc.alloc([]const u8, MaxTypes);
        self.type_name_kinds = try alloc.alloc(TypeSymbolKind, MaxTypes);
        self.type_name_count = 0;
        self.named_types = try alloc.alloc(NamedTypeInfo, MaxNamedTypes);
        self.named_type_count = 0;
        self.global_symbols = try alloc.alloc([]const u8, MaxGlobals);
        self.global_is_const = try alloc.alloc(bool, MaxGlobals);
        self.global_count = 0;
        self.global_named_return_counts = try alloc.alloc(u8, MaxGlobals);
        @memset(self.global_named_return_counts, 0);
        self.global_func_objs = try alloc.alloc(?*Object, MaxGlobals);
        @memset(self.global_func_objs, null);
        self.type_buckets = try alloc.alloc(TypeHashEntry, TypeHashSize);
        @memset(self.type_buckets, .{});
        self.func_buckets = try alloc.alloc(FuncHashEntry, FuncHashSize);
        @memset(self.func_buckets, .{});
        self.variant_objs = try alloc.alloc(?*Object, MaxTypes);
        @memset(self.variant_objs, null);
        self.struct_objs = try alloc.alloc(?*Object, MaxTypes);
        @memset(self.struct_objs, null);
        self.task_objs = try alloc.alloc(?*Object, MaxTypes);
        @memset(self.task_objs, null);
        self.interface_objs = try alloc.alloc(?*Object, MaxTypes);
        @memset(self.interface_objs, null);
        self.generic_types = try alloc.alloc(GenericTypeInfo, MaxGenericTypes);
        self.generic_count = 0;
        self.generic_funcs = try alloc.alloc(GenericFuncInfo, MaxGenericFuncs);
        self.generic_func_count = 0;
        self.inst_cache = try alloc.alloc(InstCacheEntry, MaxInstantiations);
        self.inst_count = 0;
        self.type_aliases = try alloc.alloc(TypeAliasInfo, MaxTypeAliases);
        self.type_alias_count = 0;
    }

    pub fn reset(self: *TypeRegistry) void {
        self.type_name_count = 0;
        self.named_type_count = 0;
        self.global_count = 0;
        @memset(self.global_func_objs[0..], null);
        self.generic_count = 0;
        self.generic_func_count = 0;
        self.inst_count = 0;
        self.type_alias_count = 0;
        @memset(self.type_buckets[0..], .{});
        @memset(self.func_buckets[0..], .{});
        @memset(self.variant_objs[0..], null);
        @memset(self.struct_objs[0..], null);
        @memset(self.task_objs[0..], null);
        @memset(self.interface_objs[0..], null);
    }

    pub fn checkpoint(self: *const TypeRegistry) RegistryCp {
        return .{
            .type_name_count = self.type_name_count,
            .named_type_count = self.named_type_count,
            .global_count = self.global_count,
            .generic_count = self.generic_count,
            .generic_func_count = self.generic_func_count,
            .inst_count = self.inst_count,
            .type_alias_count = self.type_alias_count,
        };
    }

    /// Rewind to a prior checkpoint.  The hash tables are cleared and rebuilt
    /// from the surviving entries so that open-addressing chains stay coherent.
    pub fn rollback(self: *TypeRegistry, cp: RegistryCp) void {
        self.type_name_count = cp.type_name_count;
        self.named_type_count = cp.named_type_count;
        self.global_count = cp.global_count;
        self.generic_count = cp.generic_count;
        self.generic_func_count = cp.generic_func_count;
        self.inst_count = cp.inst_count;
        self.type_alias_count = cp.type_alias_count;

        // Rebuild hash tables from the surviving entries only.
        @memset(self.type_buckets[0..], .{});
        @memset(self.func_buckets[0..], .{});
        for (0..self.type_name_count) |i| {
            self.insertTypeSlot(self.type_names[i], self.type_name_kinds[i], i);
        }
        for (0..self.named_type_count) |i| {
            self.insertTypeSlot(self.named_types[i].name, .named_type, i);
        }
        for (0..self.global_count) |i| {
            const slot = self.funcSlotForInsert(self.global_symbols[i]) orelse continue;
            if (!self.func_buckets[slot].occupied)
                self.func_buckets[slot] = .{
                    .sub_idx = @intCast(i),
                    .is_const = self.global_is_const[i],
                    .occupied = true,
                };
        }
    }

    // ── Hash helpers ──────────────────────────────────────────────────────────

    fn nameAtTypeSlot(self: *const TypeRegistry, idx: usize) []const u8 {
        const e = self.type_buckets[idx];
        return if (e.kind == .named_type)
            self.named_types[e.sub_idx].name
        else
            self.type_names[e.sub_idx];
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

    fn funcSlotFor(self: *const TypeRegistry, name: []const u8, want_const: bool) ?usize {
        const mask: usize = FuncHashSize - 1;
        var idx: usize = @intCast(common.hashBytes(name) & mask);
        for (0..FuncHashSize) |_| {
            const e = self.func_buckets[idx];
            if (!e.occupied) return null;
            if (e.is_const == want_const and common.streq(self.global_symbols[e.sub_idx], name)) return idx;
            idx = (idx + 1) & mask;
        }
        return null;
    }

    fn funcSlotForInsert(self: *const TypeRegistry, name: []const u8) ?usize {
        const mask: usize = FuncHashSize - 1;
        var idx: usize = @intCast(common.hashBytes(name) & mask);
        for (0..FuncHashSize) |_| {
            const e = self.func_buckets[idx];
            if (!e.occupied or common.streq(self.global_symbols[e.sub_idx], name)) return idx;
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
        return self.funcSlotFor(name, true) != null;
    }

    pub fn addGlobalConst(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasGlobalConst(name)) return;
        if (self.global_count >= MaxGlobals) return error.TooManyGlobals;
        const sub_idx = self.global_count;
        self.global_symbols[sub_idx] = name;
        self.global_is_const[sub_idx] = true;
        self.global_count += 1;
        const slot = self.funcSlotForInsert(name) orelse return;
        if (!self.func_buckets[slot].occupied)
            self.func_buckets[slot] = .{ .sub_idx = @intCast(sub_idx), .is_const = true, .occupied = true };
    }

    pub fn addStructType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasStructType(name)) return error.DuplicateStructType;
        if (self.type_name_count >= MaxTypes) return error.TooManyTypes;
        const sub_idx = self.type_name_count;
        self.type_names[sub_idx] = name;
        self.type_name_kinds[sub_idx] = .struct_type;
        self.type_name_count += 1;
        self.insertTypeSlot(name, .struct_type, sub_idx);
    }

    pub fn setStructObj(self: *TypeRegistry, name: []const u8, obj: *Object) void {
        const slot = self.typeSlotFor(name) orelse return;
        const entry = self.type_buckets[slot];
        if (entry.kind != .struct_type) return;
        self.struct_objs[entry.sub_idx] = obj;
    }

    pub fn getStructObj(self: *const TypeRegistry, name: []const u8) ?*Object {
        const slot = self.typeSlotFor(name) orelse return null;
        const entry = self.type_buckets[slot];
        if (entry.kind != .struct_type) return null;
        return self.struct_objs[entry.sub_idx];
    }

    pub fn setInterfaceObj(self: *TypeRegistry, name: []const u8, obj: *Object) void {
        const slot = self.typeSlotFor(name) orelse return;
        const entry = self.type_buckets[slot];
        if (entry.kind != .interface_type) return;
        self.interface_objs[entry.sub_idx] = obj;
    }

    pub fn getInterfaceObj(self: *const TypeRegistry, name: []const u8) ?*Object {
        const slot = self.typeSlotFor(name) orelse return null;
        const entry = self.type_buckets[slot];
        if (entry.kind != .interface_type) return null;
        return self.interface_objs[entry.sub_idx];
    }

    pub fn addInterfaceType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasInterfaceType(name)) return error.DuplicateInterfaceType;
        if (self.type_name_count >= MaxTypes) return error.TooManyTypes;
        const sub_idx = self.type_name_count;
        self.type_names[sub_idx] = name;
        self.type_name_kinds[sub_idx] = .interface_type;
        self.type_name_count += 1;
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

    /// Returns true if a and b are the same type, or one is an ancestor of the other.
    pub fn areNamedTypesCompatible(self: *const TypeRegistry, a: []const u8, b: []const u8) bool {
        if (common.streq(a, b)) return true;
        var cur = a;
        while (self.getNamedTypeInfo(cur)) |info| {
            if (common.streq(cur, b)) return true;
            const parent = info.parent_name orelse break;
            cur = parent;
        }
        cur = b;
        while (self.getNamedTypeInfo(cur)) |info| {
            if (common.streq(cur, a)) return true;
            const parent = info.parent_name orelse break;
            cur = parent;
        }
        return false;
    }

    pub fn addNamedType(self: *TypeRegistry, info: NamedTypeInfo) !void {
        if (self.hasNamedType(info.name)) return error.DuplicateNamedType;
        if (self.named_type_count >= MaxNamedTypes) return error.TooManyNamedTypes;
        const sub_idx = self.named_type_count;
        self.named_types[sub_idx] = info;
        self.named_type_count += 1;
        self.insertTypeSlot(info.name, .named_type, sub_idx);
    }

    pub fn setNamedTypeRuntimeObject(self: *TypeRegistry, name: []const u8, obj: *Object) void {
        const slot = self.typeSlotFor(name) orelse return;
        const entry = self.type_buckets[slot];
        if (entry.kind != .named_type) return;
        self.named_types[entry.sub_idx].runtime_obj = obj;
    }

    pub fn namedTypeRuntimeConstIdx(self: *const TypeRegistry, name: []const u8) ?u16 {
        const slot = self.typeSlotFor(name) orelse return null;
        const entry = self.type_buckets[slot];
        if (entry.kind != .named_type) return null;
        return self.named_types[entry.sub_idx].runtime_const_idx;
    }

    pub fn setNamedTypeRuntimeConstIdx(self: *TypeRegistry, name: []const u8, idx: u16) void {
        const slot = self.typeSlotFor(name) orelse return;
        const entry = self.type_buckets[slot];
        if (entry.kind != .named_type) return;
        self.named_types[entry.sub_idx].runtime_const_idx = idx;
    }

    pub fn hasVariantType(self: *const TypeRegistry, name: []const u8) bool {
        const slot = self.typeSlotFor(name) orelse return false;
        return self.type_buckets[slot].kind == .variant_type;
    }

    pub fn setVariantObj(self: *TypeRegistry, name: []const u8, obj: *Object) void {
        const slot = self.typeSlotFor(name) orelse return;
        const e = self.type_buckets[slot];
        if (e.kind != .variant_type) return;
        self.variant_objs[e.sub_idx] = obj;
    }

    /// Return the unique variant type whose arm set is a superset of `seen_arms`,
    /// or null if zero or more than one type qualifies (ambiguous or unknown).
    pub fn findVariantForArms(self: *const TypeRegistry, seen_arms: []const []const u8) ?*Object {
        var match: ?*Object = null;
        for (0..self.type_name_count) |i| {
            const obj = self.variant_objs[i] orelse continue;
            if (obj.* != .variant_type) continue;
            const arms = obj.variant_type.arms;
            // Every seen arm must be present in this type's arm list.
            var all_match = true;
            for (seen_arms) |sa| {
                var found = false;
                for (arms) |a| {
                    if (common.streq(a.name, sa)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    all_match = false;
                    break;
                }
            }
            if (!all_match) continue;
            if (match != null) return null; // ambiguous
            match = obj;
        }
        return match;
    }

    pub fn hasNamedErrorType(self: *const TypeRegistry, name: []const u8) bool {
        const slot = self.typeSlotFor(name) orelse return false;
        return self.type_buckets[slot].kind == .named_error_type;
    }

    pub fn addNamedErrorType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasNamedErrorType(name)) return error.DuplicateNamedErrorType;
        if (self.hasAnyTypeName(name)) return error.DuplicateNamedType;
        if (self.type_name_count >= MaxTypes) return error.TooManyTypes;
        const sub_idx = self.type_name_count;
        self.type_names[sub_idx] = name;
        self.type_name_kinds[sub_idx] = .named_error_type;
        self.type_name_count += 1;
        self.insertTypeSlot(name, .named_error_type, sub_idx);
    }

    pub fn hasAnyTypeName(self: *const TypeRegistry, name: []const u8) bool {
        return self.typeSlotFor(name) != null or self.hasGenericType(name) or self.hasTypeAlias(name);
    }

    pub fn addVariantType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasVariantType(name)) return error.DuplicateVariantType;
        if (self.type_name_count >= MaxTypes) return error.TooManyTypes;
        const sub_idx = self.type_name_count;
        self.type_names[sub_idx] = name;
        self.type_name_kinds[sub_idx] = .variant_type;
        self.type_name_count += 1;
        self.insertTypeSlot(name, .variant_type, sub_idx);
    }

    pub fn hasTaskType(self: *const TypeRegistry, name: []const u8) bool {
        const slot = self.typeSlotFor(name) orelse return false;
        return self.type_buckets[slot].kind == .task_type;
    }

    pub fn addTaskType(self: *TypeRegistry, name: []const u8) !void {
        if (self.hasTaskType(name)) return error.DuplicateTaskType;
        if (self.type_name_count >= MaxTypes) return error.TooManyTypes;
        const sub_idx = self.type_name_count;
        self.type_names[sub_idx] = name;
        self.type_name_kinds[sub_idx] = .task_type;
        self.type_name_count += 1;
        self.insertTypeSlot(name, .task_type, sub_idx);
    }

    pub fn setTaskObj(self: *TypeRegistry, name: []const u8, obj: *Object) void {
        const slot = self.typeSlotFor(name) orelse return;
        const e = self.type_buckets[slot];
        if (e.kind != .task_type) return;
        self.task_objs[e.sub_idx] = obj;
    }

    pub fn hasGlobalFunc(self: *const TypeRegistry, name: []const u8) bool {
        return self.funcSlotFor(name, false) != null;
    }

    pub fn setGlobalFuncReturnCount(self: *TypeRegistry, name: []const u8, count: u8) void {
        const slot = self.funcSlotFor(name, false) orelse return;
        const sub_idx = self.func_buckets[slot].sub_idx;
        self.global_named_return_counts[sub_idx] = count;
    }

    pub fn getGlobalFuncReturnCount(self: *const TypeRegistry, name: []const u8) u8 {
        const slot = self.funcSlotFor(name, false) orelse return 0;
        const sub_idx = self.func_buckets[slot].sub_idx;
        return self.global_named_return_counts[sub_idx];
    }

    pub fn setGlobalFuncObj(self: *TypeRegistry, name: []const u8, obj: *Object) void {
        const slot = self.funcSlotFor(name, false) orelse return;
        const sub_idx = self.func_buckets[slot].sub_idx;
        self.global_func_objs[sub_idx] = obj;
    }

    pub fn getGlobalFuncObj(self: *const TypeRegistry, name: []const u8) ?*Object {
        const slot = self.funcSlotFor(name, false) orelse return null;
        const sub_idx = self.func_buckets[slot].sub_idx;
        return self.global_func_objs[sub_idx];
    }

    pub fn addGlobalFunc(self: *TypeRegistry, name: []const u8) !void {
        if (self.global_count >= MaxGlobals) return error.TooManyGlobals;
        const sub_idx = self.global_count;
        self.global_symbols[sub_idx] = name;
        self.global_is_const[sub_idx] = false;
        self.global_count += 1;
        const slot = self.funcSlotForInsert(name) orelse return;
        if (!self.func_buckets[slot].occupied)
            self.func_buckets[slot] = .{ .sub_idx = @intCast(sub_idx), .is_const = false, .occupied = true };
    }

    // ── Generic types ─────────────────────────────────────────────────────────

    pub fn hasGenericType(self: *const TypeRegistry, name: []const u8) bool {
        for (self.generic_types[0..self.generic_count]) |*gt| {
            if (common.streq(gt.name, name)) return true;
        }
        return false;
    }

    pub fn getGenericType(self: *const TypeRegistry, name: []const u8) ?*const GenericTypeInfo {
        for (self.generic_types[0..self.generic_count]) |*gt| {
            if (common.streq(gt.name, name)) return gt;
        }
        return null;
    }

    pub fn addGenericType(self: *TypeRegistry, info: GenericTypeInfo) !void {
        if (self.generic_count >= MaxGenericTypes) return error.TooManyTypes;
        self.generic_types[self.generic_count] = info;
        self.generic_count += 1;
    }

    // ── Generic functions ─────────────────────────────────────────────────────

    pub fn hasGenericFunc(self: *const TypeRegistry, name: []const u8) bool {
        for (self.generic_funcs[0..self.generic_func_count]) |*gf| {
            if (common.streq(gf.name, name)) return true;
        }
        return false;
    }

    pub fn getGenericFunc(self: *const TypeRegistry, name: []const u8) ?*const GenericFuncInfo {
        for (self.generic_funcs[0..self.generic_func_count]) |*gf| {
            if (common.streq(gf.name, name)) return gf;
        }
        return null;
    }

    pub fn addGenericFunc(self: *TypeRegistry, info: GenericFuncInfo) !void {
        if (self.generic_func_count >= MaxGenericFuncs) return error.TooManyTypes;
        self.generic_funcs[self.generic_func_count] = info;
        self.generic_func_count += 1;
    }

    pub fn getCachedInst(self: *const TypeRegistry, key: []const u8) ?InstCacheEntry {
        for (self.inst_cache[0..self.inst_count]) |e| {
            if (common.streq(e.key, key)) return e;
        }
        return null;
    }

    pub fn getCachedInstByQname(self: *const TypeRegistry, qname: []const u8) ?InstCacheEntry {
        for (self.inst_cache[0..self.inst_count]) |e| {
            if (common.streq(e.qname, qname)) return e;
        }
        return null;
    }

    pub fn addInstCache(self: *TypeRegistry, entry: InstCacheEntry) !void {
        if (self.inst_count >= MaxInstantiations) return error.TooManyInstantiations;
        self.inst_cache[self.inst_count] = entry;
        self.inst_count += 1;
    }

    pub fn hasTypeAlias(self: *const TypeRegistry, name: []const u8) bool {
        for (self.type_aliases[0..self.type_alias_count]) |*a| {
            if (common.streq(a.name, name)) return true;
        }
        return false;
    }

    pub fn getTypeAlias(self: *const TypeRegistry, name: []const u8) ?TypeAliasInfo {
        for (self.type_aliases[0..self.type_alias_count]) |a| {
            if (common.streq(a.name, name)) return a;
        }
        return null;
    }

    pub fn addTypeAlias(self: *TypeRegistry, info: TypeAliasInfo) !void {
        if (self.hasTypeAlias(info.name)) return error.DuplicateTypeName;
        if (self.type_alias_count >= MaxTypeAliases) return error.TooManyTypes;
        self.type_aliases[self.type_alias_count] = info;
        self.type_alias_count += 1;
    }
};
