const std = @import("std");
const Compiler = @import("../lang/compiler.zig").Compiler;
const chunk = @import("../lang/chunk.zig");
const globals = @import("../lang/globals.zig");
const heap = @import("heap.zig");
const io = @import("io.zig");
const module_compile = @import("../lang/module_compile.zig");
const vm = @import("../lang/vm.zig");
const vms = @import("../lang/vm_state.zig");
const vmnative = @import("../lang/vm_native.zig");
const net_state = @import("../lang/native/net_state.zig");
const cfg = @import("config.zig");
const Value = @import("../lang/value.zig").Value;

fn checkGlobalExists(ctx: *anyopaque, name: []const u8) bool {
    _ = ctx;
    return globals.has(name);
}

const MaxFrames = @import("../runtime/config.zig").max_frames;
const MaxTests = 64;

pub const Runtime = struct {
    policy: vm.Policy = .{},
    host_modules: []const module_compile.HostModuleDesc = &.{},
    enabled_capabilities: []const []const u8 = &.{},
    last_compile_line: u32 = 0,
    last_compile_path_buf: [module_compile.MaxModulePathBytes]u8 = undefined,
    last_compile_path_len: usize = 0,
    last_compile_col: u32 = 0,
    last_compile_msg_buf: [512]u8 = undefined,
    last_compile_msg_len: u16 = 0,
    last_runtime_line: u32 = 0,
    last_runtime_col: u32 = 0,
    last_runtime_msg_buf: [512]u8 = undefined,
    last_runtime_msg_len: u16 = 0,
    panic_frames: [MaxFrames]vm.PanicFrame = undefined,
    panic_depth: usize = 0,
    chunk_state: chunk.State = .{},
    globals_state: globals.State = .{},
    heap_state: heap.State = .{},
    vm_state: vm.State = .{},
    test_count: u8 = 0,
    test_names: [MaxTests][]const u8 = undefined,
    test_failed: bool = false,

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

    // Initialize this Runtime in-place without allocating a large stack temporary.
    // Use this instead of withPolicy() when the Runtime is already heap-allocated
    // or when the shadow stack is too small to hold a temporary copy (e.g. WASM with large presets).
    pub fn initWithPolicy(self: *Runtime, policy: vm.Policy) void {
        initWithConfig(self, policy, heap.HeapSize, heap.MaxObjects, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.heap.page_allocator);
    }

    pub fn initWithConfig(self: *Runtime, policy: vm.Policy, heap_size: usize, max_objects: usize, max_stack: usize, max_frames: usize, max_defers: usize, allocator: std.mem.Allocator) void {
        @memset(std.mem.asBytes(self), 0);
        self.policy = policy;
        self.heap_state.init(heap_size, max_objects, allocator) catch return;
        self.vm_state.init(max_stack, max_frames, max_defers, heap_size, allocator) catch return;
        chunk.setActive(&self.chunk_state);
        globals.setActive(&self.globals_state);
        chunk.reset();
        globals.reset();
        heap.setActive(&self.heap_state);
        vm.setActive(&self.vm_state);
        vm.reset();
        heap.reset();
    }

    pub fn deinit(self: *Runtime) void {
        self.vm_state.deinit();
        self.heap_state.deinit();
    }

    pub fn setPolicy(self: *Runtime, policy: vm.Policy) void {
        self.policy = policy;
    }

    pub fn reset(self: *Runtime) void {
        self.activate();
        net_state.netReset();
        globals.reset();
        vm.reset();
        heap.reset();
        chunk.reset();
    }

    pub fn run(self: *Runtime, src: []const u8) !void {
        return self.runPath(src, "");
    }

    pub fn runPath(self: *Runtime, src: []const u8, path: []const u8) !void {
        return self.runPathWithProvider(src, path, .filesystem, false);
    }

    pub fn runPathWithSources(self: *Runtime, src: []const u8, path: []const u8, sources: []const module_compile.SourceEntry) !void {
        return self.runPathWithProvider(src, path, .{ .table = sources }, false);
    }

    pub fn runPathWithProvider(self: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider, test_mode: bool) !void {
        self.last_compile_line = 0;
        self.last_compile_path_len = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        self.last_runtime_line = 0;
        self.last_runtime_col = 0;
        self.last_runtime_msg_len = 0;
        self.panic_depth = 0;
        self.test_count = 0;
        self.test_failed = false;
        self.reset();
        vm.setPolicy(self.policy);

        const hm_names = blk: {
            const names_ptr = heap.bump([]const u8, self.host_modules.len) orelse return error.OutOfMemory;
            const names = names_ptr[0..self.host_modules.len];
            for (names, self.host_modules) |*n, hm| n.* = hm.name;
            break :blk names;
        };

        const all_caps: []const module_compile.CapModuleDesc = if (self.enabled_capabilities.len > 0) module_compile.AllCapabilities else &[_]module_compile.CapModuleDesc{};
        if (path.len != 0) {
            var session: module_compile.Session = .{};
            session.provider = provider;
            session.host_module_names = hm_names;
            session.enabled_capabilities = self.enabled_capabilities;
            session.capability_modules = all_caps;
            session.test_mode = test_mode;
            session.compileRoot(path, src) catch |err| {
                self.last_compile_line = if (session.last_error_line != 0) session.last_error_line else 1;
                self.last_compile_col = session.last_error_col;
                self.last_compile_msg_len = session.last_error_msg_len;
                @memcpy(self.last_compile_msg_buf[0..session.last_error_msg_len], session.last_error_msg_buf[0..session.last_error_msg_len]);
                self.setLastCompilePath(session.last_error_path);
                return err;
            };
            if (test_mode) {
                self.test_count = session.test_count;
                var ti: usize = 0;
                while (ti < session.test_count) : (ti += 1) {
                    self.test_names[ti] = session.test_names[ti];
                }
            }
        } else {
            var session: module_compile.Session = .{};
            session.provider = provider;
            session.host_module_names = hm_names;
            session.enabled_capabilities = self.enabled_capabilities;
            session.capability_modules = all_caps;
            var compiler = Compiler.init(src, .{
                .module_ctx = &session,
                .resolve_import = module_compile.Session.resolveImportOpaque,
                .test_mode = test_mode,
            });
            compiler.compile(true) catch |err| {
                self.last_compile_line = if (compiler.err_line != 0) compiler.err_line else compiler.prev.line;
                self.last_compile_col = compiler.err_col;
                self.last_compile_msg_len = compiler.err_msg_len;
                @memcpy(self.last_compile_msg_buf[0..compiler.err_msg_len], compiler.err_msg_buf[0..compiler.err_msg_len]);
                self.setLastCompilePath("");
                return err;
            };
            if (test_mode) {
                self.test_count = compiler.test_count;
                var ti: usize = 0;
                while (ti < compiler.test_count) : (ti += 1) {
                    self.test_names[ti] = compiler.test_names[ti];
                }
            }
        }

        try vmnative.installStdGlobal();
        try vmnative.installHostModules(self.host_modules);
        try vmnative.installCapabilityModules(all_caps);
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

        if (test_mode and self.test_count > 0) {
            var passed: u8 = 0;
            var failed: u8 = 0;
            var ti: u8 = 0;
            while (ti < self.test_count) : (ti += 1) {
                var name_buf: [32]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "__test_{d}", .{ti}) catch continue;
                _ = vm.callGlobal(name, &[_]Value{}) catch |err| {
                    failed += 1;
                    io.werr("FAIL: ");
                    io.werr(self.test_names[ti]);
                    io.werr(": ");
                    io.werr(@errorName(err));
                    const emsg = vm.runtimeErrMsg();
                    if (emsg.len > 0) {
                        io.werr(": ");
                        io.werr(emsg);
                    }
                    io.werr("\n");
                    continue;
                };
                passed += 1;
                io.werr("PASS: ");
                io.werr(self.test_names[ti]);
                io.werr("\n");
            }
            io.werr("\n");
            io.writeInt(@intCast(passed));
            io.werr(" passed, ");
            io.writeInt(@intCast(failed));
            io.werr(" failed\n");
            if (failed > 0) self.test_failed = true;
        }
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

        const repl_caps: []const module_compile.CapModuleDesc = if (self.enabled_capabilities.len > 0) module_compile.AllCapabilities else &[_]module_compile.CapModuleDesc{};
        var session: module_compile.Session = .{};
        session.enabled_capabilities = self.enabled_capabilities;
        session.capability_modules = repl_caps;
        var compiler = Compiler.init(src, .{
            .module_ctx = &session,
            .resolve_import = module_compile.Session.resolveImportOpaque,
            .repl_mode = true,
            .check_global_exists = checkGlobalExists,
            .check_global_ctx = @ptrFromInt(1),
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
        try vmnative.installHostModules(self.host_modules);
        try vmnative.installCapabilityModules(repl_caps);
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
