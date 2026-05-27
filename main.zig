const sc = @import("libsc");
const std = @import("std");

const Compiler = @import("lang/compiler.zig").Compiler;
const globals = @import("lang/globals.zig");
const heap = @import("runtime/heap.zig");
const io = @import("runtime/io.zig");
const vm = @import("lang/vm.zig");
const cfg = @import("runtime/config.zig");

const MaxArgs = 16;
const ArgBufSize = 512;
const MaxInput = cfg.max_input_bytes;

const stdin_fd: i32 = 0;

var g_src_buf: [MaxInput]u8 = undefined;

export fn _start() void {
    var argv_ptrs: [MaxArgs]u32 = undefined;
    var argv_buf: [ArgBufSize]u8 = undefined;
    var argv_out: [MaxArgs][]const u8 = undefined;
    const ar = sc.process.args(argv_ptrs[0..], argv_buf[0..], argv_out[0..]);
    if (ar.errno != .OK) {
        io.werr("gengo: cannot read args\n");
        sc.process.exit(1);
    }
    const argv = ar.argv;

    var src: []const u8 = undefined;
    var script_index: usize = 1;
    var backend: vm.Policy.NativeBackend = .embedded;
    while (script_index < argv.len) {
        const a = argv[script_index];
        if (a.len == 2 and a[0] == '-' and a[1] == '-') {
            script_index += 1;
            continue;
        }
        if (a.len == 9 and std.mem.eql(u8, a, "--backend")) {
            if (script_index + 1 >= argv.len) {
                io.werr("gengo: --backend requires value\n");
                sc.process.exit(1);
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
                sc.process.exit(1);
            }
            script_index += 2;
            continue;
        }
        break;
    }

    if (argv.len <= script_index) {
        var total: usize = 0;
        while (total < g_src_buf.len) {
            const r = sc.fd.read(stdin_fd, g_src_buf[total..]);
            if (r.errno != .OK or r.n == 0) break;
            total += r.n;
        }
        src = g_src_buf[0..total];
    } else {
        const path = argv[script_index];
        const fr = sc.fs.open(path, sc.fd.O.read, 0);
        if (fr.errno != .OK) {
            io.werr("gengo: cannot open: ");
            io.werr(path);
            io.werr("\n");
            sc.process.exit(1);
        }
        var total: usize = 0;
        while (total < g_src_buf.len) {
            const r = sc.fd.read(fr.fd, g_src_buf[total..]);
            if (r.errno != .OK or r.n == 0) break;
            total += r.n;
        }
        _ = sc.fd.close(fr.fd);
        src = g_src_buf[0..total];
    }

    globals.reset();
    vm.reset();
    vm.setPolicy(.{ .allow_io = true, .native_backend = backend });
    heap.reset();

    var compiler = Compiler.init(src);
    compiler.compile() catch |err| {
        io.werr("gengo: compile error on line ");
        io.writeInt(@intCast(compiler.prev.line));
        io.werr(": ");
        io.werr(@errorName(err));
        io.werr("\n");
        sc.process.exit(1);
    };

    vm.run() catch |err| {
        io.werr("gengo: runtime error: ");
        io.werr(@errorName(err));
        io.werr("\n");
        sc.process.exit(1);
    };

    sc.process.exit(0);
}
