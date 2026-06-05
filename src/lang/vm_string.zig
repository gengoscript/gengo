const std = @import("std");
const vms = @import("vm_state.zig");

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

pub fn ensureRuneCache(s: []const u8) !void {
    const st = vms.vmState();
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

pub fn utf8RuneCountCached(s: []const u8) !usize {
    try ensureRuneCache(s);
    return vms.vmState().rune_cache_rune_len;
}

pub fn utf8ByteOffsetForRuneIndexCached(s: []const u8, rune_idx: usize) !usize {
    try ensureRuneCache(s);
    const st = vms.vmState();
    if (rune_idx == st.rune_cache_rune_len) return s.len;
    if (rune_idx > st.rune_cache_rune_len) return error.IndexOutOfBounds;
    if (rune_idx < vms.RuneCacheMax) return st.rune_cache_offsets[rune_idx];
    return utf8ByteOffsetForRuneIndex(s, rune_idx);
}
