const std = @import("std");
const vms = @import("vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("vm_gc.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const StringSlice = @import("value.zig").StringSlice;

// Comptime-built pool of the 128 single-ASCII-byte strings (bytes 0x00–0x7F).
// stringIndex / stringSlice return Value.string = &ascii_ss[b] for ASCII results:
// no GC Object allocation, no byte copy.
const ascii_bytes: [128]u8 = blk: {
    var b: [128]u8 = undefined;
    for (0..128) |i| b[i] = @intCast(i);
    break :blk b;
};
const ascii_ss: [128]StringSlice = blk: {
    var s: [128]StringSlice = undefined;
    for (0..128) |i| s[i] = .{ .bytes = ascii_bytes[i .. i + 1] };
    break :blk s;
};

pub fn utf8NextRuneByteLen(s: []const u8, byte_idx: usize) !usize {
    if (byte_idx >= s.len) return error.IndexOutOfBounds;
    const w = std.unicode.utf8ByteSequenceLength(s[byte_idx]) catch return error.TypeError;
    const width: usize = @intCast(w);
    if (byte_idx + width > s.len) return error.TypeError;
    _ = std.unicode.utf8Decode(s[byte_idx .. byte_idx + width]) catch return error.TypeError;
    return width;
}

pub fn utf8RuneCount(s: []const u8) !usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        i += try utf8NextRuneByteLen(s, i);
        count += 1;
    }
    return count;
}

pub fn utf8ByteOffsetForRuneIndex(s: []const u8, rune_idx: usize) !usize {
    var r: usize = 0;
    var i: usize = 0;
    while (i < s.len and r < rune_idx) {
        i += try utf8NextRuneByteLen(s, i);
        r += 1;
    }
    if (r != rune_idx) return error.IndexOutOfBounds;
    return i;
}

pub fn ensureRuneCache(ctx: VMContext, s: []const u8) !void {
    const st = ctx.vs;
    if (st.rune_cache_valid and st.rune_cache_ptr == @intFromPtr(s.ptr) and st.rune_cache_byte_len == s.len) return;
    st.rune_cache_ptr = @intFromPtr(s.ptr);
    st.rune_cache_byte_len = s.len;
    st.rune_cache_rune_len = 0;
    st.rune_cache_overflow = false;
    var i: usize = 0;
    while (i < s.len) {
        if (st.rune_cache_rune_len < vms.RuneCacheMax) {
            st.rune_cache_offsets[st.rune_cache_rune_len] = i;
        } else {
            st.rune_cache_overflow = true;
        }
        i += try utf8NextRuneByteLen(s, i);
        st.rune_cache_rune_len += 1;
    }
    st.rune_cache_valid = true;
}

pub fn utf8RuneCountCached(ctx: VMContext, s: []const u8) !usize {
    try ensureRuneCache(ctx, s);
    return ctx.vs.rune_cache_rune_len;
}

pub fn utf8ByteOffsetForRuneIndexCached(ctx: VMContext, s: []const u8, rune_idx: usize) !usize {
    try ensureRuneCache(ctx, s);
    const st = ctx.vs;
    if (rune_idx == st.rune_cache_rune_len) return s.len;
    if (rune_idx > st.rune_cache_rune_len) return error.IndexOutOfBounds;
    if (rune_idx < vms.RuneCacheMax) return st.rune_cache_offsets[rune_idx];
    return utf8ByteOffsetForRuneIndex(s, rune_idx);
}

// ---------------------------------------------------------------------------
// Unified string operations — dispatch over all string representations
// ---------------------------------------------------------------------------

pub fn stringBytesFromObj(obj: *Object) ![]const u8 {
    return switch (obj.*) {
        .dyn_string => |s| s,
        .string_view => |sv| sv.bytes,
        else => error.TypeError,
    };
}

pub fn stringSliceRange(ctx: VMContext, s: []const u8, has_start: bool, start_v: Value, has_end: bool, end_v: Value) !struct { start_b: usize, end_b: usize } {
    const rune_len = try utf8RuneCountCached(ctx, s);
    const start_r: usize = if (has_start) try vms.vmSliceIndex(start_v, rune_len) else 0;
    const end_r: usize = if (has_end) try vms.vmSliceIndex(end_v, rune_len) else rune_len;
    if (start_r > end_r) return error.IndexOutOfBounds;
    return .{
        .start_b = try utf8ByteOffsetForRuneIndexCached(ctx, s, start_r),
        .end_b = try utf8ByteOffsetForRuneIndexCached(ctx, s, end_r),
    };
}

/// Return a Value for a single UTF-8 character slice.  ASCII bytes (0x00–0x7F)
/// resolve to the comptime ascii_ss pool (zero allocation).  Multi-byte runes
/// borrow `bytes` as a string_view; pass source=null when bytes are immortal.
pub fn makeCharValue(ctx: VMContext, bytes: []const u8, source: ?*Object) !Value {
    if (bytes.len == 1 and bytes[0] < 128) return .{ .string = &ascii_ss[bytes[0]] };
    return vmgc.makeStringView(ctx, bytes, source);
}

pub fn stringIndex(ctx: VMContext, container: Value, idx_v: Value) !Value {
    const ridx = try vms.vmIndexFromVal(idx_v);
    switch (container) {
        .string => |s| {
            const start = try utf8ByteOffsetForRuneIndexCached(ctx, s.bytes, ridx);
            const w = try utf8NextRuneByteLen(s.bytes, start);
            return makeCharValue(ctx, s.bytes[start .. start + w], null);
        },
        .object => |obj| switch (obj.*) {
            .dyn_string => {
                const bytes = obj.dyn_string;
                const start = try utf8ByteOffsetForRuneIndexCached(ctx, bytes, ridx);
                const w = try utf8NextRuneByteLen(bytes, start);
                // ASCII fast path: no allocation, pre-captured bytes are still valid.
                if (w == 1 and bytes[start] < 128) return .{ .string = &ascii_ss[bytes[start]] };
                // Multi-byte: makeStringView allocates internally and may compact;
                // re-derive bytes from obj after the allocation.
                return vmgc.makeStringViewFromStringObj(ctx, obj, start, start + w);
            },
            .string_view => {
                const sv = obj.string_view;
                const start = try utf8ByteOffsetForRuneIndexCached(ctx, sv.bytes, ridx);
                const w = try utf8NextRuneByteLen(sv.bytes, start);
                // ASCII fast path: no allocation, pre-captured bytes are still valid.
                if (w == 1 and sv.bytes[start] < 128) return .{ .string = &ascii_ss[sv.bytes[start]] };
                // Multi-byte: makeStringView allocates internally and may compact;
                // re-derive bytes from obj after the allocation.
                return vmgc.makeStringViewFromStringObj(ctx, obj, start, start + w);
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    }
}

pub fn stringSlice(ctx: VMContext, container: Value, has_start: bool, start_v: Value, has_end: bool, end_v: Value) !Value {
    switch (container) {
        .string => |s| {
            const r = try stringSliceRange(ctx, s.bytes, has_start, start_v, has_end, end_v);
            const sub = s.bytes[r.start_b..r.end_b];
            if (sub.len == 1 and sub[0] < 128) return .{ .string = &ascii_ss[sub[0]] };
            // Bytes are immortal (static string); borrow a view with no GC parent.
            return vmgc.makeStringView(ctx, sub, null);
        },
        .object => |obj| switch (obj.*) {
            .dyn_string => {
                const bytes = obj.dyn_string;
                const r = try stringSliceRange(ctx, bytes, has_start, start_v, has_end, end_v);
                // makeStringView allocates internally and may compact; re-derive bytes
                // from obj after the allocation.
                return vmgc.makeStringViewFromStringObj(ctx, obj, r.start_b, r.end_b);
            },
            .string_view => {
                const sv = obj.string_view;
                const r = try stringSliceRange(ctx, sv.bytes, has_start, start_v, has_end, end_v);
                // makeStringView allocates internally and may compact; re-derive bytes
                // from obj after the allocation.
                return vmgc.makeStringViewFromStringObj(ctx, obj, r.start_b, r.end_b);
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    }
}
