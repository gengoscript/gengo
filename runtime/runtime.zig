const Compiler = @import("../lang/compiler.zig").Compiler;
const globals = @import("../lang/globals.zig");
const heap = @import("heap.zig");
const vm = @import("../lang/vm.zig");

pub const Runtime = struct {
    policy: vm.Policy = .{},
    last_compile_line: u32 = 0,

    pub fn init() Runtime {
        return .{};
    }

    pub fn withPolicy(policy: vm.Policy) Runtime {
        return .{ .policy = policy };
    }

    pub fn setPolicy(self: *Runtime, policy: vm.Policy) void {
        self.policy = policy;
    }

    pub fn reset(self: *Runtime) void {
        _ = self;
        globals.reset();
        vm.reset();
        heap.reset();
    }

    pub fn run(self: *Runtime, src: []const u8) !void {
        self.last_compile_line = 0;
        self.reset();
        vm.setPolicy(self.policy);

        var compiler = Compiler.init(src);
        compiler.compile() catch |err| {
            self.last_compile_line = compiler.prev.line;
            return err;
        };

        try vm.run();
    }
};
