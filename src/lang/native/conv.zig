const std = @import("std");
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const Value = @import("../value.zig").Value;
const host_abi = @import("../../runtime/host_abi.zig");
const host_abi_mod = @import("host_abi.zig");
const core_mod = @import("core.zig");
const vms = @import("../vm_state.zig");

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .conv_to_bool => {
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_BOOL) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmTop(0));
                    var out_wire = host_abi_mod.nullWire();
                    try host_abi_mod.nativeCallChecked(.conv_to_bool, arg_wire[0..], &out_wire);
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    try vms.vmPopArgs(argc);
                    try vms.vmPush(out);
                    return;
                }
            }
            const out = try core_mod.nativeConvToBool(vms.vmTop(0));
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .conv_to_float => {
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_FLOAT) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmTop(0));
                    var out_wire = host_abi_mod.nullWire();
                    try host_abi_mod.nativeCallChecked(.conv_to_float, arg_wire[0..], &out_wire);
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    try vms.vmPopArgs(argc);
                    try vms.vmPush(out);
                    return;
                }
            }
            const out = try core_mod.nativeConvToFloat(vms.vmTop(0));
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .conv_to_int => {
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_INT) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmTop(0));
                    var out_wire = host_abi_mod.nullWire();
                    try host_abi_mod.nativeCallChecked(.conv_to_int, arg_wire[0..], &out_wire);
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    try vms.vmPopArgs(argc);
                    try vms.vmPush(out);
                    return;
                }
            }
            const out = try core_mod.nativeConvToInt(vms.vmTop(0));
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .conv_to_string => {
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CONV_TO_STRING) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try host_abi_mod.wireFromValue(vms.vmTop(0));
                    var out_wire = host_abi_mod.nullWire();
                    try host_abi_mod.nativeCallChecked(.conv_to_string, arg_wire[0..], &out_wire);
                    const out = try host_abi_mod.valueFromWire(out_wire);
                    try vms.vmPopArgs(argc);
                    try vms.vmPush(out);
                    return;
                }
            }
            const out = try core_mod.nativeConvToString(vms.vmTop(0));
            try vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        else => {},
    }
}
