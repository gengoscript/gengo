const std = @import("std");
const builtin = @import("builtin");

const w32 = std.os.windows;

extern "kernel32" fn GetStdHandle(nStdHandle: w32.DWORD) callconv(.winapi) w32.HANDLE;
extern "kernel32" fn ReadFile(
    hFile: w32.HANDLE,
    lpBuffer: *anyopaque,
    nNumberOfBytesToRead: w32.DWORD,
    lpNumberOfBytesRead: ?*w32.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) w32.BOOL;

const Runtime = @import("runtime/runtime.zig").Runtime;
const io = @import("runtime/io.zig");
const source_io = @import("runtime/source_io.zig");
const vm = @import("lang/vm.zig");
const vmperf = @import("lang/vm_perf.zig");
const vms = @import("lang/vm_state.zig");
const cfg = @import("runtime/config.zig");

const MaxArgs = 32;
const ArgBufSize = 4096;
const MaxInput = cfg.max_input_bytes;

var g_src_buf: [MaxInput]u8 = undefined;

fn die(code: u32) noreturn {
    if (comptime builtin.os.tag == .wasi) {
        std.os.wasi.proc_exit(code);
    }
    std.process.exit(@intCast(code));
}

// Read a file (or stdin when maybe_path is null) into buf, returning bytes read.
fn readSource(maybe_path: ?[]const u8, buf: []u8) !usize {
    if (maybe_path) |p| return source_io.readFile(p, buf);
    if (comptime builtin.os.tag == .wasi) {
        var total: usize = 0;
        while (total < buf.len) {
            var iov = [1]std.os.wasi.iovec_t{.{ .base = buf[total..].ptr, .len = buf.len - total }};
            var nread: usize = 0;
            const rc = std.os.wasi.fd_read(0, &iov, iov.len, &nread);
            if (rc != .SUCCESS) return error.ReadFailed;
            if (nread == 0) break;
            total += nread;
        }
        return total;
    }
    if (comptime builtin.os.tag == .windows) {
        const STD_INPUT_HANDLE: w32.DWORD = 0xFFFFFFF6;
        const handle = GetStdHandle(STD_INPUT_HANDLE);
        var total: usize = 0;
        while (total < buf.len) {
            var nread: w32.DWORD = 0;
            const to_read: w32.DWORD = @intCast(buf.len - total);
            const ok = ReadFile(handle, &buf[total], to_read, &nread, null);
            if (!ok.toBool() or nread == 0) break;
            total += nread;
        }
        return total;
    }
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}

// Returns true if fd 0 (stdin) is an interactive terminal.
// On WASI always false. On Linux uses TCGETS ioctl. Other native targets: false.
fn stdinIsTerminal() bool {
    if (comptime builtin.os.tag == .wasi) return false;
    if (comptime builtin.os.tag == .linux) {
        const TCGETS: usize = 0x5401;
        var buf: [64]u8 align(8) = undefined;
        const rc = std.os.linux.syscall3(.ioctl, 0, TCGETS, @intFromPtr(&buf));
        return rc == 0;
    }
    return false;
}

// Read one line from stdin into buf (without the newline).
// Returns null on EOF with no data. Never called on WASI (stdinIsTerminal = false).
fn readLine(buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .wasi) return null;
    if (comptime builtin.os.tag == .windows) {
        const STD_INPUT_HANDLE: w32.DWORD = 0xFFFFFFF6;
        const handle = GetStdHandle(STD_INPUT_HANDLE);
        var n: usize = 0;
        while (n < buf.len) {
            var ch: [1]u8 = undefined;
            var nread: w32.DWORD = 0;
            const ok = ReadFile(handle, &ch, 1, &nread, null);
            if (!ok.toBool() or nread == 0) return if (n > 0) buf[0..n] else null;
            if (ch[0] == '\n') return buf[0..n];
            if (ch[0] == '\r') continue;
            buf[n] = ch[0];
            n += 1;
        }
        return buf[0..n];
    }
    var n: usize = 0;
    while (n < buf.len) {
        var ch: [1]u8 = undefined;
        const r = std.posix.read(std.posix.STDIN_FILENO, &ch) catch return if (n > 0) buf[0..n] else null;
        if (r == 0) return if (n > 0) buf[0..n] else null;
        if (ch[0] == '\n') return buf[0..n];
        if (ch[0] == '\r') continue;
        buf[n] = ch[0];
        n += 1;
    }
    return buf[0..n];
}

// printSourceLine prints a Rust-style source snippet for the given 1-based line and column.
// col == 0 means no caret.
fn printSourceLine(src: []const u8, line: u32, col: u32) void {
    var cur_line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < src.len and cur_line < line) : (i += 1) {
        if (src[i] == '\n') {
            cur_line += 1;
            line_start = i + 1;
        }
    }
    if (cur_line != line) return;

    var line_end = line_start;
    while (line_end < src.len and src[line_end] != '\n') : (line_end += 1) {}
    const text = src[line_start..line_end];

    var digit_count: usize = 0;
    var tmp = line;
    if (tmp == 0) { digit_count = 1; } else { while (tmp > 0) : (tmp /= 10) digit_count += 1; }

    io.werr("   ");
    io.werrInt(@intCast(line));
    io.werr(" | ");
    io.werr(text);
    io.werr("\n");

    if (col > 0) {
        io.werr("   ");
        var di: usize = 0;
        while (di < digit_count) : (di += 1) io.werr(" ");
        io.werr(" | ");
        var c: u32 = 1;
        while (c < col) : (c += 1) io.werr(" ");
        io.werr("^\n");
    }
}

// Isolated to keep runCli's frame small. Runtime is heap-allocated because its
// size grows with the active preset and can exceed the WASM shadow stack limit.
fn runReplMode(backend: vm.Policy.NativeBackend, max_ops: ?u64) noreturn {
    const repl_rt = std.heap.page_allocator.create(Runtime) catch {
        io.werr("gengo: out of memory\n");
        die(1);
    };
    repl_rt.initWithPolicy(.{
        .allow_io = true,
        .native_backend = backend,
        .max_ops = max_ops,
    });
    io.write("Gengo REPL  (Ctrl+D to exit)\n");
    while (true) {
        io.write("> ");
        const line = readLine(g_src_buf[0..]) orelse break;
        if (line.len == 0) continue;
        repl_rt.runIncremental(line) catch |err| {
            if (repl_rt.last_compile_line != 0) {
                io.werr("compile error: ");
                if (repl_rt.last_compile_msg_len > 0) {
                    io.werr(repl_rt.last_compile_msg_buf[0..repl_rt.last_compile_msg_len]);
                    io.werr("\n     --> line ");
                    io.werrInt(@intCast(repl_rt.last_compile_line));
                    if (repl_rt.last_compile_col > 0) {
                        io.werr(":");
                        io.werrInt(@intCast(repl_rt.last_compile_col));
                    }
                    io.werr("\n");
                } else {
                    io.werr(@errorName(err));
                    io.werr("\n");
                }
            } else {
                io.werr("error: ");
                io.werr(@errorName(err));
                io.werr("\n");
            }
        };
    }
    io.write("\n");
    die(0);
}

fn runCli(argv: []const []const u8) void {
    var script_path: ?[]const u8 = null;
    var script_name: []const u8 = "<stdin>";
    var script_index: usize = 1;
    var backend: vm.Policy.NativeBackend = .embedded;
    var max_ops: ?u64 = null;
    var test_mode: bool = false;
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
        if (std.mem.eql(u8, a, "--test")) {
            test_mode = true;
            script_index += 1;
            continue;
        }
        break;
    }

    if (argv.len > script_index) {
        script_path = argv[script_index];
        script_name = argv[script_index];
    }

    // REPL: enter interactive mode when no file is given and stdin is a terminal.
    // Runs in a separate function so this frame never holds two Runtimes at once.
    if (script_path == null and stdinIsTerminal()) {
        runReplMode(backend, max_ops);
    }

    const total = readSource(script_path, &g_src_buf) catch {
        if (script_path) |p| {
            io.werr("gengo: cannot open: ");
            io.werr(p);
        } else {
            io.werr("gengo: cannot read stdin");
        }
        io.werr("\n");
        die(1);
    };
    const src = g_src_buf[0..total];

    const runtime = std.heap.page_allocator.create(Runtime) catch {
        io.werr("gengo: out of memory\n");
        die(1);
    };
    runtime.initWithPolicy(.{
        .allow_io = true,
        .native_backend = backend,
        .max_ops = max_ops,
    });
    runtime.runPathWithProvider(src, if (script_path) |p| p else "", .filesystem, test_mode) catch |err| {
        vmperf.printSummary(vms.vmState().gc_runs, vms.vmState().gc_time_ns,
            vms.vmState().alloc_object_calls, vms.vmState().alloc_managed_slice_calls,
            vms.vmState().alloc_managed_bytes_calls);

        if (runtime.last_compile_line != 0) {
            const compile_path = if (runtime.lastCompilePath().len != 0) runtime.lastCompilePath() else script_name;
            io.werr("gengo: compile error: ");
            io.werr(@errorName(err));
            if (runtime.last_compile_msg_len > 0) {
                io.werr(": ");
                io.werr(runtime.last_compile_msg_buf[0..runtime.last_compile_msg_len]);
            }
            io.werr("\n  --> ");
            io.werr(compile_path);
            io.werr(":");
            io.werrInt(@intCast(runtime.last_compile_line));
            if (runtime.last_compile_col > 0) {
                io.werr(":");
                io.werrInt(@intCast(runtime.last_compile_col));
            }
            io.werr("\n");
            if (std.mem.eql(u8, compile_path, script_name)) {
                printSourceLine(src, runtime.last_compile_line, runtime.last_compile_col);
            }
        } else if (runtime.last_runtime_line != 0) {
            io.werr("gengo: panic: ");
            io.werr(@errorName(err));
            if (runtime.last_runtime_msg_len > 0) {
                io.werr(": ");
                io.werr(runtime.last_runtime_msg_buf[0..runtime.last_runtime_msg_len]);
            }
            io.werr("\n  --> ");
            io.werr(script_name);
            io.werr(":");
            io.werrInt(@intCast(runtime.last_runtime_line));
            if (runtime.last_runtime_col != 0) {
                io.werr(":");
                io.werrInt(@intCast(runtime.last_runtime_col));
            }
            io.werr("\n");
            printSourceLine(src, runtime.last_runtime_line, runtime.last_runtime_col);
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
                    io.werrInt(@intCast(pf.line));
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

    vmperf.printSummary(vms.vmState().gc_runs, vms.vmState().gc_time_ns,
        vms.vmState().alloc_object_calls, vms.vmState().alloc_managed_slice_calls,
        vms.vmState().alloc_managed_bytes_calls);
    die(if (runtime.test_failed) 1 else 0);
}

// Zig 0.16 start.zig auto-exports _start for WASM and calls main().
// On WASM, init.args.vector is void — collect args via WASI syscalls instead.
// On native, Zig runtime populates init.args.vector from OS argv.
pub fn main(init: std.process.Init.Minimal) void {
    var argv_storage: [MaxArgs][]const u8 = undefined;
    var n: usize = 0;

    if (comptime builtin.os.tag == .wasi) {
        var argc: usize = 0;
        var argv_buf_size: usize = 0;
        if (std.os.wasi.args_sizes_get(&argc, &argv_buf_size) != .SUCCESS) {
            io.werr("gengo: cannot read args\n");
            die(1);
        }
        if (argc > MaxArgs or argv_buf_size > ArgBufSize) {
            io.werr("gengo: args too large\n");
            die(1);
        }
        var argv_ptrs: [MaxArgs][*:0]u8 = undefined;
        var argv_buf: [ArgBufSize]u8 = undefined;
        if (std.os.wasi.args_get(argv_ptrs[0..argc].ptr, argv_buf[0..argv_buf_size].ptr) != .SUCCESS) {
            io.werr("gengo: cannot read args\n");
            die(1);
        }
        for (0..argc) |i| argv_storage[i] = std.mem.span(argv_ptrs[i]);
        n = argc;
    } else if (comptime builtin.os.tag == .windows) {
        // On Windows, init.args.vector is []const u16 (WTF-16 command line).
        // Use Args.Iterator which parses and converts to WTF-8 strings.
        var utf8_bufs: [MaxArgs][512]u8 = undefined;
        var iter = std.process.Args.Iterator.initAllocator(init.args, std.heap.page_allocator) catch die(1);
        defer iter.deinit();
        while (iter.next()) |arg| {
            if (n >= MaxArgs) break;
            const len = @min(arg.len, utf8_bufs[n].len);
            @memcpy(utf8_bufs[n][0..len], arg[0..len]);
            argv_storage[n] = utf8_bufs[n][0..len];
            n += 1;
        }
        runCli(argv_storage[0..n]);
        return;
    } else {
        for (init.args.vector) |arg| {
            if (n >= MaxArgs) break;
            argv_storage[n] = std.mem.span(arg);
            n += 1;
        }
    }

    runCli(argv_storage[0..n]);
}
