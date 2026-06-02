pub fn streq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

pub fn hashBytes(s: []const u8) u64 {
    var h: u64 = 1469598103934665603; // FNV-1a 64-bit offset basis
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        h ^= @as(u64, s[i]);
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
