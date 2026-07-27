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
const fusion_pass = @import("lang/fusion_pass.zig");
const chunk_decoder = @import("lang/chunk_decoder.zig");
const gbc_writer = @import("lang/gbc_writer.zig");
const gbc_reader = @import("lang/gbc_reader.zig");
const net_state = @import("lang/native/net_state.zig");

fn setup() !Runtime {
    var rt: Runtime = .{};
    // allow_io=false: this file has no setWriteOverrides capture, so any test
    // that called println with real I/O allowed would write raw bytes to fd 1
    // — the same fd zig's --listen=- test protocol uses for its own message
    // framing, corrupting it (diagnosed 2026-07-13, see feedback_allow_io_tests
    // memory). Tests needing real I/O must set allow_io=true explicitly AND
    // wrap execution in a setWriteOverrides-guarded capture, same as
    // chaos_spec_test.zig's runWithCapture.
    try rt.initWithConfig(.{ .allow_io = false }, heap.HeapSize, heap.MaxObjects, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.testing.allocator);
    return rt;
}

fn compile(rt: *Runtime, src: []const u8) !void {
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    var compiler = Compiler.init(src, chunk.g_state, heap.g_state, .{});
    try compiler.compile(true);
    try fusion_pass.fuse(chunk.g_state, rt.vm_state.allocator);
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

    var compiler = Compiler.init(src, chunk.g_state, heap.g_state, .{
        .module_prefix = path,
        .module_ctx = &session,
        .resolve_import = module_compile.Session.resolveImportOpaque,
        .has_module_export = module_compile.hasModuleExport,
        .resolve_module_type = module_compile.resolveModuleTypeKind,
    });
    try compiler.compile(true);
    try fusion_pass.fuse(chunk.g_state, rt.vm_state.allocator);
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

// std.sort.by (and sort_asc/sort_desc) used to clone the input array via
// cloneArraySlice into a raw, unrooted managed slice, then loop over it
// while calling arbitrary user comparator code (which allocates). If that
// allocation pressure forced a heap compaction, the clone — invisible to
// the compaction walk, since no Object owned it yet — could be silently
// overwritten while native/sort.zig kept reading/writing through the now-
// stale slice. Fixed by allocating the working copy as a GC-visible,
// temp-rooted array up front (see native/sort.zig).
//
// This test is a basic correctness check for std.sort.by under GC pressure,
// not a guaranteed reproduction of the compaction-corruption crash itself:
// the crash was confirmed directly against the compiled CLI (`--heap 128k`,
// verified via `git stash` of the fix, reproducing identically under plain,
// -Dgc_stress, and -Dheap_paranoia builds — see the fix commit), but the
// same script run in-process through api.Runtime here — with heap size,
// max_objects, and allocator all matched to the CLI — did not reproduce it.
// The corruption is apparently sensitive to something about process
// environment/layout beyond these parameters; if this test class needs a
// deterministic regression guard, it likely has to shell out to the actual
// compiled binary rather than run in-process.
test "std.sort.by does not corrupt array elements under heap pressure (compaction during a comparator call)" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 128 * 1024,
        .max_objects = 2048,
    });
    defer rt.deinit();

    try std.testing.expect(rt.run(
        \\std := import("std")
        \\type Item struct { key int, tag string }
        \\func check() bool {
        \\    n := 20
        \\    arr := []
        \\    i := 0
        \\    for i < n {
        \\        idx := (n - i) * 37 mod 97
        \\        arr = std.core.append(arr, Item{ key: idx, tag: "tag-" + std.conv.to_string(idx) })
        \\        i = i + 1
        \\    }
        \\    pins := []
        \\    calls := 0
        \\    cmp := func(a Item, b Item) int {
        \\        calls = calls + 1
        \\        s1 := ""
        \\        p := 0
        \\        plen := 40 + (calls mod 7) * 30
        \\        for p < plen {
        \\            s1 = s1 + "m"
        \\            p = p + 1
        \\        }
        \\        pins = std.core.append(pins, s1)
        \\        if a.key < b.key { return -1 }
        \\        if a.key > b.key { return 1 }
        \\        return 0
        \\    }
        \\    sorted := std.sort.by(arr, cmp)
        \\    ok := true
        \\    k := 1
        \\    for k < std.core.len(sorted) {
        \\        if sorted[k - 1].key > sorted[k].key { ok = false }
        \\        k = k + 1
        \\    }
        \\    k = 0
        \\    for k < std.core.len(sorted) {
        \\        want := "tag-" + std.conv.to_string(sorted[k].key)
        \\        if sorted[k].tag != want { ok = false }
        \\        k = k + 1
        \\    }
        \\    return ok
        \\}
    ) == .ok);

    const result = rt.call("check", &.{});
    switch (result) {
        .ok => |v| try std.testing.expect(v == .boolean and v.boolean),
        else => return error.TestUnexpectedResult,
    }
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

test "compiler: named int arithmetic lowers to add without runtime unwrapping" {
    var rt = try setup();
    defer rt.deinit();

    try compile(&rt,
        \\type Meter int range 0..100
        \\func add(a Meter, b Meter) Meter {
        \\    return a + b
        \\}
    );

    const c = rt.chunk_state;
    var found_add = false;
    var found_named_inner = false;
    var found_named_range = false;
    var found_named_predicate = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.add)) found_add = true;
        if (op == @intFromEnum(Op.named_inner)) found_named_inner = true;
        if (op == @intFromEnum(Op.validate_named_range)) found_named_range = true;
        if (op == @intFromEnum(Op.check_named_predicate)) found_named_predicate = true;
    }
    try std.testing.expect(found_add);
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
    var found_ge = false;
    var found_le = false;
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
        if (inst.op == .ge) found_ge = true;
        if (inst.op == .le) found_le = true;
        ip += inst.width;
    }
    try std.testing.expect(found_named_predicate);
    try std.testing.expectEqual(range_const_idx, predicate_const_idx);
    try std.testing.expect(found_ge);
    try std.testing.expect(found_le);
}

test "compiler: named scalar field and return values avoid runtime unwrapping" {
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
    var found_add = false;
    var found_named_inner = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.add)) found_add = true;
        if (op == @intFromEnum(Op.named_inner)) found_named_inner = true;
    }
    try std.testing.expect(found_add);
    try std.testing.expect(!found_named_inner);
}

test "compiler: indexed named scalars avoid runtime unwrapping" {
    var rt = try setup();
    defer rt.deinit();

    try compile(&rt,
        \\type Meter int range 0..100
        \\func fromArray(xs []Meter, extra Meter) Meter { return xs[0] + extra }
        \\func fromMap(xs map[string]Meter, extra Meter) Meter { return xs["main"] + extra }
    );

    const c = rt.chunk_state;
    var add_count: usize = 0;
    var range_check_count: usize = 0;
    var found_named_inner = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.add)) add_count += 1;
        if (op == @intFromEnum(Op.validate_named_range)) range_check_count += 1;
        if (op == @intFromEnum(Op.named_inner)) found_named_inner = true;
    }
    try std.testing.expectEqual(@as(usize, 2), add_count);
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

test "compiler: named float division avoids runtime unwrapping and validates its range" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\type Ratio float range 0.0..10.0
        \\func divide(a Ratio, b Ratio) Ratio { return a / b }
    );

    const c = rt.chunk_state;
    var found_div = false;
    var found_range_check = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.div)) found_div = true;
        if (op == @intFromEnum(Op.validate_named_range)) found_range_check = true;
    }
    try std.testing.expect(found_div);
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

test "compiler: named bool not retains nominal type" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\std := import("std")
        \\type Flag bool
        \\func typeOfFlag(v Flag) string { return std.core.type_of(not v) }
    );

    const type_result = try rt.callGlobal("typeOfFlag", &.{.{ .boolean = true }});
    const name = try vms.asStringValue(type_result);
    try std.testing.expectEqualStrings("Flag", name);
}

test "compiler: named bool predicate validates at both argument and return boundaries" {
    var rt = try setup();
    defer rt.deinit();

    try runSrc(&rt,
        \\type Enabled bool predicate func(v) { return v }
        \\func invert(v Enabled) Enabled { return not v }
        \\func identity(v Enabled) Enabled { return v }
    );

    // Argument-type boundary: a dynamic value arriving as a call argument
    // (as opposed to a compiler-proven static call site) must still run the
    // predicate — previously silently bypassed for erased scalar named
    // types (int/float/rune/bool), which let any value through unchecked.
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("identity", &.{.{ .boolean = false }}));
    _ = try rt.callGlobal("identity", &.{.{ .boolean = true }});

    // Return-type boundary: not(true) is false, an invalid Enabled.
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
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_add) or op == @intFromEnum(Op.const_add)) found_const_add = true;
    }
    try std.testing.expect(found_const_add);
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
    var i: usize = 0;
    while (i < c.code_len) {
        const inst = chunk_decoder.decodeAt(c, i) catch break;
        switch (inst.op) {
            .get_local_const_eq, .get_local_const_lt, .get_local_const_gt, .const_eq, .const_lt, .const_gt => found_const = true,
            else => {},
        }
        i += inst.width;
    }
    try std.testing.expect(found_const);
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

test "time sleep suspends and charges the operation budget before waiting" {
    var rt = try setup();
    defer rt.deinit();
    // A 200ms deadline (not 1ms) gives the "still suspended" assertion below
    // a generous real-time margin against scheduler jitter — nothing in this
    // test actually waits out the real 200ms; sleep_deadline_ns is forced
    // past it immediately afterward.
    rt.setPolicy(.{ .max_ops = 500_000_000 });
    const first = try rt.begin(
        \\std := import("std")
        \\std.time.sleep(200)
        \\completed := true
    );
    try std.testing.expect(first == .suspended);
    try std.testing.expect(rt.vm_state.ops_budget_remaining < 300_000_000);
    try std.testing.expectError(error.RuntimeSuspended, rt.begin("completed := false"));
    try std.testing.expect((try rt.continueRun()) == .suspended);
    rt.vm_state.sleep_deadline_ns = 0;
    try std.testing.expect((try rt.continueRun()) == .completed);
}

test "time sleep exceeding the remaining operation budget fails before suspension" {
    var rt = try setup();
    defer rt.deinit();
    rt.setPolicy(.{ .max_ops = 100 });
    try std.testing.expectError(error.InstructionBudgetExceeded, rt.begin(
        \\std := import("std")
        \\std.time.sleep(14_400_000)
    ));
}

// Regression: run()/runIncremental() used to convert a sleep-suspended
// script straight into error.ExecutionSuspended (run() did this directly;
// runIncremental() called the same non-suspend-aware vm.run() wrapper),
// with no code path anywhere that ever resumed it — the REPL and every
// C-ABI/engine_run caller would hard-fail the moment a script called
// std.time.sleep(), and (worse) leave the runtime permanently stuck
// suspended (sleep_deadline_ns never cleared) forever after. Both now
// block through it via Runtime.waitOutSuspension() and complete
// transparently, the same way the CLI's own driver already did.
//
// Not covered by an automated test here: driving an actual real-time wait
// (std.Io.Timestamp.wait) inside this test binary was found to hang under
// zig build's --listen=- test runner specifically — a standalone `zig test`
// using the identical wait call resolves instantly, and the compiled CLI
// itself (./zig-out/bin/gengo -e '...sleep(1)...') completes correctly in
// ~20ms, so this is a test-harness interaction, not a defect in
// waitOutSuspension/continueRun. Verified manually via the CLI instead;
// see the compiled-binary check in this session's history.
test "compiler: named value survives allocation in its predicate" {
    var rt = try setup();
    defer rt.deinit();
    const src =
        \\std := import("std")
        \\type ClientId string predicate func(s) {
        \\    i := 0
        \\    for i < 1000 {
        \\        b := std.string.builder()
        \\        b.write(s)
        \\        _ = b.str()
        \\        i = i + 1
        \\    }
        \\    return s != ""
        \\}
        \\type Options struct { id ClientId }
        \\opts := Options{ id: ClientId("listener") }
        \\assert(string(opts.id) == "listener")
    ;
    _ = try rt.run(src);
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

test "compiler: enum-typed assignment emits no constructor call" {
    // Regression for the simlab2 NotAFunction crash: the named-type
    // assignment epilog compiled enum-typed assignments (inferred := AND
    // explicit var) to a Priority(value) constructor call, which enum types
    // cannot satisfy. This asserts the compile SHAPE — no call opcodes may
    // appear at all in a script whose source contains no calls — so the
    // miscompile is caught without executing anything.
    var rt = try setup();
    defer rt.deinit();

    try compileWithSession(&rt,
        \\type Priority enum { low, medium, high }
        \\func pick() Priority {
        \\    pri := Priority.medium
        \\    pri = Priority.high
        \\    return pri
        \\}
        \\var explicit Priority = Priority.low
        \\explicit = Priority.medium
    , "@mod:enum-assign");

    const c = rt.chunk_state;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk.decodeAt(ip);
        switch (inst.op) {
            .call, .call_tail, .call_spread, .get_local_const_sub_call, .get_local_const_sub_call_tail, .call_global_local_sub_const, .call_global_local_sub_const_tail => {
                std.debug.print("unexpected {s} at ip={d}\n", .{ @tagName(inst.op), ip });
                return error.TestUnexpectedResult;
            },
            else => {},
        }
        ip += inst.width;
    }
}

test "compiler: enum-typed bindings assign and zero-init correctly" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Priority enum { low, medium, high }
        \\var explicit Priority = Priority.low
        \\explicit = Priority.medium
        \\var zeroed Priority
        \\func check() int {
        \\    pri := Priority.medium
        \\    pri = Priority.high
        \\    ok := 0
        \\    if pri == Priority.high { ok = ok + 1 }
        \\    if explicit == Priority.medium { ok = ok + 1 }
        \\    if zeroed == Priority.low { ok = ok + 1 }
        \\    return ok
        \\}
    );
    const r = try rt.callGlobal("check", &.{});
    try std.testing.expect(r == .int and r.int == 3);
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

fn hasOp(c: *chunk.State, op: Op) !bool {
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk_decoder.decodeAt(c, ip);
        if (inst.op == op) return true;
        ip += inst.width;
    }
    return false;
}

test "compiler: std.conv.to_float/to_int lower to cast_float/cast_int for a provably numeric arg" {
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\std := import("std")
        \\func f() float {
        \\    var a int = 42
        \\    return std.conv.to_float(a)
        \\}
        \\func g() int {
        \\    var b float = 3.14
        \\    return std.conv.to_int(b)
        \\}
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(try hasOp(c, .cast_float));
    try std.testing.expect(try hasOp(c, .cast_int));
}

test "compiler: std.conv.to_int/to_float do NOT lower when the arg could be a string" {
    // A regression guard for the divergence found 2026-07-20: cast_int/cast_float
    // have no string-parsing branch (unlike nativeConvToInt/Float), so lowering
    // must stay gated on a provably non-string static prim. Without the gate,
    // to_int("123")/to_float("2.5") would start erroring instead of parsing.
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\std := import("std")
        \\func f() int {
        \\    return std.conv.to_int("123")
        \\}
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(!(try hasOp(c, .cast_int)));
    try std.testing.expect(try hasOp(c, .call) or try hasOp(c, .call_tail));
}

test "compiler: std.conv.to_string does NOT lower for a null-typed arg" {
    // cast_string rejects .null (string(null) errors) while
    // nativeConvToString returns "null" for it (std.conv.to_string(null)
    // succeeds) — the gate must exclude untyped/null arguments.
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\std := import("std")
        \\func f() string {
        \\    return std.conv.to_string(null)
        \\}
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(!(try hasOp(c, .cast_string)));
    try std.testing.expect(try hasOp(c, .call) or try hasOp(c, .call_tail));
}

test "compiler: std.core.len lowers to the len op" {
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\std := import("std")
        \\func f(a []int) int {
        \\    return std.core.len(a)
        \\}
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(try hasOp(c, .len));
}

test "compiler: std.core.append lowers to the append op" {
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\std := import("std")
        \\func f(a []int) []int {
        \\    return std.core.append(a, 1, 2)
        \\}
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(try hasOp(c, .append));
}

test "compiler: append with a closure argument inside a loop keeps correct entry points (regression, deleteCodeRange)" {
    // deleteCodeRange previously shifted bytecode without adjusting FuncObj.ip
    // or module boundaries recorded before the call — invisible for every
    // prior intrinsic (math/type_of/conv/len), whose arguments are plain
    // value expressions, but append(arr, func() {...}) compiles a whole
    // nested function body after the deleted preamble, exposing it as a
    // stack-underflow verifier failure (found via
    // tests/spec/146_loop_closure_capture.gengo, 2026-07-20).
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\func check() {
        \\    funcs := []
        \\    i := 0
        \\    for i < 3 {
        \\        captured := i
        \\        funcs = std.core.append(funcs, func() int { return captured })
        \\        i += 1
        \\    }
        \\    assert funcs[0]() == 0
        \\    assert funcs[1]() == 1
        \\    assert funcs[2]() == 2
        \\}
        \\check()
    );
}

test "compiler: std.core.bytelen lowers to the bytelen op" {
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\std := import("std")
        \\func f(s string) int {
        \\    return std.core.bytelen(s)
        \\}
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(try hasOp(c, .bytelen));
}

test "compiler: std.core.bytelen counts raw bytes, not runes" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.core.bytelen("hello") == 5
        \\assert std.core.bytelen("åäö") == 6
        \\assert std.core.len("åäö") == 3
    );
}

test "compiler: std.bytes decode family lowers to bytes_decode with the correct kind byte" {
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\std := import("std")
        \\b := std.bytes
        \\func f(s string, i int) int {
        \\    return b.u16be_at(s, i)
        \\}
    , "");
    const c = rt.chunk_state;
    var found = false;
    var ip: usize = 0;
    while (ip < c.code_len) {
        const inst = try chunk_decoder.decodeAt(c, ip);
        if (inst.op == .bytes_decode) {
            // kind=1 is u16be_at (native/bytes.zig's DecodeKind).
            try std.testing.expectEqual(@as(u8, 1), c.code[ip + 1]);
            found = true;
        }
        ip += inst.width;
    }
    try std.testing.expect(found);
}

test "compiler: std.bytes decode family matches the native-call path byte for byte" {
    // The op and the native call must produce identical results for every
    // kind (0-10): the op calls native/bytes.zig's decodeAt directly, but
    // this guards against the two ever being wired to different logic.
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\b := std.bytes
        \\data := b.u8(0x12) + b.u16be(0x3456) + b.u32be(0x789ABCDE) + b.u64be(0x0102030405060708) + b.f32be(3.5) + b.f64be(2.5)
        \\assert b.at(data, 0) == 0x12
        \\assert b.u16be_at(data, 1) == 0x3456
        \\assert b.u16le_at(data, 1) == 0x5634
        \\assert b.u32be_at(data, 3) == 0x789ABCDE
        \\assert b.u64be_at(data, 7) == 0x0102030405060708
        \\assert b.f32be_at(data, 15) == 3.5
        \\assert b.f64be_at(data, 19) == 2.5
    );
}

// A negative offset used to reach @intCast on a negative i64 (a Zig
// safety-check panic that aborts the process) instead of raising a
// catchable RangeError like every other out-of-bounds offset — decodeAt's
// multi-byte variants (everything but byte_at) cast straight to usize
// without checking the sign first. Fixed with offsetToUsize (bytes.zig).
test "compiler: std.bytes decode family raises RangeError (not a crash) on a negative offset" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() int { return std.bytes.u32be_at(std.bytes.u32be(1234), -1) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("f", &.{}));
}

// A pattern that can match zero characters (a bare anchor, or a nullable
// quantifier) was rejected everywhere in regexp.zig: `end == i` was
// treated as "no match", so match/find/find_all/split could never report
// a zero-width match. Fixed in findMatch/findAllMatches (regexp.zig);
// nativeReReplace/nativeReSplit were also rewritten to scan via
// findAllMatches (absolute positions in the original string) instead of
// re-running findMatch against a shrinking re-sliced substring, which
// both avoids an infinite loop on a zero-width match and fixes anchors
// (`^`) incorrectly re-matching at every iteration's substring start.
test "compiler: regexp zero-width matches (anchors, nullable quantifiers)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\re := std.regexp
        \\assert re.match("^", "bbb")
        \\assert re.match("a*", "bbb")
        \\parts := re.split("x*", "abc")
        \\assert std.core.len(parts) == 4
        \\assert parts[0] == ""
        \\assert parts[1] == "a"
        \\assert parts[2] == "b"
        \\assert parts[3] == "c"
        \\all := re.find_all("a*", "baab")
        \\assert std.core.len(all) == 4
        \\assert all[0] == ""
        \\assert all[1] == "aa"
        \\assert all[2] == ""
        \\assert all[3] == ""
    );
}

// Zig's std.json.Stringify only supports a fixed set of whitespace widths
// (1/2/3/4/8 spaces or a tab) — no arbitrary N. A width outside that set
// (5, 6, or 7 spaces) used to silently fall back to 2-space indentation
// instead of the requested width. Fixed to fail loudly (TypeError)
// instead of silently returning output at the wrong width.
test "compiler: std.json.indent rejects an unsupported indent width instead of silently substituting one" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func four() string { return std.json.indent("{\"a\":1}", "    ") }
        \\func five() string { return std.json.indent("{\"a\":1}", "     ") }
    );
    const four = try rt.callGlobal("four", &.{});
    try std.testing.expectEqualStrings("{\n    \"a\": 1\n}", try vms.asStringValue(four));
    try std.testing.expectError(error.TypeError, rt.callGlobal("five", &.{}));
}

test "compiler: field = field + const fuses into field_add_const" {
    // The "c.tx_id = c.tx_id + 1" idiom (found independently in gengo-modbus
    // and gengo-mqtt as a transaction/packet-ID counter), issue #207.
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\type Client struct {
        \\    tx_id int,
        \\}
        \\func (c Client) next() int {
        \\    c.tx_id = c.tx_id + 1
        \\    return c.tx_id
        \\}
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(try hasOp(c, .field_add_const));
    try std.testing.expect(!(try hasOp(c, .set_field)));
}

test "compiler: field_add_const increments correctly across repeated calls" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\type Client struct {
        \\    tx_id int,
        \\}
        \\func (c Client) next() int {
        \\    c.tx_id = c.tx_id + 1
        \\    return c.tx_id
        \\}
        \\cl := Client { tx_id: 0 }
        \\assert cl.next() == 1
        \\assert cl.next() == 2
        \\assert cl.next() == 3
    );
}

test "compiler: field_add_const preserves const-field and named-type checks" {
    // field_add_const delegates the write to opSetField verbatim rather than
    // reimplementing its type-coercion/const-field logic — this guards that
    // delegation actually happens (a hand-rolled write would risk silently
    // skipping the const check).
    var rt = try setup();
    defer rt.deinit();
    const result = rt.run(
        \\type Foo struct {
        \\    const x int,
        \\}
        \\func (f Foo) bump() {
        \\    f.x = f.x + 1
        \\}
        \\foo := Foo { x: 0 }
        \\foo.bump()
    );
    try std.testing.expectError(error.AssignToConst, result);
}

test "compiler: m[\"literal\"] lowers to get_index_const_str, not constant+get_index" {
    // Issue #206: a bare string-literal index is known at compile time, so
    // it's lowered directly rather than pushing the key onto the stack.
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\m := { "alpha": 1 }
        \\x := m["alpha"]
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(try hasOp(c, .get_index_const_str));
    try std.testing.expect(!(try hasOp(c, .get_index)));
}

test "compiler: m[key] with a non-literal index still uses generic get_index" {
    // Guards the lowering's own boundary: only a bare literal token
    // immediately closed by ']' qualifies — a computed key must still go
    // through the fully generic path.
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\m := { "alpha": 1 }
        \\key := "alpha"
        \\x := m[key]
    , "");
    const c = rt.chunk_state;
    try std.testing.expect(try hasOp(c, .get_index));
    try std.testing.expect(!(try hasOp(c, .get_index_const_str)));
}

test "compiler: get_index_const_str map lookup returns correct values and null on miss" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\m := { "alpha": 1, "bravo": 2 }
        \\assert m["alpha"] == 1
        \\assert m["bravo"] == 2
        \\assert m["charlie"] == null
    );
}

test "compiler: get_index_const_str falls back to generic get_index for non-map receivers" {
    // A bare string-literal index isn't only used for maps (struct field
    // access via bracket syntax uses the same syntax shape) — the fallback
    // path in opGetIndexConstStr must delegate to opGetIndex verbatim.
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\type Point struct {
        \\    x int,
        \\    y int,
        \\}
        \\p := Point { x: 3, y: 4 }
        \\assert p["x"] == 3
        \\assert p["y"] == 4
    );
}

// ── #204 native-lane backfill: call-flag emission (argc | 0x80) ────────────
//
// selectTypedArithmeticOp-adjacent but distinct: this is compiler.zig's
// argProvenForParam/checkDirectCallArgCompatibility machinery (see
// dev-docs/design/compiler-architecture.md §3's "Calls" paragraph), which
// sets the top bit of a direct call's argc byte when every argument is
// compiler-provably type-correct against the resolved callee signature,
// letting the VM's warm call path skip runtime arg-type enforcement
// entirely. Had zero native coverage before this (#204).

fn findCallArgcByte(c: *chunk.State) ?u8 {
    var ip: usize = 0;
    while (ip < c.code_len) {
        const op: Op = @enumFromInt(c.code[ip]);
        if (op == .call) return c.code[ip + 1];
        const decoded = c.decodeAt(ip) catch return null;
        ip += decoded.width;
    }
    return null;
}

test "compiler: direct call with provable literal args sets the 0x80 proven bit" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func add(a int, b int) int {
        \\    return a + b
        \\}
        \\x := add(1, 2)
    );
    const c = rt.chunk_state;
    const argc_byte = findCallArgcByte(c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 2 | 0x80), argc_byte);
}

test "compiler: direct call with an erased-type arg does not set the proven bit" {
    // The argument's static type is unknown at the call site (it flows
    // through std.json.parse, an any-typed source) — argProvenForParam must
    // refuse, not assume, since the runtime value could be any type.
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\std := import("std")
        \\func add(a int, b int) int {
        \\    return a + b
        \\}
        \\data := std.json.parse("1")
        \\x := add(data, 2)
    , "");
    const c = rt.chunk_state;
    const argc_byte = findCallArgcByte(c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), argc_byte & 0x80);
}

test "compiler: direct call to a function with default params never sets the proven bit" {
    // proven additionally requires default_count == 0 (see the call site's
    // "proven" computation in compiler_expr.zig) — a call site can supply
    // provably-correct args and still not be a full-arity, default-free
    // match, so it must not skip runtime enforcement.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func add(a int, b int = 1) int {
        \\    return a + b
        \\}
        \\x := add(1, 2)
    );
    const c = rt.chunk_state;
    const argc_byte = findCallArgcByte(c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), argc_byte & 0x80);
}

test "compiler: call through an indirect/unknown callee does not set the proven bit" {
    // callee_sig is only resolved for a direct, statically-known callee
    // (registry lookup or in-progress recursive self-call) — calling
    // through a plain local variable holding a closure has no signature to
    // prove arguments against.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func add(a int, b int) int {
        \\    return a + b
        \\}
        \\f := add
        \\x := f(1, 2)
    );
    const c = rt.chunk_state;
    const argc_byte = findCallArgcByte(c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), argc_byte & 0x80);
}

// ── #204 native-lane backfill: return-proof stamping (returns_proven) ──────
//
// See dev-docs/design/compiler-architecture.md §4's "Return-type proof"
// paragraph: a single-primitive-return function whose body provably always
// returns, with every return matching the declared type, gets its FuncObj
// stamped returns_proven — letting the VM trust the return value's type
// instead of re-checking it at runtime. Had zero native coverage (#204).

fn findFuncObjNamed(c: *chunk.State, name: []const u8) ?@import("lang/value.zig").FuncObj {
    var i: usize = 0;
    while (i < c.const_count) : (i += 1) {
        if (c.consts[i] == .object and c.consts[i].object.* == .function) {
            const func = c.consts[i].object.*.function;
            if (std.mem.eql(u8, func.name, name)) return func;
        }
    }
    return null;
}

test "compiler: function whose body always returns the declared primitive type is proven" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func classify(x int) string {
        \\    if x < 0 {
        \\        return "negative"
        \\    }
        \\    return "non-negative"
        \\}
    );
    const c = rt.chunk_state;
    const func = findFuncObjNamed(c, "classify") orelse return error.TestUnexpectedResult;
    try std.testing.expect(func.returns_proven);
}

test "compiler: function with a fallthrough (implicit null return) path is not proven" {
    // The `if` branch returns, but there is no unconditional return after
    // it — the implicit end-of-body null return is reachable, so the
    // compiler cannot prove every path returns the declared type.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func classify(x int) string {
        \\    if x < 0 {
        \\        return "negative"
        \\    }
        \\}
    );
    const c = rt.chunk_state;
    const func = findFuncObjNamed(c, "classify") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!func.returns_proven);
}

test "compiler: multi-named-return function is not returns_proven" {
    // returns_proven is specifically single-primitive-return (scope.return_prim
    // != null); named-return / multi-value functions use a different
    // mechanism (call_spread) entirely and must not be stamped.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func divmod(a int, b int) (q int, r int) {
        \\    q = a / b
        \\    r = a rem b
        \\    return
        \\}
    );
    const c = rt.chunk_state;
    const func = findFuncObjNamed(c, "divmod") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!func.returns_proven);
}

test "compiler: function returning a named type is not returns_proven" {
    // return_prim tracks primitive return types only; a named-type return
    // takes a different validation path (named-type construction/predicate
    // checks) and is deliberately excluded from this proof.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Meters int range 0..1000
        \\func clampMeters(x int) Meters {
        \\    return Meters(x)
        \\}
    );
    const c = rt.chunk_state;
    const func = findFuncObjNamed(c, "clampMeters") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!func.returns_proven);
}

// ── #204 native-lane backfill: typed-assignment prolog/epilog matrix ──────
//
// See dev-docs/design/compiler-architecture.md §9's "Erased vs. boxed named
// types" invariant: named types over a scalar/enum base are erased at
// runtime, so the compiler emits validate-in-place ops (validate_named_range
// / check_named_predicate) instead of a real constructor call; named types
// over a non-scalar base (string/array/map) always go through a real
// get_global+call(1) constructor. This distinction is threaded through
// compoundStmt, incrStmt, and returnStmt's named-return epilogs. Had zero
// native coverage before this (#204).

fn countOp(c: *chunk.State, op: Op) usize {
    var count: usize = 0;
    for (c.code[0..c.code_len]) |byte| {
        if (byte == @intFromEnum(op)) count += 1;
    }
    return count;
}

test "compiler: compound assign on an erased-named local validates in place" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Meters int range 0..1000
        \\func bump(m Meters) Meters {
        \\    m += Meters(5)
        \\    return m
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expect(countOp(c, .validate_named_range) >= 1);
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .named_inner));
}

test "compiler: compound assign on a boxed-named local unwraps and reconstructs" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Tag string
        \\func shout(t Tag) Tag {
        \\    t += Tag("!")
        \\    return t
        \\}
    );
    const c = rt.chunk_state;
    // Boxed path: get_global (constructor callee) before the epilog's call,
    // named_inner to unwrap both operands, and no validate_named_range
    // (the VM's .named_type call handler does the validation, not the
    // compiler's fast-path ops).
    try std.testing.expect(countOp(c, .named_inner) >= 1);
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .validate_named_range));
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .check_named_predicate));
}

test "compiler: increment on an erased-named local validates in place" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Meters int range 0..1000
        \\func step(m Meters) Meters {
        \\    m++
        \\    return m
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expect(countOp(c, .validate_named_range) >= 1);
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .named_inner));
}

test "compiler: decrement on a boxed-named local unwraps and reconstructs" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Count []int
        \\func shrink(c Count) string { c--; return std.core.type_of(c) }
    );
    const c = rt.chunk_state;
    try std.testing.expect(countOp(c, .named_inner) >= 1);
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .validate_named_range));
}

test "compiler: named-return of a boxed named type constructs correctly (regression)" {
    // Previously returnStmt called emitVarTypeEpilog for a named-return slot
    // without first calling emitVarTypeProlog — for a boxed (non-scalar
    // base) named-return type this meant the epilog's `call(1)` had no
    // constructor callee pushed under the return value, and treated the
    // already-built value itself as the callee: `return Tag(s)` panicked
    // with NotAFunction at runtime. Fixed by pushing the prolog's
    // get_global before compiling the return expression, exactly like
    // assignStmt/compoundStmt/incrStmt already did.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Tag string
        \\func makeTag(s string) (result Tag) {
        \\    return Tag(s)
        \\}
    );
    const result = try rt.callGlobal("makeTag", &.{.{ .string = value_mod.staticSS("hello") }});
    const named = result.asNamed() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Tag", named.typ.named_type.name);
}

test "compiler: multi named-return with mixed erased and boxed types constructs both correctly" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Tag string
        \\type Meters int range 0..1000
        \\func makeBoth(s string, m int) (t Tag, mm Meters) {
        \\    return Tag(s), Meters(m)
        \\}
    );
    const c = rt.chunk_state;
    // The boxed Tag slot's epilog is a second get_global+call wrapping the
    // already-constructed source value (2 get_global "Tag": one from the
    // `Tag(s)` source expression, one from the epilog's own prolog); the
    // erased Meters slot's epilog is a validate_named_range with no extra
    // call or get_global at all (its one get_global/call pair comes solely
    // from the `Meters(m)` source expression, not from its epilog).
    try std.testing.expectEqual(@as(usize, 3), countOp(c, .get_global));
    try std.testing.expectEqual(@as(usize, 3), countOp(c, .call));
    try std.testing.expect(countOp(c, .validate_named_range) >= 1);
}

// ── #204 native-lane backfill: fusion pass trigger decisions ──────────────
//
// See lang/fusion_pass.zig's module doc and dev-docs/design/vm-architecture.md
// §6: every fusion is a legality-checked rewrite of adjacent core ops into a
// VM-private fused op, run by `compile()`/`compileWithSession()` (both call
// fusion_pass.fuse() already, so every test in this file already observes
// post-fusion bytecode). These tests assert the *specific* trigger shape for
// each fused op that had zero direct native coverage before this pass, plus
// one legality-boundary case (same_slot). Had zero native coverage (#204).

test "fusion: global read + constant binop fuses to get_global_const_X" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\g := 10
        \\func geqc() bool { return g == 5 }
        \\func gaddc() int { return g + 5 }
        \\func gltc() bool { return g < 5 }
        \\func gsubc() int { return g - 5 }
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_global_const_eq));
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_global_const_add));
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_global_const_lt));
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_global_const_sub));
}

test "fusion: add immediately before ret fuses to add_ret" {
    // Two different locals summed and returned directly: neither get_local
    // pairs with the other (no pairFusion rule joins two get_locals), so the
    // only fusable pair left is the trailing add+ret.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func addTwo(a int, b int) int { return a + b }
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .add_ret));
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .add));
}

test "fusion: local struct field read fuses to get_local_get_field" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Point struct { x int, y int }
        \\func fieldRead(p Point) int { return p.x }
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_local_get_field));
}

test "fusion: bare local return fuses to get_local_ret" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func identity(x int) int { return x }
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_local_ret));
}

test "fusion: while-loop condition on a global with a constant fuses to get_global_const_lt_jif_pop" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\g := 10
        \\func gforlt() int {
        \\    i := 0
        \\    for g < 100 {
        \\        i = i + 1
        \\    }
        \\    return i
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_global_const_lt_jif_pop));
}

test "fusion: while-loop condition on a local with > and a constant fuses to get_local_const_gt_jif_pop" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func countdown() int {
        \\    i := 5
        \\    for i > 0 {
        \\        i = i - 1
        \\    }
        \\    return i
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_local_const_gt_jif_pop));
}

test "fusion: C-style for-loop header (local < constant) fuses to the quint get_local_const_lt_jif_pop_jump" {
    // The jump-to-body-first layout a C-for uses (skip the post-statement on
    // the loop's first iteration) is the one shape that places an
    // unconditional jump directly after the get_local_const_lt_jif_pop quad,
    // letting it grow into the 13-byte quint.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func cfor() int {
        \\    x := 0
        \\    for i := 0; i < 5; i++ {
        \\        x = x + i
        \\    }
        \\    return x
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_local_const_lt_jif_pop_jump));
}

test "fusion: C-style for-loop's per-iteration capture close fuses to close_upvalue_loop" {
    // Every iteration of a C-for rebinds the loop variable (for capture
    // correctness), closing it right before the loop's back-edge — this is
    // what supplies close_upvalue_loop's trigger, independent of whether the
    // loop body actually captures the variable in a closure.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func cfor() int {
        \\    x := 0
        \\    for i := 0; i < 5; i++ {
        \\        x = x + i
        \\    }
        \\    return x
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .close_upvalue_loop));
}

test "fusion: top-level global compound-add fuses to inc_global_const" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\g := 10
        \\func incGlobal() { g += 5 }
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .inc_global_const));
}

test "fusion: loop-body compound-add on a local fuses to local_add_const, and to local_add_const_loop when it directly precedes the back-edge" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func loopLocalAdd(n int) int {
        \\    x := 0
        \\    i := 0
        \\    for i < n {
        \\        x += 3
        \\        i = i + 1
        \\    }
        \\    return x
        \\}
    );
    const c = rt.chunk_state;
    // x += 3 isn't the loop's last statement (i = i + 1 follows it), so it
    // fuses only as far as local_add_const; the trailing i = i + 1 IS last,
    // so it grows the extra step to local_add_const_loop.
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .local_add_const));
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .local_add_const_loop));
}

test "fusion: global assignment as a loop's last statement fuses to set_global_loop" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\g := 0
        \\func loopGlobalAssign(n int) int {
        \\    i := 0
        \\    for i < n {
        \\        i = i + 1
        \\        g = i
        \\    }
        \\    return g
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .set_global_loop));
}

test "fusion: local = local + local fuses to the 4-window local_add_local" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func addLocal() int {
        \\    a := 1
        \\    b := 2
        \\    a += b
        \\    return a
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .local_add_local));
}

test "fusion: local += struct field fuses to the 4-window local_add_field" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Point struct { x int, y int }
        \\func addField() int {
        \\    x := 1
        \\    p := Point{x: 1, y: 2}
        \\    x += p.y
        \\    return x
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .local_add_field));
}

test "fusion: get_local_const_add does not fuse into local_add_const across mismatched slots" {
    // Legality boundary: local_add_const additionally requires the read slot
    // and the write slot to match (same_slot in pairFusionFull) — a plain
    // reassignment into a *different* local must leave get_local_const_add
    // and set_local as two separate instructions, not one fused op.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int {
        \\    x := 10
        \\    y := 0
        \\    y = x + 5
        \\    return y
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .get_local_const_add));
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .local_add_const));
    try std.testing.expect(try hasOp(c, .set_local));
}

// ── #208: named-type range 'clamp' mode ────────────────────────────────────
//
// A third range mode alongside 'range' (hard RangeError) and 'cycle'
// (modular wrap): saturates an out-of-bounds value to the nearest bound
// instead of erroring or wrapping. See vm_types.zig's clampValue and its
// call sites in constructNamedType (int/float/decimal/rune) and
// applyNamedTypeFn (succ/pred).

test "compiler: clamp saturates int/float/decimal/rune to their bounds" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Percent int clamp 0..100
        \\type Ratio float clamp 0.0..1.0
        \\type Letter rune clamp 65..90
        \\func mkPercent(x int) Percent { return Percent(x) }
        \\func mkRatio(x float) Ratio { return Ratio(x) }
        \\func mkLetter(x int) Letter { return Letter(x) }
    );
    const high = try rt.callGlobal("mkPercent", &.{.{ .int = 150 }});
    try std.testing.expectEqual(@as(i64, 100), high.int);
    const low = try rt.callGlobal("mkPercent", &.{.{ .int = -10 }});
    try std.testing.expectEqual(@as(i64, 0), low.int);
    const in_range = try rt.callGlobal("mkPercent", &.{.{ .int = 50 }});
    try std.testing.expectEqual(@as(i64, 50), in_range.int);

    const ratio_high = try rt.callGlobal("mkRatio", &.{.{ .float = 2.5 }});
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), ratio_high.float, 1e-9);

    const letter_high = try rt.callGlobal("mkLetter", &.{.{ .int = 200 }});
    try std.testing.expectEqual(@as(u21, 90), letter_high.rune);
}

test "compiler: clamp raises no RangeError, unlike plain range, on an out-of-bounds construction" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Hard int range 0..100
        \\type Soft int clamp 0..100
        \\func mkHard(x int) Hard { return Hard(x) }
        \\func mkSoft(x int) Soft { return Soft(x) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkHard", &.{.{ .int = 150 }}));
    const soft = try rt.callGlobal("mkSoft", &.{.{ .int = 150 }});
    try std.testing.expectEqual(@as(i64, 100), soft.int);
}

test "compiler: clamp composes with predicate — clamping happens first, predicate checks the clamped result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type EvenPercent int clamp 0..100 predicate func(x) { return x rem 2 == 0 }
        \\func mkEvenPercent(x int) EvenPercent { return EvenPercent(x) }
    );
    // 200 clamps to 100 (even) — passes the predicate on the clamped value.
    const clamped_even = try rt.callGlobal("mkEvenPercent", &.{.{ .int = 200 }});
    try std.testing.expectEqual(@as(i64, 100), clamped_even.int);
    // 99 is within 0..100 so it is NOT clamped, and fails the predicate as-is.
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("mkEvenPercent", &.{.{ .int = 99 }}));
}

test "compiler: clamp is inherited by a subtype, same as range/cycle" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Percent int clamp 0..100
        \\type StrictPercent Percent
        \\func mkStrict(x int) StrictPercent { return StrictPercent(x) }
    );
    const result = try rt.callGlobal("mkStrict", &.{.{ .int = 500 }});
    try std.testing.expectEqual(@as(i64, 100), result.int);
}

test "compiler: a default value must still be within bounds under clamp — clamp does not relax default validation" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.RangeError, compile(&rt,
        \\type BadDefault int clamp 0..100 default 500
    ));
}

test "compiler: clamp is rejected on a non-numeric base, same as range/cycle" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, compile(&rt,
        \\type BadBase string clamp 0..100
    ));
}

// ── #210: limited operator overloading via reserved dunder methods ────────
//
// See dunderMethodName/dunderOpForBinaryTok/checkDunderConflict/
// validateDunderSignature/lookupDunderCallee in compiler.zig, and
// tryEmitDunderBinaryOp/unaryExpr's __neg__ branch in compiler_expr.zig for
// the compile-time desugar (a + b -> a.__add__(b), same get_global+swap+call
// shape as static method dispatch). tryStructDunderBinary/Unary in vm.zig
// cover the runtime fallback needed inside type-erased generic bodies.

test "compiler: a + b desugars to a direct call when the LHS struct type declares __add__" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Vec2 struct { x float, y float }
        \\func (a Vec2) __add__(b Vec2) Vec2 { return a }
        \\func f(a Vec2, b Vec2) Vec2 { return a + b }
    );
    const c = rt.chunk_state;
    try std.testing.expect(try hasOp(c, .swap));
    try std.testing.expect(try hasOp(c, .get_global));
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .add));
}

test "compiler: struct dunder arithmetic and unary minus compute correctly" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Vec2 struct { x float, y float }
        \\func (a Vec2) __add__(b Vec2) Vec2 { return Vec2 { x: a.x + b.x, y: a.y + b.y } }
        \\func (a Vec2) __sub__(b Vec2) Vec2 { return Vec2 { x: a.x - b.x, y: a.y - b.y } }
        \\func (v Vec2) __neg__() Vec2 { return Vec2 { x: -v.x, y: -v.y } }
        \\func addX() float {
        \\    a := Vec2 { x: 1.0, y: 2.0 }
        \\    b := Vec2 { x: 3.0, y: 4.0 }
        \\    return (a + b).x
        \\}
        \\func subX() float {
        \\    a := Vec2 { x: 5.0, y: 2.0 }
        \\    b := Vec2 { x: 3.0, y: 4.0 }
        \\    return (a - b).x
        \\}
        \\func negX() float {
        \\    v := Vec2 { x: 5.0, y: 2.0 }
        \\    return (-v).x
        \\}
    );
    const va = try rt.callGlobal("addX", &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), va.float, 1e-9);
    const vs = try rt.callGlobal("subX", &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), vs.float, 1e-9);
    const vn = try rt.callGlobal("negX", &.{});
    try std.testing.expectApproxEqAbs(@as(f64, -5.0), vn.float, 1e-9);
}

test "compiler: __compare__ drives all four ordering operators" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box struct { v int }
        \\func (a Box) __compare__(b Box) int {
        \\    if a.v < b.v { return -1 }
        \\    if a.v > b.v { return 1 }
        \\    return 0
        \\}
        \\func lt() bool { return Box{v:1} < Box{v:2} }
        \\func gt() bool { return Box{v:2} > Box{v:1} }
        \\func le() bool { return Box{v:2} <= Box{v:2} }
        \\func ge() bool { return Box{v:2} >= Box{v:2} }
        \\func ltFalse() bool { return Box{v:2} < Box{v:1} }
    );
    try std.testing.expect((try rt.callGlobal("lt", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("gt", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("le", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("ge", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("ltFalse", &.{})).boolean);
}

test "compiler: __eq__ drives == and != for a struct" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box struct { v int }
        \\func (a Box) __eq__(b Box) bool { return a.v == b.v }
        \\func eq() bool { return Box{v:3} == Box{v:3} }
        \\func neq() bool { return Box{v:3} != Box{v:4} }
        \\func eqFalse() bool { return Box{v:3} == Box{v:4} }
    );
    try std.testing.expect((try rt.callGlobal("eq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("neq", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("eqFalse", &.{})).boolean);
}

test "compiler: declaring a dunder that conflicts with an already-working built-in operator is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DunderConflict, compile(&rt,
        \\type Meters int
        \\func (a Meters) __add__(b Meters) Meters { return a }
    ));
}

test "compiler: a dunder that fills a genuine gap (decimal __rem__, __compare__) is allowed" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Money decimal 2
        \\func (a Money) __rem__(b Money) Money { return a }
        \\func (a Money) __compare__(b Money) int { return 0 }
    );
}

test "compiler: a dunder with the wrong arity, param type, or return type is rejected" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DunderSignatureMismatch, compile(&rt,
        \\type Vec2 struct { x float, y float }
        \\func (a Vec2) __add__(b Vec2, extra int) Vec2 { return a }
    ));
    var rt2 = try setup();
    defer rt2.deinit();
    try std.testing.expectError(error.DunderSignatureMismatch, compile(&rt2,
        \\type Vec2 struct { x float, y float }
        \\type Other struct { z int }
        \\func (a Vec2) __add__(b Other) Vec2 { return a }
    ));
    var rt3 = try setup();
    defer rt3.deinit();
    try std.testing.expectError(error.DunderSignatureMismatch, compile(&rt3,
        \\type Vec2 struct { x float, y float }
        \\func (a Vec2) __eq__(b Vec2) int { return 0 }
    ));
}

test "compiler: __compare__ satisfies the ordered generic constraint" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Box struct { v int }
        \\func (a Box) __compare__(b Box) int { return 0 }
        \\func biggest[T: ordered](xs []T) T { return xs[0] }
        \\func f(boxes []Box) Box { return biggest[Box](boxes) }
    );
}

test "compiler: dunder operators work at runtime inside a type-erased generic function body" {
    // The compile-time desugar can't fire here (T is erased inside the
    // generic body), so this exercises the VM-level runtime fallback
    // (tryStructDunderBinary in vm.zig) instead.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box struct { v int }
        \\func (a Box) __compare__(b Box) int {
        \\    if a.v < b.v { return -1 }
        \\    if a.v > b.v { return 1 }
        \\    return 0
        \\}
        \\func biggest[T: ordered](xs []T) T {
        \\    m := xs[0]
        \\    i := 1
        \\    for i < 3 {
        \\        if xs[i] > m { m = xs[i] }
        \\        i = i + 1
        \\    }
        \\    return m
        \\}
        \\func f() int {
        \\    boxes := [Box{v:3}, Box{v:7}, Box{v:1}]
        \\    best := biggest[Box](boxes)
        \\    return best.v
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 7), result.int);
}

// addGenericFunc used to run AFTER compiling the function's own body, so a
// self-recursive call with explicit type args (countdown[T](...)) inside
// that same body couldn't find hasGenericFunc(name) yet — compiler_expr.zig
// treated `countdown[T]` as an indexing expression instead of a generic
// call, evaluating `T` as a (nonexistent) runtime variable and panicking
// with NotDefined. Fixed by registering a top-level generic function before
// compiling its body.
test "compiler: self-recursive generic function call with explicit type args" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func countdown[T](x T, n int) T {
        \\    if n <= 0 { return x }
        \\    return countdown[T](x, n - 1)
        \\}
    );
    const result = try rt.callGlobal("countdown", &.{ .{ .int = 0 }, .{ .int = 5 } });
    try std.testing.expectEqual(@as(i64, 0), result.int);
}

// looksLikeGenericTypeParams (compiler.zig) — the lookahead that decides
// whether `Name[...]` after a type name is a generic-parameter list — only
// accepted .ident/.comma inside the brackets, so a `:` constraint (e.g.
// `[T: numeric]`) fell through to `else => return false` and the whole
// declaration was never even recognized as generic, despite the sibling
// scanner for generic functions (isNamedFuncDecl) already allowing `:`, and
// despite docs/language.md explicitly documenting the same constraint
// syntax for generic types. Fixed by allowing .colon in the type-param
// scan too, and by wiring checkTypeArgConstraints into
// instantiateGenericType (compiler_decls.zig) — generic functions already
// enforced constraints at call time, but generic types never did, even
// once recognized as generic.
test "compiler: constrained generic struct type parameter parses and instantiates" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box[T: numeric] struct { val T }
        \\func f() int {
        \\    b := Box[int]{ val: 42 }
        \\    return b.val
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 42), result.int);
}

test "compiler: constrained generic struct type parameter rejects a non-conforming type arg" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ConstraintViolation, compile(&rt,
        \\type Box[T: numeric] struct { val T }
        \\func f() string {
        \\    b := Box[string]{ val: "hi" }
        \\    return b.val
        \\}
    ));
}

test "compiler: := infers struct type for dunder dispatch, same as an explicitly var-typed local" {
    // Struct literals previously left no ExprPrimInfo on their own result at
    // all, and := never inferred struct_type for a local either — both
    // fixed (compiler_expr.zig's structInstanceLit, compiler_stmts.zig's
    // varDecl) so operator overloading works from ordinary short-decl style,
    // not only from an explicitly `var x StructType`-typed local.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Vec2 struct { x float, y float }
        \\func (a Vec2) __add__(b Vec2) Vec2 { return Vec2 { x: a.x + b.x, y: a.y + b.y } }
        \\func f() float {
        \\    a := Vec2 { x: 1.0, y: 2.0 }
        \\    b := Vec2 { x: 3.0, y: 4.0 }
        \\    c := a + b
        \\    return c.x
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.float, 1e-9);
}

test "compiler: := infers struct type for a top-level global too" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Vec2 struct { x float, y float }
        \\func (a Vec2) __add__(b Vec2) Vec2 { return Vec2 { x: a.x + b.x, y: a.y + b.y } }
        \\a := Vec2 { x: 1.0, y: 2.0 }
        \\b := Vec2 { x: 3.0, y: 4.0 }
        \\c := a + b
        \\func f() float { return c.x }
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.float, 1e-9);
}

// ── #5: GBC (Gengo Bytecode Cache) — first milestone round-trip ───────────
//
// gbc_writer.write() serializes the DEFUSED (core-ops-only) form of an
// already-compiled, already-fused chunk; gbc_reader.read() loads that back
// into a fresh chunk.State, and the caller re-runs fusion_pass.fuse() —
// exactly the same step the normal compile pipeline (runtime.zig's
// compileProgram) already performs — before executing. Globals are
// populated by running the loaded top-level code, not by any separate
// globals table; see both modules' doc comments for the full design.
//
// This milestone deliberately does not implement most of the spec's 27
// validation checks (§11.1) — magic/header/body-checksum bounds only. See
// dev-docs/design/gbc-spec.md and issue #5 for the full remaining scope.

test "gbc: writer + reader round-trip produces identical execution results" {
    const src =
        \\func addOne(x int) int {
        \\    return x + 1
        \\}
        \\func compute() int {
        \\    a := addOne(10)
        \\    b := addOne(a)
        \\    return a + b
        \\}
    ;

    var rt1 = try setup();
    defer rt1.deinit();
    try runSrc(&rt1, src); // must actually execute top-level code to define compute/addOne as globals
    const expected = try rt1.callGlobal("compute", &.{});

    // Compiled separately (not reused from rt1) because gbc_writer.write()
    // mutates the chunk it's given (buildDefusedCode remaps FuncObj.ip to
    // match the defused bytes it returns, leaving cs.code inconsistent with
    // those ips) — see gbc_writer.zig's module doc.
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, src);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx); // executes the loaded top-level code, defining addOne/compute as globals
    const actual = try vm.callGlobal(ctx, "compute", &.{});

    try std.testing.expectEqual(expected.int, actual.int);
}

test "gbc: a whole-valued float constant round-trips as .float, not .int" {
    // Regression: CONST_NUMBER/CONST_INT used to share one f64 wire slot,
    // reconstructed by a "no fractional part -> int" heuristic on read. A
    // literal like 1.0 is a genuine .float at compile time but is also
    // exactly representable as an integer, so the old heuristic silently
    // turned it into .int on load — this only surfaced once a test returned
    // a whole-valued float directly (found while adding variant support,
    // #5), since every earlier GBC test happened to avoid that exact shape.
    const src =
        \\func f() float {
        \\    return 1.0
        \\}
    ;

    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, src);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual = try vm.callGlobal(ctx, "f", &.{});

    try std.testing.expect(actual == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), actual.float, 1e-9);
}

test "gbc: writer supports struct-typed constants" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Point struct { x int, y int }
        \\func origin() Point { return Point { x: 0, y: 0 } }
    );
    const bytes = try gbc_writer.write(rt.chunk_state, std.testing.allocator, .{ .root_source = "" });
    std.testing.allocator.free(bytes);
}

test "gbc: writer rejects an enum-typed constant (out of scope for this increment)" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Status enum { pending, active, done }
        \\func f() Status { return Status.active }
    );
    try std.testing.expectError(error.UnsupportedConstant, gbc_writer.write(rt.chunk_state, std.testing.allocator, .{ .root_source = "" }));
}

test "gbc: writer supports a captureless (module-scope) predicate-bearing named type" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Score int predicate func(x) { return x >= 0 and x <= 100 }
        \\func f() Score { return Score(50) }
    );
    const bytes = try gbc_writer.write(rt.chunk_state, std.testing.allocator, .{ .root_source = "" });
    std.testing.allocator.free(bytes);
}

// A named type declared inside a function, with a predicate that captures
// that function's own locals (predicate_uv_count > 0 in compiler_decls.zig's
// namedTypeDecl/subtypeDecl), used to hit a real, GBC-unrelated compiler bug
// the moment the enclosing function ran: `make_closure` was emitted before
// the named type's own `emitConst`, but the `set_named_predicate` opcode
// expected the opposite stack order — TypeError, unconditionally, on every
// call. Fixed (issue #211) by deferring the `make_closure` emission to run
// immediately before `set_named_predicate`, after the named type's own
// `emitConst`, in both namedTypeDecl and subtypeDecl.
test "compiler: in-function named type predicate capturing an enclosing local (issue #211)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func make(threshold int, val int) int {
        \\    type Score int predicate func(x) { return x >= threshold }
        \\    return int(Score(val))
        \\}
    );
    const ok = try rt.callGlobal("make", &.{ .{ .int = 5 }, .{ .int = 5 } });
    try std.testing.expectEqual(@as(i64, 5), ok.int);
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("make", &.{ .{ .int = 5 }, .{ .int = 1 } }));
}

test "gbc: struct and named-type constants round-trip through write+read and execute correctly" {
    const src =
        \\type Meters int range 0..1000
        \\type Reading struct { value Meters, label string }
        \\func f() int {
        \\    r := Reading { value: Meters(42), label: "test" }
        \\    return int(r.value)
        \\}
    ;

    var rt1 = try setup();
    defer rt1.deinit();
    try runSrc(&rt1, src);
    const expected = try rt1.callGlobal("f", &.{});

    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, src);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual = try vm.callGlobal(ctx, "f", &.{});

    try std.testing.expectEqual(expected.int, actual.int);
}

test "gbc: variant-type constants (shared fields, record arm, single-payload arm, no-payload arm) round-trip through write+read and execute correctly" {
    const src =
        \\type Shape variant {
        \\    x float,
        \\    circle { radius float },
        \\    tag(label string),
        \\    point,
        \\}
        \\func area(s Shape) float {
        \\    switch s {
        \\        case .circle { return s.radius * 2.0 }
        \\        case .tag { return 0.0 }
        \\        case .point { return 0.0 }
        \\    }
        \\}
        \\func f() float {
        \\    c := Shape.circle { x: 1.0, radius: 5.0 }
        \\    return c.x + area(c)
        \\}
    ;

    var rt1 = try setup();
    defer rt1.deinit();
    try runSrc(&rt1, src);
    const expected = try rt1.callGlobal("f", &.{});

    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, src);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual = try vm.callGlobal(ctx, "f", &.{});

    try std.testing.expectApproxEqAbs(expected.float, actual.float, 1e-9);
}

test "gbc: a predicate-bearing named type still enforces its predicate after round-tripping" {
    // Note: `f` returns `int`, not `Score` — deliberately independent of
    // issue #212 (now fixed, see the regression test below), which was a
    // separate, GBC-unrelated VM bug specific to a *declared, checked*
    // function return type that is itself a predicate-bearing named type.
    // Constructing `Score(n)` as a local exercises the predicate without
    // relying on that other, separately-tested path.
    const src =
        \\type Score int predicate func(x) { return x >= 0 and x <= 100 }
        \\func f(n int) int {
        \\    s := Score(n)
        \\    return int(s)
        \\}
    ;

    var rt1 = try setup();
    defer rt1.deinit();
    try runSrc(&rt1, src);
    const expected_ok = try rt1.callGlobal("f", &.{.{ .int = 50 }});
    try std.testing.expectError(error.PredicateFailed, rt1.callGlobal("f", &.{.{ .int = 200 }}));

    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, src);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual_ok = try vm.callGlobal(ctx, "f", &.{.{ .int = 50 }});
    try std.testing.expectEqual(expected_ok.int, actual_ok.int);
    try std.testing.expectError(error.PredicateFailed, vm.callGlobal(ctx, "f", &.{.{ .int = 200 }}));
}

// Returning a predicate-bearing named type as a function's *declared,
// checked* return type used to crash with a fatal VM integrity error
// (ImpossibleOpcodeState, frame corruption) the moment the function
// returned. Root cause: retSlowPath (vm.zig) held a raw pointer into
// ctx.vs.frames[fi] across the call to enforceFuncReturnTypes, which — for
// a predicate-bearing named_t return — makes a reentrant nested VM call to
// run the predicate function. That nested call reuses (and overwrites) the
// exact same frames[] slot once frame_top no longer counts it, so the outer
// retSlowPath's later reads of frame.base/frame.ret_ip picked up the nested
// call's frame data instead of its own. Fixed (issue #212) by capturing
// frame.base/frame.ret_ip/frame.has_typed_returns into locals before
// frame_top is dropped, matching the pattern the multi-named-return spread
// path already used a few lines above.
// The named-error-type constructor (vm.zig's .named_error_type case)
// interned a dyn_string's or string_view's bytes via internStr, which
// stores a raw reference without copying ("s MUST point at immortal
// data") — but those bytes live in GC-managed memory, not immortal
// storage. A later allocation forcing a heap compaction could relocate
// or reuse that memory while the named_error_value's msg pointer still
// pointed at it, corrupting the message. Fixed by switching to
// internStrCopy, which copies to the permanent bump allocator first
// (same fix already applied to core_error/cap_http.zig, commit 7a87570).
// A small heap plus post-construction allocation churn is needed to
// force compaction to actually relocate the message bytes.
test "compiler: named error value message survives compaction" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 128 * 1024,
        .max_objects = 2048,
    });
    defer rt.deinit();

    try std.testing.expect(rt.run(
        \\std := import("std")
        \\type MyErr error
        \\func build(n int) error {
        \\    s := "msg-" + std.conv.to_string(n) + "-tail"
        \\    return MyErr(s)
        \\}
        \\e := build(424242)
        \\func churn() string {
        \\    i := 0
        \\    for i < 3000 {
        \\        junk := "garbage-" + std.conv.to_string(i) + "-more-padding-here"
        \\        _ = std.core.bytelen(junk)
        \\        i = i + 1
        \\    }
        \\    return string(e)
        \\}
    ) == .ok);
    const result = rt.call("churn", &.{});
    switch (result) {
        .ok => |v| try std.testing.expectEqualStrings("msg-424242-tail", try vms.asStringValue(v)),
        else => return error.TestUnexpectedResult,
    }
}

test "compiler: predicate-bearing named type as a function's declared return type (issue #212)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Score int predicate func(x) { return x >= 0 and x <= 100 }
        \\func make_score(n int) Score { return Score(n) }
    );
    const ok = try rt.callGlobal("make_score", &.{.{ .int = 50 }});
    const inner = ok.namedInner() orelse ok;
    try std.testing.expectEqual(@as(i64, 50), inner.int);
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("make_score", &.{.{ .int = 500 }}));
}

test "gbc: interface-type constants round-trip and assert_interface still enforces conformance" {
    // Exercises the exact concern that made interface support riskier than
    // struct/named/variant: interfaceMethodMatches (vm_types.zig) compares
    // an interface method's declared param/return types against the actual
    // implementing function's FuncObj.param_types/return_types at every
    // assert_interface check — if the loaded FuncObj's types were left
    // empty/placeholder (as function param/return types were before this
    // increment), a real, correctly-typed conformance would wrongly fail
    // after a GBC round-trip. Covers both a conforming type (succeeds) and
    // a non-conforming one (still rejected) through the loaded artifact.
    const src =
        \\type Adder interface {
        \\    add(int) int,
        \\}
        \\type Counter struct { n int }
        \\func (c Counter) add(x int) int { return c.n + x }
        \\type NotAnAdder struct { z int }
        \\func call_add(a Adder, x int) int { return a.add(x) }
        \\func good() int {
        \\    c := Counter { n: 10 }
        \\    return call_add(c, 5)
        \\}
        \\func bad() int {
        \\    n := NotAnAdder { z: 1 }
        \\    return call_add(n, 1)
        \\}
    ;

    var rt1 = try setup();
    defer rt1.deinit();
    try runSrc(&rt1, src);
    const expected = try rt1.callGlobal("good", &.{});
    try std.testing.expectError(error.TypeError, rt1.callGlobal("bad", &.{}));

    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, src);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual = try vm.callGlobal(ctx, "good", &.{});
    try std.testing.expectEqual(expected.int, actual.int);
    try std.testing.expectError(error.TypeError, vm.callGlobal(ctx, "bad", &.{}));
}

test "gbc: a named type's default value and is_anonymous/scale round-trip correctly" {
    // Regression coverage for fields the writer previously silently dropped
    // from NAMED entries entirely (not rejected — just never written, a gap
    // found while extending GBC for predicates/interfaces): a non-zero
    // `default` on a range-constrained named type (zero-init must produce
    // the declared default, not the base type's ordinary zero), and `scale`
    // (decimal fixed-point precision — a zero-inited Price must compare
    // equal to a freshly constructed Price(9.99), which only holds if both
    // share the same scale-encoded raw representation).
    const src =
        \\type Grade int range 1..5 default 3
        \\type Price decimal 2 default 9.99
        \\func f() int {
        \\    var g Grade
        \\    return int(g)
        \\}
        \\func p() bool {
        \\    var pr Price
        \\    return pr == Price(9.99)
        \\}
    ;

    var rt1 = try setup();
    defer rt1.deinit();
    try runSrc(&rt1, src);
    const expected_g = try rt1.callGlobal("f", &.{});
    const expected_p = try rt1.callGlobal("p", &.{});

    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, src);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual_g = try vm.callGlobal(ctx, "f", &.{});
    const actual_p = try vm.callGlobal(ctx, "p", &.{});
    try std.testing.expectEqual(expected_g.int, actual_g.int);
    try std.testing.expectEqual(expected_p.boolean, actual_p.boolean);
    try std.testing.expect(actual_p.boolean);
}

test "gbc: reader rejects a corrupted magic" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);

    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    corrupted[0] = 0x00;

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.InvalidMagic, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator));
}

test "gbc: reader rejects a corrupted body checksum" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);

    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    // Flip a byte inside the body (past the 8-byte magic + 192-byte header).
    corrupted[8 + gbc_writer.HEADER_SIZE + 4] ^= 0xFF;

    var rt3 = try setup();
    defer rt3.deinit();
    chunk.setActive(rt3.chunk_state);
    globals.setActive(&rt3.globals_state);
    heap.setActive(&rt3.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.BodyChecksumMismatch, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator));
}

test "cap:net listen: bare --cap net (dial only) refuses listen at call time" {
    // Import must still succeed (bare "net" satisfies the "net" import gate),
    // but the listen scope wasn't granted, so the call itself must return a
    // catchable error rather than a crash or a compile-time failure.
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"net"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\net := import("cap:net")
        \\func testListen() string {
        \\    l, err := net.listen("tcp", "127.0.0.1:0")
        \\    if err != null { return "err" }
        \\    return "ok"
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("testListen", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("err", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
}

test "cap:net listen: default-deny refuses listen with no policy rules" {
    net_state.clearListenPolicyRules();
    defer net_state.clearListenPolicyRules();

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"net.listen"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\net := import("cap:net")
        \\func testListen() string {
        \\    l, err := net.listen("tcp", "127.0.0.1:0")
        \\    if err != null { return "err" }
        \\    return "ok"
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("testListen", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("err", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
}

fn netListenClientWorker(port: u16, connected: *std.atomic.Value(bool), echoed: *std.atomic.Value(bool)) void {
    const sock = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(sock) != .SUCCESS) return;
    const fd: std.posix.socket_t = @intCast(sock);
    defer _ = std.posix.system.close(fd);

    var addr_storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
    const sa: *std.posix.sockaddr.in = @ptrCast(&addr_storage);
    sa.family = std.posix.AF.INET;
    sa.port = std.mem.nativeToBig(u16, port);
    sa.addr = @bitCast([4]u8{ 127, 0, 0, 1 });

    // The listener may not have bound yet when this thread starts; busy-retry
    // rather than assuming ordering between the two threads (connect() on a
    // refused port returns near-instantly, so this spins for at most a few
    // milliseconds in practice).
    var attempts: usize = 0;
    while (attempts < 20000) : (attempts += 1) {
        const rc = std.posix.system.connect(fd, @ptrCast(&addr_storage), @sizeOf(std.posix.sockaddr.in));
        if (std.posix.errno(rc) == .SUCCESS) {
            connected.store(true, .seq_cst);
            break;
        }
    }
    if (!connected.load(.seq_cst)) return;

    const wrc = std.posix.system.write(fd, "ping", 4);
    if (std.posix.errno(wrc) != .SUCCESS) return;

    var buf: [64]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return;
    echoed.store(std.mem.eql(u8, buf[0..n], "pong:ping"), .seq_cst);
}

test "cap:net listen/accept: real POSIX bind+accept+read+write roundtrip" {
    net_state.clearListenPolicyRules();
    _ = net_state.addListenPolicyRule(.allow, "*", 0);
    defer net_state.clearListenPolicyRules();

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{ "net", "net.listen" },
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    // Fixed high port rather than discovering an OS-assigned ephemeral one:
    // the script's listen()+accept() run as one synchronous host call, so
    // there's no point at which to observe local_addr() before the client
    // thread needs to know where to connect.
    const port: u16 = 18453;
    var connected = std.atomic.Value(bool).init(false);
    var echoed = std.atomic.Value(bool).init(false);
    const client = try std.Thread.spawn(.{}, netListenClientWorker, .{ port, &connected, &echoed });

    var src_buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf,
        \\net := import("cap:net")
        \\func serve() string {{
        \\    l, err := net.listen("tcp", "127.0.0.1:{d}")
        \\    if err != null {{ return "listen error" }}
        \\    l.set_accept_deadline(3000)
        \\    conn, aerr := l.accept()
        \\    if aerr != null {{ return "accept error" }}
        \\    data := conn.read(64)
        \\    conn.write("pong:" + data)
        \\    conn.close()
        \\    l.close()
        \\    return "ok"
        \\}}
    , .{port});

    switch (rt.run(src)) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("serve", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("ok", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }

    client.join();
    try std.testing.expect(connected.load(.seq_cst));
    try std.testing.expect(echoed.load(.seq_cst));
}

// math.abs(minInt(i64)) used to panic: @abs on i64 returns a u64 magnitude
// of 2^63, which doesn't fit back into i64 via @intCast. math.max/min used
// to round-trip int operands through f64 to pick a result, which rounds a
// value like i64::max up to the next representable f64 (2^63, one past
// i64::max) and then panicked converting that back with @intFromFloat.
test "compiler: std.math abs/max/min raise RangeError (not a crash) at the i64 boundary" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func absMin() int { return std.math.abs(-9223372036854775808) }
        \\func maxNearBoundary() int { return std.math.max(9223372036854775807, 0) }
        \\func minNearBoundary() int { return std.math.min(9223372036854775807, 9223372036854775806) }
        \\func maxNormal() int { return std.math.max(3, 7) }
        \\func minNormal() int { return std.math.min(3, 7) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("absMin", &.{}));
    const max_v = try rt.callGlobal("maxNearBoundary", &.{});
    try std.testing.expectEqual(@as(i64, 9223372036854775807), max_v.int);
    const min_v = try rt.callGlobal("minNearBoundary", &.{});
    try std.testing.expectEqual(@as(i64, 9223372036854775806), min_v.int);
    const max_n = try rt.callGlobal("maxNormal", &.{});
    try std.testing.expectEqual(@as(i64, 7), max_n.int);
    const min_n = try rt.callGlobal("minNormal", &.{});
    try std.testing.expectEqual(@as(i64, 3), min_n.int);
}

// std.conv.to_int used to feed NaN/Infinity/out-of-range floats straight
// into @intFromFloat, which panics on all three instead of raising a
// catchable error. Also covers the string path (common.parseFloat), where
// "1e" (no digits after the exponent marker) used to silently parse as 1.0
// instead of being rejected as malformed.
test "compiler: std.conv.to_int raises RangeError/TypeError instead of crashing on NaN/Inf/malformed input" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func viaNan() int { return std.conv.to_int(std.math.nan()) }
        \\func viaInf() int { return std.conv.to_int(std.math.inf) }
        \\func viaHuge() int { return std.conv.to_int(1e300) }
        \\func viaBadStr() int { return std.conv.to_int("1e") }
        \\func viaOk() int { return std.conv.to_int(42.9) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("viaNan", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("viaInf", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("viaHuge", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("viaBadStr", &.{}));
    const ok = try rt.callGlobal("viaOk", &.{});
    try std.testing.expectEqual(@as(i64, 42), ok.int);
}

// std.rand.perm(n) used to panic for a huge n: on wasm32 (32-bit usize),
// @intCast(n) itself panics; on 64-bit, vmAllocManagedSlice's own
// @sizeOf(Value) * n size-limit guard overflowed u64 (a raw, non-wrapping
// multiply) before the size-limit check could ever fire.
test "compiler: std.rand.perm raises RangeError (not a crash) for an unreasonably large n" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func hugePerm() []int { return std.rand.perm(9223372036854775807) }
        \\func smallPerm() []int { return std.rand.perm(5) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("hugePerm", &.{}));
    const small = try rt.callGlobal("smallPerm", &.{});
    try std.testing.expectEqual(@as(usize, 5), (try vms.asArraySlice(small.object)).len);
}

// tplParse's parse-time ctrl_stack (tracking nested {{if}}/{{range}}/{{with}}
// blocks) was a fixed [64]TplCtrlEntry with no bounds check, so a template
// with more than 64 unclosed control tags indexed past the array (a Zig
// safety panic that aborts the process) instead of raising a catchable
// error. This is reachable via pure template *source text*, no numeric
// trickery required.
test "compiler: std.template.parse raises an error (not a crash) on excessive control-tag nesting" {
    var rt = try setup();
    defer rt.deinit();
    const prefix =
        \\std := import("std")
        \\func f() bool {
        \\    src := "
    ;
    const suffix =
        \\"
        \\    std.template.parse(src)
        \\    return true
        \\}
        \\
    ;
    var buf: [16 * 1024]u8 = undefined;
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    for (0..80) |_| {
        @memcpy(buf[pos..][0..8], "{{if 1}}");
        pos += 8;
    }
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    try runSrc(&rt, buf[0..pos]);
    try std.testing.expectError(error.InvalidTemplate, rt.callGlobal("f", &.{}));
}

// mapSet's caller (opSetIndex/opSetField) had already popped key/val off the
// VM operand stack by the time mapSet ran, so a growth allocation
// (vmAllocManagedSlice, which can trigger a full mark-sweep collectGarbage)
// could sweep the value being inserted if it had no other live reference —
// storing a dangling pointer into the map. Uses a small heap plus heavy
// garbage churn to force collectGarbage to run mid-insert, mirroring the
// named-error-value regression test above.
test "compiler: map insert keeps a freshly built value alive across a growth allocation" {
    var rt = try setupApiRuntime(.{ .heap_size_bytes = 128 * 1024, .max_objects = 2048 });
    defer rt.deinit();
    switch (rt.run(
        \\std := import("std")
        \\func churn() string {
        \\    m := {}
        \\    for i := 0; i < 200; i += 1 {
        \\        // Garbage to keep pressuring the heap toward collectGarbage.
        \\        junk := "junk-" + std.conv.to_string(i) + "-filler-filler-filler"
        \\        _ = junk
        \\        key := "k" + std.conv.to_string(i)
        \\        // The value has no other reference once assigned here —
        \\        // exactly the case that used to go stale mid-insert.
        \\        m[key] = "v-" + std.conv.to_string(i) + "-tail-marker"
        \\    }
        \\    return m["k199"]
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("churn", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("v-199-tail-marker", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
}

// Plain int+int/int-int/int*int throughout the dispatch loop (the main
// add/sub/mul opcodes, `+=`/inc-const fast paths, and the various fused
// local/global/field/const/loop opcodes) used to do raw, unchecked i64
// arithmetic: near the i64 boundary this panics (a hard Zig safety trap
// that aborts the whole process) in Debug/ReleaseSafe, or silently wraps to
// a sign-flipped wrong answer in ReleaseFast. Fixed with checkedIntAdd/Sub/
// Mul helpers (@addWithOverflow/etc.) raising a catchable RangeError.
test "compiler: int add/sub/mul raise RangeError (not a crash) on overflow" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func addOverflow() int { return 9223372036854775807 + 1 }
        \\func subOverflow() int { return -9223372036854775807 - 2 }
        \\func mulOverflow() int { return 4611686018427387904 * 2 }
        \\func addOk() int { return 40 + 2 }
        \\func compoundOverflow() int {
        \\    x := 9223372036854775807
        \\    x += 1
        \\    return x
        \\}
        \\func loopOverflow() int {
        \\    x := 9223372036854775806
        \\    for i := 0; i < 5; i += 1 {
        \\        x += 1
        \\    }
        \\    return x
        \\}
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("addOverflow", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("subOverflow", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("mulOverflow", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("compoundOverflow", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("loopOverflow", &.{}));
    const ok = try rt.callGlobal("addOk", &.{});
    try std.testing.expectEqual(@as(i64, 42), ok.int);
}

// Unary '-' on i64::MIN doesn't fit back into i64 (magnitude is one past
// maxInt) — this used to be a raw `-n` that panics. Also covers the
// decimal-literal-overflow fix in common.parseInt: a bare decimal digit run
// exceeding i64's range now cleanly fails to compile instead of silently
// wrapping to a sign-flipped constant.
test "compiler: unary negation of i64::MIN raises RangeError; oversized decimal literal fails to compile" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func negMin() int { return -9223372036854775808 }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("negMin", &.{}));

    var rt2 = try setup();
    defer rt2.deinit();
    try std.testing.expectError(error.BadNumber, compile(&rt2, "x := 99999999999999999999"));
}

// minInt(i64) div -1 mathematically overflows (2^63); the old special-case
// sidestepped @divTrunc's trap but returned the dividend unmodified as if it
// were the correct quotient — a silently wrong answer instead of an error.
test "compiler: int_div raises RangeError (not a silently wrong answer) for i64::MIN div -1" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func g(a int, b int) int { return a div b }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("g", &.{ .{ .int = std.math.minInt(i64) }, .{ .int = -1 } }));
}

// std.json.stringify used to serialize any bigint as `null` (falling through
// the object-tag switch's generic else branch), silently discarding the
// value entirely. std.conv.to_int/to_float rejected bigint with TypeError
// even though the direct-dispatched `int(...)`/`float(...)` builtins already
// supported it — an inconsistency between two paths meant to be equivalent.
test "compiler: std.json.stringify serializes bigint as digits, not null; std.conv accepts bigint" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func stringifyBig() string { return std.json.stringify(bigint("123456789012345678901234567890")) }
        \\func convIntBig() int { return std.conv.to_int(bigint(123)) }
        \\func convFloatBig() float { return std.conv.to_float(bigint(123)) }
    );
    const json_str = try rt.callGlobal("stringifyBig", &.{});
    try std.testing.expectEqualStrings("123456789012345678901234567890", try vms.asStringValue(json_str));
    const as_int = try rt.callGlobal("convIntBig", &.{});
    try std.testing.expectEqual(@as(i64, 123), as_int.int);
    const as_float = try rt.callGlobal("convFloatBig", &.{});
    try std.testing.expectEqual(@as(f64, 123.0), as_float.float);
}

// A predicate-bearing named array/map element type was only checked at
// initial construction (validateNamedCollectionElements); every mutation
// path after that (arr[i]=v, m[k]=v, core.append) reused a shallow
// matchesTypeSpec check that only compares a bare scalar's type tag, not
// its named_t spec's own range/predicate — so a script could silently
// write a value into a "validated" collection that violates its own
// element type's predicate.
test "compiler: array/map element write re-enforces the named element type's predicate" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Score int predicate func(x) { return x >= 0 and x <= 100 }
        \\type ScoreList []Score
        \\type ScoreMap [string]Score
        \\func arrWrite() int { s := ScoreList([10, 20]); s[0] = 500; return 0 }
        \\func arrAppend() int { s := ScoreList([10, 20]); _ = std.core.append(s, 500); return 0 }
        \\func mapWrite() int { m := ScoreMap({"a": 10}); m["a"] = 500; return 0 }
        \\func arrWriteOk() int { s := ScoreList([10, 20]); s[0] = 30; return s[0] }
    );
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("arrWrite", &.{}));
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("arrAppend", &.{}));
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("mapWrite", &.{}));
    const ok = try rt.callGlobal("arrWriteOk", &.{});
    try std.testing.expectEqual(@as(i64, 30), ok.int);
}

// Every other arithmetic-carrier path (add/sub/mul, unary neg, abs) re-checks
// a named type's predicate after producing a new value; TypeName.succ/pred
// (both the bound-function form and the method-call form) didn't, so
// `Even.succ(4)` could silently return an odd value.
test "compiler: named type succ/pred re-enforces the predicate" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Even int range 0..10 predicate func(x) { return x rem 2 == 0 }
        \\type Bounded int range 0..10
        \\func succFn() int { return Even.succ(4) }
        \\func predFn() int { return Even.pred(6) }
        \\func succOk() int { return Bounded.succ(4) }
    );
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("succFn", &.{}));
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("predFn", &.{}));
    const ok = try rt.callGlobal("succOk", &.{});
    const inner = ok.namedInner() orelse ok;
    try std.testing.expectEqual(@as(i64, 5), inner.int);
}

// String `+` concatenation on a named string type built the result via
// makeNamedValue with no predicate check at all, unlike every numeric
// carrier path — a length-bounded named string could concatenate into a
// longer string silently violating its own predicate.
test "compiler: named string concatenation re-enforces the predicate" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Short string predicate func(x) { return std.core.len(x) <= 5 }
        \\func concatTooLong() string {
        \\    a := Short("abc")
        \\    b := Short("cde")
        \\    return string(a + b)
        \\}
        \\func concatOk() string {
        \\    a := Short("ab")
        \\    b := Short("cd")
        \\    return string(a + b)
        \\}
    );
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("concatTooLong", &.{}));
    const ok = try rt.callGlobal("concatOk", &.{});
    try std.testing.expectEqualStrings("abcd", try vms.asStringValue(ok));
}

// std.fmt.format/printf/eprintf take no capability at all (reachable from
// any script). parseSpec's width/precision digit accumulation had no bound,
// so a format string with enough digits overflowed the accumulator (usize
// needs ~20 digits, i32 needs ~10) — a raw `*`/`+` traps on overflow,
// aborting the whole process.
test "compiler: std.fmt.format raises no crash on an absurdly long width/precision field" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func precOverflow() string { return std.fmt.format("%.9999999999f", 1.0) }
        \\func widthOverflow() string { return std.fmt.format("%99999999999999999999d", 1) }
        \\func normal() string { return std.fmt.format("%5d", 42) }
    );
    // Whatever exact result these produce isn't the point — the point is
    // they return cleanly (a success value, or a catchable error like
    // AllocationTooLarge for the clamped-but-still-huge field width)
    // instead of aborting the whole process, which a real crash would.
    _ = rt.callGlobal("precOverflow", &.{}) catch {};
    _ = rt.callGlobal("widthOverflow", &.{}) catch {};
    const normal = try rt.callGlobal("normal", &.{});
    try std.testing.expectEqualStrings("   42", try vms.asStringValue(normal));
}
