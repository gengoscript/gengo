const std = @import("std");
const Allocator = std.mem.Allocator;
const AlignedManaged = std.array_list.AlignedManaged;
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

const RegexpQualifiedName = "@std.regexp.obj";
const MaxPatternLen = 4096;

var regexp_type_cache: ?*Object = null;

// ── Regex type helpers ───────────────────────────────────────────────────────

pub fn reGetType() !*Object {
    if (regexp_type_cache) |t| return t;
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    obj.* = .{ .named_type = .{
        .name = "Regexp",
        .qualified_name = RegexpQualifiedName,
        .base = .string,
    } };
    regexp_type_cache = obj;
    return obj;
}

pub fn reBuildObj(pattern: []const u8) !Value {
    const obj = try vmgc.vmAllocObject();
    const typ = try reGetType();
    const str_val = try vmgc.makeDynString(pattern);
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    obj.* = .{ .named_value = .{ .typ = typ, .value = str_val } };
    return .{ .object = obj };
}

pub fn reGetPattern(val: Value) ![]const u8 {
    const uv = vms.unboxNamed(val);
    return switch (uv) {
        .string => |s| s,
        .object => |obj| switch (obj.*) {
            .named_value => |nv| nv.value.string,
            .dyn_string => obj.dyn_string,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
}

// ── Regex engine ─────────────────────────────────────────────────────────────

const Kind = enum {
    literal,
    dot,
    caret,
    dollar,
    star,
    plus,
    maybe,
    char_class,
    char_class_neg,
    group,
};

const Node = struct {
    kind: Kind,
    ch: u8 = 0,
    class_bits: u128 = 0,
    child_kind: Kind = .literal,
    children: []Alt = &[_]Alt{},
};

const Alt = []Node;

fn digitBits() u128 {
    var bits: u128 = 0;
    var c: u8 = '0';
    while (c <= '9') : (c += 1) bits |= @as(u128, 1) << @intCast(c);
    return bits;
}

fn wordBits() u128 {
    var bits: u128 = 0;
    for ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") |c|
        bits |= @as(u128, 1) << @intCast(c);
    return bits;
}

fn spaceBits() u128 {
    var bits: u128 = 0;
    for (" \t\n\r\x0c\x0b") |c| bits |= @as(u128, 1) << @intCast(c);
    return bits;
}

const ParseError = error{
    PatternTooLong,
    InvalidPattern,
    UnmatchedParen,
    UnterminatedGroup,
    UnterminatedClass,
    UnexpectedPipe,
    OutOfMemory,
};

fn parseAlts(alloc: Allocator, pattern: []const u8, start: usize, end: usize) ParseError![]Alt {
    var alts = AlignedManaged(Alt, null).init(alloc);
    errdefer {
        for (alts.items) |a| alloc.free(a);
        alts.deinit();
    }
    var alt_start = start;
    var i = alt_start;
    var depth: usize = 0;
    while (i < end) {
        switch (pattern[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return error.UnmatchedParen;
                depth -= 1;
            },
            '|' => {
                if (depth == 0) {
                    const nodes = try parseAlt(alloc, pattern, alt_start, i);
                    try alts.append(nodes);
                    alt_start = i + 1;
                }
            },
            else => {},
        }
        i += 1;
    }
    if (depth != 0) return error.UnterminatedGroup;
    const nodes = try parseAlt(alloc, pattern, alt_start, end);
    try alts.append(nodes);
    return try alts.toOwnedSlice();
}

fn parseAlt(alloc: Allocator, pattern: []const u8, start: usize, end: usize) ParseError!Alt {
    var nodes = AlignedManaged(Node, null).init(alloc);
    errdefer nodes.deinit();
    var i = start;
    while (i < end) {
        switch (pattern[i]) {
            '\\' => {
                i += 1;
                if (i >= end) return error.InvalidPattern;
                try nodes.append(switch (pattern[i]) {
                    'd' => Node{ .kind = .char_class, .class_bits = digitBits() },
                    'w' => Node{ .kind = .char_class, .class_bits = wordBits() },
                    's' => Node{ .kind = .char_class, .class_bits = spaceBits() },
                    'D' => Node{ .kind = .char_class_neg, .class_bits = digitBits() },
                    'W' => Node{ .kind = .char_class_neg, .class_bits = wordBits() },
                    'S' => Node{ .kind = .char_class_neg, .class_bits = spaceBits() },
                    else => Node{ .kind = .literal, .ch = pattern[i] },
                });
            },
            '.' => try nodes.append(.{ .kind = .dot }),
            '^' => try nodes.append(.{ .kind = .caret }),
            '$' => try nodes.append(.{ .kind = .dollar }),
            '*' => {
                if (nodes.items.len == 0) return error.InvalidPattern;
                var prev = nodes.pop().?;
                prev.child_kind = prev.kind;
                prev.kind = .star;
                try nodes.append(prev);
            },
            '+' => {
                if (nodes.items.len == 0) return error.InvalidPattern;
                var prev = nodes.pop().?;
                prev.child_kind = prev.kind;
                prev.kind = .plus;
                try nodes.append(prev);
            },
            '?' => {
                if (nodes.items.len == 0) return error.InvalidPattern;
                var prev = nodes.pop().?;
                prev.child_kind = prev.kind;
                prev.kind = .maybe;
                try nodes.append(prev);
            },
            '[' => {
                i += 1;
                var negated = false;
                if (i < end and pattern[i] == '^') {
                    negated = true;
                    i += 1;
                }
                var bits: u128 = 0;
                var range_start: u8 = 0;
                var in_range = false;
                while (i < end and pattern[i] != ']') {
                    if (pattern[i] == '\\') {
                        i += 1;
                        if (i >= end) return error.InvalidPattern;
                        const esc_ch = pattern[i];
                        const sh_bits: u128 = if (esc_ch == 'd') digitBits() else if (esc_ch == 'w') wordBits() else if (esc_ch == 's') spaceBits() else 0;
                        if (sh_bits != 0) {
                            bits |= sh_bits;
                            i += 1;
                            continue;
                        }
                        if (in_range) {
                            var r: u8 = range_start;
                            while (r <= esc_ch and r < 128) : (r += 1) bits |= @as(u128, 1) << @intCast(r);
                            in_range = false;
                        } else {
                            if (esc_ch < 128) bits |= @as(u128, 1) << @intCast(esc_ch);
                        }
                        i += 1;
                        continue;
                    }
                    if (pattern[i] == '-' and i + 1 < end and pattern[i + 1] != ']') {
                        range_start = pattern[i - 1];
                        in_range = true;
                        i += 1;
                        continue;
                    }
                    if (in_range) {
                        var r: u8 = range_start;
                        while (r <= pattern[i] and r < 128) : (r += 1) bits |= @as(u128, 1) << @intCast(r);
                        in_range = false;
                    } else {
                        if (pattern[i] < 128) bits |= @as(u128, 1) << @intCast(pattern[i]);
                    }
                    i += 1;
                }
                if (i >= end) return error.UnterminatedClass;
                if (negated) {
                    try nodes.append(.{ .kind = .char_class_neg, .class_bits = bits });
                } else {
                    try nodes.append(.{ .kind = .char_class, .class_bits = bits });
                }
            },
            '(' => {
                i += 1;
                const gs = i;
                var depth: usize = 1;
                while (i < end and depth > 0) : (i += 1) {
                    if (pattern[i] == '(') depth += 1;
                    if (pattern[i] == ')') depth -= 1;
                }
                if (depth != 0) return error.UnterminatedGroup;
                const ge = i - 1;
                i = ge;
                const group_alts = try parseAlts(alloc, pattern, gs, ge);
                try nodes.append(.{ .kind = .group, .children = group_alts });
            },
            ')' => return error.UnmatchedParen,
            '|' => return error.UnexpectedPipe,
            else => try nodes.append(.{ .kind = .literal, .ch = pattern[i] }),
        }
        i += 1;
    }
    return try nodes.toOwnedSlice();
}

fn classMatch(ch: u8, node: Node) bool {
    if (ch >= 128) return node.kind != .char_class;
    const present = (node.class_bits >> @intCast(ch)) & 1 == 1;
    return if (node.kind == .char_class_neg) !present else present;
}

fn matchOne(ch: u8, node: Node) bool {
    switch (node.kind) {
        .literal => return node.ch == ch,
        .dot => return true,
        .char_class, .char_class_neg => return classMatch(ch, node),
        .star, .plus, .maybe => {
            return switch (node.child_kind) {
                .dot => true,
                .char_class, .char_class_neg => classMatch(ch, node),
                else => node.ch == ch,
            };
        },
        else => return false,
    }
}

fn childNode(node: Node) Node {
    return .{
        .kind = node.child_kind,
        .ch = node.ch,
        .class_bits = node.class_bits,
        .children = node.children,
    };
}

fn matchAlt(alt: Alt, s: []const u8, pos: usize) ?usize {
    var p = pos;
    var i: usize = 0;
    while (i < alt.len) {
        const node = alt[i];
        switch (node.kind) {
            .caret => { if (p != 0) return null; },
            .dollar => { if (p != s.len) return null; },
            .literal, .dot, .char_class, .char_class_neg => {
                if (p >= s.len or !matchOne(s[p], node)) return null;
                p += 1;
            },
            .star => {
                const child = childNode(node);
                var child_arr = [_]Node{child};
                const child_alt: Alt = &child_arr;
                var ends: [512]usize = undefined;
                ends[0] = p;
                var count: usize = 0;
                var cur = p;
                while (count < ends.len - 1) {
                    if (matchAlt(child_alt, s, cur)) |e| {
                        if (e == cur) break;
                        count += 1;
                        cur = e;
                        ends[count] = cur;
                    } else {
                        break;
                    }
                }
                var idx = count;
                while (true) {
                    if (matchAlt(alt[i + 1 ..], s, ends[idx])) |result| return result;
                    if (idx == 0) break;
                    idx -= 1;
                }
                return null;
            },
            .plus => {
                const child = childNode(node);
                var child_arr = [_]Node{child};
                const child_alt: Alt = &child_arr;
                var ends: [512]usize = undefined;
                var count: usize = 0;
                var cur = p;
                while (count < ends.len) {
                    if (matchAlt(child_alt, s, cur)) |e| {
                        if (e == cur) break;
                        ends[count] = e;
                        count += 1;
                        cur = e;
                    } else {
                        if (count == 0) return null;
                        break;
                    }
                }
                var idx = count;
                while (idx > 0) {
                    idx -= 1;
                    if (matchAlt(alt[i + 1 ..], s, ends[idx])) |result| return result;
                }
                return null;
            },
            .maybe => {
                const child = childNode(node);
                var child_arr = [_]Node{child};
                const child_alt: Alt = &child_arr;
                if (matchAlt(child_alt, s, p)) |end| {
                    if (matchAlt(alt[i + 1 ..], s, end)) |result| return result;
                }
                return matchAlt(alt[i + 1 ..], s, p);
            },
            .group => {
                const m = matchAny(node.children, s, p) orelse return null;
                p = m;
            },
        }
        i += 1;
    }
    return p;
}

fn matchAny(alts: []Alt, s: []const u8, pos: usize) ?usize {
    for (alts) |alt| {
        if (matchAlt(alt, s, pos)) |end| return end;
    }
    return null;
}

fn fullMatch(alts: []Alt, s: []const u8) bool {
    return (matchAny(alts, s, 0) orelse return false) == s.len;
}

fn findMatch(alts: []Alt, s: []const u8) ?struct { usize, usize } {
    if (alts.len > 0 and alts[0].len > 0 and alts[0][0].kind == .caret) {
        const end = matchAny(alts, s, 0) orelse return null;
        if (end > 0) return .{ 0, end };
        return null;
    }
    var i: usize = 0;
    while (i < s.len) {
        if (matchAny(alts, s, i)) |end| {
            if (end > i) return .{ i, end };
        }
        i += 1;
    }
    return null;
}

fn findAllMatches(alts: []Alt, s: []const u8, alloc: std.mem.Allocator) ![]struct { usize, usize } {
    var matches = AlignedManaged(struct { usize, usize }, null).init(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (matchAny(alts, s, i)) |end| {
            if (end > i) {
                try matches.append(.{ i, end });
                i = end;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return try matches.toOwnedSlice();
}

// ── Native function implementations ──────────────────────────────────────────

fn parsePattern(pattern: []const u8) ParseError![]Alt {
    if (pattern.len > MaxPatternLen) return error.PatternTooLong;
    const alloc = std.heap.page_allocator;
    const alts = try parseAlts(alloc, pattern, 0, pattern.len);
    return alts;
}

fn freeAlts(alts: []Alt) void {
    const alloc = std.heap.page_allocator;
    for (alts) |alt| {
        for (alt) |node| {
            if (node.kind == .group and node.children.len > 0) {
                freeAlts(node.children);
            }
        }
        alloc.free(alt);
    }
    alloc.free(alts);
}

pub fn nativeReMatch(pattern_val: Value, s_val: Value) !Value {
    const pattern = try reGetPattern(pattern_val);
    const s = try vms.asStringValue(s_val);
    const alts = parsePattern(pattern) catch |err| return err;
    defer freeAlts(alts);
    return .{ .boolean = findMatch(alts, s) != null };
}

pub fn nativeReFind(pattern_val: Value, s_val: Value) !Value {
    const pattern = try reGetPattern(pattern_val);
    const s = try vms.asStringValue(s_val);
    const alts = parsePattern(pattern) catch |err| return err;
    defer freeAlts(alts);
    const m = findMatch(alts, s) orelse return .null;
    return try vmgc.makeDynString(s[m[0]..m[1]]);
}

pub fn nativeReFindAll(pattern_val: Value, s_val: Value) !Value {
    const pattern = try reGetPattern(pattern_val);
    const s = try vms.asStringValue(s_val);
    const alloc = std.heap.page_allocator;
    const alts = parsePattern(pattern) catch |err| return err;
    defer freeAlts(alts);
    const matches = findAllMatches(alts, s, alloc) catch |err| { alloc.free(alts); return err; };
    defer alloc.free(matches);
    const result = try vmgc.vmAllocManagedSlice(Value, matches.len);
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    for (matches, 0..) |m, j| {
        result[j] = try vmgc.makeDynString(s[m[0]..m[1]]);
    }
    obj.* = .{ .array_managed = result };
    return .{ .object = obj };
}

pub fn nativeReReplace(pattern_val: Value, s_val: Value, repl_val: Value) !Value {
    const pattern = try reGetPattern(pattern_val);
    const s = try vms.asStringValue(s_val);
    const repl = try vms.asStringValue(repl_val);
    const alloc = std.heap.page_allocator;
    const alts = parsePattern(pattern) catch |err| return err;
    defer freeAlts(alts);
    var result = AlignedManaged(u8, null).init(alloc);
    defer result.deinit();
    var i: usize = 0;
    while (i < s.len) {
        const m = findMatch(alts, s[i..]) orelse {
            try result.appendSlice(s[i..]);
            break;
        };
        try result.appendSlice(s[i .. i + m[0]]);
        try result.appendSlice(repl);
        i += m[1];
    }
    return try vmgc.makeDynString(result.items);
}

pub fn nativeReSplit(pattern_val: Value, s_val: Value) !Value {
    const pattern = try reGetPattern(pattern_val);
    const s = try vms.asStringValue(s_val);
    const alloc = std.heap.page_allocator;
    const alts = parsePattern(pattern) catch |err| return err;
    defer freeAlts(alts);
    var parts = AlignedManaged([]const u8, null).init(alloc);
    defer parts.deinit();
    var i: usize = 0;
    while (i < s.len) {
        const m = findMatch(alts, s[i..]) orelse {
            try parts.append(s[i..]);
            break;
        };
        try parts.append(s[i .. i + m[0]]);
        i += m[1];
    }
    const result = try vmgc.vmAllocManagedSlice(Value, parts.items.len);
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    for (parts.items, 0..) |part, j| {
        result[j] = try vmgc.makeDynString(part);
    }
    obj.* = .{ .array_managed = result };
    return .{ .object = obj };
}

pub fn nativeReCompile(pattern_val: Value) !Value {
    const pattern = try vms.asStringValue(pattern_val);
    if (pattern.len > MaxPatternLen) return error.PatternTooLong;
    const alloc = std.heap.page_allocator;
    const alts = try parseAlts(alloc, pattern, 0, pattern.len);
    freeAlts(alts);
    return try reBuildObj(pattern);
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .re_compile => {

            if (argc != nf.arity) return error.ArityMismatch;
            const pattern_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const result = try nativeReCompile(pattern_val);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_find => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const result = try nativeReFind(pattern_val, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_find_all => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const result = try nativeReFindAll(pattern_val, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_match => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const result = try nativeReMatch(pattern_val, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_find => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const pattern = try reGetPattern(recv);
            const result = try nativeReFind(.{ .string = pattern }, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_find_all => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const pattern = try reGetPattern(recv);
            const result = try nativeReFindAll(.{ .string = pattern }, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_match => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const pattern = try reGetPattern(recv);
            const result = try nativeReMatch(.{ .string = pattern }, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_replace => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 3];
            const s_val = vms.vmState().stack[top - 2];
            const repl_val = vms.vmState().stack[top - 1];
            const pattern = try reGetPattern(recv);
            const result = try nativeReReplace(.{ .string = pattern }, s_val, repl_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_obj_split => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const pattern = try reGetPattern(recv);
            const result = try nativeReSplit(.{ .string = pattern }, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_replace => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 3];
            const s_val = vms.vmState().stack[top - 2];
            const repl_val = vms.vmState().stack[top - 1];
            const result = try nativeReReplace(pattern_val, s_val, repl_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .re_split => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const pattern_val = vms.vmState().stack[top - 2];
            const s_val = vms.vmState().stack[top - 1];
            const result = try nativeReSplit(pattern_val, s_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        else => {},
    }
}
