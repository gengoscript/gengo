const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const net_state = @import("net_state.zig");
const globals = @import("../globals.zig");
const MapEntry = @import("../value.zig").MapEntry;

fn extractHandle(arg: Value) !u32 {
    const obj = switch (arg) {
        .object => |o| o,
        else => return error.TypeError,
    };
    const fields = switch (obj.*) {
        .struct_instance => |inst| inst.fields,
        else => return error.TypeError,
    };
    const handle_val = fields[0].value;
    return switch (handle_val) {
        .int => |n| blk: {
            if (n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.TypeError;
            break :blk @as(u32, @intFromFloat(n));
        },
        .float => |n| blk: {
            if (n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.TypeError;
            break :blk @as(u32, @intFromFloat(n));
        },
        else => return error.TypeError,
    };
}

fn ioContext() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_net_dial => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const network = vms.asStringValue(arg0) catch return error.TypeError;
            const address = vms.asStringValue(arg1) catch return error.TypeError;
            _ = try vms.vmPop();

            const id = net_state.netDial(network, address) catch return error.CapabilityError;

            const conn_type_val = globals.get("@cap_type:net.Conn") orelse return error.CapabilityError;
            const conn_type_obj = switch (conn_type_val) {
                .object => |o| o,
                else => return error.CapabilityError,
            };

            const inst_obj = try vmgc.vmAllocObject();
            try vms.pushTempRoot(.{ .object = inst_obj });
            defer vms.popTempRoot();
            const inst_fields = try vmgc.vmAllocManagedSlice(MapEntry, 1);
            inst_obj.* = .{ .struct_instance = .{ .typ = conn_type_obj, .fields = inst_fields } };
            inst_fields[0] = .{ .key = .{ .string = "_handle" }, .value = .{ .int = @floatFromInt(id) } };
            try vms.vmPush(.{ .object = inst_obj });
        },
        .cap_net_read => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const id = try extractHandle(arg0);
            const max_bytes = switch (arg1) {
                .int => |n| blk: {
                    if (n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.TypeError;
                    break :blk @as(usize, @intFromFloat(n));
                },
                .float => |n| blk: {
                    if (n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.TypeError;
                    break :blk @as(usize, @intFromFloat(n));
                },
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
            const id = try extractHandle(arg0);
            const data = vms.asStringValue(arg1) catch return error.TypeError;
            _ = try vms.vmPop();

            const n = net_state.netWrite(id, data) catch return error.CapabilityError;
            try vms.vmPush(.{ .int = @floatFromInt(n) });
        },
        .cap_net_close => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const id = try extractHandle(arg0);
            _ = try vms.vmPop();

            net_state.netClose(id) catch return error.CapabilityError;
            try vms.vmPush(.null);
        },
        .cap_net_local_addr => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const id = try extractHandle(arg0);
            _ = try vms.vmPop();

            const addr = net_state.netLocalAddr(id) catch return error.CapabilityError;
            const out = try vmgc.makeDynString(addr);
            try vms.vmPush(out);
        },
        .cap_net_remote_addr => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try vms.vmPop();
            const id = try extractHandle(arg0);
            _ = try vms.vmPop();

            const addr = net_state.netRemoteAddr(id) catch return error.CapabilityError;
            const out = try vmgc.makeDynString(addr);
            try vms.vmPush(out);
        },
        .cap_net_set_deadline => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try vms.vmPop();
            const arg0 = try vms.vmPop();
            const id = try extractHandle(arg0);
            const ms = switch (arg1) {
                .int => |n| blk: {
                    if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                    break :blk @as(i64, @intFromFloat(n));
                },
                .float => |n| blk: {
                    if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                    break :blk @as(i64, @intFromFloat(n));
                },
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
            const id = try extractHandle(arg0);
            const ms = switch (arg1) {
                .int => |n| blk: {
                    if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                    break :blk @as(i64, @intFromFloat(n));
                },
                .float => |n| blk: {
                    if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                    break :blk @as(i64, @intFromFloat(n));
                },
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
            const id = try extractHandle(arg0);
            const ms = switch (arg1) {
                .int => |n| blk: {
                    if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                    break :blk @as(i64, @intFromFloat(n));
                },
                .float => |n| blk: {
                    if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                    break :blk @as(i64, @intFromFloat(n));
                },
                else => return error.TypeError,
            };
            _ = try vms.vmPop();

            net_state.netSetWriteDeadline(id, ms) catch return error.CapabilityError;
            try vms.vmPush(.null);
        },
        else => unreachable,
    }
}
