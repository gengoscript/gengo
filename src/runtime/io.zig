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
