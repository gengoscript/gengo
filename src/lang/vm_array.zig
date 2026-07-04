const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;

pub fn arrayRead(obj: *Object, idx_v: Value) !Value {
    const items = try vms.asArraySlice(obj);
    const idx = try vms.vmIndexFromVal(idx_v);
    if (idx >= items.len) {
        vms.setRuntimeErr("index {} out of bounds for array of length {}", .{ idx, items.len });
        return error.IndexOutOfBounds;
    }
    return items[idx];
}

pub fn arrayWrite(obj: *Object, idx_v: Value, val: Value) !void {
    const items = try vms.asArraySlice(obj);
    const idx = try vms.vmIndexFromVal(idx_v);
    if (idx >= items.len) {
        vms.setRuntimeErr("index {} out of bounds for array of length {}", .{ idx, items.len });
        return error.IndexOutOfBounds;
    }
    items[idx] = val;
}

pub fn arraySlice(obj: *Object, has_start: bool, start_v: Value, has_end: bool, end_v: Value) !Value {
    const items = try vms.asArraySlice(obj);
    const start: usize = if (has_start) try vms.vmSliceIndex(start_v, items.len) else 0;
    const end: usize = if (has_end) try vms.vmSliceIndex(end_v, items.len) else items.len;
    if (start > end) return error.IndexOutOfBounds;
    const out = try vmgc.vmAllocObject();
    const source = switch (obj.*) {
        .array_view => obj.array_view.source,
        else => obj,
    };
    out.* = .{ .array_view = .{ .items = items[start..end], .source = source } };
    return .{ .object = out };
}
