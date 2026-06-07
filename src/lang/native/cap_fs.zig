const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const heap = @import("../../runtime/heap.zig");
const Value = @import("../value.zig").Value;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_fs_read => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const path = switch (arg0) {
                .string => |s| s,
                else => return error.TypeError,
            };
            if (comptime builtin.os.tag == .wasi) {
                return error.CapabilityNotAvailable;
            }
            _ = try vms.vmPop();
            const allocator = heap.allocator();
            const contents = std.fs.cwd().readFileAlloc(allocator, path, 1 << 20) catch return error.CapabilityError;
            defer allocator.free(contents);
            const out = try vmgc.vmAllocString(contents.len);
            @memcpy(out.chars[0..contents.len], contents);
            try vms.vmPush(.{ .string = out.chars[0..contents.len] });
        },
        .cap_fs_exists => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const path = switch (arg0) {
                .string => |s| s,
                else => return error.TypeError,
            };
            if (comptime builtin.os.tag == .wasi) {
                return error.CapabilityNotAvailable;
            }
            _ = try vms.vmPop();
            const exists = std.fs.cwd().access(path, .{}) catch false;
            try vms.vmPush(.{ .boolean = exists });
        },
        else => unreachable,
    }
}
