// Standalone test runner: no IPC with the build system.
// Reports results to stderr only; stdout is untouched (safe for any gengo
// tests that exercise io.write() without overrides).
//
// Wire in via:
//   b.addTest(.{
//       .root_module = mod,
//       .test_runner = .{ .path = b.path("tools/standalone_runner.zig"), .mode = .simple },
//   })
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = logFn };

var log_err_count: usize = 0;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ fmt ++ "\n", args);
    }
}

pub fn main() void {
    const io_ref = std.Io.Threaded.global_single_threaded.io();
    const test_fns = builtin.test_functions;
    var ok: usize = 0;
    var skip: usize = 0;
    var fail: usize = 0;
    var leaks: usize = 0;

    for (test_fns, 0..) |t, i| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{});
        log_err_count = 0;
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) leaks += 1;
        }

        std.Io.File.stderr().writeStreamingAll(io_ref, t.name) catch {};
        std.Io.File.stderr().writeStreamingAll(io_ref, "...") catch {};

        if (t.func()) |_| {
            if (log_err_count > 0) {
                std.Io.File.stderr().writeStreamingAll(io_ref, "FAIL (log errors)\n") catch {};
                fail += 1;
            } else {
                std.Io.File.stderr().writeStreamingAll(io_ref, "OK\n") catch {};
                ok += 1;
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                std.Io.File.stderr().writeStreamingAll(io_ref, "SKIP\n") catch {};
                skip += 1;
            },
            else => {
                std.Io.File.stderr().writeStreamingAll(io_ref, "FAIL\n") catch {};
                fail += 1;
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
        _ = i;
    }

    if (fail == 0 and leaks == 0) {
        std.debug.print("All {d} tests passed.\n", .{ok + skip});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed; {d} leaked.\n", .{ ok, skip, fail, leaks });
    }
    if (fail > 0 or leaks > 0) std.process.exit(1);
}
