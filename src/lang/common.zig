pub fn streq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (ca != cb) return false;
    return true;
}

pub fn hashBytes(s: []const u8) u64 {
    var h: u64 = 1469598103934665603; // FNV-1a 64-bit offset basis
    for (s) |byte| {
        h ^= @as(u64, byte);
        h *%= 1099511628211; // FNV-1a 64-bit prime
    }
    return h;
}

const std = @import("std");

pub fn parseFloat(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[i] == '-') { neg = true; i += 1; }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    if (s[i] == '0' and i + 1 < s.len) {
        const prefix = s[i + 1];
        // Hex: 0x… / 0X…
        if (prefix == 'x' or prefix == 'X') {
            i += 2;
            if (i >= s.len) return null;
            var v: u64 = 0;
            while (i < s.len) : (i += 1) {
                const ch = s[i];
                if (ch == '_') continue;
                const nib: u8 = if (ch >= '0' and ch <= '9') ch - '0'
                                else if (ch >= 'a' and ch <= 'f') ch - 'a' + 10
                                else if (ch >= 'A' and ch <= 'F') ch - 'A' + 10
                                else return null;
                v = v * 16 + nib;
            }
            const r: f64 = @floatFromInt(v);
            return if (neg) -r else r;
        }
        // Binary: 0b… / 0B…
        if (prefix == 'b' or prefix == 'B') {
            i += 2;
            if (i >= s.len) return null;
            var v: u64 = 0;
            while (i < s.len) : (i += 1) {
                const ch = s[i];
                if (ch == '_') continue;
                if (ch != '0' and ch != '1') return null;
                v = v * 2 + (ch - '0');
            }
            const r: f64 = @floatFromInt(v);
            return if (neg) -r else r;
        }
        // Octal: 0o… / 0O…
        if (prefix == 'o' or prefix == 'O') {
            i += 2;
            if (i >= s.len) return null;
            var v: u64 = 0;
            while (i < s.len) : (i += 1) {
                const ch = s[i];
                if (ch == '_') continue;
                if (ch < '0' or ch > '7') return null;
                v = v * 8 + (ch - '0');
            }
            const r: f64 = @floatFromInt(v);
            return if (neg) -r else r;
        }
    }
    var ip: f64 = 0;
    while (i < s.len and (s[i] == '_' or (s[i] >= '0' and s[i] <= '9'))) : (i += 1) {
        if (s[i] != '_') ip = ip * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
    }
    var fp: f64 = 0;
    var fd: f64 = 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and (s[i] == '_' or (s[i] >= '0' and s[i] <= '9'))) : (i += 1) {
            if (s[i] != '_') {
                fp = fp * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
                fd *= 10.0;
            }
        }
    }
    var exp: f64 = 0;
    var exp_neg = false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and s[i] == '-') { exp_neg = true; i += 1; }
        else if (i < s.len and s[i] == '+') i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            exp = exp * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
        }
    }
    if (i != s.len) return null;
    var r = ip + fp / fd;
    if (exp != 0) {
        const scale = std.math.pow(f64, 10.0, exp);
        if (exp_neg) r /= scale else r *= scale;
    }
    if (neg) r = -r;
    return r;
}

// Parse an integer literal (decimal, 0x hex, 0b binary, 0o octal) as i64.
// Avoids the f64 round-trip that parseFloat uses, preserving all 64 bits.
// Returns null if the input is not a valid integer literal.
pub fn parseInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[i] == '-') { neg = true; i += 1; }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    if (s[i] == '0' and i + 1 < s.len) {
        const prefix = s[i + 1];
        if (prefix == 'x' or prefix == 'X') {
            i += 2;
            if (i >= s.len) return null;
            var v: u64 = 0;
            while (i < s.len) : (i += 1) {
                const ch = s[i];
                if (ch == '_') continue;
                const nib: u64 = if (ch >= '0' and ch <= '9') ch - '0'
                                  else if (ch >= 'a' and ch <= 'f') ch - 'a' + 10
                                  else if (ch >= 'A' and ch <= 'F') ch - 'A' + 10
                                  else return null;
                v = v *% 16 +% nib;
            }
            return if (neg) -@as(i64, @bitCast(v)) else @as(i64, @bitCast(v));
        }
        if (prefix == 'b' or prefix == 'B') {
            i += 2;
            if (i >= s.len) return null;
            var v: u64 = 0;
            while (i < s.len) : (i += 1) {
                const ch = s[i];
                if (ch == '_') continue;
                if (ch != '0' and ch != '1') return null;
                v = v *% 2 +% (ch - '0');
            }
            return if (neg) -@as(i64, @bitCast(v)) else @as(i64, @bitCast(v));
        }
        if (prefix == 'o' or prefix == 'O') {
            i += 2;
            if (i >= s.len) return null;
            var v: u64 = 0;
            while (i < s.len) : (i += 1) {
                const ch = s[i];
                if (ch == '_') continue;
                if (ch < '0' or ch > '7') return null;
                v = v *% 8 +% (ch - '0');
            }
            return if (neg) -@as(i64, @bitCast(v)) else @as(i64, @bitCast(v));
        }
    }
    // Decimal integer (no '.' or 'e'/'E' — caller must verify)
    var v: u64 = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '_') continue;
        if (ch < '0' or ch > '9') return null;
        v = v *% 10 +% (ch - '0');
    }
    return if (neg) -@as(i64, @bitCast(v)) else @as(i64, @bitCast(v));
}

pub fn fmod(a: f64, b: f64) f64 {
    if (b == 0.0) return 0.0;
    return a - @trunc(a / b) * b;
}

pub fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isAlphaNum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}
