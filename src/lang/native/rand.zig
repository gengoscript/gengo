const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

var g_prng: std.Random.DefaultPrng = undefined;
var g_prng_ready: bool = false;

pub fn randResetState() void {
    g_prng_ready = false;
}

pub fn randRng() std.Random {
    if (!g_prng_ready) {
        var seed: u64 = undefined;
        const seed_bytes = std.mem.asBytes(&seed);
        if (comptime builtin.os.tag == .wasi) {
            _ = std.os.wasi.random_get(seed_bytes.ptr, seed_bytes.len);
        } else if (comptime builtin.os.tag == .linux) {
            _ = std.os.linux.getrandom(seed_bytes.ptr, seed_bytes.len, 0);
        } else {
            seed = @intFromPtr(&g_prng) ^ 0xdeadbeef_cafebabe;
        }
        g_prng = std.Random.DefaultPrng.init(seed);
        g_prng_ready = true;
    }
    return g_prng.random();
}

pub fn nativeRandFloat() Value {
    return .{ .float = randRng().float(f64) };
}

pub fn nativeRandIntn(n_val: Value) !Value {
    const n = try vms.valueAsInt(n_val);
    if (n <= 0) return error.RangeError;
    return .{ .int = randRng().intRangeLessThan(i64, 0, n) };
}

pub fn nativeRandBetween(lo_val: Value, hi_val: Value) !Value {
    const lo = try vms.valueAsInt(lo_val);
    const hi = try vms.valueAsInt(hi_val);
    if (lo > hi) return error.RangeError;
    return .{ .int = randRng().intRangeAtMost(i64, lo, hi) };
}

pub fn nativeRandSeed(n_val: Value) !void {
    const n = try vms.valueAsInt(n_val);
    const seed: u64 = @bitCast(n);
    g_prng = std.Random.DefaultPrng.init(seed);
    g_prng_ready = true;
}

pub fn nativeRandChoice(arr_obj: *Object) !Value {
    if (!vms.isArrayObject(arr_obj)) return error.TypeError;
    const items = try vms.asArraySlice(arr_obj);
    if (items.len == 0) return error.RangeError;
    const idx = randRng().intRangeLessThan(usize, 0, items.len);
    return items[idx];
}

pub fn nativeRandPerm(n_v: Value) !Value {
    const n = try vms.valueAsInt(n_v);
    if (n < 0) return error.RangeError;
    const usize_n = @as(usize, @intCast(n));
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(Value, usize_n);
    for (items, 0..) |*item, i| item.* = .{ .int = @intCast(i) };
    var j: usize = usize_n;
    while (j > 1) {
        j -= 1;
        const k = randRng().intRangeLessThan(usize, 0, j + 1);
        const tmp = items[j];
        items[j] = items[k];
        items[k] = tmp;
    }
    obj.* = .{ .array_managed = items[0..usize_n] };
    return .{ .object = obj };
}

pub fn nativeRandNormFloat() Value {
    var u1_val: f64 = undefined;
    var u2_val: f64 = undefined;
    var rsq: f64 = 2.0;
    while (rsq >= 1.0 or rsq == 0.0) {
        u1_val = randRng().float(f64) * 2.0 - 1.0;
        u2_val = randRng().float(f64) * 2.0 - 1.0;
        rsq = u1_val * u1_val + u2_val * u2_val;
    }
    const fac = std.math.sqrt(-2.0 * @log(rsq) / rsq);
    return .{ .float = u1_val * fac };
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .rand_between => {
            const out = try nativeRandBetween(vms.vmTop(1), vms.vmTop(0));
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .rand_choice => {
            const arr_val = vms.unboxNamed(vms.vmTop(0));
            if (arr_val != .object) return error.TypeError;
            const out = try nativeRandChoice(arr_val.object);
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .rand_float => {
            try vms.vmPopArgs(argc);
            try vms.vmPush(nativeRandFloat());
        },
        .rand_intn => {
            const out = try nativeRandIntn(vms.vmTop(0));
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .rand_norm_float => {
            try vms.vmPopArgs(argc);
            try vms.vmPush(nativeRandNormFloat());
        },
        .rand_perm => {
            const out = try nativeRandPerm(vms.vmTop(0));
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .rand_seed => {
            try nativeRandSeed(vms.vmTop(0));
            try vms.vmPopArgs(argc);
            try vms.vmPush(.null);
        },
        else => {},
    }
}
