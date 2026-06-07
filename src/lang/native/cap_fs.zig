const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
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
            _ = try vms.vmPop();

            if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;

            const io_ctx = std.Io.Threaded.global_single_threaded.io();
            const contents = std.Io.Dir.cwd().readFileAlloc(io_ctx, path, std.heap.page_allocator, .limited(1 << 20)) catch return error.CapabilityError;
            defer std.heap.page_allocator.free(contents);

            const out = try vmgc.makeDynString(contents);
            try vms.vmPush(out);
        },
        .cap_fs_exists => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const path = switch (arg0) {
                .string => |s| s,
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;

            const io_ctx = std.Io.Threaded.global_single_threaded.io();
            std.Io.Dir.cwd().access(io_ctx, path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try vms.vmPush(.{ .boolean = false });
                    return;
                },
                else => return error.CapabilityError,
            };
            try vms.vmPush(.{ .boolean = true });
        },
        else => unreachable,
    }
}
