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
                const items = vms.asArraySlice(obj);
                var i: usize = 0;
                while (i < items.len) : (i += 1) markValue(items[i]);
            },
            .map, .map_managed, .map_hashed => {
                const items = vms.asMapSlice(obj);
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
                if (it.source) |src| markObjectQueue(src);
            },
            .enum_value => |ev| markObjectQueue(ev.typ),
            .variant_type => {},
            .variant_value => |vv| {
                markObjectQueue(vv.typ);
                markValue(vv.payload);
            },
            .variant_ctor => |vc| markObjectQueue(vc.typ),
            .named_type => |nt| { if (nt.parent_obj) |p| markObjectQueue(p); },
            // No GC-traced children; backing bytes are freed by the sweep.
            .dyn_string, .function, .native_function, .struct_type, .interface_type,
            .enum_type, .string_builder => {},
        }
    }
}

pub fn collectGarbage() void {
    const t0 = monoNowNs();
    mark_worklist_top = 0;

    var i: usize = 0;
    while (i < vms.vmState().stack_top) : (i += 1) markValue(vms.vmState().stack[i]);

    i = 0;
    while (i < globals.len()) : (i += 1) markValue(globals.valueAt(i));

    if (vms.vmState().std_module) |m| markObjectQueue(m);

    i = 0;
    while (i < vms.vmState().temp_root_top) : (i += 1) markValue(vms.vmState().temp_roots[i]);

    i = 0;
    while (i < chunk.constCount()) : (i += 1) markValue(chunk.constAt(i));

    i = 0;
    while (i < vms.vmState().defer_top) : (i += 1) markValue(vms.vmState().defer_stack[i]);

    drainMarkQueue();

    const marked_count = heap.liveObjectCount();
    heap.sweepObjects();
    const swept_count = marked_count - heap.liveObjectCount();
    vmperf.countGCSweep(marked_count, swept_count);
    const t1 = monoNowNs();
    vms.vmState().gc_runs += 1;
    if (t1 > t0) vms.vmState().gc_time_ns += @intCast(t1 - t0);
}

pub fn vmAllocObject() !*Object {
    if (heap.liveObjectCount() >= vms.vmState().next_gc_objects) {
        collectGarbage();
        const live = heap.liveObjectCount();
        vms.vmState().next_gc_objects = (live * 2) + 64;
    }
    if (heap.allocObject()) |o| {
        vms.vmState().alloc_object_calls += 1;
        return o;
    }
    collectGarbage();
    const live = heap.liveObjectCount();
    vms.vmState().next_gc_objects = (live * 2) + 64;
    if (heap.allocObject()) |o| {
        vms.vmState().alloc_object_calls += 1;
        return o;
    }
    return error.OutOfMemory;
}

pub fn vmAllocManagedSlice(comptime T: type, n: usize) ![]T {
    if (heap.usedBytes() >= vms.vmState().next_gc_heap_bytes) {
        collectGarbage();
        const used = heap.usedBytes();
        const step = heap.HeapSize / 4;
        vms.vmState().next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    }
    if (heap.allocManagedSlice(T, n)) |s| {
        vms.vmState().alloc_managed_slice_calls += 1;
        return s;
    }
    collectGarbage();
    const used = heap.usedBytes();
    const step = heap.HeapSize / 4;
    vms.vmState().next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    if (heap.allocManagedSlice(T, n)) |s| {
        vms.vmState().alloc_managed_slice_calls += 1;
        return s;
    }
    return error.OutOfMemory;
}

pub fn vmAllocManagedBytes(n: usize) ![]u8 {
    if (heap.usedBytes() >= vms.vmState().next_gc_heap_bytes) {
        collectGarbage();
        const used = heap.usedBytes();
        const step = heap.HeapSize / 4;
        vms.vmState().next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    }
    if (heap.allocBytesManaged(n)) |s| {
        vms.vmState().alloc_managed_bytes_calls += 1;
        return s;
    }
    collectGarbage();
    const used = heap.usedBytes();
    const step = heap.HeapSize / 4;
    vms.vmState().next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    if (heap.allocBytesManaged(n)) |s| {
        vms.vmState().alloc_managed_bytes_calls += 1;
        return s;
    }
    return error.OutOfMemory;
}

pub fn makeDynString(s: []const u8) !Value {
    const obj = try vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmAllocManagedBytes(s.len);
    @memcpy(buf[0..s.len], s);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
}

pub fn concatDynString(a: []const u8, b: []const u8) !Value {
    const obj = try vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const total = a.len + b.len;
    const buf = try vmAllocManagedBytes(total);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..total], b);
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}
