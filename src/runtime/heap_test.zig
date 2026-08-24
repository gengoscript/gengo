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

test "flat mode has no fixed compiler reservation when bump() is unused" {
    // With the two-ended arena, permanent data only claims space it actually
    // uses — unlike the old fixed heap_size/8 prefix, reserved whether or
    // not a script ever called bump(). With zero bump() calls, the full
    // 256 KiB heap is available for managed allocation: four 64 KiB blocks
    // fit exactly (was three, wasting 32 KiB, under the old fixed prefix).
    var h: heap.State = .{};
    try h.init(256 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) == null);
}

test "flat mode: bump() usage reduces managed capacity by exactly what it uses" {
    var h: heap.State = .{};
    try h.init(256 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    _ = heap.bump(u8, 64 * 1024) orelse return error.TestFailed;

    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expect(heap.allocBytesManaged(64 * 1024) == null);
}

test "flat mode preserves compiler bump data during managed allocation" {
    var h: heap.State = .{};
    try h.init(256 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    const compiler_data = (heap.bump(u8, 9) orelse return error.TestFailed)[0..9];
    @memcpy(compiler_data, "fieldkey!");

    try std.testing.expect(heap.allocBytesManaged(64 * 1024) != null);
    try std.testing.expectEqualStrings("fieldkey!", compiler_data);
}

test "managed overflow path stays aligned regardless of permanent-region bump size" {
    // bump() now grows down from the top, on its own pointer, entirely
    // separate from overflow_bump — so odd-sized permanent allocations can no
    // longer misalign the managed overflow bump the way they could when both
    // shared one counter. This just confirms allocBytesManaged's own
    // alignment logic holds regardless of how much (or how oddly-sized) the
    // permanent side has consumed.
    var h: heap.State = .{};
    try h.init(1024 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    _ = heap.bump(u8, 1) orelse return error.TestFailed;
    _ = heap.bump(u8, 3) orelse return error.TestFailed;
    _ = heap.bump(u8, 7) orelse return error.TestFailed;

    _ = heap.allocBytesManaged(@sizeOf(MapEntry)) orelse return error.TestFailed;
    const bytes = heap.allocBytesManaged(@sizeOf(MapEntry)) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % @alignOf(MapEntry));
}

test "bump refuses to cross into the managed region's current frontier" {
    var h: heap.State = .{};
    try h.init(4096, 8, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    _ = heap.allocBytesManaged(1024) orelse return error.TestFailed;
    const frontier = h.overflow_bump;

    // Big enough to require landing below the managed side's current
    // frontier — must fail rather than silently overlapping it.
    try std.testing.expect(heap.bump(u8, h.heap.len - frontier + 1) == null);

    // A request that comfortably fits above the frontier still succeeds.
    _ = heap.bump(u8, 8) orelse return error.TestFailed;
}

test "managed overflow allocation refuses to cross into the permanent region" {
    var h: heap.State = .{};
    try h.init(4096, 8, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    _ = heap.bump(u8, 3072) orelse return error.TestFailed; // permanent_bump now at 1024
    try std.testing.expect(heap.allocBytesManaged(2048) == null);
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

// ── Permanent-region (bump()) compaction safety ───────────────────────────
//
// Regression test for a real bug (found via the gengo-mbus decode corruption,
// "no field '<garbage>' on type 'DataRecord'"): struct_type.fields — and, it
// turned out, ANY bump()-allocated permanent data (interned string constants
// in particular) — used to share address space with the managed/collectible
// region once a fixed compiler-region budget (heap_size/8) was exceeded.
// compactManagedHeap() packed live managed objects starting from that fixed
// boundary with no idea permanent data might have spilled past it, silently
// overwriting it. The fix replaces the fixed prefix with a two-ended arena:
// permanent data bumps down from the top of the heap, managed data bumps up
// from the bottom, and an allocation on either side that would cross the
// other's current frontier fails outright rather than overlapping. This
// makes the corruption structurally impossible regardless of how much
// permanent data a program needs — not just within some fixed budget.

test "compactManagedHeap never corrupts permanent data even with heavy bump() pressure" {
    var h: heap.State = .{};
    try h.init(1024 * 1024, 64, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    // Consume far more than the old fixed compiler budget (heap_size / 8 =
    // 128 KiB) via plain byte bumps, standing in for interned string
    // constants — the actual data type that was corrupted in the M-Bus case.
    var chunks: [64][]u8 = undefined;
    for (&chunks, 0..) |*c, i| {
        const buf = (heap.bump(u8, 4096) orelse return error.TestFailed)[0..4096];
        @memset(buf, @truncate(i));
        c.* = buf;
    }

    // Also cover the originally-fixed case: a StructFieldSpec array owned by
    // a live struct_type object.
    const empty_alts = @import("../lang/value.zig").FieldTypeSpec{ .alts = &.{} };
    const field_specs = (heap.bump(StructFieldSpec, 3) orelse return error.TestFailed)[0..3];
    field_specs[0] = .{ .name = "alpha", .typ = empty_alts };
    field_specs[1] = .{ .name = "beta", .typ = empty_alts };
    field_specs[2] = .{ .name = "gamma", .typ = empty_alts };
    const typ_obj = heap.allocObject() orelse return error.TestFailed;
    typ_obj.* = .{ .struct_type = .{
        .name = "T",
        .qualified_name = "@module_type:T",
        .fields = field_specs,
    } };
    heap.markObject(typ_obj);

    // Ordinary managed churn, then force a compaction.
    const other = heap.allocObject() orelse return error.TestFailed;
    const bytes = heap.allocBytesManaged(64) orelse return error.TestFailed;
    other.* = .{ .dyn_string = bytes };
    heap.markObject(other);
    heap.sweepObjects();
    heap.compactManagedHeap();

    // All bump()-permanent data must be byte-for-byte intact — compaction
    // must never have touched it, let alone relocated or corrupted it.
    for (chunks, 0..) |c, i| {
        const want: u8 = @truncate(i);
        for (c) |b| try std.testing.expectEqual(want, b);
    }
    try std.testing.expectEqualStrings("alpha", typ_obj.struct_type.fields[0].name);
    try std.testing.expectEqualStrings("beta", typ_obj.struct_type.fields[1].name);
    try std.testing.expectEqualStrings("gamma", typ_obj.struct_type.fields[2].name);
}

// ── Compaction: additional object tags ────────────────────────────────────
//
// The tests above only exercise compactManagedHeap()'s dyn_string path.
// compactFillBlocks/compactCountBlocks/compactUpdateObj switch on many more
// ObjTags; these tests drive each of the remaining owning-block tags through
// a real relocation (via an interspersed, then-freed, spacer block so the
// live block's address actually changes) and confirm the data read back
// through the object's updated slice is byte-for-byte correct.

test "compactManagedHeap relocates array_managed, map, map_managed, and map_hashed blocks" {
    var h: heap.State = .{};
    try h.init(4096, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    const spacer_a = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_arr = heap.allocObject() orelse return error.TestFailed;
    const arr = heap.g_state.allocManagedSlice(Value, 4) orelse return error.TestFailed;
    arr[0] = .{ .int = 10 };
    arr[1] = .{ .int = 20 };
    arr[2] = .{ .int = 30 };
    arr[3] = .{ .int = 40 };
    o_arr.* = .{ .array_managed = arr };
    const arr_orig_addr = @intFromPtr(arr.ptr);

    const spacer_b = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_map = heap.allocObject() orelse return error.TestFailed;
    const map_slice = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    map_slice[0] = .{ .key = .{ .int = 1 }, .value = .{ .int = 100 } };
    o_map.* = .{ .map = map_slice };

    const spacer_c = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_mapm = heap.allocObject() orelse return error.TestFailed;
    const mapm_slice = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    mapm_slice[0] = .{ .key = .{ .int = 2 }, .value = .{ .int = 200 } };
    o_mapm.* = .{ .map_managed = mapm_slice };

    const spacer_d = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_hashed = heap.allocObject() orelse return error.TestFailed;
    const hashed_entries = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    hashed_entries[0] = .{ .key = .{ .int = 3 }, .value = .{ .int = 300 } };
    const hashed_buckets = heap.g_state.allocManagedSlice(i32, 4) orelse return error.TestFailed;
    hashed_buckets[0] = -1;
    hashed_buckets[1] = 0;
    hashed_buckets[2] = -1;
    hashed_buckets[3] = -1;
    o_hashed.* = .{ .map_hashed = .{ .entries = hashed_entries, .len = 1, .buckets = hashed_buckets } };

    // Free the spacers to create gaps between the live blocks so compaction
    // has to actually move data, not just leave it in place.
    heap.freeBytesManaged(spacer_a);
    heap.freeBytesManaged(spacer_b);
    heap.freeBytesManaged(spacer_c);
    heap.freeBytesManaged(spacer_d);

    const info_before = heap.fragmentationInfo();
    try std.testing.expect(info_before.free_bytes > 0);

    heap.compactManagedHeap();

    // Compaction clears the free lists outright (all freed space becomes
    // implicit bump headroom instead), so fragmentationInfo reports zero.
    const info_after = heap.fragmentationInfo();
    try std.testing.expectEqual(@as(usize, 0), info_after.free_bytes);

    // The array_managed block actually moved (spacer_a preceded it).
    try std.testing.expect(@intFromPtr(o_arr.array_managed.ptr) < arr_orig_addr);

    try std.testing.expectEqual(@as(usize, 4), o_arr.array_managed.len);
    try std.testing.expectEqual(@as(i64, 10), o_arr.array_managed[0].int);
    try std.testing.expectEqual(@as(i64, 20), o_arr.array_managed[1].int);
    try std.testing.expectEqual(@as(i64, 30), o_arr.array_managed[2].int);
    try std.testing.expectEqual(@as(i64, 40), o_arr.array_managed[3].int);

    try std.testing.expectEqual(@as(i64, 1), o_map.map[0].key.int);
    try std.testing.expectEqual(@as(i64, 100), o_map.map[0].value.int);

    try std.testing.expectEqual(@as(i64, 2), o_mapm.map_managed[0].key.int);
    try std.testing.expectEqual(@as(i64, 200), o_mapm.map_managed[0].value.int);

    try std.testing.expectEqual(@as(i64, 3), o_hashed.map_hashed.entries[0].key.int);
    try std.testing.expectEqual(@as(i64, 300), o_hashed.map_hashed.entries[0].value.int);
    try std.testing.expectEqual(@as(usize, 4), o_hashed.map_hashed.buckets.len);
    try std.testing.expectEqual(@as(i32, -1), o_hashed.map_hashed.buckets[0]);
    try std.testing.expectEqual(@as(i32, 0), o_hashed.map_hashed.buckets[1]);
}

test "compactManagedHeap relocates struct_instance, closure, bigint, and variant_value blocks" {
    var h: heap.State = .{};
    try h.init(4096, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    // A plain helper object referenced by pointer from struct_instance/
    // closure/variant_value below. It lives in the object pool (a separate
    // fixed allocation from the byte heap), so compaction never relocates it
    // — only the managed byte blocks these objects own get moved.
    const helper = heap.allocObject() orelse return error.TestFailed;
    helper.* = .{ .array = &[_]Value{} };

    const spacer_a = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_struct = heap.allocObject() orelse return error.TestFailed;
    const struct_fields = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    struct_fields[0] = .{ .key = .{ .int = 7 }, .value = .{ .int = 700 } };
    o_struct.* = .{ .struct_instance = .{ .typ = helper, .fields = struct_fields } };
    const struct_orig_addr = @intFromPtr(struct_fields.ptr);

    const spacer_b = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_closure = heap.allocObject() orelse return error.TestFailed;
    const upvalues = heap.g_state.allocManagedSlice(*Object, 2) orelse return error.TestFailed;
    upvalues[0] = helper;
    upvalues[1] = helper;
    o_closure.* = .{ .closure = .{ .func = helper, .upvalues = upvalues } };

    const spacer_c = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_big = heap.allocObject() orelse return error.TestFailed;
    const limbs = heap.g_state.allocManagedSlice(std.math.big.Limb, 2) orelse return error.TestFailed;
    limbs[0] = 0xDEAD;
    limbs[1] = 0xBEEF;
    o_big.* = .{ .bigint = .{ .limbs = limbs, .len = 2, .positive = true } };

    const spacer_d = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_variant = heap.allocObject() orelse return error.TestFailed;
    const arm_fields = heap.g_state.allocManagedSlice(Value, 1) orelse return error.TestFailed;
    arm_fields[0] = .{ .int = 9 };
    const shared_values = heap.g_state.allocManagedSlice(Value, 1) orelse return error.TestFailed;
    shared_values[0] = .{ .int = 99 };
    o_variant.* = .{ .variant_value = .{
        .typ = helper,
        .tag = "Arm",
        .ordinal = 0,
        .payload = .{ .int = 9 },
        .shared_values = shared_values,
        .arm_fields = arm_fields,
    } };

    heap.freeBytesManaged(spacer_a);
    heap.freeBytesManaged(spacer_b);
    heap.freeBytesManaged(spacer_c);
    heap.freeBytesManaged(spacer_d);

    heap.compactManagedHeap();

    try std.testing.expect(@intFromPtr(o_struct.struct_instance.fields.ptr) < struct_orig_addr);

    try std.testing.expectEqual(@as(i64, 7), o_struct.struct_instance.fields[0].key.int);
    try std.testing.expectEqual(@as(i64, 700), o_struct.struct_instance.fields[0].value.int);
    try std.testing.expect(o_struct.struct_instance.typ == helper);

    try std.testing.expectEqual(@as(usize, 2), o_closure.closure.upvalues.len);
    try std.testing.expect(o_closure.closure.upvalues[0] == helper);
    try std.testing.expect(o_closure.closure.upvalues[1] == helper);

    try std.testing.expectEqual(@as(usize, 2), o_big.bigint.limbs.len);
    try std.testing.expectEqual(@as(std.math.big.Limb, 0xDEAD), o_big.bigint.limbs[0]);
    try std.testing.expectEqual(@as(std.math.big.Limb, 0xBEEF), o_big.bigint.limbs[1]);

    try std.testing.expectEqual(@as(i64, 9), o_variant.variant_value.arm_fields[0].int);
    try std.testing.expectEqual(@as(i64, 99), o_variant.variant_value.shared_values[0].int);
}

test "compactManagedHeap relocates struct_type fields when they are managed-heap-backed" {
    // struct_type.fields is normally bump()-allocated permanent data (see the
    // "never corrupts permanent data" test above), so compactFillBlocks/
    // compactCountBlocks gate relocation behind isManagedAddr() as "defense
    // in depth". This test drives that true branch directly: fields backed
    // by an ordinary managed-heap allocation must still be found, moved, and
    // have the owning object's slice updated correctly.
    var h: heap.State = .{};
    try h.init(4096, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    const empty_alts = @import("../lang/value.zig").FieldTypeSpec{ .alts = &.{} };

    const spacer = heap.allocBytesManaged(64) orelse return error.TestFailed;
    const typ_obj = heap.allocObject() orelse return error.TestFailed;
    const fields = heap.g_state.allocManagedSlice(StructFieldSpec, 2) orelse return error.TestFailed;
    fields[0] = .{ .name = "x", .typ = empty_alts };
    fields[1] = .{ .name = "y", .typ = empty_alts };
    typ_obj.* = .{ .struct_type = .{ .name = "P", .qualified_name = "@m:P", .fields = fields } };
    const orig_addr = @intFromPtr(fields.ptr);

    heap.freeBytesManaged(spacer);
    heap.compactManagedHeap();

    try std.testing.expect(@intFromPtr(typ_obj.struct_type.fields.ptr) < orig_addr);
    try std.testing.expectEqual(@as(usize, 2), typ_obj.struct_type.fields.len);
    try std.testing.expectEqualStrings("x", typ_obj.struct_type.fields[0].name);
    try std.testing.expectEqualStrings("y", typ_obj.struct_type.fields[1].name);
}

test "compactManagedHeap updates string_view, array_view, and iterator sub-slice pointers" {
    // string_view/array_view/iterator hold non-owning slices into another
    // object's managed block. They're never counted/filled by
    // compactCountBlocks/compactFillBlocks (they own nothing), but
    // compactUpdateObj's second pass must still retarget their slice via
    // compactFindReloc against the owning block's relocation, preserving the
    // correct sub-range offset and length.
    var h: heap.State = .{};
    try h.init(4096, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    const spacer_a = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_str = heap.allocObject() orelse return error.TestFailed;
    const str_bytes = heap.allocBytesManaged(32) orelse return error.TestFailed;
    for (str_bytes, 0..) |*b, i| b.* = @intCast(i);
    o_str.* = .{ .dyn_string = str_bytes };

    const o_view = heap.allocObject() orelse return error.TestFailed;
    o_view.* = .{ .string_view = .{ .bytes = str_bytes[8..16], .source = o_str } };

    const spacer_b = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_arr = heap.allocObject() orelse return error.TestFailed;
    const arr = heap.g_state.allocManagedSlice(Value, 4) orelse return error.TestFailed;
    arr[0] = .{ .int = 1 };
    arr[1] = .{ .int = 2 };
    arr[2] = .{ .int = 3 };
    arr[3] = .{ .int = 4 };
    o_arr.* = .{ .array_managed = arr };

    const o_aview = heap.allocObject() orelse return error.TestFailed;
    o_aview.* = .{ .array_view = .{ .items = arr[1..3], .source = o_arr } };

    const o_iter_str = heap.allocObject() orelse return error.TestFailed;
    o_iter_str.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = str_bytes[2..6], .source = o_str } };

    const o_iter_arr = heap.allocObject() orelse return error.TestFailed;
    o_iter_arr.* = .{ .iterator = .{ .kind = .array, .index = 0, .array = arr[0..2], .source = o_arr } };

    const spacer_c = heap.allocBytesManaged(16) orelse return error.TestFailed;
    const o_map = heap.allocObject() orelse return error.TestFailed;
    const map_slice = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    map_slice[0] = .{ .key = .{ .int = 5 }, .value = .{ .int = 50 } };
    o_map.* = .{ .map_managed = map_slice };

    const o_iter_map = heap.allocObject() orelse return error.TestFailed;
    o_iter_map.* = .{ .iterator = .{ .kind = .map, .index = 0, .map = map_slice[0..1], .source = o_map } };

    // Range iterator: no slice to relocate, but exercises the trivial
    // `.range => {}` arm of compactUpdateObj's iterator-kind switch.
    const o_iter_range = heap.allocObject() orelse return error.TestFailed;
    o_iter_range.* = .{ .iterator = .{ .kind = .range, .index = 0, .range_current = 0, .range_max = 10 } };

    heap.freeBytesManaged(spacer_a);
    heap.freeBytesManaged(spacer_b);
    heap.freeBytesManaged(spacer_c);

    heap.compactManagedHeap();

    // Owning blocks kept their data.
    try std.testing.expectEqual(@as(u8, 8), o_str.dyn_string[8]);
    try std.testing.expectEqual(@as(i64, 1), o_arr.array_managed[0].int);

    // Views follow the relocated owning block at the correct offset/length.
    try std.testing.expectEqual(@as(usize, 8), o_view.string_view.bytes.len);
    try std.testing.expectEqual(@as(u8, 8), o_view.string_view.bytes[0]);
    try std.testing.expectEqual(@as(u8, 9), o_view.string_view.bytes[1]);

    try std.testing.expectEqual(@as(usize, 2), o_aview.array_view.items.len);
    try std.testing.expectEqual(@as(i64, 2), o_aview.array_view.items[0].int);
    try std.testing.expectEqual(@as(i64, 3), o_aview.array_view.items[1].int);

    try std.testing.expectEqual(@as(usize, 4), o_iter_str.iterator.string.len);
    try std.testing.expectEqual(@as(u8, 2), o_iter_str.iterator.string[0]);

    try std.testing.expectEqual(@as(usize, 2), o_iter_arr.iterator.array.len);
    try std.testing.expectEqual(@as(i64, 1), o_iter_arr.iterator.array[0].int);
    try std.testing.expectEqual(@as(i64, 2), o_iter_arr.iterator.array[1].int);

    try std.testing.expectEqual(@as(i64, 5), o_iter_map.iterator.map[0].key.int);
    try std.testing.expectEqual(@as(i64, 50), o_iter_map.iterator.map[0].value.int);

    // Range iterator is untouched (no slice needed relocation).
    try std.testing.expectEqual(@as(f64, 10), o_iter_range.iterator.range_max);
}

// ── Paranoia / overlap-check mode ──────────────────────────────────────────
//
// paranoiaOn() is gated by a comptime build flag (-Dheap_paranoia=true) OR
// the runtime `heap.paranoia` var (the CLI's GENGO_HEAP_PARANOIA=1 path) —
// so a normal, non-stress test build can still exercise assertNotLive's
// full switch by flipping the runtime flag directly, exactly as the CLI
// does. This drives takeFreeBlock's and freeBytesManaged's paranoia checks
// across one live object of every ObjTag assertNotLive inspects, confirming
// the "no real overlap" case reports cleanly (a false-positive overlap
// would @panic and abort the whole test binary).

test "paranoia mode's overlap check passes across every inspected ObjTag with no false positive" {
    var h: heap.State = .{};
    try h.init(4096, 32, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    heap.paranoia = true;
    defer heap.paranoia = false;

    const o_str = heap.allocObject() orelse return error.TestFailed;
    const str_bytes = heap.allocBytesManaged(16) orelse return error.TestFailed;
    o_str.* = .{ .dyn_string = str_bytes };

    const o_sb = heap.allocObject() orelse return error.TestFailed;
    const sb_buf = heap.allocBytesManaged(16) orelse return error.TestFailed;
    o_sb.* = .{ .string_builder = .{ .buf = sb_buf, .len = 0 } };

    const o_arr = heap.allocObject() orelse return error.TestFailed;
    const arr = heap.g_state.allocManagedSlice(Value, 1) orelse return error.TestFailed;
    arr[0] = .{ .int = 1 };
    o_arr.* = .{ .array_managed = arr };

    const o_map = heap.allocObject() orelse return error.TestFailed;
    const map_slice = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    map_slice[0] = .{ .key = .{ .int = 1 }, .value = .{ .int = 2 } };
    o_map.* = .{ .map = map_slice };

    const o_mapm = heap.allocObject() orelse return error.TestFailed;
    const mapm_slice = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    mapm_slice[0] = .{ .key = .{ .int = 3 }, .value = .{ .int = 4 } };
    o_mapm.* = .{ .map_managed = mapm_slice };

    const o_hashed = heap.allocObject() orelse return error.TestFailed;
    const hashed_entries = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    hashed_entries[0] = .{ .key = .{ .int = 5 }, .value = .{ .int = 6 } };
    const hashed_buckets = heap.g_state.allocManagedSlice(i32, 4) orelse return error.TestFailed;
    o_hashed.* = .{ .map_hashed = .{ .entries = hashed_entries, .len = 1, .buckets = hashed_buckets } };

    const helper = heap.allocObject() orelse return error.TestFailed;
    helper.* = .{ .array = &[_]Value{} };

    const o_struct = heap.allocObject() orelse return error.TestFailed;
    const struct_fields = heap.g_state.allocManagedSlice(MapEntry, 1) orelse return error.TestFailed;
    struct_fields[0] = .{ .key = .{ .int = 7 }, .value = .{ .int = 8 } };
    o_struct.* = .{ .struct_instance = .{ .typ = helper, .fields = struct_fields } };

    const o_variant = heap.allocObject() orelse return error.TestFailed;
    const arm_fields = heap.g_state.allocManagedSlice(Value, 1) orelse return error.TestFailed;
    arm_fields[0] = .{ .int = 9 };
    const shared_values = heap.g_state.allocManagedSlice(Value, 1) orelse return error.TestFailed;
    shared_values[0] = .{ .int = 10 };
    o_variant.* = .{ .variant_value = .{
        .typ = helper,
        .tag = "Arm",
        .ordinal = 0,
        .payload = .{ .int = 9 },
        .shared_values = shared_values,
        .arm_fields = arm_fields,
    } };

    const o_closure = heap.allocObject() orelse return error.TestFailed;
    const upvalues = heap.g_state.allocManagedSlice(*Object, 1) orelse return error.TestFailed;
    upvalues[0] = helper;
    o_closure.* = .{ .closure = .{ .func = helper, .upvalues = upvalues } };

    const o_big = heap.allocObject() orelse return error.TestFailed;
    const limbs = heap.g_state.allocManagedSlice(std.math.big.Limb, 1) orelse return error.TestFailed;
    limbs[0] = 42;
    o_big.* = .{ .bigint = .{ .limbs = limbs, .len = 1, .positive = true } };

    try std.testing.expectEqual(@as(usize, 11), heap.liveObjectCount());

    // A wholly unrelated block: freeing it makes assertNotLive scan every
    // live object above (hitting every tag in its switch) and find no
    // overlap — must not panic.
    const scratch = heap.allocBytesManaged(16) orelse return error.TestFailed;
    heap.freeBytesManaged(scratch);

    // Re-allocating the same class exercises takeFreeBlock's paranoia check
    // (assertNotLive runs again on the block about to be handed back out).
    const reused = heap.allocBytesManaged(16) orelse return error.TestFailed;
    try std.testing.expect(reused.ptr == scratch.ptr);
}

// ── bump() edge cases ──────────────────────────────────────────────────────

test "bump handles a zero-size request and an exact-fit request at the frontier" {
    var h: heap.State = .{};
    try h.init(256, 8, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    // A zero-size request must succeed and land exactly at the current
    // permanent_bump (heap.len for a fresh heap) — see the "very first
    // bump() call (even n == 0) can land exactly there" comment on bump().
    const zero_ptr = heap.bump(u8, 0) orelse return error.TestFailed;
    try std.testing.expectEqual(h.heap.len, @intFromPtr(zero_ptr) - @intFromPtr(h.heap.ptr));

    // Consume the entire remaining permanent region in one exact-fit request
    // (sz == permanent_bump) — the boundary must still succeed, not just
    // requests strictly smaller than what remains.
    const remaining = h.permanent_bump - h.overflow_bump;
    const exact = heap.bump(u8, remaining) orelse return error.TestFailed;
    try std.testing.expectEqual(h.overflow_bump, @intFromPtr(exact) - @intFromPtr(h.heap.ptr));
    try std.testing.expectEqual(@as(usize, 0), h.permanent_bump - h.overflow_bump);

    // No room remains for even one more byte.
    try std.testing.expect(heap.bump(u8, 1) == null);
}

// ── objectPoolIndex edge cases ─────────────────────────────────────────────

test "objectPoolIndex covers the first/last pool slots and rejects a foreign pointer" {
    var h: heap.State = .{};
    try h.init(1024, 4, std.testing.allocator);
    defer h.deinit();
    heap.setActive(&h);

    // A pointer that was never handed out by allocObject() — not inside the
    // pool's backing allocation at all — must resolve to the sentinel, not
    // be mistaken for a valid index.
    var stray: Object = .{ .array = &[_]Value{} };
    try std.testing.expectEqual(@as(u16, 0xFFFF), heap.objectPoolIndex(&stray));

    const first = heap.allocObject() orelse return error.TestFailed;
    _ = heap.allocObject() orelse return error.TestFailed;
    _ = heap.allocObject() orelse return error.TestFailed;
    const last = heap.allocObject() orelse return error.TestFailed;

    try std.testing.expectEqual(@as(u16, 0), heap.objectPoolIndex(first));
    try std.testing.expectEqual(@as(u16, 3), heap.objectPoolIndex(last));
}
