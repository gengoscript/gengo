const std = @import("std");
const builtin = @import("builtin");
const vmod = @import("../lang/value.zig");
const Value = vmod.Value;

const w32 = std.os.windows;

extern "kernel32" fn GetStdHandle(nStdHandle: w32.DWORD) callconv(.winapi) w32.HANDLE;
extern "kernel32" fn WriteFile(
    hFile: w32.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: w32.DWORD,
    lpNumberOfBytesWritten: ?*w32.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) w32.BOOL;
extern "kernel32" fn ReadFile(
    hFile: w32.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: w32.DWORD,
    lpNumberOfBytesRead: ?*w32.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) w32.BOOL;

pub const WriteFn = *const fn (s: []const u8) void;
pub const ReadFn = *const fn (buf: []u8, is_line: bool) isize;
pub const TraceFn = *const fn (userdata: ?*anyopaque, handle: i32, line: i32, col: i32) callconv(.c) void;

// threadlocal: set for the duration of one engine_run/engine_call by
// engine.zig's pushEngineState/popEngineState, the same as
// g_active_engine/write_callback/read_callback there and
// native_host_call_fn/_ctx in host_abi.zig. As plain (non-threadlocal)
// vars, two threads calling into different engines concurrently could
// interleave these writes so one engine's trace/write/read calls fired
// through the other engine's callback and userdata — see engine.zig's
// g_active_engine doc comment for the full writeup and the two-thread
// repro that caught the analogous bug in those other fields.
threadlocal var write_override: ?WriteFn = null;
threadlocal var werr_override: ?WriteFn = null;
threadlocal var read_override: ?ReadFn = null;
threadlocal var g_trace_fn: ?TraceFn = null;
threadlocal var g_trace_userdata: ?*anyopaque = null;
threadlocal var g_trace_handle: i32 = -1;
threadlocal var g_trace_prev_line: u32 = 0xFFFF_FFFF;

pub fn setWriteOverrides(w: WriteFn, e: WriteFn) void {
    write_override = w;
    werr_override = e;
}

pub fn clearWriteOverrides() void {
    write_override = null;
    werr_override = null;
}

pub fn setReadOverride(f: ReadFn) void {
    read_override = f;
}

pub fn clearReadOverride() void {
    read_override = null;
}

pub fn setTrace(f: ?TraceFn, ud: ?*anyopaque, handle: i32) void {
    g_trace_fn = f;
    g_trace_userdata = ud;
    g_trace_handle = handle;
    g_trace_prev_line = 0xFFFF_FFFF;
}

pub fn clearTrace() void {
    g_trace_fn = null;
    g_trace_handle = -1;
}

pub fn traceActive() bool {
    return g_trace_fn != null;
}

pub fn fireTrace(line: u32, col: u32) void {
    const f = g_trace_fn orelse return;
    if (line == g_trace_prev_line) return;
    g_trace_prev_line = line;
    f(g_trace_userdata, g_trace_handle, @intCast(line), @intCast(col));
}

pub fn writeAllFd(fd: u8, s: []const u8) void {
    if (comptime builtin.os.tag == .wasi) {
        var off: usize = 0;
        while (off < s.len) {
            var iov = [1]std.os.wasi.ciovec_t{.{ .base = s[off..].ptr, .len = s.len - off }};
            var wrote: usize = 0;
            const rc = std.os.wasi.fd_write(fd, &iov, iov.len, &wrote);
            if (rc != .SUCCESS or wrote == 0) return;
            off += wrote;
        }
        return;
    }

    if (comptime builtin.os.tag == .windows) {
        const STD_OUTPUT_HANDLE: w32.DWORD = 0xFFFFFFF5;
        const STD_ERROR_HANDLE: w32.DWORD = 0xFFFFFFF4;
        const handle = switch (fd) {
            1 => GetStdHandle(STD_OUTPUT_HANDLE),
            2 => GetStdHandle(STD_ERROR_HANDLE),
            else => return,
        };
        _ = WriteFile(handle, s.ptr, @intCast(s.len), null, null);
        return;
    }

    _ = std.posix.system.write(@intCast(fd), s.ptr, s.len);
}

pub fn write(s: []const u8) void {
    if (write_override) |f| return f(s);
    writeAllFd(1, s);
}

pub fn werr(s: []const u8) void {
    if (werr_override) |f| return f(s);
    writeAllFd(2, s);
}

fn formatUint(v: u64, comptime emit: fn ([]const u8) void) void {
    if (v == 0) {
        emit("0");
        return;
    }
    var buf: [24]u8 = undefined;
    var n = v;
    var len: usize = 0;
    while (n > 0) {
        buf[len] = '0' + @as(u8, @intCast(n % 10));
        len += 1;
        n /= 10;
    }
    var i: usize = 0;
    while (i < len / 2) : (i += 1) {
        const t = buf[i];
        buf[i] = buf[len - 1 - i];
        buf[len - 1 - i] = t;
    }
    emit(buf[0..len]);
}

fn formatInt(v: i64, comptime emit: fn ([]const u8) void) void {
    if (v < 0) {
        emit("-");
        const uv = if (v == std.math.minInt(i64)) @as(u64, @intCast(std.math.maxInt(i64))) + 1 else @as(u64, @intCast(-v));
        formatUint(uv, emit);
    } else formatUint(@intCast(v), emit);
}

pub fn writeUint(v: u64) void {
    formatUint(v, write);
}
pub fn writeInt(v: i64) void {
    formatInt(v, write);
}
pub fn werrUint(v: u64) void {
    formatUint(v, werr);
}
pub fn werrInt(v: i64) void {
    formatInt(v, werr);
}

pub fn writeF64Prec(v: f64, prec: usize) void {
    if (v != v) {
        write("NaN");
        return;
    }
    if (std.math.isInf(v)) {
        write(if (v > 0) "Inf" else "-Inf");
        return;
    }
    var n = v;
    if (n < 0.0) {
        write("-");
        n = -n;
    }
    var scale: f64 = 1.0;
    var pi: usize = 0;
    while (pi < prec) : (pi += 1) scale *= 10.0;
    const scaled = @round(n * scale);
    const scaled_div = @trunc(scaled / scale);
    if (scaled_div < 0 or scaled_div >= std.math.pow(f64, 2.0, 64.0)) {
        write("?");
        return;
    }
    const int_part: u64 = @intFromFloat(scaled_div);
    const frac_mod = @mod(scaled, scale);
    if (frac_mod < 0 or frac_mod >= std.math.pow(f64, 2.0, 64.0)) {
        write("?");
        return;
    }
    const frac_raw: u64 = @intFromFloat(frac_mod);
    writeUint(int_part);
    if (prec == 0) return;
    write(".");
    var digits: [20]u8 = undefined;
    var j: usize = prec;
    var fp = frac_raw;
    while (j > 0) {
        j -= 1;
        digits[j] = '0' + @as(u8, @intCast(fp % 10));
        fp /= 10;
    }
    write(digits[0..prec]);
}

pub fn writeF64(v: f64) void {
    if (v != v) {
        write("NaN");
        return;
    }
    if (std.math.isInf(v)) {
        write(if (v > 0) "Inf" else "-Inf");
        return;
    }
    var n = v;
    if (n < 0.0) {
        write("-");
        n = -n;
    }
    const ip = @trunc(n);
    if (ip < 0 or ip >= std.math.pow(f64, 2.0, 64.0)) {
        write("?");
        return;
    }
    if (ip == n) {
        writeUint(@intFromFloat(ip));
        return;
    }
    writeUint(@intFromFloat(ip));
    write(".");
    var frac = n - ip;
    var digits: [10]u8 = undefined;
    var dlen: usize = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        frac *= 10.0;
        const d = @trunc(frac);
        digits[dlen] = '0' + @as(u8, @intFromFloat(d));
        dlen += 1;
        frac -= d;
    }
    while (dlen > 1 and digits[dlen - 1] == '0') dlen -= 1;
    write(digits[0..dlen]);
}

fn readFd0(buf: []u8) isize {
    if (comptime builtin.os.tag == .wasi) {
        var iov = [1]std.os.wasi.iovec_t{.{ .base = buf.ptr, .len = buf.len }};
        var nread: usize = 0;
        const rc = std.os.wasi.fd_read(0, &iov, 1, &nread);
        if (rc != .SUCCESS or nread == 0) return -1;
        return @intCast(nread);
    }
    if (comptime builtin.os.tag == .windows) {
        const STD_INPUT_HANDLE: w32.DWORD = 0xFFFFFFF6;
        const handle = GetStdHandle(STD_INPUT_HANDLE);
        var nread: w32.DWORD = 0;
        const ok = ReadFile(handle, buf.ptr, @intCast(buf.len), &nread, null);
        if (ok == .FALSE or nread == 0) return -1;
        return @intCast(nread);
    }
    const n = std.posix.read(0, buf) catch return -1;
    return if (n == 0) -1 else @intCast(n);
}

pub fn readAllBytesRaw(buf: []u8) isize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = if (read_override) |f| f(buf[total..], false) else readFd0(buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return if (total > 0) @intCast(total) else -1;
}

pub fn readBytesRaw(buf: []u8, is_line: bool) isize {
    if (read_override) |f| return f(buf, is_line);
    if (buf.len == 0) return 0;
    if (!is_line) return readFd0(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = readFd0(buf[total .. total + 1]);
        if (n <= 0) return if (total > 0) @intCast(total) else -1;
        total += 1;
        if (buf[total - 1] == '\n') break;
    }
    return @intCast(total);
}

const PrintMaxDepth = 64;

pub fn printValue(v: Value) void {
    var ancestors: [PrintMaxDepth]*const vmod.Object = undefined;
    var anc_count: usize = 0;
    printValueDepth(v, 0, &ancestors, &anc_count);
}

fn printValueDepth(v: Value, depth: u32, ancestors: *[PrintMaxDepth]*const vmod.Object, anc_count: *usize) void {
    if (depth >= PrintMaxDepth) {
        write("...");
        return;
    }
    if (vmod.decimalRawAndScale(v)) |drs| {
        var tmp: [64]u8 = undefined;
        const s = vmod.formatDecimalString(drs.raw, drs.scale, &tmp);
        write(s);
        return;
    }
    switch (v) {
        .int => |n| writeInt(n),
        .float => |n| writeF64(n),
        .decimal => unreachable,
        .rune => |r| writeUint(r),
        .boolean => |b| write(if (b) "true" else "false"),
        .string => |s| write(s.bytes),
        .error_value => |s| {
            write("error(");
            write(s.bytes);
            write(")");
        },
        .null => write("null"),
        .inline_variant => |iv| {
            const ordinal = vmod.inlineVariantOrdinal(iv);
            const iv_typ = vmod.objectAtIdx(iv.typ_idx);
            const arm = iv_typ.variant_type.arms[ordinal];
            const payload = vmod.inlineVariantPayload(iv);
            write(iv_typ.variant_type.name);
            write(".");
            write(arm.name);
            if (payload != .null) {
                write("(");
                printValueDepth(payload, depth + 1, ancestors, anc_count);
                write(")");
            }
        },
        .actor_ref => |r| {
            write("actor<");
            writeUint(r.index);
            write(":");
            writeUint(r.generation);
            write(">");
        },
        .object => |obj| {
            // Cycle detection: if this object is in the ancestor chain, emit <cycle>.
            for (ancestors[0..anc_count.*]) |a| {
                if (a == obj) {
                    write("<cycle>");
                    return;
                }
            }
            // Push this object onto the ancestor chain.
            ancestors[anc_count.*] = obj;
            anc_count.* += 1;

            switch (obj.*) {
                .dyn_string => |s| write(s),
                .string_view => |sv| write(sv.bytes),
                .array, .array_managed => |items| {
                    write("[");
                    for (items, 0..) |item, i| {
                        if (i > 0) write(", ");
                        printValueDepth(item, depth + 1, ancestors, anc_count);
                    }
                    write("]");
                },
                .array_view => |av| {
                    write("[");
                    for (av.items, 0..) |item, i| {
                        if (i > 0) write(", ");
                        printValueDepth(item, depth + 1, ancestors, anc_count);
                    }
                    write("]");
                },
                .array_capacity => |ac| {
                    write("[");
                    for (ac.backing.array_managed[0..ac.len], 0..) |item, i| {
                        if (i > 0) write(", ");
                        printValueDepth(item, depth + 1, ancestors, anc_count);
                    }
                    write("]");
                },
                .map, .map_managed => |items| {
                    write("{");
                    for (items, 0..) |item, i| {
                        if (i > 0) write(", ");
                        switch (item.key) {
                            .string => |s| write(s.bytes),
                            else => printValueDepth(item.key, depth + 1, ancestors, anc_count),
                        }
                        write(": ");
                        printValueDepth(item.value, depth + 1, ancestors, anc_count);
                    }
                    write("}");
                },
                .map_hashed => |hm| {
                    write("{");
                    for (hm.entries[0..hm.len], 0..) |item, i| {
                        if (i > 0) write(", ");
                        switch (item.key) {
                            .string => |s| write(s.bytes),
                            else => printValueDepth(item.key, depth + 1, ancestors, anc_count),
                        }
                        write(": ");
                        printValueDepth(item.value, depth + 1, ancestors, anc_count);
                    }
                    write("}");
                },
                .function => write("<func>"),
                .closure => write("<closure>"),
                .cell => write("<cell>"),
                .native_function => write("<native-func>"),
                .host_module_function => write("<host-func>"),
                .struct_type => |st| {
                    write("<struct ");
                    write(st.name);
                    write(">");
                },
                .task_type => |tt| {
                    write("<task ");
                    write(tt.name);
                    write(">");
                },
                .interface_type => |it| {
                    write("<interface ");
                    write(it.name);
                    write(">");
                },
                .named_type => |nt| {
                    write("<type ");
                    write(nt.name);
                    write(">");
                },
                .named_value => |nv| {
                    printValueDepth(nv.value, depth + 1, ancestors, anc_count);
                },
                .enum_type => |et| {
                    write("<enum ");
                    write(et.name);
                    write(">");
                },
                .enum_value => |ev| {
                    write(ev.name);
                },
                .struct_instance => |inst| {
                    write(inst.typ.struct_type.name);
                    write("{");
                    for (inst.fields, 0..) |item, i| {
                        if (i > 0) write(", ");
                        switch (item.key) {
                            .string => |s| write(s.bytes),
                            else => printValueDepth(item.key, depth + 1, ancestors, anc_count),
                        }
                        write(": ");
                        printValueDepth(item.value, depth + 1, ancestors, anc_count);
                    }
                    write("}");
                },
                .small_struct_instance => |ssi| {
                    write(ssi.typ.struct_type.name);
                    write("{");
                    for (0..@as(usize, ssi.count)) |i| {
                        if (i > 0) write(", ");
                        write(ssi.typ.struct_type.fields[i].name);
                        write(": ");
                        printValueDepth(ssi.v[i], depth + 1, ancestors, anc_count);
                    }
                    write("}");
                },
                .iterator => write("<iter>"),
                .variant_type => |vt| {
                    write("<variant ");
                    write(vt.name);
                    write(">");
                },
                .variant_ctor => |vc| {
                    write(vc.typ.variant_type.name);
                    write(".");
                    write(vc.tag);
                },
                .variant_value => |vv| {
                    write(vv.typ.variant_type.name);
                    write(".");
                    write(vv.tag);
                    if (vv.arm_fields.len > 0) {
                        write("(");
                        for (vv.arm_fields, 0..) |f, i| {
                            if (i > 0) write(", ");
                            printValueDepth(f, depth + 1, ancestors, anc_count);
                        }
                        write(")");
                    } else if (vv.payload != .null) {
                        write("(");
                        printValueDepth(vv.payload, depth + 1, ancestors, anc_count);
                        write(")");
                    }
                },
                .named_type_fn, .enum_type_fn => write("<func>"),
                .string_builder => write("<builder>"),
                .named_error_type => |net| {
                    write("<error type ");
                    write(net.name);
                    write(">");
                },
                .named_error_value => |nev| {
                    write(nev.typ.named_error_type.name);
                    write("(");
                    write(nev.msg.bytes);
                    write(")");
                },
                .bigint => |bi| {
                    const s = bi.toConst().toStringAlloc(std.heap.page_allocator, 10, .lower) catch {
                        write("<bigint>");
                        return;
                    };
                    defer std.heap.page_allocator.free(s);
                    write(s);
                },
            }

            anc_count.* -= 1;
        },
    }
}

const testing = std.testing;

var test_capture_buf: [4096]u8 = undefined;
var test_capture_len: usize = 0;
var test_error_msg: vmod.StringSlice = .{ .bytes = "" };

fn testCaptureWrite(s: []const u8) void {
    @memcpy(test_capture_buf[test_capture_len..][0..s.len], s);
    test_capture_len += s.len;
}

fn withCapture(comptime run: fn () void) []const u8 {
    test_capture_len = 0;
    setWriteOverrides(testCaptureWrite, testCaptureWrite);
    run();
    clearWriteOverrides();
    return test_capture_buf[0..test_capture_len];
}

test "writeUint/writeInt format zero, positive, negative, and i64 min" {
    try testing.expectEqualStrings("0", withCapture(struct {
        fn f() void {
            writeUint(0);
        }
    }.f));
    try testing.expectEqualStrings("12345", withCapture(struct {
        fn f() void {
            writeUint(12345);
        }
    }.f));
    try testing.expectEqualStrings("-42", withCapture(struct {
        fn f() void {
            writeInt(-42);
        }
    }.f));
    try testing.expectEqualStrings("42", withCapture(struct {
        fn f() void {
            writeInt(42);
        }
    }.f));
    // std.math.minInt(i64) has no positive i64 counterpart — formatInt's
    // negation path must widen to u64 before negating, not `-v` on the i64.
    try testing.expectEqualStrings("-9223372036854775808", withCapture(struct {
        fn f() void {
            writeInt(std.math.minInt(i64));
        }
    }.f));
    try testing.expectEqualStrings("0", withCapture(struct {
        fn f() void {
            werrUint(0);
        }
    }.f));
    try testing.expectEqualStrings("-7", withCapture(struct {
        fn f() void {
            werrInt(-7);
        }
    }.f));
}

test "writeF64 formats NaN, Inf, integers, fractions, and out-of-u64-range values" {
    try testing.expectEqualStrings("NaN", withCapture(struct {
        fn f() void {
            writeF64(std.math.nan(f64));
        }
    }.f));
    try testing.expectEqualStrings("Inf", withCapture(struct {
        fn f() void {
            writeF64(std.math.inf(f64));
        }
    }.f));
    try testing.expectEqualStrings("-Inf", withCapture(struct {
        fn f() void {
            writeF64(-std.math.inf(f64));
        }
    }.f));
    try testing.expectEqualStrings("5", withCapture(struct {
        fn f() void {
            writeF64(5.0);
        }
    }.f));
    try testing.expectEqualStrings("-5", withCapture(struct {
        fn f() void {
            writeF64(-5.0);
        }
    }.f));
    try testing.expectEqualStrings("3.5", withCapture(struct {
        fn f() void {
            writeF64(3.5);
        }
    }.f));
    // Trailing zeros in the 6-digit fractional expansion are trimmed, but
    // at least one digit always survives.
    try testing.expectEqualStrings("1.25", withCapture(struct {
        fn f() void {
            writeF64(1.25);
        }
    }.f));
    try testing.expectEqualStrings("?", withCapture(struct {
        fn f() void {
            writeF64(std.math.pow(f64, 2.0, 65.0));
        }
    }.f));
}

test "writeF64Prec formats at a fixed precision, including zero-precision and edge values" {
    try testing.expectEqualStrings("3.14", withCapture(struct {
        fn f() void {
            writeF64Prec(3.14159, 2);
        }
    }.f));
    try testing.expectEqualStrings("3", withCapture(struct {
        fn f() void {
            writeF64Prec(3.14159, 0);
        }
    }.f));
    try testing.expectEqualStrings("-2.50", withCapture(struct {
        fn f() void {
            writeF64Prec(-2.5, 2);
        }
    }.f));
    try testing.expectEqualStrings("NaN", withCapture(struct {
        fn f() void {
            writeF64Prec(std.math.nan(f64), 2);
        }
    }.f));
    try testing.expectEqualStrings("Inf", withCapture(struct {
        fn f() void {
            writeF64Prec(std.math.inf(f64), 2);
        }
    }.f));
    try testing.expectEqualStrings("?", withCapture(struct {
        fn f() void {
            writeF64Prec(std.math.pow(f64, 2.0, 65.0), 2);
        }
    }.f));
}

var test_read_chunks: []const []const u8 = &.{};
var test_read_idx: usize = 0;

fn testReadOverride(buf: []u8, is_line: bool) isize {
    _ = is_line;
    if (test_read_idx >= test_read_chunks.len) return -1;
    const chunk_bytes = test_read_chunks[test_read_idx];
    test_read_idx += 1;
    @memcpy(buf[0..chunk_bytes.len], chunk_bytes);
    return @intCast(chunk_bytes.len);
}

test "readAllBytesRaw loops the override until the buffer fills or a read fails" {
    test_read_chunks = &.{ "ab", "cd", "ef" };
    test_read_idx = 0;
    setReadOverride(testReadOverride);
    defer clearReadOverride();

    var buf: [6]u8 = undefined;
    const n = readAllBytesRaw(&buf);
    try testing.expectEqual(@as(isize, 6), n);
    try testing.expectEqualStrings("abcdef", &buf);

    // Override exhausted (-1 on the next call) with a partially filled
    // buffer still reports the partial count, not failure.
    test_read_chunks = &.{"xy"};
    test_read_idx = 0;
    var buf2: [5]u8 = undefined;
    const n2 = readAllBytesRaw(&buf2);
    try testing.expectEqual(@as(isize, 2), n2);

    // Override exhausted immediately (nothing ever read) reports -1.
    test_read_chunks = &.{};
    test_read_idx = 0;
    var buf3: [4]u8 = undefined;
    try testing.expectEqual(@as(isize, -1), readAllBytesRaw(&buf3));
}

test "readBytesRaw delegates whole-buffer reads straight to the override" {
    test_read_chunks = &.{"hello"};
    test_read_idx = 0;
    setReadOverride(testReadOverride);
    defer clearReadOverride();

    var buf: [5]u8 = undefined;
    const n = readBytesRaw(&buf, false);
    try testing.expectEqual(@as(isize, 5), n);
    try testing.expectEqualStrings("hello", &buf);
}

// Coverage-audit 2026-09: readFd0's actual POSIX read(2) path (and
// readBytesRaw's is_line=true byte-at-a-time loop that calls it directly,
// bypassing read_override) had never run — every existing test here
// installs an override first, which readBytesRaw/readAllBytesRaw both
// check before ever reaching readFd0. Temporarily redirecting the real fd 0
// to a pipe (the same std.Io.Threaded.pipe2 helper tls_common.zig's own
// FdReader/FdWriter tests use) drives the genuine syscall path without a
// read_override in place, restoring the original fd 0 afterward either way.
test "readFd0's real POSIX path: readBytesRaw reads a line and a fixed-size chunk from actual fd 0" {
    clearReadOverride(); // must not be masked by a leftover override from another test
    const dup_rc = std.posix.system.dup(0);
    try testing.expect(std.posix.errno(dup_rc) == .SUCCESS);
    const saved_stdin: std.posix.fd_t = @intCast(dup_rc);
    defer {
        _ = std.posix.system.dup2(saved_stdin, 0);
        _ = std.posix.system.close(saved_stdin);
    }

    const fds = try std.Io.Threaded.pipe2(.{});
    defer std.Io.Threaded.closeFd(fds[1]);
    try testing.expect(std.posix.errno(std.posix.system.dup2(fds[0], 0)) == .SUCCESS);
    std.Io.Threaded.closeFd(fds[0]); // fd 0 now holds an equivalent duplicate

    const payload = "first line\nrest";
    _ = std.posix.system.write(fds[1], payload.ptr, payload.len);

    var line_buf: [32]u8 = undefined;
    const line_n = readBytesRaw(&line_buf, true);
    try testing.expectEqual(@as(isize, 11), line_n);
    try testing.expectEqualStrings("first line\n", line_buf[0..11]);

    var chunk_buf: [4]u8 = undefined;
    const chunk_n = readBytesRaw(&chunk_buf, false);
    try testing.expectEqual(@as(isize, 4), chunk_n);
    try testing.expectEqualStrings("rest", &chunk_buf);
}

test "fireTrace calls the hook once per distinct line and skips repeats" {
    const Rec = struct {
        var hits: u32 = 0;
        fn hook(userdata: ?*anyopaque, handle: i32, line: i32, col: i32) callconv(.c) void {
            _ = userdata;
            _ = handle;
            _ = col;
            _ = line;
            hits += 1;
        }
    };
    Rec.hits = 0;
    try testing.expect(!traceActive());
    setTrace(Rec.hook, null, 3);
    defer clearTrace();
    try testing.expect(traceActive());

    fireTrace(1, 0);
    fireTrace(1, 5); // same line, different column: still deduped
    try testing.expectEqual(@as(u32, 1), Rec.hits);

    fireTrace(2, 0);
    try testing.expectEqual(@as(u32, 2), Rec.hits);

    clearTrace();
    try testing.expect(!traceActive());
    fireTrace(3, 0);
    try testing.expectEqual(@as(u32, 2), Rec.hits);
}

test "printValue renders scalars, strings, and null through the write override" {
    try testing.expectEqualStrings("42", withCapture(struct {
        fn f() void {
            printValue(.{ .int = 42 });
        }
    }.f));
    try testing.expectEqualStrings("true", withCapture(struct {
        fn f() void {
            printValue(.{ .boolean = true });
        }
    }.f));
    try testing.expectEqualStrings("null", withCapture(struct {
        fn f() void {
            printValue(.null);
        }
    }.f));
    test_error_msg = .{ .bytes = "boom" };
    try testing.expectEqualStrings("error(boom)", withCapture(struct {
        fn f() void {
            printValue(.{ .error_value = &test_error_msg });
        }
    }.f));
    try testing.expectEqualStrings("actor<2:7>", withCapture(struct {
        fn f() void {
            printValue(.{ .actor_ref = .{ .index = 2, .generation = 7 } });
        }
    }.f));
}

// Coverage-audit 2026-09: printValueDepth's giant switch over every .object
// kind (used whenever a script prints a composite value, e.g. std.io.println
// on an array/map/struct) had only ever been reached for scalar Value tags
// (int/bool/null/error/actor_ref) in this file's own tests — every .object
// arm was untested here. None of these Object variants need real heap
// allocation or a VMContext to construct — they're plain Zig struct
// literals — so they're cheap to build directly. withCapture's `run` must
// be a plain zero-arg fn (no captures), so the object to print for each
// case is staged through this module-level var rather than passed in.
fn emptySpec() vmod.FieldTypeSpec {
    return .{ .alts = &.{} };
}

fn minimalFunc() vmod.FuncObj {
    return .{
        .ip = 0,
        .arity = 0,
        .is_variadic = false,
        .variadic_type = emptySpec(),
        .capture_slots = &.{},
        .param_types = &.{},
        .has_typed_params = false,
        .return_types = &.{},
        .has_typed_returns = false,
    };
}

var test_print_staged: Value = .null;
fn printStaged() void {
    printValue(test_print_staged);
}
fn captureObj(obj: *vmod.Object) []const u8 {
    test_print_staged = .{ .object = obj };
    return withCapture(printStaged);
}

test "printValue renders every .object kind" {
    var struct_type_obj: vmod.Object = .{ .struct_type = .{ .name = "Point", .qualified_name = "@m:Point", .fields = &.{} } };
    try testing.expectEqualStrings("<struct Point>", captureObj(&struct_type_obj));

    var interface_type_obj: vmod.Object = .{ .interface_type = .{ .name = "Shaped", .qualified_name = "@m:Shaped", .methods = &.{} } };
    try testing.expectEqualStrings("<interface Shaped>", captureObj(&interface_type_obj));

    var named_type_obj: vmod.Object = .{ .named_type = .{ .name = "Meters", .qualified_name = "@m:Meters", .base = .float } };
    try testing.expectEqualStrings("<type Meters>", captureObj(&named_type_obj));

    var enum_type_obj: vmod.Object = .{ .enum_type = .{ .name = "Color", .qualified_name = "@m:Color", .members = &.{"red"} } };
    try testing.expectEqualStrings("<enum Color>", captureObj(&enum_type_obj));

    var variant_type_obj: vmod.Object = .{ .variant_type = .{ .name = "Shape", .qualified_name = "@m:Shape", .arms = &.{} } };
    try testing.expectEqualStrings("<variant Shape>", captureObj(&variant_type_obj));

    var named_error_type_obj: vmod.Object = .{ .named_error_type = .{ .name = "MyErr" } };
    try testing.expectEqualStrings("<error type MyErr>", captureObj(&named_error_type_obj));

    var func_obj: vmod.Object = .{ .function = minimalFunc() };
    try testing.expectEqualStrings("<func>", captureObj(&func_obj));

    var task_behavior_obj: vmod.Object = .{ .function = minimalFunc() };
    var task_type_obj: vmod.Object = .{ .task_type = .{ .name = "Worker", .qualified_name = "@m:Worker", .behavior = &task_behavior_obj } };
    try testing.expectEqualStrings("<task Worker>", captureObj(&task_type_obj));

    var closure_obj: vmod.Object = .{ .closure = .{ .func = &func_obj, .upvalues = &.{} } };
    try testing.expectEqualStrings("<closure>", captureObj(&closure_obj));

    var cell_obj: vmod.Object = .{ .cell = .{ .value = .{ .int = 1 } } };
    try testing.expectEqualStrings("<cell>", captureObj(&cell_obj));

    var native_func_obj: vmod.Object = .{ .native_function = .{ .id = 0, .arity = 0 } };
    try testing.expectEqualStrings("<native-func>", captureObj(&native_func_obj));

    var host_func_obj: vmod.Object = .{ .host_module_function = .{ .call_id = 0, .arity = 0 } };
    try testing.expectEqualStrings("<host-func>", captureObj(&host_func_obj));

    var iterator_obj: vmod.Object = .{ .iterator = .{ .kind = .array, .index = 0 } };
    try testing.expectEqualStrings("<iter>", captureObj(&iterator_obj));

    var string_builder_obj: vmod.Object = .{ .string_builder = .{ .buf = &.{}, .len = 0 } };
    try testing.expectEqualStrings("<builder>", captureObj(&string_builder_obj));

    var named_type_fn_obj: vmod.Object = .{ .named_type_fn = .{ .typ = &named_type_obj, .kind = .succ } };
    try testing.expectEqualStrings("<func>", captureObj(&named_type_fn_obj));

    var enum_type_fn_obj: vmod.Object = .{ .enum_type_fn = .{ .typ = &enum_type_obj, .kind = .from_int } };
    try testing.expectEqualStrings("<func>", captureObj(&enum_type_fn_obj));

    var enum_value_obj: vmod.Object = .{ .enum_value = .{ .typ = &enum_type_obj, .name = "red", .ordinal = 0 } };
    try testing.expectEqualStrings("red", captureObj(&enum_value_obj));

    var named_value_obj: vmod.Object = .{ .named_value = .{ .typ = &named_type_obj, .value = .{ .int = 42 } } };
    try testing.expectEqualStrings("42", captureObj(&named_value_obj));

    var variant_ctor_obj: vmod.Object = .{ .variant_ctor = .{ .typ = &variant_type_obj, .tag = "point", .ordinal = 0, .payload_type = null } };
    try testing.expectEqualStrings("Shape.point", captureObj(&variant_ctor_obj));

    var variant_value_obj: vmod.Object = .{ .variant_value = .{ .typ = &variant_type_obj, .tag = "point", .ordinal = 0, .payload = .null } };
    try testing.expectEqualStrings("Shape.point", captureObj(&variant_value_obj));

    var variant_payload_value_obj: vmod.Object = .{ .variant_value = .{ .typ = &variant_type_obj, .tag = "tag", .ordinal = 1, .payload = .{ .int = 7 } } };
    try testing.expectEqualStrings("Shape.tag(7)", captureObj(&variant_payload_value_obj));

    var arm_fields = [_]Value{ .{ .int = 1 }, .{ .int = 2 } };
    var variant_arm_fields_obj: vmod.Object = .{ .variant_value = .{ .typ = &variant_type_obj, .tag = "pair", .ordinal = 2, .payload = .null, .arm_fields = &arm_fields } };
    try testing.expectEqualStrings("Shape.pair(1, 2)", captureObj(&variant_arm_fields_obj));

    var named_error_value_obj: vmod.Object = .{ .named_error_value = .{ .typ = &named_error_type_obj, .msg = &.{ .bytes = "boom" } } };
    try testing.expectEqualStrings("MyErr(boom)", captureObj(&named_error_value_obj));

    // .map/.map_managed: string keys print bare; a non-string key (the
    // struct_instance/map else-branch below) recurses through
    // printValueDepth instead.
    var map_entries = [_]vmod.MapEntry{.{ .key = .{ .string = &.{ .bytes = "k" } }, .value = .{ .int = 9 } }};
    var map_obj: vmod.Object = .{ .map = &map_entries };
    try testing.expectEqualStrings("{k: 9}", captureObj(&map_obj));

    var map_managed_obj: vmod.Object = .{ .map_managed = &map_entries };
    try testing.expectEqualStrings("{k: 9}", captureObj(&map_managed_obj));

    var int_key_entries = [_]vmod.MapEntry{.{ .key = .{ .int = 5 }, .value = .{ .int = 9 } }};
    var int_key_map_obj: vmod.Object = .{ .map = &int_key_entries };
    try testing.expectEqualStrings("{5: 9}", captureObj(&int_key_map_obj));

    var hashed_buckets = [_]i32{ 0, -1 };
    var map_hashed_obj: vmod.Object = .{ .map_hashed = .{ .entries = &map_entries, .len = 1, .buckets = &hashed_buckets } };
    try testing.expectEqualStrings("{k: 9}", captureObj(&map_hashed_obj));

    // struct_instance (heap-backed, >4 fields) and small_struct_instance
    // (inline, <=4 fields) are two separate representations with their own
    // rendering code; struct_instance's field list also uses the same
    // string/else key-printing split as .map above, so a non-string key
    // (structurally never produced by real struct construction, but the
    // renderer handles it defensively the same way .map does) exercises
    // the same "else" branch here too.
    var struct_fields = [_]vmod.MapEntry{
        .{ .key = .{ .string = &.{ .bytes = "x" } }, .value = .{ .int = 1 } },
        .{ .key = .{ .int = 99 }, .value = .{ .int = 2 } },
    };
    var struct_instance_obj: vmod.Object = .{ .struct_instance = .{ .typ = &struct_type_obj, .fields = &struct_fields } };
    try testing.expectEqualStrings("Point{x: 1, 99: 2}", captureObj(&struct_instance_obj));

    var small_struct_obj: vmod.Object = .{ .small_struct_instance = .{
        .typ = &struct_type_obj,
        .count = 0,
        .v = .{ .null, .null, .null, .null },
    } };
    try testing.expectEqualStrings("Point{}", captureObj(&small_struct_obj));
}

// Coverage-audit 2026-09: printValueDepth's own recursion-depth guard
// (PrintMaxDepth = 64) has no test — building 64 real nested arrays would
// work but is needlessly indirect; printValueDepth is a private fn in this
// same file, so it can be called directly at the guard's boundary depth.
test "printValueDepth stops recursing and emits '...' at PrintMaxDepth" {
    try testing.expectEqualStrings("...", withCapture(struct {
        fn f() void {
            var a: [PrintMaxDepth]*const vmod.Object = undefined;
            var c: usize = 0;
            printValueDepth(.{ .int = 1 }, PrintMaxDepth, &a, &c);
        }
    }.f));
}

// Coverage-audit 2026-09: writeF64Prec's frac_mod-overflow guard is the
// sibling of the already-tested integer-part overflow, but needs the
// *fractional* scaled value to exceed u64 range — only reachable at a
// precision high enough that scale (10^prec) itself exceeds 2^64, i.e.
// prec >= 20.
test "writeF64Prec emits '?' when the requested precision overflows u64" {
    // frac_mod ~= (fractional part of v) * 10^prec must exceed 2^64
    // (~1.8e19); at prec=20 (scale=1e20) that needs a fractional part
    // over ~0.185, which 3.14159's ~0.14159 narrowly misses — 3.5's 0.5
    // clears it comfortably.
    try testing.expectEqualStrings("?", withCapture(struct {
        fn f() void {
            writeF64Prec(3.5, 20);
        }
    }.f));
}
