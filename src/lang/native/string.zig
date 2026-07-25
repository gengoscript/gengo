const std = @import("std");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const vmstr = @import("../vm_string.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const chunk = @import("../chunk.zig");

// A raw .string view is only safe when the source bytes are immortal
// (source-code constants). Substrings of GC-managed strings must be copied,
// or they dangle once the source is collected.
fn substring(ctx: VMContext, bytes: []const u8, managed: bool) !Value {
    _ = managed;
    return vmgc.makeDynString(ctx, bytes);
}

pub fn nativeStrSplit(ctx: VMContext, s_val: Value, sep_val: Value, managed: bool) !Value {
    const s0 = try vms.asStringValue(s_val);
    const sep = try vms.asStringValue(sep_val);
    var count: usize = undefined;
    if (sep.len == 0) {
        count = try vmstr.utf8RuneCount(s0);
    } else {
        count = 1;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, s0, i, sep)) |pos| {
            count += 1;
            i = pos + sep.len;
        }
    }
    const arr_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    if (count > 0) {
        const pieces = try vmgc.vmAllocManagedSlice(ctx, Value, count);
        // Attach the slice as it fills: substring() can trigger GC, and
        // already-filled elements must be traced or they get reclaimed.
        arr_obj.* = .{ .array_managed = pieces[0..0] };
        if (sep.len == 0) {
            var i: usize = 0;
            var pi: usize = 0;
            while (i < s0.len) {
                // Re-derive every iteration: the previous iteration's
                // substring()/makeDynString() call can allocate and
                // compact, relocating s_val's backing.
                const s = try vms.asStringValue(s_val);
                const w = try vmstr.utf8NextRuneByteLen(s, i);
                pieces[pi] = try substring(ctx, s[i .. i + w], managed);
                i += w;
                pi += 1;
                arr_obj.* = .{ .array_managed = pieces[0..pi] };
            }
        } else {
            var i: usize = 0;
            var pi: usize = 0;
            while (true) {
                const s = try vms.asStringValue(s_val);
                const pos = std.mem.indexOfPos(u8, s, i, sep) orelse break;
                pieces[pi] = try substring(ctx, s[i..pos], managed);
                pi += 1;
                arr_obj.* = .{ .array_managed = pieces[0..pi] };
                i = pos + sep.len;
            }
            const s = try vms.asStringValue(s_val);
            pieces[pi] = try substring(ctx, s[i..], managed);
        }
        arr_obj.* = .{ .array_managed = pieces[0..count] };
    }
    return .{ .object = arr_obj };
}

pub fn nativeStrJoin(ctx: VMContext, arr_obj: *Object, sep_val: Value) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items_len = (try vms.asArraySlice(arr_obj)).len;
    if (items_len == 0) return vmgc.makeDynString(ctx, "");
    const sep = try vms.asStringValue(sep_val);
    var total: usize = sep.len * (items_len - 1);
    for (try vms.asArraySlice(arr_obj)) |v| total += (try vms.asStringValue(v)).len;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, total);
    // Re-derive after the allocation above, which can compact and
    // relocate arr_obj's or sep_val's backing.
    const items = try vms.asArraySlice(arr_obj);
    const sep_now = try vms.asStringValue(sep_val);
    var pos: usize = 0;
    for (items, 0..) |v, idx| {
        const piece = try vms.asStringValue(v);
        @memcpy(buf[pos .. pos + piece.len], piece);
        pos += piece.len;
        if (idx + 1 < items.len) {
            @memcpy(buf[pos .. pos + sep_now.len], sep_now);
            pos += sep_now.len;
        }
    }
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn nativeStrTrim(ctx: VMContext, s: []const u8) !Value {
    return vmgc.makeDynString(ctx, std.mem.trim(u8, s, " \t\n\r"));
}

fn nativeStrTransform(ctx: VMContext, s_val: Value, comptime transform: fn (u8) u8) !Value {
    const s_len = (try vms.asStringValue(s_val)).len;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, s_len);
    // Re-derive after the allocation above, which can compact and
    // relocate s_val's backing.
    const s = try vms.asStringValue(s_val);
    for (s, 0..) |b, i| buf[i] = transform(b);
    obj.* = .{ .dyn_string = buf[0..s_len] };
    return .{ .object = obj };
}

pub fn nativeStrUpper(ctx: VMContext, s_val: Value) !Value {
    return nativeStrTransform(ctx, s_val, std.ascii.toUpper);
}
pub fn nativeStrLower(ctx: VMContext, s_val: Value) !Value {
    return nativeStrTransform(ctx, s_val, std.ascii.toLower);
}

pub fn nativeStrContains(s: []const u8, sub: []const u8) Value {
    return .{ .boolean = std.mem.indexOf(u8, s, sub) != null };
}

pub fn nativeStrStartsWith(s: []const u8, prefix: []const u8) Value {
    return .{ .boolean = std.mem.startsWith(u8, s, prefix) };
}

pub fn nativeStrEndsWith(s: []const u8, suffix: []const u8) Value {
    return .{ .boolean = std.mem.endsWith(u8, s, suffix) };
}

pub fn nativeStrIndexOf(s: []const u8, sub: []const u8) !Value {
    const byte_idx = std.mem.indexOf(u8, s, sub) orelse return .{ .int = -1 };
    const rune_idx = try vmstr.utf8RuneCount(s[0..byte_idx]);
    return .{ .int = @intCast(rune_idx) };
}

pub fn nativeStrReplace(ctx: VMContext, s_val: Value, old_val: Value, new_val: Value) !Value {
    const s = try vms.asStringValue(s_val);
    const old = try vms.asStringValue(old_val);
    const new = try vms.asStringValue(new_val);
    if (old.len == 0) return vmgc.makeDynString(ctx, s);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, old)) |pos| {
        count += 1;
        i = pos + old.len;
    }
    if (count == 0) return vmgc.makeDynString(ctx, s);
    const total = s.len + count * new.len - count * old.len;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, total);
    // Re-derive after the allocation above, which can compact and
    // relocate s_val/old_val/new_val's backing.
    const s_now = try vms.asStringValue(s_val);
    const old_now = try vms.asStringValue(old_val);
    const new_now = try vms.asStringValue(new_val);
    var src_i: usize = 0;
    var dst_i: usize = 0;
    while (std.mem.indexOfPos(u8, s_now, src_i, old_now)) |pos| {
        @memcpy(buf[dst_i .. dst_i + (pos - src_i)], s_now[src_i..pos]);
        dst_i += pos - src_i;
        @memcpy(buf[dst_i .. dst_i + new_now.len], new_now);
        dst_i += new_now.len;
        src_i = pos + old_now.len;
    }
    @memcpy(buf[dst_i .. dst_i + (s_now.len - src_i)], s_now[src_i..]);
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn nativeStrLastIndexOf(s: []const u8, sub: []const u8) !Value {
    const byte_idx = std.mem.lastIndexOf(u8, s, sub) orelse return .{ .int = -1 };
    const rune_idx = try vmstr.utf8RuneCount(s[0..byte_idx]);
    return .{ .int = @intCast(rune_idx) };
}

pub fn nativeStrRepeat(ctx: VMContext, s_val: Value, count_v: Value) !Value {
    const n = try vms.valueAsInt(count_v);
    if (n < 0) return error.RangeError;
    if (n == 0) return vmgc.makeDynString(ctx, "");
    const count: usize = @intCast(n);
    const s_len = (try vms.asStringValue(s_val)).len;
    const total = s_len * count;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, total);
    // Re-derive after the allocation above, which can compact and
    // relocate s_val's backing.
    const s = try vms.asStringValue(s_val);
    var pos: usize = 0;
    for (0..count) |_| {
        @memcpy(buf[pos .. pos + s.len], s);
        pos += s.len;
    }
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn nativeStrSplitOnce(ctx: VMContext, s_val: Value, sep_val: Value, managed: bool) !Value {
    const s0 = try vms.asStringValue(s_val);
    const sep0 = try vms.asStringValue(sep_val);
    const pos = std.mem.indexOf(u8, s0, sep0) orelse {
        const obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
        defer ctx.vs.popTempRoot();
        const items = try vmgc.vmAllocManagedSlice(ctx, Value, 2);
        items[0] = .null;
        items[1] = .null;
        obj.* = .{ .array_managed = items[0..2] };
        return .{ .object = obj };
    };
    const sep_len = sep0.len;
    const obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(ctx, Value, 2);
    items[0] = .null;
    items[1] = .null;
    obj.* = .{ .array_managed = items[0..2] };
    // Re-derive before each substring(): the previous one can allocate and
    // compact, relocating s_val's backing.
    const s1 = try vms.asStringValue(s_val);
    items[0] = try substring(ctx, s1[0..pos], managed);
    const s2 = try vms.asStringValue(s_val);
    items[1] = try substring(ctx, s2[pos + sep_len ..], managed);
    return .{ .object = obj };
}

pub fn nativeStrCount(s: []const u8, sub: []const u8) Value {
    return .{ .int = @intCast(std.mem.count(u8, s, sub)) };
}

fn isFieldSep(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

pub fn nativeStrFields(ctx: VMContext, s_val: Value) !Value {
    const s0 = try vms.asStringValue(s_val);
    var count: usize = 0;
    var i: usize = 0;
    while (i < s0.len) {
        while (i < s0.len and isFieldSep(s0[i])) i += 1;
        if (i >= s0.len) break;
        count += 1;
        while (i < s0.len and !isFieldSep(s0[i])) i += 1;
    }
    const arr_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    if (count > 0) {
        const pieces = try vmgc.vmAllocManagedSlice(ctx, Value, count);
        // Attach as it fills: makeDynString can trigger GC and earlier
        // elements must be traced.
        arr_obj.* = .{ .array_managed = pieces[0..0] };
        var pi: usize = 0;
        i = 0;
        while (i < s0.len) {
            // Re-derive every iteration: the previous iteration's
            // makeDynString() call can allocate and compact, relocating
            // s_val's backing.
            const s = try vms.asStringValue(s_val);
            while (i < s.len and isFieldSep(s[i])) i += 1;
            if (i >= s.len) break;
            const start = i;
            while (i < s.len and !isFieldSep(s[i])) i += 1;
            const piece = try vmgc.makeDynString(ctx, s[start..i]);
            pieces[pi] = piece;
            pi += 1;
            arr_obj.* = .{ .array_managed = pieces[0..pi] };
        }
        arr_obj.* = .{ .array_managed = pieces[0..count] };
    }
    return .{ .object = arr_obj };
}

pub fn nativeStrPadLeft(ctx: VMContext, s_val: Value, n_v: Value, pad_val: Value) !Value {
    const n = try vms.valueAsInt(n_v);
    if (n < 0) return error.RangeError;
    const width: usize = @intCast(n);
    const s0 = try vms.asStringValue(s_val);
    const pad0 = try vms.asStringValue(pad_val);
    if (width <= s0.len or pad0.len == 0) return vmgc.makeDynString(ctx, s0);
    const pad_needed = width - s0.len;
    const total = width;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, total);
    // Re-derive after the allocation above, which can compact and
    // relocate s_val/pad_val's backing.
    const s = try vms.asStringValue(s_val);
    const pad = try vms.asStringValue(pad_val);
    var pos: usize = 0;
    while (pos + pad.len <= pad_needed) {
        @memcpy(buf[pos..][0..pad.len], pad);
        pos += pad.len;
    }
    if (pos < pad_needed) {
        @memcpy(buf[pos..][0 .. pad_needed - pos], pad[0 .. pad_needed - pos]);
        pos = pad_needed;
    }
    @memcpy(buf[pos..][0..s.len], s);
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn nativeStrPadRight(ctx: VMContext, s_val: Value, n_v: Value, pad_val: Value) !Value {
    const n = try vms.valueAsInt(n_v);
    if (n < 0) return error.RangeError;
    const width: usize = @intCast(n);
    const s0 = try vms.asStringValue(s_val);
    const pad0 = try vms.asStringValue(pad_val);
    if (width <= s0.len or pad0.len == 0) return vmgc.makeDynString(ctx, s0);
    const total = width;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, total);
    // Re-derive after the allocation above, which can compact and
    // relocate s_val/pad_val's backing.
    const s = try vms.asStringValue(s_val);
    const pad = try vms.asStringValue(pad_val);
    var pos: usize = 0;
    @memcpy(buf[pos..][0..s.len], s);
    pos += s.len;
    while (pos + pad.len <= width) {
        @memcpy(buf[pos..][0..pad.len], pad);
        pos += pad.len;
    }
    if (pos < width) {
        @memcpy(buf[pos..][0 .. width - pos], pad[0 .. width - pos]);
    }
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn nativeStrEqualFold(s: []const u8, t: []const u8) Value {
    if (s.len != t.len) return .{ .boolean = false };
    for (s, t) |sc, tc| {
        if (std.ascii.toLower(sc) != std.ascii.toLower(tc)) return .{ .boolean = false };
    }
    return .{ .boolean = true };
}

pub fn nativeStrContainsAny(s: []const u8, chars: []const u8) Value {
    for (s) |c| {
        for (chars) |ch| {
            if (c == ch) return .{ .boolean = true };
        }
    }
    return .{ .boolean = false };
}

fn inCutset(c: u8, cutset: []const u8) bool {
    for (cutset) |ch| if (c == ch) return true;
    return false;
}

pub fn nativeStrTrimLeft(ctx: VMContext, s: []const u8, cutset: []const u8) !Value {
    var i: usize = 0;
    while (i < s.len and inCutset(s[i], cutset)) : (i += 1) {}
    return vmgc.makeDynString(ctx, s[i..]);
}

pub fn nativeStrTrimRight(ctx: VMContext, s: []const u8, cutset: []const u8) !Value {
    var i: usize = s.len;
    while (i > 0 and inCutset(s[i - 1], cutset)) : (i -= 1) {}
    return vmgc.makeDynString(ctx, s[0..i]);
}

pub fn nativeStrTrimPrefix(ctx: VMContext, s: []const u8, prefix: []const u8) !Value {
    if (std.mem.startsWith(u8, s, prefix)) return vmgc.makeDynString(ctx, s[prefix.len..]);
    return vmgc.makeDynString(ctx, s);
}

pub fn nativeStrTrimSuffix(ctx: VMContext, s: []const u8, suffix: []const u8) !Value {
    if (std.mem.endsWith(u8, s, suffix)) return vmgc.makeDynString(ctx, s[0 .. s.len - suffix.len]);
    return vmgc.makeDynString(ctx, s);
}

pub fn nativeStrSplitN(ctx: VMContext, s_val: Value, sep_val: Value, n_v: Value) !Value {
    const n = try vms.valueAsInt(n_v);
    if (n < 0) return error.RangeError;
    const max: usize = @intCast(n);
    if (max == 0) {
        const obj = try vmgc.vmAllocObject(ctx);
        obj.* = .{ .array = &[_]Value{} };
        return .{ .object = obj };
    }
    const s0 = try vms.asStringValue(s_val);
    const sep0 = try vms.asStringValue(sep_val);
    // Count pieces (up to max) — read-only, no allocation, so s0/sep0 are
    // safe to use throughout this pass.
    var count: usize = 0;
    if (sep0.len == 0) {
        count = @min(s0.len, max);
    } else {
        var pos: usize = 0;
        count = 1;
        while (count < max) {
            const idx = std.mem.indexOf(u8, s0[pos..], sep0) orelse break;
            count += 1;
            pos += idx + sep0.len;
        }
    }
    const arr_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    const pieces = try vmgc.vmAllocManagedSlice(ctx, Value, count);
    // Attach as it fills: makeDynString can trigger GC and earlier elements
    // must be traced.
    arr_obj.* = .{ .array_managed = pieces[0..0] };
    if (sep0.len == 0) {
        for (0..count) |i| {
            // Re-derive every iteration: the previous iteration's
            // makeDynString() call can allocate and compact, relocating
            // s_val's backing.
            const s = try vms.asStringValue(s_val);
            pieces[i] = try vmgc.makeDynString(ctx, s[i .. i + 1]);
            arr_obj.* = .{ .array_managed = pieces[0 .. i + 1] };
        }
    } else {
        var pos: usize = 0;
        var pi: usize = 0;
        while (pi + 1 < count) {
            const s = try vms.asStringValue(s_val);
            const sep = try vms.asStringValue(sep_val);
            const idx = std.mem.indexOf(u8, s[pos..], sep).?;
            pieces[pi] = try vmgc.makeDynString(ctx, s[pos .. pos + idx]);
            pos += idx + sep.len;
            pi += 1;
            arr_obj.* = .{ .array_managed = pieces[0..pi] };
        }
        const s = try vms.asStringValue(s_val);
        pieces[pi] = try vmgc.makeDynString(ctx, s[pos..]);
    }
    arr_obj.* = .{ .array_managed = pieces[0..count] };
    return .{ .object = arr_obj };
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .str_builder_new => {
            const obj = try vmgc.vmAllocObject(ctx);
            obj.* = .{ .string_builder = .{ .buf = &[_]u8{}, .len = 0 } };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = obj });
        },
        .str_contains => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const sub = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(nativeStrContains(s, sub));
        },
        .str_contains_any => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const chars = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(nativeStrContainsAny(s, chars));
        },
        .str_count => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const sub = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(nativeStrCount(s, sub));
        },
        .str_ends_with => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const suffix = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(nativeStrEndsWith(s, suffix));
        },
        .str_equal_fold => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const t = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(nativeStrEqualFold(s, t));
        },
        .str_fields => {
            const out = try nativeStrFields(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_index_of => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const sub = try vms.asStringValue(ctx.vs.vmTop(0));
            const out = try nativeStrIndexOf(s, sub);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_join => {
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const out = try nativeStrJoin(ctx, arr_val.object, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_last_index_of => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const sub = try vms.asStringValue(ctx.vs.vmTop(0));
            const out = try nativeStrLastIndexOf(s, sub);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_lower => {
            const out = try nativeStrLower(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_pad_left => {
            const s_val = ctx.vs.vmTop(2);
            const n_v = ctx.vs.vmTop(1);
            const pad_val = ctx.vs.vmTop(0);
            const out = try nativeStrPadLeft(ctx, s_val, n_v, pad_val);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_pad_right => {
            const s_val = ctx.vs.vmTop(2);
            const n_v = ctx.vs.vmTop(1);
            const pad_val = ctx.vs.vmTop(0);
            const out = try nativeStrPadRight(ctx, s_val, n_v, pad_val);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_repeat => {
            const out = try nativeStrRepeat(ctx, ctx.vs.vmTop(1), ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_replace => {
            const s_val = ctx.vs.vmTop(2);
            const old_val = ctx.vs.vmTop(1);
            const new_val = ctx.vs.vmTop(0);
            const out = try nativeStrReplace(ctx, s_val, old_val, new_val);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_split => {
            const src_val = ctx.vs.vmTop(1);
            const sep_val = ctx.vs.vmTop(0);
            const out = try nativeStrSplit(ctx, src_val, sep_val, src_val == .object);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_split_once => {
            const src_val = ctx.vs.vmTop(1);
            const sep_val = ctx.vs.vmTop(0);
            const out = try nativeStrSplitOnce(ctx, src_val, sep_val, src_val == .object);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_starts_with => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const prefix = try vms.asStringValue(ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(nativeStrStartsWith(s, prefix));
        },
        .str_trim => {
            const s = try vms.asStringValue(ctx.vs.vmTop(0));
            const out = try nativeStrTrim(ctx, s);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_upper => {
            const out = try nativeStrUpper(ctx, ctx.vs.vmTop(0));
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_trim_left => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const cutset = try vms.asStringValue(ctx.vs.vmTop(0));
            const out = try nativeStrTrimLeft(ctx, s, cutset);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_trim_right => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const cutset = try vms.asStringValue(ctx.vs.vmTop(0));
            const out = try nativeStrTrimRight(ctx, s, cutset);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_trim_prefix => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const prefix = try vms.asStringValue(ctx.vs.vmTop(0));
            const out = try nativeStrTrimPrefix(ctx, s, prefix);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_trim_suffix => {
            const s = try vms.asStringValue(ctx.vs.vmTop(1));
            const suffix = try vms.asStringValue(ctx.vs.vmTop(0));
            const out = try nativeStrTrimSuffix(ctx, s, suffix);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .str_split_n => {
            const s_val = ctx.vs.vmTop(2);
            const sep_val = ctx.vs.vmTop(1);
            const n_v = ctx.vs.vmTop(0);
            const out = try nativeStrSplitN(ctx, s_val, sep_val, n_v);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        else => {},
    }
}
