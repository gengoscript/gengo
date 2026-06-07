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
        .cap_net_get => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const url = switch (arg0) {
                .string => |s| s,
                else => return error.TypeError,
            };
            if (comptime builtin.os.tag == .wasi) {
                return error.CapabilityNotAvailable;
            }
            _ = try vms.vmPop();
            const allocator = heap.allocator();
            var client = std.http.Client{ .allocator = allocator };
            defer client.deinit();
            const uri = std.Uri.parse(url) catch return error.ValueError;
            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();
            const res = client.fetch(.{
                .method = .GET,
                .location = .{ .uri = uri },
                .response_storage = .{ .dynamic = &buf },
            }) catch return error.CapabilityError;
            if (res.status != .ok) return error.CapabilityError;
            const body = buf.items;
            const out = try vmgc.vmAllocString(body.len);
            @memcpy(out.chars[0..body.len], body);
            try vms.vmPush(.{ .string = out.chars[0..body.len] });
        },
        else => unreachable,
    }
}
