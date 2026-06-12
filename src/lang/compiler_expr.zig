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

pub fn expr(c: anytype) !void {
    c.std_namespace_path = null;
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
        if (c.cur.typ != .ident) { c.setErr("expected property name, found {s}", .{c.tokenName(c.cur.typ)}); return error.ExpectedPropertyName; }
        const prop = c.cur;
        c.advance();
        if (c.match(.lparen)) {
            try c.checkStdNamespaceField(prop.src, line);
            try c.checkImportModuleField(prop.src, line);
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
            try chunk.emitInvokeMethod(prop.src, argc, line);
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
        try chunk.emit2(@intFromEnum(Op.call), argc, line);
        return;
    }

    const p = tokPrec(tt);
    if (tt == .amp_amp) {
        const j = try chunk.emitJump(.jump_if_false, line);
        try chunk.emitOp(.pop, line);
        try parsePrecedence(c, p.next());
        try chunk.patchJump(j);
        return;
    }
    if (tt == .pipe_pipe) {
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

pub fn looksLikeStructLiteral(c: anytype) bool {
    var lx = c.lex;
    var t = lx.next(); // first token inside '{'
    if (t.typ == .rbrace) return true; // empty literal form (if ever allowed)
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
    const n = common.parseFloat(c.prev.src) orelse return error.BadNumber;
    const is_float = std.mem.indexOfAny(u8, c.prev.src, ".eE") != null;
    try chunk.emitConst(if (is_float) .{ .float = n } else .{ .int = n }, c.prev.line);
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
        .minus, .bang, .tilde => try unaryExpr(c, pfx),
        .lparen => {
            try expr(c, );
            try c.consume(.rparen);
        },
        .lbracket => try arrayLit(c, ),
        .lbrace => try mapLit(c, ),
        .kw_func => try c.funcLit(),
        .kw_import => try importExpr(c, ),
        .err_invalid_char => return error.InvalidChar,
        .err_unterminated_string => return error.UnterminatedString,
        .err_string_pool_exhausted => return error.UnterminatedString,
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
    try chunk.emitConst(.{ .string = c.prev.src }, c.prev.line);
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
                try chunk.emitConst(.{ .string = key_tok.src }, key_tok.line);
            } else if (c.check(.string)) {
                try chunk.emitConst(.{ .string = c.cur.src }, c.cur.line);
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
                try chunk.emitConst(.{ .string = key_tok.src }, key_tok.line);
            } else if (c.check(.string)) {
                try chunk.emitConst(.{ .string = c.cur.src }, c.cur.line);
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
        .bang => try chunk.emitOp(.not, c.prev.line),
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
        try structInstanceLit(c, name);
        return;
    }
    try c.emitGetVar(name);
}

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
