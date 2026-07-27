const std = @import("std");
const builtin = @import("builtin");
const vm_integrity = @import("vm_integrity.zig");
const chunk = @import("chunk.zig");
const globals = @import("globals.zig");
const heap = @import("../runtime/heap.zig");
const cfg = @import("runtime_config");
const vms = @import("vm_state.zig");
const vmperf = @import("vm_perf.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;
const build_options = @import("build_options");

const VMContext = vms.VMContext;

// Monotonic ns for GC pause accounting (callers only ever take deltas).
pub fn monoNowNs() u64 {
    if (comptime builtin.os.tag == .wasi) {
        var ns: std.os.wasi.timestamp_t = 0;
        if (std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns) != .SUCCESS) return 0;
        return ns;
    }
    var ts: std.posix.timespec = undefined;
    if (std.posix.system.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// Iterative mark worklist (lives in heap.State) — each live object is pushed
// at most once (we mark before pushing, so duplicates are never enqueued).
fn markObjectQueue(ctx: VMContext, obj: *Object) void {
    if (!ctx.hs.isObjectLive(obj)) return;
    if (ctx.hs.isObjectMarked(obj)) return;
    ctx.hs.markObject(obj);
    if (ctx.hs.mark_worklist_top >= ctx.hs.mark_worklist.len) {
        vm_integrity.fatal(ctx, error.GCInvariantFailure);
    }
    ctx.hs.mark_worklist[ctx.hs.mark_worklist_top] = obj;
    ctx.hs.mark_worklist_top += 1;
}

fn markValue(ctx: VMContext, v: Value) void {
    if (v == .inline_variant) {
        markObjectQueue(ctx, ctx.hs.objectAt(v.inline_variant.typ_idx));
        return;
    }
    if (v == .object) markObjectQueue(ctx, v.object);
}

fn drainMarkQueue(ctx: VMContext) void {
    while (ctx.hs.mark_worklist_top > 0) {
        ctx.hs.mark_worklist_top -= 1;
        const obj = ctx.hs.mark_worklist[ctx.hs.mark_worklist_top];
        switch (obj.*) {
            .array, .array_managed => {
                for (vms.asArraySlice(obj) catch vm_integrity.fatal(ctx, error.GCInvariantFailure)) |v| markValue(ctx, v);
            },
            .array_view => |av| {
                if (ctx.hs.isObjectLive(av.source)) markObjectQueue(ctx, av.source);
            },
            .array_capacity => |ac| {
                if (ctx.hs.isObjectLive(ac.backing)) markObjectQueue(ctx, ac.backing);
            },
            .map, .map_managed, .map_hashed => {
                for (vms.asMapSlice(obj) catch vm_integrity.fatal(ctx, error.GCInvariantFailure)) |e| {
                    markValue(ctx, e.key);
                    markValue(ctx, e.value);
                }
            },
            .closure => |cl| {
                markObjectQueue(ctx, cl.func);
                for (cl.upvalues) |uv| markObjectQueue(ctx, uv);
            },
            .cell => |c| markValue(ctx, c.value),
            .struct_instance => |inst| {
                markObjectQueue(ctx, inst.typ);
                for (inst.fields) |f| {
                    markValue(ctx, f.key);
                    markValue(ctx, f.value);
                }
            },
            .small_struct_instance => |ssi| {
                markObjectQueue(ctx, ssi.typ);
                for (0..@as(usize, ssi.count)) |i| markValue(ctx, ssi.v[i]);
            },
            .named_value => |nv| {
                markObjectQueue(ctx, nv.typ);
                markValue(ctx, nv.value);
            },
            .iterator => |it| {
                if (it.source) |src| if (ctx.hs.isObjectLive(src)) markObjectQueue(ctx, src);
                switch (it.kind) {
                    .array => {
                        for (it.array) |v| markValue(ctx, v);
                    },
                    .map => {
                        for (it.map) |e| {
                            markValue(ctx, e.key);
                            markValue(ctx, e.value);
                        }
                    },
                    .string, .range => {},
                }
            },
            .enum_value => |ev| markObjectQueue(ctx, ev.typ),
            .variant_type => {},
            .variant_value => |vv| {
                markObjectQueue(ctx, vv.typ);
                markValue(ctx, vv.payload);
                for (vv.shared_values) |sv| markValue(ctx, sv);
                for (vv.arm_fields) |af| markValue(ctx, af);
            },
            .variant_ctor => |vc| markObjectQueue(ctx, vc.typ),
            .named_type_fn => |nf| markObjectQueue(ctx, nf.typ),
            .enum_type_fn => |ef| markObjectQueue(ctx, ef.typ),
            .named_type => |nt| {
                if (nt.parent_obj) |p| markObjectQueue(ctx, p);
                if (nt.predicate) |p| markObjectQueue(ctx, p);
            },
            .enum_type => |et| {
                if (et.parent) |p| markObjectQueue(ctx, p);
            },
            .string_view => |sv| {
                if (sv.source) |src| if (ctx.hs.isObjectLive(src)) markObjectQueue(ctx, src);
            },
            .named_error_type => {},
            .named_error_value => |nev| markObjectQueue(ctx, nev.typ),
            // No GC-traced children; backing bytes are freed by the sweep.
            .dyn_string, .function, .native_function, .host_module_function, .struct_type, .interface_type, .string_builder, .bigint => {},
        }
    }
}

fn gcCheckIntegrityPostSweep(ctx: VMContext) void {
    if (comptime builtin.mode != .Debug) return;
    const gs = ctx.hs;
    const max = gs.obj_pool.len;

    // Every source-retaining view object must still point at a live source after sweep.
    for (gs.obj_pool[0..max], gs.obj_live[0..max], 0..) |*obj, live, i| {
        if (!live) continue;
        switch (obj.*) {
            .array_view => |av| {
                if (!ctx.hs.isObjectLive(av.source) and !ctx.hs.isObjectImmortal(av.source)) {
                    std.debug.print("GC INTEGRITY: array_view.source (obj {d}) is dead after sweep\n", .{i});
                    vm_integrity.fatal(ctx, error.GCInvariantFailure);
                }
            },
            .string_view => |sv| {
                if (sv.source) |src| if (!ctx.hs.isObjectLive(src) and !ctx.hs.isObjectImmortal(src)) {
                    std.debug.print("GC INTEGRITY: string_view.source (obj {d}) is dead after sweep\n", .{i});
                    vm_integrity.fatal(ctx, error.GCInvariantFailure);
                };
            },
            else => {},
        }
    }

    // Freed-block overlap is checked by heap.assertNotLive when
    // heap.paranoia is enabled (via freeBytesManaged).
}

pub fn collectGarbage(ctx: VMContext) void {
    const t0 = monoNowNs();
    ctx.hs.mark_worklist_top = 0;

    for (ctx.vs.stack[0..ctx.vs.stack_top]) |v| markValue(ctx, v);

    for (0..ctx.gs.len()) |i| markValue(ctx, ctx.gs.compactValue(i));

    if (ctx.vs.std_module) |m| markObjectQueue(ctx, m);

    for (ctx.vs.temp_roots[0..ctx.vs.temp_root_top]) |v| markValue(ctx, v);

    // Only constants holding heap objects are roots; scalars and strings need
    // no marking. addConst records their indices so this walk skips the bulk
    // of the pool (#187). The bound check guards against constant-folding
    // rollbacks shrinking const_count below a recorded index.
    for (ctx.cs.obj_const_idxs[0..ctx.cs.obj_const_count]) |ci| {
        if (ci < ctx.cs.const_count) markValue(ctx, ctx.cs.consts[ci]);
    }

    for (ctx.vs.defer_stack[0..ctx.vs.defer_top]) |v| markValue(ctx, v);

    drainMarkQueue(ctx);

    const marked_count = ctx.hs.liveObjectCount();
    ctx.hs.sweepObjects();
    gcCheckIntegrityPostSweep(ctx);
    const swept_count = marked_count - ctx.hs.liveObjectCount();
    vmperf.countGCSweep(marked_count, swept_count);
    const t1 = monoNowNs();
    ctx.vs.gc_runs += 1;
    if (t1 > t0) ctx.vs.gc_time_ns += @intCast(t1 - t0);
}

fn nextGcObjects(ctx: VMContext, live: usize) usize {
    const obj_step = cfg.gc_object_step;
    const max_obj = ctx.hs.maxObjects();
    const raw = (live * 2) + obj_step;
    return if (raw >= max_obj) max_obj - 1 else raw;
}

// Debug stress mode, enabled by the CLI when GENGO_GC_STRESS is set:
// collect on every allocation so unrooted-window bugs fire deterministically.
pub var gc_stress: bool = false;
fn gcStress() bool {
    if (comptime build_options.gc_stress) return true;
    return gc_stress;
}

// gengo --test --profile only: object-slot and managed-slice allocation are
// the only two places usedBytes()/liveObjectCount() can grow — GC only ever
// shrinks them — so checking here after a successful allocation is
// sufficient to capture the true peak, without touching the push/pop hot
// path at all.
inline fn recordProfilePeaks(ctx: VMContext) void {
    if (!ctx.vs.policy.profile_mode) return;
    const objs = ctx.hs.liveObjectCount();
    if (objs > ctx.vs.peak_live_objects) ctx.vs.peak_live_objects = objs;
    const bytes = ctx.hs.usedBytes();
    if (bytes > ctx.vs.peak_heap_bytes) ctx.vs.peak_heap_bytes = bytes;
}

pub fn vmAllocObject(ctx: VMContext) !*Object {
    if (gcStress()) collectGarbage(ctx);
    if (ctx.hs.liveObjectCount() >= ctx.vs.next_gc_objects) {
        collectGarbage(ctx);
        ctx.vs.next_gc_objects = nextGcObjects(ctx, ctx.hs.liveObjectCount());
    }
    if (ctx.hs.allocObject()) |o| {
        ctx.vs.alloc_object_calls += 1;
        recordProfilePeaks(ctx);
        return o;
    }
    collectGarbage(ctx);
    ctx.vs.next_gc_objects = nextGcObjects(ctx, ctx.hs.liveObjectCount());
    if (ctx.hs.allocObject()) |o| {
        ctx.vs.alloc_object_calls += 1;
        recordProfilePeaks(ctx);
        return o;
    }
    return error.OutOfMemory;
}

fn gcStepThreshold(ctx: VMContext, used: usize) usize {
    // Shrink the step as the heap fills so GC keeps firing even when the bump
    // pointer is near the top. HeapSize/4 at low usage, HeapSize/16 at >75%.
    const sz = ctx.hs.heap.len;
    const step = if (used * 4 > sz * 3) sz / 16 else sz / 4;
    const next = used + step;
    return if (next >= sz) sz - sz / 16 else next;
}

pub fn vmAllocManagedSlice(ctx: VMContext, comptime T: type, n: usize) ![]T {
    if (gcStress()) collectGarbage(ctx);
    // n can be directly attacker-controlled (e.g. std.rand.perm's count argument),
    // so @sizeOf(T) * n must not be a raw non-wrapping multiply — it would panic
    // (integer overflow trap) for large n instead of raising a catchable error.
    const total_bytes = std.math.mul(usize, @sizeOf(T), n) catch {
        ctx.vs.setRuntimeErr("allocation of {d} elements ({d} bytes each) overflows; configure a larger heap", .{ n, @sizeOf(T) });
        return error.AllocationTooLarge;
    };
    if (total_bytes > ctx.hs.maxManagedAlloc()) {
        ctx.vs.setRuntimeErr("allocation of {d} bytes exceeds this heap's largest block ({d} bytes); configure a larger heap", .{ total_bytes, ctx.hs.maxManagedAlloc() });
        return error.AllocationTooLarge;
    }
    if (ctx.hs.usedBytes() >= ctx.vs.next_gc_heap_bytes) {
        collectGarbage(ctx);
        ctx.vs.next_gc_heap_bytes = gcStepThreshold(ctx, ctx.hs.usedBytes());
    }
    if (ctx.hs.wouldBump(total_bytes) and ctx.hs.usedBytes() * 2 >= ctx.hs.heap.len) {
        collectGarbage(ctx);
        ctx.vs.next_gc_heap_bytes = gcStepThreshold(ctx, ctx.hs.usedBytes());
    }
    if (ctx.hs.allocManagedSlice(T, n)) |s| {
        ctx.vs.alloc_managed_slice_calls += 1;
        recordProfilePeaks(ctx);
        return s;
    }
    collectGarbage(ctx);
    ctx.vs.next_gc_heap_bytes = gcStepThreshold(ctx, ctx.hs.usedBytes());
    if (ctx.hs.allocManagedSlice(T, n)) |s| {
        ctx.vs.alloc_managed_slice_calls += 1;
        recordProfilePeaks(ctx);
        return s;
    }
    ctx.hs.compactManagedHeap();
    if (ctx.hs.allocManagedSlice(T, n)) |s| {
        ctx.vs.alloc_managed_slice_calls += 1;
        recordProfilePeaks(ctx);
        return s;
    }
    return error.OutOfMemory;
}

pub fn vmAllocManagedBytes(ctx: VMContext, n: usize) ![]u8 {
    if (gcStress()) collectGarbage(ctx);
    if (n > ctx.hs.maxManagedAlloc()) {
        ctx.vs.setRuntimeErr("allocation of {d} bytes exceeds this heap's largest block ({d} bytes); configure a larger heap", .{ n, ctx.hs.maxManagedAlloc() });
        return error.AllocationTooLarge;
    }
    if (ctx.hs.usedBytes() >= ctx.vs.next_gc_heap_bytes) {
        collectGarbage(ctx);
        ctx.vs.next_gc_heap_bytes = gcStepThreshold(ctx, ctx.hs.usedBytes());
    }
    // Proactive GC: when the free list for this size class is empty and the
    // heap is over 50% full, collect before bumping. Prevents fragmentation-
    // induced OOM where small freed blocks fill their class free lists but
    // the needed class has no free blocks and the bump is exhausted.
    if (ctx.hs.wouldBump(n) and ctx.hs.usedBytes() * 2 >= ctx.hs.heap.len) {
        collectGarbage(ctx);
        ctx.vs.next_gc_heap_bytes = gcStepThreshold(ctx, ctx.hs.usedBytes());
    }
    if (ctx.hs.allocBytesManaged(n)) |s| {
        ctx.vs.alloc_managed_bytes_calls += 1;
        recordProfilePeaks(ctx);
        return s;
    }
    collectGarbage(ctx);
    ctx.vs.next_gc_heap_bytes = gcStepThreshold(ctx, ctx.hs.usedBytes());
    if (ctx.hs.allocBytesManaged(n)) |s| {
        ctx.vs.alloc_managed_bytes_calls += 1;
        recordProfilePeaks(ctx);
        return s;
    }
    // Last resort: compact live managed data into a contiguous region so that
    // fragmentation caused by live objects between freed blocks is eliminated.
    ctx.hs.compactManagedHeap();
    if (ctx.hs.allocBytesManaged(n)) |s| {
        ctx.vs.alloc_managed_bytes_calls += 1;
        recordProfilePeaks(ctx);
        return s;
    }
    return error.OutOfMemory;
}

pub fn allocTempRooted(ctx: VMContext, comptime safeInit: Object) !*Object {
    const obj = try vmAllocObject(ctx);
    obj.* = safeInit;
    try ctx.vs.pushTempRoot(.{ .object = obj });
    return obj;
}

// Both TempRootedManaged* helpers publish their full backing slice to the
// owning (already temp-rooted) object *immediately*, null-filled, rather
// than incrementally as the caller fills each element in. A freshly
// allocated managed block that isn't yet reachable from any live object is
// invisible to compactManagedHeap's relocation bookkeeping — a nested
// allocation (e.g. inside a map/zip/chunk callback, which runs arbitrary
// Gengo code) can trigger a compaction that packs other live data right on
// top of it. Publishing at full length up front means the block is
// protected from the first write onward. `.set()` then re-derives the
// current backing slice from the object on every call instead of trusting
// a slice captured once — compaction keeps the object's own field
// correctly updated when it relocates the block, but a separately-held
// copy of that slice would not follow along.
pub const TempRootedManagedValueArray = struct {
    obj: *Object,

    pub fn set(self: TempRootedManagedValueArray, i: usize, v: Value) void {
        self.obj.array_managed[i] = v;
    }

    // Bulk-copy variant of set(): src must already be a *current* slice
    // (re-derived after any allocation that could have moved its source),
    // the same requirement as any other read from managed memory.
    pub fn setAll(self: TempRootedManagedValueArray, src: []const Value) void {
        @memcpy(self.obj.array_managed[0..src.len], src);
    }
};

pub fn allocTempRootedManagedValueArray(ctx: VMContext, len: usize) !TempRootedManagedValueArray {
    const obj = try allocTempRooted(ctx, .{ .array_managed = &[_]Value{} });
    const values = try vmAllocManagedSlice(ctx, Value, len);
    @memset(values, .null);
    obj.* = .{ .array_managed = values };
    return .{ .obj = obj };
}

pub const TempRootedManagedMap = struct {
    obj: *Object,

    pub fn set(self: TempRootedManagedMap, i: usize, e: MapEntry) void {
        self.obj.map[i] = e;
    }
};

pub fn allocTempRootedManagedMap(ctx: VMContext, len: usize) !TempRootedManagedMap {
    const obj = try allocTempRooted(ctx, .{ .map = &[_]MapEntry{} });
    const entries = try vmAllocManagedSlice(ctx, MapEntry, len);
    @memset(entries, .{ .key = .null, .value = .null });
    obj.* = .{ .map = entries };
    return .{ .obj = obj };
}

pub fn makeDynString(ctx: VMContext, s: []const u8) !Value {
    const obj = try allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    if (s.len == 0) return .{ .object = obj };
    // s is very often a sub-range or transform of a managed object's own
    // bytes (a trim, a case conversion, a split fragment...), computed by
    // the caller just before this call. The allocation below can trigger
    // a GC + compaction that relocates that source out from under s — a
    // caller re-deriving from the object afterward is safe (see
    // makeDynStringFromObj for the identity-copy case), but nothing
    // forces every caller to do that, and several throughout the codebase
    // don't. Copying s into scratch page_allocator memory first — never
    // touched by compaction — makes this safe unconditionally, for any
    // caller, without relying on that discipline.
    const scratch = try std.heap.page_allocator.dupe(u8, s);
    defer std.heap.page_allocator.free(scratch);
    const buf = try vmAllocManagedBytes(ctx, scratch.len);
    @memcpy(buf[0..scratch.len], scratch);
    obj.* = .{ .dyn_string = buf[0..scratch.len] };
    return .{ .object = obj };
}

/// Safe copy from a live managed Object when vmAllocManagedBytes may compact.
/// Callers passing a raw []const u8 derived from a managed Object to makeDynString
/// risk reading a stale pointer if compactManagedHeap runs inside vmAllocManagedBytes
/// and updates the Object field while the Zig-local slice stays at the old address.
/// This variant re-reads the source bytes from src AFTER the allocation, ensuring
/// the copy uses the post-compact pointer.  src must be temp-rooted by the caller
/// and must be one of: dyn_string, string_view, string_builder.
pub fn makeDynStringFromObj(ctx: VMContext, src: *Object) !Value {
    const slen: usize = switch (src.*) {
        .dyn_string => |s| s.len,
        .string_view => |sv| sv.bytes.len,
        .string_builder => |sb| sb.len,
        else => return error.TypeError,
    };
    const obj = try allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    if (slen == 0) return .{ .object = obj };
    const buf = try vmAllocManagedBytes(ctx, slen);
    const src_bytes: []const u8 = switch (src.*) {
        .dyn_string => |s| s,
        .string_view => |sv| sv.bytes,
        .string_builder => |sb| sb.buf[0..sb.len],
        else => return error.TypeError,
    };
    @memcpy(buf[0..slen], src_bytes);
    obj.* = .{ .dyn_string = buf[0..slen] };
    return .{ .object = obj };
}

pub fn concatDynString(ctx: VMContext, a: Value, b: Value) !Value {
    const obj = try allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const a_len = (try vms.asStringValue(a)).len;
    const b_len = (try vms.asStringValue(b)).len;
    const total = a_len +% b_len;
    if (total < a_len) return error.OutOfMemory;
    const buf = try vmAllocManagedBytes(ctx, total);
    // Re-read a/b's current bytes now, after the allocation above: it can
    // trigger a GC + compaction that relocates a/b's backing storage if
    // either is a dyn_string/string_view object. a/b (the Values, i.e. the
    // Object pointers) don't change — Objects never move, only their
    // internal fields do — so re-deriving from them here is safe and
    // correctly picks up any relocation, unlike a slice captured earlier
    // by the caller (which is exactly what let stale bytes get memcpy'd
    // into a freshly allocated, possibly-overlapping buffer here).
    const a_bytes = try vms.asStringValue(a);
    const b_bytes = try vms.asStringValue(b);
    @memcpy(buf[0..a_bytes.len], a_bytes);
    @memcpy(buf[a_bytes.len..total], b_bytes);
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn makeStringView(ctx: VMContext, bytes: []const u8, source: ?*Object) !Value {
    const obj = try vmAllocObject(ctx);
    obj.* = .{ .string_view = .{ .bytes = bytes, .source = source } };
    return .{ .object = obj };
}

/// Like makeStringView but takes a managed Object and byte-range offsets instead
/// of a pre-sliced []const u8.  The internal vmAllocObject call may trigger
/// compaction; bytes and source are re-derived from obj AFTER the allocation so
/// the stored sub-slice always points to live memory.
/// obj must be a .dyn_string or .string_view Object.
pub fn makeStringViewFromStringObj(ctx: VMContext, obj: *Object, start_b: usize, end_b: usize) !Value {
    const view_obj = try vmAllocObject(ctx);
    // Re-derive bytes and source from the GC-updated obj after potential compaction.
    const bytes_now: []const u8 = switch (obj.*) {
        .dyn_string => |s| s,
        .string_view => |sv| sv.bytes,
        else => return error.TypeError,
    };
    const source_now: ?*Object = switch (obj.*) {
        .dyn_string => obj,
        .string_view => |sv| sv.source,
        else => return error.TypeError,
    };
    view_obj.* = .{ .string_view = .{ .bytes = bytes_now[start_b..end_b], .source = source_now } };
    return .{ .object = view_obj };
}
