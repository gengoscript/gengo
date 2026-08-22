const std = @import("std");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;

fn strBytes(v: Value) ?[]const u8 {
    if (v == .string) return v.string.bytes;
    if (v == .object) {
        return switch (v.object.*) {
            .dyn_string => |s| s,
            .string_view => |sv| sv.bytes,
            else => null,
        };
    }
    return null;
}

fn valueCompare(a: Value, b: Value, comptime op: enum { lt, gt }) !bool {
    if (a == .int and b == .int) return switch (op) {
        .lt => a.int < b.int,
        .gt => a.int > b.int,
    };
    if (a == .float and b == .float) return switch (op) {
        .lt => a.float < b.float,
        .gt => a.float > b.float,
    };
    if (a == .boolean and b == .boolean) return switch (op) {
        .lt => !a.boolean and b.boolean,
        .gt => a.boolean and !b.boolean,
    };
    const sa = strBytes(a);
    if (sa) |sa_bytes| {
        const sb = strBytes(b);
        if (sb) |sb_bytes| return switch (op) {
            .lt => std.mem.lessThan(u8, sa_bytes, sb_bytes),
            .gt => std.mem.lessThan(u8, sb_bytes, sa_bytes),
        };
    }
    return switch (op) {
        .lt => @intFromEnum(a) < @intFromEnum(b),
        .gt => @intFromEnum(a) > @intFromEnum(b),
    };
}

pub fn valueLessThan(a: Value, b: Value) !bool {
    return valueCompare(a, b, .lt);
}
pub fn valueGreaterThan(a: Value, b: Value) !bool {
    return valueCompare(a, b, .gt);
}

const testing = std.testing;
const value_mod = @import("../value.zig");

test "valueCompare: int/float/bool comparisons" {
    try testing.expect(try valueLessThan(.{ .int = 1 }, .{ .int = 2 }));
    try testing.expect(!(try valueLessThan(.{ .int = 2 }, .{ .int = 1 })));
    try testing.expect(try valueGreaterThan(.{ .int = 2 }, .{ .int = 1 }));

    try testing.expect(try valueLessThan(.{ .float = 1.5 }, .{ .float = 2.5 }));
    try testing.expect(try valueGreaterThan(.{ .float = 2.5 }, .{ .float = 1.5 }));

    try testing.expect(try valueLessThan(.{ .boolean = false }, .{ .boolean = true }));
    try testing.expect(try valueGreaterThan(.{ .boolean = true }, .{ .boolean = false }));
    try testing.expect(!(try valueLessThan(.{ .boolean = true }, .{ .boolean = true })));
}

test "valueCompare: string comparisons across .string/.dyn_string/.string_view representations" {
    const lit_a = Value{ .string = value_mod.staticSS("apple") };
    const lit_b = Value{ .string = value_mod.staticSS("banana") };
    try testing.expect(try valueLessThan(lit_a, lit_b));
    try testing.expect(try valueGreaterThan(lit_b, lit_a));

    var dyn_buf: [5]u8 = "apple".*;
    var dyn_obj: Object = .{ .dyn_string = &dyn_buf };
    const dyn_val = Value{ .object = &dyn_obj };
    try testing.expect(try valueLessThan(dyn_val, lit_b));
    try testing.expect(!(try valueLessThan(lit_b, dyn_val)));

    var view_obj: Object = .{ .string_view = .{ .bytes = "apple", .source = null } };
    const view_val = Value{ .object = &view_obj };
    try testing.expect(try valueLessThan(view_val, lit_b));

    // dyn_string vs string_view: both resolve to the same bytes ("apple"),
    // so neither direction should report strictly less/greater.
    try testing.expect(!(try valueLessThan(dyn_val, view_val)));
    try testing.expect(!(try valueGreaterThan(dyn_val, view_val)));
}

test "valueCompare: cross-type fallback is antisymmetric and mutually exclusive" {
    // int vs boolean never matches string/int/float/bool-vs-same-tag rules
    // above, so it falls through to the @intFromEnum(tag) order fallback.
    // Assert the actual contract (swapping args flips lt<->gt, and lt/gt
    // can't both hold) rather than hard-coding which tag sorts first.
    const int_val = Value{ .int = 5 };
    const bool_val = Value{ .boolean = true };

    const lt = try valueLessThan(int_val, bool_val);
    const gt = try valueGreaterThan(int_val, bool_val);
    const lt_reversed = try valueLessThan(bool_val, int_val);
    const gt_reversed = try valueGreaterThan(bool_val, int_val);

    try testing.expect(!(lt and gt));
    try testing.expectEqual(lt, gt_reversed);
    try testing.expectEqual(gt, lt_reversed);
    // Different tags (int vs boolean) must compare unequal one way or the
    // other — this is a real cross-type comparison, not a same-tag no-op.
    try testing.expect(lt or gt);
}
