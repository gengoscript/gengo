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
            const url = switch (arg0) {
                .string => |s| s,
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;

            const io_ctx = std.Io.Threaded.global_single_threaded.io();
            var client = std.http.Client{
                .allocator = std.heap.page_allocator,
                .io = io_ctx,
            };
            defer client.deinit();

            var writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer writer.deinit();

            const res = client.fetch(.{
                .location = .{ .url = url },
                .response_writer = &writer.writer,
            }) catch return error.CapabilityError;

            if (res.status.class() != .success) return error.CapabilityError;

            const body = writer.written();
            const out = try vmgc.makeDynString(body);
            try vms.vmPush(out);
        },
        else => unreachable,
    }
}
