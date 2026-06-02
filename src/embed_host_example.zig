const std = @import("std");
const api = @import("runtime/api.zig");
const Value = @import("lang/value.zig").Value;

pub fn main() !void {
    var rt = api.Runtime.init(.{ .allow_io = false, .max_ops = 200000 });

    const setup = rt.run(
        \\counter := 0
        \\func bump(delta int) int {
        \\    counter += delta
        \\    return counter
        \\}
    );
    switch (setup) {
        .ok => {},
        .compile_error => |e| {
            std.debug.print("compile error line={d} kind={s}\n", .{ e.line, @errorName(e.kind) });
            return;
        },
        .runtime_error => |e| {
            std.debug.print("runtime error kind={s}\n", .{@errorName(e.kind)});
            return;
        },
    }

    const a = rt.call("bump", &[_]Value{.{ .number = 2 }});
    const b = rt.call("bump", &[_]Value{.{ .number = 5 }});
    switch (a) {
        .ok => |v| std.debug.print("bump(2) -> {d}\n", .{v.number}),
        .runtime_error => |e| std.debug.print("call error: {s}\n", .{@errorName(e.kind)}),
    }
    switch (b) {
        .ok => |v| std.debug.print("bump(5) -> {d}\n", .{v.number}),
        .runtime_error => |e| std.debug.print("call error: {s}\n", .{@errorName(e.kind)}),
    }
}
