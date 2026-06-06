const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const Object = @import("../value.zig").Object;
const Value = @import("../value.zig").Value;
const vm = @import("../vm.zig");
const vmgc = @import("../vm_gc.zig");
const vms = @import("../vm_state.zig");

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .array_filter => {

            if (argc != nf.arity) return error.ArityMismatch;
            const fn_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            var count: usize = 0;
            for (items) |item| {
                const ok = try vm.callFunction(fn_val, &.{item});
                if (ok.isTruthy()) count += 1;
            }
            if (count > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, count);
                var idx: usize = 0;
                for (items) |item| {
                    const ok = try vm.callFunction(fn_val, &.{item});
                    if (ok.isTruthy()) {
                        out[idx] = item;
                        idx += 1;
                    }
                }
                out_obj.* = .{ .array_managed = out[0..count] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_flat => {

            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            var total: usize = 0;
            for (items) |item| {
                if (item == .object and vms.isArrayObject(item.object)) {
                    total += vms.asArraySlice(item.object).len;
                } else {
                    total += 1;
                }
            }
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            if (total > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, total);
                var idx: usize = 0;
                for (items) |item| {
                    if (item == .object and vms.isArrayObject(item.object)) {
                        const sub = vms.asArraySlice(item.object);
                        @memcpy(out[idx..][0..sub.len], sub);
                        idx += sub.len;
                    } else {
                        out[idx] = item;
                        idx += 1;
                    }
                }
                out_obj.* = .{ .array_managed = out[0..total] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_map => {

            if (argc != nf.arity) return error.ArityMismatch;
            const fn_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            if (items.len > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, items.len);
                for (items, 0..) |item, i| {
                    out[i] = try vm.callFunction(fn_val, &.{item});
                }
                out_obj.* = .{ .array_managed = out[0..items.len] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_reduce => {

            if (argc != nf.arity) return error.ArityMismatch;
            const init_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const fn_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 3];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            var acc = init_val;
            try vms.pushTempRoot(acc);
            defer vms.popTempRoot();
            for (items) |item| {
                acc = try vm.callFunction(fn_val, &.{ acc, item });
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(acc);
        },
        .array_slice => {

            if (argc != nf.arity) return error.ArityMismatch;
            const to_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const from_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 3];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items = vms.asArraySlice(arr_obj);
            const from = try vms.valueAsInt(from_val);
            const to = try vms.valueAsInt(to_val);
            if (from < 0 or to > @as(i64, @intCast(items.len)) or from > to) return error.IndexOutOfBounds;
            const from_u: usize = @intCast(from);
            const to_u: usize = @intCast(to);
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            const slice_len = to_u - from_u;
            if (slice_len > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, slice_len);
                @memcpy(out[0..slice_len], items[from_u..to_u]);
                out_obj.* = .{ .array_managed = out[0..slice_len] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .array_zip => {

            if (argc != nf.arity) return error.ArityMismatch;
            const b_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const a_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            if (a_val != .object or b_val != .object) return error.TypeError;
            const a_obj = a_val.object;
            const b_obj = b_val.object;
            if (!vms.isArrayObject(a_obj) or !vms.isArrayObject(b_obj)) return error.TypeError;
            const a_items = vms.asArraySlice(a_obj);
            const b_items = vms.asArraySlice(b_obj);
            const pair_count = @min(a_items.len, b_items.len);
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = out_obj });
            defer vms.popTempRoot();
            if (pair_count > 0) {
                const out = try vmgc.vmAllocManagedSlice(Value, pair_count);
                for (0..pair_count) |i| {
                    const pair = try vmgc.vmAllocObject();
                    const pair_items = try vmgc.vmAllocManagedSlice(Value, 2);
                    pair_items[0] = a_items[i];
                    pair_items[1] = b_items[i];
                    pair.* = .{ .array_managed = pair_items[0..2] };
                    out[i] = .{ .object = pair };
                }
                out_obj.* = .{ .array_managed = out[0..pair_count] };
            }
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        else => {},
    }
}
