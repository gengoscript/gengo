const std = @import("std");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

fn makeBinaryString(ctx: VMContext, bytes: []const u8) !Value {
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, bytes.len);
    @memcpy(buf[0..bytes.len], bytes);
    obj.* = .{ .dyn_string = buf[0..bytes.len] };
    return .{ .object = obj };
}

fn argAsI64(v: Value) !i64 {
    return switch (v) {
        .int => |n| n,
        .float => |n| @as(i64, @intFromFloat(n)),
        else => error.TypeError,
    };
}

fn readU16be(s: []const u8, i: usize) !i64 {
    if (i + 2 > s.len) return error.RangeError;
    const n: u16 = (@as(u16, s[i]) << 8) | s[i + 1];
    return @as(i64, n);
}

fn readU32be(s: []const u8, i: usize) !i64 {
    if (i + 4 > s.len) return error.RangeError;
    const n: u32 = (@as(u32, s[i]) << 24) | (@as(u32, s[i + 1]) << 16) |
        (@as(u32, s[i + 2]) << 8) | @as(u32, s[i + 3]);
    return @as(i64, n);
}

fn readU64be(s: []const u8, i: usize) !i64 {
    if (i + 8 > s.len) return error.RangeError;
    var n: u64 = 0;
    for (0..8) |k| n = (n << 8) | s[i + k];
    return @as(i64, @bitCast(n));
}

fn readU16le(s: []const u8, i: usize) !i64 {
    if (i + 2 > s.len) return error.RangeError;
    const n: u16 = @as(u16, s[i]) | (@as(u16, s[i + 1]) << 8);
    return @as(i64, n);
}

fn readU32le(s: []const u8, i: usize) !i64 {
    if (i + 4 > s.len) return error.RangeError;
    const n: u32 = @as(u32, s[i]) | (@as(u32, s[i + 1]) << 8) |
        (@as(u32, s[i + 2]) << 16) | (@as(u32, s[i + 3]) << 24);
    return @as(i64, n);
}

fn readU64le(s: []const u8, i: usize) !i64 {
    if (i + 8 > s.len) return error.RangeError;
    var n: u64 = 0;
    for (0..8) |k| n |= @as(u64, s[i + k]) << @as(u6, @intCast(k * 8));
    return @as(i64, @bitCast(n));
}

fn readF32be(s: []const u8, i: usize) !f64 {
    if (i + 4 > s.len) return error.RangeError;
    const bits: u32 = (@as(u32, s[i]) << 24) | (@as(u32, s[i + 1]) << 16) |
        (@as(u32, s[i + 2]) << 8) | @as(u32, s[i + 3]);
    return @as(f64, @as(f32, @bitCast(bits)));
}

fn readF32le(s: []const u8, i: usize) !f64 {
    if (i + 4 > s.len) return error.RangeError;
    const bits: u32 = @as(u32, s[i]) | (@as(u32, s[i + 1]) << 8) |
        (@as(u32, s[i + 2]) << 16) | (@as(u32, s[i + 3]) << 24);
    return @as(f64, @as(f32, @bitCast(bits)));
}

fn readF64be(s: []const u8, i: usize) !f64 {
    if (i + 8 > s.len) return error.RangeError;
    var bits: u64 = 0;
    for (0..8) |k| bits = (bits << 8) | s[i + k];
    return @bitCast(bits);
}

fn readF64le(s: []const u8, i: usize) !f64 {
    if (i + 8 > s.len) return error.RangeError;
    var bits: u64 = 0;
    for (0..8) |k| bits |= @as(u64, s[i + k]) << @as(u6, @intCast(k * 8));
    return @bitCast(bits);
}

// Single source of truth for every "decode a fixed-width value from a byte
// string at an offset" operation — called both by the native dispatch below
// (bytes_at/bytes_u16be_at/...) and by the VM's dedicated .bytes_decode op
// (see op.zig), so the two paths can never behave differently. Mirrors the
// exact bounds-check style each variant already had: byte_at compares as i64
// (catches a negative offset cleanly); the multi-byte reads cast to usize
// first (an existing, unchanged behavior — not something introduced here).
pub const DecodeKind = enum(u8) {
    byte_at = 0,
    u16be = 1,
    u16le = 2,
    u32be = 3,
    u32le = 4,
    u64be = 5,
    u64le = 6,
    f32be = 7,
    f32le = 8,
    f64be = 9,
    f64le = 10,
};

pub fn decodeAt(kind: DecodeKind, s: []const u8, offset_arg: Value) !Value {
    switch (kind) {
        .byte_at => {
            const idx = try argAsI64(offset_arg);
            if (idx < 0 or idx >= @as(i64, @intCast(s.len))) return error.RangeError;
            return .{ .int = @as(i64, s[@as(usize, @intCast(idx))]) };
        },
        .u16be => return .{ .int = try readU16be(s, @intCast(try argAsI64(offset_arg))) },
        .u16le => return .{ .int = try readU16le(s, @intCast(try argAsI64(offset_arg))) },
        .u32be => return .{ .int = try readU32be(s, @intCast(try argAsI64(offset_arg))) },
        .u32le => return .{ .int = try readU32le(s, @intCast(try argAsI64(offset_arg))) },
        .u64be => return .{ .int = try readU64be(s, @intCast(try argAsI64(offset_arg))) },
        .u64le => return .{ .int = try readU64le(s, @intCast(try argAsI64(offset_arg))) },
        .f32be => return .{ .float = try readF32be(s, @intCast(try argAsI64(offset_arg))) },
        .f32le => return .{ .float = try readF32le(s, @intCast(try argAsI64(offset_arg))) },
        .f64be => return .{ .float = try readF64be(s, @intCast(try argAsI64(offset_arg))) },
        .f64le => return .{ .float = try readF64le(s, @intCast(try argAsI64(offset_arg))) },
    }
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .bytes_u8 => {
            const n: u8 = @truncate(@as(u64, @bitCast(try argAsI64(ctx.vs.vmTop(0)))) & 0xFF);
            const buf = [_]u8{n};
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_pack => {
            const arr_val = ctx.vs.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_val.object)).len;
            const buf = try vmgc.vmAllocManagedBytes(ctx, items_len);
            // Re-derive after the allocation above, which can compact and
            // relocate arr_val.object's backing.
            const items = try vms.asArraySlice(arr_val.object);
            for (items, 0..) |item, i| {
                const n = try argAsI64(item);
                buf[i] = @truncate(@as(u64, @bitCast(n)) & 0xFF);
            }
            const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
            defer ctx.vs.popTempRoot();
            obj.* = .{ .dyn_string = buf[0..items.len] };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = obj });
        },
        .bytes_unpack => {
            const s = try vms.asStringValue(ctx.vs.vmTop(0));
            const out_items = try vmgc.vmAllocManagedSlice(ctx, Value, s.len);
            for (s, 0..) |b, i| out_items[i] = .{ .int = @as(i64, b) };
            const obj = try vmgc.vmAllocObject(ctx);
            obj.* = .{ .array_managed = out_items[0..s.len] };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = obj });
        },
        .bytes_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.byte_at, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_len => {
            const s = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .int = @as(i64, @intCast(s.len)) });
        },
        .bytes_slice => {
            const src_val = ctx.vs.vmTop(2);
            const from = try argAsI64(ctx.vs.vmTop(1));
            const to = try argAsI64(ctx.vs.vmTop(0));
            // When the source is a GC-managed string object, return a zero-copy
            // string_view instead of allocating and copying bytes.  The view keeps
            // the source object alive via its .source pointer, so the backing buffer
            // is never freed while the view exists.  Static constant-pool strings
            // (.string tag) are immortal; they still require a copy via the slow path.
            if (src_val == .object) {
                const src_obj = src_val.object;
                switch (src_obj.*) {
                    .dyn_string => |s| {
                        const slen = @as(i64, @intCast(s.len));
                        if (from < 0 or to < from or to > slen) return error.RangeError;
                        const f = @as(usize, @intCast(from));
                        const t_idx = @as(usize, @intCast(to));
                        // src_obj is still on the VM stack (vmTop(2)), so GC keeps it
                        // alive through the vmAllocObject call inside makeStringView.
                        const result = try vmgc.makeStringView(ctx, s[f..t_idx], src_obj);
                        ctx.vs.vmPopArgs(argc);
                        try ctx.vs.vmPush(result);
                        return;
                    },
                    .string_view => |sv| {
                        const slen = @as(i64, @intCast(sv.bytes.len));
                        if (from < 0 or to < from or to > slen) return error.RangeError;
                        const f = @as(usize, @intCast(from));
                        const t_idx = @as(usize, @intCast(to));
                        // Chase through to the owning dyn_string so the view graph
                        // stays shallow: a view of a view still points at the root.
                        const result = try vmgc.makeStringView(ctx, sv.bytes[f..t_idx], sv.source);
                        ctx.vs.vmPopArgs(argc);
                        try ctx.vs.vmPush(result);
                        return;
                    },
                    else => return error.TypeError,
                }
            }
            // Slow path: static string — must copy since it has no GC object header.
            const s = try vms.asStringValue(src_val);
            const slen = @as(i64, @intCast(s.len));
            if (from < 0 or to < from or to > slen) return error.RangeError;
            const f = @as(usize, @intCast(from));
            const t_idx = @as(usize, @intCast(to));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, s[f..t_idx]));
        },
        .bytes_repeat => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const n = try argAsI64(ctx.vs.vmTop(0));
            if (n < 0) return error.RangeError;
            const count = @as(usize, @intCast(n));
            const total = s.len * count;
            const buf = try vmgc.vmAllocManagedBytes(ctx, total);
            for (0..count) |i| @memcpy(buf[i * s.len .. (i + 1) * s.len], s);
            const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
            defer ctx.vs.popTempRoot();
            obj.* = .{ .dyn_string = buf[0..total] };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = obj });
        },
        // ── Integer encoding ─────────────────────────────────────────────────
        .bytes_u16be => {
            const n: u16 = @truncate(@as(u64, @bitCast(try argAsI64(ctx.vs.vmTop(0)))) & 0xFFFF);
            const buf = [_]u8{ @as(u8, @intCast((n >> 8) & 0xFF)), @as(u8, @intCast(n & 0xFF)) };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_u32be => {
            const n: u32 = @truncate(@as(u64, @bitCast(try argAsI64(ctx.vs.vmTop(0)))) & 0xFFFFFFFF);
            const buf = [_]u8{
                @as(u8, @intCast((n >> 24) & 0xFF)), @as(u8, @intCast((n >> 16) & 0xFF)),
                @as(u8, @intCast((n >> 8) & 0xFF)),  @as(u8, @intCast(n & 0xFF)),
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_u64be => {
            const raw = @as(u64, @bitCast(try argAsI64(ctx.vs.vmTop(0))));
            const buf = [_]u8{
                @as(u8, @intCast((raw >> 56) & 0xFF)), @as(u8, @intCast((raw >> 48) & 0xFF)),
                @as(u8, @intCast((raw >> 40) & 0xFF)), @as(u8, @intCast((raw >> 32) & 0xFF)),
                @as(u8, @intCast((raw >> 24) & 0xFF)), @as(u8, @intCast((raw >> 16) & 0xFF)),
                @as(u8, @intCast((raw >> 8) & 0xFF)),  @as(u8, @intCast(raw & 0xFF)),
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_u16le => {
            const n: u16 = @truncate(@as(u64, @bitCast(try argAsI64(ctx.vs.vmTop(0)))) & 0xFFFF);
            const buf = [_]u8{ @as(u8, @intCast(n & 0xFF)), @as(u8, @intCast((n >> 8) & 0xFF)) };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_u32le => {
            const n: u32 = @truncate(@as(u64, @bitCast(try argAsI64(ctx.vs.vmTop(0)))) & 0xFFFFFFFF);
            const buf = [_]u8{
                @as(u8, @intCast(n & 0xFF)),         @as(u8, @intCast((n >> 8) & 0xFF)),
                @as(u8, @intCast((n >> 16) & 0xFF)), @as(u8, @intCast((n >> 24) & 0xFF)),
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_u64le => {
            const raw = @as(u64, @bitCast(try argAsI64(ctx.vs.vmTop(0))));
            const buf = [_]u8{
                @as(u8, @intCast(raw & 0xFF)),         @as(u8, @intCast((raw >> 8) & 0xFF)),
                @as(u8, @intCast((raw >> 16) & 0xFF)), @as(u8, @intCast((raw >> 24) & 0xFF)),
                @as(u8, @intCast((raw >> 32) & 0xFF)), @as(u8, @intCast((raw >> 40) & 0xFF)),
                @as(u8, @intCast((raw >> 48) & 0xFF)), @as(u8, @intCast((raw >> 56) & 0xFF)),
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        // ── Integer decoding ─────────────────────────────────────────────────
        .bytes_u16be_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.u16be, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_u32be_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.u32be, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_u64be_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.u64be, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_u16le_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.u16le, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_u32le_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.u32le, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_u64le_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.u64le, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        // ── Byte-level search ────────────────────────────────────────────────
        .bytes_index_of => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const sub = try vms.asStringValue(ctx.vs.vmTop(0));
            const idx: i64 = if (std.mem.indexOf(u8, s, sub)) |pos| @as(i64, @intCast(pos)) else -1;
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .int = idx });
        },
        .bytes_contains => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const sub = try vms.asStringValue(ctx.vs.vmTop(0));
            const found = std.mem.indexOf(u8, s, sub) != null;
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = found });
        },
        .bytes_starts_with => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const pre = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = std.mem.startsWith(u8, s, pre) });
        },
        .bytes_ends_with => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const suf = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = std.mem.endsWith(u8, s, suf) });
        },
        .bytes_count => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const sub = try vms.asStringValue(ctx.vs.vmTop(0));
            var cnt: i64 = 0;
            if (sub.len == 0) {
                cnt = @as(i64, @intCast(s.len + 1));
            } else {
                var pos: usize = 0;
                while (std.mem.indexOf(u8, s[pos..], sub)) |found| {
                    cnt += 1;
                    pos += found + sub.len;
                }
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .int = cnt });
        },
        .bytes_replace => {
            const s_val = ctx.vs.vmTop(2);
            const old_val = ctx.vs.vmTop(1);
            const new_val = ctx.vs.vmTop(0);
            const s = try vms.asStringValue(s_val);
            const old_s = try vms.asStringValue(old_val);
            const new_s = try vms.asStringValue(new_val);
            if (old_s.len == 0) {
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(try makeBinaryString(ctx, s));
                return;
            }
            var cnt: usize = 0;
            var pos: usize = 0;
            while (std.mem.indexOf(u8, s[pos..], old_s)) |found| {
                cnt += 1;
                pos += found + old_s.len;
            }
            if (cnt == 0) {
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(try makeBinaryString(ctx, s));
                return;
            }
            const new_len = s.len - cnt * old_s.len + cnt * new_s.len;
            const buf = try vmgc.vmAllocManagedBytes(ctx, new_len);
            // Re-derive after the allocation above, which can compact and
            // relocate s_val/old_val/new_val's backing.
            const s_now = try vms.asStringValue(s_val);
            const old_now = try vms.asStringValue(old_val);
            const new_now = try vms.asStringValue(new_val);
            var src: usize = 0;
            var dst: usize = 0;
            while (std.mem.indexOf(u8, s_now[src..], old_now)) |found| {
                @memcpy(buf[dst .. dst + found], s_now[src .. src + found]);
                dst += found;
                @memcpy(buf[dst .. dst + new_now.len], new_now);
                dst += new_now.len;
                src += found + old_now.len;
            }
            @memcpy(buf[dst .. dst + (s_now.len - src)], s_now[src..]);
            const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
            defer ctx.vs.popTempRoot();
            obj.* = .{ .dyn_string = buf[0..new_len] };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = obj });
        },
        // ── IEEE 754 float encoding ──────────────────────────────────────────
        .bytes_f32be => {
            const fval: f32 = @floatCast(switch (ctx.vs.vmTop(0)) {
                .float => |n| n,
                .int => |n| @as(f64, @floatFromInt(n)),
                else => return error.TypeError,
            });
            const bits = @as(u32, @bitCast(fval));
            const buf = [_]u8{
                @truncate(bits >> 24), @truncate(bits >> 16),
                @truncate(bits >> 8),  @truncate(bits),
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_f32le => {
            const fval: f32 = @floatCast(switch (ctx.vs.vmTop(0)) {
                .float => |n| n,
                .int => |n| @as(f64, @floatFromInt(n)),
                else => return error.TypeError,
            });
            const bits = @as(u32, @bitCast(fval));
            const buf = [_]u8{
                @truncate(bits),       @truncate(bits >> 8),
                @truncate(bits >> 16), @truncate(bits >> 24),
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_f64be => {
            const fval: f64 = switch (ctx.vs.vmTop(0)) {
                .float => |n| n,
                .int => |n| @floatFromInt(n),
                else => return error.TypeError,
            };
            const bits = @as(u64, @bitCast(fval));
            const buf = [_]u8{
                @truncate(bits >> 56), @truncate(bits >> 48),
                @truncate(bits >> 40), @truncate(bits >> 32),
                @truncate(bits >> 24), @truncate(bits >> 16),
                @truncate(bits >> 8),  @truncate(bits),
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        .bytes_f64le => {
            const fval: f64 = switch (ctx.vs.vmTop(0)) {
                .float => |n| n,
                .int => |n| @floatFromInt(n),
                else => return error.TypeError,
            };
            const bits = @as(u64, @bitCast(fval));
            const buf = [_]u8{
                @truncate(bits),       @truncate(bits >> 8),
                @truncate(bits >> 16), @truncate(bits >> 24),
                @truncate(bits >> 32), @truncate(bits >> 40),
                @truncate(bits >> 48), @truncate(bits >> 56),
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try makeBinaryString(ctx, &buf));
        },
        // ── IEEE 754 float decoding ──────────────────────────────────────────
        .bytes_f32be_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.f32be, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_f32le_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.f32le, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_f64be_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.f64be, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .bytes_f64le_at => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const result = try decodeAt(.f64le, s, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        else => {},
    }
}
