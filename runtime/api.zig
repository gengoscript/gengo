const rt_mod = @import("runtime.zig");
const vm = @import("../lang/vm.zig");
const Value = @import("../lang/value.zig").Value;

pub const Config = struct {
    allow_io: bool = true,
    native_backend: vm.Policy.NativeBackend = .embedded,
    max_ops: ?u64 = null,
};

pub const CompileError = struct {
    line: u32,
    kind: anyerror,
};

pub const RuntimeError = struct {
    kind: anyerror,
};

pub const RuntimeResult = union(enum) {
    ok,
    compile_error: CompileError,
    runtime_error: RuntimeError,
};

pub const Runtime = struct {
    inner: rt_mod.Runtime,

    pub fn init(config: Config) Runtime {
        const inner = rt_mod.Runtime.withPolicy(.{
            .allow_io = config.allow_io,
            .native_backend = config.native_backend,
            .max_ops = config.max_ops,
        });
        return .{ .inner = inner };
    }

    pub fn reset(self: *Runtime) void {
        self.inner.reset();
    }

    pub fn setConfig(self: *Runtime, config: Config) void {
        self.inner.setPolicy(.{
            .allow_io = config.allow_io,
            .native_backend = config.native_backend,
            .max_ops = config.max_ops,
        });
    }

    pub fn run(self: *Runtime, src: []const u8) RuntimeResult {
        self.inner.run(src) catch |err| {
            if (self.inner.last_compile_line != 0) {
                return .{ .compile_error = .{
                    .line = self.inner.last_compile_line,
                    .kind = err,
                } };
            }
            return .{ .runtime_error = .{ .kind = err } };
        };
        return .ok;
    }

    pub fn call(self: *Runtime, name: []const u8, args: []const Value) RuntimeResultWithValue {
        const out = self.inner.callGlobal(name, args) catch |err| {
            return .{ .runtime_error = .{ .kind = err } };
        };
        return .{ .ok = out };
    }
};

pub const RuntimeResultWithValue = union(enum) {
    ok: Value,
    runtime_error: RuntimeError,
};
