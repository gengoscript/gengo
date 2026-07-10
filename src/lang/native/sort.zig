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
            const out_obj = try vmgc.vmAllocObject(ctx);
            out_obj.* = .{ .array_managed = items[0..n] };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_obj });
        },
        .sort_by => {
            const fn_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
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
                        const cmp = try vm.callFunction(ctx, fn_val, &.{ items[j - 1], key });
                        const less = if (cmp == .int) cmp.int < 0 else if (cmp == .float) cmp.float < 0 else cmp.asBool() catch {
                            ctx.vs.setRuntimeErr("comparator must return int, float, or bool, got {s}", .{vmtyp.runtimeTypeName(cmp)});
                            return error.TypeError;
                        };
                        if (less) break;
                        items[j] = items[j - 1];
                    }
                    items[j] = key;
                }
            }
            const out_obj = try vmgc.vmAllocObject(ctx);
            out_obj.* = .{ .array_managed = items[0..n] };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_obj });
        },
        .sort_desc => {
            const arr_val = ctx.vs.vmTop(0);
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
            const out_obj = try vmgc.vmAllocObject(ctx);
            out_obj.* = .{ .array_managed = items[0..n] };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_obj });
        },
        else => {},
    }
}
