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

fn expectCompileError() void {
    var rt = api.Runtime.init(.{ .allow_io = false });
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
    var rt = api.Runtime.init(.{ .allow_io = false });
    const res = rt.run(
        \\func bad() { return 1 + "x" }
    );
    switch (res) {
        .ok => {},
        else => fail("embedding FAIL: setup script should compile/run\n"),
    }
    const call_res = rt.call("bad", &[_]Value{});
    switch (call_res) {
        .runtime_error => |e| {
            if (e.kind != error.TypeError) fail("embedding FAIL: expected TypeError\n");
        },
        else => fail("embedding FAIL: expected runtime_error from call\n"),
    }
}

fn expectCallAndStatePersistence() void {
    var rt = api.Runtime.init(.{ .allow_io = false });
    const res = rt.run(
        \\counter := 0
        \\func bump() {
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
    if (r1 != .ok or r1.ok != .number or r1.ok.number != 1) fail("embedding FAIL: bump #1\n");
    if (r2 != .ok or r2.ok != .number or r2.ok.number != 2) fail("embedding FAIL: bump #2\n");
    if (r3 != .ok or r3.ok != .number or r3.ok.number != 3) fail("embedding FAIL: bump #3\n");
}

fn expectMaxOps() void {
    var rt = api.Runtime.init(.{ .allow_io = false, .max_ops = 64 });
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

export fn _start() void {
    expectCompileError();
    expectRuntimeError();
    expectCallAndStatePersistence();
    expectMaxOps();
    out("embedding-api OK\n");
    std.os.wasi.proc_exit(0);
}
