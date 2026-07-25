const std = @import("std");
const cfg = @import("runtime_config");
const builtin = @import("builtin");
const build_options = @import("build_options");

const val_mod = @import("../lang/value.zig");
const Value = val_mod.Value;
const MapEntry = val_mod.MapEntry;
const StructFieldSpec = val_mod.StructFieldSpec;

pub const HeapSize = cfg.heap_size_bytes;
pub const MaxObjects = cfg.max_objects;
pub const FragmentationInfo = struct { free_bytes: usize, largest_block: usize };
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
    mark_worklist: [MaxObjects]*Object = undefined,
} else struct {};

var g_wasm_backing: WasmBacking = .{};

pub const State = struct {
    heap: []align(16) u8 = &[_]u8{},
    // Permanent region: bump()-allocated data (interned string constants,
    // closure upvalue arrays, struct/interface/variant field-type metadata,
    // native singleton objects, etc.) is bump-allocated from the TOP of the
    // heap downward. permanent_bump is its current low-water mark — it starts
    // at heap.len and only decreases. This data must live for the life of the
    // compiled program and is never tracked as a GC object, so it must never
    // share address space with the managed/collectible region below: the two
    // sides grow toward each other and an allocation on either side simply
    // fails (OOM) rather than being allowed to cross the other's current
    // frontier. This makes it structurally impossible for GC compaction to
    // ever overwrite permanent data, regardless of how much of it a script
    // needs — see the previous flat-mode/struct_type.fields incidents this
    // replaces, where a fixed-size compiler prefix could be exceeded and
    // spill into the shared managed-overflow arena, silently corrupted by a
    // later compaction pass that had no idea permanent data lived there.
    permanent_bump: usize = 0,
    class_bump: [ClassCount]usize = [_]usize{0} ** ClassCount,
    class_end: [ClassCount]usize = [_]usize{0} ** ClassCount,
    overflow_bump: usize = 0,
    overflow_base: usize = 0,
    obj_pool: []Object = &[_]Object{},
    obj_marked: []bool = &[_]bool{},
    obj_live: []bool = &[_]bool{},
    obj_next_free: []u16 = &[_]u16{},
    obj_free_head: u16 = 0xffff,
    obj_live_count: usize = 0,
    // Iterative GC mark worklist (scratch; only valid during a collection).
    // Sized to max_objects: each live object is pushed at most once.
    mark_worklist: []*Object = &[_]*Object{},
    mark_worklist_top: usize = 0,
    // Pool index of the object currently being swept; used by assertNotLive to
    // exclude the dead object's own region from the overlap check (it still has
    // obj_live=true when freeBytesManaged is called on its backing).
    sweep_exclude_idx: usize = 0xFFFF,
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
            self.mark_worklist = &g_wasm_backing.mark_worklist;
        } else {
            self.heap = try allocator.alignedAlloc(u8, .@"16", heap_size);
            self.obj_pool = try allocator.alloc(Object, max_objects);
            self.obj_marked = try allocator.alloc(bool, max_objects);
            self.obj_live = try allocator.alloc(bool, max_objects);
            self.obj_next_free = try allocator.alloc(u16, max_objects);
            self.mark_worklist = try allocator.alloc(*Object, max_objects);
        }

        val_mod.obj_pool_ptr = self.obj_pool.ptr;
        self.obj_free_head = 0;
        self.obj_live_count = 0;
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

        // Permanent (bump()) data now claims space dynamically from the top
        // of the heap as it's actually used — no fixed prefix reservation.
        self.permanent_bump = heap_size;

        // Partition the managed region (per-class regions + overflow),
        // starting at offset 0. compiler_sz_estimate is a heuristic only
        // (kept so the flat/partitioned boundary matches historical
        // behavior) — it no longer reserves any actual bytes.
        const compiler_sz_estimate = heap_size / 8;
        var offset: usize = 0;

        // Only partition if all classes' minimum (ClassSizes[ci]) plus the
        // heuristic overflow/permanent headroom fit in the heap. Otherwise
        // use flat mode where overflow serves as a shared bump (traditional
        // behavior). Small heaps stay in flat mode.
        var class_min_sum: usize = 0;
        for (0..self.class_count) |ci| class_min_sum += ClassSizes[ci];
        if (class_min_sum * 2 + compiler_sz_estimate <= heap_size) {
            // Partitioned mode: each class gets at least ClassSizes[ci] bytes.
            for (0..self.class_count) |ci| {
                const base = offset;
                var size = ClassSizes[ci];
                const remaining = heap_size - offset;
                if (size > remaining) size = remaining;
                self.class_bump[ci] = base;
                offset += size;
                self.class_end[ci] = offset;
            }
        } else {
            // Flat mode has no per-class reservations — every managed
            // allocation goes through the shared overflow bump.
            for (0..self.class_count) |ci| {
                self.class_bump[ci] = 0;
                self.class_end[ci] = 0;
            }
        }

        self.overflow_bump = offset;
        self.overflow_base = offset;
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
        if (self.mark_worklist.len > 0) self.allocator.free(self.mark_worklist);
        self.* = .{};
    }

    pub fn maxObjects(self: *const State) usize {
        return self.obj_pool.len;
    }

    // ── Private helpers ────────────────────────────────────────────────────

    fn classIndexFor(self: *State, n: usize) ?usize {
        var i: usize = 0;
        while (i < self.class_count) : (i += 1) {
            if (n <= ClassSizes[i]) return i;
        }
        return null;
    }

    fn assertNotLive(self: *State, buf: []u8) void {
        const std_ = @import("std");
        const lo = @intFromPtr(buf.ptr);
        const hi = lo + buf.len;
        var i: usize = 0;
        while (i < self.obj_pool.len) : (i += 1) {
            if (!self.obj_live[i]) continue;
            if (i == self.sweep_exclude_idx) continue; // the dead object being swept
            const region: ?[]const u8 = switch (self.obj_pool[i]) {
                .dyn_string => |ds| ds,
                .string_builder => |sb| sb.buf,
                .array_managed => |am| std_.mem.sliceAsBytes(am),
                .map => |m| std_.mem.sliceAsBytes(m),
                .map_managed => |mm| std_.mem.sliceAsBytes(mm),
                .map_hashed => |mh| std_.mem.sliceAsBytes(mh.entries),
                .struct_instance => |si| std_.mem.sliceAsBytes(si.fields),
                .variant_value => |vv| std_.mem.sliceAsBytes(vv.arm_fields),
                .closure => |cl| std_.mem.sliceAsBytes(cl.upvalues),
                else => null,
            };
            if (region) |r| {
                if (r.len == 0) continue;
                const rlo = @intFromPtr(r.ptr);
                const rhi = rlo + r.len;
                if (lo < rhi and rlo < hi) {
                    std_.debug.print(
                        "VM integrity failure [CorruptedObjectHandle] gc_live={d}\n  freeing {x}..{x} overlaps live obj {d} ({s}) {x}..{x}\n",
                        .{ self.obj_live_count, lo, hi, i, @tagName(self.obj_pool[i]), rlo, rhi },
                    );
                    @panic("VM integrity failure [CorruptedObjectHandle]");
                }
            }
        }
    }

    fn takeFreeBlock(self: *State, ci: usize) ?[]u8 {
        if (self.free_blocks[ci]) |head| {
            const next_ptr = @as(*usize, @ptrCast(@alignCast(head))).*;
            self.free_blocks[ci] = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
            const blk = @as([*]u8, @ptrCast(head))[0..ClassSizes[ci]];
            if (paranoiaOn()) self.assertNotLive(blk);
            return blk;
        }
        return null;
    }

    fn splitLargerFreeBlock(self: *State, ci: usize) ?[]u8 {
        var split_ci = ci + 1;
        while (split_ci < self.class_count) : (split_ci += 1) {
            if (self.free_blocks[split_ci]) |head| {
                const next_ptr = @as(*usize, @ptrCast(@alignCast(head))).*;
                self.free_blocks[split_ci] = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
                // Split from split_ci down to ci, placing upper buddies in intermediate lists.
                var cur_ci = split_ci;
                var cur_ptr = @as([*]u8, @ptrCast(head));
                while (cur_ci > ci) {
                    cur_ci -= 1;
                    const half = ClassSizes[cur_ci];
                    const buddy = cur_ptr + half;
                    const buddy_next = if (self.free_blocks[cur_ci]) |h| @intFromPtr(h) else 0;
                    @as(*usize, @ptrCast(@alignCast(buddy))).* = buddy_next;
                    self.free_blocks[cur_ci] = @ptrCast(buddy);
                }
                const blk = cur_ptr[0..ClassSizes[ci]];
                if (paranoiaOn()) self.assertNotLive(blk);
                return blk;
            }
        }
        return null;
    }

    // Remove a block at target_addr from free list ci. Returns true if found.
    fn removeFromFreeList(self: *State, ci: usize, target_addr: usize) bool {
        var prev: ?*u8 = null;
        var cur: ?*u8 = self.free_blocks[ci];
        while (cur) |node| {
            const next_val = @as(*usize, @ptrCast(@alignCast(node))).*;
            const next_node: ?*u8 = if (next_val == 0) null else @as(*u8, @ptrFromInt(next_val));
            if (@intFromPtr(node) == target_addr) {
                if (prev) |p| {
                    @as(*usize, @ptrCast(@alignCast(p))).* = next_val;
                } else {
                    self.free_blocks[ci] = next_node;
                }
                return true;
            }
            prev = node;
            cur = next_node;
        }
        return false;
    }

    fn objectIndex(self: *State, ptr: *Object) ?usize {
        if (self.obj_pool.len == 0) return null;
        const base = @intFromPtr(self.obj_pool.ptr);
        const p = @intFromPtr(ptr);
        if (p < base) return null;
        const diff = p - base;
        const sz = @sizeOf(Object);
        if (diff % sz != 0) return null;
        const idx = diff / sz;
        if (idx >= self.obj_pool.len) return null;
        return idx;
    }

    fn addLargestBlocksToFreeList(self: *State, start_addr: usize, len: usize) void {
        var off: usize = 0;
        while (off < len) {
            const remaining = len - off;
            // Find the largest class that fits.
            var ci = self.class_count - 1;
            while (ci > 0 and ClassSizes[ci] > remaining) : (ci -= 1) {}
            const class_size = ClassSizes[ci];
            if (class_size > remaining) return;

            const addr = start_addr + off;
            const p = @as(*u8, @ptrFromInt(addr));
            const next = if (self.free_blocks[ci]) |h| @intFromPtr(h) else 0;
            @as(*usize, @ptrCast(@alignCast(p))).* = next;
            self.free_blocks[ci] = p;
            off += class_size;
        }
    }

    // Return the managed block size (ClassSizes[ci]) for a raw byte count.
    fn managedBlockSize(self: *State, byte_len: usize) usize {
        if (byte_len == 0) return 0;
        const ci = self.classIndexFor(byte_len) orelse return 0;
        return ClassSizes[ci];
    }

    fn compactFillBlocks(self: *State, obj: *const Object, out: []CompactReloc) usize {
        var n: usize = 0;
        switch (obj.*) {
            .dyn_string => |s| {
                if (s.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(s.ptr), .block_size = self.managedBlockSize(s.len), .new_addr = 0 };
                    n += 1;
                }
            },
            .string_builder => |sb| {
                if (sb.buf.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(sb.buf.ptr), .block_size = self.managedBlockSize(sb.buf.len), .new_addr = 0 };
                    n += 1;
                }
            },
            .array_managed => |a| {
                if (a.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(a.ptr), .block_size = self.managedBlockSize(a.len * @sizeOf(Value)), .new_addr = 0 };
                    n += 1;
                }
            },
            .map => |m| {
                if (m.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(m.ptr), .block_size = self.managedBlockSize(m.len * @sizeOf(MapEntry)), .new_addr = 0 };
                    n += 1;
                }
            },
            .map_managed => |m| {
                if (m.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(m.ptr), .block_size = self.managedBlockSize(m.len * @sizeOf(MapEntry)), .new_addr = 0 };
                    n += 1;
                }
            },
            .map_hashed => |mh| {
                if (mh.entries.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(mh.entries.ptr), .block_size = self.managedBlockSize(mh.entries.len * @sizeOf(MapEntry)), .new_addr = 0 };
                    n += 1;
                }
                if (mh.buckets.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(mh.buckets.ptr), .block_size = self.managedBlockSize(mh.buckets.len * @sizeOf(i32)), .new_addr = 0 };
                    n += 1;
                }
            },
            .struct_instance => |si| {
                if (si.fields.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(si.fields.ptr), .block_size = self.managedBlockSize(si.fields.len * @sizeOf(MapEntry)), .new_addr = 0 };
                    n += 1;
                }
            },
            .closure => |cl| {
                if (cl.upvalues.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(cl.upvalues.ptr), .block_size = self.managedBlockSize(cl.upvalues.len * @sizeOf(*Object)), .new_addr = 0 };
                    n += 1;
                }
            },
            .struct_type => |st| {
                if (st.fields.len > 0) {
                    const addr = @intFromPtr(st.fields.ptr);
                    if (isManagedAddr(self, addr)) {
                        out[n] = .{ .old_addr = addr, .block_size = st.fields.len * @sizeOf(StructFieldSpec), .new_addr = 0 };
                        n += 1;
                    }
                }
            },
            .variant_value => |vv| {
                if (vv.arm_fields.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(vv.arm_fields.ptr), .block_size = self.managedBlockSize(vv.arm_fields.len * @sizeOf(Value)), .new_addr = 0 };
                    n += 1;
                }
                if (vv.shared_values.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(vv.shared_values.ptr), .block_size = self.managedBlockSize(vv.shared_values.len * @sizeOf(Value)), .new_addr = 0 };
                    n += 1;
                }
            },
            .bigint => |bi| {
                if (bi.limbs.len > 0) {
                    out[n] = .{ .old_addr = @intFromPtr(bi.limbs.ptr), .block_size = self.managedBlockSize(bi.limbs.len * @sizeOf(@import("std").math.big.Limb)), .new_addr = 0 };
                    n += 1;
                }
            },
            else => {},
        }
        return n;
    }

    // ── Public methods ─────────────────────────────────────────────────────

    pub fn reset(self: *State) void {
        if (self.obj_pool.len == 0 and self == &g_default_state) {
            _ = g_default_state.init(HeapSize, MaxObjects, self.allocator) catch {};
        }
        self.permanent_bump = self.heap.len;
        var class_base: usize = 0;
        for (0..self.class_count) |ci| {
            self.class_bump[ci] = class_base;
            class_base = self.class_end[ci];
        }
        self.overflow_bump = self.overflow_base;
        var c: usize = 0;
        while (c < ClassCount) : (c += 1) self.free_blocks[c] = null;
        const max = self.obj_pool.len;
        var i: usize = 0;
        while (i < max) : (i += 1) {
            self.obj_marked[i] = false;
            self.obj_live[i] = false;
            self.obj_next_free[i] = @intCast(i + 1);
        }
        if (max > 0) {
            self.obj_next_free[max - 1] = 0xffff;
        }
        self.obj_free_head = 0;
        self.obj_live_count = 0;
    }

    // Largest single managed allocation the active heap supports.
    pub fn maxManagedAlloc(self: *State) usize {
        return ClassSizes[self.class_count - 1];
    }

    // Returns true if allocating n bytes would expand the bump pointer (i.e., the
    // slab free list for the class has no available block). Callers can use this
    // to decide whether to run GC proactively before a large allocation.
    pub fn wouldBump(self: *State, n: usize) bool {
        if (n == 0) return false;
        const ci = self.classIndexFor(n) orelse return false; // too large for slab → handled separately
        return self.free_blocks[ci] == null;
    }

    pub fn bump(self: *State, comptime T: type, n: usize) ?[*]T {
        const al: usize = @alignOf(T);
        const mask: usize = al - 1;
        const sz = @sizeOf(T) * n;
        // Bump DOWN from the top of the heap. Round the candidate start down
        // to alignment — this may waste up to (al - 1) bytes as padding above
        // the returned block, never fewer bytes than requested.
        if (sz > self.permanent_bump) return null;
        const pos = (self.permanent_bump - sz) & ~mask;
        // Must not cross into the managed/collectible region's current
        // frontier (overflow_bump is always >= every class region's extent,
        // so this one check is sufficient — see the permanent_bump field doc).
        if (pos < self.overflow_bump) return null;
        self.permanent_bump = pos;
        // Range-slice (not single-element index) so pos == heap.len is legal
        // for a zero-size request — permanent_bump starts at heap.len, so the
        // very first bump() call (even n == 0) can land exactly there.
        return @as([*]T, @ptrCast(@alignCast(self.heap[pos..].ptr)));
    }

    pub fn allocBytesManaged(self: *State, n: usize) ?[]u8 {
        if (n == 0) return &[_]u8{};
        const ci = self.classIndexFor(n) orelse return null;
        if (self.takeFreeBlock(ci)) |blk| return blk;
        // Try bump from class-dedicated region. ClassSizes and bases are
        // multiples of ManagedAlign so no alignment mask is needed.
        const cpos = self.class_bump[ci];
        if (cpos + ClassSizes[ci] <= self.class_end[ci]) {
            self.class_bump[ci] = cpos + ClassSizes[ci];
            return self.heap[cpos .. cpos + ClassSizes[ci]];
        }
        // Try overflow bump — shared space after all class regions. This is the
        // sequential fallback that keeps small heaps working while the per-class
        // regions provide the isolation guarantee for steady-state operation.
        const mask: usize = ManagedAlign - 1;
        const opos = (self.overflow_bump + mask) & ~mask;
        // Ceiling is the current permanent-region floor, not heap.len — the
        // two bump directions must never cross (see permanent_bump's doc).
        if (opos + ClassSizes[ci] <= self.permanent_bump) {
            self.overflow_bump = opos + ClassSizes[ci];
            return self.heap[opos .. opos + ClassSizes[ci]];
        }
        // Bump exhausted: try buddy-splitting a larger free block.
        // ClassSizes are exact powers of 2, so splitting is lossless.
        if (self.splitLargerFreeBlock(ci)) |blk| return blk;

        // Last resort: when enough bytes are already free but stranded across
        // class lists, rebuild the free lists before reporting OOM.
        const info = self.fragmentationInfo();
        if (info.free_bytes >= ClassSizes[ci] and info.largest_block < ClassSizes[ci]) {
            self.defragmentFreeLists();
            if (self.takeFreeBlock(ci)) |blk| return blk;
            if (self.splitLargerFreeBlock(ci)) |blk| return blk;
        }
        return null;
    }

    pub fn freeBytesManaged(self: *State, buf: []u8) void {
        if (buf.len == 0) return;
        if (paranoiaOn()) self.assertNotLive(buf);
        const ci = self.classIndexFor(buf.len) orelse return;
        const p_addr = @intFromPtr(buf.ptr);

        // Coalesce: if an adjacent free block of the same class exists, merge them
        // into a ci+1 block and recurse. Any two adjacent free blocks form a valid
        // larger block regardless of how they were originally allocated.
        if (ci + 1 < self.class_count) {
            // Try upper buddy: block immediately after us.
            const upper_addr = p_addr + ClassSizes[ci];
            if (self.removeFromFreeList(ci, upper_addr)) {
                const merged = @as([*]u8, @ptrCast(buf.ptr))[0..ClassSizes[ci + 1]];
                self.freeBytesManaged(merged);
                return;
            }
            // Try lower buddy: block immediately before us.
            if (p_addr >= ClassSizes[ci]) {
                const lower_addr = p_addr - ClassSizes[ci];
                if (lower_addr >= @intFromPtr(self.heap.ptr) and self.removeFromFreeList(ci, lower_addr)) {
                    const merged = @as([*]u8, @ptrFromInt(lower_addr))[0..ClassSizes[ci + 1]];
                    self.freeBytesManaged(merged);
                    return;
                }
            }
        }

        const p = @as(*u8, @ptrCast(buf.ptr));
        const next = if (self.free_blocks[ci]) |h| @intFromPtr(h) else 0;
        @as(*usize, @ptrCast(@alignCast(p))).* = next;
        self.free_blocks[ci] = p;
    }

    pub fn allocManagedSlice(self: *State, comptime T: type, n: usize) ?[]T {
        if (n == 0) return &[_]T{};
        const need = @sizeOf(T) * n;
        const bytes = self.allocBytesManaged(need) orelse return null;
        const p = @as([*]T, @ptrCast(@alignCast(bytes.ptr)));
        return p[0..n];
    }

    pub fn freeManagedSlice(self: *State, comptime T: type, s: []T) void {
        if (s.len == 0) return;
        const need = @sizeOf(T) * s.len;
        const ci = self.classIndexFor(need) orelse return;
        const block = @as([*]u8, @ptrCast(s.ptr))[0..ClassSizes[ci]];
        self.freeBytesManaged(block);
    }

    pub fn allocObject(self: *State) ?*Object {
        if (self.obj_free_head == 0xffff) return null;
        const idx = self.obj_free_head;
        self.obj_free_head = self.obj_next_free[idx];
        self.obj_live[idx] = true;
        self.obj_marked[idx] = false;
        self.obj_live_count += 1;
        return &self.obj_pool[idx];
    }

    // Returns the object pool index (0..maxObjects-1) or 0xFFFF if ptr is not in the pool.
    pub fn objectPoolIndex(self: *State, ptr: *Object) u16 {
        const idx = self.objectIndex(ptr) orelse return 0xFFFF;
        return @intCast(idx);
    }

    // Returns a pointer to the object at the given pool index.
    pub fn objectAt(self: *State, idx: u16) *Object {
        return &self.obj_pool[idx];
    }

    pub fn markObject(self: *State, ptr: *Object) void {
        const idx = self.objectIndex(ptr) orelse return;
        if (!self.obj_live[idx]) return;
        self.obj_marked[idx] = true;
    }

    pub fn isObjectMarked(self: *State, ptr: *Object) bool {
        const idx = self.objectIndex(ptr) orelse return false;
        return self.obj_live[idx] and self.obj_marked[idx];
    }

    pub fn isObjectLive(self: *State, ptr: *Object) bool {
        const idx = self.objectIndex(ptr) orelse return false;
        return self.obj_live[idx];
    }

    // True when ptr lives outside the object pool: a bump-allocated or static
    // singleton (std type objects, the shared empty-args array). Such objects
    // are never swept, so they are immortal by construction.
    pub fn isObjectImmortal(self: *State, ptr: *Object) bool {
        return self.objectIndex(ptr) == null;
    }

    pub fn sweepObjects(self: *State) void {
        const max = self.obj_pool.len;
        var i: usize = 0;
        while (i < max) : (i += 1) {
            if (!self.obj_live[i]) continue;
            if (self.obj_marked[i]) {
                self.obj_marked[i] = false;
                continue;
            }
            if (paranoiaOn()) self.sweep_exclude_idx = i;
            switch (@as(ObjTag, self.obj_pool[i])) {
                .dyn_string => self.freeBytesManaged(self.obj_pool[i].dyn_string),
                .array_managed => self.freeManagedSlice(@import("../lang/value.zig").Value, self.obj_pool[i].array_managed),
                .map_managed => self.freeManagedSlice(@import("../lang/value.zig").MapEntry, self.obj_pool[i].map_managed),
                .map_hashed => {
                    self.freeManagedSlice(@import("../lang/value.zig").MapEntry, self.obj_pool[i].map_hashed.entries);
                    self.freeManagedSlice(i32, self.obj_pool[i].map_hashed.buckets);
                },
                .map => self.freeManagedSlice(@import("../lang/value.zig").MapEntry, self.obj_pool[i].map),
                .struct_instance => self.freeManagedSlice(@import("../lang/value.zig").MapEntry, self.obj_pool[i].struct_instance.fields),
                .closure => self.freeManagedSlice(*Object, self.obj_pool[i].closure.upvalues),
                .string_builder => self.freeBytesManaged(self.obj_pool[i].string_builder.buf),
                .bigint => self.freeManagedSlice(@import("std").math.big.Limb, self.obj_pool[i].bigint.limbs),
                .string_view => {},
                .variant_value => {
                    const vv = self.obj_pool[i].variant_value;
                    if (vv.arm_fields.len > 0) self.freeManagedSlice(@import("../lang/value.zig").Value, vv.arm_fields);
                    if (vv.shared_values.len > 0) self.freeManagedSlice(@import("../lang/value.zig").Value, vv.shared_values);
                },
                else => {},
            }
            self.obj_live[i] = false;
            self.obj_next_free[i] = self.obj_free_head;
            self.obj_free_head = @intCast(i);
            self.obj_live_count -= 1;
        }
    }

    pub fn liveObjectCount(self: *State) usize {
        return self.obj_live_count;
    }

    pub fn usedBytes(self: *State) usize {
        var total = self.heap.len - self.permanent_bump;
        var prev_end: usize = 0;
        for (0..self.class_count) |ci| {
            const cb = self.class_bump[ci];
            if (cb > prev_end) total += cb - prev_end;
            prev_end = self.class_end[ci];
        }
        const ob = self.overflow_bump;
        if (ob > prev_end) total += ob - prev_end;
        return total;
    }

    // Returns total bytes sitting in free lists across all classes.
    pub fn totalFreeListBytes(self: *State) usize {
        var total: usize = 0;
        for (0..self.class_count) |ci| {
            var node = self.free_blocks[ci];
            while (node) |n| {
                total += ClassSizes[ci];
                const next_ptr = @as(*usize, @ptrCast(@alignCast(n))).*;
                node = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
            }
        }
        return total;
    }

    // Returns total free bytes in free lists and the largest single free block.
    pub fn fragmentationInfo(self: *State) FragmentationInfo {
        var free_bytes: usize = 0;
        var largest_block: usize = 0;
        for (0..self.class_count) |ci| {
            var depth: usize = 0;
            var node = self.free_blocks[ci];
            while (node) |n| {
                depth += 1;
                node = nextFreeBlock(n);
            }
            const bytes = depth * ClassSizes[ci];
            free_bytes += bytes;
            if (depth > 0 and ClassSizes[ci] > largest_block) {
                largest_block = ClassSizes[ci];
            }
        }
        return .{ .free_bytes = free_bytes, .largest_block = largest_block };
    }

    // Collects all free blocks from all classes, sorts by address, merges
    // adjacent blocks, and rebuilds the free lists with the largest possible
    // class blocks. This recovers fragmentation where adjacent free blocks of
    // different classes prevent buddy coalescing.
    pub fn defragmentFreeLists(self: *State) void {
        // Count total free blocks across all classes.
        var total: usize = 0;
        for (0..self.class_count) |ci| {
            var node = self.free_blocks[ci];
            while (node) |n| {
                total += 1;
                node = nextFreeBlock(n);
            }
        }
        if (total < 2) return;

        // Collect all free blocks into a buffer.
        const FreeBlock = struct { addr: usize, size: usize };
        var stack_buf: [512]FreeBlock = undefined;
        const heap_buf = if (total <= stack_buf.len)
            null
        else
            self.allocator.alloc(FreeBlock, total) catch return;
        defer if (heap_buf) |buf| self.allocator.free(buf);
        const buf = if (heap_buf) |owned| owned else stack_buf[0..total];

        var count: usize = 0;
        for (0..self.class_count) |ci| {
            var node = self.free_blocks[ci];
            while (node) |n| {
                buf[count] = .{ .addr = @intFromPtr(n), .size = ClassSizes[ci] };
                count += 1;
                node = nextFreeBlock(n);
            }
        }

        // Clear free lists — we'll rebuild them from merged blocks.
        for (0..self.class_count) |ci| {
            self.free_blocks[ci] = null;
        }

        // Sort by address.
        std.sort.block(FreeBlock, buf[0..count], {}, struct {
            fn lessThan(_: void, a: FreeBlock, b: FreeBlock) bool {
                return a.addr < b.addr;
            }
        }.lessThan);

        // Merge adjacent blocks and add to free lists.
        var i: usize = 0;
        while (i < count) {
            const cur_addr = buf[i].addr;
            var cur_end = cur_addr + buf[i].size;

            var j = i + 1;
            while (j < count and buf[j].addr == cur_end) : (j += 1) {
                cur_end += buf[j].size;
            }

            self.addLargestBlocksToFreeList(cur_addr, cur_end - cur_addr);
            i = j;
        }
    }

    // Move all live managed allocations to a contiguous region at managed_start,
    // then reset the bump pointer so all freed space forms one contiguous block.
    // Safe to call after sweepObjects(); must not be called while allocations are
    // in flight. Pointer updates cover owning objects, sub-slice views, and
    // iterator slice references.
    pub fn compactManagedHeap(self: *State) void {
        // Phase 1: count live managed blocks.
        var count: usize = 0;
        for (0..self.obj_pool.len) |i| {
            if (self.obj_live[i]) count += compactCountBlocks(self, &self.obj_pool[i]);
        }
        if (count == 0) return;

        // Phase 2: allocate reloc table (prefer stack).
        // Typical live_objs counts are low (a few hundred), but worst-case
        // every object owns two blocks (map_hashed: entries + buckets,
        // variant_value: arm_fields + shared_values).  The stack buffer is
        // sized to MaxObjects * 2 capped at 2048 entries (48 KiB) so the
        // common case never hits the native allocator.  For very large presets
        // (16 m, unlimited) with more live objects we fall back to a heap
        // allocation that page_allocator handles trivially on native targets.
        const StkCap = @min(MaxObjects * 2, 2048);
        var sbuf: [StkCap]CompactReloc = undefined;
        const dbuf: ?[]CompactReloc = if (count > sbuf.len)
            (self.allocator.alloc(CompactReloc, count) catch return)
        else
            null;
        defer if (dbuf) |b| self.allocator.free(b);
        const relocs: []CompactReloc = if (dbuf) |b| b else sbuf[0..count];

        // Phase 3: fill reloc table.
        var ri: usize = 0;
        for (0..self.obj_pool.len) |i| {
            if (self.obj_live[i]) ri += self.compactFillBlocks(&self.obj_pool[i], relocs[ri..]);
        }

        // Phase 4: sort relocs by old address so we can copy in ascending order
        // (guarantees new_addr[i] <= old_addr[i], making copyForwards safe).
        std.sort.block(CompactReloc, relocs[0..count], {}, struct {
            fn lt(_: void, a: CompactReloc, b: CompactReloc) bool {
                return a.old_addr < b.old_addr;
            }
        }.lt);

        // Phase 5: compute new addresses, packing to the managed region's
        // start (address 0 — there's no fixed compiler prefix anymore).
        const heap_base = @intFromPtr(self.heap.ptr);
        const align_mask: usize = ManagedAlign - 1;
        var dest: usize = heap_base;
        for (relocs[0..count]) |*r| {
            dest = (dest + align_mask) & ~align_mask;
            r.new_addr = dest;
            dest += r.block_size;
        }

        // Phase 6: copy blocks to new positions. new_addr[i] <= old_addr[i] always
        // (proven by induction on sorted order), so copyForwards is safe even when
        // source and destination ranges partially overlap.
        for (relocs[0..count]) |r| {
            if (r.new_addr == r.old_addr) continue;
            const src: [*]const u8 = @ptrFromInt(r.old_addr);
            const dst: [*]u8 = @ptrFromInt(r.new_addr);
            std.mem.copyForwards(u8, dst[0..r.block_size], src[0..r.block_size]);
        }

        // Phase 7: update owning slice pointers and all derived view/iterator slices.
        for (0..self.obj_pool.len) |i| {
            if (self.obj_live[i]) compactUpdateObj(&self.obj_pool[i], relocs[0..count]);
        }

        // Phase 8: reset bump state. All class bumps are exhausted; the overflow
        // bump starts right after the packed live data. Free lists are cleared
        // because all free space is now contiguous at [dest..heap.len].
        const dest_off = dest - heap_base;
        for (0..self.class_count) |ci| {
            self.class_bump[ci] = self.class_end[ci];
            self.free_blocks[ci] = null;
        }
        self.overflow_bump = if (dest_off > self.overflow_base) dest_off else self.overflow_base;
    }

    // Writes a compact free-list summary: "ci=N:depth,..." for non-empty classes.
    // buf must be large enough; returns the slice written.
    pub fn freeListSummary(self: *State, buf: []u8) []u8 {
        var pos: usize = 0;
        var first = true;
        for (0..self.class_count) |ci| {
            var depth: usize = 0;
            var node = self.free_blocks[ci];
            while (node) |n| {
                depth += 1;
                const next_ptr = @as(*usize, @ptrCast(@alignCast(n))).*;
                node = if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
            }
            if (depth == 0) continue;
            if (!first) {
                if (pos < buf.len) {
                    buf[pos] = ',';
                    pos += 1;
                }
            }
            first = false;
            // write "ci=N:depth"
            const prefix = "ci=";
            for (prefix) |c| {
                if (pos < buf.len) {
                    buf[pos] = c;
                    pos += 1;
                }
            }
            // ci index as decimal
            var tmp: [4]u8 = undefined;
            var n: usize = ci;
            var tlen: usize = 0;
            if (n == 0) {
                tmp[0] = '0';
                tlen = 1;
            } else {
                while (n > 0) : (n /= 10) {
                    tmp[tlen] = @intCast('0' + n % 10);
                    tlen += 1;
                }
                std.mem.reverse(u8, tmp[0..tlen]);
            }
            for (tmp[0..tlen]) |c| {
                if (pos < buf.len) {
                    buf[pos] = c;
                    pos += 1;
                }
            }
            if (pos < buf.len) {
                buf[pos] = ':';
                pos += 1;
            }
            // depth as decimal
            var d: usize = depth;
            var dlen: usize = 0;
            var dtmp: [8]u8 = undefined;
            if (d == 0) {
                dtmp[0] = '0';
                dlen = 1;
            } else {
                while (d > 0) : (d /= 10) {
                    dtmp[dlen] = @intCast('0' + d % 10);
                    dlen += 1;
                }
                std.mem.reverse(u8, dtmp[0..dlen]);
            }
            for (dtmp[0..dlen]) |c| {
                if (pos < buf.len) {
                    buf[pos] = c;
                    pos += 1;
                }
            }
        }
        return buf[0..pos];
    }
};

var g_default_state: State = .{};
pub threadlocal var g_state: *State = &g_default_state;

pub fn setActive(state: *State) void {
    if (state.obj_pool.len == 0 and state == &g_default_state) {
        _ = state.init(HeapSize, MaxObjects, state.allocator) catch {};
    }
    g_state = state;
    // Keep the inline-value decode base (named_scalar/inline_variant pool
    // indices) pointed at the active heap's object pool, so values decode
    // against the runtime that produced them when runtimes are switched.
    if (state.obj_pool.len > 0) val_mod.obj_pool_ptr = state.obj_pool.ptr;
}

pub fn reset() void {
    g_state.reset();
}

// Largest single managed allocation the active heap supports.

// Returns true if allocating n bytes would expand the bump pointer (i.e., the
// slab free list for the class has no available block). Callers can use this
// to decide whether to run GC proactively before a large allocation.

pub fn bump(comptime T: type, n: usize) ?[*]T {
    return g_state.bump(T, n);
}

pub fn allocBytesManaged(n: usize) ?[]u8 {
    return g_state.allocBytesManaged(n);
}

pub fn freeBytesManaged(buf: []u8) void {
    g_state.freeBytesManaged(buf);
}

pub fn allocObject() ?*Object {
    return g_state.allocObject();
}

// Returns the object pool index (0..maxObjects-1) or 0xFFFF if ptr is not in the pool.
pub fn objectPoolIndex(ptr: *Object) u16 {
    return g_state.objectPoolIndex(ptr);
}

// Returns a pointer to the object at the given pool index.

pub fn markObject(ptr: *Object) void {
    g_state.markObject(ptr);
}

pub fn isObjectLive(ptr: *Object) bool {
    return g_state.isObjectLive(ptr);
}

pub fn sweepObjects() void {
    g_state.sweepObjects();
}

pub fn liveObjectCount() usize {
    return g_state.liveObjectCount();
}

// Returns total bytes sitting in free lists across all classes.

// Returns total free bytes in free lists and the largest single free block.
pub fn fragmentationInfo() FragmentationInfo {
    return g_state.fragmentationInfo();
}

// Collects all free blocks from all classes, sorts by address, merges
// adjacent blocks, and rebuilds the free lists with the largest possible
// class blocks. This recovers fragmentation where adjacent free blocks of
// different classes prevent buddy coalescing.
pub fn defragmentFreeLists() void {
    g_state.defragmentFreeLists();
}

// Move all live managed allocations to a contiguous region at managed_start,
// then reset the bump pointer so all freed space forms one contiguous block.
pub fn compactManagedHeap() void {
    g_state.compactManagedHeap();
}

// Writes a compact free-list summary: "ci=N:depth,..." for non-empty classes.
// buf must be large enough; returns the slice written.

// Debug tripwire. Enabled at compile time via -Dheap_paranoia=true, or at
// runtime when the CLI sees GENGO_HEAP_PARANOIA=1.
pub var paranoia: bool = false;
fn paranoiaOn() bool {
    if (comptime build_options.heap_paranoia) return true;
    return paranoia;
}

// ── Managed heap compaction ────────────────────────────────────────────────
//
// Moves all live managed allocations to a contiguous region at the start of
// the managed heap, freeing all fragmented space as one large contiguous
// block at the end. Unlike defragmentFreeLists (which only merges adjacent
// FREE blocks), compaction moves LIVE allocations, eliminating fragmentation
// caused by live objects interleaved with freed space.
//
// After compaction:
//   - All live managed bytes occupy [managed_start .. dest]
//   - All class bumps are exhausted (set to class_end)
//   - overflow_bump = max(overflow_base, dest) — new allocations bump from here
//   - All free lists are cleared
//
// Sub-slice views (string_view.bytes, array_view.items) and iterator slices
// are updated in a second pass using a reloc table binary search so that
// sub-slices into moved blocks get the correct offset-adjusted new pointer.

const CompactReloc = struct {
    old_addr: usize,
    block_size: usize,
    new_addr: usize,
};

// Binary search: find the CompactReloc entry whose range [old_addr, old_addr+block_size)
// contains `addr`. Returns the corresponding new address (with offset applied), or null.
fn compactFindReloc(relocs: []const CompactReloc, addr: usize) ?usize {
    if (relocs.len == 0) return null;
    var lo: usize = 0;
    var hi: usize = relocs.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (relocs[mid].old_addr <= addr) lo = mid else hi = mid;
    }
    const r = relocs[lo];
    if (addr < r.old_addr or addr >= r.old_addr + r.block_size) return null;
    return r.new_addr + (addr - r.old_addr);
}

// Returns true if the raw address falls within the managed/collectible heap
// region (below the current permanent-region floor) rather than the
// permanent (bump()) region. With the two-ended arena this should never be
// true for permanent data — struct_type.fields and similar bump()-allocated
// metadata now always live at or above permanent_bump — but the check stays
// as defense in depth for compaction's relocation logic.
fn isManagedAddr(self: *const State, addr: usize) bool {
    const heap_base = @intFromPtr(self.heap.ptr);
    const heap_end = heap_base + self.heap.len;
    if (addr < heap_base or addr >= heap_end) return false;
    return addr < heap_base + self.permanent_bump;
}

fn compactCountBlocks(self: *const State, obj: *const Object) usize {
    return switch (obj.*) {
        .dyn_string => |s| if (s.len > 0) 1 else 0,
        .string_builder => |sb| if (sb.buf.len > 0) 1 else 0,
        .array_managed => |a| if (a.len > 0) 1 else 0,
        .map => |m| if (m.len > 0) 1 else 0,
        .map_managed => |m| if (m.len > 0) 1 else 0,
        .map_hashed => |mh| blk: {
            var n: usize = 0;
            if (mh.entries.len > 0) n += 1;
            if (mh.buckets.len > 0) n += 1;
            break :blk n;
        },
        .struct_instance => |si| if (si.fields.len > 0) 1 else 0,
        .closure => |cl| if (cl.upvalues.len > 0) 1 else 0,
        .struct_type => |st| if (st.fields.len > 0 and isManagedAddr(self, @intFromPtr(st.fields.ptr))) 1 else 0,
        .variant_value => |vv| blk: {
            var n: usize = 0;
            if (vv.arm_fields.len > 0) n += 1;
            if (vv.shared_values.len > 0) n += 1;
            break :blk n;
        },
        .bigint => |bi| if (bi.limbs.len > 0) 1 else 0,
        else => 0,
    };
}

fn compactUpdateObj(obj: *Object, relocs: []const CompactReloc) void {
    switch (obj.*) {
        .dyn_string => |*s| {
            if (s.len > 0) if (compactFindReloc(relocs, @intFromPtr(s.ptr))) |na| {
                s.* = @as([*]u8, @ptrFromInt(na))[0..s.len];
            };
        },
        .string_builder => |*sb| {
            if (sb.buf.len > 0) if (compactFindReloc(relocs, @intFromPtr(sb.buf.ptr))) |na| {
                sb.buf = @as([*]u8, @ptrFromInt(na))[0..sb.buf.len];
            };
        },
        .array_managed => |*a| {
            if (a.len > 0) if (compactFindReloc(relocs, @intFromPtr(a.ptr))) |na| {
                a.* = @as([*]Value, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..a.len];
            };
        },
        .map => |*m| {
            if (m.len > 0) if (compactFindReloc(relocs, @intFromPtr(m.ptr))) |na| {
                m.* = @as([*]MapEntry, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..m.len];
            };
        },
        .map_managed => |*m| {
            if (m.len > 0) if (compactFindReloc(relocs, @intFromPtr(m.ptr))) |na| {
                m.* = @as([*]MapEntry, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..m.len];
            };
        },
        .map_hashed => |*mh| {
            if (mh.entries.len > 0) if (compactFindReloc(relocs, @intFromPtr(mh.entries.ptr))) |na| {
                mh.entries = @as([*]MapEntry, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..mh.entries.len];
            };
            if (mh.buckets.len > 0) if (compactFindReloc(relocs, @intFromPtr(mh.buckets.ptr))) |na| {
                mh.buckets = @as([*]i32, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..mh.buckets.len];
            };
        },
        .struct_instance => |*si| {
            if (si.fields.len > 0) if (compactFindReloc(relocs, @intFromPtr(si.fields.ptr))) |na| {
                si.fields = @as([*]MapEntry, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..si.fields.len];
            };
        },
        .closure => |*cl| {
            if (cl.upvalues.len > 0) if (compactFindReloc(relocs, @intFromPtr(cl.upvalues.ptr))) |na| {
                cl.upvalues = @as([*]*Object, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..cl.upvalues.len];
            };
        },
        .struct_type => |*st| {
            if (st.fields.len > 0) if (compactFindReloc(relocs, @intFromPtr(st.fields.ptr))) |na| {
                st.fields = @as([*]StructFieldSpec, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..st.fields.len];
            };
        },
        .variant_value => |*vv| {
            if (vv.arm_fields.len > 0) if (compactFindReloc(relocs, @intFromPtr(vv.arm_fields.ptr))) |na| {
                vv.arm_fields = @as([*]Value, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..vv.arm_fields.len];
            };
            if (vv.shared_values.len > 0) if (compactFindReloc(relocs, @intFromPtr(vv.shared_values.ptr))) |na| {
                vv.shared_values = @as([*]Value, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..vv.shared_values.len];
            };
        },
        // Sub-slice views: update pointer within the moved parent block.
        .string_view => |*sv| {
            if (sv.bytes.len > 0) if (compactFindReloc(relocs, @intFromPtr(sv.bytes.ptr))) |na| {
                sv.bytes = @as([*]const u8, @ptrFromInt(na))[0..sv.bytes.len];
            };
        },
        .array_view => |*av| {
            if (av.items.len > 0) if (compactFindReloc(relocs, @intFromPtr(av.items.ptr))) |na| {
                av.items = @as([*]Value, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..av.items.len];
            };
        },
        // Iterators hold non-owning slice references into managed blocks.
        .iterator => |*it| switch (it.kind) {
            .string => {
                if (it.string.len > 0) if (compactFindReloc(relocs, @intFromPtr(it.string.ptr))) |na| {
                    it.string = @as([*]const u8, @ptrFromInt(na))[0..it.string.len];
                };
            },
            .array => {
                if (it.array.len > 0) if (compactFindReloc(relocs, @intFromPtr(it.array.ptr))) |na| {
                    it.array = @as([*]Value, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..it.array.len];
                };
            },
            .map => {
                if (it.map.len > 0) if (compactFindReloc(relocs, @intFromPtr(it.map.ptr))) |na| {
                    it.map = @as([*]MapEntry, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..it.map.len];
                };
            },
            .range => {},
        },
        .bigint => |*bi| {
            if (bi.limbs.len > 0) if (compactFindReloc(relocs, @intFromPtr(bi.limbs.ptr))) |na| {
                bi.limbs = @as([*]@import("std").math.big.Limb, @ptrCast(@alignCast(@as(*u8, @ptrFromInt(na)))))[0..bi.limbs.len];
            };
        },
        else => {},
    }
}

fn nextFreeBlock(node: *u8) ?*u8 {
    const next_ptr = @as(*usize, @ptrCast(@alignCast(node))).*;
    return if (next_ptr == 0) null else @as(*u8, @ptrFromInt(next_ptr));
}
