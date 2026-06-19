const std = @import("std");

const chunk = @import("lang/chunk.zig");
const globals = @import("lang/globals.zig");
const heap = @import("runtime/heap.zig");
const vm = @import("lang/vm.zig");
const vms = @import("lang/vm_state.zig");
const Op = @import("lang/op.zig").Op;
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
fn err(s: []const u8) void { writeAll(2, s); }

fn fail(msg: []const u8) noreturn {
    err("vm-value FAIL: ");
    err(msg);
    err("\n");
    std.os.wasi.proc_exit(1);
}

fn expect(cond: bool, msg: []const u8) void {
    if (!cond) fail(msg);
}

fn resetAll() void {
    chunk.reset();
    globals.reset();
    vm.reset();
    heap.reset();
    vm.setPolicy(.{ .allow_io = false, .native_backend = .embedded });
}

fn emitConstBytecode(idx: u16) !void {
    try chunk.emitByte(@intCast((idx >> 8) & 0xff), 1);
    try chunk.emitByte(@intCast(idx & 0xff), 1);
}

fn emitOffset4(off: u32) !void {
    try chunk.emitByte(@intCast((off >> 24) & 0xff), 1);
    try chunk.emitByte(@intCast((off >> 16) & 0xff), 1);
    try chunk.emitByte(@intCast((off >> 8)  & 0xff), 1);
    try chunk.emitByte(@intCast(off & 0xff), 1);
}

// ── Type values ───────────────────────────────────────────────────────────

fn testNullVal() void {
    resetAll();
    chunk.emitOp(.null_val, 1) catch fail("null_val emit");
    chunk.emitOp(.halt, 1) catch fail("null_val halt");
    vm.run() catch fail("null_val run");
    expect(vms.vmState().stack_top == 1, "null_val: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .null, "null_val: expected .null");
}

fn testTrueVal() void {
    resetAll();
    chunk.emitOp(.true_val, 1) catch fail("true_val emit");
    chunk.emitOp(.halt, 1) catch fail("true_val halt");
    vm.run() catch fail("true_val run");
    expect(vms.vmState().stack_top == 1, "true_val: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .boolean and vms.vmState().stack[0].boolean, "true_val: expected true");
}

fn testFalseVal() void {
    resetAll();
    chunk.emitOp(.false_val, 1) catch fail("false_val emit");
    chunk.emitOp(.halt, 1) catch fail("false_val halt");
    vm.run() catch fail("false_val run");
    expect(vms.vmState().stack_top == 1, "false_val: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .boolean and !vms.vmState().stack[0].boolean, "false_val: expected false");
}

// ── Constants ─────────────────────────────────────────────────────────────

fn testConstantInt() void {
    resetAll();
    chunk.emitConst(.{ .int = 42 }, 1) catch fail("constant int emit");
    chunk.emitOp(.halt, 1) catch fail("constant int halt");
    vm.run() catch fail("constant int run");
    expect(vms.vmState().stack_top == 1, "constant int: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 42, "constant int: expected 42");
}

fn testConstantFloat() void {
    resetAll();
    chunk.emitConst(.{ .float = 3.14 }, 1) catch fail("constant float emit");
    chunk.emitOp(.halt, 1) catch fail("constant float halt");
    vm.run() catch fail("constant float run");
    expect(vms.vmState().stack_top == 1, "constant float: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .float and vms.vmState().stack[0].float == 3.14, "constant float: expected 3.14");
}

fn testConstantString() void {
    resetAll();
    chunk.emitConst(.{ .string = "hello" }, 1) catch fail("constant string emit");
    chunk.emitOp(.halt, 1) catch fail("constant string halt");
    vm.run() catch fail("constant string run");
    expect(vms.vmState().stack_top == 1, "constant string: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .string, "constant string: expected .string");
}

fn testConstantRune() void {
    resetAll();
    chunk.emitConst(.{ .rune = 'A' }, 1) catch fail("constant rune emit");
    chunk.emitOp(.halt, 1) catch fail("constant rune halt");
    vm.run() catch fail("constant rune run");
    expect(vms.vmState().stack_top == 1, "constant rune: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .rune and vms.vmState().stack[0].rune == 'A', "constant rune: expected 'A'");
}

fn testConstantDecimal() void {
    resetAll();
    chunk.emitConst(.{ .decimal = 100 }, 1) catch fail("constant decimal emit");
    chunk.emitOp(.halt, 1) catch fail("constant decimal halt");
    vm.run() catch fail("constant decimal run");
    expect(vms.vmState().stack_top == 1, "constant decimal: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .decimal and vms.vmState().stack[0].decimal == 100, "constant decimal: expected 100");
}

// ── Arithmetic (int) ──────────────────────────────────────────────────────

fn testAddInt() void {
    resetAll();
    chunk.emitConst(.{ .int = 3 }, 1) catch fail("add int const 3");
    chunk.emitConst(.{ .int = 4 }, 1) catch fail("add int const 4");
    chunk.emitOp(.add, 1) catch fail("add int add");
    chunk.emitOp(.halt, 1) catch fail("add int halt");
    vm.run() catch fail("add int run");
    expect(vms.vmState().stack_top == 1, "add int: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 7, "add int: expected 7");
}

fn testSubInt() void {
    resetAll();
    chunk.emitConst(.{ .int = 10 }, 1) catch fail("sub int const 10");
    chunk.emitConst(.{ .int = 3 }, 1) catch fail("sub int const 3");
    chunk.emitOp(.sub, 1) catch fail("sub int sub");
    chunk.emitOp(.halt, 1) catch fail("sub int halt");
    vm.run() catch fail("sub int run");
    expect(vms.vmState().stack_top == 1, "sub int: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 7, "sub int: expected 7");
}

fn testMulInt() void {
    resetAll();
    chunk.emitConst(.{ .int = 3 }, 1) catch fail("mul int const 3");
    chunk.emitConst(.{ .int = 4 }, 1) catch fail("mul int const 4");
    chunk.emitOp(.mul, 1) catch fail("mul int mul");
    chunk.emitOp(.halt, 1) catch fail("mul int halt");
    vm.run() catch fail("mul int run");
    expect(vms.vmState().stack_top == 1, "mul int: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 12, "mul int: expected 12");
}

fn testDivInt() void {
    resetAll();
    chunk.emitConst(.{ .int = 10 }, 1) catch fail("div int const 10");
    chunk.emitConst(.{ .int = 2 }, 1) catch fail("div int const 2");
    chunk.emitOp(.div, 1) catch fail("div int div");
    chunk.emitOp(.halt, 1) catch fail("div int halt");
    vm.run() catch fail("div int run");
    expect(vms.vmState().stack_top == 1, "div int: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .float and vms.vmState().stack[0].float == 5.0, "div int: expected 5.0 float");
}

fn testModInt() void {
    resetAll();
    chunk.emitConst(.{ .int = 10 }, 1) catch fail("mod int const 10");
    chunk.emitConst(.{ .int = 3 }, 1) catch fail("mod int const 3");
    chunk.emitOp(.mod, 1) catch fail("mod int mod");
    chunk.emitOp(.halt, 1) catch fail("mod int halt");
    vm.run() catch fail("mod int run");
    expect(vms.vmState().stack_top == 1, "mod int: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 1, "mod int: expected 1");
}

// ── Arithmetic (float) ────────────────────────────────────────────────────

fn testAddFloat() void {
    resetAll();
    chunk.emitConst(.{ .float = 1.5 }, 1) catch fail("add float const 1.5");
    chunk.emitConst(.{ .float = 2.5 }, 1) catch fail("add float const 2.5");
    chunk.emitOp(.add, 1) catch fail("add float add");
    chunk.emitOp(.halt, 1) catch fail("add float halt");
    vm.run() catch fail("add float run");
    expect(vms.vmState().stack_top == 1, "add float: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .float and vms.vmState().stack[0].float == 4.0, "add float: expected 4.0");
}

fn testSubFloat() void {
    resetAll();
    chunk.emitConst(.{ .float = 5.0 }, 1) catch fail("sub float const 5.0");
    chunk.emitConst(.{ .float = 2.0 }, 1) catch fail("sub float const 2.0");
    chunk.emitOp(.sub, 1) catch fail("sub float sub");
    chunk.emitOp(.halt, 1) catch fail("sub float halt");
    vm.run() catch fail("sub float run");
    expect(vms.vmState().stack_top == 1, "sub float: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .float and vms.vmState().stack[0].float == 3.0, "sub float: expected 3.0");
}

// ── Unary ops ─────────────────────────────────────────────────────────────

fn testNegInt() void {
    resetAll();
    chunk.emitConst(.{ .int = 42 }, 1) catch fail("neg int const");
    chunk.emitOp(.neg, 1) catch fail("neg int neg");
    chunk.emitOp(.halt, 1) catch fail("neg int halt");
    vm.run() catch fail("neg int run");
    expect(vms.vmState().stack_top == 1, "neg int: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == -42, "neg int: expected -42");
}

fn testCastIntFromFloat() void {
    resetAll();
    chunk.emitConst(.{ .float = 3.9 }, 1) catch fail("cast int float const");
    chunk.emitOp(.cast_int, 1) catch fail("cast int op");
    chunk.emitOp(.halt, 1) catch fail("cast int halt");
    vm.run() catch fail("cast int run");
    expect(vms.vmState().stack_top == 1, "cast int: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 3, "cast int: expected 3");
}

fn testNotBool() void {
    resetAll();
    chunk.emitConst(.{ .boolean = true }, 1) catch fail("not bool const true");
    chunk.emitOp(.not, 1) catch fail("not bool not");
    chunk.emitOp(.halt, 1) catch fail("not bool halt");
    vm.run() catch fail("not bool run");
    expect(vms.vmState().stack_top == 1, "not bool: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .boolean and !vms.vmState().stack[0].boolean, "not bool: expected false");
}

// ── Fused const ops ───────────────────────────────────────────────────────

fn testConstEqTrue() void {
    resetAll();
    const push_idx = chunk.addConst(.{ .int = 5 }) catch fail("const_eq true addConst push");
    const eq_idx = chunk.addConst(.{ .int = 5 }) catch fail("const_eq true addConst eq");
    chunk.emitOp(.constant, 1) catch fail("const_eq true const");
    emitConstBytecode(push_idx) catch fail("const_eq true push idx");
    chunk.emitByte(@intFromEnum(Op.const_eq), 1) catch fail("const_eq true op");
    emitConstBytecode(eq_idx) catch fail("const_eq true eq idx");
    chunk.emitOp(.halt, 1) catch fail("const_eq true halt");
    vm.run() catch fail("const_eq true run");
    expect(vms.vmState().stack_top == 1, "const_eq true: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .boolean and vms.vmState().stack[0].boolean, "const_eq true: expected true");
}

fn testConstEqFalse() void {
    resetAll();
    const push_idx = chunk.addConst(.{ .int = 3 }) catch fail("const_eq false addConst push");
    const eq_idx = chunk.addConst(.{ .int = 5 }) catch fail("const_eq false addConst eq");
    chunk.emitOp(.constant, 1) catch fail("const_eq false const");
    emitConstBytecode(push_idx) catch fail("const_eq false push idx");
    chunk.emitByte(@intFromEnum(Op.const_eq), 1) catch fail("const_eq false op");
    emitConstBytecode(eq_idx) catch fail("const_eq false eq idx");
    chunk.emitOp(.halt, 1) catch fail("const_eq false halt");
    vm.run() catch fail("const_eq false run");
    expect(vms.vmState().stack_top == 1, "const_eq false: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .boolean and !vms.vmState().stack[0].boolean, "const_eq false: expected false");
}

fn testConstSub() void {
    resetAll();
    const push_idx = chunk.addConst(.{ .int = 10 }) catch fail("const_sub addConst push");
    const sub_idx = chunk.addConst(.{ .int = 3 }) catch fail("const_sub addConst sub");
    chunk.emitOp(.constant, 1) catch fail("const_sub const");
    emitConstBytecode(push_idx) catch fail("const_sub push idx");
    chunk.emitByte(@intFromEnum(Op.const_sub), 1) catch fail("const_sub op");
    emitConstBytecode(sub_idx) catch fail("const_sub sub idx");
    chunk.emitOp(.halt, 1) catch fail("const_sub halt");
    vm.run() catch fail("const_sub run");
    expect(vms.vmState().stack_top == 1, "const_sub: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 7, "const_sub: expected 7");
}

fn testConstAdd() void {
    resetAll();
    const push_idx = chunk.addConst(.{ .int = 5 }) catch fail("const_add addConst push");
    const add_idx = chunk.addConst(.{ .int = 3 }) catch fail("const_add addConst add");
    chunk.emitOp(.constant, 1) catch fail("const_add const");
    emitConstBytecode(push_idx) catch fail("const_add push idx");
    chunk.emitByte(@intFromEnum(Op.const_add), 1) catch fail("const_add op");
    emitConstBytecode(add_idx) catch fail("const_add add idx");
    chunk.emitOp(.halt, 1) catch fail("const_add halt");
    vm.run() catch fail("const_add run");
    expect(vms.vmState().stack_top == 1, "const_add: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 8, "const_add: expected 8");
}

// ── Stack discipline ──────────────────────────────────────────────────────

fn testDup() void {
    resetAll();
    chunk.emitConst(.{ .int = 42 }, 1) catch fail("dup const");
    chunk.emitOp(.dup, 1) catch fail("dup op");
    chunk.emitOp(.halt, 1) catch fail("dup halt");
    vm.run() catch fail("dup run");
    expect(vms.vmState().stack_top == 2, "dup: expected stack_top == 2");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 42, "dup: stack[0] == 42");
    expect(vms.vmState().stack[1] == .int and vms.vmState().stack[1].int == 42, "dup: stack[1] == 42");
}

fn testPop() void {
    resetAll();
    chunk.emitConst(.{ .int = 1 }, 1) catch fail("pop const 1");
    chunk.emitConst(.{ .int = 2 }, 1) catch fail("pop const 2");
    chunk.emitOp(.pop, 1) catch fail("pop op");
    chunk.emitOp(.halt, 1) catch fail("pop halt");
    vm.run() catch fail("pop run");
    expect(vms.vmState().stack_top == 1, "pop: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 1, "pop: expected stack[0] == 1");
}

fn testDup2() void {
    resetAll();
    chunk.emitConst(.{ .int = 1 }, 1) catch fail("dup2 const 1");
    chunk.emitConst(.{ .int = 2 }, 1) catch fail("dup2 const 2");
    chunk.emitOp(.dup2, 1) catch fail("dup2 op");
    chunk.emitOp(.halt, 1) catch fail("dup2 halt");
    vm.run() catch fail("dup2 run");
    expect(vms.vmState().stack_top == 4, "dup2: expected stack_top == 4");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 1, "dup2: stack[0] == 1");
    expect(vms.vmState().stack[1] == .int and vms.vmState().stack[1].int == 2, "dup2: stack[1] == 2");
    expect(vms.vmState().stack[2] == .int and vms.vmState().stack[2].int == 1, "dup2: stack[2] == 1");
    expect(vms.vmState().stack[3] == .int and vms.vmState().stack[3].int == 2, "dup2: stack[3] == 2");
}

// ── Conditional branch ────────────────────────────────────────────────────

fn testJifPopTaken() void {
    resetAll();
    const push_idx = chunk.addConst(.{ .int = 5 }) catch fail("jif taken addConst push");
    const eq_idx = chunk.addConst(.{ .int = 5 }) catch fail("jif taken addConst eq");
    chunk.emitOp(.constant, 1) catch fail("jif taken const");
    emitConstBytecode(push_idx) catch fail("jif taken push idx");
    chunk.emitByte(@intFromEnum(Op.const_eq), 1) catch fail("jif taken const_eq");
    emitConstBytecode(eq_idx) catch fail("jif taken eq idx");
    // jif_pop: condition is true (5 == 5), don't jump; 4-byte offset
    chunk.emitOp(.jif_pop, 1) catch fail("jif taken jif_pop");
    emitOffset4(3) catch fail("jif taken jmp offset");
    // fall through: push 99
    chunk.emitConst(.{ .int = 99 }, 1) catch fail("jif taken const 99");
    chunk.emitOp(.halt, 1) catch fail("jif taken halt");
    vm.run() catch fail("jif taken run");
    expect(vms.vmState().stack_top == 1, "jif taken: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 99, "jif taken: expected 99 (fall-through)");
}

fn testJifPopNotTaken() void {
    resetAll();
    const push_idx = chunk.addConst(.{ .int = 99 }) catch fail("jif not taken addConst push");
    const eq_idx = chunk.addConst(.{ .int = 5 }) catch fail("jif not taken addConst eq");
    chunk.emitOp(.constant, 1) catch fail("jif not taken const");
    emitConstBytecode(push_idx) catch fail("jif not taken push idx");
    chunk.emitByte(@intFromEnum(Op.const_eq), 1) catch fail("jif not taken const_eq");
    emitConstBytecode(eq_idx) catch fail("jif not taken eq idx");
    // jif_pop at pos 6: condition is false (99 != 5), should jump
    // ip after reading 4-byte offset = 11, target = pos 14 (constant 42)
    chunk.emitOp(.jif_pop, 1) catch fail("jif not taken jif_pop");
    emitOffset4(3) catch fail("jif not taken jmp offset");
    // [11] skipped — would push 99 if reached
    chunk.emitConst(.{ .int = 99 }, 1) catch fail("jif not taken skipped const");
    // [14] target — push 42
    chunk.emitConst(.{ .int = 42 }, 1) catch fail("jif not taken const 42");
    chunk.emitOp(.halt, 1) catch fail("jif not taken halt");
    vm.run() catch fail("jif not taken run");
    expect(vms.vmState().stack_top == 1, "jif not taken: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 42, "jif not taken: expected 42 (jumped)");
}

// ── Left shift ────────────────────────────────────────────────────────────

fn testShl() void {
    resetAll();
    chunk.emitConst(.{ .int = 1 }, 1) catch fail("shl const 1");
    chunk.emitConst(.{ .int = 10 }, 1) catch fail("shl const 10");
    chunk.emitOp(.shl, 1) catch fail("shl op");
    chunk.emitOp(.halt, 1) catch fail("shl halt");
    vm.run() catch fail("shl run");
    expect(vms.vmState().stack_top == 1, "shl: expected stack_top == 1");
    expect(vms.vmState().stack[0] == .int and vms.vmState().stack[0].int == 1024, "shl: expected 1024");
}

fn testShlOverflow() void {
    resetAll();
    // (maxInt(i64) >> 1) + 1 = 2^62 = 4611686018427387904, exactly representable as f64
    // Shifting left by 1 would produce 2^63 which overflows i64.
    chunk.emitConst(.{ .int = 4611686018427387904.0 }, 1) catch fail("shl overflow const val");
    chunk.emitConst(.{ .int = 1 }, 1) catch fail("shl overflow const 1");
    chunk.emitOp(.shl, 1) catch fail("shl overflow op");
    chunk.emitOp(.halt, 1) catch fail("shl overflow halt");
    vm.run() catch |e| {
        if (e == error.RangeError) return;
        fail("shl overflow: expected RangeError");
    };
    fail("shl overflow: expected error, got success");
}

// ── Arithmetic error paths ────────────────────────────────────────────────

fn testDivByZero() void {
    resetAll();
    chunk.emitConst(.{ .int = 5 }, 1) catch fail("div by zero const 5");
    chunk.emitConst(.{ .int = 0 }, 1) catch fail("div by zero const 0");
    chunk.emitOp(.div, 1) catch fail("div by zero div");
    chunk.emitOp(.halt, 1) catch fail("div by zero halt");
    vm.run() catch |e| {
        if (e == error.DivisionByZero) return;
        fail("div by zero: expected DivisionByZero");
    };
    fail("div by zero: expected error, got success");
}

fn testModByZero() void {
    resetAll();
    chunk.emitConst(.{ .int = 5 }, 1) catch fail("mod by zero const 5");
    chunk.emitConst(.{ .int = 0 }, 1) catch fail("mod by zero const 0");
    chunk.emitOp(.mod, 1) catch fail("mod by zero mod");
    chunk.emitOp(.halt, 1) catch fail("mod by zero halt");
    vm.run() catch |e| {
        if (e == error.DivisionByZero) return;
        fail("mod by zero: expected DivisionByZero");
    };
    fail("mod by zero: expected error, got success");
}

fn testAddOverflow() void {
    resetAll();
    chunk.emitConst(.{ .float = std.math.floatMax(f64) }, 1) catch fail("add overflow const max");
    chunk.emitConst(.{ .float = std.math.floatMax(f64) }, 1) catch fail("add overflow const max2");
    chunk.emitOp(.add, 1) catch fail("add overflow add");
    chunk.emitOp(.halt, 1) catch fail("add overflow halt");
    vm.run() catch |e| {
        if (e == error.TypeError) return;
        fail("add overflow: expected TypeError");
    };
    fail("add overflow: expected error, got success");
}

fn testMixedIntFloatError() void {
    resetAll();
    chunk.emitConst(.{ .int = 3 }, 1) catch fail("mixed int const");
    chunk.emitConst(.{ .float = 2.5 }, 1) catch fail("mixed float const");
    chunk.emitOp(.add, 1) catch fail("mixed add");
    chunk.emitOp(.halt, 1) catch fail("mixed halt");
    vm.run() catch |e| {
        if (e == error.TypeError) return;
        fail("mixed int+float: expected TypeError");
    };
    fail("mixed int+float: expected error, got success");
}

// ── Entry point ───────────────────────────────────────────────────────────

export fn _start() void {
    testNullVal();             out("  null_val: OK\n");
    testTrueVal();             out("  true_val: OK\n");
    testFalseVal();            out("  false_val: OK\n");
    testConstantInt();         out("  constant int: OK\n");
    testConstantFloat();       out("  constant float: OK\n");
    testConstantString();      out("  constant string: OK\n");
    testConstantRune();        out("  constant rune: OK\n");
    testConstantDecimal();     out("  constant decimal: OK\n");
    testAddInt();              out("  add int: OK\n");
    testSubInt();              out("  sub int: OK\n");
    testMulInt();              out("  mul int: OK\n");
    testDivInt();              out("  div int: OK\n");
    testModInt();              out("  mod int: OK\n");
    testAddFloat();            out("  add float: OK\n");
    testSubFloat();            out("  sub float: OK\n");
    testNegInt();              out("  neg int: OK\n");
    testCastIntFromFloat();    out("  cast int from float: OK\n");
    testNotBool();             out("  not bool: OK\n");
    testConstEqTrue();         out("  const_eq true: OK\n");
    testConstEqFalse();        out("  const_eq false: OK\n");
    testConstSub();            out("  const_sub: OK\n");
    testConstAdd();            out("  const_add: OK\n");
    testDup();                 out("  dup: OK\n");
    testPop();                 out("  pop: OK\n");
    testDup2();                out("  dup2: OK\n");
    testJifPopTaken();         out("  jif_pop taken: OK\n");
    testJifPopNotTaken();      out("  jif_pop not taken: OK\n");
    testShl();                 out("  shl: OK\n");
    testShlOverflow();         out("  shl overflow: OK\n");
    testDivByZero();           out("  div by zero: OK\n");
    testModByZero();           out("  mod by zero: OK\n");
    testAddOverflow();         out("  add overflow: OK\n");
    testMixedIntFloatError();  out("  mixed int+float: OK\n");
    out("vm-value OK\n");
    std.os.wasi.proc_exit(0);
}
