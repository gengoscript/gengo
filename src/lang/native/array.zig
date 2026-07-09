const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const Object = @import("../value.zig").Object;
const Value = @import("../value.zig").Value;
const vm = @import("../vm.zig");
const vmgc = @import("../vm_gc.zig");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmtyp = @import("../vm_types.zig");

fn predBool(v: Value) !bool {
    return v.asBool() catch {
        vms.setRuntimeErr("predicate must return bool, got {s}", .{vmtyp.runtimeTypeName(v)});
        return error.TypeError;
    };
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .array_filter => {
            const fn_val = vms.vmTop(0);
            const arr_val = vms.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
            defer vms.popTempRoot();
            var count: usize = 0;
            for (items) |item| {
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ok)) count += 1;
            }
            if (count > 0) {
                const out = try vmgc.vmAllocManagedSlice(ctx, Value, count);
                var idx: usize = 0;
                for (items) |item| {
                    const ok = try vm.callFunction(ctx, fn_val, &.{item});
                    if (try predBool(ok)) {
                        out[idx] = item;
                        idx += 1;
                    }
                }
                out_obj.* = .{ .array_managed = out[0..count] };
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_flat => {
            const arr_val = vms.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            var total: usize = 0;
            for (items) |item| {
                if (item == .object and vms.isArrayObject(item.object)) {
                    total += (try vms.asArraySlice(item.object)).len;
                } else {
                    total += 1;
                }
            }
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
            defer vms.popTempRoot();
            if (total > 0) {
                const out = try vmgc.vmAllocManagedSlice(ctx, Value, total);
                var idx: usize = 0;
                for (items) |item| {
                    if (item == .object and vms.isArrayObject(item.object)) {
                        const sub = try vms.asArraySlice(item.object);
                        @memcpy(out[idx..][0..sub.len], sub);
                        idx += sub.len;
                    } else {
                        out[idx] = item;
                        idx += 1;
                    }
                }
                out_obj.* = .{ .array_managed = out[0..total] };
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_map => {
            const fn_val = vms.vmTop(0);
            const arr_val = vms.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, items.len);
            defer vms.popTempRoot();
            if (items.len > 0) {
                for (items, 0..) |item, i| {
                    out_arr.values[i] = try vm.callFunction(ctx, fn_val, &.{item});
                    out_arr.publish(i + 1);
                }
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .object = out_arr.obj });
        },
        .array_reduce => {
            const init_val = vms.vmTop(0);
            const fn_val = vms.vmTop(1);
            const arr_val = vms.vmTop(2);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            var acc = init_val;
            try vms.pushTempRoot(acc);
            defer vms.popTempRoot();
            for (items) |item| {
                acc = try vm.callFunction(ctx, fn_val, &.{ acc, item });
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(acc);
        },
        .array_slice => {
            const to_val = vms.vmTop(0);
            const from_val = vms.vmTop(1);
            const arr_val = vms.vmTop(2);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            const from = try vms.valueAsInt(from_val);
            const to = try vms.valueAsInt(to_val);
            if (from < 0 or to > @as(i64, @intCast(items.len)) or from > to) return error.IndexOutOfBounds;
            const from_u: usize = @intCast(from);
            const to_u: usize = @intCast(to);
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
            defer vms.popTempRoot();
            const slice_len = to_u - from_u;
            if (slice_len > 0) {
                const out = try vmgc.vmAllocManagedSlice(ctx, Value, slice_len);
                @memcpy(out[0..slice_len], items[from_u..to_u]);
                out_obj.* = .{ .array_managed = out[0..slice_len] };
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_zip => {
            const b_val = vms.vmTop(0);
            const a_val = vms.vmTop(1);
            if (a_val != .object or b_val != .object) return error.TypeError;
            const a_obj = a_val.object;
            const b_obj = b_val.object;
            if (!vms.isArrayObject(a_obj) or !vms.isArrayObject(b_obj)) return error.TypeError;
            const a_items = try vms.asArraySlice(a_obj);
            const b_items = try vms.asArraySlice(b_obj);
            const pair_count = @min(a_items.len, b_items.len);
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, pair_count);
            defer vms.popTempRoot();
            if (pair_count > 0) {
                for (0..pair_count) |i| {
                    const pair_arr = try vmgc.allocTempRootedManagedValueArray(ctx, 2);
                    defer vms.popTempRoot();
                    pair_arr.values[0] = a_items[i];
                    pair_arr.values[1] = b_items[i];
                    pair_arr.publish(2);
                    out_arr.values[i] = .{ .object = pair_arr.obj };
                    out_arr.publish(i + 1);
                }
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .object = out_arr.obj });
        },
        .array_find => {
            const fn_val = vms.vmTop(0);
            const arr_val = vms.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            var result: Value = .null;
            for (items) |item| {
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ok)) {
                    result = item;
                    break;
                }
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(result);
        },
        .array_find_index => {
            const fn_val = vms.vmTop(0);
            const arr_val = vms.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            var result: Value = .{ .int = -1 };
            for (items, 0..) |item, i| {
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ok)) {
                    result = .{ .int = @intCast(i) };
                    break;
                }
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(result);
        },
        .array_all => {
            const fn_val = vms.vmTop(0);
            const arr_val = vms.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            var result = true;
            for (items) |item| {
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (!(try predBool(ok))) {
                    result = false;
                    break;
                }
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .boolean = result });
        },
        .array_any => {
            const fn_val = vms.vmTop(0);
            const arr_val = vms.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = try vms.asArraySlice(arr_obj);
            var result = false;
            for (items) |item| {
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ok)) {
                    result = true;
                    break;
                }
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .boolean = result });
        },
        .array_chunk => {
            const size_val = vms.vmTop(0);
            const arr_val = vms.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const size = try vms.valueAsInt(size_val);
            if (size <= 0) return error.RangeError;
            const sz: usize = @intCast(size);
            const items = try vms.asArraySlice(arr_obj);
            const chunk_count = if (items.len == 0) 0 else (items.len + sz - 1) / sz;
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, chunk_count);
            defer vms.popTempRoot();
            if (chunk_count > 0) {
                for (0..chunk_count) |ci| {
                    const from = ci * sz;
                    const to = @min(from + sz, items.len);
                    const chunk_arr = try vmgc.allocTempRootedManagedValueArray(ctx, to - from);
                    defer vms.popTempRoot();
                    @memcpy(chunk_arr.values, items[from..to]);
                    chunk_arr.publish(to - from);
                    out_arr.values[ci] = .{ .object = chunk_arr.obj };
                    out_arr.publish(ci + 1);
                }
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .object = out_arr.obj });
        },
        else => {},
    }
}
