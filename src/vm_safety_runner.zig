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
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("stack-underflow", error.StackUnderflow, e);
    return error.TestFailed;
}

fn runBytecodeOutOfBounds() !void {
    resetAll();
    try chunk.emitOp(.constant, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("bytecode-oob", error.BytecodeOutOfBounds, e);
    return error.TestFailed;
}

fn runBadConstantIndex() !void {
    resetAll();
    // no constants added
    try chunk.emitOp(.constant, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("bad-const-index", error.BadConstantIndex, e);
    return error.TestFailed;
}

fn runBadOpcode() !void {
    resetAll();
    // 255 is outside current Op enum range.
    try chunk.emitByte(255, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("bad-opcode", error.BadOpcode, e);
    return error.TestFailed;
}

fn runInstructionBudgetExceeded() !void {
    resetAll();
    vm.setPolicy(.{ .allow_io = false, .native_backend = .embedded, .max_ops = 1 });
    try chunk.emitOp(.null_val, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("instruction-budget", error.InstructionBudgetExceeded, e);
    return error.TestFailed;
}

fn runSetNamedPredicateTypeError() !void {
    resetAll();
    const nt = heap.allocObject() orelse return error.OutOfMemory;
    nt.* = .{ .named_type = .{
        .name = "TestType",
        .qualified_name = "TestType",
        .base = .int,
    } };
    try chunk.emitConst(.{ .object = nt }, 1);
    try chunk.emitConst(.{ .int = 42 }, 1);
    try chunk.emitOp(.set_named_predicate, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("set-named-predicate-type-error", error.TypeError, e);
    return error.TestFailed;
}

fn runRuntimeIsolation() !void {
    const alloc = std.heap.page_allocator;
    const rt1 = try alloc.create(Runtime);
    try rt1.initWithPolicy(.{ .allow_io = false, .native_backend = .embedded });
    try rt1.run(
        \\x := 11
        \\func read() int { return x }
    );

    const rt2 = try alloc.create(Runtime);
    try rt2.initWithPolicy(.{ .allow_io = false, .native_backend = .embedded });
    try rt2.run(
        \\x := 99
        \\func read() int { return x }
    );

    const v1 = try rt1.callGlobal("read", &[_]Value{});
    if (v1 != .int or v1.int != 11) return error.TestFailed;

    const v2 = try rt2.callGlobal("read", &[_]Value{});
    if (v2 != .int or v2.int != 99) return error.TestFailed;

    // Interleaved calls into both runtimes should preserve each runtime's
    // independent mutable state.
    try rt1.run(
        \\counter := 0
        \\func bump() int {
        \\    counter += 1
        \\    return counter
        \\}
    );
    try rt2.run(
        \\counter := 100
        \\func bump() int {
        \\    counter += 2
        \\    return counter
        \\}
    );
    const a1 = try rt1.callGlobal("bump", &[_]Value{});
    const b1 = try rt2.callGlobal("bump", &[_]Value{});
    const a2 = try rt1.callGlobal("bump", &[_]Value{});
    const b2 = try rt2.callGlobal("bump", &[_]Value{});
    if (a1 != .int or a1.int != 1) return error.TestFailed;
    if (b1 != .int or b1.int != 102) return error.TestFailed;
    if (a2 != .int or a2.int != 2) return error.TestFailed;
    if (b2 != .int or b2.int != 104) return error.TestFailed;
}

fn runDupStackUnderflow() !void {
    resetAll();
    try chunk.emitOp(.dup, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("dup-stack-underflow", error.StackUnderflow, e);
    return error.TestFailed;
}

fn runDup2StackUnderflow() !void {
    resetAll();
    try chunk.emitOp(.dup2, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("dup2-stack-underflow", error.StackUnderflow, e);
    return error.TestFailed;
}

fn runDivByZero() !void {
    resetAll();
    try chunk.emitConst(.{ .float = 5.0 }, 1);
    try chunk.emitConst(.{ .float = 0.0 }, 1);
    try chunk.emitOp(.div, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("div-by-zero", error.DivisionByZero, e);
    return error.TestFailed;
}

fn runCallNumber() !void {
    resetAll();
    try chunk.emitConst(.{ .float = 42.0 }, 1);
    try chunk.emitOp(.call, 1);
    try chunk.emitByte(0, 1); // argc = 0
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("call-number", error.NotAFunction, e);
    return error.TestFailed;
}

fn runReturnAtTopLevel() !void {
    resetAll();
    try chunk.emitOp(.ret, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("return-toplevel", error.ReturnAtTopLevel, e);
    return error.TestFailed;
}

fn runRetConstAtTopLevel() !void {
    resetAll();
    try chunk.emitConst(.{ .int = 1 }, 1);
    try chunk.emitOp(.ret_const, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("ret-const-toplevel", error.ReturnAtTopLevel, e);
    return error.TestFailed;
}

fn runBadJumpTarget() !void {
    resetAll();
    try chunk.emitOp(.jump, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(0, 1);
    try chunk.emitByte(1, 1);
    try chunk.emitConst(.{ .int = 42 }, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("bad-jump-target", error.BadJumpTarget, e);
    return error.TestFailed;
}

fn runNegOnNonNumber() !void {
    resetAll();
    try chunk.emitConst(.{ .boolean = true }, 1);
    try chunk.emitOp(.neg, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("neg-non-number", error.TypeError, e);
    return error.TestFailed;
}

fn runAssertOnNonBoolean() !void {
    resetAll();
    try chunk.emitConst(.{ .float = 42.0 }, 1);
    try chunk.emitOp(.op_assert, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("assert-non-bool", error.TypeError, e);
    return error.TestFailed;
}

fn runAssertMsgOnNonBoolean() !void {
    resetAll();
    try chunk.emitStringConst("msg", 1);
    try chunk.emitConst(.{ .float = 42.0 }, 1);
    try chunk.emitOp(.op_assert_msg, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("assert-msg-non-bool", error.TypeError, e);
    return error.TestFailed;
}

fn runTrapCheckOnNonNull() !void {
    resetAll();
    try chunk.emitConst(.{ .float = 1.0 }, 1);
    try chunk.emitOp(.op_trap_check, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("trap-check-non-null", error.TrapFired, e);
    return error.TestFailed;
}

fn runVariantPayloadOnNonObject() !void {
    resetAll();
    try chunk.emitConst(.{ .float = 42.0 }, 1);
    try chunk.emitOp(.variant_payload, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("variant-payload-non-obj", error.TypeError, e);
    return error.TestFailed;
}

fn runAssertTypeInvalidTag() !void {
    resetAll();
    try chunk.emitConst(.{ .float = 1.0 }, 1);
    try chunk.emitOp(.assert_type, 1);
    try chunk.emitByte(99, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("assert-type-invalid-tag", error.TypeError, e);
    return error.TestFailed;
}

fn runSetNamedPredicateBadNtVal() !void {
    resetAll();
    // nt_val is a number (not an object), pred is null
    try chunk.emitConst(.{ .float = 99.0 }, 1);
    try chunk.emitOp(.null_val, 1);
    try chunk.emitOp(.set_named_predicate, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("set-named-predicate-bad-nt", error.TypeError, e);
    return error.TestFailed;
}

fn runDeferCallStackUnderflow() !void {
    resetAll();
    try chunk.emitOp(.defer_call, 1);
    try chunk.emitByte(1, 1); // argc = 1
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("defer-call-underflow", error.StackUnderflow, e);
    return error.TestFailed;
}

fn runModByZero() !void {
    resetAll();
    try chunk.emitConst(.{ .float = 5.0 }, 1);
    try chunk.emitConst(.{ .float = 0.0 }, 1);
    try chunk.emitOp(.mod, 1);
    try chunk.emitOp(.halt, 1);
    vm.run(vm.VMContext.fromActive()) catch |e| return expectError("mod-by-zero", error.DivisionByZero, e);
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
    runSetNamedPredicateTypeError() catch {
        std.os.wasi.proc_exit(1);
    };
    runRuntimeIsolation() catch {
        std.os.wasi.proc_exit(1);
    };
    runDupStackUnderflow() catch {
        std.os.wasi.proc_exit(1);
    };
    runDup2StackUnderflow() catch {
        std.os.wasi.proc_exit(1);
    };
    runDivByZero() catch {
        std.os.wasi.proc_exit(1);
    };
    runModByZero() catch {
        std.os.wasi.proc_exit(1);
    };
    runCallNumber() catch {
        std.os.wasi.proc_exit(1);
    };
    runReturnAtTopLevel() catch {
        std.os.wasi.proc_exit(1);
    };
    runRetConstAtTopLevel() catch {
        std.os.wasi.proc_exit(1);
    };
    runBadJumpTarget() catch {
        std.os.wasi.proc_exit(1);
    };
    runNegOnNonNumber() catch {
        std.os.wasi.proc_exit(1);
    };
    runAssertOnNonBoolean() catch {
        std.os.wasi.proc_exit(1);
    };
    runAssertMsgOnNonBoolean() catch {
        std.os.wasi.proc_exit(1);
    };
    runTrapCheckOnNonNull() catch {
        std.os.wasi.proc_exit(1);
    };
    runVariantPayloadOnNonObject() catch {
        std.os.wasi.proc_exit(1);
    };
    runAssertTypeInvalidTag() catch {
        std.os.wasi.proc_exit(1);
    };
    runSetNamedPredicateBadNtVal() catch {
        std.os.wasi.proc_exit(1);
    };
    runDeferCallStackUnderflow() catch {
        std.os.wasi.proc_exit(1);
    };
    out("vm-safety OK\n");
    std.os.wasi.proc_exit(0);
}
