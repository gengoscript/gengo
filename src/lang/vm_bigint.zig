const std = @import("std");
const Bi = std.math.big.int;
const Limb = std.math.big.Limb;
const vmod = @import("value.zig");
const BigIntObj = vmod.BigIntObj;
const Value = vmod.Value;
const Object = vmod.Object;
const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");

pub const VMContext = vms.VMContext;

pub fn isBigInt(v: Value) bool {
    return v == .object and v.object.* == .bigint;
}

fn strBytes(v: Value) []const u8 {
    return switch (v) {
        .string => |ss| ss.bytes,
        .object => |o| switch (o.*) {
            .dyn_string => |s| s,
            .string_view => |sv| sv.bytes,
            else => "",
        },
        else => "",
    };
}

// ── Construction ──────────────────────────────────────────────────────────────

pub fn fromInt(ctx: VMContext, n: i64) !Value {
    const cap = Bi.calcLimbLen(n);
    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{
        .limbs = &[_]Limb{},
        .len = 0,
        .positive = true,
    } });
    defer ctx.vs.popTempRoot();
    const limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, cap);
    const m = Bi.Mutable.init(limbs, n);
    obj.* = .{ .bigint = .{ .limbs = limbs, .len = m.len, .positive = m.positive } };
    return .{ .object = obj };
}

// fromStrVal converts a string Value to bigint (decimal format, optional leading '-').
// str_val must be alive (on stack or temp_roots) before calling.
pub fn fromStrVal(ctx: VMContext, str_val: Value) !Value {
    // Read length before allocating (length is stable across GC)
    const initial = strBytes(str_val);
    const digit_str = if (initial.len > 0 and initial[0] == '-') initial[1..] else initial;
    const limb_cap = Bi.calcSetStringLimbCount(10, @max(digit_str.len, 1)) + 1;

    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{
        .limbs = &[_]Limb{},
        .len = 0,
        .positive = true,
    } });
    defer ctx.vs.popTempRoot();
    const limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, limb_cap);

    // Re-read bytes after potential compaction (pointer updated by compactUpdateObj)
    const str = strBytes(str_val);
    var m = Bi.Mutable{ .limbs = limbs, .len = 0, .positive = true };
    try m.setString(10, str);

    obj.* = .{ .bigint = .{ .limbs = limbs, .len = m.len, .positive = m.positive } };
    return .{ .object = obj };
}

// ── Type queries ──────────────────────────────────────────────────────────────

pub fn compareValues(a: Value, b: Value) !std.math.Order {
    const a_bi = isBigInt(a);
    const b_bi = isBigInt(b);
    if (a_bi and b_bi) return a.object.bigint.toConst().order(b.object.bigint.toConst());
    if (a_bi and b == .int) return a.object.bigint.toConst().orderAgainstScalar(b.int);
    if (a == .int and b_bi) return b.object.bigint.toConst().orderAgainstScalar(a.int).invert();
    return error.TypeError;
}

pub fn toInt(a: Value) !i64 {
    return a.object.bigint.toConst().toInt(i64) catch error.RangeError;
}

pub fn toFloat(a: Value) f64 {
    const f, _ = a.object.bigint.toConst().toFloat(f64, .nearest_even);
    return f;
}

pub fn toDynString(ctx: VMContext, a: Value) !Value {
    const bi = a.object.bigint;
    const ac = bi.toConst();
    if (bi.len == 0 or ac.eqlZero()) return vmgc.makeDynString(ctx, "0");

    const str_cap = ac.sizeInBaseUpperBound(10);
    const str_buf = try std.heap.page_allocator.alloc(u8, str_cap);
    defer std.heap.page_allocator.free(str_buf);

    const scratch_cap = Bi.calcToStringLimbsBufferLen(bi.len, 10);
    const limb_scratch: []Limb = if (scratch_cap > 0)
        try std.heap.page_allocator.alloc(Limb, scratch_cap)
    else
        &[_]Limb{};
    defer if (scratch_cap > 0) std.heap.page_allocator.free(limb_scratch);

    const n = ac.toString(str_buf, 10, .lower, limb_scratch);
    return vmgc.makeDynString(ctx, str_buf[0..n]);
}

// Format a bigint as decimal digits directly into a writer, using
// page_allocator scratch space (not the Gengo GC heap) — for callers like
// std.json.stringify that only have a std.io writer on hand, not a
// VMContext to allocate a dyn_string through.
pub fn writeDecimal(a: Value, writer: anytype) !void {
    const bi = a.object.bigint;
    const ac = bi.toConst();
    if (bi.len == 0 or ac.eqlZero()) {
        try writer.writeAll("0");
        return;
    }
    const str_cap = ac.sizeInBaseUpperBound(10);
    const str_buf = try std.heap.page_allocator.alloc(u8, str_cap);
    defer std.heap.page_allocator.free(str_buf);

    const scratch_cap = Bi.calcToStringLimbsBufferLen(bi.len, 10);
    const limb_scratch: []Limb = if (scratch_cap > 0)
        try std.heap.page_allocator.alloc(Limb, scratch_cap)
    else
        &[_]Limb{};
    defer if (scratch_cap > 0) std.heap.page_allocator.free(limb_scratch);

    const n = ac.toString(str_buf, 10, .lower, limb_scratch);
    try writer.writeAll(str_buf[0..n]);
}

// ── Arithmetic helpers ────────────────────────────────────────────────────────

// Promote an int Value to bigint, keeping `other` alive during the allocation.
pub fn promoteInt(ctx: VMContext, n: i64, other: Value) !Value {
    try ctx.vs.pushTempRoot(other);
    defer ctx.vs.popTempRoot();
    return fromInt(ctx, n);
}

pub fn addBi(ctx: VMContext, a: Value, b: Value) !Value {
    try ctx.vs.pushTempRoot(a);
    defer ctx.vs.popTempRoot();
    try ctx.vs.pushTempRoot(b);
    defer ctx.vs.popTempRoot();

    const cap = @max(a.object.bigint.len, b.object.bigint.len) + 1;
    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{ .limbs = &[_]Limb{}, .len = 0, .positive = true } });
    defer ctx.vs.popTempRoot();
    const limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, cap);

    var r = Bi.Mutable{ .limbs = limbs, .len = 0, .positive = true };
    r.add(a.object.bigint.toConst(), b.object.bigint.toConst());
    obj.* = .{ .bigint = .{ .limbs = limbs, .len = r.len, .positive = r.positive } };
    return .{ .object = obj };
}

pub fn subBi(ctx: VMContext, a: Value, b: Value) !Value {
    try ctx.vs.pushTempRoot(a);
    defer ctx.vs.popTempRoot();
    try ctx.vs.pushTempRoot(b);
    defer ctx.vs.popTempRoot();

    const cap = @max(a.object.bigint.len, b.object.bigint.len) + 1;
    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{ .limbs = &[_]Limb{}, .len = 0, .positive = true } });
    defer ctx.vs.popTempRoot();
    const limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, cap);

    var r = Bi.Mutable{ .limbs = limbs, .len = 0, .positive = true };
    r.sub(a.object.bigint.toConst(), b.object.bigint.toConst());
    obj.* = .{ .bigint = .{ .limbs = limbs, .len = r.len, .positive = r.positive } };
    return .{ .object = obj };
}

pub fn mulBi(ctx: VMContext, a: Value, b: Value) !Value {
    try ctx.vs.pushTempRoot(a);
    defer ctx.vs.popTempRoot();
    try ctx.vs.pushTempRoot(b);
    defer ctx.vs.popTempRoot();

    const cap = @max(a.object.bigint.len + b.object.bigint.len, 1);
    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{ .limbs = &[_]Limb{}, .len = 0, .positive = true } });
    defer ctx.vs.popTempRoot();
    const limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, cap);

    var r = Bi.Mutable{ .limbs = limbs, .len = 0, .positive = true };
    // Pass empty limbs_buffer since result slice doesn't alias either operand.
    r.mul(a.object.bigint.toConst(), b.object.bigint.toConst(), &[_]Limb{}, null);
    obj.* = .{ .bigint = .{ .limbs = limbs, .len = r.len, .positive = r.positive } };
    return .{ .object = obj };
}

pub fn intDivBi(ctx: VMContext, a: Value, b: Value) !Value {
    if (b.object.bigint.toConst().eqlZero()) {
        ctx.vs.setRuntimeErr("division by zero", .{});
        return error.DivisionByZero;
    }
    try ctx.vs.pushTempRoot(a);
    defer ctx.vs.popTempRoot();
    try ctx.vs.pushTempRoot(b);
    defer ctx.vs.popTempRoot();

    const a_len = a.object.bigint.len;
    const b_len = b.object.bigint.len;
    const q_cap = a_len + 1;
    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{ .limbs = &[_]Limb{}, .len = 0, .positive = true } });
    defer ctx.vs.popTempRoot();
    const q_limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, q_cap);

    const a_const = a.object.bigint.toConst();
    const b_const = b.object.bigint.toConst();

    const r_cap = b_len + 1;
    const div_scratch_cap = Bi.calcDivLimbsBufferLen(a_len, b_len);
    const tmp = try std.heap.page_allocator.alloc(Limb, r_cap + div_scratch_cap);
    defer std.heap.page_allocator.free(tmp);

    var q = Bi.Mutable{ .limbs = q_limbs, .len = 0, .positive = true };
    var rem = Bi.Mutable{ .limbs = tmp[0..r_cap], .len = 0, .positive = true };
    Bi.Mutable.divTrunc(&q, &rem, a_const, b_const, tmp[r_cap..]);

    obj.* = .{ .bigint = .{ .limbs = q_limbs, .len = q.len, .positive = q.positive } };
    return .{ .object = obj };
}

pub fn remBi(ctx: VMContext, a: Value, b: Value) !Value {
    if (b.object.bigint.toConst().eqlZero()) {
        ctx.vs.setRuntimeErr("division by zero", .{});
        return error.DivisionByZero;
    }
    try ctx.vs.pushTempRoot(a);
    defer ctx.vs.popTempRoot();
    try ctx.vs.pushTempRoot(b);
    defer ctx.vs.popTempRoot();

    const a_len = a.object.bigint.len;
    const b_len = b.object.bigint.len;
    const r_cap = b_len + 1;
    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{ .limbs = &[_]Limb{}, .len = 0, .positive = true } });
    defer ctx.vs.popTempRoot();
    const r_limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, r_cap);

    const a_const = a.object.bigint.toConst();
    const b_const = b.object.bigint.toConst();

    const q_cap = a_len + 1;
    const div_scratch_cap = Bi.calcDivLimbsBufferLen(a_len, b_len);
    const tmp = try std.heap.page_allocator.alloc(Limb, q_cap + div_scratch_cap);
    defer std.heap.page_allocator.free(tmp);

    var q = Bi.Mutable{ .limbs = tmp[0..q_cap], .len = 0, .positive = true };
    var r = Bi.Mutable{ .limbs = r_limbs, .len = 0, .positive = true };
    Bi.Mutable.divTrunc(&q, &r, a_const, b_const, tmp[q_cap..]);

    obj.* = .{ .bigint = .{ .limbs = r_limbs, .len = r.len, .positive = r.positive } };
    return .{ .object = obj };
}

pub fn modBi(ctx: VMContext, a: Value, b: Value) !Value {
    const r = try remBi(ctx, a, b);
    const r_const = r.object.bigint.toConst();
    const b_const = b.object.bigint.toConst();
    // Floor mod: if remainder non-zero with different sign than divisor, add divisor.
    if (!r_const.eqlZero() and r_const.positive != b_const.positive) {
        try ctx.vs.pushTempRoot(r);
        defer ctx.vs.popTempRoot();
        return addBi(ctx, r, b);
    }
    return r;
}

pub fn powBi(ctx: VMContext, a: Value, exp: u32) !Value {
    // Read metadata before allocation; limb values don't change during compaction.
    const a_len = a.object.bigint.len;
    const a_const_pre = a.object.bigint.toConst();
    const a_bits = if (a_const_pre.eqlZero()) 0 else a_const_pre.bitCountAbs();
    const needed: usize = if (exp == 0 or a_bits == 0 or (a_len == 1 and a.object.bigint.limbs[0] <= 1))
        @max(a_len, 1)
    else if (exp == 1)
        a_len
    else
        Bi.calcPowLimbsBufferLen(a_bits, exp);

    try ctx.vs.pushTempRoot(a);
    defer ctx.vs.popTempRoot();
    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{ .limbs = &[_]Limb{}, .len = 0, .positive = true } });
    defer ctx.vs.popTempRoot();
    const r_limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, @max(needed, 1));

    const a_const = a.object.bigint.toConst();
    const scratch = try std.heap.page_allocator.alloc(Limb, @max(needed, 1));
    defer std.heap.page_allocator.free(scratch);

    var r = Bi.Mutable{ .limbs = r_limbs, .len = 0, .positive = true };
    r.pow(a_const, exp, scratch);

    obj.* = .{ .bigint = .{ .limbs = r_limbs, .len = r.len, .positive = r.positive } };
    return .{ .object = obj };
}

pub fn negBi(ctx: VMContext, a: Value) !Value {
    const a_len = a.object.bigint.len;
    try ctx.vs.pushTempRoot(a);
    defer ctx.vs.popTempRoot();
    const obj = try vmgc.allocTempRooted(ctx, .{ .bigint = .{ .limbs = &[_]Limb{}, .len = 0, .positive = true } });
    defer ctx.vs.popTempRoot();
    const limbs = try vmgc.vmAllocManagedSlice(ctx, Limb, @max(a_len, 1));

    var r = Bi.Mutable{ .limbs = limbs, .len = 0, .positive = true };
    r.copy(a.object.bigint.toConst());
    r.negate();

    obj.* = .{ .bigint = .{ .limbs = limbs, .len = r.len, .positive = r.positive } };
    return .{ .object = obj };
}
