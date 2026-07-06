const std = @import("std");
const heap = @import("heap.zig");
const MapEntry = @import("../lang/value.zig").MapEntry;
const Object = @import("../lang/value.zig").Object;
const Value = @import("../lang/value.zig").Value;
const StructFieldSpec = @import("../lang/value.zig").StructFieldSpec;

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

test "flat mode preserves shared heap capacity for managed allocations" {
    var h: heap.State = .{};
    try h.init(256 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
}

test "managed overflow path realigns after compiler spillover" {
    var h: heap.State = .{};
    try h.init(1024 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    _ = heap.bump(u8, h.compiler_end) orelse return error.TestFailed;
    _ = heap.bump(u8, 1) orelse return error.TestFailed;

    _ = heap.allocBytesManaged(@sizeOf(MapEntry)) orelse return error.TestFailed;
    const bytes = heap.allocBytesManaged(@sizeOf(MapEntry)) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % @alignOf(MapEntry));
}

// ── Fragmentation and defragmentation ──────────────────────────────────────

test "defrag merges adjacent cross-class free blocks" {
    // Exhaust the heap, then free three adjacent blocks of different classes:
    // class-16, class-32, class-16. Defrag should recover a single class-64
    // block from that fragmented hole.
    var h: heap.State = .{};
    try h.init(1024, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    const a = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const b = heap.allocBytesManaged(32) orelse return error.TestFailed;
    const c = heap.allocBytesManaged(16) orelse return error.TestFailed;

    while (heap.allocBytesManaged(64) != null) {}

    // Free in reverse order so intermediate buddies don't merge early.
    heap.freeBytesManaged(c);
    heap.freeBytesManaged(b);
    heap.freeBytesManaged(a);

    const info = heap.fragmentationInfo();
    try std.testing.expect(info.free_bytes >= 64);
    try std.testing.expect(info.largest_block <= 32);

    // Run defrag and check that we now have a usable class-64 block.
    heap.defragmentFreeLists();

    const big = heap.allocBytesManaged(64) orelse return error.TestFailed;
    try std.testing.expect(big.len >= 64);
}

test "allocBytesManaged defragments cross-class fragmentation before failing" {
    var h: heap.State = .{};
    try h.init(1024, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    const a = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const b = heap.allocBytesManaged(32) orelse return error.TestFailed;
    const c = heap.allocBytesManaged(16) orelse return error.TestFailed;

    while (heap.allocBytesManaged(64) != null) {}

    heap.freeBytesManaged(c);
    heap.freeBytesManaged(b);
    heap.freeBytesManaged(a);

    const info = heap.fragmentationInfo();
    try std.testing.expect(info.free_bytes >= 64);
    try std.testing.expect(info.largest_block <= 32);

    const big = heap.allocBytesManaged(64) orelse return error.TestFailed;
    try std.testing.expect(big.len >= 64);
}

test "fragmentationInfo reflects free list state" {
    var h: heap.State = .{};
    try h.init(4096, 16, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    const info_empty = heap.fragmentationInfo();
    try std.testing.expectEqual(@as(usize, 0), info_empty.free_bytes);

    const a = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const info_allocd = heap.fragmentationInfo();
    try std.testing.expectEqual(@as(usize, 0), info_allocd.free_bytes);

    heap.freeBytesManaged(a);

    const info_freed = heap.fragmentationInfo();
    try std.testing.expect(info_freed.free_bytes >= 16);
}

test "compactManagedHeap eliminates live-object fragmentation" {
    // Three live dyn_string objects backed by managed blocks (a=16, b=32, c=16).
    // After exhausting the heap and freeing the middle object, defrag cannot
    // merge the 32 free bytes with anything because a and c are live on either
    // side. compactManagedHeap() moves a and c together and makes room for 64 B.
    var h: heap.State = .{};
    try h.init(1024, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    // Allocate three live objects backed by managed bytes.
    const oa = heap.allocObject() orelse return error.TestFailed;
    const a = heap.allocBytesManaged(16) orelse return error.TestFailed;
    oa.* = .{ .dyn_string = a };

    const ob = heap.allocObject() orelse return error.TestFailed;
    const b_bytes = heap.allocBytesManaged(32) orelse return error.TestFailed;
    ob.* = .{ .dyn_string = b_bytes };

    const oc = heap.allocObject() orelse return error.TestFailed;
    const c = heap.allocBytesManaged(16) orelse return error.TestFailed;
    oc.* = .{ .dyn_string = c };

    // Exhaust the heap so no bump space remains.
    while (heap.allocBytesManaged(64) != null) {}

    // Simulate GC sweep of ob: mark slot dead first, then free its managed bytes
    // (mirrors the order the real sweeper uses; paranoia checks live refs on free).
    const ob_idx = heap.objectPoolIndex(ob);
    if (ob_idx != 0xFFFF) {
        heap.g_state.obj_live[ob_idx] = false;
        heap.g_state.obj_next_free[ob_idx] = heap.g_state.obj_free_head;
        heap.g_state.obj_free_head = ob_idx;
        heap.g_state.obj_live_count -= 1;
    }
    heap.freeBytesManaged(ob.dyn_string);

    // 32 bytes in free list, but sandwiched between live a and c.
    const info = heap.fragmentationInfo();
    try std.testing.expect(info.free_bytes >= 32);

    // compactManagedHeap moves a and c together, freeing a contiguous tail.
    heap.compactManagedHeap();

    const big = heap.allocBytesManaged(64) orelse return error.TestFailed;
    try std.testing.expect(big.len >= 64);
}

test "compactManagedHeap updates slice pointers in owning objects" {
    // After compaction, Object.dyn_string slice pointers must reflect the new
    // locations and the underlying data must be intact.
    var h: heap.State = .{};
    try h.init(4096, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    // Live block a with known content.
    const oa = heap.allocObject() orelse return error.TestFailed;
    const a = heap.allocBytesManaged(16) orelse return error.TestFailed;
    @memset(a, 0xAB);
    oa.* = .{ .dyn_string = a };

    // Middle block b (will be freed to create a gap).
    const ob = heap.allocObject() orelse return error.TestFailed;
    const b_bytes = heap.allocBytesManaged(16) orelse return error.TestFailed;
    ob.* = .{ .dyn_string = b_bytes };

    // Live block c with known content.
    const oc = heap.allocObject() orelse return error.TestFailed;
    const c = heap.allocBytesManaged(16) orelse return error.TestFailed;
    @memset(c, 0xEF);
    oc.* = .{ .dyn_string = c };

    // Exhaust the heap then simulate GC sweep of ob (mark dead before free).
    while (heap.allocBytesManaged(64) != null) {}
    const ob_idx = heap.objectPoolIndex(ob);
    if (ob_idx != 0xFFFF) {
        heap.g_state.obj_live[ob_idx] = false;
        heap.g_state.obj_next_free[ob_idx] = heap.g_state.obj_free_head;
        heap.g_state.obj_free_head = ob_idx;
        heap.g_state.obj_live_count -= 1;
    }
    heap.freeBytesManaged(ob.dyn_string);

    heap.compactManagedHeap();

    // Data must be preserved at the new locations.
    try std.testing.expect(oa.dyn_string[0] == 0xAB);
    try std.testing.expect(oc.dyn_string[0] == 0xEF);
    try std.testing.expectEqual(@as(usize, 16), oa.dyn_string.len);
    try std.testing.expectEqual(@as(usize, 16), oc.dyn_string.len);
}

test "defrag frees scratch buffer when free block count exceeds stack buffer" {
    var h: heap.State = .{};
    try h.init(32768, 2048, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    var blocks: [1026][]u8 = undefined;
    for (&blocks) |*block| {
        block.* = heap.allocBytesManaged(16) orelse return error.TestFailed;
    }

    var i: usize = 0;
    while (i < blocks.len) : (i += 2) {
        heap.freeBytesManaged(blocks[i]);
    }

    heap.defragmentFreeLists();
}

// ── struct_type.fields compaction regression ──────────────────────────────
//
// Regression test for: struct_type.fields allocated via heap.bump() overflow
// (when the compiler region is exhausted) was not tracked by compactManagedHeap().
// After compaction, new overflow allocations overwrote the old fields address
// without the struct_type pointer being updated, corrupting field lookups.

test "compactManagedHeap updates struct_type.fields bumped to managed overflow" {
    // Use a 1 MiB heap to guarantee partitioned mode (class regions + overflow).
    var h: heap.State = .{};
    try h.init(1024 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    // Fill the entire compiler region so the next bump() falls through to
    // managed-heap overflow — the scenario that happens after compiling a large
    // script and then running installStdGlobal().
    _ = heap.bump(u8, h.compiler_end) orelse return error.TestFailed;

    // Allocate a StructFieldSpec array via bump() — it lands in overflow.
    const empty_alts = @import("../lang/value.zig").FieldTypeSpec{ .alts = &.{} };
    const field_specs = (heap.bump(StructFieldSpec, 3) orelse return error.TestFailed)[0..3];
    field_specs[0] = .{ .name = "alpha", .typ = empty_alts };
    field_specs[1] = .{ .name = "beta",  .typ = empty_alts };
    field_specs[2] = .{ .name = "gamma", .typ = empty_alts };
    const orig_ptr = field_specs.ptr;

    // Create a live struct_type pool object owning those fields.
    const typ_obj = heap.allocObject() orelse return error.TestFailed;
    typ_obj.* = .{ .struct_type = .{
        .name = "T",
        .qualified_name = "@module_type:T",
        .fields = field_specs,
    } };

    // Mark only typ_obj live, then compact.
    heap.markObject(typ_obj);
    heap.sweepObjects();
    heap.compactManagedHeap();

    // The fields were in overflow and must have been moved to the packed region.
    try std.testing.expect(typ_obj.struct_type.fields.ptr != orig_ptr);
    try std.testing.expectEqual(@as(usize, 3), typ_obj.struct_type.fields.len);

    // Overwrite the old overflow location with 0xFF to simulate subsequent
    // managed allocations reusing that space.  Without the fix, the pointer
    // would still point here and field name reads would return garbage.
    const old_addr = @intFromPtr(orig_ptr);
    const field_bytes = @sizeOf(StructFieldSpec) * 3;
    if (old_addr + field_bytes <= @intFromPtr(h.heap.ptr) + h.heap.len) {
        const old_mem: [*]u8 = @ptrFromInt(old_addr);
        @memset(old_mem[0..field_bytes], 0xFF);
    }

    // Field names must still be correct at the new location.
    try std.testing.expectEqualStrings("alpha", typ_obj.struct_type.fields[0].name);
    try std.testing.expectEqualStrings("beta",  typ_obj.struct_type.fields[1].name);
    try std.testing.expectEqualStrings("gamma", typ_obj.struct_type.fields[2].name);
}
