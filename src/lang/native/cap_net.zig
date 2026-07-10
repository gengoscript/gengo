const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const net_state = @import("net_state.zig");
const globals = @import("../globals.zig");
const MapEntry = @import("../value.zig").MapEntry;
const chunk = @import("../chunk.zig");

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
            if (n < 0 or n > std.math.maxInt(u32)) return error.TypeError;
            break :blk @intCast(n);
        },
        .float => |n| blk: {
            if (n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.TypeError;
            break :blk @as(u32, @intFromFloat(n));
        },
        else => return error.TypeError,
    };
}

fn extractUsize(arg: Value) !usize {
    return switch (arg) {
        .int => |n| blk: {
            if (n < 0 or n > std.math.maxInt(usize)) return error.TypeError;
            break :blk @as(usize, @intCast(n));
        },
        .float => |n| blk: {
            if (n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.TypeError;
            break :blk @as(usize, @intFromFloat(n));
        },
        else => return error.TypeError,
    };
}

fn extractI64(arg: Value) !i64 {
    return switch (arg) {
        .int => |n| n,
        .float => |n| blk: {
            if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
            break :blk @as(i64, @intFromFloat(n));
        },
        else => return error.TypeError,
    };
}

fn pushCatchableNetError(ctx: VMContext, err: anyerror) !void {
    const msg: []const u8 = if (err == error.DeadlineExceeded) "timeout" else net_state.lastNetErr();
    try ctx.vs.vmPush(.{ .error_value = try ctx.cs.internStr(msg) });
}

fn pushPageString(ctx: VMContext, bytes: []u8) !void {
    defer std.heap.page_allocator.free(bytes);
    const out = try vmgc.makeDynString(ctx, bytes);
    try ctx.vs.vmPush(out);
}

fn ioContext() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_net_dial => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const network = vms.asStringValue(arg0) catch return error.TypeError;
            const address = vms.asStringValue(arg1) catch return error.TypeError;
            _ = try ctx.vs.vmPop();

            if (!net_state.checkDialPolicy(address)) {
                try ctx.vs.vmPush(.{ .error_value = try ctx.cs.internStr("net.dial: refused by policy") });
                return;
            }

            const id = net_state.netDial(network, address) catch {
                try ctx.vs.vmPush(.{ .error_value = try ctx.cs.internStr(net_state.lastNetErr()) });
                return;
            };

            const conn_type_val = ctx.gs.get("@cap_type:net.Conn") orelse return error.CapabilityError;
            const conn_type_obj = switch (conn_type_val) {
                .object => |o| o,
                else => return error.CapabilityError,
            };

            const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 1);
            const inst_obj = try vmgc.vmAllocObject(ctx);
            inst_obj.* = .{ .struct_instance = .{ .typ = conn_type_obj, .fields = inst_fields } };
            try ctx.vs.pushTempRoot(.{ .object = inst_obj });
            defer ctx.vs.popTempRoot();
            inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("_handle") }, .value = .{ .int = @as(i64, id) } };
            try ctx.vs.vmPush(.{ .object = inst_obj });
        },
        .cap_net_read => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            const max_bytes = try extractUsize(arg1);
            _ = try ctx.vs.vmPop();

            // Host/WASM path: use the page-allocator round-trip.
            if (net_state.hasHandlers() or comptime (builtin.os.tag == .wasi or builtin.os.tag == .windows)) {
                const buf = net_state.netRead(id, max_bytes) catch |err| {
                    try pushCatchableNetError(ctx, err);
                    return;
                };
                try pushPageString(ctx, buf);
                return;
            }

            // Native POSIX fast path: fill from the connection's internal read
            // buffer (which batches socket reads at 4 KiB) into a local Zig
            // stack buffer, then copy into the GC heap via makeDynString.
            // Using a local buffer keeps netReadInto free of any GC interaction.
            if (max_bytes == 0) {
                try ctx.vs.vmPush(try vmgc.makeDynString(ctx, ""));
                return;
            }
            var local_buf: [4096]u8 = undefined;
            const read_dest = local_buf[0..@min(max_bytes, local_buf.len)];
            const n = net_state.netReadInto(id, read_dest) catch |err| {
                try pushCatchableNetError(ctx, err);
                return;
            };
            try ctx.vs.vmPush(try vmgc.makeDynString(ctx, read_dest[0..n]));
        },
        .cap_net_write => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            const data = vms.asStringValue(arg1) catch return error.TypeError;
            _ = try ctx.vs.vmPop();

            const n = net_state.netWrite(id, data) catch |err| {
                try pushCatchableNetError(ctx, err);
                return;
            };
            try ctx.vs.vmPush(.{ .int = @intCast(n) });
        },
        .cap_net_close => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            _ = try ctx.vs.vmPop();

            net_state.netClose(id) catch return error.CapabilityError;
            try ctx.vs.vmPush(.null);
        },
        .cap_net_local_addr => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            _ = try ctx.vs.vmPop();

            const addr = net_state.netLocalAddr(id) catch return error.CapabilityError;
            try pushPageString(ctx, addr);
        },
        .cap_net_remote_addr => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            _ = try ctx.vs.vmPop();

            const addr = net_state.netRemoteAddr(id) catch return error.CapabilityError;
            try pushPageString(ctx, addr);
        },
        .cap_net_set_deadline => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            const ms = try extractI64(arg1);
            _ = try ctx.vs.vmPop();
            net_state.netSetDeadline(id, ms) catch return error.CapabilityError;
            try ctx.vs.vmPush(.null);
        },
        .cap_net_set_read_deadline => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            const ms = try extractI64(arg1);
            _ = try ctx.vs.vmPop();
            net_state.netSetReadDeadline(id, ms) catch return error.CapabilityError;
            try ctx.vs.vmPush(.null);
        },
        .cap_net_set_write_deadline => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            const ms = try extractI64(arg1);
            _ = try ctx.vs.vmPop();

            net_state.netSetWriteDeadline(id, ms) catch return error.CapabilityError;
            try ctx.vs.vmPush(.null);
        },
        else => unreachable,
    }
}
