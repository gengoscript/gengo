const std = @import("std");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const vmstr = @import("../vm_string.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

pub fn nativeStrSplit(s: []const u8, sep: []const u8) !Value {
    var count: usize = undefined;
    if (sep.len == 0) {
        count = try vmstr.utf8RuneCount(s);
    } else {
        count = 1;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
            count += 1;
            i = pos + sep.len;
        }
    }
    const arr_obj = try vmgc.vmAllocObject();
    arr_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = arr_obj });
    defer vms.popTempRoot();
    if (count > 0) {
        const pieces = try vmgc.vmAllocManagedSlice(Value, count);
        if (sep.len == 0) {
            var i: usize = 0;
            var pi: usize = 0;
            while (i < s.len) {
                const w = try vmstr.utf8NextRuneByteLen(s, i);
                pieces[pi] = .{ .string = s[i .. i + w] };
                i += w;
                pi += 1;
            }
        } else {
            var i: usize = 0;
            var pi: usize = 0;
            while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
                pieces[pi] = .{ .string = s[i..pos] };
                pi += 1;
                i = pos + sep.len;
            }
            pieces[pi] = .{ .string = s[i..] };
        }
        arr_obj.* = .{ .array_managed = pieces[0..count] };
    }
    return .{ .object = arr_obj };
}

pub fn nativeStrJoin(arr_obj: *Object, sep: []const u8) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = vms.asArraySlice(arr_obj);
    if (items.len == 0) return vmgc.makeDynString("");
    var total: usize = sep.len * (items.len - 1);
    for (items) |v| total += (try vms.asStringValue(v)).len;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);
    var pos: usize = 0;
    for (items, 0..) |v, idx| {
        const piece = try vms.asStringValue(v);
        @memcpy(buf[pos .. pos + piece.len], piece);
        pos += piece.len;
        if (idx + 1 < items.len) {
            @memcpy(buf[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
    }
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn nativeStrTrim(s: []const u8) !Value {
    return vmgc.makeDynString(std.mem.trim(u8, s, " \t\n\r"));
}

pub fn nativeStrUpper(s: []const u8) !Value {
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(s.len);
    for (s, 0..) |b, i| buf[i] = std.ascii.toUpper(b);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
}

pub fn nativeStrLower(s: []const u8) !Value {
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(s.len);
    for (s, 0..) |b, i| buf[i] = std.ascii.toLower(b);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
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
    const byte_idx = std.mem.indexOf(u8, s, sub) orelse return .{ .number = -1.0 };
    const rune_idx = try vmstr.utf8RuneCount(s[0..byte_idx]);
    return .{ .number = @floatFromInt(rune_idx) };
}

pub fn nativeStrReplace(s: []const u8, old: []const u8, new: []const u8) !Value {
    if (old.len == 0) return vmgc.makeDynString(s);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, old)) |pos| {
        count += 1;
        i = pos + old.len;
    }
    if (count == 0) return vmgc.makeDynString(s);
    const total = s.len + count * new.len - count * old.len;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);
    var src_i: usize = 0;
    var dst_i: usize = 0;
    while (std.mem.indexOfPos(u8, s, src_i, old)) |pos| {
        @memcpy(buf[dst_i .. dst_i + (pos - src_i)], s[src_i..pos]);
        dst_i += pos - src_i;
        @memcpy(buf[dst_i .. dst_i + new.len], new);
        dst_i += new.len;
        src_i = pos + old.len;
    }
    @memcpy(buf[dst_i .. dst_i + (s.len - src_i)], s[src_i..]);
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn nativeStrLastIndexOf(s: []const u8, sub: []const u8) !Value {
    const byte_idx = std.mem.lastIndexOf(u8, s, sub) orelse return .{ .number = -1.0 };
    const rune_idx = try vmstr.utf8RuneCount(s[0..byte_idx]);
    return .{ .number = @floatFromInt(rune_idx) };
}

pub fn nativeStrRepeat(s: []const u8, count_v: Value) !Value {
    const n = try vms.valueAsInt(count_v);
    if (n < 0) return error.RangeError;
    if (n == 0) return vmgc.makeDynString("");
    const count: usize = @intCast(n);
    const total = s.len * count;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);
    var pos: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(buf[pos .. pos + s.len], s);
        pos += s.len;
    }
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn nativeStrSplitOnce(s: []const u8, sep: []const u8) !Value {
    const pos = std.mem.indexOf(u8, s, sep) orelse {
        const obj = try vmgc.vmAllocObject();
        obj.* = .{ .array = &[_]Value{} };
        try vms.pushTempRoot(.{ .object = obj });
        defer vms.popTempRoot();
        const items = try vmgc.vmAllocManagedSlice(Value, 2);
        items[0] = .null;
        items[1] = .null;
        obj.* = .{ .array_managed = items[0..2] };
        return .{ .object = obj };
    };
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(Value, 2);
    items[0] = .{ .string = s[0..pos] };
    items[1] = .{ .string = s[pos + sep.len ..] };
    obj.* = .{ .array_managed = items[0..2] };
    return .{ .object = obj };
}

pub fn nativeStrCount(s: []const u8, sub: []const u8) Value {
    return .{ .number = @floatFromInt(std.mem.count(u8, s, sub)) };
}

pub fn nativeStrFields(s: []const u8) !Value {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r' or s[i] == 0x0b or s[i] == 0x0c)) i += 1;
        if (i >= s.len) break;
        count += 1;
        while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != '\n' and s[i] != '\r' and s[i] != 0x0b and s[i] != 0x0c) i += 1;
    }
    const arr_obj = try vmgc.vmAllocObject();
    arr_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = arr_obj });
    defer vms.popTempRoot();
    if (count > 0) {
        const pieces = try vmgc.vmAllocManagedSlice(Value, count);
        var pi: usize = 0;
        i = 0;
        while (i < s.len) {
            while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r' or s[i] == 0x0b or s[i] == 0x0c)) i += 1;
            if (i >= s.len) break;
            const start = i;
            while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != '\n' and s[i] != '\r' and s[i] != 0x0b and s[i] != 0x0c) i += 1;
            const piece = try vmgc.makeDynString(s[start..i]);
            pieces[pi] = piece;
            pi += 1;
        }
        arr_obj.* = .{ .array_managed = pieces[0..count] };
    }
    return .{ .object = arr_obj };
}

pub fn nativeStrPadLeft(s: []const u8, n_v: Value, pad: []const u8) !Value {
    const n = try vms.valueAsInt(n_v);
    if (n < 0) return error.RangeError;
    const width: usize = @intCast(n);
    if (width <= s.len or pad.len == 0) return vmgc.makeDynString(s);
    const pad_needed = width - s.len;
    const total = width;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);
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

pub fn nativeStrPadRight(s: []const u8, n_v: Value, pad: []const u8) !Value {
    const n = try vms.valueAsInt(n_v);
    if (n < 0) return error.RangeError;
    const width: usize = @intCast(n);
    if (width <= s.len or pad.len == 0) return vmgc.makeDynString(s);
    const total = width;
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);
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
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (std.ascii.toLower(s[i]) != std.ascii.toLower(t[i])) return .{ .boolean = false };
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

pub fn nativeStrTrimLeft(s: []const u8, cutset: []const u8) !Value {
    var i: usize = 0;
    while (i < s.len and inCutset(s[i], cutset)) : (i += 1) {}
    return vmgc.makeDynString(s[i..]);
}

pub fn nativeStrTrimRight(s: []const u8, cutset: []const u8) !Value {
    var i: usize = s.len;
    while (i > 0 and inCutset(s[i - 1], cutset)) : (i -= 1) {}
    return vmgc.makeDynString(s[0..i]);
}

pub fn nativeStrTrimPrefix(s: []const u8, prefix: []const u8) !Value {
    if (std.mem.startsWith(u8, s, prefix)) return vmgc.makeDynString(s[prefix.len..]);
    return vmgc.makeDynString(s);
}

pub fn nativeStrTrimSuffix(s: []const u8, suffix: []const u8) !Value {
    if (std.mem.endsWith(u8, s, suffix)) return vmgc.makeDynString(s[0 .. s.len - suffix.len]);
    return vmgc.makeDynString(s);
}

pub fn nativeStrSplitN(s: []const u8, sep: []const u8, n_v: Value) !Value {
    const n = try vms.valueAsInt(n_v);
    if (n < 0) return error.RangeError;
    const max: usize = @intCast(n);
    if (max == 0) {
        const obj = try vmgc.vmAllocObject();
        obj.* = .{ .array = &[_]Value{} };
        return .{ .object = obj };
    }
    // Count pieces (up to max)
    var count: usize = 0;
    if (sep.len == 0) {
        count = @min(s.len, max);
    } else {
        var pos: usize = 0;
        count = 1;
        while (count < max) {
            const idx = std.mem.indexOf(u8, s[pos..], sep) orelse break;
            count += 1;
            pos += idx + sep.len;
        }
    }
    const arr_obj = try vmgc.vmAllocObject();
    arr_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = arr_obj });
    defer vms.popTempRoot();
    const pieces = try vmgc.vmAllocManagedSlice(Value, count);
    if (sep.len == 0) {
        for (0..count) |i| pieces[i] = try vmgc.makeDynString(s[i .. i + 1]);
    } else {
        var pos: usize = 0;
        var pi: usize = 0;
        while (pi + 1 < count) {
            const idx = std.mem.indexOf(u8, s[pos..], sep).?;
            pieces[pi] = try vmgc.makeDynString(s[pos .. pos + idx]);
            pos += idx + sep.len;
            pi += 1;
        }
        pieces[pi] = try vmgc.makeDynString(s[pos..]);
    }
    arr_obj.* = .{ .array_managed = pieces[0..count] };
    return .{ .object = arr_obj };
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .str_builder_new => {

            if (argc != 0) return error.ArityMismatch;
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .string_builder = .{ .buf = &[_]u8{}, .len = 0 } };
            _ = try vms.vmPop();
            try vms.vmPush(.{ .object = obj });
        },
        .str_contains => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(nativeStrContains(s, sub));
        },
        .str_contains_any => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const chars = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(nativeStrContainsAny(s, chars));
        },
        .str_count => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(nativeStrCount(s, sub));
        },
        .str_ends_with => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const suffix = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(nativeStrEndsWith(s, suffix));
        },
        .str_equal_fold => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const t = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(nativeStrEqualFold(s, t));
        },
        .str_fields => {

            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try nativeStrFields(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_index_of => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrIndexOf(s, sub);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_join => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const arr_val = vms.vmState().stack[top - 2];
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            if (arr_val != .object) return error.TypeError;
            const out = try nativeStrJoin(arr_val.object, sep);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_last_index_of => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sub = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrLastIndexOf(s, sub);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_lower => {

            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try nativeStrLower(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_pad_left => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 3]);
            const n_v = vms.vmState().stack[top - 2];
            const pad = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrPadLeft(s, n_v, pad);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_pad_right => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 3]);
            const n_v = vms.vmState().stack[top - 2];
            const pad = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrPadRight(s, n_v, pad);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_repeat => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const out = try nativeStrRepeat(s, vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_replace => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 3]);
            const old = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const new = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrReplace(s, old, new);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_split => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrSplit(s, sep);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_split_once => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const sep = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrSplitOnce(s, sep);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_starts_with => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const prefix = try vms.asStringValue(vms.vmState().stack[top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(nativeStrStartsWith(s, prefix));
        },
        .str_trim => {

            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try nativeStrTrim(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_upper => {

            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const out = try nativeStrUpper(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_trim_left => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const cutset = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrTrimLeft(s, cutset);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_trim_right => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const cutset = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrTrimRight(s, cutset);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_trim_prefix => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const prefix = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrTrimPrefix(s, prefix);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_trim_suffix => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const suffix = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try nativeStrTrimSuffix(s, suffix);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .str_split_n => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 3]);
            const sep = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const n_v = vms.vmState().stack[top - 1];
            const out = try nativeStrSplitN(s, sep, n_v);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        else => {},
    }
}
