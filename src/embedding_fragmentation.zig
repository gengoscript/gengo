const std = @import("std");
const api = @import("runtime/api.zig");
const heap = @import("runtime/heap.zig");
const value = @import("lang/value.zig");

const StringSlice = value.StringSlice;
const Value = value.Value;

pub const Lane = enum {
    long_lived,
    reset_per_call,
};

pub const Outcome = enum {
    completed,
    runtime_oom,
    runtime_error,
    compile_error,
};

pub const Options = struct {
    lane: Lane,
    iterations: usize = 2048,
    heap_size_bytes: usize = 256 * 1024,
    max_objects: usize = 1024,
    sample_every: usize = 64,
    max_ops: ?u64 = 200_000,
};

pub const Stats = struct {
    lane: Lane,
    iterations_requested: usize,
    completed_iterations: usize = 0,
    outcome: Outcome = .completed,
    failed_iteration: ?usize = null,
    failure_kind: ?anyerror = null,
    sample_count: usize = 0,
    peak_used_bytes: usize = 0,
    peak_free_list_bytes: usize = 0,
    min_largest_block: usize = 0,
    last_used_bytes: usize = 0,
    last_free_list_bytes: usize = 0,
    last_largest_block: usize = 0,
    peak_live_objects: usize = 0,
};

const policy_source =
    \\std := import("std")
    \\tmpl := std.template
    \\
    \\func acl(client string, user string, topic string, access string) bool {
    \\    items := []
    \\    items = std.core.append(items, client)
    \\    items = std.core.append(items, topic)
    \\    if std.core.bytelen(topic) > 18 {
    \\        items = std.core.append(items, user)
    \\    }
    \\    if std.core.bytelen(topic) > 24 {
    \\        items = std.core.append(items, access)
    \\    }
    \\    if std.core.bytelen(topic) > 32 {
    \\        items = std.core.append(items, client + ":" + user)
    \\    }
    \\
    \\    out := tmpl.render("{{range .items}}[{{.}}]{{end}}", {"items": items})
    \\
    \\    return std.core.bytelen(out) > std.core.bytelen(access)
    \\}
;

pub fn run(opts: Options) !Stats {
    var rt = try api.Runtime.init(.{
        .allow_io = false,
        .heap_size_bytes = opts.heap_size_bytes,
        .max_objects = opts.max_objects,
        .max_ops = opts.max_ops,
    });
    defer rt.deinit();

    var stats = Stats{
        .lane = opts.lane,
        .iterations_requested = opts.iterations,
        .min_largest_block = std.math.maxInt(usize),
    };
    const prev_heap = heap.g_state;
    defer heap.setActive(prev_heap);

    if (opts.lane == .long_lived) {
        switch (rt.run(policy_source)) {
            .ok => {},
            .compile_error => |e| {
                stats.outcome = .compile_error;
                stats.failure_kind = e.kind;
                return stats;
            },
            .runtime_error => |e| {
                stats.outcome = classifyRuntimeError(e.kind);
                stats.failure_kind = e.kind;
                return stats;
            },
        }
    }

    const sample_every = if (opts.sample_every == 0) 1 else opts.sample_every;
    var topic_buf: [128]u8 = undefined;
    var client_buf: [32]u8 = undefined;
    var user_buf: [32]u8 = undefined;

    var i: usize = 0;
    while (i < opts.iterations) : (i += 1) {
        if (opts.lane == .reset_per_call) {
            rt.reset();
            switch (rt.run(policy_source)) {
                .ok => {},
                .compile_error => |e| {
                    stats.outcome = .compile_error;
                    stats.failure_kind = e.kind;
                    stats.failed_iteration = i;
                    sample(&rt, &stats);
                    return stats;
                },
                .runtime_error => |e| {
                    stats.outcome = classifyRuntimeError(e.kind);
                    stats.failure_kind = e.kind;
                    stats.failed_iteration = i;
                    sample(&rt, &stats);
                    return stats;
                },
            }
        }

        const client = try std.fmt.bufPrint(&client_buf, "client-{d}", .{i % 11});
        const user = try std.fmt.bufPrint(&user_buf, "user-{d}", .{i % 7});
        const topic = try buildTopic(&topic_buf, user, i);
        const access = switch (i % 4) {
            0 => "read",
            1 => "write",
            2 => "subscribe",
            else => "unsubscribe",
        };

        const client_ss: StringSlice = .{ .bytes = client };
        const user_ss: StringSlice = .{ .bytes = user };
        const topic_ss: StringSlice = .{ .bytes = topic };
        const access_ss: StringSlice = .{ .bytes = access };

        const result = rt.call("acl", &.{
            .{ .string = &client_ss },
            .{ .string = &user_ss },
            .{ .string = &topic_ss },
            .{ .string = &access_ss },
        });
        switch (result) {
            .ok => |v| {
                if (v != .boolean) {
                    stats.outcome = .runtime_error;
                    stats.failed_iteration = i;
                    sample(&rt, &stats);
                    return stats;
                }
            },
            .runtime_error => |e| {
                stats.outcome = classifyRuntimeError(e.kind);
                stats.failure_kind = e.kind;
                stats.failed_iteration = i;
                sample(&rt, &stats);
                return stats;
            },
        }

        stats.completed_iterations = i + 1;
        if ((i + 1) % sample_every == 0) {
            sample(&rt, &stats);
        }
    }

    sample(&rt, &stats);
    if (stats.min_largest_block == std.math.maxInt(usize)) {
        stats.min_largest_block = 0;
    }
    return stats;
}

fn classifyRuntimeError(err: anyerror) Outcome {
    return if (err == error.OutOfMemory or err == error.AllocationTooLarge) .runtime_oom else .runtime_error;
}

fn sample(rt: *api.Runtime, stats: *Stats) void {
    heap.setActive(&rt.inner.heap_state);
    const info = heap.fragmentationInfo();
    const used = heap.usedBytes();
    const free_list_bytes = heap.totalFreeListBytes();
    const live_objects = heap.liveObjectCount();

    stats.sample_count += 1;
    if (used > stats.peak_used_bytes) stats.peak_used_bytes = used;
    if (free_list_bytes > stats.peak_free_list_bytes) stats.peak_free_list_bytes = free_list_bytes;
    if (live_objects > stats.peak_live_objects) stats.peak_live_objects = live_objects;
    if (info.largest_block < stats.min_largest_block) stats.min_largest_block = info.largest_block;
    stats.last_used_bytes = used;
    stats.last_free_list_bytes = free_list_bytes;
    stats.last_largest_block = info.largest_block;
}

fn buildTopic(buf: []u8, user: []const u8, iteration: usize) ![]const u8 {
    const pattern = switch (iteration % 6) {
        0 => "alerts",
        1 => "metrics/system",
        2 => "public/events",
        3 => "devices/edge/updates",
        4 => "tenant",
        else => "shadow/config/history",
    };
    return std.fmt.bufPrint(buf, "tenant/{s}/{s}/{d}/{d}", .{ user, pattern, iteration % 17, iteration % 97 });
}
