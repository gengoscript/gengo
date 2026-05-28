const Compiler = @import("../lang/compiler.zig").Compiler;
const chunk = @import("../lang/chunk.zig");
const globals = @import("../lang/globals.zig");
const heap = @import("heap.zig");
const vm = @import("../lang/vm.zig");
const Value = @import("../lang/value.zig").Value;

pub const Runtime = struct {
    policy: vm.Policy = .{},
    last_compile_line: u32 = 0,
    chunk_state: chunk.State = undefined,
    globals_state: globals.State = undefined,
    heap_state: heap.State = undefined,
    vm_state: vm.State = undefined,

    pub fn init() Runtime {
        chunk.reset();
        globals.reset();
        vm.reset();
        heap.reset();
        return .{
            .chunk_state = chunk.snapshot(),
            .globals_state = globals.snapshot(),
            .heap_state = heap.snapshot(),
            .vm_state = vm.snapshot(),
        };
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
        self.capture();
    }

    pub fn run(self: *Runtime, src: []const u8) !void {
        self.last_compile_line = 0;
        self.reset();
        self.activate();
        defer self.capture();
        vm.setPolicy(self.policy);

        var compiler = Compiler.init(src);
        compiler.compile() catch |err| {
            self.last_compile_line = compiler.prev.line;
            return err;
        };

        try vm.run();
    }

    pub fn callGlobal(self: *Runtime, name: []const u8, args: []const Value) !Value {
        self.activate();
        defer self.capture();
        vm.setPolicy(self.policy);
        return vm.callGlobal(name, args);
    }

    fn activate(self: *Runtime) void {
        chunk.restore(self.chunk_state);
        globals.restore(self.globals_state);
        heap.restore(self.heap_state);
        vm.restore(self.vm_state);
    }

    fn capture(self: *Runtime) void {
        self.chunk_state = chunk.snapshot();
        self.globals_state = globals.snapshot();
        self.heap_state = heap.snapshot();
        self.vm_state = vm.snapshot();
    }
};
