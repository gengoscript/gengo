const Compiler = @import("../lang/compiler.zig").Compiler;
const chunk = @import("../lang/chunk.zig");
const globals = @import("../lang/globals.zig");
const heap = @import("heap.zig");
const module_compile = @import("../lang/module_compile.zig");
const vm = @import("../lang/vm.zig");
const vmnative = @import("../lang/vm_native.zig");
const Value = @import("../lang/value.zig").Value;

const MaxFrames = @import("../runtime/config.zig").max_frames;

pub const Runtime = struct {
    policy: vm.Policy = .{},
    last_compile_line: u32 = 0,
    last_compile_path_buf: [module_compile.MaxModulePathBytes]u8 = undefined,
    last_compile_path_len: usize = 0,
    last_compile_col: u16 = 0,
    last_compile_msg_buf: [512]u8 = undefined,
    last_compile_msg_len: u16 = 0,
    last_runtime_line: u32 = 0,
    last_runtime_col: u16 = 0,
    last_runtime_msg_buf: [512]u8 = undefined,
    last_runtime_msg_len: u16 = 0,
    panic_frames: [MaxFrames]vm.PanicFrame = undefined,
    panic_depth: usize = 0,
    chunk_state: chunk.State = .{},
    globals_state: globals.State = .{},
    heap_state: heap.State = .{},
    vm_state: vm.State = .{},

    pub fn init() Runtime {
        var rt: Runtime = .{};
        chunk.setActive(&rt.chunk_state);
        globals.setActive(&rt.globals_state);
        chunk.reset();
        globals.reset();
        heap.setActive(&rt.heap_state);
        vm.setActive(&rt.vm_state);
        vm.reset();
        heap.reset();
        return rt;
    }

    pub fn withPolicy(policy: vm.Policy) Runtime {
        var rt = init();
        rt.policy = policy;
        return rt;
    }

    pub fn setPolicy(self: *Runtime, policy: vm.Policy) void {
        self.policy = policy;
    }

    pub fn reset(self: *Runtime) void {
        self.activate();
        globals.reset();
        vm.reset();
        heap.reset();
        chunk.reset();
    }

    pub fn run(self: *Runtime, src: []const u8) !void {
        return self.runPath(src, "");
    }

    pub fn runPath(self: *Runtime, src: []const u8, path: []const u8) !void {
        return self.runPathWithProvider(src, path, .filesystem);
    }

    pub fn runPathWithSources(self: *Runtime, src: []const u8, path: []const u8, sources: []const module_compile.SourceEntry) !void {
        return self.runPathWithProvider(src, path, .{ .table = sources });
    }

    pub fn runPathWithProvider(self: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider) !void {
        self.last_compile_line = 0;
        self.last_compile_path_len = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        self.last_runtime_line = 0;
        self.last_runtime_col = 0;
        self.last_runtime_msg_len = 0;
        self.panic_depth = 0;
        self.reset();
        vm.setPolicy(self.policy);

        if (path.len != 0) {
            var session: module_compile.Session = .{};
            session.provider = provider;
            session.compileRoot(path, src) catch |err| {
                self.last_compile_line = if (session.last_error_line != 0) session.last_error_line else 1;
                self.last_compile_col = session.last_error_col;
                self.last_compile_msg_len = session.last_error_msg_len;
                @memcpy(self.last_compile_msg_buf[0..session.last_error_msg_len], session.last_error_msg_buf[0..session.last_error_msg_len]);
                self.setLastCompilePath(session.last_error_path);
                return err;
            };
        } else {
            var session: module_compile.Session = .{};
            session.provider = provider;
            var compiler = Compiler.init(src, .{
                .module_ctx = &session,
                .resolve_import = module_compile.Session.resolveImportOpaque,
            });
            compiler.compile(true) catch |err| {
                self.last_compile_line = compiler.prev.line;
                self.last_compile_col = compiler.err_col;
                self.last_compile_msg_len = compiler.err_msg_len;
                @memcpy(self.last_compile_msg_buf[0..compiler.err_msg_len], compiler.err_msg_buf[0..compiler.err_msg_len]);
                self.setLastCompilePath("");
                return err;
            };
        }

        try vmnative.installStdGlobal();
        vm.run() catch |err| {
            self.last_runtime_line = vm.panicLine();
            self.last_runtime_col = vm.panicCol();
            const pf = vm.panicFrames();
            self.panic_depth = pf.len;
            var fi: usize = 0;
            while (fi < pf.len) : (fi += 1) self.panic_frames[fi] = pf[fi];
            const emsg = vm.runtimeErrMsg();
            self.last_runtime_msg_len = @intCast(emsg.len);
            @memcpy(self.last_runtime_msg_buf[0..emsg.len], emsg);
            return err;
        };
    }

    // Run src without resetting globals or heap — allows successive REPL lines
    // to share definitions and allocated objects.
    pub fn runIncremental(self: *Runtime, src: []const u8) !void {
        self.last_compile_line = 0;
        self.last_compile_path_len = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        self.last_runtime_line = 0;
        self.last_runtime_col = 0;
        self.last_runtime_msg_len = 0;
        self.panic_depth = 0;
        self.activate();
        vm.setPolicy(self.policy);
        chunk.reset();
        vm.resetExec();

        var session: module_compile.Session = .{};
        var compiler = Compiler.init(src, .{
            .module_ctx = &session,
            .resolve_import = module_compile.Session.resolveImportOpaque,
        });
        compiler.compile(true) catch |err| {
            self.last_compile_line = compiler.prev.line;
            self.last_compile_col = compiler.err_col;
            self.last_compile_msg_len = compiler.err_msg_len;
            @memcpy(self.last_compile_msg_buf[0..compiler.err_msg_len], compiler.err_msg_buf[0..compiler.err_msg_len]);
            self.setLastCompilePath("");
            return err;
        };

        try vmnative.installStdGlobal();
        vm.run() catch |err| {
            self.last_runtime_line = vm.panicLine();
            self.last_runtime_col = vm.panicCol();
            const pf = vm.panicFrames();
            self.panic_depth = pf.len;
            var fi: usize = 0;
            while (fi < pf.len) : (fi += 1) self.panic_frames[fi] = pf[fi];
            const emsg = vm.runtimeErrMsg();
            self.last_runtime_msg_len = @intCast(emsg.len);
            @memcpy(self.last_runtime_msg_buf[0..emsg.len], emsg);
            return err;
        };
    }

    pub fn callGlobal(self: *Runtime, name: []const u8, args: []const Value) !Value {
        self.activate();
        vm.setPolicy(self.policy);
        self.last_compile_line = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        return vm.callGlobal(name, args) catch |err| {
            self.last_runtime_line = vm.panicLine();
            self.last_runtime_col = vm.panicCol();
            const pf = vm.panicFrames();
            self.panic_depth = pf.len;
            var fi: usize = 0;
            while (fi < pf.len) : (fi += 1) self.panic_frames[fi] = pf[fi];
            const emsg = vm.runtimeErrMsg();
            self.last_runtime_msg_len = @intCast(emsg.len);
            @memcpy(self.last_runtime_msg_buf[0..emsg.len], emsg);
            return err;
        };
    }

    fn activate(self: *Runtime) void {
        chunk.setActive(&self.chunk_state);
        globals.setActive(&self.globals_state);
        heap.setActive(&self.heap_state);
        vm.setActive(&self.vm_state);
    }

    pub fn lastCompilePath(self: *Runtime) []const u8 {
        return self.last_compile_path_buf[0..self.last_compile_path_len];
    }

    fn setLastCompilePath(self: *Runtime, path: []const u8) void {
        self.last_compile_path_len = @min(path.len, self.last_compile_path_buf.len);
        @memcpy(self.last_compile_path_buf[0..self.last_compile_path_len], path[0..self.last_compile_path_len]);
    }

};
