const std = @import("std");
const chunk = @import("lang/chunk.zig");
const heap = @import("runtime/heap.zig");
const globals = @import("lang/globals.zig");
const Compiler = @import("lang/compiler.zig").Compiler;
const Op = @import("lang/op.zig").Op;
const Runtime = @import("runtime/runtime.zig").Runtime;
const vms = @import("lang/vm_state.zig");
const api = @import("runtime/api.zig");
const cfg = @import("runtime_config");
const Value = @import("lang/value.zig").Value;
const module_compile = @import("lang/module_compile.zig");
const vm = @import("lang/vm.zig");
const vm_defuse = @import("lang/vm_defuse.zig");
const chunk_decoder = @import("lang/chunk_decoder.zig");

fn setup() !Runtime {
    var rt: Runtime = .{};
    try rt.initWithConfig(.{}, heap.HeapSize, heap.MaxObjects, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.testing.allocator);
    return rt;
}

fn compile(rt: *Runtime, src: []const u8) !void {
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    var compiler = Compiler.init(src, .{});
    try compiler.compile(true);
}

fn compileWithSession(rt: *Runtime, src: []const u8, path: []const u8) !void {
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    var session: module_compile.Session = .{};
    session.hs = heap.g_state;
    session.provider = .{ .table = &.{} };
    session.host_module_names = &.{};
    session.host_module_descs = &.{};
    session.enabled_capabilities = &.{};
    session.capability_modules = &.{};

    var compiler = Compiler.init(src, .{
        .module_ctx = &session,
        .resolve_import = module_compile.Session.resolveImportOpaque,
        .has_module_export = module_compile.hasModuleExport,
        .resolve_module_type = module_compile.resolveModuleTypeKind,
    });
    _ = path;
    try compiler.compile(true);
}

const CompileSnapshot = struct {
    err: anyerror,
    line: u32,
    col: u32,
    msg: []const u8,
    path: []const u8,
    runtime_line: u32,
    runtime_col: u32,
    runtime_msg: []const u8,
};

fn compileOnlySnapshot(rt: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider) !CompileSnapshot {
    const err = rt.compileOnly(src, path, provider) catch |e| {
        try std.testing.expect(rt.last_compile_line != 0);
        return .{
            .err = e,
            .line = rt.last_compile_line,
            .col = rt.last_compile_col,
            .msg = rt.last_compile_msg_buf[0..rt.last_compile_msg_len],
            .path = rt.lastCompilePath(),
            .runtime_line = rt.last_runtime_line,
            .runtime_col = rt.last_runtime_col,
            .runtime_msg = rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len],
        };
    };
    _ = err;
    return error.TestUnexpectedResult;
}

fn runPathCompileSnapshot(rt: *Runtime, src: []const u8, path: []const u8, provider: module_compile.SourceProvider) !CompileSnapshot {
    const err = rt.runPathWithProvider(src, path, provider, false) catch |e| {
        try std.testing.expect(rt.last_compile_line != 0);
        return .{
            .err = e,
            .line = rt.last_compile_line,
            .col = rt.last_compile_col,
            .msg = rt.last_compile_msg_buf[0..rt.last_compile_msg_len],
            .path = rt.lastCompilePath(),
            .runtime_line = rt.last_runtime_line,
            .runtime_col = rt.last_runtime_col,
            .runtime_msg = rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len],
        };
    };
    try std.testing.expect(rt.last_compile_line != 0);
    _ = err;
    return error.TestUnexpectedResult;
}

fn expectCompileSnapshotsEqual(a: CompileSnapshot, b: CompileSnapshot) !void {
    try std.testing.expectEqual(a.err, b.err);
    try std.testing.expectEqual(a.line, b.line);
    try std.testing.expectEqual(a.col, b.col);
    try std.testing.expectEqualStrings(a.msg, b.msg);
    try std.testing.expectEqualStrings(a.path, b.path);
    try std.testing.expectEqual(a.runtime_line, b.runtime_line);
    try std.testing.expectEqual(a.runtime_col, b.runtime_col);
    try std.testing.expectEqualStrings(a.runtime_msg, b.runtime_msg);
}

fn setupApiRuntime(config: api.Config) !api.Runtime {
    return api.Runtime.init(config);
}

fn expectApiCompileErrorEqual(a: api.CompileError, b: api.CompileError) !void {
    try std.testing.expectEqual(a.kind, b.kind);
    try std.testing.expectEqual(a.line, b.line);
    try std.testing.expectEqual(a.col, b.col);
    try std.testing.expectEqualStrings(a.msg, b.msg);
}

fn expectApiRuntimeErrorEqual(a: api.RuntimeError, b: api.RuntimeError) !void {
    try std.testing.expectEqual(a.kind, b.kind);
    try std.testing.expectEqual(a.line, b.line);
    try std.testing.expectEqual(a.col, b.col);
    try std.testing.expectEqual(a.frame_count, b.frame_count);
    try std.testing.expectEqualStrings(a.msg, b.msg);
}

fn expectNoTempRoots() !void {
    try std.testing.expectEqual(@as(usize, 0), vms.tempRootDepth());
}

test "api runtime leaves no temp roots after GC-heavy success and error churn" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer rt.deinit();

    try std.testing.expect(rt.run(
        \\std := import("std")
        \\
        \\func churn() int {
        \\    arr := []
        \\    for i := 0; i < 50; i += 1 {
        \\        arr = std.core.append(arr, { i: i })
        \\    }
        \\    return std.core.len(arr)
        \\}
        \\
        \\func explode() int {
        \\    m := {}
        \\    return 1 + m["missing"]
        \\}
    ) == .ok);
    try expectNoTempRoots();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const ok_result = rt.call("churn", &.{});
        switch (ok_result) {
            .ok => |v| try std.testing.expect(v == .int and v.int == 50),
            else => return error.TestUnexpectedResult,
        }
        try expectNoTempRoots();

        const err_result = rt.call("explode", &.{});
        try std.testing.expect(err_result == .runtime_error);
        try expectNoTempRoots();
    }

    var repl_rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer repl_rt.deinit();

    try std.testing.expect(repl_rt.runIncremental(
        \\std := import("std")
        \\
        \\func moreChurn() int {
        \\    arr := []
        \\    for i := 0; i < 10; i += 1 {
        \\        arr = std.core.append(arr, { i: i })
        \\    }
        \\    return std.core.len(arr)
        \\}
    ) == .ok);
    try expectNoTempRoots();
}

test "api runtime leaves no temp roots after std.array zip and chunk churn" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer rt.deinit();

    try std.testing.expect(rt.run(
        \\std := import("std")
        \\a := std.array
        \\
        \\func zipCount() int {
        \\    pairs := a.zip([1, 2, 3, 4], [5, 6, 7, 8])
        \\    return std.core.len(pairs)
        \\}
        \\
        \\func chunkCount() int {
        \\    groups := a.chunk([1, 2, 3, 4, 5, 6], 2)
        \\    return std.core.len(groups)
        \\}
    ) == .ok);
    try expectNoTempRoots();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const zip_result = rt.call("zipCount", &.{});
        switch (zip_result) {
            .ok => |v| try std.testing.expect(v == .int and v.int == 4),
            else => return error.TestUnexpectedResult,
        }
        try expectNoTempRoots();

        const chunk_result = rt.call("chunkCount", &.{});
        switch (chunk_result) {
            .ok => |v| try std.testing.expect(v == .int and v.int == 3),
            else => return error.TestUnexpectedResult,
        }
        try expectNoTempRoots();
    }
}

test "api runtime leaves no temp roots after std.json parse churn" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer rt.deinit();

    try std.testing.expect(rt.run(
        \\std := import("std")
        \\json := std.json
        \\
        \\func parseCount() int {
        \\    arr := json.parse("[1,2,3,{\"k\":\"v\"},[4,5,6]]")
        \\    return std.core.len(arr)
        \\}
        \\
        \\func parseValueTag() bool {
        \\    doc := json.parse_value("{\"items\":[1,2,3],\"ok\":true}")
        \\    return std.core.type_of(doc) == "JSONValue"
        \\}
    ) == .ok);
    try expectNoTempRoots();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const parse_result = rt.call("parseCount", &.{});
        switch (parse_result) {
            .ok => |v| try std.testing.expect(v == .int and v.int == 5),
            else => return error.TestUnexpectedResult,
        }
        try expectNoTempRoots();

        const parse_value_result = rt.call("parseValueTag", &.{});
        switch (parse_value_result) {
            .ok => |v| try std.testing.expect(v == .boolean and v.boolean),
            else => return error.TestUnexpectedResult,
        }
        try expectNoTempRoots();
    }
}

test "api runtime leaves no temp roots after std.template render churn" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer rt.deinit();

    try std.testing.expect(rt.run(
        \\std := import("std")
        \\tmpl := std.template
        \\
        \\func renderLen() int {
        \\    out := tmpl.render("Hello {{.name}} {{range .nums}}#{{.}}{{end}}", {
        \\        "name": "Ada",
        \\        "nums": [1, 2, 3, 4],
        \\    })
        \\    return std.core.len(out)
        \\}
    ) == .ok);
    try expectNoTempRoots();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const render_result = rt.call("renderLen", &.{});
        switch (render_result) {
            .ok => |v| try std.testing.expect(v == .int and v.int > 0),
            else => return error.TestUnexpectedResult,
        }
        try expectNoTempRoots();
    }
}

test "array slices survive GC churn from temporary array sources" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer rt.deinit();

    try std.testing.expect(rt.run(
        \\std := import("std")
        \\
        \\func churnedSliceSum() int {
        \\    s := [10, 20, 30, 40, 50][1:4]
        \\    junk := []
        \\    for i := 0; i < 1500; i += 1 {
        \\        junk = std.core.append(junk, [i, i + 1, i + 2, i + 3])
        \\        if std.core.len(junk) > 96 { junk = [] }
        \\    }
        \\    return s[0] + s[2]
        \\}
    ) == .ok);
    try expectNoTempRoots();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const result = rt.call("churnedSliceSum", &.{});
        switch (result) {
            .ok => |v| try std.testing.expect(v == .int and v.int == 60),
            else => return error.TestUnexpectedResult,
        }
        try expectNoTempRoots();
    }
}

test "api heap diagnostics preserve the previously active heap" {
    var active_rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer active_rt.deinit();

    var probe_rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
    });
    defer probe_rt.deinit();

    heap.setActive(&active_rt.inner.heap_state);

    _ = probe_rt.heapUsedBytes();
    try std.testing.expect(heap.g_state == &active_rt.inner.heap_state);

    _ = probe_rt.heapTotalFreeListBytes();
    try std.testing.expect(heap.g_state == &active_rt.inner.heap_state);

    _ = probe_rt.heapFragmentationInfo();
    try std.testing.expect(heap.g_state == &active_rt.inner.heap_state);

    var buf: [128]u8 = undefined;
    _ = probe_rt.heapFreeListSummary(&buf);
    try std.testing.expect(heap.g_state == &active_rt.inner.heap_state);

    _ = probe_rt.heapLiveObjectCount();
    try std.testing.expect(heap.g_state == &active_rt.inner.heap_state);
}

test "compiler: empty source emits halt" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt, "");
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), c.code_len);
    try std.testing.expectEqual(@intFromEnum(Op.halt), c.code[0]);
}

test "compiler: integer constant 42" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int { return 42 }
    );
    const c = rt.chunk_state;

    try std.testing.expectEqual(@as(usize, 17), c.code_len);

    try std.testing.expect(c.consts[0] == .int);

    try std.testing.expectEqual(@intFromEnum(Op.ret_const), c.code[5]);

    try std.testing.expectEqual(@intFromEnum(Op.make_closure), c.code[10]);

    try std.testing.expectEqual(@intFromEnum(Op.def_global), c.code[13]);

    try std.testing.expectEqual(@intFromEnum(Op.halt), c.code[16]);
}

test "compiler: var global int" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt, "var x = 42");

    const c = rt.chunk_state;

    try std.testing.expectEqual(@as(usize, 7), c.code_len);

    try std.testing.expectEqual(@intFromEnum(Op.constant), c.code[0]);
    try std.testing.expectEqual(@intFromEnum(Op.def_global), c.code[3]);
    try std.testing.expectEqual(@intFromEnum(Op.halt), c.code[6]);
}

test "compiler: const_add fusion" {
    // 1 + 2 is now constant-folded at compile time — the folded value 3 is in
    // the constant table and no separate 1 or 2 appear.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int { return 1 + 2 }
    );
    const c = rt.chunk_state;
    var found3 = false;
    var i: usize = 0;
    while (i < c.const_count) : (i += 1) {
        if (c.consts[i] == .int) {
            try std.testing.expect(c.consts[i].int == 3); // no stray 1 or 2
            found3 = true;
        }
    }
    try std.testing.expect(found3);
}

test "compiler: ret_const peephole" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int { return 42 }
    );
    const c = rt.chunk_state;

    var found_ret_const = false;
    var i: usize = 0;
    while (i < c.code_len) : (i += 1) {
        if (c.code[i] == @intFromEnum(Op.ret_const)) {
            found_ret_const = true;
            break;
        }
    }
    try std.testing.expect(found_ret_const);
}

test "compiler: def_global with string constant" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int { return 42 }
    );

    const c = rt.chunk_state;
    var found_name = false;
    var i: usize = 0;
    while (i < c.const_count) : (i += 1) {
        if (c.consts[i] == .string and std.mem.eql(u8, c.consts[i].string.bytes, "f")) {
            found_name = true;
            break;
        }
    }
    try std.testing.expect(found_name);
}

test "compiler: make_closure emitted" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int { return 42 }
    );
    const c = rt.chunk_state;
    var found_make_closure = false;
    var j: usize = 0;
    while (j < c.code_len) : (j += 1) {
        if (c.code[j] == @intFromEnum(Op.make_closure)) {
            found_make_closure = true;
            break;
        }
    }
    try std.testing.expect(found_make_closure);
}

test "compiler: closure captures upvalue" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func makeCounter() func() int {
        \\    var x = 0
        \\    return func() int { x = x + 1; return x }
        \\}
    );
    _ = &rt;

    var found_get_upvalue = false;
    var found_set_upvalue = false;
    const c = rt.chunk_state;
    var i: usize = 0;
    while (i < c.code_len) : (i += 1) {
        if (c.code[i] == @intFromEnum(Op.get_upvalue)) found_get_upvalue = true;
        if (c.code[i] == @intFromEnum(Op.set_upvalue)) found_set_upvalue = true;
    }
    try std.testing.expect(found_get_upvalue);
    try std.testing.expect(found_set_upvalue);
}

test "runtime: compileOnly and runPathWithProvider agree on direct compile errors" {
    const src =
        \\func broken( {
        \\
    ;

    var rt = try setup();
    defer rt.deinit();

    const compile_snapshot = try compileOnlySnapshot(&rt, src, "", .filesystem);
    const run_snapshot = try runPathCompileSnapshot(&rt, src, "", .filesystem);

    try expectCompileSnapshotsEqual(compile_snapshot, run_snapshot);
    try std.testing.expectEqualStrings("", compile_snapshot.path);
}

test "runtime: compileOnly and runPathWithProvider agree on rooted compile errors" {
    const path = "main.gengo";
    const src =
        \\func broken( {
        \\
    ;
    const provider: module_compile.SourceProvider = .{ .table = &.{} };

    var rt = try setup();
    defer rt.deinit();

    const compile_snapshot = try compileOnlySnapshot(&rt, src, path, provider);
    const run_snapshot = try runPathCompileSnapshot(&rt, src, path, provider);

    try expectCompileSnapshotsEqual(compile_snapshot, run_snapshot);
    try std.testing.expectEqualStrings(path, compile_snapshot.path);
}

test "runtime: compileOnly and runPathWithProvider agree on imported module compile errors" {
    const path = "main.gengo";
    const src =
        \\dep := import("./dep")
        \\
    ;
    const dep_src =
        \\func broken( {
        \\
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = path, .source = src },
        .{ .path = "dep.gengo", .source = dep_src },
    };
    const provider: module_compile.SourceProvider = .{ .table = &source_entries };

    var rt = try setup();
    defer rt.deinit();

    const compile_snapshot = try compileOnlySnapshot(&rt, src, path, provider);
    const run_snapshot = try runPathCompileSnapshot(&rt, src, path, provider);

    try expectCompileSnapshotsEqual(compile_snapshot, run_snapshot);
    try std.testing.expectEqualStrings("dep.gengo", compile_snapshot.path);
}

test "runtime: compileOnly and runPathWithProvider agree on nested import lookup failures" {
    const path = "main.gengo";
    const src =
        \\dep := import("./dep")
        \\
    ;
    const dep_src =
        \\missing := import("./missing")
        \\
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = path, .source = src },
        .{ .path = "dep.gengo", .source = dep_src },
    };
    const provider: module_compile.SourceProvider = .{ .table = &source_entries };

    var rt = try setup();
    defer rt.deinit();

    const compile_snapshot = try compileOnlySnapshot(&rt, src, path, provider);
    const run_snapshot = try runPathCompileSnapshot(&rt, src, path, provider);

    try expectCompileSnapshotsEqual(compile_snapshot, run_snapshot);
    try std.testing.expectEqualStrings("dep.gengo", compile_snapshot.path);
}

test "api runtime: rooted entrypoints agree on compile and runtime error mapping" {
    const bad_src =
        \\func broken( {
        \\
    ;
    const boom_src =
        \\x := 0
        \\1 / x
        \\
    ;
    const path = "main.gengo";
    const source_entries = [_]module_compile.SourceEntry{.{ .path = path, .source = bad_src }};
    const source_entries_runtime = [_]module_compile.SourceEntry{.{ .path = path, .source = boom_src }};

    var rt_compile = try setupApiRuntime(.{
        .allow_io = false,
        .module_sources = &source_entries,
        .allocator = std.testing.allocator,
    });
    defer rt_compile.deinit();

    const res_sources = rt_compile.runPathWithSources(bad_src, path, &source_entries);
    const res_provider = rt_compile.runPathWithSourceProvider(bad_src, path, .{ .table = &source_entries });
    try std.testing.expect(res_sources == .compile_error);
    try std.testing.expect(res_provider == .compile_error);
    try expectApiCompileErrorEqual(res_sources.compile_error, res_provider.compile_error);

    var rt_runtime = try setupApiRuntime(.{
        .allow_io = false,
        .module_sources = &source_entries_runtime,
        .allocator = std.testing.allocator,
    });
    defer rt_runtime.deinit();

    const runtime_sources = rt_runtime.runPathWithSources(boom_src, path, &source_entries_runtime);
    const runtime_provider = rt_runtime.runPathWithSourceProvider(boom_src, path, .{ .table = &source_entries_runtime });
    try std.testing.expect(runtime_sources == .runtime_error);
    try std.testing.expect(runtime_provider == .runtime_error);
    try expectApiRuntimeErrorEqual(runtime_sources.runtime_error, runtime_provider.runtime_error);
}

test "api runtime: setConfig updates mirrored config fields" {
    const initial_sources = [_]module_compile.SourceEntry{.{ .path = "a.gengo", .source = "x := 1" }};
    const updated_sources = [_]module_compile.SourceEntry{.{ .path = "b.gengo", .source = "y := 2" }};
    const host_funcs = [_]module_compile.HostModuleFuncDesc{.{ .name = "ping", .arity = 0, .call_id = 7 }};
    const initial_hosts = [_]module_compile.HostModuleDesc{.{ .name = "alpha", .functions = &host_funcs }};
    const updated_hosts = [_]module_compile.HostModuleDesc{.{ .name = "beta", .functions = &host_funcs }};

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .module_sources = &initial_sources,
        .host_modules = &initial_hosts,
        .capabilities = &.{"fs"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    try std.testing.expectEqual(@as(usize, 1), rt.module_sources.len);
    try std.testing.expectEqualStrings("alpha", rt.host_modules[0].name);
    try std.testing.expectEqual(@as(usize, 1), rt.capabilities.len);
    try std.testing.expectEqualStrings("fs", rt.capabilities[0]);
    try std.testing.expectEqual(@as(usize, 1), rt.inner.host_modules.len);
    try std.testing.expectEqualStrings("alpha", rt.inner.host_modules[0].name);
    try std.testing.expectEqual(@as(usize, 1), rt.inner.enabled_capabilities.len);
    try std.testing.expectEqualStrings("fs", rt.inner.enabled_capabilities[0]);

    rt.setConfig(.{
        .allow_io = true,
        .module_sources = &updated_sources,
        .host_modules = &updated_hosts,
        .capabilities = &.{"http"},
        .allocator = std.testing.allocator,
    });

    try std.testing.expectEqual(@as(usize, 1), rt.module_sources.len);
    try std.testing.expectEqualStrings("b.gengo", rt.module_sources[0].path);
    try std.testing.expectEqualStrings("beta", rt.host_modules[0].name);
    try std.testing.expectEqual(@as(usize, 1), rt.capabilities.len);
    try std.testing.expectEqualStrings("http", rt.capabilities[0]);
    try std.testing.expectEqual(@as(usize, 1), rt.inner.host_modules.len);
    try std.testing.expectEqualStrings("beta", rt.inner.host_modules[0].name);
    try std.testing.expectEqual(@as(usize, 1), rt.inner.enabled_capabilities.len);
    try std.testing.expectEqualStrings("http", rt.inner.enabled_capabilities[0]);
}

test "api runtime: incremental std namespace validation matches file mode" {
    const src =
        \\std := import("std")
        \\std.io.missing
        \\
    ;

    var rt_file = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt_file.deinit();

    const file_result = rt_file.run(src);
    try std.testing.expect(file_result == .compile_error);

    var rt_repl = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt_repl.deinit();

    try std.testing.expect(rt_repl.runIncremental("std := import(\"std\")") == .ok);
    const repl_result = rt_repl.runIncremental("std.io.missing");
    try std.testing.expect(repl_result == .compile_error);

    try std.testing.expectEqual(file_result.compile_error.kind, repl_result.compile_error.kind);
    try std.testing.expectEqual(file_result.compile_error.col, repl_result.compile_error.col);
    try std.testing.expectEqualStrings(file_result.compile_error.msg, repl_result.compile_error.msg);
    try std.testing.expectEqual(@as(u32, 2), file_result.compile_error.line);
    try std.testing.expectEqual(@as(u32, 1), repl_result.compile_error.line);
}

test "api runtime: incremental enum subtype validation matches file mode" {
    const src =
        \\type Colors enum { red, green, blue }
        \\subtype Warm Colors { orange }
        \\
    ;

    var rt_file = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt_file.deinit();

    const file_result = rt_file.run(src);
    try std.testing.expect(file_result == .compile_error);

    var rt_repl = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt_repl.deinit();

    try std.testing.expect(rt_repl.runIncremental("type Colors enum { red, green, blue }") == .ok);
    const repl_result = rt_repl.runIncremental("subtype Warm Colors { orange }");
    try std.testing.expect(repl_result == .compile_error);

    try std.testing.expectEqual(file_result.compile_error.kind, repl_result.compile_error.kind);
    try std.testing.expectEqual(file_result.compile_error.col, repl_result.compile_error.col);
    try std.testing.expectEqualStrings(file_result.compile_error.msg, repl_result.compile_error.msg);
    try std.testing.expectEqual(@as(u32, 2), file_result.compile_error.line);
    try std.testing.expectEqual(@as(u32, 1), repl_result.compile_error.line);
}

test "chunk: verify rejects jump target into instruction body" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    try chunk.emitOp(.jump, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(1, 1);
    try chunk.emitConst(.{ .int = 42 }, 1);
    try chunk.emitOp(.halt, 1);

    try std.testing.expectError(error.BadJumpTarget, chunk.verify());
}

test "chunk: verify catches truncated instruction (BytecodeOutOfBounds)" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    // Emit just the opcode byte of .constant — missing 2 operand bytes
    try chunk.emitOp(.constant, 1);

    try std.testing.expectError(error.BytecodeOutOfBounds, chunk.verify());
}

test "chunk: verify catches bad constant index (BadConstantIndex)" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    // Emit .constant with an index that exceeds const_count
    try chunk.emitOp(.constant, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(1, 1);

    try std.testing.expectError(error.BadConstantIndex, chunk.verify());
}

test "chunk: verify catches stack underflow (StackUnderflow)" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    // .pop with empty stack → depth(0) < pop(1)
    try chunk.emitOp(.pop, 1);
    try chunk.emitOp(.halt, 1);

    try std.testing.expectError(error.StackUnderflow, chunk.verify());
}

test "chunk: verify catches return at top level (ReturnAtTopLevel)" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    try chunk.emitOp(.ret, 1);

    try std.testing.expectError(error.ReturnAtTopLevel, chunk.verify());
}

test "chunk: verify catches malformed fused instruction (BadOpcode)" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    // Add a constant so the const_index check passes,
    // then check that the skip-byte mismatch triggers BadOpcode
    try chunk.emitConst(.{ .int = 42 }, 1);
    try chunk.emitConst(.{ .int = 99 }, 1);
    // Emit get_local_const_eq with a wrong skip byte (0 instead of const_eq)
    try chunk.emitByte(@intFromEnum(Op.get_local_const_eq), 1);
    try chunk.emitByte(1, 1); // local slot (valid)
    try chunk.emitByte(0, 1); // skip byte — should be const_eq
    try chunk.emitByte(0, 1); // const index hi
    try chunk.emitByte(1, 1); // const index lo = 1 (valid, < const_count)
    try chunk.emitOp(.halt, 1);

    try std.testing.expectError(error.BadOpcode, chunk.verify());
}

// regression: verifier error message includes IP/opcode context
test "chunk: verify context on BadConstantIndex" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    try chunk.emitOp(.constant, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(99, 1);

    try std.testing.expectError(error.BadConstantIndex, chunk.verify());
    try std.testing.expect(chunk.g_state.verify_err_len > 0);
    const msg = chunk.g_state.verify_err_buf[0..chunk.g_state.verify_err_len];
    try std.testing.expect(std.mem.indexOf(u8, msg, "constant") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "ip=0") != null);
}

test "compiler: std math abs direct call lowers to intrinsic op" {
    var rt = try setup();
    defer rt.deinit();

    try compileWithSession(&rt,
        \\std := import("std")
        \\func f(x int) int { return std.math.abs(x) }
    , "");

    const c = rt.chunk_state;
    var found_abs = false;
    var found_direct_abs_global = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .abs) found_abs = true;
        if (inst.op == .get_global and inst.const_index != null) {
            const name = (try chunk.constAt(inst.const_index.?)).string.bytes;
            if (std.mem.eql(u8, name, "module:std.math.abs")) found_direct_abs_global = true;
        }
        ip += inst.width;
    }
    try std.testing.expect(found_abs);
    try std.testing.expect(!found_direct_abs_global);
}

test "compiler: std math rounding direct calls lower to intrinsic ops" {
    var rt = try setup();
    defer rt.deinit();

    try compileWithSession(&rt,
        \\std := import("std")
        \\func a(x float) float { return std.math.floor(x) }
        \\func b(x float) float { return std.math.ceil(x) }
        \\func c(x float) float { return std.math.trunc(x) }
        \\func d(x float) float { return std.math.round(x) }
    , "");

    const c = rt.chunk_state;
    var found_floor = false;
    var found_ceil = false;
    var found_trunc = false;
    var found_nearest = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .floor) found_floor = true;
        if (inst.op == .ceil) found_ceil = true;
        if (inst.op == .trunc) found_trunc = true;
        if (inst.op == .nearest) found_nearest = true;
        ip += inst.width;
    }
    try std.testing.expect(found_floor);
    try std.testing.expect(found_ceil);
    try std.testing.expect(found_trunc);
    try std.testing.expect(found_nearest);
}

test "compiler: std math min max sign direct calls lower to intrinsic ops" {
    var rt = try setup();
    defer rt.deinit();

    try compileWithSession(&rt,
        \\std := import("std")
        \\func a(x int, y int) int { return std.math.min(x, y) }
        \\func b(x float, y float) float { return std.math.max(x, y) }
        \\func c(x int) int { return std.math.sign(x) }
    , "");

    const c = rt.chunk_state;
    var found_min = false;
    var found_max = false;
    var found_sign = false;
    var found_direct_min_global = false;
    var found_direct_max_global = false;
    var found_direct_sign_global = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .min) found_min = true;
        if (inst.op == .max) found_max = true;
        if (inst.op == .sign) found_sign = true;
        if (inst.op == .get_global and inst.const_index != null) {
            const name = (try chunk.constAt(inst.const_index.?)).string.bytes;
            if (std.mem.eql(u8, name, "module:std.math.min")) found_direct_min_global = true;
            if (std.mem.eql(u8, name, "module:std.math.max")) found_direct_max_global = true;
            if (std.mem.eql(u8, name, "module:std.math.sign")) found_direct_sign_global = true;
        }
        ip += inst.width;
    }
    try std.testing.expect(found_min);
    try std.testing.expect(found_max);
    try std.testing.expect(found_sign);
    try std.testing.expect(!found_direct_min_global);
    try std.testing.expect(!found_direct_max_global);
    try std.testing.expect(!found_direct_sign_global);
}

test "compiler: std math sqrt clamp direct calls lower to intrinsic ops" {
    var rt = try setup();
    defer rt.deinit();

    try compileWithSession(&rt,
        \\std := import("std")
        \\func a(x float) float { return std.math.sqrt(x) }
        \\func b(x float, lo float, hi float) float { return std.math.clamp(x, lo, hi) }
    , "");

    const c = rt.chunk_state;
    var found_sqrt = false;
    var found_clamp = false;
    var found_direct_sqrt_global = false;
    var found_direct_clamp_global = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .sqrt) found_sqrt = true;
        if (inst.op == .clamp) found_clamp = true;
        if (inst.op == .get_global and inst.const_index != null) {
            const name = (try chunk.constAt(inst.const_index.?)).string.bytes;
            if (std.mem.eql(u8, name, "module:std.math.sqrt")) found_direct_sqrt_global = true;
            if (std.mem.eql(u8, name, "module:std.math.clamp")) found_direct_clamp_global = true;
        }
        ip += inst.width;
    }
    try std.testing.expect(found_sqrt);
    try std.testing.expect(found_clamp);
    try std.testing.expect(!found_direct_sqrt_global);
    try std.testing.expect(!found_direct_clamp_global);
}

test "compiler: std math intrinsic direct call results" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func ai(x int) int { return std.math.abs(x) }
        \\func af(x float) float { return std.math.abs(x) }
        \\func fl(x float) float { return std.math.floor(x) }
        \\func ce(x float) float { return std.math.ceil(x) }
        \\func tr(x float) float { return std.math.trunc(x) }
        \\func rd(x float) float { return std.math.round(x) }
    );
    const ai = try rt.callGlobal("ai", &.{.{ .int = -5 }});
    try std.testing.expect(ai == .int and ai.int == 5);
    const af = try rt.callGlobal("af", &.{.{ .float = -5.5 }});
    try std.testing.expect(af == .float);
    try std.testing.expectApproxEqRel(@as(f64, 5.5), af.float, 1e-12);
    const fl = try rt.callGlobal("fl", &.{.{ .float = 3.7 }});
    try std.testing.expect(fl == .float);
    try std.testing.expectApproxEqRel(@as(f64, 3.0), fl.float, 1e-12);
    const ce = try rt.callGlobal("ce", &.{.{ .float = 3.1 }});
    try std.testing.expect(ce == .float);
    try std.testing.expectApproxEqRel(@as(f64, 4.0), ce.float, 1e-12);
    const tr = try rt.callGlobal("tr", &.{.{ .float = 3.7 }});
    try std.testing.expect(tr == .float);
    try std.testing.expectApproxEqRel(@as(f64, 3.0), tr.float, 1e-12);
    const rd = try rt.callGlobal("rd", &.{.{ .float = 3.5 }});
    try std.testing.expect(rd == .float);
    try std.testing.expectApproxEqRel(@as(f64, 4.0), rd.float, 1e-12);
}

test "compiler: std math min max sign intrinsic direct call results" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func mi(x int, y int) int { return std.math.min(x, y) }
        \\func mf(x float, y float) float { return std.math.min(x, y) }
        \\func xi(x int, y int) int { return std.math.max(x, y) }
        \\func xf(x float, y float) float { return std.math.max(x, y) }
        \\func si(x int) int { return std.math.sign(x) }
        \\func sf(x float) float { return std.math.sign(x) }
    );
    const mi = try rt.callGlobal("mi", &.{ .{ .int = 8 }, .{ .int = 3 } });
    try std.testing.expect(mi == .int and mi.int == 3);
    const mf = try rt.callGlobal("mf", &.{ .{ .float = 8.5 }, .{ .float = 3.25 } });
    try std.testing.expect(mf == .float);
    try std.testing.expectApproxEqRel(@as(f64, 3.25), mf.float, 1e-12);
    const xi = try rt.callGlobal("xi", &.{ .{ .int = 8 }, .{ .int = 3 } });
    try std.testing.expect(xi == .int and xi.int == 8);
    const xf = try rt.callGlobal("xf", &.{ .{ .float = 8.5 }, .{ .float = 3.25 } });
    try std.testing.expect(xf == .float);
    try std.testing.expectApproxEqRel(@as(f64, 8.5), xf.float, 1e-12);
    const si = try rt.callGlobal("si", &.{.{ .int = -7 }});
    try std.testing.expect(si == .int and si.int == -1);
    const sf = try rt.callGlobal("sf", &.{.{ .float = 0.0 }});
    try std.testing.expect(sf == .float);
    try std.testing.expectApproxEqRel(@as(f64, 0.0), sf.float, 1e-12);
}

test "compiler: std math sqrt clamp intrinsic direct call results" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func sq(x float) float { return std.math.sqrt(x) }
        \\func cl(x int, lo int, hi int) float { return std.math.clamp(x, lo, hi) }
        \\func cf(x float, lo float, hi float) float { return std.math.clamp(x, lo, hi) }
    );
    const sq = try rt.callGlobal("sq", &.{.{ .float = 100.0 }});
    try std.testing.expect(sq == .float);
    try std.testing.expectApproxEqRel(@as(f64, 10.0), sq.float, 1e-12);
    const cl = try rt.callGlobal("cl", &.{ .{ .int = 20 }, .{ .int = 1 }, .{ .int = 10 } });
    try std.testing.expect(cl == .float);
    try std.testing.expectApproxEqRel(@as(f64, 10.0), cl.float, 1e-12);
    const cf = try rt.callGlobal("cf", &.{ .{ .float = 0.5 }, .{ .float = 1.0 }, .{ .float = 10.0 } });
    try std.testing.expect(cf == .float);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), cf.float, 1e-12);
}

test "compiler: std math intrinsic direct calls survive defuse" {
    var rt = try api.Runtime.init(.{ .allow_io = false, .allocator = std.testing.allocator });
    defer rt.deinit();

    const src =
        \\std := import("std")
        \\
        \\// abs/min/max/sign preserve int when all inputs are int; verify via assert
        \\// so no stdout writes corrupt the --listen=- IPC channel.
        \\assert std.math.abs(-5) == 5
        \\assert std.math.abs(-5.5) == 5.5
        \\assert std.math.min(2, 9) == 2
        \\assert std.math.max(2, 9) == 9
        \\assert std.math.sign(-7) == -1
        \\assert std.math.sqrt(100.0) == 10.0
        \\assert std.math.clamp(20, 1, 10) == 10
        \\
        \\total := 0
        \\i := -3
        \\total = total + std.math.abs(i)
        \\assert total == 3
    ;
    try rt.inner.compileAndInstall(src, "tests/spec/189_math_int_preservation.gengo", .filesystem);

    const defused = try vm_defuse.buildDefusedCode(vm.VMContext.fromActive().cs, std.testing.allocator);
    defer std.testing.allocator.free(defused);

    @memcpy(chunk.g_state.code[0..defused.len], defused);
    chunk.g_state.code_len = defused.len;
    chunk.g_state.verified = false;
    chunk.g_state.verified_code_len = 0;
    vm.VMContext.fromActive().vs.resetExec();

    try vm.run(vm.VMContext.fromActive());
}

test "compiler: defused named-type interface arg survives gc stress reification" {
    var rt = try api.Runtime.init(.{ .allow_io = false, .allocator = std.testing.allocator });
    defer rt.deinit();

    const src =
        \\type Meters int
        \\type Decoy1 int
        \\type Decoy2 int
        \\type Decoy3 int
        \\type Decoy4 int
        \\type Decoy5 int
        \\
        \\func (m Meters) doubled() Meters {
        \\    return Meters(int(m) * 2)
        \\}
        \\
        \\type HasDouble interface { doubled() Meters }
        \\
        \\func accept(h HasDouble) {
        \\    assert int(h.doubled()) == 14
        \\}
        \\
        \\accept(Meters(7))
    ;
    try rt.inner.compileAndInstall(src, "tests/spec/191_non_struct_interface.gengo", .filesystem);

    const defused = try vm_defuse.buildDefusedCode(vm.VMContext.fromActive().cs, std.testing.allocator);
    defer std.testing.allocator.free(defused);

    @memcpy(chunk.g_state.code[0..defused.len], defused);
    chunk.g_state.code_len = defused.len;
    chunk.g_state.verified = false;
    chunk.g_state.verified_code_len = 0;
    vm.VMContext.fromActive().vs.resetExec();

    try vm.run(vm.VMContext.fromActive());
}

test "compiler: std.core.type_of on named local lowers to nominal type string" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Age int
        \\func f() string {
        \\    age := Age(7)
        \\    return std.core.type_of(age)
        \\}
    );

    const c = rt.chunk_state;
    var found_runtime_type_of = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .get_global and inst.const_index != null) {
            const name = (try chunk.constAt(inst.const_index.?)).string.bytes;
            if (std.mem.eql(u8, name, "module:std.core.type_of")) found_runtime_type_of = true;
        }
        ip += inst.width;
    }
    try std.testing.expect(!found_runtime_type_of);

    const out = try rt.callGlobal("f", &.{});
    const s = try vms.asStringValue(out);
    try std.testing.expectEqualStrings("Age", s);
}

test "compiler: std.core.type_of preserves nominal result of named arithmetic" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Index int
        \\func f() string {
        \\    a := Index(10)
        \\    b := Index(3)
        \\    r := a div b
        \\    return std.core.type_of(r)
        \\}
    );

    const out = try rt.callGlobal("f", &.{});
    const s = try vms.asStringValue(out);
    try std.testing.expectEqualStrings("Index", s);
}

test "compiler: named int arithmetic lowers to add_int without runtime unwrapping" {
    var rt = try setup();
    defer rt.deinit();

    try compile(&rt,
        \\type Meter int range 0..100
        \\func add(a Meter, b Meter) Meter {
        \\    return a + b
        \\}
    );

    const c = rt.chunk_state;
    var found_add_int = false;
    var found_named_inner = false;
    var found_named_range = false;
    var found_named_predicate = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.add_int)) found_add_int = true;
        if (op == @intFromEnum(Op.named_inner)) found_named_inner = true;
        if (op == @intFromEnum(Op.validate_named_range)) found_named_range = true;
        if (op == @intFromEnum(Op.check_named_predicate)) found_named_predicate = true;
    }
    try std.testing.expect(found_add_int);
    try std.testing.expect(!found_named_inner);
    try std.testing.expect(found_named_range);
    try std.testing.expect(!found_named_predicate);
}

test "compiler: named scalar arithmetic validates its result without a constructor call" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\type Score int range 0..200 predicate func(x) { return x >= 0 and x <= 100 }
        \\func add() Score {
        \\    return Score(60) + Score(50)
        \\}
    );

    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("add", &.{}));

    const c = rt.chunk_state;
    var found_named_predicate = false;
    var found_ge_int = false;
    var found_le_int = false;
    var range_const_idx: ?usize = null;
    var predicate_const_idx: ?usize = null;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .check_named_predicate) {
            found_named_predicate = true;
            predicate_const_idx = inst.const_index;
        }
        if (inst.op == .validate_named_range) range_const_idx = inst.const_index;
        if (inst.op == .ge_int) found_ge_int = true;
        if (inst.op == .le_int) found_le_int = true;
        ip += inst.width;
    }
    try std.testing.expect(found_named_predicate);
    try std.testing.expectEqual(range_const_idx, predicate_const_idx);
    try std.testing.expect(found_ge_int);
    try std.testing.expect(found_le_int);
}

test "compiler: named scalar field and return values retain typed lowering" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Meter int range 0..100
        \\type Reading struct { value Meter }
        \\func fromReading(r Reading) Meter { return r.value }
        \\func add(r Reading, extra Meter) string {
        \\    return std.core.type_of(fromReading(r) + extra)
        \\}
    );

    const c = rt.chunk_state;
    var found_add_int = false;
    var found_named_inner = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.add_int)) found_add_int = true;
        if (op == @intFromEnum(Op.named_inner)) found_named_inner = true;
    }
    try std.testing.expect(found_add_int);
    try std.testing.expect(!found_named_inner);
}

test "compiler: indexed named scalars retain typed lowering" {
    var rt = try setup();
    defer rt.deinit();

    try compile(&rt,
        \\type Meter int range 0..100
        \\func fromArray(xs []Meter, extra Meter) Meter { return xs[0] + extra }
        \\func fromMap(xs map[string]Meter, extra Meter) Meter { return xs["main"] + extra }
    );

    const c = rt.chunk_state;
    var add_int_count: usize = 0;
    var range_check_count: usize = 0;
    var found_named_inner = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.add_int)) add_int_count += 1;
        if (op == @intFromEnum(Op.validate_named_range)) range_check_count += 1;
        if (op == @intFromEnum(Op.named_inner)) found_named_inner = true;
    }
    try std.testing.expectEqual(@as(usize, 2), add_int_count);
    try std.testing.expectEqual(@as(usize, 2), range_check_count);
    try std.testing.expect(!found_named_inner);
}

test "compiler: indexed named scalars retain nominal behavior" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Meter int range 0..100
        \\type Score int predicate func(x) { return x >= 0 and x <= 100 }
        \\func fromArray() Meter {
        \\    var xs []Meter = [Meter(40)]
        \\    return xs[0] + Meter(20)
        \\}
        \\func fromMap() string {
        \\    var xs map[string]Meter = {"main": Meter(40)}
        \\    return std.core.type_of(xs["main"] + Meter(20))
        \\}
        \\func invalidCollection() { var xs []Meter = [150] }
        \\func invalidPredicateCollection() { var xs []Score = [101] }
    );

    const array_result = try rt.callGlobal("fromArray", &.{});
    try std.testing.expect(array_result == .int);
    try std.testing.expectEqual(@as(i64, 60), array_result.int);
    const map_result = try rt.callGlobal("fromMap", &.{});
    const map_type = try vms.asStringValue(map_result);
    try std.testing.expectEqualStrings("Meter", map_type);
    try std.testing.expectError(error.RangeError, rt.callGlobal("invalidCollection", &.{}));
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("invalidPredicateCollection", &.{}));
}

test "compiler: static named method uses its declared return type" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\type Meter int
        \\type Count int
        \\func (m Meter) asCount() Count { return Count(int(m)) }
        \\func add(m Meter, n Count) Count { return m.asCount() + n }
    );

    const result = try rt.callGlobal("add", &.{ .{ .int = 2 }, .{ .int = 3 } });
    try std.testing.expect(result == .int);
    try std.testing.expectEqual(@as(i64, 5), result.int);
}

test "compiler: named float division retains typed lowering and validation" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\type Ratio float range 0.0..10.0
        \\func divide(a Ratio, b Ratio) Ratio { return a / b }
    );

    const c = rt.chunk_state;
    var found_div_float = false;
    var found_range_check = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.div_float)) found_div_float = true;
        if (op == @intFromEnum(Op.validate_named_range)) found_range_check = true;
    }
    try std.testing.expect(found_div_float);
    try std.testing.expect(found_range_check);
    try std.testing.expectError(error.RangeError, rt.callGlobal("divide", &.{ .{ .float = 8.0 }, .{ .float = 0.5 } }));
}

test "compiler: named unary result retains nominal type" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Delta int range -100..100
        \\func typeOfNegated(v Delta) string { return std.core.type_of(-v) }
    );

    const result = try rt.callGlobal("typeOfNegated", &.{.{ .int = 4 }});
    const name = try vms.asStringValue(result);
    try std.testing.expectEqualStrings("Delta", name);
}

test "compiler: named bool not retains and validates nominal type" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Enabled bool predicate func(v) { return v }
        \\func invert(v Enabled) Enabled { return not v }
        \\func typeOfEnabled(v Enabled) string { return std.core.type_of(not v) }
    );

    const type_result = try rt.callGlobal("typeOfEnabled", &.{.{ .boolean = false }});
    const name = try vms.asStringValue(type_result);
    try std.testing.expectEqualStrings("Enabled", name);
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("invert", &.{.{ .boolean = true }}));
}

test "compiler: named bitwise result retains and validates nominal type" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Mask int range 0..255
        \\func combine(a Mask, b Mask) string { return std.core.type_of((a & b) | (a ^ b)) }
    );

    const result = try rt.callGlobal("combine", &.{ .{ .int = 12 }, .{ .int = 10 } });
    const name = try vms.asStringValue(result);
    try std.testing.expectEqualStrings("Mask", name);
}

test "compiler: named math intrinsic validates its result" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Negative int range -10..-1
        \\func absolute(v Negative) int { x := std.math.abs(v); return int(x) }
    );

    try std.testing.expectError(error.RangeError, rt.callGlobal("absolute", &.{.{ .int = -2 }}));
}

test "compiler: named shifts retain the left type and validate results" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Bits int range 0..63
        \\type Count int
        \\func shiftPlain(v Bits) string { return std.core.type_of(v << 1) }
        \\func shiftNamed(v Bits, n Count) string { return std.core.type_of(v << n) }
        \\func shiftOutOfRange(v Bits) int { result := v << 6; return int(result) }
    );

    const plain = try rt.callGlobal("shiftPlain", &.{.{ .int = 2 }});
    try std.testing.expectEqualStrings("Bits", try vms.asStringValue(plain));
    const named = try rt.callGlobal("shiftNamed", &.{ .{ .int = 2 }, .{ .int = 1 } });
    try std.testing.expectEqualStrings("Bits", try vms.asStringValue(named));
    try std.testing.expectError(error.RangeError, rt.callGlobal("shiftOutOfRange", &.{.{ .int = 2 }}));
}

test "compiler: named shift count must have an int base" {
    var rt = try setup();
    defer rt.deinit();

    try std.testing.expectError(error.TypeMismatch, compile(&rt,
        \\type Bits int
        \\func invalid(v Bits) Bits { return v << 1.0 }
    ));
}

test "compiler: named min max clamp retain and validate nominal type" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Temperature float range 0.0..100.0
        \\func minType(a Temperature, b Temperature) string { return std.core.type_of(std.math.min(a, b)) }
        \\func maxType(a Temperature, b Temperature) string { return std.core.type_of(std.math.max(a, b)) }
        \\func clampType(v Temperature, lo Temperature, hi Temperature) string { return std.core.type_of(std.math.clamp(v, lo, hi)) }
        \\func invalidClamp(v Temperature) float { result := std.math.clamp(v, Temperature(110.0), Temperature(120.0)); return float(result) }
    );

    const min_result = try rt.callGlobal("minType", &.{ .{ .float = 20.0 }, .{ .float = 30.0 } });
    try std.testing.expectEqualStrings("Temperature", try vms.asStringValue(min_result));
    const max_result = try rt.callGlobal("maxType", &.{ .{ .float = 20.0 }, .{ .float = 30.0 } });
    try std.testing.expectEqualStrings("Temperature", try vms.asStringValue(max_result));
    const clamp_result = try rt.callGlobal("clampType", &.{ .{ .float = 20.0 }, .{ .float = 0.0 }, .{ .float = 80.0 } });
    try std.testing.expectEqualStrings("Temperature", try vms.asStringValue(clamp_result));
    try std.testing.expectError(error.RangeError, rt.callGlobal("invalidClamp", &.{.{ .float = 20.0 }}));
}

test "compiler: struct field access" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Point struct { x int, y int }
        \\
        \\func getX(p Point) int { return p.x }
    );
    const c = rt.chunk_state;

    var found_get_field = false;
    var i: usize = 0;
    while (i < c.code_len) : (i += 1) {
        if (c.code[i] == @intFromEnum(Op.get_field)) {
            found_get_field = true;
            break;
        }
    }
    try std.testing.expect(found_get_field);
}

test "compiler: named return values" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func divide(a int, b int) (result int, err error) {
        \\    if b == 0 { return 0, "division by zero" }
        \\    result = a / b
        \\    return
        \\}
    );
    _ = &rt;

    const c = rt.chunk_state;
    try std.testing.expect(c.code_len > 0);
    try std.testing.expectEqual(@intFromEnum(Op.halt), c.code[c.code_len - 1]);
}

test "compiler: multi-value return" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func pair() (int, int) { return 1, 2 }
    );
    const c = rt.chunk_state;

    var found_build_tuple = false;
    var i: usize = 0;
    while (i < c.code_len) : (i += 1) {
        if (c.code[i] == @intFromEnum(Op.build_tuple)) found_build_tuple = true;
    }
    try std.testing.expect(found_build_tuple);
}

test "compiler: for-in loop bytecode" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func sum(a []int) int {
        \\    var s = 0
        \\    for x in a { s = s + x }
        \\    return s
        \\}
    );
    const c = rt.chunk_state;

    var found_iter_init = false;
    var i: usize = 0;
    while (i < c.code_len) : (i += 1) {
        if (c.code[i] == @intFromEnum(Op.iter_init)) {
            found_iter_init = true;
            break;
        }
    }
    try std.testing.expect(found_iter_init);
}

test "compiler: nested function has correct ip" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func outer() int {
        \\    func inner() int { return 99 }
        \\    return inner()
        \\}
    );
    _ = &rt;

    const c = rt.chunk_state;
    var i: usize = 0;
    while (i < c.const_count) : (i += 1) {
        if (c.consts[i] == .object and c.consts[i].object.* == .function) {
            const func = c.consts[i].object.*.function;
            try std.testing.expect(func.ip < c.code_len);
        }
    }
}

// ── Fusion helper ─────────────────────────────────────────────────────────

fn runSrc(rt: *Runtime, src: []const u8) !void {
    try rt.run(src);
}

fn findFirstCallIc(c: *chunk.State) ?struct { offset: usize, slot: u16 } {
    var ip: usize = 0;
    while (ip < c.code_len) {
        const op: Op = @enumFromInt(c.code[ip]);
        if (op == .call) {
            if (ip + 3 >= c.code_len) return null;
            const slot: u16 = (@as(u16, c.code[ip + 2]) << 8) | c.code[ip + 3];
            return .{ .offset = ip, .slot = slot };
        }
        const decoded = c.decodeAt(ip) catch return null;
        ip += decoded.width;
    }
    return null;
}

// ── const_eq fusion ───────────────────────────────────────────────────────

test "compiler: const_eq fusion fires" {
    var rt = try setup();
    defer rt.deinit();
    // Global variable: emits get_global (not get_local), so the triple fusion
    // cannot fire; const_eq remains as a standalone fused opcode.
    try compile(&rt,
        \\var g = 10
        \\func f() bool { return g == 42 }
    );
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.const_eq)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "compiler: const_eq fusion result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt, "func f(x int) bool { return x == 42 }");
    const r1 = try rt.callGlobal("f", &.{.{ .int = 42 }});
    try std.testing.expect(r1 == .boolean and r1.boolean);
    const r2 = try rt.callGlobal("f", &.{.{ .int = 99 }});
    try std.testing.expect(r2 == .boolean and !r2.boolean);
}

test "compiler: typed primitive call warms call inline cache after execution" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func inc(x int) int { return x + 1 }
        \\n := 0
        \\for i := 0; i < 100; i += 1 {
        \\    n = inc(n)
        \\}
    );

    const before = findFirstCallIc(rt.chunk_state) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 0xFFFF), before.slot);

    try runSrc(&rt,
        \\func inc(x int) int { return x + 1 }
        \\n := 0
        \\for i := 0; i < 100; i += 1 {
        \\    n = inc(n)
        \\}
    );

    const after = findFirstCallIc(rt.chunk_state) orelse return error.TestUnexpectedResult;
    try std.testing.expect(after.slot != 0xFFFF);
}

test "compiler: warmed typed primitive call still enforces arg types" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.TypeError, rt.run(
        \\func inc(x int) int { return x + 1 }
        \\v := 1
        \\func step() int { return inc(v) }
        \\step()
        \\v = "x"
        \\step()
    ));
}

// findFusedSubCallIc scans bytecode for get_local_const_sub_call or
// call_global_local_sub_const and returns the call IC slot embedded in that opcode.
fn findFusedSubCallIc(c: *chunk.State) ?struct { op: Op, offset: usize, slot: u16 } {
    var ip: usize = 0;
    while (ip < c.code_len) {
        const op: Op = @enumFromInt(c.code[ip]);
        if (op == .get_local_const_sub_call) {
            // layout: [op][slot][const_op][const_hi][const_lo][argc][ic_hi][ic_lo]
            if (ip + 7 >= c.code_len) return null;
            const slot: u16 = (@as(u16, c.code[ip + 6]) << 8) | c.code[ip + 7];
            return .{ .op = op, .offset = ip, .slot = slot };
        }
        if (op == .call_global_local_sub_const) {
            // layout: [op][nh][nl][gh][gl][sub_op][slot][cop][ch][cl][argc][ic_hi][ic_lo]
            if (ip + 12 >= c.code_len) return null;
            const slot: u16 = (@as(u16, c.code[ip + 11]) << 8) | c.code[ip + 12];
            return .{ .op = op, .offset = ip, .slot = slot };
        }
        const decoded = c.decodeAt(ip) catch return null;
        ip += decoded.width;
    }
    return null;
}

test "compiler: fused global-sub call warms call inline cache after execution" {
    var rt = try setup();
    defer rt.deinit();
    // Use inc(n-1) + inc(n-2): neither call is in tail position (add_ret follows),
    // so tryTailCall does not fire and both calls go through performCallIC.
    try compile(&rt,
        \\func inc(x int) int { return x + 1 }
        \\func run(n int) int { return inc(n - 1) + inc(n - 2) }
    );
    const before = findFusedSubCallIc(rt.chunk_state) orelse return error.TestUnexpectedResult;
    try std.testing.expect(before.op == .call_global_local_sub_const);
    try std.testing.expectEqual(@as(u16, 0xFFFF), before.slot);

    try runSrc(&rt,
        \\func inc(x int) int { return x + 1 }
        \\func run(n int) int { return inc(n - 1) + inc(n - 2) }
        \\_ = run(5)
    );
    const after = findFusedSubCallIc(rt.chunk_state) orelse return error.TestUnexpectedResult;
    try std.testing.expect(after.slot != 0xFFFF);
}

test "compiler: fused global-sub call IC gives correct result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func double(x int) int { return x * 2 }
        \\func run(n int) int { return double(n - 1) }
    );
    const r = try rt.callGlobal("run", &.{.{ .int = 6 }});
    try std.testing.expect(r == .int and r.int == 10);
}

// ── const_sub fusion ──────────────────────────────────────────────────────

test "compiler: const_sub fusion fires" {
    var rt = try setup();
    defer rt.deinit();
    // Global variable: emits get_global (not get_local), so the triple fusion
    // cannot fire; const_sub remains as a standalone fused opcode.
    try compile(&rt,
        \\var g = 10
        \\func f() int { return g - 1 }
    );
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.const_sub)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "compiler: const_sub fusion result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt, "func f(x int) int { return x - 1 }");
    const r = try rt.callGlobal("f", &.{.{ .int = 10 }});
    try std.testing.expect(r == .int and r.int == 9);
}

// ── get_local_const_eq triple fusion ──────────────────────────────────────

test "compiler: get_local_const_eq triple fusion fires" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt, "func f(x int) bool { return x == 0 }");
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_eq)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "compiler: get_local_const_eq triple fusion result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt, "func f(x int) bool { return x == 0 }");
    const r1 = try rt.callGlobal("f", &.{.{ .int = 0 }});
    try std.testing.expect(r1 == .boolean and r1.boolean);
    const r2 = try rt.callGlobal("f", &.{.{ .int = 5 }});
    try std.testing.expect(r2 == .boolean and !r2.boolean);
}

// ── get_local_const_sub triple fusion ─────────────────────────────────────

test "compiler: get_local_const_sub triple fusion fires" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt, "func f(x int) int { return x - 1 }");
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_sub)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "compiler: get_local_const_sub triple fusion result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt, "func f(x int) int { return x - 1 }");
    const r = try rt.callGlobal("f", &.{.{ .int = 10 }});
    try std.testing.expect(r == .int and r.int == 9);
}

// ── get_local_const_add triple fusion ─────────────────────────────────────

test "compiler: get_local_const_add triple fusion fires" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt, "func f(x int) int { return x + 1 }");
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_add)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "compiler: get_local_const_add triple fusion result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt, "func f(x int) int { return x + 1 }");
    const r = try rt.callGlobal("f", &.{.{ .int = 10 }});
    try std.testing.expect(r == .int and r.int == 11);
}

// ── get_local_const_lt triple fusion ──────────────────────────────────────

test "compiler: get_local_const_lt triple fusion fires" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt, "func f(x int) bool { return x < 5 }");
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_lt)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "compiler: get_local_const_lt triple fusion result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt, "func f(x int) bool { return x < 5 }");
    const r1 = try rt.callGlobal("f", &.{.{ .int = 3 }});
    try std.testing.expect(r1 == .boolean and r1.boolean);
    const r2 = try rt.callGlobal("f", &.{.{ .int = 10 }});
    try std.testing.expect(r2 == .boolean and !r2.boolean);
}

// ── get_local_const_eq_jif_pop quad fusion ────────────────────────────────

test "compiler: get_local_const_eq_jif_pop quad fusion fires" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f(x int) int {
        \\    if x == 0 { return 1 }
        \\    return 2
        \\}
    );
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_eq_jif_pop)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "compiler: get_local_const_eq_jif_pop quad fusion result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f(x int) int {
        \\    if x == 0 { return 1 }
        \\    return 2
        \\}
    );
    const r1 = try rt.callGlobal("f", &.{.{ .int = 0 }});
    try std.testing.expect(r1 == .int and r1.int == 1);
    const r2 = try rt.callGlobal("f", &.{.{ .int = 5 }});
    try std.testing.expect(r2 == .int and r2.int == 2);
}

// ── get_local_const_lt_jif_pop quad fusion ────────────────────────────────

test "compiler: get_local_const_lt_jif_pop quad fusion fires" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f(x int) int {
        \\    if x < 5 { return 10 }
        \\    return 20
        \\}
    );
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_lt_jif_pop)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "compiler: get_local_const_lt_jif_pop quad fusion result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f(x int) int {
        \\    if x < 5 { return 10 }
        \\    return 20
        \\}
    );
    const r1 = try rt.callGlobal("f", &.{.{ .int = 3 }});
    try std.testing.expect(r1 == .int and r1.int == 10);
    const r2 = try rt.callGlobal("f", &.{.{ .int = 10 }});
    try std.testing.expect(r2 == .int and r2.int == 20);
}

test "compiler: typed int compound mul/div opcodes fire" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int {
        \\    var x int = 8
        \\    x += 2
        \\    x -= 3
        \\    x *= 4
        \\    x /= 7
        \\    return x
        \\}
    );
    const c = rt.chunk_state;
    var found_mul = false;
    var found_div = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.mul_int)) found_mul = true;
        if (op == @intFromEnum(Op.div_int)) found_div = true;
    }
    try std.testing.expect(found_mul);
    try std.testing.expect(found_div);
}

test "compiler: typed int compound arithmetic result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    var x int = 8
        \\    x += 2
        \\    x -= 3
        \\    x *= 4
        \\    x /= 7
        \\    return x
        \\}
    );
    const r = try rt.callGlobal("f", &.{});
    try std.testing.expect(r == .int and r.int == 4);
}

test "compiler: typed int expression add sub mul div opcodes fire" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func addsub(a int, b int) int {
        \\    return a + b - a
        \\}
        \\
        \\func muldiv(a int, b int) float {
        \\    return (a * b) / a
        \\}
    );
    const c = rt.chunk_state;
    var found_add = false;
    var found_sub = false;
    var found_mul = false;
    var found_div = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.add_int)) found_add = true;
        if (op == @intFromEnum(Op.sub_int)) found_sub = true;
        if (op == @intFromEnum(Op.mul_int)) found_mul = true;
        if (op == @intFromEnum(Op.div_int)) found_div = true;
    }
    try std.testing.expect(found_add);
    try std.testing.expect(found_sub);
    try std.testing.expect(found_mul);
    try std.testing.expect(found_div);
}

test "compiler: typed int expression arithmetic result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func addsub(a int, b int) int {
        \\    return a + b - a
        \\}
        \\
        \\func muldiv(a int, b int) float {
        \\    return (a * b) / a
        \\}
    );
    const r1 = try rt.callGlobal("addsub", &.{ .{ .int = 8 }, .{ .int = 3 } });
    try std.testing.expect(r1 == .int and r1.int == 3);
    const r2 = try rt.callGlobal("muldiv", &.{ .{ .int = 8 }, .{ .int = 3 } });
    try std.testing.expect(r2 == .float);
    try std.testing.expectApproxEqRel(@as(f64, 3.0), r2.float, 1e-12);
}

test "compiler: typed int expression keeps const add fusion" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f(x int) int {
        \\    return x + 1
        \\}
    );
    const c = rt.chunk_state;
    var found_const_add = false;
    var found_typed_add = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_add) or op == @intFromEnum(Op.const_add)) found_const_add = true;
        if (op == @intFromEnum(Op.add_int)) found_typed_add = true;
    }
    try std.testing.expect(found_const_add);
    try std.testing.expect(!found_typed_add);
}

test "compiler: typed int expression comparison opcodes fire" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func cmp(a int, b int) bool {
        \\    return a == b or a != b or a < b or a > b
        \\}
    );
    const c = rt.chunk_state;
    var found_eq = false;
    var found_ne = false;
    var found_lt = false;
    var found_gt = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.eq_int)) found_eq = true;
        if (op == @intFromEnum(Op.ne_int)) found_ne = true;
        if (op == @intFromEnum(Op.lt_int)) found_lt = true;
        if (op == @intFromEnum(Op.gt_int)) found_gt = true;
    }
    try std.testing.expect(found_eq);
    try std.testing.expect(found_ne);
    try std.testing.expect(found_lt);
    try std.testing.expect(found_gt);
}

test "compiler: typed int expression comparison result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func cmp(a int, b int) bool {
        \\    return a == b or a != b or a < b or a > b
        \\}
    );
    const r1 = try rt.callGlobal("cmp", &.{ .{ .int = 4 }, .{ .int = 4 } });
    try std.testing.expect(r1 == .boolean and r1.boolean);
    const r2 = try rt.callGlobal("cmp", &.{ .{ .int = 3 }, .{ .int = 4 } });
    try std.testing.expect(r2 == .boolean and r2.boolean);
    const r3 = try rt.callGlobal("cmp", &.{ .{ .int = 5 }, .{ .int = 4 } });
    try std.testing.expect(r3 == .boolean and r3.boolean);
}

test "compiler: typed int eqz opcode fires for computed zero compare" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func cmp(a int, b int) bool {
        \\    return (a - b) == 0 or (a - b) != 0
        \\}
    );
    const c = rt.chunk_state;
    var found_eqz = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.eqz_int)) {
            found_eqz = true;
            break;
        }
    }
    try std.testing.expect(found_eqz);
}

test "compiler: typed int eqz result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func isZero(a int, b int) bool {
        \\    return (a - b) == 0
        \\}
        \\
        \\func notZero(a int, b int) bool {
        \\    return (a - b) != 0
        \\}
    );
    const r1 = try rt.callGlobal("isZero", &.{ .{ .int = 4 }, .{ .int = 4 } });
    try std.testing.expect(r1 == .boolean and r1.boolean);
    const r2 = try rt.callGlobal("isZero", &.{ .{ .int = 4 }, .{ .int = 3 } });
    try std.testing.expect(r2 == .boolean and !r2.boolean);
    const r3 = try rt.callGlobal("notZero", &.{ .{ .int = 4 }, .{ .int = 3 } });
    try std.testing.expect(r3 == .boolean and r3.boolean);
}

test "compiler: typed int zero compare opcodes fire" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func cmp(a int, b int) bool {
        \\    return (a - b) == 0 or (a - b) != 0 or (a - b) < 0 or (a - b) > 0 or (a - b) <= 0 or (a - b) >= 0
        \\}
    );
    const c = rt.chunk_state;
    var found_eqz = false;
    var found_nez = false;
    var found_ltz = false;
    var found_gtz = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.eqz_int)) found_eqz = true;
        if (op == @intFromEnum(Op.nez_int)) found_nez = true;
        if (op == @intFromEnum(Op.ltz_int)) found_ltz = true;
        if (op == @intFromEnum(Op.gtz_int)) found_gtz = true;
    }
    try std.testing.expect(found_eqz);
    try std.testing.expect(found_nez);
    try std.testing.expect(found_ltz);
    try std.testing.expect(found_gtz);
}

test "compiler: typed int zero compare result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func isNeg(a int, b int) bool {
        \\    return (a - b) < 0
        \\}
        \\
        \\func isPos(a int, b int) bool {
        \\    return (a - b) > 0
        \\}
        \\
        \\func isNonPos(a int, b int) bool {
        \\    return (a - b) <= 0
        \\}
        \\
        \\func isNonNeg(a int, b int) bool {
        \\    return (a - b) >= 0
        \\}
        \\
        \\func isNonZero(a int, b int) bool {
        \\    return (a - b) != 0
        \\}
    );
    const r1 = try rt.callGlobal("isNeg", &.{ .{ .int = 3 }, .{ .int = 4 } });
    try std.testing.expect(r1 == .boolean and r1.boolean);
    const r2 = try rt.callGlobal("isPos", &.{ .{ .int = 5 }, .{ .int = 4 } });
    try std.testing.expect(r2 == .boolean and r2.boolean);
    const r3 = try rt.callGlobal("isNonPos", &.{ .{ .int = 4 }, .{ .int = 4 } });
    try std.testing.expect(r3 == .boolean and r3.boolean);
    const r4 = try rt.callGlobal("isNonNeg", &.{ .{ .int = 4 }, .{ .int = 4 } });
    try std.testing.expect(r4 == .boolean and r4.boolean);
    const r5 = try rt.callGlobal("isNonZero", &.{ .{ .int = 4 }, .{ .int = 3 } });
    try std.testing.expect(r5 == .boolean and r5.boolean);
}

test "compiler: typed int comparison keeps const fusion" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f(x int) bool {
        \\    return x == 1 or x != 2 or x < 2 or x > 0
        \\}
    );
    const c = rt.chunk_state;
    var found_const = false;
    var found_typed = false;
    var i: usize = 0;
    while (i < c.code_len) {
        const inst = chunk_decoder.decodeAt(c, i) catch break;
        switch (inst.op) {
            .get_local_const_eq, .get_local_const_lt, .get_local_const_gt, .const_eq, .const_lt, .const_gt => found_const = true,
            .eq_int, .ne_int, .lt_int, .gt_int => found_typed = true,
            else => {},
        }
        i += inst.width;
    }
    try std.testing.expect(found_const);
    try std.testing.expect(!found_typed);
}

test "compiler: typed float compound mul/div opcodes fire" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() float {
        \\    var x float = 8.0
        \\    x += 2.0
        \\    x -= 3.0
        \\    x *= 4.0
        \\    x /= 7.0
        \\    return x
        \\}
    );
    const c = rt.chunk_state;
    var found_mul = false;
    var found_div = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.mul_float)) found_mul = true;
        if (op == @intFromEnum(Op.div_float)) found_div = true;
    }
    try std.testing.expect(found_mul);
    try std.testing.expect(found_div);
}

test "compiler: typed float expression add sub mul div opcodes fire" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func addsub(a float, b float) float {
        \\    return a + b - a
        \\}
        \\
        \\func muldiv(a float, b float) float {
        \\    return (a * b) / a
        \\}
    );
    const c = rt.chunk_state;
    var found_add = false;
    var found_sub = false;
    var found_mul = false;
    var found_div = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.add_float)) found_add = true;
        if (op == @intFromEnum(Op.sub_float)) found_sub = true;
        if (op == @intFromEnum(Op.mul_float)) found_mul = true;
        if (op == @intFromEnum(Op.div_float)) found_div = true;
    }
    try std.testing.expect(found_add);
    try std.testing.expect(found_sub);
    try std.testing.expect(found_mul);
    try std.testing.expect(found_div);
}

test "compiler: typed float compound arithmetic result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() float {
        \\    var x float = 8.0
        \\    x += 2.0
        \\    x -= 3.0
        \\    x *= 4.0
        \\    x /= 7.0
        \\    return x
        \\}
    );
    const r = try rt.callGlobal("f", &.{});
    try std.testing.expect(r == .float);
    try std.testing.expectApproxEqRel(@as(f64, 4.0), r.float, 1e-12);
}

test "compiler: typed float expression arithmetic result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func addsub(a float, b float) float {
        \\    return a + b - a
        \\}
        \\
        \\func muldiv(a float, b float) float {
        \\    return (a * b) / a
        \\}
    );
    const r1 = try rt.callGlobal("addsub", &.{ .{ .float = 8.0 }, .{ .float = 3.5 } });
    try std.testing.expect(r1 == .float);
    try std.testing.expectApproxEqRel(@as(f64, 3.5), r1.float, 1e-12);
    const r2 = try rt.callGlobal("muldiv", &.{ .{ .float = 8.0 }, .{ .float = 3.5 } });
    try std.testing.expect(r2 == .float);
    try std.testing.expectApproxEqRel(@as(f64, 3.5), r2.float, 1e-12);
}

test "compiler: typed float expression comparison opcodes fire" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func cmp(a float, b float) bool {
        \\    return a == b or a != b or a < b or a > b
        \\}
    );
    const c = rt.chunk_state;
    var found_eq = false;
    var found_ne = false;
    var found_lt = false;
    var found_gt = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.eq_float)) found_eq = true;
        if (op == @intFromEnum(Op.ne_float)) found_ne = true;
        if (op == @intFromEnum(Op.lt_float)) found_lt = true;
        if (op == @intFromEnum(Op.gt_float)) found_gt = true;
    }
    try std.testing.expect(found_eq);
    try std.testing.expect(found_ne);
    try std.testing.expect(found_lt);
    try std.testing.expect(found_gt);
}

test "compiler: typed float expression comparison result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func cmp(a float, b float) bool {
        \\    return a == b or a != b or a < b or a > b
        \\}
    );
    const r1 = try rt.callGlobal("cmp", &.{ .{ .float = 4.0 }, .{ .float = 4.0 } });
    try std.testing.expect(r1 == .boolean and r1.boolean);
    const r2 = try rt.callGlobal("cmp", &.{ .{ .float = 3.0 }, .{ .float = 4.0 } });
    try std.testing.expect(r2 == .boolean and r2.boolean);
    const r3 = try rt.callGlobal("cmp", &.{ .{ .float = 5.0 }, .{ .float = 4.0 } });
    try std.testing.expect(r3 == .boolean and r3.boolean);
}

// ── expression depth limit ──────────────────────────────────────────────────

test "compiler: expression too deep returns error" {
    var rt = try setup();
    defer rt.deinit();
    // Build a deeply nested unary expression: var x = -(-(-(-...-1...)))
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    const prefix = "var x = ";
    @memcpy(buf[i .. i + prefix.len], prefix);
    i += prefix.len;
    const depth = 257;
    var j: usize = 0;
    while (j < depth) : (j += 1) {
        buf[i] = '-';
        buf[i + 1] = '(';
        i += 2;
    }
    buf[i] = '1';
    i += 1;
    j = 0;
    while (j < depth) : (j += 1) {
        buf[i] = ')';
        i += 1;
    }
    const result = compile(&rt, buf[0..i]);
    try std.testing.expectError(error.ExpressionTooDeep, result);
}

test "compiler: invalid character reports direct scanner error" {
    var rt = try setup();
    defer rt.deinit();

    const result = compile(&rt, "@");
    try std.testing.expectError(error.InvalidChar, result);
}

test "compiler: unterminated string reports direct scanner error" {
    var rt = try setup();
    defer rt.deinit();

    const result = compile(&rt, "\"unterminated");
    try std.testing.expectError(error.UnterminatedString, result);
}

test {
    _ = @import("lang/native/fs_state.zig");
}

// Regression for #101: .string immortality invariant.
// After the fix, const_add string concatenation must NOT produce a .string
// view into the fmt_scratch buffer; it should always allocate a dyn_string.
// This test compiles a chain and verifies the result is a GC object.
test "string literal chain folds to a single compile-time constant" {
    var rt = try setup();
    defer rt.deinit();
    // "a"+"b"+"c" folds at compile time: the function returns Value.string (immortal),
    // not a dyn_string object allocated at runtime.
    try rt.run(
        \\func f() string {
        \\    return "a" + "b" + "c"
        \\}
    );

    const v = try rt.callGlobal("f", &[_]Value{});
    try std.testing.expect(v == .string);
    try std.testing.expectEqualStrings("abc", v.string.bytes);
}

test "non-ASCII string iteration is zero-alloc and produces correct chars" {
    var rt = try setup();
    defer rt.deinit();
    // "åäö" has 3 multi-byte runes. Iterating with for...in must not call
    // makeDynString, and must not panic on a null-source string_view iterator
    // (regression: aa0bf9f made static-string slices string_views with null
    // source, but iterNext1/iterNext2 used it.source.? which would panic).
    try rt.run(
        \\func collect_static() string {
        \\    s := "åäö"
        \\    out := ""
        \\    for ch in s { out = out + ch }
        \\    return out
        \\}
        \\func collect_slice() string {
        \\    s := "åäö"
        \\    out := ""
        \\    for ch in s[0:2] { out = out + ch }
        \\    return out
        \\}
    );
    const vmst = @import("lang/vm_state.zig");
    const v1 = try rt.callGlobal("collect_static", &[_]Value{});
    try std.testing.expectEqualStrings("åäö", try vmst.asStringValue(v1));
    const v2 = try rt.callGlobal("collect_slice", &[_]Value{});
    try std.testing.expectEqualStrings("åä", try vmst.asStringValue(v2));
}

// ── Dispatch gas: op budget + trace hook (#186) ──────────────────────────────

test "op budget: small budget stops runaway loop, generous budget does not" {
    var rt = try setup();
    defer rt.deinit();
    rt.setPolicy(.{ .max_ops = 100 });
    const r = rt.run("for {}");
    try std.testing.expectError(error.InstructionBudgetExceeded, r);

    var rt2 = try setup();
    defer rt2.deinit();
    rt2.setPolicy(.{ .max_ops = 1_000_000 });
    try rt2.run(
        \\t := 0
        \\for i := 0; i < 100; i += 1 { t += i }
    );
}

var g_trace_hits: u32 = 0;
fn testTraceFn(userdata: ?*anyopaque, handle: i32, line: i32, col: i32) callconv(.c) void {
    _ = userdata;
    _ = handle;
    _ = line;
    _ = col;
    g_trace_hits += 1;
}

test "trace hook fires per line when installed, not at all when cleared" {
    const io_mod = @import("runtime/io.zig");
    var rt = try setup();
    defer rt.deinit();

    g_trace_hits = 0;
    io_mod.setTrace(testTraceFn, null, -1);
    defer io_mod.clearTrace();
    try rt.run(
        \\a := 1
        \\b := 2
        \\c := a + b
    );
    try std.testing.expect(g_trace_hits >= 3);

    io_mod.clearTrace();
    const hits_after_clear = g_trace_hits;
    try rt.run("d := 4");
    try std.testing.expectEqual(hits_after_clear, g_trace_hits);
}

// ── Multi-runtime isolation (#190) ─────────────────────────────────────────

const value_mod = @import("lang/value.zig");
const fs_state_mod = @import("lang/native/fs_state.zig");

const isolation_src_a =
    \\std := import("std")
    \\type Celsius int
    \\c := Celsius(21)
    \\func temp() Celsius { return c }
    \\func hit(s string) bool { return std.regexp.match("^ab+c$", s) }
;
const isolation_src_b =
    \\std := import("std")
    \\type Celsius int
    \\c := Celsius(42)
    \\func temp() Celsius { return c }
    \\func hit(s string) bool { return std.regexp.match("^xy+z$", s) }
;

test "two runtimes stay isolated across interleaved calls (#190)" {
    var a = try setup();
    defer a.deinit();
    var b = try setup();
    defer b.deinit();

    try a.run(isolation_src_a);
    try b.run(isolation_src_b);

    // Globals and named scalars: each callGlobal activates its runtime, so
    // the inline named_scalar decode must resolve through that runtime's
    // object pool. Read inner values immediately, while the owner is active.
    const ta = try a.callGlobal("temp", &.{});
    const ia = ta.namedInner() orelse ta;
    try std.testing.expect(ia == .int);
    try std.testing.expectEqual(@as(i64, 21), ia.int);

    const tb = try b.callGlobal("temp", &.{});
    const ib = tb.namedInner() orelse tb;
    try std.testing.expect(ib == .int);
    try std.testing.expectEqual(@as(i64, 42), ib.int);

    // Back to A: its state must be untouched by B's run.
    const ta2 = try a.callGlobal("temp", &.{});
    const ia2 = ta2.namedInner() orelse ta2;
    try std.testing.expect(ia2 == .int);
    try std.testing.expectEqual(@as(i64, 21), ia2.int);

    // Regexp pattern caches are per-runtime: each runtime matches only its
    // own pattern even though both scripts call the same function name.
    const abbc: Value = .{ .string = value_mod.staticSS("abbc") };
    const xyyz: Value = .{ .string = value_mod.staticSS("xyyz") };
    const ra1 = try a.callGlobal("hit", &.{abbc});
    try std.testing.expect(ra1 == .boolean and ra1.boolean);
    const rb1 = try b.callGlobal("hit", &.{abbc});
    try std.testing.expect(rb1 == .boolean and !rb1.boolean);
    const ra2 = try a.callGlobal("hit", &.{xyyz});
    try std.testing.expect(ra2 == .boolean and !ra2.boolean);
    const rb2 = try b.callGlobal("hit", &.{xyyz});
    try std.testing.expect(rb2 == .boolean and rb2.boolean);
}

test "per-runtime fs mount tables switch with activation (#190)" {
    var a = try setup();
    defer a.deinit();
    var b = try setup();
    defer b.deinit();

    try fs_state_mod.addMountToState(&a.fs_mounts, "data", "/a-root");
    try fs_state_mod.addMountToState(&b.fs_mounts, "data", "/b-root");

    var buf: [256]u8 = undefined;
    a.activate();
    b.activate();
    // VM-path isolation: activate() binds each runtime's vm_state.fs_es to
    // its own mount table (the Runtime struct may move between init and the
    // first activate, so binding happens at the pinned-address entry points).
    // Each binding stays correct regardless of which runtime activated last.
    try std.testing.expectEqualStrings("/a-root/f", try fs_state_mod.resolve(a.vm_state.fs_es, "data/f", &buf));
    try std.testing.expectEqualStrings("/b-root/f", try fs_state_mod.resolve(b.vm_state.fs_es, "data/f", &buf));
    // The entry-layer active pointer follows the most recent activate().
    try std.testing.expectEqualStrings("/b-root/f", try fs_state_mod.resolve(fs_state_mod.activeState(), "data/f", &buf));
    a.activate();
    try std.testing.expectEqualStrings("/a-root/f", try fs_state_mod.resolve(fs_state_mod.activeState(), "data/f", &buf));
}

// Worker for the concurrent isolation test: builds its own Runtime, runs a
// GC-heavy script parameterized by seed, and checks every call's result so
// any cross-thread contamination shows up as a wrong value.
fn isolationWorker(seed: i64, failed: *std.atomic.Value(bool)) void {
    var src_buf: [512]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf,
        \\std := import("std")
        \\type T int
        \\base := T({d})
        \\func step(i int) int {{
        \\    s := ""
        \\    for j := 0; j < 40; j += 1 {{ s += "x" }}
        \\    t := T(i)
        \\    return std.core.len(s) + int(t) + int(base)
        \\}}
    , .{seed}) catch {
        failed.store(true, .seq_cst);
        return;
    };

    var rt: Runtime = .{};
    rt.initWithConfig(.{}, heap.HeapSize, heap.MaxObjects, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.heap.page_allocator) catch {
        failed.store(true, .seq_cst);
        return;
    };
    defer rt.deinit();

    rt.run(src) catch {
        failed.store(true, .seq_cst);
        return;
    };
    var i: i64 = 0;
    while (i < 300) : (i += 1) {
        const r = rt.callGlobal("step", &.{.{ .int = i }}) catch {
            failed.store(true, .seq_cst);
            return;
        };
        if (r != .int or r.int != 40 + i + seed) {
            failed.store(true, .seq_cst);
            return;
        }
    }
}

test "two runtimes run concurrently on separate threads (#190)" {
    var failed = std.atomic.Value(bool).init(false);
    const t1 = try std.Thread.spawn(.{}, isolationWorker, .{ @as(i64, 1000), &failed });
    const t2 = try std.Thread.spawn(.{}, isolationWorker, .{ @as(i64, 5000), &failed });
    t1.join();
    t2.join();
    try std.testing.expect(!failed.load(.seq_cst));
}

test "compiler: named-type local method call lowers to direct global call (3b)" {
    var rt = try setup();
    defer rt.deinit();

    try compileWithSession(&rt,
        \\type Meters int
        \\func (m Meters) doubled() Meters { return Meters(int(m) * 2) }
        \\func go() {
        \\    x := Meters(5)
        \\    x.doubled()
        \\}
    , "");

    const c = rt.chunk_state;
    var found_swap = false;
    var found_invoke_method = false;
    var found_meters_doubled = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .swap) found_swap = true;
        if (inst.op == .invoke_method) found_invoke_method = true;
        if (inst.op == .get_global and inst.const_index != null) {
            const name = (try chunk.constAt(inst.const_index.?)).string.bytes;
            if (std.mem.eql(u8, name, "Meters.doubled")) found_meters_doubled = true;
        }
        ip += inst.width;
    }
    try std.testing.expect(found_swap);
    try std.testing.expect(found_meters_doubled);
    try std.testing.expect(!found_invoke_method);
}

test "compiler: named-type subtype method call resolves inherited method via chain (3b)" {
    var rt = try setup();
    defer rt.deinit();

    try compileWithSession(&rt,
        \\type Meters int
        \\func (m Meters) times(n int) int { return int(m) * n }
        \\subtype SmallMeters Meters range 0..100
        \\func go() {
        \\    x := SmallMeters(5)
        \\    x.times(3)
        \\}
    , "");

    const c = rt.chunk_state;
    var found_swap = false;
    var found_invoke_method = false;
    var found_meters_times = false;
    var found_small_meters_times = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .swap) found_swap = true;
        if (inst.op == .invoke_method) found_invoke_method = true;
        if (inst.op == .get_global and inst.const_index != null) {
            const name = (try chunk.constAt(inst.const_index.?)).string.bytes;
            if (std.mem.eql(u8, name, "Meters.times")) found_meters_times = true;
            if (std.mem.eql(u8, name, "SmallMeters.times")) found_small_meters_times = true;
        }
        ip += inst.width;
    }
    try std.testing.expect(found_swap);
    try std.testing.expect(found_meters_times);
    try std.testing.expect(!found_small_meters_times);
    try std.testing.expect(!found_invoke_method);
}

test "compiler: defer named-type qualified method lowers to direct deferred call" {
    var rt = try setup();
    defer rt.deinit();

    try compileWithSession(&rt,
        \\type MyInt int
        \\func (m MyInt) show() {}
        \\func run() {
        \\    defer MyInt.show(MyInt(42))
        \\}
    , "");

    const c = rt.chunk_state;
    var found_defer_call = false;
    var found_defer_invoke_method = false;
    var found_show_global = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        if (inst.op == .defer_call) found_defer_call = true;
        if (inst.op == .defer_invoke_method) found_defer_invoke_method = true;
        if (inst.op == .get_global and inst.const_index != null) {
            const name = (try chunk.constAt(inst.const_index.?)).string.bytes;
            if (std.mem.eql(u8, name, "MyInt.show")) found_show_global = true;
        }
        ip += inst.width;
    }

    try std.testing.expect(found_defer_call);
    try std.testing.expect(found_show_global);
    try std.testing.expect(!found_defer_invoke_method);
}
