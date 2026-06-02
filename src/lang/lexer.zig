const common = @import("common.zig");
const token = @import("token.zig");
const TT = token.TT;
const Token = token.Token;

pub const Lexer = struct {
    src: []const u8,
    start: usize = 0,
    pos: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    str_pool: [128 * 1024]u8 = undefined,
    str_pool_pos: usize = 0,

    pub fn next(self: *Lexer) Token {
        self.skipWS();
        self.start = self.pos;
        if (self.atEnd()) return self.tok(.eof);
        const c = self.adv();
        if (common.isAlpha(c)) return self.ident();
        if (common.isDigit(c)) return self.numLit();
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
            '*' => self.tok(if (self.eat('=')) .star_eq else .star),
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
        while (common.isAlphaNum(self.peek())) _ = self.adv();
        const text = self.src[self.start..self.pos];
        const tt: TT =
            if (common.streq(text, "true")) .kw_true else if (common.streq(text, "false")) .kw_false else if (common.streq(text, "null")) .kw_null else if (common.streq(text, "if")) .kw_if else if (common.streq(text, "else")) .kw_else else if (common.streq(text, "for")) .kw_for else if (common.streq(text, "in")) .kw_in else if (common.streq(text, "switch")) .kw_switch else if (common.streq(text, "case")) .kw_case else if (common.streq(text, "default")) .kw_default else if (common.streq(text, "return")) .kw_return else if (common.streq(text, "func")) .kw_func else if (common.streq(text, "struct")) .kw_struct else if (common.streq(text, "interface")) .kw_interface else if (common.streq(text, "type")) .kw_type else if (common.streq(text, "range")) .kw_range else if (common.streq(text, "cycle")) .kw_cycle else if (common.streq(text, "enum")) .kw_enum else if (common.streq(text, "import")) .kw_import else if (common.streq(text, "const")) .kw_const else if (common.streq(text, "break")) .kw_break else if (common.streq(text, "continue")) .kw_continue else if (common.streq(text, "defer")) .kw_defer else if (common.streq(text, "assert")) .kw_assert else if (common.streq(text, "trap")) .kw_trap else if (common.streq(text, "variant")) .kw_variant else if (common.streq(text, "subtype")) .kw_subtype else if (common.streq(text, "pub")) .kw_pub else .ident;
        return self.tok(tt);
    }

    fn numLit(self: *Lexer) Token {
        while (common.isDigit(self.peek())) _ = self.adv();
        if (self.peek() == '.' and common.isDigit(self.peekNext())) {
            _ = self.adv();
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
                if (!self.outEscaped(esc)) return self.tok(.err_unterminated_string);
                continue;
            }
            _ = self.adv();
            if (!self.outByte(c)) return self.tok(.err_unterminated_string);
        }
        return self.tok(.err_unterminated_string);
    }

    fn multilineStrLit(self: *Lexer) Token {
        const start_out = self.str_pool_pos;
        while (true) {
            // Read content to end of line; no escape processing
            while (!self.atEnd() and self.peek() != '\n') {
                const c = self.adv();
                if (!self.outByte(c)) return self.tok(.eof);
            }
            if (self.atEnd()) break;
            _ = self.adv(); // consume '\n'
            self.line += 1;
            self.line_start = self.pos;
            if (!self.outByte('\n')) return self.tok(.eof);
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
};
