const std = @import("std");
const builtin = @import("builtin");
const api = @import("runtime/api.zig");
const io = @import("runtime/io.zig");
const Value = @import("lang/value.zig").Value;
const Object = @import("lang/value.zig").Object;
const vms = @import("lang/vm_state.zig");
const vmgc = @import("lang/vm_gc.zig");
const net_state = @import("lang/native/net_state.zig");
const http_state = @import("lang/native/http_state.zig");

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
    rt.initWithPolicy(config) catch fail("engine: runtime init failed\n");
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

    if (b1 != .ok or b1.ok != .int or b1.ok.int != 1) fail("engine FAIL: h1 bump #1\n");
    if (b2 != .ok or b2.ok != .int or b2.ok.int != 101) fail("engine FAIL: h2 bump #1\n");
    if (b3 != .ok or b3.ok != .int or b3.ok.int != 2) fail("engine FAIL: h1 bump #2\n");

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
            if (v != .int or v.int != 42) fail("engine FAIL: runPath result\n");
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

    const call_res = rt.call("add", &.{ .{ .int = 20 }, .{ .int = 22 } });
    switch (call_res) {
        .ok => |v| {
            if (v != .int or v.int != 42) fail("engine FAIL: add(20,22) != 42\n");
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
            if (e.msg.len == 0) fail("engine FAIL: runtime error missing message\n");
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

fn testHostModules() void {
    const host_funcs = [_]api.HostModuleFuncDesc{
        .{ .name = "query", .arity = 2, .call_id = 0x1000 },
        .{ .name = "insert", .arity = 1, .call_id = 0x1001 },
    };
    const host_mods = [_]api.HostModuleDesc{
        .{ .name = "mydb", .functions = &host_funcs },
    };
    const rt = makeRt(.{ .allow_io = false, .native_backend = .host, .host_modules = &host_mods });

    const res = rt.run(
        \\db := import("mydb")
        \\func testQuery() {
        \\    _ = db.query("SELECT 1", [])
        \\}
    );
    switch (res) {
        .ok => {},
        else => fail("engine FAIL: host module compile failed\n"),
    }

    // Calling a host function should produce a runtime error
    // (no real host backend is available in WASI test environment)
    const call_res = rt.call("testQuery", &.{});
    switch (call_res) {
        .runtime_error => {},
        else => fail("engine FAIL: expected runtime error for host call\n"),
    }

    out("  host modules: OK\n");
}

fn testHostModuleUnknownField() void {
    const host_funcs = [_]api.HostModuleFuncDesc{
        .{ .name = "query", .arity = 2, .call_id = 0x1000 },
    };
    const host_mods = [_]api.HostModuleDesc{
        .{ .name = "mydb", .functions = &host_funcs },
    };
    const rt = makeRt(.{ .allow_io = false, .native_backend = .host, .host_modules = &host_mods });

    // Accessing a non-existent host module field should fail at compile time
    const res = rt.run(
        \\db := import("mydb")
        \\func testUnknown() {
        \\    _ = db.nonexistent()
        \\}
    );
    switch (res) {
        .compile_error => {},
        else => fail("engine FAIL: expected compile error for unknown host field\n"),
    }

    out("  host module unknown field: OK\n");
}

fn testFailedModuleReimport() void {
    // Two modules share a broken dependency — the second import should
    // report the original compile error, not a misleading ImportCycle.
    const sources = [_]api.SourceEntry{
        .{
            .path = "app/broken.gengo",
            .source = "func f() int { return } // syntax error\n",
        },
        .{
            .path = "app/a.gengo",
            .source = "broke := import(\"./broken\")\nfunc useA() { _ = broke }\n",
        },
        .{
            .path = "app/b.gengo",
            .source = "broke := import(\"./broken\")\nfunc useB() { _ = broke }\n",
        },
    };
    const rt = makeRt(.{ .allow_io = false, .module_sources = &sources });
    const res = rt.runPath(
        \\a := import("./a")
        \\b := import("./b")
        \\func test() { _ = a; _ = b }
    , "app/main.gengo");
    switch (res) {
        .compile_error => |e| {
            // Should report the original syntax error, not "import cycle"
            if (std.mem.indexOf(u8, e.msg, "import cycle") != null) {
                fail("engine FAIL: re-import of failed module reported import cycle instead of original error\n");
            }
        },
        else => fail("engine FAIL: expected compile error for broken module\n"),
    }

    out("  failed module re-import: OK\n");
}

fn testReplIncremental() void {
    const rt = initWithAllowIO(false);

    // Basic incremental compilation: declarations persist
    const r1 = rt.runIncremental("x := 10");
    if (r1 != .ok) fail("engine FAIL: repl init\n");

    const r2 = rt.runIncremental("x = 20");
    if (r2 != .ok) fail("engine FAIL: repl update\n");

    const r3 = rt.runIncremental("x");
    if (r3 != .ok) fail("engine FAIL: repl expr\n");

    // Typed redeclaration of existing global should error
    const r4 = rt.runIncremental("var x int := 30");
    switch (r4) {
        .compile_error => {},
        else => fail("engine FAIL: expected redeclare error\n"),
    }

    // const declared in one line must not be reassignable in a subsequent line
    const r5 = rt.runIncremental("const cx int = 99");
    if (r5 != .ok) fail("engine FAIL: repl const decl\n");
    const r6 = rt.runIncremental("cx = 1");
    switch (r6) {
        .compile_error => {},
        else => fail("engine FAIL: expected AssignToConst across repl lines\n"),
    }

    const r7 = rt.runIncremental("x += 1.5");
    switch (r7) {
        .runtime_error => |e| {
            if (e.kind != error.TypeError) fail("engine FAIL: expected runtime TypeError in repl\n");
            if (e.line == 0 or e.col == 0) fail("engine FAIL: repl runtime position missing\n");
            if (e.msg.len == 0) fail("engine FAIL: repl runtime message missing\n");
        },
        else => fail("engine FAIL: expected runtime error in repl\n"),
    }

    // Named type persistence across REPL lines
    const rt2 = initWithAllowIO(false);
    const r8 = rt2.runIncremental("type Time float");
    if (r8 != .ok) fail("engine FAIL: repl type decl\n");
    const r9 = rt2.runIncremental("var t Time = Time(1.5)");
    if (r9 != .ok) fail("engine FAIL: repl typed var across lines\n");
    const r10 = rt2.runIncremental("subtype Age Time range 0..200");
    if (r10 != .ok) fail("engine FAIL: repl subtype across lines\n");
    const r11 = rt2.runIncremental("var a Age = Age(100)");
    if (r11 != .ok) fail("engine FAIL: repl subtype typed var across lines\n");
    // The FIRST type must survive the persistence of later ones: the name
    // buffer is rebuilt per line, and a reused-but-unreserved slice gets
    // clobbered by the next new name (regression: Time read back as "Agee").
    const r11b = rt2.runIncremental("var t2 Time = Time(2.5)");
    if (r11b != .ok) fail("engine FAIL: repl first type clobbered by later type persist\n");

    // Struct type persistence across REPL lines
    const rt3 = initWithAllowIO(false);
    const r12 = rt3.runIncremental("type Point struct { x int, y int }");
    if (r12 != .ok) fail("engine FAIL: repl struct type decl\n");
    const r13 = rt3.runIncremental("var p Point = Point{x: 1, y: 2}");
    if (r13 != .ok) fail("engine FAIL: repl struct typed var across lines\n");

    // Struct type annotation on a parameter across lines
    const rt4 = initWithAllowIO(false);
    const r14 = rt4.runIncremental("type Meters int");
    if (r14 != .ok) fail("engine FAIL: repl type for annotation\n");
    const r15 = rt4.runIncremental(
        \\func f(x Meters) int { return int(x) }
    );
    if (r15 != .ok) fail("engine FAIL: repl type annotation in func param\n");

    // Enum subtype member access across REPL lines (#115)
    const rt5 = initWithAllowIO(false);
    const r16 = rt5.runIncremental("type Days enum { mon, sat, sun }");
    if (r16 != .ok) fail("engine FAIL: repl enum type decl (#115)\n");
    const r17 = rt5.runIncremental("subtype Weekend Days { sat, sun }");
    if (r17 != .ok) fail("engine FAIL: repl enum subtype decl (#115)\n");
    const r18 = rt5.runIncremental("_ = Weekend.sat");
    if (r18 != .ok) fail("engine FAIL: repl enum subtype member access (#115)\n");

    // Enum subtype member VALIDATION must persist across REPL lines (#115):
    // the parent enum's member list must be available so an out-of-set member
    // is rejected at declaration time, exactly as in file mode.
    const rt6 = initWithAllowIO(false);
    const r19 = rt6.runIncremental("type Colors enum { red, green, blue }");
    if (r19 != .ok) fail("engine FAIL: repl enum type decl for validation (#115)\n");
    const r20 = rt6.runIncremental("subtype Warm Colors { orange }");
    switch (r20) {
        .compile_error => {},
        else => fail("engine FAIL: repl enum subtype must reject non-parent member (#115)\n"),
    }

    out("  repl incremental: OK\n");
}

fn testArrayWireResult() void {
    const rt = initWithAllowIO(false);
    const res = rt.run(
        \\func makeArr() []int { return [1, 2, 3] }
    );
    if (res != .ok) fail("engine FAIL: array_wire setup\n");

    // engine_call returns Value, not wire - access array directly
    const call_res = rt.call("makeArr", &.{});
    switch (call_res) {
        .ok => |v| {
            if (v != .object) fail("engine FAIL: expected object\n");
            const items = vms.asArraySlice(v.object) catch unreachable;
            if (items.len != 3) fail("engine FAIL: expected 3 items\n");
            if (items[0] != .int or items[0].int != 1) fail("engine FAIL: expected 1\n");
            if (items[1] != .int or items[1].int != 2) fail("engine FAIL: expected 2\n");
            if (items[2] != .int or items[2].int != 3) fail("engine FAIL: expected 3\n");
        },
        else => fail("engine FAIL: array_wire call\n"),
    }

    out("  array wire result: OK\n");
}

fn testMapWireResult() void {
    const rt = initWithAllowIO(false);
    const res = rt.run(
        \\m := {"a": 1, "b": 2}
        \\func readMap(k string) int { return m[k] }
    );
    if (res != .ok) fail("engine FAIL: map_wire setup\n");

    const call_res = rt.call("readMap", &.{.{ .string = "b" }});
    switch (call_res) {
        .ok => |v| {
            if (v != .int or v.int != 2) fail("engine FAIL: expected 2\n");
        },
        else => fail("engine FAIL: map_wire call\n"),
    }

    // Also verify the global map is accessible
    const global_m = rt.call("readMap", &.{.{ .string = "a" }});
    switch (global_m) {
        .ok => |v| {
            if (v != .int or v.int != 1) fail("engine FAIL: expected 1\n");
        },
        else => fail("engine FAIL: map_wire call a\n"),
    }

    out("  map wire result: OK\n");
}

fn testHostModuleArrayArgs() void {
    const host_funcs = [_]api.HostModuleFuncDesc{
        .{ .name = "process", .arity = 2, .call_id = 0x1002 },
    };
    const host_mods = [_]api.HostModuleDesc{
        .{ .name = "proc", .functions = &host_funcs },
    };
    const rt = makeRt(.{ .allow_io = false, .native_backend = .host, .host_modules = &host_mods });

    const res = rt.run(
        \\p := import("proc")
        \\func testArr() {
        \\    _ = p.process([1, 2, 3], {"k": "v"})
        \\}
    );
    switch (res) {
        .ok => {},
        else => fail("engine FAIL: host_module_array compile failed\n"),
    }

    // Call should produce runtime error (no real host backend)
    const call_res = rt.call("testArr", &.{});
    switch (call_res) {
        .runtime_error => {},
        else => fail("engine FAIL: expected runtime error\n"),
    }

    out("  host module array args: OK\n");
}

fn testNetCapability() void {
    const rt = makeRt(.{ .allow_io = false, .capabilities = &.{"net"} });

    const res = rt.run(
        \\net := import("cap:net")
        \\func testDial() {
        \\    _ = net.dial("tcp", "127.0.0.1:1")
        \\}
        \\func testLocalAddr() {
        \\    conn := net.dial("tcp", "127.0.0.1:1")
        \\    _ = conn.local_addr()
        \\}
        \\func testRemoteAddr() {
        \\    conn := net.dial("tcp", "127.0.0.1:1")
        \\    _ = conn.remote_addr()
        \\}
        \\func testDeadline() {
        \\    conn := net.dial("tcp", "127.0.0.1:1")
        \\    conn.set_deadline(1000)
        \\}
    );
    switch (res) {
        .ok => {},
        else => fail("engine FAIL: net capability compile failed\n"),
    }

    // On WASM, all net socket functions return CapabilityNotAvailable at runtime
    const dial_res = rt.call("testDial", &.{});
    switch (dial_res) {
        .runtime_error => {},
        else => fail("engine FAIL: expected runtime error for net.dial on WASM\n"),
    }
    const local_res = rt.call("testLocalAddr", &.{});
    switch (local_res) {
        .runtime_error => {},
        else => fail("engine FAIL: expected runtime error for conn.local_addr on WASM\n"),
    }
    const remote_res = rt.call("testRemoteAddr", &.{});
    switch (remote_res) {
        .runtime_error => {},
        else => fail("engine FAIL: expected runtime error for conn.remote_addr on WASM\n"),
    }
    const deadline_res = rt.call("testDeadline", &.{});
    switch (deadline_res) {
        .runtime_error => {},
        else => fail("engine FAIL: expected runtime error for conn.set_deadline on WASM\n"),
    }

    out("  net capability: OK\n");
}

const MockNetState = struct {
    dial_called: bool = false,
    read_called: bool = false,
    write_called: bool = false,
    close_called: bool = false,
    local_addr_called: bool = false,
    remote_addr_called: bool = false,
    deadline_called: bool = false,
    read_deadline_called: bool = false,
    write_deadline_called: bool = false,
    closed: bool = false,
    dial_network: [64]u8 = undefined,
    dial_network_len: usize = 0,
    dial_address: [64]u8 = undefined,
    dial_address_len: usize = 0,
    written_data: [64]u8 = undefined,
    written_len: usize = 0,
};

fn mockDial(network: [*]const u8, network_len: usize, address: [*]const u8, address_len: usize, out_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 {
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    s.dial_called = true;
    s.dial_network_len = @min(network_len, s.dial_network.len);
    @memcpy(s.dial_network[0..s.dial_network_len], network[0..s.dial_network_len]);
    s.dial_address_len = @min(address_len, s.dial_address.len);
    @memcpy(s.dial_address[0..s.dial_address_len], address[0..s.dial_address_len]);
    out_handle.* = 42;
    return 0;
}

fn mockRead(handle: i32, buf: [*]u8, max_bytes: i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = handle;
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    if (s.closed) return -1;
    s.read_called = true;
    const test_data = "hello from mock";
    const n = @min(@as(usize, @intCast(max_bytes)), test_data.len);
    @memcpy(buf[0..n], test_data[0..n]);
    return @intCast(n);
}

fn mockWrite(handle: i32, data: [*]const u8, len: i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = handle;
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    if (s.closed) return -1;
    s.write_called = true;
    s.written_len = @min(@as(usize, @intCast(len)), s.written_data.len);
    @memcpy(s.written_data[0..s.written_len], data[0..s.written_len]);
    return len;
}

fn mockClose(handle: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    s.close_called = true;
    s.closed = true;
}

fn mockLocalAddr(handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    s.local_addr_called = true;
    const addr = "127.0.0.1:54321";
    const n = @min(@as(usize, @intCast(buf_len)), addr.len);
    @memcpy(buf[0..n], addr);
}

fn mockRemoteAddr(handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    s.remote_addr_called = true;
    const addr = "127.0.0.1:9999";
    const n = @min(@as(usize, @intCast(buf_len)), addr.len);
    @memcpy(buf[0..n], addr);
}

fn mockSetDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    _ = handle;
    _ = ms;
    s.deadline_called = true;
}

fn mockSetReadDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    _ = handle;
    _ = ms;
    s.read_deadline_called = true;
}

fn mockSetWriteDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    const s: *MockNetState = @ptrCast(@alignCast(userdata));
    _ = handle;
    _ = ms;
    s.write_deadline_called = true;
}

fn testNetCapabilityHandlers() void {
    var state = MockNetState{};

    const handlers = net_state.GengoNetHandlers{
        .dial = &mockDial,
        .read = &mockRead,
        .write = &mockWrite,
        .close = &mockClose,
        .local_addr = &mockLocalAddr,
        .remote_addr = &mockRemoteAddr,
        .set_deadline = &mockSetDeadline,
        .set_read_deadline = &mockSetReadDeadline,
        .set_write_deadline = &mockSetWriteDeadline,
    };
    net_state.setNetHandlers(handlers, @ptrCast(&state));

    const rt = makeRt(.{ .allow_io = false, .capabilities = &.{"net"} });

    const test_src =
        \\net := import("cap:net")
        \\func testAll() {
        \\    conn := net.dial("tcp", "127.0.0.1:9999")
        \\    _ = conn.read(100)
        \\    _ = conn.write("hello from gengo")
        \\    _ = conn.local_addr()
        \\    _ = conn.remote_addr()
        \\    conn.set_deadline(5000)
        \\    conn.set_read_deadline(3000)
        \\    conn.set_write_deadline(4000)
        \\    conn.close()
        \\}
        \\func testUseAfterClose() {
        \\    conn := net.dial("tcp", "127.0.0.1:9999")
        \\    conn.close()
        \\    _ = conn.read(10)
        \\}
    ;
    const res = rt.run(test_src);
    switch (res) {
        .ok => {},
        .compile_error => |e| { writeAll(2, "engine FAIL: net handler compile: "); writeAll(2, e.msg); writeAll(2, "\n"); std.os.wasi.proc_exit(1); },
        .runtime_error => |e| { writeAll(2, "engine FAIL: net handler runtime: "); writeAll(2, e.msg); writeAll(2, "\n"); std.os.wasi.proc_exit(1); },
    }

    const all_res = rt.call("testAll", &.{});
    switch (all_res) {
        .ok => {
            if (!state.dial_called) fail("engine FAIL: handler dial not called\n");
            if (!state.read_called) fail("engine FAIL: handler read not called\n");
            if (!state.write_called) fail("engine FAIL: handler write not called\n");
            if (!state.close_called) fail("engine FAIL: handler close not called\n");
            if (!state.local_addr_called) fail("engine FAIL: handler local_addr not called\n");
            if (!state.remote_addr_called) fail("engine FAIL: handler remote_addr not called\n");
            if (!state.deadline_called) fail("engine FAIL: handler set_deadline not called\n");
            if (!state.read_deadline_called) fail("engine FAIL: handler set_read_deadline not called\n");
            if (!state.write_deadline_called) fail("engine FAIL: handler set_write_deadline not called\n");
        },
        .runtime_error => fail("engine FAIL: handler test unexpected error\n"),
    }

    {
        const uac_res = rt.call("testUseAfterClose", &.{});
        switch (uac_res) {
            .runtime_error => {},
            else => fail("engine FAIL: expected runtime error for use-after-close\n"),
        }
    }

    out("  net capability handlers: OK\n");
}

const MockHttpState = struct {
    get_called: bool = false,
    post_called: bool = false,
    fetch_called: bool = false,
    last_method: [8]u8 = undefined,
    last_method_len: usize = 0,
    last_url: [128]u8 = undefined,
    last_url_len: usize = 0,
    last_body: [256]u8 = undefined,
    last_body_len: usize = 0,
    fail_next: bool = false,
};

fn mockHttpFetch(req: *const http_state.GengoHttpRequest, resp: *http_state.GengoHttpResponse, userdata: ?*anyopaque) callconv(.c) c_int {
    const s: *MockHttpState = @ptrCast(@alignCast(userdata));
    const method = std.mem.span(req.method);
    const url = std.mem.span(req.url);

    s.last_method_len = @min(method.len, s.last_method.len);
    @memcpy(s.last_method[0..s.last_method_len], method[0..s.last_method_len]);
    s.last_url_len = @min(url.len, s.last_url.len);
    @memcpy(s.last_url[0..s.last_url_len], url[0..s.last_url_len]);

    if (req.body_len > 0) {
        const bl = @min(@as(usize, @intCast(req.body_len)), s.last_body.len);
        @memcpy(s.last_body[0..bl], req.body[0..bl]);
        s.last_body_len = bl;
    } else {
        s.last_body_len = 0;
    }

    if (std.mem.eql(u8, method, "GET")) {
        s.get_called = true;
    } else if (std.mem.eql(u8, method, "POST")) {
        s.post_called = true;
    } else {
        s.fetch_called = true;
    }

    if (s.fail_next) {
        s.fail_next = false;
        return -1;
    }

    const test_body = "{\"status\":\"ok\"}";
    resp.status = if (std.mem.containsAtLeast(u8, url, 1, "404")) 404 else 200;
    resp.body = test_body.ptr;
    resp.body_len = @intCast(test_body.len);
    resp.headers = .{ .keys = null, .values = null, .count = 0 };
    return 0;
}

fn testGcStressWindows() void {
    // Verify the runtime toggle exists.
    const saved = vmgc.gc_stress;
    vmgc.gc_stress = true;
    _ = vmgc.gc_stress;
    vmgc.gc_stress = saved;

    // The specific opcode GC-window fixes (peek-allocate-pop, temp-rooting)
    // are verified implicitly by the conformance tests. The `-Dgc_stress`
    // compile-time option provides exhaustive GC-window coverage.
    out("  gc stress windows: N/A (build with -Dgc_stress=true for full coverage)\n");
}

fn testInitWithConfig() void {
    // Create a runtime with custom (but valid) resource limits.
    // On WASM this falls back to preset backing arrays; on native it
    // allocates per-instance buffers of the requested size.
    const rt = std.heap.page_allocator.create(api.Runtime) catch fail("engine: out of memory\n");
    rt.initWithPolicy(.{
        .allow_io = true,
        .heap_size_bytes = 64 * 1024,
        .max_objects = 256,
        .max_stack = 128,
        .max_frames = 32,
        .max_defers = 64,
    }) catch fail("engine: runtime init failed\n");

    const res = rt.run("std := import(\"std\")\nstd.io.println(42)");
    switch (res) {
        .ok => {},
        .compile_error => |e| { writeAll(2, "engine FAIL: config compile: "); writeAll(2, e.msg); writeAll(2, "\n"); std.os.wasi.proc_exit(1); },
        .runtime_error => |e| { writeAll(2, "engine FAIL: config runtime: "); writeAll(2, e.msg); writeAll(2, "\n"); std.os.wasi.proc_exit(1); },
    }
    out("  init_with_config: OK\n");
}

fn testInitFailure() void {
    // Verify that runtime init failures are propagated to the caller
    // rather than silently returning a partially-initialised runtime.
    // On WASM the backing arrays are fixed-size and init never allocates,
    // so this test only applies to native targets.
    if (comptime builtin.target.cpu.arch == .wasm32) {
        out("  init_failure_detected: OK (skipped on WASM)\n");
        return;
    }

    const FailingAlloc = struct {
        fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            return null;
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
    };
    const failing_alloc_vtable: std.mem.Allocator.VTable = .{
        .alloc = FailingAlloc.alloc,
        .resize = FailingAlloc.resize,
        .free = FailingAlloc.free,
        .remap = FailingAlloc.remap,
    };
    const failing_alloc: std.mem.Allocator = .{ .ptr = undefined, .vtable = &failing_alloc_vtable };

    var rt: api.Runtime = undefined;
    rt.initWithPolicy(.{ .allow_io = false, .allocator = failing_alloc }) catch {
        out("  init_failure_detected: OK\n");
        return;
    };
    fail("engine FAIL: init failure was not detected\n");
}

fn testStructReturn() void {
    const rt = initWithAllowIO(false);
    const res = rt.run(
        \\type Point struct { x int, y int }
        \\func makePoint() Point {
        \\    return Point{x: 1, y: 2}
        \\}
    );
    if (res != .ok) fail("engine FAIL: struct return setup\n");

    const call_res = rt.call("makePoint", &[_]Value{});
    switch (call_res) {
        .ok => |v| {
            if (v != .object or v.object.* != .struct_instance) fail("engine FAIL: struct return type\n");
            const fields = v.object.struct_instance.fields;
            if (fields.len != 2) fail("engine FAIL: struct field count\n");
            // fields are MapEntry with string keys
            var found_x = false;
            var found_y = false;
            for (fields) |f| {
                const key = switch (f.key) {
                    .string => |s| s,
                    .object => |o| if (o.* == .dyn_string) o.dyn_string else if (o.* == .string_view) o.string_view.bytes else fail("engine FAIL: struct bad key type\n"),
                    else => fail("engine FAIL: struct bad key type\n"),
                };
                if (std.mem.eql(u8, key, "x")) {
                    if (f.value != .int or f.value.int != 1) fail("engine FAIL: struct x field\n");
                    found_x = true;
                } else if (std.mem.eql(u8, key, "y")) {
                    if (f.value != .int or f.value.int != 2) fail("engine FAIL: struct y field\n");
                    found_y = true;
                }
            }
            if (!found_x or !found_y) fail("engine FAIL: struct missing fields\n");
        },
        .runtime_error => |e| {
            writeAll(2, "struct call runtime: "); writeAll(2, e.msg); writeAll(2, "\n");
            fail("engine FAIL: struct call failed\n");
        },
    }
    out("  struct return: OK\n");
}

fn testRuneReturn() void {
    const rt = initWithAllowIO(false);
    const res = rt.run(
        \\func makeRune() rune {
        \\    return `A`
        \\}
    );
    if (res != .ok) {
        switch (res) {
            .compile_error => |e| { writeAll(2, "rune setup compile: "); writeAll(2, e.msg); writeAll(2, "\n"); },
            .runtime_error => |e| { writeAll(2, "rune setup runtime: "); writeAll(2, e.msg); writeAll(2, "\n"); },
            else => {},
        }
        fail("engine FAIL: rune return setup\n");
    }

    const call_res = rt.call("makeRune", &[_]Value{});
    switch (call_res) {
        .ok => |v| {
            if (v != .rune or v.rune != 'A') fail("engine FAIL: rune return value\n");
        },
        .runtime_error => |e| {
            writeAll(2, "rune call runtime: ");
            writeAll(2, @errorName(e.kind));
            writeAll(2, ": ");
            writeAll(2, e.msg);
            writeAll(2, "\n");
            fail("engine FAIL: rune call failed\n");
        },
    }
    out("  rune return: OK\n");
}

fn testNamedTypeReturn() void {
    const rt = initWithAllowIO(false);
    const res = rt.run(
        \\type Meter int
        \\func makeMeter() Meter {
        \\    return Meter(5)
        \\}
    );
    if (res != .ok) fail("engine FAIL: named type return setup\n");

    const call_res = rt.call("makeMeter", &[_]Value{});
    switch (call_res) {
        .ok => |v| {
            if (v != .object or v.object.* != .named_value) fail("engine FAIL: named type return type\n");
            const inner = v.object.named_value.value;
            if (inner != .int or inner.int != 5) fail("engine FAIL: named type inner value\n");
        },
        .runtime_error => |e| {
            writeAll(2, "named type call runtime: "); writeAll(2, e.msg); writeAll(2, "\n");
            fail("engine FAIL: named type call failed\n");
        },
    }
    out("  named type return: OK\n");
}

fn testErrorReturn() void {
    const rt = initWithAllowIO(false);
    const res = rt.run(
        \\std := import("std")
        \\func makeError() error {
        \\    return std.core.error("boom")
        \\}
    );
    if (res != .ok) fail("engine FAIL: error return setup\n");

    const call_res = rt.call("makeError", &[_]Value{});
    switch (call_res) {
        .ok => |v| {
            if (v != .error_value) fail("engine FAIL: error return type\n");
            if (!std.mem.eql(u8, v.error_value, "boom")) fail("engine FAIL: error return message\n");
        },
        .runtime_error => |e| {
            writeAll(2, "error call runtime: "); writeAll(2, e.msg); writeAll(2, "\n");
            fail("engine FAIL: error call failed\n");
        },
    }
    out("  error return: OK\n");
}

fn testRuntimeDisablePredicates() void {
    const rt = makeRt(.{ .allow_io = false, .enable_predicates = false });
    const res = rt.run(
        \\type PositiveInt int predicate func(x) { return x > 0 }
        \\a := PositiveInt(-1)
        \\func getA() PositiveInt { return a }
    );
    switch (res) {
        .ok => {},
        else => fail("engine FAIL: predicate disable should allow negative value\n"),
    }
    const call_res = rt.call("getA", &.{});
    switch (call_res) {
        .ok => |v| {
            if (v != .object or v.object.* != .named_value) fail("engine FAIL: expected named value when predicates disabled\n");
            if (v.object.named_value.value != .int or v.object.named_value.value.int != -1) fail("engine FAIL: expected -1 when predicates disabled\n");
        },
        else => fail("engine FAIL: expected call success when predicates disabled\n"),
    }
    out("  runtime disable predicates: OK\n");
}

fn testHttpCapability() void {
    var state: MockHttpState = .{};
    http_state.setHttpHandler(&mockHttpFetch, @ptrCast(&state));

    const rt = makeRt(.{ .allow_io = true, .capabilities = &.{"http"} });

    const test_src =
        \\std := import("std")
        \\http := import("cap:http")
        \\func testGet() {
        \\    resp, err := http.get("https://example.com/data")
        \\    if err != null { return }
        \\    std.io.println(resp.status)
        \\    std.io.println(resp.ok)
        \\    std.io.println(resp.body)
        \\}
        \\func testPost() {
        \\    resp, err := http.post("https://example.com/api", "{\"key\":\"value\"}")
        \\    if err != null { return }
        \\    std.io.println(resp.status)
        \\}
        \\func testFetch() {
        \\    resp, err := http.fetch("https://example.com/api", {
        \\        "method": "PUT",
        \\        "body": "put-body",
        \\        "timeout_ms": 5000,
        \\    })
        \\    if err != null { return }
        \\    std.io.println(resp.status)
        \\}
        \\func testNotFound() {
        \\    resp, err := http.get("https://example.com/404")
        \\    if err != null { return }
        \\    std.io.println(resp.status)
        \\    std.io.println(resp.ok)
        \\}
        \\func testFailure() {
        \\    _, err := http.get("https://fail.example.com/")
        \\    std.io.println(err)
        \\}
    ;

    const res = rt.run(test_src);
    switch (res) {
        .ok => {},
        .compile_error => |e| { writeAll(2, "engine FAIL: http handler compile: "); writeAll(2, e.msg); writeAll(2, "\n"); std.os.wasi.proc_exit(1); },
        .runtime_error => |e| { writeAll(2, "engine FAIL: http handler runtime: "); writeAll(2, e.msg); writeAll(2, "\n"); std.os.wasi.proc_exit(1); },
    }

    const get_res = rt.call("testGet", &.{});
    switch (get_res) {
        .ok => {
            if (!state.get_called) fail("engine FAIL: http handler get not called\n");
            if (!std.mem.eql(u8, state.last_method[0..state.last_method_len], "GET")) fail("engine FAIL: expected GET method\n");
            if (!std.mem.eql(u8, state.last_url[0..state.last_url_len], "https://example.com/data")) fail("engine FAIL: unexpected GET url\n");
        },
        .runtime_error => fail("engine FAIL: http get unexpected error\n"),
    }

    const post_res = rt.call("testPost", &.{});
    switch (post_res) {
        .ok => {
            if (!state.post_called) fail("engine FAIL: http handler post not called\n");
            if (!std.mem.eql(u8, state.last_method[0..state.last_method_len], "POST")) fail("engine FAIL: expected POST method\n");
            if (!std.mem.eql(u8, state.last_body[0..state.last_body_len], "{\"key\":\"value\"}")) fail("engine FAIL: unexpected POST body\n");
        },
        .runtime_error => fail("engine FAIL: http post unexpected error\n"),
    }

    const fetch_res = rt.call("testFetch", &.{});
    switch (fetch_res) {
        .ok => {
            if (!state.fetch_called) fail("engine FAIL: http handler fetch not called\n");
            if (!std.mem.eql(u8, state.last_method[0..state.last_method_len], "PUT")) fail("engine FAIL: expected PUT method\n");
            if (!std.mem.eql(u8, state.last_body[0..state.last_body_len], "put-body")) fail("engine FAIL: unexpected fetch body\n");
        },
        .runtime_error => fail("engine FAIL: http fetch unexpected error\n"),
    }

    const nf_res = rt.call("testNotFound", &.{});
    switch (nf_res) {
        .ok => {},
        .runtime_error => fail("engine FAIL: http 404 should not be an error\n"),
    }

    state.fail_next = true;
    const fail_res = rt.call("testFailure", &.{});
    switch (fail_res) {
        .ok => {},
        .runtime_error => fail("engine FAIL: http failure should return error value, not panic\n"),
    }

    http_state.resetHandler();
    out("  http capability: OK\n");
}

// fd 3 = preopened "/" (--dir /), fd 4 = preopened "." (--dir .) from build.zig
const cwd_preopen_fd: std.os.wasi.fd_t = 4;

fn readFileWasi(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const wasi = std.os.wasi;
    var file_fd: wasi.fd_t = undefined;
    const rc = wasi.path_open(
        cwd_preopen_fd,
        .{},
        path.ptr, path.len,
        .{},
        .{ .FD_READ = true, .FD_SEEK = true },
        .{ .FD_READ = true, .FD_SEEK = true },
        .{},
        &file_fd,
    );
    if (rc != .SUCCESS) return error.FileNotFound;
    defer _ = wasi.fd_close(file_fd);

    var data: []u8 = try alloc.alloc(u8, 0);
    var buf: [4096]u8 = undefined;
    while (true) {
        var iov = [1]wasi.iovec_t{.{ .base = &buf, .len = buf.len }};
        var nread: usize = 0;
        const rrc = wasi.fd_read(file_fd, &iov, 1, &nread);
        if (rrc != .SUCCESS or nread == 0) break;
        const old_len = data.len;
        data = try alloc.realloc(data, old_len + nread);
        @memcpy(data[old_len..][0..nread], buf[0..nread]);
    }
    return data;
}

fn runCapHttpConformance() void {
    const alloc = std.heap.page_allocator;
    const spec_dir = "tests/spec/cap/http";
    const cases = [_][]const u8{ "003_http_get", "004_http_post", "005_http_non2xx", "006_http_error" };

    var state: MockHttpState = .{};
    http_state.setHttpHandler(&mockHttpFetch, @ptrCast(&state));
    defer http_state.resetHandler();

    const rt = makeRt(.{ .allow_io = true, .capabilities = &.{"http"} });

    var pass: usize = 0;
    var fail_count: usize = 0;

    for (cases) |name| {
        const src_path = std.fmt.allocPrint(alloc, "{s}/{s}.gengo", .{ spec_dir, name }) catch continue;
        defer alloc.free(src_path);
        const out_path = std.fmt.allocPrint(alloc, "{s}/{s}.out", .{ spec_dir, name }) catch continue;
        defer alloc.free(out_path);

        const src = readFileWasi(alloc, src_path) catch continue;
        defer alloc.free(src);
        const expected = readFileWasi(alloc, out_path) catch continue;
        defer alloc.free(expected);

        capture_len = 0;
        state = .{};
        rt.reset();
        rt.setConfig(.{ .allow_io = true, .capabilities = &.{"http"} });
        io.setWriteOverrides(captureWrite, captureWerr);

        const res = rt.runPath(src, src_path);
        const ok = switch (res) {
            .ok => std.mem.eql(u8, capture_buf[0..capture_len], expected),
            else => false,
        };

        out(if (ok) "  [PASS-CASE] " else "  [FAIL-CASE] ");
        out(src_path);
        out("\n");
        if (ok) pass += 1 else fail_count += 1;
    }

    io.clearWriteOverrides();

    if (fail_count > 0) {
        out("cap/http conformance FAILED\n");
        std.os.wasi.proc_exit(1);
    }
    if (pass > 0) {
        out("  cap/http conformance OK\n");
    }
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
    testReplIncremental();
    testHostModules();
    testHostModuleUnknownField();
    testFailedModuleReimport();
    testArrayWireResult();
    testMapWireResult();
    testHostModuleArrayArgs();
    testGcStressWindows();
    testNetCapability();
    testNetCapabilityHandlers();
    testInitWithConfig();
    testInitFailure();
    testStructReturn();
    testRuneReturn();
    testNamedTypeReturn();
    testErrorReturn();
    testRuntimeDisablePredicates();
    testHttpCapability();
    out("engine-api OK\n");
    runCapHttpConformance();
    std.os.wasi.proc_exit(0);
}
