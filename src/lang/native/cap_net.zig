const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_net_get => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            _ = arg0;
            _ = try vms.vmPop();
            // TODO: implement using std.Io (Zig 0.16.0) — see issue #60
            return error.CapabilityNotImplemented;
        },
        else => unreachable,
    }
}
