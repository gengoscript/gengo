const std = @import("std");
const heap = @import("heap.zig");
const Object = @import("../lang/value.zig").Object;
const Value = @import("../lang/value.zig").Value;

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
    a.* = .{ .array = &[_]Value{} };
    const b = heap.allocObject() orelse return error.TestFailed;
    b.* = .{ .array = &[_]Value{} };
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
    obj.* = .{ .array = &[_]Value{} };
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
    const dropped1 = heap.allocObject() orelse return error.TestFailed;
    dropped1.* = .{ .array = &[_]Value{} };
    const kept = heap.allocObject() orelse return error.TestFailed;
    kept.* = .{ .array = &[_]Value{} };
    const dropped2 = heap.allocObject() orelse return error.TestFailed;
    dropped2.* = .{ .array = &[_]Value{} };
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

// ── Heap-scaled size classes ──────────────────────────────────────────────

test "class cap scales with heap: 16 MiB heap allows 1 MiB blocks" {
    var h: heap.State = .{};
    try h.init(16 * 1024 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);
    const buf = heap.allocBytesManaged(1024 * 1024) orelse return error.TestFailed;
    try std.testing.expect(buf.len >= 1024 * 1024);
}

test "class cap scales with heap: 2 MiB heap allows 256 KiB, rejects 512 KiB" {
    var h: heap.State = .{};
    try h.init(2 * 1024 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);
    const ok = heap.allocBytesManaged(256 * 1024) orelse return error.TestFailed;
    _ = ok;
    try std.testing.expect(heap.allocBytesManaged(512 * 1024) == null);
}

test "class cap floor preserved: small heap still allows 64 KiB blocks" {
    var h: heap.State = .{};
    try h.init(128 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);
    const buf = heap.allocBytesManaged(64 * 1024) orelse return error.TestFailed;
    try std.testing.expect(buf.len >= 64 * 1024);
    try std.testing.expect(heap.allocBytesManaged(128 * 1024) == null);
}

test "scaled class blocks are reusable after free" {
    var h: heap.State = .{};
    try h.init(16 * 1024 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);
    const a = heap.allocBytesManaged(1024 * 1024) orelse return error.TestFailed;
    heap.freeBytesManaged(a);
    const b = heap.allocBytesManaged(1024 * 1024) orelse return error.TestFailed;
    try std.testing.expect(a.ptr == b.ptr);
}
