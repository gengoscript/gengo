const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const lexer_mod = @import("lexer.zig");
const op_mod = @import("op.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");
const ct = @import("compiler_types.zig");

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

pub const ImportResolverFn = *const fn (ctx: *anyopaque, importer_path: []const u8, import_name: []const u8) anyerror![]const u8;

pub const CompilerOptions = struct {
    module_path: []const u8 = "",
    module_prefix: []const u8 = "",
    module_struct_name: []const u8 = "",
    module_global_name: []const u8 = "",
    module_ctx: ?*anyopaque = null,
    resolve_import: ?ImportResolverFn = null,
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
    registry: TypeRegistry = .{},
    last_func_obj: ?*@import("value.zig").Object = null,
    peek_tok: ?Token = null,
    options: CompilerOptions = .{},
    exports: [MaxLocals]ExportEntry = undefined,
    export_count: u8 = 0,
    err_msg_buf: [512]u8 = undefined,
    err_msg_len: u16 = 0,
    err_col: u16 = 0,

    // ── Lifecycle ────────────────────────────────────────────────────────────────

    pub fn init(src: []const u8, options: CompilerOptions) Compiler {
        return .{ .lex = .{ .src = src }, .options = options };
    }

    pub fn compile(self: *Compiler, emit_halt: bool) !void {
        self.registry.reset();
        self.export_count = 0;
        self.err_msg_len = 0;
        self.err_col = 0;
        self.advance();
        while (!self.check(.eof)) {
            if (self.cur.typ == .err_invalid_char) {
                self.setErr("invalid character '{c}'", .{self.cur.src[0]});
                self.err_col = @intCast(self.cur.col);
                return error.InvalidChar;
            }
            if (self.cur.typ == .err_unterminated_string) {
                self.setErr("unterminated string literal", .{});
                self.err_col = @intCast(self.cur.col);
                return error.UnterminatedString;
            }
            try self.decl();
        }
        if (emit_halt) try chunk.emitOp(.halt, self.prev.line);
    }

    // ── Error reporting helpers ──────────────────────────────────────────────────

    fn setErr(self: *Compiler, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.err_msg_buf[0..], fmt, args) catch "error";
        self.err_msg_len = @intCast(s.len);
    }

    fn err(self: *Compiler, comptime fmt: []const u8, args: anytype) anyerror {
        self.setErr(fmt, args);
        self.err_col = @intCast(self.cur.col);
        return error.UnexpectedToken;
    }

    fn tokenName(self: *Compiler, tt: TT) []const u8 {
        _ = self;
        return switch (tt) {
            .eof => "end of file",
            .err_invalid_char => "invalid character",
            .err_unterminated_string => "unterminated string",
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

    fn inFunc(self: *Compiler) bool {
        return self.scope_depth > 0;
    }

    fn currentScope(self: *Compiler) *FuncInfo {
        return &self.scopes[self.scope_depth - 1];
    }

    fn resolveLocal(self: *Compiler, name: []const u8) ?u8 {
        if (!self.inFunc()) return null;
        const scope = self.currentScope();
        var i: u8 = scope.local_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(scope.locals[i].name, name)) return i;
        }
        return null;
    }

    fn defineLocal(self: *Compiler, name: []const u8, is_const: bool) !u8 {
        const scope = self.currentScope();
        if (scope.local_count >= MaxLocals) { self.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
        const slot = scope.local_count;
        scope.locals[slot] = .{ .name = name, .is_const = is_const };
        scope.local_count += 1;
        return slot;
    }

    fn resolveLocalConst(self: *Compiler, name: []const u8) ?bool {
        if (!self.inFunc()) return null;
        const scope = self.currentScope();
        var i: u8 = scope.local_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(scope.locals[i].name, name)) return scope.locals[i].is_const;
        }
        return null;
    }

    fn emitGetVar(self: *Compiler, name: Token) !void {
        chunk.setCol(name.col);
        if (self.resolveLocal(name.src)) |slot| {
            try chunk.emit2(@intFromEnum(Op.get_local), slot, name.line);
        } else if (self.resolveUpvalue(name.src)) |uv| {
            try chunk.emit2(@intFromEnum(Op.get_upvalue), uv, name.line);
        } else {
            try chunk.emitGetGlobal(try self.qualifyGlobalName(name.src), name.line);
        }
    }

    fn emitSetVar(self: *Compiler, name: Token) !void {
        if (self.resolveLocal(name.src)) |slot| {
            try chunk.emit2(@intFromEnum(Op.set_local), slot, name.line);
        } else if (self.resolveUpvalue(name.src)) |uv| {
            try chunk.emit2(@intFromEnum(Op.set_upvalue), uv, name.line);
        } else {
            try chunk.emitSetGlobal(try self.qualifyGlobalName(name.src), name.line);
        }
    }

    fn resolveUpvalue(self: *Compiler, name: []const u8) ?u8 {
        if (self.scope_depth < 2) return null;
        return self.resolveUpvalueForScope(self.scope_depth - 1, name);
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
        if (enclosing_index == 0) return null;
        return self.resolveUpvalueConstForScope(enclosing_index, name);
    }

    fn resolveUpvalueConst(self: *Compiler, name: []const u8) ?bool {
        if (self.scope_depth < 2) return null;
        return self.resolveUpvalueConstForScope(self.scope_depth - 1, name);
    }

    fn ensureMutableBinding(self: *Compiler, name: Token) !void {
        if (self.resolveLocalConst(name.src)) |is_const| {
            if (is_const) { self.setErr("cannot assign to const variable '{s}'", .{name.src}); return error.AssignToConst; }
            return;
        }
        if (self.resolveUpvalueConst(name.src)) |is_const| {
            if (is_const) { self.setErr("cannot assign to const variable '{s}'", .{name.src}); return error.AssignToConst; }
            return;
        }
        if (self.registry.hasGlobalConst(name.src)) { self.setErr("cannot assign to const variable '{s}'", .{name.src}); return error.AssignToConst; }
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
                return self.addUpvalueToScope(scope_index, name, i, false);
            }
        }

        if (enclosing_index == 0) return null;
        const parent_up = self.resolveUpvalueForScope(enclosing_index, name) orelse return null;
        return self.addUpvalueToScope(scope_index, name, parent_up, true);
    }

    fn cleanupLocals(self: *Compiler, base: u8, line: u32) !void {
        if (!self.inFunc()) return;
        const scope = self.currentScope();
        while (scope.local_count > base) {
            try chunk.emitOp(.pop, line);
            scope.local_count -= 1;
        }
    }

    // ── Loop context ─────────────────────────────────────────────────────────────

    fn loopKeepBase(self: *Compiler) u8 {
        if (!self.inFunc()) return 0;
        return self.currentScope().local_count;
    }

    fn pushLoop(self: *Compiler, continue_target: usize, local_keep: u8, body_keep: u8, iter_pops: u8) !void {
        if (self.loop_depth >= MaxLoopDepth) { self.setErr("too many nested loops (max {d})", .{MaxLoopDepth}); return error.TooManyNestedLoops; }
        self.loops[self.loop_depth] = .{
            .continue_target = continue_target,
            .local_keep = local_keep,
            .body_keep = body_keep,
            .iter_pops = iter_pops,
        };
        self.loop_depth += 1;
    }

    fn popLoop(self: *Compiler) LoopCtx {
        self.loop_depth -= 1;
        return self.loops[self.loop_depth];
    }

    fn currentLoop(self: *Compiler) *LoopCtx {
        return &self.loops[self.loop_depth - 1];
    }

    fn emitBreak(self: *Compiler, line: u32) !void {
        if (self.loop_depth == 0) { self.setErr("'break' outside of loop", .{}); return error.BreakOutsideLoop; }
        const loop = self.currentLoop();
        // Save so code after the if-break block sees the correct local count (non-break path).
        const saved: u8 = if (self.inFunc()) self.currentScope().local_count else 0;
        try self.cleanupLocals(loop.body_keep, line);
        var p: u8 = 0;
        while (p < loop.iter_pops) : (p += 1) try chunk.emitOp(.pop, line);
        try self.cleanupLocals(loop.local_keep, line);
        const off = try chunk.emitJump(.jump, line);
        if (loop.break_count >= MaxLoopBreaks) { self.setErr("too many 'break' statements in loop (max {d})", .{MaxLoopBreaks}); return error.TooManyBreaksInLoop; }
        loop.break_offsets[loop.break_count] = off;
        loop.break_count += 1;
        if (self.inFunc()) self.currentScope().local_count = saved;
    }

    fn emitContinue(self: *Compiler, line: u32) !void {
        if (self.loop_depth == 0) { self.setErr("'continue' outside of loop", .{}); return error.ContinueOutsideLoop; }
        const loop = self.currentLoop();
        const saved: u8 = if (self.inFunc()) self.currentScope().local_count else 0;
        try self.cleanupLocals(loop.body_keep, line);
        try chunk.emitLoop(loop.continue_target, line);
        if (self.inFunc()) self.currentScope().local_count = saved;
    }

    // ── Top-level dispatch ───────────────────────────────────────────────────────

    fn decl(self: *Compiler) anyerror!void {
        if (self.match(.kw_pub)) {
            if (self.inFunc()) { self.setErr("invalid 'pub' target", .{}); return error.InvalidPubTarget; }
            try self.pubDecl();
        } else if (self.check(.ident) and self.peekTT() == .colon_eq) {
            try self.varDecl(false, false);
        } else if (self.check(.ident) and self.isTypedVarDecl()) {
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

    fn interfaceDeclBody(self: *Compiler, kw: Token, name: Token, is_pub: bool) !void {
        try self.registry.addInterfaceType(name.src);
        try self.consume(.lbrace);

        var methods_tmp: [MaxLocals]InterfaceMethodSpec = undefined;
        var mcount: u8 = 0;
        while (!self.check(.rbrace)) {
            if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
            if (mcount >= MaxLocals) { self.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
            const mname = try self.copyName(self.cur.src);
            self.advance();
            try self.consume(.lparen);

            var ptypes_tmp: [MaxLocals]FieldTypeSpec = undefined;
            var arity: u8 = 0;
            var is_variadic = false;
            var variadic_type: FieldTypeSpec = undefined;
            var has_typed_params = false;
            const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
            any_alts[0] = .{ .typ = .any };
            const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };
            variadic_type = any_spec;
            if (!self.check(.rparen)) {
                while (true) {
                    const vari = self.match(.ellipsis);
                    if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                    self.advance(); // param name
                    if (self.cur.typ != .question and self.cur.typ != .ident and self.cur.typ != .kw_func and self.cur.typ != .lbracket) { self.setErr("expected type annotation, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedTypeAnnotation; }
                    const ptype: FieldTypeSpec = try self.parseFieldTypeSpec();
                    if (!(ptype.alts.len == 1 and ptype.alts[0].typ == .any)) has_typed_params = true;
                    ptypes_tmp[arity] = ptype;
                    arity += 1;
                    if (vari) {
                        is_variadic = true;
                        variadic_type = ptype;
                        break;
                    }
                    if (!self.match(.comma)) break;
                    if (self.check(.rparen)) break;
                }
            }
            try self.consume(.rparen);

            var returns_tmp: [MaxLocals]FieldTypeSpec = undefined;
            var rcount: u8 = 0;
            var has_typed_returns = false;
            if (self.match(.lparen)) {
                while (true) {
                    returns_tmp[rcount] = try self.parseFieldTypeSpec();
                    rcount += 1;
                    has_typed_returns = true;
                    if (!self.match(.comma)) break;
                    if (self.check(.rparen)) break;
                }
                try self.consume(.rparen);
            } else if (self.cur.typ == .question or self.cur.typ == .ident or self.cur.typ == .kw_func or self.cur.typ == .lbracket) {
                returns_tmp[0] = try self.parseFieldTypeSpec();
                rcount = 1;
                has_typed_returns = true;
            }

            const ptypes = heap.bump(FieldTypeSpec, arity) orelse return error.OutOfMemory;
            var pi: usize = 0;
            while (pi < arity) : (pi += 1) ptypes[pi] = ptypes_tmp[pi];
            const rtypes = heap.bump(FieldTypeSpec, rcount) orelse return error.OutOfMemory;
            var ri: usize = 0;
            while (ri < rcount) : (ri += 1) rtypes[ri] = returns_tmp[ri];

            methods_tmp[mcount] = .{
                .name = mname,
                .arity = arity,
                .is_variadic = is_variadic,
                .variadic_type = variadic_type,
                .param_types = ptypes[0..arity],
                .return_types = rtypes[0..rcount],
                .has_typed_params = has_typed_params,
                .has_typed_returns = has_typed_returns,
            };
            mcount += 1;
            self.matchOpt(.comma);
        }
        try self.consume(.rbrace);
        const methods = heap.bump(InterfaceMethodSpec, mcount) orelse return error.OutOfMemory;
        var i: usize = 0;
        while (i < mcount) : (i += 1) methods[i] = methods_tmp[i];
        const qname = try self.qualifyTypeName(name.src);
        const it = heap.allocObject() orelse return error.OutOfMemory;
        it.* = .{ .interface_type = InterfaceTypeObj{ .name = try self.copyName(name.src), .qualified_name = qname, .methods = methods[0..mcount] } };
        try chunk.emitConst(.{ .object = it }, kw.line);
        if (self.inFunc()) {
            _ = try self.defineLocal(name.src, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try self.addExport(name.src, qname);
        }
        self.matchOpt(.semicolon);
    }

    fn parseSignedNumber(self: *Compiler) !f64 {
        var sign: f64 = 1.0;
        if (self.match(.minus)) sign = -1.0;
        if (self.cur.typ != .number) return self.err("expected number, found {s}", .{self.tokenName(self.cur.typ)});
        const n = common.parseFloat(self.cur.src) orelse {
            self.setErr("invalid number literal '{s}'", .{self.cur.src});
            return error.BadNumber;
        };
        self.advance();
        return sign * n;
    }

    fn parseConstraintBounds(self: *Compiler) !struct { is_cycle: bool, min: f64, max: f64 } {
        const is_cycle = if (self.match(.kw_range))
            false
        else if (self.match(.kw_cycle))
            true
        else
            return self.err("expected 'range' or 'cycle', found {s}", .{self.tokenName(self.cur.typ)});
        const min = try self.parseSignedNumber();
        try self.consume(.dotdot);
        const max = try self.parseSignedNumber();
        if (min > max) {
            self.setErr("range minimum ({d}) must not exceed maximum ({d})", .{ min, max });
            return error.RangeError;
        }
        return .{ .is_cycle = is_cycle, .min = min, .max = max };
    }

    fn variantDeclBody(self: *Compiler, kw: Token, name_tok: Token, is_pub: bool) !void {
        const name = name_tok.src;
        if (self.registry.hasVariantType(name)) { self.setErr("duplicate variant type name '{s}'", .{name}); return error.DuplicateVariantType; }
        try self.registry.addVariantType(name);
        try self.consume(.lbrace);
        var arms_tmp: [MaxLocals]VariantArmSpec = undefined;
        var arm_count: u8 = 0;
        if (!self.check(.rbrace)) {
            while (true) {
                if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                const arm_name = try self.copyName(self.cur.src);
                self.advance();
                var has_payload = false;
                var payload_name: []const u8 = "";
                var payload_type: ?FieldTypeSpec = null;
                if (self.match(.lparen)) {
                    has_payload = true;
                    // Disambiguate: `armName(fieldName Type)` vs `armName(Type)`
                    // If two idents before `)`: first is field name, second is type.
                    if (self.cur.typ == .ident) {
                        var lx2 = self.lex;
                        const peek = lx2.next();
                        if (peek.typ == .ident) {
                            payload_name = try self.copyName(self.cur.src);
                            self.advance();
                        }
                    }
                    payload_type = try self.parseFieldTypeSpec();
                    try self.consume(.rparen);
                }
                if (arm_count >= MaxLocals) { self.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
                arms_tmp[arm_count] = .{
                    .name = arm_name,
                    .has_payload = has_payload,
                    .payload_name = payload_name,
                    .payload_type = payload_type,
                };
                arm_count += 1;
                if (!self.match(.comma)) break;
                if (self.check(.rbrace)) break;
            }
        }
        try self.consume(.rbrace);
        const arms = heap.bump(VariantArmSpec, arm_count) orelse return error.OutOfMemory;
        var ai: usize = 0;
        while (ai < arm_count) : (ai += 1) arms[ai] = arms_tmp[ai];
        const qname = try self.qualifyTypeName(name);
        const vt = heap.allocObject() orelse return error.OutOfMemory;
        vt.* = .{ .variant_type = VariantTypeObj{ .name = try self.copyName(name), .qualified_name = qname, .arms = arms[0..arm_count] } };
        try chunk.emitConst(.{ .object = vt }, kw.line);
        if (self.inFunc()) {
            _ = try self.defineLocal(name, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try self.addExport(name, qname);
        }
        self.matchOpt(.semicolon);
    }

    fn subtypeDecl(self: *Compiler, is_pub: bool) !void {
        const kw = self.cur;
        self.advance(); // subtype
        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const name_tok = self.cur;
        self.advance(); // name
        const name = name_tok.src;

        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const parent_name = self.cur.src;
        self.advance(); // parent name

        const parent_info = self.registry.getNamedTypeInfo(parent_name) orelse { self.setErr("unknown type '{s}'", .{parent_name}); return error.UnexpectedToken; };

        // Handle enum subtype: subtype Weekend_Days Days { Saturday, Sunday }
        if (parent_info.base == .enum_t) {
            if (self.registry.hasNamedType(name)) { self.setErr("duplicate type name '{s}'", .{name}); return error.DuplicateNamedType; }
            const qname = try self.qualifyTypeName(name);
            const qparent = try self.qualifyTypeName(parent_name);
            try self.registry.addNamedType(.{
                .name = name,
                .base = .enum_t,
                .parent_name = parent_name,
            });
            try self.consume(.lbrace);
            var members_tmp: [MaxLocals][]const u8 = undefined;
            var mcount: u8 = 0;
            if (!self.check(.rbrace)) {
                while (true) {
                    if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                    members_tmp[mcount] = try self.copyName(self.cur.src);
                    mcount += 1;
                    self.advance();
                    if (!self.match(.comma)) break;
                    if (self.check(.rbrace)) break;
                }
            }
            try self.consume(.rbrace);
            const members = heap.bump([]const u8, mcount) orelse return error.OutOfMemory;
            var mi: usize = 0;
            while (mi < mcount) : (mi += 1) members[mi] = members_tmp[mi];
            const et = heap.allocObject() orelse return error.OutOfMemory;
            et.* = .{ .enum_type = .{
                .name = try self.copyName(name),
                .qualified_name = qname,
                .members = members[0..mcount],
                .parent_name = qparent,
            } };
            try chunk.emitConst(.{ .object = et }, kw.line);
            if (self.inFunc()) {
                _ = try self.defineLocal(name, false);
            } else {
                try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
                if (is_pub) try self.addExport(name, qname);
            }
            self.matchOpt(.semicolon);
            return;
        }

        if (parent_info.base != .int and parent_info.base != .float and parent_info.base != .rune)
            return self.err("subtype parent must be numeric type (int, float, or rune)", .{});
        if (self.registry.hasNamedType(name)) { self.setErr("duplicate type name '{s}'", .{name}); return error.DuplicateNamedType; }

        const base = parent_info.base;
        var has_range = parent_info.has_range;
        var is_cycle = parent_info.is_cycle;
        var min: f64 = parent_info.min;
        var max: f64 = parent_info.max;

        if (self.check(.kw_range) or self.check(.kw_cycle)) {
            const constraint = try self.parseConstraintBounds();
            if (constraint.is_cycle and base != .int) return self.err("'cycle' constraint requires integer base type", .{});
            if (parent_info.has_range) {
                if (constraint.min < parent_info.min or constraint.max > parent_info.max) return error.RangeError;
            }
            has_range = true;
            is_cycle = constraint.is_cycle;
            min = constraint.min;
            max = constraint.max;
        }

        try self.registry.addNamedType(.{
            .name = name,
            .base = base,
            .has_range = has_range,
            .is_cycle = is_cycle,
            .min = min,
            .max = max,
            .parent_name = parent_name,
        });

        const qname = try self.qualifyTypeName(name);
        const qparent = try self.qualifyTypeName(parent_name);
        const nt = heap.allocObject() orelse return error.OutOfMemory;
        nt.* = .{ .named_type = NamedTypeObj{
            .name = try self.copyName(name),
            .qualified_name = qname,
            .base = base,
            .has_range = has_range,
            .is_cycle = is_cycle,
            .min = min,
            .max = max,
            .parent_name = qparent,
        } };
        try chunk.emitConst(.{ .object = nt }, kw.line);
        if (self.inFunc()) {
            _ = try self.defineLocal(name, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try self.addExport(name, qname);
        }
        self.matchOpt(.semicolon);
    }

    fn namedTypeDecl(self: *Compiler, is_pub: bool) !void {
        const kw = self.cur;
        self.advance(); // type
        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const name_tok = self.cur;
        self.advance(); // name
        if (self.match(.kw_struct)) return self.structDeclBody(kw, name_tok, is_pub);
        if (self.match(.kw_interface)) return self.interfaceDeclBody(kw, name_tok, is_pub);
        if (self.match(.kw_variant)) return self.variantDeclBody(kw, name_tok, is_pub);
        const name = name_tok.src;
        if (self.registry.hasNamedType(name)) { self.setErr("duplicate type name '{s}'", .{name}); return error.DuplicateNamedType; }
        const qname = try self.qualifyTypeName(name);
        if (self.check(.kw_enum)) {
            try self.registry.addNamedType(.{
                .name = name,
                .base = .enum_t,
                .has_range = false,
                .is_cycle = false,
                .min = 0,
                .max = 0,
            });
            self.advance();
            try self.consume(.lbrace);
            var members_tmp: [MaxLocals][]const u8 = undefined;
            var mcount: u8 = 0;
            if (!self.check(.rbrace)) {
                while (true) {
                    if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                    members_tmp[mcount] = try self.copyName(self.cur.src);
                    mcount += 1;
                    self.advance();
                    if (!self.match(.comma)) break;
                    if (self.check(.rbrace)) break;
                }
            }
            try self.consume(.rbrace);
            const members = heap.bump([]const u8, mcount) orelse return error.OutOfMemory;
            var mi: usize = 0;
            while (mi < mcount) : (mi += 1) members[mi] = members_tmp[mi];
            const et = heap.allocObject() orelse return error.OutOfMemory;
            et.* = .{ .enum_type = .{ .name = try self.copyName(name), .qualified_name = qname, .members = members[0..mcount] } };
            try chunk.emitConst(.{ .object = et }, kw.line);
            if (self.inFunc()) {
                _ = try self.defineLocal(name, false);
            } else {
                try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
                if (is_pub) try self.addExport(name, qname);
            }
            self.matchOpt(.semicolon);
            return;
        }

        if (self.cur.typ == .lbracket) {
            // type Name []T — named slice type
            self.advance(); // consume '['
            try self.consume(.rbracket); // consume ']'
            const es: FieldTypeSpec = try self.parseFieldTypeSpec();
            try self.registry.addNamedType(.{ .name = name, .base = .array_t, .elem_spec = es });
            const nt = heap.allocObject() orelse return error.OutOfMemory;
            nt.* = .{ .named_type = NamedTypeObj{ .name = try self.copyName(name), .qualified_name = qname, .base = .array_t, .elem_spec = es } };
            try chunk.emitConst(.{ .object = nt }, kw.line);
            if (self.inFunc()) {
                _ = try self.defineLocal(name, false);
            } else {
                try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
                if (is_pub) try self.addExport(name, qname);
            }
            self.matchOpt(.semicolon);
            return;
        }

        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const base_name = self.cur.src;
        self.advance();

        var base: NamedTypeBase = undefined;
        var parent_has_range = false;
        var parent_is_cycle = false;
        var parent_min: f64 = 0;
        var parent_max: f64 = 0;
        if (common.streq(base_name, "int")) {
            base = .int;
        } else if (common.streq(base_name, "float")) {
            base = .float;
        } else if (common.streq(base_name, "string")) {
            base = .string;
        } else if (common.streq(base_name, "bool")) {
            base = .bool;
        } else if (common.streq(base_name, "rune")) {
            base = .rune;
        } else if (common.streq(base_name, "array")) {
            return self.err("use '[]T' syntax for array types", .{});
        } else if (common.streq(base_name, "map")) {
            try self.consume(.lbracket);
            const ks = try self.parseFieldTypeSpec();
            try self.consume(.rbracket);
            const vs = try self.parseFieldTypeSpec();
            try self.registry.addNamedType(.{ .name = name, .base = .map_t, .key_spec = ks, .val_spec = vs });
            const nt = heap.allocObject() orelse return error.OutOfMemory;
            nt.* = .{ .named_type = NamedTypeObj{ .name = try self.copyName(name), .qualified_name = qname, .base = .map_t, .key_spec = ks, .val_spec = vs } };
            try chunk.emitConst(.{ .object = nt }, kw.line);
            if (self.inFunc()) {
                _ = try self.defineLocal(name, false);
            } else {
                try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
                if (is_pub) try self.addExport(name, qname);
            }
            self.matchOpt(.semicolon);
            return;
        } else if (self.registry.getNamedTypeInfo(base_name)) |parent| {
            base = parent.base;
            parent_has_range = parent.has_range;
            parent_is_cycle = parent.is_cycle;
            parent_min = parent.min;
            parent_max = parent.max;
        } else return self.err("unknown type '{s}'", .{base_name});

        var has_range = false;
        var is_cycle = false;
        var min: f64 = 0;
        var max: f64 = 0;
        if (self.check(.kw_range) or self.check(.kw_cycle)) {
            const constraint = try self.parseConstraintBounds();
            if (constraint.is_cycle and base != .int) return self.err("'cycle' constraint requires integer base type", .{});
            has_range = true;
            is_cycle = constraint.is_cycle;
            min = constraint.min;
            max = constraint.max;
        }
        if (parent_has_range) {
            if (has_range) {
                if (min < parent_min or max > parent_max) return error.RangeError;
            } else {
                has_range = true;
                is_cycle = parent_is_cycle;
                min = parent_min;
                max = parent_max;
            }
        }

        try self.registry.addNamedType(.{
            .name = name,
            .base = base,
            .has_range = has_range,
            .is_cycle = is_cycle,
            .min = min,
            .max = max,
        });

        const nt = heap.allocObject() orelse return error.OutOfMemory;
        nt.* = .{ .named_type = NamedTypeObj{
            .name = try self.copyName(name),
            .qualified_name = qname,
            .base = base,
            .has_range = has_range,
            .is_cycle = is_cycle,
            .min = min,
            .max = max,
        } };
        try chunk.emitConst(.{ .object = nt }, kw.line);
        if (self.inFunc()) {
            _ = try self.defineLocal(name, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try self.addExport(name, qname);
        }
        self.matchOpt(.semicolon);
    }

    fn isMethodDecl(self: *Compiler) bool {
        var lx = self.lex;
        const t1 = lx.next();
        if (t1.typ != .lparen) return false;
        const t2 = lx.next();
        if (t2.typ != .ident) return false;
        const t3 = lx.next();
        if (t3.typ != .ident) return false;
        const t4 = lx.next();
        if (t4.typ != .rparen) return false;
        const t5 = lx.next();
        if (t5.typ != .ident) return false;
        const t6 = lx.next();
        return t6.typ == .lparen;
    }

    fn structDeclBody(self: *Compiler, kw: Token, name: Token, is_pub: bool) !void {
        try self.registry.addStructType(name.src);
        try self.consume(.lbrace);

        var field_specs: [MaxLocals]StructFieldSpec = undefined;
        var count: u8 = 0;
        if (!self.check(.rbrace)) {
            while (true) {
                const field_is_const = self.match(.kw_const);
                if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                if (count >= MaxLocals) { self.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
                const fname = try self.copyName(self.cur.src);
                var i: u8 = 0;
                while (i < count) : (i += 1) {
                    if (common.streq(field_specs[i].name, fname)) { self.setErr("duplicate field name '{s}'", .{fname}); return error.DuplicateField; }
                }
                self.advance();

                var spec = StructFieldSpec{ .name = fname, .typ = .{ .alts = &[_]FieldTypeAlt{} }, .is_const = field_is_const };
                if (self.cur.typ == .ident or self.cur.typ == .question or self.cur.typ == .kw_func or self.cur.typ == .lbracket) {
                    // Space syntax: field type  (colon no longer used)
                    spec.typ = try self.parseFieldTypeSpec();
                    var ti: usize = 0;
                    while (ti < spec.typ.alts.len) : (ti += 1) {
                        const alt = spec.typ.alts[ti];
                        if (alt.typ == .struct_t) {
                            // Policy: no forward refs and no self refs.
                            const qself = try self.qualifyTypeName(name.src);
                            if (common.streq(alt.struct_name, qself)) { self.setErr("unknown struct type '{s}'", .{alt.struct_name}); return error.UnknownStructType; }
                            if (!self.isKnownLocalStructType(alt.struct_name)) { self.setErr("unknown struct type '{s}'", .{alt.struct_name}); return error.UnknownStructType; }
                        }
                    }
                } else {
                    const alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
                    alts[0] = .{ .typ = .any };
                    spec.typ = .{ .alts = alts[0..1] };
                }

                field_specs[count] = spec;
                count += 1;
                if (!self.match(.comma)) break;
                if (self.check(.rbrace)) break;
            }
        }
        try self.consume(.rbrace);

        const fields = heap.bump(StructFieldSpec, count) orelse return error.OutOfMemory;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            fields[i] = field_specs[i];
        }
        const qname = try self.qualifyTypeName(name.src);
        const st = heap.allocObject() orelse return error.OutOfMemory;
        st.* = .{ .struct_type = StructTypeObj{ .name = try self.copyName(name.src), .qualified_name = qname, .fields = fields[0..count] } };
        try chunk.emitConst(.{ .object = st }, kw.line);

        if (self.inFunc()) {
            _ = try self.defineLocal(name.src, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try self.addExport(name.src, qname);
        }
        self.matchOpt(.semicolon);
    }

    fn parseFieldTypeSpec(self: *Compiler) !FieldTypeSpec {
        var tmp: [MaxTypeAlts]FieldTypeAlt = undefined;
        var count: u8 = 0;

        if (self.match(.question)) {
                if (count >= MaxTypeAlts) { self.setErr("too many type alternatives (max {d})", .{MaxTypeAlts}); return error.TooManyTypeAlternatives; }
            tmp[count] = .{ .typ = .null_t };
            count += 1;
        }

        while (true) {
            var alt: FieldTypeAlt = undefined;
            if (self.cur.typ == .lbracket) {
                // SliceType: []T
                self.advance(); // consume '['
                try self.consume(.rbracket); // consume ']'
                const es = try self.parseFieldTypeSpec();
                const ep = heap.bump(FieldTypeSpec, 1) orelse return error.OutOfMemory;
                ep[0] = es;
                alt = .{ .typ = .array, .elem_spec = ep[0] };
            } else if (self.cur.typ == .kw_func) {
                self.advance(); // consume 'func'
                try self.consume(.lparen);
                var func_params_tmp: [MaxLocals]FieldTypeSpec = undefined;
                var func_param_count: u8 = 0;
                if (!self.check(.rparen)) {
                    while (true) {
                        if (func_param_count >= MaxLocals) { self.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
                        func_params_tmp[func_param_count] = try self.parseFieldTypeSpec();
                        func_param_count += 1;
                        if (!self.match(.comma)) break;
                        if (self.check(.rparen)) break;
                    }
                }
                try self.consume(.rparen);
                var func_returns_tmp: [MaxLocals]FieldTypeSpec = undefined;
                var func_return_count: u8 = 0;
                if (self.match(.lparen)) {
                    while (true) {
                        if (func_return_count >= MaxLocals) { self.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
                        func_returns_tmp[func_return_count] = try self.parseFieldTypeSpec();
                        func_return_count += 1;
                        if (!self.match(.comma)) break;
                        if (self.check(.rparen)) break;
                    }
                    try self.consume(.rparen);
                } else if (self.cur.typ == .question or self.cur.typ == .ident or self.cur.typ == .kw_func or self.cur.typ == .lbracket) {
                    func_returns_tmp[0] = try self.parseFieldTypeSpec();
                    func_return_count = 1;
                }
                const fp = if (func_param_count > 0) blk: {
                    const ps = heap.bump(FieldTypeSpec, func_param_count) orelse return error.OutOfMemory;
                    var ii: u8 = 0;
                    while (ii < func_param_count) : (ii += 1) ps[ii] = func_params_tmp[ii];
                    break :blk ps[0..func_param_count];
                } else @as([]FieldTypeSpec, &.{});
                const fr = if (func_return_count > 0) blk: {
                    const rs = heap.bump(FieldTypeSpec, func_return_count) orelse return error.OutOfMemory;
                    var ii: u8 = 0;
                    while (ii < func_return_count) : (ii += 1) rs[ii] = func_returns_tmp[ii];
                    break :blk rs[0..func_return_count];
                } else @as([]FieldTypeSpec, &.{});
                alt = .{ .typ = .func_t, .func_params = fp, .func_returns = fr };
            } else {
            if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
            const tname = self.cur.src;
            self.advance();

            alt = .{ .typ = .struct_t, .struct_name = tname };
            if (common.streq(tname, "any")) {
                alt = .{ .typ = .any };
            } else if (common.streq(tname, "int")) {
                alt = .{ .typ = .int };
            } else if (common.streq(tname, "float")) {
                alt = .{ .typ = .float };
            } else if (common.streq(tname, "rune")) {
                alt = .{ .typ = .rune_t };
            } else if (common.streq(tname, "bool")) {
                alt = .{ .typ = .boolean };
            } else if (common.streq(tname, "string")) {
                alt = .{ .typ = .string };
            } else if (common.streq(tname, "error")) {
                alt = .{ .typ = .error_t };
            } else if (common.streq(tname, "array")) {
                return self.err("use '[]T' syntax for array types", .{});
            } else if (common.streq(tname, "map")) {
                var ks: ?FieldTypeSpec = null;
                var vs: ?FieldTypeSpec = null;
                if (self.match(.lbracket)) {
                    ks = try self.parseFieldTypeSpec();
                    try self.consume(.rbracket);
                    vs = try self.parseFieldTypeSpec();
                } else {
                    return self.err("use 'map[K]V' syntax for map types", .{});
                }
                alt = .{ .typ = .map, .key_spec = ks, .val_spec = vs };
            } else if (self.registry.hasStructTypeLocal(tname)) {
                alt = .{ .typ = .struct_t, .struct_name = try self.qualifyTypeName(tname) };
            } else if (self.registry.hasInterfaceType(tname)) {
                alt = .{ .typ = .interface_t, .interface_name = try self.qualifyTypeName(tname) };
            } else if (self.registry.hasNamedType(tname)) {
                alt = .{ .typ = .named_t, .named_name = try self.qualifyTypeName(tname) };
            } else if (self.registry.hasVariantType(tname)) {
                alt = .{ .typ = .variant_t, .named_name = try self.qualifyTypeName(tname) };
            }
            } // end else (ident type)

            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (tmp[i].typ == alt.typ and common.streq(tmp[i].struct_name, alt.struct_name) and common.streq(tmp[i].interface_name, alt.interface_name) and common.streq(tmp[i].named_name, alt.named_name)) break;
            }
            if (i == count) {
                if (count >= MaxTypeAlts) { self.setErr("too many type alternatives (max {d})", .{MaxTypeAlts}); return error.TooManyTypeAlternatives; }
                tmp[count] = alt;
                count += 1;
            }

            if (!self.match(.pipe)) break;
        }

        const alts = heap.bump(FieldTypeAlt, count) orelse return error.OutOfMemory;
        var ai: usize = 0;
        while (ai < count) : (ai += 1) {
            alts[ai] = tmp[ai];
        }
        return .{ .alts = alts[0..count] };
    }

    fn isNamedFuncDecl(self: *Compiler) bool {
        var lx = self.lex;
        const t1 = lx.next();
        if (t1.typ != .ident) return false;
        const t2 = lx.next();
        return t2.typ == .lparen;
    }

    fn namedFuncDecl(self: *Compiler, is_pub: bool) !void {
        const kw = self.cur;
        self.advance(); // consume 'func'
        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const name = self.cur;
        self.advance(); // consume function name

        // current token is '('; compile as a named function for return-type enforcement
        try self.compileFuncWithPrefix(&[_][]const u8{}, true);
        if (self.last_func_obj) |fo| fo.function.name = name.src;

        if (self.inFunc()) {
            _ = try self.defineLocal(name.src, false);
        } else {
            const qname = try self.qualifyGlobalName(name.src);
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try self.addExport(name.src, qname);
        }
        self.matchOpt(.semicolon);
    }

    fn methodDecl(self: *Compiler) !void {
        const kw = self.cur;
        self.advance(); // func
        try self.consume(.lparen);
        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const recv_name = self.cur.src;
        self.advance();
        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const recv_type = self.cur.src;
        self.advance();
        if (self.registry.hasInterfaceType(recv_type)) { self.setErr("cannot define method on interface type '{s}'", .{recv_type}); return error.MethodOnInterface; }
        try self.consume(.rparen);
        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const method_name = self.cur.src;
        self.advance();

        var prefix: [1][]const u8 = .{recv_name};
        try self.compileFuncWithPrefix(prefix[0..], true);

        const qrecv_type = try self.qualifyTypeName(recv_type);
        const total = qrecv_type.len + 1 + method_name.len;
        const key_buf = heap.bump(u8, total) orelse return error.OutOfMemory;
        @memcpy(key_buf[0..qrecv_type.len], qrecv_type);
        key_buf[qrecv_type.len] = '.';
        @memcpy(key_buf[qrecv_type.len + 1 .. total], method_name);
        const key = key_buf[0..total];
        if (self.last_func_obj) |fo| fo.function.name = key;

        if (self.inFunc()) {
            _ = try self.defineLocal(key, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = key }, kw.line);
        }
        self.matchOpt(.semicolon);
    }

    // ── Variable declarations ────────────────────────────────────────────────────

    fn varDecl(self: *Compiler, has_keyword: bool, is_const: bool) !void {
        if (has_keyword and self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const name = self.cur;
        self.advance();
        if (self.match(.colon_eq)) {
            try self.expr();
        } else if (self.cur.typ == .lbracket) {
            // Space-syntax slice type: name []T = expr
            _ = try self.parseFieldTypeSpec();
            try self.consume(.eq);
            try self.expr();
            try chunk.emit2(@intFromEnum(Op.assert_type), 1, name.line);
        } else if (self.cur.typ == .kw_func) {
            // Space-syntax func type annotation: name func(T...) R = expr
            _ = try self.parseFieldTypeSpec();
            try self.consume(.eq);
            try self.expr();
        } else if (self.cur.typ == .ident or self.cur.typ == .question) {
            // Space-syntax typed form: name Type = expr  (no keyword required)
            const type_name = if (self.cur.typ == .ident) self.cur.src else "";
            _ = try self.parseFieldTypeSpec();
            try self.consume(.eq);
            if (common.streq(type_name, "int") or common.streq(type_name, "float") or common.streq(type_name, "bool")) {
                try self.expr();
                if (common.streq(type_name, "int")) {
                    try chunk.emitOp(.cast_int, name.line);
                } else if (common.streq(type_name, "float")) {
                    try chunk.emitOp(.cast_float, name.line);
                } else {
                    try chunk.emitOp(.cast_bool, name.line);
                }
            } else if (type_name.len > 0 and self.registry.hasNamedType(type_name)) {
                try chunk.emitGetGlobal(try self.qualifyTypeName(type_name), name.line);
                try self.expr();
                try chunk.emit2(@intFromEnum(Op.call), 1, name.line);
            } else if (common.streq(type_name, "string")) {
                try self.expr();
                try chunk.emitOp(.cast_string, name.line);
            } else if (common.streq(type_name, "rune")) {
                try self.expr();
                try chunk.emitOp(.cast_rune, name.line);
            } else if (common.streq(type_name, "array")) {
                return self.err("use '[]T' syntax for array types", .{});
            } else if (common.streq(type_name, "map")) {
                // map[K]V typed decl: type was parsed above, just assert it's a map
                try self.expr();
                try chunk.emit2(@intFromEnum(Op.assert_type), 2, name.line);
            } else if (common.streq(type_name, "error")) {
                try self.expr();
                try chunk.emit2(@intFromEnum(Op.assert_type), 3, name.line);
            } else if (type_name.len == 0 or common.streq(type_name, "any") or
                       self.registry.hasInterfaceType(type_name) or
                       self.registry.hasStructTypeLocal(type_name)) {
                try self.expr();
            } else {
                return { self.setErr("unknown type name '{s}'", .{type_name}); return error.UnknownTypeName; };
            }
        } else {
            return self.err("expected expression, found {s}", .{self.tokenName(self.cur.typ)});
        }
        if (self.inFunc()) {
            _ = try self.defineLocal(name.src, is_const);
        } else {
            if (!is_const and self.registry.hasGlobalConst(name.src)) { self.setErr("cannot assign to const variable '{s}'", .{name.src}); return error.AssignToConst; }
            try chunk.emitOpConst(.def_global, .{ .string = try self.qualifyGlobalName(name.src) }, name.line);
            if (is_const) try self.registry.addGlobalConst(name.src);
        }
        self.matchOpt(.semicolon);
    }

    fn isMultiBind(self: *Compiler, op: TT) bool {
        var lx = self.lex;
        const start_line = self.cur.line;
        var saw_comma = false;
        var expect_ident = false;
        var t = lx.next(); // token after first identifier
        while (t.typ != .eof) {
            if (t.line > start_line) return false;
            if (expect_ident) {
                if (t.typ != .ident and t.typ != .kw_trap) return false;
                expect_ident = false;
                t = lx.next();
                continue;
            }
            if (t.typ == .comma) {
                saw_comma = true;
                expect_ident = true;
                t = lx.next();
                continue;
            }
            return saw_comma and t.typ == op;
        }
        return false;
    }

    fn isMultiAssignEq(self: *Compiler) bool {
        var lx = self.lex;
        const start_line = self.cur.line;
        var depth: u32 = 0;
        var saw_comma = false;
        var t = lx.next(); // token after first identifier
        while (t.typ != .eof) {
            if (t.line > start_line) return false;
            switch (t.typ) {
                .lbracket, .lparen => depth += 1,
                .rbracket, .rparen => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .comma => {
                    if (depth == 0) saw_comma = true;
                },
                .eq => return saw_comma and depth == 0,
                .colon_eq, .semicolon, .lbrace, .rbrace => return false,
                else => {},
            }
            t = lx.next();
        }
        return false;
    }

    fn parseNameList(self: *Compiler, out: *[MaxLocals]Token) !u8 {
        var count: u8 = 0;
        while (true) {
            if (self.cur.typ != .ident and self.cur.typ != .kw_trap) return self.err("expected identifier or 'trap', found {s}", .{self.tokenName(self.cur.typ)});
            if (count >= MaxLocals) { self.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
            out[count] = self.cur;
            count += 1;
            self.advance();
            if (!self.match(.comma)) break;
        }
        return count;
    }

    fn emitExprListTuple(self: *Compiler) !u8 {
        var count: u8 = 0;
        try self.expr();
        count += 1;
        while (self.match(.comma)) {
            if (count == 255) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
            try self.expr();
            count += 1;
        }
        if (count > 1) try chunk.emit2(@intFromEnum(Op.build_tuple), count, self.prev.line);
        return count;
    }

    fn parseAssignTargetList(self: *Compiler, targets: *[MaxLocals]AssignTarget, steps: *[MaxLocals * 8]AssignTargetStep) !struct { target_count: u8, step_count: u16 } {
        var tcount: u8 = 0;
        var scount: u16 = 0;
        while (true) {
            if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
            if (tcount >= MaxLocals) { self.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
            const root = self.cur;
            self.advance();
            const start = scount;

            while (true) {
                if (self.match(.dot)) {
                    if (self.cur.typ != .ident) { self.setErr("expected property name, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedPropertyName; }
                    if (scount >= steps.len) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                    steps[scount] = .{ .dot_name = self.cur.src };
                    scount += 1;
                    self.advance();
                    continue;
                }
                if (self.match(.lbracket)) {
                    if (scount >= steps.len) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                    if (self.cur.typ == .number) {
                        const n = common.parseFloat(self.cur.src) orelse return error.BadNumber;
                        steps[scount] = .{ .index_number = n };
                        scount += 1;
                        self.advance();
                    } else if (self.cur.typ == .string) {
                        steps[scount] = .{ .index_string = self.cur.src };
                        scount += 1;
                        self.advance();
                    } else {
                        return self.err("expected number or string index, found {s}", .{self.tokenName(self.cur.typ)});
                    }
                    try self.consume(.rbracket);
                    continue;
                }
                break;
            }

            targets[tcount] = .{
                .root = root,
                .step_start = start,
                .step_count = @intCast(scount - start),
            };
            tcount += 1;
            if (!self.match(.comma)) break;
        }
        return .{ .target_count = tcount, .step_count = scount };
    }

    fn emitAssignTargetPath(self: *Compiler, target: AssignTarget, all_steps: []const AssignTargetStep) !void {
        const vidx: u16 = try chunk.addConst(.{ .string = MultiAssignValueScratch });
        if (target.step_count == 0) {
            try chunk.emitGetGlobalIdx(vidx, target.root.line);
            try self.emitSetVar(target.root);
            return;
        }

        try self.emitGetVar(target.root);
        var i: u8 = 0;
        while (i + 1 < target.step_count) : (i += 1) {
            const st = all_steps[target.step_start + i];
            switch (st) {
                .dot_name => |name| try chunk.emitGetField(name, target.root.line),
                .index_number => |n| {
                    try chunk.emitConst(.{ .number = n }, target.root.line);
                    try chunk.emitOp(.get_index, target.root.line);
                },
                .index_string => |s| {
                    try chunk.emitConst(.{ .string = s }, target.root.line);
                    try chunk.emitOp(.get_index, target.root.line);
                },
            }
        }

        const last = all_steps[target.step_start + target.step_count - 1];
        switch (last) {
            .dot_name => |name| {
                try chunk.emitGetGlobalIdx(vidx, target.root.line);
                try chunk.emitSetField(name, target.root.line);
            },
            .index_number => |n| {
                try chunk.emitConst(.{ .number = n }, target.root.line);
                try chunk.emitGetGlobalIdx(vidx, target.root.line);
                try chunk.emitOp(.set_index, target.root.line);
            },
            .index_string => |s| {
                try chunk.emitConst(.{ .string = s }, target.root.line);
                try chunk.emitGetGlobalIdx(vidx, target.root.line);
                try chunk.emitOp(.set_index, target.root.line);
            },
        }
    }

    fn multiBindStmt(self: *Compiler, is_decl: bool) !void {
        var names: [MaxLocals]Token = undefined;
        var targets: [MaxLocals]AssignTarget = undefined;
        var steps: [MaxLocals * 8]AssignTargetStep = undefined;
        var count: u8 = 0;
        var step_count: u16 = 0;

        if (is_decl) {
            count = try self.parseNameList(&names);
            if (count < 2) return self.err("multi-assign requires at least two targets", .{});
            if (self.inFunc()) {
                var pre_i: u8 = 0;
                while (pre_i < count) : (pre_i += 1) {
                    if (names[pre_i].typ == .kw_trap) continue;
                    try chunk.emitOp(.null_val, names[pre_i].line);
                    _ = try self.defineLocal(names[pre_i].src, false);
                }
            }
        } else {
            const parsed = try self.parseAssignTargetList(&targets, &steps);
            count = parsed.target_count;
            step_count = parsed.step_count;
            if (count < 2) return self.err("multi-assign requires at least two targets", .{});
        }

        try self.consume(if (is_decl) .colon_eq else .eq);
        _ = try self.emitExprListTuple();
        try chunk.emit2(@intFromEnum(Op.tuple_check_arity), count, self.prev.line);

        var i: u8 = 0;
        while (i < count) : (i += 1) {
            if (is_decl) {
                const is_trap_slot = names[i].typ == .kw_trap;
                try chunk.emitOp(.dup, names[i].line);
                try chunk.emit2(@intFromEnum(Op.tuple_get), i, names[i].line);
                if (is_trap_slot) {
                    try chunk.emitOp(.op_trap_check, names[i].line);
                } else if (self.inFunc()) {
                    try self.emitSetVar(names[i]);
                } else {
                    try chunk.emitOpConst(.def_global, .{ .string = try self.qualifyGlobalName(names[i].src) }, names[i].line);
                }
            } else {
                if (targets[i].step_count == 0) try self.ensureMutableBinding(targets[i].root);
                const vidx: u16 = try chunk.addConst(.{ .string = MultiAssignValueScratch });
                try chunk.emitOp(.dup, targets[i].root.line);
                try chunk.emit2(@intFromEnum(Op.tuple_get), i, targets[i].root.line);
                try chunk.emitConstIdx(.def_global, vidx, targets[i].root.line);
                try self.emitAssignTargetPath(targets[i], steps[0..step_count]);
            }
        }
        try chunk.emitOp(.pop, self.prev.line);
        self.matchOpt(.semicolon);
    }

    // ── Statement parsing ────────────────────────────────────────────────────────

    fn deferStmt(self: *Compiler) !void {
        if (!self.inFunc()) { self.setErr("'defer' outside of function", .{}); return error.DeferOutsideFunction; }
        // Parse the callee: a primary expression followed by any chain of
        // .prop and [index] accesses, stopping before the outermost call '('.
        self.advance();
        const pfx = self.prev.typ;
        switch (pfx) {
            .ident => try self.varExpr(self.prev),
            .kw_func => try self.funcLit(),
            .lparen => {
                try self.expr();
                try self.consume(.rparen);
            },
            .err_invalid_char => return error.InvalidChar,
            .err_unterminated_string => return error.UnterminatedString,
            else => { self.setErr("expected expression, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedExpression; },
        }
        // Consume chained .prop and [index]; when .prop( is seen it's a deferred method call.
        while (true) {
            if (self.cur.typ == .lbracket) {
                const line = self.cur.line;
                self.advance();
                try self.expr();
                try self.consume(.rbracket);
                try chunk.emitOp(.get_index, line);
            } else if (self.cur.typ == .dot) {
                self.advance();
                if (self.cur.typ != .ident) { self.setErr("expected property name, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedPropertyName; }
                const prop = self.cur;
                self.advance();
                if (self.cur.typ == .lparen) {
                    self.advance(); // consume '('
                    var argc: u8 = 0;
                    if (!self.check(.rparen)) {
                        while (true) {
                            if (argc == 255) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                            try self.expr();
                            argc += 1;
                            if (!self.match(.comma)) break;
                            if (self.check(.rparen)) break;
                        }
                    }
                    try self.consume(.rparen);
                    try chunk.emitDeferInvokeMethod(prop.src, argc, prop.line);
                    self.matchOpt(.semicolon);
                    return;
                }
                try chunk.emitGetField(prop.src, prop.line);
            } else {
                break;
            }
        }
        // Deferred regular call.
        if (!self.match(.lparen)) { self.setErr("'defer' requires a function call expression", .{}); return error.DeferRequiresCall; }
        const call_line = self.prev.line;
        var argc: u8 = 0;
        if (!self.check(.rparen)) {
            while (true) {
                if (argc == 255) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                try self.expr();
                argc += 1;
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.rparen);
        try chunk.emit2(@intFromEnum(Op.defer_call), argc, call_line);
        self.matchOpt(.semicolon);
    }

    fn stmt(self: *Compiler) anyerror!void {
        if (self.match(.kw_break)) {
            try self.emitBreak(self.prev.line);
            self.matchOpt(.semicolon);
            return;
        }
        if (self.match(.kw_continue)) {
            try self.emitContinue(self.prev.line);
            self.matchOpt(.semicolon);
            return;
        }
        if (self.match(.kw_return)) {
            try self.returnStmt();
            return;
        }
        if (self.match(.kw_defer)) {
            try self.deferStmt();
            return;
        }
        if (self.match(.kw_assert)) {
            try self.assertStmt();
            return;
        }
        if (self.match(.kw_if)) {
            try self.ifStmt();
            return;
        }
        if (self.match(.kw_for)) {
            try self.forStmt();
            return;
        }
        if (self.match(.kw_switch)) {
            try self.switchStmt();
            return;
        }

        if (self.check(.kw_trap)) {
            if (self.peekTT() == .comma and self.isMultiBind(.colon_eq)) {
                try self.multiBindStmt(true);
                return;
            }
            return self.err("expected expression, found {s}", .{self.tokenName(self.cur.typ)});
        }

        if (self.check(.ident)) {
            const ptt = self.peekTT();
            if (ptt == .comma and self.isMultiBind(.colon_eq)) {
                try self.multiBindStmt(true);
                return;
            }
            if ((ptt == .comma or ptt == .dot or ptt == .lbracket) and self.isMultiAssignEq()) {
                try self.multiBindStmt(false);
                return;
            }
            if (ptt == .plus_plus or ptt == .minus_minus) {
                try self.incrStmt();
                return;
            }
            if (ptt == .plus_eq or ptt == .minus_eq or ptt == .star_eq or ptt == .slash_eq or ptt == .percent_eq or ptt == .amp_eq or ptt == .pipe_eq or ptt == .caret_eq or ptt == .lt_lt_eq or ptt == .gt_gt_eq) {
                try self.compoundStmt();
                return;
            }
            if (ptt == .eq) {
                try self.assignStmt();
                return;
            }
            if ((ptt == .dot or ptt == .lbracket) and self.isPropertyAssign()) {
                try self.propertyAssignStmt();
                return;
            }
            if (ptt == .lbracket and self.isIndexAssign()) {
                try self.indexAssignStmt();
                return;
            }
        }

        try self.expr();
        try chunk.emitOp(.pop, self.prev.line);
        self.matchOpt(.semicolon);
    }

    fn assertStmt(self: *Compiler) !void {
        const line = self.prev.line;
        try self.expr();
        if (self.match(.comma)) {
            try self.expr();
            try chunk.emitOp(.op_assert_msg, line);
        } else {
            try chunk.emitOp(.op_assert, line);
        }
        self.matchOpt(.semicolon);
    }

    fn returnStmt(self: *Compiler) !void {
        if (!self.inFunc()) { self.setErr("'return' outside of function", .{}); return error.ReturnOutsideFunction; }
        const line = self.prev.line;
        const scope = self.currentScope();
        if (self.check(.rbrace) or self.check(.eof) or self.check(.semicolon)) {
            // Bare return: use named return variables if present, otherwise null.
            try emitImplicitReturn(scope, line);
        } else if (scope.named_return_count > 0) {
            // Named-return function with explicit value(s): assign to the named return
            // slots first so deferred closures can observe and modify them.
            if (scope.named_return_count == 1) {
                try self.expr();
                try chunk.emit2(@intFromEnum(Op.set_local), scope.named_return_base, line);
            } else {
                var ri: u8 = 0;
                while (ri < scope.named_return_count) : (ri += 1) {
                    if (ri > 0) try self.consume(.comma);
                    try self.expr();
                    try chunk.emit2(@intFromEnum(Op.set_local), scope.named_return_base + ri, line);
                }
            }
            try emitImplicitReturn(scope, line);
        } else {
            if (scope.is_named and !scope.has_typed_returns) return error.MissingReturnType;
            _ = try self.emitExprListTuple();
        }
        try chunk.emitOp(.ret, line);
        self.matchOpt(.semicolon);
    }

    fn incrStmt(self: *Compiler) !void {
        const name = self.cur;
        try self.ensureMutableBinding(name);
        self.advance();
        const is_inc = self.cur.typ == .plus_plus;
        self.advance();
        try self.emitGetVar(name);
        try chunk.emitConst(.{ .number = 1.0 }, name.line);
        try chunk.emitOp(if (is_inc) .add else .sub, name.line);
        try self.emitSetVar(name);
        self.matchOpt(.semicolon);
    }

    fn compoundStmt(self: *Compiler) !void {
        const name = self.cur;
        try self.ensureMutableBinding(name);
        self.advance();
        const op_tok = self.cur;
        self.advance();
        try self.emitGetVar(name);
        try self.expr();
        const op: Op = switch (op_tok.typ) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .percent_eq => .mod,
            .amp_eq => .bit_and,
            .pipe_eq => .bit_or,
            .caret_eq => .bit_xor,
            .lt_lt_eq => .shl,
            .gt_gt_eq => .shr,
            else => return self.err("unsupported compound assignment operator", .{}),
        };
        try chunk.emitOp(op, op_tok.line);
        try self.emitSetVar(name);
        self.matchOpt(.semicolon);
    }

    fn assignStmt(self: *Compiler) !void {
        const name = self.cur;
        // `_` is the blank identifier: evaluate and discard.
        if (common.streq(name.src, "_")) {
            self.advance();
            try self.consume(.eq);
            try self.expr();
            try chunk.emitOp(.pop, name.line);
            self.matchOpt(.semicolon);
            return;
        }
        try self.ensureMutableBinding(name);
        self.advance();
        try self.consume(.eq);
        try self.expr();
        try self.emitSetVar(name);
        self.matchOpt(.semicolon);
    }

    fn isIndexAssign(self: *Compiler) bool {
        var lx = self.lex;
        const start_line = self.cur.line;
        var depth: u32 = 0;
        var t = lx.next();
        while (t.typ != .eof) {
            if (t.line > start_line and depth == 0) return false;
            if (t.typ == .lbracket) {
                depth += 1;
            } else if (t.typ == .rbracket) {
                depth -= 1;
                if (depth == 0) return lx.next().typ == .eq;
            }
            t = lx.next();
        }
        return false;
    }

    fn isPropertyAssign(self: *Compiler) bool {
        var lx = self.lex;
        const start_line = self.cur.line;
        var depth: u32 = 0;
        var saw_path = false;
        var t = lx.next(); // token after first identifier
        while (t.typ != .eof) {
            if (t.line > start_line and depth == 0) return false;
            switch (t.typ) {
                .dot => saw_path = true,
                .lbracket => {
                    saw_path = true;
                    depth += 1;
                },
                .rbracket => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq => return saw_path and depth == 0,
                .semicolon, .lbrace, .rbrace => return false,
                else => {},
            }
            t = lx.next();
        }
        return false;
    }

    fn indexAssignStmt(self: *Compiler) !void {
        const name = self.cur;
        self.advance();
        try self.emitGetVar(name);
        try self.consume(.lbracket);
        try self.expr();
        try self.consume(.rbracket);
        try self.consume(.eq);
        try self.expr();
        try chunk.emitOp(.set_index, name.line);
        self.matchOpt(.semicolon);
    }

    fn propertyAssignStmt(self: *Compiler) !void {
        const root = self.cur;
        self.advance();
        try self.emitGetVar(root);

        // Track the kind of the last accessor so we can emit get_field/set_field for
        // dot accesses and the old constant+get_index/set_index path for bracket accesses.
        const LastKind = enum { dot_name, bracket };
        var last_kind: LastKind = .bracket;
        var last_name: []const u8 = undefined;
        var last_line: u32 = 0;

        while (true) {
            if (self.match(.dot)) {
                if (self.cur.typ != .ident) { self.setErr("expected property name, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedPropertyName; }
                const prop = self.cur;
                self.advance();
                if (self.check(.eq) or self.check(.plus_eq) or self.check(.minus_eq) or self.check(.star_eq) or self.check(.slash_eq) or self.check(.percent_eq) or self.check(.amp_eq) or self.check(.pipe_eq) or self.check(.caret_eq) or self.check(.lt_lt_eq) or self.check(.gt_gt_eq)) {
                    // This is the last step — record name, do NOT push key, break.
                    last_kind = .dot_name;
                    last_name = prop.src;
                    last_line = prop.line;
                    break;
                }
                try chunk.emitGetField(prop.src, prop.line);
                continue;
            }

            if (self.match(.lbracket)) {
                try self.expr();
                try self.consume(.rbracket);
                if (self.check(.eq) or self.check(.plus_eq) or self.check(.minus_eq) or self.check(.star_eq) or self.check(.slash_eq) or self.check(.percent_eq) or self.check(.amp_eq) or self.check(.pipe_eq) or self.check(.caret_eq) or self.check(.lt_lt_eq) or self.check(.gt_gt_eq)) {
                    last_kind = .bracket;
                    break;
                }
                try chunk.emitOp(.get_index, self.prev.line);
                continue;
            }

            return self.err("expected '.' or '[', found {s}", .{self.tokenName(self.cur.typ)});
        }

        const op_tok = self.cur;

        if (self.match(.eq)) {
            try self.expr();
            switch (last_kind) {
                .dot_name => try chunk.emitSetField(last_name, last_line),
                .bracket => try chunk.emitOp(.set_index, self.prev.line),
            }
            self.matchOpt(.semicolon);
            return;
        }

        if (self.match(.plus_eq) or self.match(.minus_eq) or self.match(.star_eq) or self.match(.slash_eq) or self.match(.percent_eq) or self.match(.amp_eq) or self.match(.pipe_eq) or self.match(.caret_eq) or self.match(.lt_lt_eq) or self.match(.gt_gt_eq)) {
            const op: Op = switch (op_tok.typ) {
                .plus_eq => .add,
                .minus_eq => .sub,
                .star_eq => .mul,
                .slash_eq => .div,
                .percent_eq => .mod,
                .amp_eq => .bit_and,
                .pipe_eq => .bit_or,
                .caret_eq => .bit_xor,
                .lt_lt_eq => .shl,
                .gt_gt_eq => .shr,
                else => return self.err("unsupported compound assignment operator", .{}),
            };
            switch (last_kind) {
                .dot_name => {
                    // Stack: container. Dup it, read old value with get_field, compute, write back.
                    try chunk.emitOp(.dup, op_tok.line);
                    try chunk.emitGetField(last_name, last_line);
                    try self.expr();
                    try chunk.emitOp(op, op_tok.line);
                    try chunk.emitSetField(last_name, op_tok.line);
                },
                .bracket => {
                    // Stack: container, key. Dup pair, read old value, compute, write back.
                    try chunk.emitOp(.dup2, op_tok.line);
                    try chunk.emitOp(.get_index, op_tok.line);
                    try self.expr();
                    try chunk.emitOp(op, op_tok.line);
                    try chunk.emitOp(.set_index, op_tok.line);
                },
            }
            self.matchOpt(.semicolon);
            return;
        }

        return self.err("unsupported compound assignment operator", .{});
    }

    fn ifStmt(self: *Compiler) anyerror!void {
        const local_base: u8 = if (self.inFunc()) self.currentScope().local_count else 0;

        if (self.hasInitSemicolon()) {
            if (self.check(.ident) and self.peekTT() == .colon_eq) {
                try self.varDecl(false, false);
            } else if (self.check(.ident) and self.isTypedVarDecl()) {
                try self.varDecl(false, false);
            } else if (self.match(.kw_const)) {
                try self.varDecl(true, true);
            } else if (self.check(.ident) and self.peekTT() == .eq) {
                try self.assignStmt();
            } else {
                try self.expr();
                try chunk.emitOp(.pop, self.prev.line);
                self.matchOpt(.semicolon);
            }
        }

        try self.expr();
        try self.consume(.lbrace);

        const then_j = try chunk.emitJump(.jif_pop, self.prev.line);
        try self.block();

        const else_j = try chunk.emitJump(.jump, self.prev.line);
        try chunk.patchJump(then_j);

        if (self.match(.kw_else)) {
            if (self.match(.kw_if)) {
                try self.ifStmt();
            } else {
                try self.consume(.lbrace);
                try self.block();
            }
        }
        try chunk.patchJump(else_j);
        try self.cleanupLocals(local_base, self.prev.line);
    }

    fn hasInitSemicolon(self: *Compiler) bool {
        var lx = self.lex;
        var t = self.cur;
        while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
            if (t.typ == .semicolon) return true;
            t = lx.next();
        }
        return false;
    }

    fn forStmt(self: *Compiler) anyerror!void {
        if (self.isForIn()) {
            try self.forInStmt();
        } else if (self.isCStyleFor()) {
            try self.cForStmt();
        } else {
            try self.whileForStmt();
        }
    }

    fn isForIn(self: *Compiler) bool {
        var lx = self.lex;
        var t = self.cur;
        while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
            if (t.typ == .kw_in) return true;
            if (t.typ == .semicolon) return false;
            t = lx.next();
        }
        return false;
    }

    fn declareLoopVar(self: *Compiler, name: Token) !void {
        if (self.inFunc()) {
            try chunk.emitOp(.null_val, name.line);
            _ = try self.defineLocal(name.src, false);
        } else {
            try chunk.emitOp(.null_val, name.line);
            try chunk.emitOpConst(.def_global, .{ .string = try self.qualifyGlobalName(name.src) }, name.line);
        }
    }

    fn assignLoopVar(self: *Compiler, name: Token) !void {
        try self.emitSetVar(name);
    }

    fn forInStmt(self: *Compiler) anyerror!void {
        const local_base: u8 = if (self.inFunc()) self.currentScope().local_count else 0;
        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        const kname = self.cur;
        self.advance();
        var vname: ?Token = null;
        if (self.match(.comma)) {
            if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
            vname = self.cur;
            self.advance();
        }
        try self.consume(.kw_in);

        try self.declareLoopVar(kname);
        if (vname) |vn| try self.declareLoopVar(vn);

        try self.expr(); // iterable
        try chunk.emitOp(.iter_init, self.prev.line);
        // Claim a hidden local slot for the iterator so that body locals land on the
        // correct stack offsets. Without this, body-local slot N resolves to the iterator
        // object instead of the actual value.
        const in_func = self.inFunc();
        if (in_func) self.currentScope().local_count += 1;
        const body_keep: u8 = if (in_func) self.currentScope().local_count else 0;

        const loop_start = chunk.codeLen();
        // In functions the hidden local slot is cleaned up by cleanupLocals; at top-level
        // cleanupLocals is a no-op so an explicit pop is still needed (iter_pops=1).
        try self.pushLoop(loop_start, local_base, body_keep, if (in_func) @as(u8, 0) else @as(u8, 1));
        try chunk.emitOp(if (vname == null) .iter_next1 else .iter_next2, self.prev.line);
        const exit_j = try chunk.emitJump(.jif_pop, self.prev.line);

        if (vname) |vn| {
            // stack: iter, key, value
            try self.assignLoopVar(vn);
            try self.assignLoopVar(kname);
        } else {
            // stack: iter, value
            try self.assignLoopVar(kname);
        }

        try self.consume(.lbrace);
        try self.block();
        try chunk.emitLoop(loop_start, self.prev.line);

        try chunk.patchJump(exit_j);
        if (!in_func) try chunk.emitOp(.pop, self.prev.line); // pop iterator (top-level only)
        try self.cleanupLocals(local_base, self.prev.line);

        const loop = self.popLoop();
        var i: usize = 0;
        while (i < loop.break_count) : (i += 1) {
            try chunk.patchJump(loop.break_offsets[i]);
        }
    }

    fn switchStmt(self: *Compiler) anyerror!void {
        try self.expr();
        try self.consume(.lbrace);

        var end_jumps: [MaxSwitchJumps]usize = undefined;
        var end_count: usize = 0;
        var saw_default = false;

        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.match(.kw_case)) {
                if (self.check(.dot)) {
                    // Variant arm pattern: case .arm_name { } or case .arm_name(binding) { }
                    const dot_line = self.cur.line;
                    self.advance(); // consume '.'
                    if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                    const arm_name_tok = self.cur;
                    self.advance(); // consume arm name
                    var binding: ?[]const u8 = null;
                    if (self.match(.lparen)) {
                        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                        binding = self.cur.src;
                        self.advance();
                        try self.consume(.rparen);
                    }
                    // Emit: dup, variant_check arm_name, jump_if_false [H]
                    try chunk.emitOp(.dup, dot_line);
                    try chunk.emitOpConst(.variant_check, .{ .string = arm_name_tok.src }, dot_line);
                    const next_case = try chunk.emitJump(.jif_pop, dot_line);
                    // Handle switch value and optional binding
                    const local_before = if (self.inFunc()) self.currentScope().local_count else 0;
                    if (binding != null) {
                        try chunk.emitOp(.variant_payload, dot_line);
                        if (self.inFunc()) {
                            _ = try self.defineLocal(binding.?, false);
                        } else {
                            try chunk.emitOpConst(.def_global, .{ .string = try self.qualifyGlobalName(binding.?) }, dot_line);
                        }
                    } else {
                        try chunk.emitOp(.pop, dot_line); // discard switch value
                    }
                    try self.consume(.lbrace);
                    try self.block();
                    try self.cleanupLocals(local_before, self.prev.line);
                    if (end_count >= MaxSwitchJumps) { self.setErr("too many switch cases (max {d})", .{MaxSwitchJumps}); return error.TooManySwitchCases; }
                    end_jumps[end_count] = try chunk.emitJump(.jump, self.prev.line);
                    end_count += 1;
                    try chunk.patchJump(next_case);
                } else {
                    // Regular value case: dup switch-val, compare, jif_pop to next case.
                    // If matched (no jump), pop the switch-val before running the body so
                    // the stack is balanced on the jump-to-end path.
                    try chunk.emitOp(.dup, self.prev.line);
                    try self.expr();
                    try chunk.emitBinOpFused(.eq, self.prev.line);
                    const next_case = try chunk.emitJump(.jif_pop, self.prev.line);
                    try chunk.emitOp(.pop, self.prev.line); // consume the switch value
                    try self.consume(.lbrace);
                    try self.block();
                    if (end_count >= MaxSwitchJumps) { self.setErr("too many switch cases (max {d})", .{MaxSwitchJumps}); return error.TooManySwitchCases; }
                    end_jumps[end_count] = try chunk.emitJump(.jump, self.prev.line);
                    end_count += 1;
                    try chunk.patchJump(next_case);
                }
                continue;
            }

            if (self.match(.kw_default)) {
                if (saw_default) return error.DuplicateDefaultCase;
                saw_default = true;
                // Pop the switch value that is still on the stack when default is reached.
                try chunk.emitOp(.pop, self.prev.line);
                try self.consume(.lbrace);
                try self.block();
                if (end_count >= MaxSwitchJumps) { self.setErr("too many switch cases (max {d})", .{MaxSwitchJumps}); return error.TooManySwitchCases; }
                end_jumps[end_count] = try chunk.emitJump(.jump, self.prev.line);
                end_count += 1;
                continue;
            }

            return self.err("expected 'case' or 'default', found {s}", .{self.tokenName(self.cur.typ)});
        }

        try self.consume(.rbrace);
        try chunk.emitOp(.pop, self.prev.line);

        var i: usize = 0;
        while (i < end_count) : (i += 1) {
            try chunk.patchJump(end_jumps[i]);
        }
    }

    fn isCStyleFor(self: *Compiler) bool {
        var lx = self.lex;
        var t = self.cur;
        while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
            if (t.typ == .semicolon) return true;
            t = lx.next();
        }
        return false;
    }

    fn whileForStmt(self: *Compiler) anyerror!void {
        const loop_start = chunk.codeLen();
        try self.pushLoop(loop_start, self.loopKeepBase(), self.loopKeepBase(), 0);
        try self.expr();
        try self.consume(.lbrace);
        const exit_j = try chunk.emitJump(.jif_pop, self.prev.line);
        try self.block();
        try chunk.emitLoop(loop_start, self.prev.line);
        try chunk.patchJump(exit_j);
        const loop = self.popLoop();
        var i: usize = 0;
        while (i < loop.break_count) : (i += 1) {
            try chunk.patchJump(loop.break_offsets[i]);
        }
    }

    fn cForStmt(self: *Compiler) anyerror!void {
        const local_base: u8 = if (self.inFunc()) self.currentScope().local_count else 0;

        if (self.match(.semicolon)) {} else if (self.check(.ident) and self.peekTT() == .colon_eq) {
            try self.varDecl(false, false);
        } else if (self.check(.ident) and self.isTypedVarDecl()) {
            try self.varDecl(false, false);
        } else if (self.match(.kw_const)) {
            try self.varDecl(true, true);
        } else if (self.check(.ident) and self.peekTT() == .eq) {
            try self.assignStmt();
        } else {
            try self.expr();
            try chunk.emitOp(.pop, self.prev.line);
            try self.consume(.semicolon);
        }

        var loop_start = chunk.codeLen();
        var exit_j: ?usize = null;

        if (!self.match(.semicolon)) {
            try self.expr();
            try self.consume(.semicolon);
            exit_j = try chunk.emitJump(.jif_pop, self.prev.line);
        }

        if (!self.check(.lbrace)) {
            const body_j = try chunk.emitJump(.jump, self.prev.line);
            const post_start = chunk.codeLen();
            if (self.check(.ident) and (self.peekTT() == .plus_plus or self.peekTT() == .minus_minus)) {
                try self.incrStmt();
            } else if (self.check(.ident) and self.peekTT() == .eq) {
                try self.assignStmt();
            } else if (self.check(.ident)) {
                const ptt = self.peekTT();
                if (ptt == .plus_eq or ptt == .minus_eq or ptt == .star_eq or ptt == .slash_eq or ptt == .percent_eq or ptt == .amp_eq or ptt == .pipe_eq or ptt == .caret_eq or ptt == .lt_lt_eq or ptt == .gt_gt_eq) {
                    try self.compoundStmt();
                } else {
                    try self.expr();
                    try chunk.emitOp(.pop, self.prev.line);
                }
            } else {
                try self.expr();
                try chunk.emitOp(.pop, self.prev.line);
            }
            try chunk.emitLoop(loop_start, self.prev.line);
            loop_start = post_start;
            try chunk.patchJump(body_j);
        }

        try self.pushLoop(loop_start, local_base, self.loopKeepBase(), 0);
        try self.consume(.lbrace);
        try self.block();
        try chunk.emitLoop(loop_start, self.prev.line);

        if (exit_j) |j| {
            try chunk.patchJump(j);
        }

        try self.cleanupLocals(local_base, self.prev.line);

        const loop = self.popLoop();
        var i: usize = 0;
        while (i < loop.break_count) : (i += 1) {
            try chunk.patchJump(loop.break_offsets[i]);
        }
    }

    // ── Block and function bodies ────────────────────────────────────────────────

    fn block(self: *Compiler) anyerror!void {
        const local_base: u8 = if (self.inFunc()) self.currentScope().local_count else 0;
        while (!self.check(.rbrace) and !self.check(.eof)) try self.decl();
        try self.consume(.rbrace);
        try self.cleanupLocals(local_base, self.prev.line);
    }

    // Emit the value for a bare `return` (or fall-off-end) given the current function scope.
    // Named returns: collect the named locals. No named returns: push null.
    fn emitImplicitReturn(scope: *FuncInfo, line: u32) !void {
        if (scope.named_return_count == 0) {
            try chunk.emitOp(.null_val, line);
        } else if (scope.named_return_count == 1) {
            try chunk.emit2(@intFromEnum(Op.get_local), scope.named_return_base, line);
        } else {
            var ri: u8 = 0;
            while (ri < scope.named_return_count) : (ri += 1) {
                try chunk.emit2(@intFromEnum(Op.get_local), scope.named_return_base + ri, line);
            }
            try chunk.emit2(@intFromEnum(Op.build_tuple), scope.named_return_count, line);
        }
    }

    fn funcLit(self: *Compiler) anyerror!void {
        try self.compileFuncWithPrefix(&[_][]const u8{}, false);
    }

    fn compileFuncWithPrefix(self: *Compiler, prefix: []const []const u8, is_named: bool) anyerror!void {
        try self.consume(.lparen);
        var param_names: [MaxLocals][]const u8 = undefined;
        var param_types: [MaxLocals]FieldTypeSpec = undefined;
        var param_const: [MaxLocals]bool = [_]bool{false} ** MaxLocals;
        var arity: u8 = 0;
        var is_variadic = false;
        var variadic_type: FieldTypeSpec = undefined;

        const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        any_alts[0] = .{ .typ = .any };
        const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };
        variadic_type = any_spec;

        if (prefix.len > MaxLocals) { self.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
        var pi0: usize = 0;
        while (pi0 < prefix.len) : (pi0 += 1) {
            param_names[arity] = prefix[pi0];
            param_types[arity] = any_spec;
            arity += 1;
        }

        if (!self.check(.rparen)) {
            while (true) {
                if (arity >= MaxLocals) { self.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
                const vari = self.match(.ellipsis);
                const p_is_const = self.match(.kw_const);
                if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                param_names[arity] = self.cur.src;
                param_const[arity] = p_is_const;
                arity += 1;
                self.advance();
                if (self.cur.typ != .question and self.cur.typ != .ident and self.cur.typ != .kw_func and self.cur.typ != .lbracket) { self.setErr("expected type annotation, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedTypeAnnotation; }
                const ptype: FieldTypeSpec = try self.parseFieldTypeSpec();
                param_types[arity - 1] = ptype;
                if (vari) {
                    is_variadic = true;
                    variadic_type = ptype;
                    break;
                }
                if (!self.match(.comma)) break;
                if (self.check(.rparen)) break;
            }
        }
        try self.consume(.rparen);

        var return_types: [MaxLocals]FieldTypeSpec = undefined;
        var return_names: [MaxLocals][]const u8 = undefined;
        var return_count: u8 = 0;
        var has_typed_returns = false;
        var named_return_count: u8 = 0;

        if (self.match(.lparen)) {
            // Detect named vs anonymous: named if first entry is 'ident type_start'.
            const is_named_returns = self.cur.typ == .ident and
                (self.peekToken().typ == .ident or self.peekToken().typ == .question or self.peekToken().typ == .kw_func or self.peekToken().typ == .lbracket);
            while (true) {
                if (is_named_returns) {
                    if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
                    return_names[return_count] = self.cur.src;
                    self.advance();
                }
                return_types[return_count] = try self.parseFieldTypeSpec();
                return_count += 1;
                has_typed_returns = true;
                if (!self.match(.comma)) break;
                if (self.check(.rparen)) break;
            }
            try self.consume(.rparen);
            if (is_named_returns) named_return_count = return_count;
        } else if (self.cur.typ == .question or self.cur.typ == .ident or self.cur.typ == .kw_func or self.cur.typ == .lbracket) {
            return_types[0] = try self.parseFieldTypeSpec();
            return_count = 1;
            has_typed_returns = true;
        }

        const jump_over = try chunk.emitJump(.jump, self.prev.line);
        const func_ip = chunk.codeLen();

        if (self.scope_depth >= MaxScopes) return error.TooManyNestedFunctions;
        self.scopes[self.scope_depth] = .{};
        self.scope_depth += 1;
        const scope = self.currentScope();
        scope.is_named = is_named;
        scope.has_typed_returns = has_typed_returns;

        var pi: u8 = 0;
        while (pi < arity) : (pi += 1) {
            scope.locals[pi] = .{ .name = param_names[pi], .is_const = param_const[pi] };
        }
        scope.local_count = arity;

        // Named return variables occupy slots [arity .. arity+named_return_count).
        // Scalar types (int, float, bool, string) are zero-initialised so that
        // compound-assignment operators (+=, etc.) work without a prior explicit
        // assignment. Other types (nullable, any, complex) are initialised to null.
        if (named_return_count > 0) {
            scope.named_return_base = arity;
            scope.named_return_count = named_return_count;
            var ri: u8 = 0;
            while (ri < named_return_count) : (ri += 1) {
                scope.locals[arity + ri] = .{ .name = return_names[ri], .is_const = false };
                scope.local_count += 1;
                const rt = return_types[ri];
                if (rt.alts.len == 1) {
                    switch (rt.alts[0].typ) {
                        .int, .float, .rune_t =>
                            try chunk.emitConst(.{ .number = 0.0 }, @intCast(func_ip)),
                        .boolean =>
                            try chunk.emitOp(.false_val, @intCast(func_ip)),
                        .string =>
                            try chunk.emitConst(.{ .string = "" }, @intCast(func_ip)),
                        else =>
                            try chunk.emitOp(.null_val, @intCast(func_ip)),
                    }
                } else {
                    try chunk.emitOp(.null_val, @intCast(func_ip));
                }
            }
        }

        try self.consume(.lbrace);
        const body_local_base: u8 = arity + named_return_count;
        while (!self.check(.rbrace) and !self.check(.eof)) try self.decl();
        try self.consume(.rbrace);
        try self.cleanupLocals(body_local_base, self.prev.line);

        // Implicit return: bare named returns or null.
        try emitImplicitReturn(scope, self.prev.line);
        try chunk.emitOp(.ret, self.prev.line);

        self.scope_depth -= 1;
        try chunk.patchJump(jump_over);

        const uv_count = scope.upvalue_count;
        const slots = heap.bump(u8, uv_count) orelse return error.OutOfMemory;
        var ui: u8 = 0;
        while (ui < uv_count) : (ui += 1) {
            const uv = scope.upvalues[ui];
            const flag: u8 = if (uv.from_upvalue) @as(u8, 0x80) else @as(u8, 0x00);
            slots[ui] = flag | uv.index;
        }

        const ptypes = heap.bump(FieldTypeSpec, arity) orelse return error.OutOfMemory;
        var has_typed_params = false;
        var pti: u8 = 0;
        while (pti < arity) : (pti += 1) {
            ptypes[pti] = param_types[pti];
            if (!(param_types[pti].alts.len == 1 and param_types[pti].alts[0].typ == .any)) {
                has_typed_params = true;
            }
        }

        const rtypes = heap.bump(FieldTypeSpec, return_count) orelse return error.OutOfMemory;
        var rti: u8 = 0;
        while (rti < return_count) : (rti += 1) rtypes[rti] = return_types[rti];

        const func_obj = heap.allocObject() orelse return error.OutOfMemory;
        func_obj.* = .{ .function = .{
            .ip = func_ip,
            .arity = arity,
            .is_variadic = is_variadic,
            .variadic_type = variadic_type,
            .capture_slots = slots[0..uv_count],
            .param_types = ptypes[0..arity],
            .has_typed_params = has_typed_params,
            .return_types = rtypes[0..return_count],
            .has_typed_returns = has_typed_returns,
            .named_return_count = named_return_count,
        } };
        self.last_func_obj = func_obj;
        const cidx: u16 = try chunk.addConst(.{ .object = func_obj });
        try chunk.emitConstIdx(.make_closure, cidx, self.prev.line);
    }

    // ── Expression parsing (Pratt) ───────────────────────────────────────────────

    fn skipTypeSpec(self: *Compiler) !void {
        _ = self.match(.question);
        if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
        self.advance();
        while (self.match(.pipe)) {
            if (self.cur.typ != .ident) return self.err("expected identifier, found {s}", .{self.tokenName(self.cur.typ)});
            self.advance();
        }
    }

    fn expr(self: *Compiler) !void {
        try self.parsePrecedence(.assign);
    }

    fn parsePrecedence(self: *Compiler, p: Prec) anyerror!void {
        self.advance();
        const pfx = self.prev.typ;
        switch (pfx) {
            .number => try self.numLit(),
            .string => try self.strLitExpr(),
            .rune => try self.runeLitExpr(),
            .kw_true => try chunk.emitOp(.true_val, self.prev.line),
            .kw_false => try chunk.emitOp(.false_val, self.prev.line),
            .kw_null => try chunk.emitOp(.null_val, self.prev.line),
            .ident => try self.varExpr(self.prev),
            .minus, .bang, .tilde => try self.unaryExpr(pfx),
            .lparen => {
                try self.expr();
                try self.consume(.rparen);
            },
            .lbracket => try self.arrayLit(),
            .lbrace => try self.mapLit(),
            .kw_func => try self.funcLit(),
            .kw_import => try self.importExpr(),
            .err_invalid_char => return error.InvalidChar,
            .err_unterminated_string => return error.UnterminatedString,
            else => { self.setErr("expected expression, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedExpression; },
        }
        while (@intFromEnum(p) <= @intFromEnum(tokPrec(self.cur.typ))) {
            self.advance();
            try self.infixExpr(self.prev.typ);
        }
    }

    fn numLit(self: *Compiler) !void {
        const n = common.parseFloat(self.prev.src) orelse return error.BadNumber;
        try chunk.emitConst(.{ .number = n }, self.prev.line);
    }

    fn strLitExpr(self: *Compiler) !void {
        try chunk.emitConst(.{ .string = self.prev.src }, self.prev.line);
    }

    fn runeLitExpr(self: *Compiler) !void {
        const raw = self.prev.src;
        if (raw.len < 3) return self.err("rune literal must contain exactly one codepoint", .{});
        const body = raw[1 .. raw.len - 1];
        var it = std.unicode.Utf8View.init(body) catch return error.TypeError;
        var iter = it.iterator();
        const cp = iter.nextCodepoint() orelse return self.err("rune literal must contain exactly one codepoint", .{});
        if (iter.nextCodepoint() != null) return self.err("rune literal must contain exactly one codepoint", .{});
        try chunk.emitConst(.{ .rune = @intCast(cp) }, self.prev.line);
    }

    fn varExpr(self: *Compiler, name: Token) !void {
        if ((common.streq(name.src, "int") or common.streq(name.src, "float") or common.streq(name.src, "bool") or common.streq(name.src, "string")) and self.match(.lparen)) {
            try self.expr();
            try self.consume(.rparen);
            if (common.streq(name.src, "int")) {
                try chunk.emitOp(.cast_int, name.line);
            } else if (common.streq(name.src, "float")) {
                try chunk.emitOp(.cast_float, name.line);
            } else if (common.streq(name.src, "bool")) {
                try chunk.emitOp(.cast_bool, name.line);
            } else {
                try chunk.emitOp(.cast_string, name.line);
            }
            return;
        }
        if (self.check(.lbrace) and self.looksLikeStructLiteral()) {
            try self.structInstanceLit(name);
            return;
        }
        try self.emitGetVar(name);
    }

    fn looksLikeStructLiteral(self: *Compiler) bool {
        var lx = self.lex;
        var t = lx.next(); // first token inside '{'
        if (t.typ == .rbrace) return true; // empty literal form (if ever allowed)
        if (!(t.typ == .ident or t.typ == .string)) return false;
        t = lx.next();
        return t.typ == .colon;
    }

    fn structInstanceLit(self: *Compiler, type_name: Token) !void {
        try self.emitGetVar(type_name);
        try self.consume(.lbrace);
        var count: u8 = 0;
        if (!self.check(.rbrace)) {
            while (true) {
                if (count == 255) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                if (self.check(.ident)) {
                    const key_tok = self.cur;
                    self.advance();
                    try chunk.emitConst(.{ .string = key_tok.src }, key_tok.line);
                } else if (self.check(.string)) {
                    try chunk.emitConst(.{ .string = self.cur.src }, self.cur.line);
                    self.advance();
                } else return self.err("expected identifier or string key, found {s}", .{self.tokenName(self.cur.typ)});
                try self.consume(.colon);
                try self.expr();
                count += 1;
                if (!self.match(.comma)) break;
                if (self.check(.rbrace)) break;
            }
        }
        try self.consume(.rbrace);
        try chunk.emit2(@intFromEnum(Op.build_struct_instance), count, type_name.line);
    }

    fn arrayLit(self: *Compiler) !void {
        var count: u8 = 0;
        if (!self.check(.rbracket)) {
            while (true) {
                try self.expr();
                if (count == 255) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                count += 1;
                if (!self.match(.comma)) break;
                if (self.check(.rbracket)) break;
            }
        }
        try self.consume(.rbracket);
        try chunk.emit2(@intFromEnum(Op.build_array), count, self.prev.line);
    }

    fn mapLit(self: *Compiler) !void {
        var count: u8 = 0;
        if (!self.check(.rbrace)) {
            while (true) {
                if (count == 255) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }

                try self.expr();

                try self.consume(.colon);
                try self.expr();
                count += 1;
                if (!self.match(.comma)) break;
                if (self.check(.rbrace)) break;
            }
        }
        try self.consume(.rbrace);
        try chunk.emit2(@intFromEnum(Op.build_map), count, self.prev.line);
    }

    fn unaryExpr(self: *Compiler, tt: TT) !void {
        try self.parsePrecedence(.unary);
        switch (tt) {
            .minus => try chunk.emitOp(.neg, self.prev.line),
            .bang => try chunk.emitOp(.not, self.prev.line),
            .tilde => try chunk.emitOp(.bit_not, self.prev.line),
            else => unreachable,
        }
    }

    fn infixExpr(self: *Compiler, tt: TT) anyerror!void {
        const line = self.prev.line;
        const col = self.prev.col;

        if (tt == .dot) {
            if (self.cur.typ != .ident) { self.setErr("expected property name, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedPropertyName; }
            const prop = self.cur;
            self.advance();
            if (self.match(.lparen)) {
                var argc: u8 = 0;
                if (!self.check(.rparen)) {
                    while (true) {
                        try self.expr();
                        argc += 1;
                        if (!self.match(.comma)) break;
                        if (self.check(.rparen)) break;
                    }
                }
                try self.consume(.rparen);
                try chunk.emitInvokeMethod(prop.src, argc, line);
                return;
            }
            try chunk.emitGetField(prop.src, line);
            if (self.check(.lbrace) and self.looksLikeStructLiteral()) {
                try self.structInstanceLitAfterValue(prop.line);
            }
            return;
        }

        if (tt == .lbracket) {
            if (self.match(.colon)) {
                var flags: u8 = 0;
                if (!self.check(.rbracket)) {
                    try self.expr();
                    flags |= 0b10;
                }
                try self.consume(.rbracket);
                try chunk.emit2(@intFromEnum(Op.get_slice), flags, line);
                return;
            }

            try self.expr();
            if (self.match(.colon)) {
                var flags: u8 = 0b01;
                if (!self.check(.rbracket)) {
                    try self.expr();
                    flags |= 0b10;
                }
                try self.consume(.rbracket);
                try chunk.emit2(@intFromEnum(Op.get_slice), flags, line);
                return;
            }

            try self.consume(.rbracket);
            try chunk.emitOp(.get_index, line);
            return;
        }
        if (tt == .lparen) {
            var argc: u8 = 0;
            if (!self.check(.rparen)) {
                while (true) {
                    try self.expr();
                    argc += 1;
                    if (!self.match(.comma)) break;
                    if (self.check(.rparen)) break;
                }
            }
            try self.consume(.rparen);
            chunk.setCol(col);
            try chunk.emit2(@intFromEnum(Op.call), argc, line);
            return;
        }

        const p = tokPrec(tt);
        if (tt == .amp_amp) {
            const j = try chunk.emitJump(.jump_if_false, line);
            try chunk.emitOp(.pop, line);
            try self.parsePrecedence(p.next());
            try chunk.patchJump(j);
            return;
        }
        if (tt == .pipe_pipe) {
            const j_else = try chunk.emitJump(.jump_if_false, line);
            const j_end = try chunk.emitJump(.jump, line);
            try chunk.patchJump(j_else);
            try chunk.emitOp(.pop, line);
            try self.parsePrecedence(p.next());
            try chunk.patchJump(j_end);
            return;
        }

        // ** is right-associative: recurse at same level so 2**3**2 = 2**(3**2)
        if (tt == .star_star) {
            try self.parsePrecedence(p);
            chunk.setCol(col);
            try chunk.emitOp(.pow, line);
            return;
        }
        try self.parsePrecedence(p.next());
        chunk.setCol(col);
        switch (tt) {
            .plus  => try chunk.emitBinOpFused(.add, line),
            .minus => try chunk.emitBinOpFused(.sub, line),
            .star  => try chunk.emitOp(.mul, line),
            .slash => try chunk.emitOp(.div, line),
            .percent => try chunk.emitOp(.mod, line),
            .amp   => try chunk.emitOp(.bit_and, line),
            .pipe  => try chunk.emitOp(.bit_or, line),
            .caret => try chunk.emitOp(.bit_xor, line),
            .lt_lt => try chunk.emitOp(.shl, line),
            .gt_gt => try chunk.emitOp(.shr, line),
            .eq_eq => try chunk.emitBinOpFused(.eq, line),
            .bang_eq => {
                try chunk.emitBinOpFused(.eq, line);
                try chunk.emitOp(.not, line);
            },
            .gt => try chunk.emitOp(.gt, line),
            .gt_eq => {
                try chunk.emitBinOpFused(.lt, line);
                try chunk.emitOp(.not, line);
            },
            .lt => try chunk.emitBinOpFused(.lt, line),
            .lt_eq => {
                try chunk.emitOp(.gt, line);
                try chunk.emitOp(.not, line);
            },
            else => unreachable,
        }
    }

    // ── Token helpers ────────────────────────────────────────────────────────────

    fn advance(self: *Compiler) void {
        self.prev = self.cur;
        if (self.peek_tok) |t| {
            self.cur = t;
            self.peek_tok = null;
        } else {
            self.cur = self.lex.next();
        }
        chunk.setCol(self.prev.col);
    }

    fn peekToken(self: *Compiler) Token {
        if (self.peek_tok == null) self.peek_tok = self.lex.next();
        return self.peek_tok.?;
    }
    fn check(self: *Compiler, tt: TT) bool {
        return self.cur.typ == tt;
    }
    fn match(self: *Compiler, tt: TT) bool {
        if (!self.check(tt)) return false;
        self.advance();
        return true;
    }
    fn matchOpt(self: *Compiler, tt: TT) void {
        _ = self.match(tt);
    }
    fn consume(self: *Compiler, tt: TT) !void {
        if (self.cur.typ == tt) {
            self.advance();
            return;
        }
        self.setErr("expected {s}, found {s}", .{ self.tokenName(tt), self.tokenName(self.cur.typ) });
        self.err_col = @intCast(self.cur.col);
        return error.UnexpectedToken;
    }
    fn peekTT(self: *Compiler) TT {
        var lx = self.lex;
        return lx.next().typ;
    }

    // ── Module and name helpers ──────────────────────────────────────────────────

    fn qualifyGlobalName(self: *Compiler, name: []const u8) ![]const u8 {
        if (self.options.module_prefix.len == 0) return name;
        const total = self.options.module_prefix.len + 1 + name.len;
        const buf = heap.bump(u8, total) orelse return error.OutOfMemory;
        @memcpy(buf[0..self.options.module_prefix.len], self.options.module_prefix);
        buf[self.options.module_prefix.len] = '.';
        @memcpy(buf[self.options.module_prefix.len + 1 .. total], name);
        return buf[0..total];
    }

    fn qualifyTypeName(self: *Compiler, name: []const u8) ![]const u8 {
        return self.qualifyGlobalName(name);
    }

    fn addExport(self: *Compiler, name: []const u8, global_name: []const u8) !void {
        const stable_name = try self.copyName(name);
        var i: usize = 0;
        while (i < self.export_count) : (i += 1) {
            if (common.streq(self.exports[i].name, stable_name)) return error.DuplicateExport;
        }
        if (self.export_count >= MaxLocals) { self.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
        self.exports[self.export_count] = .{ .name = stable_name, .global_name = global_name };
        self.export_count += 1;
    }

    // Returns true when the current token is a var name followed by a type and '='.
    // Matches: name type = expr  (space-syntax typed declaration, no keyword needed)
    fn isTypedVarDecl(self: *Compiler) bool {
        var lx = self.lex;
        var t = lx.next(); // token after the var name
        if (t.typ == .question) t = lx.next(); // skip optional nullable prefix
        if (t.typ == .lbracket) {
            // []T = expr — must start with exactly '[]' (empty bracket pair)
            t = lx.next();
            if (t.typ != .rbracket) return false;
            // depth-scan element type to find '='
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

    fn importExpr(self: *Compiler) !void {
        try self.consume(.lparen);
        if (self.cur.typ != .string) { self.setErr("expected string literal, found {s}", .{self.tokenName(self.cur.typ)}); return error.ExpectedStringLiteral; }
        const name = self.cur.src;
        self.advance();
        try self.consume(.rparen);
        const ctx = self.options.module_ctx orelse { self.setErr("unsupported import module '{s}'", .{name}); return error.UnsupportedImportModule; };
        const resolver = self.options.resolve_import orelse { self.setErr("unsupported import module '{s}'", .{name}); return error.UnsupportedImportModule; };
        const mod_name = try resolver(ctx, self.options.module_path, name);
        try chunk.emitGetGlobal(mod_name, self.prev.line);
    }

    fn structInstanceLitAfterValue(self: *Compiler, line: u32) !void {
        try self.consume(.lbrace);
        var count: u8 = 0;
        if (!self.check(.rbrace)) {
            while (true) {
                if (count == 255) { self.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                if (self.check(.ident)) {
                    const key_tok = self.cur;
                    self.advance();
                    try chunk.emitConst(.{ .string = key_tok.src }, key_tok.line);
                } else if (self.check(.string)) {
                    try chunk.emitConst(.{ .string = self.cur.src }, self.cur.line);
                    self.advance();
                } else return self.err("expected identifier or string key, found {s}", .{self.tokenName(self.cur.typ)});
                try self.consume(.colon);
                try self.expr();
                count += 1;
                if (!self.match(.comma)) break;
                if (self.check(.rbrace)) break;
            }
        }
        try self.consume(.rbrace);
        try chunk.emit2(@intFromEnum(Op.build_struct_instance), count, line);
    }

    fn copyName(self: *Compiler, name: []const u8) ![]const u8 {
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

    fn isKnownLocalStructType(self: *Compiler, name: []const u8) bool {
        if (self.registry.hasStructTypeLocal(name)) return true;
        var i = name.len;
        while (i > 0) : (i -= 1) {
            if (name[i - 1] == '.') return self.registry.hasStructTypeLocal(name[i..]);
        }
        return false;
    }
};

fn tokPrec(tt: TT) Prec {
    return switch (tt) {
        .pipe_pipe => .or_,
        .amp_amp => .and_,
        .eq_eq, .bang_eq => .eq_,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .amp => .bit_and,
        .lt_lt, .gt_gt => .shift,
        .lt, .lt_eq, .gt, .gt_eq => .cmp,
        .plus, .minus => .term,
        .star, .slash, .percent => .factor,
        .star_star => .power,
        .lbracket, .lparen, .dot => .call,
        else => .none,
    };
}
