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

            const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return error.CapabilityError;
            defer _ = std.posix.system.close(fd);

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(std.heap.page_allocator);
            var temp: [4096]u8 = undefined;
            while (true) {
                const n = std.posix.read(fd, &temp) catch return error.CapabilityError;
                if (n == 0) break;
                buf.appendSlice(std.heap.page_allocator, temp[0..n]) catch return error.CapabilityError;
            }
            const contents = buf.toOwnedSlice(std.heap.page_allocator) catch return error.CapabilityError;
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

            const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
                error.FileNotFound => {
                    try vms.vmPush(.{ .boolean = false });
                    return;
                },
                else => return error.CapabilityError,
            };
            _ = std.posix.system.close(fd);
            try vms.vmPush(.{ .boolean = true });
        },
        else => unreachable,
    }
}
