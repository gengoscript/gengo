const cfg = @import("config.zig");

pub const HeapSize = cfg.heap_size_bytes;
pub const MaxObjects = cfg.max_objects;

const Object = @import("../lang/value.zig").Object;
const ObjTag = @import("../lang/value.zig").ObjTag;

var g_heap: [HeapSize]u8 align(16) = undefined;
var g_heap_pos: usize = 0;
var g_obj_pool: [MaxObjects]Object = undefined;
var g_obj_marked: [MaxObjects]bool = [_]bool{false} ** MaxObjects;
var g_obj_live: [MaxObjects]bool = [_]bool{false} ** MaxObjects;
var g_obj_next_free: [MaxObjects]u16 = undefined;
var g_obj_free_head: u16 = 0;
var g_obj_live_count: usize = 0;

const ClassCount = 12;
const ClassSizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 };
const ManagedAlign: usize = 16;
var g_free_blocks: [ClassCount]?*u8 = [_]?*u8{null} ** ClassCount;

pub const State = struct {
    heap: [HeapSize]u8 align(16) = undefined,
    heap_pos: usize = 0,
    obj_pool: [MaxObjects]Object = undefined,
    obj_marked: [MaxObjects]bool = [_]bool{false} ** MaxObjects,
    obj_live: [MaxObjects]bool = [_]bool{false} ** MaxObjects,
    obj_next_free: [MaxObjects]u16 = undefined,
    obj_free_head: u16 = 0,
    obj_live_count: usize = 0,
    free_blocks: [ClassCount]?*u8 = [_]?*u8{null} ** ClassCount,
};

pub fn reset() void {
    g_heap_pos = 0;
    var c: usize = 0;
    while (c < ClassCount) : (c += 1) g_free_blocks[c] = null;
    var i: usize = 0;
    while (i < MaxObjects) : (i += 1) {
        g_obj_marked[i] = false;
        g_obj_live[i] = false;
        g_obj_next_free[i] = @intCast(i + 1);
    }
    g_obj_next_free[MaxObjects - 1] = 0xffff;
    g_obj_free_head = 0;
    g_obj_live_count = 0;
}

fn classIndexFor(n: usize) ?usize {
    var i: usize = 0;
    while (i < ClassCount) : (i += 1) {
        if (n <= ClassSizes[i]) return i;
    }
    return null;
}

pub fn bump(comptime T: type, n: usize) ?[*]T {
    const al: usize = @alignOf(T);
    const mask: usize = al - 1;
    const pos = (g_heap_pos + mask) & ~mask;
    const sz = @sizeOf(T) * n;
    if (pos + sz > g_heap.len) return null;
    g_heap_pos = pos + sz;
    return @as([*]T, @ptrCast(@alignCast(&g_heap[pos])));
}

pub fn allocBytesManaged(n: usize) ?[]u8 {
    if (n == 0) return &[_]u8{};
    const ci = classIndexFor(n) orelse return null;
    if (g_free_blocks[ci]) |head| {
        const next_ptr = @as(*usize, @ptrCast(@alignCast(head))).*;
        g_free_blocks[ci] = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
        return @as([*]u8, @ptrCast(head))[0..ClassSizes[ci]];
    }
    // Fresh managed blocks are always allocated at a fixed alignment so that
    // later typed casts from managed slices remain valid.
    const mask: usize = ManagedAlign - 1;
    const pos = (g_heap_pos + mask) & ~mask;
    if (pos + ClassSizes[ci] > g_heap.len) return null;
    g_heap_pos = pos + ClassSizes[ci];
    return g_heap[pos .. pos + ClassSizes[ci]];
}

pub fn freeBytesManaged(buf: []u8) void {
    if (buf.len == 0) return;
    const ci = classIndexFor(buf.len) orelse return;
    const p = @as(*u8, @ptrCast(buf.ptr));
    const next = if (g_free_blocks[ci]) |h| @intFromPtr(h) else 0;
    @as(*usize, @ptrCast(@alignCast(p))).* = next;
    g_free_blocks[ci] = p;
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
    if (g_obj_free_head == 0xffff) return null;
    const idx = g_obj_free_head;
    g_obj_free_head = g_obj_next_free[idx];
    g_obj_live[idx] = true;
    g_obj_marked[idx] = false;
    g_obj_live_count += 1;
    return &g_obj_pool[idx];
}

fn objectIndex(ptr: *Object) ?usize {
    const base = @intFromPtr(&g_obj_pool[0]);
    const p = @intFromPtr(ptr);
    if (p < base) return null;
    const diff = p - base;
    const sz = @sizeOf(Object);
    if (diff % sz != 0) return null;
    const idx = diff / sz;
    if (idx >= MaxObjects) return null;
    return idx;
}

pub fn markObject(ptr: *Object) void {
    const idx = objectIndex(ptr) orelse return;
    if (!g_obj_live[idx]) return;
    g_obj_marked[idx] = true;
}

pub fn isObjectMarked(ptr: *Object) bool {
    const idx = objectIndex(ptr) orelse return false;
    return g_obj_live[idx] and g_obj_marked[idx];
}

pub fn isObjectLive(ptr: *Object) bool {
    const idx = objectIndex(ptr) orelse return false;
    return g_obj_live[idx];
}

pub fn sweepObjects() void {
    var i: usize = 0;
    while (i < MaxObjects) : (i += 1) {
        if (!g_obj_live[i]) continue;
        if (g_obj_marked[i]) {
            g_obj_marked[i] = false;
            continue;
        }
        switch (@as(ObjTag, g_obj_pool[i])) {
            .dyn_string => freeBytesManaged(g_obj_pool[i].dyn_string),
            .array_managed => freeManagedSlice(@import("../lang/value.zig").Value, g_obj_pool[i].array_managed),
            .map_managed => freeManagedSlice(@import("../lang/value.zig").MapEntry, g_obj_pool[i].map_managed),
            .map_hashed => {
                freeManagedSlice(@import("../lang/value.zig").MapEntry, g_obj_pool[i].map_hashed.entries);
                freeManagedSlice(i32, g_obj_pool[i].map_hashed.buckets);
            },
            else => {},
        }
        g_obj_live[i] = false;
        g_obj_next_free[i] = g_obj_free_head;
        g_obj_free_head = @intCast(i);
        g_obj_live_count -= 1;
    }
}

pub fn liveObjectCount() usize {
    return g_obj_live_count;
}

pub fn usedBytes() usize {
    return g_heap_pos;
}

pub fn snapshot() State {
    return .{
        .heap = g_heap,
        .heap_pos = g_heap_pos,
        .obj_pool = g_obj_pool,
        .obj_marked = g_obj_marked,
        .obj_live = g_obj_live,
        .obj_next_free = g_obj_next_free,
        .obj_free_head = g_obj_free_head,
        .obj_live_count = g_obj_live_count,
        .free_blocks = g_free_blocks,
    };
}

pub fn restore(state: State) void {
    g_heap = state.heap;
    g_heap_pos = state.heap_pos;
    g_obj_pool = state.obj_pool;
    g_obj_marked = state.obj_marked;
    g_obj_live = state.obj_live;
    g_obj_next_free = state.obj_next_free;
    g_obj_free_head = state.obj_free_head;
    g_obj_live_count = state.obj_live_count;
    g_free_blocks = state.free_blocks;
}
