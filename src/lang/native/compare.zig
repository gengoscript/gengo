const std = @import("std");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;

fn strBytes(v: Value) ?[]const u8 {
    if (v == .string) return v.string;
    if (v == .object and v.object.* == .dyn_string) return v.object.dyn_string;
    return null;
}

pub fn valueLessThan(a: Value, b: Value) !bool {
    if (a == .int and b == .int) return a.int < b.int;
    if (a == .float and b == .float) return a.float < b.float;
    if (a == .boolean and b == .boolean) return !a.boolean and b.boolean;
    const sa = strBytes(a);
    if (sa) |sa_bytes| {
        const sb = strBytes(b);
        if (sb) |sb_bytes| return std.mem.lessThan(u8, sa_bytes, sb_bytes);
    }
    return @intFromEnum(a) < @intFromEnum(b);
}

pub fn valueGreaterThan(a: Value, b: Value) !bool {
    if (a == .int and b == .int) return a.int > b.int;
    if (a == .float and b == .float) return a.float > b.float;
    if (a == .boolean and b == .boolean) return a.boolean and !b.boolean;
    const sa = strBytes(a);
    if (sa) |sa_bytes| {
        const sb = strBytes(b);
        if (sb) |sb_bytes| return std.mem.lessThan(u8, sb_bytes, sa_bytes);
    }
    return @intFromEnum(a) > @intFromEnum(b);
}


