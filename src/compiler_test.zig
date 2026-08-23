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
const ct = @import("lang/compiler_types.zig");
const net_state = @import("lang/native/net_state.zig");
const http_state = @import("lang/native/http_state.zig");

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

// Fixed bug (2026-08-20), found by a coverage-audit test: every test below
// that manually builds a vm.VMContext and calls vm.run()/vm.callGlobal()
// directly (bypassing Runtime.run()/runFromGbc(), needed here to drive
// gbc_reader.read() before there's a compiled program the normal entry
// points could run) used to re-pin only 3 of Runtime.activate()'s 8
// setActive calls — chunk/globals/heap — by hand, omitting vm/tasks_mod/
// fs_state/net_state/http_state. Runtime.activate()'s own doc comment
// explains why this matters: setup() returns Runtime BY VALUE, and Zig
// does not guarantee that copy is elided, so every pointer captured
// during initWithConfig (before the return) can go stale the moment the
// caller's `var rt3 = try setup();` copy lands at a different address.
// chunk_state survived because it's a *pointer* field (heap-allocated
// separately, stable across the move); globals_state/heap_state were
// already being manually re-pinned; tasks_mod (and the other omitted
// globals) were not. This went undetected because ordinary Runtime.run()-
// based tests self-heal (every real entry point calls activate() on its
// own, already-stable `self`) — only this file's ~28 manually-driven
// VMContext tests were exposed, and only when something (here,
// vmAllocObject under -Dgc_stress=true, a CI-only lane the pre-push hook
// never runs) actually dereferenced the stale global mid-test: vm_gc.zig's
// collectGarbage walked tasks_mod.g_state's task table, read
// 0xAA-poisoned freed memory as an out-of-range temp_root_top, and
// panicked. Fixed by calling `rt3.activate()` instead of the manual
// triplet everywhere below — it does strictly more, correctly.

fn compile(rt: *Runtime, src: []const u8) !void {
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    var compiler = try Compiler.init(src, chunk.g_state, heap.g_state, .{});
    defer compiler.deinit();
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
    try session.initArena();
    defer session.deinitArena();
    session.hs = heap.g_state;
    session.provider = .{ .table = &.{} };
    session.host_module_names = &.{};
    session.host_module_descs = &.{};
    session.enabled_capabilities = &.{};
    session.capability_modules = &.{};

    var compiler = try Compiler.init(src, chunk.g_state, heap.g_state, .{
        .module_prefix = path,
        .module_ctx = &session,
        .resolve_import = module_compile.Session.resolveImportOpaque,
        .has_module_export = module_compile.hasModuleExport,
        .resolve_module_type = module_compile.resolveModuleTypeKind,
    });
    defer compiler.deinit();
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

// Found via the REPL, not by review: `x := "asd"` on one line, then `x`
// alone on the next, printed "x" (the SECOND line's own global-name
// lookup) instead of "asd". Root cause: internStr's *const StringSlice
// points directly into chunk_state.str_slices, the only Value variant that
// references chunk-owned (not GC-heap) memory -- every other kind either
// lives inline in the Value union or as an .object on the persistent GC
// heap. runIncremental's chunk_state.reset() (once per REPL line)
// unconditionally zeroed str_slice_count, so a persisted global's string
// value became a dangling reference to whatever the NEXT line happened to
// intern at that same slot. Reproduced here without any I/O capture
// machinery: persist a string-holding global across two separate
// runIncremental calls, then read it back through a THIRD incremental
// compile (a function returning the global) rather than relying on the
// REPL's bare-expression echo, so this only exercises the actual
// Value-persistence bug, not the echo mechanism itself. Covers a bare
// string global, and a string nested inside an array (the shape that
// originally surfaced this while testing the []Type{...} composite-literal
// sugar) and inside a map, since all three store the identical
// Value{.string = ...} shape.
test "repl: a string value (bare, in an array, in a map) survives across incremental compiles" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    try std.testing.expect(rt.runIncremental(
        \\x := "asd"
        \\arr := []string{"asd"}
        \\m := {"k": "asd"}
    ) == .ok);
    try std.testing.expect(rt.runIncremental(
        \\func getX() string { return x }
        \\func getArr0() string { return arr[0] }
        \\func getMK() string { return m["k"] }
    ) == .ok);

    switch (rt.call("getX", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("asd", try vms.asStringValue(v)),
        .runtime_error => return error.TestUnexpectedResult,
    }
    switch (rt.call("getArr0", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("asd", try vms.asStringValue(v)),
        .runtime_error => return error.TestUnexpectedResult,
    }
    switch (rt.call("getMK", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("asd", try vms.asStringValue(v)),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Coverage gap audit (2026-08-23): runtime.zig's REPL cross-line persistence
// machinery (persistReplSymbols/restoreReplCompilerState and friends) was
// almost entirely untested beyond the two compile-error-parity tests above
// and the string-survival regression. Each runIncremental call compiles
// against a brand-new Compiler, so every declaration category (named-type
// range/predicate metadata, struct/interface types, global funcs, enum
// member lists, std/import namespace provenance) has to be explicitly
// serialized out of the old compiler's registry and replayed into the new
// one — these tests drive at least two runIncremental calls each and prove
// the LATER call actually sees what an EARLIER one declared, not just that
// a single line in isolation compiles.
test "repl: a named type's range constraint (not just its bare name) persists across incremental compiles" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    try std.testing.expect(rt.runIncremental("type Score int range 0..100") == .ok);
    try std.testing.expect(rt.runIncremental(
        \\func makeGood() Score { return Score(50) }
        \\func makeBad() Score { return Score(500) }
    ) == .ok);

    switch (rt.call("makeGood", &.{})) {
        .ok => |v| try std.testing.expect(v == .int and v.int == 50),
        .runtime_error => return error.TestUnexpectedResult,
    }
    switch (rt.call("makeBad", &.{})) {
        .ok => return error.TestUnexpectedResult,
        .runtime_error => |e| try std.testing.expectEqual(error.RangeError, e.kind),
    }
}

test "repl: a struct type declared on one incremental line is instantiated and read back on a later line" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    try std.testing.expect(rt.runIncremental("type Point struct { x int, y int }") == .ok);
    try std.testing.expect(rt.runIncremental(
        \\func makePoint() Point { return Point{x: 3, y: 4} }
        \\func getX(p Point) int { return p.x }
    ) == .ok);

    const p = switch (rt.call("makePoint", &.{})) {
        .ok => |v| v,
        .runtime_error => return error.TestUnexpectedResult,
    };
    switch (rt.call("getX", &.{p})) {
        .ok => |v| try std.testing.expect(v == .int and v.int == 3),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// KNOWN LIMITATION, found by this test (not previously documented anywhere
// — see docs/changelog.md's "REPL type persistence" entry, which lists only
// type/subtype/struct/interface/variant DECLARATIONS as surviving across
// REPL lines, deliberately omitting func). runIncremental() unconditionally
// calls chunk_state.reset() on every line (see its own doc comment above),
// wiping all previously-compiled BYTECODE; only declaration METADATA is
// persisted/restored (persistReplSymbols's own comment on the global-func
// branch: "name only; overflow is graceful — duplicate detection
// degrades" — i.e. purely for duplicate-declaration checking, not for
// making the function body callable again). A function declared on one
// REPL line is only actually callable as long as its ORIGINAL chunk is
// still current: it works immediately after its own declaring line, but
// the very next unrelated line invalidates its bytecode reference, and a
// later call reads out-of-bounds into whatever the new line's chunk
// reused that offset for. This test documents CURRENT (broken) behavior;
// it should be rewritten to expect a correct call once REPL function
// persistence is implemented (analogous to how type declarations already
// are, by re-elaborating/re-emitting the function body fresh into every
// new line's chunk rather than only tracking its name).
test "repl: a function's compiled body does not survive past its own incremental line (known limitation)" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    try std.testing.expect(rt.runIncremental("func double(n int) int { return n * 2 }") == .ok);
    switch (rt.call("double", &.{.{ .int = 5 }})) {
        .ok => |v| try std.testing.expect(v == .int and v.int == 10),
        .runtime_error => return error.TestUnexpectedResult,
    }

    // A subsequent, unrelated incremental line resets the chunk out from
    // under the previously-declared function's stale bytecode reference.
    try std.testing.expect(rt.runIncremental("_ = 1") == .ok);
    switch (rt.call("double", &.{.{ .int = 5 }})) {
        .ok => return error.TestUnexpectedResult, // would mean this got fixed — update the test
        .runtime_error => |e| try std.testing.expectEqual(error.BytecodeOutOfBounds, e.kind),
    }
}

test "repl: an enum's full member list (not just its name) persists across incremental compiles" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    try std.testing.expect(rt.runIncremental("type Colors enum { red, green, blue }") == .ok);
    try std.testing.expect(rt.runIncremental(
        \\func blueOrdinal() int { return Colors.blue.int }
        \\func greenName() string { return Colors.green.name }
    ) == .ok);

    switch (rt.call("blueOrdinal", &.{})) {
        .ok => |v| try std.testing.expect(v == .int and v.int == 2),
        .runtime_error => return error.TestUnexpectedResult,
    }
    switch (rt.call("greenName", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("green", try vms.asStringValue(v)),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// KNOWN LIMITATION (same root cause as the "function's compiled body does
// not survive" test above, manifesting worse here: SILENTLY WRONG instead
// of erroring). `Square.area()`'s method body is compiled into the chunk
// on incremental line 2; by line 3, chunk_state.reset() has invalidated
// that bytecode reference. Calling it here through interface dynamic
// dispatch (sh.area()) doesn't hit the bounds check that direct-call
// hits above — it apparently returns without error, but with the WRONG
// value. This documents CURRENT (broken) behavior. Do not treat the
// currently-observed value as intentional/spec'd — it is presented here
// only so a future fix can tell it actually changed something, and this
// test should be rewritten to expect the correct area (16) once REPL
// function/method-body persistence is implemented (see the sibling test
// above for the full root-cause writeup).
test "repl: a method's compiled body from an earlier line is stale by the time a later line dispatches to it through an interface (known limitation)" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    try std.testing.expect(rt.runIncremental("type Shape interface { area() int }") == .ok);
    try std.testing.expect(rt.runIncremental(
        \\type Square struct { side int }
        \\func (s Square) area() int { return s.side * s.side }
    ) == .ok);
    try std.testing.expect(rt.runIncremental(
        \\func totalArea(sh Shape) int { return sh.area() }
        \\func run() int { return totalArea(Square{side: 4}) }
    ) == .ok);

    switch (rt.call("run", &.{})) {
        .ok => |v| try std.testing.expect(v != .int or v.int != 16), // would mean this got fixed — update the test
        .runtime_error => {}, // also acceptable evidence of the same staleness; either outcome documents the bug
    }
}

test "repl: std-import namespace provenance and a locally-declared struct coexist across incremental lines" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    try std.testing.expect(rt.runIncremental("std := import(\"std\")") == .ok);
    try std.testing.expect(rt.runIncremental("type Widget struct { n int }") == .ok);
    try std.testing.expect(rt.runIncremental(
        \\func combine(w Widget) int { return w.n + std.core.len([1, 2, 3]) }
        \\func run() int { return combine(Widget{n: 10}) }
    ) == .ok);

    switch (rt.call("run", &.{})) {
        .ok => |v| try std.testing.expect(v == .int and v.int == 13),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Coverage gap audit (2026-08-23): MaxReplSyms (= MaxTypes + MaxNamedTypes +
// MaxGlobals, runtime.zig) is sized so a single compiler's registry can
// never legitimately produce more *entries* than the REPL symbol table can
// hold — the per-category limits (TooManyTypes/TooManyNamedTypes/
// TooManyGlobals) always fire first. But persistReplSymbols' NAME BUFFER
// (repl_sym_name_buf, MaxNamedTypes*64 + MaxGlobals*64 bytes) is sized only
// for an *average* 64-byte name and has no matching per-declaration cap, so
// it can overflow on byte count long before any entry-count ceiling is
// reached. Use deliberately long names to hit that path cheaply (well under
// MaxNamedTypes named-type declarations) instead of needing thousands of
// lines.
// One declaration per runIncremental call (real REPL usage — a line at a
// time), not one giant concatenated blob: cfg.max_input_bytes is a
// preset-dependent build option (differs under -Dpreset=stress), and a
// single huge multi-line input previously tripped runIncremental's own
// `src.len > cfg.max_input_bytes` guard (error.InputTooLong) under the
// stress preset's smaller limit before ever reaching the REPL symbol
// buffer it meant to test. Each line here is ~620 bytes, comfortably under
// every preset's max_input_bytes, so only the intended sym_name_buf
// exhaustion (ReplSymNameBufSize = (MaxNamedTypes + MaxGlobals) * 64 =
// 98304 bytes; ~163 declarations at this padded name length) can trigger.
test "repl: exceeding the REPL symbol name buffer surfaces a graceful overflow error, not a crash" {
    var rt: Runtime = .{};
    defer rt.deinit();
    try rt.initWithConfig(.{ .allow_io = false }, 4 * 1024 * 1024, 8192, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.testing.allocator);

    const pad = "a" ** 600;
    var buf: [1024]u8 = undefined;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "type T{d}{s} int", .{ i, pad });
        rt.runIncremental(line) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqualStrings("REPL symbol name buffer full", rt.last_compile_msg_buf[0..rt.last_compile_msg_len]);
            return;
        };
    }
    return error.TestUnexpectedResult; // never overflowed within 300 declarations — buffer size assumption is stale
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
    var ip: usize = c.std_script_code_end;
    while (ip < c.code_len) {
        const op: Op = @enumFromInt(c.code[ip]);
        switch (op) {
            .call => {
                if (ip + 3 >= c.code_len) return null;
                const slot: u16 = (@as(u16, c.code[ip + 2]) << 8) | c.code[ip + 3];
                return .{ .offset = ip, .slot = slot };
            },
            // call IC is at bytes 6-7 of get_global_call
            .get_global_call, .get_global_call_tail => {
                if (ip + 7 >= c.code_len) return null;
                const slot: u16 = (@as(u16, c.code[ip + 6]) << 8) | c.code[ip + 7];
                return .{ .offset = ip, .slot = slot };
            },
            // call IC is at bytes 10-11 of call_global_global
            .call_global_global, .call_global_global_tail => {
                if (ip + 11 >= c.code_len) return null;
                const slot: u16 = (@as(u16, c.code[ip + 10]) << 8) | c.code[ip + 11];
                return .{ .offset = ip, .slot = slot };
            },
            else => {},
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
    // get_local_const_add + ret fuses further to get_local_const_add_ret
    try compile(&rt, "func f(x int) int { return x + 1 }");
    const c = rt.chunk_state;
    var found = false;
    for (c.code[0..c.code_len]) |op| {
        if (op == @intFromEnum(Op.get_local_const_add_ret)) {
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

// Regression for the .string immortality invariant.
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

// ── Dispatch gas: operation budget and trace hook ────────────────────────────

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

// ── Multi-runtime isolation ─────────────────────────────────────────────────

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
// bytes.zig's argAsI64 (backing std.bytes.u8/u16be/pack/slice/etc.) fed a
// NaN or out-of-i64-range float straight into @intFromFloat, which is
// safety-checked illegal behavior (process abort) for either — reachable
// from any script with no capability required, unlike vm.zig/core.zig's
// analogous conversions which already guarded against this.
test "compiler: std.bytes.u8 raises RangeError (not a crash) on NaN/Inf/huge float" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func viaNan() string { return std.bytes.u8(std.math.nan()) }
        \\func viaInf() string { return std.bytes.u8(std.math.inf) }
        \\func viaHuge() string { return std.bytes.u8(1e300) }
        \\func viaOk() string { return std.bytes.u8(65) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("viaNan", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("viaInf", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("viaHuge", &.{}));
    const ok = try rt.callGlobal("viaOk", &.{});
    try std.testing.expectEqualStrings("A", try vms.asStringValue(ok));
}

test "compiler: std.bytes decode family raises RangeError (not a crash) on a negative offset" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() int { return std.bytes.u32be_at(std.bytes.u32be(1234), -1) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("f", &.{}));
}

test "compiler: std.bytes pack/unpack round-trip, including the empty string" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\b := std.bytes
        \\data := b.pack([1, 2, 255, 0])
        \\assert b.len(data) == 4
        \\assert b.at(data, 0) == 1
        \\assert b.at(data, 1) == 2
        \\assert b.at(data, 2) == 255
        \\assert b.at(data, 3) == 0
        \\arr := b.unpack(data)
        \\assert std.core.len(arr) == 4
        \\assert arr[0] == 1
        \\assert arr[1] == 2
        \\assert arr[2] == 255
        \\assert arr[3] == 0
        \\empty_arr := b.unpack("")
        \\assert std.core.len(empty_arr) == 0
    );
}

test "compiler: std.bytes.slice takes a zero-copy view within bounds and raises RangeError outside them" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\b := std.bytes
        \\func validSlice() string { return b.slice(b.u8(0x41) + b.u8(0x42) + b.u8(0x43) + b.u8(0x44), 1, 3) }
        \\func negFrom() string { return b.slice(b.u8(1) + b.u8(2), -1, 1) }
        \\func toGreaterLen() string { return b.slice(b.u8(1) + b.u8(2), 0, 5) }
        \\func fromGreaterTo() string { return b.slice(b.u8(1) + b.u8(2), 2, 1) }
    );
    const valid = try rt.callGlobal("validSlice", &.{});
    try std.testing.expectEqualStrings("BC", try vms.asStringValue(valid));
    try std.testing.expectError(error.RangeError, rt.callGlobal("negFrom", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("toGreaterLen", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("fromGreaterTo", &.{}));
}

test "compiler: std.bytes.repeat concatenates n copies and rejects a negative count" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\b := std.bytes
        \\func validRepeat() string { return b.repeat(b.u8(0x41), 3) }
        \\func negRepeat() string { return b.repeat(b.u8(0x41), -1) }
    );
    const valid = try rt.callGlobal("validRepeat", &.{});
    try std.testing.expectEqualStrings("AAA", try vms.asStringValue(valid));
    try std.testing.expectError(error.RangeError, rt.callGlobal("negRepeat", &.{}));
}

test "compiler: std.bytes little-endian encoders round-trip through their _at decoders" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\b := std.bytes
        \\data := b.u16le(0x1234) + b.u32le(0x89ABCDEF) + b.u64le(0x0102030405060708) + b.f32le(3.5) + b.f64le(2.5)
        \\assert b.u16le_at(data, 0) == 0x1234
        \\assert b.u32le_at(data, 2) == 0x89ABCDEF
        \\assert b.u64le_at(data, 6) == 0x0102030405060708
        \\assert b.f32le_at(data, 14) == 3.5
        \\assert b.f64le_at(data, 18) == 2.5
    );
}

test "compiler: std.bytes index_of/contains/starts_with/ends_with/count/replace" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\b := std.bytes
        \\data := b.pack([65, 66, 67, 66, 67])
        \\assert b.index_of(data, b.pack([66, 67])) == 1
        \\assert b.index_of(data, b.pack([90])) == -1
        \\assert b.contains(data, b.pack([67, 66])) == true
        \\assert b.contains(data, b.pack([90])) == false
        \\assert b.starts_with(data, b.pack([65, 66])) == true
        \\assert b.starts_with(data, b.pack([66, 67])) == false
        \\assert b.ends_with(data, b.pack([66, 67])) == true
        \\assert b.ends_with(data, b.pack([65, 66])) == false
        \\assert b.count(data, b.pack([66, 67])) == 2
        \\assert b.count(data, "") == 6
        \\assert b.replace(data, b.pack([66, 67]), b.pack([88])) == "AXX"
        \\assert b.replace(data, "", b.pack([90])) == "ABCBC"
    );
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
    // and gengo-mqtt as a transaction/packet-ID counter).
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
    // A bare string-literal index is known at compile time, so
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

// ── Native-lane call-flag emission (argc | 0x80) ────────────────────────────
//
// selectTypedArithmeticOp-adjacent but distinct: this is compiler.zig's
// argProvenForParam/checkDirectCallArgCompatibility machinery (see
// dev-docs/design/compiler-architecture.md §3's "Calls" paragraph), which
// sets the top bit of a direct call's argc byte when every argument is
// compiler-provably type-correct against the resolved callee signature,
// letting the VM's warm call path skip runtime arg-type enforcement
// entirely. These tests cover the native path directly.

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

// ── Native-lane return-proof stamping (returns_proven) ──────────────────────
//
// See dev-docs/design/compiler-architecture.md §4's "Return-type proof"
// paragraph: a single-primitive-return function whose body provably always
// returns, with every return matching the declared type, gets its FuncObj
// stamped returns_proven — letting the VM trust the return value's type
// instead of re-checking it at runtime. These tests cover the native path directly.

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

// ── Native-lane typed-assignment prolog/epilog matrix ───────────────────────
//
// See dev-docs/design/compiler-architecture.md §9's "Erased vs. boxed named
// types" invariant: named types over a scalar/enum base are erased at
// runtime, so the compiler emits validate-in-place ops (validate_named_range
// / check_named_predicate) instead of a real constructor call; named types
// over a non-scalar base (string/array/map) always go through a real
// get_global+call(1) constructor. This distinction is threaded through
// compoundStmt, incrStmt, and returnStmt's named-return epilogs. Had zero
// native coverage directly.

fn countOp(c: *chunk.State, op: Op) usize {
    var count: usize = 0;
    var ip: usize = c.std_script_code_end;
    while (ip < c.code_len) {
        const inst = chunk_decoder.decodeAt(c, ip) catch break;
        if (inst.op == op) count += 1;
        ip += inst.width;
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

// ── Native-lane fusion pass trigger decisions ───────────────────────────────
//
// See lang/fusion_pass.zig's module doc and dev-docs/design/vm-architecture.md
// §6: every fusion is a legality-checked rewrite of adjacent core ops into a
// VM-private fused op, run by `compile()`/`compileWithSession()` (both call
// fusion_pass.fuse() already, so every test in this file already observes
// post-fusion bytecode). These tests assert the *specific* trigger shape for
// each fused op that had zero direct native coverage before this pass, plus
// one legality-boundary case (same_slot).

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

test "fusion: C-style for-loop skips close_upvalue when loop var is not captured" {
    // When no closure in the loop body captures the loop variable, the compiler
    // omits the close_upvalue entirely — no close_upvalue_loop in the output.
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
    try std.testing.expectEqual(@as(usize, 0), countOp(c, .close_upvalue_loop));
}

test "fusion: C-style for-loop emits close_upvalue_loop when loop var is captured" {
    // When a closure in the loop body captures the loop variable, the compiler
    // emits close_upvalue at each back-edge, which fuses to close_upvalue_loop.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func cfor() int {
        \\    result := 0
        \\    for i := 0; i < 5; i++ {
        \\        f := func() int { return i }
        \\        result = result + f()
        \\    }
        \\    return result
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

// ── Named-type range 'clamp' mode ───────────────────────────────────────────
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

// subtypeDecl's parent lookup (getNamedTypeInfo) only searches the named-
// scalar/enum-type bucket. A struct/interface/variant/generic type name is
// a real, declared type — just not an eligible subtype parent — so it must
// not be reported the same way as a name that was never declared at all.
test "compiler: subtyping a struct type reports it as an ineligible parent, not 'unknown type'" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, rt.compileOnly(
        \\type Point struct { x int, y int }
        \\subtype P2 Point
    , "", .filesystem));
    try std.testing.expect(std.mem.indexOf(u8, rt.last_compile_msg_buf[0..rt.last_compile_msg_len], "not a named scalar or enum type") != null);
}

test "compiler: subtyping a genuinely undeclared name still reports 'unknown type'" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, rt.compileOnly(
        \\subtype X Ghost
    , "", .filesystem));
    try std.testing.expect(std.mem.indexOf(u8, rt.last_compile_msg_buf[0..rt.last_compile_msg_len], "unknown type") != null);
}

// subtypeDecl's duplicate-name check used to call hasNamedType alone,
// which only rejects a collision with another named scalar/enum type — a
// struct/interface/variant/generic-type name passed it silently. Found by
// compiling `subtype Point Percent range 0..50` after `type Point struct
// {...}`: it compiled with no error at all, silently corrupting the
// earlier struct declaration, and a later, unrelated `Point{...}` literal
// then panicked with a confusing runtime TypeError far from the actual
// mistake. Every other type-declaration path (namedTypeDecl,
// variantDeclBody) already guards this with hasAnyTypeName; subtypeDecl
// now does too, for both the enum-subtype and scalar-subtype branches.
test "compiler: subtype name colliding with an existing struct type is a compile error, not silent shadowing" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type Percent int range 0..100
        \\type Point struct { x int, y int }
        \\subtype Point Percent range 0..50
    ));
}

test "compiler: enum-subtype name colliding with an existing struct type is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type Mode enum { dev, prod }
        \\type Point struct { x int, y int }
        \\subtype Point Mode { dev }
    ));
}

// ── Limited operator overloading via reserved dunder methods ─────────────────
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
        \\func biggest[T ordered](xs []T) T { return xs[0] }
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
        \\func biggest[T ordered](xs []T) T {
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
// whether `Name[...]` after a type name is a generic-parameter list — must
// accept a constraint's second identifier (e.g. `[T numeric]`) the same way
// the sibling scanner for generic functions (isNamedFuncDecl) does, or a
// constrained generic type is never even recognized as generic in the
// first place. Also exercises checkTypeArgConstraints being wired into
// instantiateGenericType (compiler_decls.zig) — generic functions enforce
// constraints at call time; generic types must enforce the same way at
// instantiation.
test "compiler: constrained generic struct type parameter parses and instantiates" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box[T numeric] struct { val T }
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
        \\type Box[T numeric] struct { val T }
        \\func f() string {
        \\    b := Box[string]{ val: "hi" }
        \\    return b.val
        \\}
    ));
}

// Generic receiver methods: func (s Stack[T]) top() T
// isMethodDecl previously returned false for a bracketed receiver, misidentifying
// the declaration as an anonymous func and producing a nonsensical error.
// methodDecl now parses [T, ...] after the receiver type name and pushes type
// params so the body can use T.  The VM falls back from "@mod:Stack[int]" to
// "@mod:Stack" when looking up the method, so one definition covers all instantiations.
test "compiler: method on generic struct with bracketed receiver (Stack[T])" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Stack[T] struct { items []T }
        \\func (s Stack[T]) top() T { return s.items[0] }
        \\func f() int {
        \\    s := Stack[int]{ items: [10, 20, 30] }
        \\    return s.top()
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 10), result.int);
}

test "compiler: multiple methods on the same generic struct receiver" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Stack[T] struct { items []T }
        \\func (s Stack[T]) top() T { return s.items[0] }
        \\func (s Stack[T]) second() T { return s.items[1] }
        \\func f() int {
        \\    s := Stack[int]{ items: [1, 2, 3] }
        \\    return s.top() + s.second()
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 3), result.int);
}

// structInstanceLitAfterValue (the struct-literal path used for generic
// instantiations, e.g. Box[int]{...}, and type aliases of them) used to
// leave no ExprPrimInfo on its result at all, unlike its sibling
// structInstanceLit (plain Name{...}) — so a dunder operator declared on a
// generic struct was unreachable when the literal was used directly in an
// expression (not read back out of a variable first, whose static type is
// tracked separately from ExprPrimInfo).
test "compiler: dunder operator dispatches on a generic struct literal built directly in an expression" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box[T] struct { v T }
        \\func (a Box[T]) __add__(b Box[T]) Box[T] { return Box[T]{ v: a.v + b.v } }
        \\func direct() int {
        \\    return (Box[int]{ v: 1 } + Box[int]{ v: 2 }).v
        \\}
    );
    const result = try rt.callGlobal("direct", &.{});
    try std.testing.expectEqual(@as(i64, 3), result.int);
}

test "compiler: generic receiver method works for multiple instantiations of same type" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box[T] struct { val T }
        \\func (b Box[T]) get() T { return b.val }
        \\func f() string {
        \\    bi := Box[int]{ val: 42 }
        \\    bs := Box[string]{ val: "hello" }
        \\    if bi.get() == 42 { return bs.get() }
        \\    return "fail"
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("hello", try vms.asStringValue(result));
}

// Concrete-alias case: type IntStack Stack[int]; func (s IntStack) top() int
// Previously failed with UnknownReceiverType because methodDecl never checked
// hasTypeAlias.  Now it resolves the alias target_qname so the method is
// registered under "@mod:Stack[int].top", matching what dispatch produces.
test "compiler: method on type alias of generic instantiation (IntStack = Stack[int])" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Stack[T] struct { items []T }
        \\type IntStack Stack[int]
        \\func (s IntStack) top() int { return s.items[0] }
        \\func f() int {
        \\    s := IntStack{ items: [7, 8, 9] }
        \\    return s.top()
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 7), result.int);
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

// ── GBC (Gengo Bytecode Cache) round-trip ──────────────────────────────────
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
// dev-docs/design/gbc-spec.md for the full remaining scope.

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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
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
    // since every earlier GBC test happened to avoid that exact shape.
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
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

// Enum GBC support (2026-08-19): TYPE_KIND_ENUM (0x03) was reserved by
// gbc-spec.md §8.6 from the start but never implemented — enum_type fell
// through the constant-writing switch's allowlist to UnsupportedConstant,
// same as this test used to assert. Implemented following struct_t/
// variant_t/interface_t's existing TypeEntryInfo/writeTypesSection
// pattern exactly: members (name list), member_ints (optional explicit
// representation values — null means "use ordinal position", same
// convention compiler_decls.zig's own enum parsing already uses), and
// parent_name (enum subtypes — a separate feature from named-type
// subtypes, sharing the same "" == no parent wire convention). parent
// (the resolved *Object) is left null on load and picked up lazily by
// vm_types.zig's resolveEnumParent, identical to a normally compiled
// enum subtype — no special GBC-side cross-reference resolution needed.
// Covers explicit representation values, auto-incremented ordinals,
// .name/.int/from_int(), and an enum subtype (parent resolution).
test "gbc: enum-type constants (explicit ints, auto-increment, subtype) round-trip through write+read and execute correctly" {
    const src =
        \\type Status enum { pending = 0, active = 1, done = 2 }
        \\type Level enum { low, mid, high }
        \\type Days enum { Mon, Tue, Wed, Thu, Fri, Sat, Sun }
        \\subtype Weekend Days { Sat, Sun }
        \\func f() string {
        \\    s := Status.active
        \\    d := Weekend.Sat
        \\    return s.name + ":" + string(s.int) + ":" + string(Level.mid.int) + ":" + d.name + ":" + string(d.int) + ":" + Status.from_int(2).name
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual = try vm.callGlobal(ctx, "f", &.{});

    try std.testing.expectEqualStrings(try vms.asStringValue(expected), try vms.asStringValue(actual));
    try std.testing.expectEqualStrings("active:1:1:Sat:5:done", try vms.asStringValue(actual));
}

// Coverage gap audit (2026-08-19): task_type has no case in gbc_writer.zig's
// constant-writing switch at all (unlike struct_type/named_type/
// variant_type/interface_type/enum_type, which each register into the
// TYPES section — enum_type joined that list later the same day), so it
// falls through to the generic `else => UnsupportedConstant`. At the time
// this was found, the CLI's --emit-gbc/--emit-gbc-module error message
// (main.zig) only mentioned enums, in-body predicates, and captured
// closures as causes, never task types — fixed alongside this test. Once
// enum support landed later, "enums" was removed from that same message
// (no longer a valid cause) without touching the task-type wording added
// here. Confirmed via the actual CLI before writing this down: it fails
// loudly, not silently, but with an incomplete explanation at the time.
// Locks down the loud-failure half; the message text itself doesn't have
// a test (it's not really testable — see known-limitations.md's Tooling
// table, extended alongside this test).
// Task GBC support (2026-08-19): TYPE_KIND_TASK (0x06, no gap reserved for
// it — task/actor shipped after the initial GBC spec pass) implemented
// following enum_t's TYPE_KIND_ENUM pattern, registering the task's
// behavior FuncObj through the same SEC_FUNCTIONS/FuncNamePatchTarget
// machinery a predicate uses (never closure-wrapped, unlike a predicate —
// task bodies can't capture outer locals at all, design doc §3.3).
//
// This test must go through Runtime.runFromGbc specifically, not the
// lower-level manual gbc_reader.read()+vm.run() pattern the other
// round-trip tests above use — that pattern calls vm.run() directly on a
// single vm_state with no task scheduler at all, so it would never have
// caught the real bug this test is actually pinned against: runFromGbc
// used to call vm.runUntilSuspend() once, directly, with no task
// scheduling loop whatsoever — predating task/actor integration entirely
// (runPathWithProvider gained the scheduler loop when tasks shipped;
// runFromGbc never did). A task spawned from a GBC-loaded program would
// enqueue but never get a turn: the top-level receive() below would block
// forever, and since nothing drove the scheduler to notice, the whole run
// would silently return success having run none of the spawned task's
// body — found by running exactly this shape through the actual CLI and
// getting no output at all, not even a crash. Fixed by extracting the
// scheduler loop into Runtime.driveTaskScheduler and having both
// runPathWithProvider and runFromGbc call it.
test "gbc: task-type constants round-trip through Runtime.compileOnly + runFromGbc, including actually running the scheduler" {
    const src =
        \\var got = 0
        \\type Worker task func(start int, reply actor) {
        \\    count := start
        \\    msg := receive()
        \\    count += msg
        \\    reply.send(count)
        \\}
        \\w := Worker(10, self())
        \\w.send(5)
        \\got = receive()
        \\func getGot() int { return got }
    ;

    var rt2 = try setup();
    defer rt2.deinit();
    try rt2.compileOnly(src, "", .filesystem);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    try rt3.runFromGbc(bytes, null);

    const result = try rt3.callGlobal("getGot", &.{});
    try std.testing.expectEqual(@as(i64, 15), result.int);
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
// call. The fix defers the `make_closure` emission to run
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual = try vm.callGlobal(ctx, "f", &.{});

    try std.testing.expectEqual(expected.int, actual.int);
}

// func_t (FT_FUNC_T) used to be rejected outright (UnsupportedFieldType),
// which broke --emit-gbc for every program: compileStdScripts always
// compiles array.gengo's `count(arr []any, pred func(any) bool) int` into
// every chunk regardless of whether the user's script imports std, and its
// `pred` param is func_t. This exercises func_t directly, independent of
// the std-script path (covered separately below).
test "gbc: writer supports a func_t (function-typed) parameter" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func apply(f func(int) int, x int) int { return f(x) }
    );
    const bytes = try gbc_writer.write(rt.chunk_state, std.testing.allocator, .{ .root_source = "" });
    std.testing.allocator.free(bytes);
}

test "gbc: a func_t parameter round-trips through write+read and executes correctly" {
    const src =
        \\func apply(f func(int) int, x int) int { return f(x) }
        \\func double(n int) int { return n * 2 }
        \\func f() int { return apply(double, 21) }
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual = try vm.callGlobal(ctx, "f", &.{});

    try std.testing.expectEqual(expected.int, actual.int);
}

// Generic function GBC support (2026-08-19): writeTypeSpec used to reject
// any FieldTypeAlt tagged .type_param with error.UnsupportedFieldType — a
// generic function's own declared parameter type (e.g. the "T" in
// `func identity[T](x T) T`) is exactly that, and since every function
// declaration emits a constant regardless of whether it's ever called
// (known-limitations.md's old wording: "even if it is never called"),
// --emit-gbc rejected any script merely declaring a generic function.
// Fixed by erasing type_param to FT_ANY on the wire instead — matching
// docs/language.md's own stated runtime semantics ("Type parameters are
// erased at runtime, treated as any"), not inventing new behavior.
// Constraint enforcement (checkTypeArgConstraints) is unaffected: it runs
// at each call site's own compile time against the caller's concrete type
// arguments, never by inspecting a callee's stored param_types.
test "gbc: writer supports a generic function (type_param erased to any)" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func identity[T](x T) T { return x }
    );
    const bytes = try gbc_writer.write(rt.chunk_state, std.testing.allocator, .{ .root_source = "" });
    std.testing.allocator.free(bytes);
}

// Covers: a simple single-type-param function, a two-type-param function
// combined with a func_t (function-typed) argument (map_array — the
// erased-any path composing with an already-supported FieldTypeAlt kind,
// not just in isolation), and a constrained generic (T ordered) called
// both with an explicit type argument and with inference — constraint
// checking happening correctly proves erasure didn't silently disable it.
// Goes through Runtime.compileOnly + runFromGbc (like the std.array.count
// test below), not the bare compile()/manual gbc_reader.read()+vm.run()
// pattern the struct/variant/enum/func_t tests above use: this source
// needs `std := import("std")` for std.core.append, and compile()'s
// Compiler.init(...) has no import resolution at all.
test "gbc: generic functions round-trip through Runtime.compileOnly + runFromGbc and execute correctly" {
    const src =
        \\std := import("std")
        \\func identity[T](x T) T { return x }
        \\func map_array[T, U](xs []T, f func(T) U) []U {
        \\    out := []
        \\    for x in xs {
        \\        out = std.core.append(out, f(x))
        \\    }
        \\    return out
        \\}
        \\func maxOf[T ordered](a T, b T) T {
        \\    if a > b { return a }
        \\    return b
        \\}
        \\func f() string {
        \\    doubled := map_array([1, 2, 3], func(x int) int { return x * 2 })
        \\    sum := 0
        \\    for d in doubled { sum += d }
        \\    return string(identity(42)) + ":" + string(identity("hi")) + ":" + string(sum) + ":" + string(maxOf[int](3, 7)) + ":" + string(maxOf(9, 2))
        \\}
    ;

    var rt1 = try setup();
    defer rt1.deinit();
    try runSrc(&rt1, src);
    const expected = try rt1.callGlobal("f", &.{});

    var rt2 = try setup();
    defer rt2.deinit();
    try rt2.compileOnly(src, "", .filesystem);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    try rt3.runFromGbc(bytes, null);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    const actual = try vm.callGlobal(ctx, "f", &.{});

    try std.testing.expectEqualStrings(try vms.asStringValue(expected), try vms.asStringValue(actual));
    try std.testing.expectEqualStrings("42:hi:12:7:9", try vms.asStringValue(actual));
}

// Exercises the full Runtime.compileOnly -> gbc_writer.write ->
// Runtime.runFromGbc path (not the lower-level compile()/gbc_reader.read()
// helper the other gbc tests use), since compileStdScripts — and the two
// bugs this covers — only run on that path. std.array.count is
// implemented in embedded Gengoscript (array.gengo), always compiled into
// every chunk; before this fix it was unreachable after a GBC round-trip
// for two independent reasons: (1) func_t on its `pred` param rejected
// the whole write, and (2) even with that fixed, chunk.State's
// std_script_const_base/std_script_const_count/std_script_code_end
// bookkeeping (which buildStdModule's script_function lookup needs to
// find `count` in the loaded constant pool) was never serialized, and (3)
// the found FuncObj's own .name came back "" because gbc_writer only
// wrote a name_constant_idx when the bare name happened to already exist
// as an independent string constant — "count" never does, since the only
// string compileStdScripts naturally emits for it is the qualified global
// name "@std_script:array.count", a different string entirely.
test "gbc: std.array.count (embedded-stdlib script_function) round-trips through Runtime.compileOnly + runFromGbc and executes correctly" {
    const src =
        \\std := import("std")
        \\func f() int {
        \\    nums := [1, 2, 3, 4, 5, 6]
        \\    return std.array.count(nums, func(x any) bool {
        \\        return int(x) rem 2 == 0
        \\    })
        \\}
    ;

    var rt2 = try setup();
    defer rt2.deinit();
    try rt2.compileOnly(src, "", .filesystem);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    try rt3.runFromGbc(bytes, null);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    const actual = try vm.callGlobal(ctx, "f", &.{});
    try std.testing.expectEqual(@as(i64, 3), actual.int);
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual = try vm.callGlobal(ctx, "f", &.{});

    try std.testing.expectApproxEqAbs(expected.float, actual.float, 1e-9);
}

test "gbc: a predicate-bearing named type still enforces its predicate after round-tripping" {
    // Note: `f` returns `int`, not `Score` — deliberately independent of a
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const actual_ok = try vm.callGlobal(ctx, "f", &.{.{ .int = 50 }});
    try std.testing.expectEqual(expected_ok.int, actual_ok.int);
    try std.testing.expectError(error.PredicateFailed, vm.callGlobal(ctx, "f", &.{.{ .int = 200 }}));
}

// Coverage gap audit (2026-08-19): known-limitations.md claimed --emit-gbc
// rejects "a predicate declared inside a function body when that predicate
// closes over the function's own locals" — checked empirically via the
// actual CLI before trusting the doc, and it was wrong: --emit-gbc already
// succeeds for this case (issue #211's own test above proves it executes
// correctly natively; this proves it survives a GBC round-trip too). The
// reason: a module-scope predicate's NamedTypeObj.predicate field is
// populated once at compile time (a real captureless closure, eagerly
// written into the TYPES section — see the test above), but an in-function
// declaration re-executes make_closure fresh every call (proven here by
// three calls with three different captured thresholds each producing the
// correct, distinct result) — its NamedTypeObj.predicate field is still
// null at the moment gbc_writer.write() runs, so the writer has nothing to
// reject in the first place; the closure is ordinary SEC_BYTECODE
// (make_closure + friends), already round-tripped like any other
// instruction. Removed the stale limitation row and the two now-inaccurate
// causes ("a predicate declared inside a function body", "a closure with
// real captures stored as a constant") from the CLI's UnsupportedConstant
// message alongside this test — closures with real captures never reach
// gbc_writer's constant-writing switch as a literal object at all, since
// every emitConst(.{.object = <closure>}) site in the compiler is a
// module/type-scope declaration, which cannot capture anything by
// construction (resolveUpvalue finds nothing at scope_depth <= 1).
test "gbc: an in-function predicate with real captures round-trips, re-capturing fresh per call" {
    const src =
        \\func make(threshold int, val int) int {
        \\    type Score int predicate func(x) { return x >= threshold }
        \\    return int(Score(val))
        \\}
    ;

    var rt1 = try setup();
    defer rt1.deinit();
    try runSrc(&rt1, src);
    const e1 = try rt1.callGlobal("make", &.{ .{ .int = 5 }, .{ .int = 5 } });
    const e2 = try rt1.callGlobal("make", &.{ .{ .int = 1 }, .{ .int = 5 } });
    const e3 = try rt1.callGlobal("make", &.{ .{ .int = 100 }, .{ .int = 200 } });
    try std.testing.expectError(error.PredicateFailed, rt1.callGlobal("make", &.{ .{ .int = 5 }, .{ .int = 1 } }));

    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, src);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
    try fusion_pass.fuse(chunk.g_state, rt3.vm_state.allocator);

    const ctx: vm.VMContext = .{ .cs = rt3.chunk_state, .gs = &rt3.globals_state, .hs = &rt3.heap_state, .vs = &rt3.vm_state };
    try vm.run(ctx);
    const a1 = try vm.callGlobal(ctx, "make", &.{ .{ .int = 5 }, .{ .int = 5 } });
    const a2 = try vm.callGlobal(ctx, "make", &.{ .{ .int = 1 }, .{ .int = 5 } });
    const a3 = try vm.callGlobal(ctx, "make", &.{ .{ .int = 100 }, .{ .int = 200 } });
    try std.testing.expectEqual(e1.int, a1.int);
    try std.testing.expectEqual(e2.int, a2.int);
    try std.testing.expectEqual(e3.int, a3.int);
    try std.testing.expectError(error.PredicateFailed, vm.callGlobal(ctx, "make", &.{ .{ .int = 5 }, .{ .int = 1 } }));
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
// call's frame data instead of its own. The fix captures
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, src);
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.InvalidMagic, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, "func f() int { return 1 }"));
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
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.BodyChecksumMismatch, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, "func f() int { return 1 }"));
}

test "gbc: reader rejects a .gbc whose source has changed since it was compiled" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    // Source on disk has since changed (even a single-byte edit) — the
    // artifact's source_graph_hash no longer matches what the caller
    // expects, and must be rejected rather than silently trusted.
    try std.testing.expectError(error.SourceGraphStale, gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, "func f() int { return 2 }"));
}

test "gbc: reader accepts a .gbc when the expected source still matches" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try gbc_reader.read(bytes, chunk.g_state, heap.g_state, rt3.vm_state.allocator, "func f() int { return 1 }");
}

// The two tests directly above/below exercise gbc_reader.read()'s staleness
// check at the low level; Runtime.runFromGbc's own expected_root_source
// parameter (the plumbing the CLI's --verify-source flag uses) was never
// itself covered end-to-end — this closes that gap.
test "gbc: Runtime.runFromGbc's expected_root_source parameter accepts a match and rejects drift" {
    const src = "func f() int { return 7 }";
    var rt2 = try setup();
    defer rt2.deinit();
    try rt2.compileOnly(src, "", .filesystem);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    var rt3 = try setup();
    defer rt3.deinit();
    try rt3.runFromGbc(bytes, src);
    const result = try rt3.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 7), result.int);

    var rt4 = try setup();
    defer rt4.deinit();
    try std.testing.expectError(error.SourceGraphStale, rt4.runFromGbc(bytes, "func f() int { return 8 }"));
}

// The tests below close a real gap found by a coverage audit: gbc_reader.zig
// defines ~20 structural ReadError variants (guarding a crafted/corrupted
// .gbc file's section table, constant tags, and field-type tags) and none
// of them were ever exercised — the only existing corruption tests above
// flip a byte and hit BodyChecksumMismatch before any structural parsing
// even runs. These recompute a valid checksum after each targeted mutation
// so the reader actually reaches the check under test.

// Locates one section's table entry and payload within a valid artifact's
// body, by walking the section table exactly as gbc_reader.
// parseHeaderAndSections does (gbc-spec.md §7): body starts with a u32
// section_count, then section_count entries of id(u32)+flags(u32)+
// offset(u64)+length(u64), 24 bytes each.
const GbcSection = struct { table_pos: usize, payload_offset: usize, payload_len: usize };

fn findGbcSection(bytes: []const u8, section_id: u32) GbcSection {
    const body_start = 8 + gbc_writer.HEADER_SIZE;
    const section_count = std.mem.readInt(u32, bytes[body_start..][0..4], .little);
    var pos = body_start + 4;
    var i: u32 = 0;
    while (i < section_count) : (i += 1) {
        const id = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const offset = std.mem.readInt(u64, bytes[pos + 8 ..][0..8], .little);
        const length = std.mem.readInt(u64, bytes[pos + 16 ..][0..8], .little);
        if (id == section_id) return .{ .table_pos = pos, .payload_offset = body_start + @as(usize, @intCast(offset)), .payload_len = @intCast(length) };
        pos += 24;
    }
    unreachable;
}

// Recomputes the whole-body XxHash64 checksum after an in-place mutation
// and patches it into the header (bytes[184..192]) — every corruption below
// only flips existing bytes, never resizes the buffer, so body_length
// itself is never touched.
fn patchGbcChecksum(bytes: []u8) void {
    const body_start = 8 + gbc_writer.HEADER_SIZE;
    const body_length = std.mem.readInt(u64, bytes[176..184], .little);
    const body = bytes[body_start..][0..@as(usize, @intCast(body_length))];
    const checksum = std.hash.XxHash64.hash(0, body);
    std.mem.writeInt(u64, bytes[184..192], checksum, .little);
}

// Walks a CONSTANTS section's payload (past its leading u32 count),
// mirroring gbc_reader's own constants-loop tag switch exactly, to find the
// first constant of `want_tag` and return the file-absolute offset of its
// trailing operand (FUNC_REF/TYPE_REF: a u32 index right after the tag byte).
fn findConstantOperand(bytes: []const u8, section: GbcSection, want_tag: u8) usize {
    var pos = section.payload_offset + 4; // past u32 const_count
    while (true) {
        const tag = bytes[pos];
        const operand_pos = pos + 1;
        const payload_len: usize = switch (tag) {
            gbc_writer.CONST_NUMBER, gbc_writer.CONST_INT => 8,
            gbc_writer.CONST_STRING => 4 + std.mem.readInt(u32, bytes[operand_pos..][0..4], .little),
            gbc_writer.CONST_NULL => 0,
            gbc_writer.CONST_BOOL => 1,
            gbc_writer.CONST_RUNE => 4,
            gbc_writer.CONST_FUNC_REF, gbc_writer.CONST_TYPE_REF => 4,
            else => unreachable,
        };
        if (tag == want_tag) return operand_pos;
        pos = operand_pos + payload_len;
    }
}

test "gbc: reader rejects a header_size smaller than HEADER_SIZE (HeaderTooSmall)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    std.mem.writeInt(u16, corrupted[8..10], gbc_writer.HEADER_SIZE - 1, .little);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.HeaderTooSmall, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects an unsupported header_version (UnsupportedHeaderVersion)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    std.mem.writeInt(u16, corrupted[10..12], gbc_writer.HEADER_VERSION + 1, .little);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.UnsupportedHeaderVersion, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a mismatched format_major (FormatMajorMismatch)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    std.mem.writeInt(u16, corrupted[12..14], gbc_writer.FORMAT_MAJOR + 1, .little);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.FormatMajorMismatch, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a non-zero reserved header byte (NonZeroReserved)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    corrupted[34] = 1; // first of the 6 reserved bytes at absolute offset 34

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.NonZeroReserved, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a header whose opt_hash doesn't match its own target/backend/flags (OptionsMismatch)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    corrupted[144] ^= 0xFF; // first byte of opt_hash (absolute offset 144)

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.OptionsMismatch, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a header whose vm_fingerprint doesn't match the running VM (VMFingerprintMismatch)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    corrupted[80] ^= 0xFF; // first byte of vm_fp (absolute offset 80)

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.VMFingerprintMismatch, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a header claiming more header bytes than the file has (TruncatedHeader)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    // A huge header_size still satisfies HeaderTooSmall (only checks a lower
    // bound) but pushes header_end well past the actual (short) buffer.
    std.mem.writeInt(u16, corrupted[8..10], 60000, .little);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.TruncatedHeader, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a body_length claim exceeding the file (TruncatedBody)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    std.mem.writeInt(u64, corrupted[176..184], 0xFFFFFFFF, .little);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.TruncatedBody, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a section count above 64 (MalformedSectionTable)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    // Body's first 4 bytes are section_count; the check fires before any
    // entry is read, so the rest of the body can stay untouched.
    std.mem.writeInt(u32, corrupted[8 + gbc_writer.HEADER_SIZE ..][0..4], 65, .little);
    patchGbcChecksum(corrupted);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.MalformedSectionTable, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a section table entry whose length exceeds the body (SectionOutOfBounds)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    const sec = findGbcSection(corrupted, gbc_writer.SEC_TYPES);
    // Table entry layout: id(4) flags(4) offset(8) length(8) — length is the
    // last 8 bytes of the 24-byte entry.
    std.mem.writeInt(u64, corrupted[sec.table_pos + 16 ..][0..8], 0xFFFFFFFF, .little);
    patchGbcChecksum(corrupted);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.SectionOutOfBounds, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects an artifact missing a required section (MissingRequiredSection)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    const sec = findGbcSection(corrupted, gbc_writer.SEC_TYPES);
    // Relabel SEC_TYPES's own table entry to an unused section id so
    // findSection(..., SEC_TYPES) no longer finds it.
    std.mem.writeInt(u32, corrupted[sec.table_pos..][0..4], 0x9999, .little);
    patchGbcChecksum(corrupted);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.MissingRequiredSection, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects an unknown constant tag (BadConstantTag)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    const sec = findGbcSection(corrupted, gbc_writer.SEC_CONSTANTS);
    // The very first constant's tag byte, right after the section's leading
    // u32 count — 0xFF isn't any defined CONST_* tag.
    corrupted[sec.payload_offset + 4] = 0xFF;
    patchGbcChecksum(corrupted);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.BadConstantTag, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a CONST_FUNC_REF index past the functions table (FuncRefOutOfRange)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "func f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "func f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    const sec = findGbcSection(corrupted, gbc_writer.SEC_CONSTANTS);
    const operand = findConstantOperand(corrupted, sec, gbc_writer.CONST_FUNC_REF);
    std.mem.writeInt(u32, corrupted[operand..][0..4], 0xFFFFFFFF, .little);
    patchGbcChecksum(corrupted);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.FuncRefOutOfRange, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

test "gbc: reader rejects a CONST_TYPE_REF index past the types table (TypeRefOutOfRange)" {
    var rt2 = try setup();
    defer rt2.deinit();
    try compile(&rt2, "type Score int\nfunc f() int { return 1 }");
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = "type Score int\nfunc f() int { return 1 }" });
    defer std.testing.allocator.free(bytes);
    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    const sec = findGbcSection(corrupted, gbc_writer.SEC_CONSTANTS);
    const operand = findConstantOperand(corrupted, sec, gbc_writer.CONST_TYPE_REF);
    std.mem.writeInt(u32, corrupted[operand..][0..4], 0xFFFFFFFF, .little);
    patchGbcChecksum(corrupted);

    var rt3 = try setup();
    defer rt3.deinit();
    rt3.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()
    chunk.reset();
    globals.reset();
    heap.reset();
    try std.testing.expectError(error.TypeRefOutOfRange, gbc_reader.read(corrupted, chunk.g_state, heap.g_state, rt3.vm_state.allocator, null));
}

// End-to-end: a real import("./mathlib.gbc") through the full Session/
// runtime pipeline — resolveImportPath resolving the specifier,
// compileModuleFromPath dispatching to linkGbcModule, the splice landing in
// the importer's own in-progress chunk, the dependency's own top-level code
// (emitted by compileBegunModule's emitModuleObject call, same as any
// module) running as part of the combined program and binding its module
// object global, and the importer reading a field off it and calling the
// contained function — gbc-spec.md §14 exercised through the CLI-level
// entrypoint (Runtime.runPathWithSources), not just the lower-level reader
// API Phase 3's test used directly.
test "gbc: import(\"./x.gbc\") links a precompiled module end-to-end" {
    const mathlib_src =
        \\pub func Add(a int, b int) int {
        \\    return a + b
        \\}
        \\pub const Pi = 3
    ;
    var rt_dep = try setup();
    defer rt_dep.deinit();
    try rt_dep.compileModuleOnly(mathlib_src, "mathlib", .filesystem);
    try std.testing.expectEqual(@as(u16, 2), rt_dep.last_export_count);
    var export_buf: [2]gbc_writer.ExportInfo = undefined;
    for (export_buf[0..2], 0..) |*e, i| {
        e.* = .{
            .name = rt_dep.last_export_names[i],
            .type_kind = rt_dep.last_export_type_kinds[i],
            .const_value = rt_dep.last_export_const_values[i],
        };
    }
    const dep_bytes = try gbc_writer.write(rt_dep.chunk_state, std.testing.allocator, .{
        .entry_kind = .module,
        .root_source = mathlib_src,
        .module_id = "mathlib",
        .module_prefix = "@mod:mathlib",
        .exports = &export_buf,
    });
    defer std.testing.allocator.free(dep_bytes);

    const main_src =
        \\m := import("./mathlib.gbc")
        \\func compute() int {
        \\    return m.Add(m.Pi, 4)
        \\}
    ;
    var rt = try setup();
    defer rt.deinit();
    _ = try rt.runPathWithSources(main_src, "main.gengo", &.{.{ .path = "mathlib.gbc", .source = dep_bytes }});
    const result = try rt.callGlobal("compute", &.{});
    try std.testing.expectEqual(@as(i64, 7), result.int);
}

// A corrupted dependency artifact must fail the importer's compile loudly
// — never silently misload or fall back to treating the import as absent
// (gbc-spec.md §14.6's trust model: a LINKED_ARTIFACT dependency has no
// source to recompile from, so a body mismatch is a hard failure, full
// stop). Reuses the exact same mathlib artifact/importer as the end-to-end
// test above, just with one flipped byte in the dependency's body.
test "gbc: import(\"./x.gbc\") fails loudly on a corrupted dependency artifact" {
    const mathlib_src =
        \\pub func Add(a int, b int) int {
        \\    return a + b
        \\}
        \\pub const Pi = 3
    ;
    var rt_dep = try setup();
    defer rt_dep.deinit();
    try rt_dep.compileModuleOnly(mathlib_src, "mathlib", .filesystem);
    var export_buf: [2]gbc_writer.ExportInfo = undefined;
    for (export_buf[0..2], 0..) |*e, i| {
        e.* = .{
            .name = rt_dep.last_export_names[i],
            .type_kind = rt_dep.last_export_type_kinds[i],
            .const_value = rt_dep.last_export_const_values[i],
        };
    }
    const dep_bytes = try gbc_writer.write(rt_dep.chunk_state, std.testing.allocator, .{
        .entry_kind = .module,
        .root_source = mathlib_src,
        .module_id = "mathlib",
        .module_prefix = "@mod:mathlib",
        .exports = &export_buf,
    });
    defer std.testing.allocator.free(dep_bytes);

    const corrupted = try std.testing.allocator.dupe(u8, dep_bytes);
    defer std.testing.allocator.free(corrupted);
    // Flip a byte inside the body (past the 8-byte magic + header).
    corrupted[8 + gbc_writer.HEADER_SIZE + 4] ^= 0xFF;

    const main_src =
        \\m := import("./mathlib.gbc")
        \\func compute() int {
        \\    return m.Add(m.Pi, 4)
        \\}
    ;
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(
        error.BodyChecksumMismatch,
        rt.runPathWithSources(main_src, "main.gengo", &.{.{ .path = "mathlib.gbc", .source = corrupted }}),
    );
}

// gbc-spec.md §14.1's single-level bound, enforced at write time: a module
// artifact being produced for others to link against must not itself link
// a .gbc. Uses a `.table` provider so the dependency's mere presence (not
// its content) is what's under test — even an empty/inert entry is enough
// to prove resolution reaches it and gets rejected before ever trying to
// splice it.
test "gbc: compileModuleRoot rejects a source that links a .gbc dependency" {
    var rt = try setup();
    defer rt.deinit();
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    var session: module_compile.Session = .{};
    try session.initArena();
    defer session.deinitArena();
    session.hs = heap.g_state;
    session.cs = chunk.g_state;
    session.provider = .{ .table = &.{.{ .path = "dep.gbc", .source = "not a real gbc file, never read" }} };
    const src = "dep := import(\"./dep.gbc\")\npub func f() int { return 1 }\n";
    try std.testing.expectError(error.ChainedGbcLinkingNotSupported, session.compileModuleRoot("user", src));
}

// The load-bearing correctness test for gbc-spec.md §14's splice mechanics
// (readIntoSession): compiles a "destination" chunk with real, non-empty
// consts/code first (so the spliced dependency lands at a genuinely nonzero
// base, not the degenerate const_base==0/code_base==0 case), compiles a
// separate module artifact with a function that references a real constant
// (so a broken const-index remap would read the WRONG constant — the
// destination's own — rather than merely crashing), splices it in, and
// calls the spliced function directly (vm.callFunction, not callGlobal:
// the spliced artifact's own top-level def_global never runs here — only
// its constants/functions/code get spliced in, not executed — so nothing
// binds "Greet" as an actual global; finding its FuncObj through cs.consts
// and calling it directly is what actually exercises the ip/const_index
// remap, which is the thing this test exists to catch).
test "gbc: readIntoSession splices a dependency's function into an existing chunk with correct ip/const-index remapping" {
    var rt = try setup();
    defer rt.deinit();

    // Destination chunk: real pre-existing consts (so const_base > 0) and
    // code (so code_base > 0), compiled without fusion so the whole buffer
    // stays in the same core-op form the spliced artifact's own defused
    // bytecode is in.
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    {
        var dest_compiler = try Compiler.init("func existing() string { return \"WRONG\" }", chunk.g_state, heap.g_state, .{});
        defer dest_compiler.deinit();
        try dest_compiler.compile(true);
    }
    const const_base_before = rt.chunk_state.const_count;
    try std.testing.expect(const_base_before > 0);
    const code_base_before = rt.chunk_state.code_len;
    try std.testing.expect(code_base_before > 0);

    // Dependency artifact: a function returning a string constant — a
    // broken const_index remap would, after splicing, read whatever
    // constant now sits at the UNADJUSTED index instead (here, the
    // destination's own "WRONG" string happens to be a plausible collision
    // if remapping were skipped entirely and const_base_before were small).
    const dep_src = "pub func Greet() string { return \"hi\" }";
    var rt_dep = try setup();
    defer rt_dep.deinit();
    try rt_dep.compileModuleOnly(dep_src, "greetlib", .filesystem);
    try std.testing.expectEqual(@as(u16, 1), rt_dep.last_export_count);
    var export_buf: [1]gbc_writer.ExportInfo = undefined;
    export_buf[0] = .{
        .name = rt_dep.last_export_names[0],
        .type_kind = rt_dep.last_export_type_kinds[0],
        .const_value = rt_dep.last_export_const_values[0],
    };
    const dep_bytes = try gbc_writer.write(rt_dep.chunk_state, std.testing.allocator, .{
        .entry_kind = .module,
        .root_source = dep_src,
        .module_id = "greetlib",
        .module_prefix = "@mod:greetlib",
        .exports = &export_buf,
    });
    defer std.testing.allocator.free(dep_bytes);

    // rt_dep.compileModuleOnly (above) repointed the global active
    // chunk/heap state at rt_dep's own fields — restore it to rt's before
    // splicing, or readIntoSession would silently operate on the wrong
    // chunk (found the hard way: without this, const_base_before's own
    // "> 0" assertion still passed, but rt.chunk_state.const_count never
    // grew, because the splice landed in rt_dep.chunk_state instead).
    rt.activate(); // see Runtime.activate()'s doc comment; see also the fixed-bug note above compile()

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed_exports = try gbc_reader.readIntoSession(dep_bytes, rt.chunk_state, &rt.heap_state, arena.allocator(), dep_src);
    try std.testing.expectEqualStrings("greetlib", parsed_exports.module_id);
    try std.testing.expectEqual(@as(usize, 1), parsed_exports.exports.len);
    try std.testing.expectEqualStrings("Greet", parsed_exports.exports[0].name);

    // Constants/code genuinely landed after the destination's own, proving
    // this exercised the nonzero-base path rather than accidentally testing
    // the degenerate const_base==0 case.
    try std.testing.expect(rt.chunk_state.const_count > const_base_before);
    try std.testing.expect(rt.chunk_state.code_len > code_base_before);

    // Find Greet's FuncObj through the now-spliced consts (never a cached
    // pointer from before the splice — re-derived fresh here, same
    // GC-safety discipline the reader itself follows).
    var greet_val: ?Value = null;
    for (rt.chunk_state.consts[0..rt.chunk_state.const_count]) |cv| {
        if (cv != .object or cv.object.* != .function) continue;
        if (std.mem.eql(u8, cv.object.function.name, "Greet")) {
            greet_val = cv;
            break;
        }
    }
    const fn_val = greet_val orelse return error.TestUnexpectedResult;

    const ctx: vm.VMContext = .{ .cs = rt.chunk_state, .gs = &rt.globals_state, .hs = &rt.heap_state, .vs = &rt.vm_state };
    // Every FuncObj starts with max_stack = maxInt(u16) (value.zig) until
    // chunk_verifier's BFS stamps a real per-function bound — which only
    // happens as part of a verify() pass, triggered here by running the
    // destination's own top-level code once (harmless: it's the "existing"
    // script above, ending in its own halt; execution never reaches
    // Greet's spliced code this way, only verify()'s static analysis does).
    // Calling a never-verified function directly would StackOverflow
    // against that maxInt sentinel.
    try vm.run(ctx);
    const result = try vm.callFunction(ctx, fn_val, &.{});
    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("hi", result.string.bytes);
}

test "gbc: writer emits real SEC_EXPORTS data for a linkable module artifact" {
    const src =
        \\pub func Add(a int, b int) int {
        \\    return a + b
        \\}
        \\pub const Pi = 3
        \\func unexported() int { return 0 }
    ;

    var rt = try setup();
    defer rt.deinit();
    try rt.compileModuleOnly(src, "mathlib", .filesystem);
    try std.testing.expectEqual(@as(u16, 2), rt.last_export_count);

    var export_buf: [2]gbc_writer.ExportInfo = undefined;
    for (export_buf[0..2], 0..) |*e, i| {
        e.* = .{
            .name = rt.last_export_names[i],
            .type_kind = rt.last_export_type_kinds[i],
            .const_value = rt.last_export_const_values[i],
        };
    }
    const bytes = try gbc_writer.write(rt.chunk_state, std.testing.allocator, .{
        .entry_kind = .module,
        .root_source = src,
        .module_id = "mathlib",
        .module_prefix = "@mod:mathlib",
        .exports = &export_buf,
    });
    defer std.testing.allocator.free(bytes);

    const sec_bytes = (try gbc_reader.findSectionBytes(bytes, std.testing.allocator, gbc_writer.SEC_EXPORTS, src)) orelse
        return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try gbc_reader.readExportsSection(sec_bytes, arena.allocator());
    try std.testing.expectEqualStrings("mathlib", parsed.module_id);
    try std.testing.expectEqual(@as(usize, 2), parsed.exports.len);

    try std.testing.expectEqualStrings("Add", parsed.exports[0].name);
    try std.testing.expectEqualStrings("@mod:mathlib.Add", parsed.exports[0].qualified_name);
    try std.testing.expectEqual(@intFromEnum(ct.ExportTypeKind.func_or_var), parsed.exports[0].type_kind);
    try std.testing.expect(parsed.exports[0].const_value == .none);

    try std.testing.expectEqualStrings("Pi", parsed.exports[1].name);
    try std.testing.expectEqualStrings("@mod:mathlib.Pi", parsed.exports[1].qualified_name);
    try std.testing.expectEqual(@intFromEnum(ct.ExportTypeKind.func_or_var), parsed.exports[1].type_kind);
    switch (parsed.exports[1].const_value) {
        .number => |n| try std.testing.expectEqual(@as(f64, 3), n),
        else => return error.TestUnexpectedResult,
    }
}

test "gbc: writer emits real SEC_EXPORTS data for a struct-typed export" {
    const src =
        \\pub type Point struct {
        \\    x int,
        \\    y int,
        \\}
    ;

    var rt = try setup();
    defer rt.deinit();
    try rt.compileModuleOnly(src, "geom", .filesystem);
    try std.testing.expectEqual(@as(u16, 1), rt.last_export_count);
    try std.testing.expectEqual(ct.ExportTypeKind.struct_t, rt.last_export_type_kinds[0]);

    var export_buf: [1]gbc_writer.ExportInfo = undefined;
    export_buf[0] = .{
        .name = rt.last_export_names[0],
        .type_kind = rt.last_export_type_kinds[0],
        .const_value = rt.last_export_const_values[0],
    };
    const bytes = try gbc_writer.write(rt.chunk_state, std.testing.allocator, .{
        .entry_kind = .module,
        .root_source = src,
        .module_id = "geom",
        .module_prefix = "@mod:geom",
        .exports = &export_buf,
    });
    defer std.testing.allocator.free(bytes);

    const sec_bytes = (try gbc_reader.findSectionBytes(bytes, std.testing.allocator, gbc_writer.SEC_EXPORTS, src)) orelse
        return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try gbc_reader.readExportsSection(sec_bytes, arena.allocator());
    try std.testing.expectEqualStrings("geom", parsed.module_id);
    try std.testing.expectEqual(@as(usize, 1), parsed.exports.len);
    try std.testing.expectEqualStrings("Point", parsed.exports[0].name);
    try std.testing.expectEqualStrings("@mod:geom.Point", parsed.exports[0].qualified_name);
    try std.testing.expectEqual(@intFromEnum(ct.ExportTypeKind.struct_t), parsed.exports[0].type_kind);
}

test "gbc: --emit-gbc-module rejects a source that itself imports a .gbc" {
    // .gbc-as-import-target resolution landed in a97f6b2 (compileModuleFromPath
    // dispatches any .gbc-suffixed specifier to linkGbcModule, gated by
    // reject_linked_deps for gbc-spec.md §14.1's single-level bound — see
    // "compileModuleRoot rejects a source that links a .gbc dependency"
    // above, which exercises that rejection directly with a .table provider
    // where the fake dependency "exists").
    //
    // This test still expects ImportNotFound, not ChainedGbcLinkingNotSupported,
    // for an unrelated reason: it uses the real .filesystem provider and
    // "./dep.gbc" has no backing fixture file, so resolveImportPath's
    // sourceExists probe fails before compileModuleFromPath ever sees the
    // path and gets a chance to reject the chain.
    const src =
        \\dep := import("./dep.gbc")
        \\pub func f() int {
        \\    return 1
        \\}
    ;
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ImportNotFound, rt.compileModuleOnly(src, "user", .filesystem));
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

// Dial's no-rules default is deny, matching listen
// above. dial scope is granted (bare "net") but zero policy rules are
// configured, so every dial must be refused — net.dial itself is not a
// [value, error] pair like listen, so std.core.is_error is used instead.
test "cap:net dial: default-deny refuses dial with no policy rules" {
    net_state.clearPolicyRules();
    defer net_state.clearPolicyRules();

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"net"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\std := import("std")
        \\net := import("cap:net")
        \\func testDial() bool {
        \\    conn := net.dial("tcp", "127.0.0.1:1")
        \\    return std.core.is_error(conn)
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("testDial", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
}

// An explicit allow rule must still let a dial reach the real network
// attempt — proven by distinguishing "refused by policy" (net_state never
// let the dial through) from a genuine connection-level failure (it did).
// Nothing listens on 127.0.0.1:1 (a privileged, normally-unbound port), so
// an allowed dial fails at the OS/connect level instead.
test "cap:net dial: explicit allow rule lets dial reach the real connect attempt" {
    net_state.clearPolicyRules();
    defer net_state.clearPolicyRules();
    _ = net_state.addPolicyRule(.allow, "*", 0);

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"net"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\std := import("std")
        \\net := import("cap:net")
        \\func testDial() string {
        \\    conn := net.dial("tcp", "127.0.0.1:1")
        \\    if std.core.is_error(conn) { return string(conn) }
        \\    return "ok"
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("testDial", &.{})) {
        .ok => |v| try std.testing.expect(!std.mem.eql(u8, try vms.asStringValue(v), "net.dial: refused by policy")),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
}

// Task/actor coverage gap audit (2026-08-19): dev-docs/design/task-actor-design.md
// documents several safety-boundary behaviors (isSendable's closure rejection,
// §9's "a spawned task's panic kills only that task") that had zero test
// coverage anywhere — neither tests/spec/338_task_actor_basic.gengo nor
// 339_task_actor_complex.gengo exercise a failure path, only the happy path.
// The four tests below were each verified against the actual CLI binary
// before being written down, not just reasoned about from reading vm_task.zig.

// vm_task.zig's isSendable is a closed allowlist that explicitly rejects
// .function/.closure (shared upvalue cells would break task isolation).
// This is a recoverable runtime panic (error.NotSendable via `try`), not a
// catchable std.core.error value — matches the general panic/recover model,
// not the is_error() model cap:net's policy refusals use.
// receive()/self() are legal only lexically inside a task's own body or
// top-level main (compiler_expr.zig:1191) — never inside an ordinary named
// func — so these all keep the spawn/send/receive sequence at top level,
// same as tests/spec/338/339 do, rather than wrapping it in a callable
// function.
test "task: sending a closure across a task boundary raises NotSendable, not a crash" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.NotSendable, runSrc(&rt,
        \\func makeAdder(n int) func(int) int {
        \\    return func(x int) int { return x + n }
        \\}
        \\type Echo task func(reply actor) {
        \\    msg := receive()
        \\    reply.send(msg)
        \\}
        \\e := Echo(self())
        \\f := makeAdder(5)
        \\e.send(f)
        \\result := receive()
    ));
}

// Same check, but at the spawn-argument crossing point (vm.zig:1262's
// checkSendableAndClone loop over spawn args) rather than send()'s.
test "task: a closure as a spawn argument raises NotSendable, not a crash" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.NotSendable, runSrc(&rt,
        \\func makeAdder(n int) func(int) int {
        \\    return func(x int) int { return x + n }
        \\}
        \\type Holder task func(f func(int) int) {
        \\    _ = f(1)
        \\}
        \\_ = Holder(makeAdder(5))
    ));
}

// §9: "a spawned task's unrecovered panic ... kills only that task" —
// runtime.zig's scheduler loop marks the panicking slot .dead and moves on.
// Proven here by having a doomed task panic before it can reply, alongside
// a working one that does reply — main's receive() must resolve to the
// working reply, proving the doomed task's death didn't take anything else
// down with it (not the scheduler, not the other task, not main). The
// result is stashed in a global (rather than returned from a wrapper func,
// which receive() can't be called inside) and read back afterward.
test "task: a spawned task's panic kills only that task, not the scheduler or other tasks" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\var got = 0
        \\type Doomed task func(reply actor) {
        \\    x := 1
        \\    y := 0
        \\    _ = x / y
        \\    reply.send(42)
        \\}
        \\type Fine task func(reply actor) {
        \\    reply.send(7)
        \\}
        \\_ = Doomed(self())
        \\_ = Fine(self())
        \\got = receive()
        \\func getGot() int { return got }
    );
    const result = try rt.callGlobal("getGot", &.{});
    try std.testing.expectEqual(@as(i64, 7), result.int);
}

// The flip side of the above, and the sharpest edge in the whole feature:
// there is no death notification (monitor() was cut from v0 — see
// vm_task.zig's header). If a task's ONLY potential replier panics before
// replying, that task's receive() blocks forever — and since the scheduler
// declares the run .completed as soon as nothing is left in the ready
// queue (runtime.zig ~line 686), the *entire program* silently stops
// running additional top-level code and exits successfully, without error,
// without hanging, and without ever resuming past the blocked receive().
// This is a deliberate consequence of the "no death notification" design,
// not a bug — but it had zero test coverage, so a future change to the
// scheduler could silently flip this to "hang forever" or "propagate an
// error" without any test noticing either way.
//
// A sharper discovery made while writing this test: top-level function
// declarations register as globals via ordinary sequential execution too
// (make_closure + def_global bytecode at the declaration site), not
// compile-time hoisting independent of control flow — a func declared
// textually AFTER the permanently-blocked line never becomes callable at
// all (error.NotDefined), not just unreached. getWasReached is therefore
// declared BEFORE the blocking receive(), so it's already registered by
// the time the scheduler gives up and the run "completes".
test "task: main permanently blocks (silently) if its sole replier panics before replying" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\var reached = false
        \\func wasReached() bool { return reached }
        \\type Doomed task func(reply actor) {
        \\    x := 1
        \\    y := 0
        \\    _ = x / y
        \\    reply.send(42)
        \\}
        \\_ = Doomed(self())
        \\result := receive()
        \\reached = true
    );
    const reached = try rt.callGlobal("wasReached", &.{});
    try std.testing.expectEqual(false, reached.boolean);
}

// Coverage gap audit, pass 3 (2026-08-19): task_state.zig follows the same
// g_default_state + threadlocal g_state + setActive pattern as net_state/
// fs_state/heap (its own header comment says so), and Runtime embeds a
// task_state: tasks_mod.State field by value (runtime.zig:158), not a
// pointer into shared memory — structurally the same isolation shape
// net_state now has. But net_state only has that shape because of a real,
// shipped, historical bug (#216, "net/http state not per-Runtime") found
// AFTER the fact; task/actor was built to match that shape from the start,
// but nothing had ever verified two live Runtimes' task schedulers don't
// bleed into each other the same way engine_runner.zig's testMultiHandle
// already does for plain globals. Two Runtimes alive at once, each
// spawning a task with a different distinctive computation, interleaved
// (rt2 created and fully run between rt1's spawn and rt1's second task
// operation) specifically to catch any g_state redirection left pointing
// at the wrong Runtime's task_state.
test "task: two concurrent Runtimes' task schedulers don't bleed into each other" {
    var rt1 = try setup();
    defer rt1.deinit();
    // Both spawn+receive sequences are top-level (self()/receive() are
    // illegal inside an ordinary func — see the two tests above), so each
    // is its own runSrc call against the same, already-used rt1 — matching
    // how a real embedding host would run one script, then run another
    // against the same live Runtime (the "repl incremental" pattern this
    // codebase already relies on elsewhere).
    try runSrc(&rt1,
        \\var last1 = 0
        \\type Adder1000 task func(n int, reply actor) {
        \\    reply.send(n + 1000)
        \\}
        \\_ = Adder1000(1, self())
        \\last1 = receive()
        \\func getLast1() int { return last1 }
    );
    const first = try rt1.callGlobal("getLast1", &.{});
    try std.testing.expectEqual(@as(i64, 1001), first.int);

    var rt2 = try setup();
    defer rt2.deinit();
    try runSrc(&rt2,
        \\var last2 = 0
        \\type Adder2000 task func(n int, reply actor) {
        \\    reply.send(n + 2000)
        \\}
        \\_ = Adder2000(1, self())
        \\last2 = receive()
        \\func getLast2() int { return last2 }
    );
    const second = try rt2.callGlobal("getLast2", &.{});
    try std.testing.expectEqual(@as(i64, 2001), second.int);

    // Back to rt1: a second, independent top-level spawn+receive, after
    // rt2's scheduler ran to completion in between. If g_state redirection
    // ever left rt1 pointed at rt2's task_state (or vice versa), this
    // either resolves the wrong task type/mailbox or panics instead of
    // returning 1002.
    try runSrc(&rt1,
        \\var last1b = 0
        \\type Adder1000b task func(n int, reply actor) {
        \\    reply.send(n + 1000)
        \\}
        \\_ = Adder1000b(2, self())
        \\last1b = receive()
        \\func getLast1b() int { return last1b }
    );
    const third = try rt1.callGlobal("getLast1b", &.{});
    try std.testing.expectEqual(@as(i64, 1002), third.int);
}

// Coverage gap audit (2026-08-20): task_state.zig's MaxTasks=64 ceiling and
// claimSlot's error.TooManyTasks path had zero coverage — no test ever
// spawned more than a couple of tasks. claimSlot() runs synchronously at
// the spawn call site (vm.zig:1267), before the scheduler ever switches to
// any of them, so main can fill the whole table with cooperative spawns
// that never get a turn to run: slot 0 is permanently reserved and slot 1
// is claimed by main itself (claimMainSlot), leaving exactly
// MaxTasks-2 = 62 slots for spawned tasks.
test "task: spawning past MaxTasks returns TooManyTasks instead of crashing" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.TooManyTasks, runSrc(&rt,
        \\type NoOp task func() {}
        \\for i := 0; i < 62; i++ {
        \\    _ = NoOp()
        \\}
        \\_ = NoOp()
    ));
}

// A task spawning another task, and using self()/receive() itself — not
// just main doing the spawning — was never exercised by any test.
test "task: a task can spawn another task and receive its reply" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Inner task func(reply actor) {
        \\    reply.send(99)
        \\}
        \\type Outer task func(reply actor) {
        \\    _ = Inner(self())
        \\    v := receive()
        \\    reply.send(v + 1)
        \\}
        \\_ = Outer(self())
        \\result := receive()
        \\func getResult() int { return result }
    );
    const result = try rt.callGlobal("getResult", &.{});
    try std.testing.expectEqual(@as(i64, 100), result.int);
}

// More than the "a couple" every existing test used: 5 tasks spawned in
// sequence, each replying with a distinctive value, verifying the ready
// queue's strict FIFO order (§4.2) survives past the two-task case.
test "task: five concurrently-ready tasks reply in spawn (FIFO) order" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Echo task func(n int, reply actor) {
        \\    reply.send(n)
        \\}
        \\_ = Echo(10, self())
        \\_ = Echo(20, self())
        \\_ = Echo(30, self())
        \\_ = Echo(40, self())
        \\_ = Echo(50, self())
        \\a := receive()
        \\b := receive()
        \\c := receive()
        \\d := receive()
        \\e := receive()
        \\func getA() int { return a }
        \\func getB() int { return b }
        \\func getC() int { return c }
        \\func getD() int { return d }
        \\func getE() int { return e }
    );
    try std.testing.expectEqual(@as(i64, 10), (try rt.callGlobal("getA", &.{})).int);
    try std.testing.expectEqual(@as(i64, 20), (try rt.callGlobal("getB", &.{})).int);
    try std.testing.expectEqual(@as(i64, 30), (try rt.callGlobal("getC", &.{})).int);
    try std.testing.expectEqual(@as(i64, 40), (try rt.callGlobal("getD", &.{})).int);
    try std.testing.expectEqual(@as(i64, 50), (try rt.callGlobal("getE", &.{})).int);
}

// Coverage gap audit (2026-08-20): compiler_types.zig's MaxTypes=1024
// ceiling (struct+interface+variant+named combined, per its own comment)
// had zero coverage — DuplicateField turned out to already be thoroughly
// covered by tests/spec/fail/{009,017,216,217,218,219,220,221,222}, but the
// resource-ceiling checks (TooManyTypes here) genuinely weren't. Empty
// interfaces are the cheapest declaration that still counts toward the
// shared counter.
test "compiler: declaring more than MaxTypes named types is rejected (TooManyTypes)" {
    var rt: Runtime = .{};
    defer rt.deinit();
    // Explicit, generous heap/object budget instead of setup()'s ambient
    // preset: -Dpreset=stress (a CI lane, see config_stress.zig) caps
    // max_objects at 512, far below the 1025 type objects this test
    // declares — under that preset the run hit OutOfMemory before ever
    // reaching the TooManyTypes check this test targets. Found by the
    // pre-push hook's -Dpreset=stress lane, which the earlier -Dpreset=1m
    // verification never exercised.
    try rt.initWithConfig(.{ .allow_io = false }, 4 * 1024 * 1024, 4096, vms.MaxStack, vms.MaxFrames, cfg.max_defers, std.testing.allocator);
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i <= ct.MaxTypes) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "type T{d} interface {{}}\n", .{i});
        try src.appendSlice(std.testing.allocator, line);
    }
    try std.testing.expectError(error.TooManyTypes, runSrc(&rt, src.items));
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

// cap_fs.zig's dispatch functions (unlike cap:net/cap:http) return a single
// value, not a (value, err) pair — a failure is an uncaught runtime error,
// not a value-level error. Exercised end-to-end against a real temp
// directory (no fake/mock needed, filesystem I/O is cheap and hermetic).
test "cap:fs read/write/exists/list/delete/mkdir round-trip through a real temp directory" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"fs"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(tmp_path);

    switch (rt.run(
        \\std := import("std")
        \\fs := import("cap:fs")
        \\func doWrite() bool {
        \\    fs.write("root/hello.txt", "hello-content")
        \\    return true
        \\}
        \\func doExists() bool {
        \\    return fs.exists("root/hello.txt")
        \\}
        \\func doRead() string {
        \\    return fs.read("root/hello.txt")
        \\}
        \\func doMkdir() bool {
        \\    fs.mkdir("root/subdir")
        \\    return true
        \\}
        \\func doList() int {
        \\    return std.core.len(fs.list("root"))
        \\}
        \\func doDelete() bool {
        \\    fs.delete("root/hello.txt")
        \\    return true
        \\}
        \\func doExistsAfterDelete() bool {
        \\    return fs.exists("root/hello.txt")
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    // Registered after run(), same reasoning as the cap:http handler tests
    // below: run()/compile can re-pin the process-wide active-runtime
    // pointers, which would wipe out mounts set before that pin lands.
    try rt.setFsMounts(&.{.{ .name = "root", .real = tmp_path }});

    switch (rt.call("doWrite", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doExists", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doRead", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("hello-content", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doMkdir", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doList", &.{})) {
        .ok => |v| try std.testing.expect(v.int >= 1),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doDelete", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doExistsAfterDelete", &.{})) {
        .ok => |v| try std.testing.expect(!v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
}

// Fake host driver for cap:fs tests below: an in-memory virtual filesystem
// backing a `.driver` mount (fs_state.MountKind.driver), exercising
// cap_fs.zig's driver-path branches (the `if (lr.mount.kind == .driver)`
// blocks at the top of each dispatch case) that the real-tmpdir test above
// never reaches, since that one only ever registers a `.real_path` mount.
// Same idea as FakeCapHttpState/fakeCapHttpHandler and FakeCapNetState/
// fake_cap_net_handlers above: deterministic, hermetic stand-ins for a host
// driver so read/exists/write/list/delete/mkdir's full marshaling can be
// exercised without a real filesystem.
const FakeFsDriverState = struct {
    // fs.read
    file_contents: []const u8 = "",
    read_pos: usize = 0,
    chunk_len: usize = 4, // small on purpose: forces cap_fs_read's
    // 4096-byte-buffer read loop to run multiple iterations and accumulate
    // via chunks.appendSlice, instead of finishing in one call.
    open_should_fail: bool = false,

    // fs.write
    write_seen: [256]u8 = undefined,
    write_seen_len: usize = 0,

    // fs.exists
    exists_result: i32 = 1,

    // fs.list: caller-provided NUL-packed names blob, returned verbatim.
    list_names: []const u8 = "",

    // Observed calls/paths: also proves lr.rest (the path with the mount
    // name stripped, e.g. "vfs/foo.txt" -> "foo.txt") is what reaches the
    // driver, not the full mount-qualified script path.
    last_open_path: [64]u8 = undefined,
    last_open_path_len: usize = 0,
    last_open_mode: i32 = -1,
    last_list_path: [64]u8 = undefined,
    last_list_path_len: usize = 0,
    last_unlink_path: [64]u8 = undefined,
    last_unlink_path_len: usize = 0,
    last_mkdir_path: [64]u8 = undefined,
    last_mkdir_path_len: usize = 0,
    unlink_calls: u32 = 0,
    mkdir_calls: u32 = 0,
};

fn fakeFsOpen(userdata: ?*anyopaque, path_ptr: [*]const u8, path_len: i32, mode: i32, out_fd: *i32) callconv(.c) i32 {
    const st: *FakeFsDriverState = @ptrCast(@alignCast(userdata.?));
    if (st.open_should_fail) return -1;
    const n: usize = @intCast(path_len);
    @memcpy(st.last_open_path[0..n], path_ptr[0..n]);
    st.last_open_path_len = n;
    st.last_open_mode = mode;
    if (mode == 0) st.read_pos = 0;
    out_fd.* = 7;
    return 0;
}

fn fakeFsRead(userdata: ?*anyopaque, fd: i32, buf: [*]u8, buf_len: i32) callconv(.c) i32 {
    _ = fd;
    const st: *FakeFsDriverState = @ptrCast(@alignCast(userdata.?));
    const remaining = st.file_contents.len - st.read_pos;
    if (remaining == 0) return 0;
    const n = @min(@min(remaining, st.chunk_len), @as(usize, @intCast(buf_len)));
    @memcpy(buf[0..n], st.file_contents[st.read_pos..][0..n]);
    st.read_pos += n;
    return @intCast(n);
}

fn fakeFsWrite(userdata: ?*anyopaque, fd: i32, data: [*]const u8, len: i32) callconv(.c) i32 {
    _ = fd;
    const st: *FakeFsDriverState = @ptrCast(@alignCast(userdata.?));
    const n: usize = @intCast(len);
    @memcpy(st.write_seen[0..n], data[0..n]);
    st.write_seen_len = n;
    return @intCast(n);
}

fn fakeFsClose(userdata: ?*anyopaque, fd: i32) callconv(.c) void {
    _ = userdata;
    _ = fd;
}

fn fakeFsExists(userdata: ?*anyopaque, path_ptr: [*]const u8, path_len: i32) callconv(.c) i32 {
    _ = path_ptr;
    _ = path_len;
    const st: *FakeFsDriverState = @ptrCast(@alignCast(userdata.?));
    return st.exists_result;
}

fn fakeFsList(userdata: ?*anyopaque, path_ptr: [*]const u8, path_len: i32, out_buf: [*]u8, out_buf_len: i32) callconv(.c) i32 {
    const st: *FakeFsDriverState = @ptrCast(@alignCast(userdata.?));
    const pn: usize = @intCast(path_len);
    @memcpy(st.last_list_path[0..pn], path_ptr[0..pn]);
    st.last_list_path_len = pn;
    const n = st.list_names.len;
    if (n > @as(usize, @intCast(out_buf_len))) return -1;
    @memcpy(out_buf[0..n], st.list_names);
    return @intCast(n);
}

fn fakeFsUnlink(userdata: ?*anyopaque, path_ptr: [*]const u8, path_len: i32) callconv(.c) i32 {
    const st: *FakeFsDriverState = @ptrCast(@alignCast(userdata.?));
    const n: usize = @intCast(path_len);
    @memcpy(st.last_unlink_path[0..n], path_ptr[0..n]);
    st.last_unlink_path_len = n;
    st.unlink_calls += 1;
    return 0;
}

fn fakeFsMkdir(userdata: ?*anyopaque, path_ptr: [*]const u8, path_len: i32) callconv(.c) i32 {
    const st: *FakeFsDriverState = @ptrCast(@alignCast(userdata.?));
    const n: usize = @intCast(path_len);
    @memcpy(st.last_mkdir_path[0..n], path_ptr[0..n]);
    st.last_mkdir_path_len = n;
    st.mkdir_calls += 1;
    return 0;
}

const fake_fs_driver: fs_state_mod.FsDriver = .{
    .open = fakeFsOpen,
    .read = fakeFsRead,
    .write = fakeFsWrite,
    .close = fakeFsClose,
    .exists = fakeFsExists,
    .list = fakeFsList,
    .unlink = fakeFsUnlink,
    .mkdir = fakeFsMkdir,
};

test "cap:fs driver mount: read/exists/write/list/delete/mkdir all go through host callback functions" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"fs"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\std := import("std")
        \\fs := import("cap:fs")
        \\func doRead() string { return fs.read("vfs/foo.txt") }
        \\func doExistsTrue() bool { return fs.exists("vfs/foo.txt") }
        \\func doExistsFalse() bool { return fs.exists("vfs/missing.txt") }
        \\func doWrite() bool { fs.write("vfs/foo.txt", "written-content"); return true }
        \\func doListLen() int {
        \\    names := fs.list("vfs/somedir")
        \\    return std.core.len(names)
        \\}
        \\func doListItem0() string {
        \\    names := fs.list("vfs/somedir")
        \\    return names[0]
        \\}
        \\func doListItem1() string {
        \\    names := fs.list("vfs/somedir")
        \\    return names[1]
        \\}
        \\func doDelete() bool { fs.delete("vfs/foo.txt"); return true }
        \\func doMkdir() bool { fs.mkdir("vfs/newdir"); return true }
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    // Two names ("alpha", "beta") followed by a doubled NUL before "gamma":
    // exercises both the normal multi-name parse and cap_fs.zig's
    // `if (end == pos) break` early-stop-on-empty-name path in the same
    // buffer — "gamma" must NOT show up in the result.
    var state = FakeFsDriverState{
        .file_contents = "Hello, virtual world!",
        .list_names = "alpha\x00beta\x00\x00gamma\x00",
    };
    // Registered after run(), same reasoning as the real-tmpdir/http/net
    // fake-handler tests above: run() re-pins the process-wide active-state
    // pointer, which would wipe out a mount registered before that pin
    // lands. Runtime.setFsMounts (api.zig) only builds .real_path mounts, so
    // a .driver mount goes straight through fs_state onto the inner
    // Runtime's own mount table.
    try fs_state_mod.addDriverMountToState(&rt.inner.fs_mounts, "vfs", fake_fs_driver, @ptrCast(&state));

    switch (rt.call("doRead", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("Hello, virtual world!", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqualStrings("foo.txt", state.last_open_path[0..state.last_open_path_len]);
    try std.testing.expectEqual(@as(i32, 0), state.last_open_mode);

    switch (rt.call("doExistsTrue", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    state.exists_result = 0;
    switch (rt.call("doExistsFalse", &.{})) {
        .ok => |v| try std.testing.expect(!v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }

    switch (rt.call("doWrite", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqualStrings("written-content", state.write_seen[0..state.write_seen_len]);
    try std.testing.expectEqual(@as(i32, 1), state.last_open_mode);

    switch (rt.call("doListLen", &.{})) {
        .ok => |v| try std.testing.expectEqual(@as(i64, 2), v.int),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doListItem0", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("alpha", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doListItem1", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("beta", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqualStrings("somedir", state.last_list_path[0..state.last_list_path_len]);

    switch (rt.call("doDelete", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqual(@as(u32, 1), state.unlink_calls);
    try std.testing.expectEqualStrings("foo.txt", state.last_unlink_path[0..state.last_unlink_path_len]);

    switch (rt.call("doMkdir", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqual(@as(u32, 1), state.mkdir_calls);
    try std.testing.expectEqualStrings("newdir", state.last_mkdir_path[0..state.last_mkdir_path_len]);
}

// A driver mount can leave individual callback fields null (an embedder only
// implementing a read-only view, say), and a host driver callback can report
// failure via a negative return code. cap_fs.zig's driver branches guard
// both: `drv.<fn> orelse return error.CapabilityError` for a missing
// callback, and `if (<fn>(...) < 0) return error.CapabilityError` for a
// negative rc. Both must surface to the script as a CapabilityError runtime
// error, exactly like the .wasi CapabilityNotAvailable branches already
// covered by the real-tmpdir test's platform.
test "cap:fs driver mount: missing callback and negative host rc both surface as CapabilityError" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"fs"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\fs := import("cap:fs")
        \\func doRead() string { return fs.read("noread/foo.txt") }
        \\func doWrite() { fs.write("failopen/foo.txt", "x") }
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    // open/close wired but read left null: cap_fs_read's
    // `drv.read orelse return error.CapabilityError` guard.
    const no_read_driver: fs_state_mod.FsDriver = .{
        .open = fakeFsOpen,
        .close = fakeFsClose,
    };
    var no_read_state = FakeFsDriverState{};
    try fs_state_mod.addDriverMountToState(&rt.inner.fs_mounts, "noread", no_read_driver, @ptrCast(&no_read_state));

    // open() reports failure (negative rc): cap_fs_write's
    // `if (open_fn(...) < 0) return error.CapabilityError` branch.
    var fail_open_state = FakeFsDriverState{ .open_should_fail = true };
    try fs_state_mod.addDriverMountToState(&rt.inner.fs_mounts, "failopen", fake_fs_driver, @ptrCast(&fail_open_state));

    switch (rt.call("doRead", &.{})) {
        .runtime_error => |e| try std.testing.expectEqual(error.CapabilityError, e.kind),
        .ok => return error.ExpectedCapabilityError,
    }
    switch (rt.call("doWrite", &.{})) {
        .runtime_error => |e| try std.testing.expectEqual(error.CapabilityError, e.kind),
        .ok => return error.ExpectedCapabilityError,
    }
}

// cap:http's dispatch() validates the fetch() options map (method/body/
// timeout_ms/headers types, and the opts argument itself) before ever
// calling http_state.httpFetch — so these TypeError branches need no
// network or registered handler at all to exercise.
test "cap:http fetch rejects malformed options before any dispatch to httpFetch" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"http"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\http := import("cap:http")
        \\func badMethod() { r, e := http.fetch("http://x.invalid/", {"method": 123}) }
        \\func badBody() { r, e := http.fetch("http://x.invalid/", {"body": 123}) }
        \\func badTimeout() { r, e := http.fetch("http://x.invalid/", {"timeout_ms": "nope"}) }
        \\func badHeaders() { r, e := http.fetch("http://x.invalid/", {"headers": 123}) }
        \\func badOpts() { r, e := http.fetch("http://x.invalid/", 123) }
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    const names = [_][]const u8{ "badMethod", "badBody", "badTimeout", "badHeaders", "badOpts" };
    for (names) |name| {
        switch (rt.call(name, &.{})) {
            .runtime_error => |e| try std.testing.expectEqual(error.TypeError, e.kind),
            .ok => return error.ExpectedTypeError,
        }
    }
}

// Fake host handler for cap:http tests below: fills in a canned response
// and records what it was called with, so http.get/post/fetch's full
// success path (options marshaling in cap_http.zig's dispatch, request/
// response marshaling in http_state.zig's httpFetchHost, struct-building
// in buildResponseStruct) runs for real with no network involved.
const FakeCapHttpState = struct {
    seen_method: [16]u8 = undefined,
    seen_method_len: usize = 0,
    seen_body_len: c_int = -1,
    seen_header_count: c_int = -1,
    resp_status: c_int = 200,
    resp_body: []const u8 = "",
    resp_key: [:0]const u8 = "x-resp",
    resp_value: [:0]const u8 = "resp-value",
    resp_keys_arr: [1][*:0]const u8 = undefined,
    resp_vals_arr: [1][*:0]const u8 = undefined,
};

fn fakeCapHttpHandler(req: *const http_state.GengoHttpRequest, out: *http_state.GengoHttpResponse, userdata: ?*anyopaque) callconv(.c) c_int {
    const st: *FakeCapHttpState = @ptrCast(@alignCast(userdata.?));
    const method = std.mem.span(req.method);
    @memcpy(st.seen_method[0..method.len], method);
    st.seen_method_len = method.len;
    st.seen_body_len = req.body_len;
    st.seen_header_count = req.headers.count;

    out.status = st.resp_status;
    out.body = st.resp_body.ptr;
    out.body_len = @intCast(st.resp_body.len);
    st.resp_keys_arr[0] = st.resp_key.ptr;
    st.resp_vals_arr[0] = st.resp_value.ptr;
    out.headers = .{ .keys = &st.resp_keys_arr, .values = &st.resp_vals_arr, .count = 1 };
    return 0;
}

test "cap:http get/post/fetch build a full Response struct through a fake host handler" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"http"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    var state = FakeCapHttpState{ .resp_status = 201, .resp_body = "hello-body" };

    switch (rt.run(
        \\http := import("cap:http")
        \\func doGet() int {
        \\    r, err := http.get("http://x.invalid/")
        \\    if err != null { return -1 }
        \\    return r.status
        \\}
        \\func doGetBody() string {
        \\    r, err := http.get("http://x.invalid/")
        \\    if err != null { return "ERR" }
        \\    return r.body
        \\}
        \\func doGetOk() bool {
        \\    r, err := http.get("http://x.invalid/")
        \\    if err != null { return false }
        \\    return r.ok
        \\}
        \\func doPost() int {
        \\    r, err := http.post("http://x.invalid/", "payload")
        \\    if err != null { return -1 }
        \\    return r.status
        \\}
        \\func doFetchHeader() string {
        \\    r, err := http.fetch("http://x.invalid/", {"method": "PUT", "headers": {"X-Foo": "bar"}})
        \\    if err != null { return "ERR" }
        \\    return r.headers["x-resp"]
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    // Registered after run() (which activates rt's own state), not before:
    // run()/compile can re-pin the process-wide active-runtime pointers,
    // which would otherwise wipe out a handler registered on a stale
    // pre-activation pointer (same class of pitfall as this file's setup()
    // doc comment describes for Runtime returned by value).
    http_state.setHttpHandler(fakeCapHttpHandler, @ptrCast(&state));
    defer http_state.resetHandler();

    switch (rt.call("doGet", &.{})) {
        .ok => |v| try std.testing.expectEqual(@as(i64, 201), v.int),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqualStrings("GET", state.seen_method[0..state.seen_method_len]);

    switch (rt.call("doGetBody", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("hello-body", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }

    switch (rt.call("doGetOk", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }

    switch (rt.call("doPost", &.{})) {
        .ok => |v| try std.testing.expectEqual(@as(i64, 201), v.int),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqualStrings("POST", state.seen_method[0..state.seen_method_len]);
    try std.testing.expectEqual(@as(c_int, 7), state.seen_body_len); // "payload".len == 7

    switch (rt.call("doFetchHeader", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("resp-value", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqualStrings("PUT", state.seen_method[0..state.seen_method_len]);
    try std.testing.expectEqual(@as(c_int, 1), state.seen_header_count);
}

// Fake host handler for cap:net tests below, same idea as FakeCapHttpState/
// fakeCapHttpHandler above: a deterministic, hermetic stand-in for real
// sockets so cap_net.zig's dispatch/marshaling branches (arg extraction,
// Conn/Listener struct building, [ok, err] pair construction, the
// DeadlineExceeded => "timeout" mapping) can be exercised without a real
// network. Read/write loop back through a 2-slot buffer indexed by the host
// handle (dial's fake handle is always 1, accept's is always 2), mirroring
// net_state.zig's own FakeNetHandlerState/fakeDial/fakeRead/etc. test-block
// fixtures (those are private to that file, so this is a fresh copy here).
const FakeCapNetState = struct {
    buf: [2][256]u8 = undefined,
    buf_len: [2]usize = .{ 0, 0 },
    buf_pos: [2]usize = .{ 0, 0 },
    dial_handle: i32 = 1,
    listener_handle: i32 = 50,
    accept_handle: i32 = 2,
    accept_should_block: bool = false,
    close_calls: u32 = 0,
    listener_close_calls: u32 = 0,
    last_deadline_ms: i64 = -1,
    last_read_deadline_ms: i64 = -1,
    last_write_deadline_ms: i64 = -1,
    last_accept_deadline_ms: i64 = -1,
};

fn fakeCapNetDial(network: [*]const u8, network_len: usize, address: [*]const u8, address_len: usize, out_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = network;
    _ = network_len;
    _ = address;
    _ = address_len;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    out_handle.* = st.dial_handle;
    return 0;
}

fn fakeCapNetRead(handle: i32, buf: [*]u8, max_bytes: i32, userdata: ?*anyopaque) callconv(.c) i32 {
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    const idx: usize = @intCast(handle - 1);
    const avail = st.buf_len[idx] - st.buf_pos[idx];
    const n = @min(avail, @as(usize, @intCast(max_bytes)));
    @memcpy(buf[0..n], st.buf[idx][st.buf_pos[idx]..][0..n]);
    st.buf_pos[idx] += n;
    return @intCast(n);
}

fn fakeCapNetWrite(handle: i32, data: [*]const u8, len: i32, userdata: ?*anyopaque) callconv(.c) i32 {
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    const idx: usize = @intCast(handle - 1);
    const n: usize = @intCast(len);
    @memcpy(st.buf[idx][st.buf_len[idx]..][0..n], data[0..n]);
    st.buf_len[idx] += n;
    return @intCast(n);
}

fn fakeCapNetClose(handle: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    st.close_calls += 1;
}

fn fakeCapNetLocalAddr(handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    _ = userdata;
    const s = "10.0.0.1:1234";
    const n = @min(s.len, @as(usize, @intCast(buf_len)) - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

fn fakeCapNetRemoteAddr(handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    _ = userdata;
    const s = "203.0.113.9:443";
    const n = @min(s.len, @as(usize, @intCast(buf_len)) - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

fn fakeCapNetSetDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    st.last_deadline_ms = ms;
}

fn fakeCapNetSetReadDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    st.last_read_deadline_ms = ms;
}

fn fakeCapNetSetWriteDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    st.last_write_deadline_ms = ms;
}

fn fakeCapNetListen(network: [*]const u8, network_len: usize, address: [*]const u8, address_len: usize, out_listener_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = network;
    _ = network_len;
    _ = address;
    _ = address_len;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    out_listener_handle.* = st.listener_handle;
    return 0;
}

fn fakeCapNetAccept(listener_handle: i32, out_conn_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = listener_handle;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    if (st.accept_should_block) return 0;
    out_conn_handle.* = st.accept_handle;
    return 1;
}

fn fakeCapNetListenerClose(listener_handle: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = listener_handle;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    st.listener_close_calls += 1;
}

fn fakeCapNetListenerLocalAddr(listener_handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = listener_handle;
    _ = userdata;
    const s = "0.0.0.0:9000";
    const n = @min(s.len, @as(usize, @intCast(buf_len)) - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

fn fakeCapNetSetAcceptDeadline(listener_handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    _ = listener_handle;
    const st: *FakeCapNetState = @ptrCast(@alignCast(userdata.?));
    st.last_accept_deadline_ms = ms;
}

const fake_cap_net_handlers: net_state.GengoNetHandlers = .{
    .dial = fakeCapNetDial,
    .read = fakeCapNetRead,
    .write = fakeCapNetWrite,
    .close = fakeCapNetClose,
    .local_addr = fakeCapNetLocalAddr,
    .remote_addr = fakeCapNetRemoteAddr,
    .set_deadline = fakeCapNetSetDeadline,
    .set_read_deadline = fakeCapNetSetReadDeadline,
    .set_write_deadline = fakeCapNetSetWriteDeadline,
    .listen = fakeCapNetListen,
    .accept = fakeCapNetAccept,
    .listener_close = fakeCapNetListenerClose,
    .listener_local_addr = fakeCapNetListenerLocalAddr,
    .set_accept_deadline = fakeCapNetSetAcceptDeadline,
};

// Covers dial/write/read/close, local_addr/remote_addr, set_deadline/
// set_read_deadline/set_write_deadline, listen/accept/write/read/
// listener_close, and dial_tls's host-callback-unsupported branch — all
// through the fake handler set above, so no real socket is ever opened.
// dial_tls: with handlers registered, net_state.netDialTls refuses before
// ever attempting a handshake ("TLS is not supported with host net
// callbacks"), which is itself a useful deterministic branch to exercise.
test "cap:net dial/listen/accept/read/write/close and address/deadline ops through a fake host handler" {
    net_state.clearPolicyRules();
    _ = net_state.addPolicyRule(.allow, "*", 0);
    defer net_state.clearPolicyRules();
    net_state.clearListenPolicyRules();
    _ = net_state.addListenPolicyRule(.allow, "*", 0);
    defer net_state.clearListenPolicyRules();

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{ "net", "net.listen" },
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\net := import("cap:net")
        \\func doDial() string {
        \\    conn := net.dial("tcp", "example.com:443")
        \\    n := conn.write("hello")
        \\    data := conn.read(5)
        \\    conn.close()
        \\    return data + ":" + string(n)
        \\}
        \\func doAddrs() string {
        \\    conn := net.dial("tcp", "example.com:443")
        \\    la := conn.local_addr()
        \\    ra := conn.remote_addr()
        \\    conn.close()
        \\    return la + "|" + ra
        \\}
        \\func doDeadlines() bool {
        \\    conn := net.dial("tcp", "example.com:443")
        \\    conn.set_deadline(1000)
        \\    conn.set_read_deadline(2000)
        \\    conn.set_write_deadline(3000)
        \\    conn.close()
        \\    return true
        \\}
        \\func doDialTls() string {
        \\    conn := net.dial_tls("tcp", "example.com:443")
        \\    return string(conn)
        \\}
        \\func doListenAccept() string {
        \\    l, err := net.listen("tcp", "0.0.0.0:9000")
        \\    if err != null { return "listen-err" }
        \\    l.set_accept_deadline(4000)
        \\    conn, aerr := l.accept()
        \\    if aerr != null { return "accept-err" }
        \\    conn.write("world")
        \\    data := conn.read(5)
        \\    conn.close()
        \\    l.close()
        \\    return data
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    // Registered after run(), not before — same re-pinning hazard documented
    // on the cap:http fake handler test above.
    var state = FakeCapNetState{};
    net_state.setNetHandlers(fake_cap_net_handlers, @ptrCast(&state));
    defer net_state.resetHandlers();

    switch (rt.call("doDial", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("hello:5", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqual(@as(u32, 1), state.close_calls);

    switch (rt.call("doAddrs", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("10.0.0.1:1234|203.0.113.9:443", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }

    switch (rt.call("doDeadlines", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqual(@as(i64, 1000), state.last_deadline_ms);
    try std.testing.expectEqual(@as(i64, 2000), state.last_read_deadline_ms);
    try std.testing.expectEqual(@as(i64, 3000), state.last_write_deadline_ms);

    switch (rt.call("doDialTls", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("dial_tls: TLS is not supported with host net callbacks", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }

    switch (rt.call("doListenAccept", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("world", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqual(@as(u32, 1), state.listener_close_calls);
}

// Scenario 3: accept's would-block result (host handler returns 0, "no
// connection yet") must surface as a catchable [null, err] pair rather than
// blocking or crashing — net_state.netListenerAccept maps rc==0 to
// error.DeadlineExceeded, which pushErrPairForNetError renders as "timeout".
// Kept as its own test (separate fake state) so its accept_should_block=true
// fixture can't interfere with the happy-path accept above.
test "cap:net listener.accept surfaces a 'timeout' error when the host handler reports would-block" {
    net_state.clearListenPolicyRules();
    _ = net_state.addListenPolicyRule(.allow, "*", 0);
    defer net_state.clearListenPolicyRules();

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"net.listen"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\net := import("cap:net")
        \\func doAccept() string {
        \\    l, err := net.listen("tcp", "0.0.0.0:9000")
        \\    if err != null { return "listen-err" }
        \\    conn, aerr := l.accept()
        \\    if aerr != null { return string(aerr) }
        \\    return "unexpected-ok"
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    var state = FakeCapNetState{ .accept_should_block = true };
    net_state.setNetHandlers(fake_cap_net_handlers, @ptrCast(&state));
    defer net_state.resetHandlers();

    switch (rt.call("doAccept", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("timeout", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
}

// Scenario 4: dialing without the dial scope granted must raise a catchable
// script-visible error naming the missing --cap flag, not a crash — the
// scope-check short-circuit at the top of cap_net.zig's dialImpl, which
// fires before net_state (and thus any handler/policy setup) is even
// consulted. "net.listen" alone satisfies the bare "net" import gate
// (module_compile.zig's isCapabilityEnabled treats any scoped grant as
// satisfying its own module's bare-name gate) while granting listen but not
// dial scope, so import("cap:net") still succeeds here.
test "cap:net dial: dialing without the dial scope granted raises a catchable scope error" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"net.listen"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\net := import("cap:net")
        \\func doDial() string {
        \\    conn := net.dial("tcp", "example.com:443")
        \\    return string(conn)
        \\}
        \\func doDialTls() string {
        \\    conn := net.dial_tls("tcp", "example.com:443")
        \\    return string(conn)
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    switch (rt.call("doDial", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("net.dial: dial scope not granted (--cap net=dial)", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doDialTls", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("net.dial_tls: dial scope not granted (--cap net=dial)", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
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

// std.math's trig/log/exp/root family: each computes a correct value in its
// normal domain, and (where math.zig's dispatch adds an explicit guard, or
// the result comes back non-finite) raises RangeError instead of returning
// NaN/Inf silently.
test "compiler: std.math trig/log/exp/root functions compute correct values and raise RangeError at their domain boundaries" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func acosOk() float { return std.math.acos(0.5) }
        \\func acosBoundary() float { return std.math.acos(1.0) }
        \\func acosOob() float { return std.math.acos(2.0) }
        \\func asinOk() float { return std.math.asin(0.5) }
        \\func asinOob() float { return std.math.asin(-2.0) }
        \\func atanOk() float { return std.math.atan(1.0) }
        \\func cosOk() float { return std.math.cos(0.0) }
        \\func sinOk() float { return std.math.sin(0.0) }
        \\func tanOk() float { return std.math.tan(0.0) }
        \\func cbrtOk() float { return std.math.cbrt(27.0) }
        \\func ceilOk() float { return std.math.ceil(1.2) }
        \\func floorOk() float { return std.math.floor(1.8) }
        \\func roundOk() float { return std.math.round(1.5) }
        \\func truncOk() float { return std.math.trunc(1.9) }
        \\func coshOk() float { return std.math.cosh(0.0) }
        \\func sinhOk() float { return std.math.sinh(0.0) }
        \\func tanhOk() float { return std.math.tanh(0.0) }
        \\func expOk() float { return std.math.exp(0.0) }
        \\func exp2Ok() float { return std.math.exp2(3.0) }
        \\func logOk() float { return std.math.log(1.0) }
        \\func logZero() float { return std.math.log(0.0) }
        \\func logNeg() float { return std.math.log(-1.0) }
        \\func log10Ok() float { return std.math.log10(100.0) }
        \\func log10Zero() float { return std.math.log10(0.0) }
        \\func log2Ok() float { return std.math.log2(8.0) }
        \\func log2Neg() float { return std.math.log2(-1.0) }
        \\func sqrtOk() float { return std.math.sqrt(4.0) }
        \\func sqrtNeg() float { return std.math.sqrt(-1.0) }
        \\func powOk() float { return std.math.pow(2.0, 10.0) }
        \\func powNonFinite() float { return std.math.pow(0.0, -1.0) }
    );

    const tol = 1e-9;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0471975511965979), (try rt.callGlobal("acosOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("acosBoundary", &.{})).float, tol);
    try std.testing.expectError(error.RangeError, rt.callGlobal("acosOob", &.{}));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5235987755982989), (try rt.callGlobal("asinOk", &.{})).float, tol);
    try std.testing.expectError(error.RangeError, rt.callGlobal("asinOob", &.{}));
    try std.testing.expectApproxEqAbs(@as(f64, 0.7853981633974483), (try rt.callGlobal("atanOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), (try rt.callGlobal("cosOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("sinOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("tanOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), (try rt.callGlobal("cbrtOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), (try rt.callGlobal("ceilOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), (try rt.callGlobal("floorOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), (try rt.callGlobal("roundOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), (try rt.callGlobal("truncOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), (try rt.callGlobal("coshOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("sinhOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("tanhOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), (try rt.callGlobal("expOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), (try rt.callGlobal("exp2Ok", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("logOk", &.{})).float, tol);
    try std.testing.expectError(error.RangeError, rt.callGlobal("logZero", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("logNeg", &.{}));
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), (try rt.callGlobal("log10Ok", &.{})).float, tol);
    try std.testing.expectError(error.RangeError, rt.callGlobal("log10Zero", &.{}));
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), (try rt.callGlobal("log2Ok", &.{})).float, tol);
    try std.testing.expectError(error.RangeError, rt.callGlobal("log2Neg", &.{}));
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), (try rt.callGlobal("sqrtOk", &.{})).float, tol);
    try std.testing.expectError(error.RangeError, rt.callGlobal("sqrtNeg", &.{}));
    try std.testing.expectApproxEqAbs(@as(f64, 1024.0), (try rt.callGlobal("powOk", &.{})).float, tol);
    try std.testing.expectError(error.RangeError, rt.callGlobal("powNonFinite", &.{}));
}

// std.math's remaining dispatch branches: clamp, hypot, atan2, is_nan/is_inf,
// sign, nan, and mod (including its DivisionByZero guard).
test "compiler: std.math clamp/hypot/atan2/is_nan/is_inf/sign/nan/mod cover their normal and edge-case behavior" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func clampMid() float { return std.math.clamp(5.0, 0.0, 10.0) }
        \\func clampLow() float { return std.math.clamp(-5.0, 0.0, 10.0) }
        \\func clampHigh() float { return std.math.clamp(15.0, 0.0, 10.0) }
        \\func hypotOk() float { return std.math.hypot(3.0, 4.0) }
        \\func atan2Ok() float { return std.math.atan2(1.0, 1.0) }
        \\func isNanTrue() bool { return std.math.is_nan(std.math.nan()) }
        \\func isNanFalse() bool { return std.math.is_nan(1.0) }
        \\func isInfPos() bool { return std.math.is_inf(std.math.inf, 0) }
        \\func isInfNeg() bool { return std.math.is_inf(-std.math.inf, 0) }
        \\func isInfFalse() bool { return std.math.is_inf(1.0, 0) }
        \\func isInfSignPos() bool { return std.math.is_inf(std.math.inf, 1) }
        \\func isInfSignPosMismatch() bool { return std.math.is_inf(-std.math.inf, 1) }
        \\func isInfSignNeg() bool { return std.math.is_inf(-std.math.inf, -1) }
        \\func signPos() float { return std.math.sign(5.5) }
        \\func signNeg() float { return std.math.sign(-5.5) }
        \\func signZero() float { return std.math.sign(0.0) }
        \\func modOk() float { return std.math.mod(7.5, 2.0) }
        \\func modByZero() float { return std.math.mod(1.0, 0.0) }
    );

    const tol = 1e-9;
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), (try rt.callGlobal("clampMid", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("clampLow", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), (try rt.callGlobal("clampHigh", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), (try rt.callGlobal("hypotOk", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7853981633974483), (try rt.callGlobal("atan2Ok", &.{})).float, tol);
    try std.testing.expect((try rt.callGlobal("isNanTrue", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isNanFalse", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isInfPos", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isInfNeg", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isInfFalse", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isInfSignPos", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isInfSignPosMismatch", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isInfSignNeg", &.{})).boolean);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), (try rt.callGlobal("signPos", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), (try rt.callGlobal("signNeg", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("signZero", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), (try rt.callGlobal("modOk", &.{})).float, tol);
    try std.testing.expectError(error.DivisionByZero, rt.callGlobal("modByZero", &.{}));
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

// A copy-paste-divergence audit found .int_div's OTHER path -- reached when
// either operand is a named-type-wrapped int, via numericBinaryOp/
// pushNumericResultWithCarrier rather than the plain int/int fast path
// above -- had silently reintroduced the exact bug the fast path was
// already fixed for: it returned minInt(i64) unmodified instead of raising
// RangeError.
test "compiler: int_div's named-type carrier path also raises RangeError for i64::MIN div -1" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Big int
        \\func g() int { return int(Big(-9223372036854775808) div Big(-1)) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("g", &.{}));
}

// The same copy-paste-divergence audit found .mod's plain int/int path
// (unlike its two siblings .int_div and .rem, just above) never checked
// for this case at all -- @mod(minInt(i64), -1) traps/UB's on the same 2^63
// overflow, since floored and truncating division coincide when dividing
// by exactly -1. x mod 1 is always mathematically 0.
test "compiler: mod does not trap/overflow for i64::MIN mod -1" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func g(a int, b int) int { return a mod b }
    );
    const result = try rt.callGlobal("g", &.{ .{ .int = std.math.minInt(i64) }, .{ .int = -1 } });
    try std.testing.expectEqual(@as(i64, 0), result.int);
}

// computeAddResult (the .add opcode's non-int fallback, shared by every
// fused add opcode) has an explicit bigint check; its sibling pushSubResult
// (the same role for .sub) didn't — found via `bigint(x) - 5` panicking with
// a confusing TypeError while `bigint(x) + 5` worked. The plain, unfused
// `.sub` opcode handler happens to pre-check bigint itself before ever
// calling pushSubResult, masking the gap there entirely — this only broke
// through the FUSED subtraction opcodes (const_sub, get_local_const_sub,
// get_local_const_sub_call[_tail], call_global_local_sub_const[_tail],
// get_global_const_sub), all of which call pushSubResult directly with no
// such pre-check. `local - const` (as opposed to a `func g(a, b)` runtime
// call, which never fuses this way) specifically exercises
// get_local_const_sub — confirmed via --disasm before writing this test.
test "compiler: bigint - const survives fusion (get_local_const_sub)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() string {
        \\    a := bigint("1000000000000000000000")
        \\    return string(a - 3)
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("999999999999999999997", try vms.asStringValue(result));
}

// std.json.stringify used to serialize any bigint as `null` (falling through
// the object-tag switch's generic else branch), silently discarding the
// value entirely. std.conv.to_int/to_float rejected bigint with TypeError
// even though the direct-dispatched `int(...)`/`float(...)` builtins already
// supported it — an inconsistency between two paths meant to be equivalent.
// A capability-module audit found argon2id validated only t/m/p's LOWER
// bounds (unlike bcryptHash's cost, which is bounded both ways) before
// @intCast-ing them into std.crypto.pwhash.argon2.Params' u32/u32/u24
// fields -- an out-of-range value (e.g. m between u32::max and i64::max)
// panicked that cast immediately, a crash trivially reachable from Gengo
// source with no wire format or policy misconfiguration needed.
test "compiler: std.crypto.argon2id rejects an out-of-range m instead of panicking the @intCast" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func g() string { return std.crypto.argon2id("password", "somesalt1", 1, 999999999999, 1, 32) }
    );
    try std.testing.expectError(error.ValueError, rt.callGlobal("g", &.{}));
}

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

// ── std.fmt.format printf-style engine coverage (src/lang/native/io.zig) ──
// std.fmt.format/std.fmt.stringify are NOT gated by allow_io (unlike
// print/println/printf), so the whole format engine (parseSpec/fmtInt/
// fmtFloat/fmtQuoted/fmtArg/fmtProcess/doSprintf) is reachable from plain
// compiler_test.zig with no I/O capture setup. Expected outputs below were
// derived by tracing io.zig's hand-rolled formatting functions directly
// (a standalone `zig run` of copies of fmtF64Sci/fmtF64General/fmtF64Fixed),
// not assumed from Go/C printf convention -- this is a from-scratch
// reimplementation with its own rounding/cutover/escaping quirks.

test "compiler: std.fmt.format integer verbs %d/%x/%X/%o/%b with sign and alt-form flags" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func decPos() string { return std.fmt.format("%d", 42) }
        \\func decNeg() string { return std.fmt.format("%d", -42) }
        \\func hexLower() string { return std.fmt.format("%x", 255) }
        \\func hexUpper() string { return std.fmt.format("%X", 255) }
        \\func hexNeg() string { return std.fmt.format("%x", -255) }
        \\func oct() string { return std.fmt.format("%o", 8) }
        \\func bin() string { return std.fmt.format("%b", 5) }
        \\func altHex() string { return std.fmt.format("%#x", 255) }
        \\func altHexUpper() string { return std.fmt.format("%#X", 255) }
        \\func altOct() string { return std.fmt.format("%#o", 8) }
        \\func altBin() string { return std.fmt.format("%#b", 5) }
        \\func altZero() string { return std.fmt.format("%#x", 0) }
        \\func plusSign() string { return std.fmt.format("%+d", 42) }
        \\func spaceSign() string { return std.fmt.format("% d", 42) }
        \\func plusSignOnNeg() string { return std.fmt.format("%+d", -42) }
        \\func minInt(n int) string { return std.fmt.format("%d", n) }
    );
    try std.testing.expectEqualStrings("42", try vms.asStringValue(try rt.callGlobal("decPos", &.{})));
    try std.testing.expectEqualStrings("-42", try vms.asStringValue(try rt.callGlobal("decNeg", &.{})));
    try std.testing.expectEqualStrings("ff", try vms.asStringValue(try rt.callGlobal("hexLower", &.{})));
    try std.testing.expectEqualStrings("FF", try vms.asStringValue(try rt.callGlobal("hexUpper", &.{})));
    try std.testing.expectEqualStrings("-ff", try vms.asStringValue(try rt.callGlobal("hexNeg", &.{})));
    try std.testing.expectEqualStrings("10", try vms.asStringValue(try rt.callGlobal("oct", &.{})));
    try std.testing.expectEqualStrings("101", try vms.asStringValue(try rt.callGlobal("bin", &.{})));
    try std.testing.expectEqualStrings("0xff", try vms.asStringValue(try rt.callGlobal("altHex", &.{})));
    try std.testing.expectEqualStrings("0XFF", try vms.asStringValue(try rt.callGlobal("altHexUpper", &.{})));
    try std.testing.expectEqualStrings("010", try vms.asStringValue(try rt.callGlobal("altOct", &.{})));
    try std.testing.expectEqualStrings("0b101", try vms.asStringValue(try rt.callGlobal("altBin", &.{})));
    // alt-form prefix is suppressed for a zero magnitude.
    try std.testing.expectEqualStrings("0", try vms.asStringValue(try rt.callGlobal("altZero", &.{})));
    try std.testing.expectEqualStrings("+42", try vms.asStringValue(try rt.callGlobal("plusSign", &.{})));
    try std.testing.expectEqualStrings(" 42", try vms.asStringValue(try rt.callGlobal("spaceSign", &.{})));
    // an actual negative sign always wins over +/space flags.
    try std.testing.expectEqualStrings("-42", try vms.asStringValue(try rt.callGlobal("plusSignOnNeg", &.{})));
    // i64::MIN's magnitude (2^63) overflows a naive negate -- fmtInt's
    // std.math.minInt special case must avoid that trap. Passed in as a
    // call argument (not a source literal): writing -9223372036854775808
    // directly in Gengo source hits the unrelated, already-documented
    // "unary negation of i64::MIN raises RangeError" literal-parsing trap.
    try std.testing.expectEqualStrings("-9223372036854775808", try vms.asStringValue(try rt.callGlobal("minInt", &.{.{ .int = std.math.minInt(i64) }})));
}

test "compiler: std.fmt.format width/padding for integer verbs (right/left/zero-pad, signed zero-pad)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func rightPad() string { return std.fmt.format("%5d", 42) }
        \\func leftPad() string { return std.fmt.format("%-5d", 42) }
        \\func zeroPad() string { return std.fmt.format("%05d", 42) }
        \\func zeroPadNeg() string { return std.fmt.format("%05d", -42) }
    );
    try std.testing.expectEqualStrings("   42", try vms.asStringValue(try rt.callGlobal("rightPad", &.{})));
    try std.testing.expectEqualStrings("42   ", try vms.asStringValue(try rt.callGlobal("leftPad", &.{})));
    try std.testing.expectEqualStrings("00042", try vms.asStringValue(try rt.callGlobal("zeroPad", &.{})));
    // the sign stays in front of the zero-padding, not behind it.
    try std.testing.expectEqualStrings("-0042", try vms.asStringValue(try rt.callGlobal("zeroPadNeg", &.{})));
}

test "compiler: std.fmt.format float verbs %f/%e/%E with default and explicit precision" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func fixedDefault() string { return std.fmt.format("%f", 1234.5) }
        \\func fixedPrec2() string { return std.fmt.format("%.2f", 1234.5) }
        \\func fixedPrec0Rounds() string { return std.fmt.format("%.0f", 3.7) }
        \\func sciDefault() string { return std.fmt.format("%e", 1234.5) }
        \\func sciUpper() string { return std.fmt.format("%E", 1234.5) }
        \\func sciPrec2() string { return std.fmt.format("%.2e", 1234.5) }
        \\func sciSmallExp() string { return std.fmt.format("%e", 0.0001234) }
        \\func fixedPlusSign() string { return std.fmt.format("%+.1f", 3.5) }
        \\func fixedSpaceSign() string { return std.fmt.format("% .1f", 3.5) }
    );
    try std.testing.expectEqualStrings("1234.500000", try vms.asStringValue(try rt.callGlobal("fixedDefault", &.{})));
    try std.testing.expectEqualStrings("1234.50", try vms.asStringValue(try rt.callGlobal("fixedPrec2", &.{})));
    try std.testing.expectEqualStrings("4", try vms.asStringValue(try rt.callGlobal("fixedPrec0Rounds", &.{})));
    try std.testing.expectEqualStrings("1.234500e+03", try vms.asStringValue(try rt.callGlobal("sciDefault", &.{})));
    try std.testing.expectEqualStrings("1.234500E+03", try vms.asStringValue(try rt.callGlobal("sciUpper", &.{})));
    try std.testing.expectEqualStrings("1.23e+03", try vms.asStringValue(try rt.callGlobal("sciPrec2", &.{})));
    try std.testing.expectEqualStrings("1.234000e-04", try vms.asStringValue(try rt.callGlobal("sciSmallExp", &.{})));
    try std.testing.expectEqualStrings("+3.5", try vms.asStringValue(try rt.callGlobal("fixedPlusSign", &.{})));
    try std.testing.expectEqualStrings(" 3.5", try vms.asStringValue(try rt.callGlobal("fixedSpaceSign", &.{})));
}

test "compiler: std.fmt.format %g/%G general float verb picks fixed vs scientific per exponent-vs-precision rule" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func fixedSide() string { return std.fmt.format("%g", 1234.5) }
        \\func sciSideSmall() string { return std.fmt.format("%g", 0.00001234) }
        \\func sciSideLarge() string { return std.fmt.format("%g", 123456789.0) }
        \\func sciSideLargeUpper() string { return std.fmt.format("%G", 123456789.0) }
        \\func trailingZerosStripped() string { return std.fmt.format("%g", 100.0) }
        \\func zeroValue() string { return std.fmt.format("%g", 0.0) }
    );
    // exp=3 < default precision 6 -> fixed notation, trailing zeros stripped.
    try std.testing.expectEqualStrings("1234.5", try vms.asStringValue(try rt.callGlobal("fixedSide", &.{})));
    // exp=-5 < -4 -> scientific notation.
    try std.testing.expectEqualStrings("1.234e-05", try vms.asStringValue(try rt.callGlobal("sciSideSmall", &.{})));
    // exp=8 >= precision 6 -> scientific notation, rounded to 6 significant digits.
    try std.testing.expectEqualStrings("1.23457e+08", try vms.asStringValue(try rt.callGlobal("sciSideLarge", &.{})));
    try std.testing.expectEqualStrings("1.23457E+08", try vms.asStringValue(try rt.callGlobal("sciSideLargeUpper", &.{})));
    try std.testing.expectEqualStrings("100", try vms.asStringValue(try rt.callGlobal("trailingZerosStripped", &.{})));
    try std.testing.expectEqualStrings("0", try vms.asStringValue(try rt.callGlobal("zeroValue", &.{})));
}

test "compiler: std.fmt.format float verbs short-circuit on NaN/+Inf/-Inf regardless of verb" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func nanF() string { return std.fmt.format("%f", std.math.nan()) }
        \\func nanE() string { return std.fmt.format("%e", std.math.nan()) }
        \\func nanG() string { return std.fmt.format("%g", std.math.nan()) }
        \\func infF() string { return std.fmt.format("%f", std.math.inf) }
        \\func infE() string { return std.fmt.format("%e", std.math.inf) }
        \\func negInfG() string { return std.fmt.format("%g", -std.math.inf) }
    );
    try std.testing.expectEqualStrings("NaN", try vms.asStringValue(try rt.callGlobal("nanF", &.{})));
    try std.testing.expectEqualStrings("NaN", try vms.asStringValue(try rt.callGlobal("nanE", &.{})));
    try std.testing.expectEqualStrings("NaN", try vms.asStringValue(try rt.callGlobal("nanG", &.{})));
    try std.testing.expectEqualStrings("Inf", try vms.asStringValue(try rt.callGlobal("infF", &.{})));
    try std.testing.expectEqualStrings("Inf", try vms.asStringValue(try rt.callGlobal("infE", &.{})));
    try std.testing.expectEqualStrings("-Inf", try vms.asStringValue(try rt.callGlobal("negInfG", &.{})));
}

test "compiler: std.fmt.format %s precision truncates bytes, %t formats booleans, %c emits a rune" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func plainS() string { return std.fmt.format("%s", "hello") }
        \\func precS() string { return std.fmt.format("%.3s", "hello") }
        \\func precLongerThanStr() string { return std.fmt.format("%.10s", "hi") }
        \\func boolTrue() string { return std.fmt.format("%t", true) }
        \\func boolFalse() string { return std.fmt.format("%t", false) }
        \\func runeVerb() string { return std.fmt.format("%c", 65) }
    );
    try std.testing.expectEqualStrings("hello", try vms.asStringValue(try rt.callGlobal("plainS", &.{})));
    try std.testing.expectEqualStrings("hel", try vms.asStringValue(try rt.callGlobal("precS", &.{})));
    try std.testing.expectEqualStrings("hi", try vms.asStringValue(try rt.callGlobal("precLongerThanStr", &.{})));
    try std.testing.expectEqualStrings("true", try vms.asStringValue(try rt.callGlobal("boolTrue", &.{})));
    try std.testing.expectEqualStrings("false", try vms.asStringValue(try rt.callGlobal("boolFalse", &.{})));
    try std.testing.expectEqualStrings("A", try vms.asStringValue(try rt.callGlobal("runeVerb", &.{})));
}

test "compiler: std.fmt.format %q hand-rolled escaping for backslash/quote/newline/CR/tab/control-byte" {
    var rt = try setup();
    defer rt.deinit();
    // Input (after Gengo's own lexer escape processing) is:
    //   a \ b " c <LF> d <CR> e <TAB> f <0x01> g
    // fmtQuoted re-escapes: '\\'->\\\\, '"'->\", '\n'->\n, '\r'->\r, '\t'->\t,
    // and control bytes 0-8/11/12/14-31/127 -> \xHH.
    try runSrc(&rt,
        \\std := import("std")
        \\func q() string { return std.fmt.format("%q", "a\\b\"c\nd\re\tf\x01g") }
    );
    const result = try rt.callGlobal("q", &.{});
    try std.testing.expectEqualStrings("\"a\\\\b\\\"c\\nd\\re\\tf\\x01g\"", try vms.asStringValue(result));
}

test "compiler: std.fmt.format %v generic verb honors width/left-align like the other verbs" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func plainInt() string { return std.fmt.format("%v", 42) }
        \\func plainStr() string { return std.fmt.format("%v", "hi") }
        \\func plainBool() string { return std.fmt.format("%v", true) }
        \\func widthPair() string { return std.fmt.format("[%5v][%-5v]", 42, 42) }
    );
    try std.testing.expectEqualStrings("42", try vms.asStringValue(try rt.callGlobal("plainInt", &.{})));
    try std.testing.expectEqualStrings("hi", try vms.asStringValue(try rt.callGlobal("plainStr", &.{})));
    try std.testing.expectEqualStrings("true", try vms.asStringValue(try rt.callGlobal("plainBool", &.{})));
    try std.testing.expectEqualStrings("[   42][42   ]", try vms.asStringValue(try rt.callGlobal("widthPair", &.{})));
}

test "compiler: std.fmt.format %% literal percent and multi-arg positional consumption" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func literalPercent() string { return std.fmt.format("100%%") }
        \\func interleaved() string { return std.fmt.format("Name: %s, Age: %d, Score: %.1f%%", "Bob", 30, 99.5) }
    );
    try std.testing.expectEqualStrings("100%", try vms.asStringValue(try rt.callGlobal("literalPercent", &.{})));
    try std.testing.expectEqualStrings("Name: Bob, Age: 30, Score: 99.5%", try vms.asStringValue(try rt.callGlobal("interleaved", &.{})));
}

test "compiler: std.fmt.format raises ArityMismatch on verb/arg count mismatch, TypeError on an unrecognized verb" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func tooFewArgs() string { return std.fmt.format("%d %d", 5) }
        \\func tooManyArgs() string { return std.fmt.format("%d", 5, 6) }
        \\func unknownVerb() string { return std.fmt.format("%z", 5) }
    );
    try std.testing.expectError(error.ArityMismatch, rt.callGlobal("tooFewArgs", &.{}));
    try std.testing.expectError(error.ArityMismatch, rt.callGlobal("tooManyArgs", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("unknownVerb", &.{}));
}

// std.fmt.stringify (fmt_stringify) drives the same sprintValue/
// sprintValueDepth object-stringification engine used by print/println/%v,
// exercising branches (struct_instance, array, map, named_error_value,
// variant_value with a record arm/single-payload arm/no-payload arm) that
// had no coverage anywhere else in this file -- every existing `string(x)`
// call in this file goes through the *unrelated* cast_string/
// nativeConvToString path (src/lang/native/core.zig) instead, which formats
// named errors as their bare message ("boom") rather than "MyErr(boom)".
test "compiler: std.fmt.stringify formats struct/array/map/named-error/variant objects" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Point struct { x int, y int }
        \\type MyErr error
        \\type Shape variant {
        \\    circle { radius float },
        \\    tag(label string),
        \\    point,
        \\}
        \\func structStr() string { return std.fmt.stringify(Point{x: 1, y: 2}) }
        \\func arrayStr() string { return std.fmt.stringify([1, 2, 3]) }
        \\func mapStr() string { return std.fmt.stringify({ "alpha": 1 }) }
        \\func namedErrStr() string { return std.fmt.stringify(MyErr("boom")) }
        \\func variantRecordStr() string { return std.fmt.stringify(Shape.circle { radius: 5.0 }) }
        \\func variantPayloadStr() string { return std.fmt.stringify(Shape.tag("hi")) }
        \\func variantNoPayloadStr() string { return std.fmt.stringify(Shape.point) }
    );
    try std.testing.expectEqualStrings("<struct Point>", try vms.asStringValue(try rt.callGlobal("structStr", &.{})));
    try std.testing.expectEqualStrings("[1, 2, 3]", try vms.asStringValue(try rt.callGlobal("arrayStr", &.{})));
    try std.testing.expectEqualStrings("{alpha: 1}", try vms.asStringValue(try rt.callGlobal("mapStr", &.{})));
    try std.testing.expectEqualStrings("MyErr(boom)", try vms.asStringValue(try rt.callGlobal("namedErrStr", &.{})));
    try std.testing.expectEqualStrings("Shape.circle(5)", try vms.asStringValue(try rt.callGlobal("variantRecordStr", &.{})));
    try std.testing.expectEqualStrings("Shape.tag(hi)", try vms.asStringValue(try rt.callGlobal("variantPayloadStr", &.{})));
    try std.testing.expectEqualStrings("Shape.point", try vms.asStringValue(try rt.callGlobal("variantNoPayloadStr", &.{})));
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

// Go-style typed composite-literal sugar for arrays: `[]Type{elem, ...}` as
// a standalone expression. Desugars to the exact same construction
// `var xs []Type = [elem, ...]` already compiles to (compiler_stmts.zig's
// varDecl: an anonymous array named_type built once, its object pushed as
// a constant, the plain array value constructed and passed to it as a
// single-arg call) — verified here across primitive, struct, named-type,
// empty, and nested element types, plus that element-type checking still
// fires (an ill-typed element must still be rejected, not silently
// accepted just because it went through the new sugar path).
test "compiler: []Type{...} composite-literal sugar constructs a typed array" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Point struct { x int, y int }
        \\type Meters int
        \\func ints() []int { return []int{1, 2, 3} }
        \\func strs() []string { return []string{"a", "b", "c"} }
        \\func emptyInts() []int { return []int{} }
        \\func points() []Point { return []Point{Point{x: 1, y: 2}, Point{x: 3, y: 4}} }
        \\func meters() []Meters { return []Meters{Meters(1), Meters(2)} }
        \\func nested() [][]int { return [][]int{[]int{1, 2}, []int{3, 4}} }
        \\func typeName() string { return std.core.type_of([]int{1, 2}) }
    );
    // A `[]T`-declared function return (like a `[]T`-declared local or
    // param) is a named_value wrapping the plain array — unwrap before
    // inspecting, same as the matchesTypeAlt fix this test also exercises.
    const arraySlice = struct {
        fn get(v: Value) ![]Value {
            const inner = v.namedInner() orelse v;
            return vms.asArraySlice(inner.object);
        }
    }.get;

    const ints = try rt.callGlobal("ints", &.{});
    const ints_items = try arraySlice(ints);
    try std.testing.expectEqual(@as(usize, 3), ints_items.len);
    try std.testing.expectEqual(@as(i64, 1), ints_items[0].int);

    const strs = try rt.callGlobal("strs", &.{});
    try std.testing.expectEqual(@as(usize, 3), (try arraySlice(strs)).len);

    const empty = try rt.callGlobal("emptyInts", &.{});
    try std.testing.expectEqual(@as(usize, 0), (try arraySlice(empty)).len);

    const points = try rt.callGlobal("points", &.{});
    try std.testing.expectEqual(@as(usize, 2), (try arraySlice(points)).len);

    const meters = try rt.callGlobal("meters", &.{});
    try std.testing.expectEqual(@as(usize, 2), (try arraySlice(meters)).len);

    // A copy-paste-divergence audit found matchesTypeAlt's .array/.map
    // cases never unwrapped a named_value before checking isArrayObject —
    // this is exactly the shape `[][]int{...}` produces for each inner
    // element (a named-array-typed value nested inside another array
    // literal), so this specific assertion is the regression guard for
    // that fix, not just the sugar's own construction.
    const nested = try rt.callGlobal("nested", &.{});
    const nested_items = try arraySlice(nested);
    try std.testing.expectEqual(@as(usize, 2), nested_items.len);
    try std.testing.expectEqual(@as(i64, 1), (try arraySlice(nested_items[0]))[0].int);

    const tn = try rt.callGlobal("typeName", &.{});
    try std.testing.expectEqualStrings("array", try vms.asStringValue(tn));

    try std.testing.expectError(error.TypeError, runSrc(&rt, "bad := []int{1, \"two\", 3}"));
}

// Gengo is newline-insensitive, so a naive "identifier right after ']'
// means a type name follows" check misfires on completely ordinary code:
// `xs := []` (a complete statement, empty untyped array) directly followed
// by an unrelated NEW statement that happens to start with an identifier
// (`std.io.println(xs)`) used to be swallowed as if it were
// `[]std...{...}`. The fix requires that identifier to actually be a known
// type name (isKnownTypeName) before treating it as the sugar.
test "compiler: []Type{...} sugar doesn't misfire on a plain [] followed by an unrelated statement" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\empty := []
        \\func describe() string { return std.core.type_of(empty) }
    );
    const result = try rt.callGlobal("describe", &.{});
    try std.testing.expectEqualStrings("array", try vms.asStringValue(result));
}

// The same matchesTypeAlt fix as the nested-array assertion above, but
// isolated to its actual trigger: a []T-typed function parameter receiving
// an already []T-typed argument. Before the fix this failed with a
// confusingly identical-looking "expected []int, got []int" (both sides
// render the same runtime type name — the check just never looked past the
// named_value wrapper constructNamedType's .array_t case always produces).
// Reproduced via the plain `var` declaration form too, proving this was a
// pre-existing bug in typed-array declarations generally, not something
// the new []Type{} sugar introduced.
test "compiler: a []T-typed value passes a []T-typed function parameter (named_value unwrapping)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func sum(xs []int) int {
        \\    total := 0
        \\    for v in xs {
        \\        total += v
        \\    }
        \\    return total
        \\}
        \\func viaSugar() int { return sum([]int{10, 20, 30}) }
        \\func viaVarDecl() int {
        \\    var ys []int = [1, 2, 3]
        \\    return sum(ys)
        \\}
    );
    const a = try rt.callGlobal("viaSugar", &.{});
    try std.testing.expectEqual(@as(i64, 60), a.int);
    const b = try rt.callGlobal("viaVarDecl", &.{});
    try std.testing.expectEqual(@as(i64, 6), b.int);
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
// ── Error-recovery audit tests ────────────────────────────────────────────────
//
// These tests document the current single-error limitation: the compiler stops
// at the first error and returns immediately, even when subsequent declarations
// contain independent, diagnosable errors.
//
// Each test asserts CURRENT behavior (first error only, by kind and line).
// When error recovery is implemented these tests must be updated to assert that
// ALL errors in the source are collected.

fn compileAndInspect(rt: *Runtime, src: []const u8) struct { err: anyerror, line: u32, msg: []const u8 } {
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    var compiler = Compiler.init(src, chunk.g_state, heap.g_state, .{}) catch |e| {
        return .{ .err = e, .line = 0, .msg = "" };
    };
    defer compiler.deinit();
    const result = compiler.compile(true);
    const e = result catch |err| {
        // Mirror the runtime's fallback: err_line is only set by the combined err()
        // helper; errors that call setErr() alone leave err_line=0, so fall back to
        // the lexer's prev token line — the same position the CLI displays.
        const line = if (compiler.err_line != 0) compiler.err_line else compiler.prev.line;
        return .{
            .err = err,
            .line = line,
            .msg = compiler.err_msg_buf[0..compiler.err_msg_len],
        };
    };
    _ = e;
    return .{ .err = error.NoError, .line = 0, .msg = "" };
}

fn compileAndInspectMulti(rt: *Runtime, src: []const u8) struct { first_err: anyerror, first_line: u32, count: u8 } {
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();
    var compiler = Compiler.init(src, chunk.g_state, heap.g_state, .{}) catch {
        return .{ .first_err = error.OutOfMemory, .first_line = 0, .count = 0 };
    };
    defer compiler.deinit();
    _ = compiler.compile(true) catch {};
    return .{
        .first_err = if (compiler.collected_error_count > 0) compiler.collected_errors[0].kind else error.NoError,
        .first_line = if (compiler.collected_error_count > 0) compiler.collected_errors[0].line else 0,
        .count = compiler.collected_error_count,
    };
}

test "compiler error recovery: all assign-to-const errors are collected" {
    // Three independent assign-to-const errors on lines 2, 4, and 6.
    // With recovery all three are collected; only the first aborted compilation before.
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspectMulti(&rt,
        \\const a = 1
        \\a = 2
        \\const b = 1
        \\b = 2
        \\const c = 1
        \\c = 2
    );
    try std.testing.expectEqual(error.AssignToConst, r.first_err);
    try std.testing.expectEqual(@as(u32, 2), r.first_line);
    try std.testing.expectEqual(@as(u8, 3), r.count);
}

test "compiler error recovery: all duplicate-type errors are collected" {
    // Two pairs of duplicate type declarations.
    // With recovery both duplicates (lines 2 and 4) are collected.
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspectMulti(&rt,
        \\type Color int
        \\type Color int
        \\type Size int
        \\type Size int
    );
    try std.testing.expectEqual(error.DuplicateNamedType, r.first_err);
    try std.testing.expectEqual(@as(u32, 2), r.first_line);
    try std.testing.expectEqual(@as(u8, 2), r.count);
}

test "compiler error recovery: mixed error kinds across declarations are all collected" {
    // Three independent compile errors of two distinct kinds: two AssignToConst
    // (lines 2 and 4) and one DuplicateNamedType (line 6).
    // With recovery all three are collected; previously only the first was seen.
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspectMulti(&rt,
        \\const x = 1
        \\x = 99
        \\const y = 1
        \\y = 99
        \\type Meter int
        \\type Meter int
    );
    try std.testing.expectEqual(error.AssignToConst, r.first_err);
    try std.testing.expectEqual(@as(u32, 2), r.first_line);
    try std.testing.expectEqual(@as(u8, 3), r.count);
}

test "compiler error recovery: error in one function body does not suppress error in another" {
    // Two functions each returning the wrong type.
    // With recovery both TypeError instances (lines 2 and 5) are collected.
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspectMulti(&rt,
        \\func broken_one() int {
        \\    return "not an int"
        \\}
        \\func broken_two() int {
        \\    return "also not an int"
        \\}
    );
    try std.testing.expectEqual(error.TypeError, r.first_err);
    try std.testing.expectEqual(@as(u32, 2), r.first_line);
    try std.testing.expectEqual(@as(u8, 2), r.count);
}

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

// ── std.array.* dispatch coverage (src/lang/native/array.zig) ──────────────

test "compiler: std.array.filter selects matching elements, including empty-input and no-match cases" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\even := func(v int) { return v rem 2 == 0 }
        \\assert std.core.deep_equal(std.array.filter([1, 2, 3, 4, 5, 6], even), [2, 4, 6])
        \\assert std.core.deep_equal(std.array.filter([1, 3, 5], even), [])
        \\assert std.core.deep_equal(std.array.filter([], even), [])
    );
}

test "compiler: std.array.map transforms every element, including an empty array" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\double := func(v int) { return v * 2 }
        \\assert std.core.deep_equal(std.array.map([1, 2, 3], double), [2, 4, 6])
        \\assert std.core.deep_equal(std.array.map([], double), [])
    );
}

test "compiler: std.array.reduce folds left-to-right and returns init unchanged for an empty array" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\sum := func(acc int, v int) { return acc + v }
        \\assert std.array.reduce([1, 2, 3, 4, 5], sum, 0) == 15
        \\assert std.array.reduce([], sum, 42) == 42
        \\concat := func(acc string, v string) { return acc + v }
        \\assert std.array.reduce(["a", "b", "c"], concat, "") == "abc"
    );
}

test "compiler: std.array.slice returns the requested sub-array and raises IndexOutOfBounds on invalid ranges" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\assert std.core.deep_equal(std.array.slice([1, 2, 3, 4, 5], 1, 4), [2, 3, 4])
        \\assert std.core.deep_equal(std.array.slice([1, 2, 3], 0, 3), [1, 2, 3])
        \\assert std.core.deep_equal(std.array.slice([1, 2, 3], 0, 0), [])
        \\func negFrom() any { return std.array.slice([1, 2, 3], -1, 2) }
        \\func toGreaterLen() any { return std.array.slice([1, 2, 3], 0, 5) }
        \\func fromGreaterTo() any { return std.array.slice([1, 2, 3], 2, 1) }
    );
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("negFrom", &.{}));
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("toGreaterLen", &.{}));
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("fromGreaterTo", &.{}));
}

test "compiler: std.array.zip pairs elements up to the shorter array's length" {
    var rt = try setup();
    defer rt.deinit();
    // Each pair is [int, string] — a heterogeneous array that can't be
    // spelled as a literal (bare array literals are runtime-homogeneous;
    // see build_array's element-type check in vm.zig), so pairs are
    // checked element-by-element via indexing instead of deep_equal
    // against a literal.
    try rt.run(
        \\std := import("std")
        \\z := std.array.zip([1, 2, 3], ["a", "b", "c"])
        \\assert std.core.len(z) == 3
        \\assert z[0][0] == 1 and z[0][1] == "a"
        \\assert z[1][0] == 2 and z[1][1] == "b"
        \\assert z[2][0] == 3 and z[2][1] == "c"
        \\z2 := std.array.zip([1, 2], ["x"])
        \\assert std.core.len(z2) == 1
        \\assert z2[0][0] == 1 and z2[0][1] == "x"
        \\z3 := std.array.zip([], [1, 2, 3])
        \\assert std.core.len(z3) == 0
    );
}

test "compiler: std.array.flat flattens exactly one level, leaving scalars and deeper nesting alone" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.core.deep_equal(std.array.flat([[1, 2], [3, 4], [5]]), [1, 2, 3, 4, 5])
        \\assert std.core.deep_equal(std.array.flat([[], [1], [2, 3]]), [1, 2, 3])
        \\assert std.core.deep_equal(std.array.flat([]), [])
        \\// Non-array elements pass through untouched, and only one level unwraps.
        \\// A bare array literal is runtime-homogeneous (build_array in vm.zig
        \\// rejects mixed element types), so the heterogeneous `mixed` input
        \\// below is assembled via std.core.append instead of a mixed-type
        \\// literal, and checked element-by-element rather than via
        \\// std.core.deep_equal against a hand-built "expected" array: an
        \\// append-built array is the .array_capacity Object variant, while
        \\// std.array.flat's own output is .array_managed, and deep_equal's
        \\// cross-variant exemption (core.zig's deepEqualObject) only covers
        \\// .array/.array_managed pairs, not .array_capacity — so comparing
        \\// the two forms wrongly reports "not equal" on identical content.
        \\inner := [2, 3]
        \\one_two_three := []
        \\one_two_three = std.core.append(one_two_three, 1)
        \\one_two_three = std.core.append(one_two_three, inner)
        \\mixed := []
        \\mixed = std.core.append(mixed, one_two_three)
        \\mixed = std.core.append(mixed, 4)
        \\mixed = std.core.append(mixed, [5])
        \\flat_mixed := std.array.flat(mixed)
        \\assert std.core.len(flat_mixed) == 4
        \\assert flat_mixed[0] == 1
        \\assert std.core.deep_equal(flat_mixed[1], inner)
        \\assert flat_mixed[2] == 4
        \\assert flat_mixed[3] == 5
    );
}

test "compiler: std.array.find and find_index return null/-1 when no element matches" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\isNeg := func(v int) { return v < 0 }
        \\assert std.array.find([1, 2, -3, 4], isNeg) == -3
        \\assert std.array.find([1, 2, 3], isNeg) == null
        \\assert std.array.find([], isNeg) == null
        \\assert std.array.find_index([1, 2, -3, 4], isNeg) == 2
        \\assert std.array.find_index([1, 2, 3], isNeg) == -1
        \\assert std.array.find_index([], isNeg) == -1
    );
}

test "compiler: std.array.all and any handle mixed predicates and the empty-array edge case" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\pos := func(v int) { return v > 0 }
        \\assert std.array.all([1, 2, 3], pos) == true
        \\assert std.array.all([1, -2, 3], pos) == false
        \\assert std.array.all([], pos) == true
        \\assert std.array.any([-1, -2, 3], pos) == true
        \\assert std.array.any([-1, -2, -3], pos) == false
        \\assert std.array.any([], pos) == false
    );
}

test "compiler: std.array.chunk splits into even and uneven groups and rejects size <= 0" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\assert std.core.deep_equal(std.array.chunk([1, 2, 3, 4, 5, 6], 2), [[1, 2], [3, 4], [5, 6]])
        \\assert std.core.deep_equal(std.array.chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
        \\assert std.core.deep_equal(std.array.chunk([], 3), [])
        \\func chunkZero() any { return std.array.chunk([1, 2, 3], 0) }
        \\func chunkNeg() any { return std.array.chunk([1, 2, 3], -1) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("chunkZero", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("chunkNeg", &.{}));
}

test "compiler: std.array.filter/map raise TypeError for a non-array argument or a non-bool predicate result" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func filterNonArray() any { return std.array.filter(5, func(v int) bool { return true }) }
        \\func filterBadPredicate() any { return std.array.filter([1, 2, 3], func(v int) int { return v }) }
        \\func mapNonArray() any { return std.array.map("nope", func(v int) { return v }) }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("filterNonArray", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("filterBadPredicate", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("mapNonArray", &.{}));
}

// Regression: two independent bugs in core.zig's deepEqualObject/
// deepEqualValue made std.core.deep_equal spuriously return false for
// content-identical arrays:
//
// 1. deepEqualObject's cross-variant array exemption checked
//    `(a==.array or a==.array_managed) and (b==.array or b==.array_managed)`
//    directly, missing .array_view/.array_capacity — the Object variant
//    std.core.append produces once an array outgrows its initial backing.
//    Fixed to use vms.isArrayObject (recognizes all four array-like tags),
//    matching the switch below it that already handled all four uniformly.
//
// 2. Bigger: a typed `[]int` var decl wraps its array in a .named_value
//    carrying a synthesized, PER-DECLARATION-SITE "[]int" NamedTypeObj (see
//    vm.zig's checkAssignCompat doc comment: "each var decl creates its own
//    type object"). deepEqualObject's .named_value case compared that
//    wrapper by raw pointer identity, so two SEPARATELY DECLARED []int
//    values — even a plain array literal against the exact same values
//    built via std.core.append on a []int-typed variable — always failed,
//    since every declaration site gets a distinct anonymous type object.
//    Fixed by unwrapping anonymous array_t/map_t named-value wrappers
//    (unwrapTransparentArrayOrMap) before any comparison, mirroring how
//    vm.zig's own equality/assignment-compat checks already treat these
//    synthesized wrappers as transparent rather than nominally distinct.
//    A REAL user-declared named type (`type Meter int`) is never
//    is_anonymous and keeps the strict pointer-identity check — two
//    differently-declared named types with the same underlying value must
//    NOT compare deep-equal.
test "compiler: std.core.deep_equal treats an append-grown array as equal to an equivalent literal" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func appendVsLiteral() bool {
        \\    grown := []int{}
        \\    grown = std.core.append(grown, 1)
        \\    grown = std.core.append(grown, 2)
        \\    grown = std.core.append(grown, 3)
        \\    literal := [1, 2, 3]
        \\    return std.core.deep_equal(grown, literal)
        \\}
        \\func literalVsAppend() bool {
        \\    grown := []int{}
        \\    grown = std.core.append(grown, 1)
        \\    grown = std.core.append(grown, 2)
        \\    literal := [1, 2]
        \\    return std.core.deep_equal(literal, grown)
        \\}
        \\func stillDetectsDifference() bool {
        \\    grown := []int{}
        \\    grown = std.core.append(grown, 1)
        \\    grown = std.core.append(grown, 2)
        \\    literal := [1, 3]
        \\    return std.core.deep_equal(grown, literal)
        \\}
        \\func twoAppendedArraysAreEqual() bool {
        \\    a := []int{}
        \\    a = std.core.append(a, 1)
        \\    b := []int{}
        \\    b = std.core.append(b, 1)
        \\    return std.core.deep_equal(a, b)
        \\}
        \\type Meter int
        \\type Foot int
        \\func sameDeclaredNamedTypeEqual() bool {
        \\    a := Meter(5)
        \\    c := Meter(5)
        \\    return std.core.deep_equal(a, c)
        \\}
    );
    const r1 = try rt.callGlobal("appendVsLiteral", &.{});
    try std.testing.expect(r1.boolean);
    const r2 = try rt.callGlobal("literalVsAppend", &.{});
    try std.testing.expect(r2.boolean);
    const r3 = try rt.callGlobal("stillDetectsDifference", &.{});
    try std.testing.expect(!r3.boolean);
    const r4 = try rt.callGlobal("twoAppendedArraysAreEqual", &.{});
    try std.testing.expect(r4.boolean);
    const r5 = try rt.callGlobal("sameDeclaredNamedTypeEqual", &.{});
    try std.testing.expect(r5.boolean);
}

// ── core.zig coverage sweep: is_int/is_float/is_string/is_array/is_map/
// is_struct/is_null, has/delete/keys/values/contains/remove, clone,
// type_of on rarer kinds, std.conv.to_bool, and the object (dyn_string/
// string_view) branch of std.conv.to_int/to_float. None of these were
// exercised anywhere in this file before (grepped for `core\.is_`,
// `core\.has(`, `core\.delete(`, `core\.remove(`, `core\.contains(`,
// `core\.keys(`, `core\.values(`, `core\.clone(`, `core\.gc_stats` and
// found zero hits), despite core.zig implementing all of them.
test "compiler: std.core.is_int/is_float/is_string/is_array/is_map/is_struct/is_null classify plain and named values" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Meter int
        \\type Speed float
        \\type Name string
        \\type ScoreList []int
        \\type ScoreMap [string]int
        \\type Point struct { x int, y int }
        \\func isIntPlain() bool { return std.core.is_int(5) }
        \\func isIntWholeFloat() bool { return std.core.is_int(5.0) }
        \\func isIntFractionalFloat() bool { return std.core.is_int(5.5) }
        \\func isIntNamed() bool { return std.core.is_int(Meter(5)) }
        \\func isIntString() bool { return std.core.is_int("5") }
        \\func isFloatPlain() bool { return std.core.is_float(5.5) }
        \\func isFloatWhole() bool { return std.core.is_float(5.0) }
        \\func isFloatInt() bool { return std.core.is_float(5) }
        \\func isFloatNamed() bool { return std.core.is_float(Speed(2.5)) }
        \\func isStringPlain() bool { return std.core.is_string("hi") }
        \\func isStringNamed() bool { return std.core.is_string(Name("hi")) }
        \\func isStringInt() bool { return std.core.is_string(5) }
        \\func isArrayPlain() bool { return std.core.is_array([1, 2, 3]) }
        \\func isArrayAnon() bool { return std.core.is_array([]int{1, 2, 3}) }
        \\func isArrayNamed() bool { return std.core.is_array(ScoreList([1, 2])) }
        \\func isArrayMap() bool { return std.core.is_array({"a": 1}) }
        \\func isMapPlain() bool { return std.core.is_map({"a": 1}) }
        \\func isMapNamed() bool { return std.core.is_map(ScoreMap({"a": 1})) }
        \\func isMapArray() bool { return std.core.is_map([1, 2]) }
        \\func isStructPlain() bool { return std.core.is_struct(Point{x: 1, y: 2}) }
        \\func isStructInt() bool { return std.core.is_struct(5) }
        \\func isNullPlain() bool { return std.core.is_null(null) }
        \\func isNullZero() bool { return std.core.is_null(0) }
    );
    try std.testing.expect((try rt.callGlobal("isIntPlain", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isIntWholeFloat", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isIntFractionalFloat", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isIntNamed", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isIntString", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isFloatPlain", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isFloatWhole", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isFloatInt", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isFloatNamed", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isStringPlain", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isStringNamed", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isStringInt", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isArrayPlain", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isArrayAnon", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isArrayNamed", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isArrayMap", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isMapPlain", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isMapNamed", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isMapArray", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isStructPlain", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isStructInt", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isNullPlain", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isNullZero", &.{})).boolean);
}

test "compiler: std.core.has/delete/keys/values/contains/remove cover map+array success and edge-case paths" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func hasPresent() bool { m := {"a": 1, "b": 2}; return std.core.has(m, "a") }
        \\func hasMissing() bool { m := {"a": 1}; return std.core.has(m, "z") }
        \\func deleteExisting() int { m := {"a": 1, "b": 2}; return std.core.delete(m, "a") }
        \\func deleteExistingShrinks() bool {
        \\    m := {"a": 1, "b": 2}
        \\    _ = std.core.delete(m, "a")
        \\    return std.core.len(m) == 1 and not std.core.has(m, "a") and std.core.has(m, "b")
        \\}
        \\func deleteMissingIsNull() bool {
        \\    m := {"a": 1}
        \\    removed := std.core.delete(m, "z")
        \\    return std.core.is_null(removed) and std.core.len(m) == 1
        \\}
        \\func keysAndValues() bool {
        \\    m := {"a": 1, "b": 2}
        \\    ks := std.core.keys(m)
        \\    vs := std.core.values(m)
        \\    return std.core.len(ks) == 2 and std.core.len(vs) == 2 and std.core.contains(ks, "a") and std.core.contains(ks, "b") and std.core.contains(vs, 1) and std.core.contains(vs, 2)
        \\}
        \\func containsPresent() bool { return std.core.contains([1, 2, 3], 2) }
        \\func containsAbsent() bool { return std.core.contains([1, 2, 3], 9) }
        \\func removeMiddle() bool {
        \\    a := [1, 2, 3]
        \\    b := std.core.remove(a, 1)
        \\    return std.core.deep_equal(b, [1, 3]) and std.core.deep_equal(a, [1, 2, 3])
        \\}
        \\func removeLastElement() bool {
        \\    a := [42]
        \\    b := std.core.remove(a, 0)
        \\    return std.core.len(b) == 0
        \\}
        \\func removeOutOfRange() []int { a := [1, 2, 3]; return std.core.remove(a, 5) }
        \\func removeNegative() []int { a := [1, 2, 3]; return std.core.remove(a, -1) }
    );
    try std.testing.expect((try rt.callGlobal("hasPresent", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("hasMissing", &.{})).boolean);
    try std.testing.expectEqual(@as(i64, 1), (try rt.callGlobal("deleteExisting", &.{})).int);
    try std.testing.expect((try rt.callGlobal("deleteExistingShrinks", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("deleteMissingIsNull", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("keysAndValues", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("containsPresent", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("containsAbsent", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("removeMiddle", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("removeLastElement", &.{})).boolean);
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("removeOutOfRange", &.{}));
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("removeNegative", &.{}));
}

// The real behavioral contract of std.core.clone is that it is a DEEP copy:
// mutating the clone's nested array/map (arrays/maps are reference types in
// Gengo, mutated in place through any alias) must never affect the
// original. A shallow/reference "clone" would fail every assertion below.
test "compiler: std.core.clone deep-copies nested arrays/maps/structs; mutating the clone leaves the original untouched" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Box struct {
        \\    items []int,
        \\    tags map[string]int,
        \\}
        \\type Wide struct {
        \\    a int,
        \\    b int,
        \\    c int,
        \\    d int,
        \\    e int,
        \\}
        \\func arrayIndependence() bool {
        \\    original := [1, 2, 3]
        \\    var copy []int = std.core.clone(original)
        \\    copy[0] = 999
        \\    return original[0] == 1 and copy[0] == 999
        \\}
        \\func mapIndependence() bool {
        \\    original := {"a": 1}
        \\    var copy map[string]int = std.core.clone(original)
        \\    copy["a"] = 999
        \\    return original["a"] == 1 and copy["a"] == 999
        \\}
        \\func smallStructIndependence() bool {
        \\    original := Box{items: [1, 2, 3], tags: {"x": 1}}
        \\    var copy Box = std.core.clone(original)
        \\    items := copy.items
        \\    items[0] = 999
        \\    tags := copy.tags
        \\    tags["x"] = 999
        \\    return original.items[0] == 1 and copy.items[0] == 999 and original.tags["x"] == 1 and copy.tags["x"] == 999
        \\}
        \\func wideStructIndependence() bool {
        \\    original := Wide{a: 1, b: 2, c: 3, d: 4, e: 5}
        \\    var copy Wide = std.core.clone(original)
        \\    copy.a = 999
        \\    return original.a == 1 and copy.a == 999 and copy.e == 5
        \\}
        \\func stringCloneRoundTrips() bool {
        \\    original := "hello"
        \\    copy := std.core.clone(original)
        \\    return copy == "hello"
        \\}
    );
    try std.testing.expect((try rt.callGlobal("arrayIndependence", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("mapIndependence", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("smallStructIndependence", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("wideStructIndependence", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("stringCloneRoundTrips", &.{})).boolean);
}

// cloneObject's CloneVisit tracking (cloneFindExisting/cloneRemember) mirrors
// deep_equal's cycle-guard, but was otherwise unexercised: a struct can
// reference its own type through a `[]Node` field (structs are heap
// objects, so this needs no forward-declaration trick), and appending the
// struct's own local binding into that field builds a genuine one-hop
// cycle straight from Gengo source. If clone() didn't track already-cloned
// objects, cloning this would recurse forever / stack-overflow.
test "compiler: std.core.clone on a self-referential struct terminates and stays independent" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Node struct {
        \\    val int,
        \\    children []Node,
        \\}
        \\func selfCycle() bool {
        \\    n := Node{val: 1, children: []Node{}}
        \\    n.children = std.core.append(n.children, n)
        \\    var copy Node = std.core.clone(n)
        \\    copy.val = 999
        \\    return n.val == 1 and copy.val == 999 and std.core.len(copy.children) == 1
        \\}
    );
    try std.testing.expect((try rt.callGlobal("selfCycle", &.{})).boolean);
}

test "compiler: std.core.type_of covers variant/enum/error/named-error/function/string_view values" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Shape variant {
        \\    circle { radius float },
        \\    tag(label string),
        \\    point,
        \\}
        \\type Color enum { red, green, blue }
        \\type MyErr error
        \\func typeOfVariantInline() string { return std.core.type_of(Shape.point) }
        \\func typeOfVariantRecord() string { return std.core.type_of(Shape.circle{radius: 5.0}) }
        \\func typeOfVariantPayload() string { return std.core.type_of(Shape.tag("hi")) }
        \\func typeOfEnum() string { return std.core.type_of(Color.red) }
        \\func typeOfPlainError() string { return std.core.type_of(std.core.error("boom")) }
        \\func typeOfNamedError() string { return std.core.type_of(MyErr("boom")) }
        \\func typeOfFunc() string {
        \\    f := func() int { return 1 }
        \\    return std.core.type_of(f)
        \\}
        \\func typeOfStringView() string {
        \\    s := std.bytes.slice(std.conv.to_string(12345), 1, 3)
        \\    return std.core.type_of(s)
        \\}
    );
    try std.testing.expectEqualStrings("Shape", try vms.asStringValue(try rt.callGlobal("typeOfVariantInline", &.{})));
    try std.testing.expectEqualStrings("Shape", try vms.asStringValue(try rt.callGlobal("typeOfVariantRecord", &.{})));
    try std.testing.expectEqualStrings("Shape", try vms.asStringValue(try rt.callGlobal("typeOfVariantPayload", &.{})));
    try std.testing.expectEqualStrings("Color", try vms.asStringValue(try rt.callGlobal("typeOfEnum", &.{})));
    try std.testing.expectEqualStrings("error", try vms.asStringValue(try rt.callGlobal("typeOfPlainError", &.{})));
    try std.testing.expectEqualStrings("MyErr", try vms.asStringValue(try rt.callGlobal("typeOfNamedError", &.{})));
    try std.testing.expectEqualStrings("func", try vms.asStringValue(try rt.callGlobal("typeOfFunc", &.{})));
    try std.testing.expectEqualStrings("string", try vms.asStringValue(try rt.callGlobal("typeOfStringView", &.{})));
}

// std.conv.to_bool has NO compiler intrinsic lowering to cast_bool (unlike
// to_int/to_float/to_string — see selectStdConvIntrinsicOp, which never
// mentions to_bool), so every call below always reaches nativeConvToBool
// via the native-call path regardless of the argument's static type.
test "compiler: std.conv.to_bool covers every source Value/Object kind" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Flag bool
        \\type Money decimal 2
        \\type MyErr error
        \\func boolTrue() bool { return std.conv.to_bool(true) }
        \\func boolFalse() bool { return std.conv.to_bool(false) }
        \\func intZero() bool { return std.conv.to_bool(0) }
        \\func intNonzero() bool { return std.conv.to_bool(5) }
        \\func floatZero() bool { return std.conv.to_bool(0.0) }
        \\func floatNonzero() bool { return std.conv.to_bool(1.5) }
        \\func runeNonzero() bool { return std.conv.to_bool('a') }
        \\func emptyString() bool { return std.conv.to_bool("") }
        \\func nonEmptyString() bool { return std.conv.to_bool("hi") }
        \\func nullValue() bool { return std.conv.to_bool(null) }
        \\func namedBoolTrue() bool { return std.conv.to_bool(Flag(true)) }
        \\func namedBoolFalse() bool { return std.conv.to_bool(Flag(false)) }
        \\func decimalZero() bool { return std.conv.to_bool(Money(0.00)) }
        \\func decimalNonzero() bool { return std.conv.to_bool(Money(9.99)) }
        \\func plainErrorVal() bool { return std.conv.to_bool(std.core.error("boom")) }
        \\func namedErrorVal() bool { return std.conv.to_bool(MyErr("boom")) }
        \\func dynStringNonEmpty() bool { return std.conv.to_bool(std.conv.to_string(123)) }
        \\func stringViewNonEmpty() bool { return std.conv.to_bool(std.bytes.slice(std.conv.to_string(12345), 1, 3)) }
        \\func arrayIsAlwaysTrue() bool { return std.conv.to_bool([1, 2, 3]) }
        \\func emptyArrayIsAlwaysTrue() bool { return std.conv.to_bool([]int{}) }
    );
    try std.testing.expect((try rt.callGlobal("boolTrue", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("boolFalse", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("intZero", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("intNonzero", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("floatZero", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("floatNonzero", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("runeNonzero", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("emptyString", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("nonEmptyString", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("nullValue", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("namedBoolTrue", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("namedBoolFalse", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("decimalZero", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("decimalNonzero", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("plainErrorVal", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("namedErrorVal", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("dynStringNonEmpty", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("stringViewNonEmpty", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("arrayIsAlwaysTrue", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("emptyArrayIsAlwaysTrue", &.{})).boolean);
}

// std.conv.to_int/to_float only lower to cast_int/cast_float for a
// provably non-string static type (selectStdConvIntrinsicOp); a runtime
// string built via concatenation or std.bytes.slice keeps them on the
// native-call path, exercising nativeConvToInt/Float's `.object` branch
// (dyn_string/string_view, as opposed to the interned `.string` tag a
// literal produces) instead of the VM's cast_int/cast_float ops.
test "compiler: std.conv.to_int/to_float exercise the dyn_string/string_view object conversion path" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func intFromDynStringOk() int { s := std.conv.to_string(123); return std.conv.to_int(s) }
        \\func intFromDynStringBad() int { s := std.conv.to_string(123) + "x"; return std.conv.to_int(s) }
        \\func floatFromDynStringOk() float { s := std.conv.to_string(1.5); return std.conv.to_float(s) }
        \\func floatFromDynStringBad() float { s := std.conv.to_string(1.5) + "z"; return std.conv.to_float(s) }
        \\func intFromStringViewOk() int {
        \\    s := std.bytes.slice(std.conv.to_string(12345), 1, 3)
        \\    return std.conv.to_int(s)
        \\}
    );
    try std.testing.expectEqual(@as(i64, 123), (try rt.callGlobal("intFromDynStringOk", &.{})).int);
    try std.testing.expectError(error.TypeError, rt.callGlobal("intFromDynStringBad", &.{}));
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), (try rt.callGlobal("floatFromDynStringOk", &.{})).float, 1e-9);
    try std.testing.expectError(error.TypeError, rt.callGlobal("floatFromDynStringBad", &.{}));
    try std.testing.expectEqual(@as(i64, 23), (try rt.callGlobal("intFromStringViewOk", &.{})).int);
}

// std.core.gc_stats/gc_stats_ext were never called anywhere in this file
// before; field values are runtime/GC-state-dependent so only their
// presence and sane (non-negative / positive-heap-size) bounds are
// checked, not exact numbers. Also covers std.core.gc, gc_live_objects,
// error, and is_error's .named_error_value branch (previously only its
// plain .error_value branch was exercised, via the cap:net tests).
test "compiler: std.core.gc_stats/gc_stats_ext report sane fields; gc/gc_live_objects/error/is_error(named error) round-trip" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type MyErr error
        \\func gcStatsHasFields() bool {
        \\    stats := std.core.gc_stats()
        \\    return std.core.has(stats, "heap_used_bytes") and std.core.has(stats, "heap_size_bytes") and std.core.has(stats, "live_objects") and stats["heap_size_bytes"] > 0 and stats["heap_used_bytes"] >= 0 and stats["live_objects"] >= 0
        \\}
        \\func gcStatsExtHasFields() bool {
        \\    stats := std.core.gc_stats_ext()
        \\    ok := std.core.has(stats, "heap_used_bytes") and std.core.has(stats, "heap_size_bytes") and std.core.has(stats, "live_objects") and std.core.has(stats, "gc_runs") and std.core.has(stats, "gc_time_ns") and std.core.has(stats, "alloc_object_calls") and std.core.has(stats, "alloc_managed_slice_calls") and std.core.has(stats, "alloc_managed_bytes_calls")
        \\    return ok and stats["heap_size_bytes"] > 0 and stats["gc_runs"] >= 0 and stats["gc_time_ns"] >= 0 and stats["alloc_object_calls"] >= 0 and stats["alloc_managed_slice_calls"] >= 0 and stats["alloc_managed_bytes_calls"] >= 0
        \\}
        \\func gcDoesNotCrash() bool { std.core.gc(); return true }
        \\func gcLiveObjectsNonNegative() bool { return std.core.gc_live_objects() >= 0 }
        \\func errorRoundTrip() bool { e := std.core.error("boom"); return std.core.is_error(e) }
        \\func namedErrorIsError() bool { return std.core.is_error(MyErr("boom")) }
    );
    try std.testing.expect((try rt.callGlobal("gcStatsHasFields", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("gcStatsExtHasFields", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("gcDoesNotCrash", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("gcLiveObjectsNonNegative", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("errorRoundTrip", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("namedErrorIsError", &.{})).boolean);
}
