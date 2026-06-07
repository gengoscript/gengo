const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const net_state = @import("net_state.zig");

fn ioContext() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

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

            const io_ctx = ioContext();
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
        .cap_net_dial => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const network = switch (arg0) {
                .string => |s| s,
                else => return error.TypeError,
            };
            const address = switch (arg1) {
                .string => |s| s,
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            const id = net_state.netDial(network, address) catch return error.CapabilityError;
            try vms.vmPush(.{ .number = @floatFromInt(id) });
        },
        .cap_net_read => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const id = switch (arg0) {
                .number => |n| @as(u32, @intFromFloat(n)),
                else => return error.TypeError,
            };
            const max_bytes = switch (arg1) {
                .number => |n| @as(usize, @intFromFloat(n)),
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            const buf = net_state.netRead(id, max_bytes) catch return error.CapabilityError;
            defer std.heap.page_allocator.free(buf);
            const out = try vmgc.makeDynString(buf);
            try vms.vmPush(out);
        },
        .cap_net_write => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const id = switch (arg0) {
                .number => |n| @as(u32, @intFromFloat(n)),
                else => return error.TypeError,
            };
            const data = switch (arg1) {
                .string => |s| s,
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            const n = net_state.netWrite(id, data) catch return error.CapabilityError;
            try vms.vmPush(.{ .number = @floatFromInt(n) });
        },
        .cap_net_close => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const id = switch (arg0) {
                .number => |n| @as(u32, @intFromFloat(n)),
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            net_state.netClose(id) catch return error.CapabilityError;
            try vms.vmPush(.null);
        },
        .cap_net_local_addr => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const id = switch (arg0) {
                .number => |n| @as(u32, @intFromFloat(n)),
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            const addr = net_state.netLocalAddr(id) catch return error.CapabilityError;
            const out = try vmgc.makeDynString(addr);
            try vms.vmPush(out);
        },
        .cap_net_remote_addr => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const id = switch (arg0) {
                .number => |n| @as(u32, @intFromFloat(n)),
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            const addr = net_state.netRemoteAddr(id) catch return error.CapabilityError;
            const out = try vmgc.makeDynString(addr);
            try vms.vmPush(out);
        },
        .cap_net_set_deadline => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const id = switch (arg0) {
                .number => |n| @as(u32, @intFromFloat(n)),
                else => return error.TypeError,
            };
            const ms = switch (arg1) {
                .number => |n| @as(i64, @intFromFloat(n)),
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            net_state.netSetDeadline(id, ms) catch return error.CapabilityError;
            try vms.vmPush(.null);
        },
        .cap_net_set_read_deadline => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const id = switch (arg0) {
                .number => |n| @as(u32, @intFromFloat(n)),
                else => return error.TypeError,
            };
            const ms = switch (arg1) {
                .number => |n| @as(i64, @intFromFloat(n)),
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            net_state.netSetReadDeadline(id, ms) catch return error.CapabilityError;
            try vms.vmPush(.null);
        },
        .cap_net_set_write_deadline => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const id = switch (arg0) {
                .number => |n| @as(u32, @intFromFloat(n)),
                else => return error.TypeError,
            };
            const ms = switch (arg1) {
                .number => |n| @as(i64, @intFromFloat(n)),
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            net_state.netSetWriteDeadline(id, ms) catch return error.CapabilityError;
            try vms.vmPush(.null);
        },
        else => unreachable,
    }
}
