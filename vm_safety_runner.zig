const std = @import("std");

const chunk = @import("lang/chunk.zig");
const globals = @import("lang/globals.zig");
const heap = @import("runtime/heap.zig");
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
    out("vm-safety OK\n");
    std.os.wasi.proc_exit(0);
}
