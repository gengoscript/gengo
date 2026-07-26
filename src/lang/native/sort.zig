const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const Object = @import("../value.zig").Object;
const compare = @import("compare.zig");
const vm = @import("../vm.zig");
const vmgc = @import("../vm_gc.zig");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmtyp = @import("../vm_types.zig");

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .sort_asc => {
            const arr_val = ctx.vs.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const n = (try vms.asArraySlice(arr_obj)).len;
            // Allocate the working copy as a GC-visible, temp-rooted array
            // right away (rather than an owner-less clone) so it survives
            // any allocation below — cloneArraySlice's old unrooted slice
            // went stale if a later allocation forced a heap compaction.
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, n);
            defer ctx.vs.popTempRoot();
            out_arr.setAll(try vms.asArraySlice(arr_obj));
            // Safe to hold as one slice across the whole loop: valueGreaterThan
            // does no allocation, so nothing here can move out_arr's backing.
            const items = out_arr.obj.array_managed;
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
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_arr.obj });
        },
        .sort_by => {
            const fn_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const n = (try vms.asArraySlice(arr_obj)).len;
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, n);
            defer ctx.vs.popTempRoot();
            out_arr.setAll(try vms.asArraySlice(arr_obj));
            if (n > 1) {
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    // Re-derive out_arr's slice after every callFunction: the
                    // comparator is arbitrary user code and can allocate,
                    // which can trigger a heap compaction that relocates
                    // out_arr's backing storage. A slice captured before the
                    // call would then point at stale/reused memory.
                    const key = out_arr.obj.array_managed[i];
                    var j: usize = i;
                    while (j > 0) : (j -= 1) {
                        const prev = out_arr.obj.array_managed[j - 1];
                        const cmp = try vm.callFunction(ctx, fn_val, &.{ prev, key });
                        const less = if (cmp == .int) cmp.int < 0 else if (cmp == .float) cmp.float < 0 else cmp.asBool() catch {
                            ctx.vs.setRuntimeErr("comparator must return int, float, or bool, got {s}", .{vmtyp.runtimeTypeName(cmp)});
                            return error.TypeError;
                        };
                        if (less) break;
                        out_arr.obj.array_managed[j] = out_arr.obj.array_managed[j - 1];
                    }
                    out_arr.obj.array_managed[j] = key;
                }
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_arr.obj });
        },
        .sort_desc => {
            const arr_val = ctx.vs.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const n = (try vms.asArraySlice(arr_obj)).len;
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, n);
            defer ctx.vs.popTempRoot();
            out_arr.setAll(try vms.asArraySlice(arr_obj));
            // Safe to hold as one slice across the whole loop: valueLessThan
            // does no allocation, so nothing here can move out_arr's backing.
            const items = out_arr.obj.array_managed;
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
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_arr.obj });
        },
        else => {},
    }
}
