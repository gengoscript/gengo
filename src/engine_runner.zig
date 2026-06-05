const std = @import("std");
const api = @import("runtime/api.zig");
const io = @import("runtime/io.zig");
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

fn out(s: []const u8) void { writeAll(1, s); }
fn fail(msg: []const u8) noreturn { writeAll(2, msg); std.os.wasi.proc_exit(1); }

var capture_buf: [4096]u8 = undefined;
var capture_len: usize = 0;

fn captureWrite(s: []const u8) void {
    const avail = @min(s.len, capture_buf.len - capture_len);
    @memcpy(capture_buf[capture_len..][0..avail], s[0..avail]);
    capture_len += avail;
}

fn captureWerr(s: []const u8) void {
    _ = s;
}

fn makeRt(config: api.Config) *api.Runtime {
    const rt = std.heap.page_allocator.create(api.Runtime) catch fail("engine: out of memory\n");
    rt.initWithPolicy(config);
    return rt;
}

fn initWithAllowIO(allow_io: bool) *api.Runtime {
    return makeRt(.{ .allow_io = allow_io });
}

fn testInitDestroy() void {
    const rt = initWithAllowIO(false);
    rt.reset();
    out("  init/destroy: OK\n");
}

fn testRun() void {
    const rt = initWithAllowIO(false);
    const res = rt.run(
        \\x := 42
        \\func getX() int { return x }
    );
    switch (res) {
        .ok => {},
        else => fail("engine FAIL: run failed\n"),
    }
    out("  run: OK\n");
}

fn testMultiHandle() void {
    const rt1 = initWithAllowIO(false);
    const rt2 = initWithAllowIO(false);

    const res1 = rt1.run("counter := 0\nfunc bump() int { counter += 1; return counter }\n");
    if (res1 != .ok) fail("engine FAIL: h1 setup\n");

    const res2 = rt2.run("counter := 100\nfunc bump() int { counter += 1; return counter }\n");
    if (res2 != .ok) fail("engine FAIL: h2 setup\n");

    const b1 = rt1.call("bump", &.{});
    const b2 = rt2.call("bump", &.{});
    const b3 = rt1.call("bump", &.{});

    if (b1 != .ok or b1.ok != .number or b1.ok.number != 1) fail("engine FAIL: h1 bump #1\n");
    if (b2 != .ok or b2.ok != .number or b2.ok.number != 101) fail("engine FAIL: h2 bump #1\n");
    if (b3 != .ok or b3.ok != .number or b3.ok.number != 2) fail("engine FAIL: h1 bump #2\n");

    out("  multi-handle isolation: OK\n");
}

fn testRunPathWithSourceProvider() void {
    const sources = [_]api.SourceEntry{
        .{
            .path = "app/pkg/mod.gengo",
            .source = "pub func answer() int { return 42 }\n",
        },
    };
    const rt = makeRt(.{ .allow_io = false, .module_sources = &sources });
    const res = rt.runPath(
        \\pkg := import("./pkg")
        \\func read() int {
        \\    return pkg.answer()
        \\}
    , "app/main.gengo");
    switch (res) {
        .ok => {},
        else => fail("engine FAIL: runPath with sources setup failed\n"),
    }
    const call_res = rt.call("read", &.{});
    switch (call_res) {
        .ok => |v| {
            if (v != .number or v.number != 42) fail("engine FAIL: runPath result\n");
        },
        else => fail("engine FAIL: runPath call failed\n"),
    }
    out("  run_path with sources: OK\n");
}

fn testCallWithArgs() void {
    const rt = initWithAllowIO(false);
    const res = rt.run(
        \\func add(a int, b int) int {
        \\    return a + b
        \\}
    );
    if (res != .ok) fail("engine FAIL: call_with_args setup\n");

    const call_res = rt.call("add", &.{ .{ .number = 20 }, .{ .number = 22 } });
    switch (call_res) {
        .ok => |v| {
            if (v != .number or v.number != 42) fail("engine FAIL: add(20,22) != 42\n");
        },
        else => fail("engine FAIL: add call failed\n"),
    }
    out("  call with args: OK\n");
}

fn testReset() void {
    const rt = initWithAllowIO(false);

    const r1 = rt.run("x := 1\n");
    if (r1 != .ok) fail("engine FAIL: reset setup\n");

    rt.reset();

    const r2 = rt.run("x := 2\n");
    if (r2 != .ok) fail("engine FAIL: reset then rerun\n");

    out("  reset: OK\n");
}

fn testLastError() void {
    const rt = initWithAllowIO(false);

    const res = rt.run("x :=\n");
    switch (res) {
        .compile_error => |e| {
            if (e.msg.len == 0) fail("engine FAIL: compile error without message\n");
        },
        else => fail("engine FAIL: expected compile error\n"),
    }

    // Runtime error via call
    const r2 = rt.run(
        \\func fail() int { return 1 + "x" }
    );
    if (r2 != .ok) fail("engine FAIL: last_error setup\n");

    const call_res = rt.call("fail", &.{});
    switch (call_res) {
        .runtime_error => |e| {
            if (e.kind != error.TypeError) fail("engine FAIL: expected TypeError\n");
        },
        else => fail("engine FAIL: expected runtime error\n"),
    }
    out("  last_error: OK\n");
}

fn testIO() void {
    io.setWriteOverrides(captureWrite, captureWerr);
    defer io.clearWriteOverrides();

    capture_len = 0;

    const rt = initWithAllowIO(true);
    const res = rt.run(
        \\std := import("std")
        \\std.io.println("hello from engine")
    );
    switch (res) {
        .ok => {},
        .compile_error => fail("engine FAIL: io compile error\n"),
        .runtime_error => fail("engine FAIL: io runtime error\n"),
    }

    if (capture_len == 0) fail("engine FAIL: io produced no output\n");

    out("  std.io hook: OK\n");
}

export fn _start() void {
    out("engine runner:\n");
    testInitDestroy();
    testRun();
    testMultiHandle();
    testRunPathWithSourceProvider();
    testCallWithArgs();
    testReset();
    testLastError();
    testIO();
    out("engine-api OK\n");
    std.os.wasi.proc_exit(0);
}
