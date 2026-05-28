const std = @import("std");

const chunk = @import("lang/chunk.zig");
const globals = @import("lang/globals.zig");
const heap = @import("runtime/heap.zig");
const Runtime = @import("runtime/runtime.zig").Runtime;
const Value = @import("lang/value.zig").Value;
const vm = @import("lang/vm.zig");

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

fn err(s: []const u8) void {
    writeAll(2, s);
}

fn resetAll() void {
    chunk.reset();
    globals.reset();
    vm.reset();
    heap.reset();
    vm.setPolicy(.{ .allow_io = false, .native_backend = .embedded });
}

fn expectError(name: []const u8, expected: anyerror, got: anyerror) !void {
    if (expected == got) return;
    err("vm-safety FAIL ");
    err(name);
    err(": expected ");
    err(@errorName(expected));
    err(", got ");
    err(@errorName(got));
    err("\n");
    return error.TestFailed;
}

fn runStackUnderflow() !void {
    resetAll();
    try chunk.emitOp(.pop, 1);
    try chunk.emitOp(.halt, 1);
    vm.run() catch |e| return expectError("stack-underflow", error.StackUnderflow, e);
    return error.TestFailed;
}

fn runBytecodeOutOfBounds() !void {
    resetAll();
    try chunk.emitOp(.constant, 1);
    vm.run() catch |e| return expectError("bytecode-oob", error.BytecodeOutOfBounds, e);
    return error.TestFailed;
}

fn runBadConstantIndex() !void {
    resetAll();
    // no constants added
    try chunk.emitOp(.constant, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitOp(.halt, 1);
    vm.run() catch |e| return expectError("bad-const-index", error.BadConstantIndex, e);
    return error.TestFailed;
}

fn runBadOpcode() !void {
    resetAll();
    // 255 is outside current Op enum range.
    try chunk.emitByte(255, 1);
    vm.run() catch |e| return expectError("bad-opcode", error.BadOpcode, e);
    return error.TestFailed;
}

fn runInstructionBudgetExceeded() !void {
    resetAll();
    vm.setPolicy(.{ .allow_io = false, .native_backend = .embedded, .max_ops = 1 });
    try chunk.emitOp(.null_val, 1);
    try chunk.emitOp(.halt, 1);
    vm.run() catch |e| return expectError("instruction-budget", error.InstructionBudgetExceeded, e);
    return error.TestFailed;
}

fn runRuntimeIsolation() !void {
    var rt1 = Runtime.init();
    rt1.setPolicy(.{ .allow_io = false, .native_backend = .embedded });
    try rt1.run(
        \\x := 11
        \\func read() { return x }
    );

    var rt2 = Runtime.init();
    rt2.setPolicy(.{ .allow_io = false, .native_backend = .embedded });
    try rt2.run(
        \\x := 99
        \\func read() { return x }
    );

    const v1 = try rt1.callGlobal("read", &[_]Value{});
    if (v1 != .number or v1.number != 11) return error.TestFailed;

    const v2 = try rt2.callGlobal("read", &[_]Value{});
    if (v2 != .number or v2.number != 99) return error.TestFailed;

    // Interleaved calls into both runtimes should preserve each runtime's
    // independent mutable state.
    try rt1.run(
        \\counter := 0
        \\func bump() {
        \\    counter += 1
        \\    return counter
        \\}
    );
    try rt2.run(
        \\counter := 100
        \\func bump() {
        \\    counter += 2
        \\    return counter
        \\}
    );
    const a1 = try rt1.callGlobal("bump", &[_]Value{});
    const b1 = try rt2.callGlobal("bump", &[_]Value{});
    const a2 = try rt1.callGlobal("bump", &[_]Value{});
    const b2 = try rt2.callGlobal("bump", &[_]Value{});
    if (a1 != .number or a1.number != 1) return error.TestFailed;
    if (b1 != .number or b1.number != 102) return error.TestFailed;
    if (a2 != .number or a2.number != 2) return error.TestFailed;
    if (b2 != .number or b2.number != 104) return error.TestFailed;
}

export fn _start() void {
    runStackUnderflow() catch {
        std.os.wasi.proc_exit(1);
    };
    runBytecodeOutOfBounds() catch {
        std.os.wasi.proc_exit(1);
    };
    runBadConstantIndex() catch {
        std.os.wasi.proc_exit(1);
    };
    runBadOpcode() catch {
        std.os.wasi.proc_exit(1);
    };
    runInstructionBudgetExceeded() catch {
        std.os.wasi.proc_exit(1);
    };
    runRuntimeIsolation() catch {
        std.os.wasi.proc_exit(1);
    };
    out("vm-safety OK\n");
    std.os.wasi.proc_exit(0);
}
