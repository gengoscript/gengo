const std = @import("std");
const rt_mod = @import("runtime.zig");
const vm = @import("../lang/vm.zig");
const Value = @import("../lang/value.zig").Value;
pub const SourceEntry = @import("../lang/module_compile.zig").SourceEntry;
pub const SourceProvider = @import("../lang/module_compile.zig").SourceProvider;
pub const HostModuleFuncDesc = @import("../lang/module_compile.zig").HostModuleFuncDesc;
pub const HostModuleDesc = @import("../lang/module_compile.zig").HostModuleDesc;

const fs_state = @import("../lang/native/fs_state.zig");
pub const FsMount = fs_state.Mount;

/// Register the host directories visible to cap:fs scripts. Mounts are
/// process-global (cap:fs has no per-runtime state); call once before
/// running scripts. Replaces any previously registered mounts.
pub fn setFsMounts(mounts: []const FsMount) fs_state.MountError!void {
    try fs_state.setMounts(mounts);
}

const MaxFrames = @import("config.zig").max_frames;
const cfg = @import("config.zig");

pub const Config = struct {
    allow_io: bool = true,
    native_backend: vm.Policy.NativeBackend = .embedded,
    max_ops: ?u64 = null,
    enable_predicates: bool = true,
    heap_size_bytes: usize = cfg.heap_size_bytes,
    max_objects: usize = cfg.max_objects,
    max_stack: usize = cfg.max_stack,
    max_frames: usize = cfg.max_frames,
    max_defers: usize = cfg.max_defers,
    module_sources: []const SourceEntry = &.{},
    module_source_provider: ?SourceProvider = null,
    host_modules: []const HostModuleDesc = &.{},
    capabilities: []const []const u8 = &.{},
    allocator: std.mem.Allocator = std.heap.page_allocator,
};

pub const CompileError = struct {
    line: u32,
    col: u32 = 0,
    kind: anyerror,
    msg: []const u8 = "",
};

pub const RuntimeError = struct {
    kind: anyerror,
    line: u32 = 0,
    col: u32 = 0,
    msg: []const u8 = "",
    frames: [MaxFrames]vm.PanicFrame = undefined,
    frame_count: usize = 0,
};

pub const RuntimeResult = union(enum) {
    ok,
    compile_error: CompileError,
    runtime_error: RuntimeError,
};

pub const Runtime = struct {
    inner: rt_mod.Runtime,
    module_sources: []const SourceEntry = &.{},
    module_source_provider: ?SourceProvider = null,
    host_modules: []const HostModuleDesc = &.{},
    capabilities: []const []const u8 = &.{},

    pub fn init(config: Config) !Runtime {
        var inner: rt_mod.Runtime = undefined;
        try inner.initWithConfig(
            .{
                .allow_io = config.allow_io,
                .native_backend = config.native_backend,
                .max_ops = config.max_ops,
                .enable_predicates = config.enable_predicates,
            },
            config.heap_size_bytes,
            config.max_objects,
            config.max_stack,
            config.max_frames,
            config.max_defers,
            config.allocator,
        );
        inner.host_modules = config.host_modules;
        inner.enabled_capabilities = config.capabilities;
        return .{
            .inner = inner,
            .module_sources = config.module_sources,
            .module_source_provider = config.module_source_provider,
            .host_modules = config.host_modules,
            .capabilities = config.capabilities,
        };
    }

    // In-place initializer: no large stack temporary. Use when the Runtime is
    // heap-allocated and the shadow stack cannot hold a full Runtime value.
    pub fn initWithPolicy(self: *Runtime, config: Config) !void {
        try self.inner.initWithConfig(
            .{
                .allow_io = config.allow_io,
                .native_backend = config.native_backend,
                .max_ops = config.max_ops,
                .enable_predicates = config.enable_predicates,
            },
            config.heap_size_bytes,
            config.max_objects,
            config.max_stack,
            config.max_frames,
            config.max_defers,
            config.allocator,
        );
        self.inner.host_modules = config.host_modules;
        self.inner.enabled_capabilities = config.capabilities;
        self.module_sources = config.module_sources;
        self.module_source_provider = config.module_source_provider;
        self.host_modules = config.host_modules;
        self.capabilities = config.capabilities;
    }

    pub fn deinit(self: *Runtime) void {
        self.inner.deinit();
    }

    pub fn reset(self: *Runtime) void {
        self.inner.reset();
    }

    pub fn setConfig(self: *Runtime, config: Config) void {
        self.inner.setPolicy(.{
            .allow_io = config.allow_io,
            .native_backend = config.native_backend,
            .max_ops = config.max_ops,
            .enable_predicates = config.enable_predicates,
        });
        self.inner.host_modules = config.host_modules;
        self.inner.enabled_capabilities = config.capabilities;
        self.module_sources = config.module_sources;
        self.module_source_provider = config.module_source_provider;
        self.host_modules = config.host_modules;
        self.capabilities = config.capabilities;
    }

    pub fn run(self: *Runtime, src: []const u8) RuntimeResult {
        self.inner.run(src) catch |err| {
            if (self.inner.last_compile_line != 0) {
                return .{ .compile_error = compileError(err, &self.inner) };
            }
            return .{ .runtime_error = runtimeError(err, &self.inner) };
        };
        return .ok;
    }

    pub fn runPath(self: *Runtime, src: []const u8, path: []const u8) RuntimeResult {
        self.inner.runPathWithProvider(src, path, defaultSourceProvider(self), false) catch |err| {
            if (self.inner.last_compile_line != 0) {
                return .{ .compile_error = compileError(err, &self.inner) };
            }
            return .{ .runtime_error = runtimeError(err, &self.inner) };
        };
        return .ok;
    }

    pub fn runPathWithSources(self: *Runtime, src: []const u8, path: []const u8, sources: []const SourceEntry) RuntimeResult {
        self.inner.runPathWithSources(src, path, sources) catch |err| {
            if (self.inner.last_compile_line != 0) {
                return .{ .compile_error = compileError(err, &self.inner) };
            }
            return .{ .runtime_error = runtimeError(err, &self.inner) };
        };
        return .ok;
    }

    pub fn runPathWithSourceProvider(self: *Runtime, src: []const u8, path: []const u8, provider: SourceProvider) RuntimeResult {
        self.inner.runPathWithProvider(src, path, provider, false) catch |err| {
            if (self.inner.last_compile_line != 0) {
                return .{ .compile_error = compileError(err, &self.inner) };
            }
            return .{ .runtime_error = runtimeError(err, &self.inner) };
        };
        return .ok;
    }

    pub fn call(self: *Runtime, name: []const u8, args: []const Value) RuntimeResultWithValue {
        const out = self.inner.callGlobal(name, args) catch |err| {
            return .{ .runtime_error = runtimeError(err, &self.inner) };
        };
        return .{ .ok = out };
    }

    pub fn runIncremental(self: *Runtime, src: []const u8) RuntimeResult {
        self.inner.runIncremental(src) catch |err| {
            if (self.inner.last_compile_line != 0) {
                return .{ .compile_error = compileError(err, &self.inner) };
            }
            return .{ .runtime_error = runtimeError(err, &self.inner) };
        };
        return .ok;
    }
};

pub const RuntimeResultWithValue = union(enum) {
    ok: Value,
    runtime_error: RuntimeError,
};

fn defaultSourceProvider(self: *const Runtime) SourceProvider {
    if (self.module_source_provider) |provider| return provider;
    if (self.module_sources.len != 0) return .{ .table = self.module_sources };
    return .filesystem;
}

fn compileError(err: anyerror, rt: *rt_mod.Runtime) CompileError {
    return .{
        .line = rt.last_compile_line,
        .col = rt.last_compile_col,
        .kind = err,
        .msg = if (rt.last_compile_msg_len > 0) rt.last_compile_msg_buf[0..rt.last_compile_msg_len] else "",
    };
}

fn runtimeError(err: anyerror, rt: *rt_mod.Runtime) RuntimeError {
    var e = RuntimeError{
        .kind = err,
        .line = rt.last_runtime_line,
        .col = rt.last_runtime_col,
        .msg = if (rt.last_runtime_msg_len > 0) rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len] else "",
        .frame_count = rt.panic_depth,
    };
    var fi: usize = 0;
    while (fi < rt.panic_depth) : (fi += 1) e.frames[fi] = rt.panic_frames[fi];
    return e;
}
