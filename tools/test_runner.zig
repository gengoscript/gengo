const std = @import("std");

const MaxCases = 512;
const MaxOutputBytes = 512 * 1024;

fn toCStr(alloc: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return try alloc.dupeZ(u8, s);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;

    var argv_storage: [16][]const u8 = undefined;
    var arg_count: usize = 0;
    for (init.args.vector) |arg| {
        if (arg_count >= argv_storage.len) break;
        argv_storage[arg_count] = std.mem.span(arg);
        arg_count += 1;
    }
    const args = argv_storage[0..arg_count];

    if (args.len < 2) {
        std.debug.print("usage: test-runner <conformance|bench> [wasmtime] [wasm] [--filter <pattern>]\n", .{});
        std.debug.print("   or: test-runner <native-cap|chaos> [gengo] [--filter <pattern>]\n", .{});
        std.process.exit(1);
    }

    const mode = args[1];

    var filter: ?[]const u8 = null;
    {
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--filter")) {
                filter = args[i + 1];
                break;
            }
        }
    }

    if (std.mem.eql(u8, mode, "native-cap") or std.mem.eql(u8, mode, "chaos")) {
        var gengo: []const u8 = "zig-out/bin/gengo";
        if (args.len > 2 and !std.mem.eql(u8, args[2], "--filter")) {
            gengo = args[2];
        }
        if (!commandExists(alloc, gengo)) {
            std.debug.print("gengo binary not found: {s}\n", .{gengo});
            std.debug.print("build it first with `zig build -Dpreset=1m cli` or pass an explicit path\n", .{});
            std.process.exit(1);
        }
        if (std.mem.eql(u8, mode, "chaos")) {
            try runChaos(alloc, gengo, filter);
        } else {
            try runNativeCap(alloc, gengo, filter);
        }
        return;
    }

    const wasmtime = if (args.len > 2) args[2] else "wasmtime";
    const wasm_path = if (args.len > 3) args[3] else "build/test/gengo-cli.wasm";

    if (!commandExists(alloc, wasmtime)) {
        std.debug.print("wasmtime binary not found: {s}\n", .{wasmtime});
        std.debug.print("install wasmtime or pass an explicit path with -Dwasmtime=/path/to/wasmtime\n", .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, mode, "conformance")) {
        try runConformance(alloc, wasmtime, wasm_path);
    } else if (std.mem.eql(u8, mode, "bench")) {
        try runBench(alloc, wasmtime, wasm_path);
    } else {
        std.debug.print("unknown mode: {s}\n", .{mode});
        std.process.exit(1);
    }
}

// ── Conformance ──────────────────────────────────────────────────────────────

fn runConformance(alloc: std.mem.Allocator, wasmtime: []const u8, wasm_path: []const u8) !void {
    var pass_count: usize = 0;
    var fail_count: usize = 0;
    var errors: usize = 0;

    // Collect pass cases
    {
        var cases_buf: [MaxCases][]const u8 = undefined;
        const case_count = collectGengoFiles(alloc, "tests/spec", &cases_buf) catch |err| {
            std.debug.print("cannot scan pass dir: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        for (cases_buf[0..case_count]) |path| {
            defer alloc.free(path);
            const base = path[0 .. path.len - 6];
            const out_path = try std.fmt.allocPrint(alloc, "{s}.out", .{base});
            defer alloc.free(out_path);
            if (!fileExists(out_path)) {
                std.debug.print("missing expected output file: {s}\n", .{out_path});
                errors += 1;
                continue;
            }
            runConformanceCase(alloc, wasmtime, wasm_path, path, out_path, true, "", &pass_count, &fail_count, &errors);
        }
    }

    // Collect fail cases
    // Module flags allow fail-case tests to import from sibling test module dirs.
    const spec_fail_flags = "--modules tests/spec/modules --modules tests/spec/fail_modules";
    {
        var cases_buf: [MaxCases][]const u8 = undefined;
        const case_count = collectGengoFiles(alloc, "tests/spec/fail", &cases_buf) catch |err| {
            std.debug.print("cannot scan fail dir: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        for (cases_buf[0..case_count]) |path| {
            defer alloc.free(path);
            const base = path[0 .. path.len - 6];
            const err_path = try std.fmt.allocPrint(alloc, "{s}.err", .{base});
            defer alloc.free(err_path);
            if (!fileExists(err_path)) {
                std.debug.print("missing expected error file: {s}\n", .{err_path});
                errors += 1;
                continue;
            }
            runConformanceCase(alloc, wasmtime, wasm_path, path, err_path, false, spec_fail_flags, &pass_count, &fail_count, &errors);
        }
    }

    // Collect capability cases
    const cap_flags = "--cap net --cap fs --cap http --cap env";
    const cap_dirs = [_][]const u8{ "tests/spec/cap", "tests/spec/cap/fail" };
    for (cap_dirs) |cap_dir| {
        var cap_cases: [MaxCases][]const u8 = undefined;
        const cap_count = collectGengoFiles(alloc, cap_dir, &cap_cases) catch continue;
        for (cap_cases[0..cap_count]) |path| {
            defer alloc.free(path);
            const base = path[0 .. path.len - 6];
            const out_path = std.fmt.allocPrint(alloc, "{s}.out", .{base}) catch continue;
            defer alloc.free(out_path);
            const err_path = std.fmt.allocPrint(alloc, "{s}.err", .{base}) catch continue;
            defer alloc.free(err_path);
            if (fileExists(out_path)) {
                runConformanceCase(alloc, wasmtime, wasm_path, path, out_path, true, cap_flags, &pass_count, &fail_count, &errors);
            } else if (fileExists(err_path)) {
                runConformanceCase(alloc, wasmtime, wasm_path, path, err_path, false, cap_flags, &pass_count, &fail_count, &errors);
            }
        }
    }

    if (errors != 0) {
        std.debug.print("Conformance FAILED: {d} pass-cases, {d} fail-cases, {d} errors\n", .{ pass_count, fail_count, errors });
        std.process.exit(1);
    }
    std.debug.print("Conformance OK: {d} pass-cases, {d} fail-cases\n", .{ pass_count, fail_count });
}

fn runConformanceCase(
    alloc: std.mem.Allocator,
    wasmtime: []const u8,
    wasm_path: []const u8,
    path: []const u8,
    expected_path: []const u8,
    is_pass: bool,
    flags: []const u8,
    pass_count: *usize,
    fail_count: *usize,
    errors: *usize,
) void {
    const label = if (is_pass) "PASS-CASE" else "FAIL-CASE";
    std.debug.print("[{s}] {s}\n", .{ label, path });
    const result = runWasmtimeWithFlags(alloc, wasmtime, wasm_path, path, flags);
    const output = result[0];
    const failed = result[1];
    defer alloc.free(output);

    if (is_pass) {
        if (failed) {
            std.debug.print("PASS-CASE execution failed unexpectedly: {s}\n", .{path});
            errors.* += 1;
            return;
        }
        const expected = readFileAlloc(alloc, expected_path, MaxOutputBytes) catch |err| {
            std.debug.print("PASS-CASE cannot read .out: {s} ({s})\n", .{ expected_path, @errorName(err) });
            errors.* += 1;
            return;
        };
        defer alloc.free(expected);
        if (!std.mem.eql(u8, expected, output)) {
            std.debug.print("PASS-CASE output mismatch: {s}\n", .{path});
            errors.* += 1;
            return;
        }
        pass_count.* += 1;
        return;
    }

    if (!failed) {
        std.debug.print("Expected failure but script succeeded: {s}\n", .{path});
        errors.* += 1;
        return;
    }
    const expected = readFileAlloc(alloc, expected_path, 1024) catch |err| {
        std.debug.print("cannot read .err file: {s} ({s})\n", .{ expected_path, @errorName(err) });
        errors.* += 1;
        return;
    };
    defer alloc.free(expected);
    if (!errFileMatchesOutput(output, expected)) {
        std.debug.print("Expected error token not found for {s}\n", .{path});
        errors.* += 1;
        return;
    }
    fail_count.* += 1;
}

// ── Bench ──────────────────────────────────────────────────────────────────

fn runBench(alloc: std.mem.Allocator, wasmtime: []const u8, wasm_path: []const u8) !void {
    const bench_dir = "tests/bench";

    var cases_buf: [MaxCases][]const u8 = undefined;
    const case_count = collectGengoFiles(alloc, bench_dir, &cases_buf) catch |err| {
        std.debug.print("cannot scan bench dir: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var pass_count: usize = 0;
    var errors: usize = 0;

    for (cases_buf[0..case_count]) |path| {
        defer alloc.free(path);

        // Skip stress cases by default (same as old shell script)
        if (std.mem.indexOf(u8, path, "stress") != null) {
            continue;
        }

        const base = path[0 .. path.len - 6];
        const out_path = try std.fmt.allocPrint(alloc, "{s}.out", .{base});
        defer alloc.free(out_path);

        const policy_path = try std.fmt.allocPrint(alloc, "{s}.policy", .{base});
        defer alloc.free(policy_path);

        if (!fileExists(out_path)) {
            std.debug.print("missing expected output file: {s}\n", .{out_path});
            errors += 1;
            continue;
        }

        var allow_oom = false;
        if (fileExists(policy_path)) {
            const policy_data = readFileAlloc(alloc, policy_path, 1024) catch "";
            defer if (policy_data.len > 0) alloc.free(policy_data);
            if (std.mem.indexOf(u8, policy_data, "ALLOW_OOM") != null) {
                allow_oom = true;
            }
        }

        std.debug.print("[BENCH] {s}\n", .{path});

        const got_path = try std.fmt.allocPrint(alloc, "{s}.got", .{base});
        defer alloc.free(got_path);

        const bench_result = runWasmtime(alloc, wasmtime, wasm_path, path);
        const stdout_data = bench_result[0];
        const failed = bench_result[1];
        defer alloc.free(stdout_data);

        if (failed) {
            if (allow_oom and std.mem.indexOf(u8, stdout_data, "OutOfMemory") != null) {
                std.debug.print("BENCH expected OOM accepted: {s}\n", .{path});
                pass_count += 1;
                continue;
            }
            std.debug.print("BENCH execution failed unexpectedly: {s}\n", .{path});
            errors += 1;
            continue;
        }

        const expected_data = readFileAlloc(alloc, out_path, MaxOutputBytes) catch |err| {
            std.debug.print("BENCH cannot read .out: {s} ({s})\n", .{ out_path, @errorName(err) });
            errors += 1;
            continue;
        };
        defer alloc.free(expected_data);

        if (!std.mem.eql(u8, expected_data, stdout_data)) {
            std.debug.print("BENCH output mismatch: {s}\n", .{path});
            errors += 1;
            continue;
        }

        pass_count += 1;
    }

    if (errors != 0) {
        std.debug.print("Bench FAILED: {d} cases, {d} errors\n", .{ pass_count, errors });
        std.process.exit(1);
    }
    std.debug.print("Bench OK: {d} cases\n", .{pass_count});
}

// ── Native capability lane ────────────────────────────────────────────────

fn runNativeCap(alloc: std.mem.Allocator, gengo: []const u8, filter: ?[]const u8) !void {
    var pass_cases: [MaxCases][]const u8 = undefined;
    const pass_count = collectGengoFiles(alloc, "tests/native-cap", &pass_cases) catch |err| {
        std.debug.print("cannot scan native-cap dir: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var fail_cases: [MaxCases][]const u8 = undefined;
    const fail_count = collectGengoFiles(alloc, "tests/native-cap/fail", &fail_cases) catch |err| {
        std.debug.print("cannot scan native-cap fail dir: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var pass_ok: usize = 0;
    var fail_ok: usize = 0;
    var errors: usize = 0;

    for (pass_cases[0..pass_count]) |path| {
        defer alloc.free(path);
        if (filter) |f| {
            if (std.mem.indexOf(u8, path, f) == null) continue;
        }
        const base = path[0 .. path.len - 6];
        const out_path = try std.fmt.allocPrint(alloc, "{s}.out", .{base});
        defer alloc.free(out_path);

        if (!fileExists(out_path)) {
            std.debug.print("missing expected output file: {s}\n", .{out_path});
            errors += 1;
            continue;
        }

        std.debug.print("[NATIVE-CAP PASS] {s}\n", .{path});
        const temp_subpath = try createNativeCapTempDir(alloc);
        defer destroyNativeCapTempDir(temp_subpath);

        const result = runNativeCliWithMount(alloc, gengo, temp_subpath, path);
        const output = result[0];
        const failed = result[1];
        defer alloc.free(output);

        if (failed) {
            std.debug.print("native-cap execution failed unexpectedly: {s}\n", .{path});
            errors += 1;
            continue;
        }

        const expected = readFileAlloc(alloc, out_path, MaxOutputBytes) catch |err| {
            std.debug.print("cannot read .out file: {s} ({s})\n", .{ out_path, @errorName(err) });
            errors += 1;
            continue;
        };
        defer alloc.free(expected);

        if (!std.mem.eql(u8, expected, output)) {
            std.debug.print("native-cap output mismatch: {s}\n", .{path});
            errors += 1;
            continue;
        }

        pass_ok += 1;
    }

    for (fail_cases[0..fail_count]) |path| {
        defer alloc.free(path);
        if (filter) |f| {
            if (std.mem.indexOf(u8, path, f) == null) continue;
        }
        const base = path[0 .. path.len - 6];
        const err_path = try std.fmt.allocPrint(alloc, "{s}.err", .{base});
        defer alloc.free(err_path);

        if (!fileExists(err_path)) {
            std.debug.print("missing expected error file: {s}\n", .{err_path});
            errors += 1;
            continue;
        }

        std.debug.print("[NATIVE-CAP FAIL] {s}\n", .{path});
        const temp_subpath = try createNativeCapTempDir(alloc);
        defer destroyNativeCapTempDir(temp_subpath);

        const result = runNativeCliWithMount(alloc, gengo, temp_subpath, path);
        const output = result[0];
        const failed = result[1];
        defer alloc.free(output);

        if (!failed) {
            std.debug.print("expected failure but script succeeded: {s}\n", .{path});
            errors += 1;
            continue;
        }

        const err_content = readFileAlloc(alloc, err_path, 1024) catch |err| {
            std.debug.print("cannot read .err file: {s} ({s})\n", .{ err_path, @errorName(err) });
            errors += 1;
            continue;
        };
        defer alloc.free(err_content);

        if (!errFileMatchesOutput(output, err_content)) {
            std.debug.print("expected error token not found for {s}\n", .{path});
            errors += 1;
            continue;
        }

        fail_ok += 1;
    }

    if (errors != 0) {
        std.debug.print("Native capability lane FAILED: {d} pass-cases, {d} fail-cases, {d} errors\n", .{ pass_ok, fail_ok, errors });
        std.process.exit(1);
    }
    std.debug.print("Native capability lane OK: {d} pass-cases, {d} fail-cases\n", .{ pass_ok, fail_ok });
}

// ── Chaos lane ────────────────────────────────────────────────────────────
//
// Limit and edge-case behavior pinned as expectations, run against the
// native CLI: tests/chaos/*.gengo must match their .out exactly, and
// tests/chaos/fail/*.gengo must fail with their .err tokens present.
// tests/chaos/pending/ holds cases blocked on open bugs and is not scanned.

fn runNativeCli(alloc: std.mem.Allocator, gengo: []const u8, script: []const u8) struct { []const u8, bool } {
    const cmd = std.fmt.allocPrint(alloc, "{s} {s}", .{ gengo, script }) catch return .{ "", true };
    defer alloc.free(cmd);
    return runShellCommand(alloc, cmd);
}

fn runNativeCliFlags(alloc: std.mem.Allocator, gengo: []const u8, flags: []const u8, script: []const u8) struct { []const u8, bool } {
    const cmd = std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ gengo, flags, script }) catch return .{ "", true };
    defer alloc.free(cmd);
    return runShellCommand(alloc, cmd);
}

fn runChaos(alloc: std.mem.Allocator, gengo: []const u8, filter: ?[]const u8) !void {
    var pass_cases: [MaxCases][]const u8 = undefined;
    const pass_count = collectGengoFiles(alloc, "tests/chaos", &pass_cases) catch |err| {
        std.debug.print("cannot scan chaos dir: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var fail_cases: [MaxCases][]const u8 = undefined;
    const fail_count = collectGengoFiles(alloc, "tests/chaos/fail", &fail_cases) catch |err| {
        std.debug.print("cannot scan chaos fail dir: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var pass_ok: usize = 0;
    var fail_ok: usize = 0;
    var errors: usize = 0;

    for (pass_cases[0..pass_count]) |path| {
        defer alloc.free(path);
        if (filter) |f| {
            if (std.mem.indexOf(u8, path, f) == null) continue;
        }
        const base = path[0 .. path.len - 6];
        const out_path = try std.fmt.allocPrint(alloc, "{s}.out", .{base});
        defer alloc.free(out_path);

        if (!fileExists(out_path)) {
            std.debug.print("missing expected output file: {s}\n", .{out_path});
            errors += 1;
            continue;
        }

        std.debug.print("[CHAOS PASS] {s}\n", .{path});
        const result = runNativeCli(alloc, gengo, path);
        const output = result[0];
        const failed = result[1];
        defer alloc.free(output);

        if (failed) {
            std.debug.print("chaos execution failed unexpectedly: {s}\n", .{path});
            errors += 1;
            continue;
        }

        const expected = readFileAlloc(alloc, out_path, MaxOutputBytes) catch |err| {
            std.debug.print("cannot read .out file: {s} ({s})\n", .{ out_path, @errorName(err) });
            errors += 1;
            continue;
        };
        defer alloc.free(expected);

        if (!std.mem.eql(u8, expected, output)) {
            std.debug.print("chaos output mismatch: {s}\n", .{path});
            errors += 1;
            continue;
        }

        pass_ok += 1;
    }

    const chaos_fail_flags = "--modules tests/chaos/modules --modules tests/chaos/fail_modules";
    for (fail_cases[0..fail_count]) |path| {
        defer alloc.free(path);
        if (filter) |f| {
            if (std.mem.indexOf(u8, path, f) == null) continue;
        }
        const base = path[0 .. path.len - 6];
        const err_path = try std.fmt.allocPrint(alloc, "{s}.err", .{base});
        defer alloc.free(err_path);

        if (!fileExists(err_path)) {
            std.debug.print("missing expected error file: {s}\n", .{err_path});
            errors += 1;
            continue;
        }

        std.debug.print("[CHAOS FAIL] {s}\n", .{path});
        const result = runNativeCliFlags(alloc, gengo, chaos_fail_flags, path);
        const output = result[0];
        const failed = result[1];
        defer alloc.free(output);

        if (!failed) {
            std.debug.print("expected failure but script succeeded: {s}\n", .{path});
            errors += 1;
            continue;
        }

        const err_content = readFileAlloc(alloc, err_path, 1024) catch |err| {
            std.debug.print("cannot read .err file: {s} ({s})\n", .{ err_path, @errorName(err) });
            errors += 1;
            continue;
        };
        defer alloc.free(err_content);

        if (!errFileMatchesOutput(output, err_content)) {
            std.debug.print("expected error token not found for {s}\n", .{path});
            errors += 1;
            continue;
        }

        fail_ok += 1;
    }

    if (errors != 0) {
        std.debug.print("Chaos lane FAILED: {d} pass-cases, {d} fail-cases, {d} errors\n", .{ pass_ok, fail_ok, errors });
        std.process.exit(1);
    }
    std.debug.print("Chaos lane OK: {d} pass-cases, {d} fail-cases\n", .{ pass_ok, fail_ok });
}

// ── Shared helpers ─────────────────────────────────────────────────────────

fn collectGengoFiles(alloc: std.mem.Allocator, dir: []const u8, out: *[MaxCases][]const u8) !usize {
    var count: usize = 0;
    const dir_z = try toCStr(alloc, dir);
    defer alloc.free(dir_z);
    const dirp = std.c.opendir(dir_z.ptr) orelse return error.OpenDirFailed;
    defer _ = std.c.closedir(dirp);

    while (std.c.readdir(dirp)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (!std.mem.endsWith(u8, name, ".gengo")) continue;
        if (count >= MaxCases) return error.TooManyCases;
        out[count] = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        count += 1;
    }

    // Sort
    std.mem.sort([]const u8, out[0..count], {}, struct {
        pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return count;
}

fn runWasmtime(alloc: std.mem.Allocator, wasmtime: []const u8, wasm_path: []const u8, script: []const u8) struct { []const u8, bool } {
    return runWasmtimeExtra(alloc, wasmtime, wasm_path, script);
}

fn runWasmtimeExtra(alloc: std.mem.Allocator, wasmtime: []const u8, wasm_path: []const u8, extra: []const u8) struct { []const u8, bool } {
    return runWasmtimeWithFlags(alloc, wasmtime, wasm_path, extra, "");
}

fn runWasmtimeWithFlags(alloc: std.mem.Allocator, wasmtime: []const u8, wasm_path: []const u8, extra: []const u8, flags: []const u8) struct { []const u8, bool } {
    const cmd = if (flags.len == 0)
        std.fmt.allocPrint(alloc, "{s} --dir . {s} -- {s}", .{ wasmtime, wasm_path, extra }) catch return .{ "", true }
    else
        std.fmt.allocPrint(alloc, "{s} --dir . {s} -- {s} {s}", .{ wasmtime, wasm_path, flags, extra }) catch return .{ "", true };
    defer alloc.free(cmd);

    var stdout_pipe: [2]std.c.fd_t = undefined;
    var stderr_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stdout_pipe) != 0 or std.c.pipe(&stderr_pipe) != 0) {
        return .{ "", true };
    }

    const pid = std.c.fork();
    if (pid < 0) return .{ "", true };

    if (pid == 0) {
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stderr_pipe[0]);
        _ = std.c.dup2(stdout_pipe[1], 1);
        _ = std.c.dup2(stderr_pipe[1], 2);
        _ = std.c.close(stdout_pipe[1]);
        _ = std.c.close(stderr_pipe[1]);

        const sh_z = toCStr(alloc, "/bin/sh") catch std.c._exit(1);
        defer alloc.free(sh_z);
        const sh_c_z = toCStr(alloc, "-c") catch std.c._exit(1);
        defer alloc.free(sh_c_z);
        const cmd_z = toCStr(alloc, cmd) catch std.c._exit(1);
        defer alloc.free(cmd_z);

        const argv = [_:null]?[*:0]const u8{ sh_z.ptr, sh_c_z.ptr, cmd_z.ptr, null };
        _ = std.c.execve(sh_z.ptr, &argv, std.c.environ);
        std.c._exit(1);
    }

    _ = std.c.close(stdout_pipe[1]);
    _ = std.c.close(stderr_pipe[1]);

    var stdout_buf: [MaxOutputBytes]u8 = undefined;
    var stderr_buf: [MaxOutputBytes]u8 = undefined;
    const stdout_len = readAllFromFd(stdout_pipe[0], &stdout_buf) catch 0;
    const stderr_len = readAllFromFd(stderr_pipe[0], &stderr_buf) catch 0;
    _ = std.c.close(stdout_pipe[0]);
    _ = std.c.close(stderr_pipe[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const exited = (status & 0x7f) == 0;
    const exit_code = if (exited) @as(u8, @intCast((status >> 8) & 0xff)) else 1;
    const failed = !exited or exit_code != 0;

    // Combine stdout + stderr
    const total_len = stdout_len + stderr_len;
    const combined = alloc.alloc(u8, total_len) catch return .{ "", true };
    @memcpy(combined[0..stdout_len], stdout_buf[0..stdout_len]);
    @memcpy(combined[stdout_len..total_len], stderr_buf[0..stderr_len]);

    return .{ combined, failed };
}

fn runNativeCliWithMount(alloc: std.mem.Allocator, gengo: []const u8, mount_path: []const u8, script: []const u8) struct { []const u8, bool } {
    const cmd = std.fmt.allocPrint(alloc, "{s} --cap fs --cap ffi --mount tmp={s} {s}", .{ gengo, mount_path, script }) catch return .{ "", true };
    defer alloc.free(cmd);

    return runShellCommand(alloc, cmd);
}

fn runShellCommand(alloc: std.mem.Allocator, cmd: []const u8) struct { []const u8, bool } {
    var stdout_pipe: [2]std.c.fd_t = undefined;
    var stderr_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stdout_pipe) != 0 or std.c.pipe(&stderr_pipe) != 0) {
        return .{ "", true };
    }

    const pid = std.c.fork();
    if (pid < 0) return .{ "", true };

    if (pid == 0) {
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stderr_pipe[0]);
        _ = std.c.dup2(stdout_pipe[1], 1);
        _ = std.c.dup2(stderr_pipe[1], 2);
        _ = std.c.close(stdout_pipe[1]);
        _ = std.c.close(stderr_pipe[1]);

        const sh_z = toCStr(alloc, "/bin/sh") catch std.c._exit(1);
        defer alloc.free(sh_z);
        const sh_c_z = toCStr(alloc, "-c") catch std.c._exit(1);
        defer alloc.free(sh_c_z);
        const cmd_z = toCStr(alloc, cmd) catch std.c._exit(1);
        defer alloc.free(cmd_z);

        const argv = [_:null]?[*:0]const u8{ sh_z.ptr, sh_c_z.ptr, cmd_z.ptr, null };
        _ = std.c.execve(sh_z.ptr, &argv, std.c.environ);
        std.c._exit(1);
    }

    _ = std.c.close(stdout_pipe[1]);
    _ = std.c.close(stderr_pipe[1]);

    var stdout_buf: [MaxOutputBytes]u8 = undefined;
    var stderr_buf: [MaxOutputBytes]u8 = undefined;
    const stdout_len = readAllFromFd(stdout_pipe[0], &stdout_buf) catch 0;
    const stderr_len = readAllFromFd(stderr_pipe[0], &stderr_buf) catch 0;
    _ = std.c.close(stdout_pipe[0]);
    _ = std.c.close(stderr_pipe[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const exited = (status & 0x7f) == 0;
    const exit_code = if (exited) @as(u8, @intCast((status >> 8) & 0xff)) else 1;
    const failed = !exited or exit_code != 0;

    const total_len = stdout_len + stderr_len;
    const combined = alloc.alloc(u8, total_len) catch return .{ "", true };
    @memcpy(combined[0..stdout_len], stdout_buf[0..stdout_len]);
    @memcpy(combined[stdout_len..total_len], stderr_buf[0..stderr_len]);
    return .{ combined, failed };
}

fn readAllFromFd(fd: std.c.fd_t, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch |err| {
            if (err == error.WouldBlock or err == error.Interrupted) continue;
            return err;
        };
        if (n == 0) break;
        total += n;
    }
    return total;
}

fn fileExists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch return false;
    defer _ = std.posix.system.close(fd);
    return true;
}

fn commandExists(alloc: std.mem.Allocator, command: []const u8) bool {
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        return fileExists(command);
    }

    const probe_cmd = std.fmt.allocPrint(alloc, "command -v {s} >/dev/null 2>&1", .{command}) catch return false;
    defer alloc.free(probe_cmd);

    const sh_z = toCStr(alloc, "/bin/sh") catch return false;
    defer alloc.free(sh_z);
    const sh_c_z = toCStr(alloc, "-c") catch return false;
    defer alloc.free(sh_c_z);
    const probe_z = toCStr(alloc, probe_cmd) catch return false;
    defer alloc.free(probe_z);

    const pid = std.c.fork();
    if (pid < 0) return false;

    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ sh_z.ptr, sh_c_z.ptr, probe_z.ptr, null };
        _ = std.c.execve(sh_z.ptr, &argv, std.c.environ);
        std.c._exit(1);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
}

fn errFileMatchesOutput(output: []const u8, err_content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, err_content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, output, line) != null) return true;
    }
    return false;
}

var native_cap_counter: usize = 0;

fn createNativeCapTempDir(alloc: std.mem.Allocator) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache/native-cap");
    const subpath = try std.fmt.allocPrint(alloc, ".zig-cache/native-cap/{d}-{d}", .{ std.c.getpid(), native_cap_counter });
    native_cap_counter += 1;
    try cwd.createDirPath(io, subpath);
    return subpath;
}

fn destroyNativeCapTempDir(subpath: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, subpath) catch {};
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

test "err file token matching handles multiple lines and trailing line without newline" {
    try std.testing.expect(errFileMatchesOutput("prefix second-token suffix", "first-token\nsecond-token"));
    try std.testing.expect(!errFileMatchesOutput("completely different", "first-token\nsecond-token"));
}

test "command exists handles explicit paths and missing commands" {
    try std.testing.expect(commandExists(std.testing.allocator, "/bin/sh"));
    try std.testing.expect(!commandExists(std.testing.allocator, "/definitely/not/a/real/binary"));
    try std.testing.expect(!commandExists(std.testing.allocator, "definitely-not-a-real-command"));
}

test "native cap temp dir lifecycle" {
    const subpath = try createNativeCapTempDir(std.testing.allocator);
    defer std.testing.allocator.free(subpath);

    try std.testing.expect(fileExists(subpath));
    destroyNativeCapTempDir(subpath);
    try std.testing.expect(!fileExists(subpath));
}
