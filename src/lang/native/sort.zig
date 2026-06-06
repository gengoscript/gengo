const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const Object = @import("../value.zig").Object;
const compare = @import("compare.zig");
const vm = @import("../vm.zig");
const vmgc = @import("../vm_gc.zig");
const vms = @import("../vm_state.zig");

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .sort_asc => {

            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            var items = try vms.cloneArraySlice(arr_obj);
            const n = items.len;
            if (n > 1) {
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    const key = items[i];
                    var j: usize = i;
                    while (j > 0 and try compare.valueGreaterThan(items[j - 1], key)) : (j -= 1) {
                        items[j] = items[j - 1];
                    }
                    items[j] = key;
                }
            }
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array_managed = items[0..n] };
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .sort_by => {

            if (argc != nf.arity) return error.ArityMismatch;
            const fn_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 2];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            var items = try vms.cloneArraySlice(arr_obj);
            const n = items.len;
            if (n > 1) {
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    const key = items[i];
                    var j: usize = i;
                    while (j > 0) : (j -= 1) {
                        const cmp = try vm.callFunction(fn_val, &.{ items[j - 1], key });
                        const less = if (cmp == .number) cmp.number < 0 else cmp.isTruthy();
                        if (less) break;
                        items[j] = items[j - 1];
                    }
                    items[j] = key;
                }
            }
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array_managed = items[0..n] };
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        .sort_desc => {

            if (argc != nf.arity) return error.ArityMismatch;
            const arr_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            var items = try vms.cloneArraySlice(arr_obj);
            const n = items.len;
            if (n > 1) {
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    const key = items[i];
                    var j: usize = i;
                    while (j > 0 and try compare.valueLessThan(items[j - 1], key)) : (j -= 1) {
                        items[j] = items[j - 1];
                    }
                    items[j] = key;
                }
            }
            const out_obj = try vmgc.vmAllocObject();
            out_obj.* = .{ .array_managed = items[0..n] };
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .object = out_obj });
        },
        else => {},
    }
}
