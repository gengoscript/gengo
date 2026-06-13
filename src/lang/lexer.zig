const std = @import("std");
const common = @import("common.zig");
const unicode = @import("unicode.zig");
const token = @import("token.zig");
const TT = token.TT;
const Token = token.Token;

/// Capacity of the per-lexer string pool that backs processed string
/// literals. Error messages derive their reported limit from this.
pub const StrPoolSize: usize = 128 * 1024;

const keyword_map = std.StaticStringMap(TT).initComptime(.{
    .{ "assert",    .kw_assert },
    .{ "break",     .kw_break },
    .{ "case",      .kw_case },
    .{ "const",     .kw_const },
    .{ "continue",  .kw_continue },
    .{ "cycle",     .kw_cycle },
    .{ "default",   .kw_default },
    .{ "defer",     .kw_defer },
    .{ "else",      .kw_else },
    .{ "enum",      .kw_enum },
    .{ "false",     .kw_false },
    .{ "for",       .kw_for },
    .{ "func",      .kw_func },
    .{ "if",        .kw_if },
    .{ "import",    .kw_import },
    .{ "in",        .kw_in },
    .{ "interface", .kw_interface },
    .{ "null",      .kw_null },
    .{ "message",   .kw_message },
    .{ "predicate", .kw_predicate },
    .{ "pub",       .kw_pub },
    .{ "range",     .kw_range },
    .{ "return",    .kw_return },
    .{ "struct",    .kw_struct },
    .{ "subtype",   .kw_subtype },
    .{ "switch",    .kw_switch },
    .{ "test",      .kw_test },
    .{ "trap",      .kw_trap },
    .{ "true",      .kw_true },
    .{ "type",      .kw_type },
    .{ "var",       .kw_var },
    .{ "variant",   .kw_variant },
});

pub const Lexer = struct {
    src: []const u8,
    start: usize = 0,
    pos: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    str_pool: [StrPoolSize]u8 = undefined,
    str_pool_pos: usize = 0,

    pub fn next(self: *Lexer) Token {
        self.skipWS();
        self.start = self.pos;
        if (self.atEnd()) return self.tok(.eof);
        const c = self.adv();
        if (common.isAlpha(c)) return self.ident();
        if (common.isDigit(c)) return self.numLit();
        if (c >= 0x80) {
            self.pos = self.start;
            const cp_len = self.peekCodepointLen();
            if (cp_len > 0) {
                const cp = self.decodeCodepoint(cp_len);
                if (unicode.isIdentStart(cp)) {
                    self.pos += cp_len;
                    return self.ident();
                }
            }
            self.pos = self.start + 1;
            return self.tok(.err_invalid_char);
        }
        return switch (c) {
            '(' => self.tok(.lparen),
            ')' => self.tok(.rparen),
            '{' => self.tok(.lbrace),
            '}' => self.tok(.rbrace),
            '[' => self.tok(.lbracket),
            ']' => self.tok(.rbracket),
            ',' => self.tok(.comma),
            ';' => self.tok(.semicolon),
            ':' => self.tok(if (self.eat('=')) .colon_eq else .colon),
            '.' => self.tok(if (self.eat('.')) (if (self.eat('.')) .ellipsis else .dotdot) else .dot),
            '?' => self.tok(.question),
            '+' => self.tok(if (self.eat('+')) .plus_plus else if (self.eat('=')) .plus_eq else .plus),
            '-' => self.tok(if (self.eat('-')) .minus_minus else if (self.eat('=')) .minus_eq else .minus),
            '*' => self.tok(if (self.eat('*')) .star_star else if (self.eat('=')) .star_eq else .star),
            '/' => self.tok(if (self.eat('=')) .slash_eq else .slash),
            '%' => self.tok(if (self.eat('=')) .percent_eq else .percent),
            '~' => self.tok(.tilde),
            '!' => self.tok(if (self.eat('=')) .bang_eq else .bang),
            '=' => self.tok(if (self.eat('=')) .eq_eq else .eq),
            '<' => self.tok(if (self.eat('<')) (if (self.eat('=')) .lt_lt_eq else .lt_lt) else if (self.eat('=')) .lt_eq else .lt),
            '>' => self.tok(if (self.eat('>')) (if (self.eat('=')) .gt_gt_eq else .gt_gt) else if (self.eat('=')) .gt_eq else .gt),
            '&' => self.tok(if (self.eat('&')) .amp_amp else if (self.eat('=')) .amp_eq else .amp),
            '|' => self.tok(if (self.eat('|')) .pipe_pipe else if (self.eat('=')) .pipe_eq else .pipe),
            '^' => self.tok(if (self.eat('=')) .caret_eq else .caret),
            '"' => self.strLit('"'),
            '\'' => self.strLit('\''),
            '`' => self.runeLit(),
            '\\' => if (self.eat('\\')) self.multilineStrLit() else self.tok(.err_invalid_char),
            else => self.tok(.err_invalid_char),
        };
    }

    fn skipWS(self: *Lexer) void {
        while (!self.atEnd()) {
            switch (self.peek()) {
                ' ', '\r', '\t' => _ = self.adv(),
                '\n' => {
                    self.line += 1;
                    _ = self.adv();
                    self.line_start = self.pos;
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        while (!self.atEnd() and self.peek() != '\n') _ = self.adv();
                    } else return;
                },
                else => return,
            }
        }
    }

    fn ident(self: *Lexer) Token {
        while (true) {
            const c = self.peek();
            if (common.isAlphaNum(c)) {
                _ = self.adv();
                continue;
            }
            if (c >= 0x80) {
                const cp_len = self.peekCodepointLen();
                if (cp_len > 0) {
                    const cp = self.decodeCodepoint(cp_len);
                    if (unicode.isIdentContinue(cp)) {
                        self.pos += cp_len;
                        continue;
                    }
                }
            }
            break;
        }
        const text = self.src[self.start..self.pos];
        const tt = keyword_map.get(text) orelse .ident;
        return self.tok(tt);
    }

    fn numLit(self: *Lexer) Token {
        while (common.isDigit(self.peek()) or self.peek() == '_') _ = self.adv();
        if (self.peek() == '.' and common.isDigit(self.peekNext())) {
            _ = self.adv();
            while (common.isDigit(self.peek()) or self.peek() == '_') _ = self.adv();
        }
        if (self.peek() == 'e' or self.peek() == 'E') {
            _ = self.adv();
            if (self.peek() == '+' or self.peek() == '-') _ = self.adv();
            while (common.isDigit(self.peek())) _ = self.adv();
        }
        return self.tok(.number);
    }

    fn lineStartFor(self: *Lexer, idx: usize) usize {
        var i = idx;
        while (i > 0 and self.src[i - 1] != '\n') : (i -= 1) {}
        return i;
    }

    fn outByte(self: *Lexer, b: u8) bool {
        if (self.str_pool_pos >= self.str_pool.len) return false;
        self.str_pool[self.str_pool_pos] = b;
        self.str_pool_pos += 1;
        return true;
    }

    fn outEscaped(self: *Lexer, esc: u8) bool {
        return switch (esc) {
            'n' => self.outByte('\n'),
            't' => self.outByte('\t'),
            'r' => self.outByte('\r'),
            '\\' => self.outByte('\\'),
            '"' => self.outByte('"'),
            '\'' => self.outByte('\''),
            else => self.outByte(esc),
        };
    }

    fn tokString(self: *Lexer, start_out: usize) Token {
        const ls = self.lineStartFor(self.start);
        return .{ .typ = .string, .src = self.str_pool[start_out..self.str_pool_pos], .line = self.line, .col = @intCast(self.start - ls + 1) };
    }

    fn strLit(self: *Lexer, quote: u8) Token {
        const start_out = self.str_pool_pos;
        while (!self.atEnd()) {
            const c = self.peek();
            if (c == quote) {
                _ = self.adv();
                return self.tokString(start_out);
            }
            if (c == '\n') return self.tok(.err_unterminated_string);
            if (quote == '"' and c == '\\') {
                _ = self.adv();
                if (self.atEnd()) return self.tok(.err_unterminated_string);
                const esc = self.adv();
                if (!self.outEscaped(esc)) return self.tok(.err_string_pool_exhausted);
                continue;
            }
            _ = self.adv();
            if (!self.outByte(c)) return self.tok(.err_string_pool_exhausted);
        }
        return self.tok(.err_unterminated_string);
    }

    fn multilineStrLit(self: *Lexer) Token {
        const start_out = self.str_pool_pos;
        while (true) {
            // Read content to end of line; no escape processing
            while (!self.atEnd() and self.peek() != '\n') {
                const c = self.adv();
                if (!self.outByte(c)) return self.tok(.err_string_pool_exhausted);
            }
            if (self.atEnd()) break;
            _ = self.adv(); // consume '\n'
            self.line += 1;
            self.line_start = self.pos;
            if (!self.outByte('\n')) return self.tok(.err_string_pool_exhausted);
            // Skip leading whitespace on next line
            while (!self.atEnd() and (self.peek() == ' ' or self.peek() == '\t')) {
                _ = self.adv();
            }
            // Continue only if next line starts with '\\'
            if (!self.atEnd() and self.peek() == '\\' and self.peekNext() == '\\') {
                _ = self.adv();
                _ = self.adv();
                continue;
            }
            break;
        }
        return self.tokString(start_out);
    }

    fn runeLit(self: *Lexer) Token {
        while (!self.atEnd() and self.peek() != '`') {
            if (self.peek() == '\n') return self.tok(.err_unterminated_string);
            _ = self.adv();
        }
        if (self.atEnd()) return self.tok(.err_unterminated_string);
        _ = self.adv(); // closing backtick
        return self.tok(.rune);
    }

    fn tok(self: *Lexer, tt: TT) Token {
        return .{ .typ = tt, .src = self.src[self.start..self.pos], .line = self.line, .col = @intCast((self.start -| self.line_start) + 1) };
    }
    fn adv(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }
    fn eat(self: *Lexer, c: u8) bool {
        if (self.atEnd() or self.src[self.pos] != c) return false;
        self.pos += 1;
        return true;
    }
    fn peek(self: *Lexer) u8 {
        return if (self.atEnd()) 0 else self.src[self.pos];
    }
    fn peekNext(self: *Lexer) u8 {
        return if (self.pos + 1 >= self.src.len) 0 else self.src[self.pos + 1];
    }
    fn atEnd(self: *Lexer) bool {
        return self.pos >= self.src.len;
    }
    fn peekCodepointLen(self: *Lexer) usize {
        if (self.atEnd()) return 0;
        const c = self.src[self.pos];
        return std.unicode.utf8ByteSequenceLength(c) catch 0;
    }
    fn decodeCodepoint(self: *Lexer, len: usize) u21 {
        return std.unicode.utf8Decode(self.src[self.pos..self.pos + len]) catch 0;
    }
};

const testing = std.testing;

test "lexer: keywords" {
    var lex = Lexer{ .src = "assert break case const continue cycle default defer else enum false for func if import in interface message null predicate pub range return struct subtype switch test trap true type var variant" };
    const expected = comptime [_]TT{
        .kw_assert, .kw_break, .kw_case, .kw_const, .kw_continue, .kw_cycle,
        .kw_default, .kw_defer, .kw_else, .kw_enum, .kw_false, .kw_for,
        .kw_func, .kw_if, .kw_import, .kw_in, .kw_interface, .kw_message,
        .kw_null, .kw_predicate, .kw_pub, .kw_range, .kw_return, .kw_struct,
        .kw_subtype, .kw_switch, .kw_test, .kw_trap, .kw_true, .kw_type,
        .kw_var, .kw_variant,
    };
    inline for (expected) |exp| {
        const tok = lex.next();
        try testing.expectEqual(exp, tok.typ);
    }
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: identifiers" {
    var lex = Lexer{ .src = "foo bar _baz hello123" };
    {
        const tok = lex.next();
        try testing.expectEqual(.ident, tok.typ);
        try testing.expectEqualStrings("foo", tok.src);
    }
    {
        const tok = lex.next();
        try testing.expectEqual(.ident, tok.typ);
        try testing.expectEqualStrings("bar", tok.src);
    }
    {
        const tok = lex.next();
        try testing.expectEqual(.ident, tok.typ);
        try testing.expectEqualStrings("_baz", tok.src);
    }
    {
        const tok = lex.next();
        try testing.expectEqual(.ident, tok.typ);
        try testing.expectEqualStrings("hello123", tok.src);
    }
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: non-ASCII start is valid ident" {
    var lex = Lexer{ .src = "λ" };
    const tok = lex.next();
    try testing.expectEqual(.ident, tok.typ);
    try testing.expectEqualStrings("λ", tok.src);
}

test "lexer: ascii ident followed by UTF-8 continues ident" {
    var lex = Lexer{ .src = "aλb" };
    const tok = lex.next();
    try testing.expectEqual(.ident, tok.typ);
    try testing.expectEqualStrings("aλb", tok.src);
}

test "lexer: single-char punctuation" {
    var lex = Lexer{ .src = "(){}[],;:." };
    const expected = comptime [_]TT{
        .lparen, .rparen, .lbrace, .rbrace, .lbracket, .rbracket,
        .comma, .semicolon, .colon, .dot,
    };
    inline for (expected) |exp| try testing.expectEqual(exp, lex.next().typ);
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: operators" {
    var lex = Lexer{ .src = "?~!= == <= >= << >> <<= >>= := += -= *= /= %= &= |= ^= ++ -- ** && ||" };
    const expected = comptime [_]TT{
        .question, .tilde, .bang_eq, .eq_eq, .lt_eq, .gt_eq,
        .lt_lt, .gt_gt, .lt_lt_eq, .gt_gt_eq, .colon_eq,
        .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq,
        .amp_eq, .pipe_eq, .caret_eq,
        .plus_plus, .minus_minus, .star_star, .amp_amp, .pipe_pipe,
    };
    inline for (expected) |exp| try testing.expectEqual(exp, lex.next().typ);
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: single-char + = / . combos" {
    // Tests that prefix operators don't consume extra when not followed by = or .
    var lex = Lexer{ .src = "+ - * / % & | ^ = < > ! ." };
    const expected = comptime [_]TT{ .plus, .minus, .star, .slash, .percent, .amp, .pipe, .caret, .eq, .lt, .gt, .bang, .dot };
    inline for (expected) |exp| try testing.expectEqual(exp, lex.next().typ);
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: ... ellipsis" {
    var lex = Lexer{ .src = "..." };
    try testing.expectEqual(.ellipsis, lex.next().typ);
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: integer literals" {
    var lex = Lexer{ .src = "0 42 1_000" };
    {
        const tok = lex.next();
        try testing.expectEqual(.number, tok.typ);
        try testing.expectEqualStrings("0", tok.src);
    }
    {
        const tok = lex.next();
        try testing.expectEqual(.number, tok.typ);
        try testing.expectEqualStrings("42", tok.src);
    }
    {
        const tok = lex.next();
        try testing.expectEqual(.number, tok.typ);
        try testing.expectEqualStrings("1_000", tok.src);
    }
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: float literals" {
    var lex = Lexer{ .src = "3.14 0.5 1.0 1_000.5 1e10 2.5e-3 1E+2" };
    const expected = comptime [_][]const u8{ "3.14", "0.5", "1.0", "1_000.5", "1e10", "2.5e-3", "1E+2" };
    inline for (expected) |exp| {
        const tok = lex.next();
        try testing.expectEqual(.number, tok.typ);
        try testing.expectEqualStrings(exp, tok.src);
    }
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: number with leading zeros" {
    var lex = Lexer{ .src = "007" };
    const tok = lex.next();
    try testing.expectEqual(.number, tok.typ);
    try testing.expectEqualStrings("007", tok.src);
}

test "lexer: string literal" {
    var lex = Lexer{ .src = "\"hello\"" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("hello", tok.src);
}

test "lexer: string literal with escape sequences" {
    var lex = Lexer{ .src = "\"hello\\nworld\\ttab\"" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("hello\nworld\ttab", tok.src);
}

test "lexer: string literal with backslash and quote escapes" {
    var lex = Lexer{ .src = "\"a\\\\b\\\"c\\'\"" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("a\\b\"c'", tok.src);
}

test "lexer: string literal with unknown escape passes through" {
    var lex = Lexer{ .src = "\"\\x\"" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("x", tok.src);
}

test "lexer: unterminated double-quoted string" {
    var lex = Lexer{ .src = "\"hello" };
    try testing.expectEqual(.err_unterminated_string, lex.next().typ);
}

test "lexer: string with embedded newline returns error" {
    var lex = Lexer{ .src = "\"hello\nworld\"" };
    try testing.expectEqual(.err_unterminated_string, lex.next().typ);
}

test "lexer: char literal" {
    var lex = Lexer{ .src = "'a'" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("a", tok.src);
}

test "lexer: char literal with escape not processed in single quotes" {
    var lex = Lexer{ .src = "'\\n'" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("\\n", tok.src);
}

test "lexer: char literal with escaped quote" {
    var lex = Lexer{ .src = "'\\''" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("\\", tok.src);
}

test "lexer: unterminated single-quoted string" {
    var lex = Lexer{ .src = "'hello" };
    try testing.expectEqual(.err_unterminated_string, lex.next().typ);
}

test "lexer: rune literal" {
    var lex = Lexer{ .src = "`a`" };
    const tok = lex.next();
    try testing.expectEqual(.rune, tok.typ);
    try testing.expectEqualStrings("`a`", tok.src);
}

test "lexer: rune literal multi-byte UTF-8" {
    var lex = Lexer{ .src = "`λ`" };
    const tok = lex.next();
    try testing.expectEqual(.rune, tok.typ);
    try testing.expectEqualStrings("`λ`", tok.src);
}

test "lexer: empty rune" {
    var lex = Lexer{ .src = "``" };
    const tok = lex.next();
    try testing.expectEqual(.rune, tok.typ);
    try testing.expectEqualStrings("``", tok.src);
}

test "lexer: multi-codepoint rune" {
    var lex = Lexer{ .src = "`ab`" };
    const tok = lex.next();
    try testing.expectEqual(.rune, tok.typ);
    try testing.expectEqualStrings("`ab`", tok.src);
}

test "lexer: unterminated rune" {
    var lex = Lexer{ .src = "`hello" };
    try testing.expectEqual(.err_unterminated_string, lex.next().typ);
}

test "lexer: rune with embedded newline returns error" {
    var lex = Lexer{ .src = "`hello\nworld`" };
    try testing.expectEqual(.err_unterminated_string, lex.next().typ);
}

test "lexer: multiline string" {
    var lex = Lexer{ .src = "\\\\hello\n\\\\world" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("hello\nworld", tok.src);
}

test "lexer: multiline string with whitespace continuation" {
    var lex = Lexer{ .src = "\\\\hello\n  \\\\world" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("hello\nworld", tok.src);
}

test "lexer: multiline string stops at line without continuation" {
    var lex = Lexer{ .src = "\\\\hello\nworld" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("hello\n", tok.src);
}

test "lexer: multiline string single line" {
    var lex = Lexer{ .src = "\\\\hello" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("hello", tok.src);
}

test "lexer: multiline string empty body" {
    var lex = Lexer{ .src = "\\\\\n\\\\world" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("\nworld", tok.src);
}

test "lexer: multiline string at EOF" {
    var lex = Lexer{ .src = "\\\\\n" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("\n", tok.src);
}

test "lexer: double backslash alone" {
    var lex = Lexer{ .src = "\\\\" };
    const tok = lex.next();
    try testing.expectEqual(.string, tok.typ);
    try testing.expectEqualStrings("", tok.src);
}

test "lexer: single backslash is invalid" {
    var lex = Lexer{ .src = "\\a" };
    try testing.expectEqual(.err_invalid_char, lex.next().typ);
}

test "lexer: line numbers start at 1" {
    var lex = Lexer{ .src = "a" };
    try testing.expectEqual(@as(u32, 1), lex.next().line);
}

test "lexer: column numbers start at 1" {
    var lex = Lexer{ .src = "a" };
    try testing.expectEqual(@as(u32, 1), lex.next().col);
}

test "lexer: line incremented after newline" {
    var lex = Lexer{ .src = "a\nb" };
    const tok1 = lex.next();
    try testing.expectEqual(@as(u32, 1), tok1.line);
    const tok2 = lex.next();
    try testing.expectEqual(@as(u32, 2), tok2.line);
}

test "lexer: column reset after newline" {
    var lex = Lexer{ .src = "abc\nd" };
    _ = lex.next();
    const tok = lex.next();
    try testing.expectEqual(@as(u32, 2), tok.line);
    try testing.expectEqual(@as(u32, 1), tok.col);
}

test "lexer: column tracks byte offset" {
    var lex = Lexer{ .src = "  x" };
    const tok = lex.next();
    try testing.expectEqual(@as(u32, 3), tok.col);
}

test "lexer: column in string literal" {
    var lex = Lexer{ .src = "\"hi\"" };
    const tok = lex.next();
    try testing.expectEqual(@as(u32, 1), tok.col);
}

test "lexer: string literal column on same line" {
    var lex = Lexer{ .src = "x \"hi\"" };
    _ = lex.next();
    const tok = lex.next();
    try testing.expectEqual(@as(u32, 3), tok.col);
}

test "lexer: comment skipped" {
    var lex = Lexer{ .src = "a // comment\nb" };
    {
        const tok = lex.next();
        try testing.expectEqual(.ident, tok.typ);
        try testing.expectEqualStrings("a", tok.src);
    }
    {
        const tok = lex.next();
        try testing.expectEqual(.ident, tok.typ);
        try testing.expectEqualStrings("b", tok.src);
    }
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: comment at end of file" {
    var lex = Lexer{ .src = "a // comment" };
    const tok = lex.next();
    try testing.expectEqual(.ident, tok.typ);
    try testing.expectEqualStrings("a", tok.src);
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: EOF returns eof repeatedly" {
    var lex = Lexer{ .src = "" };
    try testing.expectEqual(.eof, lex.next().typ);
    try testing.expectEqual(.eof, lex.next().typ);
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: only whitespace returns eof" {
    var lex = Lexer{ .src = "   \t  \n  " };
    try testing.expectEqual(.eof, lex.next().typ);
}

test "lexer: invalid character" {
    var lex = Lexer{ .src = "@" };
    try testing.expectEqual(.err_invalid_char, lex.next().typ);
}

test "lexer: identifier with underscore prefix" {
    var lex = Lexer{ .src = "_foo _123" };
    {
        const tok = lex.next();
        try testing.expectEqual(.ident, tok.typ);
        try testing.expectEqualStrings("_foo", tok.src);
    }
    {
        const tok = lex.next();
        try testing.expectEqual(.ident, tok.typ);
        try testing.expectEqualStrings("_123", tok.src);
    }
    try testing.expectEqual(.eof, lex.next().typ);
}
