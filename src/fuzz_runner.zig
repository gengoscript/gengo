const std = @import("std");

const chunk = @import("lang/chunk.zig");
const globals = @import("lang/globals.zig");
const heap = @import("runtime/heap.zig");
const vm = @import("lang/vm.zig");
const Compiler = @import("lang/compiler.zig").Compiler;
const CompilerOptions = @import("lang/compiler.zig").CompilerOptions;
const vms = @import("lang/vm_state.zig");
const vmnative = @import("lang/vm_native.zig");
const host_abi = @import("lang/native/host_abi.zig");
const vm_defuse = @import("lang/vm_defuse.zig");
const vmod = @import("lang/value.zig");
const staticSS = vmod.staticSS;
const module_compile = @import("lang/module_compile.zig");
const op_mod = @import("lang/op.zig");

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
            vm.run(vm.VMContext.fromActive()) catch {};
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
        vm.run(vm.VMContext.fromActive()) catch {};
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
        .{ .string = staticSS("") },
        .{ .string = staticSS("hello") },
        .{ .string = staticSS("hello\nworld\t") },
        .{ .rune = 0 },
        .{ .rune = 65 },
        .{ .rune = 0x10FFFF },
        .{ .decimal = 0 },
        .{ .decimal = 1000000 },
        .{ .decimal = -1000000 },
        .{ .error_value = staticSS("test") },
        .{ .error_value = staticSS("") },
        .{ .error_value = staticSS("something went wrong") },
    };

    for (test_values) |v| {
        const wire = host_abi.wireFromValue(vm.VMContext.fromActive(), v) catch {
            fail("fuzz FAIL: wireFromValue failed\n");
        };
        const round = host_abi.valueFromWire(vm.VMContext.fromActive(), wire) catch {
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
            .error_value => if (round != .error_value or !std.mem.eql(u8, round.error_value.bytes, v.error_value.bytes)) fail("fuzz FAIL: error round-trip\n"),
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
        vm.run(vm.VMContext.fromActive()) catch {};
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
            vm.run(vm.VMContext.fromActive()) catch { continue; };
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
    vm.run(vm.VMContext.fromActive()) catch {};

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
    vm.run(vm.VMContext.fromActive()) catch {};
    out("  stack/heap boundary fuzz: OK\n");
}

// ── Valid adversarial bytecode: stack-balanced, jump-free sequences ──────────
// These are valid-by-construction: N null_val pushes + (N-1) eq folds + halt.
// Tests the VM dispatcher at unusual stack depths without invalid-bytecode noise.

fn fuzzValidAdversarialBytecode() void {
    const depths = [_]usize{ 1, 2, 3, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 511 };
    const null_byte = @intFromEnum(op_mod.Op.null_val);
    const true_byte = @intFromEnum(op_mod.Op.true_val);
    const eq_byte   = @intFromEnum(op_mod.Op.eq);
    const halt_byte = @intFromEnum(op_mod.Op.halt);

    for (depths) |depth| {
        // null_val * depth, eq * (depth-1), halt — stack ends at depth 1
        resetAll();
        var i: usize = 0;
        while (i < depth) : (i += 1) chunk.emitByte(null_byte, 1) catch break;
        i = 0;
        while (i < depth - 1) : (i += 1) chunk.emitByte(eq_byte, 1) catch break;
        chunk.emitByte(halt_byte, 1) catch {};
        vm.run(vm.VMContext.fromActive()) catch {};

        // Same but with true_val pushes — exercises the bool fast-path in eq
        resetAll();
        i = 0;
        while (i < depth) : (i += 1) chunk.emitByte(true_byte, 1) catch break;
        i = 0;
        while (i < depth - 1) : (i += 1) chunk.emitByte(eq_byte, 1) catch break;
        chunk.emitByte(halt_byte, 1) catch {};
        vm.run(vm.VMContext.fromActive()) catch {};
    }
    out("  valid adversarial bytecode: OK\n");
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
    vm.run(vm.VMContext.fromActive()) catch |e| return classifyErr(e);
    return .ok;
}

fn runDefused(src: []const u8) OutcomeTag {
    resetAll();
    var c = Compiler.init(src, .{});
    c.compile(true) catch return .other;
    chunk.emitOp(.halt, 1) catch return .other;

    const alloc = std.heap.page_allocator;
    const defused = vm_defuse.buildDefusedCode(vm.VMContext.fromActive().cs, alloc) catch return .other;
    defer alloc.free(defused);

    @memcpy(chunk.g_state.code[0..defused.len], defused);
    chunk.g_state.code_len = defused.len;

    vm.run(vm.VMContext.fromActive()) catch |e| return classifyErr(e);
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

// ── Helper: compile+run a gengo program; exit if the program panics ──────────

fn propStdResolver(_: *anyopaque, _: []const u8, import_name: []const u8) anyerror![]const u8 {
    if (std.mem.eql(u8, import_name, "std")) return module_compile.StdModuleGlobalName;
    return error.ModuleNotFound;
}

var _prop_ctx: u8 = 0;

fn runAssert(src: []const u8, label: []const u8) void {
    resetAll();
    vmnative.installStdGlobal(vm.VMContext.fromActive(), globals.activeState()) catch {};
    var c = Compiler.init(src, .{
        .module_ctx = &_prop_ctx,
        .resolve_import = propStdResolver,
    });
    c.compile(true) catch {
        out("property FAIL (compile): ");
        out(label);
        out("\n");
        std.os.wasi.proc_exit(1);
    };
    chunk.emitOp(.halt, 1) catch {};
    vm.run(vm.VMContext.fromActive()) catch |e| {
        if (e == error.PanicError) {
            out("property FAIL (panic): ");
            out(label);
            out("\n");
            std.os.wasi.proc_exit(1);
        }
        // Other errors (OOM, etc.) are not property failures.
    };
}

// Like runAssert but tolerates panics and runtime errors — used for adversarial
// patterns where the outcome is undefined or deliberately exceptional.
fn runTolerant(src: []const u8) void {
    resetAll();
    vmnative.installStdGlobal(vm.VMContext.fromActive(), globals.activeState()) catch {};
    var c = Compiler.init(src, .{
        .module_ctx = &_prop_ctx,
        .resolve_import = propStdResolver,
    });
    c.compile(true) catch { return; };
    chunk.emitOp(.halt, 1) catch {};
    vm.run(vm.VMContext.fromActive()) catch {};
}

// ── Property: clone(x) deep-equals x for all representable value types ───────

fn propCloneDeepEquals() void {
    const cases = [_][]const u8{
        // Scalar values
        \\std := import("std")
        \\core := std.core
        \\assert core.deep_equal(core.clone(42), 42), "int"
        \\assert core.deep_equal(core.clone(3.14), 3.14), "float"
        \\assert core.deep_equal(core.clone(true), true), "bool"
        \\assert core.deep_equal(core.clone(null), null), "null"
        \\assert core.deep_equal(core.clone("hello"), "hello"), "string"
        ,
        // Flat array
        \\std := import("std")
        \\core := std.core
        \\v := [1, 2, 3, 4, 5]
        \\assert core.deep_equal(core.clone(v), v), "flat array"
        ,
        // Nested array
        \\std := import("std")
        \\core := std.core
        \\v := [[1, 2], [3, 4], [5, 6]]
        \\assert core.deep_equal(core.clone(v), v), "nested array"
        ,
        // Small map (linear representation, <=8 entries)
        \\std := import("std")
        \\core := std.core
        \\v := {"a": 1, "b": 2, "c": 3}
        \\assert core.deep_equal(core.clone(v), v), "small map"
        ,
        // Large map (hashed representation, >8 entries)
        \\std := import("std")
        \\core := std.core
        \\v := {"k1": 1, "k2": 2, "k3": 3, "k4": 4, "k5": 5, "k6": 6, "k7": 7, "k8": 8, "k9": 9, "k10": 10}
        \\assert core.deep_equal(core.clone(v), v), "large map"
        ,
        // Clone independence: mutating clone does not affect original
        \\std := import("std")
        \\core := std.core
        \\original := [1, 2, 3]
        \\cloned := core.clone(original)
        \\cloned[0] = 99
        \\assert original[0] == 1, "clone independence"
        ,
    };

    for (cases) |src| {
        runAssert(src, "clone deep-equals");
    }
    out("  clone deep-equals: OK\n");
}

// ── Property: map promotion does not change lookup or membership semantics ────

fn propMapPromotion() void {
    const cases = [_][]const u8{
        // After promotion (9th entry) lookups of all prior keys still work
        \\std := import("std")
        \\core := std.core
        \\m := {}
        \\m["k1"] = 10
        \\m["k2"] = 20
        \\m["k3"] = 30
        \\m["k4"] = 40
        \\m["k5"] = 50
        \\m["k6"] = 60
        \\m["k7"] = 70
        \\m["k8"] = 80
        \\m["k9"] = 90
        \\assert m["k1"] == 10, "k1 after promote"
        \\assert m["k5"] == 50, "k5 after promote"
        \\assert m["k9"] == 90, "k9 after promote"
        ,
        // has() works after promotion
        \\std := import("std")
        \\core := std.core
        \\m := {}
        \\for i := 0; i < 10; i++ { m[i] = i * 10 }
        \\for i := 0; i < 10; i++ { assert core.has(m, i), "has after promote" }
        \\assert not core.has(m, 11), "has false positive"
        ,
        // Overwrite after promotion preserves the new value
        \\std := import("std")
        \\core := std.core
        \\m := {}
        \\for i := 0; i < 10; i++ { m[i] = i }
        \\m[5] = 999
        \\assert m[5] == 999, "overwrite after promote"
        ,
        // for-in over promoted map yields all entries exactly once
        \\std := import("std")
        \\core := std.core
        \\m := {}
        \\for i := 0; i < 10; i++ { m[i] = true }
        \\count := 0
        \\for k in m { count = count + 1 }
        \\assert count == 10, "for-in count after promote"
        ,
        // delete() works after promotion
        \\std := import("std")
        \\core := std.core
        \\m := {}
        \\for i := 0; i < 10; i++ { m[i] = i }
        \\core.delete(m, 5)
        \\assert not core.has(m, 5), "delete after promote"
        \\assert core.len(m) == 9, "len after delete+promote"
        ,
    };

    for (cases) |src| {
        runAssert(src, "map promotion");
    }
    out("  map promotion semantics: OK\n");
}

// ── Property: panic/defer/recover ordering is stable ────────────────────────

fn propPanicDeferRecover() void {
    const cases = [_][]const u8{
        // defer runs after normal return
        \\std := import("std")
        \\core := std.core
        \\ran := false
        \\func f() {
        \\    defer func() { ran = true }()
        \\    return
        \\}
        \\f()
        \\assert ran, "defer after return"
        ,
        // defer runs when panic occurs (recover absorbs the panic)
        \\std := import("std")
        \\core := std.core
        \\ran := false
        \\func f() {
        \\    defer func() {
        \\        e := core.recover()
        \\        if core.is_error(e) { ran = true }
        \\    }()
        \\    _ = [][0]
        \\}
        \\f()
        \\assert ran, "defer on panic"
        ,
        // recover() sees an error value on panic
        \\std := import("std")
        \\core := std.core
        \\got_error := false
        \\func f() {
        \\    defer func() {
        \\        e := core.recover()
        \\        if core.is_error(e) { got_error = true }
        \\    }()
        \\    _ = [][0]
        \\}
        \\f()
        \\assert got_error, "recover must see error"
        ,
        // Multiple defers run in LIFO order (encoded as digits: last-registered runs first)
        \\std := import("std")
        \\core := std.core
        \\order := 0
        \\func f() {
        \\    defer func() { order = order * 10 + 1 }()
        \\    defer func() { order = order * 10 + 2 }()
        \\    defer func() { order = order * 10 + 3 }()
        \\}
        \\f()
        \\assert order == 321, "LIFO order"
        ,
        // Nested recover: inner panic is caught in inner function, does not reach outer
        \\std := import("std")
        \\core := std.core
        \\inner_caught := false
        \\func inner() {
        \\    defer func() {
        \\        e := core.recover()
        \\        if core.is_error(e) { inner_caught = true }
        \\    }()
        \\    _ = [][0]
        \\}
        \\func outer() { inner() }
        \\outer()
        \\assert inner_caught, "nested: inner panic caught"
        ,
    };

    for (cases) |src| {
        runAssert(src, "panic/defer/recover");
    }
    out("  panic/defer/recover ordering: OK\n");
}

// ── Property: GC invariance — same result with and without forced GC ──────────
// This runs programs known to allocate heap objects and verifies they don't
// crash. Full GC invariance is enforced by the gc-stress CI lane; this suite
// focuses on programs that exercise the allocator boundary conditions.

fn propGcInvariance() void {
    const programs = [_][]const u8{
        // String growth
        \\std := import("std")
        \\core := std.core
        \\s := ""
        \\for i := 0; i < 50; i++ { s = s + "x" }
        \\assert core.len(s) == 50, "string concat len"
        ,
        // Array growth via append
        \\std := import("std")
        \\core := std.core
        \\arr := []
        \\for i := 0; i < 50; i++ { arr = core.append(arr, i) }
        \\assert core.len(arr) == 50, "array grow len"
        \\assert arr[49] == 49, "array grow last"
        ,
        // Map growth past promotion, then sum all values
        \\std := import("std")
        \\core := std.core
        \\m := {}
        \\for i := 0; i < 20; i++ { m[i] = i * i }
        \\total := 0
        \\for k in m { total = total + m[k] }
        \\assert total == 2470, "map sum"
        ,
        // Clone of array-of-maps
        \\std := import("std")
        \\core := std.core
        \\arr := []
        \\for i := 0; i < 20; i++ { arr = core.append(arr, {"k": i, "v": i * 2}) }
        \\arr2 := core.clone(arr)
        \\assert core.len(arr2) == 20, "clone len"
        \\assert core.deep_equal(arr, arr2), "clone eq"
        ,
    };

    for (programs) |src| {
        runAssert(src, "gc invariance");
    }
    out("  gc invariance: OK\n");
}

// ── Property: objects reachable via multiple paths survive GC correctly ───────

fn propSharedReferences() void {
    const cases = [_][]const u8{
        // Two containers pointing to the same map value
        \\std := import("std")
        \\core := std.core
        \\shared := {"val": 42}
        \\a := {"ref": shared}
        \\b := {"ref": shared}
        \\ref_a := a["ref"]
        \\ref_b := b["ref"]
        \\assert ref_a["val"] == 42, "shared ref via a"
        \\assert ref_b["val"] == 42, "shared ref via b"
        ,
        // Diamond graph: two inner nodes share the same leaf array
        \\std := import("std")
        \\core := std.core
        \\leaf := [1, 2, 3]
        \\inner1 := {"data": leaf}
        \\inner2 := {"data": leaf}
        \\d1 := inner1["data"]
        \\d2 := inner2["data"]
        \\assert d1[0] == 1, "diamond left"
        \\assert d2[0] == 1, "diamond right"
        ,
        // Same array stored under multiple map keys; force allocations to trigger GC
        \\std := import("std")
        \\core := std.core
        \\shared := []
        \\for i := 0; i < 10; i++ { shared = core.append(shared, i) }
        \\m := {"a": shared, "b": shared, "c": shared}
        \\assert core.len(m["a"]) == 10, "shared len a"
        \\assert core.len(m["b"]) == 10, "shared len b"
        \\assert core.deep_equal(m["a"], m["b"]), "shared deep equal"
        ,
        // Clone of structure with shared sub-values: paths are independent after clone
        \\std := import("std")
        \\core := std.core
        \\inner := {"x": 1}
        \\outer := {"p": inner, "q": inner}
        \\cloned := core.clone(outer)
        \\cp := cloned["p"]
        \\cq := cloned["q"]
        \\assert cp["x"] == 1, "clone p"
        \\assert cq["x"] == 1, "clone q"
        ,
        // Wide fan-out: one root referenced from 10 container slots, GC pressure
        \\std := import("std")
        \\core := std.core
        \\root := {"marker": 99}
        \\arr := []
        \\for i := 0; i < 10; i++ { arr = core.append(arr, root) }
        \\for i := 0; i < 10; i++ {
        \\    slot := arr[i]
        \\    assert slot["marker"] == 99, "fan-out slot"
        \\}
        ,
    };

    for (cases) |src| {
        runAssert(src, "shared references");
    }
    out("  shared references: OK\n");
}

// ── Property: extended panic/defer/recover interaction patterns ───────────────

fn propPanicRecoverExtended() void {
    const cases = [_][]const u8{
        // recover() called outside any panic must return null
        \\std := import("std")
        \\core := std.core
        \\v := core.recover()
        \\assert v == null, "recover outside panic is null"
        ,
        // re-panic: handler panics after recovering, outer handler catches it
        \\std := import("std")
        \\core := std.core
        \\outer_caught := false
        \\func inner() {
        \\    defer func() {
        \\        e := core.recover()
        \\        if core.is_error(e) { panic("re-panic") }
        \\    }()
        \\    panic("original")
        \\}
        \\func outer() {
        \\    defer func() {
        \\        e := core.recover()
        \\        if core.is_error(e) { outer_caught = true }
        \\    }()
        \\    inner()
        \\}
        \\outer()
        \\assert outer_caught, "re-panic caught by outer"
        ,
        // Multiple sequential panics, each absorbed by its own frame
        \\std := import("std")
        \\core := std.core
        \\count := 0
        \\func safe_panic() {
        \\    defer func() {
        \\        e := core.recover()
        \\        if core.is_error(e) { count = count + 1 }
        \\    }()
        \\    _ = [][0]
        \\}
        \\safe_panic()
        \\safe_panic()
        \\safe_panic()
        \\assert count == 3, "multiple sequential panics"
        ,
        // Panic at call depth 4, recovered at depth 1 (all intermediate frames unwind)
        \\std := import("std")
        \\core := std.core
        \\unwound := false
        \\func d4() { _ = [][0] }
        \\func d3() { d4() }
        \\func d2() { d3() }
        \\func d1() {
        \\    defer func() {
        \\        e := core.recover()
        \\        if core.is_error(e) { unwound = true }
        \\    }()
        \\    d2()
        \\}
        \\d1()
        \\assert unwound, "deep unwind to recover"
        ,
        // recover() inside a non-deferred inner func: only works if called from defer
        \\std := import("std")
        \\core := std.core
        \\recovered := false
        \\func handler() {
        \\    e := core.recover()
        \\    if core.is_error(e) { recovered = true }
        \\}
        \\func victim() {
        \\    defer handler()
        \\    _ = [][0]
        \\}
        \\victim()
        \\assert recovered, "recover via deferred func call"
        ,
    };

    for (cases) |src| {
        runAssert(src, "panic/recover extended");
    }
    out("  panic/recover extended: OK\n");
}

// ── Property: collection mutation during for-in must not crash ────────────────
// These test adversarial iteration patterns. We use runTolerant because some
// patterns may legitimately panic (e.g. key deletion mid-traverse). The goal
// is crash-freedom (no WASI trap), not outcome purity.

fn propIteratorInvalidation() void {
    const cases = [_][]const u8{
        // Overwrite element value (not length) during array for-in — safe
        \\var arr = [1, 2, 3, 4, 5]
        \\for v in arr {
        \\    arr[0] = 99
        \\}
        ,
        // Append during array for-in: iterator holds snapshot of original length
        \\std := import("std")
        \\core := std.core
        \\arr := [1, 2, 3]
        \\for v in arr {
        \\    arr = core.append(arr, v)
        \\    if core.len(arr) > 10 { break }
        \\}
        ,
        // Overwrite map value during map for-in (key set unchanged)
        \\var m = {"a": 1, "b": 2, "c": 3}
        \\for k in m {
        \\    m["a"] = 99
        \\}
        ,
        // Insert new key during map for-in (structural change)
        \\var m = {"a": 1}
        \\count := 0
        \\for k in m {
        \\    m["b"] = 2
        \\    count = count + 1
        \\    if count > 5 { break }
        \\}
        ,
        // Delete key currently being iterated (most adversarial)
        \\std := import("std")
        \\core := std.core
        \\m := {"a": 1, "b": 2, "c": 3}
        \\for k in m {
        \\    core.delete(m, k)
        \\}
        ,
        // Nested for-in over same array
        \\std := import("std")
        \\core := std.core
        \\arr := [1, 2, 3]
        \\pairs := 0
        \\for x in arr {
        \\    for y in arr {
        \\        pairs = pairs + 1
        \\    }
        \\}
        \\assert pairs == 9, "nested for-in same array"
        ,
    };

    for (cases) |src| {
        runTolerant(src);
    }
    out("  iterator invalidation: OK\n");
}

// ── Property: variant constructor and named-type explosion ────────────────────

fn propVariantExplosion() void {
    const cases = [_][]const u8{
        // Variant with 6 arms: all construction and dispatch paths exercised
        \\std := import("std")
        \\core := std.core
        \\type Status variant {
        \\    pending,
        \\    running(id int),
        \\    paused(id int),
        \\    failed(msg string),
        \\    succeeded(result int),
        \\    cancelled
        \\}
        \\count := 0
        \\vals := [Status.pending, Status.running(1), Status.paused(2), Status.failed("oops"), Status.succeeded(42), Status.cancelled]
        \\for v in vals {
        \\    switch v {
        \\        case .pending { count = count + 1 }
        \\        case .running as id { count = count + 1 }
        \\        case .paused as id { count = count + 1 }
        \\        case .failed as m { count = count + 1 }
        \\        case .succeeded as r { count = count + 1 }
        \\        case .cancelled { count = count + 1 }
        \\    }
        \\}
        \\assert count == 6, "all 6 variant arms matched"
        ,
        // Deep subtype chain: 3 levels of named int types
        \\std := import("std")
        \\type Score int range 0..100
        \\subtype Grade Score range 0..100
        \\subtype Honors Grade range 90..100
        \\var h Honors = Honors(95)
        \\var g Grade = Grade(h)
        \\var s Score = Score(g)
        \\assert int(s) == 95, "deep subtype chain"
        ,
        // Named type with inline predicate
        \\std := import("std")
        \\type Port int predicate func(x) { return x >= 1 and x <= 65535 }
        \\var p Port = Port(8080)
        \\assert int(p) == 8080, "predicate named type"
        ,
        // Variant construction explosion: many values with GC pressure
        \\std := import("std")
        \\core := std.core
        \\type Node variant {
        \\    leaf(v int),
        \\    branch(label string)
        \\}
        \\nodes := []
        \\for i := 0; i < 30; i++ {
        \\    if i rem 2 == 0 {
        \\        nodes = core.append(nodes, Node.leaf(i))
        \\    } else {
        \\        nodes = core.append(nodes, Node.branch("x"))
        \\    }
        \\}
        \\assert core.len(nodes) == 30, "variant explosion count"
        ,
        // Variant in map values: named dispatch over heterogeneous payload types
        \\std := import("std")
        \\core := std.core
        \\type Event variant {
        \\    click(x int),
        \\    key(code string),
        \\    resize
        \\}
        \\m := {"e1": Event.click(10), "e2": Event.key("Enter"), "e3": Event.resize}
        \\clicks := 0
        \\keys := 0
        \\for k in m {
        \\    switch m[k] {
        \\        case .click as x { clicks = clicks + 1 }
        \\        case .key as c { keys = keys + 1 }
        \\        case .resize { }
        \\    }
        \\}
        \\assert clicks == 1, "one click"
        \\assert keys == 1, "one key"
        ,
    };

    for (cases) |src| {
        runAssert(src, "variant explosion");
    }
    out("  variant explosion: OK\n");
}

// ── Main ────────────────────────────────────────────────────────────────────

export fn _start() void {
    fuzzCompiler();
    fuzzVmBytecode();
    fuzzValidAdversarialBytecode();
    fuzzVmArithmetic();
    fuzzValueWire();
    fuzzNamedTypeBoundaries();
    fuzzForInNesting();
    fuzzStackHeapBoundaries();
    fuzzDifferential();
    propCloneDeepEquals();
    propMapPromotion();
    propPanicDeferRecover();
    propPanicRecoverExtended();
    propGcInvariance();
    propSharedReferences();
    propIteratorInvalidation();
    propVariantExplosion();
    out("fuzz OK\n");
    std.os.wasi.proc_exit(0);
}
