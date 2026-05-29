const std = @import("std");
const builtin = @import("builtin");

const Runtime = @import("runtime/runtime.zig").Runtime;
const io = @import("runtime/io.zig");
const vm = @import("lang/vm.zig");
const cfg = @import("runtime/config.zig");

const MaxArgs = 32;
const ArgBufSize = 4096;
const MaxInput = cfg.max_input_bytes;
const WasiCwdFd: std.os.wasi.fd_t = 3;

var g_src_buf: [MaxInput]u8 = undefined;

fn die(code: u32) noreturn {
    if (comptime builtin.os.tag == .wasi) {
        std.os.wasi.proc_exit(code);
    }
    std.process.exit(@intCast(code));
}

fn collectArgs(argv_out: *[MaxArgs][]const u8) ![]const []const u8 {
    if (comptime builtin.os.tag == .wasi) {
        var argc: usize = 0;
        var argv_buf_size: usize = 0;
        if (std.os.wasi.args_sizes_get(&argc, &argv_buf_size) != .SUCCESS) return error.ArgsReadFailed;
        if (argc > MaxArgs or argv_buf_size > ArgBufSize) return error.ArgsTooLarge;

        var argv_ptrs: [MaxArgs][*:0]u8 = undefined;
        var argv_buf: [ArgBufSize]u8 = undefined;
        if (std.os.wasi.args_get(argv_ptrs[0..argc].ptr, argv_buf[0..argv_buf_size].ptr) != .SUCCESS) return error.ArgsReadFailed;

        for (0..argc) |i| argv_out[i] = std.mem.span(argv_ptrs[i]);
        return argv_out[0..argc];
    }
    var it = std.process.args();
    var n: usize = 0;
    while (it.next()) |a| {
        if (n >= MaxArgs) return error.ArgsTooLarge;
        argv_out[n] = a;
        n += 1;
    }
    return argv_out[0..n];
}

fn readAllFd(fd: std.os.wasi.fd_t, out: []u8) !usize {
    var total: usize = 0;
    while (total < out.len) {
        var iov = [1]std.os.wasi.iovec_t{.{ .base = out[total..].ptr, .len = out.len - total }};
        var nread: usize = 0;
        const rc = std.os.wasi.fd_read(fd, &iov, iov.len, &nread);
        if (rc != .SUCCESS) return error.ReadFailed;
        if (nread == 0) break;
        total += nread;
    }
    return total;
}

fn openReadOnly(path: []const u8) !std.os.wasi.fd_t {
    var fd: std.os.wasi.fd_t = undefined;
    const rights = std.os.wasi.rights_t{
        .FD_READ = true,
        .FD_SEEK = true,
        .FD_TELL = true,
        .FD_FILESTAT_GET = true,
    };
    const rc = std.os.wasi.path_open(
        WasiCwdFd,
        .{},
        path.ptr,
        path.len,
        .{},
        rights,
        .{},
        .{},
        &fd,
    );
    if (rc != .SUCCESS) return error.OpenFailed;
    return fd;
}

// printSourceLine prints a Rust-style source snippet for the given 1-based line and column.
// col == 0 means no caret.
fn printSourceLine(src: []const u8, line: u32, col: u32) void {
    // Find the start of the requested line.
    var cur_line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < src.len and cur_line < line) : (i += 1) {
        if (src[i] == '\n') {
            cur_line += 1;
            line_start = i + 1;
        }
    }
    if (cur_line != line) return; // line out of range

    // Find end of line.
    var line_end = line_start;
    while (line_end < src.len and src[line_end] != '\n') : (line_end += 1) {}
    const text = src[line_start..line_end];

    // Print line number gutter and source text.
    io.werr("   ");
    io.writeInt(@intCast(line));
    io.werr(" | ");
    io.werr(text);
    io.werr("\n");

    // Print caret line if col is known.
    if (col > 0) {
        io.werr("     | ");
        var c: u32 = 1;
        while (c < col) : (c += 1) io.werr(" ");
        io.werr("^\n");
    }
}

export fn _start() void {
    var argv_storage: [MaxArgs][]const u8 = undefined;
    const argv = collectArgs(&argv_storage) catch {
        io.werr("gengo: cannot read args\n");
        die(1);
    };

    var src: []const u8 = undefined;
    var script_name: []const u8 = "<stdin>";
    var script_index: usize = 1;
    var backend: vm.Policy.NativeBackend = .embedded;
    var max_ops: ?u64 = null;
    while (script_index < argv.len) {
        const a = argv[script_index];
        if (a.len == 2 and a[0] == '-' and a[1] == '-') {
            script_index += 1;
            continue;
        }
        if (a.len == 9 and std.mem.eql(u8, a, "--backend")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: --backend requires value\n");
                die(1);
            }
            const v = argv[script_index + 1];
            if (std.mem.eql(u8, v, "embedded")) {
                backend = .embedded;
            } else if (std.mem.eql(u8, v, "host")) {
                backend = .host;
            } else {
                io.werr("gengo: unknown backend: ");
                io.werr(v);
                io.werr("\n");
                die(1);
            }
            script_index += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--max-ops")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: --max-ops requires value\n");
                die(1);
            }
            const v = argv[script_index + 1];
            max_ops = std.fmt.parseUnsigned(u64, v, 10) catch {
                io.werr("gengo: invalid --max-ops value: ");
                io.werr(v);
                io.werr("\n");
                die(1);
            };
            script_index += 2;
            continue;
        }
        break;
    }

    if (argv.len <= script_index) {
        const total = readAllFd(0, g_src_buf[0..]) catch {
            io.werr("gengo: cannot read stdin\n");
            die(1);
        };
        src = g_src_buf[0..total];
    } else {
        const path = argv[script_index];
        script_name = path;
        const fd = openReadOnly(path) catch {
            io.werr("gengo: cannot open: ");
            io.werr(path);
            io.werr("\n");
            die(1);
        };
        defer _ = std.os.wasi.fd_close(fd);
        const total = readAllFd(fd, g_src_buf[0..]) catch {
            io.werr("gengo: cannot read: ");
            io.werr(path);
            io.werr("\n");
            die(1);
        };
        src = g_src_buf[0..total];
    }

    var runtime = Runtime.withPolicy(.{
        .allow_io = true,
        .native_backend = backend,
        .max_ops = max_ops,
    });
    runtime.run(src) catch |err| {
        if (runtime.last_compile_line != 0) {
            io.werr("gengo: compile error: ");
            io.werr(@errorName(err));
            io.werr("\n  --> ");
            io.werr(script_name);
            io.werr(":");
            io.writeInt(@intCast(runtime.last_compile_line));
            io.werr("\n");
            printSourceLine(src, runtime.last_compile_line, 0);
        } else if (runtime.last_runtime_line != 0) {
            io.werr("gengo: panic: ");
            io.werr(@errorName(err));
            io.werr("\n  --> ");
            io.werr(script_name);
            io.werr(":");
            io.writeInt(@intCast(runtime.last_runtime_line));
            if (runtime.last_runtime_col != 0) {
                io.werr(":");
                io.writeInt(@intCast(runtime.last_runtime_col));
            }
            io.werr("\n");
            printSourceLine(src, runtime.last_runtime_line, runtime.last_runtime_col);
            // Stack trace (innermost call site first, skip entry if no callers)
            if (runtime.panic_depth > 0) {
                io.werr("stack trace:\n");
                var fi: usize = 0;
                while (fi < runtime.panic_depth) : (fi += 1) {
                    const pf = runtime.panic_frames[fi];
                    io.werr("    ");
                    if (pf.name.len > 0) {
                        io.werr(pf.name);
                        io.werr("() called from ");
                    } else {
                        io.werr("called from ");
                    }
                    io.werr(script_name);
                    io.werr(":");
                    io.writeInt(@intCast(pf.line));
                    io.werr("\n");
                }
            }
        } else {
            io.werr("gengo: panic: ");
            io.werr(@errorName(err));
            io.werr("\n");
        }
        die(1);
    };

    die(0);
}
