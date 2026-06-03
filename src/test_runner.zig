const std = @import("std");

const MaxCases = 256;
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
        std.debug.print("usage: test-runner <conformance|bench|parity> [wasmtime] [wasm]\n", .{});
        std.process.exit(1);
    }

    const mode = args[1];
    const wasmtime = if (args.len > 2) args[2] else "wasmtime";
    const wasm_path = if (args.len > 3) args[3] else "build/gengo-runtime.wasm";

    if (std.mem.eql(u8, mode, "conformance")) {
        try runConformance(alloc, wasmtime, wasm_path);
    } else if (std.mem.eql(u8, mode, "bench")) {
        try runBench(alloc, wasmtime, wasm_path);
    } else if (std.mem.eql(u8, mode, "parity")) {
        try runParity(alloc, wasmtime, wasm_path);
    } else {
        std.debug.print("unknown mode: {s}\n", .{mode});
        std.process.exit(1);
    }
}

// ── Conformance ──────────────────────────────────────────────────────────────

fn runConformance(alloc: std.mem.Allocator, wasmtime: []const u8, wasm_path: []const u8) !void {
    const pass_dir = "examples/spec";
    const fail_dir = "examples/spec/fail";

    var pass_count: usize = 0;
    var fail_count: usize = 0;
    var errors: usize = 0;

    // Pass cases
    {
        var cases_buf: [MaxCases][]const u8 = undefined;
        const case_count = collectGengoFiles(alloc, pass_dir, &cases_buf) catch |err| {
            std.debug.print("cannot scan pass dir: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };

        for (cases_buf[0..case_count]) |path| {
            defer alloc.free(path);
            const base = path[0 .. path.len - 6]; // strip .gengo
            const out_path = try std.fmt.allocPrint(alloc, "{s}.out", .{base});
            defer alloc.free(out_path);

            if (!fileExists(out_path)) {
                std.debug.print("missing expected output file: {s}\n", .{out_path});
                errors += 1;
                continue;
            }

            std.debug.print("[PASS-CASE] {s}\n", .{path});

            const got_path = try std.fmt.allocPrint(alloc, "{s}.got", .{base});
            defer alloc.free(got_path);

            const pass_result = runWasmtime(alloc, wasmtime, wasm_path, path);
            const stdout_data = pass_result[0];
            const failed = pass_result[1];
            defer alloc.free(stdout_data);

            if (failed) {
                std.debug.print("PASS-CASE execution failed unexpectedly: {s}\n", .{path});
                errors += 1;
                continue;
            }

            const expected_data = readFileAlloc(alloc, out_path, MaxOutputBytes) catch |err| {
                std.debug.print("PASS-CASE cannot read .out: {s} ({s})\n", .{ out_path, @errorName(err) });
                errors += 1;
                continue;
            };
            defer alloc.free(expected_data);

            if (!std.mem.eql(u8, expected_data, stdout_data)) {
                std.debug.print("PASS-CASE output mismatch: {s}\n", .{path});
                errors += 1;
                continue;
            }

            pass_count += 1;
        }
    }

    // Fail cases
    {
        var cases_buf: [MaxCases][]const u8 = undefined;
        const case_count = collectGengoFiles(alloc, fail_dir, &cases_buf) catch |err| {
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

            std.debug.print("[FAIL-CASE] {s}\n", .{path});

            const got_path = try std.fmt.allocPrint(alloc, "{s}.got", .{base});
            defer alloc.free(got_path);

            const fail_result = runWasmtime(alloc, wasmtime, wasm_path, path);
            const got_data = fail_result[0];
            const failed = fail_result[1];
            defer alloc.free(got_data);

            if (!failed) {
                std.debug.print("Expected failure but script succeeded: {s}\n", .{path});
                errors += 1;
                continue;
            }

            const err_content = readFileAlloc(alloc, err_path, 1024) catch |err| {
                std.debug.print("cannot read .err file: {s} ({s})\n", .{ err_path, @errorName(err) });
                errors += 1;
                continue;
            };
            defer alloc.free(err_content);

            var found = false;
            var err_start: usize = 0;
            while (err_start < err_content.len) {
                const nl = std.mem.indexOfScalar(u8, err_content[err_start..], '\n') orelse err_content.len;
                const line = err_content[err_start..nl];
                err_start = nl + 1;
                if (line.len == 0) continue;
                if (std.mem.indexOf(u8, got_data, line) != null) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                std.debug.print("Expected error token not found for {s}\n", .{path});
                errors += 1;
                continue;
            }

            fail_count += 1;
        }
    }

    if (errors != 0) {
        std.debug.print("Conformance FAILED: {d} pass-cases, {d} fail-cases, {d} errors\n", .{ pass_count, fail_count, errors });
        std.process.exit(1);
    }
    std.debug.print("Conformance OK: {d} pass-cases, {d} fail-cases\n", .{ pass_count, fail_count });
}

// ── Bench ──────────────────────────────────────────────────────────────────

fn runBench(alloc: std.mem.Allocator, wasmtime: []const u8, wasm_path: []const u8) !void {
    const bench_dir = "examples/bench";

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

// ── Parity ─────────────────────────────────────────────────────────────────

fn runParity(alloc: std.mem.Allocator, wasmtime: []const u8, wasm_path: []const u8) !void {
    const parity_dir = "examples/parity";

    var cases_buf: [MaxCases][]const u8 = undefined;
    const case_count = collectGengoFiles(alloc, parity_dir, &cases_buf) catch |err| {
        std.debug.print("cannot scan parity dir: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var pass_count: usize = 0;
    var errors: usize = 0;

    for (cases_buf[0..case_count]) |path| {
        defer alloc.free(path);
        const base = path[0 .. path.len - 6];
        const got_emb_path = try std.fmt.allocPrint(alloc, "{s}.embedded.got", .{base});
        defer alloc.free(got_emb_path);
        const got_host_path = try std.fmt.allocPrint(alloc, "{s}.host.got", .{base});
        defer alloc.free(got_host_path);

        std.debug.print("[PARITY] {s}\n", .{path});

        // Embedded backend
        const emb_extra = try std.fmt.allocPrint(alloc, "--backend embedded {s}", .{path});
        defer alloc.free(emb_extra);
        const emb_result = runWasmtimeExtra(alloc, wasmtime, wasm_path, emb_extra);
        const emb_data = emb_result[0];
        const emb_failed = emb_result[1];
        defer alloc.free(emb_data);

        if (emb_failed) {
            std.debug.print("embedded backend failed: {s}\n", .{path});
            errors += 1;
            continue;
        }

        // Host backend
        const host_extra = try std.fmt.allocPrint(alloc, "--backend host {s}", .{path});
        defer alloc.free(host_extra);
        const host_result = runWasmtimeExtra(alloc, wasmtime, wasm_path, host_extra);
        const host_data = host_result[0];
        const host_failed = host_result[1];
        defer alloc.free(host_data);

        if (host_failed) {
            std.debug.print("host backend failed: {s}\n", .{path});
            errors += 1;
            continue;
        }

        if (!std.mem.eql(u8, emb_data, host_data)) {
            std.debug.print("backend output mismatch: {s}\n", .{path});
            errors += 1;
            continue;
        }

        pass_count += 1;
    }

    if (errors != 0) {
        std.debug.print("Host parity FAILED: {d} pass, {d} errors\n", .{ pass_count, errors });
        std.process.exit(1);
    }
    std.debug.print("Host parity OK: {d} cases\n", .{pass_count});
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
    const cmd = std.fmt.allocPrint(alloc, "{s} --dir . {s} -- {s}", .{ wasmtime, wasm_path, extra }) catch return .{ "", true };
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
