const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const Value = @import("../value.zig").Value;
const host_abi_mod = @import("host_abi.zig");
const core_mod = @import("core.zig");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .conv_to_bool => try host_abi_mod.callNative1(ctx, argc, core_mod.nativeConvToBool),
        .conv_to_float => try host_abi_mod.callNative1(ctx, argc, core_mod.nativeConvToFloat),
        .conv_to_int => try host_abi_mod.callNative1(ctx, argc, core_mod.nativeConvToInt),
        .conv_to_string => try host_abi_mod.callNative1(ctx, argc, core_mod.nativeConvToString),
        else => {},
    }
}
