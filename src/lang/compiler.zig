const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const lexer_mod = @import("lexer.zig");
const op_mod = @import("op.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");
const ct = @import("compiler_types.zig");
const std_schema = @import("std_schema.zig");
const compiler_decls = @import("compiler_decls.zig");
const compiler_stmts = @import("compiler_stmts.zig");
const compiler_expr = @import("compiler_expr.zig");

const Lexer = lexer_mod.Lexer;
const FieldTypeAlt = value_mod.FieldTypeAlt;
const FieldTypeSpec = value_mod.FieldTypeSpec;
const Op = op_mod.Op;
const FieldTypeTag = value_mod.FieldTypeTag;
const StructFieldSpec = value_mod.StructFieldSpec;
const TT = token.TT;
const Token = token.Token;
const Object = value_mod.Object;
const StructTypeObj = value_mod.StructTypeObj;
const InterfaceMethodSpec = value_mod.InterfaceMethodSpec;
const InterfaceTypeObj = value_mod.InterfaceTypeObj;
const NamedTypeObj = value_mod.NamedTypeObj;
const NamedTypeBase = value_mod.NamedTypeBase;
const VariantArmSpec = value_mod.VariantArmSpec;
const VariantTypeObj = value_mod.VariantTypeObj;
const Value = value_mod.Value;

const MaxLocals = ct.MaxLocals;
const MaxScopes = ct.MaxScopes;
const MaxLoopDepth = ct.MaxLoopDepth;
const MaxLoopBreaks = ct.MaxLoopBreaks;
const MaxTypeAlts = ct.MaxTypeAlts;
const MaxStructTypes = ct.MaxStructTypes;
const MaxInterfaceTypes = ct.MaxInterfaceTypes;
const MaxNamedTypes = ct.MaxNamedTypes;
const MaxVariantTypes = ct.MaxVariantTypes;
const MaxSwitchJumps = ct.MaxSwitchJumps;
const MaxUpvalues = ct.MaxUpvalues;
const MaxGlobalConsts = ct.MaxGlobalConsts;
const MaxExprDepth = ct.MaxExprDepth;

const Prec = ct.Prec;
const Local = ct.Local;
const Upvalue = ct.Upvalue;
const FuncInfo = ct.FuncInfo;
const LoopCtx = ct.LoopCtx;
const NamedTypeInfo = ct.NamedTypeInfo;
const AssignTargetStep = ct.AssignTargetStep;
const AssignTarget = ct.AssignTarget;
const MultiAssignValueScratch = ct.MultiAssignValueScratch;
const TypeRegistry = ct.TypeRegistry;
const TypeCheck = ct.TypeCheck;

pub const ImportResolverFn = *const fn (ctx: *anyopaque, importer_path: []const u8, import_name: []const u8) anyerror![]const u8;

pub const CompilerOptions = struct {
    module_path: []const u8 = "",
    module_prefix: []const u8 = "",
    module_struct_name: []const u8 = "",
    module_global_name: []const u8 = "",
    module_ctx: ?*anyopaque = null,
    resolve_import: ?ImportResolverFn = null,
    has_module_export: ?*const fn (ctx: *anyopaque, path: []const u8, field: []const u8) bool = null,
    test_mode: bool = false,
    repl_mode: bool = false,
    check_global_exists: ?*const fn (ctx: *anyopaque, name: []const u8) bool = null,
    check_global_is_const: ?*const fn (ctx: *anyopaque, name: []const u8) bool = null,
    check_global_ctx: ?*anyopaque = null,
};

const ExportEntry = struct {
    name: []const u8,
    global_name: []const u8,
};

pub const Compiler = struct {
    lex: Lexer,
    prev: Token = undefined,
    cur: Token = undefined,
    scopes: [MaxScopes]FuncInfo = undefined,
    scope_depth: u8 = 0,
    loops: [MaxLoopDepth]LoopCtx = undefined,
    loop_depth: u8 = 0,
    expr_depth: u16 = 0,
    registry: TypeRegistry = .{},
    last_func_obj: ?*@import("value.zig").Object = null,
    peek_tok: ?Token = null,
    options: CompilerOptions = .{},
    exports: [MaxLocals]ExportEntry = undefined,
    export_count: u8 = 0,
    err_msg_buf: [512]u8 = undefined,
    err_msg_len: u16 = 0,
    err_col: u32 = 0,
    err_line: u32 = 0,

    std_namespace_path: ?[]const u8 = null,
    std_module_global_names: [MaxLocals][]const u8 = undefined,
    std_module_global_count: u8 = 0,
    import_module_path: ?[]const u8 = null,
    import_module_global_qnames: [MaxLocals][]const u8 = undefined,
    import_module_global_paths: [MaxLocals][]const u8 = undefined,
    import_module_global_count: u8 = 0,
    typed_global_names: [MaxLocals][]const u8 = undefined,
    typed_global_type_checks: [MaxLocals]TypeCheck = undefined,
    typed_global_count: u8 = 0,

    test_names: [MaxLocals][]const u8 = undefined,
    test_count: u8 = 0,

    repl_expr_ok: bool = true,
    repl_expr_pop_pos: ?usize = null,
    in_loop_init: bool = false,

    // ── Lifecycle ────────────────────────────────────────────────────────────────

    pub fn init(src: []const u8, options: CompilerOptions) Compiler {
        var c = Compiler{ .lex = .{ .src = src }, .options = options };
        c.scopes[0] = .{};
        c.scope_depth = 1;
        return c;
    }

    pub fn compile(self: *Compiler, emit_halt: bool) !void {
        if (!self.options.repl_mode) self.registry.reset();
        self.export_count = 0;
        self.err_msg_len = 0;
        self.err_col = 0;
        self.err_line = 0;
        self.expr_depth = 0;
        self.repl_expr_ok = true;
        self.repl_expr_pop_pos = null;
        self.advance();
        while (!self.check(.eof)) {
            if (self.cur.typ == .err_invalid_char) {
                self.setErr("invalid character '{c}'", .{self.cur.src[0]});
                self.err_col = self.cur.col;
                return error.InvalidChar;
            }
            if (self.cur.typ == .err_unterminated_string) {
                self.setErr("unterminated string literal", .{});
                self.err_col = self.cur.col;
                return error.UnterminatedString;
            }
            if (self.cur.typ == .err_string_pool_exhausted) {
                self.setErr("string pool exhausted (max {d}KB)", .{lexer_mod.StrPoolSize / 1024});
                self.err_col = self.cur.col;
                return error.UnterminatedString;
            }
            self.repl_expr_ok = true;
            try self.decl();
        }
        if (self.options.repl_mode) {
            if (self.repl_expr_pop_pos) |pos| {
                chunk.g_state.code[pos] = @intFromEnum(Op.repl_print);
            }
        }
        if (emit_halt) try chunk.emitOp(.halt, self.prev.line);
    }

    // ── Error reporting helpers ──────────────────────────────────────────────────

    pub fn setErr(self: *Compiler, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.err_msg_buf[0..], fmt, args) catch "error";
        self.err_msg_len = @intCast(s.len);
    }

    pub fn err(self: *Compiler, comptime fmt: []const u8, args: anytype) anyerror {
        self.setErr(fmt, args);
        self.err_col = @intCast(self.cur.col);
        self.err_line = self.cur.line;
        return error.UnexpectedToken;
    }

    pub fn tokenName(self: *Compiler, tt: TT) []const u8 {
        _ = self;
        return switch (tt) {
            .eof => "end of file",
            .err_invalid_char => "invalid character",
            .err_unterminated_string => "unterminated string",
            .err_string_pool_exhausted => "string pool exhausted",
            .ident => "identifier",
            .number => "number",
            .string => "string",
            .rune => "rune literal",
            .kw_true => "'true'",
            .kw_false => "'false'",
            .kw_null => "'null'",
            .kw_if => "'if'",
            .kw_else => "'else'",
            .kw_for => "'for'",
            .kw_in => "'in'",
            .kw_switch => "'switch'",
            .kw_case => "'case'",
            .kw_default => "'default'",
            .kw_return => "'return'",
            .kw_func => "'func'",
            .kw_struct => "'struct'",
            .kw_interface => "'interface'",
            .kw_type => "'type'",
            .kw_range => "'range'",
            .kw_cycle => "'cycle'",
            .kw_enum => "'enum'",
            .kw_import => "'import'",
            .kw_var => "'var'",
            .kw_const => "'const'",
            .kw_break => "'break'",
            .kw_continue => "'continue'",
            .kw_defer => "'defer'",
            .kw_assert => "'assert'",
            .kw_trap => "'trap'",
            .kw_variant => "'variant'",
            .kw_subtype => "'subtype'",
            .kw_pub => "'pub'",
            .kw_test => "'test'",
            .kw_message => "'message'",
            .kw_predicate => "'predicate'",
            .lparen => "'('",
            .rparen => "')'",
            .lbrace => "'{'",
            .rbrace => "'}'",
            .lbracket => "'['",
            .rbracket => "']'",
            .comma => "','",
            .semicolon => "';'",
            .colon => "':'",
            .dot => "'.'",
            .dotdot => "'..'",
            .ellipsis => "'...'",
            .question => "'?'",
            .plus => "'+'",
            .minus => "'-'",
            .star => "'*'",
            .star_star => "'**'",
            .slash => "'/'",
            .percent => "'%'",
            .tilde => "'~'",
            .caret => "'^'",
            .amp => "'&'",
            .bang => "'!'",
            .pipe => "'|'",
            .amp_amp => "'&&'",
            .pipe_pipe => "'||'",
            .bang_eq => "'!='",
            .eq => "'='",
            .eq_eq => "'=='",
            .lt => "'<'",
            .lt_eq => "'<='",
            .gt => "'>'",
            .gt_eq => "'>='",
            .colon_eq => ":='",
            .plus_eq => "'+='",
            .minus_eq => "'-='",
            .star_eq => "'*='",
            .slash_eq => "'/='",
            .percent_eq => "'%='",
            .amp_eq => "'&='",
            .pipe_eq => "'|='",
            .caret_eq => "'^='",
            .lt_lt => "'<<'",
            .gt_gt => "'>>'",
            .lt_lt_eq => "'<<='",
            .gt_gt_eq => "'>>='",
            .plus_plus => "'++'",
            .minus_minus => "'--'",
        };
    }

    pub fn emitModuleObject(self: *Compiler) !void {
        if (self.options.module_global_name.len == 0) return;

        const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        any_alts[0] = .{ .typ = .any };
        const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

        const fields = heap.bump(StructFieldSpec, self.export_count) orelse return error.OutOfMemory;
        var i: usize = 0;
        while (i < self.export_count) : (i += 1) {
            fields[i] = .{ .name = self.exports[i].name, .typ = any_spec, .is_const = true };
        }

        const st = heap.allocObject() orelse return error.OutOfMemory;
        const struct_name = if (self.options.module_struct_name.len != 0) self.options.module_struct_name else self.options.module_prefix;
        st.* = .{ .struct_type = StructTypeObj{ .name = self.copyName(self.moduleBaseName()) catch struct_name, .qualified_name = struct_name, .fields = fields[0..self.export_count] } };
        try chunk.emitConst(.{ .object = st }, self.prev.line);

        i = 0;
        while (i < self.export_count) : (i += 1) {
            try chunk.emitConst(.{ .string = self.exports[i].name }, self.prev.line);
            try chunk.emitGetGlobal(self.exports[i].global_name, self.prev.line);
        }
        try chunk.emit2(@intFromEnum(Op.build_struct_instance), self.export_count, self.prev.line);
        try chunk.emitOpConst(.def_global, .{ .string = self.options.module_global_name }, self.prev.line);
    }

    // ── Scope and variable resolution ────────────────────────────────────────────

    pub fn inFunc(self: *Compiler) bool {
        return self.scope_depth > 1;
    }

    pub fn currentScope(self: *Compiler) *FuncInfo {
        return &self.scopes[self.scope_depth - 1];
    }

    pub fn resolveLocal(self: *Compiler, name: []const u8) ?u8 {
        const scope = self.currentScope();
        var i: u8 = scope.local_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(scope.locals[i].name, name)) return i;
        }
        return null;
    }

    pub fn defineLocal(self: *Compiler, name: []const u8, is_const: bool) !u8 {
        const scope = self.currentScope();
        if (scope.local_count >= MaxLocals) { self.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
        const slot = scope.local_count;
        scope.locals[slot] = .{ .name = name, .is_const = is_const };
        scope.local_count += 1;
        return slot;
    }

    fn resolveLocalConst(self: *Compiler, name: []const u8) ?bool {
        const scope = self.currentScope();
        var i: u8 = scope.local_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(scope.locals[i].name, name)) return scope.locals[i].is_const;
        }
        return null;
    }

    pub fn emitGetVar(self: *Compiler, name: Token) !void {
        chunk.setCol(name.col);
        if (self.resolveLocal(name.src)) |slot| {
            try chunk.emit2(@intFromEnum(Op.get_local), slot, name.line);
            const local = self.currentScope().locals[slot];
            if (local.from_std) {
                self.std_namespace_path = "";
                self.import_module_path = null;
            } else if (local.import_module_path) |path| {
                self.import_module_path = path;
                self.std_namespace_path = null;
            } else {
                self.std_namespace_path = null;
                self.import_module_path = null;
            }
        } else if (self.resolveUpvalue(name.src)) |uv| {
            try chunk.emit2(@intFromEnum(Op.get_upvalue), uv, name.line);
            self.std_namespace_path = null;
            self.import_module_path = null;
        } else {
            const qname = try self.qualifyGlobalName(name.src);
            try chunk.emitGetGlobal(qname, name.line);
            if (self.isStdModuleGlobal(qname)) {
                self.std_namespace_path = "";
                self.import_module_path = null;
            } else if (self.getImportModuleGlobalPath(qname)) |path| {
                self.import_module_path = path;
                self.std_namespace_path = null;
            } else {
                self.std_namespace_path = null;
                self.import_module_path = null;
            }
        }
    }

    fn isStdModuleGlobal(self: *Compiler, name: []const u8) bool {
        var i: u8 = 0;
        while (i < self.std_module_global_count) : (i += 1) {
            if (common.streq(self.std_module_global_names[i], name)) return true;
        }
        return false;
    }

    fn getImportModuleGlobalPath(self: *Compiler, name: []const u8) ?[]const u8 {
        var i: u8 = 0;
        while (i < self.import_module_global_count) : (i += 1) {
            if (common.streq(self.import_module_global_qnames[i], name)) return self.import_module_global_paths[i];
        }
        return null;
    }

    pub fn emitSetVar(self: *Compiler, name: Token) !void {
        if (self.resolveLocal(name.src)) |slot| {
            try chunk.emit2(@intFromEnum(Op.set_local), slot, name.line);
        } else if (self.resolveUpvalue(name.src)) |uv| {
            try chunk.emit2(@intFromEnum(Op.set_upvalue), uv, name.line);
        } else {
            try chunk.emitSetGlobal(try self.qualifyGlobalName(name.src), name.line);
        }
    }

    pub fn getLocalTypeCheck(self: *Compiler, name: []const u8) ?TypeCheck {
        if (self.resolveLocal(name)) |slot| {
            return self.currentScope().locals[slot].type_check;
        }
        const qname = self.qualifyGlobalName(name) catch return null;
        var i: u8 = 0;
        while (i < self.typed_global_count) : (i += 1) {
            if (common.streq(self.typed_global_names[i], qname)) return self.typed_global_type_checks[i];
        }
        return null;
    }

    pub fn emitVarTypeProlog(_: *Compiler, tc: TypeCheck, line: u32) !void {
        if (tc == .named) {
            try chunk.emitGetGlobal(tc.named, line);
        }
    }

    pub fn emitVarTypeEpilog(_: *Compiler, tc: TypeCheck, line: u32) !void {
        switch (tc) {
            .none => {},
            .prim => |p| try chunk.emitOp(switch (p) {
                .int => .cast_int,
                .float => .cast_float,
                .decimal => .cast_decimal,
                .bool => .cast_bool,
                .string => .cast_string,
                .rune => .cast_rune,
            }, line),
            .named => try chunk.emit2(@intFromEnum(Op.call), 1, line),
            .assert_arr => try chunk.emit2(@intFromEnum(Op.assert_type), 1, line),
            .assert_map => try chunk.emit2(@intFromEnum(Op.assert_type), 2, line),
            .assert_err => try chunk.emit2(@intFromEnum(Op.assert_type), 3, line),
        }
    }

    fn resolveUpvalue(self: *Compiler, name: []const u8) ?u8 {
        if (self.scope_depth == 0) return null;
        return self.resolveUpvalueForScope(self.scope_depth, name);
    }

    fn resolveUpvalueConstForScope(self: *Compiler, scope_index: u8, name: []const u8) ?bool {
        if (scope_index == 0) return null;
        const enclosing_index: u8 = scope_index - 1;
        const enclosing = &self.scopes[enclosing_index];
        var i: u8 = enclosing.local_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(enclosing.locals[i].name, name)) return enclosing.locals[i].is_const;
        }
        return self.resolveUpvalueConstForScope(enclosing_index, name);
    }

    fn resolveUpvalueConst(self: *Compiler, name: []const u8) ?bool {
        if (self.scope_depth == 0) return null;
        return self.resolveUpvalueConstForScope(self.scope_depth, name);
    }

    pub fn ensureMutableBinding(self: *Compiler, name: Token) !void {
        if (self.resolveLocalConst(name.src)) |is_const| {
            if (is_const) return self.constAssignErr(name);
            return;
        }
        if (self.resolveUpvalueConst(name.src)) |is_const| {
            if (is_const) return self.constAssignErr(name);
            return;
        }
        if (self.registry.hasGlobalConst(name.src)) return self.constAssignErr(name);
        if (self.options.check_global_is_const) |f| {
            if (f(self.options.check_global_ctx.?, name.src)) return self.constAssignErr(name);
        }
    }

    fn constAssignErr(self: *Compiler, name: Token) anyerror {
        self.setErr("cannot assign to const variable '{s}'", .{name.src});
        self.err_line = name.line;
        self.err_col = @intCast(name.col);
        return error.AssignToConst;
    }

    fn addUpvalueToScope(self: *Compiler, scope_index: u8, name: []const u8, index: u8, from_upvalue: bool) ?u8 {
        const scope = &self.scopes[scope_index];
        var u: u8 = 0;
        while (u < scope.upvalue_count) : (u += 1) {
            if (common.streq(scope.upvalues[u].name, name) and scope.upvalues[u].index == index and scope.upvalues[u].from_upvalue == from_upvalue) return u;
        }
        if (scope.upvalue_count >= MaxUpvalues) return null;
        const idx = scope.upvalue_count;
        scope.upvalues[idx] = .{ .name = name, .index = index, .from_upvalue = from_upvalue };
        scope.upvalue_count += 1;
        return idx;
    }

    // scope_index is the function scope that wants to capture `name` from its enclosing scope.
    fn resolveUpvalueForScope(self: *Compiler, scope_index: u8, name: []const u8) ?u8 {
        if (scope_index == 0) return null;
        const enclosing_index: u8 = scope_index - 1;
        const enclosing = &self.scopes[enclosing_index];
        var i: u8 = enclosing.local_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(enclosing.locals[i].name, name)) {
                enclosing.locals[i].is_captured = true;
                return self.addUpvalueToScope(scope_index, name, i, false);
            }
        }

        const parent_up = self.resolveUpvalueForScope(enclosing_index, name) orelse return null;
        return self.addUpvalueToScope(scope_index, name, parent_up, true);
    }

    pub fn cleanupLocals(self: *Compiler, base: u8, line: u32) !void {
        if (self.scope_depth <= 1) return;
        const scope = self.currentScope();
        while (scope.local_count > base) {
            const idx = scope.local_count - 1;
            if (scope.locals[idx].is_captured) {
                try chunk.emit2(@intFromEnum(Op.close_upvalue), idx, line);
            }
            try chunk.emitOp(.pop, line);
            scope.local_count -= 1;
        }
    }

    // ── Loop context ─────────────────────────────────────────────────────────────

    pub fn loopKeepBase(self: *Compiler) u8 {
        if (self.scope_depth <= 1) return 0;
        return self.currentScope().local_count;
    }

    pub fn pushLoop(self: *Compiler, continue_target: usize, local_keep: u8, body_keep: u8, iter_pops: u8) !void {
        if (self.loop_depth >= MaxLoopDepth) { self.setErr("too many nested loops (max {d})", .{MaxLoopDepth}); return error.TooManyNestedLoops; }
        self.loops[self.loop_depth] = .{
            .continue_target = continue_target,
            .local_keep = local_keep,
            .body_keep = body_keep,
            .iter_pops = iter_pops,
        };
        self.loop_depth += 1;
    }

    pub fn popLoop(self: *Compiler) LoopCtx {
        self.loop_depth -= 1;
        return self.loops[self.loop_depth];
    }

    pub fn currentLoop(self: *Compiler) *LoopCtx {
        return &self.loops[self.loop_depth - 1];
    }

    pub fn emitBreak(self: *Compiler, line: u32) !void {
        if (self.loop_depth == 0) { self.setErr("'break' outside of loop", .{}); return error.BreakOutsideLoop; }
        const loop = self.currentLoop();
        // Save so code after the if-break block sees the correct local count (non-break path).
        const saved: u8 = if (self.inFunc()) self.currentScope().local_count else 0;
        try self.cleanupLocals(loop.body_keep, line);
        var p: u8 = 0;
        while (p < loop.iter_pops) : (p += 1) try chunk.emitOp(.pop, line);
        for (loop.loop_var_slots[0..loop.loop_var_count]) |slot| {
            try chunk.emit2(@intFromEnum(Op.close_upvalue), slot, line);
        }
        try self.cleanupLocals(loop.local_keep, line);
        const off = try chunk.emitJump(.jump, line);
        if (loop.break_count >= MaxLoopBreaks) { self.setErr("too many 'break' statements in loop (max {d})", .{MaxLoopBreaks}); return error.TooManyBreaksInLoop; }
        loop.break_offsets[loop.break_count] = off;
        loop.break_count += 1;
        if (self.inFunc()) self.currentScope().local_count = saved;
    }

    pub fn emitContinue(self: *Compiler, line: u32) !void {
        if (self.loop_depth == 0) { self.setErr("'continue' outside of loop", .{}); return error.ContinueOutsideLoop; }
        const loop = self.currentLoop();
        const saved: u8 = if (self.inFunc()) self.currentScope().local_count else 0;
        try self.cleanupLocals(loop.body_keep, line);
        for (loop.loop_var_slots[0..loop.loop_var_count]) |slot| {
            try chunk.emit2(@intFromEnum(Op.close_upvalue), slot, line);
        }
        try chunk.emitLoop(loop.continue_target, line);
        if (self.inFunc()) self.currentScope().local_count = saved;
    }

    // ── Top-level dispatch ───────────────────────────────────────────────────────

    pub fn decl(self: *Compiler) anyerror!void {
        if (self.match(.kw_pub)) {
            if (self.inFunc()) { self.setErr("invalid 'pub' target", .{}); return error.InvalidPubTarget; }
            try self.pubDecl();
        } else if (self.match(.kw_test)) {
            try self.testDecl();
        } else if (self.match(.kw_var)) {
            try self.varDecl(true, false);
        } else if (self.check(.ident) and self.peekTT() == .colon_eq) {
            try self.varDecl(false, false);
        } else if (self.match(.kw_const)) {
            try self.varDecl(true, true);
        } else if (self.check(.kw_type)) {
            try self.namedTypeDecl(false);
        } else if (self.check(.kw_subtype)) {
            try self.subtypeDecl(false);
        } else if (self.check(.kw_func) and self.isMethodDecl()) {
            try self.methodDecl();
        } else if (self.check(.kw_func) and self.isNamedFuncDecl()) {
            try self.namedFuncDecl(false);
        } else {
            try self.stmt();
        }
    }

    fn testDecl(self: *Compiler) !void {
        const line = self.prev.line;
        if (self.cur.typ != .string) return self.err("expected test name string, found {s}", .{self.tokenName(self.cur.typ)});
        const label = self.cur.src;
        self.advance();

        if (!self.options.test_mode) {
            // Normal mode: parse the body but discard emitted code.
            var tmp_state: chunk.State = .{};
            const saved_state = chunk.g_state;
            chunk.setActive(&tmp_state);
            defer chunk.setActive(saved_state);

            try self.consume(.lbrace);
            while (!self.check(.rbrace) and !self.check(.eof)) try self.decl();
            try self.consume(.rbrace);
            return;
        }

        // Test mode: emit the test block as a zero-arity function.
        if (self.test_count >= MaxLocals) return self.err("too many test blocks (max {d})", .{MaxLocals});
        const idx = self.test_count;
        self.test_count += 1;
        self.test_names[idx] = label;

        const name_buf = heap.bump(u8, 32) orelse return error.OutOfMemory;
        const name_str = std.fmt.bufPrint(name_buf[0..32], "__test_{d}", .{idx}) catch return error.OutOfMemory;

        const jump_over = try chunk.emitJump(.jump, line);
        const func_ip = chunk.codeLen();

        if (self.scope_depth >= MaxScopes) return error.TooManyNestedFunctions;
        self.scopes[self.scope_depth] = .{};
        self.scope_depth += 1;
        const scope = self.currentScope();
        scope.is_named = false;
        scope.has_typed_returns = false;

        try self.consume(.lbrace);
        const saved = self.repl_expr_ok;
        self.repl_expr_ok = false;
        while (!self.check(.rbrace) and !self.check(.eof)) try self.decl();
        try self.consume(.rbrace);
        self.repl_expr_ok = saved;
        try self.cleanupLocals(0, self.prev.line);
        try chunk.emitOp(.ret, self.prev.line);

        self.scope_depth -= 1;
        try chunk.patchJump(jump_over);

        const func_obj = heap.allocObject() orelse return error.OutOfMemory;
        func_obj.* = .{ .function = .{
            .ip = func_ip,
            .arity = 0,
            .is_variadic = false,
            .variadic_type = .{ .alts = @constCast(&[_]FieldTypeAlt{.{ .typ = .any }}) },
            .capture_slots = &[_]u8{},
            .param_types = &[_]FieldTypeSpec{},
            .has_typed_params = false,
            .return_types = &[_]FieldTypeSpec{},
            .has_typed_returns = false,
            .named_return_count = 0,
        } };
        self.last_func_obj = func_obj;
        const cidx: u16 = try chunk.addConst(.{ .object = func_obj });
        try chunk.emitConstIdx(.make_closure, cidx, self.prev.line);
        try chunk.emitOpConst(.def_global, .{ .string = name_str }, line);
    }

    fn pubDecl(self: *Compiler) !void {
        if (self.match(.kw_const)) {
            const name = self.cur.src;
            try self.varDecl(true, true);
            try self.addExport(name, try self.qualifyGlobalName(name));
            return;
        }
        if (self.check(.kw_type)) {
            try self.namedTypeDecl(true);
            return;
        }
        if (self.check(.kw_subtype)) {
            try self.subtypeDecl(true);
            return;
        }
        if (self.check(.kw_func) and self.isNamedFuncDecl()) {
            try self.namedFuncDecl(true);
            return;
        }
        return { self.setErr("invalid 'pub' target", .{}); return error.InvalidPubTarget; };
    }

    // ── Type declarations ────────────────────────────────────────────────────────


    pub fn advance(self: *Compiler) void {
        self.prev = self.cur;
        if (self.peek_tok) |t| {
            self.cur = t;
            self.peek_tok = null;
        } else {
            self.cur = self.lex.next();
        }
        chunk.setCol(self.prev.col);
    }

    pub fn peekToken(self: *Compiler) Token {
        if (self.peek_tok == null) self.peek_tok = self.lex.next();
        return self.peek_tok.?;
    }
    pub fn check(self: *Compiler, tt: TT) bool {
        return self.cur.typ == tt;
    }
    pub fn match(self: *Compiler, tt: TT) bool {
        if (!self.check(tt)) return false;
        self.advance();
        return true;
    }
    pub fn matchOpt(self: *Compiler, tt: TT) void {
        _ = self.match(tt);
    }
    pub fn consume(self: *Compiler, tt: TT) !void {
        if (self.cur.typ == tt) {
            self.advance();
            return;
        }
        self.setErr("expected {s}, found {s}", .{ self.tokenName(tt), self.tokenName(self.cur.typ) });
        self.err_col = self.cur.col;
        self.err_line = self.cur.line;
        return error.UnexpectedToken;
    }
    pub fn peekTT(self: *Compiler) TT {
        var lx = self.lex;
        return lx.next().typ;
    }

    // ── Module and name helpers ──────────────────────────────────────────────────

    pub fn qualifyGlobalName(self: *Compiler, name: []const u8) ![]const u8 {
        if (self.options.module_prefix.len == 0) return name;
        const total = self.options.module_prefix.len + 1 + name.len;
        const buf = heap.bump(u8, total) orelse return error.OutOfMemory;
        @memcpy(buf[0..self.options.module_prefix.len], self.options.module_prefix);
        buf[self.options.module_prefix.len] = '.';
        @memcpy(buf[self.options.module_prefix.len + 1 .. total], name);
        return buf[0..total];
    }

    pub fn qualifyTypeName(self: *Compiler, name: []const u8) ![]const u8 {
        return self.qualifyGlobalName(name);
    }

    // True for primitive type names and every registered named/struct/
    // interface/variant type — identifiers that binding forms must not shadow.
    pub fn isKnownTypeName(self: *Compiler, name: []const u8) bool {
        const prims = [_][]const u8{ "int", "float", "bool", "string", "rune", "decimal", "error", "any", "map" };
        for (prims) |p| {
            if (common.streq(name, p)) return true;
        }
        return self.registry.hasNamedType(name) or self.registry.hasStructTypeLocal(name) or
            self.registry.hasInterfaceType(name) or self.registry.hasVariantType(name);
    }

    pub fn addExport(self: *Compiler, name: []const u8, global_name: []const u8) !void {
        const stable_name = try self.copyName(name);
        var i: usize = 0;
        while (i < self.export_count) : (i += 1) {
            if (common.streq(self.exports[i].name, stable_name)) { self.setErr("duplicate export name '{s}'", .{stable_name}); return error.DuplicateExport; }
        }
        if (self.export_count >= MaxLocals) { self.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
        self.exports[self.export_count] = .{ .name = stable_name, .global_name = global_name };
        self.export_count += 1;
    }

    // Returns true when the current token is a var name followed by a type and '='.
    // Matches: name type = expr  (space-syntax typed declaration, no keyword needed)
    pub fn isTypedVarDecl(self: *Compiler) bool {
        var lx = self.lex;
        var t = lx.next(); // token after the var name
        if (t.typ == .question) t = lx.next(); // skip optional nullable prefix
        if (t.typ == .lbracket) {
            // No space between name and '[' → index expression (e.g. m[k] = v),
            // not a typed declaration (e.g. m [int] = v).
            if (self.cur.col + self.cur.src.len == t.col) return false;
            t = lx.next(); // token after '['
            if (t.typ == .rbracket) {
                // []T = expr: scan element type for '='
                var depth: i32 = 0;
                t = lx.next();
                while (true) {
                    switch (t.typ) {
                        .lparen, .lbracket => depth += 1,
                        .rparen, .rbracket => depth -= 1,
                        .eq => if (depth == 0) return true,
                        .lbrace, .semicolon, .eof => return false,
                        else => {},
                    }
                    t = lx.next();
                }
            }
            if (t.typ != .ident and t.typ != .kw_func and t.typ != .lbracket and t.typ != .question) return false;
            // [T] or [K]V: scan through type(s) to matching ']'
            var depth: i32 = 0;
            while (t.typ != .rbracket or depth > 0) {
                switch (t.typ) {
                    .lparen, .lbracket => depth += 1,
                    .rparen, .rbracket => depth -= 1,
                    .lbrace, .semicolon, .eof => return false,
                    else => {},
                }
                t = lx.next();
            }
            t = lx.next(); // consume ']'
            // Scan forward for '=' at depth 0 (handles [K]V where V follows ']')
            while (true) {
                switch (t.typ) {
                    .lparen, .lbracket => depth += 1,
                    .rparen, .rbracket => depth -= 1,
                    .eq => if (depth == 0) return true,
                    .lbrace, .semicolon, .eof => return false,
                    else => {},
                }
                t = lx.next();
            }
        }
        if (t.typ == .kw_func) {
            // func(T...) R = expr: scan forward tracking paren depth to find '='
            var depth: i32 = 0;
            while (true) {
                switch (t.typ) {
                    .lparen, .lbracket => depth += 1,
                    .rparen, .rbracket => depth -= 1,
                    .eq => if (depth == 0) return true,
                    .lbrace, .semicolon, .eof => return false,
                    else => {},
                }
                t = lx.next();
            }
        }
        if (t.typ != .ident) return false;
        t = lx.next(); // token after the type ident
        // Skip map[K]V or other parameterized types with brackets
        if (t.typ == .lbracket) {
            var depth: i32 = 0;
            while (true) {
                switch (t.typ) {
                    .lparen, .lbracket => depth += 1,
                    .rparen, .rbracket => { depth -= 1; if (depth < 0) return false; },
                    .eq => if (depth == 0) return true,
                    .lbrace, .semicolon, .eof => return false,
                    else => {},
                }
                t = lx.next();
            }
        }
        while (t.typ == .pipe) { // skip union alternatives: | type ...
            t = lx.next();
            if (t.typ != .ident) return false;
            t = lx.next();
        }
        return t.typ == .eq;
    }

    pub fn checkStdNamespaceField(self: *Compiler, field: []const u8, line: u32) !void {
        const path = self.std_namespace_path orelse return;
        const kind = std_schema.lookup(path, field) orelse {
            self.setErr("unknown field '{s}' in std{s}{s}", .{
                field,
                if (path.len > 0) "." else "",
                if (path.len > 0) path else "",
            });
            self.err_line = line;
            self.err_col = self.prev.col;
            return error.UnknownField;
        };
        switch (kind) {
            .namespace => self.std_namespace_path = field,
            .function, .value => self.std_namespace_path = null,
        }
        self.import_module_path = null;
    }

    pub fn checkImportModuleField(self: *Compiler, field: []const u8, line: u32) !void {
        const path = self.import_module_path orelse return;
        self.import_module_path = null;
        const cb = self.options.has_module_export orelse return;
        if (cb(self.options.module_ctx.?, path, field)) return;
        self.setErr("unknown field '{s}' in module '{s}'", .{ field, path });
        self.err_line = line;
        self.err_col = self.prev.col;
        return error.UnknownField;
    }


    pub fn copyName(self: *Compiler, name: []const u8) ![]const u8 {
        _ = self;
        const out = heap.bump(u8, name.len) orelse return error.OutOfMemory;
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }

    fn moduleBaseName(self: *Compiler) []const u8 {
        const path = self.options.module_path;
        if (path.len == 0) return "module";
        var end = path.len;
        while (end > 0 and path[end - 1] != '/') : (end -= 1) {}
        const base = path[end..];
        if (std.mem.endsWith(u8, base, ".gengo")) return base[0 .. base.len - 6];
        return base;
    }

    pub fn isKnownLocalStructType(self: *Compiler, name: []const u8) bool {
        if (self.registry.hasStructTypeLocal(name)) return true;
        var i = name.len;
        while (i > 0) : (i -= 1) {
            if (name[i - 1] == '.') return self.registry.hasStructTypeLocal(name[i..]);
        }
        return false;
    }
    fn arrayLit(self: *Compiler) !void {
        return compiler_expr.arrayLit(self);
    }
    fn assertStmt(self: *Compiler) !void {
        return compiler_stmts.assertStmt(self);
    }
    fn assignLoopVar(self: *Compiler, name: Token) !void {
        return compiler_stmts.assignLoopVar(self, name);
    }
    fn assignStmt(self: *Compiler) !void {
        return compiler_stmts.assignStmt(self);
    }
    fn block(self: *Compiler) anyerror!void {
        return compiler_stmts.block(self);
    }
    fn cForStmt(self: *Compiler) anyerror!void {
        return compiler_stmts.cForStmt(self);
    }
    pub fn compileFuncWithPrefix(self: *Compiler, prefix: []const []const u8, is_named: bool, predicate_base: ?NamedTypeBase) anyerror!u8 {
        return compiler_stmts.compileFuncWithPrefix(self, prefix, is_named, predicate_base);
    }
    fn compoundStmt(self: *Compiler) !void {
        return compiler_stmts.compoundStmt(self);
    }
    fn declareLoopVar(self: *Compiler, name: Token) !void {
        return compiler_stmts.declareLoopVar(self, name);
    }
    fn deferStmt(self: *Compiler) !void {
        return compiler_stmts.deferStmt(self);
    }
    fn emitAssignTargetPath(self: *Compiler, target: AssignTarget, all_steps: []const AssignTargetStep) !void {
        return compiler_stmts.emitAssignTargetPath(self, target, all_steps);
    }
    fn emitExprListTuple(self: *Compiler) !u8 {
        return compiler_stmts.emitExprListTuple(self);
    }
    fn emitImplicitReturn(scope: *FuncInfo, line: u32) !void {
        return compiler_stmts.emitImplicitReturn(scope, line);
    }
    pub fn emitZeroValue(self: *Compiler, tc: TypeCheck, line: u32) !void {
        return compiler_decls.emitZeroValue(self, tc, line);
    }
    pub fn expr(self: *Compiler) !void {
        return compiler_expr.expr(self);
    }
    fn forInStmt(self: *Compiler) anyerror!void {
        return compiler_stmts.forInStmt(self);
    }
    fn forStmt(self: *Compiler) anyerror!void {
        return compiler_stmts.forStmt(self);
    }
    pub fn funcLit(self: *Compiler) anyerror!void {
        return compiler_stmts.funcLit(self);
    }
    fn hasInitSemicolon(self: *Compiler) bool {
        return compiler_stmts.hasInitSemicolon(self);
    }
    fn ifStmt(self: *Compiler) anyerror!void {
        return compiler_stmts.ifStmt(self);
    }
    fn importExpr(self: *Compiler) !void {
        return compiler_expr.importExpr(self);
    }
    fn incrStmt(self: *Compiler) !void {
        return compiler_stmts.incrStmt(self);
    }
    fn indexAssignStmt(self: *Compiler) !void {
        return compiler_stmts.indexAssignStmt(self);
    }
    fn infixExpr(self: *Compiler, tt: TT) anyerror!void {
        return compiler_expr.infixExpr(self, tt);
    }
    fn interfaceDeclBody(self: *Compiler, kw: Token, name: Token, is_pub: bool) !void {
        return compiler_decls.interfaceDeclBody(self, kw, name, is_pub);
    }
    fn isCStyleFor(self: *Compiler) bool {
        return compiler_stmts.isCStyleFor(self);
    }
    fn isForIn(self: *Compiler) bool {
        return compiler_stmts.isForIn(self);
    }
    fn isIndexAssign(self: *Compiler) bool {
        return compiler_stmts.isIndexAssign(self);
    }
    fn isMethodDecl(self: *Compiler) bool {
        return compiler_decls.isMethodDecl(self);
    }
    fn isMultiAssignEq(self: *Compiler) bool {
        return compiler_stmts.isMultiAssignEq(self);
    }
    fn isMultiBind(self: *Compiler, op: TT) bool {
        return compiler_stmts.isMultiBind(self, op);
    }
    fn isNamedFuncDecl(self: *Compiler) bool {
        return compiler_decls.isNamedFuncDecl(self);
    }
    fn isPropertyAssign(self: *Compiler) bool {
        return compiler_stmts.isPropertyAssign(self);
    }
    fn looksLikeStructLiteral(self: *Compiler) bool {
        return compiler_expr.looksLikeStructLiteral(self);
    }
    fn mapLit(self: *Compiler) !void {
        return compiler_expr.mapLit(self);
    }
    fn methodDecl(self: *Compiler) !void {
        return compiler_decls.methodDecl(self);
    }
    fn multiBindStmt(self: *Compiler, is_decl: bool) !void {
        return compiler_stmts.multiBindStmt(self, is_decl);
    }
    fn namedFuncDecl(self: *Compiler, is_pub: bool) !void {
        return compiler_decls.namedFuncDecl(self, is_pub);
    }
    fn namedTypeDecl(self: *Compiler, is_pub: bool) !void {
        return compiler_decls.namedTypeDecl(self, is_pub);
    }
    fn numLit(self: *Compiler) !void {
        return compiler_expr.numLit(self);
    }
    fn parseAssignTargetList(self: *Compiler, targets: *[MaxLocals]AssignTarget, steps: *[MaxLocals * 8]AssignTargetStep) !struct { target_count: u8, step_count: u16 } {
        return compiler_stmts.parseAssignTargetList(self, targets, steps);
    }
    fn parseConstraintBounds(self: *Compiler) !struct { is_cycle: bool, min: f64, max: f64 } {
        return compiler_decls.parseConstraintBounds(self);
    }
    pub fn parseFieldTypeSpec(self: *Compiler) !FieldTypeSpec {
        return compiler_decls.parseFieldTypeSpec(self);
    }
    fn parseNameList(self: *Compiler, out: *[MaxLocals]Token) !u8 {
        return compiler_stmts.parseNameList(self, out);
    }
    fn parsePrecedence(self: *Compiler, p: Prec) anyerror!void {
        return compiler_expr.parsePrecedence(self, p);
    }
    fn parseSignedNumber(self: *Compiler) !f64 {
        return compiler_decls.parseSignedNumber(self);
    }
    fn propertyAssignStmt(self: *Compiler) !void {
        return compiler_stmts.propertyAssignStmt(self);
    }
    fn returnStmt(self: *Compiler) !void {
        return compiler_stmts.returnStmt(self);
    }
    fn runeLitExpr(self: *Compiler) !void {
        return compiler_expr.runeLitExpr(self);
    }
    fn skipTypeSpec(self: *Compiler) !void {
        return compiler_stmts.skipTypeSpec(self);
    }
    fn stmt(self: *Compiler) anyerror!void {
        return compiler_stmts.stmt(self);
    }
    fn strLitExpr(self: *Compiler) !void {
        return compiler_expr.strLitExpr(self);
    }
    fn structDeclBody(self: *Compiler, kw: Token, name: Token, is_pub: bool) !void {
        return compiler_decls.structDeclBody(self, kw, name, is_pub);
    }
    fn structInstanceLit(self: *Compiler, type_name: Token) !void {
        return compiler_expr.structInstanceLit(self, type_name);
    }
    fn structInstanceLitAfterValue(self: *Compiler, line: u32) !void {
        return compiler_expr.structInstanceLitAfterValue(self, line);
    }
    fn subtypeDecl(self: *Compiler, is_pub: bool) !void {
        return compiler_decls.subtypeDecl(self, is_pub);
    }
    fn switchStmt(self: *Compiler) anyerror!void {
        return compiler_stmts.switchStmt(self);
    }
    fn unaryExpr(self: *Compiler, tt: TT) !void {
        return compiler_expr.unaryExpr(self, tt);
    }
    fn varDecl(self: *Compiler, has_keyword: bool, is_const: bool) !void {
        return compiler_stmts.varDecl(self, has_keyword, is_const);
    }
    pub fn varExpr(self: *Compiler, name: Token) !void {
        return compiler_expr.varExpr(self, name);
    }
    fn variantDeclBody(self: *Compiler, kw: Token, name_tok: Token, is_pub: bool) !void {
        return compiler_decls.variantDeclBody(self, kw, name_tok, is_pub);
    }
    fn whileForStmt(self: *Compiler) anyerror!void {
        return compiler_stmts.whileForStmt(self);
    }
    };
