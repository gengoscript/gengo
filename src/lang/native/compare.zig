const std = @import("std");
const Value = @import("../value.zig").Value;

pub fn valueLessThan(a: Value, b: Value) !bool {
    if (a == .number and b == .number) return a.number < b.number;
    if (a == .string and b == .string) return std.mem.lessThan(u8, a.string, b.string);
    if (a == .boolean and b == .boolean) return !a.boolean and b.boolean;
    return @intFromEnum(a) < @intFromEnum(b);
}

pub fn valueGreaterThan(a: Value, b: Value) !bool {
    if (a == .number and b == .number) return a.number > b.number;
    if (a == .string and b == .string) return std.mem.lessThan(u8, b.string, a.string);
    if (a == .boolean and b == .boolean) return a.boolean and !b.boolean;
    return @intFromEnum(a) > @intFromEnum(b);
}


