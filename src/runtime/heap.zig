const std = @import("std");
const cfg = @import("config.zig");
const builtin = @import("builtin");

pub const HeapSize = cfg.heap_size_bytes;
pub const MaxObjects = cfg.max_objects;

const Object = @import("../lang/value.zig").Object;
const ObjTag = @import("../lang/value.zig").ObjTag;

const ClassCount = 12;
const ClassSizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 };
const ManagedAlign: usize = 16;

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
    heap: []u8 align(16) = &[_]u8{},
    heap_pos: usize = 0,
    obj_pool: []Object = &[_]Object{},
    obj_marked: []bool = &[_]bool{},
    obj_live: []bool = &[_]bool{},
    obj_next_free: []u16 = &[_]u16{},
    obj_free_head: u16 = 0xffff,
    obj_live_count: usize = 0,
    free_blocks: [ClassCount]?*u8 = [_]?*u8{null} ** ClassCount,

    pub fn init(self: *State, heap_size: usize, max_objects: usize) !void {
        if (comptime builtin.target.cpu.arch == .wasm32) {
            self.heap = &g_wasm_backing.heap;
            self.obj_pool = &g_wasm_backing.obj_pool;
            self.obj_marked = &g_wasm_backing.obj_marked;
            self.obj_live = &g_wasm_backing.obj_live;
            self.obj_next_free = &g_wasm_backing.obj_next_free;
        } else {
            self.heap = try std.heap.page_allocator.alignedAlloc(u8, .@"16", heap_size);
            self.obj_pool = try std.heap.page_allocator.alloc(Object, max_objects);
            self.obj_marked = try std.heap.page_allocator.alloc(bool, max_objects);
            self.obj_live = try std.heap.page_allocator.alloc(bool, max_objects);
            self.obj_next_free = try std.heap.page_allocator.alloc(u16, max_objects);
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
        if (self.heap.len > 0) std.heap.page_allocator.free(self.heap);
        if (self.obj_pool.len > 0) std.heap.page_allocator.free(self.obj_pool);
        if (self.obj_marked.len > 0) std.heap.page_allocator.free(self.obj_marked);
        if (self.obj_live.len > 0) std.heap.page_allocator.free(self.obj_live);
        if (self.obj_next_free.len > 0) std.heap.page_allocator.free(self.obj_next_free);
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
        _ = state.init(HeapSize, MaxObjects) catch {};
    }
    g_state = state;
}

pub fn reset() void {
    if (g_state.obj_pool.len == 0 and g_state == &g_default_state) {
        _ = g_default_state.init(HeapSize, MaxObjects) catch {};
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

fn classIndexFor(n: usize) ?usize {
    var i: usize = 0;
    while (i < ClassCount) : (i += 1) {
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
        return @as([*]u8, @ptrCast(head))[0..ClassSizes[ci]];
    }
    const mask: usize = ManagedAlign - 1;
    const pos = (g_state.heap_pos + mask) & ~mask;
    if (pos + ClassSizes[ci] > g_state.heap.len) return null;
    g_state.heap_pos = pos + ClassSizes[ci];
    return g_state.heap[pos .. pos + ClassSizes[ci]];
}

pub fn freeBytesManaged(buf: []u8) void {
    if (buf.len == 0) return;
    const ci = classIndexFor(buf.len) orelse return;
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
            .struct_instance => freeManagedSlice(@import("../lang/value.zig").MapEntry, g_state.obj_pool[i].struct_instance.fields),
            .string_builder => freeBytesManaged(g_state.obj_pool[i].string_builder.buf),
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
