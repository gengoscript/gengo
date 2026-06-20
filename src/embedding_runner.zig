const std = @import("std");
const api = @import("runtime/api.zig");
const Value = @import("lang/value.zig").Value;

fn writeAll(fd: std.os.wasi.fd_t, s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        var iov = [1]std.os.wasi.ciovec_t{.{ .base = s[off..].ptr, .len = s.len - off }};
        var wrote: usize = 0;
        if (std.os.wasi.fd_write(fd, &iov, iov.len, &wrote) != .SUCCESS or wrote == 0) return;
        off += wrote;
    }
}

fn out(s: []const u8) void {
    writeAll(1, s);
}

fn fail(msg: []const u8) noreturn {
    writeAll(2, msg);
    std.os.wasi.proc_exit(1);
}

fn makeRt(config: api.Config) *api.Runtime {
    const rt = std.heap.page_allocator.create(api.Runtime) catch fail("embedding: out of memory\n");
    rt.initWithPolicy(config) catch fail("embedding: runtime init failed\n");
    return rt;
}

fn expectInitByValue() void {
    var rt = api.Runtime.init(.{ .allow_io = false }) catch fail("embedding: runtime init failed\n");
    defer rt.deinit();
    const res = rt.run(
        \\func answer() int { return 42 }
    );
    switch (res) {
        .ok => {},
        else => fail("embedding FAIL: init by-value should work\n"),
    }
    const call_res = rt.call("answer", &[_]Value{});
    switch (call_res) {
        .ok => |v| {
            if (v != .int or v.int != 42) fail("embedding FAIL: init by-value result\n");
        },
        else => fail("embedding FAIL: init by-value call\n"),
    }
}

fn expectCompileError() void {
    const rt = makeRt(.{ .allow_io = false });
    const res = rt.run(
        \\std := import("std")
        \\x :=
    );
    switch (res) {
        .compile_error => |e| {
            if (e.line == 0) fail("embedding FAIL: compile line missing\n");
        },
        else => fail("embedding FAIL: expected compile_error\n"),
    }
}

fn expectRuntimeError() void {
    const rt = makeRt(.{ .allow_io = false });
    const res = rt.run(
        \\func bad() int { return 1 + "x" }
    );
    switch (res) {
        .ok => {},
        else => fail("embedding FAIL: setup script should compile/run\n"),
    }
    const call_res = rt.call("bad", &[_]Value{});
    switch (call_res) {
        .runtime_error => |e| {
            if (e.kind != error.TypeError) fail("embedding FAIL: expected TypeError\n");
            if (e.msg.len == 0) fail("embedding FAIL: runtime error missing message\n");
        },
        else => fail("embedding FAIL: expected runtime_error from call\n"),
    }
}

fn expectCallAndStatePersistence() void {
    const rt = makeRt(.{ .allow_io = false });
    const res = rt.run(
        \\counter := 0
        \\func bump() int {
        \\    counter += 1
        \\    return counter
        \\}
    );
    switch (res) {
        .ok => {},
        else => fail("embedding FAIL: runtime setup failed\n"),
    }

    const r1 = rt.call("bump", &[_]Value{});
    const r2 = rt.call("bump", &[_]Value{});
    const r3 = rt.call("bump", &[_]Value{});
    if (r1 != .ok or r1.ok != .int or r1.ok.int != 1) fail("embedding FAIL: bump #1\n");
    if (r2 != .ok or r2.ok != .int or r2.ok.int != 2) fail("embedding FAIL: bump #2\n");
    if (r3 != .ok or r3.ok != .int or r3.ok.int != 3) fail("embedding FAIL: bump #3\n");
}

fn expectMaxOps() void {
    const rt = makeRt(.{ .allow_io = false, .max_ops = 64 });
    const res = rt.run(
        \\for true {
        \\}
    );
    switch (res) {
        .runtime_error => |e| {
            if (e.kind != error.InstructionBudgetExceeded) fail("embedding FAIL: expected InstructionBudgetExceeded\n");
        },
        else => fail("embedding FAIL: expected runtime_error for budget\n"),
    }
}

const MemorySourceSet = struct {
    entries: []const api.SourceEntry,
};

fn loadMemorySource(ctx: *anyopaque, path: []const u8) anyerror!?[]const u8 {
    const set: *const MemorySourceSet = @ptrCast(@alignCast(ctx));
    for (set.entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.source;
    }
    return null;
}

fn expectRunPathWithSources() void {
    const sources = [_]api.SourceEntry{
        .{
            .path = "app/pkg/mod.gengo",
            .source =
                \\pub func answer() int {
                \\    return 42
                \\}
            ,
        },
    };
    const rt = makeRt(.{
        .allow_io = false,
        .module_sources = &sources,
    });
    const res = rt.runPath(
        \\pkg := import("./pkg")
        \\func read() int {
        \\    return pkg.answer()
        \\}
    , "app/main.gengo");
    switch (res) {
        .ok => {},
        else => fail("embedding FAIL: runPathWithSources setup failed\n"),
    }
    const call_res = rt.call("read", &[_]Value{});
    switch (call_res) {
        .ok => |v| {
            if (v != .int or v.int != 42) fail("embedding FAIL: runPathWithSources result\n");
        },
        else => fail("embedding FAIL: expected runPathWithSources call success\n"),
    }
}

fn expectPredicatePanicLocation() void {
    const rt = makeRt(.{ .allow_io = false });
    const res = rt.run(
        \\type Bad int predicate func(x) {
        \\    arr := []
        \\    return arr[0] == x
        \\}
        \\b := Bad(5)
    );
    switch (res) {
        .runtime_error => |e| {
            // The actual fault is on line 3 (arr[0] inside predicate body),
            // not line 5 (the Bad(5) constructor call site).
            if (e.line != 3) fail("embedding FAIL: predicate panic line wrong\n");
        },
        else => fail("embedding FAIL: expected runtime_error from predicate panic\n"),
    }
}

fn expectRunPathWithSourceProvider() void {
    const entries = [_]api.SourceEntry{
        .{
            .path = "mem/math.gengo",
            .source =
                \\pub func add(a int, b int) int {
                \\    return a + b
                \\}
            ,
        },
    };
    const set = MemorySourceSet{ .entries = &entries };
    const rt = makeRt(.{ .allow_io = false });
    const res = rt.runPathWithSourceProvider(
        \\math := import("./math")
        \\func read() int {
        \\    return math.add(20, 22)
        \\}
    , "mem/main.gengo", .{
        .callback = .{
            .ctx = @constCast(&set),
            .load = loadMemorySource,
        },
    });
    switch (res) {
        .ok => {},
        else => fail("embedding FAIL: runPathWithSourceProvider setup failed\n"),
    }
    const call_res = rt.call("read", &[_]Value{});
    switch (call_res) {
        .ok => |v| {
            if (v != .int or v.int != 42) fail("embedding FAIL: runPathWithSourceProvider result\n");
        },
        else => fail("embedding FAIL: expected runPathWithSourceProvider call success\n"),
    }
}

fn expectImportLoaderWithFallback() void {
    const table_entries = [_]api.SourceEntry{
        .{ .path = "mod/fallback.gengo", .source =
            \\pub func fromTable() string { return "table" }
        },
    };
    const callback_entries = [_]api.SourceEntry{
        .{ .path = "mod/callback.gengo", .source =
            \\pub func fromCallback() string { return "callback" }
        },
    };
    const callback_set = MemorySourceSet{ .entries = &callback_entries };

    const CombinedSources = struct {
        callback_set: *const MemorySourceSet,
        table: []const api.SourceEntry,
    };
    const combined = CombinedSources{
        .callback_set = &callback_set,
        .table = &table_entries,
    };
    const rt = makeRt(.{ .allow_io = false });

    const ctx = @constCast(&combined);
    const loadWrapper = struct {
        fn load(c: *anyopaque, path: []const u8) anyerror!?[]const u8 {
            const cs: *const CombinedSources = @ptrCast(@alignCast(c));
            for (cs.callback_set.entries) |e| {
                if (std.mem.eql(u8, e.path, path)) return e.source;
            }
            for (cs.table) |e| {
                if (std.mem.eql(u8, e.path, path)) return e.source;
            }
            return null;
        }
    }.load;

    const res = rt.runPathWithSourceProvider(
        \\cb  := import("./callback")
        \\fb  := import("./fallback")
        \\func get() string {
        \\    return cb.fromCallback() + fb.fromTable()
        \\}
    , "mod/main.gengo", .{
        .callback = .{
            .ctx = ctx,
            .load = loadWrapper,
        },
    });
    switch (res) {
        .ok => {},
        else => fail("embedding FAIL: importLoaderWithFallback setup failed\n"),
    }
    const call_res = rt.call("get", &[_]Value{});
    switch (call_res) {
        .ok => |v| {
            const s = if (v == .string) v.string.bytes
                else if (v == .object and v.object.* == .dyn_string) v.object.dyn_string
                else if (v == .object and v.object.* == .string_view) v.object.string_view.bytes
                else null;
            if (s == null or !std.mem.eql(u8, s.?, "callbacktable"))
                fail("embedding FAIL: importLoaderWithFallback result\n");
        },
        else => fail("embedding FAIL: expected importLoaderWithFallback call success\n"),
    }
}

export fn _start() void {
    expectInitByValue();
    expectCompileError();
    expectRuntimeError();
    expectCallAndStatePersistence();
    expectMaxOps();
    expectRunPathWithSources();
    expectPredicatePanicLocation();
    expectRunPathWithSourceProvider();
    expectImportLoaderWithFallback();
    out("embedding-api OK\n");
    std.os.wasi.proc_exit(0);
}
