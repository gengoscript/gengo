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
const native_time = @import("../lang/native/time.zig");
const native_regexp = @import("../lang/native/regexp.zig");
const native_rand = @import("../lang/native/rand.zig");
const cfg = @import("config.zig");
const Value = @import("../lang/value.zig").Value;

const common = @import("../lang/common.zig");
const ct = @import("../lang/compiler_types.zig");
const MaxGlobalConsts = ct.MaxGlobalConsts;
const MaxGlobalFuncs = ct.MaxGlobalFuncs;
const MaxLocals = ct.MaxLocals;
const MaxNamedTypes = ct.MaxNamedTypes;
const MaxStructTypes = ct.MaxStructTypes;
const MaxInterfaceTypes = ct.MaxInterfaceTypes;
const MaxVariantTypes = ct.MaxVariantTypes;
const NamedTypeBase = @import("../lang/value.zig").NamedTypeBase;
const TypeCheck = ct.TypeCheck;
const PrimType = ct.PrimType;

fn checkGlobalExists(ctx: *anyopaque, name: []const u8) bool {
    _ = ctx;
    return globals.has(name);
}

fn checkGlobalIsConst(ctx: *anyopaque, name: []const u8) bool {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    var i: usize = 0;
    while (i < self.repl_const_count) : (i += 1) {
        if (common.streq(self.repl_const_names[i], name)) return true;
    }
    return false;
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
    chunk_state: *chunk.State = undefined,
    globals_state: globals.State = .{},
    heap_state: heap.State = .{},
    vm_state: vm.State = .{},
    test_count: u8 = 0,
    test_names: [MaxTests][]const u8 = undefined,
    test_failed: bool = false,
    repl_const_names: [MaxGlobalConsts][]const u8 = undefined,
    repl_const_name_buf: [MaxGlobalConsts * 64]u8 = undefined,
    repl_const_name_buf_used: usize = 0,
    repl_const_count: usize = 0,

    // REPL named-type persistence (for subtype/typed-var resolution across lines)
    repl_named_type_count: usize = 0,
    repl_named_type_name_offsets: [MaxNamedTypes]u32 = undefined,
    repl_named_type_name_lens: [MaxNamedTypes]u16 = undefined,
    repl_named_type_bases: [MaxNamedTypes]NamedTypeBase = undefined,
    repl_named_type_has_ranges: [MaxNamedTypes]bool = undefined,
    repl_named_type_is_cycles: [MaxNamedTypes]bool = undefined,
    repl_named_type_scales: [MaxNamedTypes]u8 = undefined,
    repl_named_type_mins: [MaxNamedTypes]f64 = undefined,
    repl_named_type_maxs: [MaxNamedTypes]f64 = undefined,
    repl_named_type_parent_offsets: [MaxNamedTypes]u32 = undefined,
    repl_named_type_parent_lens: [MaxNamedTypes]u16 = undefined,
    repl_struct_type_count: usize = 0,
    repl_struct_type_name_offsets: [MaxStructTypes]u32 = undefined,
    repl_struct_type_name_lens: [MaxStructTypes]u16 = undefined,
    repl_interface_type_count: usize = 0,
    repl_interface_type_name_offsets: [MaxInterfaceTypes]u32 = undefined,
    repl_interface_type_name_lens: [MaxInterfaceTypes]u16 = undefined,
    repl_variant_type_count: usize = 0,
    repl_variant_type_name_offsets: [MaxVariantTypes]u32 = undefined,
    repl_variant_type_name_lens: [MaxVariantTypes]u16 = undefined,
    repl_type_name_buf: [MaxNamedTypes * 64]u8 = undefined,
    repl_type_name_buf_used: usize = 0,

    // REPL enum-member persistence: the parent enum's member list must survive
    // across lines so subtype declarations can validate member subsets and so
    // member access resolves. Members are packed as [len:u8][bytes]... per type.
    repl_named_type_enum_member_counts: [MaxNamedTypes]u8 = undefined,
    repl_named_type_enum_member_offsets: [MaxNamedTypes]u32 = undefined,
    repl_enum_member_buf: [MaxNamedTypes * 64]u8 = undefined,
    repl_enum_member_buf_used: usize = 0,

    // #72: global-func persistence — function/method duplicate detection across lines
    repl_global_func_count: usize = 0,
    repl_global_func_name_offsets: [MaxGlobalFuncs]u32 = undefined,
    repl_global_func_name_lens: [MaxGlobalFuncs]u16 = undefined,
    repl_global_func_name_buf: [MaxGlobalFuncs * 64]u8 = undefined,
    repl_global_func_name_buf_used: usize = 0,

    // #73: typed-global persistence — assignment type enforcement across lines.
    // Tags: 0=prim_int 1=prim_float 2=prim_decimal 3=prim_bool 4=prim_string
    //       5=prim_rune 6=named 7=assert_arr 8=assert_map 9=assert_err
    repl_typed_global_count: usize = 0,
    repl_typed_global_name_offsets: [MaxLocals]u32 = undefined,
    repl_typed_global_name_lens: [MaxLocals]u16 = undefined,
    repl_typed_global_named_type_offsets: [MaxLocals]u32 = undefined,
    repl_typed_global_named_type_lens: [MaxLocals]u16 = undefined,
    repl_typed_global_tags: [MaxLocals]u8 = undefined,
    repl_typed_global_name_buf: [MaxLocals * 128]u8 = undefined,
    repl_typed_global_name_buf_used: usize = 0,

    // #74: std/import namespace provenance persistence — unknown-field validation
    repl_std_global_count: usize = 0,
    repl_std_global_name_offsets: [MaxLocals]u32 = undefined,
    repl_std_global_name_lens: [MaxLocals]u16 = undefined,
    repl_import_global_count: usize = 0,
    repl_import_global_qname_offsets: [MaxLocals]u32 = undefined,
    repl_import_global_qname_lens: [MaxLocals]u16 = undefined,
    repl_import_global_path_offsets: [MaxLocals]u32 = undefined,
    repl_import_global_path_lens: [MaxLocals]u16 = undefined,
    repl_namespace_name_buf: [MaxLocals * 128]u8 = undefined,
    repl_namespace_name_buf_used: usize = 0,

    pub fn init() Runtime {
        var rt: Runtime = .{};
        const cs = std.heap.page_allocator.create(chunk.State) catch @panic("OOM");
        cs.* = .{};
        rt.chunk_state = cs;
        chunk.setActive(rt.chunk_state);
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
    pub fn initWithPolicy(self: *Runtime, policy: vm.Policy) !void {
        try initWithConfig(self, policy, heap.HeapSize, heap.MaxObjects, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.heap.page_allocator);
    }

    pub fn initWithConfig(self: *Runtime, policy: vm.Policy, heap_size: usize, max_objects: usize, max_stack: usize, max_frames: usize, max_defers: usize, allocator: std.mem.Allocator) !void {
        const cs = try std.heap.page_allocator.create(chunk.State);
        errdefer std.heap.page_allocator.destroy(cs);
        cs.* = .{};
        @memset(std.mem.asBytes(self), 0);
        self.chunk_state = cs;
        self.policy = policy;
        try self.heap_state.init(heap_size, max_objects, allocator);
        try self.vm_state.init(max_stack, max_frames, max_defers, heap_size, allocator);
        chunk.setActive(self.chunk_state);
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
        std.heap.page_allocator.destroy(self.chunk_state);
    }

    pub fn setPolicy(self: *Runtime, policy: vm.Policy) void {
        self.policy = policy;
    }

    pub fn reset(self: *Runtime) void {
        self.activate();
        net_state.netReset();
        native_time.timeClearCache();
        native_regexp.reClearCache();
        native_rand.randResetState();
        globals.reset();
        vm.reset();
        heap.reset();
        chunk.reset();
        self.repl_named_type_count = 0;
        self.repl_struct_type_count = 0;
        self.repl_interface_type_count = 0;
        self.repl_variant_type_count = 0;
        self.repl_type_name_buf_used = 0;
        self.repl_const_count = 0;
        self.repl_const_name_buf_used = 0;
        self.repl_enum_member_buf_used = 0;
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

    pub fn compileOnly(self: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider) !void {
        self.last_compile_line = 0;
        self.last_compile_path_len = 0;
        self.last_compile_col = 0;
        self.last_compile_msg_len = 0;
        self.reset();
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
            session.host_module_descs = self.host_modules;
            session.enabled_capabilities = self.enabled_capabilities;
            session.capability_modules = all_caps;
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
            session.host_module_names = hm_names;
            session.host_module_descs = self.host_modules;
            session.enabled_capabilities = self.enabled_capabilities;
            session.capability_modules = all_caps;
            var compiler = Compiler.init(src, .{
                .module_ctx = &session,
                .resolve_import = module_compile.Session.resolveImportOpaque,
                .has_module_export = module_compile.hasModuleExport,
                .test_mode = false,
            });
            compiler.compile(true) catch |err| {
                self.last_compile_line = if (compiler.err_line != 0) compiler.err_line else compiler.prev.line;
                self.last_compile_col = compiler.err_col;
                self.last_compile_msg_len = compiler.err_msg_len;
                @memcpy(self.last_compile_msg_buf[0..compiler.err_msg_len], compiler.err_msg_buf[0..compiler.err_msg_len]);
                self.setLastCompilePath("");
                return err;
            };
        }
    }

    pub fn runPathWithProvider(self: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider, test_mode: bool) !void {
        if (src.len > cfg.max_input_bytes) {
            vms.setRuntimeErr("input exceeds max_input_bytes ({d})", .{cfg.max_input_bytes});
            const emsg = vms.runtimeErrMsg();
            self.last_runtime_msg_len = @intCast(emsg.len);
            @memcpy(self.last_runtime_msg_buf[0..emsg.len], emsg);
            return error.InputTooLong;
        }
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
            session.host_module_descs = self.host_modules;
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
            session.host_module_descs = self.host_modules;
            session.enabled_capabilities = self.enabled_capabilities;
            session.capability_modules = all_caps;
            var compiler = Compiler.init(src, .{
                .module_ctx = &session,
                .resolve_import = module_compile.Session.resolveImportOpaque,
                .has_module_export = module_compile.hasModuleExport,
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
        if (src.len > cfg.max_input_bytes) {
            vms.setRuntimeErr("input exceeds max_input_bytes ({d})", .{cfg.max_input_bytes});
            const emsg = vms.runtimeErrMsg();
            self.last_runtime_msg_len = @intCast(emsg.len);
            @memcpy(self.last_runtime_msg_buf[0..emsg.len], emsg);
            return error.InputTooLong;
        }
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
        session.host_module_descs = self.host_modules;
        session.enabled_capabilities = self.enabled_capabilities;
        session.capability_modules = repl_caps;
        var compiler = Compiler.init(src, .{
            .module_ctx = &session,
            .resolve_import = module_compile.Session.resolveImportOpaque,
            .repl_mode = true,
            .check_global_exists = checkGlobalExists,
            .check_global_is_const = checkGlobalIsConst,
            .check_global_ctx = self,
        });
        // Pre-populate registry with named types from previous REPL lines
        var repl_ti: usize = 0;
        while (repl_ti < self.repl_named_type_count) : (repl_ti += 1) {
            const name = self.repl_type_name_buf[self.repl_named_type_name_offsets[repl_ti]..][0..self.repl_named_type_name_lens[repl_ti]];
            const parent_name = if (self.repl_named_type_parent_lens[repl_ti] > 0)
                self.repl_type_name_buf[self.repl_named_type_parent_offsets[repl_ti]..][0..self.repl_named_type_parent_lens[repl_ti]]
            else null;
            const enum_members = self.replEnumMembersAt(repl_ti);
            compiler.registry.addNamedType(.{
                .name = name,
                .base = self.repl_named_type_bases[repl_ti],
                .has_range = self.repl_named_type_has_ranges[repl_ti],
                .is_cycle = self.repl_named_type_is_cycles[repl_ti],
                .scale = self.repl_named_type_scales[repl_ti],
                .min = self.repl_named_type_mins[repl_ti],
                .max = self.repl_named_type_maxs[repl_ti],
                .parent_name = parent_name,
                .enum_members = enum_members,
            }) catch {};
        }
        repl_ti = 0;
        while (repl_ti < self.repl_struct_type_count) : (repl_ti += 1) {
            const name = self.repl_type_name_buf[self.repl_struct_type_name_offsets[repl_ti]..][0..self.repl_struct_type_name_lens[repl_ti]];
            compiler.registry.addStructType(name) catch {};
        }
        repl_ti = 0;
        while (repl_ti < self.repl_interface_type_count) : (repl_ti += 1) {
            const name = self.repl_type_name_buf[self.repl_interface_type_name_offsets[repl_ti]..][0..self.repl_interface_type_name_lens[repl_ti]];
            compiler.registry.addInterfaceType(name) catch {};
        }
        repl_ti = 0;
        while (repl_ti < self.repl_variant_type_count) : (repl_ti += 1) {
            const name = self.repl_type_name_buf[self.repl_variant_type_name_offsets[repl_ti]..][0..self.repl_variant_type_name_lens[repl_ti]];
            compiler.registry.addVariantType(name) catch {};
        }
        // #72: restore global-func table so duplicate detection works across lines
        repl_ti = 0;
        while (repl_ti < self.repl_global_func_count) : (repl_ti += 1) {
            const fname = self.repl_global_func_name_buf[self.repl_global_func_name_offsets[repl_ti]..][0..self.repl_global_func_name_lens[repl_ti]];
            compiler.registry.addGlobalFunc(fname) catch {};
        }
        // #73: restore typed-global table so assignment type-checks persist
        repl_ti = 0;
        while (repl_ti < self.repl_typed_global_count and
               compiler.typed_global_count < MaxLocals) : (repl_ti += 1)
        {
            const gname = self.repl_typed_global_name_buf[self.repl_typed_global_name_offsets[repl_ti]..][0..self.repl_typed_global_name_lens[repl_ti]];
            const tag = self.repl_typed_global_tags[repl_ti];
            const tc: TypeCheck = switch (tag) {
                0 => .{ .prim = .int },
                1 => .{ .prim = .float },
                2 => .{ .prim = .decimal },
                3 => .{ .prim = .bool },
                4 => .{ .prim = .string },
                5 => .{ .prim = .rune },
                6 => blk: {
                    const ntname = self.repl_typed_global_name_buf[self.repl_typed_global_named_type_offsets[repl_ti]..][0..self.repl_typed_global_named_type_lens[repl_ti]];
                    break :blk .{ .named = ntname };
                },
                7 => .{ .assert_arr = {} },
                8 => .{ .assert_map = {} },
                9 => .{ .assert_err = {} },
                else => continue,
            };
            compiler.typed_global_names[compiler.typed_global_count] = gname;
            compiler.typed_global_type_checks[compiler.typed_global_count] = tc;
            compiler.typed_global_count += 1;
        }
        // #74: restore std/import namespace provenance for field validation
        repl_ti = 0;
        while (repl_ti < self.repl_std_global_count and
               compiler.std_module_global_count < MaxLocals) : (repl_ti += 1)
        {
            const sname = self.repl_namespace_name_buf[self.repl_std_global_name_offsets[repl_ti]..][0..self.repl_std_global_name_lens[repl_ti]];
            compiler.std_module_global_names[compiler.std_module_global_count] = sname;
            compiler.std_module_global_count += 1;
        }
        repl_ti = 0;
        while (repl_ti < self.repl_import_global_count and
               compiler.import_module_global_count < MaxLocals) : (repl_ti += 1)
        {
            const qn = self.repl_namespace_name_buf[self.repl_import_global_qname_offsets[repl_ti]..][0..self.repl_import_global_qname_lens[repl_ti]];
            const ip = self.repl_namespace_name_buf[self.repl_import_global_path_offsets[repl_ti]..][0..self.repl_import_global_path_lens[repl_ti]];
            compiler.import_module_global_qnames[compiler.import_module_global_count] = qn;
            compiler.import_module_global_paths[compiler.import_module_global_count] = ip;
            compiler.import_module_global_count += 1;
        }
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

        var ci: usize = 0;
        while (ci < compiler.registry.global_const_count) : (ci += 1) {
            const cname = compiler.registry.global_consts[ci].name;
            if (!checkGlobalIsConst(self, cname)) {
                if (self.repl_const_count >= MaxGlobalConsts or
                    self.repl_const_name_buf_used + cname.len > self.repl_const_name_buf.len)
                {
                    return self.setReplOverflowError("REPL const table full: too many global const declarations");
                }
                const start = self.repl_const_name_buf_used;
                @memcpy(self.repl_const_name_buf[start .. start + cname.len], cname);
                self.repl_const_names[self.repl_const_count] = self.repl_const_name_buf[start .. start + cname.len];
                self.repl_const_name_buf_used += cname.len;
                self.repl_const_count += 1;
            }
        }

        // Persist named type info for subsequent REPL lines
        self.repl_named_type_count = 0;
        self.repl_struct_type_count = 0;
        self.repl_interface_type_count = 0;
        self.repl_variant_type_count = 0;
        self.repl_type_name_buf_used = 0;
        self.repl_enum_member_buf_used = 0;
        {
            var ti: usize = 0;
            while (ti < compiler.registry.named_type_count) : (ti += 1) {
                const ni = compiler.registry.named_types[ti];
                if (self.repl_named_type_count >= MaxNamedTypes)
                    return self.setReplOverflowError("REPL type table full: too many named type declarations");
                const idx = self.repl_named_type_count;
                self.repl_named_type_enum_member_counts[idx] = 0;
                const saved_name = self.saveReplTypeName(ni.name) catch
                    return self.setReplOverflowError("REPL type name buffer full");
                self.repl_named_type_name_offsets[idx] = @intCast(@intFromPtr(saved_name.ptr) - @intFromPtr(&self.repl_type_name_buf));
                self.repl_named_type_name_lens[idx] = @intCast(saved_name.len);
                self.repl_named_type_bases[idx] = ni.base;
                self.repl_named_type_has_ranges[idx] = ni.has_range;
                self.repl_named_type_is_cycles[idx] = ni.is_cycle;
                self.repl_named_type_scales[idx] = ni.scale;
                self.repl_named_type_mins[idx] = ni.min;
                self.repl_named_type_maxs[idx] = ni.max;
                if (ni.parent_name) |pn| {
                    const saved_pn = self.saveReplTypeName(pn) catch
                        return self.setReplOverflowError("REPL type name buffer full");
                    self.repl_named_type_parent_offsets[idx] = @intCast(@intFromPtr(saved_pn.ptr) - @intFromPtr(&self.repl_type_name_buf));
                    self.repl_named_type_parent_lens[idx] = @intCast(saved_pn.len);
                } else {
                    self.repl_named_type_parent_lens[idx] = 0;
                }
                if (ni.enum_members) |members| self.saveReplEnumMembers(idx, members);
                self.repl_named_type_count += 1;
            }
        }
        {
            var ti: usize = 0;
            while (ti < compiler.registry.struct_type_count) : (ti += 1) {
                if (self.repl_struct_type_count >= MaxStructTypes)
                    return self.setReplOverflowError("REPL type table full: too many struct type declarations");
                const idx = self.repl_struct_type_count;
                const saved_name = self.saveReplTypeName(compiler.registry.struct_types[ti].name) catch
                    return self.setReplOverflowError("REPL type name buffer full");
                self.repl_struct_type_name_offsets[idx] = @intCast(@intFromPtr(saved_name.ptr) - @intFromPtr(&self.repl_type_name_buf));
                self.repl_struct_type_name_lens[idx] = @intCast(saved_name.len);
                self.repl_struct_type_count += 1;
            }
        }
        {
            var ti: usize = 0;
            while (ti < compiler.registry.interface_type_count) : (ti += 1) {
                if (self.repl_interface_type_count >= MaxInterfaceTypes)
                    return self.setReplOverflowError("REPL type table full: too many interface type declarations");
                const idx = self.repl_interface_type_count;
                const saved_name = self.saveReplTypeName(compiler.registry.interface_types[ti].name) catch
                    return self.setReplOverflowError("REPL type name buffer full");
                self.repl_interface_type_name_offsets[idx] = @intCast(@intFromPtr(saved_name.ptr) - @intFromPtr(&self.repl_type_name_buf));
                self.repl_interface_type_name_lens[idx] = @intCast(saved_name.len);
                self.repl_interface_type_count += 1;
            }
        }
        {
            var ti: usize = 0;
            while (ti < compiler.registry.variant_type_count) : (ti += 1) {
                if (self.repl_variant_type_count >= MaxVariantTypes)
                    return self.setReplOverflowError("REPL type table full: too many variant type declarations");
                const idx = self.repl_variant_type_count;
                const saved_name = self.saveReplTypeName(compiler.registry.variant_types[ti].name) catch
                    return self.setReplOverflowError("REPL type name buffer full");
                self.repl_variant_type_name_offsets[idx] = @intCast(@intFromPtr(saved_name.ptr) - @intFromPtr(&self.repl_type_name_buf));
                self.repl_variant_type_name_lens[idx] = @intCast(saved_name.len);
                self.repl_variant_type_count += 1;
            }
        }

        // #72: persist global-func names for duplicate detection on subsequent lines
        self.repl_global_func_count = 0;
        self.repl_global_func_name_buf_used = 0;
        {
            var fi: usize = 0;
            while (fi < compiler.registry.global_func_count) : (fi += 1) {
                const fn_name = compiler.registry.global_funcs[fi].name;
                if (self.repl_global_func_count >= MaxGlobalFuncs or
                    self.repl_global_func_name_buf_used + fn_name.len > self.repl_global_func_name_buf.len) break;
                const start = self.repl_global_func_name_buf_used;
                std.mem.copyForwards(u8, self.repl_global_func_name_buf[start .. start + fn_name.len], fn_name);
                self.repl_global_func_name_offsets[self.repl_global_func_count] = @intCast(start);
                self.repl_global_func_name_lens[self.repl_global_func_count] = @intCast(fn_name.len);
                self.repl_global_func_name_buf_used += fn_name.len;
                self.repl_global_func_count += 1;
            }
        }
        // #73: persist typed-global table entries
        self.repl_typed_global_count = 0;
        self.repl_typed_global_name_buf_used = 0;
        {
            var tgi: usize = 0;
            while (tgi < compiler.typed_global_count) : (tgi += 1) {
                const gname = compiler.typed_global_names[tgi];
                const tc = compiler.typed_global_type_checks[tgi];
                if (self.repl_typed_global_count >= MaxLocals) break;
                const tag: u8 = switch (tc) {
                    .prim => |p| switch (p) {
                        .int => 0, .float => 1, .decimal => 2,
                        .bool => 3, .string => 4, .rune => 5,
                    },
                    .named => 6,
                    .assert_arr => 7,
                    .assert_map => 8,
                    .assert_err => 9,
                    // Interface and struct type checks are not persisted across REPL
                    // resets — the check is emitted inline at declaration time.
                    .interface_type, .struct_type, .none => continue,
                };
                if (self.repl_typed_global_name_buf_used + gname.len > self.repl_typed_global_name_buf.len) break;
                const gs = self.repl_typed_global_name_buf_used;
                std.mem.copyForwards(u8, self.repl_typed_global_name_buf[gs .. gs + gname.len], gname);
                self.repl_typed_global_name_offsets[self.repl_typed_global_count] = @intCast(gs);
                self.repl_typed_global_name_lens[self.repl_typed_global_count] = @intCast(gname.len);
                self.repl_typed_global_name_buf_used += gname.len;
                self.repl_typed_global_named_type_offsets[self.repl_typed_global_count] = @intCast(gs);
                self.repl_typed_global_named_type_lens[self.repl_typed_global_count] = 0;
                if (tag == 6) {
                    const ntname = tc.named;
                    if (self.repl_typed_global_name_buf_used + ntname.len <= self.repl_typed_global_name_buf.len) {
                        const ns = self.repl_typed_global_name_buf_used;
                        std.mem.copyForwards(u8, self.repl_typed_global_name_buf[ns .. ns + ntname.len], ntname);
                        self.repl_typed_global_named_type_offsets[self.repl_typed_global_count] = @intCast(ns);
                        self.repl_typed_global_named_type_lens[self.repl_typed_global_count] = @intCast(ntname.len);
                        self.repl_typed_global_name_buf_used += ntname.len;
                    } else break;
                }
                self.repl_typed_global_tags[self.repl_typed_global_count] = tag;
                self.repl_typed_global_count += 1;
            }
        }
        // #74: persist std/import namespace provenance
        self.repl_std_global_count = 0;
        self.repl_import_global_count = 0;
        self.repl_namespace_name_buf_used = 0;
        {
            var si: usize = 0;
            while (si < compiler.std_module_global_count) : (si += 1) {
                const sname = compiler.std_module_global_names[si];
                if (self.repl_std_global_count >= MaxLocals or
                    self.repl_namespace_name_buf_used + sname.len > self.repl_namespace_name_buf.len) break;
                const ss = self.repl_namespace_name_buf_used;
                std.mem.copyForwards(u8, self.repl_namespace_name_buf[ss .. ss + sname.len], sname);
                self.repl_std_global_name_offsets[self.repl_std_global_count] = @intCast(ss);
                self.repl_std_global_name_lens[self.repl_std_global_count] = @intCast(sname.len);
                self.repl_namespace_name_buf_used += sname.len;
                self.repl_std_global_count += 1;
            }
        }
        {
            var ii: usize = 0;
            while (ii < compiler.import_module_global_count) : (ii += 1) {
                const qn = compiler.import_module_global_qnames[ii];
                const ip = compiler.import_module_global_paths[ii];
                if (self.repl_import_global_count >= MaxLocals or
                    self.repl_namespace_name_buf_used + qn.len + ip.len > self.repl_namespace_name_buf.len) break;
                const qs = self.repl_namespace_name_buf_used;
                std.mem.copyForwards(u8, self.repl_namespace_name_buf[qs .. qs + qn.len], qn);
                self.repl_import_global_qname_offsets[self.repl_import_global_count] = @intCast(qs);
                self.repl_import_global_qname_lens[self.repl_import_global_count] = @intCast(qn.len);
                self.repl_namespace_name_buf_used += qn.len;
                const ps = self.repl_namespace_name_buf_used;
                std.mem.copyForwards(u8, self.repl_namespace_name_buf[ps .. ps + ip.len], ip);
                self.repl_import_global_path_offsets[self.repl_import_global_count] = @intCast(ps);
                self.repl_import_global_path_lens[self.repl_import_global_count] = @intCast(ip.len);
                self.repl_namespace_name_buf_used += ip.len;
                self.repl_import_global_count += 1;
            }
        }

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
        chunk.setActive(self.chunk_state);
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

    fn setReplOverflowError(self: *Runtime, comptime msg: []const u8) error{OutOfMemory} {
        self.last_compile_line = 1;
        self.last_compile_col = 0;
        const len = @min(msg.len, self.last_compile_msg_buf.len);
        @memcpy(self.last_compile_msg_buf[0..len], msg[0..len]);
        self.last_compile_msg_len = @intCast(len);
        return error.OutOfMemory;
    }

    fn saveReplTypeName(self: *Runtime, name: []const u8) ![]const u8 {
        // Always reserve and copy, even when the name already lives in this
        // buffer: persist compacts from offset 0, and an unreserved reused
        // slice gets clobbered by the next new name written over its bytes.
        // Persist order preserves relative order, so an in-buffer source is
        // always at or ahead of its destination — copyForwards handles the
        // overlap.
        if (self.repl_type_name_buf_used + name.len > self.repl_type_name_buf.len) return error.OutOfMemory;
        const start = self.repl_type_name_buf_used;
        std.mem.copyForwards(u8, self.repl_type_name_buf[start .. start + name.len], name);
        self.repl_type_name_buf_used += name.len;
        return self.repl_type_name_buf[start .. start + name.len];
    }

    // Pack an enum type's member names for type `idx` as [len:u8][bytes]... into
    // repl_enum_member_buf. On overflow the type is left with zero persisted
    // members (graceful: validation simply can't run for that type next line).
    fn saveReplEnumMembers(self: *Runtime, idx: usize, members: []const []const u8) void {
        if (members.len == 0 or members.len > 255) return;
        var needed: usize = 0;
        for (members) |m| {
            if (m.len > 255) return;
            needed += 1 + m.len;
        }
        if (self.repl_enum_member_buf_used + needed > self.repl_enum_member_buf.len) return;
        const start = self.repl_enum_member_buf_used;
        var pos = start;
        for (members) |m| {
            self.repl_enum_member_buf[pos] = @intCast(m.len);
            pos += 1;
            std.mem.copyForwards(u8, self.repl_enum_member_buf[pos .. pos + m.len], m);
            pos += m.len;
        }
        self.repl_enum_member_buf_used = pos;
        self.repl_named_type_enum_member_offsets[idx] = @intCast(start);
        self.repl_named_type_enum_member_counts[idx] = @intCast(members.len);
    }

    // Rebuild the []const []const u8 member slice for persisted type `idx`.
    // The outer array is bump-allocated on the (REPL-persistent) heap; inner
    // slices point back into repl_enum_member_buf.
    fn replEnumMembersAt(self: *Runtime, idx: usize) ?[]const []const u8 {
        const count = self.repl_named_type_enum_member_counts[idx];
        if (count == 0) return null;
        const out = heap.bump([]const u8, count) orelse return null;
        var pos: usize = self.repl_named_type_enum_member_offsets[idx];
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const len = self.repl_enum_member_buf[pos];
            pos += 1;
            out[i] = self.repl_enum_member_buf[pos .. pos + len];
            pos += len;
        }
        return out[0..count];
    }

};
