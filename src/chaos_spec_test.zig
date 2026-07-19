const std = @import("std");
const api = @import("runtime/api.zig");
const io = @import("runtime/io.zig");
const chunk = @import("lang/chunk.zig");
const vm = @import("lang/vm.zig");
const vm_defuse = @import("lang/vm_defuse.zig");
const fusion_pass = @import("lang/fusion_pass.zig");
const heap = @import("runtime/heap.zig");
const cfg = @import("runtime_config");

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

fn expectInlineOutput(src: []const u8, expected: []const u8) !void {
    var rt = try setup();
    defer rt.deinit();

    g_stdout = std.array_list.Managed(u8).init(std.testing.allocator);
    g_stderr = std.array_list.Managed(u8).init(std.testing.allocator);
    defer g_stdout.deinit();
    defer g_stderr.deinit();

    const r = runWithCapture(&rt, src, "");
    const result = r[0];
    const output = r[1];
    const stderr_out = r[2];

    if (result != .ok) {
        if (result == .compile_error) {
            std.debug.print("inline compile error: {s}\n", .{result.compile_error.msg});
            return error.TestUnexpectedResult;
        }
        if (result == .runtime_error) {
            std.debug.print("inline runtime error: {s}\n", .{result.runtime_error.msg});
            return error.TestUnexpectedResult;
        }
        _ = stderr_out;
        return error.TestUnexpectedResult;
    }

    try std.testing.expectEqualStrings(expected, output);
}

test "access parity: named type dot and index surface agree" {
    try expectInlineOutput(
        \\std := import("std")
        \\
        \\type Month int range 1..12
        \\
        \\m := Month(4)
        \\std.io.println(Month.name)
        \\std.io.println(Month["name"])
        \\std.io.println(Month.first)
        \\std.io.println(Month["first"])
        \\std.io.println(Month.last)
        \\std.io.println(Month["last"])
        \\std.io.println(m == Month.first)
        \\std.io.println(m == Month["first"])
    ,
        \\Month
        \\Month
        \\1
        \\1
        \\12
        \\12
        \\false
        \\false
        \\
    );
}

test "access parity: variant type dot and index name lookup agree" {
    try expectInlineOutput(
        \\std := import("std")
        \\
        \\type Shape variant {
        \\    x float,
        \\    y float,
        \\    circle { radius float },
        \\    point,
        \\}
        \\
        \\std.io.println(Shape.name)
        \\std.io.println(Shape["name"])
        \\
        \\dot_circle := Shape.circle { x: 1, y: 2, radius: 5 }
        \\dot_point := Shape.point { x: 7, y: 8 }
        \\
        \\std.io.println(dot_circle.radius)
        \\std.io.println(dot_point.x)
    ,
        \\Shape
        \\Shape
        \\5
        \\7
        \\
    );
}

test "access parity: variant value dot and index field lookup agree" {
    try expectInlineOutput(
        \\std := import("std")
        \\
        \\type Shape variant {
        \\    x float,
        \\    y float,
        \\    circle { radius float },
        \\    rect { width float, height float },
        \\}
        \\
        \\circle := Shape.circle { x: 1, y: 2, radius: 5 }
        \\rect := Shape.rect { x: 3, y: 4, width: 10, height: 20 }
        \\
        \\std.io.println(circle.x)
        \\std.io.println(circle["x"])
        \\std.io.println(circle.radius)
        \\std.io.println(circle["radius"])
        \\std.io.println(rect.width)
        \\std.io.println(rect["width"])
    ,
        \\1
        \\1
        \\5
        \\5
        \\10
        \\10
        \\
    );
}

test "invoke parity: immediate and deferred method dispatch agree" {
    try expectInlineOutput(
        \\std := import("std")
        \\
        \\type UserId string
        \\func (u UserId) emit() {
        \\    std.io.println("user:" + string(u))
        \\}
        \\
        \\type Shape variant {
        \\    circle(radius int),
        \\    point,
        \\}
        \\func (s Shape) emit() {
        \\    switch s {
        \\        case .circle as v { std.io.println("shape:", v) }
        \\        case .point { std.io.println("shape:point") }
        \\    }
        \\}
        \\
        \\func outer() {
        \\    uid := UserId("alice")
        \\    shape := Shape.circle(7)
        \\    m := { "emit": func() { std.io.println("map:ok") } }
        \\    defer uid.emit()
        \\    defer shape.emit()
        \\    defer m.emit()
        \\    uid.emit()
        \\    shape.emit()
        \\    m.emit()
        \\}
        \\
        \\outer()
    ,
        \\user:alice
        \\shape:7
        \\map:ok
        \\map:ok
        \\shape:7
        \\user:alice
        \\
    );
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
        // 044 runs 400 GC rounds of live named strings; 256k is too small for this workload
        if (heap.HeapSize <= 256 * 1024 and std.mem.eql(u8, entry.name, "044_named_string_gc_windows.gengo")) continue;

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
        // 014_many_funcs expects TooManyGlobals; small heaps OOM before reaching the limit
        if (std.mem.eql(u8, entry.name, "014_many_funcs.gengo") and cfg.heap_size_bytes < 512 * 1024) continue;

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

// ── Spec pass cases — differential (defused vs fused) ─────────────────────
// For every spec pass case: compile, defuse the bytecode, run the defused
// version, and verify it also succeeds. Divergence means a fused opcode or
// IC path produces different semantics from the expanded primitives.

// ── Spec pass cases — refuse differential (defuse → fusion pass → run) ───
// Validates the load/compile-time fusion pass (lang/fusion_pass.zig, the
// forward direction of vm_defuse and the GBC load path): every pass case is
// compiled, DEFUSED to core ops (the future wire format), re-FUSED by the
// pass, executed, and its output compared against .out. Divergence means
// the pass mis-rewrote an instruction or a branch target.
test "spec pass cases refuse differential" {
    const alloc = std.testing.allocator;
    const io_ref = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var d = try cwd.openDir(io_ref, "tests/spec", .{ .iterate = true });
    defer d.close(io_ref);

    var iter = d.iterate();
    var count: usize = 0;
    var failures: usize = 0;
    var total_original: usize = 0;
    var total_defused: usize = 0;
    var total_fused: usize = 0;
    while (try iter.next(io_ref)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".gengo")) continue;
        const path = try std.fs.path.join(alloc, &.{ "tests/spec", entry.name });
        defer alloc.free(path);
        const src = readFileAlloc(alloc, path, 1024 * 1024) catch continue;
        defer alloc.free(src);
        const out_path = try std.fmt.allocPrint(alloc, "{s}.out", .{path[0 .. path.len - 6]});
        defer alloc.free(out_path);
        const expected = readFileAlloc(alloc, out_path, 1024 * 1024) catch continue;
        defer alloc.free(expected);

        var rt = try setup();
        defer rt.deinit();
        rt.inner.compileAndInstall(src, path, .filesystem) catch continue;

        // Defuse to core ops, install, then re-fuse with the pass.
        const original_len = chunk.g_state.code_len;
        const defused = vm_defuse.buildDefusedCode(vm.VMContext.fromActive().cs, alloc) catch continue;
        defer alloc.free(defused);
        if (defused.len > chunk.MaxCode) continue;
        @memcpy(chunk.g_state.code[0..defused.len], defused);
        chunk.g_state.code_len = defused.len;
        chunk.g_state.verified = false;
        chunk.g_state.verified_code_len = 0;
        total_original += original_len;
        total_defused += defused.len;
        defer total_fused += chunk.g_state.code_len;
        fusion_pass.fuse(chunk.g_state, alloc) catch |e| {
            std.debug.print("refuse FAIL (pass error): {s}: {s}\n", .{ path, @errorName(e) });
            failures += 1;
            continue;
        };
        vm.VMContext.fromActive().vs.resetExec();

        g_stdout = std.array_list.Managed(u8).init(alloc);
        g_stderr = std.array_list.Managed(u8).init(alloc);
        defer g_stdout.deinit();
        defer g_stderr.deinit();
        io.setWriteOverrides(captureStdout, captureStderr);
        defer io.clearWriteOverrides();

        vm.run(vm.VMContext.fromActive()) catch |e| {
            std.debug.print("refuse FAIL (runtime): {s}: {s}\n", .{ path, @errorName(e) });
            failures += 1;
            continue;
        };
        const combined = try std.mem.concat(alloc, u8, &.{ g_stdout.items, g_stderr.items });
        defer alloc.free(combined);
        if (!std.mem.eql(u8, expected, combined)) {
            std.debug.print("refuse FAIL (output mismatch): {s}\n", .{path});
            failures += 1;
            continue;
        }
        count += 1;
    }
    if (failures != 0) {
        std.debug.print("refuse differential: {d} passed, {d} FAILED\n", .{ count, failures });
        return error.TestUnexpectedResult;
    }
    if (count == 0) return error.NoSpecPassCases;
    // The pass must actually fuse: aggregate fused size strictly below the
    // defused input (guards against a silently pattern-blind pass).
    std.debug.print("refuse differential: {d} cases, emitter {d} / defused {d} -> pass {d} bytes\n", .{ count, total_original, total_defused, total_fused });
    try std.testing.expect(total_fused < total_defused);
}

// ── Spec pass cases — native output conformance ──────────────────────────
// Until 2026-07-19 the wasm conformance runner was the ONLY place pass-case
// stdout was compared against the .out files; natively the corpus ran just
// once (defused) with output discarded, so output-affecting miscompiles
// gated at wasmtime/pre-push speed instead of zig-test speed. This sweep
// runs every top-level spec pass case natively and diffs its output.
// The cap/ subdirectory stays wasm-lane-only: those cases exercise
// capability wiring this harness does not mount.
test "spec pass cases native output" {
    const alloc = std.testing.allocator;
    const io_ref = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var d = try cwd.openDir(io_ref, "tests/spec", .{ .iterate = true });
    defer d.close(io_ref);

    var iter = d.iterate();
    var count: usize = 0;
    var failures: usize = 0;
    while (try iter.next(io_ref)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".gengo")) continue;

        const path = try std.fs.path.join(alloc, &.{ "tests/spec", entry.name });
        defer alloc.free(path);
        const src = readFileAlloc(alloc, path, 1024 * 1024) catch continue;
        defer alloc.free(src);
        const out_path = try std.fmt.allocPrint(alloc, "{s}.out", .{path[0 .. path.len - 6]});
        defer alloc.free(out_path);
        // No .out file: not an output-conformance case (mirrors the runner).
        const expected = readFileAlloc(alloc, out_path, 1024 * 1024) catch continue;
        defer alloc.free(expected);

        var rt = try setup();
        defer rt.deinit();
        g_stdout = std.array_list.Managed(u8).init(alloc);
        g_stderr = std.array_list.Managed(u8).init(alloc);
        defer g_stdout.deinit();
        defer g_stderr.deinit();

        const r = runWithCapture(&rt, src, path);
        switch (r[0]) {
            .ok => {},
            .compile_error => |e| {
                std.debug.print("spec native FAIL (compile): {s}: {s}\n", .{ path, e.msg });
                failures += 1;
                continue;
            },
            .runtime_error => |e| {
                std.debug.print("spec native FAIL (runtime): {s}: {s}\n", .{ path, e.msg });
                failures += 1;
                continue;
            },
        }
        // The conformance runner compares stdout followed by stderr against
        // .out (see test_runner runShellCommand); match those semantics so
        // cases like 207_io_eprint keep one expectation file.
        const combined = try std.mem.concat(alloc, u8, &.{ r[1], r[2] });
        defer alloc.free(combined);
        if (!std.mem.eql(u8, expected, combined)) {
            std.debug.print("spec native FAIL (output mismatch): {s}\n  want: {s}\n  got:  {s}\n", .{ path, expected, combined });
            failures += 1;
            continue;
        }
        count += 1;
    }
    if (failures != 0) {
        std.debug.print("spec native output: {d} passed, {d} FAILED\n", .{ count, failures });
        return error.TestUnexpectedResult;
    }
    if (count == 0) return error.NoSpecPassCases;
}

test "spec pass cases differential" {
    const alloc = std.testing.allocator;
    const io_ref = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var d = try cwd.openDir(io_ref, "tests/spec", .{ .iterate = true });
    defer d.close(io_ref);

    var iter = d.iterate();
    var count: usize = 0;
    while (try iter.next(io_ref)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".gengo")) continue;

        const path = try std.fs.path.join(alloc, &.{ "tests/spec", entry.name });
        defer alloc.free(path);

        const src = readFileAlloc(alloc, path, 1024 * 1024) catch continue;
        defer alloc.free(src);

        // Compile, install natives (std/host/cap), and set vm policy — but do not run.
        var rt = try setup();
        defer rt.deinit();
        rt.inner.compileAndInstall(src, path, .filesystem) catch continue;

        // Build defused bytecode from the current (just-compiled) chunk.
        const defused = vm_defuse.buildDefusedCode(vm.VMContext.fromActive().cs, alloc) catch continue;
        defer alloc.free(defused);

        if (defused.len > chunk.MaxCode) continue; // pathological; shouldn't happen

        // Install defused code.
        @memcpy(chunk.g_state.code[0..defused.len], defused);
        chunk.g_state.code_len = defused.len;
        chunk.g_state.verified = false;
        chunk.g_state.verified_code_len = 0;
        vm.VMContext.fromActive().vs.resetExec();

        // Discard output; we only check that it doesn't error.
        g_stdout = std.array_list.Managed(u8).init(alloc);
        g_stderr = std.array_list.Managed(u8).init(alloc);
        defer g_stdout.deinit();
        defer g_stderr.deinit();
        io.setWriteOverrides(captureStdout, captureStderr);
        defer io.clearWriteOverrides();

        vm.run(vm.VMContext.fromActive()) catch |e| {
            std.debug.print(
                "differential FAIL: spec pass case {s} succeeded normally but failed as defused: {s}\n",
                .{ entry.name, @errorName(e) },
            );
            return error.TestUnexpectedResult;
        };

        count += 1;
    }

    if (count == 0) return error.NoSpecPassCases;
}

// Template compaction safety: verify that tplValToDynStr, tplAppendValToBuilder,
// and tplBuilderToStr re-read managed-heap byte pointers AFTER vmAllocManagedBytes
// rather than using a stale Zig-local []const u8 that compactManagedHeap would
// have moved.  Running with a 256 KB heap makes compaction trigger after a few
// dozen iterations rather than the ~400 rounds needed on the default 1 MB heap.
test "template render with named-string type survives compactManagedHeap" {
    var rt = try api.Runtime.init(.{
        .allow_io = true,
        .allocator = std.testing.allocator,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer rt.deinit();

    g_stdout = std.array_list.Managed(u8).init(std.testing.allocator);
    g_stderr = std.array_list.Managed(u8).init(std.testing.allocator);
    defer g_stdout.deinit();
    defer g_stderr.deinit();

    const src =
        \\std := import("std")
        \\type Html string
        \\func make_row(i int) Html {
        \\    label := "r" + std.conv.to_string(i)
        \\    return Html(std.template.render("<b>{{.}}</b>", Html(label)))
        \\}
        \\acc := Html("")
        \\i := 0
        \\for i < 400 {
        \\    acc = acc + make_row(i)
        \\    i = i + 1
        \\}
        \\last := make_row(999)
        \\std.io.println(string(last))
        \\std.io.println("ok")
    ;

    const r = runWithCapture(&rt, src, "");
    const result = r[0];
    const output = r[1];

    if (result != .ok) {
        if (result == .runtime_error) {
            std.debug.print("runtime error: {s}\n", .{result.runtime_error.msg});
        }
        return error.TestUnexpectedResult;
    }

    try std.testing.expectEqualStrings("<b>r999</b>\nok\n", output);
}
