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
const fs_state = @import("../lang/native/fs_state.zig");
const native_rand = @import("../lang/native/rand.zig");
const cfg = @import("config.zig");
const Value = @import("../lang/value.zig").Value;

const common = @import("../lang/common.zig");
const ct = @import("../lang/compiler_types.zig");
const MaxGlobals = ct.MaxGlobals;
const MaxTypes = ct.MaxTypes;
const MaxLocals = ct.MaxLocals;
const MaxNamedTypes = ct.MaxNamedTypes;
const NamedTypeBase = @import("../lang/value.zig").NamedTypeBase;
const TypeCheck = ct.TypeCheck;
const PrimType = ct.PrimType;

const MaxReplSyms = MaxTypes + MaxNamedTypes + MaxGlobals;
const ReplSymNameBufSize = MaxNamedTypes * 64 + MaxGlobals * 64;

const ReplSymKind = enum(u8) { struct_type, interface_type, named_type, variant_type, global_func };

// Compact per-symbol record for REPL persistence.  Fields beyond is_cycle are
// only meaningful when kind == .named_type; they are zero for other kinds.
const ReplSymEntry = struct {
    name_offset: u32 = 0,
    name_len: u16 = 0,
    kind: u8 = 0, // ReplSymKind encoded as u8
    base_u8: u8 = 0, // NamedTypeBase as @intFromEnum (named_type only)
    parent_offset: u32 = 0, // byte offset in repl_sym_name_buf; 0 = no parent
    parent_len: u16 = 0, // 0 = no parent
    enum_member_count: u8 = 0,
    scale: u8 = 0,
    enum_member_offset: u32 = 0,
    has_range: bool = false,
    is_cycle: bool = false,
    min: f64 = 0,
    max: f64 = 0,
};

// Compact record for one typed global (assignment-type enforcement across REPL lines).
// named_type_offset/len are only meaningful when tag == 6 (.named TypeCheck).
const ReplTypedGlobalEntry = struct {
    name_offset: u32 = 0,
    named_type_offset: u32 = 0,
    name_len: u16 = 0,
    named_type_len: u16 = 0,
    tag: u8 = 0,
};

// Compact record for one std-import or module-import global (namespace provenance).
// path_offset/len carry the std namespace path for .std_global and the module path
// for .import_global.
const ReplNsKind = enum(u8) { std_global, import_global };
const ReplNsEntry = struct {
    name_offset: u32 = 0,
    path_offset: u32 = 0,
    name_len: u16 = 0,
    path_len: u16 = 0,
    kind: u8 = 0, // ReplNsKind encoded as u8
};

const MaxReplNsEntries = MaxLocals * 2; // up to MaxLocals std + MaxLocals import entries

// All REPL cross-line persistence state, grouped so Runtime can hold it behind
// a single heap pointer instead of ~250 KB of inline arrays (see Runtime.repl).
const ReplPersist = struct {
    const_names: [MaxGlobals][]const u8 = undefined,
    const_name_buf: [MaxGlobals * 64]u8 = undefined,
    const_name_buf_used: usize = 0,
    const_count: usize = 0,

    // REPL type-and-func persistence (unified, for subtype/method duplicate-detection across lines).
    sym_count: usize = 0,
    syms: [MaxReplSyms]ReplSymEntry = undefined,
    sym_name_buf: [ReplSymNameBufSize]u8 = undefined,
    sym_name_buf_used: usize = 0,

    // REPL enum-member persistence: the parent enum's member list must survive
    // across lines so subtype declarations can validate member subsets and so
    // member access resolves. Members are packed as [len:u8][bytes]... per type.
    enum_member_buf: [MaxNamedTypes * 64]u8 = undefined,
    enum_member_buf_used: usize = 0,

    // #73: typed-global persistence — assignment type enforcement across lines.
    typed_global_count: usize = 0,
    typed_globals: [MaxLocals]ReplTypedGlobalEntry = undefined,
    typed_global_name_buf: [MaxLocals * 128]u8 = undefined,
    typed_global_name_buf_used: usize = 0,

    // #74: std/import namespace provenance persistence — unknown-field validation
    ns_count: usize = 0,
    ns_entries: [MaxReplNsEntries]ReplNsEntry = undefined,
    ns_name_buf: [MaxLocals * 128]u8 = undefined,
    ns_name_buf_used: usize = 0,
};

fn checkGlobalExists(ctx: *anyopaque, name: []const u8) bool {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    return self.globals_state.has(name);
}

fn checkGlobalIsConst(ctx: *anyopaque, name: []const u8) bool {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    var i: usize = 0;
    while (i < self.repl.const_count) : (i += 1) {
        if (common.streq(self.repl.const_names[i], name)) return true;
    }
    return false;
}

const MaxFrames = @import("../runtime/config.zig").max_frames;
const MaxTests = ct.MaxTestBlocks;

pub const Runtime = struct {
    policy: vm.Policy = .{},
    host_modules: []const module_compile.HostModuleDesc = &.{},
    enabled_capabilities: []const []const u8 = &.{},
    source_root: []const u8 = "",
    module_roots: []const []const u8 = &.{},
    last_compile_line: u32 = 0,
    last_compile_path_buf: [module_compile.MaxModulePathBytes]u8 = undefined,
    last_compile_path_len: usize = 0,
    last_compile_col: u32 = 0,
    last_compile_msg_buf: [512]u8 = undefined,
    last_compile_msg_len: u16 = 0,
    last_runtime_line: u32 = 0,
    last_runtime_col: u32 = 0,
    last_runtime_path_buf: [module_compile.MaxModulePathBytes]u8 = undefined,
    last_runtime_path_len: usize = 0,
    last_runtime_msg_buf: [512]u8 = undefined,
    last_runtime_msg_len: u16 = 0,
    panic_frames: [MaxFrames]vm.PanicFrame = undefined,
    panic_depth: usize = 0,
    chunk_state: *chunk.State = undefined,
    globals_state: globals.State = .{},
    heap_state: heap.State = .{},
    vm_state: vm.State = .{},
    // Per-runtime cap:fs mount table; activate() points the fs_state module at
    // it. Seeded from the process default so CLI --mount flags (registered
    // before the Runtime exists) carry over.
    fs_mounts: fs_state.EngineState = .{},
    test_count: u16 = 0,
    test_names: [MaxTests][]const u8 = undefined,
    test_failed: bool = false,
    // REPL persistence block. Heap-allocated (like chunk_state) because it is
    // ~250 KB of fixed arrays: keeping it inline made Runtime.init-by-value
    // overflow the WASM shadow stack (api.Runtime.init holds up to three
    // Runtime copies on the stack at once).
    repl: *ReplPersist = undefined,

    pub fn init() Runtime {
        var rt: Runtime = .{};
        const cs = std.heap.page_allocator.create(chunk.State) catch @panic("OOM");
        cs.* = .{};
        rt.chunk_state = cs;
        const rp = std.heap.page_allocator.create(ReplPersist) catch @panic("OOM");
        rp.* = .{};
        rt.repl = rp;
        chunk.setActive(rt.chunk_state);
        globals.setActive(&rt.globals_state);
        rt.chunk_state.reset();
        rt.globals_state.reset();
        heap.setActive(&rt.heap_state);
        vm.setActive(&rt.vm_state);
        rt.vm_state.reset();
        rt.heap_state.reset();
        rt.fs_mounts = fs_state.defaultState().*;
        clearNativeCaches();
        return rt;
    }

    // Reset the process-global native state a fresh Runtime should not
    // inherit. The per-runtime native caches (singleton type objects, regexp
    // pattern cache) live in vm_state.State and are cleared by its reset().
    fn clearNativeCaches() void {
        net_state.netReset();
        native_rand.randResetState();
    }

    pub fn withPolicy(policy: vm.Policy) Runtime {
        var rt = init();
        rt.policy = policy;
        return rt;
    }

    // Initialize this Runtime in-place without allocating a large stack temporary.
    // Use this instead of withPolicy() when the Runtime is already heap-allocated
    // or when the shadow stack is too small to hold a temporary copy (e.g. WASM with large presets).
    pub fn initWithPolicy(self: *Runtime, policy: vm.Policy) !void {
        try initWithConfig(self, policy, heap.HeapSize, heap.MaxObjects, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.heap.page_allocator);
    }

    pub fn initWithConfig(self: *Runtime, policy: vm.Policy, heap_size: usize, max_objects: usize, max_stack: usize, max_frames: usize, max_defers: usize, allocator: std.mem.Allocator) !void {
        const cs = try std.heap.page_allocator.create(chunk.State);
        errdefer std.heap.page_allocator.destroy(cs);
        cs.* = .{};
        const rp = try std.heap.page_allocator.create(ReplPersist);
        errdefer std.heap.page_allocator.destroy(rp);
        rp.* = .{};
        @memset(std.mem.asBytes(self), 0);
        self.chunk_state = cs;
        self.repl = rp;
        self.policy = policy;
        try self.heap_state.init(heap_size, max_objects, allocator);
        try self.vm_state.init(max_stack, max_frames, max_defers, heap_size, allocator);
        chunk.setActive(self.chunk_state);
        globals.setActive(&self.globals_state);
        self.chunk_state.reset();
        self.globals_state.reset();
        heap.setActive(&self.heap_state);
        vm.setActive(&self.vm_state);
        self.vm_state.reset();
        self.heap_state.reset();
        self.fs_mounts = fs_state.defaultState().*;
        fs_state.setActive(&self.fs_mounts);
        clearNativeCaches();
    }

    pub fn deinit(self: *Runtime) void {
        self.vm_state.deinit();
        self.heap_state.deinit();
        std.heap.page_allocator.destroy(self.chunk_state);
        std.heap.page_allocator.destroy(self.repl);
    }

    pub fn setPolicy(self: *Runtime, policy: vm.Policy) void {
        self.policy = policy;
    }

    pub fn reset(self: *Runtime) void {
        defer self.assertNoTempRootLeaks("Runtime.reset");
        self.activate();
        clearNativeCaches();
        self.globals_state.reset();
        self.vm_state.reset();
        self.heap_state.reset();
        self.chunk_state.reset();
        self.repl.sym_count = 0;
        self.repl.sym_name_buf_used = 0;
        self.repl.enum_member_buf_used = 0;
        self.repl.const_count = 0;
        self.repl.const_name_buf_used = 0;
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

    fn capabilityModules(self: *Runtime) []const module_compile.CapModuleDesc {
        return if (self.enabled_capabilities.len > 0) module_compile.AllCapabilities else &[_]module_compile.CapModuleDesc{};
    }

    fn buildHostModuleNames(self: *Runtime) ![]const []const u8 {
        const names_ptr = heap.bump([]const u8, self.host_modules.len) orelse return error.OutOfMemory;
        const names = names_ptr[0..self.host_modules.len];
        for (names, self.host_modules) |*n, hm| n.* = hm.name;
        return names;
    }

    fn initCompileSession(
        self: *Runtime,
        session: *module_compile.Session,
        provider: module_compile.SourceProvider,
        hm_names: []const []const u8,
        caps: []const module_compile.CapModuleDesc,
        test_mode: bool,
    ) void {
        session.* = .{};
        session.provider = provider;
        session.source_root = self.source_root;
        const n = @min(self.module_roots.len, module_compile.MaxModuleRoots);
        @memcpy(session.module_roots_buf[0..n], self.module_roots[0..n]);
        session.module_roots_count = @intCast(n);
        session.host_module_names = hm_names;
        session.host_module_descs = self.host_modules;
        session.enabled_capabilities = self.enabled_capabilities;
        session.capability_modules = caps;
        session.test_mode = test_mode;
    }

    fn recordSessionCompileError(self: *Runtime, session: *const module_compile.Session) void {
        self.last_compile_line = if (session.last_error_line != 0) session.last_error_line else 1;
        self.last_compile_col = session.last_error_col;
        self.last_compile_msg_len = session.last_error_msg_len;
        @memcpy(self.last_compile_msg_buf[0..session.last_error_msg_len], session.last_error_msg_buf[0..session.last_error_msg_len]);
        self.setLastCompilePath(session.last_error_path);
    }

    fn recordCompilerCompileError(self: *Runtime, compiler: *const Compiler, path: []const u8) void {
        self.last_compile_line = if (compiler.err_line != 0) compiler.err_line else compiler.prev.line;
        self.last_compile_col = compiler.err_col;
        self.last_compile_msg_len = compiler.err_msg_len;
        @memcpy(self.last_compile_msg_buf[0..compiler.err_msg_len], compiler.err_msg_buf[0..compiler.err_msg_len]);
        self.setLastCompilePath(path);
    }

    fn copyTestNamesFromSession(self: *Runtime, session: *const module_compile.Session) void {
        self.test_count = session.test_count;
        var ti: usize = 0;
        while (ti < session.test_count) : (ti += 1) {
            self.test_names[ti] = session.test_names[ti];
        }
    }

    fn copyTestNamesFromCompiler(self: *Runtime, compiler: *const Compiler) void {
        self.test_count = compiler.test_count;
        var ti: usize = 0;
        while (ti < compiler.test_count) : (ti += 1) {
            self.test_names[ti] = compiler.test_names[ti];
        }
    }

    fn compileProgram(self: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider, test_mode: bool) !void {
        const hm_names = try self.buildHostModuleNames();
        const caps = self.capabilityModules();
        if (path.len != 0) {
            var session: module_compile.Session = .{};
            self.initCompileSession(&session, provider, hm_names, caps, test_mode);
            session.compileRoot(path, src) catch |err| {
                self.recordSessionCompileError(&session);
                return err;
            };
            if (test_mode) self.copyTestNamesFromSession(&session);
            return;
        }

        var session: module_compile.Session = .{};
        self.initCompileSession(&session, provider, hm_names, caps, test_mode);
        var compiler = Compiler.init(src, .{
            .module_ctx = &session,
            .resolve_import = module_compile.Session.resolveImportOpaque,
            .has_module_export = module_compile.hasModuleExport,
            .resolve_module_type = module_compile.resolveModuleTypeKind,
            .test_mode = test_mode,
        });
        compiler.compile(true) catch |err| {
            self.recordCompilerCompileError(&compiler, "");
            return err;
        };
        if (test_mode) self.copyTestNamesFromCompiler(&compiler);
    }

    pub fn compileOnly(self: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider) !void {
        defer self.assertNoTempRootLeaks("Runtime.compileOnly");
        self.last_compile_line = 0;
        self.last_compile_path_len = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        self.reset();
        try self.compileProgram(src, path, provider, false);
    }

    // Compile and install all native globals (std, host modules, capabilities)
    // but do not execute. After this call, vm.setPolicy(self.policy) and vm.run()
    // together complete what a normal runPath would do. Used by differential testing.
    pub fn compileAndInstall(self: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider) !void {
        defer self.assertNoTempRootLeaks("Runtime.compileAndInstall");
        try self.compileOnly(src, path, provider);
        self.vm_state.setPolicy(self.policy);
        const install_ctx: vms.VMContext = .{ .cs = self.chunk_state, .gs = &self.globals_state, .hs = &self.heap_state, .vs = &self.vm_state };
        try vmnative.installStdGlobal(install_ctx, &self.globals_state);
        try vmnative.installHostModules(install_ctx, &self.globals_state, self.host_modules);
        try vmnative.installCapabilityModules(install_ctx, &self.globals_state, self.capabilityModules());
    }

    pub fn runPathWithProvider(self: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider, test_mode: bool) !void {
        if (src.len > cfg.max_input_bytes) {
            self.vm_state.setRuntimeErr("input exceeds max_input_bytes ({d})", .{cfg.max_input_bytes});
            const emsg = self.vm_state.runtimeErrMsg();
            self.last_runtime_msg_len = @intCast(emsg.len);
            @memcpy(self.last_runtime_msg_buf[0..emsg.len], emsg);
            return error.InputTooLong;
        }
        defer self.assertNoTempRootLeaks("Runtime.runPathWithProvider");
        self.last_compile_line = 0;
        self.last_compile_path_len = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        self.last_runtime_line = 0;
        self.last_runtime_col = 0;
        self.last_runtime_path_len = 0;
        self.last_runtime_msg_len = 0;
        self.panic_depth = 0;
        self.test_count = 0;
        self.test_failed = false;
        self.reset();
        self.vm_state.setPolicy(self.policy);
        try self.compileProgram(src, path, provider, test_mode);

        const install_ctx: vms.VMContext = .{ .cs = self.chunk_state, .gs = &self.globals_state, .hs = &self.heap_state, .vs = &self.vm_state };
        try vmnative.installStdGlobal(install_ctx, &self.globals_state);
        try vmnative.installHostModules(install_ctx, &self.globals_state, self.host_modules);
        try vmnative.installCapabilityModules(install_ctx, &self.globals_state, self.capabilityModules());
        vm.run(.{ .cs = self.chunk_state, .gs = &self.globals_state, .hs = &self.heap_state, .vs = &self.vm_state }) catch |err| {
            self.captureRuntimeError();
            return err;
        };

        if (test_mode and self.test_count > 0) {
            var passed: u8 = 0;
            var failed: u8 = 0;
            var ti: u8 = 0;
            while (ti < self.test_count) : (ti += 1) {
                var name_buf: [32]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "__test_{d}", .{ti}) catch continue;
                _ = vm.callGlobal(.{ .cs = self.chunk_state, .gs = &self.globals_state, .hs = &self.heap_state, .vs = &self.vm_state }, name, &[_]Value{}) catch |err| {
                    failed += 1;
                    io.werr("FAIL: ");
                    io.werr(self.test_names[ti]);
                    io.werr(": ");
                    io.werr(@errorName(err));
                    const emsg = self.vm_state.runtimeErrMsg();
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
        if (src.len > cfg.max_input_bytes) {
            self.vm_state.setRuntimeErr("input exceeds max_input_bytes ({d})", .{cfg.max_input_bytes});
            const emsg = self.vm_state.runtimeErrMsg();
            self.last_runtime_msg_len = @intCast(emsg.len);
            @memcpy(self.last_runtime_msg_buf[0..emsg.len], emsg);
            return error.InputTooLong;
        }
        defer self.assertNoTempRootLeaks("Runtime.runIncremental");
        self.last_compile_line = 0;
        self.last_compile_path_len = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        self.last_runtime_line = 0;
        self.last_runtime_col = 0;
        self.last_runtime_path_len = 0;
        self.last_runtime_msg_len = 0;
        self.panic_depth = 0;
        self.activate();
        self.vm_state.setPolicy(self.policy);
        self.chunk_state.reset();
        self.vm_state.resetExec();

        const repl_caps: []const module_compile.CapModuleDesc = if (self.enabled_capabilities.len > 0) module_compile.AllCapabilities else &[_]module_compile.CapModuleDesc{};
        var session: module_compile.Session = .{};
        session.host_module_descs = self.host_modules;
        session.enabled_capabilities = self.enabled_capabilities;
        session.capability_modules = repl_caps;
        var compiler = Compiler.init(src, .{
            .module_ctx = &session,
            .resolve_import = module_compile.Session.resolveImportOpaque,
            .resolve_module_type = module_compile.resolveModuleTypeKind,
            .repl_mode = true,
            .check_global_exists = checkGlobalExists,
            .check_global_is_const = checkGlobalIsConst,
            .check_global_ctx = self,
        });
        self.restoreReplCompilerState(&compiler);
        compiler.compile(true) catch |err| {
            // Must be nonzero: api.zig classifies compile vs runtime errors by
            // last_compile_line != 0, and a REPL line may carry no token line.
            self.last_compile_line = if (compiler.err_line != 0)
                compiler.err_line
            else if (compiler.prev.line != 0) compiler.prev.line else 1;
            self.last_compile_col = compiler.err_col;
            self.last_compile_msg_len = compiler.err_msg_len;
            @memcpy(self.last_compile_msg_buf[0..compiler.err_msg_len], compiler.err_msg_buf[0..compiler.err_msg_len]);
            self.setLastCompilePath("");
            return err;
        };

        for (compiler.registry.func_buckets) |e| {
            if (!e.occupied or !e.is_const) continue;
            const cname = compiler.registry.global_symbols[e.sub_idx];
            if (!checkGlobalIsConst(self, cname)) {
                if (self.repl.const_count >= MaxGlobals or
                    self.repl.const_name_buf_used + cname.len > self.repl.const_name_buf.len)
                {
                    return self.setReplOverflowError("REPL const table full: too many global const declarations");
                }
                const start = self.repl.const_name_buf_used;
                @memcpy(self.repl.const_name_buf[start .. start + cname.len], cname);
                self.repl.const_names[self.repl.const_count] = self.repl.const_name_buf[start .. start + cname.len];
                self.repl.const_name_buf_used += cname.len;
                self.repl.const_count += 1;
            }
        }

        try self.persistReplCompilerState(&compiler);

        const install_ctx: vms.VMContext = .{ .cs = self.chunk_state, .gs = &self.globals_state, .hs = &self.heap_state, .vs = &self.vm_state };
        try vmnative.installStdGlobal(install_ctx, &self.globals_state);
        try vmnative.installHostModules(install_ctx, &self.globals_state, self.host_modules);
        try vmnative.installCapabilityModules(install_ctx, &self.globals_state, repl_caps);
        vm.run(.{ .cs = self.chunk_state, .gs = &self.globals_state, .hs = &self.heap_state, .vs = &self.vm_state }) catch |err| {
            self.captureRuntimeError();
            return err;
        };
        if (self.vm_state.stack_top > 0) {
            const v = self.vm_state.stack[self.vm_state.stack_top - 1];
            self.vm_state.stack_top -= 1;
            if (v != .null) {
                io.printValue(v);
                io.write("\n");
            }
        }
    }

    pub fn callGlobal(self: *Runtime, name: []const u8, args: []const Value) !Value {
        defer self.assertNoTempRootLeaks("Runtime.callGlobal");
        self.activate();
        self.vm_state.setPolicy(self.policy);
        self.last_compile_line = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        return vm.callGlobal(.{ .cs = self.chunk_state, .gs = &self.globals_state, .hs = &self.heap_state, .vs = &self.vm_state }, name, args) catch |err| {
            self.captureRuntimeError();
            return err;
        };
    }

    fn restoreReplCompilerState(self: *Runtime, compiler: *Compiler) void {
        for (self.repl.syms[0..self.repl.sym_count]) |e| {
            const name = self.repl.sym_name_buf[e.name_offset..][0..e.name_len];
            switch (@as(ReplSymKind, @enumFromInt(e.kind))) {
                .struct_type => compiler.registry.addStructType(name) catch {},
                .interface_type => compiler.registry.addInterfaceType(name) catch {},
                .variant_type => compiler.registry.addVariantType(name) catch {},
                .global_func => compiler.registry.addGlobalFunc(name) catch {},
                .named_type => {
                    const parent_name: ?[]const u8 = if (e.parent_len > 0)
                        self.repl.sym_name_buf[e.parent_offset..][0..e.parent_len]
                    else
                        null;
                    compiler.registry.addNamedType(.{
                        .name = name,
                        .base = @enumFromInt(e.base_u8),
                        .has_range = e.has_range,
                        .is_cycle = e.is_cycle,
                        .scale = e.scale,
                        .min = e.min,
                        .max = e.max,
                        .parent_name = parent_name,
                        .enum_members = self.replEnumMembersAt(&e),
                    }) catch {};
                },
            }
        }
        self.restoreReplTypedGlobals(compiler);
        self.restoreReplNamespaceProvenance(compiler);
    }

    fn restoreReplTypedGlobals(self: *Runtime, compiler: *Compiler) void {
        var ti: usize = 0;
        while (ti < self.repl.typed_global_count and compiler.typed_global_count < MaxLocals) : (ti += 1) {
            const e = self.repl.typed_globals[ti];
            const tc = self.replTypedGlobalTypeCheckAt(e) orelse continue;
            compiler.typed_global_names[compiler.typed_global_count] =
                self.repl.typed_global_name_buf[e.name_offset..][0..e.name_len];
            compiler.typed_global_type_checks[compiler.typed_global_count] = tc;
            compiler.typed_global_count += 1;
        }
    }

    fn restoreReplNamespaceProvenance(self: *Runtime, compiler: *Compiler) void {
        for (self.repl.ns_entries[0..self.repl.ns_count]) |e| {
            switch (@as(ReplNsKind, @enumFromInt(e.kind))) {
                .std_global => {
                    if (compiler.std_module_global_count >= MaxLocals) continue;
                    compiler.std_module_global_names[compiler.std_module_global_count] =
                        self.repl.ns_name_buf[e.name_offset..][0..e.name_len];
                    compiler.std_module_global_paths[compiler.std_module_global_count] =
                        self.repl.ns_name_buf[e.path_offset..][0..e.path_len];
                    compiler.std_module_global_count += 1;
                },
                .import_global => {
                    if (compiler.import_module_global_count >= MaxLocals) continue;
                    compiler.import_module_global_qnames[compiler.import_module_global_count] =
                        self.repl.ns_name_buf[e.name_offset..][0..e.name_len];
                    compiler.import_module_global_paths[compiler.import_module_global_count] =
                        self.repl.ns_name_buf[e.path_offset..][0..e.path_len];
                    compiler.import_module_global_count += 1;
                },
            }
        }
    }

    fn persistReplCompilerState(self: *Runtime, compiler: *const Compiler) !void {
        try self.persistReplSymbols(compiler);
        self.persistReplTypedGlobals(compiler);
        self.persistReplNamespaceProvenance(compiler);
    }

    fn persistReplSymbols(self: *Runtime, compiler: *const Compiler) !void {
        self.repl.sym_count = 0;
        self.repl.sym_name_buf_used = 0;
        self.repl.enum_member_buf_used = 0;

        // Named types (most complex entries: carry full NamedTypeInfo fields)
        var ti: usize = 0;
        while (ti < compiler.registry.named_type_count) : (ti += 1) {
            const ni = compiler.registry.named_types[ti];
            if (self.repl.sym_count >= MaxReplSyms)
                return self.setReplOverflowError("REPL symbol table full: too many type declarations");
            var e: ReplSymEntry = .{ .kind = @intFromEnum(ReplSymKind.named_type) };
            const saved_name = self.saveReplSymName(ni.name) catch
                return self.setReplOverflowError("REPL symbol name buffer full");
            e.name_offset = @intCast(@intFromPtr(saved_name.ptr) - @intFromPtr(&self.repl.sym_name_buf));
            e.name_len = @intCast(saved_name.len);
            e.base_u8 = @intCast(@intFromEnum(ni.base));
            e.has_range = ni.has_range;
            e.is_cycle = ni.is_cycle;
            e.scale = ni.scale;
            e.min = ni.min;
            e.max = ni.max;
            if (ni.parent_name) |pn| {
                const saved_pn = self.saveReplSymName(pn) catch
                    return self.setReplOverflowError("REPL symbol name buffer full");
                e.parent_offset = @intCast(@intFromPtr(saved_pn.ptr) - @intFromPtr(&self.repl.sym_name_buf));
                e.parent_len = @intCast(saved_pn.len);
            }
            if (ni.enum_members) |members| self.saveReplEnumMembersToEntry(&e, members);
            self.repl.syms[self.repl.sym_count] = e;
            self.repl.sym_count += 1;
        }

        // Struct / interface / variant types (name only) — scan type hash
        for (compiler.registry.type_buckets) |e| {
            if (!e.occupied) continue;
            const kind: ReplSymKind = switch (e.kind) {
                .struct_type => .struct_type,
                .interface_type => .interface_type,
                .variant_type => .variant_type,
                .named_error_type => .struct_type, // display as a type in REPL
                .named_type => continue, // handled above
            };
            if (self.repl.sym_count >= MaxReplSyms)
                return self.setReplOverflowError("REPL symbol table full: too many type declarations");
            try self.appendReplSimpleSym(compiler.registry.type_names[e.sub_idx], kind);
        }

        // Global funcs (name only; overflow is graceful — duplicate detection degrades)
        for (compiler.registry.func_buckets) |e| {
            if (!e.occupied or e.is_const) continue;
            if (self.repl.sym_count >= MaxReplSyms) break;
            self.appendReplSimpleSym(compiler.registry.global_symbols[e.sub_idx], .global_func) catch break;
        }
    }

    fn appendReplSimpleSym(self: *Runtime, name: []const u8, kind: ReplSymKind) !void {
        const saved = self.saveReplSymName(name) catch
            return self.setReplOverflowError("REPL symbol name buffer full");
        self.repl.syms[self.repl.sym_count] = .{
            .name_offset = @intCast(@intFromPtr(saved.ptr) - @intFromPtr(&self.repl.sym_name_buf)),
            .name_len = @intCast(saved.len),
            .kind = @intFromEnum(kind),
        };
        self.repl.sym_count += 1;
    }

    fn persistReplTypedGlobals(self: *Runtime, compiler: *const Compiler) void {
        self.repl.typed_global_count = 0;
        self.repl.typed_global_name_buf_used = 0;
        var tgi: usize = 0;
        while (tgi < compiler.typed_global_count) : (tgi += 1) {
            const gname = compiler.typed_global_names[tgi];
            const tc = compiler.typed_global_type_checks[tgi];
            if (self.repl.typed_global_count >= MaxLocals) break;
            const tag = replTypedGlobalTag(tc) orelse continue;
            if (self.repl.typed_global_name_buf_used + gname.len > self.repl.typed_global_name_buf.len) break;
            const gs = self.repl.typed_global_name_buf_used;
            std.mem.copyForwards(u8, self.repl.typed_global_name_buf[gs .. gs + gname.len], gname);
            self.repl.typed_global_name_buf_used += gname.len;
            var e: ReplTypedGlobalEntry = .{
                .name_offset = @intCast(gs),
                .name_len = @intCast(gname.len),
                .named_type_offset = @intCast(gs),
                .named_type_len = 0,
                .tag = tag,
            };
            if (tag == 6) {
                const ntname = tc.named;
                if (self.repl.typed_global_name_buf_used + ntname.len > self.repl.typed_global_name_buf.len) break;
                const ns = self.repl.typed_global_name_buf_used;
                std.mem.copyForwards(u8, self.repl.typed_global_name_buf[ns .. ns + ntname.len], ntname);
                e.named_type_offset = @intCast(ns);
                e.named_type_len = @intCast(ntname.len);
                self.repl.typed_global_name_buf_used += ntname.len;
            }
            self.repl.typed_globals[self.repl.typed_global_count] = e;
            self.repl.typed_global_count += 1;
        }
    }

    fn persistReplNamespaceProvenance(self: *Runtime, compiler: *const Compiler) void {
        self.repl.ns_count = 0;
        self.repl.ns_name_buf_used = 0;
        var si: usize = 0;
        while (si < compiler.std_module_global_count) : (si += 1) {
            const sname = compiler.std_module_global_names[si];
            const spath = compiler.std_module_global_paths[si];
            if (self.repl.ns_count >= MaxReplNsEntries or
                self.repl.ns_name_buf_used + sname.len + spath.len > self.repl.ns_name_buf.len) break;
            const ss = self.repl.ns_name_buf_used;
            std.mem.copyForwards(u8, self.repl.ns_name_buf[ss .. ss + sname.len], sname);
            self.repl.ns_name_buf_used += sname.len;
            const ps = self.repl.ns_name_buf_used;
            std.mem.copyForwards(u8, self.repl.ns_name_buf[ps .. ps + spath.len], spath);
            self.repl.ns_entries[self.repl.ns_count] = .{
                .name_offset = @intCast(ss),
                .name_len = @intCast(sname.len),
                .path_offset = @intCast(ps),
                .path_len = @intCast(spath.len),
                .kind = @intFromEnum(ReplNsKind.std_global),
            };
            self.repl.ns_name_buf_used += spath.len;
            self.repl.ns_count += 1;
        }
        var ii: usize = 0;
        while (ii < compiler.import_module_global_count) : (ii += 1) {
            const qn = compiler.import_module_global_qnames[ii];
            const ip = compiler.import_module_global_paths[ii];
            if (self.repl.ns_count >= MaxReplNsEntries or
                self.repl.ns_name_buf_used + qn.len + ip.len > self.repl.ns_name_buf.len) break;
            const qs = self.repl.ns_name_buf_used;
            std.mem.copyForwards(u8, self.repl.ns_name_buf[qs .. qs + qn.len], qn);
            self.repl.ns_name_buf_used += qn.len;
            const ps = self.repl.ns_name_buf_used;
            std.mem.copyForwards(u8, self.repl.ns_name_buf[ps .. ps + ip.len], ip);
            self.repl.ns_entries[self.repl.ns_count] = .{
                .name_offset = @intCast(qs),
                .name_len = @intCast(qn.len),
                .path_offset = @intCast(ps),
                .path_len = @intCast(ip.len),
                .kind = @intFromEnum(ReplNsKind.import_global),
            };
            self.repl.ns_name_buf_used += ip.len;
            self.repl.ns_count += 1;
        }
    }

    fn captureRuntimeError(self: *Runtime) void {
        self.last_runtime_line = self.vm_state.panicLine();
        self.last_runtime_col = self.vm_state.panicCol();
        const rp = self.vm_state.panicPath();
        self.last_runtime_path_len = @min(rp.len, self.last_runtime_path_buf.len);
        @memcpy(self.last_runtime_path_buf[0..self.last_runtime_path_len], rp[0..self.last_runtime_path_len]);
        const pf = self.vm_state.panicFrames();
        self.panic_depth = pf.len;
        var fi: usize = 0;
        while (fi < pf.len) : (fi += 1) self.panic_frames[fi] = pf[fi];
        const emsg = self.vm_state.runtimeErrMsg();
        self.last_runtime_msg_len = @intCast(emsg.len);
        @memcpy(self.last_runtime_msg_buf[0..emsg.len], emsg);
    }

    fn assertNoTempRootLeaks(self: *Runtime, comptime context: []const u8) void {
        self.activate();
        self.vm_state.assertNoTempRoots(context);
    }

    pub fn activate(self: *Runtime) void {
        chunk.setActive(self.chunk_state);
        globals.setActive(&self.globals_state);
        heap.setActive(&self.heap_state);
        vm.setActive(&self.vm_state);
        fs_state.setActive(&self.fs_mounts);
    }

    pub fn lastCompilePath(self: *Runtime) []const u8 {
        return self.last_compile_path_buf[0..self.last_compile_path_len];
    }

    pub fn lastRuntimePath(self: *Runtime) []const u8 {
        return self.last_runtime_path_buf[0..self.last_runtime_path_len];
    }

    fn setLastCompilePath(self: *Runtime, path: []const u8) void {
        self.last_compile_path_len = @min(path.len, self.last_compile_path_buf.len);
        @memcpy(self.last_compile_path_buf[0..self.last_compile_path_len], path[0..self.last_compile_path_len]);
    }

    fn setReplOverflowError(self: *Runtime, comptime msg: []const u8) error{OutOfMemory} {
        self.last_compile_line = 1;
        self.last_compile_col = 0;
        const len = @min(msg.len, self.last_compile_msg_buf.len);
        @memcpy(self.last_compile_msg_buf[0..len], msg[0..len]);
        self.last_compile_msg_len = @intCast(len);
        return error.OutOfMemory;
    }

    fn replTypedGlobalTypeCheckAt(self: *Runtime, e: ReplTypedGlobalEntry) ?TypeCheck {
        return switch (e.tag) {
            0 => .{ .prim = .int },
            1 => .{ .prim = .float },
            2 => .{ .prim = .decimal },
            3 => .{ .prim = .bool },
            4 => .{ .prim = .string },
            5 => .{ .prim = .rune },
            6 => .{ .named = self.repl.typed_global_name_buf[e.named_type_offset..][0..e.named_type_len] },
            7 => .{ .assert_arr = null },
            8 => .{ .assert_map = null },
            9 => .{ .assert_err = {} },
            10 => .{ .prim = .bigint },
            else => null,
        };
    }

    fn replTypedGlobalTag(tc: TypeCheck) ?u8 {
        return switch (tc) {
            .prim => |p| switch (p) {
                .int => 0,
                .float => 1,
                .decimal => 2,
                .bool => 3,
                .string => 4,
                .rune => 5,
                .bigint => 10,
            },
            .named => 6,
            .assert_arr => 7,
            .assert_map => 8,
            .assert_err => 9,
            .interface_type, .struct_type, .none, .anon_typed => null,
        };
    }

    // Always reserve and copy even when the name already lives in this buffer:
    // persist compacts from offset 0, and an unreserved reused slice gets
    // clobbered by the next name written over its bytes.  Persist order
    // preserves relative order, so an in-buffer source is always at or ahead
    // of its destination — copyForwards handles the overlap correctly.
    fn saveReplSymName(self: *Runtime, name: []const u8) ![]const u8 {
        if (self.repl.sym_name_buf_used + name.len > self.repl.sym_name_buf.len) return error.OutOfMemory;
        const start = self.repl.sym_name_buf_used;
        std.mem.copyForwards(u8, self.repl.sym_name_buf[start .. start + name.len], name);
        self.repl.sym_name_buf_used += name.len;
        return self.repl.sym_name_buf[start .. start + name.len];
    }

    // Pack an enum type's member names as [len:u8][bytes]... into repl_enum_member_buf
    // and record the offset/count in the entry.  On overflow the entry retains
    // zero members (graceful: validation simply can't run for that type next line).
    fn saveReplEnumMembersToEntry(self: *Runtime, e: *ReplSymEntry, members: []const []const u8) void {
        if (members.len == 0 or members.len > 255) return;
        var needed: usize = 0;
        for (members) |m| {
            if (m.len > 255) return;
            needed += 1 + m.len;
        }
        if (self.repl.enum_member_buf_used + needed > self.repl.enum_member_buf.len) return;
        const start = self.repl.enum_member_buf_used;
        var pos = start;
        for (members) |m| {
            self.repl.enum_member_buf[pos] = @intCast(m.len);
            pos += 1;
            std.mem.copyForwards(u8, self.repl.enum_member_buf[pos .. pos + m.len], m);
            pos += m.len;
        }
        self.repl.enum_member_buf_used = pos;
        e.enum_member_offset = @intCast(start);
        e.enum_member_count = @intCast(members.len);
    }

    // Rebuild the []const []const u8 member slice for the given entry.
    // The outer array is bump-allocated on the (REPL-persistent) heap; inner
    // slices point back into repl_enum_member_buf.
    fn replEnumMembersAt(self: *Runtime, e: *const ReplSymEntry) ?[]const []const u8 {
        const count = e.enum_member_count;
        if (count == 0) return null;
        const out = heap.bump([]const u8, count) orelse return null;
        var pos: usize = e.enum_member_offset;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const len = self.repl.enum_member_buf[pos];
            pos += 1;
            out[i] = self.repl.enum_member_buf[pos .. pos + len];
            pos += len;
        }
        return out[0..count];
    }
};
