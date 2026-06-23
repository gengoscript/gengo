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
            try expr(c, );
            if (count == 255) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbracket)) break;
        }
    }
    try c.consume(.rbracket);
    try chunk.emit2(@intFromEnum(Op.build_array), count, c.prev.line);
}

// Returns true for an identifier token that names a concrete, comparable
// type — usable opposite a '.type' expression. Interfaces are excluded
// ('.type' never equals an interface name, since interfaces aren't concrete
// runtime types); unknown names are left for the caller to reject.
fn isTypeNamePrimitive(name: []const u8) bool {
    const prims = [_][]const u8{ "int", "float", "bool", "string", "rune", "decimal", "error", "map" };
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
        if (!(c.registry.hasNamedType(name.src) or c.registry.hasStructTypeLocal(name.src) or c.registry.hasVariantType(name.src))) {
            c.setErr("unknown type name '{s}'", .{name.src});
            return error.UnknownTypeName;
        }
    }
    try chunk.emitStringConst(name.src, name.line);
}

// Parses a bare type name used opposite a `.type` expression — either as the
// other side of == / != , or as a `case` label in a `.type`-headed switch.
pub fn typeNameLiteral(c: anytype) !void {
    if (c.cur.typ != .ident) { c.setErr("expected a type name, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedTypeName; }
    const name = c.cur;
    c.advance();
    try validateAndEmitTypeName(c, name);
}

pub fn expr(c: anytype) !void {
    c.std_namespace_path = null;
    chunk.clearStdCallPatchPos();
    try parsePrecedence(c, .assign);
}

pub fn importExpr(c: anytype) !void {
    try c.consume(.lparen);
    if (c.cur.typ != .string) { c.setErr("expected string literal, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedStringLiteral; }
    const name = c.cur.src;
    c.advance();
    try c.consume(.rparen);
    const ctx = c.options.module_ctx orelse { c.setErr("unsupported import module '{s}'", .{name}); return error.UnsupportedImportModule; };
    const resolver = c.options.resolve_import orelse { c.setErr("unsupported import module '{s}'", .{name}); return error.UnsupportedImportModule; };
    const mod_name = try resolver(ctx, c.options.module_path, name);
    if (common.streq(name, "std")) {
        chunk.markStdCallPatchPos();
    }
    try chunk.emitGetGlobal(mod_name, c.prev.line);
    if (common.streq(name, "std") and common.streq(mod_name, "module:std")) {
        c.std_namespace_path = "";
        c.import_module_path = null;
    } else if (mod_name.len > 5 and std.mem.startsWith(u8, mod_name, "host:")) {
        c.import_module_path = mod_name[5..];
        c.std_namespace_path = null;
    } else if (mod_name.len > 4 and std.mem.startsWith(u8, mod_name, "cap:")) {
        c.import_module_path = mod_name[4..];
        c.std_namespace_path = null;
    }
}

pub fn infixExpr(c: anytype, tt: TT) anyerror!void {
    const line = c.prev.line;
    const col = c.prev.col;

    if (tt == .dot) {
        if (c.cur.typ == .kw_type) {
            c.advance(); // consume 'type'
            try chunk.emitOp(.type_name, line);
            if (c.check(.eq_eq) or c.check(.bang_eq)) {
                const is_eq = c.cur.typ == .eq_eq;
                c.advance();
                try typeNameLiteral(c, );
                try chunk.emitOp(.eq, line);
                if (!is_eq) try chunk.emitOp(.not, line);
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
        if (!c.cur.typ.isFieldName()) { c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedPropertyName; }
        const prop = c.cur;
        c.advance();
        if (c.match(.lparen)) {
            const is_std_func = c.std_namespace_path != null;
            const std_ns = c.std_namespace_path;
            try c.checkStdNamespaceField(prop.src, line);
            try c.checkImportModuleField(prop.src, line);
            if (is_std_func) {
                if (chunk.stdCallPatchPos()) |patch_pos| {
                    chunk.clearStdCallPatchPos();
                    var name_buf: [80]u8 = undefined;
                    const direct_name = if (std_ns != null and std_ns.?.len > 0)
                        std.fmt.bufPrint(&name_buf, "module:std.{s}.{s}", .{ std_ns.?, prop.src }) catch ""
                    else
                        std.fmt.bufPrint(&name_buf, "module:std.{s}", .{prop.src}) catch "";
                    if (direct_name.len > 0) {
                        chunk.truncateTo(patch_pos);
                        try chunk.emitGetGlobal(direct_name, prop.line);
                        var argc: u8 = 0;
                        if (!c.check(.rparen)) {
                            while (true) {
                                try expr(c, );
                                argc += 1;
                                if (!c.match(.comma)) break;
                                if (c.check(.rparen)) break;
                            }
                        }
                        try c.consume(.rparen);
                        try chunk.emitCall(argc, prop.line);
                        return;
                    }
                }
                try chunk.emitGetField(prop.src, prop.line);
            }
            var argc: u8 = 0;
            if (!c.check(.rparen)) {
                while (true) {
                    try expr(c, );
                    argc += 1;
                    if (!c.match(.comma)) break;
                    if (c.check(.rparen)) break;
                }
            }
            try c.consume(.rparen);
            if (is_std_func) {
                try chunk.emitCall(argc, prop.line);
            } else {
                try chunk.emitInvokeMethod(prop.src, argc, line);
            }
            return;
        }
        try c.checkStdNamespaceField(prop.src, line);
        try c.checkImportModuleField(prop.src, line);
        try chunk.emitGetField(prop.src, line);
        if (c.check(.lbrace) and looksLikeStructLiteral(c, )) {
            try structInstanceLitAfterValue(c, prop.line);
        }
        return;
    }

    c.std_namespace_path = null;
    c.import_module_path = null;
    if (tt == .lbracket) {
        if (c.match(.colon)) {
            var flags: u8 = 0;
            if (!c.check(.rbracket)) {
                try expr(c, );
                flags |= 0b10;
            }
            try c.consume(.rbracket);
            try chunk.emit2(@intFromEnum(Op.get_slice), flags, line);
            return;
        }

        try expr(c, );
        if (c.match(.colon)) {
            var flags: u8 = 0b01;
            if (!c.check(.rbracket)) {
                try expr(c, );
                flags |= 0b10;
            }
            try c.consume(.rbracket);
            try chunk.emit2(@intFromEnum(Op.get_slice), flags, line);
            return;
        }

        try c.consume(.rbracket);
        try chunk.emitOp(.get_index, line);
        return;
    }
    if (tt == .lparen) {
        var argc: u8 = 0;
        if (!c.check(.rparen)) {
            while (true) {
                try expr(c, );
                argc += 1;
                if (!c.match(.comma)) break;
                if (c.check(.rparen)) break;
            }
        }
        try c.consume(.rparen);
        chunk.setCol(col);
        try chunk.emitCall(argc, line);
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
        const j = try chunk.emitJump(.jump_if_false, line);
        try chunk.emitOp(.pop, line);
        try parsePrecedence(c, p.next());
        try chunk.patchJump(j);
        return;
    }
    if (tt == .kw_or) {
        const j_else = try chunk.emitJump(.jump_if_false, line);
        const j_end = try chunk.emitJump(.jump, line);
        try chunk.patchJump(j_else);
        try chunk.emitOp(.pop, line);
        try parsePrecedence(c, p.next());
        try chunk.patchJump(j_end);
        return;
    }

    // ** is right-associative: recurse at same level so 2**3**2 = 2**(3**2)
    if (tt == .star_star) {
        try parsePrecedence(c, p);
        chunk.setCol(col);
        try chunk.emitOp(.pow, line);
        return;
    }
    try parsePrecedence(c, p.next());
    chunk.setCol(col);
    switch (tt) {
        .plus  => try chunk.emitBinOpFused(.add, line),
        .minus => try chunk.emitBinOpFused(.sub, line),
        .star  => try chunk.emitOp(.mul, line),
        .slash => try chunk.emitOp(.div, line),
        .kw_div => try chunk.emitOp(.int_div, line),
        .kw_rem => try chunk.emitOp(.rem, line),
        .kw_mod => try chunk.emitOp(.mod, line),
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
        .gt => try chunk.emitBinOpFused(.gt, line),
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
            if (count == 255) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }

            try expr(c, );

            try c.consume(.colon);
            try expr(c, );
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);
    try chunk.emit2(@intFromEnum(Op.build_map), count, c.prev.line);
}

pub fn numLit(c: anytype) !void {
    const is_float = std.mem.indexOfAny(u8, c.prev.src, ".eE") != null;
    if (is_float) {
        const n = common.parseFloat(c.prev.src) orelse return error.BadNumber;
        try chunk.emitConst(.{ .float = n }, c.prev.line);
    } else {
        const n = common.parseInt(c.prev.src) orelse return error.BadNumber;
        try chunk.emitConst(.{ .int = n }, c.prev.line);
    }
}

pub fn parsePrecedence(c: anytype, p: Prec) anyerror!void {
    if (c.expr_depth >= MaxExprDepth) {
        c.setErr("expression too deeply nested", .{});
        return error.ExpressionTooDeep;
    }
    c.expr_depth += 1;
    defer { c.expr_depth -= 1; }
    c.advance();
    const pfx = c.prev.typ;
    switch (pfx) {
        .number => try numLit(c, ),
        .string => try strLitExpr(c, ),
        .rune => try runeLitExpr(c, ),
        .kw_true => try chunk.emitOp(.true_val, c.prev.line),
        .kw_false => try chunk.emitOp(.false_val, c.prev.line),
        .kw_null => try chunk.emitOp(.null_val, c.prev.line),
        .ident => try varExpr(c, c.prev),
        .minus, .kw_not, .tilde => try unaryExpr(c, pfx),
        .bang => {
            c.setErr("'!' is no longer supported; use 'not'", .{});
            return error.ExpectedExpression;
        },
        .lparen => {
            try expr(c, );
            try c.consume(.rparen);
        },
        .lbracket => try arrayLit(c, ),
        .lbrace => try mapLit(c, ),
        .kw_func => try c.funcLit(),
        .kw_import => try importExpr(c, ),
        .err_invalid_char => return error.InvalidChar,
        .err_unterminated_string => { c.setErr("unterminated string literal", .{}); return error.UnterminatedString; },
        .err_string_pool_exhausted => { c.setErr("string pool exhausted (max {d}KB)", .{@import("lexer.zig").StrPoolSize / 1024}); return error.UnterminatedString; },
        else => { c.setErr("expected expression, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedExpression; },
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
    try chunk.emitConst(.{ .rune = @intCast(cp) }, c.prev.line);
}

pub fn strLitExpr(c: anytype) !void {
    try chunk.emitStringConst(c.prev.src, c.prev.line);
}

pub fn structInstanceLit(c: anytype, type_name: Token) !void {
    try c.emitGetVar(type_name);
    try c.consume(.lbrace);
    var count: u8 = 0;
    if (!c.check(.rbrace)) {
        while (true) {
            if (count == 255) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
            if (c.check(.ident)) {
                const key_tok = c.cur;
                c.advance();
                try chunk.emitStringConst(key_tok.src, key_tok.line);
            } else if (c.check(.string)) {
                try chunk.emitStringConst(c.cur.src, c.cur.line);
                c.advance();
            } else return c.err("expected identifier or string key, found {s}", .{c.tokenName(c.cur.typ)});
            try c.consume(.colon);
            try expr(c, );
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);
    try chunk.emit2(@intFromEnum(Op.build_struct_instance), count, type_name.line);
}

pub fn structInstanceLitAfterValue(c: anytype, line: u32) !void {
    try c.consume(.lbrace);
    var count: u8 = 0;
    if (!c.check(.rbrace)) {
        while (true) {
            if (count == 255) { c.setErr("too many elements (max {d})", .{MaxLocals}); return error.TooManyElements; }
            if (c.check(.ident)) {
                const key_tok = c.cur;
                c.advance();
                try chunk.emitStringConst(key_tok.src, key_tok.line);
            } else if (c.check(.string)) {
                try chunk.emitStringConst(c.cur.src, c.cur.line);
                c.advance();
            } else return c.err("expected identifier or string key, found {s}", .{c.tokenName(c.cur.typ)});
            try c.consume(.colon);
            try expr(c, );
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);
    try chunk.emit2(@intFromEnum(Op.build_struct_instance), count, line);
}

pub fn unaryExpr(c: anytype, tt: TT) !void {
    try parsePrecedence(c, .unary);
    switch (tt) {
        .minus => try chunk.emitOp(.neg, c.prev.line),
        .kw_not => try chunk.emitOp(.not, c.prev.line),
        .tilde => try chunk.emitOp(.bit_not, c.prev.line),
        else => unreachable,
    }
}

pub fn varExpr(c: anytype, name: Token) !void {
    if ((common.streq(name.src, "int") or common.streq(name.src, "float") or common.streq(name.src, "bool") or common.streq(name.src, "string")) and c.match(.lparen)) {
        try expr(c, );
        try c.consume(.rparen);
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
    if (c.check(.lbrace) and looksLikeStructLiteral(c, )) {
        const is_known_type = c.registry.hasStructTypeLocal(name.src) or
            c.registry.hasNamedType(name.src) or
            c.registry.hasVariantType(name.src);
        if (is_known_type) {
            try structInstanceLit(c, name);
            return;
        }
        // Not a registered type. If there are actual fields it's a clear error.
        // Empty braces fall through — they may be a block (if-body, loop body, etc.).
        if (looksLikeNonEmptyStructLiteral(c, )) {
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
         c.registry.hasInterfaceType(name.src)))
    {
        try validateAndEmitTypeName(c, name);
        const is_eq = c.cur.typ == .eq_eq;
        c.advance();
        c.require_type_suffix = true;
        c.type_suffix_consumed = false;
        try expr(c, );
        if (!c.type_suffix_consumed) {
            c.require_type_suffix = false;
            c.setErr("expected '{s}' to be compared against a '.type' expression", .{name.src});
            return error.UnexpectedToken;
        }
        try chunk.emitOp(.eq, name.line);
        if (!is_eq) try chunk.emitOp(.not, name.line);
        return;
    }
    try c.emitGetVar(name);
}

fn tokPrec(tt: TT) Prec {
    return switch (tt) {
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
