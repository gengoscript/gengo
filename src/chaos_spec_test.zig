const std = @import("std");
const api = @import("runtime/api.zig");
const io = @import("runtime/io.zig");

var g_stdout: std.array_list.Managed(u8) = undefined;
var g_stderr: std.array_list.Managed(u8) = undefined;

fn captureStdout(s: []const u8) void {
    g_stdout.appendSlice(s) catch {};
}

fn captureStderr(s: []const u8) void {
    g_stderr.appendSlice(s) catch {};
}

fn runWithCapture(rt: *api.Runtime, src: []const u8, path: []const u8) struct { api.RuntimeResult, []const u8, []const u8 } {
    g_stdout.clearRetainingCapacity();
    g_stderr.clearRetainingCapacity();
    io.setWriteOverrides(captureStdout, captureStderr);
    defer io.clearWriteOverrides();
    const result = if (path.len > 0) rt.runPath(src, path) else rt.run(src);
    return .{ result, g_stdout.items, g_stderr.items };
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0);
    defer _ = std.posix.system.close(fd);
    var buf = try alloc.alloc(u8, max_bytes);
    errdefer alloc.free(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch |err| {
            if (err == error.WouldBlock or err == error.Interrupted) continue;
            return err;
        };
        if (n == 0) break;
        total += n;
    }
    if (total < buf.len) {
        buf = try alloc.realloc(buf, total);
    }
    return buf[0..total];
}

fn runFileWithCapture(rt: *api.Runtime, path: []const u8) !struct { api.RuntimeResult, []const u8, []const u8 } {
    const src = try readFileAlloc(std.testing.allocator, path, 1024 * 1024);
    defer std.testing.allocator.free(src);
    return runWithCapture(rt, src, path);
}

fn errTokenMatches(output: []const u8, err_token: []const u8) bool {
    var lines = std.mem.splitScalar(u8, err_token, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const found = std.mem.indexOf(u8, output, line) != null;
        if (found) return true;
    }
    return false;
}

fn setup() !api.Runtime {
    return api.Runtime.init(.{ .allow_io = true, .allocator = std.testing.allocator });
}

// ── Chaos pass cases ───────────────────────────────────────────────────────

test "chaos pass cases" {
    const io_ref = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var d = try cwd.openDir(io_ref, "tests/chaos", .{ .iterate = true });
    defer d.close(io_ref);

    var iter = d.iterate();
    var count: usize = 0;
    while (try iter.next(io_ref)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".gengo")) continue;

        const path = try std.fs.path.join(std.testing.allocator, &.{ "tests/chaos", entry.name });
        defer std.testing.allocator.free(path);

        const base = path[0 .. path.len - 6];
        const out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.out", .{base});
        defer std.testing.allocator.free(out_path);

        const expected = readFileAlloc(std.testing.allocator, out_path, 512 * 1024) catch |err| {
            std.debug.print("missing {s}: {s}\n", .{ out_path, @errorName(err) });
            return err;
        };
        defer std.testing.allocator.free(expected);

        var rt = try setup();
        defer rt.deinit();

        g_stdout = std.array_list.Managed(u8).init(std.testing.allocator);
        g_stderr = std.array_list.Managed(u8).init(std.testing.allocator);
        defer g_stdout.deinit();
        defer g_stderr.deinit();

        const r = try runFileWithCapture(&rt, path);
        const result = r[0];
        const output = r[1];
        const stderr_out = r[2];
        _ = stderr_out;

        if (result != .ok) {
            std.debug.print("chaos pass case {s} failed unexpectedly: {s}\n", .{ entry.name, @tagName(result) });
            return error.TestUnexpectedResult;
        }

        if (!std.mem.eql(u8, expected, output)) {
            std.debug.print("chaos pass case {s} output mismatch\nexpected:\n{s}\ngot:\n{s}\n", .{ entry.name, expected, output });
            return error.TestUnexpectedResult;
        }

        count += 1;
    }

    if (count == 0) return error.NoChaosPassCases;
}

// ── Chaos fail cases ───────────────────────────────────────────────────────

test "chaos fail cases" {
    const io_ref = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var d = try cwd.openDir(io_ref, "tests/chaos/fail", .{ .iterate = true });
    defer d.close(io_ref);

    var iter = d.iterate();
    var count: usize = 0;
    while (try iter.next(io_ref)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".gengo")) continue;
        // 029_truncation depends on max_input_bytes which varies by preset
        if (std.mem.eql(u8, entry.name, "029_truncation.gengo")) continue;
        // 016_max_defers depends on max_defers which varies by preset
        if (std.mem.eql(u8, entry.name, "016_max_defers.gengo")) continue;
        // 005_recursion depends on max_frames which varies by preset
        if (std.mem.eql(u8, entry.name, "005_recursion.gengo")) continue;
        // 004_fewer_long_vars depends on max_input_bytes which varies by preset
        if (std.mem.eql(u8, entry.name, "004_fewer_long_vars.gengo")) continue;
        // 012_string_pool_overflow depends on max_input_bytes vs string pool size mismatch
        if (std.mem.eql(u8, entry.name, "012_string_pool_overflow.gengo")) continue;

        const path = try std.fs.path.join(std.testing.allocator, &.{ "tests/chaos/fail", entry.name });
        defer std.testing.allocator.free(path);

        const base = path[0 .. path.len - 6];
        const err_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.err", .{base});
        defer std.testing.allocator.free(err_path);

        const err_token_raw = readFileAlloc(std.testing.allocator, err_path, 1024) catch |err| {
            std.debug.print("missing {s}: {s}\n", .{ err_path, @errorName(err) });
            return err;
        };
        defer std.testing.allocator.free(err_token_raw);
        const err_token = std.mem.trimEnd(u8, err_token_raw, "\n\r");

        var rt = try setup();
        defer rt.deinit();

        g_stdout = std.array_list.Managed(u8).init(std.testing.allocator);
        g_stderr = std.array_list.Managed(u8).init(std.testing.allocator);
        defer g_stdout.deinit();
        defer g_stderr.deinit();

        const r = try runFileWithCapture(&rt, path);
        const result = r[0];
        const output = r[1];
        const stderr_out = r[2];

        if (result == .ok) {
            std.debug.print("chaos fail case {s} succeeded unexpectedly\n", .{entry.name});
            return error.TestUnexpectedResult;
        }

        var combined: []const u8 = "";
        if (result == .compile_error) {
            const kind_name = @errorName(result.compile_error.kind);
            combined = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}{s}", .{ output, stderr_out, result.compile_error.msg, kind_name });
        } else if (result == .runtime_error) {
            const kind_name = @errorName(result.runtime_error.kind);
            combined = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}{s}", .{ output, stderr_out, result.runtime_error.msg, kind_name });
        } else {
            combined = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ output, stderr_out });
        }
        defer std.testing.allocator.free(combined);

        if (!errTokenMatches(combined, err_token)) {
            std.debug.print("chaos fail case {s}: expected error token '{s}' not found in output:\n{s}\n", .{ entry.name, err_token, combined });
            return error.TestUnexpectedResult;
        }

        count += 1;
    }

    if (count == 0) return error.NoChaosFailCases;
}

// ── Spec fail cases ────────────────────────────────────────────────────────

test "spec fail cases" {
    const io_ref = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var d = try cwd.openDir(io_ref, "tests/spec/fail", .{ .iterate = true });
    defer d.close(io_ref);

    var iter = d.iterate();
    var count: usize = 0;
    while (try iter.next(io_ref)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".gengo")) continue;

        const path = try std.fs.path.join(std.testing.allocator, &.{ "tests/spec/fail", entry.name });
        defer std.testing.allocator.free(path);

        const base = path[0 .. path.len - 6];
        const err_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.err", .{base});
        defer std.testing.allocator.free(err_path);

        const err_token_raw = readFileAlloc(std.testing.allocator, err_path, 1024) catch |err| {
            std.debug.print("missing {s}: {s}\n", .{ err_path, @errorName(err) });
            return err;
        };
        defer std.testing.allocator.free(err_token_raw);
        const err_token = std.mem.trimEnd(u8, err_token_raw, "\n\r");

        var rt = try setup();
        defer rt.deinit();

        g_stdout = std.array_list.Managed(u8).init(std.testing.allocator);
        g_stderr = std.array_list.Managed(u8).init(std.testing.allocator);
        defer g_stdout.deinit();
        defer g_stderr.deinit();

        const r = try runFileWithCapture(&rt, path);
        const result = r[0];
        const output = r[1];
        const stderr_out = r[2];

        if (result == .ok) {
            std.debug.print("spec fail case {s} succeeded unexpectedly\n", .{entry.name});
            return error.TestUnexpectedResult;
        }

        var combined: []const u8 = "";
        if (result == .compile_error) {
            const kind_name = @errorName(result.compile_error.kind);
            combined = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}{s}", .{ output, stderr_out, result.compile_error.msg, kind_name });
        } else if (result == .runtime_error) {
            const kind_name = @errorName(result.runtime_error.kind);
            combined = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}{s}", .{ output, stderr_out, result.runtime_error.msg, kind_name });
        } else {
            combined = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ output, stderr_out });
        }
        defer std.testing.allocator.free(combined);

        if (!errTokenMatches(combined, err_token)) {
            std.debug.print("spec fail case {s}: expected error token '{s}' not found in output:\n{s}\n", .{ entry.name, err_token, combined });
            return error.TestUnexpectedResult;
        }

        count += 1;
    }

    if (count == 0) return error.NoSpecFailCases;
}

