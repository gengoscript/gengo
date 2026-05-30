const Compiler = @import("../lang/compiler.zig").Compiler;
const chunk = @import("../lang/chunk.zig");
const globals = @import("../lang/globals.zig");
const heap = @import("heap.zig");
const vm = @import("../lang/vm.zig");
const Value = @import("../lang/value.zig").Value;

const MaxFrames = @import("../runtime/config.zig").max_frames;

pub const Runtime = struct {
    policy: vm.Policy = .{},
    last_compile_line: u32 = 0,
    last_runtime_line: u32 = 0,
    last_runtime_col: u16 = 0,
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
        self.last_compile_line = 0;
        self.last_runtime_line = 0;
        self.reset();
        vm.setPolicy(self.policy);

        var compiler = Compiler.init(src);
        compiler.compile() catch |err| {
            self.last_compile_line = compiler.prev.line;
            return err;
        };

        vm.run() catch |err| {
            self.last_runtime_line = vm.panicLine();
            self.last_runtime_col = vm.panicCol();
            const pf = vm.panicFrames();
            self.panic_depth = pf.len;
            var fi: usize = 0;
            while (fi < pf.len) : (fi += 1) self.panic_frames[fi] = pf[fi];
            return err;
        };
    }

    // Run src without resetting globals or heap — allows successive REPL lines
    // to share definitions and allocated objects.
    pub fn runIncremental(self: *Runtime, src: []const u8) !void {
        self.last_compile_line = 0;
        self.last_runtime_line = 0;
        self.activate();
        vm.setPolicy(self.policy);
        chunk.reset();
        vm.resetExec();

        var compiler = Compiler.init(src);
        compiler.compile() catch |err| {
            self.last_compile_line = compiler.prev.line;
            return err;
        };

        vm.run() catch |err| {
            self.last_runtime_line = vm.panicLine();
            self.last_runtime_col = vm.panicCol();
            const pf = vm.panicFrames();
            self.panic_depth = pf.len;
            var fi: usize = 0;
            while (fi < pf.len) : (fi += 1) self.panic_frames[fi] = pf[fi];
            return err;
        };
    }

    pub fn callGlobal(self: *Runtime, name: []const u8, args: []const Value) !Value {
        self.activate();
        vm.setPolicy(self.policy);
        return vm.callGlobal(name, args) catch |err| {
            self.last_runtime_line = vm.panicLine();
            self.last_runtime_col = vm.panicCol();
            const pf = vm.panicFrames();
            self.panic_depth = pf.len;
            var fi: usize = 0;
            while (fi < pf.len) : (fi += 1) self.panic_frames[fi] = pf[fi];
            return err;
        };
    }

    fn activate(self: *Runtime) void {
        chunk.setActive(&self.chunk_state);
        globals.setActive(&self.globals_state);
        heap.setActive(&self.heap_state);
        vm.setActive(&self.vm_state);
    }

};
