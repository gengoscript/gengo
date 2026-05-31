const std = @import("std");
const builtin = @import("builtin");
const chunk = @import("chunk.zig");
const globals = @import("globals.zig");
const heap = @import("../runtime/heap.zig");
const vms = @import("vm_state.zig");
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

fn markValue(v: Value) void {
    if (v == .object) markObject(v.object);
}

fn markObject(obj: *Object) void {
    if (!heap.isObjectLive(obj)) return;
    if (heap.isObjectMarked(obj)) return;
    heap.markObject(obj);
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
            markObject(cl.func);
            var i: usize = 0;
            while (i < cl.upvalues.len) : (i += 1) markObject(cl.upvalues[i]);
        },
        .cell => |c| markValue(c.value),
        .struct_instance => |inst| {
            markObject(inst.typ);
            var i: usize = 0;
            while (i < inst.fields.len) : (i += 1) {
                markValue(inst.fields[i].key);
                markValue(inst.fields[i].value);
            }
        },
        .named_value => |nv| {
            markObject(nv.typ);
            markValue(nv.value);
        },
        .iterator => |it| {
            if (it.source) |src| markObject(src);
        },
        .enum_value => |ev| markObject(ev.typ),
        .variant_type => {},
        .variant_value => |vv| {
            markObject(vv.typ);
            markValue(vv.payload);
        },
        .variant_ctor => |vc| markObject(vc.typ),
        .named_type => |nt| { if (nt.parent_obj) |p| markObject(p); },
        .dyn_string, .function, .native_function, .struct_type, .interface_type, .enum_type => {},
    }
}

pub fn collectGarbage() void {
    const t0 = monoNowNs();
    var i: usize = 0;
    while (i < vms.vmState().stack_top) : (i += 1) markValue(vms.vmState().stack[i]);

    i = 0;
    while (i < globals.len()) : (i += 1) markValue(globals.valueAt(i));

    if (vms.vmState().std_module) |m| markObject(m);

    i = 0;
    while (i < vms.vmState().temp_root_top) : (i += 1) markValue(vms.vmState().temp_roots[i]);

    i = 0;
    while (i < chunk.constCount()) : (i += 1) markValue(chunk.constAt(i));

    i = 0;
    while (i < vms.vmState().defer_top) : (i += 1) markValue(vms.vmState().defer_stack[i]);

    heap.sweepObjects();
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
