const std = @import("std");

const chunk = @import("lang/chunk.zig");
const globals = @import("lang/globals.zig");
const heap = @import("runtime/heap.zig");
const vm = @import("lang/vm.zig");
const Compiler = @import("lang/compiler.zig").Compiler;
const vms = @import("lang/vm_state.zig");
const vmnative = @import("lang/vm_native.zig");
const host_abi = @import("lang/native/host_abi.zig");
const vm_defuse = @import("lang/vm_defuse.zig");

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

// ── Simple PRNG ─────────────────────────────────────────────────────────────

var g_rng_state: u64 = 0;

fn rngSeed(s: u64) void { g_rng_state = s; }

fn rngU64() u64 {
    g_rng_state = g_rng_state *% 6364136223846793005 +% 1;
    return g_rng_state;
}

fn rngBool() bool { return (rngU64() & 1) == 1; }

fn rngRange(min: usize, max: usize) usize {
    if (min > max) return min;
    const span = max - min + 1;
    return min + @as(usize, @intCast(rngU64() % span));
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn resetAll() void {
    chunk.reset();
    globals.reset();
    vm.reset();
    heap.reset();
    vm.setPolicy(.{ .allow_io = false, .native_backend = .embedded });
}

// ── Compiler fuzz: random source strings must never crash ────────────────────

fn fuzzCompiler() void {
    const seeds = [_]u64{ 1, 42, 123, 999, 0xDEADBEEF, 0xCAFEBABE, 0x1337, 0x1234567890ABCDEF };
    const token_fragments = [_][]const u8{
        "x", "y", "foo", "bar", "123", "456.789", "true", "false", "null",
        "\"hello\"", "\"world\"", "func", "var", "const", "if", "else", "for",
        "in", "while", "return", "break", "continue", "defer", "panic", "recover",
        "type", "struct", "interface", "import", "map", "array", "int", "float",
        "bool", "string", "rune", "error", "decimal", "[]", "[", "]", "{", "}",
        "(", ")", ",", ";", ":", "=", "==", "!=", "<", ">", "+", "-", "*", "/", "%",
        "&", "|", "^", "~", "<<", ">>", "and", "or", "not", "+=", "-=", "*=", "/=",
        ":=", "=>", ".", "..", "range", "score", "name", "age", "Score", "Name", "Age",
        "\n", " ", "\t", "", "0", "-", "+", "\\", "\"", "'", "`", "#", "@", "$", "%",
    };

    var buf: [512]u8 = undefined;
    for (seeds) |seed| {
        rngSeed(seed);
        var trial: usize = 0;
        while (trial < 64) : (trial += 1) {
            var len: usize = 0;
            const count = rngRange(1, 20);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const frag = token_fragments[rngRange(0, token_fragments.len - 1)];
                const to_copy = @min(frag.len, buf.len - len);
                @memcpy(buf[len..][0..to_copy], frag[0..to_copy]);
                len += to_copy;
            }
            var compiler = Compiler.init(buf[0..len], .{});
            compiler.compile(true) catch {};
        }
    }
    out("  compiler fuzz: OK\n");
}

// ── VM fuzz: random bytecode sequences must never crash ─────────────────────

fn fuzzVmBytecode() void {
    const seeds = [_]u64{ 1, 42, 123, 999, 0xBEEF, 0xCAFE, 0x1337, 0xABCDEF };

    for (seeds) |seed| {
        rngSeed(seed);
        var trial: usize = 0;
        while (trial < 32) : (trial += 1) {
            resetAll();
            const count = rngRange(1, 64);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const op_byte = rngRange(0, 120);
                chunk.emitByte(@intCast(op_byte), 1) catch break;
                if (rngBool()) chunk.emitByte(@intCast(rngRange(0, 255)), 1) catch break;
                if (rngBool()) chunk.emitByte(@intCast(rngRange(0, 255)), 1) catch break;
            }
            chunk.emitByte(255, 1) catch {};
            vm.run() catch {};
        }
    }
    out("  vm bytecode fuzz: OK\n");
}

// ── VM arithmetic boundary fuzz ─────────────────────────────────────────────

fn fuzzVmArithmetic() void {
    const edge_values = [_]f64{
        0, 1, -1, 0.0, -0.0,
        std.math.inf(f64), -std.math.inf(f64),
        std.math.floatMax(f64), -std.math.floatMax(f64),
        std.math.floatMin(f64), -std.math.floatMin(f64),
        2.220446049250313e-16, 1e308, -1e308, 1e-308, -1e-308,
        std.math.nan(f64),
    };

    var trial: usize = 0;
    while (trial < edge_values.len * edge_values.len * 3) : (trial += 1) {
        const a = edge_values[trial % edge_values.len];
        const b = edge_values[(trial / edge_values.len) % edge_values.len];
        const op = trial % 3;

        resetAll();
        chunk.emitConst(.{ .float = a }, 1) catch { continue; };
        chunk.emitConst(.{ .float = b }, 1) catch { continue; };
        const op_code: @import("lang/op.zig").Op = switch (op) {
            0 => .add,
            1 => .sub,
            2 => .div,
            else => unreachable,
        };
        chunk.emitOp(op_code, 1) catch { continue; };
        chunk.emitOp(.halt, 1) catch { continue; };
        vm.run() catch {};
    }
    out("  vm arithmetic boundary fuzz: OK\n");
}

// ── ValueWire fuzz: serialization round-trip ────────────────────────────────

fn fuzzValueWire() void {
    const test_values = [_]@import("lang/value.zig").Value{
        .null,
        .{ .boolean = true },
        .{ .boolean = false },
        .{ .int = 0 },
        .{ .int = 42 },
        .{ .int = -1 },
        .{ .float = 3.14 },
        .{ .float = std.math.inf(f64) },
        .{ .float = -std.math.inf(f64) },
        .{ .float = std.math.nan(f64) },
        .{ .string = "" },
        .{ .string = "hello" },
        .{ .string = "hello\nworld\t" },
        .{ .rune = 0 },
        .{ .rune = 65 },
        .{ .rune = 0x10FFFF },
        .{ .decimal = 0 },
        .{ .decimal = 1000000 },
        .{ .decimal = -1000000 },
        .{ .error_value = "test" },
        .{ .error_value = "" },
        .{ .error_value = "something went wrong" },
    };

    for (test_values) |v| {
        const wire = host_abi.wireFromValue(v) catch {
            fail("fuzz FAIL: wireFromValue failed\n");
        };
        const round = host_abi.valueFromWire(wire) catch {
            fail("fuzz FAIL: valueFromWire failed\n");
        };
        // Check tag matches for non-string values
        switch (v) {
            .null => if (round != .null) fail("fuzz FAIL: null round-trip\n"),
            .boolean => if (round != .boolean or round.boolean != v.boolean) fail("fuzz FAIL: bool round-trip\n"),
            .int => if (round != .int or round.int != v.int) fail("fuzz FAIL: int round-trip\n"),
            .float => if (round != .float or (!std.math.isNan(v.float) and round.float != v.float)) fail("fuzz FAIL: float round-trip\n"),
            .decimal => if (round != .decimal or round.decimal != v.decimal) fail("fuzz FAIL: decimal round-trip\n"),
            .rune => if (round != .rune or round.rune != v.rune) fail("fuzz FAIL: rune round-trip\n"),
            .error_value => if (round != .error_value or !std.mem.eql(u8, round.error_value, v.error_value)) fail("fuzz FAIL: error round-trip\n"),
            else => {},
        }
    }
    out("  value-wire fuzz: OK\n");
}

// ── Named type boundary fuzz ─────────────────────────────────────────────────

fn fuzzNamedTypeBoundaries() void {
    // Test named type construction with edge values via compiler
    const test_cases = [_]struct { base: []const u8, val: []const u8 }{
        .{ .base = "int", .val = "0" },
        .{ .base = "int", .val = "42" },
        .{ .base = "int", .val = "-1" },
        .{ .base = "int", .val = "10000000000" },
        .{ .base = "int", .val = "-10000000000" },
        .{ .base = "float", .val = "0.0" },
        .{ .base = "float", .val = "3.14" },
        .{ .base = "float", .val = "1e308" },
        .{ .base = "float", .val = "-1e308" },
        .{ .base = "float", .val = "1e-308" },
    };

    for (test_cases) |tc| {
        var src_buf: [256]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "std.core.{s}({s})\n", .{ tc.base, tc.val }) catch continue;
        var compiler = Compiler.init(src, .{});
        compiler.compile(true) catch {};
        chunk.emitOp(.halt, 1) catch continue;
        vm.run() catch {};
    }
    out("  named type boundary fuzz: OK\n");
}

// ── For-in/C-for nesting fuzz ───────────────────────────────────────────────
// Generates random top-level and function-scoped for-in / C-for nestings
// and runs them through compile + execute to catch stack-collision bugs.

fn fuzzForInNesting() void {
    const seeds = [_]u64{ 1, 42, 123, 999, 0xBEEF, 0xCAFE, 0x1337, 0xABCDEF };
    for (seeds) |seed| {
        rngSeed(seed);
        var trial: usize = 0;
        while (trial < 32) : (trial += 1) {
            resetAll();
            const depth = rngRange(1, 4);
            var buf: [2048]u8 = undefined;
            var pos: usize = 0;

            const preamble = "var data = [1, 2, 3]\n";
            @memcpy(buf[pos..][0..preamble.len], preamble);
            pos += preamble.len;

            var d: usize = 0;
            while (d < depth) : (d += 1) {
                if (pos + 64 > buf.len) break;
                const use_forin = rngBool();
                const dc = @as(u8, @intCast('0' + d % 10));
                if (use_forin) {
                    @memcpy(buf[pos..][0..5], "for x");
                    pos += 5;
                    buf[pos] = dc;
                    pos += 1;
                    @memcpy(buf[pos..][0..10], " in data {");
                    pos += 10;
                } else {
                    @memcpy(buf[pos..][0..5], "for i");
                    pos += 5;
                    buf[pos] = dc;
                    pos += 1;
                    @memcpy(buf[pos..][0..8], " := 0; i");
                    pos += 8;
                    buf[pos] = dc;
                    pos += 1;
                    @memcpy(buf[pos..][0..7], " < 3; i");
                    pos += 7;
                    buf[pos] = dc;
                    pos += 1;
                    @memcpy(buf[pos..][0..4], "++ {");
                    pos += 4;
                }
                buf[pos] = '\n';
                pos += 1;
            }

            const body = "print(1)\n";
            @memcpy(buf[pos..][0..body.len], body);
            pos += body.len;

            d = 0;
            while (d < depth) : (d += 1) {
                if (pos + 2 > buf.len) break;
                buf[pos] = '}';
                pos += 1;
                buf[pos] = '\n';
                pos += 1;
            }

            var compiler = Compiler.init(buf[0..pos], .{});
            compiler.compile(true) catch { continue; };
            chunk.emitOp(.halt, 1) catch continue;
            vm.run() catch { continue; };
        }
    }
    out("  for-in/C-for nesting fuzz: OK\n");
}

// ── Stack/heap boundary fuzz ─────────────────────────────────────────────────

fn fuzzStackHeapBoundaries() void {
    // Test deep recursion near stack limit
    resetAll();
    var compiler = Compiler.init(
        \\func deep(n int) int {
        \\    if n <= 0 { return 0 }
        \\    return deep(n - 1) + 1
        \\}
        \\deep(100)
    , .{});
    compiler.compile(true) catch {};
    chunk.emitOp(.halt, 1) catch {};
    vm.run() catch {};

    // Test large array allocation
    resetAll();
    var compiler2 = Compiler.init(
        \\var arr = [1000]int
        \\for i := 0; i < 1000; i++ {
        \\    arr[i] = i
        \\}
    , .{});
    compiler2.compile(true) catch {};
    chunk.emitOp(.halt, 1) catch {};
    vm.run() catch {};
    out("  stack/heap boundary fuzz: OK\n");
}

// ── Differential: defused vs fused execution must agree ─────────────────────

const OutcomeTag = enum { ok, type_error, range_error, not_defined, predicate_error, other };

fn classifyErr(e: anyerror) OutcomeTag {
    return switch (e) {
        error.TypeError        => .type_error,
        error.RangeError       => .range_error,
        error.NotDefined       => .not_defined,
        error.PredicateError   => .predicate_error,
        else                   => .other,
    };
}

fn runNormal(src: []const u8) OutcomeTag {
    resetAll();
    var c = Compiler.init(src, .{});
    c.compile(true) catch return .other;
    chunk.emitOp(.halt, 1) catch return .other;
    vm.run() catch |e| return classifyErr(e);
    return .ok;
}

fn runDefused(src: []const u8) OutcomeTag {
    resetAll();
    var c = Compiler.init(src, .{});
    c.compile(true) catch return .other;
    chunk.emitOp(.halt, 1) catch return .other;

    const alloc = std.heap.page_allocator;
    const defused = vm_defuse.buildDefusedCode(alloc) catch return .other;
    defer alloc.free(defused);

    @memcpy(chunk.g_state.code[0..defused.len], defused);
    chunk.g_state.code_len = defused.len;

    vm.run() catch |e| return classifyErr(e);
    return .ok;
}

fn fuzzDifferential() void {
    const programs = [_][]const u8{
        // C-for loop: exercises get_local_const_lt_jif_pop, local_add_const, set_global_loop
        \\var s = 0
        \\for i := 0; i < 10; i++ {
        \\    s = s + i
        \\}
        ,
        // Recursion: exercises get_local_ret, add_ret, get_local_const_sub, const_lt
        \\func fib(n int) int {
        \\    if n < 2 { return n }
        \\    return fib(n - 1) + fib(n - 2)
        \\}
        \\fib(8)
        ,
        // Named type range: exercises RangeError path
        \\type Score int range 0..100
        \\Score(50)
        ,
        // Field access: exercises get_local_get_field, invoke_method IC
        \\var m = {"a": 1, "b": 2}
        \\m["a"]
        ,
        // Struct fields: exercises get_field / set_field IC
        \\struct Point { x int, y int }
        \\var p = Point{x: 3, y: 4}
        \\p.x + p.y
        ,
        // Named type arithmetic via subtype: exercises namedTypeCommonAncestor
        \\type Pct int range 0..100
        \\subtype Hi Pct range 60..100
        \\subtype Lo Pct range 0..59
        \\var a = Hi(70)
        \\var b = Lo(30)
        \\Pct(int(a) + int(b))
        ,
        // For-in: exercises iter_next2, break stack discipline
        \\var arr = [1, 2, 3, 4, 5]
        \\var total = 0
        \\for v in arr {
        \\    total = total + v
        \\}
        ,
        // Global variable with loop counter: exercises set_global_loop
        \\var count = 0
        \\for count = 0; count < 5; count++ {
        \\}
        ,
        // Closure: exercises make_closure, get_upvalue, set_upvalue
        \\func counter() func() int {
        \\    var n = 0
        \\    return func() int {
        \\        n = n + 1
        \\        return n
        \\    }
        \\}
        \\var c = counter()
        \\c()
        \\c()
        ,
    };

    for (programs) |src| {
        const norm = runNormal(src);
        const defu = runDefused(src);
        if (norm != defu) {
            fail("differential FAIL: fused and defused outcomes diverge\n");
        }
    }
    out("  differential fuzz: OK\n");
}

// ── Main ────────────────────────────────────────────────────────────────────

export fn _start() void {
    fuzzCompiler();
    fuzzVmBytecode();
    fuzzVmArithmetic();
    fuzzValueWire();
    fuzzNamedTypeBoundaries();
    fuzzForInNesting();
    fuzzStackHeapBoundaries();
    fuzzDifferential();
    out("fuzz OK\n");
    std.os.wasi.proc_exit(0);
}
