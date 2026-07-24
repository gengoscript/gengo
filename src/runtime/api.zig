const std = @import("std");
const rt_mod = @import("runtime.zig");
const vm = @import("../lang/vm.zig");
const heap = @import("heap.zig");
const Value = @import("../lang/value.zig").Value;
pub const SourceEntry = @import("../lang/module_compile.zig").SourceEntry;
pub const SourceProvider = @import("../lang/module_compile.zig").SourceProvider;
pub const HostModuleFuncDesc = @import("../lang/module_compile.zig").HostModuleFuncDesc;
pub const HostModuleDesc = @import("../lang/module_compile.zig").HostModuleDesc;

const fs_state = @import("../lang/native/fs_state.zig");
pub const FsMount = fs_state.Mount;

/// Register the host directories visible to cap:fs scripts. Targets the
/// active mount table: the most recently initialized/activated Runtime's
/// table, or the process default (inherited by Runtimes created later) when
/// called before any Runtime exists. For explicit per-runtime control use
/// `Runtime.setFsMounts`. Replaces any previously registered mounts.
pub fn setFsMounts(mounts: []const FsMount) fs_state.MountError!void {
    try fs_state.setMounts(mounts);
}

const MaxFrames = @import("runtime_config").max_frames;
const cfg = @import("runtime_config");

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
    // Import sandbox: leave source_root empty for unrestricted access (default for
    // embedding). Set to the entry script's directory for user-facing runtimes; add
    // extra allowed trees via module_roots (e.g. shared library paths).
    source_root: []const u8 = "",
    module_roots: []const []const u8 = &.{},
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
    path: []const u8 = "",
    msg: []const u8 = "",
    frames: [MaxFrames]vm.PanicFrame = undefined,
    frame_count: usize = 0,
};

pub const RuntimeResult = union(enum) {
    ok,
    compile_error: CompileError,
    runtime_error: RuntimeError,
};

pub const ExecutionResult = union(enum) {
    completed,
    suspended,
    compile_error: CompileError,
    runtime_error: RuntimeError,
};

pub const Runtime = struct {
    inner: rt_mod.Runtime,
    module_sources: []const SourceEntry = &.{},
    module_source_provider: ?SourceProvider = null,
    source_root: []const u8 = "",
    module_roots: []const []const u8 = &.{},
    host_modules: []const HostModuleDesc = &.{},
    capabilities: []const []const u8 = &.{},

    fn policyFromConfig(config: Config) vm.Policy {
        return .{
            .allow_io = config.allow_io,
            .native_backend = config.native_backend,
            .max_ops = config.max_ops,
            .enable_predicates = config.enable_predicates,
        };
    }

    fn applyConfigState(self: *Runtime, config: Config) void {
        self.inner.host_modules = config.host_modules;
        self.inner.enabled_capabilities = config.capabilities;
        self.inner.source_root = config.source_root;
        self.inner.module_roots = config.module_roots;
        self.module_sources = config.module_sources;
        self.module_source_provider = config.module_source_provider;
        self.source_root = config.source_root;
        self.module_roots = config.module_roots;
        self.host_modules = config.host_modules;
        self.capabilities = config.capabilities;
    }

    fn classifyRunResult(self: *Runtime, err: anyerror) RuntimeResult {
        if (self.inner.last_compile_line != 0) {
            var ce = compileError(err, &self.inner);
            if (err == error.OutOfMemory) ce.msg = "heap too small";
            return .{ .compile_error = ce };
        }
        var re = runtimeError(err, &self.inner);
        if (err == error.OutOfMemory) re.msg = "heap exhausted";
        return .{ .runtime_error = re };
    }

    fn mapExecutionOutcome(outcome: vm.RunOutcome) ExecutionResult {
        return switch (outcome) {
            .completed => .completed,
            .suspended => .suspended,
        };
    }

    fn suspendedRunResult(self: *Runtime) RuntimeResult {
        return .{ .runtime_error = runtimeError(error.ExecutionSuspended, &self.inner) };
    }

    pub fn init(config: Config) !Runtime {
        var inner: rt_mod.Runtime = undefined;
        try inner.initWithConfig(
            policyFromConfig(config),
            config.heap_size_bytes,
            config.max_objects,
            config.max_stack,
            config.max_frames,
            config.max_defers,
            config.allocator,
        );
        var rt: Runtime = .{
            .inner = inner,
        };
        rt.applyConfigState(config);
        return rt;
    }

    // In-place initializer: no large stack temporary. Use when the Runtime is
    // heap-allocated and the shadow stack cannot hold a full Runtime value.
    pub fn initWithPolicy(self: *Runtime, config: Config) !void {
        try self.inner.initWithConfig(
            policyFromConfig(config),
            config.heap_size_bytes,
            config.max_objects,
            config.max_stack,
            config.max_frames,
            config.max_defers,
            config.allocator,
        );
        self.applyConfigState(config);
    }

    pub fn deinit(self: *Runtime) void {
        self.inner.deinit();
    }

    pub fn reset(self: *Runtime) void {
        self.inner.reset();
    }

    pub fn setConfig(self: *Runtime, config: Config) void {
        self.inner.setPolicy(policyFromConfig(config));
        self.applyConfigState(config);
    }

    /// Register the host directories visible to cap:fs scripts in this
    /// Runtime only. Replaces any previously registered mounts.
    pub fn setFsMounts(self: *Runtime, mounts: []const FsMount) fs_state.MountError!void {
        self.inner.fs_mounts.clear();
        for (mounts) |m| try fs_state.addMountToState(&self.inner.fs_mounts, m.name, m.real);
    }

    pub fn run(self: *Runtime, src: []const u8) RuntimeResult {
        // Route through the configured source provider like runPath does:
        // module_sources / module_source_provider from setConfig (bundles,
        // import loaders) must be visible to plain run() too — inner.run
        // would hardcode the filesystem provider.
        const outcome = self.inner.runPathWithProvider(src, "", defaultSourceProvider(self), false) catch |err| {
            return self.classifyRunResult(err);
        };
        return switch (outcome) {
            .completed => .ok,
            .suspended => self.suspendedRunResult(),
        };
    }

    pub fn begin(self: *Runtime, src: []const u8) ExecutionResult {
        const outcome = self.inner.begin(src) catch |err| {
            const result = self.classifyRunResult(err);
            return switch (result) {
                .compile_error => |e| .{ .compile_error = e },
                .runtime_error => |e| .{ .runtime_error = e },
                .ok => unreachable,
            };
        };
        return mapExecutionOutcome(outcome);
    }

    pub fn continueRun(self: *Runtime) ExecutionResult {
        const outcome = self.inner.continueRun() catch |err| {
            return .{ .runtime_error = runtimeError(err, &self.inner) };
        };
        return mapExecutionOutcome(outcome);
    }

    pub fn runPath(self: *Runtime, src: []const u8, path: []const u8) RuntimeResult {
        const outcome = self.inner.runPathWithProvider(src, path, defaultSourceProvider(self), false) catch |err| {
            return self.classifyRunResult(err);
        };
        return switch (outcome) {
            .completed => .ok,
            .suspended => self.suspendedRunResult(),
        };
    }

    pub fn runPathWithSources(self: *Runtime, src: []const u8, path: []const u8, sources: []const SourceEntry) RuntimeResult {
        const outcome = self.inner.runPathWithSources(src, path, sources) catch |err| {
            return self.classifyRunResult(err);
        };
        return switch (outcome) {
            .completed => .ok,
            .suspended => self.suspendedRunResult(),
        };
    }

    pub fn runPathWithSourceProvider(self: *Runtime, src: []const u8, path: []const u8, provider: SourceProvider) RuntimeResult {
        const outcome = self.inner.runPathWithProvider(src, path, provider, false) catch |err| {
            return self.classifyRunResult(err);
        };
        return switch (outcome) {
            .completed => .ok,
            .suspended => self.suspendedRunResult(),
        };
    }

    pub fn call(self: *Runtime, name: []const u8, args: []const Value) RuntimeResultWithValue {
        const out = self.inner.callGlobal(name, args) catch |err| {
            return .{ .runtime_error = runtimeError(err, &self.inner) };
        };
        return .{ .ok = out };
    }

    pub fn runIncremental(self: *Runtime, src: []const u8) RuntimeResult {
        self.inner.runIncremental(src) catch |err| {
            return self.classifyRunResult(err);
        };
        return .ok;
    }

    pub fn heapUsedBytes(self: *Runtime) usize {
        return self.inner.heap_state.usedBytes();
    }

    pub fn heapTotalFreeListBytes(self: *Runtime) usize {
        return self.inner.heap_state.totalFreeListBytes();
    }

    pub fn heapFragmentationInfo(self: *Runtime) HeapFragmentationInfo {
        const info = self.inner.heap_state.fragmentationInfo();
        return .{ .free_bytes = info.free_bytes, .largest_block = info.largest_block };
    }

    pub fn heapFreeListSummary(self: *Runtime, buf: []u8) []u8 {
        return self.inner.heap_state.freeListSummary(buf);
    }

    pub fn heapLiveObjectCount(self: *Runtime) usize {
        return self.inner.heap_state.liveObjectCount();
    }
};

pub const HeapFragmentationInfo = struct { free_bytes: usize, largest_block: usize };

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
        .path = rt.lastRuntimePath(),
        .msg = if (rt.last_runtime_msg_len > 0) rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len] else "",
        .frame_count = rt.panic_depth,
    };
    var fi: usize = 0;
    while (fi < rt.panic_depth) : (fi += 1) e.frames[fi] = rt.panic_frames[fi];
    return e;
}
