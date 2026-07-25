const std = @import("std");
const builtin = @import("builtin");
const build_opts = @import("build_options");

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
const module_compile = @import("lang/module_compile.zig");
const vm = @import("lang/vm.zig");
const vmperf = @import("lang/vm_perf.zig");
const vms = @import("lang/vm_state.zig");
const cfg = @import("runtime_config");
const heap_rt = @import("runtime/heap.zig");
const fs_state = @import("lang/native/fs_state.zig");
const cap_env = if (build_opts.cap_env) @import("lang/native/cap_env.zig") else struct {};
const disasm = @import("lang/disasm.zig");
const bundle = @import("bundle.zig");
const gbc_writer = @import("lang/gbc_writer.zig");

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
        if (total == buf.len) {
            var probe: [1]u8 = undefined;
            var iov = [1]std.os.wasi.iovec_t{.{ .base = &probe, .len = 1 }};
            var nread: usize = 0;
            const rc = std.os.wasi.fd_read(0, &iov, iov.len, &nread);
            if (rc == .SUCCESS and nread > 0) return error.InputTooLong;
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
        if (total == buf.len) {
            var probe: [1]u8 = undefined;
            var nread: w32.DWORD = 0;
            const ok = ReadFile(handle, &probe, 1, &nread, null);
            if (ok.toBool() and nread > 0) return error.InputTooLong;
        }
        return total;
    }
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    if (total == buf.len) {
        var probe: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &probe) catch @as(usize, 0);
        if (n > 0) return error.InputTooLong;
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
// Prints prompt before reading. Returns null on EOF with no data.
// Never called on WASI (stdinIsTerminal = false).
fn readLine(prompt: []const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .wasi) return null;
    if (comptime builtin.os.tag == .linux) {
        return @import("repl_line.zig").readLine(prompt, buf);
    }
    if (comptime builtin.os.tag == .windows) {
        io.write(prompt);
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
    io.write(prompt);
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
    if (tmp == 0) {
        digit_count = 1;
    } else {
        while (tmp > 0) : (tmp /= 10) digit_count += 1;
    }

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

fn printRuntimeErrorBlock(prefix: []const u8, path: []const u8, src: []const u8, err: anyerror, line: u32, col: u32, msg: []const u8) void {
    io.werr(prefix);
    io.werr(@errorName(err));
    if (msg.len > 0) {
        io.werr(": ");
        io.werr(msg);
    }
    io.werr("\n  --> ");
    io.werr(path);
    io.werr(":");
    io.werrInt(@intCast(line));
    if (col != 0) {
        io.werr(":");
        io.werrInt(@intCast(col));
    }
    io.werr("\n");
    printSourceLine(src, line, col);
}

// Isolated to keep runCli's frame small. Runtime is heap-allocated because its
// size grows with the active preset and can exceed the WASM shadow stack limit.
fn runReplMode(backend: vm.Policy.NativeBackend, max_ops: ?u64, caps: []const []const u8) noreturn {
    const repl_rt = std.heap.page_allocator.create(Runtime) catch {
        io.werr("gengo: out of memory\n");
        die(1);
    };
    repl_rt.initWithPolicy(.{
        .allow_io = true,
        .native_backend = backend,
        .max_ops = max_ops,
    }) catch {
        io.werr("gengo: runtime init failed\n");
        die(1);
    };
    repl_rt.enabled_capabilities = caps;
    io.write("Gengo REPL  (Ctrl+D to exit)\n");
    while (true) {
        const line = readLine("> ", g_src_buf[0..]) orelse break;
        if (line.len == 0) continue;
        repl_rt.runIncremental(line) catch |err| {
            if (repl_rt.last_compile_line != 0) {
                io.werr("compile error: ");
                io.werr(@errorName(err));
                if (repl_rt.last_compile_msg_len > 0) {
                    io.werr(": ");
                    io.werr(repl_rt.last_compile_msg_buf[0..repl_rt.last_compile_msg_len]);
                }
                io.werr("\n  --> repl:");
                io.werrInt(@intCast(repl_rt.last_compile_line));
                io.werr(":");
                io.werrInt(@intCast(repl_rt.last_compile_col));
                io.werr("\n");
                printSourceLine(line, repl_rt.last_compile_line, repl_rt.last_compile_col);
            } else if (repl_rt.last_runtime_line != 0) {
                printRuntimeErrorBlock(
                    "error: ",
                    "repl",
                    line,
                    err,
                    repl_rt.last_runtime_line,
                    repl_rt.last_runtime_col,
                    repl_rt.last_runtime_msg_buf[0..repl_rt.last_runtime_msg_len],
                );
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

fn parseHeapSize(s: []const u8) usize {
    if (s.len == 0) return 0;
    const last = s[s.len - 1];
    const multiplier: usize = switch (last) {
        'k', 'K' => 1024,
        'm', 'M' => 1024 * 1024,
        'g', 'G' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (multiplier != 1) s[0 .. s.len - 1] else s;
    const n = std.fmt.parseUnsigned(usize, digits, 10) catch return 0;
    return n * multiplier;
}

fn printBundleUsage() void {
    io.write("Usage: gengo bundle --entry <archive-path.gengo> -o <bundle.zip> [options] [folder ...]\n");
    io.write("\n");
    io.write("Options:\n");
    io.write("  --root <name>=<folder>  Add a source root (repeatable)\n");
    io.write("  --entry <path>          Entrypoint path within the archive, e.g. app/main.gengo\n");
    io.write("  -o, --output <path>     Output ZIP path\n");
    io.write("  --include <glob>        Include matching .gengo files (repeatable)\n");
    io.write("  --exclude <glob>        Exclude matching files (repeatable; wins over include)\n");
    io.write("\n");
    io.write("A positional folder is equivalent to --root <basename>=<folder>.\n");
}

fn rootNameFromPath(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {}
    if (end == 0) return path;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') : (start -= 1) {}
    return path[start..end];
}

fn runBundle(args: []const []const u8) void {
    if (comptime builtin.os.tag == .wasi) {
        io.werr("gengo: bundle is available only in the native CLI\n");
        die(1);
    }

    var roots: [MaxArgs]bundle.Root = undefined;
    var root_count: usize = 0;
    var includes: [MaxArgs][]const u8 = undefined;
    var include_count: usize = 0;
    var excludes: [MaxArgs][]const u8 = undefined;
    var exclude_count: usize = 0;
    var entry: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printBundleUsage();
            die(0);
        }
        if (std.mem.eql(u8, arg, "--entry") or std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "--root") or std.mem.eql(u8, arg, "--include") or std.mem.eql(u8, arg, "--exclude")) {
            if (index + 1 >= args.len) {
                io.werr("gengo: bundle option requires a value: ");
                io.werr(arg);
                io.werr("\n");
                die(1);
            }
            const value = args[index + 1];
            if (std.mem.eql(u8, arg, "--entry")) {
                entry = value;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                output = value;
            } else if (std.mem.eql(u8, arg, "--root")) {
                const eq = std.mem.indexOfScalar(u8, value, '=') orelse {
                    io.werr("gengo: --root expects name=folder: ");
                    io.werr(value);
                    io.werr("\n");
                    die(1);
                };
                if (root_count >= roots.len) {
                    io.werr("gengo: too many bundle roots\n");
                    die(1);
                }
                roots[root_count] = .{ .name = value[0..eq], .directory = value[eq + 1 ..] };
                root_count += 1;
            } else if (std.mem.eql(u8, arg, "--include")) {
                if (include_count >= includes.len) {
                    io.werr("gengo: too many --include patterns\n");
                    die(1);
                }
                includes[include_count] = value;
                include_count += 1;
            } else {
                if (exclude_count >= excludes.len) {
                    io.werr("gengo: too many --exclude patterns\n");
                    die(1);
                }
                excludes[exclude_count] = value;
                exclude_count += 1;
            }
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            io.werr("gengo: unknown bundle option: ");
            io.werr(arg);
            io.werr("\n");
            die(1);
        }
        if (root_count >= roots.len) {
            io.werr("gengo: too many bundle roots\n");
            die(1);
        }
        roots[root_count] = .{ .name = rootNameFromPath(arg), .directory = arg };
        root_count += 1;
        index += 1;
    }

    const entry_path = entry orelse {
        io.werr("gengo: bundle requires --entry <archive-path.gengo>\n");
        die(1);
    };
    const output_path = output orelse {
        io.werr("gengo: bundle requires -o <bundle.zip>\n");
        die(1);
    };
    const result = bundle.buildFromRoots(
        std.heap.page_allocator,
        roots[0..root_count],
        entry_path,
        includes[0..include_count],
        excludes[0..exclude_count],
    ) catch |err| {
        io.werr("gengo: cannot build bundle: ");
        io.werr(@errorName(err));
        io.werr("\n");
        die(1);
    };
    defer std.heap.page_allocator.free(result.archive);

    const io_ctx = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().createFile(io_ctx, output_path, .{}) catch {
        io.werr("gengo: cannot create bundle: ");
        io.werr(output_path);
        io.werr("\n");
        die(1);
    };
    defer file.close(io_ctx);
    file.writeStreamingAll(io_ctx, result.archive) catch {
        io.werr("gengo: cannot write bundle: ");
        io.werr(output_path);
        io.werr("\n");
        die(1);
    };
    io.write("gengo: bundled ");
    io.writeInt(@intCast(result.source_count));
    io.write(" source files to ");
    io.write(output_path);
    io.write("\n");
}

fn runCli(argv: []const []const u8) void {
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "bundle")) {
        runBundle(argv[2..]);
        return;
    }
    var script_path: ?[]const u8 = null;
    var script_name: []const u8 = "<stdin>";
    var script_index: usize = 1;
    var eval_source: ?[]const u8 = null;
    var backend: vm.Policy.NativeBackend = .embedded;
    var max_ops: ?u64 = null;
    var test_mode: bool = false;
    var profile_mode: bool = false;
    var disasm_mode: bool = false;
    var emit_gbc_path: ?[]const u8 = null;
    var cap_names: [8][]const u8 = undefined;
    var cap_count: usize = 0;
    var module_paths: [module_compile.MaxModuleRoots][]const u8 = undefined;
    var module_path_count: usize = 0;
    var heap_size: usize = heap_rt.HeapSize;
    while (script_index < argv.len) {
        const a = argv[script_index];
        if (a.len == 2 and a[0] == '-' and a[1] == '-') {
            script_index += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            io.write("Usage: gengo [options] [script.gengo]\n");
            io.write("\n");
            io.write("Options:\n");
            io.write("  --help, -h         Show this help message\n");
            io.write("  --version          Print version and exit\n");
            io.write("  --disasm           Compile and print bytecode disassembly; do not run\n");
            io.write("  --emit-gbc <path>  Compile and write a GBC bytecode cache file; do not run\n");
            io.write("  --test             Run test blocks in the script\n");
            io.write("  --profile          With --test, report peak ops/heap/stack/objects per block\n");
            io.write("  --cap <name>       Enable a named capability (repeatable)\n");
            io.write("  --modules <path>   Allow imports from an extra directory (repeatable)\n");
            io.write("  --max-ops <n>      Limit instruction count (0 = unlimited)\n");
            io.write("  --heap <size>      Set GC heap size, e.g. 4m, 512k (default 1m)\n");
            io.write("  --backend <name>   Native call backend: embedded (default) or host\n");
            io.write("  --mount <n>=<path> Mount a filesystem path under the given name\n");
            io.write("  -e, --eval <code>  Evaluate inline code instead of a script file\n");
            io.write("  --                 End of options; treat next argument as script path\n");
            io.write("\n");
            io.write("If no script is given and stdin is a terminal, starts the REPL.\n");
            die(0);
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
        if (std.mem.eql(u8, a, "--cap")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: --cap requires value\n");
                die(1);
            }
            if (cap_count >= cap_names.len) {
                io.werr("gengo: too many --cap flags\n");
                die(1);
            }
            cap_names[cap_count] = argv[script_index + 1];
            cap_count += 1;
            script_index += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--modules")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: --modules requires a path\n");
                die(1);
            }
            if (module_path_count >= module_paths.len) {
                io.werr("gengo: too many --modules flags (max 8)\n");
                die(1);
            }
            module_paths[module_path_count] = argv[script_index + 1];
            module_path_count += 1;
            script_index += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--mount")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: --mount requires value name=path\n");
                die(1);
            }
            const v = argv[script_index + 1];
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse {
                io.werr("gengo: invalid --mount value (expected name=path): ");
                io.werr(v);
                io.werr("\n");
                die(1);
            };
            fs_state.addMount(v[0..eq], v[eq + 1 ..]) catch |err| {
                io.werr("gengo: invalid --mount value (");
                io.werr(@errorName(err));
                io.werr("): ");
                io.werr(v);
                io.werr("\n");
                die(1);
            };
            script_index += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--heap")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: --heap requires a size (e.g. 4m, 512k, 8388608)\n");
                die(1);
            }
            const v = argv[script_index + 1];
            const parsed = parseHeapSize(v);
            if (parsed == 0) {
                io.werr("gengo: invalid --heap value: ");
                io.werr(v);
                io.werr("\n");
                die(1);
            }
            heap_size = parsed;
            script_index += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--disasm")) {
            disasm_mode = true;
            script_index += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--emit-gbc")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: --emit-gbc requires a path argument\n");
                die(1);
            }
            emit_gbc_path = argv[script_index + 1];
            script_index += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--test")) {
            test_mode = true;
            script_index += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--profile")) {
            profile_mode = true;
            script_index += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--version")) {
            io.write("Gengoscript v");
            io.write(build_opts.version);
            io.write("\n");
            die(0);
        }
        if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--eval")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: -e requires an argument\n");
                die(1);
            }
            eval_source = argv[script_index + 1];
            script_index += 2;
            continue;
        }
        // Positional argument: first one is the script path.
        if (script_path == null and eval_source == null) {
            script_path = a;
            script_name = a;
            script_index += 1;
            continue;
        }
        io.werr("gengo: unexpected argument: ");
        io.werr(a);
        io.werr("\n");
        die(1);
    }

    if (eval_source != null and script_path != null) {
        io.werr("gengo: -e/--eval and a script file are mutually exclusive\n");
        die(1);
    }

    // REPL: enter interactive mode when no file is given and stdin is a terminal.
    // Runs in a separate function so this frame never holds two Runtimes at once.
    if (eval_source == null and script_path == null and stdinIsTerminal()) {
        runReplMode(backend, max_ops, if (cap_count > 0) cap_names[0..cap_count] else &.{});
    }

    if (eval_source != null) script_name = "<eval>";

    const total = if (eval_source == null)
        readSource(script_path, &g_src_buf) catch |err| {
            if (err == error.InputTooLong) {
                io.werr("gengo: input is larger than max_input_bytes (");
                io.werrInt(cfg.max_input_bytes);
                io.werr("); configure a larger preset\n");
                die(1);
            }
            if (script_path) |p| {
                io.werr("gengo: cannot open: ");
                io.werr(p);
            } else {
                io.werr("gengo: cannot read stdin");
            }
            io.werr("\n");
            die(1);
        }
    else
        0;
    const src: []const u8 = if (eval_source) |es| es else g_src_buf[0..total];

    const runtime = std.heap.page_allocator.create(Runtime) catch {
        io.werr("gengo: out of memory\n");
        die(1);
    };
    const max_objects = @min(65534, @max(heap_rt.MaxObjects, heap_size / 512));
    runtime.initWithConfig(.{
        .allow_io = true,
        .native_backend = backend,
        .max_ops = max_ops,
        .profile_mode = profile_mode,
    }, heap_size, max_objects, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.heap.page_allocator) catch {
        io.werr("gengo: runtime init failed\n");
        die(1);
    };
    if (cap_count > 0) {
        runtime.enabled_capabilities = cap_names[0..cap_count];
    }
    // Set source_root to the directory containing the entry script so imports
    // are restricted to that tree by default. eval/stdin have no root restriction.
    if (script_path) |p| {
        const last_slash = std.mem.lastIndexOfScalar(u8, p, '/');
        runtime.source_root = if (last_slash) |i| p[0..i] else ".";
    }
    if (module_path_count > 0) {
        runtime.module_roots = module_paths[0..module_path_count];
    }
    const script_arg = if (eval_source != null) "<eval>" else if (script_path) |p| p else "";

    // A GBC artifact (magic bytes at offset 0) as the script argument runs
    // directly, skipping compilation entirely — the "ship a .gbc to a
    // constrained host" path (#5). Takes priority over --disasm/--emit-gbc/
    // --test, none of which apply to an already-compiled artifact.
    if (src.len >= 8 and std.mem.eql(u8, src[0..8], &gbc_writer.MAGIC)) {
        runtime.runFromGbc(src) catch |err| {
            io.werr("gengo: gbc load/run error: ");
            io.werr(@errorName(err));
            const emsg = runtime.vm_state.runtimeErrMsg();
            if (emsg.len > 0) {
                io.werr(": ");
                io.werr(emsg);
            }
            io.werr("\n");
            die(1);
        };
        die(0);
    }

    if (emit_gbc_path) |out_path| {
        runtime.compileOnly(src, script_arg, .filesystem) catch |err| {
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
            die(1);
        };
        const gbc_bytes = gbc_writer.write(runtime.chunk_state, std.heap.page_allocator, .{ .root_source = src }) catch |err| {
            io.werr("gengo: cannot emit GBC: ");
            io.werr(@errorName(err));
            if (err == error.UnsupportedConstant) {
                io.werr(" (this script uses a feature GBC caching doesn't support yet: enums, a predicate declared inside a function body (rather than at module/type scope), or a closure with real captures stored as a constant — see issue #5)");
            }
            io.werr("\n");
            die(1);
        };
        if (comptime builtin.os.tag == .wasi) {
            io.werr("gengo: --emit-gbc is not supported on this target yet\n");
            die(1);
        }
        const gbc_io = std.Io.Threaded.global_single_threaded.io();
        const gbc_file = std.Io.Dir.cwd().createFile(gbc_io, out_path, .{}) catch {
            io.werr("gengo: cannot create: ");
            io.werr(out_path);
            io.werr("\n");
            die(1);
        };
        defer gbc_file.close(gbc_io);
        gbc_file.writeStreamingAll(gbc_io, gbc_bytes) catch {
            io.werr("gengo: cannot write: ");
            io.werr(out_path);
            io.werr("\n");
            die(1);
        };
        die(0);
    }

    if (disasm_mode) {
        runtime.compileOnly(src, script_arg, .filesystem) catch |err| {
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
            die(1);
        };
        disasm.disassemble(vm.VMContext.fromActive().cs);
        die(0);
    }

    const run_error: ?anyerror = blk: {
        const outcome = runtime.runPathWithProvider(src, script_arg, .filesystem, test_mode) catch |err| break :blk err;
        _ = runtime.waitOutSuspension(outcome) catch |err| break :blk err;
        break :blk null;
    };
    if (run_error) |err| {
        vmperf.printSummary(vms.vmState().gc_runs, vms.vmState().gc_time_ns, vms.vmState().alloc_object_calls, vms.vmState().alloc_managed_slice_calls, vms.vmState().alloc_managed_bytes_calls);

        if (err == error.OutOfMemory) {
            if (runtime.last_compile_line != 0) {
                io.werr("gengo: compilation failed: heap too small (");
            } else {
                io.werr("gengo: panic: heap exhausted (");
            }
            io.werrInt(@intCast(heap_size / 1024));
            io.werr("k); bump=");
            io.werrInt(@intCast(vm.VMContext.fromActive().hs.usedBytes() / 1024));
            io.werr("k free=");
            io.werrInt(@intCast(vm.VMContext.fromActive().hs.totalFreeListBytes() / 1024));
            io.werr("k live_objs=");
            io.werrInt(@intCast(heap_rt.liveObjectCount()));
            io.werr(" gc_runs=");
            io.werrInt(@intCast(vms.vmState().gc_runs));
            var fl_buf: [256]u8 = undefined;
            const fl_summary = vm.VMContext.fromActive().hs.freeListSummary(&fl_buf);
            if (fl_summary.len > 0) {
                io.werr(" free_lists=[");
                io.werr(fl_summary);
                io.werr("]");
            }
            io.werr("; use --heap 1m or larger\n");
        } else if (runtime.last_compile_line != 0) {
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
            const runtime_path = if (runtime.lastRuntimePath().len != 0) runtime.lastRuntimePath() else script_name;
            const runtime_src = if (std.mem.eql(u8, runtime_path, script_name)) src else "";
            printRuntimeErrorBlock(
                "gengo: panic: ",
                runtime_path,
                runtime_src,
                err,
                runtime.last_runtime_line,
                runtime.last_runtime_col,
                runtime.last_runtime_msg_buf[0..runtime.last_runtime_msg_len],
            );
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
    }

    vmperf.printSummary(vms.vmState().gc_runs, vms.vmState().gc_time_ns, vms.vmState().alloc_object_calls, vms.vmState().alloc_managed_slice_calls, vms.vmState().alloc_managed_bytes_calls);
    die(if (runtime.test_failed) 1 else 0);
}

// Zig 0.16 start.zig auto-exports _start for WASM and calls main().
// On WASM, init.args.vector is void — collect args via WASI syscalls instead.
// On native, Zig runtime populates init.args.vector from OS argv.
pub fn main(init: std.process.Init.Minimal) void {
    // GC debug modes (posix native only): stress collects on every allocation
    // so unrooted-window bugs fire deterministically; paranoia adds heap
    // free/alloc-of-live tripwires.
    if (comptime builtin.os.tag != .wasi and builtin.os.tag != .windows) {
        for (init.environ.block.slice) |entry_opt| {
            const entry = entry_opt orelse continue;
            const e = std.mem.span(entry);
            if (std.mem.startsWith(u8, e, "GENGO_GC_STRESS=")) {
                @import("lang/vm_gc.zig").gc_stress = true;
            }
            if (std.mem.startsWith(u8, e, "GENGO_HEAP_PARANOIA=")) {
                @import("runtime/heap.zig").paranoia = true;
            }
        }
    }
    if (comptime build_opts.cap_env) cap_env.setEnvironBlock(init.environ.block);
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

var test_capture_buf: [1024]u8 = undefined;
var test_capture_len: usize = 0;

fn testCaptureWrite(s: []const u8) void {
    const avail = @min(s.len, test_capture_buf.len - test_capture_len);
    @memcpy(test_capture_buf[test_capture_len..][0..avail], s[0..avail]);
    test_capture_len += avail;
}

test "runtime error block includes location and caret" {
    io.setWriteOverrides(testCaptureWrite, testCaptureWrite);
    defer io.clearWriteOverrides();

    test_capture_len = 0;
    printRuntimeErrorBlock("error: ", "repl", "x += 1.5", error.TypeError, 1, 3, "cannot apply '+' to int and float");

    const got = test_capture_buf[0..test_capture_len];
    try std.testing.expect(std.mem.indexOf(u8, got, "error: TypeError: cannot apply '+' to int and float") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "  --> repl:1:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "   1 | x += 1.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "     |   ^") != null);
}
