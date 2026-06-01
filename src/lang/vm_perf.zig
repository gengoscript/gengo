const std = @import("std");
const io = @import("../runtime/io.zig");
const Op = @import("op.zig").Op;
const build_options = @import("build_options");

pub const perf_enabled: bool = build_options.perf;

const OpCount = std.meta.fields(Op).len;

pub const PerfCounters = struct {
    op_counts:           [OpCount]u64          = [_]u64{0}                        ** OpCount,
    op_pair_counts:      [OpCount][OpCount]u64 = [_][OpCount]u64{[_]u64{0} ** OpCount} ** OpCount,
    string_concat_bytes: u64                   = 0,
    map_probe_total:     u64                   = 0,
    map_probe_ops:       u64                   = 0,
    gc_marked_total:     u64                   = 0,
    gc_swept_total:      u64                   = 0,
    hostcall_counts:     [256]u64              = [_]u64{0}                        ** 256,
    prev_op:             u8                    = 0xFF,
};

var g_counters: PerfCounters = .{};

pub fn counters() *PerfCounters { return &g_counters; }
pub fn resetCounters() void { g_counters = .{}; }

pub inline fn countOp(op_raw: u8) void {
    if (!perf_enabled) return;
    g_counters.op_counts[op_raw] += 1;
    const prev = g_counters.prev_op;
    if (prev != 0xFF) g_counters.op_pair_counts[prev][op_raw] += 1;
    g_counters.prev_op = op_raw;
}

// Call at ret/halt to avoid counting cross-function pairs.
pub inline fn breakOpChain() void {
    if (!perf_enabled) return;
    g_counters.prev_op = 0xFF;
}

pub inline fn countStringConcat(bytes: usize) void {
    if (!perf_enabled) return;
    g_counters.string_concat_bytes += @intCast(bytes);
}

pub inline fn countMapProbe(probes: usize) void {
    if (!perf_enabled) return;
    g_counters.map_probe_total += @intCast(probes);
    g_counters.map_probe_ops += 1;
}

pub inline fn countGCSweep(marked: usize, swept: usize) void {
    if (!perf_enabled) return;
    g_counters.gc_marked_total += @intCast(marked);
    g_counters.gc_swept_total += @intCast(swept);
}

pub inline fn countHostcall(id: u8) void {
    if (!perf_enabled) return;
    g_counters.hostcall_counts[id] += 1;
}

fn writeU64Err(v: u64) void {
    if (v == 0) { io.werr("0"); return; }
    var buf: [24]u8 = undefined;
    var n = v;
    var len: usize = 0;
    while (n > 0) : (n /= 10) { buf[len] = '0' + @as(u8, @intCast(n % 10)); len += 1; }
    var i: usize = 0;
    while (i < len / 2) : (i += 1) {
        const t = buf[i]; buf[i] = buf[len - 1 - i]; buf[len - 1 - i] = t;
    }
    io.werr(buf[0..len]);
}

pub fn printSummary(gc_runs: u64, gc_time_ns: u64, alloc_objs: u64, alloc_slices: u64, alloc_bytes_calls: u64) void {
    if (!perf_enabled) return;
    const c = &g_counters;

    io.werr("PERF:gc_runs=");             writeU64Err(gc_runs);           io.werr("\n");
    io.werr("PERF:gc_time_ns=");          writeU64Err(gc_time_ns);        io.werr("\n");
    io.werr("PERF:gc_marked_total=");     writeU64Err(c.gc_marked_total); io.werr("\n");
    io.werr("PERF:gc_swept_total=");      writeU64Err(c.gc_swept_total);  io.werr("\n");
    io.werr("PERF:alloc_objects=");       writeU64Err(alloc_objs);        io.werr("\n");
    io.werr("PERF:alloc_managed_slices=");writeU64Err(alloc_slices);      io.werr("\n");
    io.werr("PERF:alloc_managed_bytes_calls="); writeU64Err(alloc_bytes_calls); io.werr("\n");
    io.werr("PERF:string_concat_bytes="); writeU64Err(c.string_concat_bytes); io.werr("\n");
    io.werr("PERF:map_probe_total=");     writeU64Err(c.map_probe_total); io.werr("\n");
    io.werr("PERF:map_probe_ops=");       writeU64Err(c.map_probe_ops);   io.werr("\n");

    const op_names = comptime blk: {
        const fields = std.meta.fields(Op);
        var names: [OpCount][]const u8 = undefined;
        for (fields, 0..) |f, i| names[i] = f.name;
        break :blk names;
    };

    for (0..OpCount) |i| {
        const cnt = c.op_counts[i];
        if (cnt > 0) {
            io.werr("PERF:op:"); io.werr(op_names[i]); io.werr("="); writeU64Err(cnt); io.werr("\n");
        }
    }

    for (0..OpCount) |a| {
        for (0..OpCount) |b| {
            const cnt = c.op_pair_counts[a][b];
            if (cnt > 0) {
                io.werr("PERF:pair:"); io.werr(op_names[a]); io.werr(","); io.werr(op_names[b]);
                io.werr("="); writeU64Err(cnt); io.werr("\n");
            }
        }
    }

    for (0..256) |hci| {
        const cnt = c.hostcall_counts[hci];
        if (cnt == 0) continue;
        io.werr("PERF:hostcall:"); writeU64Err(@intCast(hci)); io.werr("="); writeU64Err(cnt); io.werr("\n");
    }
}
