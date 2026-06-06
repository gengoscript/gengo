const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

const w32 = std.os.windows;

extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *w32.FILETIME) callconv(.winapi) void;

const TimeTypeQualifiedName = "@std.time.obj";
var time_type_cache: ?*Object = null;

pub fn timeGetType() !*Object {
    if (time_type_cache) |t| return t;
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    obj.* = .{ .named_type = .{
        .name = "Time",
        .qualified_name = TimeTypeQualifiedName,
        .base = .int,
    } };
    time_type_cache = obj;
    return obj;
}

pub fn timeBuildObj(ms: f64) !Value {
    const obj = try vmgc.vmAllocObject();
    const typ = try timeGetType();
    obj.* = .{ .named_value = .{ .typ = typ, .value = .{ .number = ms } } };
    return .{ .object = obj };
}

pub fn timeGetMs(val: Value) !f64 {
    const uv = vms.unboxNamed(val);
    return switch (uv) {
        .number => |n| if (n == n) n else return error.TypeError,
        .object => |obj| switch (obj.*) {
            .named_value => |nv| if (nv.value == .number) nv.value.number else return error.TypeError,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
}

pub fn timeEpochMsToParts(ms: f64) struct { year: i32, month: u8, day: u8, hour: u8, min: u8, sec: u8, ms: u16, weekday: u8 } {
    const ms_int = @as(i64, @intFromFloat(ms));
    const total_secs = @divFloor(ms_int, 1000);
    const ms_part = @as(u16, @intCast(@rem(ms_int, 1000)));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(total_secs)) };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
        .hour = day_secs.getHoursIntoDay(),
        .min = day_secs.getMinutesIntoHour(),
        .sec = day_secs.getSecondsIntoMinute(),
        .ms = ms_part,
        .weekday = @as(u8, @intCast((epoch_day.day + 4) % 7)),
    };
}

pub fn timeFormatStr(ms: f64, fmt: []const u8) !Value {
    const parts = timeEpochMsToParts(ms);
    const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const weekdays_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    const months_short = [_][]const u8{ "", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            const verb = fmt[i + 1];
            i += 2;
            switch (verb) {
                'Y' => {
                    const written = try std.fmt.bufPrint(buf[pos..], "{d:0>4}", .{@as(u32, @intCast(parts.year))});
                    pos += written.len;
                },
                'm' => {
                    const written = try std.fmt.bufPrint(buf[pos..], "{d:0>2}", .{@as(u32, parts.month)});
                    pos += written.len;
                },
                'd' => {
                    const written = try std.fmt.bufPrint(buf[pos..], "{d:0>2}", .{@as(u32, parts.day)});
                    pos += written.len;
                },
                'H' => {
                    const written = try std.fmt.bufPrint(buf[pos..], "{d:0>2}", .{@as(u32, parts.hour)});
                    pos += written.len;
                },
                'M' => {
                    const written = try std.fmt.bufPrint(buf[pos..], "{d:0>2}", .{@as(u32, parts.min)});
                    pos += written.len;
                },
                'S' => {
                    const written = try std.fmt.bufPrint(buf[pos..], "{d:0>2}", .{@as(u32, parts.sec)});
                    pos += written.len;
                },
                'L' => {
                    const written = try std.fmt.bufPrint(buf[pos..], "{d:0>3}", .{@as(u32, parts.ms)});
                    pos += written.len;
                },
                'A' => {
                    const s = weekdays[parts.weekday];
                    @memcpy(buf[pos..][0..s.len], s);
                    pos += s.len;
                },
                'a' => {
                    const s = weekdays_short[parts.weekday];
                    @memcpy(buf[pos..][0..s.len], s);
                    pos += s.len;
                },
                'B' => {
                    const s = months[parts.month];
                    @memcpy(buf[pos..][0..s.len], s);
                    pos += s.len;
                },
                'b' => {
                    const s = months_short[parts.month];
                    @memcpy(buf[pos..][0..s.len], s);
                    pos += s.len;
                },
                '%' => {
                    buf[pos] = '%';
                    pos += 1;
                },
                else => return error.TypeError,
            }
        } else {
            buf[pos] = fmt[i];
            pos += 1;
            i += 1;
        }
    }
    return vmgc.makeDynString(buf[0..pos]);
}

pub fn timeParseStr(s: []const u8, fmt: []const u8) !Value {
    var year: i32 = 1970;
    var month: u8 = 1;
    var day: u8 = 1;
    var hour: u8 = 0;
    var min: u8 = 0;
    var sec: u8 = 0;
    var ms: u16 = 0;
    var si: usize = 0;
    var fi: usize = 0;
    while (fi < fmt.len) {
        if (fmt[fi] != '%') {
            if (si >= s.len or s[si] != fmt[fi]) return error.TypeError;
            si += 1;
            fi += 1;
            continue;
        }
        fi += 1;
        if (fi >= fmt.len) return error.TypeError;
        const spec = fmt[fi];
        fi += 1;
        switch (spec) {
            'Y' => {
                if (si + 4 > s.len) return error.TypeError;
                year = std.fmt.parseInt(i32, s[si..si+4], 10) catch return error.TypeError;
                si += 4;
            },
            'y' => {
                if (si + 2 > s.len) return error.TypeError;
                const cy = std.fmt.parseInt(u8, s[si..si+2], 10) catch return error.TypeError;
                year = 2000 + @as(i32, cy);
                si += 2;
            },
            'm' => {
                if (si + 2 > s.len) return error.TypeError;
                month = std.fmt.parseInt(u8, s[si..si+2], 10) catch return error.TypeError;
                if (month < 1 or month > 12) return error.RangeError;
                si += 2;
            },
            'd' => {
                if (si + 2 > s.len) return error.TypeError;
                day = std.fmt.parseInt(u8, s[si..si+2], 10) catch return error.TypeError;
                if (day < 1 or day > 31) return error.RangeError;
                si += 2;
            },
            'H' => {
                if (si + 2 > s.len) return error.TypeError;
                hour = std.fmt.parseInt(u8, s[si..si+2], 10) catch return error.TypeError;
                if (hour > 23) return error.RangeError;
                si += 2;
            },
            'M' => {
                if (si + 2 > s.len) return error.TypeError;
                min = std.fmt.parseInt(u8, s[si..si+2], 10) catch return error.TypeError;
                if (min > 59) return error.RangeError;
                si += 2;
            },
            'S' => {
                if (si + 2 > s.len) return error.TypeError;
                sec = std.fmt.parseInt(u8, s[si..si+2], 10) catch return error.TypeError;
                if (sec > 59) return error.RangeError;
                si += 2;
            },
            '3' => {
                if (si + 3 > s.len) return error.TypeError;
                ms = std.fmt.parseInt(u16, s[si..si+3], 10) catch return error.TypeError;
                si += 3;
            },
            'B' => {
                const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
                var found = false;
                for (month_names, 1..) |mn, idx| {
                    if (si + mn.len <= s.len and std.mem.eql(u8, s[si..][0..mn.len], mn)) {
                        month = @as(u8, @intCast(idx));
                        si += mn.len;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.TypeError;
            },
            'a' => {
                const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
                var found = false;
                for (day_names, 0..) |dn, idx| {
                    if (si + dn.len <= s.len and std.mem.eql(u8, s[si..][0..dn.len], dn)) {
                        si += dn.len;
                        found = true;
                        _ = idx;
                        break;
                    }
                }
                if (!found) return error.TypeError;
            },
            'W' => {
                if (si + 2 > s.len) return error.TypeError;
                si += 2;
            },
            else => return error.TypeError,
        }
    }
    if (si != s.len) return error.TypeError;
    const epoch_secs = timeCalendarToEpochSecs(year, month, day, hour, min, sec);
    const ms_f = @as(f64, @floatFromInt(epoch_secs)) * 1000.0 + @as(f64, @floatFromInt(ms));
    return timeBuildObj(ms_f);
}

fn parseDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        else => error.TypeError,
    };
}

pub fn timeCalendarToEpochSecs(year: i32, month: u8, day: u8, hour: u8, min: u8, sec: u8) i64 {
    var y: i32 = year;
    var m: i32 = @as(i32, month);
    if (m <= 2) { y -= 1; m += 12; }
    const era = @divTrunc(y, 400);
    const yoe = y - era * 400;
    const doy = @divTrunc(153 * (m - 3) + 2, 5) + @as(i32, day) - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days = era * 146097 + @as(i64, doe) - 719468;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
}

pub fn timeNowMs() f64 {
    if (comptime builtin.os.tag == .wasi) {
        var ns: std.os.wasi.timestamp_t = 0;
        if (std.os.wasi.clock_time_get(.REALTIME, 1, &ns) == .SUCCESS) {
            return @floatFromInt(ns / 1_000_000);
        }
        return 0;
    }
    if (comptime builtin.os.tag == .windows) {
        var ft: w32.FILETIME = undefined;
        GetSystemTimeAsFileTime(&ft);
        const raw = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
        const unix_epoch_diff: u64 = 11644473600000000000;
        const total_ms = if (raw >= unix_epoch_diff)
            @divFloor(raw - unix_epoch_diff, 10000)
        else
            0;
        return @floatFromInt(total_ms);
    }
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    const total_ms = @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
    return @floatFromInt(total_ms);
}

fn isLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(year)) 29 else 28,
        else => 30,
    };
}

pub fn timeAddDate(ms: f64, y_delta: i32, m_delta: i32, d_delta: i32) !Value {
    const p = timeEpochMsToParts(ms);
    var new_y = p.year + y_delta;
    var new_m = @as(i32, p.month) + m_delta;
    while (new_m > 12) { new_m -= 12; new_y += 1; }
    while (new_m < 1) { new_m += 12; new_y -= 1; }
    const new_m_u8 = @as(u8, @intCast(new_m));
    const dim = daysInMonth(new_y, new_m_u8);
    var new_d = @as(i32, p.day) + d_delta;
    if (new_d < 1) {
        new_m -= 1;
        if (new_m < 1) { new_m += 12; new_y -= 1; }
        const prev_dim = daysInMonth(new_y, @as(u8, @intCast(new_m)));
        new_d += prev_dim;
    } else if (new_d > dim) {
        new_d -= dim;
        new_m += 1;
        if (new_m > 12) { new_m -= 12; new_y += 1; }
    }
    const epoch_secs = timeCalendarToEpochSecs(new_y, @as(u8, @intCast(new_m)), @as(u8, @intCast(new_d)), p.hour, p.min, p.sec);
    const new_ms = @as(f64, @floatFromInt(epoch_secs)) * 1000.0 + @as(f64, @floatFromInt(p.ms));
    return timeBuildObj(new_ms);
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .time_add_date => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 4];
            const y_v = vms.vmState().stack[top - 3];
            const m_v = vms.vmState().stack[top - 2];
            const d_v = vms.vmState().stack[top - 1];
            const ms = try timeGetMs(recv);
            const y = try vms.valueAsInt(y_v);
            const m = try vms.valueAsInt(m_v);
            const d = try vms.valueAsInt(d_v);
            const out = try timeAddDate(ms, @intCast(y), @intCast(m), @intCast(d));
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .time_add_h => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const n = try vms.valueAsNumber(vms.vmState().stack[top - 1]);
            const ms = try timeGetMs(recv);
            if (@trunc(n) != n) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try timeBuildObj(ms + n * 3_600_000));
        },
        .time_add_m => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const n = try vms.valueAsNumber(vms.vmState().stack[top - 1]);
            const ms = try timeGetMs(recv);
            if (@trunc(n) != n) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try timeBuildObj(ms + n * 60_000));
        },
        .time_add_ms => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const n = try vms.valueAsNumber(vms.vmState().stack[top - 1]);
            const ms = try timeGetMs(recv);
            if (@trunc(n) != n) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try timeBuildObj(ms + n));
        },
        .time_add_s => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const n = try vms.valueAsNumber(vms.vmState().stack[top - 1]);
            const ms = try timeGetMs(recv);
            if (@trunc(n) != n) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try timeBuildObj(ms + n * 1000));
        },
        .time_after => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try timeGetMs(recv);
            const ms_b = try timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = ms_a > ms_b });
        },
        .time_before => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try timeGetMs(recv);
            const ms_b = try timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = ms_a < ms_b });
        },
        .time_equal => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try timeGetMs(recv);
            const ms_b = try timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = ms_a == ms_b });
        },
        .time_format => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const fmt = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const ms = try timeGetMs(recv);
            const out = try timeFormatStr(ms, fmt);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .time_from_unix => {

            if (argc != nf.arity) return error.ArityMismatch;
            const sec = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (@trunc(sec) != sec) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try timeBuildObj(sec * 1000));
        },
        .time_from_unix_ms => {

            if (argc != nf.arity) return error.ArityMismatch;
            const ms = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            if (@trunc(ms) != ms) return error.TypeError;
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(try timeBuildObj(ms));
        },
        .time_is_zero => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = ms == 0 });
        },
        .time_now => {

            if (argc != 0) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(try timeBuildObj(timeNowMs()));
        },
        .time_parse => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const s = try vms.asStringValue(vms.vmState().stack[top - 2]);
            const fmt = try vms.asStringValue(vms.vmState().stack[top - 1]);
            const out = try timeParseStr(s, fmt);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .time_parts => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            const p = timeEpochMsToParts(ms);
            const field_count = 8;
            const entries = try vmgc.vmAllocManagedSlice(MapEntry, field_count);
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .map = &[_]MapEntry{} };
            try vms.pushTempRoot(.{ .object = obj });
            defer vms.popTempRoot();
            entries[0] = .{ .key = .{ .string = "year" }, .value = .{ .number = @floatFromInt(p.year) } };
            entries[1] = .{ .key = .{ .string = "month" }, .value = .{ .number = @floatFromInt(p.month) } };
            entries[2] = .{ .key = .{ .string = "day" }, .value = .{ .number = @floatFromInt(p.day) } };
            entries[3] = .{ .key = .{ .string = "hour" }, .value = .{ .number = @floatFromInt(p.hour) } };
            entries[4] = .{ .key = .{ .string = "min" }, .value = .{ .number = @floatFromInt(p.min) } };
            entries[5] = .{ .key = .{ .string = "sec" }, .value = .{ .number = @floatFromInt(p.sec) } };
            entries[6] = .{ .key = .{ .string = "ms" }, .value = .{ .number = @floatFromInt(p.ms) } };
            entries[7] = .{ .key = .{ .string = "weekday" }, .value = .{ .number = @floatFromInt(p.weekday) } };
            obj.* = .{ .map_managed = entries[0..field_count] };
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = obj });
        },
        .time_since => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = timeNowMs() - ms });
        },
        .time_sub => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try timeGetMs(recv);
            const ms_b = try timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = ms_a - ms_b });
        },
        .time_unix => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @floor(ms / 1000) });
        },
        .time_unix_ms => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = ms });
        },
        .time_until => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = ms - timeNowMs() });
        },
        else => {},
    }
}
