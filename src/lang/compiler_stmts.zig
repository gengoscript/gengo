const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const chunk = @import("chunk.zig");
const Op = @import("op.zig").Op;
const FuncType = @import("op.zig").FuncType;
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");
const ct = @import("compiler_types.zig");
const compiler_decls = @import("compiler_decls.zig");

const Token = token.Token;
const TT = token.TT;
const MaxLocals = ct.MaxLocals;
const Prec = ct.Prec;
const TypeCheck = ct.TypeCheck;
const FuncInfo = ct.FuncInfo;
const AssignTarget = ct.AssignTarget;
const AssignTargetStep = ct.AssignTargetStep;
const MaxSwitchJumps = ct.MaxSwitchJumps;
const MultiAssignValueScratch = ct.MultiAssignValueScratch;
const FieldTypeAlt = value_mod.FieldTypeAlt;
const FieldTypeSpec = value_mod.FieldTypeSpec;
const FieldTypeTag = value_mod.FieldTypeTag;
const StructFieldSpec = value_mod.StructFieldSpec;
const InterfaceMethodSpec = value_mod.InterfaceMethodSpec;
const NamedTypeObj = value_mod.NamedTypeObj;
const NamedTypeBase = value_mod.NamedTypeBase;
const VariantArmSpec = value_mod.VariantArmSpec;
const VariantTypeObj = value_mod.VariantTypeObj;
const Object = value_mod.Object;
const MaxTypeAlts = ct.MaxTypeAlts;
const MaxScopes = ct.MaxScopes;
const StructTypeObj = value_mod.StructTypeObj;
const InterfaceTypeObj = value_mod.InterfaceTypeObj;

fn checkBoolCondition(c: anytype) !void {
    const info = c.childExprPrimInfo();
    if (info.prim) |p| {
        if (p != .bool) {
            c.setErr("condition must be bool; got {s}; use a comparison or explicit cast", .{@tagName(p)});
            return error.TypeMismatch;
        }
    }
}

pub fn assertStmt(c: anytype) !void {
    const line = c.prev.line;
    try c.expr();
    try checkBoolCondition(c);
    if (c.match(.comma)) {
        try c.expr();
        try c.cs.emitOp(.op_assert_msg, line);
    } else {
        try c.cs.emitOp(.op_assert, line);
    }
    c.matchOpt(.semicolon);
}

pub fn assignLoopVar(c: anytype, name: Token) !void {
    try c.emitSetVar(name);
}

pub fn assignStmt(c: anytype) !void {
    const name = c.cur;
    if (common.streq(name.src, "_")) {
        c.advance();
        try c.consume(.eq);
        try c.expr();
        try c.cs.emitOp(.pop, name.line);
        c.matchOpt(.semicolon);
        return;
    }
    try c.ensureMutableBinding(name);
    c.advance();
    try c.consume(.eq);
    const tc = c.getLocalTypeCheck(name.src);
    if (tc) |t| try c.emitVarTypeProlog(t, name.line);
    c.beginExprPrimCapture();
    try c.expr();
    const rhs_info = c.endExprPrimCapture();
    if (tc) |t| {
        // Skip prim cast when the RHS is already proven to be the same primitive
        // type; the compiler's type tracking makes the runtime check redundant.
        const skip = (t == .prim) and (rhs_info.prim == t.prim);
        if (!skip) try c.emitVarTypeEpilog(t, name.line);
    }
    try c.emitSetVar(name);
    c.matchOpt(.semicolon);
}

pub fn block(c: anytype) anyerror!void {
    c.block_depth += 1;
    const saved = c.repl_expr_ok;
    c.repl_expr_ok = false;
    const local_base: u8 = c.currentScope().local_count;
    while (!c.check(.rbrace) and !c.check(.eof)) try c.decl();
    try c.consume(.rbrace);
    try c.cleanupLocals(local_base, c.prev.line);
    c.repl_expr_ok = saved;
    c.block_depth -= 1;
}

pub fn cForStmt(c: anytype) anyerror!void {
    const local_base: u8 = c.currentScope().local_count;

    var loop_var_name: ?[]const u8 = null;
    c.in_loop_init = true;
    if (c.match(.semicolon)) {} else if (c.check(.ident) and c.peekTT() == .colon_eq) {
        loop_var_name = c.cur.src;
        try varDecl(c, false, false);
    } else if (c.check(.ident) and c.isTypedVarDecl()) {
        loop_var_name = c.cur.src;
        try varDecl(c, false, false);
    } else if (c.match(.kw_const)) {
        if (c.cur.typ == .ident) loop_var_name = c.cur.src;
        try varDecl(c, true, true);
    } else if (c.check(.ident) and c.peekTT() == .eq) {
        try assignStmt(
            c,
        );
    } else {
        try c.expr();
        try c.cs.emitOp(.pop, c.prev.line);
        try c.consume(.semicolon);
    }
    c.in_loop_init = false;

    var loop_start = c.cs.codeLen();
    var exit_j: ?usize = null;

    if (!c.match(.semicolon)) {
        try c.expr();
        try checkBoolCondition(c);
        try c.consume(.semicolon);
        exit_j = try c.cs.emitJump(.jif_pop, c.prev.line);
    }

    if (!c.check(.lbrace)) {
        const body_j = try c.cs.emitJump(.jump, c.prev.line);
        const post_start = c.cs.codeLen();
        if (c.check(.ident) and (c.peekTT() == .plus_plus or c.peekTT() == .minus_minus)) {
            try incrStmt(
                c,
            );
        } else if (c.check(.ident) and c.peekTT() == .eq) {
            try assignStmt(
                c,
            );
        } else if (c.check(.ident)) {
            const ptt = c.peekTT();
            if (ptt == .plus_eq or ptt == .minus_eq or ptt == .star_eq or ptt == .slash_eq or ptt == .amp_eq or ptt == .pipe_eq or ptt == .caret_eq or ptt == .lt_lt_eq or ptt == .gt_gt_eq) {
                try compoundStmt(
                    c,
                );
            } else {
                try c.expr();
                try c.cs.emitOp(.pop, c.prev.line);
            }
        } else {
            try c.expr();
            try c.cs.emitOp(.pop, c.prev.line);
        }
        try c.cs.emitLoop(loop_start, c.prev.line);
        loop_start = post_start;
        try c.cs.patchJump(body_j);
    }

    try c.pushLoop(loop_start, local_base, c.loopKeepBase(), 0);
    if (loop_var_name) |name| {
        if (c.resolveLocal(name)) |slot| {
            c.currentLoop().loop_var_slots[c.currentLoop().loop_var_count] = slot;
            c.currentLoop().loop_var_names[c.currentLoop().loop_var_count] = name;
            c.currentLoop().loop_var_count += 1;
        }
    }
    try c.consume(.lbrace);
    c.loop_body_depth += 1;
    try block(
        c,
    );
    c.loop_body_depth -= 1;
    for (c.currentLoop().loop_var_slots[0..c.currentLoop().loop_var_count]) |slot| {
        if (c.currentScope().locals[slot].is_captured)
            try c.cs.emit2(@intFromEnum(Op.close_upvalue), slot, c.prev.line);
    }
    try c.cs.emitLoop(loop_start, c.prev.line);

    if (exit_j) |j| {
        try c.cs.patchJump(j);
    }

    if (!c.inFunc()) {
        const lp = c.currentLoop();
        for (lp.loop_var_slots[0..lp.loop_var_count], lp.loop_var_names[0..lp.loop_var_count]) |slot, lname| {
            try c.cs.emit2(@intFromEnum(Op.get_local), slot, c.prev.line);
            try c.cs.emitOpStringConst(.def_global, try c.qualifyGlobalName(lname), c.prev.line);
            try c.cs.emitOp(.pop, c.prev.line);
        }
        c.currentScope().local_count = local_base;
    }
    try c.cleanupLocals(local_base, c.prev.line);

    const loop = c.popLoop();
    for (loop.break_offsets[0..loop.break_count]) |off| try c.cs.patchJump(off);
}

fn parseLiteralDefault(c: anytype) !value_mod.Value {
    if (c.match(.kw_null)) return .null;
    if (c.match(.kw_true)) return .{ .boolean = true };
    if (c.match(.kw_false)) return .{ .boolean = false };
    const neg = c.match(.minus);
    if (c.cur.typ == .number) {
        c.advance();
        const is_float = std.mem.indexOfAny(u8, c.prev.src, ".eE") != null;
        if (is_float) {
            const n = common.parseFloat(c.prev.src) orelse return error.BadNumber;
            return .{ .float = if (neg) -n else n };
        } else {
            const i = std.fmt.parseInt(i64, c.prev.src, 10) catch return error.BadNumber;
            return .{ .int = if (neg) -i else i };
        }
    }
    if (!neg and c.cur.typ == .string) {
        const ss = try c.cs.internStr(c.cur.src);
        c.advance();
        return .{ .string = ss };
    }
    return c.err("default value must be a literal (number, string, bool, or null)", .{});
}

pub fn compileFuncWithPrefix(c: anytype, prefix: []const []const u8, is_named: bool, predicate_base: ?NamedTypeBase) anyerror!u8 {
    try c.consume(.lparen);
    var param_names: [MaxLocals][]const u8 = undefined;
    var param_types: [MaxLocals]FieldTypeSpec = undefined;
    var param_const: [MaxLocals]bool = [_]bool{false} ** MaxLocals;
    var param_defaults: [MaxLocals]value_mod.Value = undefined;
    var param_has_default: [MaxLocals]bool = [_]bool{false} ** MaxLocals;
    var arity: u8 = 0;
    var is_variadic = false;
    var variadic_type: FieldTypeSpec = undefined;

    const any_alts = c.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
    any_alts[0] = .{ .typ = .any };
    const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };
    variadic_type = any_spec;

    if (prefix.len > MaxLocals) {
        c.setErr("too many parameters (max {d})", .{MaxLocals});
        return error.TooManyParams;
    }
    for (prefix) |p| {
        if (c.isKnownTypeName(p))
            return c.err("'{s}' is a type name and cannot be used as a receiver name", .{p});
        param_names[arity] = p;
        param_types[arity] = any_spec;
        arity += 1;
    }

    if (!c.check(.rparen)) {
        while (true) {
            if (arity >= MaxLocals) {
                c.setErr("too many parameters (max {d})", .{MaxLocals});
                return error.TooManyParams;
            }
            const vari = if (predicate_base != null) false else c.match(.ellipsis);
            const p_is_const = if (predicate_base != null) false else c.match(.kw_const);
            if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
            if (c.isKnownTypeName(c.cur.src))
                return c.err("'{s}' is a type name and cannot be used as a parameter name", .{c.cur.src});
            param_names[arity] = c.cur.src;
            param_const[arity] = p_is_const;
            arity += 1;
            c.advance();
            if (predicate_base) |pb| {
                // Predicate mode: type annotation is optional; infer from base type
                if (c.cur.typ == .question or c.cur.typ == .ident or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
                    const ptype: FieldTypeSpec = try c.parseFieldTypeSpec();
                    param_types[arity - 1] = ptype;
                } else {
                    const alt = c.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
                    alt[0] = switch (pb) {
                        .int => .{ .typ = .int },
                        .float => .{ .typ = .float },
                        .decimal => .{ .typ = .decimal_t },
                        .string => .{ .typ = .string },
                        .bool => .{ .typ = .boolean },
                        .rune => .{ .typ = .rune_t },
                        else => .{ .typ = .any },
                    };
                    param_types[arity - 1] = .{ .alts = alt[0..1] };
                }
                if (!c.match(.comma)) break;
                if (c.check(.rparen)) break;
                continue;
            }
            if (c.cur.typ != .question and c.cur.typ != .ident and c.cur.typ != .kw_func and c.cur.typ != .lbracket) {
                c.setErr("expected type annotation, found {s}", .{c.tokenName(c.cur.typ)});
                return error.ExpectedTypeAnnotation;
            }
            const ptype: FieldTypeSpec = try c.parseFieldTypeSpec();
            param_types[arity - 1] = ptype;
            if (vari) {
                is_variadic = true;
                variadic_type = ptype;
                break;
            }
            if (c.match(.eq)) {
                const prev_had_default = arity >= 2 and param_has_default[arity - 2];
                _ = prev_had_default;
                param_defaults[arity - 1] = try parseLiteralDefault(c);
                param_has_default[arity - 1] = true;
            } else if (arity >= 2 and param_has_default[arity - 2]) {
                return c.err("parameter '{s}' must have a default value because the preceding parameter does", .{param_names[arity - 1]});
            }
            if (!c.match(.comma)) break;
            if (c.check(.rparen)) break;
        }
    }
    try c.consume(.rparen);

    var return_types: [MaxLocals]FieldTypeSpec = undefined;
    var return_names: [MaxLocals][]const u8 = undefined;
    var return_count: u8 = 0;
    var has_typed_returns = false;
    var named_return_count: u8 = 0;

    if (predicate_base != null) {
        const alt = c.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        alt[0] = .{ .typ = .boolean };
        return_types[0] = .{ .alts = alt[0..1] };
        return_count = 1;
        has_typed_returns = true;
    } else if (c.match(.lparen)) {
        // Detect named vs anonymous: named if first entry is 'ident type_start'.
        const is_named_returns = c.cur.typ == .ident and
            (c.peekToken().typ == .ident or c.peekToken().typ == .question or c.peekToken().typ == .kw_func or c.peekToken().typ == .lbracket);
        while (true) {
            if (return_count >= MaxLocals) {
                c.setErr("too many return types (max {d})", .{MaxLocals});
                return error.TooManyParams;
            }
            if (is_named_returns) {
                if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
                if (c.isKnownTypeName(c.cur.src))
                    return c.err("'{s}' is a type name and cannot be used as a return value name", .{c.cur.src});
                return_names[return_count] = c.cur.src;
                c.advance();
            }
            return_types[return_count] = try c.parseFieldTypeSpec();
            return_count += 1;
            has_typed_returns = true;
            if (!c.match(.comma)) break;
            if (c.check(.rparen)) break;
        }
        try c.consume(.rparen);
        if (is_named_returns) named_return_count = return_count;
    } else if (c.cur.typ == .question or c.cur.typ == .ident or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
        return_types[0] = try c.parseFieldTypeSpec();
        return_count = 1;
        has_typed_returns = true;
    }

    const jump_over = try c.cs.emitJump(.jump, c.prev.line);
    const func_ip = c.cs.codeLen();

    if (c.scope_depth >= MaxScopes) return error.TooManyNestedFunctions;
    c.scopes[c.scope_depth].reset();
    c.scope_depth += 1;
    const scope = c.currentScope();
    scope.is_named = is_named;
    scope.has_typed_returns = has_typed_returns;
    if (named_return_count == 0 and return_count == 1 and return_types[0].alts.len == 1) {
        scope.return_prim = switch (return_types[0].alts[0].typ) {
            .int => .int,
            .float => .float,
            .boolean => .bool,
            .string => .string,
            .rune_t => .rune,
            // decimal is a boxed carrier; named/complex types need the
            // runtime's coercion path — not provable here.
            else => null,
        };
    }

    for (0..@as(usize, arity)) |pi| {
        for (scope.locals[0..pi]) |local| {
            if (common.streq(local.name, param_names[pi])) {
                c.setErr("duplicate parameter name '{s}'", .{param_names[pi]});
                return error.DuplicateLocal;
            }
        }
        scope.locals[pi] = .{
            .name = param_names[pi],
            .is_const = param_const[pi],
            .type_check = c.typeCheckFromFieldTypeSpec(param_types[pi]),
        };
    }
    scope.local_count = arity;

    // Named return variables occupy slots [arity .. arity+named_return_count).
    // Scalar types (int, float, bool, string) are zero-initialised so that
    // compound-assignment operators (+=, etc.) work without a prior explicit
    // assignment. Other types (nullable, any, complex) are initialised to null.
    if (named_return_count > 0) {
        if (arity + named_return_count > MaxLocals) return error.TooManyLocals;
        scope.named_return_base = arity;
        scope.named_return_count = named_return_count;
        for (0..@as(usize, named_return_count)) |ri| {
            for (scope.locals[0 .. arity + ri]) |local| {
                if (common.streq(local.name, return_names[ri])) {
                    c.setErr("named return '{s}' conflicts with existing local binding", .{return_names[ri]});
                    return error.DuplicateLocal;
                }
            }
            const rc: TypeCheck = c.typeCheckFromFieldTypeSpec(return_types[ri]);
            scope.locals[@as(usize, arity) + ri] = .{ .name = return_names[ri], .is_const = false, .type_check = rc };
            scope.local_count += 1;
            const rt = return_types[ri];
            if (rt.alts.len == 1) {
                switch (rt.alts[0].typ) {
                    .int => try c.cs.emitConst(.{ .int = 0.0 }, @intCast(func_ip)),
                    .float => try c.cs.emitConst(.{ .float = 0.0 }, @intCast(func_ip)),
                    .rune_t => try c.cs.emitConst(.{ .rune = 0 }, @intCast(func_ip)),
                    .decimal_t => try c.cs.emitConst(.{ .decimal = 0 }, @intCast(func_ip)),
                    .boolean => try c.cs.emitOp(.false_val, @intCast(func_ip)),
                    .string => try c.cs.emitStringConst("", @intCast(func_ip)),
                    else => try c.cs.emitOp(.null_val, @intCast(func_ip)),
                }
            } else {
                try c.cs.emitOp(.null_val, @intCast(func_ip));
            }
        }
    }

    // Expose this declaration's signature to its own body: recursive
    // self-calls resolve arg types (and the args-preverified call flag)
    // through the in-progress stack, since registry registration happens
    // only after the body compiles. pending_func_qname is set by funcDecl
    // for non-generic `func name()` declarations only.
    var pushed_sig = false;
    if (c.pending_func_qname) |q| {
        c.pending_func_qname = null;
        if (c.in_progress_sig_count < c.in_progress_sigs.len) {
            const sig_ptypes = c.hs.bump(FieldTypeSpec, arity) orelse return error.OutOfMemory;
            for (sig_ptypes[0..arity], param_types[0..arity]) |*pt, s| pt.* = s;
            var sig_dc: u8 = 0;
            for (0..@as(usize, arity)) |pi| {
                if (param_has_default[pi]) sig_dc += 1;
            }
            c.in_progress_sig_qnames[c.in_progress_sig_count] = q;
            c.in_progress_sigs[c.in_progress_sig_count] = .{
                .arity = arity,
                .is_variadic = is_variadic,
                .default_count = sig_dc,
                .param_types = sig_ptypes[0..arity],
            };
            c.in_progress_sig_count += 1;
            pushed_sig = true;
        }
    }
    defer if (pushed_sig) {
        c.in_progress_sig_count -= 1;
    };

    try c.consume(.lbrace);
    const saved = c.repl_expr_ok;
    c.repl_expr_ok = false;
    const body_local_base: u8 = arity + named_return_count;
    scope.body_block_depth = c.block_depth;
    while (!c.check(.rbrace) and !c.check(.eof)) {
        scope.body_ends_with_return = false;
        try c.decl();
    }
    try c.consume(.rbrace);
    c.repl_expr_ok = saved;
    try c.cleanupLocals(body_local_base, c.prev.line);

    // Implicit return: bare named returns or null.
    try emitImplicitReturn(scope, c.cs, c.prev.line);
    try c.cs.emitOp(.ret, c.prev.line);

    c.scope_depth -= 1;
    try c.cs.patchJump(jump_over);

    const uv_count = scope.upvalue_count;
    const slots = c.hs.bump(u8, uv_count) orelse return error.OutOfMemory;
    for (scope.upvalues[0..uv_count], slots[0..uv_count]) |uv, *s| {
        s.* = (if (uv.from_upvalue) @as(u8, 0x80) else @as(u8, 0x00)) | uv.index;
    }

    const ptypes = c.hs.bump(FieldTypeSpec, arity) orelse return error.OutOfMemory;
    var has_typed_params = false;
    for (ptypes[0..arity], param_types[0..arity]) |*pt, src| {
        pt.* = src;
        if (!(src.alts.len == 1 and src.alts[0].typ == .any)) has_typed_params = true;
    }

    const rtypes = c.hs.bump(FieldTypeSpec, return_count) orelse return error.OutOfMemory;
    @memcpy(rtypes[0..return_count], return_types[0..return_count]);

    var default_count: u8 = 0;
    for (0..@as(usize, arity)) |pi| {
        if (param_has_default[pi]) default_count += 1;
    }
    const defaults = c.hs.bump(value_mod.Value, default_count) orelse return error.OutOfMemory;
    if (default_count > 0) {
        var di: usize = 0;
        for (0..@as(usize, arity)) |pi| {
            if (param_has_default[pi]) {
                defaults[di] = param_defaults[pi];
                di += 1;
            }
        }
    }

    const func_obj = c.hs.allocObject() orelse return error.OutOfMemory;
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
        .defaults = defaults[0..default_count],
        .default_count = default_count,
        .returns_proven = scope.return_prim != null and scope.all_returns_proven and scope.body_ends_with_return,
    } };
    c.last_func_obj = func_obj;
    if (predicate_base == null) {
        const cidx: u16 = try c.cs.addConst(.{ .object = func_obj });
        try c.cs.emitConstIdx(.make_closure, cidx, c.prev.line);
    }
    return uv_count;
}

pub fn compoundStmt(c: anytype) !void {
    const name = c.cur;
    try c.ensureMutableBinding(name);
    c.advance();
    const op_tok = c.cur;
    c.advance();
    const op: Op = switch (op_tok.typ) {
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .amp_eq => .bit_and,
        .pipe_eq => .bit_or,
        .caret_eq => .bit_xor,
        .lt_lt_eq => .shl,
        .gt_gt_eq => .shr,
        else => return c.err("unsupported compound assignment operator", .{}),
    };
    const tc = c.getLocalTypeCheck(name.src);
    const is_named_tc = if (tc) |t| t == .named else false;
    // Also handle :=-inferred named-type globals (not in typed_global_type_checks).
    const inferred_nt = if (!is_named_tc) c.lookupInferredNamedGlobal(name.src) else null;
    const is_named = is_named_tc or inferred_nt != null;
    const named_type = if (is_named_tc) tc.?.named else inferred_nt;
    const is_erased_named = if (named_type) |nt| blk: {
        const info = c.registry.getNamedTypeInfo(nt) orelse break :blk false;
        break :blk switch (info.base) {
            // .enum_t: see isErasedNamedType — enums take the erased path.
            .int, .float, .bool, .rune, .enum_t => true,
            else => false,
        };
    } else false;
    if (is_named_tc) {
        if (!is_erased_named) try c.emitVarTypeProlog(tc.?, op_tok.line);
    } else if (inferred_nt) |nt| {
        if (!is_erased_named) try c.cs.emitGetGlobal(nt, op_tok.line);
    }
    try c.emitGetVar(name);
    if (is_named and !is_erased_named) try c.cs.emitOp(.named_inner, op_tok.line);
    c.beginExprPrimCapture();
    try c.expr();
    const rhs_info = c.endExprPrimCapture();
    // Named-type + plain scalar is a type error (e.g. named_age += 1).
    if (is_named and rhs_info.named_type == null and rhs_info.prim != null) {
        const lhs_nt = if (is_named_tc) tc.?.named else inferred_nt.?;
        c.setErr("cannot apply '{s}' to {s} and {s}; use {s}(value) or unwrap with the base type", .{ @tagName(op), lhs_nt, @tagName(rhs_info.prim.?), lhs_nt });
        return error.TypeMismatch;
    }
    if (is_named and !is_erased_named) try c.cs.emitOp(.named_inner, op_tok.line);
    try c.cs.emitBinOpFused(op, op_tok.line);
    if (is_named) {
        if (is_erased_named) {
            try c.emitNamedValidation(.{ .named = named_type.? }, op_tok.line);
        } else {
            try c.cs.emitCall(1, op_tok.line);
        }
    } else if (tc) |t| {
        try c.emitVarTypeEpilog(t, op_tok.line);
    }
    try c.emitSetVar(name);
    c.matchOpt(.semicolon);
}

pub fn declareLoopVar(c: anytype, name: Token) !void {
    if (c.isKnownTypeName(name.src))
        return c.err("'{s}' is a type name and cannot be used as a loop variable name", .{name.src});
    try c.cs.emitOp(.null_val, name.line);
    _ = try c.defineLocal(name.src, false);
}

pub fn deferStmt(c: anytype) !void {
    if (!c.inFunc()) {
        c.setErr("'defer' outside of function", .{});
        return error.DeferOutsideFunction;
    }
    // Parse the callee: a primary expression followed by any chain of
    // .prop and [index] accesses, stopping before the outermost call '('.
    c.advance();
    const pfx = c.prev.typ;
    // Track whether the base is a registered type name and where its code starts,
    // so that `defer TypeName.method(instance, ...)` can be rewritten at compile time
    // into a method call on the instance (first argument) rather than the type object.
    var base_type_name: []const u8 = "";
    var base_code_pos: usize = 0;
    var base_is_type: bool = false;
    switch (pfx) {
        .ident => {
            base_type_name = c.prev.src;
            base_code_pos = c.cs.codeLen();
            base_is_type = c.registry.hasNamedType(c.prev.src) or
                c.registry.hasStructTypeLocal(c.prev.src) or
                c.registry.hasVariantType(c.prev.src);
            try c.varExpr(c.prev);
        },
        .kw_func => try funcLit(
            c,
        ),
        .lparen => {
            try c.expr();
            try c.consume(.rparen);
        },
        .lbrace => {
            try compileDeferBlock(c);
            try c.cs.emit2(@intFromEnum(Op.defer_call), 0, c.prev.line);
            c.matchOpt(.semicolon);
            return;
        },
        .err_invalid_char => return error.InvalidChar,
        .err_unterminated_string => {
            c.setErr("unterminated string literal", .{});
            return error.UnterminatedString;
        },
        .err_string_pool_exhausted => {
            c.setErr("string pool exhausted (max {d}KB)", .{@import("lexer.zig").StrPoolSize / 1024});
            return error.UnterminatedString;
        },
        else => {
            c.setErr("expected expression, found {s}", .{c.tokenName(c.cur.typ)});
            return error.ExpectedExpression;
        },
    }
    // Consume chained .prop and [index]; when .prop( is seen it's a deferred method call.
    while (true) {
        if (c.cur.typ == .lbracket) {
            base_is_type = false;
            const line = c.cur.line;
            c.advance();
            try c.expr();
            try c.consume(.rbracket);
            try c.cs.emitOp(.get_index, line);
        } else if (c.cur.typ == .dot) {
            c.advance();
            if (!c.cur.typ.isFieldName()) {
                c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)});
                return error.ExpectedPropertyName;
            }
            const prop = c.cur;
            c.advance();
            if (c.cur.typ == .lparen) {
                c.advance(); // consume '('
                if (base_is_type) {
                    // `defer TypeName.method(instance, args...)` — the type object on the
                    // stack is not a valid method receiver. Truncate it and treat the first
                    // argument as the receiver instead, matching regular `instance.method()`.
                    c.cs.truncateTo(base_code_pos);
                    const direct_named_method: ?[]const u8 = blk: {
                        if (!c.registry.hasNamedType(base_type_name)) break :blk null;
                        var lookup_name: ?[]const u8 = base_type_name;
                        while (lookup_name) |cur_name| {
                            const qrecv = try c.qualifyTypeName(cur_name);
                            const total = qrecv.len + 1 + prop.src.len;
                            const key_buf = c.hs.bump(u8, total) orelse return error.OutOfMemory;
                            @memcpy(key_buf[0..qrecv.len], qrecv);
                            key_buf[qrecv.len] = '.';
                            @memcpy(key_buf[qrecv.len + 1 .. total], prop.src);
                            const candidate = key_buf[0..total];
                            if (c.registry.hasGlobalFunc(candidate)) break :blk candidate;
                            const info = c.registry.getNamedTypeInfo(cur_name) orelse break;
                            lookup_name = info.parent_name;
                        }
                        break :blk null;
                    };
                    if (direct_named_method) |qmethod| {
                        try c.cs.emitGetGlobal(qmethod, prop.line);
                    }
                    var total_argc: u8 = 0;
                    if (!c.check(.rparen)) {
                        while (true) {
                            if (total_argc == 255) {
                                c.setErr("too many arguments to deferred call (max 254)", .{});
                                return error.TooManyElements;
                            }
                            try c.expr();
                            total_argc += 1;
                            if (!c.match(.comma)) break;
                            if (c.check(.rparen)) break;
                        }
                    }
                    try c.consume(.rparen);
                    if (total_argc == 0) {
                        c.setErr("'{s}.{s}(...)' requires at least one argument (the receiver instance)", .{ base_type_name, prop.src });
                        return error.ArityMismatch;
                    }
                    if (direct_named_method != null) {
                        try c.cs.emit2(@intFromEnum(Op.defer_call), total_argc, prop.line);
                    } else {
                        try c.cs.emitDeferInvokeMethod(prop.src, total_argc - 1, prop.line);
                    }
                    c.matchOpt(.semicolon);
                    return;
                }
                var argc: u8 = 0;
                if (!c.check(.rparen)) {
                    while (true) {
                        if (argc == 255) {
                            c.setErr("too many arguments to deferred call (max 254)", .{});
                            return error.TooManyElements;
                        }
                        try c.expr();
                        argc += 1;
                        if (!c.match(.comma)) break;
                        if (c.check(.rparen)) break;
                    }
                }
                try c.consume(.rparen);
                try c.cs.emitDeferInvokeMethod(prop.src, argc, prop.line);
                c.matchOpt(.semicolon);
                return;
            }
            base_is_type = false;
            try c.cs.emitGetField(prop.src, prop.line);
        } else {
            break;
        }
    }
    // Deferred regular call.
    if (!c.match(.lparen)) {
        c.setErr("'defer' requires a function call expression", .{});
        return error.DeferRequiresCall;
    }
    const call_line = c.prev.line;
    var argc: u8 = 0;
    if (!c.check(.rparen)) {
        while (true) {
            if (argc == 255) {
                c.setErr("too many arguments to deferred call (max 254)", .{});
                return error.TooManyElements;
            }
            try c.expr();
            argc += 1;
            if (!c.match(.comma)) break;
        }
    }
    try c.consume(.rparen);
    try c.cs.emit2(@intFromEnum(Op.defer_call), argc, call_line);
    c.matchOpt(.semicolon);
}

pub fn emitAssignTargetPath(c: anytype, target: AssignTarget, all_steps: []const AssignTargetStep) !void {
    const vidx: u16 = try c.cs.addStringConst(MultiAssignValueScratch);
    if (target.step_count == 0) {
        try c.cs.emitGetGlobalIdx(vidx, target.root.line);
        try c.emitSetVar(target.root);
        return;
    }

    try c.emitGetVar(target.root);
    const step_end = target.step_start + target.step_count - 1;
    for (all_steps[target.step_start..step_end]) |st| {
        switch (st) {
            .dot_name => |name| try c.cs.emitGetField(name, target.root.line),
            .index_number => |n| {
                try c.cs.emitConst(.{ .int = @intFromFloat(n) }, target.root.line);
                try c.cs.emitOp(.get_index, target.root.line);
            },
            .index_string => |s| {
                try c.cs.emitStringConst(s, target.root.line);
                try c.cs.emitOp(.get_index, target.root.line);
            },
        }
    }

    const last = all_steps[target.step_start + target.step_count - 1];
    switch (last) {
        .dot_name => |name| {
            try c.cs.emitGetGlobalIdx(vidx, target.root.line);
            try c.cs.emitSetField(name, target.root.line);
        },
        .index_number => |n| {
            try c.cs.emitConst(.{ .int = @intFromFloat(n) }, target.root.line);
            try c.cs.emitGetGlobalIdx(vidx, target.root.line);
            try c.cs.emitOp(.set_index, target.root.line);
        },
        .index_string => |s| {
            try c.cs.emitStringConst(s, target.root.line);
            try c.cs.emitGetGlobalIdx(vidx, target.root.line);
            try c.cs.emitOp(.set_index, target.root.line);
        },
    }
}

pub fn emitExprListTuple(c: anytype) !u8 {
    var count: u8 = 0;
    try c.expr();
    count += 1;
    while (c.match(.comma)) {
        if (count == 255) {
            c.setErr("too many elements (max {d})", .{MaxLocals});
            return error.TooManyElements;
        }
        try c.expr();
        count += 1;
    }
    if (count > 1) try c.cs.emit2(@intFromEnum(Op.build_tuple), count, c.prev.line);
    return count;
}

pub fn emitImplicitReturn(scope: *FuncInfo, cs: *chunk.State, line: u32) !void {
    if (scope.named_return_count == 0) {
        try cs.emitOp(.null_val, line);
    } else if (scope.named_return_count == 1) {
        try cs.emit2(@intFromEnum(Op.get_local), scope.named_return_base, line);
    } else {
        // Push null as a placeholder; the ret handler detects named_return_count>=2
        // and reads directly from slots, pushing N values for the caller (no GC).
        try cs.emitOp(.null_val, line);
    }
}

fn compileDeferBlock(c: anytype) !void {
    // c.prev is '{' (consumed by deferStmt's advance()), c.cur is first token inside block.
    // Desugars `defer { ... }` to the equivalent of `defer (func() { ... })()`:
    // compile the block as a parameterless closure and emit defer_call 0.
    const jump_over = try c.cs.emitJump(.jump, c.prev.line);
    const func_ip = c.cs.codeLen();

    if (c.scope_depth >= MaxScopes) return error.TooManyNestedFunctions;
    c.scopes[c.scope_depth].reset();
    c.scope_depth += 1;

    const saved = c.repl_expr_ok;
    c.repl_expr_ok = false;
    while (!c.check(.rbrace) and !c.check(.eof)) try c.decl();
    try c.consume(.rbrace);
    c.repl_expr_ok = saved;

    try c.cleanupLocals(0, c.prev.line);

    const scope = c.currentScope();
    try emitImplicitReturn(scope, c.cs, c.prev.line);
    try c.cs.emitOp(.ret, c.prev.line);

    c.scope_depth -= 1;
    try c.cs.patchJump(jump_over);

    const uv_count = scope.upvalue_count;
    const slots = c.hs.bump(u8, uv_count) orelse return error.OutOfMemory;
    for (scope.upvalues[0..uv_count], slots[0..uv_count]) |uv, *s| {
        s.* = (if (uv.from_upvalue) @as(u8, 0x80) else @as(u8, 0x00)) | uv.index;
    }

    const any_alts = c.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
    any_alts[0] = .{ .typ = .any };
    const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

    const func_obj = c.hs.allocObject() orelse return error.OutOfMemory;
    func_obj.* = .{ .function = .{
        .ip = func_ip,
        .arity = 0,
        .is_variadic = false,
        .variadic_type = any_spec,
        .capture_slots = slots[0..uv_count],
        .param_types = &.{},
        .has_typed_params = false,
        .return_types = &.{},
        .has_typed_returns = false,
        .named_return_count = 0,
    } };

    const cidx: u16 = try c.cs.addConst(.{ .object = func_obj });
    try c.cs.emitConstIdx(.make_closure, cidx, c.prev.line);
}

pub fn forInStmt(c: anytype) anyerror!void {
    const local_base: u8 = c.currentScope().local_count;
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const kname = c.cur;
    c.advance();
    var vname: ?Token = null;
    if (c.match(.comma)) {
        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
        vname = c.cur;
        c.advance();
    }
    try c.consume(.kw_in);

    try declareLoopVar(c, kname);
    if (vname) |vn| try declareLoopVar(c, vn);

    try c.expr(); // iterable
    try c.cs.emitOp(.iter_init, c.prev.line);
    // Claim a hidden local slot for the iterator so that body locals land on the
    // correct stack offsets. Without this, body-local slot N resolves to the iterator
    // object instead of the actual value. The slot must be REGISTERED under an
    // unmatchable name, not just counted: local_count resets leave stale entries in
    // locals[], and a bare count bump re-exposes them — a previous loop's variable
    // name at this index would shadow the current loop's variable in resolveLocal
    // and make assignLoopVar overwrite the iterator on the stack (#193).
    {
        const scope = c.currentScope();
        if (scope.local_count >= MaxLocals) {
            c.setErr("too many local variables (max {d})", .{MaxLocals});
            return error.TooManyLocals;
        }
        scope.locals[scope.local_count] = .{ .name = "" };
        scope.local_count += 1;
    }
    const body_keep: u8 = c.currentScope().local_count;

    const loop_start = c.cs.codeLen();
    try c.pushLoop(loop_start, local_base, body_keep, 0);
    if (c.resolveLocal(kname.src)) |slot| {
        c.currentLoop().loop_var_slots[c.currentLoop().loop_var_count] = slot;
        c.currentLoop().loop_var_names[c.currentLoop().loop_var_count] = kname.src;
        c.currentLoop().loop_var_count += 1;
    }
    if (vname) |vn| {
        if (c.resolveLocal(vn.src)) |slot| {
            c.currentLoop().loop_var_slots[c.currentLoop().loop_var_count] = slot;
            c.currentLoop().loop_var_names[c.currentLoop().loop_var_count] = vn.src;
            c.currentLoop().loop_var_count += 1;
        }
    }
    try c.cs.emitOp(if (vname == null) .iter_next1 else .iter_next2, c.prev.line);
    const exit_j = try c.cs.emitJump(.jif_pop, c.prev.line);

    if (vname) |vn| {
        // stack: iter, key, value
        try assignLoopVar(c, vn);
        try assignLoopVar(c, kname);
    } else {
        // stack: iter, value
        try assignLoopVar(c, kname);
    }

    try c.consume(.lbrace);
    c.loop_body_depth += 1;
    try block(
        c,
    );
    c.loop_body_depth -= 1;
    for (c.currentLoop().loop_var_slots[0..c.currentLoop().loop_var_count]) |slot| {
        if (c.currentScope().locals[slot].is_captured)
            try c.cs.emit2(@intFromEnum(Op.close_upvalue), slot, c.prev.line);
    }
    try c.cs.emitLoop(loop_start, c.prev.line);

    try c.cs.patchJump(exit_j);
    if (!c.inFunc()) try c.cs.emitOp(.pop, c.prev.line); // pop iterator (top-level only)
    if (!c.inFunc()) {
        const lp = c.currentLoop();
        for (lp.loop_var_slots[0..lp.loop_var_count], lp.loop_var_names[0..lp.loop_var_count]) |slot, lname| {
            try c.cs.emit2(@intFromEnum(Op.get_local), slot, c.prev.line);
            try c.cs.emitOpStringConst(.def_global, try c.qualifyGlobalName(lname), c.prev.line);
            try c.cs.emitOp(.pop, c.prev.line);
        }
        c.currentScope().local_count = local_base;
    }
    try c.cleanupLocals(local_base, c.prev.line);

    const loop = c.popLoop();
    for (loop.break_offsets[0..loop.break_count]) |off| try c.cs.patchJump(off);
}

pub fn forStmt(c: anytype) anyerror!void {
    if (isForIn(
        c,
    )) {
        try forInStmt(
            c,
        );
    } else if (isCStyleFor(
        c,
    )) {
        try cForStmt(
            c,
        );
    } else {
        try whileForStmt(
            c,
        );
    }
}

pub fn funcLit(c: anytype) anyerror!void {
    // receive() is legal only lexically inside a task's own behavior
    // function, never inside a nested closure — see the in_task_body
    // field comment (compiler.zig) and design doc §4.1.
    const saved_in_task_body = c.in_task_body;
    c.in_task_body = false;
    defer c.in_task_body = saved_in_task_body;
    _ = try compileFuncWithPrefix(c, &[_][]const u8{}, false, null);
}

pub fn hasInitSemicolon(c: anytype) bool {
    var lx = c.lex;
    var t = c.cur;
    while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
        if (t.typ == .semicolon) return true;
        t = lx.next();
    }
    return false;
}

pub fn ifStmt(c: anytype) anyerror!void {
    return ifStmtDepth(c, 0);
}

fn ifStmtDepth(c: anytype, depth: u32) anyerror!void {
    if (depth >= 256) return c.err("if/else-if chain too deep (max 256 levels)", .{});
    const local_base: u8 = c.currentScope().local_count;

    if (hasInitSemicolon(
        c,
    )) {
        if (c.check(.ident) and c.peekTT() == .colon_eq) {
            try varDecl(c, false, false);
        } else if (c.check(.ident) and c.isTypedVarDecl()) {
            try varDecl(c, false, false);
        } else if (c.match(.kw_const)) {
            try varDecl(c, true, true);
        } else if (c.check(.ident) and c.peekTT() == .eq) {
            try assignStmt(
                c,
            );
        } else {
            try c.expr();
            try c.cs.emitOp(.pop, c.prev.line);
            c.matchOpt(.semicolon);
        }
    }

    try c.expr();
    try checkBoolCondition(c);
    try c.consume(.lbrace);

    const then_j = try c.cs.emitJump(.jif_pop, c.prev.line);
    try block(
        c,
    );

    const else_j = try c.cs.emitJump(.jump, c.prev.line);
    try c.cs.patchJump(then_j);

    if (c.match(.kw_else)) {
        if (c.match(.kw_if)) {
            try ifStmtDepth(
                c,
                depth + 1,
            );
        } else {
            try c.consume(.lbrace);
            try block(
                c,
            );
        }
    }
    try c.cs.patchJump(else_j);
    try c.cleanupLocals(local_base, c.prev.line);
}

pub fn incrStmt(c: anytype) !void {
    const name = c.cur;
    try c.ensureMutableBinding(name);
    c.advance();
    const is_inc = c.cur.typ == .plus_plus;
    c.advance();
    const tc = c.getLocalTypeCheck(name.src);
    if (tc) |t| {
        if (t == .named) {
            const info = c.registry.getNamedTypeInfo(t.named);
            const is_erased_named = if (info) |nt| switch (nt.base) {
                // .enum_t: see isErasedNamedType — enums take the erased path.
                .int, .float, .bool, .rune, .enum_t => true,
                else => false,
            } else false;
            if (is_erased_named) {
                try c.emitGetVar(name);
                try c.cs.emitConst(.{ .int = 1.0 }, name.line);
                try c.cs.emitBinOpFused(if (is_inc) .add else .sub, name.line);
                try c.emitNamedValidation(t, name.line);
            } else {
                try c.emitVarTypeProlog(t, name.line);
                try c.emitGetVar(name);
                try c.cs.emitOp(.named_inner, name.line);
                try c.cs.emitConst(.{ .int = 1.0 }, name.line);
                try c.cs.emitBinOpFused(if (is_inc) .add else .sub, name.line);
                try c.cs.emitCall(1, name.line);
            }
        } else {
            try c.emitGetVar(name);
            try c.cs.emitConst(.{ .int = 1.0 }, name.line);
            try c.cs.emitBinOpFused(if (is_inc) .add else .sub, name.line);
            try c.emitVarTypeEpilog(t, name.line);
        }
    } else {
        try c.emitGetVar(name);
        try c.cs.emitConst(.{ .int = 1.0 }, name.line);
        try c.cs.emitBinOpFused(if (is_inc) .add else .sub, name.line);
    }
    try c.emitSetVar(name);
    c.matchOpt(.semicolon);
}

pub fn indexAssignStmt(c: anytype) !void {
    const name = c.cur;
    c.advance();
    try c.emitGetVar(name);
    try c.consume(.lbracket);
    try c.expr();
    try c.consume(.rbracket);
    try c.consume(.eq);
    try c.expr();
    try c.cs.emitOp(.set_index, name.line);
    c.matchOpt(.semicolon);
}

pub fn isCStyleFor(c: anytype) bool {
    var lx = c.lex;
    var t = c.cur;
    while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
        if (t.typ == .semicolon) return true;
        t = lx.next();
    }
    return false;
}

pub fn isForIn(c: anytype) bool {
    var lx = c.lex;
    var t = c.cur;
    while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
        if (t.typ == .kw_in) return true;
        if (t.typ == .semicolon) return false;
        t = lx.next();
    }
    return false;
}

pub fn isIndexAssign(c: anytype) bool {
    var lx = c.lex;
    const start_line = c.cur.line;
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

pub fn isMultiAssignEq(c: anytype) bool {
    var lx = c.lex;
    const start_line = c.cur.line;
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

pub fn isMultiBind(c: anytype, op: TT) bool {
    var lx = c.lex;
    const start_line = c.cur.line;
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

pub fn isPropertyAssign(c: anytype) bool {
    var lx = c.lex;
    const start_line = c.cur.line;
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
            .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq => return saw_path and depth == 0,
            .semicolon, .lbrace, .rbrace => return false,
            else => {},
        }
        t = lx.next();
    }
    return false;
}

pub fn multiBindStmt(c: anytype, is_decl: bool) !void {
    var names: [MaxLocals]Token = undefined;
    var targets: [MaxLocals]AssignTarget = undefined;
    var steps: [MaxLocals * 8]AssignTargetStep = undefined;
    var count: u8 = 0;
    var step_count: u16 = 0;

    if (is_decl) {
        count = try parseNameList(c, &names);
        if (count < 2) return c.err("multi-assign requires at least two targets", .{});
        for (names[0..count]) |n| {
            if (n.typ != .ident) continue;
            if (c.isKnownTypeName(n.src))
                return c.err("'{s}' is a type name and cannot be used as a variable name", .{n.src});
        }
        if (c.inFunc()) {
            for (names[0..count]) |n| {
                if (n.typ == .kw_trap) continue;
                try c.cs.emitOp(.null_val, n.line);
                _ = try c.defineLocal(n.src, false);
            }
        }
    } else {
        const parsed = try parseAssignTargetList(c, &targets, &steps);
        count = parsed.target_count;
        step_count = parsed.step_count;
        if (count < 2) return c.err("multi-assign requires at least two targets", .{});
    }

    try c.consume(if (is_decl) .colon_eq else .eq);
    // Signal to infixExpr(.lparen) that this is a multi-assign context of `count` values.
    c.multi_assign_lhs_count = count;
    c.last_spread_return_count = 0;
    _ = try emitExprListTuple(
        c,
    );
    const spread_n = c.last_spread_return_count;
    c.multi_assign_lhs_count = 0;
    c.last_spread_return_count = 0;

    if (spread_n == count) {
        // Spread path: callee pushed N values (vN-1 on top, v0 below).
        // Assign in reverse order: pop vN-1 → names[N-1], ..., pop v0 → names[0].
        for (0..count) |rii| {
            const i: u8 = @intCast(count - 1 - rii);
            if (is_decl) {
                const is_trap_slot = names[i].typ == .kw_trap;
                if (is_trap_slot) {
                    try c.cs.emitOp(.op_trap_check, names[i].line);
                } else if (c.inFunc()) {
                    try c.emitSetVar(names[i]);
                } else {
                    try c.cs.emitOpStringConst(.def_global, try c.qualifyGlobalName(names[i].src), names[i].line);
                }
            } else {
                if (targets[i].step_count == 0) try c.ensureMutableBinding(targets[i].root);
                const vidx: u16 = try c.cs.addStringConst(MultiAssignValueScratch);
                try c.cs.emitConstIdx(.def_global, vidx, targets[i].root.line);
                try emitAssignTargetPath(c, targets[i], steps[0..step_count]);
            }
        }
        // No final pop: all values consumed individually.
    } else {
        // Tuple path: one tuple value on the stack.
        try c.cs.emit2(@intFromEnum(Op.tuple_check_arity), count, c.prev.line);
        for (0..count) |ii| {
            const i: u8 = @intCast(ii);
            if (is_decl) {
                const is_trap_slot = names[i].typ == .kw_trap;
                try c.cs.emitOp(.dup, names[i].line);
                try c.cs.emit2(@intFromEnum(Op.tuple_get), i, names[i].line);
                if (is_trap_slot) {
                    try c.cs.emitOp(.op_trap_check, names[i].line);
                } else if (c.inFunc()) {
                    try c.emitSetVar(names[i]);
                } else {
                    try c.cs.emitOpStringConst(.def_global, try c.qualifyGlobalName(names[i].src), names[i].line);
                }
            } else {
                if (targets[i].step_count == 0) try c.ensureMutableBinding(targets[i].root);
                const vidx: u16 = try c.cs.addStringConst(MultiAssignValueScratch);
                try c.cs.emitOp(.dup, targets[i].root.line);
                try c.cs.emit2(@intFromEnum(Op.tuple_get), i, targets[i].root.line);
                try c.cs.emitConstIdx(.def_global, vidx, targets[i].root.line);
                try emitAssignTargetPath(c, targets[i], steps[0..step_count]);
            }
        }
        try c.cs.emitOp(.pop, c.prev.line);
    }
    c.matchOpt(.semicolon);
}

pub fn parseAssignTargetList(c: anytype, targets: *[MaxLocals]AssignTarget, steps: *[MaxLocals * 8]AssignTargetStep) !struct { target_count: u8, step_count: u16 } {
    var tcount: u8 = 0;
    var scount: u16 = 0;
    while (true) {
        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
        if (tcount >= MaxLocals) {
            c.setErr("too many local variables (max {d})", .{MaxLocals});
            return error.TooManyLocals;
        }
        const root = c.cur;
        c.advance();
        const start = scount;

        while (true) {
            if (c.match(.dot)) {
                if (!c.cur.typ.isFieldName()) {
                    c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)});
                    return error.ExpectedPropertyName;
                }
                if (scount >= steps.len) {
                    c.setErr("too many elements (max {d})", .{MaxLocals});
                    return error.TooManyElements;
                }
                steps[scount] = .{ .dot_name = c.cur.src };
                scount += 1;
                c.advance();
                continue;
            }
            if (c.match(.lbracket)) {
                if (scount >= steps.len) {
                    c.setErr("too many elements (max {d})", .{MaxLocals});
                    return error.TooManyElements;
                }
                if (c.cur.typ == .number) {
                    const n = common.parseFloat(c.cur.src) orelse return error.BadNumber;
                    steps[scount] = .{ .index_number = n };
                    scount += 1;
                    c.advance();
                } else if (c.cur.typ == .string) {
                    steps[scount] = .{ .index_string = c.cur.src };
                    scount += 1;
                    c.advance();
                } else {
                    return c.err("expected number or string index, found {s}", .{c.tokenName(c.cur.typ)});
                }
                try c.consume(.rbracket);
                continue;
            }
            break;
        }

        const path_len = scount - start;
        if (path_len > std.math.maxInt(u8)) return error.TooManyElements;
        targets[tcount] = .{
            .root = root,
            .step_start = start,
            .step_count = @intCast(path_len),
        };
        tcount += 1;
        if (!c.match(.comma)) break;
    }
    return .{ .target_count = tcount, .step_count = scount };
}

pub fn parseNameList(c: anytype, out: *[MaxLocals]Token) !u8 {
    var count: u8 = 0;
    while (true) {
        if (c.cur.typ != .ident and c.cur.typ != .kw_trap) return c.err("expected identifier or 'trap', found {s}", .{c.tokenName(c.cur.typ)});
        if (count >= MaxLocals) {
            c.setErr("too many local variables (max {d})", .{MaxLocals});
            return error.TooManyLocals;
        }
        out[count] = c.cur;
        count += 1;
        c.advance();
        if (!c.match(.comma)) break;
    }
    return count;
}

pub fn propertyAssignStmt(c: anytype) !void {
    const root = c.cur;
    c.advance();
    try c.emitGetVar(root);

    // Track the kind of the last accessor so we can emit get_field/set_field for
    // dot accesses and the old constant+get_index/set_index path for bracket accesses.
    const LastKind = enum { dot_name, bracket };
    var last_kind: LastKind = .bracket;
    var last_name: []const u8 = undefined;
    var last_line: u32 = 0;

    while (true) {
        if (c.match(.dot)) {
            if (!c.cur.typ.isFieldName()) {
                c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)});
                return error.ExpectedPropertyName;
            }
            const prop = c.cur;
            c.advance();
            if (c.check(.eq) or c.check(.plus_eq) or c.check(.minus_eq) or c.check(.star_eq) or c.check(.slash_eq) or c.check(.amp_eq) or c.check(.pipe_eq) or c.check(.caret_eq) or c.check(.lt_lt_eq) or c.check(.gt_gt_eq)) {
                // This is the last step — record name, do NOT push key, break.
                last_kind = .dot_name;
                last_name = prop.src;
                last_line = prop.line;
                break;
            }
            try c.cs.emitGetField(prop.src, prop.line);
            continue;
        }

        if (c.match(.lbracket)) {
            try c.expr();
            try c.consume(.rbracket);
            if (c.check(.eq) or c.check(.plus_eq) or c.check(.minus_eq) or c.check(.star_eq) or c.check(.slash_eq) or c.check(.amp_eq) or c.check(.pipe_eq) or c.check(.caret_eq) or c.check(.lt_lt_eq) or c.check(.gt_gt_eq)) {
                last_kind = .bracket;
                break;
            }
            try c.cs.emitOp(.get_index, c.prev.line);
            continue;
        }

        return c.err("expected '.' or '[', found {s}", .{c.tokenName(c.cur.typ)});
    }

    const op_tok = c.cur;

    if (c.match(.eq)) {
        try c.expr();
        switch (last_kind) {
            .dot_name => try c.cs.emitSetField(last_name, last_line),
            .bracket => try c.cs.emitOp(.set_index, c.prev.line),
        }
        c.matchOpt(.semicolon);
        return;
    }

    if (c.match(.plus_eq) or c.match(.minus_eq) or c.match(.star_eq) or c.match(.slash_eq) or c.match(.amp_eq) or c.match(.pipe_eq) or c.match(.caret_eq) or c.match(.lt_lt_eq) or c.match(.gt_gt_eq)) {
        const op: Op = switch (op_tok.typ) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .amp_eq => .bit_and,
            .pipe_eq => .bit_or,
            .caret_eq => .bit_xor,
            .lt_lt_eq => .shl,
            .gt_gt_eq => .shr,
            else => return c.err("unsupported compound assignment operator", .{}),
        };
        switch (last_kind) {
            .dot_name => {
                // Stack: container. Dup it, read old value with get_field, compute, write back.
                try c.cs.emitOp(.dup, op_tok.line);
                try c.cs.emitGetField(last_name, last_line);
                try c.expr();
                try c.cs.emitOp(op, op_tok.line);
                try c.cs.emitSetField(last_name, op_tok.line);
            },
            .bracket => {
                // Stack: container, key. Dup pair, read old value, compute, write back.
                try c.cs.emitOp(.dup2, op_tok.line);
                try c.cs.emitOp(.get_index, op_tok.line);
                try c.expr();
                try c.cs.emitOp(op, op_tok.line);
                try c.cs.emitOp(.set_index, op_tok.line);
            },
        }
        c.matchOpt(.semicolon);
        return;
    }

    return c.err("unsupported compound assignment operator", .{});
}

pub fn returnStmt(c: anytype) !void {
    if (!c.inFunc()) {
        c.setErr("'return' outside of function", .{});
        return error.ReturnOutsideFunction;
    }
    const line = c.prev.line;
    const scope = c.currentScope();
    if (c.block_depth == scope.body_block_depth) scope.body_ends_with_return = true;
    if (c.check(.rbrace) or c.check(.eof) or c.check(.semicolon)) {
        // Bare return: use named return variables if present, otherwise null.
        // Returning null from a primitive-typed function is never provable.
        if (scope.return_prim != null) scope.all_returns_proven = false;
        try emitImplicitReturn(scope, c.cs, line);
    } else if (scope.named_return_count > 0) {
        // Named-return function with explicit value(s): assign to the named return
        // slots first so deferred closures can observe and modify them.
        if (scope.named_return_count == 1) {
            const tc = scope.locals[scope.named_return_base].type_check;
            try c.emitVarTypeProlog(tc, line);
            try c.expr();
            try c.emitVarTypeEpilog(tc, line);
            try c.cs.emit2(@intFromEnum(Op.set_local), scope.named_return_base, line);
        } else {
            for (0..scope.named_return_count) |ri| {
                if (ri > 0) try c.consume(.comma);
                const slot: u8 = scope.named_return_base + @as(u8, @intCast(ri));
                const tc = scope.locals[slot].type_check;
                try c.emitVarTypeProlog(tc, line);
                try c.expr();
                try c.emitVarTypeEpilog(tc, line);
                try c.cs.emit2(@intFromEnum(Op.set_local), slot, line);
            }
        }
        try emitImplicitReturn(scope, c.cs, line);
    } else {
        if (scope.is_named and !scope.has_typed_returns) {
            c.setErr("named-return function must declare return types", .{});
            return error.MissingReturnType;
        }
        // First return expression, with prim capture for the return proof.
        c.beginExprPrimCapture();
        try c.expr();
        const rinfo = c.endExprPrimCapture();
        var rcount: u8 = 1;
        while (c.match(.comma)) {
            if (rcount == 255) {
                c.setErr("too many elements (max {d})", .{MaxLocals});
                return error.TooManyElements;
            }
            try c.expr();
            rcount += 1;
        }
        if (rcount > 1) try c.cs.emit2(@intFromEnum(Op.build_tuple), rcount, c.prev.line);
        if (scope.return_prim) |rp| {
            if (rcount != 1 or rinfo.named_type != null) {
                scope.all_returns_proven = false;
            } else if (rinfo.prim) |p| {
                const ok = switch (rp) {
                    .int => p == .int or p == .rune, // mirrors checkPrimitiveReturn
                    .float => p == .float or p == .rune,
                    .bool => p == .bool,
                    .string => p == .string,
                    .rune => p == .rune,
                    else => false,
                };
                if (!ok) {
                    c.setErr("cannot return {s} from function returning {s}; convert explicitly", .{ @tagName(p), @tagName(rp) });
                    c.err_line = line;
                    return error.TypeError;
                }
            } else {
                scope.all_returns_proven = false;
            }
        }
    }
    // Close any captured locals before returning. Without this, the get_local_ret
    // peephole (get_local + ret → fused) would skip the close_upvalue that
    // cleanupLocals emits at end-of-function, leaving upvalues dangling on the
    // dead stack frame.
    // Named return variables (slots [named_return_base .. named_return_base+named_return_count))
    // must NOT be closed here: retSlowPath reads them AFTER deferred functions run, and
    // closing them severs the connection between the deferred closure's upvalue and the slot.
    // Tail-call upgrade (call immediately followed by ret → call_tail) is decided
    // by the load-time fusion pass, which sees whether close_upvalue intervened.
    var idx: u8 = scope.local_count;
    while (idx > 0) {
        idx -= 1;
        if (idx >= scope.named_return_base and idx < scope.named_return_base + scope.named_return_count) {
            continue;
        }
        if (scope.locals[idx].is_captured) {
            try c.cs.emit2(@intFromEnum(Op.close_upvalue), idx, line);
        }
    }
    try c.cs.emitOp(.ret, line);
    c.matchOpt(.semicolon);
}

pub fn skipTypeSpec(c: anytype) !void {
    _ = c.match(.question);
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    c.advance();
}

pub fn stmt(c: anytype) anyerror!void {
    const saved = c.repl_expr_ok;
    defer c.repl_expr_ok = saved;
    c.repl_expr_ok = false;

    if (c.match(.kw_break)) {
        try c.emitBreak(c.prev.line);
        c.matchOpt(.semicolon);
        return;
    }
    if (c.match(.kw_continue)) {
        try c.emitContinue(c.prev.line);
        c.matchOpt(.semicolon);
        return;
    }
    if (c.match(.kw_return)) {
        try returnStmt(
            c,
        );
        return;
    }
    if (c.match(.kw_defer)) {
        try deferStmt(
            c,
        );
        return;
    }
    if (c.match(.kw_assert)) {
        try assertStmt(
            c,
        );
        return;
    }
    if (c.match(.kw_if)) {
        try ifStmt(
            c,
        );
        return;
    }
    if (c.match(.kw_for)) {
        try forStmt(
            c,
        );
        return;
    }
    if (c.match(.kw_switch)) {
        try switchStmt(
            c,
        );
        return;
    }
    if (c.match(.kw_var)) {
        try varDecl(c, true, false);
        return;
    }

    if (c.check(.kw_trap)) {
        if (c.peekTT() == .comma and isMultiBind(c, .colon_eq)) {
            try multiBindStmt(c, true);
            return;
        }
        return c.err("expected expression, found {s}", .{c.tokenName(c.cur.typ)});
    }

    if (c.check(.ident)) {
        const ptt = c.peekTT();
        if (ptt == .comma and isMultiBind(c, .colon_eq)) {
            try multiBindStmt(c, true);
            return;
        }
        if ((ptt == .comma or ptt == .dot or ptt == .lbracket) and isMultiAssignEq(
            c,
        )) {
            try multiBindStmt(c, false);
            return;
        }
        if (ptt == .plus_plus or ptt == .minus_minus) {
            try incrStmt(
                c,
            );
            return;
        }
        if (ptt == .plus_eq or ptt == .minus_eq or ptt == .star_eq or ptt == .slash_eq or ptt == .amp_eq or ptt == .pipe_eq or ptt == .caret_eq or ptt == .lt_lt_eq or ptt == .gt_gt_eq) {
            try compoundStmt(
                c,
            );
            return;
        }
        if (ptt == .eq) {
            try assignStmt(
                c,
            );
            return;
        }
        if ((ptt == .dot or ptt == .lbracket) and isPropertyAssign(
            c,
        )) {
            try propertyAssignStmt(
                c,
            );
            return;
        }
        if (ptt == .lbracket and isIndexAssign(
            c,
        )) {
            try indexAssignStmt(
                c,
            );
            return;
        }
    }

    c.repl_expr_ok = saved;
    try c.expr();
    if (c.options.repl_mode and c.repl_expr_ok) {
        if (c.repl_pending_pop) try c.cs.emitOp(.pop, c.prev.line);
        c.repl_pending_pop = true;
    } else {
        try c.cs.emitOp(.pop, c.prev.line);
    }
    c.matchOpt(.semicolon);
}

pub fn switchStmt(c: anytype) anyerror!void {
    c.parsing_switch_scrutinee = true;
    c.switch_scrutinee_is_type = false;
    try c.expr();
    c.parsing_switch_scrutinee = false;
    // Capture into a local before parsing case bodies: a nested switch in a
    // case body would otherwise clobber this shared compiler field.
    const is_type_switch = c.switch_scrutinee_is_type;
    c.switch_scrutinee_is_type = false;
    try c.consume(.lbrace);

    var end_jumps: [MaxSwitchJumps]usize = undefined;
    var end_count: usize = 0;
    var saw_default = false;
    var seen_arms: [MaxSwitchJumps][]const u8 = undefined;
    var seen_arm_count: usize = 0;

    while (!c.check(.rbrace) and !c.check(.eof)) {
        if (c.match(.kw_case)) {
            if (c.check(.dot)) {
                if (is_type_switch) return c.err("'case .arm_name' is a variant pattern and cannot be used in a '.type' switch", .{});
                // Variant arm pattern: case .arm_name { } or case .arm_name as binding { }
                const dot_line = c.cur.line;
                c.advance(); // consume '.'
                if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
                const arm_name_tok = c.cur;
                c.advance(); // consume arm name
                var binding: ?[]const u8 = null;
                if (c.match(.kw_as)) {
                    if (c.cur.typ != .ident) return c.err("expected identifier after 'as', found {s}", .{c.tokenName(c.cur.typ)});
                    binding = c.cur.src;
                    c.advance();
                }
                // A guarded case does not fully cover its arm, so only
                // unguarded cases count toward exhaustiveness.
                const has_guard = c.check(.kw_when);
                if (!has_guard and seen_arm_count < MaxSwitchJumps) {
                    seen_arms[seen_arm_count] = arm_name_tok.src;
                    seen_arm_count += 1;
                }
                // Emit: dup, variant_check arm_name, jump_if_false [H]
                try c.cs.emitOp(.dup, dot_line);
                try c.cs.emitOpStringConst(.variant_check, arm_name_tok.src, dot_line);
                const next_case = try c.cs.emitJump(.jif_pop, dot_line);
                // Handle switch value and optional binding.
                const local_before = c.currentScope().local_count;
                // A guarded binding cannot consume the scrutinee in place: the
                // guard may fail, and the next case still needs the value. Pin
                // the scrutinee's stack slot as a hidden local and bind a
                // duplicated payload on top; a failed guard pops the binding
                // and leaves the scrutinee for the next case.
                var guarded_local_binding = false;
                if (binding != null) {
                    if (c.isKnownTypeName(binding.?))
                        return c.err("'{s}' is a type name and cannot be used as a binding name", .{binding.?});
                    if (has_guard and c.inFunc()) {
                        _ = try c.defineLocal("_ scrutinee", true);
                        try c.cs.emitOp(.dup, dot_line);
                        try c.cs.emitOp(.variant_payload, dot_line);
                        _ = try c.defineLocal(binding.?, false);
                        guarded_local_binding = true;
                    } else if (has_guard) {
                        // Global scope: def_global pops the payload copy, so
                        // the scrutinee survives a failed guard on its own.
                        try c.cs.emitOp(.dup, dot_line);
                        try c.cs.emitOp(.variant_payload, dot_line);
                        try c.cs.emitOpStringConst(.def_global, try c.qualifyGlobalName(binding.?), dot_line);
                    } else {
                        try c.cs.emitOp(.variant_payload, dot_line);
                        if (c.inFunc()) {
                            _ = try c.defineLocal(binding.?, false);
                        } else {
                            try c.cs.emitOpStringConst(.def_global, try c.qualifyGlobalName(binding.?), dot_line);
                        }
                    }
                }
                var guard_fail: ?usize = null;
                if (has_guard) {
                    _ = c.match(.kw_when);
                    const guard_line = c.prev.line;
                    // Compile the guard at case-body depth: like body reads,
                    // references (e.g. the def_global binding at global scope)
                    // resolve at runtime rather than via the eager top-level
                    // undefined-variable check.
                    c.block_depth += 1;
                    try c.expr();
                    c.block_depth -= 1;
                    guard_fail = try c.cs.emitJump(.jif_pop, guard_line);
                }
                // Consume the scrutinee on the matched path. The guarded local
                // binding keeps it pinned as the hidden local instead (cleanup
                // pops it); an unguarded binding already consumed it in place.
                if (binding == null or (has_guard and !c.inFunc())) {
                    try c.cs.emitOp(.pop, dot_line);
                }
                try c.consume(.lbrace);
                try block(
                    c,
                );
                // Snapshot before cleanup truncates the table: if the guard
                // captured the binding in a closure, the fail path must close
                // that upvalue before dropping the slot.
                const binding_captured = guarded_local_binding and
                    c.currentScope().locals[local_before + 1].is_captured;
                try c.cleanupLocals(local_before, c.prev.line);
                if (end_count >= MaxSwitchJumps) {
                    c.setErr("too many switch cases (max {d})", .{MaxSwitchJumps});
                    return error.TooManySwitchCases;
                }
                end_jumps[end_count] = try c.cs.emitJump(.jump, c.prev.line);
                end_count += 1;
                if (guarded_local_binding) {
                    // Failed guard lands here with [scrutinee, binding]: drop
                    // the binding, then fall into the next case's test.
                    try c.cs.patchJump(guard_fail.?);
                    if (binding_captured) try c.cs.emit2(@intFromEnum(Op.close_upvalue), local_before + 1, c.prev.line);
                    try c.cs.emitOp(.pop, dot_line);
                } else if (guard_fail) |gf| {
                    try c.cs.patchJump(gf);
                }
                try c.cs.patchJump(next_case);
            } else {
                // Regular value case: supports a comma-separated list of values.
                // For each value except the last:
                //   dup; val; eq; jif_pop → try_next; jump → body_start
                // For the last value:
                //   dup; val; eq; jif_pop → next_case; fall through to body_start
                const MaxCaseVals = 32;
                var body_jumps: [MaxCaseVals]usize = undefined;
                var body_jump_count: usize = 0;
                const case_line = c.prev.line;

                while (true) {
                    try c.cs.emitOp(.dup, case_line);
                    if (is_type_switch) {
                        try c.typeNameLiteral();
                    } else {
                        try c.expr();
                    }
                    try c.cs.emitBinOpFused(.eq, case_line);

                    if (c.match(.comma)) {
                        const try_next = try c.cs.emitJump(.jif_pop, case_line);
                        if (body_jump_count >= MaxCaseVals) {
                            c.setErr("too many values in case (max {d})", .{MaxCaseVals});
                            return error.TooManySwitchCases;
                        }
                        body_jumps[body_jump_count] = try c.cs.emitJump(.jump, case_line);
                        body_jump_count += 1;
                        try c.cs.patchJump(try_next);
                    } else {
                        const next_case = try c.cs.emitJump(.jif_pop, case_line);
                        for (body_jumps[0..body_jump_count]) |bj| try c.cs.patchJump(bj);
                        // Optional guard after the value list: evaluated with
                        // the scrutinee still on the stack, so a failed guard
                        // falls through to the next case like a failed match.
                        var guard_fail: ?usize = null;
                        if (c.match(.kw_when)) {
                            const guard_line = c.prev.line;
                            c.block_depth += 1;
                            try c.expr();
                            c.block_depth -= 1;
                            guard_fail = try c.cs.emitJump(.jif_pop, guard_line);
                        }
                        try c.cs.emitOp(.pop, case_line);
                        try c.consume(.lbrace);
                        try block(
                            c,
                        );
                        if (end_count >= MaxSwitchJumps) {
                            c.setErr("too many switch cases (max {d})", .{MaxSwitchJumps});
                            return error.TooManySwitchCases;
                        }
                        end_jumps[end_count] = try c.cs.emitJump(.jump, c.prev.line);
                        end_count += 1;
                        try c.cs.patchJump(next_case);
                        if (guard_fail) |gf| try c.cs.patchJump(gf);
                        break;
                    }
                }
            }
            continue;
        }

        if (c.matchWord("default")) {
            if (saw_default) {
                c.setErr("duplicate 'default' case in switch", .{});
                return error.DuplicateDefaultCase;
            }
            saw_default = true;
            // Pop the switch value that is still on the stack when default is reached.
            try c.cs.emitOp(.pop, c.prev.line);
            try c.consume(.lbrace);
            try block(
                c,
            );
            if (end_count >= MaxSwitchJumps) {
                c.setErr("too many switch cases (max {d})", .{MaxSwitchJumps});
                return error.TooManySwitchCases;
            }
            end_jumps[end_count] = try c.cs.emitJump(.jump, c.prev.line);
            end_count += 1;
            continue;
        }

        return c.err("expected 'case' or 'default', found {s}", .{c.tokenName(c.cur.typ)});
    }

    // Exhaustiveness check: if no default was present and we saw at least one
    // variant arm, try to identify the variant type and report any missing arms.
    if (!saw_default and seen_arm_count > 0 and !is_type_switch) {
        if (c.registry.findVariantForArms(seen_arms[0..seen_arm_count])) |vobj| {
            const all_arms = vobj.variant_type.arms;
            // Check per-arm coverage directly rather than gating on
            // `all_arms.len > seen_arm_count`: seen_arm_count counts every
            // unguarded case occurrence, including duplicates, so a switch
            // that repeats one arm's name instead of covering a distinct
            // arm could reach seen_arm_count == all_arms.len while a real
            // arm goes unhandled — the count-only gate let that compile
            // silently, falling through the switch at runtime with no
            // panic. Building the missing list unconditionally and only
            // erroring when it's non-empty catches that case too.
            var missing_buf: [512]u8 = undefined;
            var missing_len: usize = 0;
            for (all_arms) |a| {
                var covered = false;
                for (seen_arms[0..seen_arm_count]) |s| {
                    if (common.streq(a.name, s)) {
                        covered = true;
                        break;
                    }
                }
                if (!covered) {
                    if (missing_len > 0 and missing_len + 2 < missing_buf.len) {
                        missing_buf[missing_len] = ',';
                        missing_buf[missing_len + 1] = ' ';
                        missing_len += 2;
                    }
                    if (missing_len + 1 + a.name.len < missing_buf.len) {
                        missing_buf[missing_len] = '.';
                        missing_len += 1;
                        @memcpy(missing_buf[missing_len .. missing_len + a.name.len], a.name);
                        missing_len += a.name.len;
                    }
                }
            }
            if (missing_len > 0) {
                c.setErr("non-exhaustive switch on {s}: missing {s}", .{ vobj.variant_type.name, missing_buf[0..missing_len] });
                return error.NonExhaustiveSwitch;
            }
        }
    }

    try c.consume(.rbrace);
    try c.cs.emitOp(.pop, c.prev.line);

    for (end_jumps[0..end_count]) |j| try c.cs.patchJump(j);
}

fn fieldTypeAltLabel(hs: *heap.State, alt: FieldTypeAlt) []const u8 {
    return switch (alt.typ) {
        .int => "int",
        .float => "float",
        .decimal_t => "decimal",
        .boolean => "bool",
        .string => "string",
        .rune_t => "rune",
        .error_t => "error",
        .actor_ref_t => "actor",
        .null_t => "null",
        .any => "any",
        .func_t => "func",
        .named_t, .variant_t => alt.named_name,
        .struct_t => alt.struct_name,
        .interface_t => alt.interface_name,
        .array => blk: {
            const inner = if (alt.elem_spec) |es|
                if (es.alts.len > 0) fieldTypeAltLabel(hs, es.alts[0]) else "any"
            else
                "any";
            const buf = hs.bump(u8, inner.len + 2) orelse break :blk "array";
            buf[0] = '[';
            buf[1] = ']';
            @memcpy(buf[2 .. inner.len + 2], inner);
            break :blk buf[0 .. inner.len + 2];
        },
        .map => blk: {
            const k = if (alt.key_spec) |ks|
                if (ks.alts.len > 0) fieldTypeAltLabel(hs, ks.alts[0]) else "any"
            else
                "any";
            const v = if (alt.val_spec) |vs|
                if (vs.alts.len > 0) fieldTypeAltLabel(hs, vs.alts[0]) else "any"
            else
                "any";
            const len = 1 + k.len + 1 + v.len;
            const buf = hs.bump(u8, len) orelse break :blk "map";
            buf[0] = '[';
            @memcpy(buf[1 .. 1 + k.len], k);
            buf[1 + k.len] = ']';
            @memcpy(buf[2 + k.len .. len], v);
            break :blk buf[0..len];
        },
        .type_param => alt.param_name,
    };
}

pub fn varDecl(c: anytype, has_keyword: bool, is_const: bool) !void {
    if (has_keyword and c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const name = c.cur;
    if (name.typ == .ident and c.isKnownTypeName(name.src))
        return c.err("'{s}' is a type name and cannot be used as a variable name", .{name.src});
    c.advance();
    var inferred_type_check: TypeCheck = .{ .none = {} };
    var inferred_named_type: ?[]const u8 = null; // named type inferred from := RHS
    var inferred_struct_type: ?[]const u8 = null; // struct type inferred from := RHS (#210)
    var self_ref_slot: ?u8 = null;
    var compile_time_const: ?ct.CompileTimeConst = null;
    if (c.match(.colon_eq) or c.match(.eq)) {
        if (is_const and !c.inFunc() and !c.in_loop_init and c.loop_body_depth == 0) {
            compile_time_const = try compiler_decls.parseCompileTimeConst(c);
        }
        // Self-reference pre-allocation: if the RHS is a function literal and we are
        // inside a function, pre-push null and register the local BEFORE compiling the
        // RHS. This allows the inner closure's capture to find the local in scope (so it
        // uses get_upvalue instead of get_global). make_closure converts the null slot
        // to a heap cell; the subsequent set_local stores the closure into that cell,
        // giving the upvalue a valid self-reference from the start.
        if (c.cur.typ == .kw_func and c.inFunc()) {
            try c.cs.emitOp(.null_val, name.line);
            const sr = try c.defineLocal(name.src, is_const);
            c.currentScope().locals[sr].type_check = inferred_type_check;
            if (c.std_namespace_path != null) {
                c.currentScope().locals[sr].from_std = true;
                c.currentScope().locals[sr].std_namespace_path = c.std_namespace_path.?;
            }
            if (c.import_module_path) |path| {
                c.currentScope().locals[sr].import_module_path = path;
            }
            self_ref_slot = sr;
        } else if (c.cur.typ == .kw_func and !c.inFunc()) {
            // Top-level `name := func(params) {}` doesn't go through namedFuncDecl,
            // so pending_func_qname is never set. Set it here so compileFuncWithPrefix
            // pushes the sig onto in_progress_sigs before the body compiles, enabling
            // recursive self-calls to resolve arg types and set the 0x80 proven flag.
            c.pending_func_qname = try c.qualifyGlobalName(name.src);
        }
        try c.expr();
        // Infer named type from constructor call: d := Meters(5) → used for TypeCheck on the local.
        // childExprPrimInfo reads depth+1 — where the child expr() wrote its result.
        // Stored separately so inferred_type_check stays .none (avoiding spurious code emission).
        if (inferred_type_check == .none) {
            const rhs_info = c.childExprPrimInfo();
            inferred_named_type = rhs_info.named_type;
            if (inferred_named_type == null) inferred_struct_type = rhs_info.struct_type;
        }
        if (self_ref_slot != null) {
            try c.cs.emit2(@intFromEnum(Op.set_local), self_ref_slot.?, name.line);
        }
    } else if (c.cur.typ == .lbracket) {
        const ts = try c.parseFieldTypeSpec();
        const is_map = ts.alts.len > 0 and ts.alts[0].typ == .map;
        const type_label = if (ts.alts.len > 0) fieldTypeAltLabel(c.hs, ts.alts[0]) else if (is_map) "map" else "array";
        const nt = c.hs.allocObject() orelse return error.OutOfMemory;
        if (is_map) {
            nt.* = .{ .named_type = .{
                .name = type_label,
                .qualified_name = type_label,
                .base = .map_t,
                .is_anonymous = true,
                .key_spec = ts.alts[0].key_spec,
                .val_spec = ts.alts[0].val_spec,
            } };
        } else {
            nt.* = .{ .named_type = .{
                .name = type_label,
                .qualified_name = type_label,
                .base = .array_t,
                .is_anonymous = true,
                .elem_spec = ts.alts[0].elem_spec,
            } };
        }
        try c.cs.emitConst(.{ .object = nt }, name.line);
        const type_const_idx = c.cs.last_const_idx;
        if (c.match(.eq)) {
            try c.expr();
        } else if (has_keyword and !is_const) {
            if (is_map) {
                try c.cs.emit2(@intFromEnum(Op.build_map), 0, name.line);
            } else {
                try c.cs.emit2(@intFromEnum(Op.build_array), 0, name.line);
            }
        } else {
            return c.err("expected '=', found {s}", .{c.tokenName(c.cur.typ)});
        }
        inferred_type_check = .{ .anon_typed = type_const_idx };
        try c.cs.emitCall(1, name.line);
    } else if (c.cur.typ == .kw_func) {
        _ = try c.parseFieldTypeSpec();
        if (c.match(.eq)) {
            try c.expr();
        } else if (has_keyword and !is_const) {
            try c.cs.emitOp(.null_val, name.line);
        } else {
            return c.err("expected '=', found {s}", .{c.tokenName(c.cur.typ)});
        }
    } else if (c.cur.typ == .ident or c.cur.typ == .question) {
        const type_name = if (c.cur.typ == .ident) c.cur.src else "";
        const type_spec = try c.parseFieldTypeSpec();
        // Module-qualified types carry their canonical runtime identity in the
        // FieldTypeSpec, which need not use the source-module `@mod:` prefix.
        const resolved_mod_type: bool = blk: {
            if (type_spec.alts.len == 0) break :blk false;
            const alt = type_spec.alts[0];
            switch (alt.typ) {
                .named_t, .variant_t => if (alt.named_name.len > 0 and alt.named_name[0] == '@') {
                    inferred_type_check = .{ .named = alt.named_name };
                    break :blk true;
                },
                .struct_t => if (alt.struct_name.len > 0 and alt.struct_name[0] == '@') {
                    inferred_type_check = .{ .struct_type = alt.struct_name };
                    break :blk true;
                },
                .interface_t => if (alt.interface_name.len > 0 and alt.interface_name[0] == '@') {
                    inferred_type_check = .{ .interface_type = alt.interface_name };
                    break :blk true;
                },
                else => {},
            }
            break :blk false;
        };
        if (!resolved_mod_type) {
            if (common.streq(type_name, "int") or common.streq(type_name, "float") or common.streq(type_name, "bool")) {
                if (common.streq(type_name, "int")) {
                    inferred_type_check = .{ .prim = .int };
                } else if (common.streq(type_name, "float")) {
                    inferred_type_check = .{ .prim = .float };
                } else {
                    inferred_type_check = .{ .prim = .bool };
                }
            } else if (type_name.len > 0 and c.registry.hasNamedType(type_name)) {
                inferred_type_check = .{ .named = try c.qualifyTypeName(type_name) };
            } else if (common.streq(type_name, "string")) {
                inferred_type_check = .{ .prim = .string };
            } else if (common.streq(type_name, "rune")) {
                inferred_type_check = .{ .prim = .rune };
            } else if (common.streq(type_name, "bigint")) {
                inferred_type_check = .{ .prim = .bigint };
            } else if (common.streq(type_name, "array")) {
                return c.err("use '[]T' syntax for array types", .{});
            } else if (common.streq(type_name, "map")) {
                inferred_type_check = c.typeCheckFromFieldTypeSpec(type_spec);
            } else if (common.streq(type_name, "error")) {
                inferred_type_check = .{ .assert_err = {} };
            } else if (common.streq(type_name, "actor")) {
                inferred_type_check = .{ .assert_actor_ref = {} };
            } else if (c.registry.hasInterfaceType(type_name)) {
                inferred_type_check = .{ .interface_type = type_name };
            } else if (c.registry.hasStructTypeLocal(type_name)) {
                inferred_type_check = .{ .struct_type = type_name };
            } else if (type_name.len == 0) {
                // No type check for nullable type
            } else {
                return {
                    c.setErr("unknown type name '{s}'", .{type_name});
                    return error.UnknownTypeName;
                };
            }
        }
        // Named-type constructor must be pushed before the argument value
        // because performCall expects the callee at stack[top - argc - 1].
        // Enums with an initializer skip the push entirely: enum types are
        // not constructors (the call would be NotAFunction). The no-init
        // zero-default path still needs the type object on the stack — its
        // enum branch reads the first member off it via get_field.
        if (inferred_type_check == .named and
            !(c.check(.eq) and c.isEnumTypeName(inferred_type_check.named)))
        {
            try c.cs.emitGetGlobal(inferred_type_check.named, name.line);
        }
        if (c.match(.eq)) {
            try c.expr();
            if (inferred_type_check == .prim) {
                switch (inferred_type_check.prim) {
                    .int => {
                        // Reject float literal assigned to int at compile time
                        if (c.cs.code_len >= 3) {
                            const last_inst_start = c.cs.code_len - 3;
                            if (c.cs.code[last_inst_start] == @intFromEnum(Op.constant)) {
                                const idx = (@as(u16, c.cs.code[last_inst_start + 1]) << 8) | c.cs.code[last_inst_start + 2];
                                if (idx < c.cs.const_count and c.cs.consts[idx] == .float) {
                                    return c.err("float literal cannot be assigned to int without explicit conversion", .{});
                                }
                            }
                        }
                        try c.cs.emitOp(.cast_int, name.line);
                    },
                    .float => try c.cs.emitOp(.cast_float, name.line),
                    .decimal => try c.cs.emitOp(.cast_decimal, name.line),
                    .bool => try c.cs.emitOp(.cast_bool, name.line),
                    .string => try c.cs.emitOp(.cast_string, name.line),
                    .rune => try c.cs.emitOp(.cast_rune, name.line),
                    .bigint => try c.cs.emitOp(.cast_bigint, name.line),
                }
            } else if (inferred_type_check == .named) {
                // Enums: no constructor call — no type object was pushed.
                if (!c.isEnumTypeName(inferred_type_check.named)) {
                    try c.cs.emitCall(1, name.line);
                }
            } else if (inferred_type_check == .assert_map) {
                try c.cs.emit2(@intFromEnum(Op.assert_type), 2, name.line);
            } else if (inferred_type_check == .assert_err) {
                try c.cs.emit2(@intFromEnum(Op.assert_type), 3, name.line);
            } else if (inferred_type_check == .interface_type) {
                const idx = try c.cs.addStringConst(inferred_type_check.interface_type);
                try c.cs.emitConstIdx(.assert_interface, idx, name.line);
            } else if (inferred_type_check == .struct_type) {
                const idx = try c.cs.addStringConst(inferred_type_check.struct_type);
                try c.cs.emitConstIdx(.assert_struct, idx, name.line);
            }
        } else if (has_keyword and !is_const and inferred_type_check != .none) {
            if (inferred_type_check == .named) {
                // The type object is already on the stack (emitGetGlobal above).
                // For enum types, construct the zero value by accessing the first member
                // directly via field access — calling the enum type as a constructor is
                // only valid for enum subtypes, not plain enums.
                const ti = c.registry.getNamedTypeInfo(inferred_type_check.named);
                if (ti != null and ti.?.base == .enum_t) {
                    const members = ti.?.enum_members orelse &[_][]const u8{};
                    if (members.len > 0) {
                        try c.cs.emitGetField(members[0], name.line);
                    } else {
                        try c.cs.emitOp(.pop, name.line);
                        try c.cs.emitOp(.null_val, name.line);
                    }
                } else {
                    try c.emitNamedDefault(inferred_type_check.named, name.line);
                    try c.cs.emitCall(1, name.line);
                }
            } else {
                try c.emitZeroValue(inferred_type_check, name.line);
            }
        } else if (has_keyword and !is_const and inferred_type_check == .none) {
            try c.cs.emitOp(.null_val, name.line);
        } else {
            return c.err("expected '=', found {s}", .{c.tokenName(c.cur.typ)});
        }
    } else {
        return c.err("expected expression, found {s}", .{c.tokenName(c.cur.typ)});
    }
    if (c.inFunc() or c.in_loop_init or c.loop_body_depth > 0) {
        if (self_ref_slot == null) {
            const slot = try c.defineLocal(name.src, is_const);
            c.currentScope().locals[slot].type_check = if (inferred_type_check != .none)
                inferred_type_check
            else if (inferred_named_type) |nt|
                .{ .named = nt }
            else if (inferred_struct_type) |st|
                .{ .struct_type = st }
            else
                inferred_type_check;
            if (c.std_namespace_path != null) {
                c.currentScope().locals[slot].from_std = true;
                c.currentScope().locals[slot].std_namespace_path = c.std_namespace_path.?;
            }
            if (c.import_module_path) |path| {
                c.currentScope().locals[slot].import_module_path = path;
            }
            if (!c.inFunc()) {
                try c.cs.emitOp(.dup, name.line);
                try c.cs.emit2(@intFromEnum(Op.set_local), slot, name.line);
            }
        }
    } else {
        if (!is_const and c.registry.hasGlobalConst(name.src)) {
            c.setErr("cannot assign to const variable '{s}'", .{name.src});
            return error.AssignToConst;
        }
        if (c.options.check_global_is_const) |f| {
            if (f(c.options.check_global_ctx.?, name.src)) {
                if (is_const) {
                    c.setErr("cannot redeclare const '{s}'", .{name.src});
                } else {
                    c.setErr("cannot assign to const variable '{s}'", .{name.src});
                }
                return error.AssignToConst;
            }
        }
        const qname = try c.qualifyGlobalName(name.src);
        if (!c.skipping_test_body and c.registry.hasGlobalFunc(qname)) {
            c.setErr("name '{s}' already declared as a function", .{name.src});
            return error.DuplicateGlobal;
        }
        if (c.options.repl_mode and inferred_type_check != .none) {
            if (c.options.check_global_exists) |checker| {
                if (checker(c.options.check_global_ctx.?, qname)) {
                    c.setErr("cannot redeclare global '{s}' with a different type", .{name.src});
                    return error.RedeclareGlobal;
                }
            }
        }
        try c.cs.emitOpStringConst(.def_global, qname, name.line);
        if (!c.skipping_test_body) {
            if (inferred_type_check != .none) {
                if (c.typed_global_count >= MaxLocals) {
                    c.setErr("too many typed globals (limit {d})", .{MaxLocals});
                    return error.TooManyGlobals;
                }
                c.typed_global_names[c.typed_global_count] = qname;
                c.typed_global_type_checks[c.typed_global_count] = inferred_type_check;
                c.typed_global_count += 1;
            } else if (inferred_named_type) |nt| {
                // :=-inferred named-type globals go into the inferred array, not typed_global_type_checks.
                // This enables TypeMismatch detection without causing assignStmt to emit prolog/epilog.
                if (c.inferred_named_global_count >= MaxLocals) {
                    c.setErr("too many typed globals (limit {d})", .{MaxLocals});
                    return error.TooManyGlobals;
                }
                c.inferred_named_global_names[c.inferred_named_global_count] = qname;
                c.inferred_named_global_types[c.inferred_named_global_count] = nt;
                c.inferred_named_global_count += 1;
            } else if (inferred_struct_type) |st| {
                // Same idea for :=-inferred struct-typed globals (#210): needed so a
                // dunder method is reachable from a top-level `a := Vec3{...}` read.
                if (c.inferred_struct_global_count >= MaxLocals) {
                    c.setErr("too many typed globals (limit {d})", .{MaxLocals});
                    return error.TooManyGlobals;
                }
                c.inferred_struct_global_names[c.inferred_struct_global_count] = qname;
                c.inferred_struct_global_types[c.inferred_struct_global_count] = st;
                c.inferred_struct_global_count += 1;
            }
            if (c.std_namespace_path != null) {
                if (c.std_module_global_count >= MaxLocals) {
                    c.setErr("too many std-module globals (limit {d})", .{MaxLocals});
                    return error.TooManyGlobals;
                }
                c.std_module_global_names[c.std_module_global_count] = qname;
                c.std_module_global_paths[c.std_module_global_count] = c.std_namespace_path.?;
                c.std_module_global_count += 1;
            }
            if (c.import_module_path) |path| {
                if (c.import_module_global_count >= MaxLocals) {
                    c.setErr("too many imported-module globals (limit {d})", .{MaxLocals});
                    return error.TooManyGlobals;
                }
                c.import_module_global_qnames[c.import_module_global_count] = qname;
                c.import_module_global_paths[c.import_module_global_count] = path;
                c.import_module_global_count += 1;
            }
            if (is_const) try c.registry.addGlobalConst(name.src);
            if (compile_time_const) |value| try c.addCompileTimeConst(name.src, value);
        }
    }
    c.matchOpt(.semicolon);
}

pub fn whileForStmt(c: anytype) anyerror!void {
    const loop_start = c.cs.codeLen();
    try c.pushLoop(loop_start, c.loopKeepBase(), c.loopKeepBase(), 0);
    const infinite = c.check(.lbrace);
    var exit_j: usize = 0;
    if (!infinite) {
        try c.expr();
        try checkBoolCondition(c);
        try c.consume(.lbrace);
        exit_j = try c.cs.emitJump(.jif_pop, c.prev.line);
    } else {
        try c.consume(.lbrace);
    }
    try block(
        c,
    );
    try c.cs.emitLoop(loop_start, c.prev.line);
    if (!infinite) try c.cs.patchJump(exit_j);
    const loop = c.popLoop();
    for (loop.break_offsets[0..loop.break_count]) |off| try c.cs.patchJump(off);
}
