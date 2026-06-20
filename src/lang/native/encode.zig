const std = @import("std");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

pub fn nativeHexEncode(s: []const u8) !Value {
    const obj = try vmgc.allocTempRooted(.{ .dyn_string = &[_]u8{} });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(s.len * 2);
    for (s, 0..) |b, i| {
        const hi = @as(u8, @intCast((b >> 4) & 0xf));
        const lo = @as(u8, @intCast(b & 0xf));
        buf[i * 2] = if (hi < 10) '0' + hi else 'a' + hi - 10;
        buf[i * 2 + 1] = if (lo < 10) '0' + lo else 'a' + lo - 10;
    }
    obj.* = .{ .dyn_string = buf[0 .. s.len * 2] };
    return .{ .object = obj };
}

pub fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.TypeError,
    };
}

pub fn nativeHexDecode(s: []const u8) !Value {
    if (s.len % 2 != 0) return error.TypeError;
    const obj = try vmgc.allocTempRooted(.{ .dyn_string = &[_]u8{} });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(s.len / 2);
    var i: usize = 0;
    while (i < s.len) : (i += 2) {
        const hi = try hexNibble(s[i]);
        const lo = try hexNibble(s[i + 1]);
        buf[i / 2] = (hi << 4) | lo;
    }
    obj.* = .{ .dyn_string = buf[0 .. s.len / 2] };
    return .{ .object = obj };
}

pub fn b64Unpack(c: u8, url_safe: bool) !u6 {
    return switch (c) {
        'A'...'Z' => @as(u6, @intCast(c - 'A')),
        'a'...'z' => @as(u6, @intCast(c - 'a' + 26)),
        '0'...'9' => @as(u6, @intCast(c - '0' + 52)),
        '+' => if (url_safe) error.TypeError else 62,
        '/' => if (url_safe) error.TypeError else 63,
        '-' => if (url_safe) 62 else error.TypeError,
        '_' => if (url_safe) 63 else error.TypeError,
        else => error.TypeError,
    };
}

pub fn nativeBase64Encode(s: []const u8, url_safe: bool) !Value {
    const alphabet = if (url_safe) "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" else "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const out_len = ((s.len + 2) / 3) * 4;
    const obj = try vmgc.allocTempRooted(.{ .dyn_string = &[_]u8{} });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(out_len);
    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 <= s.len) {
        const a = s[i];
        const b = s[i + 1];
        const c = s[i + 2];
        buf[o] = alphabet[@as(usize, @intCast((a >> 2) & 0x3f))];
        buf[o + 1] = alphabet[@as(usize, @intCast(((a << 4) | (b >> 4)) & 0x3f))];
        buf[o + 2] = alphabet[@as(usize, @intCast(((b << 2) | (c >> 6)) & 0x3f))];
        buf[o + 3] = alphabet[@as(usize, @intCast(c & 0x3f))];
        i += 3;
        o += 4;
    }
    const rem = s.len - i;
    if (rem == 1) {
        const a = s[i];
        buf[o] = alphabet[@as(usize, @intCast((a >> 2) & 0x3f))];
        buf[o + 1] = alphabet[@as(usize, @intCast((a << 4) & 0x3f))];
        buf[o + 2] = '=';
        buf[o + 3] = '=';
    } else if (rem == 2) {
        const a = s[i];
        const b = s[i + 1];
        buf[o] = alphabet[@as(usize, @intCast((a >> 2) & 0x3f))];
        buf[o + 1] = alphabet[@as(usize, @intCast(((a << 4) | (b >> 4)) & 0x3f))];
        buf[o + 2] = alphabet[@as(usize, @intCast((b << 2) & 0x3f))];
        buf[o + 3] = '=';
    }
    obj.* = .{ .dyn_string = buf[0..out_len] };
    return .{ .object = obj };
}

pub fn nativeBase64Decode(s: []const u8, url_safe: bool) !Value {
    if (s.len % 4 != 0) return error.TypeError;
    var pad: usize = 0;
    if (s.len >= 2 and s[s.len - 1] == '=') pad += 1;
    if (s.len >= 2 and s[s.len - 2] == '=') pad += 1;
    const out_len = (s.len / 4) * 3 - pad;
    const obj = try vmgc.allocTempRooted(.{ .dyn_string = &[_]u8{} });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(out_len);
    var i: usize = 0;
    var o: usize = 0;
    const end = s.len - pad;
    while (i + 4 <= end) {
        const a = try b64Unpack(s[i], url_safe);
        const b = try b64Unpack(s[i + 1], url_safe);
        const c = try b64Unpack(s[i + 2], url_safe);
        const d = try b64Unpack(s[i + 3], url_safe);
        buf[o] = (@as(u8, a) << 2) | (b >> 4);
        buf[o + 1] = (@as(u8, b) << 4) | (c >> 2);
        buf[o + 2] = (@as(u8, c) << 6) | d;
        i += 4;
        o += 3;
    }
    if (end < s.len) {
        const a = try b64Unpack(s[end - (4 - pad)], url_safe);
        const b = try b64Unpack(s[end - (4 - pad) + 1], url_safe);
        if (pad == 1) {
            const c = try b64Unpack(s[end - (4 - pad) + 2], url_safe);
            buf[o] = (@as(u8, a) << 2) | (b >> 4);
            buf[o + 1] = (@as(u8, b) << 4) | (c >> 2);
        } else {
            buf[o] = (@as(u8, a) << 2) | (b >> 4);
        }
    }
    obj.* = .{ .dyn_string = buf[0..out_len] };
    return .{ .object = obj };
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .base64_decode => {
            const s = try vms.asStringValue(vms.vmTop(0));
            const out = try nativeBase64Decode(s, false);
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .base64_encode => {
            const s = try vms.asStringValue(vms.vmTop(0));
            const out = try nativeBase64Encode(s, false);
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .base64_url_decode => {
            const s = try vms.asStringValue(vms.vmTop(0));
            const out = try nativeBase64Decode(s, true);
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .base64_url_encode => {
            const s = try vms.asStringValue(vms.vmTop(0));
            const out = try nativeBase64Encode(s, true);
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .hex_decode => {
            const s = try vms.asStringValue(vms.vmTop(0));
            const out = try nativeHexDecode(s);
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .hex_encode => {
            const s = try vms.asStringValue(vms.vmTop(0));
            const out = try nativeHexEncode(s);
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        else => {},
    }
}
