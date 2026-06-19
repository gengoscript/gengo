const std = @import("std");
const builtin = @import("builtin");
const chunk = @import("chunk.zig");
const globals = @import("globals.zig");
const heap = @import("../runtime/heap.zig");
const cfg = @import("../runtime/config.zig");
const vms = @import("vm_state.zig");
const vmperf = @import("vm_perf.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const build_options = @import("build_options");

pub fn monoNowNs() u64 {
    if (comptime builtin.os.tag != .wasi) {
        return 0;
    }
    var ns: std.os.wasi.timestamp_t = 0;
    if (std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns) != .SUCCESS) return 0;
    return ns;
}

// Iterative mark worklist — each live object is pushed at most once (we mark
// before pushing, so duplicates are never enqueued).
var mark_worklist: [cfg.max_objects]*Object = undefined;
var mark_worklist_top: usize = 0;

fn markObjectQueue(obj: *Object) void {
    if (!heap.isObjectLive(obj)) return;
    if (heap.isObjectMarked(obj)) return;
    heap.markObject(obj);
    if (mark_worklist_top >= mark_worklist.len) {
        if (comptime builtin.mode == .Debug) {
            @panic("GC FATAL: mark worklist exhausted — object graph too deep or mark-phase bug");
        }
        return;
    }
    mark_worklist[mark_worklist_top] = obj;
    mark_worklist_top += 1;
}

fn markValue(v: Value) void {
    if (v == .object) markObjectQueue(v.object);
}

fn drainMarkQueue() void {
    while (mark_worklist_top > 0) {
        mark_worklist_top -= 1;
        const obj = mark_worklist[mark_worklist_top];
        switch (obj.*) {
            .array, .array_managed => {
                const items = vms.asArraySlice(obj) catch unreachable;
                var i: usize = 0;
                while (i < items.len) : (i += 1) markValue(items[i]);
            },
            .array_capacity => |ac| {
                if (heap.isObjectLive(ac.backing)) markObjectQueue(ac.backing);
            },
            .map, .map_managed, .map_hashed => {
                const items = vms.asMapSlice(obj) catch unreachable;
                var i: usize = 0;
                while (i < items.len) : (i += 1) {
                    markValue(items[i].key);
                    markValue(items[i].value);
                }
            },
            .closure => |cl| {
                markObjectQueue(cl.func);
                var i: usize = 0;
                while (i < cl.upvalues.len) : (i += 1) markObjectQueue(cl.upvalues[i]);
            },
            .cell => |c| markValue(c.value),
            .struct_instance => |inst| {
                markObjectQueue(inst.typ);
                var i: usize = 0;
                while (i < inst.fields.len) : (i += 1) {
                    markValue(inst.fields[i].key);
                    markValue(inst.fields[i].value);
                }
            },
            .named_value => |nv| {
                markObjectQueue(nv.typ);
                markValue(nv.value);
            },
            .iterator => |it| {
                if (it.source) |src| if (heap.isObjectLive(src)) markObjectQueue(src);
                switch (it.kind) {
                    .array => {
                        var i: usize = 0;
                        while (i < it.array.len) : (i += 1) markValue(it.array[i]);
                    },
                    .map => {
                        var i: usize = 0;
                        while (i < it.map.len) : (i += 1) {
                            markValue(it.map[i].key);
                            markValue(it.map[i].value);
                        }
                    },
                    .string, .range => {},
                }
            },
            .enum_value => |ev| markObjectQueue(ev.typ),
            .variant_type => {},
            .variant_value => |vv| {
                markObjectQueue(vv.typ);
                markValue(vv.payload);
                for (vv.shared_values) |sv| markValue(sv);
                for (vv.arm_fields) |af| markValue(af);
            },
            .variant_ctor => |vc| markObjectQueue(vc.typ),
            .named_type_fn => |nf| markObjectQueue(nf.typ),
            .named_type => |nt| {
                if (nt.parent_obj) |p| markObjectQueue(p);
                if (nt.predicate) |p| markObjectQueue(p);
            },
            .enum_type => |et| { if (et.parent) |p| markObjectQueue(p); },
            .string_view => |sv| {
                if (heap.isObjectLive(sv.source)) markObjectQueue(sv.source);
            },
            // No GC-traced children; backing bytes are freed by the sweep.
            .dyn_string, .function, .native_function, .host_module_function, .struct_type, .interface_type,
            .string_builder => {},
        }
    }
}

fn gcCheckIntegrityPostSweep() void {
    if (comptime builtin.mode != .Debug) return;
    const gs = heap.g_state;
    const max = gs.obj_pool.len;

    // Every string_view.source object must still be live after sweep.
    var i: usize = 0;
    while (i < max) : (i += 1) {
        if (!gs.obj_live[i]) continue;
        switch (gs.obj_pool[i]) {
            .string_view => |sv| {
                if (!heap.isObjectLive(sv.source)) {
                    std.debug.panic("GC INTEGRITY: string_view.source (obj {d}) is dead after sweep", .{i});
                }
            },
            else => {},
        }
    }

    // Freed-block overlap is checked by heap.assertNotLive when
    // heap.paranoia is enabled (via freeBytesManaged).
}

pub fn collectGarbage() void {
    const t0 = monoNowNs();
    mark_worklist_top = 0;

    var i: usize = 0;
    while (i < vms.vmState().stack_top) : (i += 1) markValue(vms.vmState().stack[i]);

    i = 0;
    while (i < globals.len()) : (i += 1) markValue(globals.compactValue(i));

    if (vms.vmState().std_module) |m| markObjectQueue(m);

    i = 0;
    while (i < vms.vmState().temp_root_top) : (i += 1) markValue(vms.vmState().temp_roots[i]);

    i = 0;
    while (i < chunk.constCount()) : (i += 1) markValue(chunk.constAt(i) catch unreachable);

    i = 0;
    while (i < vms.vmState().defer_top) : (i += 1) markValue(vms.vmState().defer_stack[i]);

    drainMarkQueue();

    const marked_count = heap.liveObjectCount();
    heap.sweepObjects();
    gcCheckIntegrityPostSweep();
    const swept_count = marked_count - heap.liveObjectCount();
    vmperf.countGCSweep(marked_count, swept_count);
    const t1 = monoNowNs();
    vms.vmState().gc_runs += 1;
    if (t1 > t0) vms.vmState().gc_time_ns += @intCast(t1 - t0);
}

fn nextGcObjects(live: usize) usize {
    const obj_step = cfg.gc_object_step;
    const max_obj = heap.g_state.maxObjects();
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

pub fn vmAllocObject() !*Object {
    if (gcStress()) collectGarbage();
    if (heap.liveObjectCount() >= vms.vmState().next_gc_objects) {
        collectGarbage();
        vms.vmState().next_gc_objects = nextGcObjects(heap.liveObjectCount());
    }
    if (heap.allocObject()) |o| {
        vms.vmState().alloc_object_calls += 1;
        return o;
    }
    collectGarbage();
    vms.vmState().next_gc_objects = nextGcObjects(heap.liveObjectCount());
    if (heap.allocObject()) |o| {
        vms.vmState().alloc_object_calls += 1;
        return o;
    }
    return error.OutOfMemory;
}

pub fn vmAllocManagedSlice(comptime T: type, n: usize) ![]T {
    if (gcStress()) collectGarbage();
    if (@sizeOf(T) * n > heap.maxManagedAlloc()) {
        vms.setRuntimeErr("allocation of {d} bytes exceeds this heap's largest block ({d} bytes); configure a larger heap", .{ @sizeOf(T) * n, heap.maxManagedAlloc() });
        return error.AllocationTooLarge;
    }
    if (heap.usedBytes() >= vms.vmState().next_gc_heap_bytes) {
        collectGarbage();
        vms.vmState().next_gc_heap_bytes = gcStepThreshold(heap.usedBytes());
    }
    if (heap.allocManagedSlice(T, n)) |s| {
        vms.vmState().alloc_managed_slice_calls += 1;
        return s;
    }
    collectGarbage();
    vms.vmState().next_gc_heap_bytes = gcStepThreshold(heap.usedBytes());
    if (heap.allocManagedSlice(T, n)) |s| {
        vms.vmState().alloc_managed_slice_calls += 1;
        return s;
    }
    return error.OutOfMemory;
}

fn gcStepThreshold(used: usize) usize {
    // Shrink the step as the heap fills so GC keeps firing even when the bump
    // pointer is near the top. HeapSize/4 at low usage, HeapSize/16 at >75%.
    const sz = heap.g_state.heap.len;
    const step = if (used * 4 > sz * 3) sz / 16 else sz / 4;
    const next = used + step;
    return if (next >= sz) sz - sz / 16 else next;
}

pub fn vmAllocManagedBytes(n: usize) ![]u8 {
    if (gcStress()) collectGarbage();
    if (n > heap.maxManagedAlloc()) {
        vms.setRuntimeErr("allocation of {d} bytes exceeds this heap's largest block ({d} bytes); configure a larger heap", .{ n, heap.maxManagedAlloc() });
        return error.AllocationTooLarge;
    }
    if (heap.usedBytes() >= vms.vmState().next_gc_heap_bytes) {
        collectGarbage();
        vms.vmState().next_gc_heap_bytes = gcStepThreshold(heap.usedBytes());
    }
    // Proactive GC: before bumping a medium/large slab when the heap is
    // already over 25% full, collect first so freed blocks refill the free
    // list and we avoid growing the bump at all.
    // Thresholds: ≥2048 B at >25%, ≥4096 B at >12.5% (the tighter bound is
    // the one the caller already checked via next_gc_heap_bytes so these only
    // fire when the free list for that class is actually empty).
    const used = heap.usedBytes();
    if (n >= 2048 and heap.wouldBump(n) and used * 4 >= heap.g_state.heap.len) {
        collectGarbage();
        vms.vmState().next_gc_heap_bytes = gcStepThreshold(heap.usedBytes());
    }
    if (heap.allocBytesManaged(n)) |s| {
        vms.vmState().alloc_managed_bytes_calls += 1;
        return s;
    }
    collectGarbage();
    vms.vmState().next_gc_heap_bytes = gcStepThreshold(heap.usedBytes());
    if (heap.allocBytesManaged(n)) |s| {
        vms.vmState().alloc_managed_bytes_calls += 1;
        return s;
    }
    return error.OutOfMemory;
}

/// Allocate an object, set `safeInit` as a GC-safe initial tag, push a
/// temp root, call `setup` (which may allocate managed memory and finalize
/// fields), pop the temp root, and return the Value.
///
/// This helper ensures new native code cannot accidentally create a
/// rooting-window bug by forgetting the temp-root or safe-tag step.
pub fn buildObject(
    comptime safeInit: Object,
    comptime setup: *const fn (obj: *Object) anyerror!void,
) anyerror!Value {
    const obj = try vmAllocObject();
    obj.* = safeInit;
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    try setup(obj);
    return .{ .object = obj };
}

pub fn makeDynString(s: []const u8) !Value {
    const obj = try vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} }; // safe tag before GC can run
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmAllocManagedBytes(s.len);
    @memcpy(buf[0..s.len], s);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
}

pub fn concatDynString(a: []const u8, b: []const u8) !Value {
    const obj = try vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} }; // safe tag before GC can run
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const total = a.len +% b.len;
    if (total < a.len) return error.OutOfMemory;
    const buf = try vmAllocManagedBytes(total);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..total], b);
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

pub fn makeStringView(bytes: []const u8, source: *Object) !Value {
    const obj = try vmAllocObject();
    obj.* = .{ .string_view = .{ .bytes = bytes, .source = source } };
    return .{ .object = obj };
}
