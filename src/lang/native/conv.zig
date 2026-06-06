const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const Value = @import("../value.zig").Value;
const host_abi = @import("../../runtime/host_abi.zig");
const host_abi_mod = @import("host_abi.zig");
const core_mod = @import("core.zig");
const vms = @import("../vm_state.zig");

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .conv_to_bool => {

            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_BOOL) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.conv_to_bool, arg_wire[0..], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try core_mod.nativeConvToBool(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_float => {

            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_FLOAT) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.conv_to_float, arg_wire[0..], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try core_mod.nativeConvToFloat(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_int => {

            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_INT) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.conv_to_int, arg_wire[0..], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try core_mod.nativeConvToInt(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_string => {

            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_STRING) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.conv_to_string, arg_wire[0..], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try core_mod.nativeConvToString(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        else => {},
    }
}
