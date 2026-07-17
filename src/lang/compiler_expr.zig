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
const MaxExprDepth = ct.MaxExprDepth;
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

pub fn arrayLit(c: anytype) !void {
    var count: u8 = 0;
    if (!c.check(.rbracket)) {
        while (true) {
            try expr(
                c,
            );
            if (count == 255) {
                c.setErr("too many elements (max {d})", .{MaxLocals});
                return error.TooManyElements;
            }
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbracket)) break;
        }
    }
    try c.consume(.rbracket);
    try c.cs.emit2(@intFromEnum(Op.build_array), count, c.prev.line);
}

// Returns true for an identifier token that names a concrete, comparable
// type — usable opposite a '.type' expression. Interfaces are excluded
// ('.type' never equals an interface name, since interfaces aren't concrete
// runtime types); unknown names are left for the caller to reject.
fn isTypeNamePrimitive(name: []const u8) bool {
    const prims = [_][]const u8{ "int", "float", "bool", "string", "rune", "decimal", "error", "map", "bigint" };
    for (prims) |p| {
        if (common.streq(name, p)) return true;
    }
    return false;
}

// Validates an already-consumed identifier token as a concrete type name and
// emits the string constant matching what `std.core.type_of` would produce
// for a value of that type — '.type' compares by that same name.
fn validateAndEmitTypeName(c: anytype, name: Token) !void {
    if (!isTypeNamePrimitive(name.src)) {
        if (c.registry.hasInterfaceType(name.src)) {
            c.setErr("'{s}' is an interface, not a concrete type — '.type' never equals an interface name", .{name.src});
            return error.UnexpectedToken;
        }
        if (c.registry.getTypeAlias(name.src)) |alias| {
            // Alias resolves to the target's short name (e.g. "Stack[int]").
            try c.cs.emitStringConst(alias.target_key, name.line);
            return;
        }
        if (!(c.registry.hasNamedType(name.src) or c.registry.hasStructTypeLocal(name.src) or c.registry.hasVariantType(name.src) or c.registry.hasNamedErrorType(name.src))) {
            c.setErr("unknown type name '{s}'", .{name.src});
            return error.UnknownTypeName;
        }
    }
    try c.cs.emitStringConst(name.src, name.line);
}

// Parses a bare type name used opposite a `.type` expression — either as the
// other side of == / != , or as a `case` label in a `.type`-headed switch.
pub fn typeNameLiteral(c: anytype) !void {
    if (c.cur.typ != .ident) {
        c.setErr("expected a type name, found {s}", .{c.tokenName(c.cur.typ)});
        return error.ExpectedTypeName;
    }
    const name = c.cur;
    c.advance();
    try validateAndEmitTypeName(c, name);
}

pub fn expr(c: anytype) !void {
    c.std_namespace_path = null;
    c.cs.clearStdCallPatchPos();
    try parsePrecedence(c, .assign);
}

pub fn importExpr(c: anytype) !void {
    try c.consume(.lparen);
    if (c.cur.typ != .string) {
        c.setErr("expected string literal, found {s}", .{c.tokenName(c.cur.typ)});
        return error.ExpectedStringLiteral;
    }
    const name = c.cur.src;
    c.advance();
    try c.consume(.rparen);
    const ctx = c.options.module_ctx orelse {
        c.setErr("unsupported import module '{s}'", .{name});
        return error.UnsupportedImportModule;
    };
    const resolver = c.options.resolve_import orelse {
        c.setErr("unsupported import module '{s}'", .{name});
        return error.UnsupportedImportModule;
    };
    const mod_name = try resolver(ctx, c.options.module_path, name);
    if (common.streq(name, "std")) {
        c.cs.markStdCallPatchPos();
    }
    try c.cs.emitGetGlobal(mod_name, c.prev.line);
    if (common.streq(name, "std") and common.streq(mod_name, "module:std")) {
        c.std_namespace_path = "";
        c.import_module_path = null;
    } else if (mod_name.len > 5 and std.mem.startsWith(u8, mod_name, "@mod:")) {
        c.import_module_path = mod_name[5..];
        c.std_namespace_path = null;
    } else if (mod_name.len > 5 and std.mem.startsWith(u8, mod_name, "host:")) {
        c.import_module_path = mod_name;
        c.std_namespace_path = null;
    } else if (mod_name.len > 4 and std.mem.startsWith(u8, mod_name, "cap:")) {
        c.import_module_path = mod_name;
        c.std_namespace_path = null;
    }
}

pub fn infixExpr(c: anytype, tt: TT) anyerror!void {
    const line = c.prev.line;
    const col = c.prev.col;

    if (tt == .dot) {
        // Save receiver's named_type before clearing (for static method dispatch in 3b).
        const receiver_info = c.currentExprPrimInfo();
        const receiver_named_type = receiver_info.named_type;
        c.clearCurrentExprPrimInfo();
        if (c.cur.typ == .kw_type) {
            c.advance(); // consume 'type'
            if (receiver_named_type) |nt| {
                // Static: receiver's named type is known at compile time.
                // Pop the receiver and push its type name as a string constant.
                try c.cs.emitOp(.pop, line);
                try c.cs.emitStringConst(nt, line);
            } else {
                try c.cs.emitOp(.type_name, line);
            }
            if (c.check(.eq_eq) or c.check(.bang_eq)) {
                const is_eq = c.cur.typ == .eq_eq;
                c.advance();
                try typeNameLiteral(
                    c,
                );
                try c.cs.emitOp(.eq, line);
                if (!is_eq) try c.cs.emitOp(.not, line);
                return;
            }
            if (c.parsing_switch_scrutinee) {
                c.switch_scrutinee_is_type = true;
                return;
            }
            if (c.require_type_suffix) {
                c.require_type_suffix = false;
                c.type_suffix_consumed = true;
                return;
            }
            c.setErr("'.type' can only be compared with '==' or '!=', or used as a switch scrutinee", .{});
            return error.UnexpectedToken;
        }
        if (!c.cur.typ.isFieldName()) {
            c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)});
            return error.ExpectedPropertyName;
        }
        const prop = c.cur;
        c.advance();
        if (c.match(.lparen)) {
            const is_std_func = c.std_namespace_path != null;
            const std_ns = c.std_namespace_path;
            try c.checkStdNamespaceField(prop.src, line);
            try c.checkImportModuleField(prop.src, line);
            if (is_std_func) {
                if (c.cs.stdCallPatchPos()) |patch_pos| {
                    c.cs.clearStdCallPatchPos();
                    var name_buf: [80]u8 = undefined;
                    const direct_name = if (std_ns != null and std_ns.?.len > 0)
                        std.fmt.bufPrint(&name_buf, "module:std.{s}.{s}", .{ std_ns.?, prop.src }) catch ""
                    else
                        std.fmt.bufPrint(&name_buf, "module:std.{s}", .{prop.src}) catch "";
                    if (direct_name.len > 0) {
                        c.cs.truncateTo(patch_pos);
                        try c.cs.emitGetGlobal(direct_name, prop.line);
                        var argc: u8 = 0;
                        var first_arg_info = c.currentExprPrimInfo();
                        var second_arg_info = first_arg_info;
                        var third_arg_info = first_arg_info;
                        if (!c.check(.rparen)) {
                            while (true) {
                                if (argc <= 2) c.beginExprPrimCapture();
                                try expr(
                                    c,
                                );
                                if (argc == 0) {
                                    first_arg_info = c.endExprPrimCapture();
                                } else if (argc == 1) {
                                    second_arg_info = c.endExprPrimCapture();
                                } else if (argc == 2) {
                                    third_arg_info = c.endExprPrimCapture();
                                }
                                argc += 1;
                                if (!c.match(.comma)) break;
                                if (c.check(.rparen)) break;
                            }
                        }
                        try c.consume(.rparen);
                        if (c.selectStdMathUnaryIntrinsicOp(direct_name, argc)) |intrinsic_op| {
                            c.cs.deleteCodeRange(patch_pos, 5);
                            try c.cs.emitOp(intrinsic_op, prop.line);
                            const result_info = c.stdMathUnaryIntrinsicResultInfo(direct_name, first_arg_info);
                            c.setCurrentExprPrimInfo(result_info);
                            if (result_info.named_type) |nt| try c.emitNamedValidation(.{ .named = nt }, prop.line);
                            return;
                        }
                        if (c.selectStdMathBinaryIntrinsicOp(direct_name, argc)) |intrinsic_op| {
                            c.cs.deleteCodeRange(patch_pos, 5);
                            try c.cs.emitOp(intrinsic_op, prop.line);
                            const result_info = c.stdMathBinaryIntrinsicResultInfo(direct_name, first_arg_info, second_arg_info);
                            c.setCurrentExprPrimInfo(result_info);
                            if (result_info.named_type) |nt| try c.emitNamedValidation(.{ .named = nt }, prop.line);
                            return;
                        }
                        if (c.selectStdMathTernaryIntrinsicOp(direct_name, argc)) |intrinsic_op| {
                            c.cs.deleteCodeRange(patch_pos, 5);
                            try c.cs.emitOp(intrinsic_op, prop.line);
                            const result_info = c.stdMathTernaryIntrinsicResultInfo(direct_name, first_arg_info, second_arg_info, third_arg_info);
                            c.setCurrentExprPrimInfo(result_info);
                            if (result_info.named_type) |nt| try c.emitNamedValidation(.{ .named = nt }, prop.line);
                            return;
                        }
                        if (common.streq(direct_name, "module:std.core.type_of") and argc == 1) {
                            if (first_arg_info.named_type) |nt| {
                                c.cs.deleteCodeRange(patch_pos, 5);
                                try c.cs.emitOp(.pop, prop.line);
                                try c.cs.emitStringConst(nt, prop.line);
                                c.setCurrentExprPrimInfo(.{ .prim = .string, .is_constant = true });
                                return;
                            }
                        }
                        c.clearCurrentExprPrimInfo();
                        try c.cs.emitCall(argc, prop.line);
                        return;
                    }
                }
                try c.cs.emitGetField(prop.src, prop.line);
            }
            // Resolve static method dispatch before compiling args so the function is
            // placed on the stack below the receiver: [func, receiver, arg1..argN].
            // call(argc+1) then finds func as callee for any argc.
            var static_method_buf: [128]u8 = undefined;
            var static_method_len: usize = 0;
            if (!is_std_func) {
                if (receiver_named_type) |nt| {
                    var lookup: ?[]const u8 = nt;
                    while (lookup) |cur_nt| {
                        const candidate = std.fmt.bufPrint(&static_method_buf, "{s}.{s}", .{ cur_nt, prop.src }) catch "";
                        if (c.registry.hasGlobalFunc(candidate)) {
                            static_method_len = candidate.len;
                            break;
                        }
                        const info = c.registry.getNamedTypeInfo(cur_nt) orelse break;
                        lookup = info.parent_name;
                    }
                    if (static_method_len > 0) {
                        try c.cs.emitGetGlobal(static_method_buf[0..static_method_len], prop.line);
                        try c.cs.emitOp(.swap, prop.line);
                    }
                }
            }
            var argc: u8 = 0;
            if (!c.check(.rparen)) {
                while (true) {
                    try expr(
                        c,
                    );
                    argc += 1;
                    if (!c.match(.comma)) break;
                    if (c.check(.rparen)) break;
                }
            }
            try c.consume(.rparen);
            if (is_std_func) {
                try c.cs.emitCall(argc, prop.line);
            } else if (static_method_len > 0) {
                try c.cs.emitCall(argc + 1, prop.line);
                if (c.registry.getGlobalFuncObj(static_method_buf[0..static_method_len])) |func_obj| {
                    if (func_obj.* == .function and func_obj.function.return_types.len == 1) {
                        c.expr_prim_info[c.expr_depth] = c.exprPrimInfoFromFieldTypeSpec(func_obj.function.return_types[0]);
                    } else {
                        c.clearCurrentExprPrimInfo();
                    }
                } else {
                    c.expr_prim_info[c.expr_depth] = c.exprPrimInfoFromNamedType(receiver_named_type.?);
                }
                return;
            } else {
                try c.cs.emitInvokeMethod(prop.src, argc, line);
            }
            return;
        }
        try c.checkStdNamespaceField(prop.src, line);
        try c.checkImportModuleField(prop.src, line);
        try c.cs.emitGetField(prop.src, line);
        if (c.check(.lbrace) and looksLikeStructLiteral(
            c,
        )) {
            try structInstanceLitAfterValue(c, prop.line);
        }
        // Propagate named_type through field access (e.g. enum member reads).
        if (receiver_named_type) |nt| {
            c.expr_prim_info[c.expr_depth] = .{ .named_type = nt };
        } else if (receiver_info.struct_type) |struct_name| {
            if (c.registry.getStructObj(struct_name)) |struct_obj| {
                for (struct_obj.struct_type.fields) |field| {
                    if (common.streq(field.name, prop.src)) {
                        c.expr_prim_info[c.expr_depth] = c.exprPrimInfoFromFieldTypeSpec(field.typ);
                        break;
                    }
                }
            }
        }
        return;
    }

    c.std_namespace_path = null;
    c.import_module_path = null;
    if (tt == .lbracket) {
        const receiver_info = c.currentExprPrimInfo();
        c.clearCurrentExprPrimInfo();
        if (c.match(.colon)) {
            var flags: u8 = 0;
            if (!c.check(.rbracket)) {
                try expr(
                    c,
                );
                flags |= 0b10;
            }
            try c.consume(.rbracket);
            try c.cs.emit2(@intFromEnum(Op.get_slice), flags, line);
            return;
        }

        try expr(
            c,
        );
        if (c.match(.colon)) {
            var flags: u8 = 0b01;
            if (!c.check(.rbracket)) {
                try expr(
                    c,
                );
                flags |= 0b10;
            }
            try c.consume(.rbracket);
            try c.cs.emit2(@intFromEnum(Op.get_slice), flags, line);
            return;
        }

        try c.consume(.rbracket);
        try c.cs.emitOp(.get_index, line);
        if (receiver_info.index_result_spec) |element_spec| {
            c.setCurrentExprPrimInfo(c.exprPrimInfoFromFieldTypeSpec(element_spec));
        }
        return;
    }
    if (tt == .lparen) {
        // Save callee's named_type info before clearing (set by varExpr for named type constructors).
        const callee_named_type = c.currentExprPrimInfo().named_type;
        const callee_qname = c.pending_call_qname;
        c.clearCurrentExprPrimInfo();
        // Capture spread info for this callee before parsing args (which may overwrite it).
        const callee_spread_n = c.pending_call_spread_count;
        c.pending_call_spread_count = 0;
        c.pending_call_qname = null;
        // Prevent the multi-assign context from bleeding into nested calls (e.g. f(g())).
        const outer_lhs_count = c.multi_assign_lhs_count;
        c.multi_assign_lhs_count = 0;
        const callee_func_obj = if (callee_qname) |qname| c.registry.getGlobalFuncObj(qname) else null;
        var argc: u8 = 0;
        if (!c.check(.rparen)) {
            while (true) {
                c.beginExprPrimCapture();
                try expr(
                    c,
                );
                const arg_info = c.endExprPrimCapture();
                if (callee_func_obj) |func_obj| {
                    try c.checkDirectCallArgCompatibility(func_obj, argc, arg_info, line);
                }
                argc += 1;
                if (!c.match(.comma)) break;
                if (c.check(.rparen)) break;
            }
        }
        try c.consume(.rparen);
        c.cs.setCol(col);
        c.multi_assign_lhs_count = outer_lhs_count;
        if (callee_spread_n >= 2) {
            // All N≥2 named-return calls use call_spread so the verifier tracks N values.
            // The callee (via ret or retSlowPath) always pushes N individual values.
            try c.cs.emitCallSpread(argc, callee_spread_n, line);
            if (outer_lhs_count == callee_spread_n) {
                // Spread-compatible context: signal multiAssignOrDecl to consume N directly.
                c.last_spread_return_count = callee_spread_n;
            } else {
                // Non-spread context: re-pack the N spread values into a single tuple.
                try c.cs.emit2(@intFromEnum(Op.build_tuple), callee_spread_n, line);
            }
        } else {
            try c.cs.emitCall(argc, line);
        }
        // Propagate named_type from callee (e.g. Meters(5) → named_type = "Meters").
        if (callee_named_type) |nt| {
            c.expr_prim_info[c.expr_depth] = c.exprPrimInfoFromNamedType(nt);
        } else if (callee_func_obj) |func_obj| {
            if (func_obj.* == .function and func_obj.function.return_types.len == 1) {
                c.expr_prim_info[c.expr_depth] = c.exprPrimInfoFromFieldTypeSpec(func_obj.function.return_types[0]);
            }
        }
        return;
    }

    if (tt == .amp_amp) {
        c.setErr("'&&' is no longer supported; use 'and'", .{});
        return error.ExpectedExpression;
    }
    if (tt == .pipe_pipe) {
        c.setErr("'||' is no longer supported; use 'or'", .{});
        return error.ExpectedExpression;
    }
    if (tt == .percent) {
        c.setErr("'%' is no longer supported; use 'rem' (truncating remainder) or 'mod' (mathematical modulo)", .{});
        return error.ExpectedExpression;
    }

    const p = tokPrec(tt);
    if (tt == .kw_and) {
        c.clearCurrentExprPrimInfo();
        const j = try c.cs.emitJump(.jump_if_false, line);
        try c.cs.emitOp(.pop, line);
        try parsePrecedence(c, p.next());
        try c.cs.patchJump(j);
        return;
    }
    if (tt == .kw_or) {
        c.clearCurrentExprPrimInfo();
        const j_else = try c.cs.emitJump(.jump_if_false, line);
        const j_end = try c.cs.emitJump(.jump, line);
        try c.cs.patchJump(j_else);
        try c.cs.emitOp(.pop, line);
        try parsePrecedence(c, p.next());
        try c.cs.patchJump(j_end);
        return;
    }
    // ?? — null-coalescing: if LHS is not null, jump past pop+RHS; else pop null and eval RHS.
    // Right-associative: recurse at same precedence level so `a ?? b ?? c` = `a ?? (b ?? c)`.
    if (tt == .question_question) {
        c.clearCurrentExprPrimInfo();
        const j = try c.cs.emitJump(.jump_if_not_null, line);
        try c.cs.emitOp(.pop, line);
        try parsePrecedence(c, p);
        try c.cs.patchJump(j);
        return;
    }

    // ** is right-associative: recurse at same level so 2**3**2 = 2**(3**2)
    if (tt == .star_star) {
        c.clearCurrentExprPrimInfo();
        try parsePrecedence(c, p);
        c.cs.setCol(col);
        try c.cs.emitOp(.pow, line);
        return;
    }
    const lhs_info = c.currentExprPrimInfo();
    try parsePrecedence(c, p.next());
    const rhs_info = c.childExprPrimInfo();
    c.cs.setCol(col);
    const shift_named_type: ?[]const u8 = blk: {
        if (tt != .lt_lt and tt != .gt_gt) break :blk null;
        const nt = lhs_info.named_type orelse break :blk null;
        if (lhs_info.prim != .int or rhs_info.prim != .int) break :blk null;
        break :blk nt;
    };
    if (shift_named_type) |nt| {
        try c.cs.emitOp(if (tt == .lt_lt) .shl else .shr, line);
        try c.emitNamedValidation(.{ .named = nt }, line);
        c.setCurrentExprPrimInfo(.{ .prim = .int, .named_type = nt });
        return;
    }
    // Scalar named values are already represented by their bare runtime scalar.
    // Keep the compiler's nominal information, emit the typed base operation, then
    // validate the result with the compiler-selected named type.
    const interleave_nt: ?[]const u8 = blk: {
        const ln = lhs_info.named_type orelse break :blk null;
        const rn = rhs_info.named_type orelse break :blk null;
        if (!common.streq(ln, rn)) break :blk null;
        if (tt != .plus and tt != .minus and tt != .star and tt != .slash and tt != .kw_div and tt != .kw_rem and tt != .kw_mod and tt != .amp and tt != .pipe and tt != .caret) break :blk null;
        if (tt == .slash and lhs_info.prim != .float) break :blk null;
        if ((tt == .amp or tt == .pipe or tt == .caret) and lhs_info.prim != .int) break :blk null;
        if (c.registry.getNamedTypeInfo(ln)) |nti| {
            if (nti.base == .decimal or nti.base == .string) break :blk null;
        }
        break :blk ln;
    };
    if (interleave_nt) |nt| {
        switch (tt) {
            .plus => try c.cs.emitOp(c.selectTypedArithmeticOp(.add, lhs_info, rhs_info), line),
            .minus => try c.cs.emitOp(c.selectTypedArithmeticOp(.sub, lhs_info, rhs_info), line),
            .star => try c.cs.emitOp(c.selectTypedArithmeticOp(.mul, lhs_info, rhs_info), line),
            .slash => try c.cs.emitOp(c.selectTypedArithmeticOp(.div, lhs_info, rhs_info), line),
            .kw_div => try c.cs.emitOp(.int_div, line),
            .kw_rem => try c.cs.emitOp(.rem, line),
            .kw_mod => try c.cs.emitOp(.mod, line),
            .amp => try c.cs.emitOp(.bit_and, line),
            .pipe => try c.cs.emitOp(.bit_or, line),
            .caret => try c.cs.emitOp(.bit_xor, line),
            else => unreachable,
        }
        try c.emitNamedValidation(.{ .named = nt }, line);
    } else {
        switch (tt) {
            .plus => try c.cs.emitBinOpFused(c.selectTypedArithmeticOp(.add, lhs_info, rhs_info), line),
            .minus => try c.cs.emitBinOpFused(c.selectTypedArithmeticOp(.sub, lhs_info, rhs_info), line),
            .star => try c.cs.emitOp(c.selectTypedArithmeticOp(.mul, lhs_info, rhs_info), line),
            .slash => try c.cs.emitOp(c.selectTypedArithmeticOp(.div, lhs_info, rhs_info), line),
            .kw_div => try c.cs.emitOp(.int_div, line),
            .kw_rem => try c.cs.emitOp(.rem, line),
            .kw_mod => try c.cs.emitOp(.mod, line),
            .amp => try c.cs.emitOp(.bit_and, line),
            .pipe => try c.cs.emitOp(.bit_or, line),
            .caret => try c.cs.emitOp(.bit_xor, line),
            .lt_lt => try c.cs.emitOp(.shl, line),
            .gt_gt => try c.cs.emitOp(.shr, line),
            .eq_eq => {
                if (c.selectZeroIntCompare(.eq_eq, lhs_info, rhs_info)) |zero_cmp| {
                    try c.cs.emitOp(.pop, line);
                    try c.cs.emitOp(zero_cmp.op, line);
                    if (zero_cmp.needs_not) try c.cs.emitOp(.not, line);
                } else {
                    try c.cs.emitBinOpFused(c.selectTypedComparisonOp(.eq, lhs_info, rhs_info), line);
                }
            },
            .bang_eq => {
                if (c.selectZeroIntCompare(.bang_eq, lhs_info, rhs_info)) |zero_cmp| {
                    try c.cs.emitOp(.pop, line);
                    try c.cs.emitOp(zero_cmp.op, line);
                } else {
                    try c.cs.emitBinOpFused(c.selectTypedComparisonOp(.ne, lhs_info, rhs_info), line);
                }
            },
            .gt => {
                if (c.selectZeroIntCompare(.gt, lhs_info, rhs_info)) |zero_cmp| {
                    try c.cs.emitOp(.pop, line);
                    try c.cs.emitOp(zero_cmp.op, line);
                } else {
                    try c.cs.emitBinOpFused(c.selectTypedComparisonOp(.gt, lhs_info, rhs_info), line);
                }
            },
            .gt_eq => {
                if (c.selectZeroIntCompare(.gt_eq, lhs_info, rhs_info)) |zero_cmp| {
                    try c.cs.emitOp(.pop, line);
                    try c.cs.emitOp(zero_cmp.op, line);
                } else {
                    try c.cs.emitBinOpFused(c.selectTypedComparisonOp(.ge, lhs_info, rhs_info), line);
                }
            },
            .lt => {
                if (c.selectZeroIntCompare(.lt, lhs_info, rhs_info)) |zero_cmp| {
                    try c.cs.emitOp(.pop, line);
                    try c.cs.emitOp(zero_cmp.op, line);
                } else {
                    try c.cs.emitBinOpFused(c.selectTypedComparisonOp(.lt, lhs_info, rhs_info), line);
                }
            },
            .lt_eq => {
                if (c.selectZeroIntCompare(.lt_eq, lhs_info, rhs_info)) |zero_cmp| {
                    try c.cs.emitOp(.pop, line);
                    try c.cs.emitOp(zero_cmp.op, line);
                } else {
                    try c.cs.emitBinOpFused(c.selectTypedComparisonOp(.le, lhs_info, rhs_info), line);
                }
            },
            else => unreachable,
        }
    }
    try c.setCurrentExprPrimResult(switch (tt) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .kw_div => .int_div,
        .kw_rem => .rem,
        .kw_mod => .mod,
        .amp => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .eq_eq, .bang_eq => .eq,
        .lt, .lt_eq, .gt, .gt_eq => .lt,
        else => .halt,
    }, lhs_info, rhs_info);
}

pub fn looksLikeStructLiteral(c: anytype) bool {
    var lx = c.lex;
    var t = lx.next(); // first token inside '{'
    if (t.typ == .rbrace) return true; // empty struct: TypeName{}
    if (!(t.typ == .ident or t.typ == .string)) return false;
    t = lx.next();
    return t.typ == .colon;
}

// Like looksLikeStructLiteral but returns false for empty braces.
// Used to detect `variable { field: val }` (clearly wrong) vs `variable {}` (ambiguous — may be a block).
fn looksLikeNonEmptyStructLiteral(c: anytype) bool {
    var lx = c.lex;
    var t = lx.next();
    if (t.typ == .rbrace) return false;
    if (!(t.typ == .ident or t.typ == .string)) return false;
    t = lx.next();
    return t.typ == .colon;
}

pub fn mapLit(c: anytype) !void {
    var count: u8 = 0;
    if (!c.check(.rbrace)) {
        while (true) {
            if (count == 255) {
                c.setErr("too many elements (max {d})", .{MaxLocals});
                return error.TooManyElements;
            }

            try expr(
                c,
            );

            try c.consume(.colon);
            try expr(
                c,
            );
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);
    try c.cs.emit2(@intFromEnum(Op.build_map), count, c.prev.line);
}

pub fn numLit(c: anytype) !void {
    const is_based = c.prev.src.len >= 2 and c.prev.src[0] == '0' and
        (c.prev.src[1] == 'x' or c.prev.src[1] == 'X' or
            c.prev.src[1] == 'b' or c.prev.src[1] == 'B' or
            c.prev.src[1] == 'o' or c.prev.src[1] == 'O');
    const is_float = !is_based and std.mem.indexOfAny(u8, c.prev.src, ".eE") != null;
    if (is_float) {
        const n = common.parseFloat(c.prev.src) orelse return error.BadNumber;
        try c.cs.emitConst(.{ .float = n }, c.prev.line);
    } else {
        const n = common.parseInt(c.prev.src) orelse return error.BadNumber;
        try c.cs.emitConst(.{ .int = n }, c.prev.line);
    }
}

pub fn parsePrecedence(c: anytype, p: Prec) anyerror!void {
    if (c.expr_depth >= MaxExprDepth) {
        c.setErr("expression too deeply nested", .{});
        return error.ExpressionTooDeep;
    }
    c.expr_depth += 1;
    defer {
        c.expr_depth -= 1;
    }
    c.clearCurrentExprPrimInfo();
    c.advance();
    const pfx = c.prev.typ;
    switch (pfx) {
        .number => {
            c.noteCurrentExprPrimFromToken(c.prev);
            try numLit(
                c,
            );
        },
        .string => {
            c.clearCurrentExprPrimInfo();
            try strLitExpr(
                c,
            );
        },
        .rune => {
            c.clearCurrentExprPrimInfo();
            try runeLitExpr(
                c,
            );
        },
        .kw_true => {
            c.clearCurrentExprPrimInfo();
            try c.cs.emitOp(.true_val, c.prev.line);
        },
        .kw_false => {
            c.clearCurrentExprPrimInfo();
            try c.cs.emitOp(.false_val, c.prev.line);
        },
        .kw_null => {
            c.clearCurrentExprPrimInfo();
            try c.cs.emitOp(.null_val, c.prev.line);
        },
        .ident => {
            c.noteCurrentExprPrimFromToken(c.prev);
            try varExpr(c, c.prev);
        },
        .minus, .kw_not, .tilde => {
            c.clearCurrentExprPrimInfo();
            try unaryExpr(c, pfx);
        },
        .bang => {
            c.clearCurrentExprPrimInfo();
            c.setErr("'!' is no longer supported; use 'not'", .{});
            return error.ExpectedExpression;
        },
        .lparen => {
            try expr(
                c,
            );
            try c.consume(.rparen);
            c.propagateChildExprPrimInfo();
        },
        .lbracket => {
            c.clearCurrentExprPrimInfo();
            try arrayLit(
                c,
            );
        },
        .lbrace => {
            c.clearCurrentExprPrimInfo();
            try mapLit(
                c,
            );
        },
        .kw_func => {
            c.clearCurrentExprPrimInfo();
            try c.funcLit();
        },
        .kw_import => {
            c.clearCurrentExprPrimInfo();
            try importExpr(
                c,
            );
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
    while (@intFromEnum(p) <= @intFromEnum(tokPrec(c.cur.typ))) {
        c.advance();
        try infixExpr(c, c.prev.typ);
    }
}

pub fn runeLitExpr(c: anytype) !void {
    const raw = c.prev.src;
    if (raw.len < 3) return c.err("rune literal must contain exactly one codepoint", .{});
    const body = raw[1 .. raw.len - 1];
    var it = std.unicode.Utf8View.init(body) catch return error.TypeError;
    var iter = it.iterator();
    const cp = iter.nextCodepoint() orelse return c.err("rune literal must contain exactly one codepoint", .{});
    if (iter.nextCodepoint() != null) return c.err("rune literal must contain exactly one codepoint", .{});
    try c.cs.emitConst(.{ .rune = @intCast(cp) }, c.prev.line);
}

pub fn strLitExpr(c: anytype) !void {
    try c.cs.emitStringConst(c.prev.src, c.prev.line);
}

pub fn structInstanceLit(c: anytype, type_name: Token) !void {
    try c.emitGetVar(type_name);
    try c.consume(.lbrace);
    var count: u8 = 0;
    if (!c.check(.rbrace)) {
        while (true) {
            if (count == 255) {
                c.setErr("too many elements (max {d})", .{MaxLocals});
                return error.TooManyElements;
            }
            if (c.check(.ident)) {
                const key_tok = c.cur;
                c.advance();
                try c.cs.emitStringConst(key_tok.src, key_tok.line);
            } else if (c.check(.string)) {
                try c.cs.emitStringConst(c.cur.src, c.cur.line);
                c.advance();
            } else return c.err("expected identifier or string key, found {s}", .{c.tokenName(c.cur.typ)});
            try c.consume(.colon);
            try expr(
                c,
            );
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);
    try c.cs.emit2(@intFromEnum(Op.build_struct_instance), count, type_name.line);
}

pub fn structInstanceLitAfterValue(c: anytype, line: u32) !void {
    try c.consume(.lbrace);
    var count: u8 = 0;
    if (!c.check(.rbrace)) {
        while (true) {
            if (count == 255) {
                c.setErr("too many elements (max {d})", .{MaxLocals});
                return error.TooManyElements;
            }
            if (c.check(.ident)) {
                const key_tok = c.cur;
                c.advance();
                try c.cs.emitStringConst(key_tok.src, key_tok.line);
            } else if (c.check(.string)) {
                try c.cs.emitStringConst(c.cur.src, c.cur.line);
                c.advance();
            } else return c.err("expected identifier or string key, found {s}", .{c.tokenName(c.cur.typ)});
            try c.consume(.colon);
            try expr(
                c,
            );
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);
    try c.cs.emit2(@intFromEnum(Op.build_struct_instance), count, line);
}

pub fn unaryExpr(c: anytype, tt: TT) !void {
    try parsePrecedence(c, .unary);
    const op_info = c.childExprPrimInfo();
    const op_named_type: ?[]const u8 = blk: {
        if (tt != .minus and tt != .tilde and tt != .kw_not) break :blk null;
        const nt = op_info.named_type orelse break :blk null;
        if (c.registry.getNamedTypeInfo(nt)) |nti| {
            if (tt == .kw_not and nti.base != .bool) break :blk null;
            if (nti.base == .decimal or nti.base == .string) break :blk null;
        }
        break :blk nt;
    };
    if (op_named_type) |nt| {
        _ = nt;
    }
    switch (tt) {
        .minus => try c.cs.emitOp(.neg, c.prev.line),
        .kw_not => try c.cs.emitOp(.not, c.prev.line),
        .tilde => try c.cs.emitOp(.bit_not, c.prev.line),
        else => unreachable,
    }
    if (op_named_type) |_| {
        try c.emitNamedValidation(.{ .named = op_named_type.? }, c.prev.line);
        c.setCurrentExprPrimInfo(.{ .prim = op_info.prim, .named_type = op_named_type.? });
    }
}

pub fn varExpr(c: anytype, name: Token) !void {
    if ((common.streq(name.src, "int") or common.streq(name.src, "float") or
        common.streq(name.src, "bool") or common.streq(name.src, "string") or
        common.streq(name.src, "bigint")) and c.match(.lparen))
    {
        try expr(
            c,
        );
        try c.consume(.rparen);
        if (common.streq(name.src, "int")) {
            try c.cs.emitOp(.cast_int, name.line);
        } else if (common.streq(name.src, "float")) {
            try c.cs.emitOp(.cast_float, name.line);
        } else if (common.streq(name.src, "bool")) {
            try c.cs.emitOp(.cast_bool, name.line);
        } else if (common.streq(name.src, "bigint")) {
            try c.cs.emitOp(.cast_bigint, name.line);
        } else {
            try c.cs.emitOp(.cast_string, name.line);
        }
        return;
    }
    // Generic struct/variant instantiation with literal: Stack[int]{ items: [] }
    if (c.check(.lbracket) and c.registry.hasGenericType(name.src)) {
        const qname = try compiler_decls.instantiateGenericType(c, name.src, name.line);
        try c.cs.emitGetGlobal(qname, name.line);
        if (c.check(.lbrace) and looksLikeStructLiteral(
            c,
        )) {
            try structInstanceLitAfterValue(c, name.line);
        }
        return;
    }
    // Generic function call with explicit type args: name[T, U](args)
    if (c.check(.lbracket) and c.registry.hasGenericFunc(name.src)) {
        const gfi = c.registry.getGenericFunc(name.src).?;
        c.advance(); // consume '['
        var arg_count: u8 = 0;
        var arg_specs: [ct.MaxTypeParams]value_mod.FieldTypeSpec = undefined;
        if (!c.check(.rbracket)) {
            while (true) {
                arg_specs[arg_count] = try compiler_decls.parseFieldTypeSpec(c);
                arg_count += 1;
                if (!c.match(.comma)) break;
                if (c.check(.rbracket)) break;
            }
        }
        try c.consume(.rbracket);
        if (arg_count != gfi.param_count) {
            c.setErr("wrong number of type arguments for '{s}': expected {d}, got {d}", .{ name.src, gfi.param_count, arg_count });
            return error.WrongTypeArgCount;
        }
        try compiler_decls.checkTypeArgConstraints(c, gfi.params[0..gfi.param_count], arg_specs[0..arg_count], name.src, name.line);
    }
    if (c.check(.lbrace) and looksLikeStructLiteral(
        c,
    )) {
        const is_known_type = c.registry.hasStructTypeLocal(name.src) or
            c.registry.hasNamedType(name.src) or
            c.registry.hasVariantType(name.src) or
            c.registry.hasTypeAlias(name.src);
        if (is_known_type) {
            if (c.registry.getTypeAlias(name.src)) |alias| {
                // Load the canonical type object (e.g. @mod:Stack[int]) not @mod:IntStack,
                // so build_struct_instance gets the type with the correct field definitions.
                try c.cs.emitGetGlobal(alias.target_qname, name.line);
                try structInstanceLitAfterValue(c, name.line);
            } else {
                try structInstanceLit(c, name);
            }
            return;
        }
        // Not a registered type. If there are actual fields it's a clear error.
        // Empty braces fall through — they may be a block (if-body, loop body, etc.).
        if (looksLikeNonEmptyStructLiteral(
            c,
        )) {
            if (c.resolveLocal(name.src) != null) {
                return c.err("'{s}' is a variable, not a type", .{name.src});
            }
            return c.err("'{s}' is not a known type", .{name.src});
        }
    }
    // `<typename> == <expr>.type` — the reverse of `<expr>.type == <typename>`.
    // Only known type names are eligible, so an ordinary variable compared
    // with == is never affected.
    if ((c.check(.eq_eq) or c.check(.bang_eq)) and
        (isTypeNamePrimitive(name.src) or c.registry.hasNamedType(name.src) or
            c.registry.hasStructTypeLocal(name.src) or c.registry.hasVariantType(name.src) or
            c.registry.hasInterfaceType(name.src) or c.registry.hasTypeAlias(name.src)))
    {
        try validateAndEmitTypeName(c, name);
        const is_eq = c.cur.typ == .eq_eq;
        c.advance();
        c.require_type_suffix = true;
        c.type_suffix_consumed = false;
        try expr(
            c,
        );
        if (!c.type_suffix_consumed) {
            c.require_type_suffix = false;
            c.setErr("expected '{s}' to be compared against a '.type' expression", .{name.src});
            return error.UnexpectedToken;
        }
        try c.cs.emitOp(.eq, name.line);
        if (!is_eq) try c.cs.emitOp(.not, name.line);
        return;
    }
    // If this is a known named type, record it in ExprPrimInfo so that
    // infixExpr(.lparen) can detect a constructor call and propagate the type.
    if (c.registry.hasNamedType(name.src)) {
        const qname = try c.qualifyTypeName(name.src);
        c.expr_prim_info[c.expr_depth] = .{ .named_type = qname };
    }
    try c.emitGetVar(name);
}

fn tokPrec(tt: TT) Prec {
    return switch (tt) {
        .question_question => .null_coalesce,
        .kw_or, .pipe_pipe => .or_,
        .kw_and, .amp_amp => .and_,
        .eq_eq, .bang_eq => .eq_,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .amp => .bit_and,
        .lt_lt, .gt_gt => .shift,
        .lt, .lt_eq, .gt, .gt_eq => .cmp,
        .plus, .minus => .term,
        .star, .slash, .kw_div, .kw_rem, .kw_mod, .percent => .factor,
        .star_star => .power,
        .lbracket, .lparen, .dot => .call,
        else => .none,
    };
}
