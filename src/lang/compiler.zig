const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const lexer_mod = @import("lexer.zig");
const op_mod = @import("op.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");
const ct = @import("compiler_types.zig");
const compiler_decls = @import("compiler_decls.zig");
const compiler_stmts = @import("compiler_stmts.zig");
const compiler_expr = @import("compiler_expr.zig");
const module_descriptor = @import("module_descriptor.zig");

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
const MaxModuleExports = ct.MaxModuleExports;
const MaxScopes = ct.MaxScopes;
const MaxLoopDepth = ct.MaxLoopDepth;
const MaxLoopBreaks = ct.MaxLoopBreaks;
const MaxTypeAlts = ct.MaxTypeAlts;
const MaxNamedTypes = ct.MaxNamedTypes;
const MaxSwitchJumps = ct.MaxSwitchJumps;
const MaxUpvalues = ct.MaxUpvalues;
const MaxTestBlocks = ct.MaxTestBlocks;
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
const PrimType = ct.PrimType;

const ExprPrimInfo = struct {
    prim: ?PrimType = null,
    named_type: ?[]const u8 = null,
    struct_type: ?[]const u8 = null,
    index_result_spec: ?FieldTypeSpec = null,
    is_constant: bool = false,
    is_plain_binding: bool = false,
    is_zero_int: bool = false,
};

const ZeroIntCompare = struct {
    op: Op,
    needs_not: bool = false,
};

pub const ImportResolverFn = *const fn (ctx: *anyopaque, importer_path: []const u8, import_name: []const u8) anyerror![]const u8;

pub const CompilerOptions = struct {
    module_path: []const u8 = "",
    module_prefix: []const u8 = "",
    module_struct_name: []const u8 = "",
    module_global_name: []const u8 = "",
    module_ctx: ?*anyopaque = null,
    resolve_import: ?ImportResolverFn = null,
    has_module_export: ?*const fn (ctx: *anyopaque, path: []const u8, field: []const u8) bool = null,
    resolve_module_type: ?*const fn (ctx: *anyopaque, path: []const u8, name: []const u8) ?module_descriptor.ModuleTypeInfo = null,
    resolve_module_constant: ?*const fn (ctx: *anyopaque, path: []const u8, name: []const u8) ?ct.CompileTimeConst = null,
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

pub const MaxCompileErrors = 16;
pub const ErrorRecord = struct {
    kind: anyerror,
    line: u32,
    col: u32,
    msg: [512]u8,
    msg_len: u16,
};

pub const Compiler = struct {
    // Per-compilation arena: holds registry slices, scope locals/upvalues, and
    // the large table slices below.  Created in init(), freed in deinit().
    arena: std.heap.ArenaAllocator,
    lex: Lexer,
    prev: Token = undefined,
    cur: Token = undefined,
    scopes: [MaxScopes]FuncInfo = undefined,
    scope_depth: u8 = 0,
    loops: []LoopCtx,
    loop_depth: u8 = 0,
    block_depth: u8 = 1,
    expr_depth: u16 = 0,
    registry: TypeRegistry,
    last_func_obj: ?*@import("value.zig").Object = null,
    peek_tok: ?Token = null,
    options: CompilerOptions = .{},
    exports: []ExportEntry,
    export_count: u16 = 0,
    err_msg_buf: [512]u8 = undefined,
    err_msg_len: u16 = 0,
    err_col: u32 = 0,
    err_line: u32 = 0,

    // Errors collected during recovery passes (index 0 = first / primary error).
    collected_errors: [MaxCompileErrors]ErrorRecord = undefined,
    collected_error_count: u8 = 0,

    std_namespace_path: ?[]const u8 = null,
    std_module_global_names: [MaxLocals][]const u8 = undefined,
    std_module_global_paths: [MaxLocals][]const u8 = undefined,
    std_module_global_count: u8 = 0,
    import_module_path: ?[]const u8 = null,
    import_module_global_qnames: [MaxLocals][]const u8 = undefined,
    import_module_global_paths: [MaxLocals][]const u8 = undefined,
    import_module_global_count: u8 = 0,
    typed_global_names: [MaxLocals][]const u8 = undefined,
    typed_global_type_checks: [MaxLocals]TypeCheck = undefined,
    typed_global_count: u8 = 0,
    // Inferred named-type globals (:= declarations): tracked for TypeMismatch detection only.
    // NOT in typed_global_type_checks so assignStmt does not emit prolog/epilog for them.
    inferred_named_global_names: [MaxLocals][]const u8 = undefined,
    inferred_named_global_types: [MaxLocals][]const u8 = undefined,
    inferred_named_global_count: u8 = 0,
    // Same idea, for :=-inferred struct-typed globals (#210: needed so a
    // dunder method declared on the struct is reachable from a top-level
    // `a := Vec3{...}` read, not only from an explicitly `var a Vec3`-typed
    // one). Structs have no prolog/epilog mechanism at all, so there's no
    // sharp reason this couldn't live in typed_global_type_checks directly —
    // kept as a separate table anyway, matching the named-type precedent.
    inferred_struct_global_names: [MaxLocals][]const u8 = undefined,
    inferred_struct_global_types: [MaxLocals][]const u8 = undefined,
    inferred_struct_global_count: u8 = 0,
    compile_time_const_names: [][]const u8,
    compile_time_const_values: []ct.CompileTimeConst,
    compile_time_const_count: u16 = 0,

    test_names: [][]const u8,
    test_count: u16 = 0,

    repl_expr_ok: bool = true,
    repl_pending_pop: bool = false,
    in_loop_init: bool = false,
    loop_body_depth: u8 = 0,
    skipping_test_body: bool = false,
    cs: *chunk.State = undefined,
    // Explicit heap handle, latched at init like cs. All compiler allocation
    // goes through this — never through heap's threadlocal-active wrappers —
    // so a compiler instance is bound to exactly one runtime's heap (A1).
    hs: *heap.State = undefined,

    // `.type` is only valid directly compared with ==/!=, or as a switch
    // scrutinee. parsing_switch_scrutinee gates the latter; switch_scrutinee_is_type
    // is set by the '.type' handler in infixExpr and read back by switchStmt.
    parsing_switch_scrutinee: bool = false,
    switch_scrutinee_is_type: bool = false,
    // Set while parsing the right operand of `<typename> == <expr>`, so the
    // '.type' handler knows a trailing '.type' here is expected (not an error)
    // even though it isn't immediately followed by == / !=. type_suffix_consumed
    // reports back whether the operand actually ended in '.type'.
    require_type_suffix: bool = false,
    type_suffix_consumed: bool = false,

    // Active generic type parameters in scope (only non-zero while compiling a generic type body).
    type_params: [ct.MaxTypeParams]ct.GenericParam = undefined,
    type_param_count: u8 = 0,

    // Spread-return optimization state:
    // Set in emitGetVar when the variable is a known multi-named-return global function.
    // Read and consumed by infixExpr(.lparen) immediately after the call.
    pending_call_spread_count: u8 = 0,
    pending_call_qname: ?[]const u8 = null,
    expr_prim_info: []ExprPrimInfo,
    expr_prim_capture_depths: []u16,
    expr_prim_capture_count: u16 = 0,
    // Set by multiAssignOrDecl before emitExprListTuple; 0 outside that context.
    multi_assign_lhs_count: u8 = 0,
    // Set by infixExpr(.lparen) when callee_spread_n == multi_assign_lhs_count;
    // read by multiAssignOrDecl after emitExprListTuple.
    last_spread_return_count: u8 = 0,
    // Signatures of `func name()` declarations whose bodies are currently
    // being compiled: registration in the registry happens only after the
    // body, so recursive self-calls resolve their arg types through this
    // stack instead. Pushed by compileFuncWithPrefix when funcDecl hands it
    // a qname via pending_func_qname.
    in_progress_sigs: [MaxScopes]CallSigView = undefined,
    in_progress_sig_qnames: [MaxScopes][]const u8 = undefined,
    in_progress_sig_count: u8 = 0,
    pending_func_qname: ?[]const u8 = null,

    // ── Lifecycle ────────────────────────────────────────────────────────────────

    // Callers name the chunk and heap the compiler works against — production
    // passes its runtime's own state; test runners pass the module defaults
    // explicitly (chunk.g_state / heap.g_state). No hidden active-state reads.
    pub fn init(src: []const u8, cs: *chunk.State, hs: *heap.State, options: CompilerOptions) !Compiler {
        var c: Compiler = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .lex = .{ .src = src },
            .options = options,
            .cs = cs,
            .hs = hs,
            .scope_depth = 1,
            // Non-defaulted slice fields: set below after arena is ready.
            .registry = undefined,
            .loops = undefined,
            .exports = undefined,
            .compile_time_const_names = undefined,
            .compile_time_const_values = undefined,
            .test_names = undefined,
            .expr_prim_info = undefined,
            .expr_prim_capture_depths = undefined,
        };
        errdefer c.arena.deinit();
        const alloc = c.arena.allocator();

        try c.registry.init(alloc);

        // Pre-allocate locals + upvalues for every possible scope depth.
        for (&c.scopes) |*scope| {
            scope.locals = try alloc.alloc(ct.Local, MaxLocals);
            scope.upvalues = try alloc.alloc(ct.Upvalue, MaxUpvalues);
        }
        c.scopes[0].reset();

        c.loops = try alloc.alloc(LoopCtx, MaxLoopDepth);
        c.exports = try alloc.alloc(ExportEntry, MaxModuleExports);
        c.compile_time_const_names = try alloc.alloc([]const u8, ct.MaxGlobals);
        c.compile_time_const_values = try alloc.alloc(ct.CompileTimeConst, ct.MaxGlobals);
        c.test_names = try alloc.alloc([]const u8, MaxTestBlocks);
        c.expr_prim_info = try alloc.alloc(ExprPrimInfo, MaxExprDepth + 2);
        @memset(c.expr_prim_info, .{});
        c.expr_prim_capture_depths = try alloc.alloc(u16, MaxExprDepth + 2);

        return c;
    }

    pub fn deinit(self: *Compiler) void {
        self.arena.deinit();
    }

    pub fn compile(self: *Compiler, emit_halt: bool) !void {
        if (!self.options.repl_mode) self.registry.reset();
        try module_descriptor.seedCompilerRegistry(&self.registry);
        self.export_count = 0;
        self.err_msg_len = 0;
        self.err_col = 0;
        self.err_line = 0;
        self.expr_depth = 0;
        self.compile_time_const_count = 0;
        self.collected_error_count = 0;
        self.repl_expr_ok = true;
        self.repl_pending_pop = false;
        self.advance();
        while (!self.check(.eof)) {
            try self.failOnLexerError();
            self.repl_expr_ok = true;
            const cp = self.declCheckpoint();
            self.decl() catch |e| {
                if (isFatalError(e)) return e;
                self.collectError(e);
                self.rollbackDecl(cp);
                self.syncToNextDecl();
            };
        }
        if (emit_halt) try self.cs.emitOp(.halt, self.prev.line);
        if (self.collected_error_count > 0) {
            // Restore legacy single-error fields from the first collected error
            // so that existing callers (runtime.zig's recordCompilerCompileError)
            // continue to see the primary error without any change.
            const first = &self.collected_errors[0];
            self.err_line = first.line;
            self.err_col = first.col;
            self.err_msg_len = first.msg_len;
            @memcpy(self.err_msg_buf[0..first.msg_len], first.msg[0..first.msg_len]);
            return first.kind;
        }
    }

    // ── Error recovery helpers ────────────────────────────────────────────────────

    /// Errors that cannot be recovered from: OOM means the heap is exhausted,
    /// TooMany* means a fixed-size compile-time table is full.  Recovering from
    /// these would risk corrupting the tables used by all subsequent decls.
    fn isFatalError(e: anyerror) bool {
        return switch (e) {
            error.OutOfMemory,
            error.TooManyLocals,
            error.TooManyGlobals,
            error.TooManyFields,
            error.TooManyElements,
            error.TooManyTypes,
            error.TooManyNamedTypes,
            error.TooManyParams,
            error.TooManyNestedFunctions,
            error.TooManyNestedLoops,
            error.TooManyBreaksInLoop,
            error.TooManySwitchCases,
            error.TooManyInstantiations,
            error.TooManyTypeAlternatives,
            => true,
            else => false,
        };
    }

    const DeclCp = struct {
        // Chunk (bytecode) state
        code_len: usize,
        const_count: usize,
        str_slice_count: usize,
        obj_const_count: usize,
        last_const_code_pos: ?usize,
        last_const_idx: u16,
        prev_const_code_pos: ?usize,
        prev_const_idx: u16,
        last_const_was_new: bool,
        prev_const_was_new: bool,
        std_call_patch_pos: ?usize,
        module_boundary_count: u8,
        // Compiler-level tracking tables (top-level only — scope_depth==1)
        export_count: u16,
        compile_time_const_count: u16,
        typed_global_count: u8,
        inferred_named_global_count: u8,
        inferred_struct_global_count: u8,
        std_module_global_count: u8,
        import_module_global_count: u8,
        test_count: u16,
        scope_local_count: u8,
        block_depth: u8,
        // Type registry
        registry: ct.RegistryCp,
    };

    fn declCheckpoint(self: *const Compiler) DeclCp {
        return .{
            .code_len = self.cs.code_len,
            .const_count = self.cs.const_count,
            .str_slice_count = self.cs.str_slice_count,
            .obj_const_count = self.cs.obj_const_count,
            .last_const_code_pos = self.cs.last_const_code_pos,
            .last_const_idx = self.cs.last_const_idx,
            .prev_const_code_pos = self.cs.prev_const_code_pos,
            .prev_const_idx = self.cs.prev_const_idx,
            .last_const_was_new = self.cs.last_const_was_new,
            .prev_const_was_new = self.cs.prev_const_was_new,
            .std_call_patch_pos = self.cs.std_call_patch_pos,
            .module_boundary_count = self.cs.module_boundary_count,
            .export_count = self.export_count,
            .compile_time_const_count = self.compile_time_const_count,
            .typed_global_count = self.typed_global_count,
            .inferred_named_global_count = self.inferred_named_global_count,
            .inferred_struct_global_count = self.inferred_struct_global_count,
            .std_module_global_count = self.std_module_global_count,
            .import_module_global_count = self.import_module_global_count,
            .test_count = self.test_count,
            .scope_local_count = self.scopes[self.scope_depth - 1].local_count,
            .block_depth = self.block_depth,
            .registry = self.registry.checkpoint(),
        };
    }

    fn rollbackDecl(self: *Compiler, cp: DeclCp) void {
        self.cs.code_len = cp.code_len;
        self.cs.const_count = cp.const_count;
        self.cs.str_slice_count = cp.str_slice_count;
        self.cs.obj_const_count = cp.obj_const_count;
        self.cs.last_const_code_pos = cp.last_const_code_pos;
        self.cs.last_const_idx = cp.last_const_idx;
        self.cs.prev_const_code_pos = cp.prev_const_code_pos;
        self.cs.prev_const_idx = cp.prev_const_idx;
        self.cs.last_const_was_new = cp.last_const_was_new;
        self.cs.prev_const_was_new = cp.prev_const_was_new;
        self.cs.std_call_patch_pos = cp.std_call_patch_pos;
        self.cs.module_boundary_count = cp.module_boundary_count;
        self.export_count = cp.export_count;
        self.compile_time_const_count = cp.compile_time_const_count;
        self.typed_global_count = cp.typed_global_count;
        self.inferred_named_global_count = cp.inferred_named_global_count;
        self.inferred_struct_global_count = cp.inferred_struct_global_count;
        self.std_module_global_count = cp.std_module_global_count;
        self.import_module_global_count = cp.import_module_global_count;
        self.test_count = cp.test_count;
        self.scopes[self.scope_depth - 1].local_count = cp.scope_local_count;
        self.block_depth = cp.block_depth;
        // After rollback the compiler is back at module scope (scope_depth=1,
        // not inside a function), no open loops.
        self.scope_depth = 1;
        self.loop_depth = 0;
        self.expr_depth = 0;
        self.peek_tok = null;
        self.registry.rollback(cp.registry);
    }

    /// Advance past tokens until we reach a token that can start a new
    /// top-level declaration, skipping balanced () [] {} groups so we do not
    /// stop inside a function body on a keyword like `var` or `func`.
    fn syncToNextDecl(self: *Compiler) void {
        var depth: u32 = 0;
        while (self.cur.typ != .eof) {
            switch (self.cur.typ) {
                .lbrace, .lparen, .lbracket => {
                    depth += 1;
                    self.advance();
                },
                .rbrace, .rparen, .rbracket => {
                    if (depth == 0) {
                        self.advance();
                        return;
                    }
                    depth -= 1;
                    self.advance();
                    if (depth == 0) return;
                },
                .kw_func, .kw_type, .kw_subtype, .kw_var, .kw_const, .kw_pub, .kw_test => {
                    if (depth == 0) return;
                    self.advance();
                },
                else => self.advance(),
            }
        }
    }

    /// Save the current error (err_msg_buf / err_line / err_col) into the
    /// collected_errors list.  The primary error fields stay intact so existing
    /// callers that read them directly continue to see the first error.
    fn collectError(self: *Compiler, kind: anyerror) void {
        // Populate the primary error slot from the current error fields (first
        // error wins for backward-compat callers; later ones are appended only).
        const line = if (self.err_line != 0) self.err_line else self.prev.line;
        const col = self.err_col;

        if (self.collected_error_count == 0) {
            // Mirror into the legacy single-error fields for callers that read
            // them directly (runtime.zig's recordCompilerCompileError).
            // err_msg_buf / err_msg_len are already set by setErr(); just make
            // sure err_line reflects the fallback logic.
            if (self.err_line == 0) self.err_line = self.prev.line;
        }

        if (self.collected_error_count >= MaxCompileErrors) return;
        const idx = self.collected_error_count;
        self.collected_error_count += 1;

        var rec = &self.collected_errors[idx];
        rec.kind = kind;
        rec.line = line;
        rec.col = col;
        rec.msg_len = self.err_msg_len;
        @memcpy(rec.msg[0..self.err_msg_len], self.err_msg_buf[0..self.err_msg_len]);

        // Reset error fields so the next decl starts clean.
        self.err_msg_len = 0;
        self.err_line = 0;
        self.err_col = 0;
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
            .err_bad_escape => "bad escape sequence",
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
            .kw_return => "'return'",
            .kw_func => "'func'",
            .kw_struct => "'struct'",
            .kw_interface => "'interface'",
            .kw_type => "'type'",
            .kw_enum => "'enum'",
            .kw_import => "'import'",
            .kw_var => "'var'",
            .kw_const => "'const'",
            .kw_break => "'break'",
            .kw_continue => "'continue'",
            .kw_defer => "'defer'",
            .kw_div => "'div'",
            .kw_rem => "'rem'",
            .kw_mod => "'mod'",
            .kw_assert => "'assert'",
            .kw_trap => "'trap'",
            .kw_variant => "'variant'",
            .kw_subtype => "'subtype'",
            .kw_pub => "'pub'",
            .kw_test => "'test'",
            .kw_and => "'and'",
            .kw_or => "'or'",
            .kw_not => "'not'",
            .kw_as => "'as'",
            .kw_when => "'when'",
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
            .question_question => "'??'",
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

        const any_alts = self.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        any_alts[0] = .{ .typ = .any };
        const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

        const fields = self.hs.bump(StructFieldSpec, self.export_count) orelse return error.OutOfMemory;
        for (fields[0..self.export_count], self.exports[0..self.export_count]) |*f, e| {
            f.* = .{ .name = e.name, .typ = any_spec, .is_const = true };
        }

        const st = self.hs.allocObject() orelse return error.OutOfMemory;
        const struct_name = if (self.options.module_struct_name.len != 0) self.options.module_struct_name else self.options.module_prefix;
        st.* = .{ .struct_type = StructTypeObj{ .name = self.copyName(self.moduleBaseName()) catch struct_name, .qualified_name = struct_name, .fields = fields[0..self.export_count] } };
        try self.cs.emitConst(.{ .object = st }, self.prev.line);

        for (self.exports[0..self.export_count]) |e| {
            try self.cs.emitStringConst(e.name, self.prev.line);
            try self.cs.emitGetGlobal(e.global_name, self.prev.line);
        }
        try self.cs.emit2(@intFromEnum(Op.build_struct_instance), @intCast(self.export_count), self.prev.line);
        try self.cs.emitOpStringConst(.def_global, self.options.module_global_name, self.prev.line);
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
        if (scope.local_count >= MaxLocals) {
            self.setErr("too many local variables (max {d})", .{MaxLocals});
            return error.TooManyLocals;
        }
        if (name.len > 0 and name[0] != '_') {
            for (scope.locals[0..scope.local_count]) |local| {
                if (common.streq(local.name, name)) {
                    self.setErr("duplicate local binding '{s}'", .{name});
                    return error.DuplicateLocal;
                }
            }
        }
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
        self.cs.setCol(name.col);
        self.pending_call_spread_count = 0;
        self.pending_call_qname = null;
        if (self.resolveLocal(name.src)) |slot| {
            const local = self.currentScope().locals[slot];
            if (local.from_std) {
                self.cs.markStdCallPatchPos();
            }
            try self.cs.emit2(@intFromEnum(Op.get_local), slot, name.line);
            self.pending_call_qname = null;
            if (local.std_namespace_path) |path| {
                self.setStdNamespacePath(path);
            } else if (local.import_module_path) |path| {
                self.setImportModulePath(path);
            } else {
                self.clearNamespaceProvenance();
            }
        } else if (self.resolveUpvalue(name.src)) |uv| {
            try self.cs.emit2(@intFromEnum(Op.get_upvalue), uv, name.line);
            self.pending_call_qname = null;
            self.clearNamespaceProvenance();
        } else {
            const qname = try self.qualifyGlobalName(name.src);
            if (!self.inFunc() and self.block_depth == 1 and !self.skipping_test_body) {
                if (self.options.check_global_exists) |checker| {
                    if (!checker(self.options.check_global_ctx.?, qname)) {
                        self.setErr("undefined variable '{s}'", .{name.src});
                        self.err_line = name.line;
                        self.err_col = @intCast(name.col);
                        return error.UndefinedVariable;
                    }
                }
            }
            if (self.getStdModuleGlobalPath(qname)) |_| {
                self.cs.markStdCallPatchPos();
            }
            try self.cs.emitGetGlobal(qname, name.line);
            self.pending_call_spread_count = self.registry.getGlobalFuncReturnCount(qname);
            self.pending_call_qname = qname;
            if (self.getStdModuleGlobalPath(qname)) |path| {
                self.setStdNamespacePath(path);
            } else if (self.getImportModuleGlobalPath(qname)) |path| {
                self.setImportModulePath(path);
            } else {
                self.clearNamespaceProvenance();
            }
        }
    }

    fn namedTypeAssignableTo(self: *Compiler, arg_named: []const u8, param_named: []const u8) bool {
        if (common.streq(arg_named, param_named)) return true;
        var cur: []const u8 = arg_named;
        while (self.registry.getNamedTypeInfo(cur)) |info| {
            const parent = info.parent_name orelse return false;
            if (common.streq(parent, param_named)) return true;
            cur = parent;
        }
        return false;
    }

    pub fn checkDirectCallArgCompatibility(self: *Compiler, sig: CallSigView, arg_index: usize, arg_info: ExprPrimInfo, line: u32) !void {
        if (arg_index >= sig.param_types.len) return;
        const spec = sig.param_types[arg_index];
        if (spec.alts.len != 1) return;
        const alt = spec.alts[0];
        switch (alt.typ) {
            .int, .float, .decimal_t, .boolean, .string, .rune_t => {
                const expected_name: []const u8 = switch (alt.typ) {
                    .int => "int",
                    .float => "float",
                    .decimal_t => "decimal",
                    .boolean => "bool",
                    .string => "string",
                    .rune_t => "rune",
                    else => unreachable,
                };
                if (arg_info.named_type) |nt| {
                    self.setErr("cannot pass {s} to parameter of type {s}; convert explicitly", .{ nt, expected_name });
                    self.err_line = line;
                    return error.TypeError;
                }
                if (arg_info.prim) |arg_p| {
                    const expected_prim: PrimType = switch (alt.typ) {
                        .int => .int,
                        .float => .float,
                        .decimal_t => .decimal,
                        .boolean => .bool,
                        .string => .string,
                        .rune_t => .rune,
                        else => unreachable,
                    };
                    if (arg_p != expected_prim) {
                        self.setErr("cannot pass {s} to parameter of type {s}; convert explicitly", .{ @tagName(arg_p), expected_name });
                        self.err_line = line;
                        return error.TypeError;
                    }
                }
            },
            .named_t => {
                if (arg_info.named_type) |nt| {
                    if (!self.namedTypeAssignableTo(nt, alt.named_name)) {
                        self.setErr("cannot pass {s} to parameter of type {s}", .{ nt, alt.named_name });
                        self.err_line = line;
                        return error.TypeError;
                    }
                }
            },
            else => {},
        }
    }

    // Callee signature as seen from a direct call site — from the registry
    // (declared functions) or the in-progress stack (recursive self-calls).
    pub const CallSigView = struct {
        arity: u8,
        is_variadic: bool,
        default_count: u8,
        param_types: []const FieldTypeSpec,
    };

    pub fn callSigForQname(self: *Compiler, qname_opt: ?[]const u8) ?CallSigView {
        const qname = qname_opt orelse return null;
        if (self.registry.getGlobalFuncObj(qname)) |fo| {
            if (fo.* != .function) return null;
            const f = fo.function;
            return .{ .arity = f.arity, .is_variadic = f.is_variadic, .default_count = f.default_count, .param_types = f.param_types };
        }
        var i = self.in_progress_sig_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(self.in_progress_sig_qnames[i], qname)) return self.in_progress_sigs[i];
        }
        return null;
    }

    // True when the compiler can prove the runtime arg-type check
    // (vm_types.matchesTypeAlt) will pass for this argument. Proven call
    // sites set the 0x80 flag on the call's argc byte and the warm call path
    // skips per-call enforcement entirely (~25% of fib's runtime).
    // Conservative by construction: unknown prim, named carriers, multi-alt
    // or non-primitive param specs, and decimal (boxed carrier) all refuse.
    pub fn argProvenForParam(self: *Compiler, sig: CallSigView, arg_index: usize, arg_info: ExprPrimInfo) bool {
        _ = self;
        if (arg_index >= sig.param_types.len) return false;
        const spec = sig.param_types[arg_index];
        if (spec.alts.len != 1) return false;
        const alt = spec.alts[0];
        if (alt.typ == .any) return true;
        if (arg_info.named_type != null) return false;
        const p = arg_info.prim orelse return false;
        return switch (alt.typ) {
            .int => p == .int or p == .rune, // VM accepts rune in int context
            .float => p == .float or p == .rune,
            .boolean => p == .bool,
            .string => p == .string,
            .rune_t => p == .rune,
            else => false,
        };
    }

    fn getStdModuleGlobalPath(self: *Compiler, name: []const u8) ?[]const u8 {
        const count = self.std_module_global_count;
        for (self.std_module_global_names[0..count], self.std_module_global_paths[0..count]) |n, path| {
            if (common.streq(n, name)) return path;
        }
        return null;
    }

    fn getImportModuleGlobalPath(self: *Compiler, name: []const u8) ?[]const u8 {
        const count = self.import_module_global_count;
        for (self.import_module_global_qnames[0..count], self.import_module_global_paths[0..count]) |qn, path| {
            if (common.streq(qn, name)) return path;
        }
        return null;
    }

    pub fn emitSetVar(self: *Compiler, name: Token) !void {
        if (self.resolveLocal(name.src)) |slot| {
            try self.cs.emit2(@intFromEnum(Op.set_local), slot, name.line);
        } else if (self.resolveUpvalue(name.src)) |uv| {
            try self.cs.emit2(@intFromEnum(Op.set_upvalue), uv, name.line);
        } else {
            try self.cs.emitSetGlobal(try self.qualifyGlobalName(name.src), name.line);
        }
    }

    pub fn getLocalTypeCheck(self: *Compiler, name: []const u8) ?TypeCheck {
        if (self.resolveLocal(name)) |slot| {
            return self.currentScope().locals[slot].type_check;
        }
        const qname = self.qualifyGlobalName(name) catch return null;
        const count = self.typed_global_count;
        for (self.typed_global_names[0..count], self.typed_global_type_checks[0..count]) |n, tc| {
            if (common.streq(n, qname)) return tc;
        }
        return null;
    }

    pub fn lookupInferredNamedGlobal(self: *Compiler, name: []const u8) ?[]const u8 {
        const qname = self.qualifyGlobalName(name) catch return null;
        const count = self.inferred_named_global_count;
        for (self.inferred_named_global_names[0..count], self.inferred_named_global_types[0..count]) |n, nt| {
            if (common.streq(n, qname)) return nt;
        }
        return null;
    }

    pub fn lookupInferredStructGlobal(self: *Compiler, name: []const u8) ?[]const u8 {
        const qname = self.qualifyGlobalName(name) catch return null;
        const count = self.inferred_struct_global_count;
        for (self.inferred_struct_global_names[0..count], self.inferred_struct_global_types[0..count]) |n, st| {
            if (common.streq(n, qname)) return st;
        }
        return null;
    }

    fn primitiveTypeFromNumberTok(tok: Token) PrimType {
        const is_based = tok.src.len >= 2 and tok.src[0] == '0' and
            (tok.src[1] == 'x' or tok.src[1] == 'X' or
                tok.src[1] == 'b' or tok.src[1] == 'B' or
                tok.src[1] == 'o' or tok.src[1] == 'O');
        const is_float = !is_based and std.mem.indexOfAny(u8, tok.src, ".eE") != null;
        return if (is_float) .float else .int;
    }

    pub fn namedTypeBaseToPrim(base: NamedTypeBase) ?PrimType {
        return switch (base) {
            .int => .int,
            .float => .float,
            .decimal => .decimal,
            .string => .string,
            .bool => .bool,
            .rune => .rune,
            .array_t, .map_t, .enum_t => null,
        };
    }

    // ── #210: limited operator overloading via reserved dunder methods ────
    //
    // A struct-based (or non-conflicting-base named) type may declare
    // __add__/__sub__/__mul__/__div__/__rem__/__neg__/__eq__/__compare__ as
    // ordinary methods (no new keyword). The compiler desugars the matching
    // operator to a direct call at compile time when the LHS's static type
    // declares one — same mechanism as the existing static method-dispatch
    // used for `.dot` calls (get_global + swap + call), just triggered by an
    // operator token instead of `.name(...)` syntax. No new opcode.
    //
    // Exact-match only, permanently, not just for a first version: Gengo has
    // no method overloading anywhere (two methods of the same name on one
    // receiver is a compile error, see methodDecl's "duplicate method"
    // check), so an asymmetric-operand form (Rust's `impl Add<Rhs>`) would
    // require exactly the overloading the language doesn't have.
    pub const DunderOp = enum { add, sub, mul, div, rem, neg, eq, compare };

    pub fn dunderMethodName(op: DunderOp) []const u8 {
        return switch (op) {
            .add => "__add__",
            .sub => "__sub__",
            .mul => "__mul__",
            .div => "__div__",
            .rem => "__rem__",
            .neg => "__neg__",
            .eq => "__eq__",
            .compare => "__compare__",
        };
    }

    pub fn dunderOpFromName(name: []const u8) ?DunderOp {
        if (common.streq(name, "__add__")) return .add;
        if (common.streq(name, "__sub__")) return .sub;
        if (common.streq(name, "__mul__")) return .mul;
        if (common.streq(name, "__div__")) return .div;
        if (common.streq(name, "__rem__")) return .rem;
        if (common.streq(name, "__neg__")) return .neg;
        if (common.streq(name, "__eq__")) return .eq;
        if (common.streq(name, "__compare__")) return .compare;
        return null;
    }

    pub fn dunderOpForBinaryTok(tt: TT) ?DunderOp {
        return switch (tt) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .kw_rem => .rem,
            .eq_eq, .bang_eq => .eq,
            .lt, .gt, .lt_eq, .gt_eq => .compare,
            else => null,
        };
    }

    // True when `base` already has a real, correctly-working implementation
    // of `op` today — declaring the matching dunder is then a compile error
    // (see issue #210's per-operator conflict table; verified against the
    // actual VM behavior, not assumed from what "should" work). Struct
    // receivers have no NamedTypeBase and never reach this function.
    pub fn baseHasBuiltinOperator(base: NamedTypeBase, op: DunderOp) bool {
        return switch (base) {
            .int, .float, .rune => true, // full arithmetic + comparison already work
            .decimal => switch (op) {
                .rem, .compare => false, // verified broken at runtime today
                else => true, // + - * / == and unary - all work
            },
            .bool => op == .eq, // only == has a dedicated fast path
            .string => op == .add or op == .eq, // concat and content equality work; ordering doesn't
            .array_t, .map_t => false, // nothing works, including == (reference identity, not a real op)
            .enum_t => op == .eq, // ordinal equality is real; ordering doesn't work
        };
    }

    // Look up "{qualifiedTypeName}.{dunderName}" as a global function, into
    // caller-supplied `buf` (avoids returning a slice into a stack-local
    // buffer). Named-type receivers walk the parent chain, matching the
    // existing static-method-dispatch lookup in compiler_expr.zig's `.dot`
    // handling; struct receivers have no parent chain to walk.
    pub fn lookupDunderCallee(self: *Compiler, buf: []u8, type_name: []const u8, is_struct: bool, op: DunderOp) ?[]const u8 {
        const dname = dunderMethodName(op);
        if (is_struct) {
            const candidate = std.fmt.bufPrint(buf, "{s}.{s}", .{ type_name, dname }) catch return null;
            return if (self.registry.hasGlobalFunc(candidate)) candidate else null;
        }
        var lookup: ?[]const u8 = type_name;
        while (lookup) |cur| {
            const candidate = std.fmt.bufPrint(buf, "{s}.{s}", .{ cur, dname }) catch return null;
            if (self.registry.hasGlobalFunc(candidate)) return candidate;
            const info = self.registry.getNamedTypeInfo(cur) orelse break;
            lookup = info.parent_name;
        }
        return null;
    }

    // Pre-compilation: does declaring `method_name` on `recv_type` conflict
    // with a real, working built-in operator? Struct receivers never
    // conflict (structs have no built-in operators today beyond reference
    // equality, which does not count as "real" per the design decision).
    pub fn checkDunderConflict(self: *Compiler, recv_type: []const u8, is_struct: bool, method_name: []const u8) !void {
        if (is_struct) return;
        const op = dunderOpFromName(method_name) orelse return;
        const info = self.registry.getNamedTypeInfo(recv_type) orelse return;
        if (baseHasBuiltinOperator(info.base, op)) {
            self.setErr("'{s}' already has a built-in '{s}'; operator overloading is only for operators its base type doesn't already define", .{ recv_type, dunderMethodName(op) });
            return error.DunderConflict;
        }
    }

    fn fieldTypeSpecIsExactlyType(spec: value_mod.FieldTypeSpec, qname: []const u8, is_struct: bool) bool {
        if (spec.alts.len != 1) return false;
        const alt = spec.alts[0];
        if (is_struct) return alt.typ == .struct_t and common.streq(alt.struct_name, qname);
        return alt.typ == .named_t and common.streq(alt.named_name, qname);
    }

    // Post-compilation: does the just-compiled method's signature match what
    // this dunder requires? Binary ops: arity 1, no defaults/variadic,
    // parameter type exactly the receiver's own type, return type exactly
    // the receiver's own type (__eq__: bool; __compare__: int). __neg__:
    // arity 0, return type exactly the receiver's own type.
    pub fn validateDunderSignature(self: *Compiler, op: DunderOp, recv_qname: []const u8, is_struct: bool, func_obj: *value_mod.Object) !void {
        if (func_obj.* != .function) return;
        const f = func_obj.function;
        // arity counts the receiver as param[0] (methodDecl passes it as a
        // prefix param typed `.any`, see compileFuncWithPrefix) — binary
        // dunders need one more explicit param beyond that, unary none.
        const expected_arity: u8 = if (op == .neg) 1 else 2;
        if (f.arity != expected_arity or f.is_variadic or f.default_count != 0) {
            const expected_explicit: u8 = expected_arity - 1;
            self.setErr("'{s}' must take exactly {d} argument(s) of type '{s}', with no defaults", .{ dunderMethodName(op), expected_explicit, recv_qname });
            return error.DunderSignatureMismatch;
        }
        if (expected_arity == 2 and !fieldTypeSpecIsExactlyType(f.param_types[1], recv_qname, is_struct)) {
            self.setErr("'{s}' parameter must be exactly '{s}'", .{ dunderMethodName(op), recv_qname });
            return error.DunderSignatureMismatch;
        }
        const ok_return = switch (op) {
            .eq => f.return_types.len == 1 and f.return_types[0].alts.len == 1 and f.return_types[0].alts[0].typ == .boolean,
            .compare => f.return_types.len == 1 and f.return_types[0].alts.len == 1 and f.return_types[0].alts[0].typ == .int,
            else => f.return_types.len == 1 and fieldTypeSpecIsExactlyType(f.return_types[0], recv_qname, is_struct),
        };
        if (!ok_return) {
            const expect_str = switch (op) {
                .eq => "bool",
                .compare => "int",
                else => recv_qname,
            };
            self.setErr("'{s}' must return exactly '{s}'", .{ dunderMethodName(op), expect_str });
            return error.DunderSignatureMismatch;
        }
    }

    pub fn namedTypeCheckBasePrim(self: *Compiler, tc: TypeCheck) ?PrimType {
        if (tc != .named) return null;
        const info = self.registry.getNamedTypeInfo(tc.named) orelse return null;
        return namedTypeBaseToPrim(info.base);
    }

    pub fn typeCheckFromFieldTypeSpec(self: *Compiler, spec: value_mod.FieldTypeSpec) TypeCheck {
        _ = self;
        if (spec.alts.len != 1) return .{ .none = {} };
        return switch (spec.alts[0].typ) {
            .int => .{ .prim = .int },
            .float => .{ .prim = .float },
            .decimal_t => .{ .prim = .decimal },
            .boolean => .{ .prim = .bool },
            .string => .{ .prim = .string },
            .rune_t => .{ .prim = .rune },
            .named_t => .{ .named = spec.alts[0].named_name },
            .struct_t => .{ .struct_type = spec.alts[0].struct_name },
            .array => .{ .assert_arr = spec.alts[0].elem_spec },
            .map => .{ .assert_map = spec.alts[0].val_spec },
            .error_t => .{ .assert_err = {} },
            else => .{ .none = {} },
        };
    }

    pub fn exprPrimInfoFromFieldTypeSpec(self: *Compiler, spec: value_mod.FieldTypeSpec) ExprPrimInfo {
        const tc = self.typeCheckFromFieldTypeSpec(spec);
        return switch (tc) {
            .prim => |prim| .{ .prim = prim },
            .named => |name| blk: {
                const info = self.registry.getNamedTypeInfo(name) orelse break :blk .{};
                const prim = namedTypeBaseToPrim(info.base) orelse break :blk .{};
                break :blk .{ .prim = prim, .named_type = name };
            },
            .assert_arr, .assert_map => |element_spec| .{ .index_result_spec = element_spec },
            .struct_type => |name| .{ .struct_type = name },
            else => .{},
        };
    }

    pub fn exprPrimInfoFromNamedType(self: *Compiler, name: []const u8) ExprPrimInfo {
        const info = self.registry.getNamedTypeInfo(name) orelse return .{ .named_type = name };
        const prim = namedTypeBaseToPrim(info.base) orelse return .{ .named_type = name };
        return .{ .prim = prim, .named_type = name };
    }

    fn exprPrimInfoFromTypeCheck(self: *Compiler, tc: TypeCheck) ExprPrimInfo {
        if (tc == .anon_typed) {
            const idx = tc.anon_typed;
            if (idx >= self.cs.const_count or self.cs.consts[idx] != .object) return .{};
            const obj = self.cs.consts[idx].object;
            if (obj.* != .named_type) return .{};
            return switch (obj.named_type.base) {
                .array_t => .{ .index_result_spec = obj.named_type.elem_spec },
                .map_t => .{ .index_result_spec = obj.named_type.val_spec },
                else => .{},
            };
        }
        return .{};
    }

    pub fn clearCurrentExprPrimInfo(self: *Compiler) void {
        self.expr_prim_info[self.expr_depth] = .{};
    }

    pub fn setCurrentExprPrimInfo(self: *Compiler, info: ExprPrimInfo) void {
        self.expr_prim_info[self.expr_depth] = info;
    }

    pub fn currentExprPrimInfo(self: *Compiler) ExprPrimInfo {
        return self.expr_prim_info[self.expr_depth];
    }

    pub fn emitPredicateCheck(self: *Compiler, tc: TypeCheck, line: u32) !void {
        switch (tc) {
            .named => |name| {
                if (!self.namedTypeHasPredicate(name)) return;
                try self.emitNamedTypeValidationOp(.check_named_predicate, name, line);
            },
            else => {},
        }
    }

    pub fn emitNamedValidation(self: *Compiler, tc: TypeCheck, line: u32) !void {
        switch (tc) {
            .named => |name| {
                const info = self.registry.getNamedTypeInfo(name) orelse return;
                if (info.has_range) try self.emitNamedTypeValidationOp(.validate_named_range, name, line);
                try self.emitPredicateCheck(tc, line);
            },
            else => {},
        }
    }

    // Type checks retain qualified names so their runtime type identity stays
    // unambiguous. The compiler's registry, however, contains declarations
    // from the module currently being compiled under their local names.
    fn localNamedTypeName(self: *Compiler, name: []const u8) []const u8 {
        const prefix = self.options.module_prefix;
        if (prefix.len == 0 or name.len <= prefix.len or !std.mem.startsWith(u8, name, prefix) or name[prefix.len] != '.') return name;
        return name[prefix.len + 1 ..];
    }

    fn localNamedTypeInfo(self: *Compiler, name: []const u8) ?NamedTypeInfo {
        return self.registry.getNamedTypeInfo(self.localNamedTypeName(name));
    }

    fn emitNamedTypeValidationOp(self: *Compiler, op: Op, name: []const u8, line: u32) !void {
        const local_name = self.localNamedTypeName(name);
        const info = self.registry.getNamedTypeInfo(local_name) orelse return;
        const idx = self.registry.namedTypeRuntimeConstIdx(local_name) orelse blk: {
            const obj = info.runtime_obj orelse return;
            const new_idx = try self.cs.addConst(.{ .object = obj });
            self.registry.setNamedTypeRuntimeConstIdx(local_name, new_idx);
            break :blk new_idx;
        };
        try self.cs.emitConstIdx(op, idx, line);
    }

    fn namedTypeHasPredicate(self: *Compiler, name: []const u8) bool {
        var current: ?[]const u8 = self.localNamedTypeName(name);
        while (current) |current_name| {
            const info = self.registry.getNamedTypeInfo(current_name) orelse return false;
            if (info.has_predicate) return true;
            current = info.parent_name;
        }
        return false;
    }

    /// Legacy wrapper: emit predicate check for the current expression's named type.
    pub fn emitPredicateCheckCurrent(self: *Compiler, line: u32) !void {
        if (self.currentExprPrimInfo().named_type) |name| {
            try self.emitNamedValidation(.{ .named = name }, line);
        }
    }

    pub fn childExprPrimInfo(self: *Compiler) ExprPrimInfo {
        return self.expr_prim_info[self.expr_depth + 1];
    }

    pub fn propagateChildExprPrimInfo(self: *Compiler) void {
        self.expr_prim_info[self.expr_depth] = self.childExprPrimInfo();
    }

    pub fn noteCurrentExprPrimFromToken(self: *Compiler, tok: Token) void {
        switch (tok.typ) {
            .number => self.expr_prim_info[self.expr_depth] = .{
                .prim = primitiveTypeFromNumberTok(tok),
                .is_constant = true,
                .is_plain_binding = false,
                .is_zero_int = primitiveTypeFromNumberTok(tok) == .int and common.parseInt(tok.src) == 0,
            },
            .ident => {
                if (self.getLocalTypeCheck(tok.src)) |tc| {
                    self.expr_prim_info[self.expr_depth] = switch (tc) {
                        .prim => |p| .{ .prim = p, .is_constant = false, .is_plain_binding = true, .is_zero_int = false },
                        .named => |n| blk: {
                            const info = self.registry.getNamedTypeInfo(n) orelse break :blk ExprPrimInfo{};
                            const p = namedTypeBaseToPrim(info.base) orelse break :blk ExprPrimInfo{};
                            break :blk .{ .prim = p, .named_type = n, .is_constant = false, .is_plain_binding = true, .is_zero_int = false };
                        },
                        .assert_arr, .assert_map => |element_spec| .{ .index_result_spec = element_spec },
                        .struct_type => |n| .{ .struct_type = n },
                        .anon_typed => self.exprPrimInfoFromTypeCheck(tc),
                        else => .{},
                    };
                } else if (self.lookupInferredNamedGlobal(tok.src)) |n| {
                    // Inferred named-type global: tracked only for TypeMismatch detection.
                    // Not in typed_global_type_checks so assignStmt does not wrap results.
                    const info = self.registry.getNamedTypeInfo(n) orelse {
                        self.clearCurrentExprPrimInfo();
                        return;
                    };
                    const p = namedTypeBaseToPrim(info.base) orelse {
                        self.clearCurrentExprPrimInfo();
                        return;
                    };
                    self.expr_prim_info[self.expr_depth] = .{ .prim = p, .named_type = n, .is_constant = false, .is_plain_binding = true, .is_zero_int = false };
                } else if (self.lookupInferredStructGlobal(tok.src)) |st| {
                    self.expr_prim_info[self.expr_depth] = .{ .struct_type = st, .is_constant = false, .is_plain_binding = true, .is_zero_int = false };
                } else {
                    self.clearCurrentExprPrimInfo();
                }
            },
            else => self.clearCurrentExprPrimInfo(),
        }
    }

    pub fn beginExprPrimCapture(self: *Compiler) void {
        if (self.expr_prim_capture_count >= self.expr_prim_capture_depths.len) return;
        self.expr_prim_capture_depths[self.expr_prim_capture_count] = self.expr_depth;
        self.expr_prim_capture_count += 1;
    }

    pub fn endExprPrimCapture(self: *Compiler) ExprPrimInfo {
        if (self.expr_prim_capture_count == 0) return .{};
        self.expr_prim_capture_count -= 1;
        const capture_depth = self.expr_prim_capture_depths[self.expr_prim_capture_count];
        return self.expr_prim_info[capture_depth + 1];
    }

    pub fn exprPrimInfoForBinding(self: *Compiler, name: []const u8) ExprPrimInfo {
        const lhs_tc = self.getLocalTypeCheck(name) orelse return .{};
        const lhs_prim = switch (lhs_tc) {
            .prim => |p| switch (p) {
                .int, .float => p,
                else => return .{},
            },
            .named => |n| {
                const info = self.registry.getNamedTypeInfo(n) orelse return .{};
                return switch (namedTypeBaseToPrim(info.base) orelse return .{}) {
                    .int, .float => |p| .{ .prim = p, .named_type = n, .is_constant = false },
                    else => .{},
                };
            },
            else => return .{},
        };
        return .{ .prim = lhs_prim, .is_constant = false };
    }

    // Only float comparisons get a typed opcode: generic .eq/.ne/.lt/.gt/.le/.ge
    // only inline an int fast path, so float still falls through to a real
    // function call. int comparisons and add/sub/mul/div (both int and float)
    // used to get typed opcodes too; removed 2026-07-21, see CHANGELOG.md.
    pub fn selectTypedComparisonOp(self: *Compiler, op: Op, lhs: ExprPrimInfo, rhs: ExprPrimInfo) Op {
        _ = self;
        const lhs_prim = lhs.prim orelse return op;
        const rhs_prim = rhs.prim orelse return op;
        if (lhs_prim != .float or rhs_prim != .float) return op;
        return switch (op) {
            .eq, .lt, .gt => if (lhs.is_constant or rhs.is_constant) op else switch (op) {
                .eq => .eq_float,
                .lt => .lt_float,
                .gt => .gt_float,
                else => unreachable,
            },
            .ne => if (lhs.is_constant or rhs.is_constant) op else .ne_float,
            .le => .le_float,
            .ge => .ge_float,
            else => op,
        };
    }

    pub fn setCurrentExprPrimResult(self: *Compiler, op: Op, lhs: ExprPrimInfo, rhs: ExprPrimInfo) !void {
        // Named-type compatibility applies regardless of whether prims are tracked
        // (constructor results carry named_type but not prim).
        if (lhs.named_type) |ln| {
            if (rhs.named_type) |rn| {
                if (!common.streq(ln, rn) and !self.registry.areNamedTypesCompatible(ln, rn)) {
                    self.setErr("cannot mix named types '{s}' and '{s}' in '{s}' operation", .{ ln, rn, @tagName(op) });
                    return error.TypeMismatch;
                }
            } else if (rhs.prim) |rp| {
                // Named erased scalar + plain scalar: reject (e.g. Age(20) + 1).
                // Constructor calls set named_type but not prim; use registry for base type.
                const is_erased = if (self.registry.getNamedTypeInfo(ln)) |info|
                    switch (info.base) {
                        .int, .float, .bool, .rune => true,
                        else => false,
                    }
                else
                    false;
                if (is_erased and (rp == .int or rp == .float or rp == .bool or rp == .rune)) {
                    self.setErr("cannot apply '{s}' to {s} and {s}; use {s}(value) or unwrap with the base type", .{ @tagName(op), ln, @tagName(rp), ln });
                    return error.TypeMismatch;
                }
            }
        } else if (rhs.named_type) |rn| {
            // Symmetric: plain scalar op named erased scalar (e.g. 1 + Age(20)).
            const is_erased = if (self.registry.getNamedTypeInfo(rn)) |info|
                switch (info.base) {
                    .int, .float, .bool, .rune => true,
                    else => false,
                }
            else
                false;
            if (is_erased) {
                if (lhs.prim) |lp| {
                    if (lp == .int or lp == .float or lp == .bool or lp == .rune) {
                        self.setErr("cannot apply '{s}' to {s} and {s}; use {s}(value) or unwrap with the base type", .{ @tagName(op), @tagName(lp), rn, rn });
                        return error.TypeMismatch;
                    }
                }
            }
        }
        const lhs_prim = lhs.prim orelse {
            self.clearCurrentExprPrimInfo();
            return;
        };
        const rhs_prim = rhs.prim orelse {
            self.clearCurrentExprPrimInfo();
            return;
        };
        if (lhs_prim != rhs_prim) {
            const int_float = (lhs_prim == .int and rhs_prim == .float) or
                (lhs_prim == .float and rhs_prim == .int);
            if (int_float) {
                const is_bitwise = op == .bit_and or op == .bit_or or op == .bit_xor;
                if (is_bitwise) {
                    const sym: []const u8 = switch (op) {
                        .bit_and => "&",
                        .bit_or => "|",
                        .bit_xor => "^",
                        else => @tagName(op),
                    };
                    self.setErr("'{s}' requires int operands; float is not valid here", .{sym});
                    return error.TypeMismatch;
                }
                // Error only when both sides are typed bindings (e.g. var x int + var y float).
                // Mixing a binding with a literal (e.g. x_float == 0) is allowed; VM widens.
                if (lhs.is_plain_binding and rhs.is_plain_binding) {
                    self.setErr("cannot mix int and float; use float(x) or 2.0 for explicit conversion", .{});
                    return error.TypeMismatch;
                }
                // At least one side is a literal or has no tracked type; VM widens int to float.
                const is_arithmetic = op == .add or op == .sub or op == .mul or op == .div or op == .rem or op == .mod or op == .int_div;
                if (is_arithmetic) {
                    self.expr_prim_info[self.expr_depth] = .{ .prim = .float, .is_constant = lhs.is_constant and rhs.is_constant };
                    return;
                }
            }
            // Catch arithmetic/bitwise on non-numeric prims (e.g. "foo" - 1, true + x).
            const lhs_non_numeric = lhs_prim == .bool or lhs_prim == .string;
            const rhs_non_numeric = rhs_prim == .bool or rhs_prim == .string;
            if (lhs_non_numeric or rhs_non_numeric) {
                const is_arith_or_bitwise = op == .add or op == .sub or op == .mul or op == .div or op == .rem or op == .mod or op == .int_div or op == .bit_and or op == .bit_or or op == .bit_xor;
                if (is_arith_or_bitwise) {
                    const sym: []const u8 = switch (op) {
                        .add => "+",
                        .sub => "-",
                        .mul => "*",
                        .div => "/",
                        .rem => "rem",
                        .mod => "mod",
                        .int_div => "div",
                        .bit_and => "&",
                        .bit_or => "|",
                        .bit_xor => "^",
                        else => @tagName(op),
                    };
                    self.setErr("cannot apply '{s}' to {s} and {s}", .{ sym, @tagName(lhs_prim), @tagName(rhs_prim) });
                    return error.TypeMismatch;
                }
            }
            // bigint promotes only from int; mixing with float is always a VM error.
            const bigint_float = (lhs_prim == .bigint and rhs_prim == .float) or
                (lhs_prim == .float and rhs_prim == .bigint);
            if (bigint_float) {
                const is_arith = op == .add or op == .sub or op == .mul or op == .div or op == .rem or op == .mod or op == .int_div;
                if (is_arith) {
                    self.setErr("cannot mix bigint and float; convert explicitly with bigint(...) or float(...)", .{});
                    return error.TypeMismatch;
                }
            }
            // Mixed bitwise: both operands must be int or rune (the VM's valueAsInt contract).
            const is_bitwise_op = op == .bit_and or op == .bit_or or op == .bit_xor;
            if (is_bitwise_op) {
                const bad_prim: ?PrimType = if (lhs_prim != .int and lhs_prim != .rune)
                    lhs_prim
                else if (rhs_prim != .int and rhs_prim != .rune)
                    rhs_prim
                else
                    null;
                if (bad_prim) |bp| {
                    const sym: []const u8 = switch (op) {
                        .bit_and => "&",
                        .bit_or => "|",
                        .bit_xor => "^",
                        else => @tagName(op),
                    };
                    self.setErr("'{s}' requires int operands; {s} is not valid here", .{ sym, @tagName(bp) });
                    return error.TypeMismatch;
                }
            }
            self.clearCurrentExprPrimInfo();
            return;
        }
        const is_constant = lhs.is_constant and rhs.is_constant;
        // Bitwise ops follow the VM's valueAsInt: only int and rune are valid operands.
        if (lhs_prim != .int and lhs_prim != .rune) {
            const is_bitwise = op == .bit_and or op == .bit_or or op == .bit_xor;
            if (is_bitwise) {
                const sym: []const u8 = switch (op) {
                    .bit_and => "&",
                    .bit_or => "|",
                    .bit_xor => "^",
                    else => @tagName(op),
                };
                self.setErr("'{s}' requires int operands; {s} is not valid here", .{ sym, @tagName(lhs_prim) });
                return error.TypeMismatch;
            }
        }
        // Arithmetic on bool operands.
        if (lhs_prim == .bool) {
            const is_arith = op == .add or op == .sub or op == .mul or op == .div or op == .rem or op == .mod or op == .int_div;
            if (is_arith) {
                const sym: []const u8 = switch (op) {
                    .add => "+",
                    .sub => "-",
                    .mul => "*",
                    .div => "/",
                    .rem => "rem",
                    .mod => "mod",
                    .int_div => "div",
                    else => @tagName(op),
                };
                self.setErr("cannot apply '{s}' to bool operands", .{sym});
                return error.TypeMismatch;
            }
        }
        // Arithmetic on strings (except '+' which concatenates).
        if (lhs_prim == .string) {
            const is_non_concat_arith = op == .sub or op == .mul or op == .div or op == .rem or op == .mod or op == .int_div;
            if (is_non_concat_arith) {
                const sym: []const u8 = switch (op) {
                    .sub => "-",
                    .mul => "*",
                    .div => "/",
                    .rem => "rem",
                    .mod => "mod",
                    .int_div => "div",
                    else => @tagName(op),
                };
                self.setErr("cannot apply '{s}' to string operands; use '+' for concatenation", .{sym});
                return error.TypeMismatch;
            }
        }
        const result_named: ?[]const u8 = if (lhs.named_type) |ln|
            if (rhs.named_type) |rn|
                if (common.streq(ln, rn)) ln else null
            else
                null
        else
            null;
        self.expr_prim_info[self.expr_depth] = switch (op) {
            .add, .sub, .mul => .{ .prim = lhs_prim, .named_type = result_named, .is_constant = is_constant, .is_zero_int = is_constant and lhs_prim == .int and switch (op) {
                .add => lhs.is_zero_int and rhs.is_zero_int,
                .sub => lhs.is_zero_int and rhs.is_zero_int,
                .mul => lhs.is_zero_int or rhs.is_zero_int,
                else => false,
            } },
            .div => .{ .prim = if (lhs_prim == .int) .float else lhs_prim, .named_type = if (lhs_prim == .float) result_named else null, .is_constant = is_constant, .is_zero_int = false },
            .int_div, .rem, .mod, .bit_and, .bit_or, .bit_xor => .{ .prim = lhs_prim, .named_type = result_named, .is_constant = is_constant, .is_zero_int = false },
            .lt, .eq => .{ .prim = .bool, .is_constant = is_constant },
            .halt => .{ .prim = .int, .is_constant = is_constant }, // shifts: result is always int (rune operands coerce)
            else => .{},
        };
    }

    pub fn selectZeroIntCompare(self: *Compiler, tt: TT, lhs: ExprPrimInfo, rhs: ExprPrimInfo) ?ZeroIntCompare {
        _ = self;
        if (!(lhs.prim == .int and rhs.prim == .int)) return null;
        if (!(rhs.is_zero_int and !lhs.is_constant and !lhs.is_plain_binding)) return null;
        return switch (tt) {
            .eq_eq => .{ .op = .eqz_int },
            .bang_eq => .{ .op = .nez_int },
            .lt => .{ .op = .ltz_int },
            .lt_eq => .{ .op = .lez_int },
            .gt => .{ .op = .gtz_int },
            .gt_eq => .{ .op = .gez_int },
            else => null,
        };
    }

    pub fn selectStdMathUnaryIntrinsicOp(self: *Compiler, direct_name: []const u8, argc: u8) ?Op {
        _ = self;
        if (argc != 1) return null;
        if (common.streq(direct_name, "module:std.math.abs")) return .abs;
        if (common.streq(direct_name, "module:std.math.floor")) return .floor;
        if (common.streq(direct_name, "module:std.math.ceil")) return .ceil;
        if (common.streq(direct_name, "module:std.math.trunc")) return .trunc;
        if (common.streq(direct_name, "module:std.math.round")) return .nearest;
        if (common.streq(direct_name, "module:std.math.sign")) return .sign;
        if (common.streq(direct_name, "module:std.math.sqrt")) return .sqrt;
        return null;
    }

    pub fn selectStdMathBinaryIntrinsicOp(self: *Compiler, direct_name: []const u8, argc: u8) ?Op {
        _ = self;
        if (argc != 2) return null;
        if (common.streq(direct_name, "module:std.math.min")) return .min;
        if (common.streq(direct_name, "module:std.math.max")) return .max;
        return null;
    }

    pub fn selectStdMathTernaryIntrinsicOp(self: *Compiler, direct_name: []const u8, argc: u8) ?Op {
        _ = self;
        if (argc != 3) return null;
        if (common.streq(direct_name, "module:std.math.clamp")) return .clamp;
        return null;
    }

    pub fn stdMathUnaryIntrinsicResultInfo(self: *Compiler, direct_name: []const u8, arg_info: ExprPrimInfo) ExprPrimInfo {
        _ = self;
        if (common.streq(direct_name, "module:std.math.abs")) {
            return switch (arg_info.prim orelse return .{}) {
                .int => .{ .prim = .int, .named_type = arg_info.named_type, .is_constant = arg_info.is_constant, .is_zero_int = arg_info.is_zero_int },
                .float => .{ .prim = .float, .is_constant = arg_info.is_constant },
                else => .{},
            };
        }
        if (common.streq(direct_name, "module:std.math.floor") or
            common.streq(direct_name, "module:std.math.ceil") or
            common.streq(direct_name, "module:std.math.trunc") or
            common.streq(direct_name, "module:std.math.round"))
        {
            return .{ .prim = .float, .is_constant = arg_info.is_constant };
        }
        if (common.streq(direct_name, "module:std.math.sign")) {
            return switch (arg_info.prim orelse return .{}) {
                .int => .{ .prim = .int, .is_constant = arg_info.is_constant, .is_zero_int = arg_info.is_zero_int },
                .float => .{ .prim = .float, .is_constant = arg_info.is_constant },
                else => .{},
            };
        }
        if (common.streq(direct_name, "module:std.math.sqrt")) {
            return .{ .prim = .float, .is_constant = arg_info.is_constant };
        }
        return .{};
    }

    pub fn stdMathBinaryIntrinsicResultInfo(self: *Compiler, direct_name: []const u8, lhs_info: ExprPrimInfo, rhs_info: ExprPrimInfo) ExprPrimInfo {
        _ = self;
        if (!(common.streq(direct_name, "module:std.math.min") or common.streq(direct_name, "module:std.math.max"))) return .{};
        const lhs_prim = lhs_info.prim orelse return .{};
        const rhs_prim = rhs_info.prim orelse return .{};
        if (lhs_prim != rhs_prim) return .{};
        const named_type = if (lhs_info.named_type) |lhs_name|
            if (rhs_info.named_type) |rhs_name|
                if (common.streq(lhs_name, rhs_name)) lhs_name else null
            else
                null
        else
            null;
        return switch (lhs_prim) {
            .int => .{ .prim = .int, .named_type = named_type, .is_constant = lhs_info.is_constant and rhs_info.is_constant, .is_zero_int = lhs_info.is_zero_int and rhs_info.is_zero_int },
            .float => .{ .prim = .float, .named_type = named_type, .is_constant = lhs_info.is_constant and rhs_info.is_constant },
            else => .{},
        };
    }

    pub fn stdMathTernaryIntrinsicResultInfo(self: *Compiler, direct_name: []const u8, first_info: ExprPrimInfo, second_info: ExprPrimInfo, third_info: ExprPrimInfo) ExprPrimInfo {
        _ = self;
        if (!common.streq(direct_name, "module:std.math.clamp")) return .{};
        if (first_info.prim != .float or second_info.prim != .float or third_info.prim != .float) return .{};
        const first_name = first_info.named_type orelse return .{ .prim = .float, .is_constant = first_info.is_constant and second_info.is_constant and third_info.is_constant };
        const second_name = second_info.named_type orelse return .{ .prim = .float, .is_constant = first_info.is_constant and second_info.is_constant and third_info.is_constant };
        const third_name = third_info.named_type orelse return .{ .prim = .float, .is_constant = first_info.is_constant and second_info.is_constant and third_info.is_constant };
        return .{ .prim = .float, .named_type = if (common.streq(first_name, second_name) and common.streq(first_name, third_name)) first_name else null, .is_constant = first_info.is_constant and second_info.is_constant and third_info.is_constant };
    }

    // std.conv.to_int/to_float/to_string lower to the existing cast_* ops
    // ONLY when provably safe — they are NOT unconditionally equivalent:
    // cast_int/cast_float have no string-parsing branch (to_int("42")
    // succeeds, int("42") errors with TypeError), and cast_int/cast_float
    // don't accept decimal/bigint inputs the way nativeConvToInt/Float's
    // native-call path silently does not either in the other direction
    // (nativeConvToInt has no decimal/bigint arm and errors; cast_int
    // handles both). Gating on a provably non-string, non-decimal,
    // non-bigint static prim (int/float/rune/bool) avoids all of that: a
    // value with one of those tracked prim types is, by the compiler's own
    // static-typing invariant (already relied on elsewhere for typed-op
    // selection), never null and never one of the divergent cases.
    // to_string -> cast_string has a narrower gap: cast_string explicitly
    // rejects .null (to_string(null) returns "null"; string(null) errors),
    // but is identical to nativeConvToString for every other value it
    // accepts (it calls nativeConvToString directly) — so any known,
    // non-null prim type is sufficient here, not just the numeric four.
    pub fn selectStdConvIntrinsicOp(self: *Compiler, direct_name: []const u8, argc: u8, arg_info: ExprPrimInfo) ?Op {
        _ = self;
        if (argc != 1) return null;
        const prim = arg_info.prim orelse return null;
        if (common.streq(direct_name, "module:std.conv.to_string")) return .cast_string;
        const is_safe_numeric = switch (prim) {
            .int, .float, .rune, .bool => true,
            else => false,
        };
        if (!is_safe_numeric) return null;
        if (common.streq(direct_name, "module:std.conv.to_int")) return .cast_int;
        if (common.streq(direct_name, "module:std.conv.to_float")) return .cast_float;
        return null;
    }

    pub fn stdConvIntrinsicResultInfo(self: *Compiler, direct_name: []const u8) ExprPrimInfo {
        _ = self;
        if (common.streq(direct_name, "module:std.conv.to_int")) return .{ .prim = .int };
        if (common.streq(direct_name, "module:std.conv.to_float")) return .{ .prim = .float };
        if (common.streq(direct_name, "module:std.conv.to_string")) return .{ .prim = .string };
        return .{};
    }

    // std.core.len lowers unconditionally: unlike std.conv above, this isn't
    // reconciling two independently-implemented functions that happened to
    // diverge — the .len op's VM handler calls the exact same nativeLen used
    // by the native-call path, so there is no behavior to keep in sync.
    pub fn selectStdCoreLenIntrinsicOp(self: *Compiler, direct_name: []const u8, argc: u8) ?Op {
        _ = self;
        if (argc != 1) return null;
        if (common.streq(direct_name, "module:std.core.len")) return .len;
        return null;
    }

    // Same rationale as len: the .bytelen op's VM handler calls the exact
    // same nativeByteLen used by the native-call path.
    pub fn selectStdCoreByteLenIntrinsicOp(self: *Compiler, direct_name: []const u8, argc: u8) ?Op {
        _ = self;
        if (argc != 1) return null;
        if (common.streq(direct_name, "module:std.core.bytelen")) return .bytelen;
        return null;
    }

    // std.bytes decode-family intrinsics: one op (.bytes_decode), an operand
    // byte selecting the width/endianness/kind (must match
    // native/bytes.zig's DecodeKind exactly). Unconditional, same rationale
    // as len/append/bytelen — the op calls the exact same bytes.zig
    // decodeAt the native-call path uses. Returns the emitted kind byte and
    // whether the result is int or float, for the caller to set result info.
    pub fn selectStdBytesDecodeIntrinsicOp(self: *Compiler, direct_name: []const u8, argc: u8) ?struct { kind: u8, is_float: bool } {
        _ = self;
        if (argc != 2) return null;
        const Entry = struct { name: []const u8, kind: u8, is_float: bool };
        const table = [_]Entry{
            .{ .name = "module:std.bytes.at", .kind = 0, .is_float = false },
            .{ .name = "module:std.bytes.u16be_at", .kind = 1, .is_float = false },
            .{ .name = "module:std.bytes.u16le_at", .kind = 2, .is_float = false },
            .{ .name = "module:std.bytes.u32be_at", .kind = 3, .is_float = false },
            .{ .name = "module:std.bytes.u32le_at", .kind = 4, .is_float = false },
            .{ .name = "module:std.bytes.u64be_at", .kind = 5, .is_float = false },
            .{ .name = "module:std.bytes.u64le_at", .kind = 6, .is_float = false },
            .{ .name = "module:std.bytes.f32be_at", .kind = 7, .is_float = true },
            .{ .name = "module:std.bytes.f32le_at", .kind = 8, .is_float = true },
            .{ .name = "module:std.bytes.f64be_at", .kind = 9, .is_float = true },
            .{ .name = "module:std.bytes.f64le_at", .kind = 10, .is_float = true },
        };
        for (table) |e| {
            if (common.streq(direct_name, e.name)) return .{ .kind = e.kind, .is_float = e.is_float };
        }
        return null;
    }

    // std.core.append lowers unconditionally for the same reason len does:
    // the .append op's VM handler calls the exact same nativeAppend used by
    // the native-call path (named-array-type unwrap/rewrap, element
    // type-checking against elem_spec included), so there is no separate
    // behavior to keep in sync. nativeAppend requires argc >= 1 (the array
    // itself); mirrored here rather than lowering a call that would only
    // fail at runtime with the same error the ordinary call path would give.
    pub fn selectStdCoreAppendIntrinsicOp(self: *Compiler, direct_name: []const u8, argc: u8) ?Op {
        _ = self;
        if (argc < 1) return null;
        if (common.streq(direct_name, "module:std.core.append")) return .append;
        return null;
    }

    pub fn emitVarTypeProlog(self: *Compiler, tc: TypeCheck, line: u32) !void {
        if (tc == .named) {
            if (self.isErasedNamedType(tc.named)) return;
            try self.cs.emitGetGlobal(tc.named, line);
        } else if (tc == .anon_typed) {
            try self.cs.emitConstIdx(.constant, tc.anon_typed, line);
        }
    }

    pub fn emitVarTypeEpilog(self: *Compiler, tc: TypeCheck, line: u32) !void {
        switch (tc) {
            .none => {},
            .prim => |p| try self.cs.emitOp(switch (p) {
                .int => .cast_int,
                .float => .cast_float,
                .decimal => .cast_decimal,
                .bool => .cast_bool,
                .string => .cast_string,
                .rune => .cast_rune,
                .bigint => .cast_bigint,
            }, line),
            .named => |name| {
                if (self.isErasedNamedType(name)) {
                    try self.emitNamedValidation(tc, line);
                } else {
                    try self.cs.emitCall(1, line);
                }
            },
            .assert_arr => try self.cs.emit2(@intFromEnum(Op.assert_type), 1, line),
            .assert_map => try self.cs.emit2(@intFromEnum(Op.assert_type), 2, line),
            .assert_err => try self.cs.emit2(@intFromEnum(Op.assert_type), 3, line),
            .interface_type => |name| {
                const idx = try self.cs.addStringConst(name);
                try self.cs.emitConstIdx(.assert_interface, idx, line);
            },
            .struct_type => |name| {
                const idx = try self.cs.addStringConst(name);
                try self.cs.emitConstIdx(.assert_struct, idx, line);
            },
            .anon_typed => try self.cs.emitCall(1, line),
        }
    }

    pub fn isEnumTypeName(self: *Compiler, name: []const u8) bool {
        const info = self.localNamedTypeInfo(name) orelse return false;
        return info.base == .enum_t;
    }

    fn isErasedNamedType(self: *Compiler, name: []const u8) bool {
        const info = self.localNamedTypeInfo(name) orelse return false;
        return switch (info.base) {
            .int, .float, .bool, .rune => true,
            // Enum types are erased for prolog/epilog purposes: they are not
            // constructors (TypeName(value) is NotAFunction for a plain enum),
            // and the erased epilog (emitNamedValidation) is a no-op for them
            // (no range, no predicate). Enum-aware consumers such as the
            // zero-init default still see the .named check and branch on
            // base == .enum_t themselves.
            .enum_t => true,
            else => false,
        };
    }

    fn resolveUpvalue(self: *Compiler, name: []const u8) ?u8 {
        if (self.scope_depth <= 1) return null;
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
        return self.resolveUpvalueConstForScope(enclosing_index, name);
    }

    fn resolveUpvalueConst(self: *Compiler, name: []const u8) ?bool {
        if (self.scope_depth <= 1) return null;
        return self.resolveUpvalueConstForScope(self.scope_depth - 1, name);
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
        // `func name()` declarations are immutable (Go semantics): call sites
        // are type-checked — and warm calls skip runtime arg enforcement —
        // against the declared signature, which is only sound if the binding
        // can never change. `name := func(...)` remains the mutable form.
        const qname = try self.qualifyGlobalName(name.src);
        if (self.registry.hasGlobalFunc(qname)) {
            self.setErr("cannot assign to function '{s}'; func declarations are immutable — use '{s} := func(...)' for a reassignable binding", .{ name.src, name.src });
            self.err_line = name.line;
            self.err_col = @intCast(name.col);
            return error.AssignToConst;
        }
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
        for (scope.upvalues[0..scope.upvalue_count], 0..) |uv, u| {
            if (common.streq(uv.name, name) and uv.index == index and uv.from_upvalue == from_upvalue) return @intCast(u);
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
        const scope = self.currentScope();
        while (scope.local_count > base) {
            const idx = scope.local_count - 1;
            if (scope.locals[idx].is_captured) {
                try self.cs.emit2(@intFromEnum(Op.close_upvalue), idx, line);
            }
            try self.cs.emitOp(.pop, line);
            scope.local_count -= 1;
        }
    }

    // ── Loop context ─────────────────────────────────────────────────────────────

    pub fn loopKeepBase(self: *Compiler) u8 {
        return self.currentScope().local_count;
    }

    pub fn pushLoop(self: *Compiler, continue_target: usize, local_keep: u8, body_keep: u8, iter_pops: u8) !void {
        if (self.loop_depth >= MaxLoopDepth) {
            self.setErr("too many nested loops (max {d})", .{MaxLoopDepth});
            return error.TooManyNestedLoops;
        }
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
        if (self.loop_depth == 0) {
            self.setErr("'break' outside of loop", .{});
            return error.BreakOutsideLoop;
        }
        const loop = self.currentLoop();
        // Save so code after the if-break block sees the correct local count (non-break path).
        const saved: u8 = self.currentScope().local_count;
        try self.cleanupLocals(loop.body_keep, line);
        for (0..loop.iter_pops) |_| try self.cs.emitOp(.pop, line);
        for (loop.loop_var_slots[0..loop.loop_var_count]) |slot| {
            try self.cs.emit2(@intFromEnum(Op.close_upvalue), slot, line);
        }
        try self.cleanupLocals(loop.local_keep, line);
        const off = try self.cs.emitJump(.jump, line);
        if (loop.break_count >= MaxLoopBreaks) {
            self.setErr("too many 'break' statements in loop (max {d})", .{MaxLoopBreaks});
            return error.TooManyBreaksInLoop;
        }
        loop.break_offsets[loop.break_count] = off;
        loop.break_count += 1;
        self.currentScope().local_count = saved;
    }

    pub fn emitContinue(self: *Compiler, line: u32) !void {
        if (self.loop_depth == 0) {
            self.setErr("'continue' outside of loop", .{});
            return error.ContinueOutsideLoop;
        }
        const loop = self.currentLoop();
        const saved: u8 = self.currentScope().local_count;
        try self.cleanupLocals(loop.body_keep, line);
        for (loop.loop_var_slots[0..loop.loop_var_count]) |slot| {
            try self.cs.emit2(@intFromEnum(Op.close_upvalue), slot, line);
        }
        try self.cs.emitLoop(loop.continue_target, line);
        self.currentScope().local_count = saved;
    }

    // ── Top-level dispatch ───────────────────────────────────────────────────────

    pub fn decl(self: *Compiler) anyerror!void {
        self.clearNamespaceProvenance();
        if (self.match(.kw_pub)) {
            if (self.inFunc()) {
                self.setErr("invalid 'pub' target", .{});
                return error.InvalidPubTarget;
            }
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
            // Normal mode: parse the body but discard emitted code AND semantic state.
            // Heap-allocate the discard state: chunk.State is ~416 KB with current limits,
            // which is too large for the WASM stack.
            const tmp_state = std.heap.page_allocator.create(chunk.State) catch return error.OutOfMemory;
            defer std.heap.page_allocator.destroy(tmp_state);
            tmp_state.* = .{};
            const saved_cs = self.cs;
            self.cs = tmp_state;
            const saved_skipping = self.skipping_test_body;
            self.skipping_test_body = true;
            defer {
                self.cs = saved_cs;
                self.skipping_test_body = saved_skipping;
            }

            try self.consume(.lbrace);
            while (!self.check(.rbrace) and !self.check(.eof)) try self.decl();
            try self.consume(.rbrace);
            return;
        }

        // Test mode: emit the test block as a zero-arity function.
        if (self.test_count >= MaxTestBlocks) return self.err("too many test blocks (max {d})", .{MaxTestBlocks});
        const idx = self.test_count;
        self.test_count += 1;
        self.test_names[idx] = label;

        const name_buf = self.hs.bump(u8, 32) orelse return error.OutOfMemory;
        const name_str = std.fmt.bufPrint(name_buf[0..32], "__test_{d}", .{idx}) catch return error.OutOfMemory;

        const jump_over = try self.cs.emitJump(.jump, line);
        const func_ip = self.cs.codeLen();

        if (self.scope_depth >= MaxScopes) return error.TooManyNestedFunctions;
        self.scopes[self.scope_depth].reset();
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
        try self.cs.emitOp(.null_val, self.prev.line);
        try self.cs.emitOp(.ret, self.prev.line);

        self.scope_depth -= 1;
        try self.cs.patchJump(jump_over);

        const func_obj = self.hs.allocObject() orelse return error.OutOfMemory;
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
        const cidx: u16 = try self.cs.addConst(.{ .object = func_obj });
        try self.cs.emitConstIdx(.make_closure, cidx, self.prev.line);
        try self.cs.emitOpStringConst(.def_global, name_str, line);
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
        return {
            self.setErr("invalid 'pub' target", .{});
            return error.InvalidPubTarget;
        };
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
        self.cs.setCol(self.prev.col);
    }

    // ── Contextual keywords ──────────────────────────────────────────────
    // The type-declaration clause words (range, cycle, default, predicate,
    // message) and switch 'default' have meaning only in their clause
    // positions and are ordinary identifiers everywhere else. Only the
    // declaration heads 'type' and 'subtype' stay globally reserved —
    // contextualizing those would collide with `name Type = value` syntax.
    pub fn checkWord(self: *Compiler, word: []const u8) bool {
        return self.cur.typ == .ident and common.streq(self.cur.src, word);
    }

    pub fn matchWord(self: *Compiler, word: []const u8) bool {
        if (!self.checkWord(word)) return false;
        self.advance();
        return true;
    }

    // Gengo is newline-insensitive, so a statement beginning with a clause
    // word can directly follow a type declaration. The word is a clause only
    // when what follows can begin its clause form; an assignment or access
    // operator after the word means it is an identifier statement instead.
    // Misclassified corner cases fail loudly at parse — nothing is silently
    // reinterpreted (e.g. `range x = 5` or a bare call `range(...)` directly
    // after a type declaration is rejected as a malformed clause; rename or
    // reorder to resolve). `(` stays clause-compatible: bounds like
    // `range (lower + stride)..upper` are legitimate clause syntax.
    pub fn checkClauseWord(self: *Compiler, word: []const u8) bool {
        if (!self.checkWord(word)) return false;
        return switch (self.peekToken().typ) {
            .colon_eq, .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .dot, .lbracket, .comma, .colon, .rparen, .rbrace, .semicolon => false,
            else => true,
        };
    }

    pub fn matchClauseWord(self: *Compiler, word: []const u8) bool {
        if (!self.checkClauseWord(word)) return false;
        self.advance();
        return true;
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

    /// Returns true if the current `[` token begins a generic type-parameter list
    /// (i.e. the `[ident, ...] struct|variant|interface` pattern), without consuming.
    /// Used to disambiguate `type Stack[T] struct` from `type Tags [K]V`.
    pub fn looksLikeGenericTypeParams(self: *Compiler) bool {
        var lx = self.lex;
        // If peek_tok is set, lx is already past it; start with peek_tok.
        var t: Token = if (self.peek_tok) |pt| pt else lx.next();
        while (true) {
            switch (t.typ) {
                .rbracket => break,
                .eof => return false,
                .ident => {},
                .comma => {},
                // `[T: numeric]`-style constraint, matching the analogous
                // scan for generic functions (compiler_decls.zig's
                // isNamedFuncDecl) — a bare `.colon` here previously
                // fell through to `else => return false`, so a
                // constrained generic type was never even recognized as
                // generic at all (docs/language.md claimed it worked).
                .colon => {},
                else => return false,
            }
            t = lx.next();
        }
        const after = lx.next();
        return after.typ == .kw_struct or after.typ == .kw_variant or after.typ == .kw_interface;
    }

    // ── Module and name helpers ──────────────────────────────────────────────────

    pub fn qualifyGlobalName(self: *Compiler, name: []const u8) ![]const u8 {
        if (self.options.module_prefix.len == 0) return name;
        const total = self.options.module_prefix.len + 1 + name.len;
        const buf = self.hs.bump(u8, total) orelse return error.OutOfMemory;
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
        const prims = [_][]const u8{ "int", "float", "bool", "string", "rune", "decimal", "error", "map", "bigint" };
        for (prims) |p| {
            if (common.streq(name, p)) return true;
        }
        return self.registry.hasNamedType(name) or self.registry.hasStructTypeLocal(name) or
            self.registry.hasInterfaceType(name) or self.registry.hasVariantType(name) or
            self.registry.hasGenericType(name) or self.registry.hasTypeAlias(name);
    }

    pub fn addExport(self: *Compiler, name: []const u8, global_name: []const u8) !void {
        if (self.skipping_test_body) return;
        const stable_name = try self.copyName(name);
        for (self.exports[0..self.export_count]) |e| {
            if (common.streq(e.name, stable_name)) {
                self.setErr("duplicate export name '{s}'", .{stable_name});
                return error.DuplicateExport;
            }
        }
        if (self.export_count >= MaxModuleExports) {
            self.setErr("too many fields (max {d})", .{MaxModuleExports});
            return error.TooManyFields;
        }
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
        // Handle module-qualified types: ident.ident
        if (t.typ == .dot) {
            t = lx.next();
            if (t.typ != .ident) return false;
            t = lx.next();
        }
        // Skip map[K]V or other parameterized types with brackets
        if (t.typ == .lbracket) {
            var depth: i32 = 0;
            while (true) {
                switch (t.typ) {
                    .lparen, .lbracket => depth += 1,
                    .rparen, .rbracket => {
                        depth -= 1;
                        if (depth < 0) return false;
                    },
                    .eq => if (depth == 0) return true,
                    .lbrace, .semicolon, .eof => return false,
                    else => {},
                }
                t = lx.next();
            }
        }
        return t.typ == .eq;
    }

    pub fn checkStdNamespaceField(self: *Compiler, field: []const u8, line: u32) !void {
        const path = self.std_namespace_path orelse return;
        const kind = module_descriptor.lookupStdNamespaceExport(path, field) orelse {
            if (module_descriptor.closestStdNamespaceExport(path, field)) |suggestion| {
                self.setErr("unknown field '{s}' in std{s}{s}; did you mean '{s}'?", .{
                    field,
                    if (path.len > 0) "." else "",
                    if (path.len > 0) path else "",
                    suggestion,
                });
            } else {
                self.setErr("unknown field '{s}' in std{s}{s}", .{
                    field,
                    if (path.len > 0) "." else "",
                    if (path.len > 0) path else "",
                });
            }
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

    fn failOnLexerError(self: *Compiler) !void {
        switch (self.cur.typ) {
            .err_invalid_char => {
                self.setErr("invalid character '{c}'", .{self.cur.src[0]});
                self.err_col = self.cur.col;
                return error.InvalidChar;
            },
            .err_unterminated_string => {
                self.setErr("unterminated string literal", .{});
                self.err_col = self.cur.col;
                return error.UnterminatedString;
            },
            .err_string_pool_exhausted => {
                self.setErr("string pool exhausted (max {d}KB)", .{lexer_mod.StrPoolSize / 1024});
                self.err_col = self.cur.col;
                return error.UnterminatedString;
            },
            .err_bad_escape => {
                self.setErr("bad escape sequence (expected \\xHH with two hex digits)", .{});
                self.err_col = self.cur.col;
                return error.BadEscape;
            },
            else => {},
        }
    }

    fn clearNamespaceProvenance(self: *Compiler) void {
        self.std_namespace_path = null;
        self.import_module_path = null;
    }

    fn setStdNamespacePath(self: *Compiler, path: []const u8) void {
        self.std_namespace_path = path;
        self.import_module_path = null;
    }

    fn setImportModulePath(self: *Compiler, path: []const u8) void {
        self.import_module_path = path;
        self.std_namespace_path = null;
    }

    pub fn resolveImportAliasPath(self: *Compiler, alias: []const u8) ?[]const u8 {
        if (self.resolveLocal(alias)) |slot| {
            const local = self.currentScope().locals[slot];
            if (local.std_namespace_path != null or local.from_std) return "std";
            return local.import_module_path;
        }
        const qname = self.qualifyGlobalName(alias) catch return null;
        if (self.getStdModuleGlobalPath(qname) != null) return "std";
        return self.getImportModuleGlobalPath(qname);
    }

    pub fn resolveModuleTypeName(self: *Compiler, path: []const u8, type_name: []const u8) ?module_descriptor.ModuleTypeInfo {
        const cb = self.options.resolve_module_type orelse return null;
        return cb(self.options.module_ctx.?, path, type_name);
    }

    pub fn getCompileTimeConst(self: *const Compiler, name: []const u8) ?ct.CompileTimeConst {
        for (self.compile_time_const_names[0..self.compile_time_const_count], self.compile_time_const_values[0..self.compile_time_const_count]) |known_name, value| {
            if (common.streq(known_name, name)) return value;
        }
        return null;
    }

    pub fn addCompileTimeConst(self: *Compiler, name: []const u8, value: ct.CompileTimeConst) !void {
        if (self.compile_time_const_count >= ct.MaxGlobals) return error.TooManyGlobals;
        self.compile_time_const_names[self.compile_time_const_count] = try self.copyName(name);
        self.compile_time_const_values[self.compile_time_const_count] = value;
        self.compile_time_const_count += 1;
    }

    pub fn resolveModuleConstant(self: *Compiler, path: []const u8, name: []const u8) ?ct.CompileTimeConst {
        const cb = self.options.resolve_module_constant orelse return null;
        return cb(self.options.module_ctx.?, path, name);
    }

    pub fn copyName(self: *Compiler, name: []const u8) ![]const u8 {
        const out = self.hs.bump(u8, name.len) orelse return error.OutOfMemory;
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
        if (std.mem.startsWith(u8, name, "@mod:")) return true;
        if (self.registry.hasStructTypeLocal(name)) return true;
        var i = name.len;
        while (i > 0) : (i -= 1) {
            if (name[i - 1] == '.') return self.registry.hasStructTypeLocal(name[i..]);
        }
        return false;
    }
    const arrayLit = compiler_expr.arrayLit;
    const assertStmt = compiler_stmts.assertStmt;
    const assignLoopVar = compiler_stmts.assignLoopVar;
    const assignStmt = compiler_stmts.assignStmt;
    const block = compiler_stmts.block;
    const cForStmt = compiler_stmts.cForStmt;
    pub const compileFuncWithPrefix = compiler_stmts.compileFuncWithPrefix;
    const compoundStmt = compiler_stmts.compoundStmt;
    const declareLoopVar = compiler_stmts.declareLoopVar;
    const deferStmt = compiler_stmts.deferStmt;
    const emitAssignTargetPath = compiler_stmts.emitAssignTargetPath;
    const emitExprListTuple = compiler_stmts.emitExprListTuple;
    const emitImplicitReturn = compiler_stmts.emitImplicitReturn;
    pub const emitNamedDefault = compiler_decls.emitNamedDefault;
    pub const emitZeroValue = compiler_decls.emitZeroValue;
    pub const expr = compiler_expr.expr;
    const forInStmt = compiler_stmts.forInStmt;
    const forStmt = compiler_stmts.forStmt;
    pub const funcLit = compiler_stmts.funcLit;
    const hasInitSemicolon = compiler_stmts.hasInitSemicolon;
    const ifStmt = compiler_stmts.ifStmt;
    const importExpr = compiler_expr.importExpr;
    const incrStmt = compiler_stmts.incrStmt;
    const indexAssignStmt = compiler_stmts.indexAssignStmt;
    const infixExpr = compiler_expr.infixExpr;
    const interfaceDeclBody = compiler_decls.interfaceDeclBody;
    const isCStyleFor = compiler_stmts.isCStyleFor;
    const isForIn = compiler_stmts.isForIn;
    const isIndexAssign = compiler_stmts.isIndexAssign;
    const isMethodDecl = compiler_decls.isMethodDecl;
    const isMultiAssignEq = compiler_stmts.isMultiAssignEq;
    const isMultiBind = compiler_stmts.isMultiBind;
    const isNamedFuncDecl = compiler_decls.isNamedFuncDecl;
    const isPropertyAssign = compiler_stmts.isPropertyAssign;
    const looksLikeStructLiteral = compiler_expr.looksLikeStructLiteral;
    const mapLit = compiler_expr.mapLit;
    const methodDecl = compiler_decls.methodDecl;
    const multiBindStmt = compiler_stmts.multiBindStmt;
    const namedFuncDecl = compiler_decls.namedFuncDecl;
    const namedTypeDecl = compiler_decls.namedTypeDecl;
    const numLit = compiler_expr.numLit;
    const parseAssignTargetList = compiler_stmts.parseAssignTargetList;
    const parseConstraintBounds = compiler_decls.parseConstraintBounds;
    pub const parseFieldTypeSpec = compiler_decls.parseFieldTypeSpec;
    const parseNameList = compiler_stmts.parseNameList;
    const parsePrecedence = compiler_expr.parsePrecedence;
    const parseSignedNumber = compiler_decls.parseSignedNumber;
    const propertyAssignStmt = compiler_stmts.propertyAssignStmt;
    const returnStmt = compiler_stmts.returnStmt;
    const runeLitExpr = compiler_expr.runeLitExpr;
    const skipTypeSpec = compiler_stmts.skipTypeSpec;
    const stmt = compiler_stmts.stmt;
    const strLitExpr = compiler_expr.strLitExpr;
    const structDeclBody = compiler_decls.structDeclBody;
    const structInstanceLit = compiler_expr.structInstanceLit;
    const structInstanceLitAfterValue = compiler_expr.structInstanceLitAfterValue;
    const subtypeDecl = compiler_decls.subtypeDecl;
    const switchStmt = compiler_stmts.switchStmt;
    pub const typeNameLiteral = compiler_expr.typeNameLiteral;
    const unaryExpr = compiler_expr.unaryExpr;
    const varDecl = compiler_stmts.varDecl;
    pub const varExpr = compiler_expr.varExpr;
    const variantDeclBody = compiler_decls.variantDeclBody;
    const whileForStmt = compiler_stmts.whileForStmt;
};
