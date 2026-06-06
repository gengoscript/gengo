const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const vms = @import("../vm_state.zig");

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .math_abs => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @abs(n) });
        },
        .math_acos => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.acos(n) });
        },
        .math_asin => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.asin(n) });
        },
        .math_atan => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.atan(n) });
        },
        .math_atan2 => {

            if (argc != nf.arity) return error.ArityMismatch;
            const x = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const y = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.atan2(y, x) });
        },
        .math_cbrt => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.cbrt(n) });
        },
        .math_ceil => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @ceil(n) });
        },
        .math_clamp => {

            if (argc != nf.arity) return error.ArityMismatch;
            const max = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const min = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            const v = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 3]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @min(@max(v, min), max) });
        },
        .math_cos => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @cos(n) });
        },
        .math_cosh => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.cosh(n) });
        },
        .math_exp => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.exp(n) });
        },
        .math_exp2 => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.exp2(n) });
        },
        .math_floor => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @floor(n) });
        },
        .math_hypot => {

            if (argc != nf.arity) return error.ArityMismatch;
            const q = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const p = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.hypot(p, q) });
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
            try vms.vmPush(.{ .number = @log(n) });
        },
        .math_log10 => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @log10(n) });
        },
        .math_log2 => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @log2(n) });
        },
        .math_max => {

            if (argc != nf.arity) return error.ArityMismatch;
            const b = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const a = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @max(a, b) });
        },
        .math_min => {

            if (argc != nf.arity) return error.ArityMismatch;
            const b = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const a = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @min(a, b) });
        },
        .math_mod => {

            if (argc != nf.arity) return error.ArityMismatch;
            const y = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const x = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @mod(x, y) });
        },
        .math_nan => {

            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.nan(f64) });
        },
        .math_pow => {

            if (argc != nf.arity) return error.ArityMismatch;
            const b = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const a = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 2]);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.pow(f64, a, b) });
        },
        .math_round => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @round(n) });
        },
        .math_sign => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            const sign: f64 = if (n > 0) 1.0 else if (n < 0) -1.0 else 0.0;
            try vms.vmPush(.{ .number = sign });
        },
        .math_sin => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @sin(n) });
        },
        .math_sinh => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.sinh(n) });
        },
        .math_sqrt => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @sqrt(n) });
        },
        .math_tan => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.tan(n) });
        },
        .math_tanh => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = std.math.tanh(n) });
        },
        .math_trunc => {

            if (argc != nf.arity) return error.ArityMismatch;
            const n = try vms.valueAsNumber(vms.vmState().stack[vms.vmState().stack_top - 1]);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @trunc(n) });
        },
        else => {},
    }
}
