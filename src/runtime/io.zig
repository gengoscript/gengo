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

pub const WriteFn = *const fn (s: []const u8) void;

var write_override: ?WriteFn = null;
var werr_override: ?WriteFn = null;

pub fn setWriteOverrides(w: WriteFn, e: WriteFn) void {
    write_override = w;
    werr_override = e;
}

pub fn clearWriteOverrides() void {
    write_override = null;
    werr_override = null;
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

pub fn writeUint(v: u64) void {
    if (v == 0) {
        write("0");
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
    write(buf[0..len]);
}

pub fn writeInt(v: i64) void {
    if (v < 0) {
        write("-");
        writeUint(@intCast(-v));
    } else writeUint(@intCast(v));
}

fn werrUint(v: u64) void {
    if (v == 0) {
        werr("0");
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
    werr(buf[0..len]);
}

pub fn werrInt(v: i64) void {
    if (v < 0) {
        werr("-");
        werrUint(@intCast(-v));
    } else werrUint(@intCast(v));
}

pub fn writeF64Prec(v: f64, prec: usize) void {
    if (v != v) { write("NaN"); return; }
    if (std.math.isInf(v)) { write(if (v > 0) "Inf" else "-Inf"); return; }
    var n = v;
    if (n < 0.0) { write("-"); n = -n; }
    var scale: f64 = 1.0;
    var pi: usize = 0;
    while (pi < prec) : (pi += 1) scale *= 10.0;
    const scaled = @round(n * scale);
    const scaled_div = @trunc(scaled / scale);
    if (scaled_div < 0 or scaled_div >= std.math.pow(f64, 2.0, 64.0)) { write("?"); return; }
    const int_part: u64 = @intFromFloat(scaled_div);
    const frac_mod = @mod(scaled, scale);
    if (frac_mod < 0 or frac_mod >= std.math.pow(f64, 2.0, 64.0)) { write("?"); return; }
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

pub fn printValue(v: Value) void {
    if (vmod.decimalRawAndScale(v)) |drs| {
        var tmp: [64]u8 = undefined;
        const s = vmod.formatDecimalString(drs.raw, drs.scale, &tmp);
        write(s);
        return;
    }
    switch (v) {
        .number => |n| writeF64(n),
        .decimal => unreachable,
        .rune => |r| writeUint(r),
        .boolean => |b| write(if (b) "true" else "false"),
        .string => |s| write(s),
        .error_value => |s| {
            write("error(");
            write(s);
            write(")");
        },
        .null => write("null"),
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| write(s),
            .array, .array_managed => |items| {
                write("[");
                for (items, 0..) |item, i| {
                    if (i > 0) write(", ");
                    printValue(item);
                }
                write("]");
            },
            .map, .map_managed => |items| {
                write("{");
                for (items, 0..) |item, i| {
                    if (i > 0) write(", ");
                    switch (item.key) {
                        .string => |s| write(s),
                        else => printValue(item.key),
                    }
                    write(": ");
                    printValue(item.value);
                }
                write("}");
            },
            .map_hashed => |hm| {
                write("{");
                for (hm.entries[0..hm.len], 0..) |item, i| {
                    if (i > 0) write(", ");
                    switch (item.key) {
                        .string => |s| write(s),
                        else => printValue(item.key),
                    }
                    write(": ");
                    printValue(item.value);
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
                printValue(nv.value);
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
                        .string => |s| write(s),
                        else => printValue(item.key),
                    }
                    write(": ");
                    printValue(item.value);
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
                        printValue(f);
                    }
                    write(")");
                } else if (vv.payload != .null) {
                    write("(");
                    printValue(vv.payload);
                    write(")");
                }
            },
            .named_type_fn => write("<func>"),
            .string_builder => write("<builder>"),
        },
    }
}
