const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const vms = @import("../vm_state.zig");

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .math_abs => {

            if (argc != nf.arity) return error.ArityMismatch;
            const v = vms.vmState().stack[vms.vmState().stack_top - 1];
            const n = try vms.valueAsNumber(v);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            // Preserve int-ness: strict arithmetic rejects int+float mixing,
            // so abs(int) must stay usable in int expressions.
            try vms.vmPush(if (v == .int) .{ .int = @abs(n) } else .{ .float = @abs(n) });
        },
        .math_acos => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            if (@abs(n) > 1.0) return error.RangeError;
            const result = std.math.acos(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_asin => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            if (@abs(n) > 1.0) return error.RangeError;
            const result = std.math.asin(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_atan => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = std.math.atan(n) });
        },
        .math_atan2 => {

            if (argc != nf.arity) return error.ArityMismatch;
            const x = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const y = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = std.math.atan2(y, x) });
        },
        .math_cbrt => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = std.math.cbrt(n) });
        },
        .math_ceil => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = @ceil(n) });
        },
        .math_clamp => {

            if (argc != nf.arity) return error.ArityMismatch;
            const max = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const min = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            const v = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 3]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = @min(@max(v, min), max) });
        },
        .math_cos => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = @cos(n) });
        },
        .math_cosh => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            const result = std.math.cosh(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_exp => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            const result = std.math.exp(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_exp2 => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            const result = std.math.exp2(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_floor => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = @floor(n) });
        },
        .math_hypot => {

            if (argc != nf.arity) return error.ArityMismatch;
            const q = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const p = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = std.math.hypot(p, q) });
        },
        .math_is_inf => {

            if (argc != nf.arity) return error.ArityMismatch;
            const sign_v = vms.vmState().stack[vms.vmState().stack_top - 1];
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            const sign = try vms.valueAsInt(sign_v);
            const result = if (sign == 0) std.math.isInf(n) else if (sign > 0) std.math.isPositiveInf(n) else std.math.isNegativeInf(n);
            try vms.vmPush(.{ .boolean = result });
        },
        .math_is_nan => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = std.math.isNan(n) });
        },
        .math_log => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            if (n <= 0.0) return error.RangeError;
            const result = @log(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_log10 => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            if (n <= 0.0) return error.RangeError;
            const result = @log10(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_log2 => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            if (n <= 0.0) return error.RangeError;
            const result = @log2(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_max => {

            if (argc != nf.arity) return error.ArityMismatch;
            const bv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const av = vms.vmState().stack[vms.vmState().stack_top - 2];
            const b = try vms.valueAsNumber(bv);
            const a = try vms.valueAsNumber(av);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            const all_int = av == .int and bv == .int;
            try vms.vmPush(if (all_int) .{ .int = @max(a, b) } else .{ .float = @max(a, b) });
        },
        .math_min => {

            if (argc != nf.arity) return error.ArityMismatch;
            const bv = vms.vmState().stack[vms.vmState().stack_top - 1];
            const av = vms.vmState().stack[vms.vmState().stack_top - 2];
            const b = try vms.valueAsNumber(bv);
            const a = try vms.valueAsNumber(av);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            const all_int = av == .int and bv == .int;
            try vms.vmPush(if (all_int) .{ .int = @min(a, b) } else .{ .float = @min(a, b) });
        },
        .math_mod => {

            if (argc != nf.arity) return error.ArityMismatch;
            const y = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const x = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            if (y == 0.0) return error.DivisionByZero;
            try vms.vmPush(.{ .float = @mod(x, y) });
        },
        .math_nan => {

            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(.{ .float = std.math.nan(f64) });
        },
        .math_pow => {

            if (argc != nf.arity) return error.ArityMismatch;
            const b = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const a = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            const result = std.math.pow(f64, a, b);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_round => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = @round(n) });
        },
        .math_sign => {

            if (argc != nf.arity) return error.ArityMismatch;
            const v = vms.vmState().stack[vms.vmState().stack_top - 1];
            const n = try vms.valueAsNumber(v);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            const sign: f64 = if (n > 0) 1.0 else if (n < 0) -1.0 else 0.0;
            try vms.vmPush(if (v == .int) .{ .int = sign } else .{ .float = sign });
        },
        .math_sin => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = @sin(n) });
        },
        .math_sinh => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            const result = std.math.sinh(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_sqrt => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            if (n < 0.0) return error.RangeError;
            const result = @sqrt(n);
            if (!std.math.isFinite(result)) return error.RangeError;
            try vms.vmPush(.{ .float = result });
        },
        .math_tan => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = std.math.tan(n) });
        },
        .math_tanh => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = std.math.tanh(n) });
        },
        .math_trunc => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .float = @trunc(n) });
        },
        else => {},
    }
}
