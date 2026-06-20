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
    if (a == .int and b == .int) return switch (op) { .lt => a.int < b.int, .gt => a.int > b.int };
    if (a == .float and b == .float) return switch (op) { .lt => a.float < b.float, .gt => a.float > b.float };
    if (a == .boolean and b == .boolean) return switch (op) { .lt => !a.boolean and b.boolean, .gt => a.boolean and !b.boolean };
    const sa = strBytes(a);
    if (sa) |sa_bytes| {
        const sb = strBytes(b);
        if (sb) |sb_bytes| return switch (op) { .lt => std.mem.lessThan(u8, sa_bytes, sb_bytes), .gt => std.mem.lessThan(u8, sb_bytes, sa_bytes) };
    }
    return switch (op) { .lt => @intFromEnum(a) < @intFromEnum(b), .gt => @intFromEnum(a) > @intFromEnum(b) };
}

pub fn valueLessThan(a: Value, b: Value) !bool { return valueCompare(a, b, .lt); }
pub fn valueGreaterThan(a: Value, b: Value) !bool { return valueCompare(a, b, .gt); }


