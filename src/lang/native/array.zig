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

fn predBool(ctx: VMContext, v: Value) !bool {
    return v.asBool() catch {
        ctx.vs.setRuntimeErr("predicate must return bool, got {s}", .{vmtyp.runtimeTypeName(v)});
        return error.TypeError;
    };
}

// Re-derives the array's current backing slice on every call rather than
// trusting one captured earlier. Every function below loops over an
// array's elements while calling into code that can allocate (a user
// callback via vm.callFunction, or the function's own managed
// allocations) — any such call can trigger a GC + compaction that
// relocates arr_obj's backing storage. arr_obj's own field is correctly
// updated when that happens; a slice held in a local variable across the
// call is not, and reading from it afterward is reading relocated-away
// (and possibly already reused) memory.
fn itemAt(arr_obj: *Object, i: usize) !Value {
    return (try vms.asArraySlice(arr_obj))[i];
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .array_filter => {
            const fn_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            var count: usize = 0;
            for (0..items_len) |i| {
                const item = try itemAt(arr_obj, i);
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ctx, ok)) count += 1;
            }
            // allocTempRootedManagedValueArray publishes the backing block
            // to out_arr.obj immediately (rather than only once fully
            // filled in), so it stays safe from compaction across every
            // remaining callFunction call in the loop below.
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, count);
            defer ctx.vs.popTempRoot();
            var idx: usize = 0;
            for (0..items_len) |i| {
                const item = try itemAt(arr_obj, i);
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ctx, ok)) {
                    out_arr.set(idx, item);
                    idx += 1;
                }
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_arr.obj });
        },
        .array_flat => {
            const arr_val = ctx.vs.vmTop(0);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            // First pass is read-only (no allocation), so the slice
            // captured here is safe to use throughout it.
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
            defer ctx.vs.popTempRoot();
            if (total > 0) {
                const out = try vmgc.vmAllocManagedSlice(ctx, Value, total);
                // Re-derive: the allocation above can trigger a compaction
                // that relocates arr_obj's backing, staling the `items`
                // captured before it. Nothing else in this second pass
                // allocates, so one re-derivation here is enough.
                const items_now = try vms.asArraySlice(arr_obj);
                var idx: usize = 0;
                for (items_now) |item| {
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
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_obj });
        },
        .array_map => {
            const fn_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, items_len);
            defer ctx.vs.popTempRoot();
            for (0..items_len) |i| {
                const item = try itemAt(arr_obj, i);
                out_arr.set(i, try vm.callFunction(ctx, fn_val, &.{item}));
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_arr.obj });
        },
        .array_reduce => {
            const init_val = ctx.vs.vmTop(0);
            const fn_val = ctx.vs.vmTop(1);
            const arr_val = ctx.vs.vmTop(2);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            var acc = init_val;
            // acc is reassigned every iteration, so its temp root must be
            // refreshed each time too — a root pushed once at the start
            // only protects the *original* value, not later reassignments.
            try ctx.vs.pushTempRoot(acc);
            for (0..items_len) |i| {
                const item = try itemAt(arr_obj, i);
                const next = try vm.callFunction(ctx, fn_val, &.{ acc, item });
                ctx.vs.popTempRoot();
                acc = next;
                try ctx.vs.pushTempRoot(acc);
            }
            ctx.vs.popTempRoot();
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(acc);
        },
        .array_slice => {
            const to_val = ctx.vs.vmTop(0);
            const from_val = ctx.vs.vmTop(1);
            const arr_val = ctx.vs.vmTop(2);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            const from = try vms.valueAsInt(from_val);
            const to = try vms.valueAsInt(to_val);
            if (from < 0 or to > @as(i64, @intCast(items_len)) or from > to) return error.IndexOutOfBounds;
            const from_u: usize = @intCast(from);
            const to_u: usize = @intCast(to);
            const out_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
            defer ctx.vs.popTempRoot();
            const slice_len = to_u - from_u;
            if (slice_len > 0) {
                const out = try vmgc.vmAllocManagedSlice(ctx, Value, slice_len);
                // Re-derive after the allocation above, which can compact
                // and relocate arr_obj's backing.
                const items_now = try vms.asArraySlice(arr_obj);
                @memcpy(out[0..slice_len], items_now[from_u..to_u]);
                out_obj.* = .{ .array_managed = out[0..slice_len] };
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_obj });
        },
        .array_zip => {
            const b_val = ctx.vs.vmTop(0);
            const a_val = ctx.vs.vmTop(1);
            if (a_val != .object or b_val != .object) return error.TypeError;
            const a_obj = a_val.object;
            const b_obj = b_val.object;
            if (!vms.isArrayObject(a_obj) or !vms.isArrayObject(b_obj)) return error.TypeError;
            const pair_count = @min((try vms.asArraySlice(a_obj)).len, (try vms.asArraySlice(b_obj)).len);
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, pair_count);
            defer ctx.vs.popTempRoot();
            for (0..pair_count) |i| {
                // Re-derive both sides fresh each iteration: either array's
                // backing may have moved since the previous iteration's
                // allocations.
                const a_item = try itemAt(a_obj, i);
                const b_item = try itemAt(b_obj, i);
                const pair_arr = try vmgc.allocTempRootedManagedValueArray(ctx, 2);
                defer ctx.vs.popTempRoot();
                pair_arr.set(0, a_item);
                pair_arr.set(1, b_item);
                out_arr.set(i, .{ .object = pair_arr.obj });
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_arr.obj });
        },
        .array_find => {
            const fn_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            var result: Value = .null;
            for (0..items_len) |i| {
                const item = try itemAt(arr_obj, i);
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ctx, ok)) {
                    result = item;
                    break;
                }
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .array_find_index => {
            const fn_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            var result: Value = .{ .int = -1 };
            for (0..items_len) |i| {
                const item = try itemAt(arr_obj, i);
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ctx, ok)) {
                    result = .{ .int = @intCast(i) };
                    break;
                }
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(result);
        },
        .array_all => {
            const fn_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            var result = true;
            for (0..items_len) |i| {
                const item = try itemAt(arr_obj, i);
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (!(try predBool(ctx, ok))) {
                    result = false;
                    break;
                }
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = result });
        },
        .array_any => {
            const fn_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            var result = false;
            for (0..items_len) |i| {
                const item = try itemAt(arr_obj, i);
                const ok = try vm.callFunction(ctx, fn_val, &.{item});
                if (try predBool(ctx, ok)) {
                    result = true;
                    break;
                }
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = result });
        },
        .array_chunk => {
            const size_val = ctx.vs.vmTop(0);
            const arr_val = ctx.vs.vmTop(1);
            if (arr_val != .object) return error.TypeError;
            const arr_obj = arr_val.object;
            if (!vms.isArrayObject(arr_obj)) return error.TypeError;
            const size = try vms.valueAsInt(size_val);
            if (size <= 0) return error.RangeError;
            const sz: usize = @intCast(size);
            const items_len = (try vms.asArraySlice(arr_obj)).len;
            const chunk_count = if (items_len == 0) 0 else (items_len + sz - 1) / sz;
            const out_arr = try vmgc.allocTempRootedManagedValueArray(ctx, chunk_count);
            defer ctx.vs.popTempRoot();
            for (0..chunk_count) |ci| {
                const from = ci * sz;
                const to = @min(from + sz, items_len);
                const chunk_arr = try vmgc.allocTempRootedManagedValueArray(ctx, to - from);
                defer ctx.vs.popTempRoot();
                // Re-derive after chunk_arr's own allocation, which can
                // compact and relocate arr_obj's backing.
                chunk_arr.setAll((try vms.asArraySlice(arr_obj))[from..to]);
                out_arr.set(ci, .{ .object = chunk_arr.obj });
            }
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = out_arr.obj });
        },
        else => {},
    }
}
