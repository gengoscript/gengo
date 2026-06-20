const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const vms = @import("../vm_state.zig");

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .math_abs => {
            const v = vms.vmTop(0);
            const n = try vms.valueAsNumber(v);
            vms.vmPopArgs(argc);
            // Preserve int-ness: strict arithmetic rejects int+float mixing,
            // so abs(int) must stay usable in int expressions.
            try vms.vmPush(if (v == .int) .{ .int = @intCast(@abs(v.int)) } else .{ .float = @abs(n) });
        },
        .math_acos, .math_asin => {
            const n = try vms.valueAsNumber(vms.vmTop(0));
            vms.vmPopArgs(argc);
            if (@abs(n) > 1.0) return error.RangeError;
            const fn_id: NativeFnId = @enumFromInt(nf.id);
            const result = switch (fn_id) { .math_acos => std.math.acos(n), .math_asin => std.math.asin(n), else => unreachable };
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_atan => {
            const n = try vms.valueAsNumber(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .float = std.math.atan(n) });
        },
        .math_atan2 => {
            const x = try vms.valueAsNumber(vms.vmTop(0));
            const y = try vms.valueAsNumber(vms.vmTop(1));
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .float = std.math.atan2(y, x) });
        },
        .math_clamp => {
            const max = try vms.valueAsNumber(vms.vmTop(0));
            const min = try vms.valueAsNumber(vms.vmTop(1));
            const v = try vms.valueAsNumber(vms.vmTop(2));
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .float = @min(@max(v, min), max) });
        },
        .math_cos, .math_sin, .math_tan, .math_cbrt, .math_ceil, .math_floor, .math_round, .math_trunc => {
            const n = try vms.valueAsNumber(vms.vmTop(0));
            vms.vmPopArgs(argc);
            const fn_id: NativeFnId = @enumFromInt(nf.id);
            try vms.vmPush(.{ .float = switch (fn_id) {
                .math_cos => @cos(n),
                .math_sin => @sin(n),
                .math_tan => std.math.tan(n),
                .math_cbrt => std.math.cbrt(n),
                .math_ceil => @ceil(n),
                .math_floor => @floor(n),
                .math_round => @round(n),
                .math_trunc => @trunc(n),
                else => unreachable,
            } });
        },
        .math_cosh, .math_sinh, .math_tanh, .math_exp, .math_exp2 => {
            const n = try vms.valueAsNumber(vms.vmTop(0));
            vms.vmPopArgs(argc);
            const fn_id: NativeFnId = @enumFromInt(nf.id);
            const result = switch (fn_id) {
                .math_cosh => std.math.cosh(n),
                .math_sinh => std.math.sinh(n),
                .math_tanh => std.math.tanh(n),
                .math_exp => std.math.exp(n),
                .math_exp2 => std.math.exp2(n),
                else => unreachable,
            };
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_hypot => {
            const q = try vms.valueAsNumber(vms.vmTop(0));
            const p = try vms.valueAsNumber(vms.vmTop(1));
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .float = std.math.hypot(p, q) });
        },
        .math_is_inf => {
            const sign_v = vms.vmTop(0);
            const n = try vms.valueAsNumber(vms.vmTop(1));
            vms.vmPopArgs(argc);
            const sign = try vms.valueAsInt(sign_v);
            const result = if (sign == 0) std.math.isInf(n) else if (sign > 0) std.math.isPositiveInf(n) else std.math.isNegativeInf(n);
            try vms.vmPush(.{ .boolean = result });
        },
        .math_is_nan => {
            const n = try vms.valueAsNumber(vms.vmTop(0));
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .boolean = std.math.isNan(n) });
        },
        .math_log, .math_log10, .math_log2 => {
            const n = try vms.valueAsNumber(vms.vmTop(0));
            vms.vmPopArgs(argc);
            if (n <= 0.0) return error.RangeError;
            const fn_id: NativeFnId = @enumFromInt(nf.id);
            const result = switch (fn_id) { .math_log => @log(n), .math_log10 => @log10(n), .math_log2 => @log2(n), else => unreachable };
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_max => {
            const bv = vms.vmTop(0);
            const av = vms.vmTop(1);
            const b = try vms.valueAsNumber(bv);
            const a = try vms.valueAsNumber(av);
            vms.vmPopArgs(argc);
            const all_int = av == .int and bv == .int;
            try vms.vmPush(if (all_int) .{ .int = @intFromFloat(@max(a, b)) } else .{ .float = @max(a, b) });
        },
        .math_min => {
            const bv = vms.vmTop(0);
            const av = vms.vmTop(1);
            const b = try vms.valueAsNumber(bv);
            const a = try vms.valueAsNumber(av);
            vms.vmPopArgs(argc);
            const all_int = av == .int and bv == .int;
            try vms.vmPush(if (all_int) .{ .int = @intFromFloat(@min(a, b)) } else .{ .float = @min(a, b) });
        },
        .math_mod => {
            const y = try vms.valueAsNumber(vms.vmTop(0));
            const x = try vms.valueAsNumber(vms.vmTop(1));
            vms.vmPopArgs(argc);
            if (y == 0.0) return error.DivisionByZero;
            try vms.vmPush(.{ .float = @mod(x, y) });
        },
        .math_nan => {
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .float = std.math.nan(f64) });
        },
        .math_pow => {
            const b = try vms.valueAsNumber(vms.vmTop(0));
            const a = try vms.valueAsNumber(vms.vmTop(1));
            vms.vmPopArgs(argc);
            const result = std.math.pow(f64, a, b);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_sign => {
            const v = vms.vmTop(0);
            const n = try vms.valueAsNumber(v);
            vms.vmPopArgs(argc);
            const sign: f64 = if (n > 0) 1.0 else if (n < 0) -1.0 else 0.0;
            try vms.vmPush(if (v == .int) .{ .int = @intFromFloat(sign) } else .{ .float = sign });
        },
        .math_sqrt => {
            const n = try vms.valueAsNumber(vms.vmTop(0));
            vms.vmPopArgs(argc);
            if (n < 0.0) return error.RangeError;
            const result = @sqrt(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        else => {},
    }
}
