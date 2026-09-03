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

test "compiler: emitModuleObject builds an empty struct for a module whose declarations are all private (zero exports)" {
    // emitModuleObject (compiler.zig) always runs at the end of a module's
    // compilation regardless of export_count — with none, its
    // `fields[0..self.export_count]`/`self.exports[0..self.export_count]`
    // loops both iterate zero times and it still builds+installs a
    // (fieldless) struct-type constant and def_globals it under the
    // module's binding name.
    const main_src =
        \\m := import("./empty")
    ;
    const dep_src =
        \\type Secret int
        \\func helper() int { return 1 }
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = "main.gengo", .source = main_src },
        .{ .path = "empty.gengo", .source = dep_src },
    };

    var rt = try setup();
    defer rt.deinit();

    const outcome = try rt.runPathWithSources(main_src, "main.gengo", &source_entries);
    try std.testing.expectEqual(vm.RunOutcome.completed, outcome);
}

// module_compile.zig's beginImportedModule detects a genuine cycle (A imports
// B while B is still mid-compile importing A back) via findModule seeing the
// importer's own record still in the `.loading` state, and reports
// error.ImportCycle. No prior test actually built a real A<->B import cycle.
test "compiler: a genuine two-file circular import (A imports B, B imports A) fails with ImportCycle" {
    const a_src =
        \\b := import("./b")
        \\pub func fa() int { return 1 }
    ;
    const b_src =
        \\a := import("./a")
        \\pub func fb() int { return 2 }
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = "a.gengo", .source = a_src },
        .{ .path = "b.gengo", .source = b_src },
    };

    var rt = try setup();
    defer rt.deinit();

    try std.testing.expectError(error.ImportCycle, rt.compileOnly(a_src, "a.gengo", .{ .table = &source_entries }));
}

// Diamond import shape: A imports B and C, and B and C both import the same
// D. beginImportedModule's findModule dedup must let the second import of D
// (from C, after B already compiled it) return without recompiling or
// re-declaring D's exports -- exercised here by having both B and C actually
// call into D and checking both results are correct.
test "compiler: diamond import (A imports B and C; B and C both import D) compiles D once and both branches see its exports" {
    const main_src =
        \\b := import("./b")
        \\c := import("./c")
        \\pub func run() int { return b.viaB() + c.viaC() }
    ;
    const b_src =
        \\d := import("./d")
        \\pub func viaB() int { return d.base() + 1 }
    ;
    const c_src =
        \\d := import("./d")
        \\pub func viaC() int { return d.base() + 2 }
    ;
    const d_src =
        \\pub func base() int { return 10 }
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = "main.gengo", .source = main_src },
        .{ .path = "b.gengo", .source = b_src },
        .{ .path = "c.gengo", .source = c_src },
        .{ .path = "d.gengo", .source = d_src },
    };

    var rt = try setup();
    defer rt.deinit();

    const outcome = try rt.runPathWithSources(main_src, "main.gengo", &source_entries);
    try std.testing.expectEqual(vm.RunOutcome.completed, outcome);
    const result = try rt.callGlobal("run", &.{});
    try std.testing.expectEqual(@as(i64, 23), result.int);
}

// Importing the same file twice under two different local bindings in one
// module: compileDependencies' pre-pass import scan dedups the two "./dep"
// specifiers to a single compile, and the live compiler still evaluates each
// `import(...)` expression separately -- beginImportedModule's second call
// must find the already-.compiled record and return null (no recompile, no
// error), handing back the same module global both times.
test "compiler: importing the same file twice under different local bindings reuses the compiled module" {
    const main_src =
        \\d1 := import("./dep")
        \\d2 := import("./dep")
        \\pub func run() int { return d1.value() + d2.value() }
    ;
    const dep_src =
        \\pub func value() int { return 7 }
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = "main.gengo", .source = main_src },
        .{ .path = "dep.gengo", .source = dep_src },
    };

    var rt = try setup();
    defer rt.deinit();

    const outcome = try rt.runPathWithSources(main_src, "main.gengo", &source_entries);
    try std.testing.expectEqual(vm.RunOutcome.completed, outcome);
    const result = try rt.callGlobal("run", &.{});
    try std.testing.expectEqual(@as(i64, 14), result.int);
}

// module_compile.zig's resolveModuleConstant is reachable from
// compiler_decls.zig's compile-time-constant expression parser, which a
// named type's `range min..max` bound requires to be resolvable at compile
// time -- so this exercises resolveModuleConstant with a genuine cross-file
// `pub const` export, not just a runtime field read.
test "compiler: a pub const exported from a file-imported module resolves as a compile-time constant for a named type's range bound" {
    const main_src =
        \\dep := import("./dep")
        \\type Meters int range 0..dep.MAX
        \\pub func boundary() int { return int(Meters(dep.MAX)) }
    ;
    const dep_src =
        \\pub const MAX = 100
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = "main.gengo", .source = main_src },
        .{ .path = "dep.gengo", .source = dep_src },
    };

    var rt = try setup();
    defer rt.deinit();

    const outcome = try rt.runPathWithSources(main_src, "main.gengo", &source_entries);
    try std.testing.expectEqual(vm.RunOutcome.completed, outcome);
    const result = try rt.callGlobal("boundary", &.{});
    try std.testing.expectEqual(@as(i64, 100), result.int);
}

// hasModuleExport's "real compiled module" branch (as opposed to its
// capability/host-module fallbacks) returns false for both a name that was
// never declared and a name that was declared but never marked `pub` --
// exports require the explicit `pub` keyword (see compiler_decls.zig's
// addExport call sites), so a plain top-level func is invisible across an
// import boundary.
test "compiler: accessing an unexported (non-pub) or nonexistent field on a file-imported module is a compile error" {
    const dep_src =
        \\pub func exported() int { return 1 }
        \\func private() int { return 2 }
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = "dep.gengo", .source = dep_src },
    };

    {
        const main_src =
            \\dep := import("./dep")
            \\pub func run() int { return dep.private() }
        ;
        var rt = try setup();
        defer rt.deinit();
        try std.testing.expectError(error.UnknownField, rt.compileOnly(main_src, "main.gengo", .{ .table = &source_entries }));
    }
    {
        const main_src =
            \\dep := import("./dep")
            \\pub func run() int { return dep.nonexistent() }
        ;
        var rt = try setup();
        defer rt.deinit();
        try std.testing.expectError(error.UnknownField, rt.compileOnly(main_src, "main.gengo", .{ .table = &source_entries }));
    }
}

// module_compile.zig's Session.sourceExists/loadSource '.filesystem' arms
// (real-disk fileExists()/source_io.readFile()) had no direct test coverage:
// every other multi-file import test in this file uses the in-memory
// '.table' SourceProvider. This drives a real cross-file import against
// actual files under a std.testing.tmpDir, matching the disk-file pattern
// used elsewhere in this codebase (see main.zig's "readSource reads a real
// file's contents" tests).
test "compiler: a file import resolves against a real file on disk via the .filesystem provider" {
    const io_ctx = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dep_content = "pub func helper() int { return 42 }";
    try tmp.dir.writeFile(io_ctx, .{ .sub_path = "dep.gengo", .data = dep_content });

    const main_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/main.gengo", .{tmp.sub_path});
    defer std.testing.allocator.free(main_path);

    const main_src =
        \\dep := import("./dep")
        \\pub func run() int { return dep.helper() }
    ;

    var rt = try setup();
    defer rt.deinit();

    const outcome = try rt.runPath(main_src, main_path);
    try std.testing.expectEqual(vm.RunOutcome.completed, outcome);
    const result = try rt.callGlobal("run", &.{});
    try std.testing.expectEqual(@as(i64, 42), result.int);
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

// Coverage-audit 2026-09: chunk_verifier.zig's per-fused-op "expected
// embedded sub-opcode" checks (verify()'s first linear-scan switch) were
// only ever exercised for get_local_const_eq. Every sibling fused op has
// the identical shape — a hand-crafted skip byte that doesn't match the
// op's hardcoded embedded opcode must trip BadOpcode, the same way a
// corrupted or maliciously-crafted .gbc file's bytecode would. Table-
// driven across every remaining case in that switch (idx_off is the byte
// offset of the u16 constant-pool index the op reads; the byte right
// before it is always the checked "skip" byte, always left as 0 here —
// 0 is Op.halt, never one of the embedded ops any of these checks expect,
// so it reliably fails every comparison without needing per-case values).
test "chunk: verify catches BadOpcode for every fused embedded-op mismatch" {
    const Case = struct { op: Op, width: u8, idx_off: u8 };
    const cases = [_]Case{
        .{ .op = .get_local_const_sub, .width = 5, .idx_off = 3 },
        .{ .op = .get_local_const_add, .width = 5, .idx_off = 3 },
        .{ .op = .get_local_const_lt, .width = 5, .idx_off = 3 },
        .{ .op = .get_local_const_gt, .width = 5, .idx_off = 3 },
        .{ .op = .get_local_const_gt_jif_pop, .width = 9, .idx_off = 3 },
        .{ .op = .get_global_const_eq, .width = 8, .idx_off = 6 },
        .{ .op = .get_global_const_sub, .width = 8, .idx_off = 6 },
        .{ .op = .get_global_const_add, .width = 8, .idx_off = 6 },
        .{ .op = .get_global_const_lt, .width = 8, .idx_off = 6 },
        .{ .op = .get_local_const_eq_jif_pop, .width = 9, .idx_off = 3 },
        .{ .op = .get_local_const_lt_jif_pop, .width = 9, .idx_off = 3 },
        .{ .op = .get_global_const_lt_jif_pop, .width = 12, .idx_off = 6 },
        .{ .op = .get_local_const_sub_call, .width = 8, .idx_off = 3 },
        .{ .op = .call_global_local_sub_const, .width = 13, .idx_off = 8 },
        .{ .op = .call_global_local_sub_const_tail, .width = 13, .idx_off = 8 },
        .{ .op = .get_local_get_field, .width = 8, .idx_off = 3 },
        .{ .op = .local_add_field, .width = 9, .idx_off = 4 },
    };

    for (cases) |c| {
        var rt = try setup();
        defer rt.deinit();

        chunk.setActive(rt.chunk_state);
        globals.setActive(&rt.globals_state);
        heap.setActive(&rt.heap_state);
        chunk.reset();
        globals.reset();
        heap.reset();

        // Two constants registered so idx=1 clears the earlier
        // BadConstantIndex check and reaches the embedded-opcode switch.
        try chunk.emitConst(.{ .int = 42 }, 1);
        try chunk.emitConst(.{ .int = 99 }, 1);

        var i: u8 = 0;
        while (i < c.width) : (i += 1) {
            if (i == 0) {
                try chunk.emitByte(@intFromEnum(c.op), 1);
            } else if (i == c.idx_off) {
                try chunk.emitByte(0, 1);
            } else if (i == c.idx_off + 1) {
                try chunk.emitByte(1, 1);
            } else {
                try chunk.emitByte(0, 1);
            }
        }

        std.testing.expectError(error.BadOpcode, chunk.verify()) catch |err| {
            std.debug.print("case op={s}: {}\n", .{ @tagName(c.op), err });
            return err;
        };
    }
}

test "chunk: verify catches local slot out of range at entry (InvalidBytecode)" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    // Top level starts with local_base=0 and depth=0, so any get_local
    // (even slot 0) reads outside the currently-valid range.
    try chunk.emitOp(.get_local, 1);
    try chunk.emitByte(0, 1);

    try std.testing.expectError(error.InvalidBytecode, chunk.verify());
}

test "chunk: verify catches upvalue index out of range (InvalidBytecode)" {
    var rt = try setup();
    defer rt.deinit();

    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    // Top level captures nothing (upvalue_count=0), so any get_upvalue
    // index, even 0, is out of range.
    try chunk.emitOp(.get_upvalue, 1);
    try chunk.emitByte(0, 1);

    try std.testing.expectError(error.InvalidBytecode, chunk.verify());
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

// ── Interface structural conformance (structConformsToInterface) ───────────
//
// structConformsToInterface (compiler.zig) is the compile-time analogue of
// vm_types.zig's matchesInterfaceType: given a real STRUCT static type (not
// a named-type receiver — those have no struct_type tracked in ExprPrimInfo
// and always fall back to the runtime check, see the
// "defused named-type interface arg" test above), it walks the interface's
// method list and proves conformance by looking up "Struct.method" in the
// registry and comparing shapes via type_shapes.interfaceMethodMatches.
// It is consumed two ways: argProvenForParam (sets the call's 0x80
// proven-args byte, skipping runtime enforcement) and varTypeCheckProven
// (skips emitting the assert_interface epilog on a var decl). Returning
// false from either "doesn't conform" or "can't prove it" is not an error by
// itself — it just means the runtime assert_interface/matchesInterfaceType
// check still runs, and that check enforces the exact same rule.

test "compiler: a struct fully implementing an interface proves conformance and sets the call's proven-args bit" {
    // p is a FUNCTION-LOCAL (get_local at the call site), not a top-level
    // global — a top-level `p := Point{...}` read back as a call argument
    // would fuse (get_global "f"; get_global "p"; call 1 -> get_global_call,
    // since the arg-loading get_global directly precedes the call), and the
    // call result is bound to a local before returning rather than returned
    // directly — a `return f(p)` tail call fuses `call` immediately followed
    // by `ret` into `call_tail`. findCallArgcByte only recognizes the plain,
    // unfused `.call` opcode, so both fusions need dodging here.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Point struct { x int, y int }
        \\func (p Point) area() int { return p.x * p.y }
        \\type Shaped interface { area() int }
        \\func f(s Shaped) int { return s.area() }
        \\func caller() int {
        \\    p := Point { x: 3, y: 4 }
        \\    r := f(p)
        \\    return r
        \\}
    );
    const c = rt.chunk_state;
    const argc_byte = findCallArgcByte(c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1 | 0x80), argc_byte);
}

test "compiler: a struct missing an interface method cannot be proven, and the runtime assert_interface catches it" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Circle struct { r int }
        \\type Shaped interface { area() int }
        \\func f(s Shaped) int { return s.area() }
        \\func caller() int {
        \\    c := Circle { r: 5 }
        \\    r := f(c)
        \\    return r
        \\}
    );
    const cs = rt.chunk_state;
    const argc_byte = findCallArgcByte(cs) orelse return error.TestUnexpectedResult;
    // structConformsToInterface's per-method registry.getGlobalFuncObj lookup
    // misses entirely (Circle never defines area()) — the loop's `orelse
    // return false` fires, so the call is left unproven.
    try std.testing.expectEqual(@as(u8, 0), argc_byte & 0x80);

    var rt2 = try setup();
    defer rt2.deinit();
    try runSrc(&rt2,
        \\type Circle struct { r int }
        \\type Shaped interface { area() int }
        \\func f(s Shaped) int { return s.area() }
        \\func caller() int {
        \\    c := Circle { r: 5 }
        \\    return f(c)
        \\}
    );
    try std.testing.expectError(error.TypeError, rt2.callGlobal("caller", &.{}));
}

test "compiler: a struct method with a mismatched signature also fails to prove interface conformance" {
    // Circle.area exists (unlike the missing-method test above) but takes an
    // extra explicit parameter the interface doesn't declare — this exercises
    // type_shapes.interfaceMethodMatches' arity mismatch, a different
    // structConformsToInterface `return false` site than the missing-method
    // case (registry.getGlobalFuncObj succeeds; the shape check fails).
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Circle struct { r int }
        \\func (c Circle) area(scale int) int { return c.r * scale }
        \\type Shaped interface { area() int }
        \\func f(s Shaped) int { return s.area() }
        \\func caller() int {
        \\    c := Circle { r: 5 }
        \\    r := f(c)
        \\    return r
        \\}
    );
    const cs = rt.chunk_state;
    const argc_byte = findCallArgcByte(cs) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), argc_byte & 0x80);

    var rt2 = try setup();
    defer rt2.deinit();
    try runSrc(&rt2,
        \\type Circle struct { r int }
        \\func (c Circle) area(scale int) int { return c.r * scale }
        \\type Shaped interface { area() int }
        \\func f(s Shaped) int { return s.area() }
        \\func caller() int {
        \\    c := Circle { r: 5 }
        \\    return f(c)
        \\}
    );
    try std.testing.expectError(error.TypeError, rt2.callGlobal("caller", &.{}));
}

test "compiler: var decl with an explicit interface type proves conformance (skips the runtime check) when the struct fully implements it" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Point struct { x int, y int }
        \\func (p Point) area() int { return p.x * p.y }
        \\type Shaped interface { area() int }
        \\func h() int {
        \\    var s Shaped = Point{x:3,y:4}
        \\    return s.area()
        \\}
    );
    const result = try rt.callGlobal("h", &.{});
    try std.testing.expectEqual(@as(i64, 12), result.int);
}

test "compiler: var decl with an explicit interface type falls back to the runtime assert_interface when the struct doesn't conform" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Circle struct { r int }
        \\type Shaped interface { area() int }
        \\func g() {
        \\    var s Shaped = Circle{r:1}
        \\}
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("g", &.{}));
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

// Coverage-audit 2026-09: attempted to close vm.zig's uncovered
// `get_global_call_tail`/`call_global_global_tail` handlers (the tail-call
// siblings of `get_global_call`/`call_global_global`, both of which ARE
// covered). Traced fusion_pass.zig's actual round-by-round algorithm and
// confirmed empirically via `gengo disasm` (both `target(g_arg)` returned
// directly, and the local-func-value `f(g_arg)` form) that neither ever
// forms: `fuseOnce`'s Pass B scans strictly left-to-right and, on hitting a
// `get_global` immediately followed by `call` with argc>0, ALWAYS commits
// to the `get_global_call` (non-tail) fusion in that same visitation
// (`decideAt`'s fuse branch consumes both instructions via
// `ip += inst.width + b_inst.width`) — `call`'s own start position is never
// separately revisited in that round, so the sibling `if (a == .call and b
// == .ret) return .flip_tail` rule (which only matches the literal `.call`
// opcode, never `get_global_call`) can't apply to it, this round or any
// later one. The two ops appear to be dead code given the current fusion
// algorithm's ordering — not attempted further; see [[project-audit-2026-09]]
// round 6 for the full trace. `get_global_call`/`call_global_global`
// (non-tail) are already covered via "fused global-sub call" above and
// pre-existing tests.

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

// Coverage-audit 2026-09: the `a == b or a != b or a < b or a > b` test
// above never actually runs its own `a < b`/`a > b` clauses at runtime —
// for any two floats, `a == b or a != b` is a tautology (exactly one side
// is always true), so `or`'s short-circuit means those first two clauses
// always decide the whole expression, and `lt_float`/`gt_float`'s success
// path (vm.zig ~3082-3091/3092-3101) never executes despite the sibling
// "opcodes fire" test proving the bytecode contains them. `le_float`/
// `ge_float`'s success path was never driven at all (no prior test).
// Isolating each comparison into its own function, with no short-circuiting
// sibling clause, actually exercises all four.
test "compiler: typed float lt/gt/le/ge comparisons actually execute their success path (not short-circuited)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func cmpLt(a float, b float) bool { return a < b }
        \\func cmpGt(a float, b float) bool { return a > b }
        \\func cmpLe(a float, b float) bool { return a <= b }
        \\func cmpGe(a float, b float) bool { return a >= b }
    );
    try std.testing.expect((try rt.callGlobal("cmpLt", &.{ .{ .float = 3.0 }, .{ .float = 4.0 } })).boolean);
    try std.testing.expect(!(try rt.callGlobal("cmpLt", &.{ .{ .float = 4.0 }, .{ .float = 3.0 } })).boolean);
    try std.testing.expect((try rt.callGlobal("cmpGt", &.{ .{ .float = 5.0 }, .{ .float = 4.0 } })).boolean);
    try std.testing.expect(!(try rt.callGlobal("cmpGt", &.{ .{ .float = 3.0 }, .{ .float = 4.0 } })).boolean);
    try std.testing.expect((try rt.callGlobal("cmpLe", &.{ .{ .float = 4.0 }, .{ .float = 4.0 } })).boolean);
    try std.testing.expect(!(try rt.callGlobal("cmpLe", &.{ .{ .float = 5.0 }, .{ .float = 4.0 } })).boolean);
    try std.testing.expect((try rt.callGlobal("cmpGe", &.{ .{ .float = 4.0 }, .{ .float = 4.0 } })).boolean);
    try std.testing.expect(!(try rt.callGlobal("cmpGe", &.{ .{ .float = 3.0 }, .{ .float = 4.0 } })).boolean);
}

// Coverage-audit 2026-09: vm.zig's setBinaryTypeError builds a refined error
// message when a failed binary op's two operands are BOTH named types
// sharing the same base primitive with no subtype/common-ancestor relation
// ("cannot apply 'op' to A and B; convert one side explicitly..."), distinct
// from its plain-TypeError fallback. No existing test reached it. It only
// fires when the underlying VALUES also genuinely fail the op — same-base
// named ints (e.g. Meters(5) + Seconds(3)) just add their erased int values
// fine, no error at all — so two same-base named *string* types subtracted
// (strings don't support '-') was the reliable way in, confirmed first via
// the CLI (`gengo run`, panicked with exactly this message) before writing
// the test. Routed through `any`-typed params so the compiler can't
// statically prove/reject the mismatch itself and defers to this runtime
// check.
test "compiler: subtracting two unrelated same-base named string types reports the named-type-specific TypeError message" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();
    switch (rt.run(
        \\type A string
        \\type B string
        \\func subAny(a any, b any) any { return a - b }
        \\func bad() any { return subAny(A("x"), B("y")) }
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("bad", &.{})) {
        .runtime_error => |e| {
            try std.testing.expectEqual(error.TypeError, e.kind);
            try std.testing.expect(std.mem.indexOf(u8, e.msg, "cannot apply '-' to A and B") != null);
        },
        .ok => return error.ExpectedTypeError,
    }
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

test "compiler: std.bytes.replace is a no-op when the pattern is not found" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\b := std.bytes
        \\data := b.pack([65, 66, 67, 66, 67])
        \\assert b.replace(data, b.pack([90]), b.pack([88])) == "ABCBC"
        \\assert b.replace(data, b.pack([90, 91]), "Z") == "ABCBC"
    );
}

// selectStdBytesDecodeIntrinsicOp (compiler.zig) recognizes std.bytes.at and
// every *_at decoder by exact direct-call name and fuses the call straight
// into the dedicated .bytes_decode VM opcode at the call site (see
// compiler_expr.zig), bypassing native/bytes.zig's dispatch() entirely --
// exactly like std.math's abs/sqrt/etc intrinsics above. Every existing
// `b.u16be_at(...)`-shaped test in this file therefore exercises only
// decodeAt() (shared with the VM op) and never bytes.zig's own
// .bytes_at/.bytes_u16be_at/.../.bytes_f64le_at dispatch arms. Binding the
// function to a global first (`f := std.bytes.at`) makes the subsequent
// `f(...)` an indirect call through a function value, which the intrinsic
// selector never sees (it matches by direct-call name only) -- this reaches
// bytes.zig's real dispatch for the big-endian half of the decode family.
test "compiler: std.bytes big-endian decode functions (at/u16be_at/u16le_at/u32be_at/u64be_at/f32be_at/f64be_at) reach bytes.zig's real native dispatch via indirect call" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\data := std.bytes.u8(0x12) + std.bytes.u16be(0x3456) + std.bytes.u32be(0x789ABCDE) + std.bytes.u64be(0x0102030405060708) + std.bytes.f32be(3.5) + std.bytes.f64be(2.5)
        \\at_fn := std.bytes.at
        \\u16be_at_fn := std.bytes.u16be_at
        \\u16le_at_fn := std.bytes.u16le_at
        \\u32be_at_fn := std.bytes.u32be_at
        \\u64be_at_fn := std.bytes.u64be_at
        \\f32be_at_fn := std.bytes.f32be_at
        \\f64be_at_fn := std.bytes.f64be_at
        \\assert at_fn(data, 0) == 0x12
        \\assert u16be_at_fn(data, 1) == 0x3456
        \\assert u16le_at_fn(data, 1) == 0x5634
        \\assert u32be_at_fn(data, 3) == 0x789ABCDE
        \\assert u64be_at_fn(data, 7) == 0x0102030405060708
        \\assert f32be_at_fn(data, 15) == 3.5
        \\assert f64be_at_fn(data, 19) == 2.5
    );
}

// Same as above but for the little-endian half of the decode family
// (u16le_at/u32le_at/u64le_at/f32le_at/f64le_at), reusing the exact data
// layout and offsets already proven correct by the fused-op round-trip test
// ("std.bytes little-endian encoders round-trip through their _at
// decoders") so only the dispatch path under test is new, not the byte
// arithmetic.
test "compiler: std.bytes little-endian decode functions (u16le_at/u32le_at/u64le_at/f32le_at/f64le_at) reach bytes.zig's real native dispatch via indirect call" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\data := std.bytes.u16le(0x1234) + std.bytes.u32le(0x89ABCDEF) + std.bytes.u64le(0x0102030405060708) + std.bytes.f32le(3.5) + std.bytes.f64le(2.5)
        \\u16le_at_fn := std.bytes.u16le_at
        \\u32le_at_fn := std.bytes.u32le_at
        \\u64le_at_fn := std.bytes.u64le_at
        \\f32le_at_fn := std.bytes.f32le_at
        \\f64le_at_fn := std.bytes.f64le_at
        \\assert u16le_at_fn(data, 0) == 0x1234
        \\assert u32le_at_fn(data, 2) == 0x89ABCDEF
        \\assert u64le_at_fn(data, 6) == 0x0102030405060708
        \\assert f32le_at_fn(data, 14) == 3.5
        \\assert f64le_at_fn(data, 18) == 2.5
    );
}

test "compiler: std.bytes.at raises RangeError via the real native dispatch (indirect call), not just the fused decode op" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\data := std.bytes.u8(0x12)
        \\func atOOB() int {
        \\    f := std.bytes.at
        \\    return f(data, 9999)
        \\}
        \\func atNeg() int {
        \\    f := std.bytes.at
        \\    return f(data, -1)
        \\}
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("atOOB", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("atNeg", &.{}));
}

// argAsI64 (native/bytes.zig) raises TypeError for any argument that is
// neither .int nor .float; module_descriptor.zig's bytesExports entries
// carry no per-parameter type, so the compiler does not reject a
// non-numeric argument at compile time -- it reaches this runtime check.
test "compiler: std.bytes.u8 raises TypeError (not a crash) on a non-numeric argument" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func viaStr() string { return std.bytes.u8("x") }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("viaStr", &.{}));
}

// bytes_slice's fast path returns a zero-copy string_view when the source is
// already a GC object (.dyn_string/.string_view); a plain string literal is
// a .string value with no object header, so it falls through to the slow
// path that copies via makeBinaryString. None of the slice tests above ever
// pass a literal directly (they all build the source via b.u8(...)
// concatenation, which allocates a dyn_string), so this path was unexercised.
test "compiler: std.bytes.slice copies an immortal string-literal source instead of viewing it" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func validSlice() string { return std.bytes.slice("ABCDE", 1, 4) }
        \\func negFrom() string { return std.bytes.slice("ABCDE", -1, 2) }
        \\func toGreaterLen() string { return std.bytes.slice("ABCDE", 0, 99) }
        \\func fromGreaterTo() string { return std.bytes.slice("ABCDE", 3, 1) }
    );
    const valid = try rt.callGlobal("validSlice", &.{});
    try std.testing.expectEqualStrings("BCD", try vms.asStringValue(valid));
    try std.testing.expectError(error.RangeError, rt.callGlobal("negFrom", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("toGreaterLen", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("fromGreaterTo", &.{}));
}

// bytes_slice's .string_view branch (a slice of an existing slice) chases
// through sv.source to the owning dyn_string rather than re-slicing the view
// itself directly -- exercised here by slicing an already-sliced value.
test "compiler: std.bytes.slice on a string_view (a slice of a slice) chases through to the owning object" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() string {
        \\    base := std.bytes.u8(0x41) + std.bytes.u8(0x42) + std.bytes.u8(0x43) + std.bytes.u8(0x44) + std.bytes.u8(0x45)
        \\    view := base[1:4]
        \\    return std.bytes.slice(view, 1, 2)
        \\}
    );
    const v = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("C", try vms.asStringValue(v));
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

// ── Local/upvalue const-shadowing (resolveLocalConst / resolveUpvalueConst) ─
//
// ensureMutableBinding checks resolveLocalConst before resolveUpvalueConst
// before the global-const path (registry.hasGlobalConst) — all three raise
// the same AssignToConst error via constAssignErr, but only the global path
// had dedicated compiler_test.zig coverage before this.

test "compiler: assigning to a function-local const is a distinct AssignToConst error from the global-const path" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func f() int {
        \\    const x = 1
        \\    x = 2
        \\    return x
        \\}
    );
    try std.testing.expectEqual(error.AssignToConst, r.err);
    try std.testing.expectEqual(@as(u32, 3), r.line);
    try std.testing.expectEqualStrings("cannot assign to const variable 'x'", r.msg);

    var rt2 = try setup();
    defer rt2.deinit();
    try std.testing.expectError(error.AssignToConst, rt2.run(
        \\func f() int {
        \\    const x = 1
        \\    x = 2
        \\    return x
        \\}
    ));
}

test "compiler: assigning to an outer function's const captured as an upvalue is AssignToConst" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func outer() func() int {
        \\    const c = 1
        \\    return func() int {
        \\        c = 2
        \\        return c
        \\    }
        \\}
    );
    try std.testing.expectEqual(error.AssignToConst, r.err);
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

// ── Compile-time call-arg / struct-field type compatibility checks ─────────
//
// checkDirectCallArgCompatibility (direct-call arguments) and
// checkFieldValueCompatibility (struct-literal field values) are the
// compiler's own narrow, conservative COMPILE-TIME rejection of a
// provably-wrong scalar/named/struct/variant value — distinct from
// argProvenForParam's "proven" bit above, which only ever *skips* the
// runtime check and never itself raises an error. These fire only when the
// static type is fully known (single-alt spec, tracked ExprPrimInfo);
// anything the compiler can't pin down is deferred to the runtime
// enforceFuncArgTypes / opSetField checks instead.

test "compiler: a direct call with a provably-wrong scalar argument type is a compile-time TypeError" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func takeInt(a int) int { return a }
        \\x := takeInt("hello")
    );
    try std.testing.expectEqual(error.TypeError, r.err);
    try std.testing.expectEqualStrings("cannot pass string to parameter of type int; convert explicitly", r.msg);
}

test "compiler: passing an erased named-type value to a plain scalar parameter is a compile-time TypeError" {
    // Meters is erased (int-based) — its own arithmetic still requires an
    // explicit unwrap (see setCurrentExprPrimResult's erased-scalar checks),
    // and checkDirectCallArgCompatibility enforces the same rule at a direct
    // call site: arg_info.named_type is checked before arg_info.prim, so a
    // named carrier is always rejected even though its underlying base
    // matches.
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Meters int
        \\func takeInt(a int) int { return a }
        \\m := Meters(5)
        \\x := takeInt(m)
    );
    try std.testing.expectEqual(error.TypeError, r.err);
    try std.testing.expectEqualStrings("cannot pass Meters to parameter of type int; convert explicitly", r.msg);
}

test "compiler: passing the wrong specific named type to a named-typed parameter is a compile-time TypeError" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Meters int
        \\type Feet int
        \\func takeMeters(a Meters) Meters { return a }
        \\f := Feet(5)
        \\x := takeMeters(f)
    );
    try std.testing.expectEqual(error.TypeError, r.err);
    try std.testing.expectEqualStrings("cannot pass Feet to parameter of type Meters", r.msg);
}

test "compiler: passing the wrong struct type to a struct-typed parameter is a compile-time TypeError" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type A struct { v int }
        \\type B struct { v int }
        \\func takeA(a A) A { return a }
        \\b := B{v:1}
        \\x := takeA(b)
    );
    try std.testing.expectEqual(error.TypeError, r.err);
    try std.testing.expectEqualStrings("cannot pass B to parameter of type A", r.msg);
}

test "compiler: passing the wrong variant type to a variant-typed parameter is a compile-time TypeError" {
    // The value's variant_type is only tracked on a LOCAL binding (a
    // top-level `:=` global has no variant-type tracking table — unlike the
    // named/struct cases above, which do — see inferred_named_global_*/
    // inferred_struct_global_* vs. the absence of an inferred_variant_global
    // equivalent), so this needs the assignment inside a function body.
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Shape variant { circle(float), square(float) }
        \\type Color variant { name(string) }
        \\func takeShape(s Shape) Shape { return s }
        \\func bad() Shape {
        \\    c := Color.name("red")
        \\    return takeShape(c)
        \\}
    );
    try std.testing.expectEqual(error.TypeError, r.err);
    try std.testing.expectEqualStrings("cannot pass Color to parameter of type Shape", r.msg);
}

// Regression: checkDirectCallArgCompatibility's scalar arm had no rune
// exception, unlike its two siblings that handle the exact same
// "rune value flowing into an int/float-shaped slot" situation:
//   - checkFieldValueCompatibility (this file, below) explicitly special-
//     cases `(alt.typ == .int or .float) and arg_p == .rune` before
//     raising StructFieldTypeMismatch, with a comment explaining runtime
//     parity requires it (vm_types.matchesTypeAlt's .int/.float arms are
//     `v == .int or v == .rune` / `v == .float or v == .rune`).
//   - argProvenForParam's own .int/.float arms explicitly accept
//     `p == .rune` ("VM accepts rune in int context").
// checkDirectCallArgCompatibility's .int/.float arm was missing that same
// exception, so a call site the runtime would happily accept (and that
// argProvenForParam already agreed was fine) was instead rejected at
// compile time. Fixed by adding the identical exception.
//
// Rune literals are backtick-delimited (`` `A` ``, see
// tests/spec/045_rune_literals.gengo) — single/double quotes both lex as
// plain strings. The literal is passed directly (rather than through a
// `:=` local) so its ExprPrimInfo.prim is actually tracked at the call
// site: a plain "x := `A`" local's type_check stays `.none` (varDecl's
// `:=` inference only tracks named/struct/variant results, not bare
// prim kinds), so routing it through a local first would leave
// arg_info.prim unset and never reach the fixed comparison at all.
test "compiler: a rune argument is accepted by a direct call's int/float parameter, same as struct fields and proven args" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func takeInt(a int) int { return a }
        \\func takeFloat(a float) float { return a }
        \\func viaInt() int { return takeInt(`A`) }
        \\func viaFloat() float { return takeFloat(`A`) }
    );
    // `A` is rune U+0041 = 65. Neither the int nor the float parameter
    // forces an actual representation conversion -- the value stays
    // .rune-tagged throughout (confirmed via std.core.type_of), matching
    // matchesTypeAlt's accept-without-coerce semantics; only the compile-time
    // TYPE CHECK is being tested here, not a numeric conversion.
    try std.testing.expectEqual(@as(u21, 65), (try rt.callGlobal("viaInt", &.{})).rune);
    try std.testing.expectEqual(@as(u21, 65), (try rt.callGlobal("viaFloat", &.{})).rune);
}

test "compiler: a provably-wrong scalar struct-field value is a compile-time StructFieldTypeMismatch" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Point struct { x int }
        \\func mk() Point { return Point{x: "no"} }
    );
    try std.testing.expectEqual(error.StructFieldTypeMismatch, r.err);
    try std.testing.expectEqualStrings("cannot assign string to field 'x' of type int; convert explicitly", r.msg);
}

test "compiler: assigning an erased named-type value to a plain scalar struct field is a compile-time StructFieldTypeMismatch" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Meters int
        \\type Point struct { x int }
        \\func mk() Point {
        \\    m := Meters(5)
        \\    return Point{x: m}
        \\}
    );
    try std.testing.expectEqual(error.StructFieldTypeMismatch, r.err);
    try std.testing.expectEqualStrings("cannot assign Meters to field 'x' of type int; convert explicitly", r.msg);
}

test "compiler: assigning the wrong specific named type to a named-typed struct field is a compile-time StructFieldTypeMismatch" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Meters int
        \\type Feet int
        \\type Distance struct { d Meters }
        \\func mk() Distance {
        \\    f := Feet(5)
        \\    return Distance{d: f}
        \\}
    );
    try std.testing.expectEqual(error.StructFieldTypeMismatch, r.err);
    try std.testing.expectEqualStrings("cannot assign Feet to field 'd' of type Meters", r.msg);
}

test "compiler: assigning the wrong struct type to a struct-typed struct field is a compile-time StructFieldTypeMismatch" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type A struct { v int }
        \\type B struct { v int }
        \\type Wrap struct { inner A }
        \\func mk() Wrap {
        \\    b := B{v:1}
        \\    return Wrap{inner: b}
        \\}
    );
    try std.testing.expectEqual(error.StructFieldTypeMismatch, r.err);
    try std.testing.expectEqualStrings("cannot assign B to field 'inner' of type A", r.msg);
}

test "compiler: assigning the wrong variant type to a variant-typed struct field is a compile-time StructFieldTypeMismatch" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Shape variant { circle(float) }
        \\type Color variant { name(string) }
        \\type Wrap struct { s Shape }
        \\func mk() Wrap {
        \\    c := Color.name("red")
        \\    return Wrap{s: c}
        \\}
    );
    try std.testing.expectEqual(error.StructFieldTypeMismatch, r.err);
    try std.testing.expectEqualStrings("cannot assign Color to field 's' of type Shape", r.msg);
}

test "compiler: a rune value assigned to an int-typed struct field is accepted (checkFieldValueCompatibility's rune exception)" {
    // checkFieldValueCompatibility has always had this rune exception;
    // checkDirectCallArgCompatibility was missing the identical exception
    // until it was fixed (see the direct-call rune test above). The rune
    // literal is written directly as the field value (see that test's note
    // on why a `:=` local wouldn't keep its prim tracked) so arg_info.prim
    // is actually `.rune` when checkFieldValueCompatibility runs.
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Point struct { x int }
        \\func mk() Point {
        \\    return Point{x: `A`}
        \\}
    );
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

// Coverage-audit 2026-09: vm.zig's `inc_global_const_loop`/
// `inc_global_const_loop_nc` dispatch handlers (the loop-back-edge variants
// of `inc_global_const`, closing an upvalue first when the loop var is
// captured) had no test at all — every existing `inc_global_const`/
// `set_global_loop` fusion test above uses `g = i` (plain assignment) or a
// non-last-statement compound-add, never `g = g + <const>` as the loop's
// own last statement. Per fusion_pass.zig's pairFusionFull: `inc_global_const`
// (itself `get_global_const_add` + `set_global`, same name) fused with a
// following `close_upvalue_loop` becomes `inc_global_const_loop`; fused with
// a following bare `loop` (uncaptured loop var, no close_upvalue) becomes
// `inc_global_const_loop_nc`.
test "fusion: global compound-add as a loop's last statement (uncaptured loop var) fuses to inc_global_const_loop_nc" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\g := 0
        \\func loopGlobalInc(n int) int {
        \\    i := 0
        \\    for i < n {
        \\        i = i + 1
        \\        g = g + 1
        \\    }
        \\    return g
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .inc_global_const_loop_nc));
}

test "fusion: global compound-add as a loop's last statement (captured loop var) fuses to inc_global_const_loop" {
    // The closure must NOT be bound to a named local (`f := func...`) —
    // that local's own end-of-iteration scope-exit `pop` lands between
    // `g = g + 1`'s `inc_global_const` and `close_upvalue_loop`, breaking
    // the adjacency pairFusionFull requires (confirmed by disassembling
    // both shapes: a named-local closure leaves `inc_global_const; pop;
    // close_upvalue_loop`, three separate ops; passing the closure as a
    // bare call argument — consumed immediately, no local slot — leaves
    // `inc_global_const` directly adjacent to `close_upvalue_loop`).
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\g := 0
        \\func consume(fn func() int) int { return fn() }
        \\func loopGlobalIncCaptured(n int) int {
        \\    for i := 0; i < n; i++ {
        \\        consume(func() int { return i })
        \\        g = g + 1
        \\    }
        \\    return g
        \\}
    );
    const c = rt.chunk_state;
    try std.testing.expectEqual(@as(usize, 1), countOp(c, .inc_global_const_loop));
}

test "fusion: inc_global_const_loop and inc_global_const_loop_nc both give correct results" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\g := 0
        \\func loopGlobalInc(n int) int {
        \\    i := 0
        \\    for i < n {
        \\        i = i + 1
        \\        g = g + 1
        \\    }
        \\    return g
        \\}
    );
    const r1 = try rt.callGlobal("loopGlobalInc", &.{.{ .int = 5 }});
    try std.testing.expect(r1 == .int and r1.int == 5);

    try runSrc(&rt,
        \\g := 0
        \\func consume(fn func() int) int { return fn() }
        \\func loopGlobalIncCaptured(n int) int {
        \\    for i := 0; i < n; i++ {
        \\        consume(func() int { return i })
        \\        g = g + 1
        \\    }
        \\    return g
        \\}
    );
    const r2 = try rt.callGlobal("loopGlobalIncCaptured", &.{.{ .int = 4 }});
    try std.testing.expect(r2 == .int and r2.int == 4);
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

// ── Named-type range 'cycle' mode (vm_types.zig's wrapCycleValue/
// wrapCycleValueWithError/wrapDecimalCycle) ─────────────────────────────────
//
// Grepped this file for "cycle"/"cyclic"/"Hour"/"Degrees" before writing
// these: the 'cycle' modifier (docs/language.md's `type Hour int cycle
// 0..23` / `type Degrees float cycle 0.0..360.0`) had zero test coverage
// anywhere in this suite, despite 'range' and 'clamp' both being well
// exercised. Covers the discrete-vs-continuous distinction wrapCycleValue's
// own doc comment describes: an int cycle's domain is the inclusive
// `max - min + 1` step count (so `cycle 0..23` wraps 24 back to 0), while a
// float/decimal cycle identifies its endpoints (so `max` itself wraps to
// `min`) — and a value that needs to wrap more than once around the domain
// in either direction, not just one step past a boundary.

test "compiler: named int cycle type wraps multiple times around its discrete domain, both directions" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Hour int cycle 0..23
        \\func h(x int) int { return int(Hour(x)) }
    );
    // 75 = 3*24 + 3: wraps around exactly three times before landing on 3.
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("h", &.{.{ .int = 75 }})).int);
    // Exactly one full domain past the top wraps back to the bottom.
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("h", &.{.{ .int = 24 }})).int);
    // A negative value wraps into the positive range (floored-mod, not
    // truncated-mod: -25 is one full domain plus 23 below zero).
    try std.testing.expectEqual(@as(i64, 23), (try rt.callGlobal("h", &.{.{ .int = -25 }})).int);
    // A value within range is untouched.
    try std.testing.expectEqual(@as(i64, 10), (try rt.callGlobal("h", &.{.{ .int = 10 }})).int);
}

test "compiler: named float cycle type is continuous — endpoints identified, wraps multiple times, both directions" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Degrees float cycle 0.0..360.0
        \\func d(x float) float { return float(Degrees(x)) }
    );
    // Continuous: max itself (not max+epsilon) wraps to min.
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("d", &.{.{ .float = 360.0 }})).float, 1e-9);
    // 750 = 2*360 + 30: wraps around twice.
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), (try rt.callGlobal("d", &.{.{ .float = 750.0 }})).float, 1e-9);
    // Negative input wraps into the positive range.
    try std.testing.expectApproxEqAbs(@as(f64, 330.0), (try rt.callGlobal("d", &.{.{ .float = -30.0 }})).float, 1e-9);
}

test "compiler: named decimal cycle type wraps via wrapDecimalCycle, both directions" {
    // wrapDecimalCycle is only reachable through a decimal-based named type
    // with a 'cycle' modifier — distinct from wrapCycleValue's plain
    // int/float paths since it must rescale through the fixed-point factor.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type AngleD decimal 2 cycle 0.0..360.0
        \\func wrapsForward() bool { return AngleD(750.0) == AngleD(30.0) }
        \\func wrapsBackward() bool { return AngleD(-30.0) == AngleD(330.0) }
        \\func endpointIdentified() bool { return AngleD(360.0) == AngleD(0.0) }
        \\func inRangeUnchanged() bool { return AngleD(45.5) == AngleD(45.5) }
    );
    try std.testing.expect((try rt.callGlobal("wrapsForward", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("wrapsBackward", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("endpointIdentified", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("inRangeUnchanged", &.{})).boolean);
}

// ── Named-type succ/pred (applyNamedTypeFn) across all three range modes ───

test "compiler: succ/pred on a plain range type raises RangeError at both boundaries, not just succ" {
    // The existing "named type succ/pred re-enforces the predicate" test
    // above only exercises the predicate-failure path; the plain
    // out-of-bounds RangeError path (applyNamedTypeFn's non-cycle,
    // non-clamp 'else' branch) had no direct test at either boundary.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Step int range 1..100
        \\func succAtMax() int { return Step.succ(Step(100)) }
        \\func predAtMin() int { return Step.pred(Step(1)) }
        \\func succOk() int { return int(Step.succ(Step(50))) }
        \\func predOk() int { return int(Step.pred(Step(50))) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("succAtMax", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("predAtMin", &.{}));
    try std.testing.expectEqual(@as(i64, 51), (try rt.callGlobal("succOk", &.{})).int);
    try std.testing.expectEqual(@as(i64, 49), (try rt.callGlobal("predOk", &.{})).int);
}

test "compiler: succ/pred wraps on a cycle type at both boundaries, for int and float bases" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Hour int cycle 0..23
        \\type Degrees float cycle 0.0..360.0
        \\func hourSucc() int { return int(Hour.succ(Hour(23))) }
        \\func hourPred() int { return int(Hour.pred(Hour(0))) }
        \\func degSucc() float { return float(Degrees.succ(Degrees(359.5))) }
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("hourSucc", &.{})).int);
    try std.testing.expectEqual(@as(i64, 23), (try rt.callGlobal("hourPred", &.{})).int);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), (try rt.callGlobal("degSucc", &.{})).float, 1e-9);
}

test "compiler: succ/pred saturates on a clamp type at both boundaries" {
    // Only the succ-at-max saturation case was documented/exercised
    // (docs/language.md's Bounded.succ(Bounded(100)) example) — pred at the
    // lower boundary (applyNamedTypeFn's is_clamp branch called from the
    // 'pred' direction) had no test.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Bounded int clamp 1..100
        \\func succAtMax() int { return int(Bounded.succ(Bounded(100))) }
        \\func predAtMin() int { return int(Bounded.pred(Bounded(1))) }
    );
    try std.testing.expectEqual(@as(i64, 100), (try rt.callGlobal("succAtMax", &.{})).int);
    try std.testing.expectEqual(@as(i64, 1), (try rt.callGlobal("predAtMin", &.{})).int);
}

// Regression: applyNamedTypeFn's non-cycle, non-clamp 'else' branch
// rejected an out-of-bounds succ/pred result with
// `if (result < nt.min or result > nt.max)` — but IEEE-754 NaN compares
// false against everything, in both directions. wrapCycleValue and
// clampValue both already defend against this explicitly (`if
// (!std.math.isFinite(n)) return error.RangeError`), but the plain-range
// 'else' branch had no such guard, and applyNamedTypeFn's own earlier
// `result == n` early-out didn't catch it either (NaN != NaN, so
// `NaN + 1.0 == NaN` is also false). The net effect: calling `.succ()` or
// `.pred()` on a plain range-constrained named type with a NaN argument
// silently returned NaN as if it were a valid instance of that type,
// instead of raising RangeError the way every other out-of-bounds value
// does. Fixed by adding an explicit `!std.math.isFinite(result)` check
// alongside the existing `result == n` one.
test "compiler: succ/pred on a plain range type rejects a NaN argument with RangeError" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Ratio float range 0.0..1.0
        \\func succNan() float { return float(Ratio.succ(std.math.nan())) }
        \\func predNan() float { return float(Ratio.pred(std.math.nan())) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("succNan", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("predNan", &.{}));
}

// ── Runtime coercion of a type-erased value into a named-type/interface
// parameter (coerceErasedValueForSpec/reifyErasedNamedInterfaceArg) ────────
//
// coerceErasedValueForSpec's .named_t branch (a bare scalar reaching a
// parameter declared as a specific named type) is already exercised
// throughout this file via rt.callGlobal's raw-Value call boundary. Its
// .interface_t branch (reifyErasedNamedInterfaceArg) is the rarer case: a
// BARE scalar (not yet wrapped in any named_value) reaching a parameter
// declared as an interface type. It scans every declared named type whose
// base matches the bare value's runtime tag, tries wrapping the value as
// each candidate, and keeps a match only if it's unique — ambiguous (more
// than one candidate satisfies the interface) is treated as "can't
// reify", not "pick one".
test "compiler: a bare int reaching an interface-typed parameter is uniquely reified into the one named type that satisfies it" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Meters int
        \\type Decoy1 int
        \\type Decoy2 int
        \\func (m Meters) doubled() Meters { return Meters(int(m) * 2) }
        \\type HasDouble interface { doubled() Meters }
        \\func accept(h HasDouble) int { return int(h.doubled()) }
        \\func viaBareInt() int { return accept(7) }
    );
    // 7 is a bare int literal, not Meters(7) — accept's parameter is typed
    // HasDouble (an interface), so the compiler cannot prove this call site
    // (checkDirectCallArgCompatibility has no case for interface_t) and it
    // falls to the runtime, which must reify 7 into Meters (the only
    // int-based named type implementing doubled() with this signature —
    // Decoy1/Decoy2 exist to prove the scan doesn't just grab the first
    // int-based type it finds) before the call can proceed.
    try std.testing.expectEqual(@as(i64, 14), (try rt.callGlobal("viaBareInt", &.{})).int);
}

test "compiler: a bare int reaching an interface-typed parameter is a runtime TypeError when reification is ambiguous" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Meters int
        \\type Kilometers int
        \\func (m Meters) doubled() Meters { return Meters(int(m) * 2) }
        \\func (k Kilometers) doubled() Meters { return Meters(int(k) * 2) }
        \\type HasDouble interface { doubled() Meters }
        \\func accept(h HasDouble) int { return int(h.doubled()) }
        \\func viaBareInt() int { return accept(7) }
    );
    // Both Meters and Kilometers are int-based and both implement
    // `doubled() Meters` — reifyErasedNamedInterfaceArg finds two matches,
    // refuses to guess, and returns null; the bare int then fails
    // matchesTypeSpec against the interface_t alt outright (a plain .int
    // Value is never == .object), surfacing as a runtime TypeError rather
    // than a compile-time one.
    try std.testing.expectError(error.TypeError, rt.callGlobal("viaBareInt", &.{}));
}

// ── Indirect calls (function value/closure) force the runtime enforcement
// path, since the compiler cannot statically know which callee a func-typed
// local actually holds at a given call site ────────────────────────────────

test "compiler: an indirect call through a function-typed parameter enforces argument types at runtime, not compile time" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func typed(x int) int { return x + 1 }
        \\func callIt(f func(int) int, v any) int { return f(v) }
        \\func viaGoodValue() int { return callIt(typed, 41) }
        \\func viaBadValue() int { return callIt(typed, "oops") }
    );
    // f(v) is a call through a local (a func-typed parameter), not a
    // direct named call — checkDirectCallArgCompatibility never runs for
    // it (it only fires for a statically known callee), so a wrong-typed
    // v must still be caught by enforceFuncArgTypes/enforcePrimitiveFuncArgTypes
    // at the actual call, exactly as if the mismatch had come from an
    // external Zig-side rt.callGlobal.
    try std.testing.expectEqual(@as(i64, 42), (try rt.callGlobal("viaGoodValue", &.{})).int);
    try std.testing.expectError(error.TypeError, rt.callGlobal("viaBadValue", &.{}));
}

// ── constructNamedType's TypeError/RangeError message-formatting branches
// on int/float/rune bases — none of these specific "wrong incoming type" or
// "value too large to represent" paths (as opposed to the has_range
// out-of-bounds paths, which are well covered) had any test anywhere in
// this file.

test "compiler: constructing a named int or float type from an incompatible type raises TypeError with a descriptive message" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Meters int
        \\type Speed float
        \\func badInt() int { return int(Meters(true)) }
        \\func badFloat() float { return float(Speed(true)) }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("badInt", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("badFloat", &.{}));
}

test "compiler: constructing an unranged named int type from a float too large to fit in i64 raises RangeError" {
    // Distinct from the has_range out-of-bounds RangeError path: this one
    // fires from constructNamedType's final floatToIntSafe conversion
    // (setNamedConversionError), reached only when there's no declared
    // range to catch the value first.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type BigInt int
        \\func bad() int { return int(BigInt(1e300)) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("bad", &.{}));
}

test "compiler: constructing a named rune type from a non-finite float raises RangeError" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Letter rune
        \\func bad() rune { return Letter(std.math.nan()) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("bad", &.{}));
}

test "compiler: constructing a plain (non-clamp) range-constrained named rune type out of bounds raises RangeError" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Grade rune range 65..90
        \\func bad() rune { return Grade(200) }
        \\func ok() rune { return Grade(70) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("bad", &.{}));
    try std.testing.expectEqual(@as(u21, 70), (try rt.callGlobal("ok", &.{})).rune);
}

test "compiler: a degenerate (single-point) cycle domain raises a cyclic-range RangeError, even for the boundary value itself" {
    // wrapCycleValue's continuous branch treats a zero-width span (min ==
    // max) as always out-of-bounds -- 'span <= 0' -- so even constructing
    // the type from its own min/max value fails, unlike every other cycle
    // domain. This exercises wrapCycleValueWithError's own error-message
    // branch (as opposed to wrapCycleValue's bare error return, which the
    // succ/pred/arithmetic call sites use instead).
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Degenerate float cycle 5.0..5.0
        \\func bad() float { return float(Degenerate(5.0)) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("bad", &.{}));
}

// coerceNamedTypeResult (as opposed to constructNamedType, which every test
// above this point exercises via a direct Type(x) call) is the arithmetic-
// result re-wrapping path: `a + b` on two cycle-typed operands must
// re-normalize the sum back into the cyclic domain, not just add the raw
// numbers.
test "compiler: arithmetic on a cycle-typed value re-wraps the result via coerceNamedTypeResult" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Hour int cycle 0..23
        \\type Degrees float cycle 0.0..360.0
        \\func hourWrap() int { return int(Hour(23) + Hour(2)) }
        \\func degWrap() float { return float(Degrees(350.0) + Degrees(20.0)) }
    );
    try std.testing.expectEqual(@as(i64, 1), (try rt.callGlobal("hourWrap", &.{})).int);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), (try rt.callGlobal("degWrap", &.{})).float, 1e-9);
}

test "compiler: a typed function call with a mixed primitive/non-inlinable-extra param list uses the slow enforceFuncArgTypes path and still validates correctly" {
    // canInlinePrimitiveArgs (vm_types.zig) only allows a function onto the
    // fast/inlined calling convention if EVERY param is either primitive
    // (isPrimitiveTypeSpec) or one of the inlinable extras (struct_t/
    // interface_t/variant_t — isInlinableExtraTypeSpec). A `[]int`-typed
    // param is neither (array specs are excluded from both sets), so a
    // function mixing one into an otherwise-primitive param list is
    // permanently on the slow path (enforceFuncArgTypes), never the warm
    // IC fast path (enforcePrimitiveFuncArgTypes) — this is a behavioral,
    // not a predicate-level, check: both a correct and an incorrect call
    // must be judged the same way the fast path judges pure-primitive
    // calls.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func mixedSlow(a int, xs []int, s string) int {
        \\    total := a
        \\    for v in xs { total += v }
        \\    return total
        \\}
        \\func callOk() int { return mixedSlow(10, [1, 2, 3], "hi") }
        \\func callBadArray() int { return mixedSlow(10, "not an array", "hi") }
    );
    try std.testing.expectEqual(@as(i64, 16), (try rt.callGlobal("callOk", &.{})).int);
    try std.testing.expectError(error.TypeError, rt.callGlobal("callBadArray", &.{}));
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

test "compiler: struct dunder __mul__ and __div__ compute correctly" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Vec2 struct { x float, y float }
        \\func (a Vec2) __mul__(b Vec2) Vec2 { return Vec2 { x: a.x * b.x, y: a.y * b.y } }
        \\func (a Vec2) __div__(b Vec2) Vec2 { return Vec2 { x: a.x / b.x, y: a.y / b.y } }
        \\func mulX() float {
        \\    a := Vec2 { x: 2.0, y: 3.0 }
        \\    b := Vec2 { x: 4.0, y: 5.0 }
        \\    return (a * b).x
        \\}
        \\func divX() float {
        \\    a := Vec2 { x: 10.0, y: 6.0 }
        \\    b := Vec2 { x: 2.0, y: 3.0 }
        \\    return (a / b).x
        \\}
    );
    const rmul = try rt.callGlobal("mulX", &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), rmul.float, 1e-9);
    const rdiv = try rt.callGlobal("divX", &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), rdiv.float, 1e-9);
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

    var src_buf: [768]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf,
        \\net := import("cap:net")
        \\func serve() string {{
        \\    l, err := net.listen("tcp", "127.0.0.1:{d}")
        \\    if err != null {{ return "listen error" }}
        \\    addr := l.local_addr()
        \\    l.set_accept_deadline(3000)
        \\    conn, aerr := l.accept()
        \\    if aerr != null {{ return "accept error" }}
        \\    data := conn.read(64)
        \\    conn.write("pong:" + data)
        \\    conn.close()
        \\    // Reading/writing a now-closed connection drives cap_net.zig's
        \\    // read/write error-mapping branches (pushCatchableNetError) —
        \\    // the results are discarded, only the dispatch path matters.
        \\    discarded_read := conn.read(1)
        \\    discarded_write := conn.write("x")
        \\    l.close()
        \\    return "ok:" + addr
        \\}}
    , .{port});

    switch (rt.run(src)) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("serve", &.{})) {
        .ok => |v| {
            const result = try vms.asStringValue(v);
            try std.testing.expect(std.mem.startsWith(u8, result, "ok:"));
            var port_buf: [8]u8 = undefined;
            const port_str = try std.fmt.bufPrint(&port_buf, ":{d}", .{port});
            try std.testing.expect(std.mem.endsWith(u8, result, port_str));
        },
        .runtime_error => return error.UnexpectedRuntimeError,
    }

    client.join();
    try std.testing.expect(connected.load(.seq_cst));
    try std.testing.expect(echoed.load(.seq_cst));
}

// Coverage-audit 2026-09: cap_net.zig's `.cap_net_listen` dispatch arm's own
// `net_state.netListen(...) catch { pushErrPairMsg(ctx, lastNetErr()); ... }`
// branch was untested — every existing listen()-failure test above stops at
// the scope/policy pre-checks (net.listen not granted / policy refused),
// never reaching net_state.netListen itself. Binding a raw socket to the
// port first forces a real EADDRINUSE out of the underlying POSIX bind(2)
// call net_state.netListen makes.
test "cap:net listen surfaces a real bind failure (port already in use) through pushErrPairMsg" {
    net_state.clearListenPolicyRules();
    _ = net_state.addListenPolicyRule(.allow, "*", 0);
    defer net_state.clearListenPolicyRules();

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{ "net", "net.listen" },
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    const port: u16 = 18454;
    const sock = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    try std.testing.expect(std.posix.errno(sock) == .SUCCESS);
    const fd: std.posix.socket_t = @intCast(sock);
    defer _ = std.posix.system.close(fd);
    var addr_storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
    const sa: *std.posix.sockaddr.in = @ptrCast(&addr_storage);
    sa.family = std.posix.AF.INET;
    sa.port = std.mem.nativeToBig(u16, port);
    sa.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
    try std.testing.expect(std.posix.errno(std.posix.system.bind(fd, @ptrCast(&addr_storage), @sizeOf(std.posix.sockaddr.in))) == .SUCCESS);
    try std.testing.expect(std.posix.errno(std.posix.system.listen(fd, 1)) == .SUCCESS);

    var src_buf: [256]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf,
        \\net := import("cap:net")
        \\func serve() bool {{
        \\    l, err := net.listen("tcp", "127.0.0.1:{d}")
        \\    return err != null
        \\}}
    , .{port});

    switch (rt.run(src)) {
        .ok => {},
        else => return error.CompileFailed,
    }
    switch (rt.call("serve", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
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

// Coverage-audit 2026-09: cap_env.zig's own tests call envGet/envListPosix
// directly, never through dispatch() — so the switch that routes
// cap_env_get/cap_env_list native-function IDs, pulls the arg off the VM
// stack, and pushes the result was entirely unexercised natively (only the
// WASM conformance runner's tests/spec/cap/004_env_import.gengo reaches it,
// and that runs under wasmtime, outside kcov's instrumentation). Driving it
// through a real compiled+run script is the same shape as the cap:fs
// round-trip test above.
test "cap:env get/list round-trip through dispatch(), including a missing key" {
    const cap_env = @import("lang/native/cap_env.zig");
    const entries = [_:null]?[*:0]const u8{"GENGO_COVERAGE_TEST_VAR=hello"};
    cap_env.setEnvironBlock(.{ .slice = &entries });
    defer cap_env.setEnvironBlock(.empty);

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"env"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\env := import("cap:env")
        \\func doGet() string {
        \\    return env.get("GENGO_COVERAGE_TEST_VAR")
        \\}
        \\func doGetMissing() bool {
        \\    return env.get("GENGO_COVERAGE_TEST_VAR_NOPE") == null
        \\}
        \\func doListLen() int {
        \\    std := import("std")
        \\    return std.core.len(env.list())
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    switch (rt.call("doGet", &.{})) {
        .ok => |v| try std.testing.expectEqualStrings("hello", try vms.asStringValue(v)),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doGetMissing", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    switch (rt.call("doListLen", &.{})) {
        .ok => |v| try std.testing.expectEqual(@as(i64, 1), v.int),
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
        \\func nonMapOpts() { r, e := http.fetch("http://x.invalid/", [1, 2, 3]) }
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    // badOpts (a bare int) trips the *outer* `arg1 switch (.object => ...,
    // else => TypeError)` guard; nonMapOpts (an array, which is a real
    // .object) instead reaches the inner `opts.* switch (.map/.map_managed/
    // .map_hashed => ..., else => TypeError)` — a distinct branch nothing
    // above exercises.
    const names = [_][]const u8{ "badMethod", "badBody", "badTimeout", "badHeaders", "badOpts", "nonMapOpts" };
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
        \\func doFetchBodyAndTimeout() int {
        \\    r, err := http.fetch("http://x.invalid/", {"method": "POST", "body": "abc", "timeout_ms": 5.0})
        \\    if err != null { return -1 }
        \\    return r.status
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

    // Exercises the "body" option's success path (only its TypeError arm
    // was covered above) and timeout_ms given as a *float* (5.0) — the
    // "int" arm was implicitly reachable via any successful fetch, but
    // nothing before this drove a float through the range-checked
    // float-to-i64 conversion.
    switch (rt.call("doFetchBodyAndTimeout", &.{})) {
        .ok => |v| try std.testing.expectEqual(@as(i64, 201), v.int),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqualStrings("POST", state.seen_method[0..state.seen_method_len]);
    try std.testing.expectEqual(@as(c_int, 3), state.seen_body_len); // "abc".len == 3
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

// matchesInterfaceType (vm_types.zig): the .native_function branch of its
// per-method switch, which only cap:net.Conn/Listener values can reach —
// their methods are registered as native_function objects under
// "@cap_type:net.Conn.<method>" keys (see main.zig's cap-module install
// code), never as Gengo function/closure objects. A Gengo-declared
// interface has no compile-time knowledge of that struct_type (it's built
// entirely at runtime by the capability installer, not through the normal
// struct-declaration registry), so structConformsToInterface can never
// prove conformance here and the call always falls back to the runtime
// check — unlike every other interface test in this file, which exercises
// user-defined struct methods (plain .function/.closure globals). The
// check is arity-only for natives (nf.arity includes the receiver, the
// interface method's arity does not): close()'s registered native arity is
// 1, matching a zero-arg interface method's arity + 1.
test "compiler: a cap:net Conn struct instance satisfies a Gengo interface via matchesInterfaceType's native-function arity check" {
    net_state.clearPolicyRules();
    _ = net_state.addPolicyRule(.allow, "*", 0);
    defer net_state.clearPolicyRules();

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"net"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\net := import("cap:net")
        \\type Closer interface { close() bool }
        \\func takeCloser(c Closer) bool { return true }
        \\func doDialAndCheckInterface() bool {
        \\    conn := net.dial("tcp", "example.com:443")
        \\    ok := takeCloser(conn)
        \\    conn.close()
        \\    return ok
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    var state = FakeCapNetState{};
    net_state.setNetHandlers(fake_cap_net_handlers, @ptrCast(&state));
    defer net_state.resetHandlers();

    switch (rt.call("doDialAndCheckInterface", &.{})) {
        .ok => |v| try std.testing.expect(v.boolean),
        .runtime_error => return error.UnexpectedRuntimeError,
    }
    try std.testing.expectEqual(@as(u32, 1), state.close_calls);
}

// The mirror of the test above: an interface requiring an arity the native
// method doesn't have (close(x int), arity 2) must fail conformance — the
// `if (nf.arity != m.arity + 1) return false;` branch actually returning
// false, surfacing as a TypeError at the call site rather than silently
// accepting.
test "compiler: a cap:net Conn struct instance fails a Gengo interface whose method arity doesn't match the native arity" {
    net_state.clearPolicyRules();
    _ = net_state.addPolicyRule(.allow, "*", 0);
    defer net_state.clearPolicyRules();

    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .capabilities = &.{"net"},
        .allocator = std.testing.allocator,
    });
    defer rt.deinit();

    switch (rt.run(
        \\net := import("cap:net")
        \\type BadCloser interface { close(x int) bool }
        \\func takeBadCloser(c BadCloser) bool { return true }
        \\func doDialAndCheckBadInterface() bool {
        \\    conn := net.dial("tcp", "example.com:443")
        \\    return takeBadCloser(conn)
        \\}
    )) {
        .ok => {},
        else => return error.CompileFailed,
    }

    var state = FakeCapNetState{};
    net_state.setNetHandlers(fake_cap_net_handlers, @ptrCast(&state));
    defer net_state.resetHandlers();

    switch (rt.call("doDialAndCheckBadInterface", &.{})) {
        .ok => return error.TestUnexpectedResult,
        .runtime_error => |e| try std.testing.expectEqual(error.TypeError, e.kind),
    }
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

// The 10 functions selectStdMathUnaryIntrinsicOp/BinaryIntrinsicOp/
// TernaryIntrinsicOp (compiler.zig) recognize by exact direct-call name --
// abs, sqrt, floor, ceil, trunc, round, sign, min, max, clamp -- are
// compiled straight to a dedicated VM opcode (.abs, .sqrt, etc.) at the
// call site itself, NOT the fusion pass (confirmed empirically: `gengo
// disasm --no-fusion` still emits the same intrinsic opcode). Every
// existing `std.math.sqrt(x)`-shaped test in this file therefore actually
// exercises vm.zig's opcode handler, never math.zig's own
// `.math_sqrt`/`.math_abs`/etc. dispatch arms -- which is why math.zig's
// coverage never moved no matter how many direct-call tests were added.
// The intrinsic recognition only fires for a call the compiler can prove
// is a DIRECT reference to that exact global by name; binding the function
// to a local first (`f := std.math.sqrt`) makes the subsequent `f(x)` an
// INDIRECT call through a function value, which the intrinsic selectors
// never see -- confirmed via disasm to compile to a plain `call`, reaching
// math.zig's real native dispatch. This test forces exactly that for all
// 10 otherwise-unreachable-from-native-code functions.
test "compiler: std.math intrinsic-shadowed functions (abs/sqrt/floor/ceil/trunc/round/sign/min/max/clamp) reach math.zig's real dispatch via indirect call" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func viaAbsInt() int { f := std.math.abs; return f(-7) }
        \\func viaAbsFloat() float { f := std.math.abs; return f(-2.5) }
        \\func viaAbsMinIntOverflow() int { f := std.math.abs; return f(-9223372036854775808) }
        \\func viaSqrtOk() float { f := std.math.sqrt; return f(16.0) }
        \\func viaSqrtNeg() float { f := std.math.sqrt; return f(-1.0) }
        \\func viaFloor() float { f := std.math.floor; return f(3.7) }
        \\func viaCeil() float { f := std.math.ceil; return f(3.2) }
        \\func viaTrunc() float { f := std.math.trunc; return f(-3.7) }
        \\func viaRound() float { f := std.math.round; return f(3.5) }
        \\func viaSignInt() int { f := std.math.sign; return f(-42) }
        \\func viaSignFloatZero() float { f := std.math.sign; return f(0.0) }
        \\func viaMinInt() int { f := std.math.min; return f(3, 7) }
        \\func viaMaxFloat() float { f := std.math.max; return f(3.5, 7.5) }
        \\func viaClamp() float { f := std.math.clamp; return f(20, 1, 10) }
    );
    try std.testing.expectEqual(@as(i64, 7), (try rt.callGlobal("viaAbsInt", &.{})).int);
    try std.testing.expectEqual(@as(f64, 2.5), (try rt.callGlobal("viaAbsFloat", &.{})).float);
    try std.testing.expectError(error.RangeError, rt.callGlobal("viaAbsMinIntOverflow", &.{}));
    try std.testing.expectEqual(@as(f64, 4.0), (try rt.callGlobal("viaSqrtOk", &.{})).float);
    try std.testing.expectError(error.RangeError, rt.callGlobal("viaSqrtNeg", &.{}));
    try std.testing.expectEqual(@as(f64, 3.0), (try rt.callGlobal("viaFloor", &.{})).float);
    try std.testing.expectEqual(@as(f64, 4.0), (try rt.callGlobal("viaCeil", &.{})).float);
    try std.testing.expectEqual(@as(f64, -3.0), (try rt.callGlobal("viaTrunc", &.{})).float);
    try std.testing.expectEqual(@as(f64, 4.0), (try rt.callGlobal("viaRound", &.{})).float);
    try std.testing.expectEqual(@as(i64, -1), (try rt.callGlobal("viaSignInt", &.{})).int);
    try std.testing.expectEqual(@as(f64, 0.0), (try rt.callGlobal("viaSignFloatZero", &.{})).float);
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("viaMinInt", &.{})).int);
    try std.testing.expectEqual(@as(f64, 7.5), (try rt.callGlobal("viaMaxFloat", &.{})).float);
    try std.testing.expectEqual(@as(f64, 10.0), (try rt.callGlobal("viaClamp", &.{})).float);
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

// tplValToDynStr formats every scalar value kind template.render can
// interpolate: int/float use the same "{d}" formatting as std.conv.to_string
// (whole floats print without a decimal point; fractional floats print their
// shortest round-trip decimal), bool prints "true"/"false", null prints the
// literal text "null", and strings pass through verbatim.
test "compiler: std.template.render interpolates int, float, bool, null and string values" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() string {
        \\    return std.template.render("{{.i}}|{{.f}}|{{.bt}}|{{.bf}}|{{.n}}|{{.s}}", {
        \\        "i": 42,
        \\        "f": 3.5,
        \\        "bt": true,
        \\        "bf": false,
        \\        "n": null,
        \\        "s": "hi",
        \\    })
        \\}
    );
    const out = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("42|3.5|true|false|null|hi", try vms.asStringValue(out));
}

// tplValToDynStr's .object branch only special-cases dyn_string/string_view
// (raw strings) and named_value (unwraps to the underlying value); every
// other object kind — arrays, maps, plain struct instances interpolated
// directly rather than field-accessed — falls through to the "?" fallback.
// This is a real limitation worth pinning down: there is no auto-serialization
// of composite values in this template engine.
test "compiler: std.template.render prints the literal '?' fallback for array and map values interpolated directly" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() string {
        \\    return std.template.render("{{.arr}}|{{.m}}", {
        \\        "arr": [1, 2, 3],
        \\        "m": {"x": 1},
        \\    })
        \\}
    );
    const out = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("?|?", try vms.asStringValue(out));
}

// tplResolveField's .struct_instance and .small_struct_instance branches:
// a struct with <= SmallStructMaxFields (4) fields is stored inline as
// small_struct_instance; a struct with more fields falls back to the
// MapEntry-based struct_instance representation. Both must resolve field
// names the same way when used directly as template data (not wrapped in
// a map).
test "compiler: std.template.render resolves field access directly on struct data (small and regular struct_instance)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Point struct { x int, y int }
        \\type Big struct { a int, b int, c int, d int, e int }
        \\func small() string {
        \\    p := Point{ x: 3, y: 4 }
        \\    return std.template.render("{{.x}},{{.y}}", p)
        \\}
        \\func big() string {
        \\    v := Big{ a: 1, b: 2, c: 3, d: 4, e: 5 }
        \\    return std.template.render("{{.e}}-{{.a}}", v)
        \\}
    );
    const small_out = try rt.callGlobal("small", &.{});
    try std.testing.expectEqualStrings("3,4", try vms.asStringValue(small_out));
    const big_out = try rt.callGlobal("big", &.{});
    try std.testing.expectEqualStrings("5-1", try vms.asStringValue(big_out));
}

// tplResolveField returns .null (rendered as the text "null") rather than
// raising an error both when the dot itself isn't an object at all (field
// access on a primitive) and when it is an object but the named field
// simply doesn't exist. Missing data is silent, not an error.
test "compiler: std.template.render treats field access on a non-object dot or an unknown field as null, not an error" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func nonObjectDot() string {
        \\    return std.template.render("{{.x}}", 5)
        \\}
        \\func unknownField() string {
        \\    return std.template.render("{{.missing}}", {"a": 1})
        \\}
    );
    const r1 = try rt.callGlobal("nonObjectDot", &.{});
    try std.testing.expectEqualStrings("null", try vms.asStringValue(r1));
    const r2 = try rt.callGlobal("unknownField", &.{});
    try std.testing.expectEqualStrings("null", try vms.asStringValue(r2));
}

// tplIsArray only returns true for .array/.array_managed — a map is never
// considered rangeable. range_begin's runtime handling treats "object but
// not an array" exactly like a false condition: it takes the else branch
// (or falls straight past to end, with no output, when there's no else).
// Unlike Go's text/template, {{range}} in this engine cannot iterate a map's
// key/value pairs at all.
test "compiler: std.template.range does not iterate map values — it takes the empty/else path instead" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func withElse() string {
        \\    return std.template.render("{{range .m}}X{{else}}empty{{end}}", {"m": {"a": 1, "b": 2}})
        \\}
        \\func withoutElse() string {
        \\    return std.template.render("{{range .m}}X{{end}}", {"m": {"a": 1}})
        \\}
    );
    const r1 = try rt.callGlobal("withElse", &.{});
    try std.testing.expectEqualStrings("empty", try vms.asStringValue(r1));
    const r2 = try rt.callGlobal("withoutElse", &.{});
    try std.testing.expectEqualStrings("", try vms.asStringValue(r2));
}

// {{break}} and {{continue}} parse into dedicated TplOp.break_inst/
// continue_inst opcodes (tplParseTag explicitly recognizes both keywords),
// but tplExec's switch handles both identically to a plain no-op:
// `.var_ref, .call_fn, .assign, .break_inst, .continue_inst => { ip += 1; }`.
// Neither tag has any effect on control flow — a {{break}} inside a
// {{range}} does not stop the loop, and a {{continue}} does not skip the
// rest of the current iteration. This is a genuine gap versus what the
// keywords imply.
test "compiler: std.template {{break}} and {{continue}} inside range are parsed but have no runtime effect" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func withBreak() string {
        \\    return std.template.render("{{range .items}}{{.}}{{break}}{{end}}", {"items": ["a", "b", "c"]})
        \\}
        \\func withContinue() string {
        \\    return std.template.render("{{range .items}}{{continue}}{{.}}{{end}}", {"items": ["a", "b"]})
        \\}
    );
    // If {{break}} actually stopped the loop this would be "a", not "abc".
    const r1 = try rt.callGlobal("withBreak", &.{});
    try std.testing.expectEqualStrings("abc", try vms.asStringValue(r1));
    // If {{continue}} actually skipped the rest of the iteration this would
    // be "" (the {{.}} after it would never run), not "ab".
    const r2 = try rt.callGlobal("withContinue", &.{});
    try std.testing.expectEqualStrings("ab", try vms.asStringValue(r2));
}

// {{$x := expr}} parses into TplOp.assign (tplParseTag only keeps the
// variable name — the RHS expression is discarded and never stored
// anywhere), and {{$x}} parses into TplOp.var_ref. Both are no-ops at
// runtime (same switch arm as break/continue above): there is no variable
// storage at all in this engine, so a declared "$x" never becomes readable.
test "compiler: std.template $var assignment and reference are parsed but produce no output (variables are unimplemented)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() string {
        \\    return std.template.render("[{{$x := .a}}{{$x}}]", {"a": "hi"})
        \\}
    );
    const out = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("[]", try vms.asStringValue(out));
}

// The headline finding for this file: std.template.add_func registers a
// name -> function mapping on the template object's `funcs` field (tplAddFunc
// really does insert/overwrite/grow that map), but tplExec's `.call_fn` arm
// is `ip += 1` — the exact same no-op as break/continue/var_ref/assign above.
// tplEvalExpr, which is the only place that could look up `funcs_v`, receives
// it as `_funcs_val` and immediately discards it (`_ = _funcs_val;`). So a
// {{funcName arg}} tag produces empty output unconditionally, whether or not
// the function was ever registered, and calling an unregistered name is not
// an error either — custom function calls are entirely non-functional at
// runtime despite add_func's bookkeeping working correctly in isolation.
//
// This test also exercises tplAddFunc's three reachable branches: first
// registration on the initial empty `.map` (converts to map_managed),
// re-registering the same name on `.map_managed` (found -> overwrite,
// returns early), and registering a new name on `.map_managed` (not found ->
// grow-and-append).
test "compiler: std.template call_fn tags render as empty output regardless of add_func registration (custom functions are inert)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func addOne(x int) int { return x + 1 }
        \\func addTwo(x int) int { return x + 2 }
        \\func registered() string {
        \\    t := std.template.parse("[{{myFunc .}}]")
        \\    std.template.add_func(t, "myFunc", addOne)
        \\    out1 := std.template.execute(t, {})
        \\    std.template.add_func(t, "myFunc", addTwo)
        \\    out2 := std.template.execute(t, {})
        \\    std.template.add_func(t, "other", addOne)
        \\    out3 := std.template.execute(t, {})
        \\    return out1 + "|" + out2 + "|" + out3
        \\}
        \\func unregistered() string {
        \\    t := std.template.parse("[{{undefinedFn .}}]")
        \\    return std.template.execute(t, {})
        \\}
    );
    const r1 = try rt.callGlobal("registered", &.{});
    try std.testing.expectEqualStrings("[]|[]|[]", try vms.asStringValue(r1));
    const r2 = try rt.callGlobal("unregistered", &.{});
    try std.testing.expectEqualStrings("[]", try vms.asStringValue(r2));
}

// tplValid (tplCountInsts under the hood) only checks that every "{{" has a
// matching "}}" — it never calls tplParseTag, so it cannot detect a
// malformed tag body. "{{???}}" is balance-valid but tag-invalid: valid()
// reports true while parse() on the exact same string raises
// error.InvalidTemplate. Separately, an empty source string is a degenerate
// case for tplCountInsts's while loop (it never executes, so count stays 0),
// making valid("") false — even though parse("")/render("", ...) both
// succeed and simply produce empty output. valid() and parse() are not the
// same predicate.
test "compiler: std.template.valid only checks brace balance, not tag syntax — it disagrees with parse() on malformed tags and on the empty string" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func validSaysOkForBadTag() bool { return std.template.valid("{{???}}") }
        \\func parseRejectsBadTag() bool {
        \\    std.template.parse("{{???}}")
        \\    return true
        \\}
        \\func validOnEmpty() bool { return std.template.valid("") }
        \\func parseOnEmpty() string {
        \\    t := std.template.parse("")
        \\    return std.template.execute(t, {})
        \\}
        \\func validOnPlainText() bool { return std.template.valid("plain text, no tags") }
    );
    const bad_tag_valid = try rt.callGlobal("validSaysOkForBadTag", &.{});
    try std.testing.expect(bad_tag_valid == .boolean and bad_tag_valid.boolean);
    try std.testing.expectError(error.InvalidTemplate, rt.callGlobal("parseRejectsBadTag", &.{}));

    const empty_valid = try rt.callGlobal("validOnEmpty", &.{});
    try std.testing.expect(empty_valid == .boolean and !empty_valid.boolean);
    const empty_parsed = try rt.callGlobal("parseOnEmpty", &.{});
    try std.testing.expectEqualStrings("", try vms.asStringValue(empty_parsed));

    const plain_valid = try rt.callGlobal("validOnPlainText", &.{});
    try std.testing.expect(plain_valid == .boolean and plain_valid.boolean);
}

// {{with expr}} unconditionally evaluates expr, pushes it as the new dot,
// and runs its body — there is no falsy/empty check at all (contrast with
// Go's text/template, where {{with}} skips its body when the value is the
// zero value). A missing field resolves to .null via tplResolveField, and
// with_begin still descends into the body with dot == null.
test "compiler: std.template.with always executes its body, even when the referenced value is missing (null)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func nestedWith() string {
        \\    return std.template.render("{{with .a}}{{.x}}{{with .y}}{{.}}{{end}}{{end}}", {"a": {"x": "X", "y": "Y"}})
        \\}
        \\func withOnMissing() string {
        \\    return std.template.render("{{with .missing}}shown:{{.}}{{end}}", {"other": 1})
        \\}
    );
    const r1 = try rt.callGlobal("nestedWith", &.{});
    try std.testing.expectEqualStrings("XY", try vms.asStringValue(r1));
    // Go's text/template would render "" here (with skips a zero value); this
    // engine always enters the body.
    const r2 = try rt.callGlobal("withOnMissing", &.{});
    try std.testing.expectEqualStrings("shown:null", try vms.asStringValue(r2));
}

// std.template does no HTML/attribute escaping at all: interpolated string
// values (including ones containing '<', '>', '&', '"') pass straight
// through to the output verbatim. Pinned down explicitly since "no escaping"
// vs. "escapes by default" is exactly the kind of behavior worth confirming
// with a real test.
test "compiler: std.template.render does not HTML-escape interpolated string values" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() string {
        \\    return std.template.render("<p>{{.x}}</p>", {"x": "<script>alert(1)</script> & \"quoted\""})
        \\}
    );
    const out = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("<p><script>alert(1)</script> & \"quoted\"</p>", try vms.asStringValue(out));
}

// dispatch's template_execute and template_add_func both reject a first
// argument that isn't a template object (`if (tmpl_val != .object) return
// error.TypeError;`), independent of tplExec/tplAddFunc's own logic.
test "compiler: std.template.execute and std.template.add_func raise TypeError when given a non-template first argument" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func execOnNonTemplate() string { return std.template.execute(5, {}) }
        \\func addFuncOnNonTemplate() string {
        \\    std.template.add_func(5, "f", func(x int) int { return x })
        \\    return "unreached"
        \\}
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("execOnNonTemplate", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("addFuncOnNonTemplate", &.{}));
}

// tplExec's {{if}} handler requires the condition to be a genuine bool
// (`cond.asBool() catch { setRuntimeErr(...); return error.TypeError; }`);
// an int (or any other non-bool truthy-looking value) is rejected rather
// than coerced.
test "compiler: std.template.render raises TypeError when an {{if}} condition is not a bool" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() string {
        \\    return std.template.render("{{if .x}}yes{{end}}", {"x": 1})
        \\}
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("f", &.{}));
}

// Regression: tplIsArray (template.zig) checked only `.array`/
// `.array_managed`, missing `.array_view`/`.array_capacity` -- the exact
// same cross-representation gap this session's deep_equal fix closed for
// core.zig. `range` gates on tplIsArray before ever calling
// tplAsArraySlice (which already correctly handled `.array_capacity`), so
// {{range .items}} over an array built via std.core.append (always
// `.array_capacity`, per vm_array.zig's arrayAppend) silently iterated
// ZERO times -- the whole render produced empty output -- while the exact
// same data as a plain array LITERAL worked fine. Confirmed via direct
// CLI repro before fixing: `render(..., items)` returned "" for an
// appended array but the correct concatenated string for a literal one.
// Fixed by giving tplIsArray/tplAsArraySlice the complete four-tag switch
// vm_state.zig's vms.isArrayObject/asArraySlice already use as the
// canonical array-representation set.
//
// This test also exercises tplAppendToBuilder/tplAppendDynStrToBuilder's
// growth branch (the string_builder's backing buffer must be reallocated
// at least once as the output accumulates).
//
// 50 iterations, not the rounder 500 a first draft used: the -Dpreset=stress
// build caps max_objects at 512 (config_stress.zig), and every element of
// the final array is a LIVE dyn_string that must all survive simultaneously
// (they're reachable from the still-live `items` array) -- 500 of those
// alone would exceed the whole object pool regardless of GC timing, since
// GC can only reclaim garbage, not live data. 50 is comfortably within
// every preset's object budget while still forcing at least one string
// builder reallocation.
test "compiler: std.template.range iterates an array built via std.core.append (not just a literal), and grows its output builder repeatedly" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() int {
        \\    items := []
        \\    i := 0
        \\    for i < 50 {
        \\        items = std.core.append(items, "item-" + std.conv.to_string(i) + "-")
        \\        i = i + 1
        \\    }
        \\    out := std.template.render("{{range .items}}{{.}}{{end}}", {"items": items})
        \\    return std.core.len(out)
        \\}
    );
    const out = try rt.callGlobal("f", &.{});
    // 10 items (0-9) at 7 bytes + 40 items (10-49) at 8 bytes = 70 + 320 = 390.
    try std.testing.expectEqual(@as(i64, 390), out.int);
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

// mapSet converts a map's small linear-scan representation to map_hashed
// once an insert pushes the entry count past 8 (see mapSet's `if (new_len >
// 8)` branch in vm_map.zig) — ordinary small-map Gengo scripts (a handful
// of key/value pairs, the overwhelming majority of real usage) never cross
// that threshold, so mapFindHashedIndex/mapBuildHashedBuckets/
// mapInsertHashed's happy path, not-found path, in-place-update path, and
// hashed mapDelete were all effectively untested. 300 entries forces
// several bucket-table growths along the way (mapInsertHashed grows once
// load factor would exceed 70%), and sequential int keys collide directly
// once the bucket mask wraps (mapHashValue(.int) is a bare bitcast, not
// mixed), so this also exercises mapFindHashedIndex/mapBuildHashedBuckets's
// collision-probing loop without needing to hand-pick colliding keys.
test "compiler: hashed map (>8 entries) covers volume round-trip, not-found, overwrite, and delete for int and string keys" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func intMapRoundTrip() bool {
        \\    m := {}
        \\    for i := 0; i < 300; i += 1 {
        \\        m[i] = i * i
        \\    }
        \\    ok := std.core.len(m) == 300
        \\    for i := 0; i < 300; i += 1 {
        \\        if m[i] != i * i { ok = false }
        \\    }
        \\    return ok
        \\}
        \\func intMapNotFound() bool {
        \\    m := {}
        \\    for i := 0; i < 300; i += 1 {
        \\        m[i] = i
        \\    }
        \\    return not std.core.has(m, 9999) and std.core.is_null(m[9999])
        \\}
        \\func intMapOverwriteInPlace() bool {
        \\    m := {}
        \\    for i := 0; i < 300; i += 1 {
        \\        m[i] = i
        \\    }
        \\    m[5] = -1
        \\    return std.core.len(m) == 300 and m[5] == -1
        \\}
        \\func intMapDeleteKeepsNeighbors() bool {
        \\    m := {}
        \\    for i := 0; i < 300; i += 1 {
        \\        m[i] = i * i
        \\    }
        \\    removed := std.core.delete(m, 10)
        \\    stillMissing := std.core.delete(m, 99999)
        \\    return removed == 100 and std.core.is_null(stillMissing) and std.core.len(m) == 299 and not std.core.has(m, 10) and m[9] == 81 and m[11] == 121
        \\}
        \\func stringMapRoundTrip() bool {
        \\    sm := {}
        \\    for i := 0; i < 300; i += 1 {
        \\        key := "k" + std.conv.to_string(i)
        \\        sm[key] = i
        \\    }
        \\    ok := std.core.len(sm) == 300
        \\    for i := 0; i < 300; i += 1 {
        \\        key := "k" + std.conv.to_string(i)
        \\        if sm[key] != i { ok = false }
        \\    }
        \\    return ok
        \\}
        \\func stringMapNotFoundOverwriteDelete() bool {
        \\    sm := {}
        \\    for i := 0; i < 300; i += 1 {
        \\        key := "k" + std.conv.to_string(i)
        \\        sm[key] = i
        \\    }
        \\    notFound := not std.core.has(sm, "missing") and std.core.is_null(sm["missing"])
        \\    sm["k5"] = -1
        \\    overwrote := std.core.len(sm) == 300 and sm["k5"] == -1
        \\    removed := std.core.delete(sm, "k10")
        \\    deleted := removed == 10 and std.core.len(sm) == 299 and not std.core.has(sm, "k10") and sm["k9"] == 9 and sm["k11"] == 11
        \\    return notFound and overwrote and deleted
        \\}
        \\func staticAndDynamicStringKeysCollide() bool {
        \\    // A static string literal key and a heap-built dyn_string key with
        \\    // the same content must hash and compare equal (mapHashValue hashes
        \\    // dyn_string by content, not pointer identity).
        \\    m := {"hello": 1}
        \\    for i := 0; i < 20; i += 1 {
        \\        m[std.conv.to_string(i)] = i
        \\    }
        \\    dynHello := "he" + "llo"
        \\    return m[dynHello] == 1
        \\}
    );
    try std.testing.expect((try rt.callGlobal("intMapRoundTrip", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("intMapNotFound", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("intMapOverwriteInPlace", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("intMapDeleteKeepsNeighbors", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("stringMapRoundTrip", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("stringMapNotFoundOverwriteDelete", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("staticAndDynamicStringKeysCollide", &.{})).boolean);
}

// mapHashValue has a distinct branch per Value key kind (int/float/decimal/
// rune/boolean/string/error_value, plus dyn_string/string_view/enum_value/
// named_value/variant_value/inline_variant inside its .object arm), but
// mapHashValue is only ever called from the hashed-map code paths
// (mapFindHashedIndex/mapBuildHashedBuckets/mapInsertHashed) — mapFindLinear
// never calls it. So every branch beyond plain int/string is unreachable
// from an ordinary small (<=8 entry) map. This builds one hashed map (past
// the 8-entry threshold from the int keys alone) keyed by one value of
// every reachable kind and round-trips each — including a decimal-based
// named type (named_value), a unit variant arm (inline_variant, since a
// null payload fits inline), a payload variant arm (variant_value, since a
// string payload does not fit inline), and a std.bytes.slice result
// (string_view).
test "compiler: hashed map with a distinct key of every Value kind exercises every mapHashValue branch" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Color enum { red, green, blue, yellow, purple, orange, cyan, magenta, black, white }
        \\type Shape variant {
        \\    point,
        \\    tag(label string),
        \\}
        \\type Money decimal 2
        \\func mixedKeyMap() bool {
        \\    m := {}
        \\    for i := 0; i < 20; i += 1 {
        \\        m[i] = i
        \\    }
        \\    m[1.5] = "float-key"
        \\    m[true] = "bool-true"
        \\    m[false] = "bool-false"
        \\    m['x'] = "rune-x"
        \\    m[Color.red] = "enum-red"
        \\    m[Money(9.99)] = "decimal-999"
        \\    m[Shape.point] = "variant-point-inline"
        \\    m[Shape.tag("hi")] = "variant-tag-heap"
        \\    m[std.core.error("boom")] = "error-boom"
        \\    dyn := "dyn-" + std.conv.to_string(42)
        \\    m[dyn] = "dyn-string-key"
        \\    view := std.bytes.slice(std.conv.to_string(123456), 1, 4)
        \\    m[view] = "string-view-key"
        \\    m[null] = "null-key"
        \\
        \\    ok := true
        \\    for i := 0; i < 20; i += 1 {
        \\        if m[i] != i { ok = false }
        \\    }
        \\    if m[1.5] != "float-key" { ok = false }
        \\    if m[true] != "bool-true" { ok = false }
        \\    if m[false] != "bool-false" { ok = false }
        \\    if m['x'] != "rune-x" { ok = false }
        \\    if m[Color.red] != "enum-red" { ok = false }
        \\    if m[Money(9.99)] != "decimal-999" { ok = false }
        \\    if m[Shape.point] != "variant-point-inline" { ok = false }
        \\    if m[Shape.tag("hi")] != "variant-tag-heap" { ok = false }
        \\    if m[std.core.error("boom")] != "error-boom" { ok = false }
        \\    if m["dyn-42"] != "dyn-string-key" { ok = false }
        \\    if m[view] != "string-view-key" { ok = false }
        \\    if m[null] != "null-key" { ok = false }
        \\    return ok
        \\}
        \\func mixedKeyMapNotFoundAndDelete() bool {
        \\    m := {}
        \\    for i := 0; i < 20; i += 1 {
        \\        m[i] = i
        \\    }
        \\    m[Color.red] = "enum-red"
        \\    m[Color.blue] = "enum-blue"
        \\    notFound := not std.core.has(m, Color.green) and std.core.is_null(m[Color.green])
        \\    removed := std.core.delete(m, Color.red)
        \\    return notFound and removed == "enum-red" and not std.core.has(m, Color.red) and m[Color.blue] == "enum-blue"
        \\}
    );
    try std.testing.expect((try rt.callGlobal("mixedKeyMap", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("mixedKeyMapNotFoundAndDelete", &.{})).boolean);
}

// std.core.has/std.core.delete (nativeHas/nativeDelete in core.zig) take the
// first argument as a raw *Object with no upfront isMapObject check, unlike
// e.g. nativeMapExtract's std.core.keys/values — they delegate straight to
// vmmap.mapHas/vmmap.mapDelete, whose `else => return error.TypeError` arms
// are the only thing standing between a non-map object (an array here) and
// undefined behavior. No existing test called either native on a non-map
// object, so these arms were unreached.
test "compiler: std.core.has/std.core.delete raise TypeError on a non-map object" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func hasOnArray() bool { a := [1, 2, 3]; return std.core.has(a, 2) }
        \\func deleteOnArray() int { a := [1, 2, 3]; return std.core.delete(a, 2) }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("hasOnArray", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("deleteOnArray", &.{}));
}

// Coverage-audit 2026-09: every map *literal* compiles through vm.zig's
// build_map, which always produces .map_hashed immediately (even for `{}`)
// — see build_map's opcode handler. So vm_map.mapSet's "append to a small
// linear-scan .map/.map_managed, promoting to .map_hashed past 8 entries"
// branch, and mapDelete's .map/.map_managed branch, are dead from every
// ordinary Gengo map literal. The only way a plain (non-hashed) .map or
// .map_managed value ever reaches a script is through specific native
// results that build one directly: std.core.gc_stats() (a fixed 3-entry
// .map) and std.json.parse of an empty JSON object ("{}", a 0-entry .map).
// Both are used here to actually exercise the append/promote/delete code
// paths a real script can only reach this way, not a contrived one.
test "compiler: native-returned plain .map/.map_managed values exercise mapSet's append/promote and mapDelete's non-hashed branch" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func deletesFromPlainMap() bool {
        \\    // std.core.gc_stats() returns a genuine 3-entry .map, untouched
        \\    // by any insert — delete must hit mapDelete's plain-.map branch,
        \\    // not the .map_managed one.
        \\    stats := std.core.gc_stats()
        \\    removed := std.core.delete(stats, "heap_used_bytes")
        \\    return not std.core.is_null(removed) and std.core.len(stats) == 2 and not std.core.has(stats, "heap_used_bytes")
        \\}
        \\func insertThenDeleteFromManagedMap() bool {
        \\    // Setting a key gc_stats() didn't already have appends via
        \\    // mapSet's linear-growth path (new_len=4, stays <=8, so no
        \\    // promotion) — mapSet always republishes as .map_managed after
        \\    // an append, so the delete below hits mapDelete's other branch.
        \\    stats := std.core.gc_stats()
        \\    stats["extra"] = 42
        \\    removed := std.core.delete(stats, "extra")
        \\    return removed == 42 and std.core.len(stats) == 3
        \\}
        \\func growsPastEightPromotesToHashed() bool {
        \\    // std.json.parse("{}") is the only way to get a genuinely empty
        \\    // (0-entry) .map — every map literal is .map_hashed from birth.
        \\    // 9 sequential new-key inserts force mapSet's own >8 promotion.
        \\    m := std.json.parse("{}")
        \\    for i := 0; i < 9; i += 1 {
        \\        m[std.conv.to_string(i)] = i
        \\    }
        \\    ok := std.core.len(m) == 9
        \\    for i := 0; i < 9; i += 1 {
        \\        if m[std.conv.to_string(i)] != i { ok = false }
        \\    }
        \\    return ok
        \\}
    );
    try std.testing.expect((try rt.callGlobal("deletesFromPlainMap", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("insertThenDeleteFromManagedMap", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("growsPastEightPromotesToHashed", &.{})).boolean);
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

// fmtFloat's plain '-' sign prefix (only reached for a finite negative value,
// after the NaN/Inf short-circuits above already claimed the sign-bit-set
// cases), fmtF64Fixed's precision arms 4 and 7..16 (existing tests only ever
// hit 0, 1, 2, 5, and 6), fmtF64Sci's round-up carry (mantissa rounds to
// 10.0 at the requested precision, forcing exp+1 and a mantissa/10 backoff),
// its abs_v==0.0 fast path (only reachable via a direct %e/%E verb -- %g's
// zero case short-circuits one level up in fmtF64General before ever
// calling into Sci), and the mantissa renormalization branches (mant>=10.0
// / mant<1.0) that only misfire deep in the exponent range near f64's
// minimum magnitude, where floor(log10(v)) and v/10^exp disagree by one ULP
// of exponent -- none of this had coverage anywhere else in this file. Note
// these two literals must stay inside roughly 1e-280..1e-308: Gengo's own
// hand-rolled float literal parser (common.zig's parseFloat) computes
// `ip / pow(10, exp)` for a negative exponent, and pow(10, exp) itself
// overflows to +Inf for exp beyond ~308, silently underflowing the whole
// literal to 0.0 instead of the intended subnormal -- e.g. `1e-320` parses
// as exactly 0.0 in Gengo today. That's a separate, real bug in
// src/lang/common.zig (out of scope for this file), not exercised further
// here.
test "compiler: std.fmt.format float verbs: negative sign, extra fixed precisions, sci zero/carry/renormalization" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func negFixed() string { return std.fmt.format("%f", -1234.5) }
        \\func prec4() string { return std.fmt.format("%.4f", 1234.5) }
        \\func prec7() string { return std.fmt.format("%.7f", 1234.5) }
        \\func prec8() string { return std.fmt.format("%.8f", 1234.5) }
        \\func prec9() string { return std.fmt.format("%.9f", 1234.5) }
        \\func prec10() string { return std.fmt.format("%.10f", 1234.5) }
        \\func prec11() string { return std.fmt.format("%.11f", 1234.5) }
        \\func prec12() string { return std.fmt.format("%.12f", 1234.5) }
        \\func prec13() string { return std.fmt.format("%.13f", 1234.5) }
        \\func prec14() string { return std.fmt.format("%.14f", 1234.5) }
        \\func prec15() string { return std.fmt.format("%.15f", 1234.5) }
        \\func prec16() string { return std.fmt.format("%.16f", 1234.5) }
        \\func sciZero() string { return std.fmt.format("%e", 0.0) }
        \\func sciRoundCarry() string { return std.fmt.format("%.2e", 9.999) }
        \\func sciMantGe10() string { return std.fmt.format("%e", 1.0000000001e-308) }
        \\func sciMantLt1() string { return std.fmt.format("%e", 9.9999999999999e-280) }
    );
    try std.testing.expectEqualStrings("-1234.500000", try vms.asStringValue(try rt.callGlobal("negFixed", &.{})));
    try std.testing.expectEqualStrings("1234.5000", try vms.asStringValue(try rt.callGlobal("prec4", &.{})));
    try std.testing.expectEqualStrings("1234.5000000", try vms.asStringValue(try rt.callGlobal("prec7", &.{})));
    try std.testing.expectEqualStrings("1234.50000000", try vms.asStringValue(try rt.callGlobal("prec8", &.{})));
    try std.testing.expectEqualStrings("1234.500000000", try vms.asStringValue(try rt.callGlobal("prec9", &.{})));
    try std.testing.expectEqualStrings("1234.5000000000", try vms.asStringValue(try rt.callGlobal("prec10", &.{})));
    try std.testing.expectEqualStrings("1234.50000000000", try vms.asStringValue(try rt.callGlobal("prec11", &.{})));
    try std.testing.expectEqualStrings("1234.500000000000", try vms.asStringValue(try rt.callGlobal("prec12", &.{})));
    try std.testing.expectEqualStrings("1234.5000000000000", try vms.asStringValue(try rt.callGlobal("prec13", &.{})));
    try std.testing.expectEqualStrings("1234.50000000000000", try vms.asStringValue(try rt.callGlobal("prec14", &.{})));
    try std.testing.expectEqualStrings("1234.500000000000000", try vms.asStringValue(try rt.callGlobal("prec15", &.{})));
    try std.testing.expectEqualStrings("1234.5000000000000000", try vms.asStringValue(try rt.callGlobal("prec16", &.{})));
    try std.testing.expectEqualStrings("0.000000e+00", try vms.asStringValue(try rt.callGlobal("sciZero", &.{})));
    try std.testing.expectEqualStrings("1.00e+01", try vms.asStringValue(try rt.callGlobal("sciRoundCarry", &.{})));
    try std.testing.expectEqualStrings("1.000000e-308", try vms.asStringValue(try rt.callGlobal("sciMantGe10", &.{})));
    try std.testing.expectEqualStrings("1.000000e-279", try vms.asStringValue(try rt.callGlobal("sciMantLt1", &.{})));
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

// sprintValueDepth's remaining branches, none reachable from the previous
// stringify test: a decimal value (decimalRawAndScale short-circuit before
// the main switch), a rune value, NaN/+Inf/-Inf (the plain %v/stringify
// float path, distinct from fmtFloat's own NaN/Inf short-circuit exercised
// via std.fmt.format elsewhere), a heap dyn_string and a string_view (as
// opposed to the static .string Value already covered), a bare type
// reference for struct/interface/named/enum/variant types, an enum value,
// a variant constructor referenced without being called, a named_value
// (boxed because its base is `string` -- scalar int/float/bool named types
// are erased to the bare value at construction and never reach this
// branch), and a multi-field record-arm variant value (exercises the ", "
// separator in both the measuring and the writing pass, since the existing
// variantRecordStr test above only used a single-field arm) plus a
// multi-entry map (same separator, map branch).
test "compiler: std.fmt.stringify covers decimal/rune/NaN-Inf/type-object/enum-value/variant-ctor/named-value/multi-field branches" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Money decimal 2
        \\type Square struct { side int }
        \\type Shape interface { area() int }
        \\type Meter int
        \\type Color enum { red, green, blue }
        \\type Boxed variant { ok(v int), bad }
        \\type Label string
        \\type ShapeV variant { circle { radius float, label string }, tag(n int), point }
        \\func decimalStr() string { return std.fmt.stringify(Money(9.99)) }
        \\func runeStr() string { return std.fmt.stringify(`A`) }
        \\func nanStr() string { return std.fmt.stringify(std.math.nan()) }
        \\func infStr() string { return std.fmt.stringify(std.math.inf) }
        \\func negInfStr() string { return std.fmt.stringify(-std.math.inf) }
        \\func dynStringStr() string { a := "he"; b := "llo"; return std.fmt.stringify(a + b) }
        \\func stringViewStr() string { return std.fmt.stringify(std.bytes.slice("hello world", 0, 5)) }
        \\func structTypeStr() string { return std.fmt.stringify(Square) }
        \\func interfaceTypeStr() string { return std.fmt.stringify(Shape) }
        \\func namedTypeStr() string { return std.fmt.stringify(Meter) }
        \\func enumTypeStr() string { return std.fmt.stringify(Color) }
        \\func enumValueStr() string { return std.fmt.stringify(Color.red) }
        \\func variantTypeStr() string { return std.fmt.stringify(Boxed) }
        \\func variantCtorStr() string { ctor := Boxed.ok; return std.fmt.stringify(ctor) }
        \\func namedValueStr() string { l := Label("hi"); return std.fmt.stringify(l) }
        \\func multiFieldVariantStr() string { return std.fmt.stringify(ShapeV.circle{radius: 5.0, label: "x"}) }
        \\func multiEntryMapStr() string { return std.fmt.stringify({"a": 1, "b": 2}) }
    );
    try std.testing.expectEqualStrings("9.99", try vms.asStringValue(try rt.callGlobal("decimalStr", &.{})));
    try std.testing.expectEqualStrings("A", try vms.asStringValue(try rt.callGlobal("runeStr", &.{})));
    try std.testing.expectEqualStrings("NaN", try vms.asStringValue(try rt.callGlobal("nanStr", &.{})));
    try std.testing.expectEqualStrings("Inf", try vms.asStringValue(try rt.callGlobal("infStr", &.{})));
    try std.testing.expectEqualStrings("-Inf", try vms.asStringValue(try rt.callGlobal("negInfStr", &.{})));
    try std.testing.expectEqualStrings("hello", try vms.asStringValue(try rt.callGlobal("dynStringStr", &.{})));
    try std.testing.expectEqualStrings("hello", try vms.asStringValue(try rt.callGlobal("stringViewStr", &.{})));
    try std.testing.expectEqualStrings("<struct Square>", try vms.asStringValue(try rt.callGlobal("structTypeStr", &.{})));
    try std.testing.expectEqualStrings("<interface Shape>", try vms.asStringValue(try rt.callGlobal("interfaceTypeStr", &.{})));
    try std.testing.expectEqualStrings("<type Meter>", try vms.asStringValue(try rt.callGlobal("namedTypeStr", &.{})));
    try std.testing.expectEqualStrings("<enum Color>", try vms.asStringValue(try rt.callGlobal("enumTypeStr", &.{})));
    try std.testing.expectEqualStrings("red", try vms.asStringValue(try rt.callGlobal("enumValueStr", &.{})));
    try std.testing.expectEqualStrings("<variant Boxed>", try vms.asStringValue(try rt.callGlobal("variantTypeStr", &.{})));
    try std.testing.expectEqualStrings("Boxed.ok", try vms.asStringValue(try rt.callGlobal("variantCtorStr", &.{})));
    try std.testing.expectEqualStrings("hi", try vms.asStringValue(try rt.callGlobal("namedValueStr", &.{})));
    try std.testing.expectEqualStrings("ShapeV.circle(5, x)", try vms.asStringValue(try rt.callGlobal("multiFieldVariantStr", &.{})));
    try std.testing.expectEqualStrings("{a: 1, b: 2}", try vms.asStringValue(try rt.callGlobal("multiEntryMapStr", &.{})));
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

test "compiler error recovery: a fatal error (TooManyLocals) aborts immediately without collecting further independent errors" {
    // isFatalError (compiler.zig) returns OOM/TooMany* errors straight out of
    // compile()'s top-level catch, bypassing collectError entirely — unlike
    // every recoverable-error test above (AssignToConst, DuplicateNamedType,
    // TypeError), which log-and-continue via syncToNextDecl. A fatal error
    // must therefore leave collected_error_count at 0 even though a second,
    // wholly independent recoverable error follows it in the source.
    var rt = try setup();
    defer rt.deinit();

    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func manyLocals() int {\n");
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "    v{d} := 0\n", .{i});
        try src.appendSlice(std.testing.allocator, line);
    }
    try src.appendSlice(std.testing.allocator, "    return v0\n}\n");
    // Never reached: the fatal error above aborts the whole compile() loop.
    try src.appendSlice(std.testing.allocator, "const zz = 1\nzz = 2\n");

    const multi = compileAndInspectMulti(&rt, src.items);
    try std.testing.expectEqual(@as(u8, 0), multi.count);

    const single = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyLocals, single.err);
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

// Coverage-audit 2026-09: drainMarkQueue (vm_gc.zig) has a dedicated switch
// arm for several object kinds that no existing test ever held alive across
// an actual std.core.gc() call — .inline_variant (a payload-less variant
// arm, which lives inline rather than as a heap object but still roots its
// type through markValue's own special case), .enum_value, and the
// first-class function objects a named/enum type's .succ/.pred/.from_int
// field access materializes (.named_type_fn/.enum_type_fn) when stored
// instead of called immediately. Every case here assigns to a local (a real
// GC root via the VM stack) and only then triggers a collection, so a
// use-after-free from an under-marked object would show up as wrong output,
// not just a crash.
test "compiler: collectGarbage keeps an inline variant, enum value, and named/enum type-fn object alive across a real GC pass" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Color enum { red, green, blue }
        \\type Shape variant { point, tag(label string) }
        \\type Step int range 1..100
        \\func keepsInlineVariantAlive() bool {
        \\    s := Shape.point
        \\    std.core.gc()
        \\    return std.core.type_of(s) == "Shape"
        \\}
        \\func keepsEnumValueAlive() bool {
        \\    c := Color.green
        \\    std.core.gc()
        \\    return c == Color.green and c != Color.red
        \\}
        \\func keepsNamedTypeFnAlive() bool {
        \\    f := Step.succ
        \\    std.core.gc()
        \\    return int(f(Step(50))) == 51
        \\}
        \\func keepsEnumTypeFnAlive() bool {
        \\    g := Color.from_int
        \\    std.core.gc()
        \\    return g(1) == Color.green
        \\}
    );
    try std.testing.expect((try rt.callGlobal("keepsInlineVariantAlive", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("keepsEnumValueAlive", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("keepsNamedTypeFnAlive", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("keepsEnumTypeFnAlive", &.{})).boolean);
}

// Coverage-audit 2026-09: makeDynStringFromObj (vm_gc.zig) special-cases
// three source object kinds so it can re-derive bytes after its own
// allocation might compact the heap; only the .dyn_string and
// .string_builder arms had ever been exercised (via named-string casts and
// std.string.builder respectively). A .string_view source — the object
// std.bytes.slice returns — reaches this same function whenever a
// string_view is cast to a named string type, and had never been used that
// way in the suite.
test "compiler: casting a string_view to a named string type exercises makeDynStringFromObj's string_view branch" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Name string
        \\func viewToNamedString() string {
        \\    // bytes.slice only returns a zero-copy string_view when the
        \\    // source is itself a GC-managed object — a static string
        \\    // literal source (immortal, constant-pool) instead takes the
        \\    // slow copying path and never produces a string_view. A
        \\    // concatenation of two literals doesn't work either: the
        \\    // compiler constant-folds it back into an immortal literal
        \\    // before bytes.slice ever runs. std.conv.to_string's result
        \\    // can't be folded, so it's genuinely GC-managed at runtime.
        \\    view := std.bytes.slice(std.conv.to_string(123456), 1, 4)
        \\    n := Name(view)
        \\    return string(n)
        \\}
    );
    try std.testing.expectEqualStrings("234", try vms.asStringValue(try rt.callGlobal("viewToNamedString", &.{})));
}

// Coverage-audit 2026-09: constructing a named int-based type from a
// non-integer float (vm_types.zig's constructNamedType .int case) had no
// test — only the decimal/float/rune sibling bases' truncation checks were
// covered.
test "compiler: constructing a named int type from a non-integer float raises TypeError" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Meter int
        \\func f() Meter { return Meter(3.5) }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("f", &.{}));
}

// Coverage-audit 2026-09: fieldTypeAltStr (vm_types.zig) formats the
// "expected <type>" half of a typed-parameter TypeError differently per
// FieldTypeAlt kind. No existing test ever triggered a mismatch against a
// map/interface/named-scalar/variant/func_t-typed parameter and inspected
// the message, so 7 of its 9 branches (array/type_param were already
// covered incidentally) had never actually run.
test "compiler: a typed-parameter TypeError names the expected type for map/interface/named/variant/func_t/struct_t params" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Meters float
        \\type Shape variant { point, tag(label string) }
        \\type Shaped interface { area() int }
        \\type Point struct { x int, y int }
        \\func takesMap(m map[string]int) int { return std.core.len(m) }
        \\func takesShaped(s Shaped) int { return 0 }
        \\func takesMeters(m Meters) float { return float(m) }
        \\func takesShape(s Shape) bool { return true }
        \\func takesFn(f func(int) int) int { return f(1) }
        \\func takesPoint(p Point) int { return p.x }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("takesMap", &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("takesMap: arg 1: expected map[string]int, got int", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
    try std.testing.expectError(error.TypeError, rt.callGlobal("takesShaped", &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("takesShaped: arg 1: expected Shaped, got int", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
    try std.testing.expectError(error.TypeError, rt.callGlobal("takesMeters", &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("takesMeters: arg 1: expected Meters, got int", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
    try std.testing.expectError(error.TypeError, rt.callGlobal("takesShape", &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("takesShape: arg 1: expected Shape, got int", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
    try std.testing.expectError(error.TypeError, rt.callGlobal("takesFn", &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("takesFn: arg 1: expected func, got int", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
    try std.testing.expectError(error.TypeError, rt.callGlobal("takesPoint", &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("takesPoint: arg 1: expected Point, got int", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
}

// Coverage-audit 2026-09: fieldTypeAltStr's .type_param branch only runs
// through funcSignatureStr (building an ArityMismatch message's function
// signature), since matchesTypeAlt's own .type_param case always matches
// (a generic function's own erased type parameter can't fail an arg-type
// check) — so it can never appear as the "expected" side of a TypeError,
// only as one entry in a signature string built for an unrelated
// ArityMismatch on the same function.
test "compiler: an ArityMismatch on a generic function's signature names its type parameter" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f[T](x T, y T) T { return x }
    );
    try std.testing.expectError(error.ArityMismatch, rt.callGlobal("f", &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("f: expected 2 argument(s), got 1 for f(T, T)", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
}

// Coverage-audit 2026-09: matchesTypeAlt's subtype/deferred-generic
// acceptance paths (a value whose exact runtime type differs from the
// declared parameter type, but should still be accepted) had no positive
// test: a scalar named-type subtype chain (namedTypeIsOrExtends walking
// past the first, non-matching link — only reachable for a decimal/string/
// array/map-based named type: int/float/rune/bool named types are erased
// to the bare base value at construction, so they never reach here at all),
// an enum subtype's restricted-member check (the parameter must be the
// *subtype*, since a subtype enum has no separate storage of its own — a
// value constructed via the base enum's own member syntax already carries
// the base type, matching trivially; only a base-typed value arriving where
// the *subtype* is declared needs the real membership walk), a >4-field
// struct (the heap-backed .struct_instance representation, vs. the inline
// .small_struct_instance every other struct test here uses), and a generic
// function's own Box[T]/Opt[T]-typed parameter matching any concrete
// instantiation at runtime (T is erased, so the match is by name prefix,
// not exact identity).
test "compiler: matchesTypeAlt accepts a scalar/enum subtype, a >4-field struct, and a generic function's own generic-typed parameter" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Meters decimal 2
        \\subtype Feet Meters range 0..100
        \\func takesMeters(m Meters) string { return string(m) }
        \\func scalarSubtypeAccepted() string {
        \\    f := Feet(50.5)
        \\    return takesMeters(f)
        \\}
        \\type Colors enum { red, orange, blue }
        \\subtype Warm Colors { orange }
        \\func takesWarm(w Warm) string { return w.name }
        \\func enumSubtypeAccepted() string {
        \\    c := Colors.orange
        \\    return takesWarm(c)
        \\}
        \\type Big struct { a int, b int, c int, d int, e int }
        \\func takesBig(x Big) int { return x.a + x.e }
        \\func bigStructAccepted() int {
        \\    b := Big{a:1,b:2,c:3,d:4,e:5}
        \\    return takesBig(b)
        \\}
        \\type Box[T] struct { val T }
        \\func genericStructParam[T](b Box[T]) T { return b.val }
        \\func genericStructAccepted() int { return genericStructParam(Box[int]{val: 42}) }
        \\type Opt[T] variant { some(v T), none }
        \\func genericVariantParam[T](o Opt[T]) int {
        \\    switch o {
        \\        case .some as v { return v }
        \\        case .none { return -1 }
        \\    }
        \\}
        \\func genericVariantAccepted() int { return genericVariantParam(Opt[int].some(7)) }
    );
    try std.testing.expectEqualStrings("50.5", try vms.asStringValue(try rt.callGlobal("scalarSubtypeAccepted", &.{})));
    try std.testing.expectEqualStrings("orange", try vms.asStringValue(try rt.callGlobal("enumSubtypeAccepted", &.{})));
    try std.testing.expectEqual(@as(i64, 6), (try rt.callGlobal("bigStructAccepted", &.{})).int);
    try std.testing.expectEqual(@as(i64, 42), (try rt.callGlobal("genericStructAccepted", &.{})).int);
    try std.testing.expectEqual(@as(i64, 7), (try rt.callGlobal("genericVariantAccepted", &.{})).int);
}

// Coverage-audit 2026-09: func_t's arity check (matchesTypeAlt) reads the
// FuncObj through the `.closure` arm only when the argument is an actual
// closure (captures an outer local) — every existing func_t test passed a
// bare top-level function instead, which takes the sibling `.function` arm.
test "compiler: a closure satisfies a func_t-typed parameter's arity check" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func apply(f func(int) int, x int) int { return f(x) }
        \\func makeAdder(n int) func(int) int {
        \\    return func(x int) int { return x + n }
        \\}
        \\func g() int { return apply(makeAdder(5), 10) }
    );
    try std.testing.expectEqual(@as(i64, 15), (try rt.callGlobal("g", &.{})).int);
}

// Coverage-audit 2026-09: runtimeTypeName's .named_error_value arm (a
// `type X error`-declared named error type) was never exercised through
// std.core.type_of — only its plain .error_value sibling was.
test "compiler: std.core.type_of on a named error value reports the declared name" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type MyErr error
        \\func f() string { return std.core.type_of(MyErr("boom")) }
    );
    try std.testing.expectEqualStrings("MyErr", try vms.asStringValue(try rt.callGlobal("f", &.{})));
}

// Coverage-audit 2026-09: enforceFuncReturnTypes' runtime mismatch path
// (vm_types.zig) had never fired at all — every prior return-type mismatch
// test in this suite was one the compiler could prove statically and reject
// at compile time. Routing the bad value through std.json.parse (a
// genuinely dynamic/erased result the compiler can't type-check ahead of
// time) forces the runtime check to actually run, for both a named function
// (single return) and two anonymous-closure shapes (single and multi
// return) — the anonymous cases produce a different message (no function
// name prefix), a second branch this had also never covered.
test "compiler: a dynamically-typed bad return value raises TypeError at runtime, for named and anonymous, single and multi return" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func namedSingle() int {
        \\    doc := std.json.parse("\"oops\"")
        \\    return doc
        \\}
        \\func anonSingle() int {
        \\    f := func() int {
        \\        doc := std.json.parse("\"oops\"")
        \\        return doc
        \\    }
        \\    return f()
        \\}
        \\func anonMulti() (int, int) {
        \\    f := func() (int, int) {
        \\        doc := std.json.parse("\"oops\"")
        \\        return 1, doc
        \\    }
        \\    return f()
        \\}
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("namedSingle", &.{}));
    try std.testing.expectEqualStrings("namedSingle: expected return int, got string", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
    try std.testing.expectError(error.TypeError, rt.callGlobal("anonSingle", &.{}));
    try std.testing.expectEqualStrings("expected return int, got string", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
    try std.testing.expectError(error.TypeError, rt.callGlobal("anonMulti", &.{}));
    try std.testing.expectEqualStrings("return 2: expected int, got string", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
}

// Coverage-audit 2026-09: an anonymous closure's own argTypeError message
// (vm_types.zig) omits the "name: " prefix a top-level function's does —
// no existing test called an anonymous closure directly with a wrong-typed
// argument.
test "compiler: an anonymous closure's arg TypeError omits the function-name prefix" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func g() int {
        \\    f := func(x int) int { return x + 1 }
        \\    return f("hello")
        \\}
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("g", &.{}));
    try std.testing.expectEqualStrings("arg 1: expected int, got string", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
}

// Coverage-audit 2026-09: funcSignatureStr's variadic-parameter formatting
// (vm_types.zig, the "type..." suffix appended to an ArityMismatch
// message's function signature) only runs for a *typed* variadic function
// called with too few fixed arguments — no existing test's variadic
// arity-mismatch case used typed parameters.
test "compiler: an ArityMismatch on a typed variadic function's signature includes the '...' suffix" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f(x int, ...nums int) int { return x }
    );
    try std.testing.expectError(error.ArityMismatch, rt.callGlobal("f", &.{}));
    try std.testing.expectEqualStrings("f: expected at least 1 argument(s), got 0 for f(int, int...)", rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len]);
}

// ── std.string coverage ─────────────────────────────────────────────────
//
// An audit found only 8 of std.string's 25 exports (builder, fields,
// repeat, split, split_once, starts_with, trim, trim_prefix) got any
// exercise anywhere in the suite (compiler_test.zig + tests/spec/*.gengo),
// and even those only on their happy paths. The tests below fill in the
// remaining exports and the untested error/edge branches of the
// partially-covered ones, deriving expected values directly from
// native/string.zig's actual implementation rather than from an assumed
// "standard" string-library convention (its split/trim/pad semantics are
// a from-scratch reimplementation with some of its own quirks — see the
// comments below on trim_left/trim_right vs. trim_prefix/trim_suffix,
// and upper/lower's byte-oriented ASCII-only conversion).

test "compiler: std.string.join concatenates array elements with a separator, including single-element and empty-array edge cases" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.join(["a", "b", "c"], "-") == "a-b-c"
        \\assert std.string.join(["only"], "-") == "only"
        \\assert std.string.join([], "-") == ""
        \\assert std.string.join(["x", "y"], "") == "xy"
    );
}

test "compiler: std.string.join raises TypeError for a non-array argument, including a non-array object like a map" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func joinNonObject() any { return std.string.join(5, ",") }
        \\func joinNonArrayObject() any { return std.string.join({"a": 1}, ",") }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("joinNonObject", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("joinNonArrayObject", &.{}));
}

// upper/lower (nativeStrTransform) apply std.ascii.toUpper/toLower BYTE BY
// BYTE over the raw string bytes — there is no UTF-8 decoding step. A
// multi-byte UTF-8 sequence's bytes are always outside the ASCII
// 'a'-'z'/'A'-'Z' ranges, so they pass through completely unchanged
// (the encoding of "é" is untouched — it does NOT become "É").
test "compiler: std.string.upper/lower perform byte-oriented ASCII-only case conversion; non-ASCII bytes pass through unchanged" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.upper("hello World 123!") == "HELLO WORLD 123!"
        \\assert std.string.lower("HELLO World 123!") == "hello world 123!"
        \\assert std.string.upper("café") == "CAFé"
        \\assert std.string.lower("CAFÉ") == "cafÉ"
    );
}

test "compiler: std.string.contains/starts_with/ends_with cover match, no-match, and empty-substring cases" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.contains("hello world", "wor") == true
        \\assert std.string.contains("hello world", "xyz") == false
        \\assert std.string.contains("hello", "") == true
        \\assert std.string.starts_with("hello", "he") == true
        \\assert std.string.starts_with("hello", "lo") == false
        \\assert std.string.starts_with("hello", "") == true
        \\assert std.string.ends_with("hello", "lo") == true
        \\assert std.string.ends_with("hello", "he") == false
        \\assert std.string.ends_with("hello", "") == true
    );
}

// index_of/last_index_of return a RUNE index, not a byte index: the found
// byte offset is converted via utf8RuneCount(s[0..byte_idx]). "héllo" is
// h(1 byte) + é(2 bytes, U+00E9) + "llo"; "llo" starts at byte offset 3
// but rune offset 2 (just "h", "é"), so a byte-index implementation would
// wrongly report 3 here.
test "compiler: std.string.index_of/last_index_of return the FIRST/LAST match's rune offset (not byte offset), and -1 when absent" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.index_of("banana", "an") == 1
        \\assert std.string.last_index_of("banana", "an") == 3
        \\assert std.string.index_of("banana", "xyz") == -1
        \\assert std.string.last_index_of("banana", "xyz") == -1
        \\assert std.string.index_of("héllo", "llo") == 2
    );
}

test "compiler: std.string.count counts non-overlapping occurrences, including the zero-occurrence case" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.count("aaaa", "aa") == 2
        \\assert std.string.count("hello world", "xyz") == 0
        \\assert std.string.count("abcabcabc", "abc") == 3
    );
}

// Regression: nativeStrCount passed an empty substring straight to
// std.mem.count, which asserts (a safety-check panic, not a catchable
// Gengo error) that its needle is non-empty for any length other than
// exactly 1 -- std.string.count(s, "") used to crash the whole process.
// Fixed to treat an empty substring as occurring zero times.
test "compiler: std.string.count treats an empty substring as zero occurrences instead of crashing" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.count("hello", "") == 0
        \\assert std.string.count("", "") == 0
    );
}

// vm_string.zig's per-string rune-offset cache (ensureRuneCache) only
// stores the first RuneCacheMax (512) rune offsets directly; indexing past
// that falls back to utf8ByteOffsetForRuneIndex's uncached linear scan
// (rune_idx >= RuneCacheMax branch in utf8ByteOffsetForRuneIndexCached).
// Ordinary test strings never came close to 512 runes, so that fallback
// path — and indexing/slicing on .dyn_string/.string_view (not just the
// static .string case) at multi-byte rune positions — was untested.
// "é" is 2 bytes/1 rune; std.string.repeat builds this as a real
// heap dyn_string (not a compile-time literal), and slicing it below
// yields a string_view over that dyn_string's backing bytes.
test "compiler: rune-indexed string access past the 512-entry rune cache falls back correctly, on dyn_string and string_view too" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\s := std.string.repeat("é", 600)
        \\assert std.core.len(s) == 600
        \\assert s[0] == "é"
        \\assert s[511] == "é"
        \\assert s[512] == "é"
        \\assert s[599] == "é"
        \\
        \\view := s[500:599]
        \\assert std.core.len(view) == 99
        \\assert view[0] == "é"
        \\assert view[98] == "é"
    );
}

test "compiler: rune-indexed string slicing rejects an out-of-range or backwards range" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\func indexOob() string { return "abc"[10] }
        \\func sliceOob() string { return "abc"[0:10] }
        \\func sliceBackwards() string { return "abcde"[3:1] }
    );
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("indexOob", &.{}));
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("sliceOob", &.{}));
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("sliceBackwards", &.{}));
}

// pad_left/pad_right repeat `pad` to fill the needed width, truncating the
// final repetition if it doesn't divide evenly; if `width <= len(s)` or
// `pad` is empty, the input is returned completely unchanged (no
// truncation happens even when s is already longer than width).
test "compiler: std.string.pad_left/pad_right repeat-and-truncate the pad string, and no-op when already wide enough" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.pad_left("x", 6, "ab") == "ababax"
        \\assert std.string.pad_right("x", 6, "ab") == "xababa"
        \\assert std.string.pad_left("hello", 3, "0") == "hello"
        \\assert std.string.pad_right("hello", 3, "0") == "hello"
        \\assert std.string.pad_left("hi", 5, "") == "hi"
        \\assert std.string.pad_right("hi", 5, "") == "hi"
    );
}

test "compiler: std.string.pad_left/pad_right reject a negative width" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func padLeftNeg() any { return std.string.pad_left("x", -1, "0") }
        \\func padRightNeg() any { return std.string.pad_right("x", -1, "0") }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("padLeftNeg", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("padRightNeg", &.{}));
}

test "compiler: std.string.equal_fold compares case-insensitively, including a genuinely-different-content false case" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.equal_fold("Hello", "hello") == true
        \\assert std.string.equal_fold("HELLO", "hello") == true
        \\assert std.string.equal_fold("Hello", "World") == false
        \\assert std.string.equal_fold("abc", "abcd") == false
    );
}

// contains_any reports whether s contains ANY byte from `chars` (not
// whether it contains `chars` as a substring). An empty `chars` set never
// matches anything, even against a non-empty s.
test "compiler: std.string.contains_any reports whether s contains any byte from a charset" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.contains_any("hello", "aeiou") == true
        \\assert std.string.contains_any("xyz", "aeiou") == false
        \\assert std.string.contains_any("hello", "") == false
        \\assert std.string.contains_any("", "abc") == false
    );
}

// trim_left/trim_right strip a CUTSET of individual bytes repeatedly from
// one side, in any order/count — unlike trim_prefix/trim_suffix, which
// strip one LITERAL string exactly once (and leave the input completely
// unchanged if it doesn't match at that exact position). The same input
// demonstrates the difference: "aaabbbccc" starts with several cutset
// characters "ab" (stripped down to "ccc" by trim_left), but does NOT
// start with the literal string "ab" (trim_prefix leaves it unchanged,
// since the string actually starts with "aa").
test "compiler: std.string.trim_left/trim_right strip a cutset of characters, contrasted with trim_prefix/trim_suffix's literal-string semantics" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.string.trim_left("aabbcabc", "ab") == "cabc"
        \\assert std.string.trim_right("cabcaabb", "ab") == "cabc"
        \\assert std.string.trim_left("aaabbbccc", "ab") == "ccc"
        \\assert std.string.trim_prefix("aaabbbccc", "ab") == "aaabbbccc"
        \\assert std.string.trim_prefix("hello world", "hello ") == "world"
        \\assert std.string.trim_prefix("hello", "xyz") == "hello"
        \\assert std.string.trim_suffix("hello.txt", ".txt") == "hello"
        \\assert std.string.trim_suffix("hello.txt", ".png") == "hello.txt"
    );
}

// split_n caps the number of pieces at n: like Go's strings.SplitN, the
// LAST piece holds the unsplit remainder of the string rather than being
// further divided, once the cap is hit. n == 0 returns an empty array; a
// separator of "" splits at UTF-8 rune boundaries (same as split's own
// empty-separator handling), and n greater than the number of possible
// splits behaves the same as an unlimited split.
test "compiler: std.string.split_n caps piece count, leaving the remainder unsplit in the last piece" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\assert std.core.deep_equal(std.string.split_n("a,b,c,d", ",", 2), ["a", "b,c,d"])
        \\assert std.core.deep_equal(std.string.split_n("a,b", ",", 5), ["a", "b"])
        \\assert std.core.deep_equal(std.string.split_n("abcde", "", 3), ["a", "b", "cde"])
        \\assert std.core.deep_equal(std.string.split_n("anything", ",", 0), [])
        \\func splitNNeg() any { return std.string.split_n("a,b", ",", -1) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("splitNNeg", &.{}));
}

// split always produces count+1 pieces around a literal separator (even
// when the separator never occurs, or the input is empty), and splits at
// UTF-8 rune boundaries when the separator is "".
test "compiler: std.string.split covers a not-found separator and the empty-separator (rune-split) case" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.core.deep_equal(std.string.split("hello", ","), ["hello"])
        \\assert std.core.deep_equal(std.string.split("abc", ""), ["a", "b", "c"])
        \\assert std.core.deep_equal(std.string.split("", ","), [""])
        \\assert std.core.deep_equal(std.string.split("", ""), [])
    );
}

// fields splits on runs of whitespace (space/tab/\n/\r/\x0b/\x0c),
// collapsing consecutive separators and ignoring leading/trailing
// whitespace entirely — an all-whitespace (or empty) input yields an
// empty array, not an array containing empty strings.
test "compiler: std.string.fields collapses consecutive whitespace runs and ignores leading/trailing whitespace" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\assert std.core.deep_equal(std.string.fields("  a   b\tc\r\nd  "), ["a", "b", "c", "d"])
        \\assert std.core.deep_equal(std.string.fields("   "), [])
        \\assert std.core.deep_equal(std.string.fields(""), [])
    );
}

// repeat's happy paths (n == 3, n == 0) are already exercised by
// tests/spec/119_string_stdlib_more.gengo; these cover its two error
// branches: a negative count, and a count that would overflow the
// 64 MiB output cap (checked via a mul-with-overflow guard so a huge
// count can't silently wrap `total` to something small and then write
// past the allocated buffer).
test "compiler: std.string.repeat rejects a negative count and a count exceeding the output size cap" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func repeatNeg() any { return std.string.repeat("x", -1) }
        \\func repeatHuge() any { return std.string.repeat("x", 70000000) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("repeatNeg", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("repeatHuge", &.{}));
}

// ── compiler_decls.zig coverage sweep (2026-08-24) ──────────────────────────
//
// tests/spec/fail/*.gengo (run via chaos_spec_test.zig, also counted in
// tools/coverage.sh's kcov numbers) already exercises the overwhelming
// majority of declaration-level error paths in compiler_decls.zig —
// duplicate names across every declaration kind, self-referential structs,
// subtype parent eligibility, generic function arg-count/constraint
// violations, interface method type mismatches, etc. The tests below target
// specifically what that sweep does NOT reach: the compile-time constant
// arithmetic evaluator's operator paths (only ever exercised there with a
// bare integer literal), generic struct/variant instantiation arg-count
// errors (only a generic FUNC has a fixture), named-error-type and task-type
// declaration conflict checks (no fixture exercises either at all), and a
// few interface/method declaration error paths with no fixture of their own
// (DuplicateInterfaceType, a truly-undeclared method receiver, a bracketed
// receiver on a non-generic type).

test "compiler: compile-time-const range bounds evaluate full arithmetic (+, -, *, **, div, rem, mod, unary minus, parens)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type A int range -5+2..10-3
        \\type B int range 2*3..2**4
        \\type C int range 10 div 4..10 rem 4 + 10 mod 4
        \\type D int range (1+2)*3..(10-2)*2
        \\func mkA(x int) A { return A(x) }
        \\func mkB(x int) B { return B(x) }
        \\func mkC(x int) C { return C(x) }
        \\func mkD(x int) D { return D(x) }
    );
    // A: -3..7
    _ = try rt.callGlobal("mkA", &.{.{ .int = -3 }});
    _ = try rt.callGlobal("mkA", &.{.{ .int = 7 }});
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkA", &.{.{ .int = -4 }}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkA", &.{.{ .int = 8 }}));
    // B: 6..16
    _ = try rt.callGlobal("mkB", &.{.{ .int = 6 }});
    _ = try rt.callGlobal("mkB", &.{.{ .int = 16 }});
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkB", &.{.{ .int = 5 }}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkB", &.{.{ .int = 17 }}));
    // C: 10 div 4 = 2 .. 10 rem 4 + 10 mod 4 = 2 + 2 = 4
    _ = try rt.callGlobal("mkC", &.{.{ .int = 2 }});
    _ = try rt.callGlobal("mkC", &.{.{ .int = 4 }});
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkC", &.{.{ .int = 1 }}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkC", &.{.{ .int = 5 }}));
    // D: (1+2)*3=9 .. (10-2)*2=16
    _ = try rt.callGlobal("mkD", &.{.{ .int = 9 }});
    _ = try rt.callGlobal("mkD", &.{.{ .int = 16 }});
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkD", &.{.{ .int = 8 }}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkD", &.{.{ .int = 17 }}));
}

test "compiler: compile-time-const range bounds support float division" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type E float range 1/4..3/4
        \\func mkE(x float) E { return E(x) }
    );
    _ = try rt.callGlobal("mkE", &.{.{ .float = 0.25 }});
    _ = try rt.callGlobal("mkE", &.{.{ .float = 0.75 }});
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkE", &.{.{ .float = 0.2 }}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkE", &.{.{ .float = 0.8 }}));
}

// Regression: parseConstProduct's "division by zero" guard (`if (rhs == 0)
// return null`) used to run unconditionally before the operator switch, so
// it also rejected `*` and `**` whenever the right operand happened to
// literally be 0 — even though `x * 0` and `x ** 0` are perfectly
// well-defined and involve no division. The compiler misdiagnosed these as
// "not a compile-time constant expression" (error.CompileTimeConstant)
// instead of evaluating them to 0 / 1 respectively. Fixed to only apply the
// zero-check to the division-family operators (/, div, rem, mod).
test "compiler: compile-time-const '*' and '**' evaluate correctly with a literal-0 right operand" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type X int range 0..(5*0)
        \\type Y int range 0..(2**0)
        \\func mkX(x int) X { return X(x) }
        \\func mkY(y int) Y { return Y(y) }
    );
    // 5*0 == 0, so X's range is 0..0.
    _ = try rt.callGlobal("mkX", &.{.{ .int = 0 }});
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkX", &.{.{ .int = 1 }}));
    // 2**0 == 1, so Y's range is 0..1.
    _ = try rt.callGlobal("mkY", &.{.{ .int = 1 }});
    try std.testing.expectError(error.RangeError, rt.callGlobal("mkY", &.{.{ .int = 2 }}));

    // Division-family operators must still correctly reject a literal-0
    // divisor as non-constant.
    try std.testing.expectError(error.CompileTimeConstant, compile(&rt,
        \\type Z int range 0..(5/0)
    ));
}

test "compiler: an unclosed paren in a compile-time-const range expression is reported as a non-constant expression" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.CompileTimeConstant, compile(&rt,
        \\type X int range (5..10
    ));
}

test "compiler: a string or boolean literal used where a compile-time-const range bound must be numeric is rejected" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.CompileTimeConstant, compile(&rt,
        \\type X int range "lo".."hi"
    ));
    var rt2 = try setup();
    defer rt2.deinit();
    try std.testing.expectError(error.CompileTimeConstant, compile(&rt2,
        \\type Y int range true..10
    ));
}

test "compiler: a previously declared top-level const can be used as a compile-time constant in a range bound" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\const MAX = 100
        \\type Score int range 0..MAX
        \\func mk(x int) Score { return Score(x) }
    );
    _ = try rt.callGlobal("mk", &.{.{ .int = 100 }});
    try std.testing.expectError(error.RangeError, rt.callGlobal("mk", &.{.{ .int = 101 }}));
}

// ── Generic struct/variant instantiation arg-count errors ───────────────────
// tests/spec/fail/264 covers wrong arg count for a generic FUNC; nothing
// exercises parseInstArgSpecs' identical checks when the generic being
// instantiated is a struct or variant TYPE (applyGenericInst /
// instantiateGenericType in compiler_decls.zig).

test "compiler: too many type arguments for a generic struct instantiation is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.WrongTypeArgCount, compile(&rt,
        \\type Box[T] struct { val T }
        \\func f() int { b := Box[int, string]{ val: 1 }; return b.val }
    ));
}

test "compiler: too few type arguments for a generic struct instantiation is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.WrongTypeArgCount, compile(&rt,
        \\type Box[T] struct { val T }
        \\func f() int { b := Box[]{ val: 1 }; return b.val }
    ));
}

// Exercises applyGenericInst's variant_t branch (substituteSpec over both a
// single-payload arm's payload_type and a record arm's fields) — no
// existing test instantiates a generic variant type at all.
test "compiler: generic variant instantiation substitutes both a single-payload arm and a record arm" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box[T] variant {
        \\    some(v T),
        \\    none,
        \\}
        \\type Wrapped[T] variant {
        \\    boxed { val T },
        \\    empty,
        \\}
        \\func f() int {
        \\    b := Box[int].some(42)
        \\    switch b {
        \\        case .some { return 1 }
        \\        case .none { return 0 }
        \\    }
        \\}
        \\func g() int {
        \\    w := Wrapped[int].boxed { val: 7 }
        \\    switch w {
        \\        case .boxed { return w.val }
        \\        case .empty { return 0 }
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(i64, 1), (try rt.callGlobal("f", &.{})).int);
    try std.testing.expectEqual(@as(i64, 7), (try rt.callGlobal("g", &.{})).int);
}

// ── Named error type declaration conflicts ───────────────────────────────────
// No existing fixture or test exercises namedErrorTypeDecl's own duplicate/
// conflict checks at all.

test "compiler: duplicate named error type declaration is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type MyErr error
        \\type MyErr error
    ));
}

test "compiler: a named error type name colliding with an existing struct type is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type Foo struct { x int }
        \\type Foo error
    ));
}

test "compiler: a named error type name colliding with an existing function is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\func Foo() int { return 1 }
        \\type Foo error
    ));
}

// ── Task type declaration conflicts ──────────────────────────────────────────
// No existing fixture or test exercises taskDeclBody's own duplicate/
// conflict checks (as opposed to task runtime semantics, well covered
// elsewhere via task_state.zig's own 98% coverage).

test "compiler: duplicate task type declaration is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateTaskType, compile(&rt,
        \\type Worker task func() {}
        \\type Worker task func() {}
    ));
}

test "compiler: a task type name colliding with an existing struct type is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateTaskType, compile(&rt,
        \\type Foo struct { x int }
        \\type Foo task func() {}
    ));
}

test "compiler: a task type name colliding with an existing function is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\func Foo() int { return 1 }
        \\type Foo task func() {}
    ));
}

// ── Interface/method declaration error paths with no fixture of their own ──

test "compiler: duplicate interface type name is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateInterfaceType, compile(&rt,
        \\type Shape interface { area() int }
        \\type Shape interface { area() int }
    ));
}

test "compiler: an interface method parameter list rejects a non-type token where a type annotation is expected" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ExpectedTypeAnnotation, compile(&rt,
        \\type Shape interface { area(123) int }
    ));
}

test "compiler: a method receiver naming a wholly undeclared type is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnknownReceiverType, compile(&rt,
        \\func (s Ghost) foo() int { return 1 }
    ));
}

test "compiler: a bracketed method receiver on a non-generic type is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, compile(&rt,
        \\type Point struct { x int }
        \\func (p Point[T]) foo() int { return 1 }
    ));
}

// ── Struct field self-reference through a map (only [] and ? were covered) ──

test "compiler: a struct can reference its own type through a map value, same as array or optional" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Node struct {
        \\    value int,
        \\    children map[string]Node,
        \\}
        \\func f() int {
        \\    leaf := Node{ value: 10, children: {} }
        \\    root := Node{ value: 1, children: {"a": leaf} }
        \\    return root.children["a"].value
        \\}
    );
    try std.testing.expectEqual(@as(i64, 10), (try rt.callGlobal("f", &.{})).int);
}

// ── vm.zig coverage sweep (2026-08-24) ──────────────────────────────────────
// Black-box additions targeting src/lang/vm.zig's own uncovered opcode
// branches (dispatch loop + opcode handlers), via Runtime.run()/callGlobal()
// only -- vm.zig itself is not touched. See the tests above this section
// header for existing arithmetic-overflow coverage (int add/sub/mul/negation/
// int_div/mod at i64::MIN); the tests below fill specific branches that
// audit found still uncovered rather than re-testing the common cases.

// getShiftArgs (vm.zig) has two branches no existing test hits: a negative
// shift count (bn < 0) raises RangeError outright, and a shift count >= 64
// is clamped to 63 (`@min(bn, 63)`) rather than passed through to a raw
// shift -- which would be undefined behavior in Zig for a shift-amount
// operand that meets or exceeds the operand's bit width. Using a
// zero/negative-one base keeps the clamped shift itself overflow-free so
// this isolates the clamp behavior from the separate signed-overflow guard
// tested elsewhere.
test "compiler: shift by a negative count raises RangeError; a count >= 64 clamps to 63 instead of invoking UB" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func shl(a int, n int) int { return a << n }
        \\func shr(a int, n int) int { return a >> n }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("shl", &.{ .{ .int = 1 }, .{ .int = -1 } }));
    try std.testing.expectError(error.RangeError, rt.callGlobal("shr", &.{ .{ .int = 1 }, .{ .int = -1 } }));
    // 0 << (anything, clamped to 63) == 0.
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("shl", &.{ .{ .int = 0 }, .{ .int = 100 } })).int);
    // -1 >> 63 (arithmetic shift right) == -1: sign bit fills every position.
    try std.testing.expectEqual(@as(i64, -1), (try rt.callGlobal("shr", &.{ .{ .int = -1 }, .{ .int = 500 } })).int);
    // 1 >> 63 (clamped) == 0.
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("shr", &.{ .{ .int = 1 }, .{ .int = 9999 } })).int);
}

// The '**' operator (Op.pow) itself has no direct test anywhere -- only
// std.math.pow (a different, unrelated std-level function) is exercised.
// Covers: plain int**int (result stays int, computed via f64 std.math.pow
// then floatToIntSafe), plain float**float, bigint**int and int**bigint
// (both routed through the isBigInt fast path with a.a_big/b conversion),
// and bigint's explicit negative-exponent rejection (TypeError, not
// RangeError -- read directly from vm.zig's .pow handler). Also covers a
// subtle plain-int edge case: 2**-1 mathematically is 0.5 -- makeNumeric's
// floatToIntSafe (safeI64FromFloat) does NOT reject this as a non-integral
// result; it @truncs first and only round-trip-checks the TRUNCATED value
// (0.0) against itself, which trivially matches. So "int ** negative int"
// silently truncates towards zero (0.5 -> 0) exactly like an explicit
// int(0.5) cast would, rather than erroring -- confirmed by reading
// safeI64FromFloat directly (common.zig), not assumed.
test "compiler: ** (pow) operator covers int/int, float/float, bigint operands, and negative-exponent edge cases" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func powIntInt() int { return 2 ** 10 }
        \\func powFloatFloat() float { return 2.0 ** 0.5 }
        \\func powIntNegExp() int { return 2 ** -1 }
        \\func powBigIntIntStr() string { return string(bigint(2) ** 10) }
        \\func powIntBigIntStr() string { return string(2 ** bigint(3)) }
        \\func powBigIntNegExp() bigint { return bigint(2) ** -1 }
    );
    try std.testing.expectEqual(@as(i64, 1024), (try rt.callGlobal("powIntInt", &.{})).int);
    try std.testing.expectApproxEqAbs(@as(f64, std.math.sqrt2), (try rt.callGlobal("powFloatFloat", &.{})).float, 1e-9);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("powIntNegExp", &.{})).int);
    try std.testing.expectEqualStrings("1024", try vms.asStringValue(try rt.callGlobal("powBigIntIntStr", &.{})));
    try std.testing.expectEqualStrings("8", try vms.asStringValue(try rt.callGlobal("powIntBigIntStr", &.{})));
    try std.testing.expectError(error.TypeError, rt.callGlobal("powBigIntNegExp", &.{}));
}

// bit_and/bit_or/bit_xor/bit_not on plain (non-named) ints are only ever
// checked for their nominal-type-preservation behavior (see "named bitwise
// result retains and validates nominal type" above) -- no test verifies the
// actual computed values of these four opcodes on plain ints.
test "compiler: bitwise &, |, ^, ~ on plain ints compute correct values" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func bAnd(a int, b int) int { return a & b }
        \\func bOr(a int, b int) int { return a | b }
        \\func bXor(a int, b int) int { return a ^ b }
        \\func bNot(a int) int { return ~a }
    );
    try std.testing.expectEqual(@as(i64, 0b1000), (try rt.callGlobal("bAnd", &.{ .{ .int = 0b1100 }, .{ .int = 0b1010 } })).int);
    try std.testing.expectEqual(@as(i64, 0b1110), (try rt.callGlobal("bOr", &.{ .{ .int = 0b1100 }, .{ .int = 0b1010 } })).int);
    try std.testing.expectEqual(@as(i64, 0b0110), (try rt.callGlobal("bXor", &.{ .{ .int = 0b1100 }, .{ .int = 0b1010 } })).int);
    try std.testing.expectEqual(@as(i64, -1), (try rt.callGlobal("bNot", &.{.{ .int = 0 }})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("bNot", &.{.{ .int = -1 }})).int);
}

// compareNumericPair (backs the general/float path of .gt/.lt/.le/.ge)
// explicitly rejects non-finite floats with TypeError -- but .eq/.ne never
// route through compareNumericPair at all for two plain floats; they fall
// straight to Value.equals, which does a bare IEEE `==`. This is an
// intentional asymmetry (found by reading both opcode handlers side by
// side), not a bug: ordering a NaN is nonsensical so it's rejected, but
// structural equality is always well-defined (NaN == NaN is simply false,
// same as Zig/most languages' `==`).
test "compiler: comparing NaN with <,>,<=,>= raises TypeError, but == and != fall back to plain IEEE equality (an intentional asymmetry)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func ltNan() bool { return std.math.nan() < 1.0 }
        \\func gtNan() bool { return std.math.nan() > 1.0 }
        \\func leNan() bool { return std.math.nan() <= std.math.nan() }
        \\func geNan() bool { return std.math.nan() >= std.math.nan() }
        \\func eqNan() bool { return std.math.nan() == std.math.nan() }
        \\func neNan() bool { return std.math.nan() != std.math.nan() }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("ltNan", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("gtNan", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("leNan", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("geNan", &.{}));
    try std.testing.expect(!(try rt.callGlobal("eqNan", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("neNan", &.{})).boolean);
}

// tryStructDunderBinary/tryStructDunderUnary's runtime fallback (used when
// the operand's static type is erased, e.g. inside a type-erased generic
// function body -- see "dunder operators work at runtime inside a
// type-erased generic function body" above, which only exercises the
// __compare__/'>' path). This covers the SAME runtime-fallback mechanism
// for every other dunder it drives: __add__, __sub__, __mul__, __div__,
// __rem__, __eq__/__ne__ (via the same __eq__ dunder, one negated), and
// __neg__ -- none of which were exercised at this layer before, only via
// the compile-time desugar (a + b -> a.__add__(b), which never touches
// tryStructDunderBinary since the desugar fires only when the operand's
// static struct/named type is known at compile time).
test "compiler: every struct dunder operator's runtime fallback (tryStructDunderBinary/Unary) works inside a type-erased generic function body" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box struct { v int }
        \\func (a Box) __add__(b Box) Box { return Box{v: a.v + b.v} }
        \\func (a Box) __sub__(b Box) Box { return Box{v: a.v - b.v} }
        \\func (a Box) __mul__(b Box) Box { return Box{v: a.v * b.v} }
        \\func (a Box) __div__(b Box) Box { return Box{v: a.v div b.v} }
        \\func (a Box) __rem__(b Box) Box { return Box{v: a.v rem b.v} }
        \\func (a Box) __eq__(b Box) bool { return a.v == b.v }
        \\func (a Box) __neg__() Box { return Box{v: -a.v} }
        \\
        \\func addG[T comparable](a T, b T) T { return a + b }
        \\func subG[T comparable](a T, b T) T { return a - b }
        \\func mulG[T comparable](a T, b T) T { return a * b }
        \\func divG[T comparable](a T, b T) T { return a / b }
        \\func remG[T comparable](a T, b T) T { return a rem b }
        \\func eqG[T comparable](a T, b T) bool { return a == b }
        \\func neqG[T comparable](a T, b T) bool { return a != b }
        \\func negG[T comparable](a T) T { return -a }
        \\
        \\func callAdd() int { return addG[Box](Box{v:12}, Box{v:3}).v }
        \\func callSub() int { return subG[Box](Box{v:12}, Box{v:3}).v }
        \\func callMul() int { return mulG[Box](Box{v:12}, Box{v:3}).v }
        \\func callDiv() int { return divG[Box](Box{v:12}, Box{v:3}).v }
        \\func callRem() int { return remG[Box](Box{v:13}, Box{v:5}).v }
        \\func callEq() bool { return eqG[Box](Box{v:3}, Box{v:3}) }
        \\func callNeq() bool { return neqG[Box](Box{v:3}, Box{v:4}) }
        \\func callNeg() int { return negG[Box](Box{v:7}).v }
    );
    try std.testing.expectEqual(@as(i64, 15), (try rt.callGlobal("callAdd", &.{})).int);
    try std.testing.expectEqual(@as(i64, 9), (try rt.callGlobal("callSub", &.{})).int);
    try std.testing.expectEqual(@as(i64, 36), (try rt.callGlobal("callMul", &.{})).int);
    try std.testing.expectEqual(@as(i64, 4), (try rt.callGlobal("callDiv", &.{})).int);
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("callRem", &.{})).int);
    try std.testing.expect((try rt.callGlobal("callEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("callNeq", &.{})).boolean);
    try std.testing.expectEqual(@as(i64, -7), (try rt.callGlobal("callNeg", &.{})).int);
}

// pushFieldFromObject's array branch (.first/.last) handles all four array
// object representations uniformly (.array, .array_managed, .array_view,
// .array_capacity) -- but no existing test exercises .first/.last at all,
// on any representation. Covers a plain array literal (.array_managed), a
// slice expression's result (.array_view), and a post-append array
// (.array_capacity, which only exists after std.core.append reallocates
// into spare backing capacity) -- plus the empty-array IndexOutOfBounds
// error path shared by all representations.
test "compiler: array .first/.last field access works across every array representation, including the empty-array error path" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func firstManaged() int { arr := [10, 20, 30]; return arr.first }
        \\func lastManaged() int { arr := [10, 20, 30]; return arr.last }
        \\func firstView() int { arr := [10, 20, 30, 40]; view := arr[1:3]; return view.first }
        \\func lastView() int { arr := [10, 20, 30, 40]; view := arr[1:3]; return view.last }
        \\func firstCapacity() int {
        \\    arr := []int{}
        \\    arr = std.core.append(arr, 100)
        \\    arr = std.core.append(arr, 200)
        \\    return arr.first
        \\}
        \\func lastCapacity() int {
        \\    arr := []int{}
        \\    arr = std.core.append(arr, 100)
        \\    arr = std.core.append(arr, 200)
        \\    return arr.last
        \\}
        \\func firstEmpty() int { arr := []int{}; return arr.first }
    );
    try std.testing.expectEqual(@as(i64, 10), (try rt.callGlobal("firstManaged", &.{})).int);
    try std.testing.expectEqual(@as(i64, 30), (try rt.callGlobal("lastManaged", &.{})).int);
    try std.testing.expectEqual(@as(i64, 20), (try rt.callGlobal("firstView", &.{})).int);
    try std.testing.expectEqual(@as(i64, 30), (try rt.callGlobal("lastView", &.{})).int);
    try std.testing.expectEqual(@as(i64, 100), (try rt.callGlobal("firstCapacity", &.{})).int);
    try std.testing.expectEqual(@as(i64, 200), (try rt.callGlobal("lastCapacity", &.{})).int);
    try std.testing.expectError(error.IndexOutOfBounds, rt.callGlobal("firstEmpty", &.{}));
}

// Closures/upvalues: a nested closure ('b') capturing a variable ('x') that
// is itself only an UPVALUE of its immediately-enclosing closure ('a'), not
// one of a's own locals -- a transitive/chained upvalue capture, distinct
// from the already-well-covered "closure captures a local of its direct
// enclosing function" case.
test "compiler: a nested closure can capture its enclosing closure's own upvalue (transitive upvalue chain)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func makeNested() int {
        \\    x := 100
        \\    a := func() func() int {
        \\        b := func() int {
        \\            x = x + 1
        \\            return x
        \\        }
        \\        return b
        \\    }
        \\    counter := a()
        \\    r1 := counter()
        \\    r2 := counter()
        \\    return r1 * 1000 + r2
        \\}
    );
    try std.testing.expectEqual(@as(i64, 101102), (try rt.callGlobal("makeNested", &.{})).int);
}

// Closures outliving their defining function's stack frame, combined with a
// heap compaction happening between closure creation and closure
// invocation -- each makeAdder(i) call's frame is long gone by the time the
// closures are actually called, and the intervening churn loop (with a
// small heap) forces at least one real compaction, exercising whatever
// path keeps a closure's captured cell(s) valid/relocated correctly across
// GC (same general bug class as project memory's stale-slice-compaction
// sweep, applied here specifically to closures/upvalue cells rather than
// raw slices).
test "compiler: closures survive heap compaction that happens between their creation and their invocation" {
    var rt = try setupApiRuntime(.{
        .allow_io = false,
        .heap_size_bytes = 128 * 1024,
        .max_objects = 2048,
    });
    defer rt.deinit();

    try std.testing.expect(rt.run(
        \\std := import("std")
        \\func makeAdder(n int) func(int) int {
        \\    return func(x int) int { return x + n }
        \\}
        \\adders := []
        \\func buildAdders() {
        \\    i := 0
        \\    for i < 5 {
        \\        adders = std.core.append(adders, makeAdder(i))
        \\        i = i + 1
        \\    }
        \\}
        \\buildAdders()
        \\func churn() int {
        \\    j := 0
        \\    for j < 3000 {
        \\        junk := "garbage-" + std.conv.to_string(j) + "-more-padding-here"
        \\        _ = std.core.bytelen(junk)
        \\        j = j + 1
        \\    }
        \\    total := 0
        \\    k := 0
        \\    for k < 5 {
        \\        total = total + adders[k](100)
        \\        k = k + 1
        \\    }
        \\    return total
        \\}
    ) == .ok);
    const result = rt.call("churn", &.{});
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(i64, 510), v.int),
        else => return error.TestUnexpectedResult,
    }
}

// InlineVariantValue packs a payload into 36 bits; an int payload outside
// ±2^35 (per value.zig's doc comment) falls back to a heap-allocated
// variant_value object instead. Same variant arm shape, same field-access
// code path (opGetField, since the receiver here is a direct call result,
// not a local -- see the opGetLocalGetField test just below for why that
// distinction used to matter), exercised at both representations --
// confirming the magnitude-based representation switch doesn't silently
// corrupt or truncate the payload at the boundary.
test "compiler: a variant arm's int payload switches from inline to heap representation once it exceeds InlineVariantValue's 36-bit range" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box variant {
        \\    count(n int),
        \\}
        \\func makeSmall() Box { return Box.count(42) }
        \\func makeBig() Box { return Box.count(999999999999) }
        \\func smallInline() int { return makeSmall().n }
        \\func bigHeap() int { return makeBig().n }
    );
    try std.testing.expectEqual(@as(i64, 42), (try rt.callGlobal("smallInline", &.{})).int);
    try std.testing.expectEqual(@as(i64, 999999999999), (try rt.callGlobal("bigHeap", &.{})).int);
}

// Regression: opGetLocalGetField (vm.zig, the get_local+get_field fusion
// used when the field's receiver is a plain local variable/parameter)
// checked only `raw == .object` for its inline-cache fast path and then
// unconditionally required `vms.unboxNamed(raw) == .object`, erroring
// TypeError otherwise -- it had no `.inline_variant` case at all. Its
// non-fused sibling opGetField DOES handle `.inline_variant` explicitly
// before requiring `.object`. The result: `x.fieldName` on a local variable
// holding a small (inline-representable) variant payload raised TypeError,
// while the exact same field access on a non-local receiver (e.g. a
// function call's return value) or on a heap-represented (large-payload)
// variant in a local both worked correctly. Fixed by adding the identical
// `.inline_variant` case to opGetLocalGetField.
test "compiler: dot-field access on an inline (small-payload) variant stored in a local variable works, same as a non-local receiver" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box variant {
        \\    count(n int),
        \\}
        \\func viaLocalSmall() int {
        \\    b := Box.count(42)
        \\    return b.n
        \\}
        \\func viaLocalBig() int {
        \\    b := Box.count(999999999999)
        \\    return b.n
        \\}
        \\func viaCallResult() int {
        \\    return Box.count(7).n
        \\}
    );
    try std.testing.expectEqual(@as(i64, 42), (try rt.callGlobal("viaLocalSmall", &.{})).int);
    try std.testing.expectEqual(@as(i64, 999999999999), (try rt.callGlobal("viaLocalBig", &.{})).int);
    try std.testing.expectEqual(@as(i64, 7), (try rt.callGlobal("viaCallResult", &.{})).int);
}

// ── compiler_stmts.zig coverage sweep (2026-08-24) ──────────────────────────
//
// Targeted at statement-compilation branches in compiler_stmts.zig that were
// under-exercised by both this file and the tests/spec(/fail) corpus (grepped
// first to avoid duplicating existing coverage — e.g. NonExhaustiveSwitch,
// DuplicateDefaultCase, struct-field type-mismatch-on-assign, const-field
// writes, assert non-bool, and multi-assign path targets are all already
// covered by tests/spec/fail/*.gengo and tests/spec/*.gengo, which contribute
// to the same coverage run via chaos_spec_test.zig).
//
// Dead-code finding (reported, not "fixed" — see task instructions): reading
// compiler_stmts.zig's stmt() dispatcher shows `isIndexAssign`/
// `indexAssignStmt` (compiler_stmts.zig ~1156-1206) can never actually run.
// The preceding branch,
//   if ((ptt == .dot or ptt == .lbracket) and isPropertyAssign(c)) { ... }
// already returns true for every input isIndexAssign would also accept: a
// bare `ident[expr] = value` sets isPropertyAssign's `saw_path` on the very
// first `[` token and returns true as soon as balanced-bracket depth hits 0
// at a bare `.eq`, exactly the shape isIndexAssign requires. Since
// isPropertyAssign is checked unconditionally first, isIndexAssign's own
// check is never reached with a true result reachable only through the
// first branch already having consumed it. No test added here can exercise
// indexAssignStmt/isIndexAssign without the dispatcher itself changing —
// doing so would require modifying stmt()'s control flow, out of scope for
// a black-box coverage pass.

test "compiler: 'case .arm_name' is rejected inside a '.type' switch scrutinee" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func f(n int) string {
        \\    switch n.type {
        \\        case .bogus { return "x" }
        \\    }
        \\    return ""
        \\}
    );
    try std.testing.expectEqual(error.UnexpectedToken, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, ".type") != null);
}

// findVariantForArms requires every seen arm name to exist on a candidate
// variant type; an arm name that matches no registered variant leaves the
// exhaustiveness check unable to identify a type to check against, so it's
// silently skipped — no compile error, and the case simply never matches at
// runtime (variant_check compares tag strings and "bogus" never equals any
// real arm name). This documents that switchStmt does NOT validate `.arm`
// names against the scrutinee's actual variant type at compile time.
test "compiler: 'case .arm_name' for a name absent from every registered variant never matches, falling through to default" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Decision variant { allow, deny(string) }
        \\func classify(d Decision) string {
        \\    switch d {
        \\        case .bogus { return "bogus" }
        \\        default { return "fallback" }
        \\    }
        \\    return ""
        \\}
        \\func run() string { return classify(Decision.allow()) }
    );
    const result = try rt.callGlobal("run", &.{});
    try std.testing.expectEqualStrings("fallback", try vms.asStringValue(result));
}

// Plain value switches (no variant-arm `.case` syntax involved) never run
// the exhaustiveness check (seen_arm_count stays 0), so a switch with no
// matching case and no default is a compile-clean runtime no-op: the
// scrutinee is computed, compared against every case, and simply discarded
// when nothing matches.
test "compiler: a plain-value switch with no matching case and no default is a silent runtime no-op" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func classify(n int) int {
        \\    result := 0
        \\    switch n {
        \\        case 1 { result = 100 }
        \\        case 2 { result = 200 }
        \\    }
        \\    return result
        \\}
    );
    const result = try rt.callGlobal("classify", &.{.{ .int = 3 }});
    try std.testing.expectEqual(@as(i64, 0), result.int);
}

// switchStmt performs no duplicate-value detection across cases (unlike the
// duplicate-arm exhaustiveness regression guard for variant switches) — the
// first matching case's jif_pop chain always wins and later duplicate cases
// are simply unreachable dead branches, not a compile error.
test "compiler: duplicate case values in a plain switch compile fine; the first matching case wins" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func classify(n int) string {
        \\    switch n {
        \\        case 1 { return "first" }
        \\        case 1 { return "second" }
        \\        default { return "none" }
        \\    }
        \\    return ""
        \\}
    );
    const result = try rt.callGlobal("classify", &.{.{ .int = 1 }});
    try std.testing.expectEqualStrings("first", try vms.asStringValue(result));
}

test "compiler: 'defer' outside of a function is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DeferOutsideFunction, compile(&rt,
        \\defer std.io.println("x")
    ));
}

test "compiler: 'defer' of a bare non-call expression is rejected" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DeferRequiresCall, compile(&rt,
        \\func f() {
        \\    x := 1
        \\    defer x
        \\}
    ));
}

// direct_named_method's global-name lookup and emitGetGlobal happen before
// argument parsing, so a `TypeName.method(...)` deferred call with zero
// arguments still compiles that far before hitting the "at least one
// argument" check — this exercises that specific ordering.
test "compiler: 'defer TypeName.method()' with no arguments is rejected (missing receiver)" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type MyInt int
        \\func (m MyInt) show() {}
        \\func run() {
        \\    defer MyInt.show()
        \\}
    );
    try std.testing.expectEqual(error.ArityMismatch, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "requires at least one argument") != null);
}

test "compiler: a malformed property name in a defer chain reports ExpectedPropertyName" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ExpectedPropertyName, compile(&rt,
        \\func f() {
        \\    x := 1
        \\    defer x.5
        \\}
    ));
}

// deferStmt's `kw_func => funcLit` branch: an immediately-invoked function
// literal as the deferred call. Combined with a named return value, since
// the design doc notes deferred closures observe/modify named returns via
// upvalues before retSlowPath reads them.
test "compiler: 'defer func() {...}()' (func-literal IIFE) runs at function exit and can mutate a named return" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() (result int) {
        \\    result = 1
        \\    defer func() { result = 99 }()
        \\    return
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 99), result.int);
}

// deferStmt's `.lparen => { expr(); consume(rparen); }` branch: the callee
// is an arbitrary parenthesized expression rather than a bare identifier.
test "compiler: 'defer (expr)()' (parenthesized callee) runs at function exit" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() (result int) {
        \\    result = 1
        \\    adder := func() { result = 77 }
        \\    defer (adder)()
        \\    return
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 77), result.int);
}

// compileDeferBlock's body compiles like an ordinary function body (via
// c.decl() in a loop), so `return` inside a `defer { ... }` block is
// perfectly legal — it just ends the deferred closure's own execution
// early, with no special interaction with the enclosing function's return.
// Note a sharp edge found while writing this test: a BARE `return` (no
// semicolon) immediately followed by another statement on the next physical
// line is NOT safely "return, then unreachable code" here — Gengo has no
// automatic semicolon insertion, so returnStmt's bare-return check
// (`c.check(.rbrace/.eof/.semicolon)`) fails to recognize the return as
// bare and instead parses the following identifier as its return
// *expression* (`return result` swallows the next line's `result`), leaving
// the trailing `= 999` as a syntax error reported against the token AFTER
// it (parsePrecedence's prefix-rule miss advances first, then reports
// against the new c.cur). An explicit `return;` avoids the trap.
test "compiler: a 'defer { ... }' block may contain its own explicit 'return;', ending only the deferred closure" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() (result int) {
        \\    result = 1
        \\    defer {
        \\        result = 55
        \\        return;
        \\        result = 999
        \\    }
        \\    return
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 55), result.int);
}

// LIFO order for defers stacked directly in straight-line code (not inside
// a loop — loop-driven LIFO defer ordering is already covered by
// tests/spec/208_break_with_defer.gengo). Each defer block appends a
// distinct digit, so the resulting string reveals execution order
// unambiguously: last-registered runs first.
test "compiler: multiple stacked 'defer { ... }' statements in one function run in LIFO order" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() (result string) {
        \\    defer { result = result + "3" }
        \\    defer { result = result + "2" }
        \\    defer { result = result + "1" }
        \\    result = "0"
        \\    return
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("0123", try vms.asStringValue(result));
}

// multiBindStmt's is_decl path always calls defineLocal for every name in
// the list with no pre-check for duplicates within that same list, so a
// repeated name is caught only by defineLocal's own "duplicate local
// binding" scan against locals already added earlier in the SAME loop.
test "compiler: declaring the same name twice in one multi-bind list is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateLocal, compile(&rt,
        \\func pair() (int, int) { return 1, 2 }
        \\func g() int {
        \\    a, a := pair()
        \\    return a
        \\}
    ));
}

// Unlike Go's `:=`, which allows redeclaring an existing name in a
// multi-value declaration as long as at least one name on the left is new,
// Gengo's multiBindStmt unconditionally defineLocal()s every name — so
// reusing an already-declared local in the SAME function scope is always a
// DuplicateLocal compile error, never a "partial declare, partial assign".
test "compiler: multi-bind ':=' has no Go-style partial-redeclare — reusing an existing local is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateLocal, compile(&rt,
        \\func pair() (int, int) { return 1, 2 }
        \\func g() int {
        \\    a := 1
        \\    a, b := pair()
        \\    return a + b
        \\}
    ));
}

// emitAssignTargetPath's step_count==0 (bare-variable) branch and its
// dot_name-step branch, exercised together in the SAME multi-assign
// statement — tests/spec/031_multi_assign_paths.gengo and
// 050_weird_multi_assign_unicode_paths.gengo only exercise all-path target
// lists, never a bare variable mixed with a property-access target.
test "compiler: multi-assign mixes a bare-variable target with a property-access target" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box struct { v int }
        \\func f() int {
        \\    a := 0
        \\    b := Box{v: 0}
        \\    a, b.v = 5, 9
        \\    return a + b.v
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 14), result.int);
}

test "compiler: multi-assign mixes a bare-variable target with an index target" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    a := 0
        \\    arr := [0, 0, 0]
        \\    a, arr[1] = 7, 8
        \\    return a + arr[1]
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 15), result.int);
}

// parseAssignTargetList's own bounds check on a bracket-index literal
// (guarding emitAssignTargetPath's later raw @intFromFloat) — mirrors the
// exact `a[1e300], b = x, y` scenario named in that function's doc comment.
test "compiler: an out-of-range array index literal in a multi-assign target list is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.BadNumber, compile(&rt,
        \\func f() {
        \\    arr := [1, 2, 3]
        \\    b := 0
        \\    arr[1e300], b = 1, 2
        \\}
    ));
}

// op_trap_check: the multi-bind `trap` slot panics with TrapFired only when
// its value is non-null; a null value passes through silently. Verified
// both ways in one test (the fail-path alone is already covered by
// tests/spec/fail/079_trap_fires.gengo).
test "compiler: multi-bind 'trap' slot passes through null silently and panics only on a non-null value" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func mayFail(fail bool) (?any, ?error) {
        \\    if fail { return null, std.core.error("boom") }
        \\    return 42, null
        \\}
        \\func ok() any {
        \\    val, trap := mayFail(false)
        \\    return val
        \\}
        \\func bad() any {
        \\    val, trap := mayFail(true)
        \\    return val
        \\}
    );
    const ok_result = try rt.callGlobal("ok", &.{});
    try std.testing.expectEqual(@as(i64, 42), ok_result.int);
    try std.testing.expectError(error.TrapFired, rt.callGlobal("bad", &.{}));
}

// checkStaticFieldAssignTarget's UnknownStructField branch, reached only
// through a direct `root.field = value` assignment statement (propertyAssignStmt) —
// distinct from the existing tests/spec/fail cases, which hit UnknownStructField
// via a struct-literal's unknown key (004) or a plain field READ (010), never
// an assignment STATEMENT's own static check.
test "compiler: assigning to a nonexistent struct field is a compile-time error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnknownStructField, compile(&rt,
        \\type Point struct { x int, y int }
        \\func f() int {
        \\    p := Point{x: 1, y: 2}
        \\    p.z = 5
        \\    return p.x
        \\}
    ));
}

// checkStaticFieldAssignTarget only resolves a direct `root.field` target
// (steps_seen == 0); any chain longer than one dot falls back to the
// runtime-only get_field/set_field path with no compile-time field
// validation at all. Exercises both the plain '=' and compound '+='
// dot_name branches of propertyAssignStmt through a two-level chain.
test "compiler: a multi-level property chain (a.b.c) assigns and compound-assigns via the runtime-only path" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Inner struct { c int }
        \\type Outer struct { b Inner }
        \\func f() int {
        \\    o := Outer{b: Inner{c: 1}}
        \\    o.b.c = 99
        \\    o.b.c += 1
        \\    return o.b.c
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 100), result.int);
}

// cForStmt: all three clauses omitted — `c.match(.semicolon)` (init),
// `!c.match(.semicolon)` (cond), and `!c.check(.lbrace)` (post) all take
// their "omitted" branch. An infinite loop, terminated only by `break`.
test "compiler: C-style for loop with all three clauses omitted runs until 'break'" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    n := 0
        \\    for ;; {
        \\        n++
        \\        if n == 5 { break }
        \\    }
        \\    return n
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 5), result.int);
}

// cForStmt: only the condition clause is present — init and post both
// omitted (post-omission taking the `!c.check(.lbrace)` false branch, the
// only combination among the new for-loop tests here where the loop body
// itself must perform the increment).
test "compiler: C-style for loop with only the condition clause present (init and post omitted)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    i := 0
        \\    for ; i < 5 ; {
        \\        i++
        \\    }
        \\    return i
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 5), result.int);
}

// cForStmt: init clause present (registering a loop-var slot via
// loop_var_name), condition and post both omitted.
test "compiler: C-style for loop with init present, condition and post both omitted" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    n := 0
        \\    for i := 0;; {
        \\        n++
        \\        if n == 3 { break }
        \\    }
        \\    return n
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 3), result.int);
}

// ── Coverage-audit batch, 2026-08-24: Runtime entry points outside the REPL
// persistence area (runFromGbc corruption handling, driveTaskScheduler's
// deadlock guard, compileAndInstall's error path, sleepRemainingMs,
// multi-step sleep, explicit reset(), and construction via
// withPolicy()/initWithPolicy()/tiny resource limits). ─────────────────────

// Every existing GBC corruption test (see the "gbc: reader rejects ..."
// block above) calls gbc_reader.read() directly; Runtime.runFromGbc() —
// the actual public entry point a host embedding a precompiled .gbc
// artifact calls — was only ever exercised against a VALID blob (many
// tests above) or one with a mismatched expected_root_source
// (SourceGraphStale, above). This closes the gap: a corrupted magic and a
// truncated buffer must surface gbc_reader's ReadError cleanly through the
// wrapper (which calls self.reset() before gbc_reader.read()), not crash.
test "gbc: Runtime.runFromGbc rejects a corrupted magic and a truncated blob without crashing" {
    const src = "func f() int { return 1 }";
    var rt2 = try setup();
    defer rt2.deinit();
    try rt2.compileOnly(src, "", .filesystem);
    const bytes = try gbc_writer.write(rt2.chunk_state, std.testing.allocator, .{ .root_source = src });
    defer std.testing.allocator.free(bytes);

    const corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    corrupted[0] = 0x00;
    var rt3 = try setup();
    defer rt3.deinit();
    try std.testing.expectError(error.InvalidMagic, rt3.runFromGbc(corrupted, null));

    var rt4 = try setup();
    defer rt4.deinit();
    try std.testing.expectError(error.TruncatedBody, rt4.runFromGbc(bytes[0..4], null));
}

// driveTaskScheduler's ".task_yielded with nothing ready" branch
// (runtime.zig, "return error.TaskDeadlock") had zero test coverage: every
// existing task test either always has a ready replier, or reaches the
// scheduler's OTHER empty-ready-queue exit (a panicking task dying with
// nothing else ready breaks the loop with plain `.completed`, not
// TaskDeadlock — see "main permanently blocks (silently) ..." above, a
// genuinely different code path). A bare top-level receive() with nothing
// ever spawned is the simplest way to reach the .task_yielded branch with
// an empty ready queue — nothing will ever wake it, so this must surface
// loudly as error.TaskDeadlock rather than hang or silently succeed.
// receive()/self() are legal at top level with no task type declared at
// all (compiler_expr.zig:1191; see the "sending a closure..." tests above
// for the same lexical-legality note).
test "task: main calling receive() with nothing ever spawned raises TaskDeadlock" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.TaskDeadlock, rt.run("result := receive()"));
}

// compileOnly's error path (last_compile_line/col/msg populated on a
// compile failure) is covered extensively above; compileAndInstall calls
// compileOnly internally and was assumed to inherit the same behavior, but
// that assumption itself had no test — compileAndInstall's happy path is
// exercised (defused-code tests above) but never its error path.
test "runtime: compileAndInstall surfaces a compile error the same way compileOnly does" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, rt.compileAndInstall(
        \\subtype X Ghost
    , "", .filesystem));
    try std.testing.expect(rt.last_compile_line != 0);
    try std.testing.expect(std.mem.indexOf(u8, rt.last_compile_msg_buf[0..rt.last_compile_msg_len], "unknown type") != null);
}

// sleepRemainingMs()'s "nothing is currently suspended" branch (returns 0,
// per its own doc comment) had no test — every existing sleep test only
// ever checked ops_budget_remaining and the suspended/completed outcomes,
// never this accessor at all.
test "sleepRemainingMs returns 0 when nothing is suspended" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectEqual(@as(i64, 0), rt.sleepRemainingMs());
    try rt.run("x := 1");
    try std.testing.expectEqual(@as(i64, 0), rt.sleepRemainingMs());
}

// The other two sleepRemainingMs branches: a positive countdown while
// genuinely suspended, and back to 0 once the deadline is forced into the
// past (continueRun's own "is it time yet" check uses the same comparison,
// so this also pins that the two stay consistent with each other).
test "sleepRemainingMs returns a positive countdown while suspended, and 0 once the deadline has passed" {
    var rt = try setup();
    defer rt.deinit();
    rt.setPolicy(.{ .max_ops = 500_000_000 });
    const outcome = try rt.begin(
        \\std := import("std")
        \\std.time.sleep(200)
    );
    try std.testing.expect(outcome == .suspended);
    try std.testing.expect(rt.sleepRemainingMs() > 0);
    rt.vm_state.sleep_deadline_ns = 0;
    try std.testing.expectEqual(@as(i64, 0), rt.sleepRemainingMs());
    try std.testing.expect((try rt.continueRun()) == .completed);
}

// waitOutSuspension's loop (`while (outcome == .suspended)`) only ever had
// single-sleep coverage above ("time sleep suspends and charges..."); a
// script that suspends TWICE before completing was never exercised, so the
// loop body's second iteration (re-reading sleep_deadline_ns, resuming via
// continueRun again) had no test forcing it to actually run more than once.
// Drives it via begin()/continueRun() directly (forcing each deadline into
// the past, same trick the single-sleep test above uses) rather than a real
// wait, for the same test-harness reasons documented on that test.
test "a script that calls std.time.sleep twice resumes correctly across each suspension" {
    var rt = try setup();
    defer rt.deinit();
    rt.setPolicy(.{ .max_ops = 500_000_000 });
    var outcome = try rt.begin(
        \\std := import("std")
        \\var total = 0
        \\std.time.sleep(50)
        \\total = total + 1
        \\std.time.sleep(50)
        \\total = total + 1
        \\func getTotal() int { return total }
    );
    try std.testing.expect(outcome == .suspended);
    rt.vm_state.sleep_deadline_ns = 0;
    outcome = try rt.continueRun();
    try std.testing.expect(outcome == .suspended);
    rt.vm_state.sleep_deadline_ns = 0;
    outcome = try rt.continueRun();
    try std.testing.expect(outcome == .completed);
    const result = try rt.callGlobal("getTotal", &.{});
    try std.testing.expectEqual(@as(i64, 2), result.int);
}

// --- std.time coverage sweep (time.zig) -------------------------------
// Everything below drives std.time purely through Gengo scripts. The
// anchor timestamp 1709622489123 ms is 2024-03-05 07:08:09.123 UTC, a
// Tuesday, hand-derived from the civil-calendar algorithm the compiler
// uses internally (days since 1970-01-01 = 31(Jan)+29(Feb, 2024 is a
// leap year)+4 = 64 days -> 1704067200 + 64*86400 = 1709596800s, plus
// 07:08:09 = 25689s -> 1709622489s, plus .123).

test "compiler: std.time.format renders every supported directive against a known date/time" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\t := std.time.from_unix_ms(1709622489123)
        \\assert t.format("%Y-%m-%d %H:%M:%S.%L") == "2024-03-05 07:08:09.123"
        \\assert t.format("%A %a %B %b") == "Tuesday Tue March Mar"
        \\assert t.format("100%%") == "100%"
        \\p := t.parts()
        \\assert p.weekday == 2
    );
}

test "compiler: std.time.format renders negative years with a leading minus sign and zero-padded magnitude" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\epoch := std.time.from_unix_ms(0)
        \\neg := epoch.add_date(-1972, 0, 0)
        \\assert neg.format("%Y-%m-%d") == "-0002-01-01"
    );
}

// %Q isn't a recognized directive (error.TypeError), and the internal
// 512-byte scratch buffer must reject a rendered string that overflows it
// (error.NoSpaceLeft) rather than corrupting memory.
test "compiler: std.time.format rejects an unknown directive and raises NoSpaceLeft once the rendered string exceeds its internal buffer" {
    var rt = try setup();
    defer rt.deinit();
    const long_fmt = "x" ** 600;
    const src = "std := import(\"std\")\n" ++
        "func badVerb() any {\n" ++
        "    t := std.time.from_unix_ms(0)\n" ++
        "    return t.format(\"%Q\")\n" ++
        "}\n" ++
        "func hugeFmt() any {\n" ++
        "    t := std.time.from_unix_ms(0)\n" ++
        "    return t.format(\"" ++ long_fmt ++ "\")\n" ++
        "}\n";
    try runSrc(&rt, src);
    try std.testing.expectError(error.TypeError, rt.callGlobal("badVerb", &.{}));
    try std.testing.expectError(error.NoSpaceLeft, rt.callGlobal("hugeFmt", &.{}));
}

test "compiler: std.time.parse parses %Y/%m/%d/%H/%M/%S/%L, two-digit years, month/weekday names, and ignores %W's payload" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\t := std.time.parse("2024-03-05 07:08:09.123", "%Y-%m-%d %H:%M:%S.%L")
        \\assert t.unix_ms() == 1709622489123.0
        \\t2 := std.time.parse("24-03-05", "%y-%m-%d")
        \\p2 := t2.parts()
        \\assert p2.year == 2024
        \\assert p2.month == 3
        \\assert p2.day == 5
        \\t3 := std.time.parse("Tuesday, March 05 2024", "%a, %B %d %Y")
        \\p3 := t3.parts()
        \\assert p3.year == 2024
        \\assert p3.month == 3
        \\assert p3.day == 5
        \\t4 := std.time.parse("2024-01-01-XY", "%Y-%m-%d-%W")
        \\p4 := t4.parts()
        \\assert p4.year == 2024
        \\assert p4.month == 1
        \\assert p4.day == 1
    );
}

// %d/%m only range-check against [1,31]/[1,12] — they don't cross-check
// against the actual days-in-month, so an out-of-range-for-its-month day
// like Feb 30 is accepted and rolls forward via the same civil-calendar
// arithmetic add_date uses (Feb 2024 has 29 days, so day 30 = Mar 1).
// This is a real characteristic of the implementation, not a crash.
test "compiler: std.time.parse does not validate day-of-month against the actual month, so Feb 30 rolls over into March" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\t := std.time.parse("2024-02-30", "%Y-%m-%d")
        \\p := t.parts()
        \\assert p.year == 2024
        \\assert p.month == 3
        \\assert p.day == 1
    );
}

test "compiler: std.time.parse raises TypeError on malformed input and RangeError on out-of-range numeric components" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func mismatchLiteral() any { return std.time.parse("2024/03/05", "%Y-%m-%d") }
        \\func tooShort() any { return std.time.parse("2024-03-0", "%Y-%m-%d") }
        \\func trailingExtra() any { return std.time.parse("2024X", "%Y") }
        \\func nonDigitMonth() any { return std.time.parse("ab", "%m") }
        \\func monthOutOfRange() any { return std.time.parse("13", "%m") }
        \\func monthZero() any { return std.time.parse("00", "%m") }
        \\func dayOutOfRange() any { return std.time.parse("32", "%d") }
        \\func dayZero() any { return std.time.parse("00", "%d") }
        \\func hourOutOfRange() any { return std.time.parse("24", "%H") }
        \\func minOutOfRange() any { return std.time.parse("60", "%M") }
        \\func secOutOfRange() any { return std.time.parse("60", "%S") }
        \\func unknownSpec() any { return std.time.parse("x", "%Q") }
        \\func trailingPercent() any { return std.time.parse("abcX", "abc%") }
        \\func badMonthName() any { return std.time.parse("Foo", "%B") }
        \\func badWeekdayName() any { return std.time.parse("Foo", "%a") }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("mismatchLiteral", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("tooShort", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("trailingExtra", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("nonDigitMonth", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("monthOutOfRange", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("monthZero", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("dayOutOfRange", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("dayZero", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("hourOutOfRange", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("minOutOfRange", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("secOutOfRange", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("unknownSpec", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("trailingPercent", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("badMonthName", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("badWeekdayName", &.{}));
}

// add_date rolls calendar-invalid results FORWARD/BACKWARD rather than
// clamping (e.g. Jan 31 + 1 month becomes Mar 3, not Feb 28/29) — this
// exercises the day/month normalization loops for both overflow and
// underflow, across year boundaries, and across the mod-4/mod-100/mod-400
// leap-year rule (1900 is NOT a leap year, 2000 IS).
test "compiler: std.time.add_date rolls calendar-invalid results forward/backward instead of clamping (month-end, leap years, year boundaries)" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\jan31 := std.time.parse("2023-01-31", "%Y-%m-%d")
        \\rolled := jan31.add_date(0, 1, 0)
        \\rp := rolled.parts()
        \\assert rp.year == 2023
        \\assert rp.month == 3
        \\assert rp.day == 3
        \\dec2023 := std.time.parse("2023-12-15", "%Y-%m-%d")
        \\nextYear := dec2023.add_date(0, 1, 0)
        \\np := nextYear.parts()
        \\assert np.year == 2024
        \\assert np.month == 1
        \\assert np.day == 15
        \\jan2024 := std.time.parse("2024-01-15", "%Y-%m-%d")
        \\prevYear := jan2024.add_date(0, -1, 0)
        \\pp := prevYear.parts()
        \\assert pp.year == 2023
        \\assert pp.month == 12
        \\assert pp.day == 15
        \\jan29leap := std.time.parse("2024-01-29", "%Y-%m-%d")
        \\feb29 := jan29leap.add_date(0, 1, 0)
        \\fp := feb29.parts()
        \\assert fp.year == 2024
        \\assert fp.month == 2
        \\assert fp.day == 29
        \\feb29from := std.time.parse("2024-02-29", "%Y-%m-%d")
        \\nextFeb := feb29from.add_date(1, 0, 0)
        \\nfp := nextFeb.parts()
        \\assert nfp.year == 2025
        \\assert nfp.month == 3
        \\assert nfp.day == 1
        \\mar1 := std.time.parse("2023-03-01", "%Y-%m-%d")
        \\backOneDay := mar1.add_date(0, 0, -1)
        \\bp := backOneDay.parts()
        \\assert bp.year == 2023
        \\assert bp.month == 2
        \\assert bp.day == 28
        \\jan1900 := std.time.parse("1900-01-31", "%Y-%m-%d")
        \\rolled1900 := jan1900.add_date(0, 1, 0)
        \\r1900 := rolled1900.parts()
        \\assert r1900.year == 1900
        \\assert r1900.month == 3
        \\assert r1900.day == 3
        \\jan2000 := std.time.parse("2000-01-31", "%Y-%m-%d")
        \\rolled2000 := jan2000.add_date(0, 1, 0)
        \\r2000 := rolled2000.parts()
        \\assert r2000.year == 2000
        \\assert r2000.month == 3
        \\assert r2000.day == 2
        \\jan1_2024 := std.time.parse("2024-01-01", "%Y-%m-%d")
        \\backFar := jan1_2024.add_date(0, 0, -40)
        \\bf := backFar.parts()
        \\assert bf.year == 2023
        \\assert bf.month == 11
        \\assert bf.day == 22
        \\dec15_2023 := std.time.parse("2023-12-15", "%Y-%m-%d")
        \\overflowYear := dec15_2023.add_date(0, 0, 20)
        \\oy := overflowYear.parts()
        \\assert oy.year == 2024
        \\assert oy.month == 1
        \\assert oy.day == 4
    );
}

// The dispatch-level i32 bounds check (on the raw y/m/d arguments) and
// timeAddDate's own @addWithOverflow guards (on year+delta/month+delta/
// day+delta, which can overflow i32 even when each operand individually
// fits) are two distinct RangeError sources — both must be reachable.
test "compiler: std.time.add_date raises RangeError both at the dispatch i32-bounds check and from internal year/month/day overflow" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func yTooBig() any { t := std.time.from_unix_ms(0); return t.add_date(9223372036854775807, 0, 0) }
        \\func yOverflowInternal() any { t := std.time.from_unix_ms(0); return t.add_date(2147483647, 0, 0) }
        \\func mOverflowInternal() any { t := std.time.from_unix_ms(0); return t.add_date(0, 2147483647, 0) }
        \\func dOverflowInternal() any { t := std.time.from_unix_ms(0); return t.add_date(0, 0, 2147483647) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("yTooBig", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("yOverflowInternal", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("mOverflowInternal", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("dOverflowInternal", &.{}));
}

// ISO 8601 week numbering: week 1 is the week containing the year's first
// Thursday, so Jan 1 can fall in the PRIOR year's week 52/53 (2023-01-01,
// a Sunday, is week 52 of 2022) and Dec 31 can fall in the NEXT year's
// week 1 (2018-12-31, a Monday, is week 1 of 2019) — both are real,
// independently-verifiable historical dates.
test "compiler: std.time.iso_week computes ISO 8601 week numbers, including year-boundary weeks that belong to the adjacent year" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\a := std.time.parse("2024-01-01", "%Y-%m-%d")
        \\aw := a.iso_week()
        \\assert aw.year == 2024
        \\assert aw.week == 1
        \\b := std.time.parse("2023-01-01", "%Y-%m-%d")
        \\bw := b.iso_week()
        \\assert bw.year == 2022
        \\assert bw.week == 52
        \\c := std.time.parse("2018-12-31", "%Y-%m-%d")
        \\cw := c.iso_week()
        \\assert cw.year == 2019
        \\assert cw.week == 1
        \\d := std.time.parse("2024-06-15", "%Y-%m-%d")
        \\dw := d.iso_week()
        \\assert dw.year == 2024
        \\assert dw.week == 24
    );
}

test "compiler: std.time.parse_duration parses single/multi-unit, fractional, signed durations and every recognized unit suffix" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func singleUnit() float { return std.time.parse_duration("45s") }
        \\func multiUnit() float { return std.time.parse_duration("1h30m45s") }
        \\func fractional() float { return std.time.parse_duration("1.5h") }
        \\func negative() float { return std.time.parse_duration("-1h30m") }
        \\func positiveSign() float { return std.time.parse_duration("+5s") }
        \\func bareZero() float { return std.time.parse_duration("0") }
        \\func trailingDot() float { return std.time.parse_duration("1.s") }
        \\func nanoseconds() float { return std.time.parse_duration("1000000ns") }
        \\func microsAscii() float { return std.time.parse_duration("500us") }
        \\func microsMicroSign() float { return std.time.parse_duration("500µs") }
        \\func microsGreekMu() float { return std.time.parse_duration("500μs") }
        \\func milliseconds() float { return std.time.parse_duration("250ms") }
        \\func minutes() float { return std.time.parse_duration("2m") }
        \\func hours() float { return std.time.parse_duration("3h") }
    );
    const tol = 1e-9;
    try std.testing.expectApproxEqAbs(@as(f64, 45_000.0), (try rt.callGlobal("singleUnit", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 5_445_000.0), (try rt.callGlobal("multiUnit", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 5_400_000.0), (try rt.callGlobal("fractional", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, -5_400_000.0), (try rt.callGlobal("negative", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 5_000.0), (try rt.callGlobal("positiveSign", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), (try rt.callGlobal("bareZero", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 1_000.0), (try rt.callGlobal("trailingDot", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), (try rt.callGlobal("nanoseconds", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), (try rt.callGlobal("microsAscii", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), (try rt.callGlobal("microsMicroSign", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), (try rt.callGlobal("microsGreekMu", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 250.0), (try rt.callGlobal("milliseconds", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 120_000.0), (try rt.callGlobal("minutes", &.{})).float, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 10_800_000.0), (try rt.callGlobal("hours", &.{})).float, tol);
}

test "compiler: std.time.parse_duration raises ParseError on malformed input (empty, bad unit, no digits, bare sign)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func empty() float { return std.time.parse_duration("") }
        \\func noDigits() float { return std.time.parse_duration("h") }
        \\func badUnit() float { return std.time.parse_duration("10x") }
        \\func bareSign() float { return std.time.parse_duration("-") }
        \\func barePlus() float { return std.time.parse_duration("+") }
    );
    try std.testing.expectError(error.ParseError, rt.callGlobal("empty", &.{}));
    try std.testing.expectError(error.ParseError, rt.callGlobal("noDigits", &.{}));
    try std.testing.expectError(error.ParseError, rt.callGlobal("badUnit", &.{}));
    try std.testing.expectError(error.ParseError, rt.callGlobal("bareSign", &.{}));
    try std.testing.expectError(error.ParseError, rt.callGlobal("barePlus", &.{}));
}

test "compiler: std.time object methods (add_h/add_m/add_s/add_ms, before/after/equal, is_zero, sub, unix/unix_ms) reach their native dispatch" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\t1 := std.time.from_unix_ms(1000)
        \\h1 := t1.add_h(1)
        \\assert h1.unix_ms() == 3601000.0
        \\m1 := t1.add_m(1)
        \\assert m1.unix_ms() == 61000.0
        \\s1 := t1.add_s(1)
        \\assert s1.unix_ms() == 2000.0
        \\ms1 := t1.add_ms(500)
        \\assert ms1.unix_ms() == 1500.0
        \\t2 := std.time.from_unix_ms(2000)
        \\assert t1.before(t2) == true
        \\assert t2.after(t1) == true
        \\assert t1.equal(t1) == true
        \\assert t1.equal(t2) == false
        \\assert t2.sub(t1) == 1000.0
        \\assert t1.is_zero() == false
        \\zero := std.time.from_unix_ms(0)
        \\assert zero.is_zero() == true
        \\t3 := std.time.from_unix_ms(1500)
        \\assert t3.unix() == 1
        \\t4 := std.time.from_unix(2)
        \\assert t4.unix_ms() == 2000.0
    );
}

test "compiler: std.time.now/since/until execute via native dispatch and produce sane relative durations" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\t := std.time.now()
        \\assert t.since() >= 0.0
        \\future := t.add_h(1)
        \\assert future.until() > 0.0
        \\assert t.until() <= 0.0
    );
}

// timeGetMs unboxes a named Time value down to its underlying float/int
// before this switch ever runs, so the switch's own '.object' arm is only
// reachable when the argument is some OTHER kind of object entirely (an
// array here) — a non-Time value passed where a Time is expected. A
// non-object, non-numeric value (a plain string) instead falls through
// the outer switch's own 'else' arm.
test "compiler: std.time methods raise TypeError when passed a non-Time object or non-numeric argument" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func nonTimeArg() any { t := std.time.from_unix_ms(0); return t.equal([1, 2, 3]) }
        \\func nonNumericArg() any { t := std.time.from_unix_ms(0); return t.equal("nope") }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("nonTimeArg", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("nonNumericArg", &.{}));
}

// timeEpochMsToParts guards against a ms value so large it can't be
// represented as an i64 (e.g. 1e20 >= 2^63), returning the zeroed epoch
// instead of an @intFromFloat panic.
test "compiler: std.time.parts on an out-of-i64-range ms value returns the zeroed epoch instead of crashing" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run(
        \\std := import("std")
        \\huge := std.time.from_unix_ms(1e20)
        \\p := huge.parts()
        \\assert p.year == 0
        \\assert p.month == 1
        \\assert p.day == 1
        \\assert p.hour == 0
        \\assert p.weekday == 0
    );
}

// Runtime.reset() is called internally by every run()/runPath(), so its
// lines are technically already exercised — but nothing ever called it
// EXPLICITLY and then verified a previous script's global genuinely
// doesn't leak into the next run on the same Runtime (as opposed to just
// re-verifying run()'s own internal reset() call, which every two-script
// test already does implicitly).
test "Runtime.reset() clears globals so a previous script's global is not callable afterward" {
    var rt = try setup();
    defer rt.deinit();
    try rt.run("func onlyInFirst() int { return 42 }");
    const first = try rt.callGlobal("onlyInFirst", &.{});
    try std.testing.expectEqual(@as(i64, 42), first.int);

    rt.reset();
    try rt.run("func onlyInSecond() int { return 7 }");
    try std.testing.expectError(error.NotDefined, rt.callGlobal("onlyInFirst", &.{}));
    const second = try rt.callGlobal("onlyInSecond", &.{});
    try std.testing.expectEqual(@as(i64, 7), second.int);
}

// Regression: Runtime.withPolicy() delegates to the bare, no-argument
// Runtime.init(), which pins chunk/globals/heap/vm/tasks/net/http/fs_state
// the same way initWithConfig() does, but — unlike
// initWithConfig()/initWithPolicy() — used to never call
// heap_state.init()/vm_state.init(). heap.State.heap and vm_state.State.
// stack/frames/defer_stack all default to zero-length slices, and the lazy
// self-healing fallback inside heap.State.reset()/vm_state.State.reset()
// ("if len == 0 and self == &g_default_state, init from module defaults")
// only fires for the process-global default singleton — never for a
// per-Runtime instance's own embedded heap_state/vm_state fields. The
// result: a Runtime built via withPolicy() (or the bare init() it wraps)
// had a genuinely zero-capacity VM stack, frame stack, defer stack, and
// object heap on every native target — the very first real allocation or
// stack push a compiled script performed would fail immediately. Fixed by
// having init() call heap_state.init()/vm_state.init() with the same
// default sizes initWithPolicy() already uses, before reset().
test "Runtime.withPolicy() allocates real heap/stack storage and can run a script" {
    var rt = Runtime.withPolicy(.{ .allow_io = false });
    defer rt.deinit();
    try std.testing.expect(rt.vm_state.stack.len > 0);
    try std.testing.expect(rt.vm_state.frames.len > 0);
    try std.testing.expect(rt.vm_state.defer_stack.len > 0);
    try std.testing.expect(rt.heap_state.heap.len > 0);

    try rt.run(
        \\func double(n int) int { return n * 2 }
    );
    const v = try rt.callGlobal("double", &.{.{ .int = 21 }});
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

// The correct counterpart to the above: initWithPolicy() (unlike
// withPolicy()) routes through initWithConfig() with the normal preset
// sizes, so it allocates real storage and is immediately usable — this had
// no direct test either (every existing test uses initWithConfig directly,
// or the setup() helper which does the same).
test "Runtime.initWithPolicy() correctly allocates storage and is immediately usable" {
    var rt: Runtime = .{};
    try rt.initWithPolicy(.{ .allow_io = false });
    defer rt.deinit();
    try std.testing.expect(rt.vm_state.stack.len > 0);
    try std.testing.expect(rt.heap_state.heap.len > 0);
    try rt.run("func f() int { return 9 }");
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 9), result.int);
}

// A deliberately-too-small max_stack must raise a clean, catchable
// error.StackOverflow (via runUntilSuspend's own top-level bounds check,
// vm.zig ~5229) rather than an out-of-bounds crash — no existing test
// varies max_stack/max_frames away from the normal preset (only heap_size
// and max_objects are varied anywhere in this file).
test "initWithConfig with a too-small max_stack raises a clean StackOverflow instead of crashing" {
    var rt: Runtime = .{};
    try rt.initWithConfig(.{ .allow_io = false }, heap.HeapSize, heap.MaxObjects, 1, vms.MaxFrames, cfg.max_defers, std.testing.allocator);
    defer rt.deinit();
    try std.testing.expectError(error.StackOverflow, rt.run(
        \\a := 1
        \\b := 2
        \\c := a + b
    ));
}

// Same idea for max_frames: two nested calls (f() calling g()) with only
// one frame slot available must raise error.CallStackOverflow cleanly
// (vm.zig's frame-entry bounds check) rather than crashing. g() is called
// from a non-tail position (assigned to a local, not `return g()` directly)
// — a plain `return g()` compiles to a tail call that reuses f()'s own
// frame instead of pushing a new one, which would never exceed max_frames
// no matter how small, and did not (found while writing this test).
test "initWithConfig with a too-small max_frames raises a clean CallStackOverflow instead of crashing" {
    var rt: Runtime = .{};
    try rt.initWithConfig(.{ .allow_io = false }, heap.HeapSize, heap.MaxObjects, vms.MaxStack, 1, cfg.max_defers, std.testing.allocator);
    defer rt.deinit();
    try std.testing.expectError(error.CallStackOverflow, rt.run(
        \\func g() int { return 1 }
        \\func f() int {
        \\    x := g()
        \\    return x + 1
        \\}
        \\_ = f()
    ));
}

// ── Second coverage pass: cast/tuple/iterator/assert/named-validation/swap-dup2 ──
//
// This section deliberately avoids re-testing shift-op edge cases, `**`,
// plain bitwise ops, NaN comparisons, array .first/.last, struct dunder
// dispatch, closure/compaction interaction, and inline-vs-heap variant
// payloads -- a prior pass already covered those. See each test's comment
// for exactly which vm.zig opcode/branch it targets.

test "compiler: int(x) truncates toward zero for both positive and negative fractional floats" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func pos() int { return int(3.9) }
        \\func neg() int { return int(-3.9) }
    );
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("pos", &.{})).int);
    try std.testing.expectEqual(@as(i64, -3), (try rt.callGlobal("neg", &.{})).int);
}

// floatToIntSafe (common.safeI64FromFloat) guards cast_int's @intFromFloat
// against a float too large to represent as i64 and against NaN -- both
// raise RangeError instead of triggering @intFromFloat's UB/trap.
test "compiler: int(x) raises RangeError instead of trapping on an out-of-i64-range float or NaN" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func huge() int { return int(1.0e300) }
        \\func nanv() int { return int(std.math.nan()) }
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("huge", &.{}));
    try std.testing.expectError(error.RangeError, rt.callGlobal("nanv", &.{}));
}

// cast_string's VM handler explicitly rejects .null before ever calling
// nativeConvToString (`if (v == .null) return error.TypeError`), even
// though nativeConvToString itself formats null as the string "null" (used
// by std.conv.to_string(null), which succeeds via the plain call path
// instead of lowering to cast_string -- see "std.conv.to_string does NOT
// lower for a null-typed arg" above). The direct `string(...)` builtin
// always lowers to cast_string unconditionally, so string(null) hits this
// gate and errors -- a real asymmetry between the two paths that this test
// pins down at the opcode level.
test "compiler: string(null) raises TypeError even though std.conv.to_string(null) succeeds" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() string { return string(null) }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("f", &.{}));
}

// cast_bool's switch only has arms for int/float/rune/boolean -- there is no
// string or decimal truthiness rule at all (unlike some languages' "empty
// string is falsy" convention). Both empty and non-empty strings error the
// same way.
test "compiler: bool(x) has no string truthiness rule -- both empty and non-empty strings raise TypeError" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func fromEmpty() bool { return bool("") }
        \\func fromNonEmpty() bool { return bool("hi") }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("fromEmpty", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("fromNonEmpty", &.{}));
}

// cast_rune's only accepted source kinds are .rune (pass through) and .int
// (range-checked against the full Unicode scalar range 0..0x10FFFF
// inclusive); every other source kind, and out-of-range ints, raise
// TypeError. rune(...) is not itself a builtin call form (unlike
// int/float/bool/string/bigint) -- cast_rune is only reachable via a
// `var x rune = <expr>` declaration whose RHS isn't already proven rune.
test "compiler: a rune-typed var declaration accepts the full Unicode scalar range and rejects anything past it" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func atMax() rune { var r rune = 1114111; return r }
        \\func pastMax() rune { var r rune = 1114112; return r }
        \\func negative() rune { var r rune = -1; return r }
    );
    try std.testing.expectEqual(@as(u21, 1114111), (try rt.callGlobal("atMax", &.{})).rune);
    try std.testing.expectError(error.TypeError, rt.callGlobal("pastMax", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("negative", &.{}));
}

// cast_bigint accepts bigint/int/string/float (integral, in-i64-range)
// sources but has no arm for .boolean -- bigint(true)/bigint(false) fall
// into the final `else` and raise TypeError. bigint(3.5) is rejected for a
// different reason: it's a float but not integral (@trunc(v.float) !=
// v.float).
test "compiler: bigint(x) rejects a non-integral float and a bool source, both via distinct guards" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func fromFraction() string { return string(bigint(3.5)) }
        \\func fromBool() string { return string(bigint(true)) }
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("fromFraction", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("fromBool", &.{}));
}

// NOTE (not a test): cast_decimal appeared, from reading vm.zig, to have a
// gap -- its switch has arms for int/float/decimal/rune/boolean but none
// for .string. Chasing down a black-box repro revealed something more
// interesting: a bare `decimal` type annotation is rejected as "unknown
// type 'decimal'" EVERYWHERE it could appear as an explicit annotation --
// struct fields and function params/returns (parseFieldTypeSpec's
// identifier-branch list has no arm for "decimal" at all) and plain `var x
// decimal = ...` declarations (compiler_stmts.zig's separate var-decl
// prim-name list also omits it) -- confirmed empirically for all three.
// `decimal` is otherwise usable only via a NAMED type declaration (`type
// Money decimal 2`). The TypeCheck.prim==.decimal variant (and therefore
// cast_decimal's compiler-driven emission sites at compiler.zig's
// emitVarTypeEpilog and compiler_stmts.zig's named-type-constructor var-decl
// path) is consequently unreachable from ordinary Gengo source -- dead code
// from a black-box standpoint, in the same vein as the tuple_get_keep
// opcode documented in this pass's report. Left undocumented as a test
// since there is no source-level repro to pin it to.

// tuple_get with an index beyond 0/1 -- most multi-return tests in this file
// use pairs, so this exercises tuple_get with idx=2 on a genuine 3-value
// build_tuple/tuple_check_arity round trip.
test "compiler: destructuring a 3-value multi-return exercises tuple_get past index 1" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func three() (int, int, int) { return 10, 20, 30 }
        \\func sumThree() int {
        \\    a, b, c := three()
        \\    return a + b + c
        \\}
    );
    const result = try rt.callGlobal("sumThree", &.{});
    try std.testing.expectEqual(@as(i64, 60), result.int);
}

// A direct call to a function with a statically-known named_return_count
// (>=2, so it uses call_spread) assigned into a multi-assign with a
// DIFFERENT target count doesn't get caught at compile time: the N spread
// values are re-packed into a tuple (build_tuple) and then
// tuple_check_arity enforces the target count at runtime, raising
// ArityMismatch -- there is no compile-time arity check for this path.
test "compiler: destructuring a 3-return call into 2 targets raises ArityMismatch at runtime, not a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func three() (int, int, int) { return 1, 2, 3 }
        \\func g() int {
        \\    a, b := three()
        \\    return a + b
        \\}
    );
    try std.testing.expectError(error.ArityMismatch, rt.callGlobal("g", &.{}));
}

// iter_next1 over a map yields keys only (no values) -- for-in over a map
// with a single loop variable was entirely untested in this file before.
test "compiler: for-in with one loop variable over a map yields keys only (iter_next1)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func sumKeys() int {
        \\    m := {"a": 100, "bb": 200, "ccc": 300}
        \\    total := 0
        \\    for k in m { total += std.core.len(k) }
        \\    return total
        \\}
    );
    const result = try rt.callGlobal("sumKeys", &.{});
    try std.testing.expectEqual(@as(i64, 6), result.int);
}

// iter_next2 over a map yields key+value pairs -- also entirely untested
// before (no test in this file used a two-variable for-in over anything).
test "compiler: for-in with two loop variables over a map yields key+value pairs (iter_next2)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func sumValues() int {
        \\    m := {"a": 1, "b": 2, "c": 3}
        \\    total := 0
        \\    for k, v in m { total += v }
        \\    return total
        \\}
    );
    const result = try rt.callGlobal("sumValues", &.{});
    try std.testing.expectEqual(@as(i64, 6), result.int);
}

// iter_next2 over an array yields index+value (distinct from the map case:
// the key is a synthesized int index, not a stored key).
test "compiler: for-in with two loop variables over an array yields index+value (iter_next2)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func sumIndexTimesValue() int {
        \\    xs := [10, 20, 30]
        \\    total := 0
        \\    for i, v in xs { total += i * v }
        \\    return total
        \\}
    );
    // 0*10 + 1*20 + 2*30 = 0 + 20 + 60 = 80
    const result = try rt.callGlobal("sumIndexTimesValue", &.{});
    try std.testing.expectEqual(@as(i64, 80), result.int);
}

// iter_next2 over a string yields rune-index+rune -- uses a multi-byte
// UTF-8 string so the rune index (1, 2, 3...) is distinguishable from a
// byte offset if the implementation ever regressed to counting bytes.
test "compiler: for-in with two loop variables over a multi-byte string yields rune-index+rune (iter_next2)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func lastIndex() int {
        \\    s := "aéb"
        \\    last := -1
        \\    for i, ch in s { last = i }
        \\    return last
        \\}
    );
    const result = try rt.callGlobal("lastIndex", &.{});
    try std.testing.expectEqual(@as(i64, 2), result.int);
}

// iterInit special-cases an empty array/string/map to the shared
// `empty_iterator` singleton (never allocates a real iterator object) --
// confirm both the one- and two-variable for-in forms run zero iterations
// without crashing over an empty array and an empty map.
test "compiler: for-in over an empty array and an empty map runs zero iterations without crashing" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func overEmptyArray() int {
        \\    count := 0
        \\    for x in [] { count += 1 }
        \\    return count
        \\}
        \\func overEmptyMapOneVar() int {
        \\    count := 0
        \\    m := {}
        \\    for k in m { count += 1 }
        \\    return count
        \\}
        \\func overEmptyMapTwoVar() int {
        \\    count := 0
        \\    m := {}
        \\    for k, v in m { count += 1 }
        \\    return count
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("overEmptyArray", &.{})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("overEmptyMapOneVar", &.{})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("overEmptyMapTwoVar", &.{})).int);
}

// iterInit's .named_type branch fires when the for-in iterable expression
// evaluates to a range-constrained named TYPE itself (not an instance of
// it) -- `for x in Percent` iterates the type's declared min..max inclusive
// range, one step at a time, via iter_next1's .range arm. This whole
// feature (iterating a type name directly) had no test in this file.
test "compiler: for-in over a range-constrained named TYPE (not an instance) iterates its declared min..max" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Percent int range 0..5
        \\func sumRange() int {
        \\    total := 0
        \\    for x in Percent { total += x }
        \\    return total
        \\}
    );
    // 0+1+2+3+4+5 = 15
    const result = try rt.callGlobal("sumRange", &.{});
    try std.testing.expectEqual(@as(i64, 15), result.int);
}

// iterNext2's .range arm is an explicit `return error.TypeError` -- a
// range-constrained named type is only iterable as a single value stream,
// never as a key+value pair. The compiler doesn't reject `for i, x in
// Percent` at compile time (forInStmt always emits iter_next2 for a
// two-name for-in regardless of the iterable's actual kind), so this is a
// genuinely reachable runtime error from ordinary-looking (if unusual)
// source.
test "compiler: for-in with two loop variables over a range-constrained named TYPE raises TypeError (iter_next2 has no .range arm)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Percent int range 0..5
        \\func bad() int {
        \\    total := 0
        \\    for i, x in Percent { total += x }
        \\    return total
        \\}
    );
    try std.testing.expectError(error.TypeError, rt.callGlobal("bad", &.{}));
}

// assert_interface's PASS path: a struct genuinely satisfying an interface,
// routed through an `any`-typed identity function so the compiler cannot
// statically prove conformance (rhs_info.struct_type is cleared across a
// call boundary) and must fall back to the runtime check. Every existing
// assert_interface test in this file exercises the FAIL path (a struct that
// does NOT conform); this confirms the pass side of the same opcode.
test "compiler: assert_interface's runtime check passes for a genuinely-conforming struct routed through an any-typed boundary" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Circle struct { r int }
        \\func (c Circle) area() int { return c.r * c.r }
        \\type Shaped interface { area() int }
        \\func identity(x any) any { return x }
        \\func g() int {
        \\    var s Shaped = identity(Circle{r: 5})
        \\    return s.area()
        \\}
    );
    const result = try rt.callGlobal("g", &.{});
    try std.testing.expectEqual(@as(i64, 25), result.int);
}

// assert_struct had NO test coverage in this file at all. Same any-typed
// boundary trick as above: a var declared with an explicit struct type,
// initialized from a value the compiler can't statically prove is that
// struct. Covers both the matching (pass) and mismatched (fail) cases.
test "compiler: assert_struct's runtime check passes for a matching struct and fails for a different one, both routed through an any-typed boundary" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Point struct { x int, y int }
        \\type Other struct { z int }
        \\func identity(x any) any { return x }
        \\func good() int {
        \\    var p Point = identity(Point{x: 3, y: 4})
        \\    return p.x + p.y
        \\}
        \\func bad() int {
        \\    var p Point = identity(Other{z: 1})
        \\    return p.x
        \\}
    );
    const good_result = try rt.callGlobal("good", &.{});
    try std.testing.expectEqual(@as(i64, 7), good_result.int);
    try std.testing.expectError(error.TypeError, rt.callGlobal("bad", &.{}));
}

// assert_variant had NO test coverage in this file at all. Same pattern:
// a var declared with an explicit variant type, initialized through an
// any-typed identity call so the compiler can't prove the variant type
// statically and must emit assert_variant. Covers a genuinely matching
// variant (pass) and a plain int masquerading as one (fail, since
// Value.asVariant() returns null for a non-variant value).
test "compiler: assert_variant's runtime check passes for a matching variant and fails for a non-variant value" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Shape variant { circle(float), square(float) }
        \\func identity(x any) any { return x }
        \\func good() float {
        \\    var s Shape = identity(Shape.circle(5.0))
        \\    switch s {
        \\        case .circle as r { return r }
        \\        default { return -1.0 }
        \\    }
        \\    return -2.0
        \\}
        \\func bad() float {
        \\    var s Shape = identity(5)
        \\    return -3.0
        \\}
    );
    const good_result = try rt.callGlobal("good", &.{});
    try std.testing.expectEqual(@as(f64, 5.0), good_result.float);
    try std.testing.expectError(error.TypeError, rt.callGlobal("bad", &.{}));
}

// zero_struct had NO test coverage in this file at all. It has two distinct
// representations depending on field count: <=SmallStructMaxFields (4)
// fields builds an inline small_struct_instance; more than that builds a
// heap struct_instance with a MapEntry-backed fields slice. Exercise both.
//
// Regression: zeroValueForFieldSpec (vm.zig) used to have arms only for
// null_t/int/float/decimal_t/boolean/rune_t -- there was no .string arm, so
// it fell through to the function's final `return .null`. A string-typed
// struct field with no initializer zero-inited to `null` instead of `""`,
// an asymmetry with a plain `var s string` (whose zero value, per
// emitZeroValue in compiler_decls.zig, IS the empty string constant) --
// `w.s == ""` was silently false for a zero-inited struct field, where the
// same check on a zero-inited bare string local was true. Fixed by adding
// a `.string` arm returning a static empty-string Value (no allocation
// needed, matching emitZeroValue's own empty-string zero value).
test "compiler: an uninitialized struct-typed var declaration zero-inits every scalar field, including string to empty" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Point struct { x int, y int }
        \\type Wide struct { a int, b int, c int, d int, e int, s string, ok bool }
        \\func smallZero() int {
        \\    var p Point
        \\    return p.x + p.y
        \\}
        \\func wideZero() int {
        \\    var w Wide
        \\    extra := 0
        \\    if w.s == "" { extra += 1 }
        \\    if w.ok == false { extra += 1 }
        \\    return w.a + w.b + w.c + w.d + w.e + extra
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("smallZero", &.{})).int);
    try std.testing.expectEqual(@as(i64, 2), (try rt.callGlobal("wideZero", &.{})).int);
}

// checkNamedTypePredicate's error path: when the predicate function ITSELF
// errors (as opposed to evaluating cleanly and returning false), that error
// (not error.PredicateFailed) propagates straight through
// check_named_predicate. `10 div x` raises DivisionByZero for x==0 before
// the predicate's `> 0` comparison ever runs.
test "compiler: a predicate that itself raises an error (not just returns false) propagates that error, not PredicateFailed" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Foo int predicate func(x) { return 10 div x > 0 }
        \\func mk(n int) int { return int(Foo(n)) }
    );
    try std.testing.expectEqual(@as(i64, 5), (try rt.callGlobal("mk", &.{.{ .int = 5 }})).int);
    try std.testing.expectError(error.DivisionByZero, rt.callGlobal("mk", &.{.{ .int = 0 }}));
}

// validate_type_default fires only when a named type declares BOTH a
// default and a predicate (installNamedTypeObject's gate is independent of
// whether the predicate captures anything). Here the predicate has zero
// captured upvalues, so set_named_predicate is never emitted -- only
// validate_type_default runs, at the type declaration itself (top-level
// module init), checking the default against the predicate immediately.
test "compiler: a default value that violates its own (non-capturing) predicate fails at type-declaration time via validate_type_default" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.PredicateFailed, runSrc(&rt,
        \\type Bad int predicate func(x) { return x > 0 } default 0
    ));
}

// validate_named_range's non-cycle path (coerceNamedTypeResult ->
// constructNamedType) enforces a hard range on the result of the SAME
// arithmetic-interleave path already covered for bitwise/shift ops in the
// prior pass, but not yet for plain `+` between two same-named-type range
// values.
test "compiler: adding two range-constrained named values past the max raises RangeError via validate_named_range" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type SmallRange int range 0..10
        \\func overflow() int {
        \\    a := SmallRange(8)
        \\    b := SmallRange(5)
        \\    c := a + b
        \\    return int(c)
        \\}
    );
    try std.testing.expectError(error.RangeError, rt.callGlobal("overflow", &.{}));
}

// validate_named_range's CYCLE path (wrapCycleValueWithError), reached via
// unary minus on a cycle-constrained named value (compiler_expr.zig's
// unaryExpr emits emitNamedValidation right after `neg` for a named
// operand) -- distinct from the hard-error range path above. -10 wraps
// modulo the cycle's span (360) into 0..359: ((-10 - 0) mod 360) = 350.
test "compiler: unary minus on a cycle-constrained named value wraps via validate_named_range instead of erroring" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Degrees int cycle 0..359
        \\func negate() int {
        \\    d := Degrees(10)
        \\    return int(-d)
        \\}
    );
    const result = try rt.callGlobal("negate", &.{});
    try std.testing.expectEqual(@as(i64, 350), result.int);
}

// swap backs the dunder-operator method-call desugar for NAMED (non-struct)
// types too, not just structs -- lookupDunderCallee's is_struct=false branch
// walks the named type's parent chain the same way. Every existing dunder
// test in this file uses either a struct receiver, or (for the decimal
// "genuine gap" test) a named decimal receiver that only checks the
// declaration COMPILES, never actually invoking the operator. An `int`
// base can't be used here: baseHasBuiltinOperator marks __add__ as already
// working for int/float/rune, which makes declaring it a compile-time
// DunderConflict. decimal's __rem__ is explicitly the one gap
// (baseHasBuiltinOperator: `.rem, .compare => false`), so it's both legal
// to declare AND has no built-in fallback to accidentally match -- if the
// dunder (and thus swap) didn't actually fire, `a rem b` would have nothing
// else to fall back to.
test "compiler: a dunder operator declared on a named (non-struct) decimal type dispatches via the same get_global+swap+call desugar" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Money decimal 2
        \\func (a Money) __rem__(b Money) Money { return Money(1.11) }
        \\func remM() string {
        \\    a := Money(2.00)
        \\    b := Money(3.00)
        \\    r := a rem b
        \\    return string(r)
        \\}
    );
    const result = try rt.callGlobal("remM", &.{});
    try std.testing.expectEqualStrings("1.11", try vms.asStringValue(result));
}

// dup2 backs compound assignment on an INDEXED container (`arr[i] += n`,
// `m[k] += n`): dup the (container, key) pair, read the old value via
// get_index, compute, write back via set_index. No existing test in this
// file exercised compound assignment through a bracket index at all (only
// through a dotted field).
test "compiler: compound assignment through a bracket index (dup2 + get_index/set_index) works for both arrays and maps" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func incArr() int {
        \\    a := [1, 2, 3]
        \\    a[1] += 10
        \\    return a[1]
        \\}
        \\func incMap() int {
        \\    m := {"a": 1, "b": 2}
        \\    m["a"] += 100
        \\    return m["a"]
        \\}
    );
    try std.testing.expectEqual(@as(i64, 12), (try rt.callGlobal("incArr", &.{})).int);
    try std.testing.expectEqual(@as(i64, 101), (try rt.callGlobal("incMap", &.{})).int);
}

// continueRun()'s own error-capture branch (`catch |err| { self.captureRuntimeError();
// return err; }`) had no test: every existing sleep/continueRun test only ever resumes
// into a clean completion. A script that panics AFTER resuming from a suspended sleep
// exercises this specifically — the panic must propagate through continueRun (not get
// swallowed or turned into a different outcome) and last_runtime_line must get populated
// exactly the way a non-suspended runtime panic already does elsewhere in this file.
test "continueRun surfaces a runtime panic that occurs after resuming from a suspended sleep" {
    var rt = try setup();
    defer rt.deinit();
    rt.setPolicy(.{ .max_ops = 500_000_000 });
    const outcome = try rt.begin(
        \\std := import("std")
        \\std.time.sleep(50)
        \\x := 1
        \\y := 0
        \\_ = x / y
    );
    try std.testing.expect(outcome == .suspended);
    rt.vm_state.sleep_deadline_ns = 0;
    try std.testing.expectError(error.DivisionByZero, rt.continueRun());
    try std.testing.expect(rt.last_runtime_line != 0);
}

// runPathWithProvider's entire `test_mode and self.test_count > 0` block (the actual
// `gengo --test` PASS/FAIL runner: calling each __test_N global, tallying passed/failed,
// setting test_failed) had zero coverage — every existing runPathWithProvider call in
// this file passes test_mode=false. Covers both the non-rooted (path="", using
// copyTestNamesFromCompiler) and rooted (path set, using copyTestNamesFromSession)
// compile branches, since compileProgram populates test_count/test_names differently
// for each — neither copy function had any coverage either. Uses the same test-block
// syntax as tests/spec/149_test_blocks.gengo. io.werr's PASS/FAIL lines go to fd 2
// (stderr), not fd 1 (the --listen=- IPC channel on fd 1 that allow_io=true would risk
// corrupting per feedback_allow_io_tests) — see io.zig's werr(), unconditional on policy.
test "runtime: runPathWithProvider(test_mode=true) with a non-rooted compile runs test blocks and reports pass/fail" {
    var rt = try setup();
    defer rt.deinit();
    const outcome = try rt.runPathWithProvider(
        \\test "one plus one" {
        \\    assert 1 + 1 == 2
        \\}
        \\test "deliberately fails" {
        \\    assert false
        \\}
    , "", .filesystem, true);
    try std.testing.expect(outcome == .completed);
    try std.testing.expectEqual(@as(u16, 2), rt.test_count);
    try std.testing.expectEqualStrings("one plus one", rt.test_names[0]);
    try std.testing.expectEqualStrings("deliberately fails", rt.test_names[1]);
    try std.testing.expect(rt.test_failed);
}

test "runtime: runPathWithProvider(test_mode=true) with a rooted compile runs test blocks and reports pass/fail" {
    const path = "main.gengo";
    const provider: module_compile.SourceProvider = .{ .table = &.{} };
    var rt = try setup();
    defer rt.deinit();
    const outcome = try rt.runPathWithProvider(
        \\test "two plus two" {
        \\    assert 2 + 2 == 4
        \\}
    , path, provider, true);
    try std.testing.expect(outcome == .completed);
    try std.testing.expectEqual(@as(u16, 1), rt.test_count);
    try std.testing.expectEqualStrings("two plus two", rt.test_names[0]);
    try std.testing.expect(!rt.test_failed);
}

// ── std.core.append on a named array type (second coverage pass) ──────────
//
// nativeAppend's `is_named` branch (core.zig ~119-141) was entirely
// unexercised: every prior std.core.append test appended onto a plain,
// unwrapped array. `var xs []T = [...]` wraps the array in an (anonymous,
// per-decl) named_value whose named_type has base == .array_t and an
// elem_spec pointing at T's own FieldTypeSpec, so appending onto it takes a
// completely different path: each new element is checked against elem_spec
// via matchesTypeSpec (a bare-scalar type-tag check) AND, when T is itself a
// named scalar type, validateErasedNamedValueForSpec re-runs T's full
// construction (range check) and predicate chain on the erased scalar
// value being appended — because matchesTypeSpec alone only confirms "this
// is an int", not "this int is a valid Meter/Score".
test "compiler: std.core.append on a named array type validates each new element's range/predicate/type, not just a bare scalar tag" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Meter int range 0..100
        \\type Score int predicate func(x) { return x >= 0 and x <= 100 }
        \\func appendValidRange() int {
        \\    var xs []Meter = [Meter(10)]
        \\    xs = std.core.append(xs, 20, 30)
        \\    return std.core.len(xs)
        \\}
        \\func appendRangeViolation() []Meter {
        \\    var xs []Meter = [Meter(10)]
        \\    xs = std.core.append(xs, 200)
        \\    return xs
        \\}
        \\func appendValidPredicate() int {
        \\    var xs []Score = [Score(10)]
        \\    xs = std.core.append(xs, 50)
        \\    return std.core.len(xs)
        \\}
        \\func appendPredicateViolation() []Score {
        \\    var xs []Score = [Score(10)]
        \\    xs = std.core.append(xs, 200)
        \\    return xs
        \\}
        \\func appendTypeMismatch() []Meter {
        \\    var xs []Meter = [Meter(10)]
        \\    xs = std.core.append(xs, "not a number")
        \\    return xs
        \\}
        \\func appendedResultStaysArray() bool {
        \\    var xs []Meter = [Meter(10)]
        \\    xs = std.core.append(xs, 20)
        \\    return std.core.is_array(xs) and std.core.type_of(xs) == "array"
        \\}
    );
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("appendValidRange", &.{})).int);
    try std.testing.expectError(error.RangeError, rt.callGlobal("appendRangeViolation", &.{}));
    try std.testing.expectEqual(@as(i64, 2), (try rt.callGlobal("appendValidPredicate", &.{})).int);
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("appendPredicateViolation", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("appendTypeMismatch", &.{}));
    try std.testing.expect((try rt.callGlobal("appendedResultStaysArray", &.{})).boolean);
}

// Coverage-audit 2026-09: vm.zig's validateErasedNamedValueForSpec's `.map`
// case (recursing into a map-typed spec's own key/value specs) was never
// exercised — the array-append test above only ever drives its sibling
// `.array` case. opSetIndex's own `nt.base == .map_t` branch (the one that
// calls validateErasedNamedValueForSpec with a value spec at all) only
// reaches the `.map` case inside that function when the value spec ITSELF
// describes a map — i.e. a named map type whose value type is *another*
// map holding a predicate-checked named scalar. `m["a"] = {"x": 200}`
// assigns a whole inner map literal as `Nested`'s value; validating it
// walks every entry of that literal and re-runs Score's full construction
// (range) + predicate chain on each raw scalar value, the same as the
// array test's elements — confirmed end-to-end via the CLI (`gengo run`)
// before writing this, panicking with `PredicateFailed: ... Score(200)`.
test "compiler: assigning into a named map-of-maps validates the inner map's values against the nested named scalar's predicate" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Score int predicate func(x) { return x >= 0 and x <= 100 }
        \\type Nested map[string]map[string]Score
        \\func setValid() bool {
        \\    var m Nested = {}
        \\    m["a"] = {"x": 50}
        \\    return true
        \\}
        \\func setInvalid() bool {
        \\    var m Nested = {}
        \\    m["a"] = {"x": 200}
        \\    return true
        \\}
    );
    try std.testing.expect((try rt.callGlobal("setValid", &.{})).boolean);
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("setInvalid", &.{}));
}

// ── std.core.remove: front/end-shift branches (second coverage pass) ──────
//
// The prior round covered "middle" (shifts both halves), "last element"
// (the items_len==1 special case that skips both memcpy calls entirely),
// and both out-of-range error paths, but never a removal at index 0 (the
// first memcpy is a no-op, only the second shifts) nor at the true last
// index of a >1-element array (the second memcpy is a no-op, only the
// first copies) — two structurally distinct empty-vs-nonempty memcpy
// combinations nativeRemove's items_len>1 branch can take.
test "compiler: std.core.remove shifts correctly when removing the front or the true last index of a multi-element array" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func removeFront() bool {
        \\    a := [1, 2, 3, 4]
        \\    b := std.core.remove(a, 0)
        \\    return std.core.deep_equal(b, [2, 3, 4]) and std.core.deep_equal(a, [1, 2, 3, 4])
        \\}
        \\func removeTrueLastIndex() bool {
        \\    a := [1, 2, 3, 4]
        \\    b := std.core.remove(a, 3)
        \\    return std.core.deep_equal(b, [1, 2, 3]) and std.core.deep_equal(a, [1, 2, 3, 4])
        \\}
    );
    try std.testing.expect((try rt.callGlobal("removeFront", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("removeTrueLastIndex", &.{})).boolean);
}

// ── std.conv.to_string / string(...) (second coverage pass) ───────────────
//
// nativeConvToString's decimal branch (vmod.decimalRawAndScale), its
// inline_variant branch (both the no-payload and payload-present buffer-
// building code, including the recursive nativeConvToString call on the
// payload), and its actor_ref branch were all unexercised. Also verifies
// that converting a heap object nativeConvToString has no case for at all
// (a struct instance, or a bare closure) correctly falls through to
// stringBytesFromObj and raises TypeError rather than silently succeeding
// with garbage — string(x)/std.conv.to_string(x) share the exact same
// nativeConvToString implementation (cast_string's VM op just calls it
// directly), so testing via the `string(...)` builtin exercises identical
// code to std.conv.to_string.
test "compiler: string(...)/std.conv.to_string cover decimal, inline_variant (with/without payload), actor_ref, and reject struct/closure" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Money decimal 2
        \\type Shape variant {
        \\    tag(label string),
        \\    point,
        \\}
        \\type Box struct { x int }
        \\func decimalToString() string { return string(Money(9.99)) }
        \\func decimalNegativeToString() string { return string(Money(-3.50)) }
        \\func variantNoPayloadToString() string { return string(Shape.point) }
        \\func variantPayloadToString() string { return string(Shape.tag("hi")) }
        \\func actorRefToString() bool {
        \\    a := self()
        \\    s := string(a)
        \\    return std.string.starts_with(s, "actor<")
        \\}
        \\func structToStringErrors() string { return string(Box{x: 1}) }
        \\func closureToStringErrors() string {
        \\    f := func() int { return 1 }
        \\    return string(f)
        \\}
    );
    try std.testing.expectEqualStrings("9.99", try vms.asStringValue(try rt.callGlobal("decimalToString", &.{})));
    try std.testing.expectEqualStrings("-3.5", try vms.asStringValue(try rt.callGlobal("decimalNegativeToString", &.{})));
    try std.testing.expectEqualStrings("Shape.point", try vms.asStringValue(try rt.callGlobal("variantNoPayloadToString", &.{})));
    try std.testing.expectEqualStrings("Shape.tag(hi)", try vms.asStringValue(try rt.callGlobal("variantPayloadToString", &.{})));
    try std.testing.expect((try rt.callGlobal("actorRefToString", &.{})).boolean);
    try std.testing.expectError(error.TypeError, rt.callGlobal("structToStringErrors", &.{}));
    try std.testing.expectError(error.TypeError, rt.callGlobal("closureToStringErrors", &.{}));
}

// ── std.core.type_of (second coverage pass) ────────────────────────────────
//
// Covers three more of nativeTypeNameValue's object branches that the prior
// round's "variant/enum/error/named-error/function/string_view" sweep
// missed: .string_builder, .bigint, and .task_type (a task type's own
// nominal identifier, referenced directly rather than spawned/called — see
// vm.zig's `.task_type` call-dispatch arm, which is the only other place a
// bare task-type identifier value is otherwise consumed).
test "compiler: std.core.type_of covers string_builder, bigint, and task_type values" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Worker task func(start int, reply actor) {}
        \\func typeOfStringBuilder() string {
        \\    b := std.string.builder()
        \\    return std.core.type_of(b)
        \\}
        \\func typeOfBigint() string { return std.core.type_of(bigint(5)) }
        \\func typeOfTaskType() string { return std.core.type_of(Worker) }
    );
    try std.testing.expectEqualStrings("string_builder", try vms.asStringValue(try rt.callGlobal("typeOfStringBuilder", &.{})));
    try std.testing.expectEqualStrings("bigint", try vms.asStringValue(try rt.callGlobal("typeOfBigint", &.{})));
    try std.testing.expectEqualStrings("Worker", try vms.asStringValue(try rt.callGlobal("typeOfTaskType", &.{})));
}

// ── compiler_decls.zig second coverage pass (2026-08-25) ────────────────────
// A first pass already covered the compile-time constant evaluator, generic
// struct/variant/func arg-count errors, named error/task type declarations,
// and interface/method decl gaps. This pass targets what that pass left:
// checkStructFieldType's DIRECT (non-ref) self-reference rejection (never
// exercised by any fixture or test — grep for the exact error text turns up
// only its one definition site), a struct field typed as an interface,
// constrained generic VARIANT type parameters (only generic STRUCT and
// generic FUNC constraints had tests), the "generic interfaces are not yet
// supported" / "generic alias arguments cannot contain type parameters"
// guards, enum explicit-representation-value validation (duplicate and
// out-of-range), the namedTypeDecl-specific bare-`array`-keyword error, and
// the "unknown constraint" diagnostic on both generic funcs and generic
// types (isKnownConstraint's failure path had no test at either call site).

test "compiler: a struct field cannot reference its own type directly (only through [], map, or ?)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnknownStructType, compile(&rt,
        \\type Node struct { value int, next Node }
    ));
}

test "compiler: a struct can reference its own type through a nullable (?) field, same as array or map" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Node struct { value int, next ?Node }
        \\func f() int {
        \\    n2 := Node{ value: 20, next: null }
        \\    n1 := Node{ value: 10, next: n2 }
        \\    if n1.next != null {
        \\        return n1.next.value
        \\    }
        \\    return -1
        \\}
    );
    try std.testing.expectEqual(@as(i64, 20), (try rt.callGlobal("f", &.{})).int);
}

// checkStructFieldType has no dedicated handling for .interface_t at all (it
// falls into the switch's `else => {}` branch, unconditionally allowed) —
// no existing test types a struct FIELD (as opposed to a function
// parameter, which is well covered) as an interface.
test "compiler: a struct field typed as an interface dispatches to whatever concrete value it holds" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Shape interface { area() int }
        \\type Square struct { side int }
        \\func (s Square) area() int { return s.side * s.side }
        \\type Container struct { shape Shape }
        \\func f() int {
        \\    c := Container{ shape: Square{ side: 4 } }
        \\    return c.shape.area()
        \\}
    );
    try std.testing.expectEqual(@as(i64, 16), (try rt.callGlobal("f", &.{})).int);
}

// Generic STRUCT and generic FUNC constraints already had tests; nothing
// instantiated a generic VARIANT with a constrained type parameter.
test "compiler: constrained generic variant type parameter instantiates when the arg satisfies the constraint" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Boxed[T numeric] variant { ok(v T), bad }
        \\func f() int {
        \\    b := Boxed[int].ok(42)
        \\    switch b {
        \\        case .ok as v { return v }
        \\        case .bad { return -1 }
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(i64, 42), (try rt.callGlobal("f", &.{})).int);
}

test "compiler: constrained generic variant type parameter rejects a non-conforming type arg" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ConstraintViolation, compile(&rt,
        \\type Boxed[T numeric] variant { ok(v T), bad }
        \\func f() {
        \\    b := Boxed[string].ok("x")
        \\}
    ));
}

// namedTypeDecl's kind dispatch rejects a bracketed type-parameter list
// before the 'interface' keyword outright; nothing exercised this (as
// opposed to the already-covered generic-struct/generic-variant paths).
test "compiler: a generic interface declaration is a compile error (not yet supported)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, compile(&rt,
        \\type Foo[T] interface { get() T }
    ));
}

// The generic-instantiation-alias path (`type Alias Base[args]`) rejects
// args that still contain a type parameter — only reachable from inside a
// generic function or generic struct/method body, where a bare type
// parameter name resolves to a .type_param alt instead of a concrete type.
test "compiler: a generic type alias cannot be instantiated with a type parameter as its argument" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, compile(&rt,
        \\type Stack[T] struct { items []T }
        \\func f[T](x T) int {
        \\    type Local Stack[T]
        \\    return 0
        \\}
    ));
}

test "compiler: an enum with a duplicate explicit representation value is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\type Flags enum { a = 1, b = 1 }
    ));
}

test "compiler: an enum explicit representation value outside i64 range is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.BadNumber, compile(&rt,
        \\type Big enum { a = 1e300 }
    ));
}

// namedTypeDecl's own bare-`array`-keyword rejection ("use '[]T' syntax for
// array types") is a distinct call site from parseFieldTypeSpec's copy of
// the same message (tests/spec/fail/099_bare_array_type.gengo covers only
// the latter, via `var x array = ...`).
test "compiler: 'type X array' (bare keyword, no []) is a compile error distinct from the var-decl case" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, compile(&rt, "type X array"));
}

// isKnownConstraint's failure path ("unknown constraint '{s}'") had no test
// at either of its two call sites: a generic function's type parameter list
// and a generic type's (struct/variant) type parameter list.
test "compiler: an unrecognized constraint name on a generic function's type parameter is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, compile(&rt,
        \\func f[T bogus](x T) T { return x }
    ));
}

test "compiler: an unrecognized constraint name on a generic struct's type parameter is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, compile(&rt,
        \\type Box[T bogus] struct { val T }
    ));
}

// ── Fourth coverage pass: closure/upvalue sharing, tail-call recursion
// depth, and per-call interface dispatch ──
//
// Targets three specific vm.zig gaps left after three prior passes: (1)
// close_upvalue/make_closure's core "closures share, don't copy, their
// captured environment" correctness property when TWO closures are made
// from the SAME enclosing call and capture the SAME local; (2) call_tail's
// frame-reuse actually preventing a CallStackOverflow on deep self-
// recursion, as a dedicated test rather than an incidental byproduct of a
// max_frames test; (3) invoke_method's inline cache (vm.zig's
// ic_type_idx/ic_func_idx patched bytes) correctly re-resolving per call
// when the same interface-typed call site sees different concrete struct
// types across separate invocations, rather than trusting a stale cached
// (type, func) pair from the first call it ever saw.

test "compiler: two closures made from the same call, capturing the same local, share one mutable upvalue cell" {
    // inc() and get() are both created inside a single makeCounterPair()
    // call and both capture `x`. make_closure's capture-slot loop (vm.zig)
    // must turn `x`'s stack slot into a shared heap `cell` object the FIRST
    // time either closure captures it, and the second closure capturing the
    // same slot must reuse that same cell (the `cur.object.* == .cell`
    // fast path) rather than boxing a fresh copy — otherwise get() would
    // never observe inc()'s mutations.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func makeCounterPair() int {
        \\    x := 0
        \\    inc := func() int { x = x + 1; return x }
        \\    get := func() int { return x }
        \\    a := inc()
        \\    b := get()
        \\    c := inc()
        \\    d := get()
        \\    return a * 1000 + b * 100 + c * 10 + d
        \\}
    );
    // If the two closures wrongly captured independent copies of x, get()
    // would always observe 0 and this would evaluate to 1000 + 0 + 10 + 0.
    try std.testing.expectEqual(@as(i64, 1122), (try rt.callGlobal("makeCounterPair", &.{})).int);
}

test "compiler: deep self-recursive tail calls do not overflow the call-frame stack (call_tail reuses the caller's frame)" {
    // setup() uses vms.MaxFrames, which resolves to the "1m" preset's
    // max_frames = 64 (src/runtime/config_1m.zig) — the default build
    // preset used by `zig build compiler-test`. 50,000 levels of ordinary
    // (non-tail) recursion would blow through 64 available frames almost
    // immediately (error.CallStackOverflow); this only succeeds if
    // `return countDown(n - 1)` really does compile to call_tail and
    // call_tail's tryTailCall really does reuse the current frame instead
    // of pushing a new one, as documented at vm.zig's .call_tail handler
    // and proven incidentally by the max_frames test above this one.
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func countDown(n int) int {
        \\    if n <= 0 { return 0 }
        \\    return countDown(n - 1)
        \\}
    );
    const result = try rt.callGlobal("countDown", &.{.{ .int = 50000 }});
    try std.testing.expectEqual(@as(i64, 0), result.int);
}

test "compiler: interface method dispatch re-resolves per call when the same call site sees different concrete struct types across separate invocations" {
    // describe()'s `sh.name()` is a SINGLE invoke_method bytecode call site,
    // compiled once. describeCircle() and describeSquare() are two separate
    // top-level calls into that same describe() body, each passing a
    // different concrete struct behind the Shape interface parameter.
    // vm.zig's opInvokeMethod patches an inline cache (ic_type_idx,
    // ic_func_idx) into that call site's operand bytes after the first
    // resolution; this proves the IC's `ctx.hs.objectAt(ic_type_idx) ==
    // inst.typ` (or the small_struct_instance equivalent) guard correctly
    // detects the type mismatch on the second, different-typed call and
    // falls back to resolveStructMethod/resolveSmallStructMethod again,
    // rather than wrongly reusing Circle's cached name() for a Square
    // receiver (or vice versa, depending on call order).
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Shape interface { name() string }
        \\type Circle struct { r int }
        \\func (c Circle) name() string { return "circle" }
        \\type Square struct { s int }
        \\func (sq Square) name() string { return "square" }
        \\func describe(sh Shape) string { return sh.name() }
        \\func describeCircle() string {
        \\    c := Circle { r: 5 }
        \\    return describe(c)
        \\}
        \\func describeSquare() string {
        \\    sq := Square { s: 3 }
        \\    return describe(sq)
        \\}
    );
    const circle_result = try rt.callGlobal("describeCircle", &.{});
    try std.testing.expectEqualStrings("circle", circle_result.string.bytes);
    const square_result = try rt.callGlobal("describeSquare", &.{});
    try std.testing.expectEqualStrings("square", square_result.string.bytes);
    // And once more in reverse-first order via a second Runtime to make sure
    // whichever type happened to populate the IC first, the other type is
    // still resolved correctly (guards against an order-dependent bug the
    // above alone couldn't distinguish from "always resolves the SECOND
    // call correctly no matter what").
    var rt2 = try setup();
    defer rt2.deinit();
    try runSrc(&rt2,
        \\type Shape interface { name() string }
        \\type Circle struct { r int }
        \\func (c Circle) name() string { return "circle" }
        \\type Square struct { s int }
        \\func (sq Square) name() string { return "square" }
        \\func describe(sh Shape) string { return sh.name() }
        \\func describeSquare() string {
        \\    sq := Square { s: 3 }
        \\    return describe(sq)
        \\}
        \\func describeCircle() string {
        \\    c := Circle { r: 5 }
        \\    return describe(c)
        \\}
    );
    const square_result2 = try rt2.callGlobal("describeSquare", &.{});
    try std.testing.expectEqualStrings("square", square_result2.string.bytes);
    const circle_result2 = try rt2.callGlobal("describeCircle", &.{});
    try std.testing.expectEqualStrings("circle", circle_result2.string.bytes);
}

// ── Second coverage-audit pass on compiler_stmts.zig, 2026-08-25 ───────────
// A prior pass covered switch-statement edge cases, defer edge cases,
// multi-bind edge cases, property-assign, and C-style for. This pass reads
// the kcov-reported 155 still-uncovered lines directly and closes as many
// as are reachable from ordinary (non-refactoring) black-box source, while
// documenting a few that turn out to be unreachable dead code.

// cForStmt's init-clause branches: an explicit `i TYPE = expr` (no ':='),
// via isTypedVarDecl(), had no coverage anywhere in this file or the spec
// corpus.
test "compiler: C-style for loop with a typed-var-decl init clause (no ':=')" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    sum := 0
        \\    for i int = 0; i < 3; i++ {
        \\        sum += i
        \\    }
        \\    return sum
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 3), result.int);
}

// cForStmt's `const` init-clause branch.
test "compiler: C-style for loop with a 'const' init clause" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    n := 0
        \\    for const start = 5; n < start; n++ {
        \\    }
        \\    return n
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 5), result.int);
}

// cForStmt's remaining fallback branches: a plain-expression init clause
// (neither decl nor assign), a plain '=' assignment in the post clause
// (instead of '++' or a compound op), and a plain-expression post clause
// (a bare call, neither '++' nor an assignment).
test "compiler: C-style for loop with a plain-expression init clause, an '=' post clause, and a call-expression post clause" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func noop() int { return 0 }
        \\func exprInit() int {
        \\    i := 0
        \\    for noop(); i < 3; i++ {
        \\    }
        \\    return i
        \\}
        \\func assignPost() int {
        \\    i := 0
        \\    for ; i < 3; i = i + 1 {
        \\    }
        \\    return i
        \\}
        \\func exprPost() int {
        \\    i := 0
        \\    for ; i < 3; noop() {
        \\        i = i + 1
        \\    }
        \\    return i
        \\}
    );
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("exprInit", &.{})).int);
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("assignPost", &.{})).int);
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("exprPost", &.{})).int);
}

// ifStmtDepth mirrors cForStmt's init-clause dispatch but had NO coverage
// at all for any branch except the plain ':=' case (tests/spec/010).
test "compiler: if-statement with a typed-var-decl init clause (no ':=')" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    if x int = 5; x > 0 {
        \\        return x
        \\    }
        \\    return -1
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 5), result.int);
}

test "compiler: if-statement with a 'const' init clause" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    if const limit = 7; limit > 5 {
        \\        return limit
        \\    }
        \\    return -1
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 7), result.int);
}

test "compiler: if-statement with a plain assignment init clause and a plain-expression init clause" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func noop() int { return 0 }
        \\func assignInit() int {
        \\    i := 0
        \\    if i = 9; i > 0 {
        \\        return i
        \\    }
        \\    return -1
        \\}
        \\func exprInit() int {
        \\    if noop(); true {
        \\        return 42
        \\    }
        \\    return -1
        \\}
    );
    try std.testing.expectEqual(@as(i64, 9), (try rt.callGlobal("assignInit", &.{})).int);
    try std.testing.expectEqual(@as(i64, 42), (try rt.callGlobal("exprInit", &.{})).int);
}

// compileFuncWithPrefix: a non-literal default parameter value.
test "compiler: a function parameter default value that is not a literal is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt, "func f(x int = y) int { return x }\n");
    try std.testing.expectEqual(error.UnexpectedToken, r.err);
}

// compileFuncWithPrefix: more than MaxLocals ordinary parameters.
test "compiler: a function with more than MaxLocals parameters is a compile error (TooManyParams)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func manyParams(");
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ", ");
        const piece = try std.fmt.bufPrint(&buf, "p{d} int", .{i});
        try src.appendSlice(std.testing.allocator, piece);
    }
    try src.appendSlice(std.testing.allocator, ") int { return 0 }\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyParams, r.err);
}

// compileFuncWithPrefix: more than MaxLocals anonymous return types.
test "compiler: a function with more than MaxLocals return types is a compile error (TooManyParams)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func manyReturns() (");
    var i: u32 = 0;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ", ");
        try src.appendSlice(std.testing.allocator, "int");
    }
    try src.appendSlice(std.testing.allocator, ") {\n    return\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyParams, r.err);
}

// compileFuncWithPrefix: a named return whose name shadows a type name.
test "compiler: a named return value using a type name as its name is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt, "func f() (int int) { return 0 }\n");
    try std.testing.expectEqual(error.UnexpectedToken, r.err);
}

// compileFuncWithPrefix: a named return whose name conflicts with a param.
test "compiler: a named return value whose name conflicts with a parameter name is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt, "func f(x int) (x int) { return }\n");
    try std.testing.expectEqual(error.DuplicateLocal, r.err);
}

// compileFuncWithPrefix's named-return zero-init switch has an arm for
// rune (the decimal_t arm is unreachable dead code -- see the "decimal" NOTE
// elsewhere in this file; a bare `decimal` type annotation is rejected
// everywhere it could appear, so a decimal-typed named return can never be
// constructed from source).
test "compiler: a bare 'return' from a rune-named-return function returns the implicit zero rune" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() (r rune) {
        \\    return
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(u21, 0), result.rune);
}

// compileFuncWithPrefix's prefix loop (method receivers): a receiver named
// after a builtin type name.
test "compiler: a method receiver named after a builtin type name is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Meters int
        \\func (int Meters) show() {}
    );
    try std.testing.expectEqual(error.UnexpectedToken, r.err);
}

// compileFuncWithPrefix's predicate-mode param loop: an explicit type
// annotation (instead of inferring from the base type) plus a trailing
// comma before ')'.
test "compiler: a predicate function literal may give its parameter an explicit type annotation with a trailing comma" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Score int predicate func(x int,) { return x >= 0 }
        \\func f() int { return int(Score(5)) }
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 5), result.int);
}

// compileFuncWithPrefix: a parameter with no type annotation at all.
test "compiler: a function parameter without a type annotation is a compile error (ExpectedTypeAnnotation)" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt, "func f(x = 5) int { return x }\n");
    try std.testing.expectEqual(error.ExpectedTypeAnnotation, r.err);
}

// deferStmt: a bracket index within the chain, before the final method call.
test "compiler: defer chain with a bracket index before the final method call" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Counter struct { n int }
        \\func (c Counter) show() int { return c.n }
        \\func f() int {
        \\    items := [Counter{n: 7}, Counter{n: 9}]
        \\    defer items[0].show()
        \\    return 1
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 1), result.int);
}

// deferStmt: the lexer-error passthrough branches for the callee token.
test "compiler: 'defer' followed immediately by an invalid character is a compile error (InvalidChar)" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func f() {
        \\    defer #
        \\}
    );
    try std.testing.expectEqual(error.InvalidChar, r.err);
}

test "compiler: 'defer' followed immediately by an unterminated string literal is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func f() {
        \\    defer "unterminated
        \\}
    );
    try std.testing.expectEqual(error.UnterminatedString, r.err);
}

test "compiler: 'defer' followed by a bare number literal is a compile error (ExpectedExpression)" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func f() {
        \\    defer 5
        \\}
    );
    try std.testing.expectEqual(error.ExpectedExpression, r.err);
}

// deferStmt's `defer TypeName.method(instance, ...)` rewrite: when the base
// is a named-type SUBTYPE and the method is declared on the parent type, the
// direct_named_method lookup must walk the parent chain (not just try the
// subtype's own qualified name once).
test "compiler: 'defer SubtypeName.method(instance)' resolves the method inherited from the subtype's parent" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Meters int
        \\func (m Meters) show() int { return int(m) }
        \\subtype SmallMeters Meters range 0..100
        \\func g() int {
        \\    x := SmallMeters(5)
        \\    defer SmallMeters.show(x)
        \\    return 1
        \\}
    );
    const result = try rt.callGlobal("g", &.{});
    try std.testing.expectEqual(@as(i64, 1), result.int);
}

// Same rewrite, but the base is a STRUCT type (never a "named type" in the
// registry's sense), so direct_named_method always returns null and the
// call must fall back to a dynamic invoke_method.
test "compiler: 'defer StructType.method(instance)' falls back to a dynamic invoke_method" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Item struct { n int }
        \\func (it Item) reveal() int { return it.n }
        \\func h() int {
        \\    it := Item{n: 7}
        \\    defer Item.reveal(it)
        \\    return 2
        \\}
    );
    const result = try rt.callGlobal("h", &.{});
    try std.testing.expectEqual(@as(i64, 2), result.int);
}

// deferStmt has three independent "too many arguments to deferred call (max
// 254)" argument-parsing loops (the type-qualified-call rewrite, the plain
// dot-method call, and the bare final call) -- none had ANY coverage,
// including their ordinary (non-overflow) loop bodies.
test "compiler: 'defer TypeName.method(...)' resolved via the named-type chain rejects more than 254 arguments" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator,
        \\type Meters int
        \\func (m Meters) show(n int) int { return n }
        \\subtype SmallMeters Meters range 0..100
        \\func g() {
        \\    x := SmallMeters(5)
        \\    defer SmallMeters.show(x
        \\
    );
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, ")\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

test "compiler: 'defer instance.method(...)' rejects more than 254 arguments" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator,
        \\type Widget struct { n int }
        \\func (w Widget) touch(n int) int { return n }
        \\func g() {
        \\    w := Widget{n: 1}
        \\    defer w.touch(0
        \\
    );
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, ")\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

test "compiler: a plain 'defer bareFunc(...)' call (no property chain) rejects more than 254 arguments" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator,
        \\func addMany(a int) int { return a }
        \\func g() {
        \\    defer addMany(0
        \\
    );
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, ")\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// emitAssignTargetPath: an index step (number or string) that is an
// INTERMEDIATE step in a multi-assign target's chain, not the final one --
// the existing tests/spec/031 coverage only ever uses index steps as the
// LAST step of a target.
test "compiler: multi-assign target chains with an index step before the final property access" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    obj := { "arr": [ { "x": 0 } ], "m": { "k": { "y": 0 } }, "other": 0 }
        \\    obj.arr[0].x, obj.m["k"].y, obj.other = 5, 6, 7
        \\    return obj.arr[0].x + obj.m.k.y + obj.other
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 18), result.int);
}

// emitExprListTuple: a multi-bind RHS value list with more than 255
// elements.
test "compiler: a multi-bind RHS value list longer than 255 elements is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    a, b := 0");
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// forInStmt claims one extra hidden local slot for its iterator object
// AFTER the loop variable(s) are already registered; when that claim
// itself would exceed MaxLocals, it has its own explicit check (distinct
// from defineLocal's).
test "compiler: for-in loop errors with TooManyLocals when claiming its hidden iterator slot would exceed MaxLocals" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() int {\n");
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i < ct.MaxLocals - 1) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "    v{d} := 0\n", .{i});
        try src.appendSlice(std.testing.allocator, line);
    }
    try src.appendSlice(std.testing.allocator, "    for x in [1, 2, 3] {\n        _ = x\n    }\n    return v0\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyLocals, r.err);
}

// multiBindStmt's SPREAD-value path (a direct call to a function with a
// statically-known named_return_count >= 2, matching the target count
// exactly) had no coverage for either its DECL ('trap'-slot and plain-name)
// or plain-ASSIGN branches -- every existing multi-return test in this file
// uses an anonymous-return-type function, which takes the tuple path
// instead of the spread path.
test "compiler: a decl multi-bind ('trap, name :=') destructuring a spread (named-return) call" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func namedPair() (a int, b ?int) {
        \\    a = 5
        \\    return
        \\}
        \\func h() int {
        \\    x, trap := namedPair()
        \\    return x
        \\}
    );
    const result = try rt.callGlobal("h", &.{});
    try std.testing.expectEqual(@as(i64, 5), result.int);
}

test "compiler: a plain multi-assign ('x, y =') destructuring a spread (named-return) call" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func namedPair2() (a int, b int) {
        \\    a = 5
        \\    b = 7
        \\    return
        \\}
        \\func h2() int {
        \\    x := 0
        \\    y := 0
        \\    x, y = namedPair2()
        \\    return x + y
        \\}
    );
    const result = try rt.callGlobal("h2", &.{});
    try std.testing.expectEqual(@as(i64, 12), result.int);
}

// parseAssignTargetList: more than MaxLocals targets in a single plain
// ('=') multi-assign.
test "compiler: a plain multi-assign ('=') with more than MaxLocals targets is a compile error (TooManyLocals)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    t0");
    var i: u32 = 1;
    var buf: [16]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        const piece = try std.fmt.bufPrint(&buf, ", t{d}", .{i});
        try src.appendSlice(std.testing.allocator, piece);
    }
    try src.appendSlice(std.testing.allocator, " = 0");
    i = 1;
    while (i <= ct.MaxLocals) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyLocals, r.err);
}

// parseAssignTargetList: a malformed property name in a NON-FIRST target of
// a multi-assign list (the single-target propertyAssignStmt version of this
// check was already covered, but this parser is a separate function).
test "compiler: a malformed property name in a non-first multi-assign target reports ExpectedPropertyName" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func f() {
        \\    a := 0
        \\    b := 0
        \\    a, b.5 = 1, 2
        \\}
    );
    try std.testing.expectEqual(error.ExpectedPropertyName, r.err);
}

// parseAssignTargetList: the shared per-statement steps buffer (sized
// MaxLocals*8) overflowing via a single target's dot chain, and separately
// via a single target's bracket chain.
test "compiler: a multi-assign target's dot chain longer than MaxLocals*8 steps is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    a");
    var i: u32 = 0;
    while (i < ct.MaxLocals * 8 + 1) : (i += 1) try src.appendSlice(std.testing.allocator, ".f");
    try src.appendSlice(std.testing.allocator, ", b = 0, 0\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

test "compiler: a multi-assign target's bracket chain longer than MaxLocals*8 steps is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    a");
    var i: u32 = 0;
    while (i < ct.MaxLocals * 8 + 1) : (i += 1) try src.appendSlice(std.testing.allocator, "[0]");
    try src.appendSlice(std.testing.allocator, ", b = 0, 0\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// parseNameList: more than MaxLocals names in a single decl (':=')
// multi-bind.
test "compiler: a decl multi-bind (':=') with more than MaxLocals names is a compile error (TooManyLocals)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    n0");
    var i: u32 = 1;
    var buf: [16]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        const piece = try std.fmt.bufPrint(&buf, ", n{d}", .{i});
        try src.appendSlice(std.testing.allocator, piece);
    }
    try src.appendSlice(std.testing.allocator, " := 0");
    i = 1;
    while (i <= ct.MaxLocals) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyLocals, r.err);
}

// propertyAssignStmt: a bracket access that is NOT the final step (an
// intermediate array index before a trailing '.field').
test "compiler: assigning through 'arr[i].field' exercises the array-then-property assignment path" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Item struct { x int }
        \\func f() int {
        \\    items := [Item{x: 1}, Item{x: 2}]
        \\    items[0].x = 99
        \\    return items[0].x
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 99), result.int);
}

// returnStmt: more than 255 comma-separated return values.
test "compiler: a return statement with more than 255 comma-separated values is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() int {\n    return 0");
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// Found while auditing returnStmt: a function whose single declared return
// type is a struct or variant accepts a comma-separated multi-value
// `return a, b` without any compile-time type check at all -- the code
// simply sets scope.all_returns_proven = false (disabling a call-site
// optimization) and moves on, unlike the analogous single-value primitive-
// return-type mismatch path, which DOES raise a TypeError. This compiles
// successfully even though the runtime value actually produced (a 2-tuple)
// can never be the declared struct/variant type. Reported, not fixed.
test "compiler: returning multiple comma-separated values from a function declared to return a single struct or variant type compiles without a type error" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Pair struct { a int, b int }
        \\func f() Pair { return 1, 2 }
        \\type Shape variant { Circle, Square }
        \\func g() Shape { return 1, 2 }
    );
}

// stmt()'s dispatch: 'trap' as the FIRST name in a multi-bind decl (the
// generic ident-first multi-bind path was already covered, but the
// trap-first special case at the top of stmt() was not).
test "compiler: 'trap' as the first name in a multi-bind decl is recognized by stmt()'s dispatch" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func maybeErr() (?int, int) { return null, 42 }
        \\func f() int {
        \\    trap, y := maybeErr()
        \\    return y
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 42), result.int);
}

// stmt()'s REPL auto-print bookkeeping: repl_pending_pop only ever gets
// exercised across TWO OR MORE bare expression statements compiled in a
// SINGLE runIncremental() call (compile() resets it to false at the start
// of every call), which no existing REPL test in this file did.
test "compiler: two consecutive bare top-level expression statements in one REPL increment" {
    var rt_repl = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt_repl.deinit();
    const result = rt_repl.runIncremental("1 + 1\n2 + 2");
    try std.testing.expect(result == .ok);
}

// switchStmt: more than MaxCaseVals (32) comma-separated values in a single
// case.
test "compiler: a switch case with more than 32 comma-separated values is a compile error (TooManySwitchCases)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f(x int) int {\n    switch x {\n    case 0");
    var i: u32 = 1;
    var buf: [16]u8 = undefined;
    while (i <= 33) : (i += 1) {
        const piece = try std.fmt.bufPrint(&buf, ", {d}", .{i});
        try src.appendSlice(std.testing.allocator, piece);
    }
    try src.appendSlice(std.testing.allocator, " {\n        return 1\n    }\n    default {\n        return 0\n    }\n    }\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManySwitchCases, r.err);
}

// switchStmt's non-exhaustive-variant-switch message builder joins 2+
// missing arm names with ", " -- every existing non-exhaustive-switch test
// (this file and tests/spec/fail) happens to be missing exactly ONE arm, so
// the comma-joining branch had no coverage.
test "compiler: a non-exhaustive variant switch missing 2+ arms joins their names with commas" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Status variant { pending, approved, rejected, closed }
        \\func label(s Status) string {
        \\    switch s {
        \\        case .pending { return "pending" }
        \\    }
        \\    return ""
        \\}
    );
    try std.testing.expectEqual(error.NonExhaustiveSwitch, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, ", ") != null);
}

// tryTypedArrayLit: a '[]T{...}' composite literal with more than 255
// elements.
test "compiler: a '[]T{...}' composite literal with more than 255 elements is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    xs := []int{0");
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, "}\n    _ = xs\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// varDecl's kw_func branch (a 'var'-keyword declaration whose type
// annotation is a func type): with and without an initializer.
test "compiler: a 'var' declaration with an explicit func-type annotation, with and without an initializer" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func double(n int) int { return n * 2 }
        \\func useFunc() int {
        \\    var f func(int) int = double
        \\    return f(21)
        \\}
        \\func declareOnly() bool {
        \\    var g func(int) int
        \\    return g == null
        \\}
    );
    try std.testing.expectEqual(@as(i64, 42), (try rt.callGlobal("useFunc", &.{})).int);
    try std.testing.expect((try rt.callGlobal("declareOnly", &.{})).boolean);
}

// varDecl's kw_func branch: a 'const' func-typed decl with no initializer
// hits the "expected '='" fallback (unlike 'var', const never gets an
// implicit default).
test "compiler: 'const f func(...) ...' with no initializer is a compile error (expected '=')" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt, "const f func(int) int\n");
    try std.testing.expectEqual(error.UnexpectedToken, r.err);
}

// Regression: varDecl's own type-name resolution switch (the ident branch
// around "int"/"float"/"bool"/"string"/"rune"/"bigint"/"array"/"map"/
// "error"/"actor" plus the struct/interface/variant/named registries) used
// to never special-case "any" -- even though `any` is a fully legitimate
// type, accepted everywhere else (params, returns, struct fields) via
// parseFieldTypeSpec. A bare `var x any = 5` therefore fell through every
// arm of varDecl's own switch and hit its final `else`, reporting "unknown
// type name 'any'" even though the type spec itself parsed successfully
// moments earlier. Fixed by adding an "any" arm that leaves
// inferred_type_check at its default `.none` (no runtime type check,
// matching parseFieldTypeSpec's own any -> FieldTypeAlt.any mapping).
// Affects `var`, top-level typed decls, and typed if/for-init decls
// equally, since they all share this switch.
test "compiler: 'var x any = ...' accepts and can be reassigned across value kinds" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func f() int {
        \\    var x any = 5
        \\    a := x
        \\    x = "hello"
        \\    b := x
        \\    x = [1, 2, 3]
        \\    c := x
        \\    return a + std.core.len(b) + std.core.len(c)
        \\}
    );
    try std.testing.expectEqual(@as(i64, 5 + 5 + 3), (try rt.callGlobal("f", &.{})).int);
}

// varDecl's cast_bigint epilog: a bigint-typed var initialized from a plain
// (not-yet-bigint) int literal.
test "compiler: 'var x bigint = <int literal>' emits the cast_bigint epilog" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() string {
        \\    var x bigint = 5
        \\    return string(x)
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqualStrings("5", try vms.asStringValue(result));
}

// varDecl: a bare nullable type annotation with no initializer implicitly
// defaults to null.
test "compiler: 'var x ?int' with no initializer implicitly defaults to null" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() bool {
        \\    var x ?int
        \\    return x == null
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expect(result.boolean);
}

// varDecl: declaring a global with the same name as an existing function.
test "compiler: declaring a global with the same name as an existing function is a compile error (DuplicateGlobal)" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func foo() int { return 1 }
        \\foo := 5
    );
    try std.testing.expectEqual(error.DuplicateGlobal, r.err);
}

// varDecl's REPL-mode redeclaration guards: check_global_exists fires on
// pure existence (not an actual type comparison), so re-declaring an
// existing explicitly-typed global via a second incremental compile is
// always rejected, even with the identical type.
test "compiler: REPL redeclaring an existing typed global is a compile error (RedeclareGlobal)" {
    var rt_repl = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt_repl.deinit();
    try std.testing.expect(rt_repl.runIncremental("if x int = 5; true { }") == .ok);
    const result = rt_repl.runIncremental("if x int = 6; true { }");
    try std.testing.expect(result == .compile_error);
}

test "compiler: REPL redeclaring an existing const is a compile error (cannot redeclare const)" {
    var rt_repl = try setupApiRuntime(.{
        .allow_io = false,
        .allocator = std.testing.allocator,
    });
    defer rt_repl.deinit();
    try std.testing.expect(rt_repl.runIncremental("const y = 5") == .ok);
    const result = rt_repl.runIncremental("const y = 10");
    try std.testing.expect(result == .compile_error);
}

// varDecl: more than MaxLocals explicitly-typed top-level globals. A bare
// typed decl (no 'var'/':=') is only reachable via an if/for init clause;
// at top level (outside any function, and outside cForStmt's in_loop_init),
// ifStmtDepth's init-clause varDecl call still takes the GLOBAL path, so a
// run of top-level `if vN TYPE = expr; true { }` statements is the only way
// to construct this many explicitly-typed globals from source.
test "compiler: more than MaxLocals typed top-level globals is a compile error (TooManyGlobals)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    var i: u32 = 0;
    var buf: [48]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "if v{d} int = 0; true {{ }}\n", .{i});
        try src.appendSlice(std.testing.allocator, line);
    }
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyGlobals, r.err);
}

// ── io.zig sprintValueDepth / fmtProcess coverage pass ─────────────────────
//
// std.fmt.format's generic '%v' verb (fmtProcess in io.zig) delegates to the
// exact same sprintValue used by print/println/std.fmt.stringify, but every
// existing '%v' test in this file only ever passed a scalar (int/string/
// bool) -- never an array or map, so the "does %v correctly measure+write a
// COMPOSITE value's full nested representation (not just a scalar)" path had
// no coverage. Also covers fmtInt/fmtFloat receiving a named-type-wrapped
// value: vms.valueAsInt/valueAsNumber both call unwrapNamed internally, so
// this is really confirming the existing unwrap behavior is actually
// exercised through the numeric verb dispatch, not just asserting it works.
test "compiler: std.fmt.format's %v verb formats composite array/map values, and numeric verbs unwrap named types" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Meter int
        \\func vArray() string { return std.fmt.format("%v", [1, 2, 3]) }
        \\func vMap() string { return std.fmt.format("%v", {"a": 1}) }
        \\func namedDec() string { return std.fmt.format("%d", Meter(7)) }
        \\func namedHex() string { return std.fmt.format("%x", Meter(255)) }
    );
    try std.testing.expectEqualStrings("[1, 2, 3]", try vms.asStringValue(try rt.callGlobal("vArray", &.{})));
    try std.testing.expectEqualStrings("{a: 1}", try vms.asStringValue(try rt.callGlobal("vMap", &.{})));
    try std.testing.expectEqualStrings("7", try vms.asStringValue(try rt.callGlobal("namedDec", &.{})));
    try std.testing.expectEqualStrings("ff", try vms.asStringValue(try rt.callGlobal("namedHex", &.{})));
}

// sprintValueDepth's .closure and .native_function object arms (rendering
// "<closure>" and "<native-func>") had no coverage anywhere -- every
// existing closure/native-function stringification test in this file goes
// through the *unrelated* string()/std.conv.to_string builtin
// (nativeConvToString in core.zig), which has no case for either and
// raises TypeError instead (see "string(...)/std.conv.to_string cover
// decimal, inline_variant ..., and reject struct/closure" above).
// std.fmt.stringify drives io.zig's sprintValue directly, so it succeeds
// here where string() fails on the exact same values.
//
// Also covers sprintValueDepth's final `else` fallback arm (renders the
// literal string "null"): .bigint, .string_builder, and .task_type all
// have no dedicated case in the object switch (unlike .struct_type/
// .enum_type/.variant_type/.interface_type/.named_type, which each render
// a distinct "<kind Name>" placeholder) and so silently fall through to
// the same "null" placeholder used for the actual null value -- confirmed
// here rather than assumed, since a prior pass's speculation that these
// might render as "<iter>"/"<builder>"-style placeholders turned out not
// to match the real switch at all.
test "compiler: std.fmt.stringify renders closure/native-function placeholders, and falls back to the bare \"null\" placeholder for bigint/string_builder/task_type" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Worker task func(start int, reply actor) {}
        \\func closureStr() string {
        \\    f := func() int { return 1 }
        \\    return std.fmt.stringify(f)
        \\}
        \\func nativeFnStr() string {
        \\    f := std.bytes.at
        \\    return std.fmt.stringify(f)
        \\}
        \\func bigintStr() string { return std.fmt.stringify(bigint(5)) }
        \\func stringBuilderStr() string {
        \\    b := std.string.builder()
        \\    return std.fmt.stringify(b)
        \\}
        \\func taskTypeStr() string { return std.fmt.stringify(Worker) }
    );
    try std.testing.expectEqualStrings("<closure>", try vms.asStringValue(try rt.callGlobal("closureStr", &.{})));
    try std.testing.expectEqualStrings("<native-func>", try vms.asStringValue(try rt.callGlobal("nativeFnStr", &.{})));
    try std.testing.expectEqualStrings("null", try vms.asStringValue(try rt.callGlobal("bigintStr", &.{})));
    try std.testing.expectEqualStrings("null", try vms.asStringValue(try rt.callGlobal("stringBuilderStr", &.{})));
    try std.testing.expectEqualStrings("null", try vms.asStringValue(try rt.callGlobal("taskTypeStr", &.{})));
}

// sprintValueDepth's .struct_instance arm (the >SmallStructMaxFields heap
// representation, MapEntry-backed) was only ever exercised via
// small_struct_instance (<=4 fields) in the earlier "std.fmt.stringify
// formats struct/array/map/named-error/variant objects" test -- both
// representations must render identically ("<struct Name>", no fields
// listed) since sprintValueDepth never actually walks a struct's fields.
test "compiler: std.fmt.stringify on a wide (>4 field) struct_instance renders the same placeholder as a small_struct_instance" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Wide struct { a int, b int, c int, d int, e int }
        \\func wideStructStr() string { return std.fmt.stringify(Wide{a: 1, b: 2, c: 3, d: 4, e: 5}) }
    );
    try std.testing.expectEqualStrings("<struct Wide>", try vms.asStringValue(try rt.callGlobal("wideStructStr", &.{})));
}

// sprintValueDepth's cycle guard (the `ancestors`/`anc_count` array, which
// renders "<cycle>" instead of recursing/stack-overflowing) had zero
// coverage. A struct can't exercise it: .struct_instance/
// .small_struct_instance render their placeholder without ever visiting
// their own fields, so a self-referential struct's cycle is never actually
// walked by the printer. A map CAN: index-assignment mutates the existing
// map object in place (proven elsewhere in this file, e.g. "m[\"a\"] =
// 500"), so `m["self"] = m` makes the map's own value entry point at the
// exact same object still being printed -- a genuine one-hop cycle, not
// just a deep-equal structural loop.
test "compiler: std.fmt.stringify on a self-referential map (m[\"self\"] = m) renders <cycle> instead of recursing forever" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func selfCycleMap() string {
        \\    m := {}
        \\    m["self"] = m
        \\    return std.fmt.stringify(m)
        \\}
    );
    try std.testing.expectEqualStrings("{self: <cycle>}", try vms.asStringValue(try rt.callGlobal("selfCycleMap", &.{})));
}

// sprintValueDepth's PrintMaxDepth (64) early-return truncation ("...")
// is distinct from the cycle guard above: it fires on a genuinely
// non-cyclic value that is just nested deeper than the printer is willing
// to recurse (e.g. an array wrapped in an array wrapped in an array...),
// preventing a pathological literal from blowing the native call stack.
// Built via a loop (rather than 70 literal levels of `[...]` in source)
// since the wrapping only needs to happen at runtime, not compile time.
test "compiler: std.fmt.stringify on an array nested more than PrintMaxDepth (64) levels truncates with \"...\" instead of crashing" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func deepNestStr() string {
        \\    var a any = 1
        \\    i := 0
        \\    for i < 70 {
        \\        a = [a]
        \\        i += 1
        \\    }
        \\    return std.fmt.stringify(a)
        \\}
    );
    const result = try vms.asStringValue(try rt.callGlobal("deepNestStr", &.{}));
    try std.testing.expect(std.mem.indexOf(u8, result, "...") != null);
}

// ── compiler_expr.zig coverage sweep (2026-08-25) ──────────────────────────
// Targeted at genuinely rare/edge-case paths in expression compilation that
// the huge existing suite doesn't otherwise exercise: element-count limits
// on the untyped array/map/struct literal forms (as opposed to the typed
// '[]T{...}' composite literal and 'defer' argument lists, which already had
// their own coverage), the 'expr.type == <non-ident>' and 'import(...)'
// argument-shape error paths, the two legacy-operator rejections that had no
// test ('&&'/'||' — only '%' did), unary '!' rejection, the lexer's string
// pool exhaustion path surfacing through an expression, struct-literal
// duplicate-field detection and its string-keyed key form (both the
// known-type and generic-instantiation constructors), the '>>' operator's
// left-operand type check (only '<<' and '>>' right-operand were covered),
// and the 'variable used where a type name was expected' struct-literal
// disambiguation error.

// arrayLit: a plain, untyped '[elem, ...]' literal with more than 255
// elements. This is a DIFFERENT count check from tryTypedArrayLit's
// '[]T{...}' sugar (compiler_stmts.zig, already covered) — arrayLit's own
// limit, reached only via the plain bracket-literal fallback path in
// arrayLitOrTypedArrayLit, had no coverage at all.
test "compiler: a plain untyped array literal with more than 255 elements is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    xs := [0");
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", 0");
    try src.appendSlice(std.testing.allocator, "]\n    _ = xs\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// mapLit: a '{ k: v, ... }' literal with more than 255 entries.
test "compiler: a map literal with more than 255 entries is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    m := { \"k0\": 0");
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", \"k\": 0");
    try src.appendSlice(std.testing.allocator, "}\n    _ = m\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// typeNameLiteral: the RHS of 'expr.type ==' (or '!=') must be a bare type
// name (an identifier) — a non-identifier RHS like a number literal is
// rejected here, distinct from the (already-covered) "unknown type name"
// case where the identifier itself doesn't resolve to anything.
test "compiler: 'expr.type == <non-identifier>' is a compile error (ExpectedTypeName)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ExpectedTypeName, compile(&rt,
        \\func f() bool {
        \\    x := 5
        \\    return x.type == 123
        \\}
    ));
}

// importExpr: the argument to 'import(...)' must be a string literal.
test "compiler: 'import(...)' with a non-string-literal argument is a compile error (ExpectedStringLiteral)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ExpectedStringLiteral, compile(&rt,
        \\x := import(123)
    ));
}

// importExpr: compiled with no module/import support configured at all
// (compile()'s bare '.{}' options — module_ctx and resolve_import both
// null), 'import(...)' of any name is rejected before ever consulting a
// resolver.
test "compiler: 'import(...)' compiled without any module context is a compile error (UnsupportedImportModule)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnsupportedImportModule, compile(&rt,
        \\x := import("std")
    ));
}

// importExpr: a module context is configured but no resolver callback is —
// the second, independent 'orelse' branch (the first requires module_ctx
// itself to be null, which the test above already covers).
test "compiler: 'import(...)' with a module context but no configured resolver is a compile error (UnsupportedImportModule)" {
    var rt = try setup();
    defer rt.deinit();
    chunk.setActive(rt.chunk_state);
    globals.setActive(&rt.globals_state);
    heap.setActive(&rt.heap_state);
    chunk.reset();
    globals.reset();
    heap.reset();

    var dummy_ctx: u8 = 0;
    const src = "x := import(\"std\")\n";
    var compiler = try Compiler.init(src, chunk.g_state, heap.g_state, .{ .module_ctx = &dummy_ctx });
    defer compiler.deinit();
    try std.testing.expectError(error.UnsupportedImportModule, compiler.compile(true));
}

// infixExpr: '&&' was removed in favor of 'and' — only '||' and '%''s
// sibling rejections existed before; '&&' itself had no test.
test "compiler: 'a && b' (removed legacy operator) is a compile error suggesting 'and'" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ExpectedExpression, compile(&rt,
        \\func f() bool { return true && false }
    ));
}

// infixExpr: '||' was removed in favor of 'or'.
test "compiler: 'a || b' (removed legacy operator) is a compile error suggesting 'or'" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ExpectedExpression, compile(&rt,
        \\func f() bool { return true || false }
    ));
}

// parsePrecedence's '.bang' prefix arm: unary '!' was removed in favor of
// 'not'. (Binary '!=' lexes to a distinct token and is unaffected.)
test "compiler: unary '!x' (removed legacy operator) is a compile error suggesting 'not'" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ExpectedExpression, compile(&rt,
        \\func f() bool { return !true }
    ));
}

// parsePrecedence's err_string_pool_exhausted prefix arm: the lexer's fixed
// 128KB string pool (shared across every string literal in the file) can be
// exhausted by one big-enough literal; the compiler surfaces this as a
// dedicated "string pool exhausted" message distinct from a plain
// unterminated-string error.
test "compiler: a string literal large enough to exhaust the lexer's 128KB string pool is a compile error (err_string_pool_exhausted)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "x := \"");
    const chunk_of_a: []const u8 = "a" ** 1000;
    var i: u32 = 0;
    while (i < 200) : (i += 1) try src.appendSlice(std.testing.allocator, chunk_of_a);
    try src.appendSlice(std.testing.allocator, "\"\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.UnterminatedString, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "string pool exhausted") != null);
}

// validateStructLiteralFieldNames: a duplicate field name within one struct
// literal is rejected at compile time (before the missing-required-field
// check even runs, since it's detected per-key during the same pass).
test "compiler: a struct literal with a duplicate field name is a compile error (DuplicateField)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\type Point struct { x int, y int }
        \\p := Point{x: 1, x: 2}
    ));
}

// structInstanceLit: a known-struct-type literal 'TypeName{...}' with more
// than 255 field entries is rejected during parsing itself (before
// validateStructLiteralFieldNames even runs), same limit as arrays/maps.
test "compiler: a known-struct-type literal with more than 255 field entries is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big struct { f0 int }\nfunc f() {\n    b := Big{f0: 0");
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", f0: 0");
    try src.appendSlice(std.testing.allocator, "}\n    _ = b\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// structInstanceLit: field keys may be string literals instead of bare
// identifiers ('Point{"x": 3}' as well as 'Point{x: 3}').
test "compiler: a known-struct-type literal accepts string-literal field keys instead of bare identifiers" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Point struct { x int, y int }
        \\func f() int {
        \\    p := Point{"x": 3, "y": 4}
        \\    return p.x + p.y
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 7), result.int);
}

// structInstanceLitAfterValue: the sibling literal-construction path taken
// for a generic instantiation ('Box[int]{...}') has its own identical
// element-count limit.
test "compiler: a generic-struct-instantiation literal with more than 255 field entries is a compile error (TooManyElements)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Box[T] struct { val T }\nfunc f() {\n    b := Box[int]{val: 0");
    var i: u32 = 0;
    while (i < 256) : (i += 1) try src.appendSlice(std.testing.allocator, ", val: 0");
    try src.appendSlice(std.testing.allocator, "}\n    _ = b\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyElements, r.err);
}

// structInstanceLitAfterValue: string-literal field keys work through the
// generic-instantiation literal path too, not just structInstanceLit's.
test "compiler: a generic-struct-instantiation literal accepts string-literal field keys too" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box[T] struct { val T }
        \\func f() int {
        \\    b := Box[int]{"val": 99}
        \\    return b.val
        \\}
    );
    const result = try rt.callGlobal("f", &.{});
    try std.testing.expectEqual(@as(i64, 99), result.int);
}

// infixExpr's '>>' handling: the left-operand int/rune check, mirroring the
// already-covered '<<' left-operand check and '>>' right-operand check —
// only this one specific combination (>> with a bad LHS) had no test.
test "compiler: '>>' with a non-int/rune left operand is a compile error (TypeMismatch)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.TypeMismatch, compile(&rt,
        \\func f() int { return true >> 1 }
    ));
}

// varExpr: 'name{ field: val }' where 'name' resolves to an ordinary local
// variable (not a registered type) is a clearer, more specific error than
// the generic "not a known type" case (already covered) — this is the
// classic Go-style ambiguity between a struct literal and a block opener,
// disambiguated here by looksLikeNonEmptyStructLiteral's lookahead.
test "compiler: 'localVar{ field: val }' where localVar is a plain variable, not a type, is a compile error naming it as such" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\func f() {
        \\    x := 5
        \\    y := x{a: 1}
        \\    _ = y
        \\}
    );
    try std.testing.expectEqual(error.UnexpectedToken, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "is a variable, not a type") != null);
}

// namedTypeAssignableTo: a two-hop subtype chain (Child subtypes Parent
// subtypes Grandparent) — the previously-covered case only walked one hop
// (direct parent match); this exercises the `cur = parent` loop continuing
// past the first ancestor to find the match two levels up.
test "compiler: a direct call argument two subtype levels below the declared parameter type is accepted" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Grandparent int
        \\subtype Parent Grandparent
        \\subtype Child Parent
        \\func take(v Grandparent) int { return int(v) }
        \\func f() int { return take(Child(5)) }
    );
}

// emitGetVar: a std import bound as a LOCAL (inside a function, not a
// top-level global) — the from_std/std_namespace_path branch on a resolved
// local was previously only exercised for the global-qname path.
test "compiler: a std import bound as a local variable inside a function still resolves namespaced calls" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func useStdLocally() string {
        \\    std := import("std")
        \\    return std.core.type_of(5)
        \\}
    );
    const result = try rt.callGlobal("useStdLocally", &.{});
    try std.testing.expectEqualStrings("int", try vms.asStringValue(result));
}

// emitGetVar: a file-imported module bound as a LOCAL (inside a function) —
// the import_module_path branch on a resolved local, mirroring the from_std
// case above but for a real cross-file import rather than std.
test "compiler: a file-imported module bound as a local variable inside a function still resolves field calls" {
    const main_src =
        \\func useDepLocally() int {
        \\    dep := import("./dep")
        \\    return dep.value()
        \\}
    ;
    const dep_src =
        \\pub func value() int { return 7 }
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = "main.gengo", .source = main_src },
        .{ .path = "dep.gengo", .source = dep_src },
    };

    var rt = try setup();
    defer rt.deinit();
    const outcome = try rt.runPathWithSources(main_src, "main.gengo", &source_entries);
    try std.testing.expectEqual(vm.RunOutcome.completed, outcome);
    const result = try rt.callGlobal("useDepLocally", &.{});
    try std.testing.expectEqual(@as(i64, 7), result.int);
}

// setCurrentExprPrimResult: the SYMMETRIC form of the erased-scalar-plus-
// plain-scalar rejection (plain scalar OP named-erased scalar, e.g.
// `1 + Age(20)`) — the asymmetric form (`Age(20) + 1`) was already covered;
// this is the mirror branch that was still unexercised.
test "compiler: a plain scalar literal on the LEFT of an erased named-scalar operand is a compile error (TypeMismatch)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.TypeMismatch, compile(&rt,
        \\type Age int
        \\func f() int { return int(1 + Age(20)) }
    ));
}

// setCurrentExprPrimResult: a mismatched-prim bitwise op where neither side
// is bool/string (so the earlier non-numeric check doesn't fire first) and
// neither side is the int/float pairing (so the int_float branch doesn't
// fire either) — bigint & int is exactly that residual case.
test "compiler: a bitwise op between bigint and int is a compile error (TypeMismatch)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.TypeMismatch, compile(&rt,
        \\func f() bigint { return bigint(2) & 5 }
    ));
}

// emitVarTypeEpilog: named-return array/map/actor-ref types — the runtime
// assert_type epilogue for these three TypeCheck variants (assert_arr,
// assert_map, assert_actor_ref) was previously only exercised for
// assert_err; varTypeCheckProven never special-cases these three tags (only
// prim/struct_type/interface_type/variant_type), so the epilogue always
// fires for them.
test "compiler: named return values of array, map, and actor type each emit a runtime type assertion on return" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func makeArr() (result []int) {
        \\    return [1, 2, 3]
        \\}
        \\func makeMap() (result map[string]int) {
        \\    return {"a": 1}
        \\}
        \\func identityActor(a actor) (result actor) {
        \\    return a
        \\}
    );
}

// emitGetVar: referencing an enclosing function's local from inside a task
// body declared INSIDE that function (rare, but the compiler explicitly
// supports task decls nested in a function) resolves via resolveUpvalue,
// which §3.3 forbids for task bodies — never previously exercised because
// every other task test declares its task types at the top level.
test "compiler: a task body declared inside a function cannot capture that function's local (TaskBodyCapturesOuterLocal)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.TaskBodyCapturesOuterLocal, compile(&rt,
        \\func outer() {
        \\    x := 5
        \\    type Leaker task func(reply actor) {
        \\        y := x
        \\        reply.send(y)
        \\    }
        \\}
    ));
}

// emitGetVar: a task body referencing a top-level mutable `var` global —
// §3.3 forbids this (only const/func/type/import "ambient" globals are
// visible); never previously exercised.
test "compiler: a task body referencing a mutable top-level global is a compile error (MutableGlobalInTaskBody)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.MutableGlobalInTaskBody, compile(&rt,
        \\var counter = 0
        \\type Reader task func(reply actor) {
        \\    v := counter
        \\    reply.send(v)
        \\}
    ));
}

// pushLoop: exceeding MaxLoopDepth nested loops is a fatal compile error.
test "compiler: nesting more than MaxLoopDepth loops is a compile error (TooManyNestedLoops)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n");
    var i: u32 = 0;
    while (i <= ct.MaxLoopDepth) : (i += 1) try src.appendSlice(std.testing.allocator, "for true {\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyNestedLoops, r.err);
}

// emitBreak: exceeding MaxLoopBreaks break statements within a single loop
// is a fatal compile error.
test "compiler: more than MaxLoopBreaks 'break' statements in one loop is a compile error (TooManyBreaksInLoop)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "func f() {\n    for true {\n");
    var i: u32 = 0;
    while (i <= ct.MaxLoopBreaks) : (i += 1) try src.appendSlice(std.testing.allocator, "break\n");
    try src.appendSlice(std.testing.allocator, "    }\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyBreaksInLoop, r.err);
}

// decl(): 'pub' used as the first token of a statement inside a function
// body is rejected immediately (before even inspecting what follows) —
// only the top-level acceptance paths were previously exercised.
test "compiler: 'pub' used inside a function body is a compile error (InvalidPubTarget)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.InvalidPubTarget, compile(&rt,
        \\func f() {
        \\    pub const x = 1
        \\}
    ));
}

// pubDecl: 'pub subtype ...' — the subtype-export path was never exercised
// (only pub const/type/func were).
test "compiler: 'pub subtype' exports a subtype declaration" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\type Meters int
        \\pub subtype SmallMeters Meters range 0..100
    );
}

// pubDecl: 'pub' followed by something other than const/type/subtype/func
// (a plain 'var') falls through to the generic InvalidPubTarget error —
// the top-level decl()-side InvalidPubTarget (inside a function) was
// covered above; this is pubDecl's own internal fallback.
test "compiler: 'pub var' is a compile error (InvalidPubTarget)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.InvalidPubTarget, compile(&rt,
        \\pub var x = 1
    ));
}

// looksLikeGenericTypeParams: a non-identifier, non-comma token inside the
// brackets (e.g. a number) immediately disqualifies the generic-type-params
// interpretation, falling back to ordinary array/map type-spec parsing --
// which then fails on the same token for an unrelated reason (not a valid
// key type), giving a clean, deliberate parse error either way.
test "compiler: a named type decl with a number inside brackets ('[5]int') is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\type Foo [5]int
    );
    try std.testing.expectEqual(error.UnexpectedToken, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "expected identifier") != null);
}

// addExport: two pub declarations exporting under the same stable name is a
// compile error, distinct from any earlier same-name-global check (a const
// and a struct type occupy different internal registries, so nothing
// upstream of addExport rejects this pairing).
test "compiler: a pub const and a pub struct type sharing the same name is a compile error (DuplicateExport)" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\pub const A = 1
        \\pub type A struct { x int }
    );
    try std.testing.expectEqual(error.DuplicateExport, r.err);
}

// addExport: exceeding MaxModuleExports distinct pub names is a fatal
// compile error.
test "compiler: exporting more than MaxModuleExports names is a compile error (TooManyFields)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i <= ct.MaxModuleExports) : (i += 1) {
        const piece = try std.fmt.bufPrint(&buf, "pub const A{d} = {d}\n", .{ i, i });
        try src.appendSlice(std.testing.allocator, piece);
    }
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyFields, r.err);
}

// isTypedVarDecl: the '[]T = expr' (array) shape of the no-keyword,
// space-syntax typed declaration, used in a for-loop init clause — only the
// bare-ident ('name Type = expr') shape had coverage before.
test "compiler: a for-loop init clause with a no-keyword array-typed declaration ('x []int = ...') compiles" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int {
        \\    total := 0
        \\    for arr []int = [1, 2, 3]; total < 1; total += 1 {
        \\        total += arr[0]
        \\    }
        \\    return total
        \\}
    );
}

// isTypedVarDecl: the '[K]V = expr' (bracket-immediate map) shape of the
// no-keyword typed declaration, used in a for-loop init clause. The RHS
// must not itself contain a '{' (e.g. a map literal) — isCStyleFor's own
// lookahead (a separate, simpler scanner) stops at the first '{' it sees
// while looking for the clause-separating ';', so an inline map literal in
// the init clause would misclassify this as a while-style loop before
// isTypedVarDecl is ever consulted; referencing a pre-built map sidesteps
// that unrelated scanner's limitation.
test "compiler: a for-loop init clause with a no-keyword bracket map-typed declaration ('x [string]int = ...') compiles" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int {
        \\    existing := {"a": 1}
        \\    for m [string]int = existing; false; {}
        \\    return 0
        \\}
    );
}

// isTypedVarDecl: the 'func(...) R = expr' shape of the no-keyword typed
// declaration, used in a for-loop init clause.
test "compiler: a for-loop init clause with a no-keyword func-typed declaration ('f func(int) int = ...') compiles" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func idFn(x int) int { return x }
        \\func g() int {
        \\    for h func(int) int = idFn; false; {}
        \\    return 0
        \\}
    );
}

// isTypedVarDecl: an identifier type immediately followed by '[...]'
// (e.g. 'map[K]V' spelled with the 'map' keyword rather than the bare
// '[K]V' bracket form above), used in a for-loop init clause.
test "compiler: a for-loop init clause with a no-keyword 'map[K]V'-typed declaration compiles" {
    var rt = try setup();
    defer rt.deinit();
    try compile(&rt,
        \\func f() int {
        \\    existing := {"a": 1}
        \\    for m map[string]int = existing; false; {}
        \\    return 0
        \\}
    );
}

// resolveImportAliasPath: a std import bound as a LOCAL used as the module
// prefix of a module-qualified type annotation (isTypedVarDecl's dot
// branch) — the local.std_namespace_path/from_std branch was previously
// only exercised via the global-qname fallback. import("std") only resolves
// through the full runtime session (bare compile() has no module_ctx), so
// this uses rt.run() rather than compileAndInspect; resolveModuleTypeName's
// callback then fails to resolve a real type on the "std" module path,
// giving a clean, expected UnknownType.
test "compiler: a for-loop init typed decl referencing a locally-bound std alias as a module-qualified type reports UnknownType" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnknownType, rt.run(
        \\func f() {
        \\    std := import("std")
        \\    for x std.Bogus = 0; false; {}
        \\}
    ));
}

// checkStdNamespaceField: an unknown field close (edit distance < 3) to a
// real export of the same std namespace gets a "did you mean" suggestion —
// only the no-suggestion fallback message was previously exercised. Uses
// rt.run() (not compileAndInspect) since import("std") needs the full
// runtime session; the resulting error/message land on rt's own
// last_compile_* fields instead of a Compiler's.
test "compiler: an unknown std namespace field close to a real export gets a 'did you mean' suggestion" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnknownField, rt.run(
        \\std := import("std")
        \\func f() float { return std.math.sqrtz(4.0) }
    ));
    try std.testing.expect(std.mem.indexOf(u8, rt.last_compile_msg_buf[0..rt.last_compile_msg_len], "did you mean 'sqrt'") != null);
}

// failOnLexerError: a string literal whose content overflows the lexer's
// shared string pool is a compile error distinct from a plain unterminated
// string.
test "compiler: a string literal exceeding the lexer's string pool size is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "x := \"");
    try src.appendNTimes(std.testing.allocator, 'a', 140 * 1024);
    try src.appendSlice(std.testing.allocator, "\"\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.UnterminatedString, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "string pool exhausted") != null);
}

// failOnLexerError: a '\x' escape with non-hex digits is a compile error
// (BadEscape) distinct from an unterminated string or an unknown escape.
test "compiler: a string literal with a non-hex '\\x' escape is a compile error (BadEscape)" {
    var rt = try setup();
    defer rt.deinit();
    const r = compileAndInspect(&rt,
        \\x := "\xZZ"
    );
    try std.testing.expectEqual(error.BadEscape, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "bad escape sequence") != null);
}

// ── core.zig (native/core.zig) coverage sweep (2026-08-25) ─────────────────
//
// core.zig sat at 82.75% line coverage with zero inline `test` blocks of its
// own -- every line is only reachable via black-box Gengo scripts run
// through a real Runtime. This sweep targets its largest remaining gaps.
//
// std.core.append/bytelen/len (like std.math's abs/sqrt/etc, see the
// "intrinsic-shadowed" test above) lower UNCONDITIONALLY at their direct
// call site to the .append/.bytelen/.len ops (selectStdCoreAppendIntrinsicOp/
// selectStdCoreByteLenIntrinsicOp/selectStdCoreLenIntrinsicOp in
// compiler.zig) -- and those ops' VM handlers call the exact same
// nativeAppend/nativeByteLen/nativeLen core.zig functions, so ordinary
// `std.core.len(x)`-shaped tests already cover those three functions'
// bodies. What NONE of those tests ever reach is core.zig's own dispatch()
// switch (the .core_append/.core_bytelen/.core_len arms), which only runs
// for a genuinely INDIRECT call -- binding the function to a local first
// (`f := std.core.append`) defeats the intrinsic recognition, same trick as
// the std.math sweep.
test "compiler: std.core.append/bytelen/len reach core.zig's own dispatch() via indirect call" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func viaAppend() []int {
        \\    f := std.core.append
        \\    a := [1, 2, 3]
        \\    return f(a, 4, 5)
        \\}
        \\func viaByteLen() int {
        \\    g := std.core.bytelen
        \\    return g("hello")
        \\}
        \\func viaLen() int {
        \\    h := std.core.len
        \\    return h([1, 2, 3, 4])
        \\}
    );
    const appended = try rt.callGlobal("viaAppend", &.{});
    const items = try vms.asArraySlice(appended.object);
    try std.testing.expectEqual(@as(usize, 5), items.len);
    try std.testing.expectEqual(@as(i64, 4), items[3].int);
    try std.testing.expectEqual(@as(i64, 5), items[4].int);
    try std.testing.expectEqual(@as(i64, 5), (try rt.callGlobal("viaByteLen", &.{})).int);
    try std.testing.expectEqual(@as(i64, 4), (try rt.callGlobal("viaLen", &.{})).int);
}

// nativeConvToInt/nativeConvToFloat's rune/boolean/TypeError-fallthrough
// branches: selectStdConvIntrinsicOp only folds a DIRECT std.conv.to_int/
// to_float call to cast_int/cast_float when the argument's STATIC type is
// provably int/float/rune/bool -- gating that itself proves those branches
// unreachable via a direct call with a statically-known-safe argument.
// Binding to_int/to_float to a local first defeats that static check
// entirely (same indirect-call trick as above), forcing every call through
// nativeConvToInt/nativeConvToFloat's real bodies regardless of argument
// kind, including the final `else => TypeError` fallthrough (null has no
// int/float/rune/bool/string/object case in either function).
test "compiler: std.conv.to_int/to_float reach nativeConvToInt/Float's rune/bool/TypeError branches via indirect call" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func intFromRune() int { f := std.conv.to_int; return f(`A`) }
        \\func intFromBoolTrue() int { f := std.conv.to_int; return f(true) }
        \\func intFromBoolFalse() int { f := std.conv.to_int; return f(false) }
        \\func intFromNullErrors() int { f := std.conv.to_int; return f(null) }
        \\func floatFromInt() float { g := std.conv.to_float; return g(5) }
        \\func floatFromFloat() float { g := std.conv.to_float; return g(5.5) }
        \\func floatFromRune() float { g := std.conv.to_float; return g(`A`) }
        \\func floatFromBool() float { g := std.conv.to_float; return g(true) }
        \\func floatFromNullErrors() float { g := std.conv.to_float; return g(null) }
    );
    try std.testing.expectEqual(@as(i64, 65), (try rt.callGlobal("intFromRune", &.{})).int);
    try std.testing.expectEqual(@as(i64, 1), (try rt.callGlobal("intFromBoolTrue", &.{})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("intFromBoolFalse", &.{})).int);
    try std.testing.expectError(error.TypeError, rt.callGlobal("intFromNullErrors", &.{}));
    try std.testing.expectEqual(@as(f64, 5.0), (try rt.callGlobal("floatFromInt", &.{})).float);
    try std.testing.expectEqual(@as(f64, 5.5), (try rt.callGlobal("floatFromFloat", &.{})).float);
    try std.testing.expectEqual(@as(f64, 65.0), (try rt.callGlobal("floatFromRune", &.{})).float);
    try std.testing.expectEqual(@as(f64, 1.0), (try rt.callGlobal("floatFromBool", &.{})).float);
    try std.testing.expectError(error.TypeError, rt.callGlobal("floatFromNullErrors", &.{}));
}

// nativeConvToBool's `.actor_ref` case: std.conv.to_bool has no compiler
// intrinsic at all (unlike to_int/to_float/to_string), so a plain direct
// call already reaches nativeConvToBool for real -- this just needed an
// actor_ref value, which only a task/self() context can produce.
test "compiler: std.conv.to_bool covers the actor_ref case" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Worker task func(start int, reply actor) {}
        \\liveActor := Worker(1, self())
        \\liveActorIsTrue := std.conv.to_bool(liveActor)
        \\func actorRefToBool() bool { return liveActorIsTrue }
    );
    try std.testing.expect((try rt.callGlobal("actorRefToBool", &.{})).boolean);
}

// NOTE (finding, not fixed -- see task report): nativeIsInt/nativeIsFloat's
// `.object => isNamedBase(ctx, v, .int)` / `(..., .float)` arms (core.zig
// lines 421/430) appear to be dead code, reachable from no Gengo script at
// all. isErasedNamedType (compiler.zig) unconditionally erases every named
// type whose base is int/float/bool/rune/enum_t -- UNCONDITIONALLY, not
// just when the type has no predicate/range as one might assume from the
// name. A predicate or range on a named int/float type only adds a runtime
// *validation* step at construction; the value produced is still a bare
// .int/.float Value with no .named_value wrapper. Since isNamedBase can
// only ever fire on a `.object => .named_value` value, and no named type
// with base .int or .float can ever produce one, isNamedBase(ctx, v, .int)
// and isNamedBase(ctx, v, .float) can never observe a match. This test
// instead just pins the (already correct, via the plain `.int`/`.float`
// fast-path arms) observable behavior for a predicate-bearing named
// int/float, so a future erasure-policy change that actually exercises
// isNamedBase's int/float arms doesn't silently flip this test's meaning.
test "compiler: std.core.is_int/is_float on a predicate-bearing named int/float is still true via the erased fast path" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type PosInt int predicate func(x) { return x > 0 }
        \\type PosFloat float predicate func(x) { return x > 0.0 }
        \\func isIntNamed() bool { return std.core.is_int(PosInt(5)) }
        \\func isFloatNamed() bool { return std.core.is_float(PosFloat(2.5)) }
        \\func isFloatOnNamedInt() bool { return std.core.is_float(PosInt(5)) }
        \\func isIntOnNamedFloat() bool { return std.core.is_int(PosFloat(2.5)) }
    );
    try std.testing.expect((try rt.callGlobal("isIntNamed", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("isFloatNamed", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isFloatOnNamedInt", &.{})).boolean);
    try std.testing.expect(!(try rt.callGlobal("isIntOnNamedFloat", &.{})).boolean);
}

// nativeLen's `.struct_instance` case and nativeTypeNameValue's own
// `.struct_instance` case are each a SEPARATE switch arm from
// `.small_struct_instance` -- SmallStructMaxFields is 4, so a struct
// literal with 4 or fewer fields (every existing len/type_of-on-a-struct
// test in this file) always takes the small-struct representation. Only a
// struct with 5+ fields uses the real (heap-allocated fields slice)
// `.struct_instance` representation these two branches need.
test "compiler: std.core.len/type_of on a struct with more than 4 fields reach the real (non-small) struct_instance branches" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Big struct { a int, b int, c int, d int, e int }
        \\func bigLen() int { return std.core.len(Big{a: 1, b: 2, c: 3, d: 4, e: 5}) }
        \\func bigTypeOf() string {
        \\    t := std.core.type_of
        \\    return t(Big{a: 1, b: 2, c: 3, d: 4, e: 5})
        \\}
    );
    try std.testing.expectEqual(@as(i64, 5), (try rt.callGlobal("bigLen", &.{})).int);
    try std.testing.expectEqualStrings("Big", try vms.asStringValue(try rt.callGlobal("bigTypeOf", &.{})));
}

// nativeConvToString's own `vmod.decimalRawAndScale` branch: cast_string's
// VM op (which `string(...)` always compiles to) special-cases decimal
// itself BEFORE ever calling nativeConvToString, so `string(someDecimal)`
// never reaches core.zig's own decimal handling at all. std.conv.to_string
// folds to cast_string too (selectStdConvIntrinsicOp, unconditionally for
// any provably-non-null prim) -- so only an INDIRECT std.conv.to_string
// call, on a decimal value, reaches nativeConvToString's decimal branch for
// real.
//
// nativeConvToString's `.inline_variant` case with a non-null payload
// (building "Type.arm(payload)") is a SEPARATE representation from a
// string/float/object payload, which tryMakeInlineVariant can never inline
// (see the .variant_value fix earlier this session) -- an INT payload,
// which fits inline, is required to reach it. `string(...)` (a direct cast,
// no intrinsic folding involved) exercises this directly.
test "compiler: std.conv.to_string reaches nativeConvToString's decimal branch via indirect call, and string(...) reaches its inline_variant-with-payload branch" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Money decimal 2
        \\type Shape variant { tag(n int), point }
        \\func decimalViaIndirectToString() string {
        \\    var d Money = 3.5
        \\    h := std.conv.to_string
        \\    return h(d)
        \\}
        \\func inlineVariantWithIntPayloadToString() string { return string(Shape.tag(42)) }
    );
    try std.testing.expectEqualStrings("3.5", try vms.asStringValue(try rt.callGlobal("decimalViaIndirectToString", &.{})));
    try std.testing.expectEqualStrings("Shape.tag(42)", try vms.asStringValue(try rt.callGlobal("inlineVariantWithIntPayloadToString", &.{})));
}

// nativeTypeNameValue (backing std.core.type_of) has its OWN compile-time
// short-circuit for a DIRECT call: selectStdCoreLenIntrinsicOp's sibling in
// compiler_expr.zig folds `std.core.type_of(x)` straight to a compile-time
// string constant whenever the compiler can statically name x's type (this
// applies far more broadly than plain `type X int` named values -- a bare
// reference to a struct/interface/enum/variant/named-error/task TYPE itself
// also folds, confirmed via disasm: `std.core.type_of(SomeStruct)` compiles
// with no runtime call to std.core.type_of at all). Binding type_of to a
// local first defeats that folding unconditionally (same indirect-call
// trick used throughout this sweep), forcing every one of these through
// nativeTypeNameValue's real switch: rune, map, native_function, and bare
// struct/interface/named/enum/variant/variant-ctor/named-error/task type
// references, plus actor_ref.
test "compiler: std.core.type_of via indirect call reaches nativeTypeNameValue's rune/map/native_function/type-object/actor_ref branches" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Square struct { side int }
        \\type Shape interface { area() int }
        \\type Meter int
        \\type Color enum { red, green, blue }
        \\type Boxed variant { ok(v int), bad }
        \\type MyErr error
        \\type Worker task func(start int, reply actor) {}
        \\func typeOfRune() string { t := std.core.type_of; return t(`x`) }
        \\func typeOfMap() string { t := std.core.type_of; return t({"a": 1}) }
        \\func typeOfNativeFunction() string { t := std.core.type_of; f := std.core.len; return t(f) }
        \\func typeOfStructType() string { t := std.core.type_of; return t(Square) }
        \\func typeOfInterfaceType() string { t := std.core.type_of; return t(Shape) }
        \\func typeOfNamedType() string { t := std.core.type_of; return t(Meter) }
        \\func typeOfEnumType() string { t := std.core.type_of; return t(Color) }
        \\func typeOfVariantType() string { t := std.core.type_of; return t(Boxed) }
        \\func typeOfVariantCtor() string { t := std.core.type_of; ctor := Boxed.ok; return t(ctor) }
        \\func typeOfNamedErrorType() string { t := std.core.type_of; return t(MyErr) }
        \\func typeOfTaskType() string { t := std.core.type_of; return t(Worker) }
        \\t := std.core.type_of
        \\a := Worker(1, self())
        \\actorRefTypeOfResult := t(a)
        \\func typeOfActorRef() string { return actorRefTypeOfResult }
    );
    try std.testing.expectEqualStrings("rune", try vms.asStringValue(try rt.callGlobal("typeOfRune", &.{})));
    try std.testing.expectEqualStrings("map", try vms.asStringValue(try rt.callGlobal("typeOfMap", &.{})));
    try std.testing.expectEqualStrings("native_func", try vms.asStringValue(try rt.callGlobal("typeOfNativeFunction", &.{})));
    try std.testing.expectEqualStrings("Square", try vms.asStringValue(try rt.callGlobal("typeOfStructType", &.{})));
    try std.testing.expectEqualStrings("Shape", try vms.asStringValue(try rt.callGlobal("typeOfInterfaceType", &.{})));
    try std.testing.expectEqualStrings("Meter", try vms.asStringValue(try rt.callGlobal("typeOfNamedType", &.{})));
    try std.testing.expectEqualStrings("Color", try vms.asStringValue(try rt.callGlobal("typeOfEnumType", &.{})));
    try std.testing.expectEqualStrings("Boxed", try vms.asStringValue(try rt.callGlobal("typeOfVariantType", &.{})));
    try std.testing.expectEqualStrings("Boxed", try vms.asStringValue(try rt.callGlobal("typeOfVariantCtor", &.{})));
    try std.testing.expectEqualStrings("MyErr", try vms.asStringValue(try rt.callGlobal("typeOfNamedErrorType", &.{})));
    try std.testing.expectEqualStrings("Worker", try vms.asStringValue(try rt.callGlobal("typeOfTaskType", &.{})));
    try std.testing.expectEqualStrings("actor", try vms.asStringValue(try rt.callGlobal("typeOfActorRef", &.{})));
}

// deepEqualObject/deepEqualValue's rarer branches: every one of these kinds
// (string_view, a bare closure, native_function, the type-object identity
// kinds, enum_value, a >4-field struct_instance, a record-style variant_value,
// named_type_fn/enum_type_fn, string_builder, bigint, error_value,
// inline_variant with a payload, named_error_value, task_type, decimal
// nested inside a named_value, and a cross string/string_view comparison)
// was previously unexercised by std.core.deep_equal anywhere in this file
// (existing usage is overwhelmingly array/map/struct/string content
// comparisons). std.core.deep_equal has no compiler intrinsic at all, so
// direct calls already reach core.zig's real deepEqualValue/deepEqualObject.
test "compiler: std.core.deep_equal covers its rarer object/value-kind branches" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Square struct { side int }
        \\type Shape interface { area() int }
        \\type Color enum { red, green, blue }
        \\type Boxed variant { ok(v int), bad }
        \\type MyErr error
        \\type Worker task func(start int, reply actor) {}
        \\type Big struct { a int, b int, c int, d int, e int }
        \\type ShapeV variant { circle { radius float, label string }, tag(n int), point }
        \\type SharedV variant { id int, circle { radius float }, point }
        \\type RangedM int range 0..100
        \\type Money decimal 2
        \\type Rect struct { w int, h int }
        \\type Named interface { name() string }
        \\type Wrapped variant { some(v int), none }
        \\type Runner task func(start int, reply actor) {}
        \\worker1 := Worker(1, self())
        \\worker2 := Worker(2, self())
        \\func actorRefEq() bool {
        \\    return std.core.deep_equal(worker1, worker1) and not std.core.deep_equal(worker1, worker2)
        \\}
        \\func stringViewEq() bool {
        \\    sv1 := std.bytes.slice(std.conv.to_string(12345), 1, 3)
        \\    sv2 := std.bytes.slice(std.conv.to_string(99123), 1, 3)
        \\    sv3 := std.bytes.slice(std.conv.to_string(12345), 1, 3)
        \\    return not std.core.deep_equal(sv1, sv2) and std.core.deep_equal(sv1, sv3)
        \\}
        \\func stringVsStringViewEq() bool {
        \\    sv := std.bytes.slice(std.conv.to_string(12345), 1, 3)
        \\    return std.core.deep_equal("23", sv) and std.core.deep_equal(sv, "23")
        \\}
        \\func closureIdentityEq() bool {
        \\    fn := func() int { return 1 }
        \\    fn2 := func() int { return 1 }
        \\    return std.core.deep_equal(fn, fn) and not std.core.deep_equal(fn, fn2)
        \\}
        \\func nativeFunctionEq() bool {
        \\    f := std.core.len
        \\    h := std.core.len
        \\    g := std.core.append
        \\    return std.core.deep_equal(f, h) and not std.core.deep_equal(f, g)
        \\}
        \\func typeObjectIdentityEq() bool {
        \\    // Comparing a type to ITSELF (e.g. deep_equal(Square, Square)) always
        \\    // takes deepEqualObject's `a == b` pointer-identity fast path (every
        \\    // reference to a given declared type resolves to the same singleton
        \\    // object) and never reaches the per-kind qualified_name comparison
        \\    // below it -- comparing two DISTINCT same-tag type objects is required
        \\    // to actually exercise struct_type/interface_type/variant_ctor/
        \\    // task_type's own comparison lines.
        \\    ctor1 := Boxed.ok
        \\    ctor2 := Wrapped.some
        \\    return not std.core.deep_equal(Square, Rect) and not std.core.deep_equal(Shape, Named) and
        \\        not std.core.deep_equal(ctor1, ctor2) and not std.core.deep_equal(Worker, Runner) and
        \\        std.core.deep_equal(Color, Color) and std.core.deep_equal(MyErr, MyErr)
        \\}
        \\func runeValueEq() bool {
        \\    return std.core.deep_equal(`x`, `x`) and not std.core.deep_equal(`x`, `y`)
        \\}
        \\func sharedFieldVariantEq() bool {
        \\    c1 := SharedV.circle{id: 1, radius: 5.0}
        \\    c2 := SharedV.circle{id: 1, radius: 5.0}
        \\    c3 := SharedV.circle{id: 2, radius: 5.0}
        \\    return std.core.deep_equal(c1, c2) and not std.core.deep_equal(c1, c3)
        \\}
        \\func enumValueEq() bool {
        \\    return std.core.deep_equal(Color.red, Color.red) and not std.core.deep_equal(Color.red, Color.green)
        \\}
        \\func bigStructInstanceEq() bool {
        \\    p1 := Big{a: 1, b: 2, c: 3, d: 4, e: 5}
        \\    p2 := Big{a: 1, b: 2, c: 3, d: 4, e: 5}
        \\    p3 := Big{a: 1, b: 2, c: 3, d: 4, e: 9}
        \\    return std.core.deep_equal(p1, p2) and not std.core.deep_equal(p1, p3)
        \\}
        \\func recordVariantValueEq() bool {
        \\    c1 := ShapeV.circle{radius: 5.0, label: "x"}
        \\    c2 := ShapeV.circle{radius: 5.0, label: "x"}
        \\    c3 := ShapeV.circle{radius: 6.0, label: "x"}
        \\    return std.core.deep_equal(c1, c2) and not std.core.deep_equal(c1, c3)
        \\}
        \\func namedAndEnumTypeFnEq() bool {
        \\    ntf := RangedM.succ
        \\    ntf2 := RangedM.succ
        \\    etf := Color.from_int
        \\    etf2 := Color.from_int
        \\    return std.core.deep_equal(ntf, ntf2) and std.core.deep_equal(etf, etf2)
        \\}
        \\func stringBuilderEq() bool {
        \\    b1 := std.string.builder()
        \\    b1.write("abc")
        \\    b2 := std.string.builder()
        \\    b2.write("abc")
        \\    b3 := std.string.builder()
        \\    b3.write("xyz")
        \\    return std.core.deep_equal(b1, b2) and not std.core.deep_equal(b1, b3)
        \\}
        \\func bigintEq() bool {
        \\    return std.core.deep_equal(bigint(5), bigint(5)) and not std.core.deep_equal(bigint(5), bigint(6))
        \\}
        \\func errorValueEq() bool {
        \\    return std.core.deep_equal(std.core.error("x"), std.core.error("x")) and
        \\        not std.core.deep_equal(std.core.error("x"), std.core.error("y"))
        \\}
        \\func inlineVariantWithPayloadEq() bool {
        \\    return std.core.deep_equal(Boxed.ok(5), Boxed.ok(5)) and not std.core.deep_equal(Boxed.ok(5), Boxed.ok(6))
        \\}
        \\func namedErrorValueEq() bool {
        \\    return std.core.deep_equal(MyErr("x"), MyErr("x")) and not std.core.deep_equal(MyErr("x"), MyErr("y"))
        \\}
        \\func decimalNestedInNamedValueEq() bool {
        \\    var d1 Money = 3.5
        \\    var d2 Money = 3.5
        \\    var d3 Money = 4.5
        \\    return std.core.deep_equal(d1, d2) and not std.core.deep_equal(d1, d3)
        \\}
    );
    try std.testing.expect((try rt.callGlobal("stringViewEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("stringVsStringViewEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("closureIdentityEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("nativeFunctionEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("typeObjectIdentityEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("runeValueEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("sharedFieldVariantEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("actorRefEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("enumValueEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("bigStructInstanceEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("recordVariantValueEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("namedAndEnumTypeFnEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("stringBuilderEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("bigintEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("errorValueEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("inlineVariantWithPayloadEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("namedErrorValueEq", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("decimalNestedInNamedValueEq", &.{})).boolean);
}

// cloneObject's rarer branches: string_view (a genuinely separate case from
// dyn_string), a non-empty string_builder (the `sb.len != 0` branch, copying
// the backing buffer), enum_value, and named_error_value all had no
// std.core.clone coverage anywhere in this file (the existing clone tests
// only exercise arrays/maps/structs). The big combined pass-through arm
// (`.function, .closure, .native_function, ... => return .{ .object = src
// }`) is exercised via native_function here too.
test "compiler: std.core.clone covers string_view, non-empty string_builder, enum_value, and named_error_value" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type Color enum { red, green, blue }
        \\type MyErr error
        \\func cloneStringView() string {
        \\    sv := std.bytes.slice(std.conv.to_string(12345), 1, 3)
        \\    return std.core.clone(sv)
        \\}
        \\func cloneNonEmptyStringBuilder() string {
        \\    b := std.string.builder()
        \\    b.write("abc")
        \\    c := std.core.clone(b)
        \\    return c.str()
        \\}
        \\func cloneEnumValueRetainsIdentity() bool {
        \\    c := std.core.clone(Color.red)
        \\    return std.core.deep_equal(c, Color.red) and not std.core.deep_equal(c, Color.green)
        \\}
        \\func cloneNamedErrorValueRetainsMessage() string {
        \\    c := std.core.clone(MyErr("boom"))
        \\    return string(c)
        \\}
        \\func cloneNativeFunctionPassesThrough() bool {
        \\    f := std.core.len
        \\    c := std.core.clone(f)
        \\    return std.core.deep_equal(c, f)
        \\}
        \\func cloneNamedErrorTypeItselfPassesThrough() bool {
        \\    c := std.core.clone(MyErr)
        \\    return std.core.deep_equal(c, MyErr)
        \\}
    );
    try std.testing.expectEqualStrings("23", try vms.asStringValue(try rt.callGlobal("cloneStringView", &.{})));
    try std.testing.expectEqualStrings("abc", try vms.asStringValue(try rt.callGlobal("cloneNonEmptyStringBuilder", &.{})));
    try std.testing.expect((try rt.callGlobal("cloneEnumValueRetainsIdentity", &.{})).boolean);
    try std.testing.expectEqualStrings("boom", try vms.asStringValue(try rt.callGlobal("cloneNamedErrorValueRetainsMessage", &.{})));
    try std.testing.expect((try rt.callGlobal("cloneNativeFunctionPassesThrough", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("cloneNamedErrorTypeItselfPassesThrough", &.{})).boolean);
}

// ── compiler_decls.zig third coverage pass (2026-08-26) ─────────────────────
// Two prior passes covered the compile-time constant evaluator, generic
// struct/variant/func arg-count and constraint errors, named error/task/
// interface/method decl gaps, and enum/array-keyword edge cases. This pass
// targets emitZeroValue/emitNamedDefault's remaining reachable branches (bare
// `var x TYPE` with no initializer, for every TYPE shape whose zero value
// isn't already exercised), the handful of duplicate/conflict checks each
// decl body repeats for itself (interface/struct/variant all have their own
// copy of the hasAnyTypeName/hasGlobalFunc guards), every decl body's
// c.inFunc() "declared as a local" branch (struct/interface/variant/enum/
// named-array/named-map/generic-alias/task/named-error, each a distinct call
// site), the MaxLocals/MaxTypeParams resource ceilings that only interface
// methods, generic receivers, struct fields, variant arms (all three shapes)
// and variant shared fields still lacked, and a batch of parser edge cases
// found by reading compiler_decls.zig line by line: isMethodDecl/
// isNamedFuncDecl's malformed-input lookahead branches, a generic type used
// as a plain type ANNOTATION (as opposed to a struct-literal expression,
// which is the only shape every existing generic test used), a generic
// variant type alias, and a handful of typeArgLabel/satisfiesConstraint
// branches for constraint violations on a type_param/named_t/variant_t/
// interface_t argument (only struct_t had a test before).

// emitZeroValue: bare `var x TYPE` (no initializer) for the primitive/
// collection/nominal shapes that weren't already covered — bigint and rune
// among primitives (int/float/bool/string were already covered), and the
// map/error/actor/interface/variant TypeCheck variants (array's bare form
// goes through a completely different, already-covered code path; see the
// dead-code note in the final report for why .assert_arr's own copy in
// emitZeroValue can never actually run).
test "compiler: a bare 'var x bigint' with no initializer zero-inits to bigint 0" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    var x bigint
        \\    return std.conv.to_int(x)
        \\}
        \\std := import("std")
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("f", &.{})).int);
}

test "compiler: a bare 'var x rune' with no initializer zero-inits to rune 0" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func f() int {
        \\    var x rune
        \\    return int(x)
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("f", &.{})).int);
}

test "compiler: a bare 'var x map[K]V', 'var x error', and 'var x actor' each zero-init without a runtime assertion" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\func fm() int {
        \\    var m map[string]int
        \\    return std.core.len(m)
        \\}
        \\func fe() bool {
        \\    var e error
        \\    return e == null
        \\}
        \\func fa() bool {
        \\    var a actor
        \\    var b actor
        \\    return a == b
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("fm", &.{})).int);
    try std.testing.expect((try rt.callGlobal("fe", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("fa", &.{})).boolean);
}

test "compiler: a bare 'var x SomeInterface' and 'var x SomeVariant' with no initializer zero-init to null" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Shape interface { area() int }
        \\type Opt variant { some(v int), none }
        \\func fi() bool {
        \\    var s Shape
        \\    return s == null
        \\}
        \\func fv() bool {
        \\    var o Opt
        \\    return o == null
        \\}
    );
    try std.testing.expect((try rt.callGlobal("fi", &.{})).boolean);
    try std.testing.expect((try rt.callGlobal("fv", &.{})).boolean);
}

// emitNamedDefault: the no-'default'-clause zero value for every named-type
// base that wasn't already covered (int/string were already exercised via
// other tests) — float/decimal/rune/bool scalars and named array/map types.
// (has_default's own array_t/map_t/enum_t arms, and the no-default enum_t
// arm, are dead from this function's sole caller; see the final report.)
test "compiler: a bare named-type var declaration zero-inits float/decimal/rune/bool/array/map bases with no 'default' clause" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\std := import("std")
        \\type F float
        \\type Dm decimal 2
        \\type R rune
        \\type B bool
        \\type Arr []int
        \\type M map[string]int
        \\func f1() float { var v F; return float(v) }
        \\func f2() int { var v Dm; return int(v) }
        \\func f3() int { var v R; return int(v) }
        \\func f4() bool { var v B; return bool(v) }
        \\func f5() int { var v Arr; return std.core.len(v) }
        \\func f6() int { var v M; return std.core.len(v) }
    );
    try std.testing.expectEqual(@as(f64, 0.0), (try rt.callGlobal("f1", &.{})).float);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("f2", &.{})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("f3", &.{})).int);
    try std.testing.expect(!(try rt.callGlobal("f4", &.{})).boolean);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("f5", &.{})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("f6", &.{})).int);
}

// ── interfaceDeclBody: duplicate/conflict checks and resource ceilings ─────

test "compiler: an interface name colliding with an existing struct type is a compile error (DuplicateNamedType)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type Foo struct { x int }
        \\type Foo interface { m() int }
    ));
}

test "compiler: an interface name colliding with an existing function is a compile error (DuplicateField)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\func Foo() int { return 1 }
        \\type Foo interface { m() int }
    ));
}

test "compiler: an interface with more than MaxLocals methods is a compile error (TooManyFields)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big interface {\n");
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "m{d}() int\n", .{i});
        try src.appendSlice(std.testing.allocator, line);
    }
    try src.appendSlice(std.testing.allocator, "}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyFields, r.err);
}

test "compiler: an interface method with more than MaxLocals parameters is a compile error (TooManyParams)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big interface {\nf(");
    var i: u32 = 0;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        try src.appendSlice(std.testing.allocator, "int");
    }
    try src.appendSlice(std.testing.allocator, ") int\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyParams, r.err);
}

test "compiler: an interface method with more than MaxLocals return types is a compile error (TooManyParams)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big interface {\nf() (");
    var i: u32 = 0;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        try src.appendSlice(std.testing.allocator, "int");
    }
    try src.appendSlice(std.testing.allocator, ")\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyParams, r.err);
}

// An interface method's parameter list allows a bare-type variadic (no name
// needed, unlike a real function — see isMethodDecl's sibling parser's own
// comment on why the bare-type form is allowed for interface specs).
test "compiler: an interface method may declare a bare-type variadic parameter" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Summable interface { sum(...int) int }
    );
}

test "compiler: an interface type declared inside a function body is a local" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func outer() int {
        \\    type Shape interface { area() int }
        \\    return 0
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outer", &.{})).int);
}

// ── isMethodDecl / isNamedFuncDecl: malformed-input lookahead branches ─────
// These two functions are pure lexer lookaheads (no registry access) used to
// decide whether `func` at a decl boundary starts a method, a generic named
// function, or a plain one. Their bracket/eof-scanning branches are only
// reachable via deliberately malformed source; the actual parse that follows
// then fails for an unrelated, expected reason.

test "compiler: a truncated generic method receiver (EOF inside the brackets) is a compile error, not a hang" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expect(std.meta.isError(compile(&rt, "func (s T[")));
}

test "compiler: a generic method receiver with a nested bracket in its type-parameter list is still recognized as a method decl" {
    var rt = try setup();
    defer rt.deinit();
    // isMethodDecl's lookahead only tracks bracket depth textually; it
    // doesn't validate that what's inside is a legal type-parameter list.
    // `T[[]int]` nests a bracket pair one level deep, exercising the
    // depth += 1 arm before the matching depth -= 1 closes it back out.
    // The actual parse (methodDecl) then fails because 'T' isn't a
    // registered generic type — that's the expected, unrelated error.
    try std.testing.expectError(error.UnexpectedToken, compile(&rt, "func (s T[[]int]) m() {}"));
}

test "compiler: a truncated generic function type-parameter list (EOF before ']') is a compile error, not a hang" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expect(std.meta.isError(compile(&rt, "func f[T")));
}

test "compiler: a stray non-identifier token inside a generic function's bracketed type-parameter list is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expect(std.meta.isError(compile(&rt, "func f[T, 5](x int) int { return x }")));
}

// ── methodDecl: receiver type-param ceiling and local-scope declaration ────

test "compiler: a method receiver with more than MaxTypeParams type parameters is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnexpectedToken, compile(&rt,
        \\type Box[T] struct { v T }
        \\func (s Box[A,B,C,D,E,F,G,H,I]) m() int { return 0 }
    ));
}

test "compiler: a method declared inside a function body is a local" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func outer() int {
        \\    type Foo struct { x int }
        \\    func (f Foo) m() int { return f.x }
        \\    return 0
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outer", &.{})).int);
}

// methodDecl's own copy of the global-function-count ceiling (namedFuncDecl's
// copy already has coverage) — fill the shared global_count counter with
// cheap top-level consts (no heap allocation, unlike struct/func objects)
// up to MaxGlobals, then declare exactly one method as the final, tipping
// declaration.
test "compiler: declaring a method after the global function/const table is full is a compile error (TooManyGlobals)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i < ct.MaxGlobals) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "const c{d} = 0\n", .{i});
        try src.appendSlice(std.testing.allocator, line);
    }
    try src.appendSlice(std.testing.allocator, "type S struct { x int }\nfunc (s S) m() int { return 1 }\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyGlobals, r.err);
}

// ── taskDeclBody / namedErrorTypeDecl / variantDeclBody: local declaration ──

test "compiler: a task type declared inside a function body is a local" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func outer() int {
        \\    type Worker task func() {}
        \\    return 0
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outer", &.{})).int);
}

test "compiler: a named error type declared inside a function body is a local" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func outer() int {
        \\    type MyErr error
        \\    return 0
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outer", &.{})).int);
}

test "compiler: a variant type declared inside a function body is a local" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func outer() int {
        \\    type V variant { a, b }
        \\    return 0
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outer", &.{})).int);
}

// ── namedTypeDecl: duplicate/conflict checks, local declaration for every
// shape, enum member ceiling, and the decimal-scale-override branch ────────

test "compiler: a plain named-type name colliding with an existing struct type is a compile error (DuplicateNamedType)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type Foo struct { x int }
        \\type Foo int
    ));
}

test "compiler: a plain named-type name colliding with an existing function is a compile error (DuplicateField)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\func Foo() int { return 1 }
        \\type Foo int
    ));
}

test "compiler: an enum with more than MaxLocals members is a compile error (TooManyFields)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big enum {\n");
    var i: u32 = 0;
    var buf: [16]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        const m = try std.fmt.bufPrint(&buf, "m{d}", .{i});
        try src.appendSlice(std.testing.allocator, m);
    }
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyFields, r.err);
}

test "compiler: an enum type, a named array/map type, and a generic-instantiation alias each declared inside a function body are locals" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func outerEnum() int {
        \\    type Color enum { red, green }
        \\    return 0
        \\}
        \\func outerArr() int {
        \\    type IntList []int
        \\    return 0
        \\}
        \\func outerMap() int {
        \\    type M map[string]int
        \\    return 0
        \\}
        \\func outerAlias() int {
        \\    type Stack[T] struct { items []T }
        \\    type LocalIntStack Stack[int]
        \\    return 0
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outerEnum", &.{})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outerArr", &.{})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outerMap", &.{})).int);
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outerAlias", &.{})).int);
}

// namedTypeDecl's decimal-scale branch for a NON-primitive base ("Named-type
// alias: scale is inherited from parent; an explicit number overrides") —
// only the primitive `type X decimal N` form (which requires the scale) had
// coverage; aliasing an existing decimal named type while overriding its
// inherited scale did not.
test "compiler: a decimal named-type alias can override its parent's inherited scale with an explicit number" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type D decimal 2
        \\type D2 D 4
        \\func f() string { return string(D2(1)) }
    );
    _ = try rt.callGlobal("f", &.{});
}

// ── structDeclBody: duplicate/conflict checks, field-count ceiling, missing
// type annotation, local declaration, and a func-typed field ───────────────

test "compiler: a struct name colliding with an existing interface type is a compile error (DuplicateNamedType)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type Foo interface { m() int }
        \\type Foo struct { x int }
    ));
}

test "compiler: a struct name colliding with an existing function is a compile error (DuplicateField)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\func Foo() int { return 1 }
        \\type Foo struct { x int }
    ));
}

test "compiler: a struct with more than MaxLocals fields is a compile error (TooManyFields)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big struct {\n");
    var i: u32 = 0;
    var buf: [16]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        const f = try std.fmt.bufPrint(&buf, "f{d} int", .{i});
        try src.appendSlice(std.testing.allocator, f);
    }
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyFields, r.err);
}

test "compiler: a struct field with no type annotation at all is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expect(std.meta.isError(compile(&rt,
        \\type S struct { x }
    )));
}

test "compiler: a struct type declared inside a function body is a local" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func outer() int {
        \\    type Point struct { x int }
        \\    return 0
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outer", &.{})).int);
}

// checkStructFieldType's func_t branch (recursing into a func-typed field's
// param/return specs) had no test at all — every other struct-field-type
// test uses a scalar/array/map/interface/optional field.
test "compiler: a struct field typed as a function stores and calls the assigned function" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Node struct { cb func(int) int }
        \\func addOne(x int) int { return x + 1 }
        \\func f() int {
        \\    n := Node{ cb: addOne }
        \\    return n.cb(5)
        \\}
    );
    try std.testing.expectEqual(@as(i64, 6), (try rt.callGlobal("f", &.{})).int);
}

// ── subtypeDecl: duplicate/conflict checks, enum-subtype ceiling, local
// declaration, capturing predicate + message clause, default-outside-range ─

test "compiler: an enum subtype name colliding with an existing named type is a compile error (DuplicateNamedType)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type Days enum { mon, tue, wed }
        \\type Dup int
        \\subtype Dup Days { mon }
    ));
}

test "compiler: an enum subtype with more than MaxLocals members is a compile error (TooManyFields)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Days enum { mon }\nsubtype Weekend Days {\n");
    var i: u32 = 0;
    var buf: [16]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        const m = try std.fmt.bufPrint(&buf, "m{d}", .{i});
        try src.appendSlice(std.testing.allocator, m);
    }
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyFields, r.err);
}

test "compiler: an enum subtype declared inside a function body is a local" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Days enum { mon, tue, wed }
        \\func outer() int {
        \\    subtype Weekend Days { mon }
        \\    return 0
        \\}
    );
    try std.testing.expectEqual(@as(i64, 0), (try rt.callGlobal("outer", &.{})).int);
}

test "compiler: a scalar subtype name colliding with an existing named type is a compile error (DuplicateNamedType)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateNamedType, compile(&rt,
        \\type Base int
        \\type Dup int
        \\subtype Dup Base range 0..5
    ));
}

// subtypeDecl's own copy of the in-function capturing-predicate fix (issue
// #211's regression test only exercised namedTypeDecl's copy) plus the
// 'message' clause, which had no test at either subtypeDecl or namedTypeDecl.
test "compiler: an in-function scalar subtype's capturing predicate with a custom message reports that message on failure" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func make(threshold int, val int) int {
        \\    type Base int
        \\    subtype Strict Base predicate func(x) { return x >= threshold } message "too small"
        \\    return int(Strict(val))
        \\}
    );
    try std.testing.expectEqual(@as(i64, 5), (try rt.callGlobal("make", &.{ .{ .int = 5 }, .{ .int = 5 } })).int);
    try std.testing.expectError(error.PredicateFailed, rt.callGlobal("make", &.{ .{ .int = 5 }, .{ .int = 1 } }));
    try std.testing.expect(std.mem.indexOf(u8, rt.last_runtime_msg_buf[0..rt.last_runtime_msg_len], "too small") != null);
}

test "compiler: a subtype's default value outside its own range is a compile error, even though clamp/range default checks were only tested on named types" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.RangeError, compile(&rt,
        \\type Base int
        \\subtype Strict Base range 0..10 default 50
    ));
}

// ── variantDeclBody: duplicate/conflict checks (zero coverage before this),
// every arm shape's field/arm-count ceiling and duplicate-name check, and
// local declaration ─────────────────────────────────────────────────────────

test "compiler: a duplicate variant type name is a compile error (DuplicateVariantType)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateVariantType, compile(&rt,
        \\type V variant { a, b }
        \\type V variant { c, d }
    ));
}

test "compiler: a variant name colliding with an existing struct type is a compile error (DuplicateVariantType)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateVariantType, compile(&rt,
        \\type Foo struct { x int }
        \\type Foo variant { a, b }
    ));
}

test "compiler: a variant name colliding with an existing function is a compile error (DuplicateField)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\func Foo() int { return 1 }
        \\type Foo variant { a, b }
    ));
}

test "compiler: a variant with more than MaxLocals single-payload arms is a compile error (TooManyLocals)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big variant {\n");
    var i: u32 = 0;
    var buf: [24]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        const a = try std.fmt.bufPrint(&buf, "a{d}(int)", .{i});
        try src.appendSlice(std.testing.allocator, a);
    }
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyLocals, r.err);
}

test "compiler: a variant record arm with more than MaxLocals fields is a compile error (TooManyFields)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big variant {\nrec {\n");
    var i: u32 = 0;
    var buf: [24]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        const f = try std.fmt.bufPrint(&buf, "f{d} int", .{i});
        try src.appendSlice(std.testing.allocator, f);
    }
    try src.appendSlice(std.testing.allocator, "\n}\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyFields, r.err);
}

test "compiler: a variant record arm field with no type annotation at all is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expect(std.meta.isError(compile(&rt,
        \\type V variant { rec { x } }
    )));
}

test "compiler: a variant with more than MaxLocals record arms is a compile error (TooManyLocals)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big variant {\n");
    var i: u32 = 0;
    var buf: [24]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        const a = try std.fmt.bufPrint(&buf, "r{d} {{ v int }}", .{i});
        try src.appendSlice(std.testing.allocator, a);
    }
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyLocals, r.err);
}

test "compiler: two variant record arms with the same name is a compile error (DuplicateField)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\type V variant { r1 { x int }, r1 { y int } }
    ));
}

test "compiler: a variant with more than MaxLocals no-payload arms is a compile error (TooManyLocals)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big variant {\n");
    var i: u32 = 0;
    var buf: [16]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        const a = try std.fmt.bufPrint(&buf, "a{d}", .{i});
        try src.appendSlice(std.testing.allocator, a);
    }
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyLocals, r.err);
}

test "compiler: two no-payload variant arms with the same name is a compile error (DuplicateField)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\type V variant { a, a }
    ));
}

test "compiler: a variant with more than MaxLocals shared fields is a compile error (TooManyFields)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type Big variant {\n");
    var i: u32 = 0;
    var buf: [16]u8 = undefined;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        const f = try std.fmt.bufPrint(&buf, "f{d} int", .{i});
        try src.appendSlice(std.testing.allocator, f);
    }
    try src.appendSlice(std.testing.allocator, "\n}\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyFields, r.err);
}

test "compiler: two variant shared fields with the same name is a compile error (DuplicateField)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.DuplicateField, compile(&rt,
        \\type V variant { count int, count int }
    ));
}

test "compiler: a variant type declared inside a function body is a local (variantDeclBody's own copy)" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\func outer() int {
        \\    type V variant { ok(v int), bad }
        \\    v := V.ok(3)
        \\    switch v {
        \\        case .ok as n { return n }
        \\        case .bad { return -1 }
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(i64, 3), (try rt.callGlobal("outer", &.{})).int);
}

// ── parseConstraintBounds / parseConstPrimary / parseNamedDefault /
// parseSignedNumber: remaining parser edge cases ────────────────────────────

test "compiler: a range whose minimum exceeds its maximum is a compile error (RangeError)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.RangeError, compile(&rt,
        \\type X int range 10..5
    ));
}

test "compiler: a boolean literal 'false' used as a range bound is rejected as a non-constant expression, same as 'true'" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.CompileTimeConstant, compile(&rt,
        \\type Z int range false..10
    ));
}

// parseNamedDefault's final `else` arm ("'default' not supported for this
// base type") is unreachable for a primitive base (namedTypeDecl only
// recognizes 'default' after int/float/decimal/string/bool/rune primitives
// take a distinct branch above it) but IS reachable when the base is
// inherited from a parent named array/map type via the aliasing path.
test "compiler: 'default' is not supported for a named array-type alias (parseNamedDefault's else arm)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expect(std.meta.isError(compile(&rt,
        \\type Arr []int
        \\type Arr2 Arr default 5
    )));
}

// parseSignedNumber's BadNumber path requires a `.number`-shaped token that
// still fails common.parseFloat -- an incomplete hex literal ('0x' with no
// hex digits after it) lexes as a complete number token but parses to null.
test "compiler: an enum member's explicit value using an incomplete hex literal ('0x') is a compile error (BadNumber)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.BadNumber, compile(&rt,
        \\type X enum { a = 0x }
    ));
}

// ── Generic type used as a plain type ANNOTATION (function param, struct
// field) rather than a struct-literal expression — every prior generic test
// in this file only ever instantiated a generic type as a literal
// (`Box[int]{...}`), which is parsed entirely in compiler_expr.zig and never
// touches parseFieldTypeSpec's own generic-instantiation branch at all ────

test "compiler: a generic struct type used as a plain function parameter annotation instantiates it" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box[T] struct { val T }
        \\func getVal(b Box[int]) int { return b.val }
        \\func f() int { return getVal(Box[int]{val: 5}) }
    );
    try std.testing.expectEqual(@as(i64, 5), (try rt.callGlobal("f", &.{})).int);
}

// The DEFERRED form of the same branch (the type argument is itself a type
// parameter, because the annotation appears inside another generic type's
// own template body) for a generic VARIANT specifically — an existing
// comment in substituteSpec already documents this exact shape for a generic
// STRUCT nested in a generic struct; nothing exercised the variant_t analog.
test "compiler: a generic variant type used as a field annotation inside another generic struct's template instantiates it" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Opt[T] variant { some(v T), none }
        \\type Wrapper[T] struct { inner Opt[T] }
        \\func f() int {
        \\    w := Wrapper[int]{ inner: Opt[int].some(9) }
        \\    switch w.inner {
        \\        case .some as v { return v }
        \\        case .none { return -1 }
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(i64, 9), (try rt.callGlobal("f", &.{})).int);
}

// A generic-instantiation ALIAS (`type Alias Base[args]`) whose base is a
// generic VARIANT, used as a type annotation elsewhere — only the generic
// STRUCT alias shape (used by methodDecl's receiver) had coverage.
test "compiler: a type alias of a generic variant instantiation can be used as a function parameter type" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Opt[T] variant { some(v T), none }
        \\type IntOpt Opt[int]
        \\func f(x IntOpt) int {
        \\    switch x {
        \\        case .some as v { return v }
        \\        case .none { return -1 }
        \\    }
        \\}
        \\func g() int { return f(Opt[int].some(7)) }
    );
    try std.testing.expectEqual(@as(i64, 7), (try rt.callGlobal("g", &.{})).int);
}

// substituteSpec's map key_spec/val_spec substitution (a generic struct field
// typed map[K]V, where K and/or V are the struct's own type parameters) —
// every existing generic-struct test used an array or scalar field, never a
// map.
test "compiler: a generic struct field typed map[K]V substitutes both the key and value type parameters on instantiation" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Box[K,V] struct { m map[K]V }
        \\func f() int {
        \\    b := Box[string,int]{ m: {"a": 1} }
        \\    return b.m["a"]
        \\}
    );
    try std.testing.expectEqual(@as(i64, 1), (try rt.callGlobal("f", &.{})).int);
}

// ── Module-qualified type annotation edge cases (parseFieldTypeSpec's
// `alias.TypeName` branch) ──────────────────────────────────────────────────

test "compiler: a module-qualified type annotation naming a real function (not a type) in that module is a compile error" {
    var rt = try setup();
    defer rt.deinit();
    const main_src =
        \\dep := import("./dep")
        \\func f() { for x dep.helper = 0; false; {} }
    ;
    const dep_src =
        \\pub func helper() int { return 1 }
    ;
    const source_entries = [_]module_compile.SourceEntry{
        .{ .path = "main.gengo", .source = main_src },
        .{ .path = "dep.gengo", .source = dep_src },
    };
    try std.testing.expectError(error.UnexpectedToken, rt.compileOnly(main_src, "main.gengo", .{ .table = &source_entries }));
}

test "compiler: a module-qualified type annotation whose alias was never imported is a compile error (UnknownType)" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.UnknownType, compile(&rt,
        \\func f() { for x foo.Bar = 0; false; {} }
    ));
}

// ── typeArgLabel / satisfiesConstraint: the type_param/named_t/variant_t/
// interface_t branches of a ConstraintViolation error message — only
// struct_t had a test (via a `numeric`-constrained struct type argument) ───

test "compiler: passing an enclosing generic function's own (erased) type parameter to a numeric-constrained generic call is a ConstraintViolation" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ConstraintViolation, compile(&rt,
        \\func inner[T numeric](x T) T { return x }
        \\func outer[U](x U) U { return inner[U](x) }
    ));
}

test "compiler: a named-type argument whose base fails a 'numeric' constraint is a ConstraintViolation naming the named type" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ConstraintViolation, compile(&rt,
        \\type Flag bool
        \\func numOnly[T numeric](x T) T { return x }
        \\func g() { _ = numOnly[Flag](Flag(true)) }
    ));
}

test "compiler: a variant-type argument to a 'numeric'-constrained generic call is a ConstraintViolation naming the variant type" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ConstraintViolation, compile(&rt,
        \\type Opt variant { some(v int), none }
        \\func numOnly2[T numeric](x T) T { return x }
        \\func g() { _ = numOnly2[Opt](Opt.none) }
    ));
}

test "compiler: an interface-type argument to a 'numeric'-constrained generic call is a ConstraintViolation naming the interface" {
    var rt = try setup();
    defer rt.deinit();
    try std.testing.expectError(error.ConstraintViolation, compile(&rt,
        \\type Shape interface { area() int }
        \\func numOnly3[T numeric](x T) T { return x }
        \\func g() { _ = numOnly3[Shape](0) }
    ));
}

// satisfiesConstraint's module-prefix dot-stripping fallback: inside a
// module-compiled file, a locally-declared named type's FieldTypeAlt carries
// the module-qualified name (e.g. "mymod.Meters"), but the type registry
// still stores it under its bare local name — a direct lookup misses and the
// dot-stripped fallback is what actually resolves it.
test "compiler: a numeric-constrained generic call inside a compiled module resolves its own named-type argument via the dot-stripped registry lookup" {
    var rt = try setup();
    defer rt.deinit();
    try compileWithSession(&rt,
        \\type Meters float
        \\func biggest[T numeric](x T) T { return x }
        \\func g() float { return biggest[Meters](Meters(5.0)) }
    , "mymod");
}

test "compiler: a named string-type argument satisfies the 'ordered' constraint via satisfiesConstraint's named_t string check" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Label string
        \\func biggestOrdered[T ordered](x T) T { return x }
        \\func g() string { return biggestOrdered[Label](Label("a")) }
    );
    try std.testing.expectEqualStrings("a", try vms.asStringValue(try rt.callGlobal("g", &.{})));
}

// satisfiesConstraint's __compare__ fallback for a named (non-struct,
// non-numeric, non-string) type — only the struct_t copy of this same qname
// switch had a test.
test "compiler: a named bool-type argument satisfies the 'ordered' constraint by declaring __compare__" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type Flag2 bool
        \\func (a Flag2) __compare__(b Flag2) int { return 0 }
        \\func biggestOrdered2[T ordered](x T) T { return x }
        \\func g() bool { return bool(biggestOrdered2[Flag2](Flag2(true))) }
    );
    try std.testing.expect((try rt.callGlobal("g", &.{})).boolean);
}

// ── parseFieldTypeSpec: func-type spec parameter/return-type ceilings and
// the previously-untested parenthesized multi-return-type form ────────────

test "compiler: a func-typed struct field with more than one return type in its parenthesized return list is accepted" {
    var rt = try setup();
    defer rt.deinit();
    try runSrc(&rt,
        \\type S struct { cb func(int) (int, string) }
    );
}

test "compiler: a func-type annotation with more than MaxLocals parameters is a compile error (TooManyParams)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type S struct { cb func(");
    var i: u32 = 0;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        try src.appendSlice(std.testing.allocator, "int");
    }
    try src.appendSlice(std.testing.allocator, ") int }\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyParams, r.err);
}

test "compiler: a func-type annotation with more than MaxLocals parenthesized return types is a compile error (TooManyParams)" {
    var rt = try setup();
    defer rt.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "type S struct { cb func(int) (");
    var i: u32 = 0;
    while (i <= ct.MaxLocals) : (i += 1) {
        if (i > 0) try src.appendSlice(std.testing.allocator, ",");
        try src.appendSlice(std.testing.allocator, "int");
    }
    try src.appendSlice(std.testing.allocator, ") }\n");
    const r = compileAndInspect(&rt, src.items);
    try std.testing.expectEqual(error.TooManyParams, r.err);
}
