const std = @import("std");

const MaxBenchCases = 64;
const MaxOutputBytes = 512 * 1024;

const PerfEntry = struct {
    name: []const u8,
    count: u64,
};

const BenchCase = struct {
    name: []const u8,
    path: []const u8,
    out_path: []const u8,
    allow_oom: bool,
};

fn toCStr(alloc: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return try alloc.dupeZ(u8, s);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;

    var argv_storage: [8][]const u8 = undefined;
    var arg_count: usize = 0;
    for (init.args.vector) |arg| {
        if (arg_count >= argv_storage.len) break;
        argv_storage[arg_count] = std.mem.span(arg);
        arg_count += 1;
    }
    const args = argv_storage[0..arg_count];

    const wasmtime = if (args.len > 1) args[1] else "wasmtime";
    const wasm_path = if (args.len > 2) args[2] else "build/gengo-perf.wasm";
    const bench_dir = if (args.len > 3) args[3] else "examples/bench";
    const perf_dir = if (args.len > 4) args[4] else "build/perf";

    // Collect bench cases using raw C directory API
    var cases: [MaxBenchCases]BenchCase = undefined;
    var case_count: usize = 0;

    {
        const bench_dir_z = try toCStr(alloc, bench_dir);
        defer alloc.free(bench_dir_z);
        const dirp = std.c.opendir(bench_dir_z.ptr) orelse {
            std.debug.print("cannot open bench directory: {s}\n", .{bench_dir});
            std.process.exit(1);
        };
        defer _ = std.c.closedir(dirp);

        while (std.c.readdir(dirp)) |entry| {
            const name = std.mem.sliceTo(&entry.name, 0);
            if (!std.mem.endsWith(u8, name, ".gengo")) continue;
            if (case_count >= MaxBenchCases) {
                std.debug.print("too many bench cases (max {d})\n", .{MaxBenchCases});
                std.process.exit(1);
            }
            const base_name = name[0 .. name.len - 6];

            // Check .out file exists
            const out_path = try std.fmt.allocPrint(alloc, "{s}/{s}.out", .{ bench_dir, base_name });
            defer alloc.free(out_path);
            if (!fileExists(out_path)) {
                std.debug.print("missing expected output file: {s}\n", .{out_path});
                continue;
            }

            // Check .policy for ALLOW_OOM
            const policy_path = try std.fmt.allocPrint(alloc, "{s}/{s}.policy", .{ bench_dir, base_name });
            defer alloc.free(policy_path);
            var allow_oom = false;
            if (fileExists(policy_path)) {
                const policy_data = readFileAlloc(alloc, policy_path, 1024) catch "";
                defer if (policy_data.len > 0) alloc.free(policy_data);
                if (std.mem.indexOf(u8, policy_data, "ALLOW_OOM") != null) {
                    allow_oom = true;
                }
            }

            cases[case_count] = .{
                .name = try alloc.dupe(u8, name),
                .path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ bench_dir, name }),
                .out_path = try std.fmt.allocPrint(alloc, "{s}/{s}.out", .{ bench_dir, base_name }),
                .allow_oom = allow_oom,
            };
            case_count += 1;
        }
    }

    // Sort cases by name
    const SortCtx = struct {
        pub fn lessThan(_: @This(), a: BenchCase, b: BenchCase) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    };
    std.mem.sort(BenchCase, cases[0..case_count], SortCtx{}, SortCtx.lessThan);

    // Ensure perf output dir exists
    {
        const perf_dir_z = try toCStr(alloc, perf_dir);
        defer alloc.free(perf_dir_z);
        _ = std.c.mkdir(perf_dir_z.ptr, 0o755);
    }

    var pass_count: usize = 0;
    var errors: usize = 0;

    for (cases[0..case_count]) |case| {
        defer {
            alloc.free(case.name);
            alloc.free(case.path);
            alloc.free(case.out_path);
        }

        std.debug.print("[BENCH-PERF] {s}\n", .{case.path});

        const got_file_path = try std.fmt.allocPrint(alloc, "{s}.got", .{case.path[0 .. case.path.len - 6]});
        defer alloc.free(got_file_path);

        const perf_file_path = try std.fmt.allocPrint(alloc, "{s}/{s}.perf", .{ perf_dir, case.name[0 .. case.name.len - 6] });
        defer alloc.free(perf_file_path);

        // Spawn wasmtime with stdout/stderr captured using raw POSIX
        const wasmtime_z = try toCStr(alloc, wasmtime);
        defer alloc.free(wasmtime_z);
        const dir_arg = try toCStr(alloc, ".");
        defer alloc.free(dir_arg);
        const wasm_path_z = try toCStr(alloc, wasm_path);
        defer alloc.free(wasm_path_z);
        const case_path_z = try toCStr(alloc, case.path);
        defer alloc.free(case_path_z);

        var stdout_pipe: [2]std.c.fd_t = undefined;
        var stderr_pipe: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&stdout_pipe) != 0 or std.c.pipe(&stderr_pipe) != 0) {
            std.debug.print("  FAIL (pipe error)\n", .{});
            errors += 1;
            continue;
        }

        const pid = std.c.fork();
        if (pid < 0) {
            std.debug.print("  FAIL (fork error)\n", .{});
            errors += 1;
            continue;
        }

        if (pid == 0) {
            // Child process
            _ = std.c.close(stdout_pipe[0]);
            _ = std.c.close(stderr_pipe[0]);
            _ = std.c.dup2(stdout_pipe[1], 1);
            _ = std.c.dup2(stderr_pipe[1], 2);
            _ = std.c.close(stdout_pipe[1]);
            _ = std.c.close(stderr_pipe[1]);
            // Build command string: wasmtime --dir . build/gengo-perf.wasm -- case.gengo
            const cmd = try std.fmt.allocPrint(alloc, "{s} --dir . {s} -- {s}", .{ wasmtime, wasm_path, case.path });
            defer alloc.free(cmd);
            const cmd_z = try toCStr(alloc, cmd);
            defer alloc.free(cmd_z);
            const sh_z = try toCStr(alloc, "/bin/sh");
            defer alloc.free(sh_z);
            const sh_c_z = try toCStr(alloc, "-c");
            defer alloc.free(sh_c_z);
            const argv = [_:null]?[*:0]const u8{
                sh_z.ptr,
                sh_c_z.ptr,
                cmd_z.ptr,
                null,
            };
            _ = std.c.execve(sh_z.ptr, &argv, std.c.environ);
            std.c._exit(1);
        }

        // Parent process
        _ = std.c.close(stdout_pipe[1]);
        _ = std.c.close(stderr_pipe[1]);

        const stdout_data = readAllFromFd(alloc, stdout_pipe[0], MaxOutputBytes) catch |err| {
            std.debug.print("  FAIL (stdout read error: {s})\n", .{@errorName(err)});
            errors += 1;
            _ = std.c.close(stdout_pipe[0]);
            _ = std.c.close(stderr_pipe[0]);
            _ = std.c.waitpid(pid, null, 0);
            continue;
        };
        defer alloc.free(stdout_data);
        _ = std.c.close(stdout_pipe[0]);

        const stderr_data = readAllFromFd(alloc, stderr_pipe[0], MaxOutputBytes) catch |err| {
            std.debug.print("  FAIL (stderr read error: {s})\n", .{@errorName(err)});
            errors += 1;
            _ = std.c.close(stderr_pipe[0]);
            _ = std.c.waitpid(pid, null, 0);
            continue;
        };
        defer alloc.free(stderr_data);
        _ = std.c.close(stderr_pipe[0]);

        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);

        const exited = (status & 0x7f) == 0;
        const exit_code = if (exited) @as(u8, @intCast((status >> 8) & 0xff)) else 1;
        const failed = !exited or exit_code != 0;

        // Write got and perf files
        {
            const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
            const got_fd = try std.posix.openat(std.posix.AT.FDCWD, got_file_path, flags, 0o644);
            defer _ = std.posix.system.close(got_fd);
            var written: usize = 0;
            while (written < stdout_data.len) {
                const n = std.c.write(got_fd, stdout_data[written..].ptr, stdout_data[written..].len);
                if (n < 0) return error.WriteFailed;
                written += @as(usize, @intCast(n));
            }
        }
        {
            const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
            const perf_fd = try std.posix.openat(std.posix.AT.FDCWD, perf_file_path, flags, 0o644);
            defer _ = std.posix.system.close(perf_fd);
            var written: usize = 0;
            while (written < stderr_data.len) {
                const n = std.c.write(perf_fd, stderr_data[written..].ptr, stderr_data[written..].len);
                if (n < 0) return error.WriteFailed;
                written += @as(usize, @intCast(n));
            }
        }

        if (failed) {
            if (case.allow_oom and std.mem.indexOf(u8, stdout_data, "OutOfMemory") != null) {
                std.debug.print("  expected OOM accepted\n", .{});
                pass_count += 1;
                continue;
            }
            std.debug.print("  FAIL (execution error)\n{s}\n", .{stdout_data});
            errors += 1;
            continue;
        }

        // Compare output
        const expected_data = readFileAlloc(alloc, case.out_path, MaxOutputBytes) catch |err| {
            std.debug.print("  FAIL (cannot read .out file: {s})\n", .{@errorName(err)});
            errors += 1;
            continue;
        };
        defer alloc.free(expected_data);

        if (!std.mem.eql(u8, expected_data, stdout_data)) {
            std.debug.print("  FAIL (output mismatch)\n", .{});
            printDiff(expected_data, stdout_data);
            errors += 1;
            continue;
        }

        pass_count += 1;

        // Parse and print perf data
        if (stderr_data.len > 0) {
            printPerfSummary(stderr_data);
            std.debug.print("  full perf data: {s}\n", .{perf_file_path});
        }
    }

    if (errors != 0) {
        std.debug.print("bench-perf FAILED: {d} pass, {d} errors\n", .{ pass_count, errors });
        std.process.exit(1);
    }
    std.debug.print("bench-perf OK: {d} cases\n", .{pass_count});
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

fn readAllFromFd(alloc: std.mem.Allocator, fd: std.c.fd_t, max_bytes: usize) ![]u8 {
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

fn printDiff(expected: []const u8, actual: []const u8) void {
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    var line_no: usize = 1;
    while (true) {
        const e = expected_lines.next();
        const a = actual_lines.next();
        if (e == null and a == null) break;
        if (e != null and a != null and std.mem.eql(u8, e.?, a.?)) {
            line_no += 1;
            continue;
        }
        if (e) |line| std.debug.print("  - {d}: {s}\n", .{ line_no, line });
        if (a) |line| std.debug.print("  + {d}: {s}\n", .{ line_no, line });
        line_no += 1;
    }
}

fn printPerfSummary(perf_data: []const u8) void {
    var op_entries: [256]PerfEntry = undefined;
    var op_count: usize = 0;

    var lines = std.mem.splitScalar(u8, perf_data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PERF:op:")) {
            const rest = line[8..];
            if (std.mem.indexOf(u8, rest, "=")) |eq| {
                const name = rest[0..eq];
                const count_str = rest[eq + 1 ..];
                const count = std.fmt.parseInt(u64, count_str, 10) catch continue;
                if (op_count < op_entries.len) {
                    op_entries[op_count] = .{ .name = name, .count = count };
                    op_count += 1;
                }
            }
        }
    }

    std.mem.sort(PerfEntry, op_entries[0..op_count], {}, struct {
        pub fn lessThan(_: void, a: PerfEntry, b: PerfEntry) bool {
            return a.count > b.count;
        }
    }.lessThan);

    const print_count = @min(op_count, 20);
    for (op_entries[0..print_count]) |entry| {
        std.debug.print("  op {s: <30} {d}\n", .{ entry.name, entry.count });
    }

    lines = std.mem.splitScalar(u8, perf_data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PERF:gc_runs=") or
            std.mem.startsWith(u8, line, "PERF:alloc_objects=") or
            std.mem.startsWith(u8, line, "PERF:string_concat=") or
            std.mem.startsWith(u8, line, "PERF:map_probe="))
        {
            const rest = line[5..];
            if (std.mem.indexOf(u8, rest, "=")) |eq| {
                const name = rest[0..eq];
                const val = rest[eq + 1 ..];
                std.debug.print("  {s: <38} {s}\n", .{ name, val });
            }
        }
    }
}
