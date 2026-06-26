const std = @import("std");
const frag = @import("embedding_fragmentation.zig");

fn printUsage() void {
    std.debug.print("usage: embedding-frag-runner [iterations] [heap_kib]\n", .{});
}

fn printStats(stats: frag.Stats) void {
    std.debug.print(
        "{s}: outcome={s} completed={d}/{d} peak_used={d} peak_free_list={d} min_largest_block={d} peak_live_objects={d}",
        .{
            @tagName(stats.lane),
            @tagName(stats.outcome),
            stats.completed_iterations,
            stats.iterations_requested,
            stats.peak_used_bytes,
            stats.peak_free_list_bytes,
            stats.min_largest_block,
            stats.peak_live_objects,
        },
    );
    if (stats.failed_iteration) |failed| {
        std.debug.print(" failed_iteration={d}", .{failed});
    }
    if (stats.failure_kind) |kind| {
        std.debug.print(" failure_kind={t}", .{kind});
    }
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var argv_storage: [8][]const u8 = undefined;
    var arg_count: usize = 0;
    for (init.args.vector) |arg| {
        if (arg_count >= argv_storage.len) break;
        argv_storage[arg_count] = std.mem.span(arg);
        arg_count += 1;
    }
    const args = argv_storage[0..arg_count];

    if (args.len > 3) {
        printUsage();
        return error.InvalidArgs;
    }

    const iterations = if (args.len >= 2) try std.fmt.parseUnsigned(usize, args[1], 10) else 4096;
    const heap_kib = if (args.len >= 3) try std.fmt.parseUnsigned(usize, args[2], 10) else 256;
    const heap_size_bytes = heap_kib * 1024;

    const long_lived = try frag.run(.{
        .lane = .long_lived,
        .iterations = iterations,
        .heap_size_bytes = heap_size_bytes,
        .max_objects = 1024,
        .sample_every = 64,
    });
    printStats(long_lived);

    const reset_per_call = try frag.run(.{
        .lane = .reset_per_call,
        .iterations = iterations,
        .heap_size_bytes = heap_size_bytes,
        .max_objects = 1024,
        .sample_every = 64,
    });
    printStats(reset_per_call);

    if (reset_per_call.outcome != .completed) {
        return error.ResetLaneFailed;
    }

    if (long_lived.outcome == .runtime_oom) {
        std.debug.print("recommendation: keep reset-per-call as the default stateless embedding pattern; compaction can stay deferred while workloads are measured.\n", .{});
    } else if (long_lived.outcome == .completed) {
        std.debug.print("recommendation: size-class isolation survives this workload; keep reset-per-call documented as the simple stateless escape hatch and defer compaction.\n", .{});
    } else {
        return error.LongLivedLaneFailed;
    }
}
