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
const std_schema = @import("std_schema.zig");

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

pub fn assertStmt(c: anytype) !void {
    const line = c.prev.line;
    try c.expr();
    if (c.match(.comma)) {
        try c.expr();
        try chunk.emitOp(.op_assert_msg, line);
    } else {
        try chunk.emitOp(.op_assert, line);
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
        try chunk.emitOp(.pop, name.line);
        c.matchOpt(.semicolon);
        return;
    }
    try c.ensureMutableBinding(name);
    c.advance();
    try c.consume(.eq);
    const tc = c.getLocalTypeCheck(name.src);
    if (tc) |t| try c.emitVarTypeProlog(t, name.line);
    try c.expr();
    if (tc) |t| try c.emitVarTypeEpilog(t, name.line);
    try c.emitSetVar(name);
    c.matchOpt(.semicolon);
}

pub fn block(c: anytype) anyerror!void {
    const saved = c.repl_expr_ok;
    c.repl_expr_ok = false;
    const local_base: u8 = c.currentScope().local_count;
    while (!c.check(.rbrace) and !c.check(.eof)) try c.decl();
    try c.consume(.rbrace);
    try c.cleanupLocals(local_base, c.prev.line);
    c.repl_expr_ok = saved;
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
        try assignStmt(c, );
    } else {
        try c.expr();
        try chunk.emitOp(.pop, c.prev.line);
        try c.consume(.semicolon);
    }
    c.in_loop_init = false;

    var loop_start = chunk.codeLen();
    var exit_j: ?usize = null;

    if (!c.match(.semicolon)) {
        try c.expr();
        try c.consume(.semicolon);
        exit_j = try chunk.emitJump(.jif_pop, c.prev.line);
    }

    if (!c.check(.lbrace)) {
        const body_j = try chunk.emitJump(.jump, c.prev.line);
        const post_start = chunk.codeLen();
        if (c.check(.ident) and (c.peekTT() == .plus_plus or c.peekTT() == .minus_minus)) {
            try incrStmt(c, );
        } else if (c.check(.ident) and c.peekTT() == .eq) {
            try assignStmt(c, );
        } else if (c.check(.ident)) {
            const ptt = c.peekTT();
            if (ptt == .plus_eq or ptt == .minus_eq or ptt == .star_eq or ptt == .slash_eq or ptt == .percent_eq or ptt == .amp_eq or ptt == .pipe_eq or ptt == .caret_eq or ptt == .lt_lt_eq or ptt == .gt_gt_eq) {
                try compoundStmt(c, );
            } else {
                try c.expr();
                try chunk.emitOp(.pop, c.prev.line);
            }
        } else {
            try c.expr();
            try chunk.emitOp(.pop, c.prev.line);
        }
        try chunk.emitLoop(loop_start, c.prev.line);
        loop_start = post_start;
        try chunk.patchJump(body_j);
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
    try block(c, );
    c.loop_body_depth -= 1;
    for (c.currentLoop().loop_var_slots[0..c.currentLoop().loop_var_count]) |slot| {
        try chunk.emit2(@intFromEnum(Op.close_upvalue), slot, c.prev.line);
    }
    try chunk.emitLoop(loop_start, c.prev.line);

    if (exit_j) |j| {
        try chunk.patchJump(j);
    }

    if (!c.inFunc()) {
        var li: u8 = 0;
        while (li < c.currentLoop().loop_var_count) : (li += 1) {
            const slot = c.currentLoop().loop_var_slots[li];
            try chunk.emit2(@intFromEnum(Op.get_local), slot, c.prev.line);
            try chunk.emitOpConst(.def_global, .{ .string = try c.qualifyGlobalName(c.currentLoop().loop_var_names[li]) }, c.prev.line);
            try chunk.emitOp(.pop, c.prev.line);
        }
        c.currentScope().local_count = local_base;
    }
    try c.cleanupLocals(local_base, c.prev.line);

    const loop = c.popLoop();
    var i: usize = 0;
    while (i < loop.break_count) : (i += 1) {
        try chunk.patchJump(loop.break_offsets[i]);
    }
}

pub fn compileFuncWithPrefix(c: anytype, prefix: []const []const u8, is_named: bool, predicate_base: ?NamedTypeBase) anyerror!u8 {
    try c.consume(.lparen);
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

    if (prefix.len > MaxLocals) { c.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
    var pi0: usize = 0;
    while (pi0 < prefix.len) : (pi0 += 1) {
        if (c.isKnownTypeName(prefix[pi0]))
            return c.err("'{s}' is a type name and cannot be used as a receiver name", .{prefix[pi0]});
        param_names[arity] = prefix[pi0];
        param_types[arity] = any_spec;
        arity += 1;
    }

    if (!c.check(.rparen)) {
        while (true) {
            if (arity >= MaxLocals) { c.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
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
                    const alt = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
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
            if (c.cur.typ != .question and c.cur.typ != .ident and c.cur.typ != .kw_func and c.cur.typ != .lbracket) { c.setErr("expected type annotation, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedTypeAnnotation; }
            const ptype: FieldTypeSpec = try c.parseFieldTypeSpec();
            param_types[arity - 1] = ptype;
            if (vari) {
                is_variadic = true;
                variadic_type = ptype;
                break;
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
        const alt = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        alt[0] = .{ .typ = .boolean };
        return_types[0] = .{ .alts = alt[0..1] };
        return_count = 1;
        has_typed_returns = true;
    } else if (c.match(.lparen)) {
        // Detect named vs anonymous: named if first entry is 'ident type_start'.
        const is_named_returns = c.cur.typ == .ident and
            (c.peekToken().typ == .ident or c.peekToken().typ == .question or c.peekToken().typ == .kw_func or c.peekToken().typ == .lbracket);
        while (true) {
            if (return_count >= MaxLocals) { c.setErr("too many return types (max {d})", .{MaxLocals}); return error.TooManyParams; }
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

    const jump_over = try chunk.emitJump(.jump, c.prev.line);
    const func_ip = chunk.codeLen();

    if (c.scope_depth >= MaxScopes) return error.TooManyNestedFunctions;
    c.scopes[c.scope_depth] = .{};
    c.scope_depth += 1;
    const scope = c.currentScope();
    scope.is_named = is_named;
    scope.has_typed_returns = has_typed_returns;

    var pi: u8 = 0;
    while (pi < arity) : (pi += 1) {
        var pdi: u8 = 0;
        while (pdi < pi) : (pdi += 1) {
            if (common.streq(scope.locals[pdi].name, param_names[pi])) {
                c.setErr("duplicate parameter name '{s}'", .{param_names[pi]});
                return error.DuplicateLocal;
            }
        }
        scope.locals[pi] = .{ .name = param_names[pi], .is_const = param_const[pi] };
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
        var ri: u8 = 0;
        while (ri < named_return_count) : (ri += 1) {
            var rdi: u8 = 0;
            while (rdi < arity + ri) : (rdi += 1) {
                if (common.streq(scope.locals[rdi].name, return_names[ri])) {
                    c.setErr("named return '{s}' conflicts with existing local binding", .{return_names[ri]});
                    return error.DuplicateLocal;
                }
            }
            const rc: TypeCheck = if (return_types[ri].alts.len == 1) blk: {
                switch (return_types[ri].alts[0].typ) {
                    .int => break :blk .{ .prim = .int },
                    .float => break :blk .{ .prim = .float },
                    .decimal_t => break :blk .{ .prim = .decimal },
                    .boolean => break :blk .{ .prim = .bool },
                    .string => break :blk .{ .prim = .string },
                    .rune_t => break :blk .{ .prim = .rune },
                    .named_t => break :blk .{ .named = return_types[ri].alts[0].named_name },
                    .array => break :blk .{ .assert_arr = {} },
                    .map => break :blk .{ .assert_map = {} },
                    .error_t => break :blk .{ .assert_err = {} },
                    else => break :blk .{ .none = {} },
                }
            } else .{ .none = {} };
            scope.locals[arity + ri] = .{ .name = return_names[ri], .is_const = false, .type_check = rc };
            scope.local_count += 1;
            const rt = return_types[ri];
            if (rt.alts.len == 1) {
                switch (rt.alts[0].typ) {
                    .int =>
                        try chunk.emitConst(.{ .int = 0.0 }, @intCast(func_ip)),
                    .float =>
                        try chunk.emitConst(.{ .float = 0.0 }, @intCast(func_ip)),
                    .rune_t =>
                        try chunk.emitConst(.{ .rune = 0 }, @intCast(func_ip)),
                    .decimal_t =>
                        try chunk.emitConst(.{ .decimal = 0 }, @intCast(func_ip)),
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

    try c.consume(.lbrace);
    const saved = c.repl_expr_ok;
    c.repl_expr_ok = false;
    const body_local_base: u8 = arity + named_return_count;
    while (!c.check(.rbrace) and !c.check(.eof)) try c.decl();
    try c.consume(.rbrace);
    c.repl_expr_ok = saved;
    try c.cleanupLocals(body_local_base, c.prev.line);

    // Implicit return: bare named returns or null.
    try emitImplicitReturn(scope, c.prev.line);
    try chunk.emitOp(.ret, c.prev.line);

    c.scope_depth -= 1;
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
    c.last_func_obj = func_obj;
    if (predicate_base == null) {
        const cidx: u16 = try chunk.addConst(.{ .object = func_obj });
        try chunk.emitConstIdx(.make_closure, cidx, c.prev.line);
    }
    return uv_count;
}

pub fn compoundStmt(c: anytype) !void {
    const name = c.cur;
    try c.ensureMutableBinding(name);
    c.advance();
    const op_tok = c.cur;
    c.advance();
    try c.emitGetVar(name);
    try c.expr();
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
        else => return c.err("unsupported compound assignment operator", .{}),
    };
    try chunk.emitOp(op, op_tok.line);
    const tc = c.getLocalTypeCheck(name.src);
    if (tc) |t| try c.emitVarTypeEpilog(t, op_tok.line);
    try c.emitSetVar(name);
    c.matchOpt(.semicolon);
}

pub fn declareLoopVar(c: anytype, name: Token) !void {
    if (c.isKnownTypeName(name.src))
        return c.err("'{s}' is a type name and cannot be used as a loop variable name", .{name.src});
    try chunk.emitOp(.null_val, name.line);
    _ = try c.defineLocal(name.src, false);
}

pub fn deferStmt(c: anytype) !void {
    if (!c.inFunc()) { c.setErr("'defer' outside of function", .{}); return error.DeferOutsideFunction; }
    // Parse the callee: a primary expression followed by any chain of
    // .prop and [index] accesses, stopping before the outermost call '('.
    c.advance();
    const pfx = c.prev.typ;
    switch (pfx) {
        .ident => try c.varExpr(c.prev),
        .kw_func => try funcLit(c, ),
        .lparen => {
            try c.expr();
            try c.consume(.rparen);
        },
        .lbrace => {
            try compileDeferBlock(c);
            try chunk.emit2(@intFromEnum(Op.defer_call), 0, c.prev.line);
            c.matchOpt(.semicolon);
            return;
        },
        .err_invalid_char => return error.InvalidChar,
        .err_unterminated_string => { c.setErr("unterminated string literal", .{}); return error.UnterminatedString; },
        .err_string_pool_exhausted => { c.setErr("string pool exhausted (max {d}KB)", .{@import("lexer.zig").StrPoolSize / 1024}); return error.UnterminatedString; },
        else => { c.setErr("expected expression, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedExpression; },
    }
    // Consume chained .prop and [index]; when .prop( is seen it's a deferred method call.
    while (true) {
        if (c.cur.typ == .lbracket) {
            const line = c.cur.line;
            c.advance();
            try c.expr();
            try c.consume(.rbracket);
            try chunk.emitOp(.get_index, line);
        } else if (c.cur.typ == .dot) {
            c.advance();
            if (c.cur.typ != .ident) { c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedPropertyName; }
            const prop = c.cur;
            c.advance();
            if (c.cur.typ == .lparen) {
                c.advance(); // consume '('
                var argc: u8 = 0;
                if (!c.check(.rparen)) {
                    while (true) {
                        if (argc == 255) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                        try c.expr();
                        argc += 1;
                        if (!c.match(.comma)) break;
                        if (c.check(.rparen)) break;
                    }
                }
                try c.consume(.rparen);
                try chunk.emitDeferInvokeMethod(prop.src, argc, prop.line);
                c.matchOpt(.semicolon);
                return;
            }
            try chunk.emitGetField(prop.src, prop.line);
        } else {
            break;
        }
    }
    // Deferred regular call.
    if (!c.match(.lparen)) { c.setErr("'defer' requires a function call expression", .{}); return error.DeferRequiresCall; }
    const call_line = c.prev.line;
    var argc: u8 = 0;
    if (!c.check(.rparen)) {
        while (true) {
            if (argc == 255) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
            try c.expr();
            argc += 1;
            if (!c.match(.comma)) break;
        }
    }
    try c.consume(.rparen);
    try chunk.emit2(@intFromEnum(Op.defer_call), argc, call_line);
    c.matchOpt(.semicolon);
}

pub fn emitAssignTargetPath(c: anytype, target: AssignTarget, all_steps: []const AssignTargetStep) !void {
    const vidx: u16 = try chunk.addConst(.{ .string = MultiAssignValueScratch });
    if (target.step_count == 0) {
        try chunk.emitGetGlobalIdx(vidx, target.root.line);
        try c.emitSetVar(target.root);
        return;
    }

    try c.emitGetVar(target.root);
    var i: u8 = 0;
    while (i + 1 < target.step_count) : (i += 1) {
        const st = all_steps[target.step_start + i];
        switch (st) {
            .dot_name => |name| try chunk.emitGetField(name, target.root.line),
            .index_number => |n| {
                try chunk.emitConst(.{ .int = n }, target.root.line);
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
            try chunk.emitConst(.{ .int = n }, target.root.line);
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

pub fn emitExprListTuple(c: anytype) !u8 {
    var count: u8 = 0;
    try c.expr();
    count += 1;
    while (c.match(.comma)) {
        if (count == 255) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
        try c.expr();
        count += 1;
    }
    if (count > 1) try chunk.emit2(@intFromEnum(Op.build_tuple), count, c.prev.line);
    return count;
}

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

fn compileDeferBlock(c: anytype) !void {
    // c.prev is '{' (consumed by deferStmt's advance()), c.cur is first token inside block.
    // Desugars `defer { ... }` to the equivalent of `defer (func() { ... })()`:
    // compile the block as a parameterless closure and emit defer_call 0.
    const jump_over = try chunk.emitJump(.jump, c.prev.line);
    const func_ip = chunk.codeLen();

    if (c.scope_depth >= MaxScopes) return error.TooManyNestedFunctions;
    c.scopes[c.scope_depth] = .{};
    c.scope_depth += 1;

    const saved = c.repl_expr_ok;
    c.repl_expr_ok = false;
    while (!c.check(.rbrace) and !c.check(.eof)) try c.decl();
    try c.consume(.rbrace);
    c.repl_expr_ok = saved;

    try c.cleanupLocals(0, c.prev.line);

    const scope = c.currentScope();
    try emitImplicitReturn(scope, c.prev.line);
    try chunk.emitOp(.ret, c.prev.line);

    c.scope_depth -= 1;
    try chunk.patchJump(jump_over);

    const uv_count = scope.upvalue_count;
    const slots = heap.bump(u8, uv_count) orelse return error.OutOfMemory;
    var ui: u8 = 0;
    while (ui < uv_count) : (ui += 1) {
        const uv = scope.upvalues[ui];
        const flag: u8 = if (uv.from_upvalue) @as(u8, 0x80) else @as(u8, 0x00);
        slots[ui] = flag | uv.index;
    }

    const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
    any_alts[0] = .{ .typ = .any };
    const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

    const func_obj = heap.allocObject() orelse return error.OutOfMemory;
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

    const cidx: u16 = try chunk.addConst(.{ .object = func_obj });
    try chunk.emitConstIdx(.make_closure, cidx, c.prev.line);
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
    try chunk.emitOp(.iter_init, c.prev.line);
    // Claim a hidden local slot for the iterator so that body locals land on the
    // correct stack offsets. Without this, body-local slot N resolves to the iterator
    // object instead of the actual value.
    c.currentScope().local_count += 1;
    const body_keep: u8 = c.currentScope().local_count;

    const loop_start = chunk.codeLen();
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
    try chunk.emitOp(if (vname == null) .iter_next1 else .iter_next2, c.prev.line);
    const exit_j = try chunk.emitJump(.jif_pop, c.prev.line);

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
    try block(c, );
    c.loop_body_depth -= 1;
    for (c.currentLoop().loop_var_slots[0..c.currentLoop().loop_var_count]) |slot| {
        try chunk.emit2(@intFromEnum(Op.close_upvalue), slot, c.prev.line);
    }
    try chunk.emitLoop(loop_start, c.prev.line);

    try chunk.patchJump(exit_j);
    if (!c.inFunc()) try chunk.emitOp(.pop, c.prev.line); // pop iterator (top-level only)
    if (!c.inFunc()) {
        var li: u8 = 0;
        while (li < c.currentLoop().loop_var_count) : (li += 1) {
            const slot = c.currentLoop().loop_var_slots[li];
            try chunk.emit2(@intFromEnum(Op.get_local), slot, c.prev.line);
            try chunk.emitOpConst(.def_global, .{ .string = try c.qualifyGlobalName(c.currentLoop().loop_var_names[li]) }, c.prev.line);
            try chunk.emitOp(.pop, c.prev.line);
        }
        c.currentScope().local_count = local_base;
    }
    try c.cleanupLocals(local_base, c.prev.line);

    const loop = c.popLoop();
    var i: usize = 0;
    while (i < loop.break_count) : (i += 1) {
        try chunk.patchJump(loop.break_offsets[i]);
    }
}

pub fn forStmt(c: anytype) anyerror!void {
    if (isForIn(c, )) {
        try forInStmt(c, );
    } else if (isCStyleFor(c, )) {
        try cForStmt(c, );
    } else {
        try whileForStmt(c, );
    }
}

pub fn funcLit(c: anytype) anyerror!void {
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
    const local_base: u8 = c.currentScope().local_count;

    if (hasInitSemicolon(c, )) {
        if (c.check(.ident) and c.peekTT() == .colon_eq) {
            try varDecl(c, false, false);
        } else if (c.check(.ident) and c.isTypedVarDecl()) {
            try varDecl(c, false, false);
        } else if (c.match(.kw_const)) {
            try varDecl(c, true, true);
        } else if (c.check(.ident) and c.peekTT() == .eq) {
            try assignStmt(c, );
        } else {
            try c.expr();
            try chunk.emitOp(.pop, c.prev.line);
            c.matchOpt(.semicolon);
        }
    }

    try c.expr();
    try c.consume(.lbrace);

    const then_j = try chunk.emitJump(.jif_pop, c.prev.line);
    try block(c, );

    const else_j = try chunk.emitJump(.jump, c.prev.line);
    try chunk.patchJump(then_j);

    if (c.match(.kw_else)) {
        if (c.match(.kw_if)) {
            try ifStmt(c, );
        } else {
            try c.consume(.lbrace);
            try block(c, );
        }
    }
    try chunk.patchJump(else_j);
    try c.cleanupLocals(local_base, c.prev.line);
}

pub fn incrStmt(c: anytype) !void {
    const name = c.cur;
    try c.ensureMutableBinding(name);
    c.advance();
    const is_inc = c.cur.typ == .plus_plus;
    c.advance();
    try c.emitGetVar(name);
    try chunk.emitConst(.{ .int = 1.0 }, name.line);
    try chunk.emitOp(if (is_inc) .add else .sub, name.line);
    const tc = c.getLocalTypeCheck(name.src);
    if (tc) |t| try c.emitVarTypeEpilog(t, name.line);
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
    try chunk.emitOp(.set_index, name.line);
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
            .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq => return saw_path and depth == 0,
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
        var chk: u8 = 0;
        while (chk < count) : (chk += 1) {
            if (names[chk].typ != .ident) continue;
            if (c.isKnownTypeName(names[chk].src))
                return c.err("'{s}' is a type name and cannot be used as a variable name", .{names[chk].src});
        }
        if (c.inFunc()) {
            var pre_i: u8 = 0;
            while (pre_i < count) : (pre_i += 1) {
                if (names[pre_i].typ == .kw_trap) continue;
                try chunk.emitOp(.null_val, names[pre_i].line);
                _ = try c.defineLocal(names[pre_i].src, false);
            }
        }
    } else {
        const parsed = try parseAssignTargetList(c, &targets, &steps);
        count = parsed.target_count;
        step_count = parsed.step_count;
        if (count < 2) return c.err("multi-assign requires at least two targets", .{});
    }

    try c.consume(if (is_decl) .colon_eq else .eq);
    _ = try emitExprListTuple(c, );
    try chunk.emit2(@intFromEnum(Op.tuple_check_arity), count, c.prev.line);

    var i: u8 = 0;
    while (i < count) : (i += 1) {
        if (is_decl) {
            const is_trap_slot = names[i].typ == .kw_trap;
            try chunk.emitOp(.dup, names[i].line);
            try chunk.emit2(@intFromEnum(Op.tuple_get), i, names[i].line);
            if (is_trap_slot) {
                try chunk.emitOp(.op_trap_check, names[i].line);
            } else if (c.inFunc()) {
                try c.emitSetVar(names[i]);
            } else {
                try chunk.emitOpConst(.def_global, .{ .string = try c.qualifyGlobalName(names[i].src) }, names[i].line);
            }
        } else {
            if (targets[i].step_count == 0) try c.ensureMutableBinding(targets[i].root);
            const vidx: u16 = try chunk.addConst(.{ .string = MultiAssignValueScratch });
            try chunk.emitOp(.dup, targets[i].root.line);
            try chunk.emit2(@intFromEnum(Op.tuple_get), i, targets[i].root.line);
            try chunk.emitConstIdx(.def_global, vidx, targets[i].root.line);
            try emitAssignTargetPath(c, targets[i], steps[0..step_count]);
        }
    }
    try chunk.emitOp(.pop, c.prev.line);
    c.matchOpt(.semicolon);
}

pub fn parseAssignTargetList(c: anytype, targets: *[MaxLocals]AssignTarget, steps: *[MaxLocals * 8]AssignTargetStep) !struct { target_count: u8, step_count: u16 } {
    var tcount: u8 = 0;
    var scount: u16 = 0;
    while (true) {
        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
        if (tcount >= MaxLocals) { c.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
        const root = c.cur;
        c.advance();
        const start = scount;

        while (true) {
            if (c.match(.dot)) {
                if (c.cur.typ != .ident) { c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedPropertyName; }
                if (scount >= steps.len) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
                steps[scount] = .{ .dot_name = c.cur.src };
                scount += 1;
                c.advance();
                continue;
            }
            if (c.match(.lbracket)) {
                if (scount >= steps.len) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
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
        if (count >= MaxLocals) { c.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
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
            if (c.cur.typ != .ident) { c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedPropertyName; }
            const prop = c.cur;
            c.advance();
            if (c.check(.eq) or c.check(.plus_eq) or c.check(.minus_eq) or c.check(.star_eq) or c.check(.slash_eq) or c.check(.percent_eq) or c.check(.amp_eq) or c.check(.pipe_eq) or c.check(.caret_eq) or c.check(.lt_lt_eq) or c.check(.gt_gt_eq)) {
                // This is the last step — record name, do NOT push key, break.
                last_kind = .dot_name;
                last_name = prop.src;
                last_line = prop.line;
                break;
            }
            try chunk.emitGetField(prop.src, prop.line);
            continue;
        }

        if (c.match(.lbracket)) {
            try c.expr();
            try c.consume(.rbracket);
            if (c.check(.eq) or c.check(.plus_eq) or c.check(.minus_eq) or c.check(.star_eq) or c.check(.slash_eq) or c.check(.percent_eq) or c.check(.amp_eq) or c.check(.pipe_eq) or c.check(.caret_eq) or c.check(.lt_lt_eq) or c.check(.gt_gt_eq)) {
                last_kind = .bracket;
                break;
            }
            try chunk.emitOp(.get_index, c.prev.line);
            continue;
        }

        return c.err("expected '.' or '[', found {s}", .{c.tokenName(c.cur.typ)});
    }

    const op_tok = c.cur;

    if (c.match(.eq)) {
        try c.expr();
        switch (last_kind) {
            .dot_name => try chunk.emitSetField(last_name, last_line),
            .bracket => try chunk.emitOp(.set_index, c.prev.line),
        }
        c.matchOpt(.semicolon);
        return;
    }

    if (c.match(.plus_eq) or c.match(.minus_eq) or c.match(.star_eq) or c.match(.slash_eq) or c.match(.percent_eq) or c.match(.amp_eq) or c.match(.pipe_eq) or c.match(.caret_eq) or c.match(.lt_lt_eq) or c.match(.gt_gt_eq)) {
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
            else => return c.err("unsupported compound assignment operator", .{}),
        };
        switch (last_kind) {
            .dot_name => {
                // Stack: container. Dup it, read old value with get_field, compute, write back.
                try chunk.emitOp(.dup, op_tok.line);
                try chunk.emitGetField(last_name, last_line);
                try c.expr();
                try chunk.emitOp(op, op_tok.line);
                try chunk.emitSetField(last_name, op_tok.line);
            },
            .bracket => {
                // Stack: container, key. Dup pair, read old value, compute, write back.
                try chunk.emitOp(.dup2, op_tok.line);
                try chunk.emitOp(.get_index, op_tok.line);
                try c.expr();
                try chunk.emitOp(op, op_tok.line);
                try chunk.emitOp(.set_index, op_tok.line);
            },
        }
        c.matchOpt(.semicolon);
        return;
    }

    return c.err("unsupported compound assignment operator", .{});
}

pub fn returnStmt(c: anytype) !void {
    if (!c.inFunc()) { c.setErr("'return' outside of function", .{}); return error.ReturnOutsideFunction; }
    const line = c.prev.line;
    const scope = c.currentScope();
    if (c.check(.rbrace) or c.check(.eof) or c.check(.semicolon)) {
        // Bare return: use named return variables if present, otherwise null.
        try emitImplicitReturn(scope, line);
    } else if (scope.named_return_count > 0) {
        // Named-return function with explicit value(s): assign to the named return
        // slots first so deferred closures can observe and modify them.
        if (scope.named_return_count == 1) {
            try c.expr();
            try c.emitVarTypeEpilog(scope.locals[scope.named_return_base].type_check, line);
            try chunk.emit2(@intFromEnum(Op.set_local), scope.named_return_base, line);
        } else {
            var ri: u8 = 0;
            while (ri < scope.named_return_count) : (ri += 1) {
                if (ri > 0) try c.consume(.comma);
                try c.expr();
                try c.emitVarTypeEpilog(scope.locals[scope.named_return_base + ri].type_check, line);
                try chunk.emit2(@intFromEnum(Op.set_local), scope.named_return_base + ri, line);
            }
        }
        try emitImplicitReturn(scope, line);
    } else {
        if (scope.is_named and !scope.has_typed_returns) { c.setErr("named-return function must declare return types", .{}); return error.MissingReturnType; }
        _ = try emitExprListTuple(c, );
    }
    try chunk.emitOp(.ret, line);
    c.matchOpt(.semicolon);
}

pub fn skipTypeSpec(c: anytype) !void {
    _ = c.match(.question);
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    c.advance();
    while (c.match(.pipe)) {
        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
        c.advance();
    }
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
        try returnStmt(c, );
        return;
    }
    if (c.match(.kw_defer)) {
        try deferStmt(c, );
        return;
    }
    if (c.match(.kw_assert)) {
        try assertStmt(c, );
        return;
    }
    if (c.match(.kw_if)) {
        try ifStmt(c, );
        return;
    }
    if (c.match(.kw_for)) {
        try forStmt(c, );
        return;
    }
    if (c.match(.kw_switch)) {
        try switchStmt(c, );
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
        if ((ptt == .comma or ptt == .dot or ptt == .lbracket) and isMultiAssignEq(c, )) {
            try multiBindStmt(c, false);
            return;
        }
        if (ptt == .plus_plus or ptt == .minus_minus) {
            try incrStmt(c, );
            return;
        }
        if (ptt == .plus_eq or ptt == .minus_eq or ptt == .star_eq or ptt == .slash_eq or ptt == .percent_eq or ptt == .amp_eq or ptt == .pipe_eq or ptt == .caret_eq or ptt == .lt_lt_eq or ptt == .gt_gt_eq) {
            try compoundStmt(c, );
            return;
        }
        if (ptt == .eq) {
            try assignStmt(c, );
            return;
        }
        if ((ptt == .dot or ptt == .lbracket) and isPropertyAssign(c, )) {
            try propertyAssignStmt(c, );
            return;
        }
        if (ptt == .lbracket and isIndexAssign(c, )) {
            try indexAssignStmt(c, );
            return;
        }
    }

    c.repl_expr_ok = saved;
    try c.expr();
    try chunk.emitOp(.pop, c.prev.line);
    if (c.options.repl_mode and c.repl_expr_ok and chunk.codeLen() > 0) {
        c.repl_expr_pop_pos = chunk.codeLen() - 1;
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

    while (!c.check(.rbrace) and !c.check(.eof)) {
        if (c.match(.kw_case)) {
            if (c.check(.dot)) {
                if (is_type_switch) return c.err("'case .arm_name' is a variant pattern and cannot be used in a '.type' switch", .{});
                // Variant arm pattern: case .arm_name { } or case .arm_name(binding) { }
                const dot_line = c.cur.line;
                c.advance(); // consume '.'
                if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
                const arm_name_tok = c.cur;
                c.advance(); // consume arm name
                var binding: ?[]const u8 = null;
                if (c.match(.lparen)) {
                    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
                    binding = c.cur.src;
                    c.advance();
                    try c.consume(.rparen);
                }
                // Emit: dup, variant_check arm_name, jump_if_false [H]
                try chunk.emitOp(.dup, dot_line);
                try chunk.emitOpConst(.variant_check, .{ .string = arm_name_tok.src }, dot_line);
                const next_case = try chunk.emitJump(.jif_pop, dot_line);
                // Handle switch value and optional binding
                const local_before = c.currentScope().local_count;
                if (binding != null) {
                    if (c.isKnownTypeName(binding.?))
                        return c.err("'{s}' is a type name and cannot be used as a binding name", .{binding.?});
                    try chunk.emitOp(.variant_payload, dot_line);
                    if (c.inFunc()) {
                        _ = try c.defineLocal(binding.?, false);
                    } else {
                        try chunk.emitOpConst(.def_global, .{ .string = try c.qualifyGlobalName(binding.?) }, dot_line);
                    }
                } else {
                    try chunk.emitOp(.pop, dot_line); // discard switch value
                }
                try c.consume(.lbrace);
                try block(c, );
                try c.cleanupLocals(local_before, c.prev.line);
                if (end_count >= MaxSwitchJumps) { c.setErr("too many switch cases (max {d})", .{MaxSwitchJumps}); return error.TooManySwitchCases; }
                end_jumps[end_count] = try chunk.emitJump(.jump, c.prev.line);
                end_count += 1;
                try chunk.patchJump(next_case);
            } else {
                // Regular value case: dup switch-val, compare, jif_pop to next case.
                // If matched (no jump), pop the switch-val before running the body so
                // the stack is balanced on the jump-to-end path.
                try chunk.emitOp(.dup, c.prev.line);
                if (is_type_switch) {
                    try c.typeNameLiteral();
                } else {
                    try c.expr();
                }
                try chunk.emitBinOpFused(.eq, c.prev.line);
                const next_case = try chunk.emitJump(.jif_pop, c.prev.line);
                try chunk.emitOp(.pop, c.prev.line); // consume the switch value
                try c.consume(.lbrace);
                try block(c, );
                if (end_count >= MaxSwitchJumps) { c.setErr("too many switch cases (max {d})", .{MaxSwitchJumps}); return error.TooManySwitchCases; }
                end_jumps[end_count] = try chunk.emitJump(.jump, c.prev.line);
                end_count += 1;
                try chunk.patchJump(next_case);
            }
            continue;
        }

        if (c.match(.kw_default)) {
            if (saw_default) { c.setErr("duplicate 'default' case in switch", .{}); return error.DuplicateDefaultCase; }
            saw_default = true;
            // Pop the switch value that is still on the stack when default is reached.
            try chunk.emitOp(.pop, c.prev.line);
            try c.consume(.lbrace);
            try block(c, );
            if (end_count >= MaxSwitchJumps) { c.setErr("too many switch cases (max {d})", .{MaxSwitchJumps}); return error.TooManySwitchCases; }
            end_jumps[end_count] = try chunk.emitJump(.jump, c.prev.line);
            end_count += 1;
            continue;
        }

        return c.err("expected 'case' or 'default', found {s}", .{c.tokenName(c.cur.typ)});
    }

    try c.consume(.rbrace);
    try chunk.emitOp(.pop, c.prev.line);

    var i: usize = 0;
    while (i < end_count) : (i += 1) {
        try chunk.patchJump(end_jumps[i]);
    }
}

pub fn varDecl(c: anytype, has_keyword: bool, is_const: bool) !void {
    if (has_keyword and c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const name = c.cur;
    if (name.typ == .ident and c.isKnownTypeName(name.src))
        return c.err("'{s}' is a type name and cannot be used as a variable name", .{name.src});
    c.advance();
    var inferred_type_check: TypeCheck = .{ .none = {} };
    if (c.match(.colon_eq) or c.match(.eq)) {
        try c.expr();
    } else if (c.cur.typ == .lbracket) {
        const ts = try c.parseFieldTypeSpec();
        const is_map = ts.alts.len > 0 and ts.alts[0].typ == .map;
        const nt = heap.allocObject() orelse return error.OutOfMemory;
        if (is_map) {
            nt.* = .{ .named_type = .{
                .name = "", .qualified_name = "",
                .base = .map_t,
                .key_spec = ts.alts[0].key_spec,
                .val_spec = ts.alts[0].val_spec,
            } };
        } else {
            nt.* = .{ .named_type = .{
                .name = "", .qualified_name = "",
                .base = .array_t,
                .elem_spec = ts.alts[0].elem_spec,
            } };
        }
        try chunk.emitConst(.{ .object = nt }, name.line);
        if (c.match(.eq)) {
            try c.expr();
        } else if (has_keyword and !is_const) {
            if (is_map) {
                try chunk.emit2(@intFromEnum(Op.build_map), 0, name.line);
            } else {
                try chunk.emit2(@intFromEnum(Op.build_array), 0, name.line);
            }
        } else {
            return c.err("expected '=', found {s}", .{c.tokenName(c.cur.typ)});
        }
        inferred_type_check = .{ .none = {} };
        try chunk.emit2(@intFromEnum(Op.call), 1, name.line);
    } else if (c.cur.typ == .kw_func) {
        _ = try c.parseFieldTypeSpec();
        if (c.match(.eq)) {
            try c.expr();
        } else if (has_keyword and !is_const) {
            try chunk.emitOp(.null_val, name.line);
        } else {
            return c.err("expected '=', found {s}", .{c.tokenName(c.cur.typ)});
        }
    } else if (c.cur.typ == .ident or c.cur.typ == .question) {
        const type_name = if (c.cur.typ == .ident) c.cur.src else "";
        _ = try c.parseFieldTypeSpec();
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
        } else if (common.streq(type_name, "array")) {
            return c.err("use '[]T' syntax for array types", .{});
        } else if (common.streq(type_name, "map")) {
            inferred_type_check = .{ .assert_map = {} };
        } else if (common.streq(type_name, "error")) {
            inferred_type_check = .{ .assert_err = {} };
        } else if (c.registry.hasInterfaceType(type_name)) {
            inferred_type_check = .{ .interface_type = type_name };
        } else if (c.registry.hasStructTypeLocal(type_name)) {
            inferred_type_check = .{ .struct_type = type_name };
        } else if (type_name.len == 0 or common.streq(type_name, "any")) {
            // No type check for these types
        } else {
            return { c.setErr("unknown type name '{s}'", .{type_name}); return error.UnknownTypeName; };
        }
        // Named-type constructor must be pushed before the argument value
        // because performCall expects the callee at stack[top - argc - 1].
        if (inferred_type_check == .named) {
            try chunk.emitGetGlobal(inferred_type_check.named, name.line);
        }
        if (c.match(.eq)) {
            try c.expr();
            if (inferred_type_check == .prim) {
                switch (inferred_type_check.prim) {
                    .int => {
                        // Reject float literal assigned to int at compile time
                        if (chunk.g_state.code_len >= 3) {
                            const last_inst_start = chunk.g_state.code_len - 3;
                            if (chunk.g_state.code[last_inst_start] == @intFromEnum(Op.constant)) {
                                const idx = (@as(u16, chunk.g_state.code[last_inst_start + 1]) << 8) | chunk.g_state.code[last_inst_start + 2];
                                if (idx < chunk.g_state.const_count and chunk.g_state.consts[idx] == .float) {
                                    return c.err("float literal cannot be assigned to int without explicit conversion", .{});
                                }
                            }
                        }
                        try chunk.emitOp(.cast_int, name.line);
                    },
                    .float => try chunk.emitOp(.cast_float, name.line),
                    .decimal => try chunk.emitOp(.cast_decimal, name.line),
                    .bool => try chunk.emitOp(.cast_bool, name.line),
                    .string => try chunk.emitOp(.cast_string, name.line),
                    .rune => try chunk.emitOp(.cast_rune, name.line),
                }
            } else if (inferred_type_check == .named) {
                try chunk.emit2(@intFromEnum(Op.call), 1, name.line);
            } else if (inferred_type_check == .assert_map) {
                try chunk.emit2(@intFromEnum(Op.assert_type), 2, name.line);
            } else if (inferred_type_check == .assert_err) {
                try chunk.emit2(@intFromEnum(Op.assert_type), 3, name.line);
            } else if (inferred_type_check == .interface_type) {
                const idx = try chunk.addConst(.{ .string = inferred_type_check.interface_type });
                try chunk.emitConstIdx(.assert_interface, idx, name.line);
            } else if (inferred_type_check == .struct_type) {
                const idx = try chunk.addConst(.{ .string = inferred_type_check.struct_type });
                try chunk.emitConstIdx(.assert_struct, idx, name.line);
            }
        } else if (has_keyword and !is_const and inferred_type_check != .none) {
            if (inferred_type_check == .named) {
                try chunk.emitOp(.null_val, name.line);
                try chunk.emit2(@intFromEnum(Op.call), 1, name.line);
            } else {
                try c.emitZeroValue(inferred_type_check, name.line);
            }
        } else if (has_keyword and !is_const and inferred_type_check == .none) {
            try chunk.emitOp(.null_val, name.line);
        } else {
            return c.err("expected '=', found {s}", .{c.tokenName(c.cur.typ)});
        }
    } else {
        return c.err("expected expression, found {s}", .{c.tokenName(c.cur.typ)});
    }
    if (c.inFunc() or c.in_loop_init or c.loop_body_depth > 0) {
        const slot = try c.defineLocal(name.src, is_const);
        c.currentScope().locals[slot].type_check = inferred_type_check;
        if (c.std_namespace_path != null and c.std_namespace_path.?.len == 0) {
            c.currentScope().locals[slot].from_std = true;
        }
        if (c.import_module_path) |path| {
            c.currentScope().locals[slot].import_module_path = path;
        }
        if (!c.inFunc()) {
            try chunk.emitOp(.dup, name.line);
            try chunk.emit2(@intFromEnum(Op.set_local), slot, name.line);
        }
    } else {
        if (!is_const and c.registry.hasGlobalConst(name.src)) { c.setErr("cannot assign to const variable '{s}'", .{name.src}); return error.AssignToConst; }
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
        try chunk.emitOpConst(.def_global, .{ .string = qname }, name.line);
        if (!c.skipping_test_body) {
            if (inferred_type_check != .none) {
                if (c.typed_global_count >= MaxLocals) {
                    c.setErr("too many typed globals (limit {d})", .{MaxLocals});
                    return error.TooManyGlobals;
                }
                c.typed_global_names[c.typed_global_count] = qname;
                c.typed_global_type_checks[c.typed_global_count] = inferred_type_check;
                c.typed_global_count += 1;
            }
            if (c.std_namespace_path != null and c.std_namespace_path.?.len == 0) {
                if (c.std_module_global_count >= MaxLocals) {
                    c.setErr("too many std-module globals (limit {d})", .{MaxLocals});
                    return error.TooManyGlobals;
                }
                c.std_module_global_names[c.std_module_global_count] = qname;
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
        }
    }
    c.matchOpt(.semicolon);
}

pub fn whileForStmt(c: anytype) anyerror!void {
    const loop_start = chunk.codeLen();
    try c.pushLoop(loop_start, c.loopKeepBase(), c.loopKeepBase(), 0);
    const infinite = c.check(.lbrace);
    var exit_j: usize = 0;
    if (!infinite) {
        try c.expr();
        try c.consume(.lbrace);
        exit_j = try chunk.emitJump(.jif_pop, c.prev.line);
    } else {
        try c.consume(.lbrace);
    }
    try block(c, );
    try chunk.emitLoop(loop_start, c.prev.line);
    if (!infinite) try chunk.patchJump(exit_j);
    const loop = c.popLoop();
    var i: usize = 0;
    while (i < loop.break_count) : (i += 1) {
        try chunk.patchJump(loop.break_offsets[i]);
    }
}
