const vms = @import("vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("vm_gc.zig");
const heap = @import("../runtime/heap.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;

pub fn arrayRead(ctx: VMContext, obj: *Object, idx_v: Value) !Value {
    const items = try vms.asArraySlice(obj);
    const idx = try vms.vmIndexFromVal(idx_v);
    if (idx >= items.len) {
        ctx.vs.setRuntimeErr("index {} out of bounds for array of length {}", .{ idx, items.len });
        return error.IndexOutOfBounds;
    }
    return items[idx];
}

pub fn arrayWrite(ctx: VMContext, obj: *Object, idx_v: Value, val: Value) !void {
    const items = try vms.asArraySlice(obj);
    const idx = try vms.vmIndexFromVal(idx_v);
    if (idx >= items.len) {
        ctx.vs.setRuntimeErr("index {} out of bounds for array of length {}", .{ idx, items.len });
        return error.IndexOutOfBounds;
    }
    items[idx] = val;
}

pub fn arraySlice(ctx: VMContext, obj: *Object, has_start: bool, start_v: Value, has_end: bool, end_v: Value) !Value {
    const items = try vms.asArraySlice(obj);
    const start: usize = if (has_start) try vms.vmSliceIndex(start_v, items.len) else 0;
    const end: usize = if (has_end) try vms.vmSliceIndex(end_v, items.len) else items.len;
    if (start > end) return error.IndexOutOfBounds;
    const out = try vmgc.vmAllocObject(ctx);
    const source = switch (obj.*) {
        .array_view => obj.array_view.source,
        else => obj,
    };
    out.* = .{ .array_view = .{ .items = items[start..end], .source = source } };
    return .{ .object = out };
}

pub fn arrayAppend(ctx: VMContext, arr_obj: *Object, elems: []const Value) !Value {
    const base = try vms.asArraySlice(arr_obj);
    const new_len = base.len + elems.len;

    // Fast path: reuse backing buffer when spare capacity exists.
    if (arr_obj.* == .array_capacity) {
        const ac = arr_obj.array_capacity;
        const cap = ac.backing.array_managed.len;
        if (new_len <= cap) {
            @memcpy(ac.backing.array_managed[ac.len .. ac.len + elems.len], elems);
            const obj = try vmgc.vmAllocObject(ctx);
            obj.* = .{ .array_capacity = .{ .backing = ac.backing, .len = new_len } };
            return .{ .object = obj };
        }
    }

    // Slow path: allocate a new backing buffer with 2x growth, capped at the
    // heap's largest single block so we never trigger AllocationTooLarge early.
    const ideal_cap = @max(new_len * 2, new_len + 4);
    const max_cap_values = ctx.hs.maxManagedAlloc() / @sizeOf(Value);
    const new_cap = if (ideal_cap <= max_cap_values) ideal_cap else @max(new_len, max_cap_values);
    const backing_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    const out = try vmgc.vmAllocManagedSlice(ctx, Value, new_cap);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len .. base.len + elems.len], elems);
    // Zero-fill spare capacity so the GC never traces stale pointers.
    @memset(out[new_len..new_cap], .null);
    backing_obj.* = .{ .array_managed = out };
    const obj = try vmgc.vmAllocObject(ctx); // backing_obj is temp-rooted
    obj.* = .{ .array_capacity = .{ .backing = backing_obj, .len = new_len } };
    return .{ .object = obj };
}
