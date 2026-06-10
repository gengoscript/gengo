const std = @import("std");
const heap = @import("heap.zig");
const Object = @import("../lang/value.zig").Object;

const test_heap_size = 1024;
const test_max_objects = 8;

fn createState() !heap.State {
    var h: heap.State = .{};
    try h.init(test_heap_size, test_max_objects, std.testing.allocator);
    return h;
}

// ── Allocation basics ─────────────────────────────────────────────────────

test "allocBytesManaged returns non-null for small request" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const buf = heap.allocBytesManaged(16) orelse return error.TestFailed;
    _ = buf;
}

test "allocBytesManaged returns 16-aligned pointer" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const buf = heap.allocBytesManaged(16) orelse return error.TestFailed;
    try std.testing.expect(@intFromPtr(buf.ptr) % 16 == 0);
}

test "allocBytesManaged returns null after heap exhaustion" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    while (heap.allocBytesManaged(64) != null) {}
    try std.testing.expect(heap.allocBytesManaged(16) == null);
}

test "reset restores allocation after exhaustion" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    while (heap.allocBytesManaged(64) != null) {}
    try std.testing.expect(heap.allocBytesManaged(16) == null);
    heap.reset();
    try std.testing.expect(heap.allocBytesManaged(16) != null);
}

// ── Object pool ───────────────────────────────────────────────────────────

test "allocObject returns a live object" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const obj = heap.allocObject() orelse return error.TestFailed;
    try std.testing.expect(heap.isObjectLive(obj));
}

test "allocObject increments liveObjectCount" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    _ = heap.allocObject() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), heap.liveObjectCount());
}

test "allocObject returns null after MaxObjects" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    var i: usize = 0;
    while (i < test_max_objects) : (i += 1) {
        try std.testing.expect(heap.allocObject() != null);
    }
    try std.testing.expect(heap.allocObject() == null);
}

test "sweepObjects recycles freed slots for reuse" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const a = heap.allocObject() orelse return error.TestFailed;
    _ = a;
    const b = heap.allocObject() orelse return error.TestFailed;
    _ = b;
    try std.testing.expectEqual(@as(usize, 2), heap.liveObjectCount());
    heap.sweepObjects();
    try std.testing.expectEqual(@as(usize, 0), heap.liveObjectCount());
    try std.testing.expect(heap.allocObject() != null);
    try std.testing.expectEqual(@as(usize, 1), heap.liveObjectCount());
}

// ── GC mark-and-sweep ─────────────────────────────────────────────────────

test "unmarked object is collected by sweep" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const obj = heap.allocObject() orelse return error.TestFailed;
    try std.testing.expect(heap.isObjectLive(obj));
    heap.sweepObjects();
    try std.testing.expect(!heap.isObjectLive(obj));
}

test "marked object survives sweep" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const obj = heap.allocObject() orelse return error.TestFailed;
    heap.markObject(obj);
    heap.sweepObjects();
    try std.testing.expect(heap.isObjectLive(obj));
}

test "liveObjectCount after sweep equals marked count" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    _ = heap.allocObject() orelse return error.TestFailed;
    const kept = heap.allocObject() orelse return error.TestFailed;
    _ = heap.allocObject() orelse return error.TestFailed;
    heap.markObject(kept);
    heap.sweepObjects();
    try std.testing.expectEqual(@as(usize, 1), heap.liveObjectCount());
}

// ── Cell / upvalue lifecycle ──────────────────────────────────────────────

test "cell object stores and retains its value" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const cell = heap.allocObject() orelse return error.TestFailed;
    cell.* = .{ .cell = .{ .value = .{ .int = 42 } } };
    try std.testing.expect(cell.cell.value == .int and cell.cell.value.int == 42);
}

test "cell object survives sweep when explicitly marked" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const cell = heap.allocObject() orelse return error.TestFailed;
    cell.* = .{ .cell = .{ .value = .{ .int = 42 } } };
    heap.markObject(cell);
    heap.sweepObjects();
    try std.testing.expect(heap.isObjectLive(cell));
    try std.testing.expect(cell.cell.value == .int and cell.cell.value.int == 42);
}

test "cell object is collected when unmarked" {
    var h = try createState();
    defer h.deinit();
    heap.setActive(&h);
    const cell = heap.allocObject() orelse return error.TestFailed;
    cell.* = .{ .cell = .{ .value = .{ .int = 42 } } };
    heap.sweepObjects();
    try std.testing.expect(!heap.isObjectLive(cell));
}
