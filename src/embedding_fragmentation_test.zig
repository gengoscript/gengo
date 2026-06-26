const std = @import("std");
const frag = @import("embedding_fragmentation.zig");

test "long-lived fragmentation lane records progress and heap stats" {
    const stats = try frag.run(.{
        .lane = .long_lived,
        .iterations = 128,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 1024,
        .sample_every = 16,
    });

    try std.testing.expect(stats.completed_iterations > 0);
    try std.testing.expect(stats.sample_count > 0);
    try std.testing.expect(stats.peak_used_bytes > 0);
}

test "reset-per-call lane completes constrained churn without failure" {
    const stats = try frag.run(.{
        .lane = .reset_per_call,
        .iterations = 128,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 1024,
        .sample_every = 16,
    });

    try std.testing.expectEqual(frag.Outcome.completed, stats.outcome);
    try std.testing.expectEqual(@as(usize, 128), stats.completed_iterations);
    try std.testing.expect(stats.sample_count > 0);
}

test "fragmentation harness accepts custom policy source under gc stress" {
    const stats = try frag.run(.{
        .lane = .reset_per_call,
        .iterations = 8,
        .heap_size_bytes = 256 * 1024,
        .max_objects = 512,
        .sample_every = 1,
        .gc_stress = true,
        .policy_source =
        \\func acl(client string, user string, topic string, access string) bool {
        \\    return client != "" and user != "" and topic != "" and access != ""
        \\}
        ,
    });

    try std.testing.expectEqual(frag.Outcome.completed, stats.outcome);
    try std.testing.expectEqual(@as(usize, 8), stats.completed_iterations);
    try std.testing.expect(stats.sample_count >= 8);
}
