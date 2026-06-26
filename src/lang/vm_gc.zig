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
const MapEntry = @import("value.zig").MapEntry;
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
                for (vms.asArraySlice(obj) catch unreachable) |v| markValue(v);
            },
            .array_view => |av| {
                if (heap.isObjectLive(av.source)) markObjectQueue(av.source);
            },
            .array_capacity => |ac| {
                if (heap.isObjectLive(ac.backing)) markObjectQueue(ac.backing);
            },
            .map, .map_managed, .map_hashed => {
                for (vms.asMapSlice(obj) catch unreachable) |e| {
                    markValue(e.key);
                    markValue(e.value);
                }
            },
            .closure => |cl| {
                markObjectQueue(cl.func);
                for (cl.upvalues) |uv| markObjectQueue(uv);
            },
            .cell => |c| markValue(c.value),
            .struct_instance => |inst| {
                markObjectQueue(inst.typ);
                for (inst.fields) |f| {
                    markValue(f.key);
                    markValue(f.value);
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
                        for (it.array) |v| markValue(v);
                    },
                    .map => {
                        for (it.map) |e| {
                            markValue(e.key);
                            markValue(e.value);
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
            .enum_type_fn => |ef| markObjectQueue(ef.typ),
            .named_type => |nt| {
                if (nt.parent_obj) |p| markObjectQueue(p);
                if (nt.predicate) |p| markObjectQueue(p);
            },
            .enum_type => |et| {
                if (et.parent) |p| markObjectQueue(p);
            },
            .string_view => |sv| {
                if (heap.isObjectLive(sv.source)) markObjectQueue(sv.source);
            },
            // No GC-traced children; backing bytes are freed by the sweep.
            .dyn_string, .function, .native_function, .host_module_function, .struct_type, .interface_type, .string_builder => {},
        }
    }
}

fn gcCheckIntegrityPostSweep() void {
    if (comptime builtin.mode != .Debug) return;
    const gs = heap.g_state;
    const max = gs.obj_pool.len;

    // Every source-retaining view object must still point at a live source after sweep.
    for (gs.obj_pool[0..max], gs.obj_live[0..max], 0..) |*obj, live, i| {
        if (!live) continue;
        switch (obj.*) {
            .array_view => |av| {
                if (!heap.isObjectLive(av.source)) {
                    std.debug.panic("GC INTEGRITY: array_view.source (obj {d}) is dead after sweep", .{i});
                }
            },
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

    for (vms.vmState().stack[0..vms.vmState().stack_top]) |v| markValue(v);

    for (0..globals.len()) |i| markValue(globals.compactValue(i));

    if (vms.vmState().std_module) |m| markObjectQueue(m);

    for (vms.vmState().temp_roots[0..vms.vmState().temp_root_top]) |v| markValue(v);

    for (0..chunk.constCount()) |i| markValue(chunk.constAt(i) catch unreachable);

    for (vms.vmState().defer_stack[0..vms.vmState().defer_top]) |v| markValue(v);

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
    if (heap.wouldBump(@sizeOf(T) * n) and heap.usedBytes() * 2 >= heap.g_state.heap.len) {
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
    // Proactive GC: when the free list for this size class is empty and the
    // heap is over 50% full, collect before bumping. Prevents fragmentation-
    // induced OOM where small freed blocks fill their class free lists but
    // the needed class has no free blocks and the bump is exhausted.
    if (heap.wouldBump(n) and heap.usedBytes() * 2 >= heap.g_state.heap.len) {
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

pub fn allocTempRooted(comptime safeInit: Object) !*Object {
    const obj = try vmAllocObject();
    obj.* = safeInit;
    try vms.pushTempRoot(.{ .object = obj });
    return obj;
}

pub const TempRootedManagedValueArray = struct {
    obj: *Object,
    values: []Value,

    pub fn publish(self: TempRootedManagedValueArray, len: usize) void {
        self.obj.* = .{ .array_managed = self.values[0..len] };
    }
};

pub fn allocTempRootedManagedValueArray(len: usize) !TempRootedManagedValueArray {
    const obj = try allocTempRooted(.{ .array_managed = &[_]Value{} });
    const values = try vmAllocManagedSlice(Value, len);
    obj.* = .{ .array_managed = values[0..0] };
    return .{ .obj = obj, .values = values };
}

pub const TempRootedManagedMap = struct {
    obj: *Object,
    entries: []MapEntry,

    pub fn publish(self: TempRootedManagedMap, len: usize) void {
        self.obj.* = .{ .map = self.entries[0..len] };
    }
};

pub fn allocTempRootedManagedMap(len: usize) !TempRootedManagedMap {
    const obj = try allocTempRooted(.{ .map = &[_]MapEntry{} });
    const entries = try vmAllocManagedSlice(MapEntry, len);
    obj.* = .{ .map = entries[0..0] };
    return .{ .obj = obj, .entries = entries };
}

pub fn makeDynString(s: []const u8) !Value {
    const obj = try allocTempRooted(.{ .dyn_string = &[_]u8{} });
    defer vms.popTempRoot();
    const buf = try vmAllocManagedBytes(s.len);
    @memcpy(buf[0..s.len], s);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
}

pub fn concatDynString(a: []const u8, b: []const u8) !Value {
    const obj = try allocTempRooted(.{ .dyn_string = &[_]u8{} });
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
