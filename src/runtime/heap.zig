const std = @import("std");
const cfg = @import("config.zig");
const builtin = @import("builtin");

pub const HeapSize = cfg.heap_size_bytes;
pub const MaxObjects = cfg.max_objects;
comptime {
    if (MaxObjects > 65535) @compileError("max_objects must be <= 65535 (free-list indices are u16; 0xffff is the sentinel)");
}

const Object = @import("../lang/value.zig").Object;
const ObjTag = @import("../lang/value.zig").ObjTag;

// Size classes 16 B .. 2 MiB. Classes above BaseClassCount (64 KiB) are only
// usable when the configured heap is large enough: the largest usable class
// is capped at heap_size / 8 so a single block can never swallow the heap.
const ClassCount = 18;
const ClassSizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152 };
const BaseClassCount = 13; // through 65536 — always available, preserves the historical floor
const ManagedAlign: usize = 16;

fn usableClassCount(heap_size: usize) usize {
    var c: usize = BaseClassCount;
    while (c < ClassCount and ClassSizes[c] * 8 <= heap_size) c += 1;
    return c;
}

// On WASM linear memory is fixed; keep preset-sized backing arrays.
const WasmBacking = if (builtin.target.cpu.arch == .wasm32) struct {
    heap: [HeapSize]u8 align(16) = undefined,
    obj_pool: [MaxObjects]Object = undefined,
    obj_marked: [MaxObjects]bool = [_]bool{false} ** MaxObjects,
    obj_live: [MaxObjects]bool = [_]bool{false} ** MaxObjects,
    obj_next_free: [MaxObjects]u16 = undefined,
} else struct {};

var g_wasm_backing: WasmBacking = .{};

pub const State = struct {
    heap: []align(16) u8 = &[_]u8{},
    heap_pos: usize = 0,
    obj_pool: []Object = &[_]Object{},
    obj_marked: []bool = &[_]bool{},
    obj_live: []bool = &[_]bool{},
    obj_next_free: []u16 = &[_]u16{},
    obj_free_head: u16 = 0xffff,
    obj_live_count: usize = 0,
    free_blocks: [ClassCount]?*u8 = [_]?*u8{null} ** ClassCount,
    class_count: usize = BaseClassCount,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn init(self: *State, heap_size: usize, max_objects: usize, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.class_count = usableClassCount(heap_size);
        if (comptime builtin.target.cpu.arch == .wasm32) {
            self.heap = &g_wasm_backing.heap;
            self.obj_pool = &g_wasm_backing.obj_pool;
            self.obj_marked = &g_wasm_backing.obj_marked;
            self.obj_live = &g_wasm_backing.obj_live;
            self.obj_next_free = &g_wasm_backing.obj_next_free;
        } else {
            self.heap = try allocator.alignedAlloc(u8, .@"16", heap_size);
            self.obj_pool = try allocator.alloc(Object, max_objects);
            self.obj_marked = try allocator.alloc(bool, max_objects);
            self.obj_live = try allocator.alloc(bool, max_objects);
            self.obj_next_free = try allocator.alloc(u16, max_objects);
        }

        self.obj_free_head = 0;
        self.obj_live_count = 0;
        self.heap_pos = 0;
        var c: usize = 0;
        while (c < ClassCount) : (c += 1) self.free_blocks[c] = null;
        var i: usize = 0;
        while (i < max_objects) : (i += 1) {
            self.obj_marked[i] = false;
            self.obj_live[i] = false;
            self.obj_next_free[i] = @intCast(i + 1);
        }
        if (max_objects > 0) {
            self.obj_next_free[max_objects - 1] = 0xffff;
        }
    }

    pub fn deinit(self: *State) void {
        if (comptime builtin.target.cpu.arch == .wasm32) {
            // On WASM backing memory is global; just clear slices.
            self.* = .{};
            return;
        }
        if (self.heap.len > 0) self.allocator.free(self.heap);
        if (self.obj_pool.len > 0) self.allocator.free(self.obj_pool);
        if (self.obj_marked.len > 0) self.allocator.free(self.obj_marked);
        if (self.obj_live.len > 0) self.allocator.free(self.obj_live);
        if (self.obj_next_free.len > 0) self.allocator.free(self.obj_next_free);
        self.* = .{};
    }

    pub fn maxObjects(self: *const State) usize {
        return self.obj_pool.len;
    }
};

var g_default_state: State = .{};
pub var g_state: *State = &g_default_state;

pub fn setActive(state: *State) void {
    if (state.obj_pool.len == 0 and state == &g_default_state) {
        _ = state.init(HeapSize, MaxObjects, state.allocator) catch {};
    }
    g_state = state;
}

pub fn reset() void {
    if (g_state.obj_pool.len == 0 and g_state == &g_default_state) {
        _ = g_default_state.init(HeapSize, MaxObjects, g_state.allocator) catch {};
    }
    g_state.heap_pos = 0;
    var c: usize = 0;
    while (c < ClassCount) : (c += 1) g_state.free_blocks[c] = null;
    const max = g_state.obj_pool.len;
    var i: usize = 0;
    while (i < max) : (i += 1) {
        g_state.obj_marked[i] = false;
        g_state.obj_live[i] = false;
        g_state.obj_next_free[i] = @intCast(i + 1);
    }
    if (max > 0) {
        g_state.obj_next_free[max - 1] = 0xffff;
    }
    g_state.obj_free_head = 0;
    g_state.obj_live_count = 0;
}

// Largest single managed allocation the active heap supports.
pub fn maxManagedAlloc() usize {
    return ClassSizes[g_state.class_count - 1];
}

fn classIndexFor(n: usize) ?usize {
    var i: usize = 0;
    while (i < g_state.class_count) : (i += 1) {
        if (n <= ClassSizes[i]) return i;
    }
    return null;
}

// Returns true if allocating n bytes would expand the bump pointer (i.e., the
// slab free list for the class has no available block). Callers can use this
// to decide whether to run GC proactively before a large allocation.
pub fn wouldBump(n: usize) bool {
    if (n == 0) return false;
    const ci = classIndexFor(n) orelse return false; // too large for slab → handled separately
    return g_state.free_blocks[ci] == null;
}

pub fn bump(comptime T: type, n: usize) ?[*]T {
    const al: usize = @alignOf(T);
    const mask: usize = al - 1;
    const pos = (g_state.heap_pos + mask) & ~mask;
    const sz = @sizeOf(T) * n;
    if (pos + sz > g_state.heap.len) return null;
    g_state.heap_pos = pos + sz;
    return @as([*]T, @ptrCast(@alignCast(&g_state.heap[pos])));
}

pub fn allocBytesManaged(n: usize) ?[]u8 {
    if (n == 0) return &[_]u8{};
    const ci = classIndexFor(n) orelse return null;
    if (g_state.free_blocks[ci]) |head| {
        const next_ptr = @as(*usize, @ptrCast(@alignCast(head))).*;
        g_state.free_blocks[ci] = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
        const blk = @as([*]u8, @ptrCast(head))[0..ClassSizes[ci]];
        if (paranoiaOn()) assertNotLive(blk);
        return blk;
    }
    // Try bump before splitting — splitting is only worthwhile when the bump
    // is exhausted, since bump blocks arrive pre-split and are cheaper.
    const mask: usize = ManagedAlign - 1;
    const pos = (g_state.heap_pos + mask) & ~mask;
    if (pos + ClassSizes[ci] <= g_state.heap.len) {
        g_state.heap_pos = pos + ClassSizes[ci];
        return g_state.heap[pos .. pos + ClassSizes[ci]];
    }
    // Bump exhausted for this class: try buddy-splitting a larger free block.
    // ClassSizes are exact powers of 2, so splitting is lossless.
    var split_ci = ci + 1;
    while (split_ci < g_state.class_count) : (split_ci += 1) {
        if (g_state.free_blocks[split_ci]) |head| {
            const next_ptr = @as(*usize, @ptrCast(@alignCast(head))).*;
            g_state.free_blocks[split_ci] = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
            // Split from split_ci down to ci, placing upper buddies in intermediate lists.
            var cur_ci = split_ci;
            var cur_ptr = @as([*]u8, @ptrCast(head));
            while (cur_ci > ci) {
                cur_ci -= 1;
                const half = ClassSizes[cur_ci];
                const buddy = cur_ptr + half;
                const buddy_next = if (g_state.free_blocks[cur_ci]) |h| @intFromPtr(h) else 0;
                @as(*usize, @ptrCast(@alignCast(buddy))).* = buddy_next;
                g_state.free_blocks[cur_ci] = @ptrCast(buddy);
            }
            const blk = cur_ptr[0..ClassSizes[ci]];
            if (paranoiaOn()) assertNotLive(blk);
            return blk;
        }
    }
    return null;
}

// Debug tripwire, enabled by the CLI when GENGO_HEAP_PARANOIA is set.
pub var paranoia: bool = false;
fn paranoiaOn() bool {
    return paranoia;
}

fn assertNotLive(buf: []u8) void {
    const std_ = @import("std");
    const lo = @intFromPtr(buf.ptr);
    const hi = lo + buf.len;
    var i: usize = 0;
    while (i < g_state.obj_pool.len) : (i += 1) {
        if (!g_state.obj_live[i]) continue;
        const region: ?[]const u8 = switch (g_state.obj_pool[i]) {
            .dyn_string => |ds| ds,
            .string_builder => |sb| sb.buf,
            .array_managed => |am| std_.mem.sliceAsBytes(am),
            .map_managed => |mm| std_.mem.sliceAsBytes(mm),
            else => null,
        };
        if (region) |r| {
            if (r.len == 0) continue;
            const rlo = @intFromPtr(r.ptr);
            const rhi = rlo + r.len;
            if (lo < rhi and rlo < hi) {
                std_.debug.print("FREE-OF-LIVE: freeing {x}..{x} overlaps live obj {d} ({s}) {x}..{x}\n", .{ lo, hi, i, @tagName(g_state.obj_pool[i]), rlo, rhi });
                @panic("free of live region");
            }
        }
    }
}

// Remove a block at target_addr from free list ci. Returns true if found.
fn removeFromFreeList(ci: usize, target_addr: usize) bool {
    var prev: ?*u8 = null;
    var cur: ?*u8 = g_state.free_blocks[ci];
    while (cur) |node| {
        const next_val = @as(*usize, @ptrCast(@alignCast(node))).*;
        const next_node: ?*u8 = if (next_val == 0) null else @as(*u8, @ptrFromInt(next_val));
        if (@intFromPtr(node) == target_addr) {
            if (prev) |p| {
                @as(*usize, @ptrCast(@alignCast(p))).* = next_val;
            } else {
                g_state.free_blocks[ci] = next_node;
            }
            return true;
        }
        prev = node;
        cur = next_node;
    }
    return false;
}

pub fn freeBytesManaged(buf: []u8) void {
    if (buf.len == 0) return;
    if (paranoiaOn()) assertNotLive(buf);
    const ci = classIndexFor(buf.len) orelse return;
    const p_addr = @intFromPtr(buf.ptr);

    // Coalesce: if an adjacent free block of the same class exists, merge them
    // into a ci+1 block and recurse. Any two adjacent free blocks form a valid
    // larger block regardless of how they were originally allocated.
    if (ci + 1 < g_state.class_count) {
        // Try upper buddy: block immediately after us.
        const upper_addr = p_addr + ClassSizes[ci];
        if (removeFromFreeList(ci, upper_addr)) {
            const merged = @as([*]u8, @ptrCast(buf.ptr))[0..ClassSizes[ci + 1]];
            freeBytesManaged(merged);
            return;
        }
        // Try lower buddy: block immediately before us.
        if (p_addr >= ClassSizes[ci]) {
            const lower_addr = p_addr - ClassSizes[ci];
            if (lower_addr >= @intFromPtr(g_state.heap.ptr) and removeFromFreeList(ci, lower_addr)) {
                const merged = @as([*]u8, @ptrFromInt(lower_addr))[0..ClassSizes[ci + 1]];
                freeBytesManaged(merged);
                return;
            }
        }
    }

    const p = @as(*u8, @ptrCast(buf.ptr));
    const next = if (g_state.free_blocks[ci]) |h| @intFromPtr(h) else 0;
    @as(*usize, @ptrCast(@alignCast(p))).* = next;
    g_state.free_blocks[ci] = p;
}

pub fn allocManagedSlice(comptime T: type, n: usize) ?[]T {
    if (n == 0) return &[_]T{};
    const need = @sizeOf(T) * n;
    const bytes = allocBytesManaged(need) orelse return null;
    const p = @as([*]T, @ptrCast(@alignCast(bytes.ptr)));
    return p[0..n];
}

pub fn freeManagedSlice(comptime T: type, s: []T) void {
    if (s.len == 0) return;
    const need = @sizeOf(T) * s.len;
    const ci = classIndexFor(need) orelse return;
    const block = @as([*]u8, @ptrCast(s.ptr))[0..ClassSizes[ci]];
    freeBytesManaged(block);
}

pub fn allocObject() ?*Object {
    if (g_state.obj_free_head == 0xffff) return null;
    const idx = g_state.obj_free_head;
    g_state.obj_free_head = g_state.obj_next_free[idx];
    g_state.obj_live[idx] = true;
    g_state.obj_marked[idx] = false;
    g_state.obj_live_count += 1;
    return &g_state.obj_pool[idx];
}

fn objectIndex(ptr: *Object) ?usize {
    if (g_state.obj_pool.len == 0) return null;
    const base = @intFromPtr(g_state.obj_pool.ptr);
    const p = @intFromPtr(ptr);
    if (p < base) return null;
    const diff = p - base;
    const sz = @sizeOf(Object);
    if (diff % sz != 0) return null;
    const idx = diff / sz;
    if (idx >= g_state.obj_pool.len) return null;
    return idx;
}

// Returns the object pool index (0..maxObjects-1) or 0xFFFF if ptr is not in the pool.
pub fn objectPoolIndex(ptr: *Object) u16 {
    const idx = objectIndex(ptr) orelse return 0xFFFF;
    return @intCast(idx);
}

// Returns a pointer to the object at the given pool index.
pub fn objectAt(idx: u16) *Object {
    return &g_state.obj_pool[idx];
}

pub fn markObject(ptr: *Object) void {
    const idx = objectIndex(ptr) orelse return;
    if (!g_state.obj_live[idx]) return;
    g_state.obj_marked[idx] = true;
}

pub fn isObjectMarked(ptr: *Object) bool {
    const idx = objectIndex(ptr) orelse return false;
    return g_state.obj_live[idx] and g_state.obj_marked[idx];
}

pub fn isObjectLive(ptr: *Object) bool {
    const idx = objectIndex(ptr) orelse return false;
    return g_state.obj_live[idx];
}

pub fn sweepObjects() void {
    const max = g_state.obj_pool.len;
    var i: usize = 0;
    while (i < max) : (i += 1) {
        if (!g_state.obj_live[i]) continue;
        if (g_state.obj_marked[i]) {
            g_state.obj_marked[i] = false;
            continue;
        }
        switch (@as(ObjTag, g_state.obj_pool[i])) {
            .dyn_string => freeBytesManaged(g_state.obj_pool[i].dyn_string),
            .array_managed => freeManagedSlice(@import("../lang/value.zig").Value, g_state.obj_pool[i].array_managed),
            .map_managed => freeManagedSlice(@import("../lang/value.zig").MapEntry, g_state.obj_pool[i].map_managed),
            .map_hashed => {
                freeManagedSlice(@import("../lang/value.zig").MapEntry, g_state.obj_pool[i].map_hashed.entries);
                freeManagedSlice(i32, g_state.obj_pool[i].map_hashed.buckets);
            },
            .map => freeManagedSlice(@import("../lang/value.zig").MapEntry, g_state.obj_pool[i].map),
            .struct_instance => freeManagedSlice(@import("../lang/value.zig").MapEntry, g_state.obj_pool[i].struct_instance.fields),
            .string_builder => freeBytesManaged(g_state.obj_pool[i].string_builder.buf),
            .string_view => {},
            .variant_value => {
                const vv = g_state.obj_pool[i].variant_value;
                if (vv.arm_fields.len > 0) freeManagedSlice(@import("../lang/value.zig").Value, vv.arm_fields);
                if (vv.shared_values.len > 0) freeManagedSlice(@import("../lang/value.zig").Value, vv.shared_values);
            },
            else => {},
        }
        g_state.obj_live[i] = false;
        g_state.obj_next_free[i] = g_state.obj_free_head;
        g_state.obj_free_head = @intCast(i);
        g_state.obj_live_count -= 1;
    }
}

pub fn liveObjectCount() usize {
    return g_state.obj_live_count;
}

pub fn usedBytes() usize {
    return g_state.heap_pos;
}

// Returns total bytes sitting in free lists across all classes.
pub fn totalFreeListBytes() usize {
    var total: usize = 0;
    for (0..g_state.class_count) |ci| {
        var node = g_state.free_blocks[ci];
        while (node) |n| {
            total += ClassSizes[ci];
            const next_ptr = @as(*usize, @ptrCast(@alignCast(n))).*;
            node = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
        }
    }
    return total;
}

// Writes a compact free-list summary: "ci=N:depth,..." for non-empty classes.
// buf must be large enough; returns the slice written.
pub fn freeListSummary(buf: []u8) []u8 {
    var pos: usize = 0;
    var first = true;
    for (0..g_state.class_count) |ci| {
        var depth: usize = 0;
        var node = g_state.free_blocks[ci];
        while (node) |n| {
            depth += 1;
            const next_ptr = @as(*usize, @ptrCast(@alignCast(n))).*;
            node = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
        }
        if (depth == 0) continue;
        if (!first) {
            if (pos < buf.len) { buf[pos] = ','; pos += 1; }
        }
        first = false;
        // write "ci=N:depth"
        const prefix = "ci=";
        for (prefix) |c| { if (pos < buf.len) { buf[pos] = c; pos += 1; } }
        // ci index as decimal
        var tmp: [4]u8 = undefined;
        var n: usize = ci;
        var tlen: usize = 0;
        if (n == 0) { tmp[0] = '0'; tlen = 1; } else {
            while (n > 0) : (n /= 10) { tmp[tlen] = @intCast('0' + n % 10); tlen += 1; }
            std.mem.reverse(u8, tmp[0..tlen]);
        }
        for (tmp[0..tlen]) |c| { if (pos < buf.len) { buf[pos] = c; pos += 1; } }
        if (pos < buf.len) { buf[pos] = ':'; pos += 1; }
        // depth as decimal
        var d: usize = depth;
        var dlen: usize = 0;
        var dtmp: [8]u8 = undefined;
        if (d == 0) { dtmp[0] = '0'; dlen = 1; } else {
            while (d > 0) : (d /= 10) { dtmp[dlen] = @intCast('0' + d % 10); dlen += 1; }
            std.mem.reverse(u8, dtmp[0..dlen]);
        }
        for (dtmp[0..dlen]) |c| { if (pos < buf.len) { buf[pos] = c; pos += 1; } }
    }
    return buf[0..pos];
}
