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

pub fn timeClearCache() void {
    time_type_cache = null;
}

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
    obj.* = .{ .named_value = .{ .typ = typ, .value = .{ .float = ms } } };
    return .{ .object = obj };
}

pub fn timeGetMs(val: Value) !f64 {
    const uv = vms.unboxNamed(val);
    return switch (uv) {
        .int => |n| @floatFromInt(n),
        .float => |n| if (n == n) n else return error.TypeError,
        .object => |obj| switch (obj.*) {
            .named_value => |nv| if (nv.value == .int) @floatFromInt(nv.value.int) else if (nv.value == .float) nv.value.float else return error.TypeError,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
}

// Convert a signed day-count from epoch (1970-01-01 = 0) to year/month/day.
// Uses the algorithm from http://howardhinnant.github.io/date_algorithms.html
fn epochDayToYmd(z: i64) struct { year: i32, month: u8, day: u8 } {
    const z2 = z + 719468;
    const era: i64 = @divFloor(z2, 146097);
    const doe: u32 = @intCast(z2 - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const yr: i32 = @intCast(y + @as(i64, if (m <= 2) 1 else 0));
    return .{ .year = yr, .month = m, .day = d };
}

pub fn timeEpochMsToParts(ms: f64) struct { year: i32, month: u8, day: u8, hour: u8, min: u8, sec: u8, ms: u16, weekday: u8 } {
    if (ms < @as(f64, @floatFromInt(std.math.minInt(i64))) or ms >= std.math.pow(f64, 2.0, 63.0)) {
        return .{ .year = 0, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = 0, .ms = 0, .weekday = 0 };
    }
    const ms_int = @as(i64, @intFromFloat(ms));
    const total_secs = @divFloor(ms_int, 1000);
    const ms_rem = @mod(ms_int, 1000);
    const ms_part: u16 = @intCast(ms_rem);
    const day = @divFloor(total_secs, 86400);
    const secs_in_day: u32 = @intCast(@mod(total_secs, 86400));
    const ymd = epochDayToYmd(day);
    const hour: u8 = @intCast(secs_in_day / 3600);
    const min_sec: u32 = secs_in_day % 3600;
    const min: u8 = @intCast(min_sec / 60);
    const sec: u8 = @intCast(min_sec % 60);
    const weekday: u8 = @intCast(@mod(day + 4, 7));
    return .{
        .year = ymd.year,
        .month = ymd.month,
        .day = ymd.day,
        .hour = hour,
        .min = min,
        .sec = sec,
        .ms = ms_part,
        .weekday = weekday,
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
                    if (parts.year < 0) {
                        buf[pos] = '-';
                        pos += 1;
                        const abs: u32 = @intCast(-@as(i64, parts.year));
                        const written = try std.fmt.bufPrint(buf[pos..], "{d:0>4}", .{abs});
                        pos += written.len;
                    } else {
                        const written = try std.fmt.bufPrint(buf[pos..], "{d:0>4}", .{@as(u32, @intCast(parts.year))});
                        pos += written.len;
                    }
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
                if (si >= s.len) return error.TypeError;
                if (s[si] == '-') {
                    if (si + 5 > s.len) return error.TypeError;
                    year = std.fmt.parseInt(i32, s[si..si+5], 10) catch return error.TypeError;
                    si += 5;
                } else {
                    if (si + 4 > s.len) return error.TypeError;
                    year = std.fmt.parseInt(i32, s[si..si+4], 10) catch return error.TypeError;
                    si += 4;
                }
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
            'L' => {
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
    const era = @divFloor(y, 400);
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
    var new_d = @as(i32, p.day) + d_delta;
    // Normalize day underflow with a loop to handle multi-month spans.
    while (new_d < 1) {
        new_m -= 1;
        if (new_m < 1) { new_m += 12; new_y -= 1; }
        new_d += @as(i32, daysInMonth(new_y, @intCast(new_m)));
    }
    // Normalize day overflow with a loop to handle multi-month spans.
    var cur_dim = @as(i32, daysInMonth(new_y, @intCast(new_m)));
    while (new_d > cur_dim) {
        new_d -= cur_dim;
        new_m += 1;
        if (new_m > 12) { new_m -= 12; new_y += 1; }
        cur_dim = @as(i32, daysInMonth(new_y, @intCast(new_m)));
    }
    const epoch_secs = timeCalendarToEpochSecs(new_y, @as(u8, @intCast(new_m)), @as(u8, @intCast(new_d)), p.hour, p.min, p.sec);
    const new_ms = @as(f64, @floatFromInt(epoch_secs)) * 1000.0 + @as(f64, @floatFromInt(p.ms));
    return timeBuildObj(new_ms);
}

pub fn timeIsoWeek(ms: f64) !Value {
    const p = timeEpochMsToParts(ms);
    // ISO weekday: Mon=1 .. Sun=7 (p.weekday is Sun=0 .. Sat=6)
    const iso_dow: i64 = if (p.weekday == 0) 7 else @as(i64, p.weekday);
    // ordinal day of year (1-based)
    const doy: i64 = blk: {
        const month_starts = [_]i32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        var d: i64 = @as(i64, month_starts[p.month - 1]) + @as(i64, p.day);
        if (p.month > 2 and isLeap(p.year)) d += 1;
        break :blk d;
    };
    // Thursday of this ISO week: shift so Thursday (iso_dow=4) is the anchor
    const thursday_doy = doy + (4 - iso_dow);
    var iso_year: i32 = p.year;
    var week_thursday_doy = thursday_doy;
    if (thursday_doy < 1) {
        // Thursday is in previous year
        iso_year -= 1;
        const prev_year_days: i64 = if (isLeap(iso_year)) 366 else 365;
        week_thursday_doy = thursday_doy + prev_year_days;
    } else {
        const this_year_days: i64 = if (isLeap(p.year)) 366 else 365;
        if (thursday_doy > this_year_days) {
            iso_year += 1;
            week_thursday_doy = thursday_doy - this_year_days;
        }
    }
    // ISO week number: week containing Jan 4 is week 1; Jan 4 is always in week 1
    // Jan 1 of iso_year day-of-week → find offset of first Thursday
    const jan1_epoch_secs = timeCalendarToEpochSecs(iso_year, 1, 1, 0, 0, 0);
    const jan1_dow_raw: i64 = @intCast(@mod(@divFloor(jan1_epoch_secs, 86400) + 4, 7)); // 0=Sun..6=Sat
    const jan1_iso_dow: i64 = if (jan1_dow_raw == 0) 7 else jan1_dow_raw;
    // doy of first Thursday of iso_year
    const first_thursday_doy: i64 = 1 + @mod(4 - jan1_iso_dow, 7);
    const week: i64 = @divFloor(week_thursday_doy - first_thursday_doy, 7) + 1;

    const entries = try vmgc.vmAllocManagedSlice(MapEntry, 2);
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .map = &[_]MapEntry{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    entries[0] = .{ .key = .{ .string = "year" }, .value = .{ .int = iso_year } };
    entries[1] = .{ .key = .{ .string = "week" }, .value = .{ .int = week } };
    obj.* = .{ .map_managed = entries[0..2] };
    return .{ .object = obj };
}

pub fn parseDuration(s: []const u8) !f64 {
    if (s.len == 0) return error.ParseError;
    var i: usize = 0;
    var neg = false;

    // optional sign
    if (s[0] == '-') { neg = true; i = 1; }
    else if (s[0] == '+') { i = 1; }

    // special case: bare zero requires no unit (matches Go)
    if (i < s.len and s[i] == '0' and i + 1 == s.len) return 0.0;

    if (i >= s.len) return error.ParseError;

    var total_ms: f64 = 0;

    while (i < s.len) {
        // each component must start with a digit or '.'
        if (s[i] != '.' and (s[i] < '0' or s[i] > '9')) return error.ParseError;

        // integer part — accumulate into u64 to avoid float parsing edge cases
        var whole: u64 = 0;
        var frac_val: u64 = 0;
        var frac_exp: u64 = 1;
        var has_digits = false;

        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            has_digits = true;
            whole = whole *% 10 +% @as(u64, s[i] - '0');
        }

        // optional fractional part; "1.s" is valid (trailing dot, no frac digits)
        if (i < s.len and s[i] == '.') {
            i += 1;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                has_digits = true;
                if (frac_exp < 1_000_000_000_000_000_000) {
                    frac_val = frac_val * 10 + @as(u64, s[i] - '0');
                    frac_exp *= 10;
                }
            }
        }

        if (!has_digits) return error.ParseError;

        const num: f64 = @as(f64, @floatFromInt(whole)) +
            @as(f64, @floatFromInt(frac_val)) / @as(f64, @floatFromInt(frac_exp));

        // unit: scan until next digit or '.'; works for ASCII and multi-byte UTF-8
        const unit_start = i;
        while (i < s.len) {
            const b = s[i];
            if ((b >= '0' and b <= '9') or b == '.') break;
            i += 1;
        }
        if (i == unit_start) return error.ParseError; // missing unit

        const unit = s[unit_start..i];
        const multiplier: f64 =
            if (std.mem.eql(u8, unit, "ns"))   1.0 / 1_000_000.0
            else if (std.mem.eql(u8, unit, "us") or
                     std.mem.eql(u8, unit, "\xc2\xb5s") or  // µs  U+00B5
                     std.mem.eql(u8, unit, "\xce\xbcs"))     // μs  U+03BC
                1.0 / 1_000.0
            else if (std.mem.eql(u8, unit, "ms"))   1.0
            else if (std.mem.eql(u8, unit, "s"))    1_000.0
            else if (std.mem.eql(u8, unit, "m"))    60_000.0
            else if (std.mem.eql(u8, unit, "h"))    3_600_000.0
            else return error.ParseError;

        total_ms += num * multiplier;
    }

    return if (neg) -total_ms else total_ms;
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
            entries[0] = .{ .key = .{ .string = "year" }, .value = .{ .int = p.year } };
            entries[1] = .{ .key = .{ .string = "month" }, .value = .{ .int = p.month } };
            entries[2] = .{ .key = .{ .string = "day" }, .value = .{ .int = p.day } };
            entries[3] = .{ .key = .{ .string = "hour" }, .value = .{ .int = p.hour } };
            entries[4] = .{ .key = .{ .string = "min" }, .value = .{ .int = p.min } };
            entries[5] = .{ .key = .{ .string = "sec" }, .value = .{ .int = p.sec } };
            entries[6] = .{ .key = .{ .string = "ms" }, .value = .{ .int = p.ms } };
            entries[7] = .{ .key = .{ .string = "weekday" }, .value = .{ .int = p.weekday } };
            obj.* = .{ .map_managed = entries[0..field_count] };
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = obj });
        },
        .time_since => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = timeNowMs() - ms });
        },
        .time_sub => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const recv = vms.vmState().stack[top - 2];
            const other = vms.vmState().stack[top - 1];
            const ms_a = try timeGetMs(recv);
            const ms_b = try timeGetMs(other);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = ms_a - ms_b });
        },
        .time_unix => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .int = @floor(ms / 1000) });
        },
        .time_unix_ms => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = ms });
        },
        .time_until => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = ms - timeNowMs() });
        },
        .time_parse_duration => {

            if (argc != nf.arity) return error.ArityMismatch;
            const s = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const ms = try parseDuration(s);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = ms });
        },
        .time_iso_week => {

            if (argc != nf.arity) return error.ArityMismatch;
            const recv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const ms = try timeGetMs(recv);
            const out = try timeIsoWeek(ms);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        else => {},
    }
}
