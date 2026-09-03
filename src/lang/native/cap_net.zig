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
const Object = @import("../value.zig").Object;
const chunk = @import("../chunk.zig");
const common = @import("../common.zig");

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
            // !isFinite catches NaN too, not just checking bounds: NaN
            // compares false against every ordinary comparison (IEEE 754),
            // so a bare `n < 0 or n > MAX` guard silently passes NaN
            // through to @intFromFloat below, which is safety-checked UB
            // for a non-finite input — the same hazard floatToIntSafe
            // (vm.zig) exists specifically to close, reimplemented here
            // without that check.
            if (!std.math.isFinite(n) or n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.TypeError;
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
            if (!std.math.isFinite(n) or n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.TypeError;
            break :blk @as(usize, @intFromFloat(n));
        },
        else => return error.TypeError,
    };
}

fn extractI64(arg: Value) !i64 {
    return switch (arg) {
        .int => |n| n,
        .float => |n| common.safeI64FromFloat(n) catch return error.TypeError,
        else => return error.TypeError,
    };
}

fn pushCatchableNetError(ctx: VMContext, err: anyerror) !void {
    const msg: []const u8 = if (err == error.DeadlineExceeded) "timeout" else net_state.lastNetErr();
    try ctx.vs.vmPush(.{ .error_value = try ctx.cs.internStr(msg) });
}

// listen/accept return [ok, err] pairs (matching the design note's own
// examples and http.get/post/fetch's existing convention), unlike dial's
// single "Conn or error" value — different from the rest of this file's
// functions, but that's what the calling shape `l, err := net.listen(...)`
// in the language actually needs.
fn pushOkPair(ctx: VMContext, ok: Value) !void {
    try ctx.vs.pushTempRoot(ok);
    defer ctx.vs.popTempRoot();
    const arr = try vmgc.allocTempRootedManagedValueArray(ctx, 2);
    defer ctx.vs.popTempRoot();
    arr.set(0, ok);
    arr.set(1, .null);
    try ctx.vs.vmPush(.{ .object = arr.obj });
}

fn pushErrPairMsg(ctx: VMContext, msg: []const u8) !void {
    const interned = try ctx.cs.internStr(msg);
    const arr = try vmgc.allocTempRootedManagedValueArray(ctx, 2);
    defer ctx.vs.popTempRoot();
    arr.set(0, .null);
    arr.set(1, .{ .error_value = interned });
    try ctx.vs.vmPush(.{ .object = arr.obj });
}

fn pushErrPairForNetError(ctx: VMContext, err: anyerror) !void {
    const msg: []const u8 = if (err == error.DeadlineExceeded) "timeout" else net_state.lastNetErr();
    try pushErrPairMsg(ctx, msg);
}

fn pushPageString(ctx: VMContext, bytes: []u8) !void {
    defer std.heap.page_allocator.free(bytes);
    const out = try vmgc.makeDynString(ctx, bytes);
    try ctx.vs.vmPush(out);
}

fn ioContext() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// cap_net_dial and cap_net_dial_tls differ only in which scope-check
// message they raise and which net_state function actually connects — kept
// as one implementation so a future fix to the shared arg-extraction,
// policy-check, or connection-object-building steps can't land on one and
// miss the other, the same divergence class that caused this session's
// .mod/.int_div and cap_net/cap_ffi NaN-guard bugs.
fn dialImpl(ctx: VMContext, argc: u8, use_tls: bool) !void {
    if (argc != 2) return error.ArityMismatch;
    const arg1 = try ctx.vs.vmPop();
    const arg0 = try ctx.vs.vmPop();
    const network = vms.asStringValue(arg0) catch return error.TypeError;
    const address = vms.asStringValue(arg1) catch return error.TypeError;
    _ = try ctx.vs.vmPop();

    if (!ctx.vs.net_scopes.dial) {
        try ctx.vs.vmPush(.{ .error_value = try ctx.cs.internStr(if (use_tls) "net.dial_tls: dial scope not granted (--cap net=dial)" else "net.dial: dial scope not granted (--cap net=dial)") });
        return;
    }

    if (!net_state.checkDialPolicy(address)) {
        try ctx.vs.vmPush(.{ .error_value = try ctx.cs.internStr(if (use_tls) "net.dial_tls: refused by policy" else "net.dial: refused by policy") });
        return;
    }

    const id = (if (use_tls) net_state.netDialTls(network, address) else net_state.netDial(network, address)) catch {
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
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_net_dial => try dialImpl(ctx, argc, false),
        .cap_net_dial_tls => try dialImpl(ctx, argc, true),
        .cap_net_listen => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const network = vms.asStringValue(arg0) catch return error.TypeError;
            const address = vms.asStringValue(arg1) catch return error.TypeError;
            _ = try ctx.vs.vmPop();

            if (!ctx.vs.net_scopes.listen) {
                try pushErrPairMsg(ctx, "net.listen: listen scope not granted (--cap net=listen)");
                return;
            }

            if (!net_state.checkListenPolicy(address)) {
                try pushErrPairMsg(ctx, "net.listen: refused by policy");
                return;
            }

            const id = net_state.netListen(network, address) catch {
                try pushErrPairMsg(ctx, net_state.lastNetErr());
                return;
            };

            const listener_type_val = ctx.gs.get("@cap_type:net.Listener") orelse return error.CapabilityError;
            const listener_type_obj = switch (listener_type_val) {
                .object => |o| o,
                else => return error.CapabilityError,
            };

            const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 1);
            const inst_obj = try vmgc.vmAllocObject(ctx);
            inst_obj.* = .{ .struct_instance = .{ .typ = listener_type_obj, .fields = inst_fields } };
            try ctx.vs.pushTempRoot(.{ .object = inst_obj });
            inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("_handle") }, .value = .{ .int = @as(i64, id) } };
            const listener_val: Value = .{ .object = inst_obj };
            try pushOkPair(ctx, listener_val);
            ctx.vs.popTempRoot();
        },
        .cap_net_listener_accept => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            _ = try ctx.vs.vmPop();

            const conn_id = net_state.netListenerAccept(id) catch |err| {
                try pushErrPairForNetError(ctx, err);
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
            inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("_handle") }, .value = .{ .int = @as(i64, conn_id) } };
            const conn_val: Value = .{ .object = inst_obj };
            try pushOkPair(ctx, conn_val);
            ctx.vs.popTempRoot();
        },
        .cap_net_listener_close => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            _ = try ctx.vs.vmPop();

            net_state.netListenerClose(id) catch return error.CapabilityError;
            try ctx.vs.vmPush(.null);
        },
        .cap_net_listener_local_addr => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            _ = try ctx.vs.vmPop();

            const addr = net_state.netListenerLocalAddr(id) catch return error.CapabilityError;
            try pushPageString(ctx, addr);
        },
        .cap_net_listener_set_accept_deadline => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const id = try extractHandle(arg0);
            const ms = try extractI64(arg1);
            _ = try ctx.vs.vmPop();
            net_state.netListenerSetAcceptDeadline(id, ms) catch return error.CapabilityError;
            try ctx.vs.vmPush(.null);
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

const testing = std.testing;

// Coverage-audit 2026-09: extractHandle's `.float` arm was never exercised
// — every dispatch() call site above always passes a handle struct whose
// `_handle` field was constructed as `.{ .int = ... }` (see dialImpl/listen
// above). extractHandle takes the whole struct-instance `Value` (not the
// handle scalar directly) and reads `fields[0].value`, so a fake struct
// instance is needed to drive the field through as a float. `.typ` is never
// dereferenced by extractHandle, so a throwaway struct_type object is
// enough to satisfy the pointer.
test "extractHandle accepts an in-range float, rejects NaN/negative/overflow/non-numeric" {
    var dummy_type: Object = .{ .struct_type = .{ .name = "T", .qualified_name = "T", .fields = &.{} } };

    var f1 = [_]MapEntry{.{ .key = .null, .value = .{ .float = 42.0 } }};
    var o1: Object = .{ .struct_instance = .{ .typ = &dummy_type, .fields = &f1 } };
    try testing.expectEqual(@as(u32, 42), try extractHandle(.{ .object = &o1 }));

    var f2 = [_]MapEntry{.{ .key = .null, .value = .{ .float = std.math.nan(f64) } }};
    var o2: Object = .{ .struct_instance = .{ .typ = &dummy_type, .fields = &f2 } };
    try testing.expectError(error.TypeError, extractHandle(.{ .object = &o2 }));

    var f3 = [_]MapEntry{.{ .key = .null, .value = .{ .float = -1.0 } }};
    var o3: Object = .{ .struct_instance = .{ .typ = &dummy_type, .fields = &f3 } };
    try testing.expectError(error.TypeError, extractHandle(.{ .object = &o3 }));

    var f4 = [_]MapEntry{.{ .key = .null, .value = .{ .float = 1e20 } }};
    var o4: Object = .{ .struct_instance = .{ .typ = &dummy_type, .fields = &f4 } };
    try testing.expectError(error.TypeError, extractHandle(.{ .object = &o4 }));

    var f5 = [_]MapEntry{.{ .key = .null, .value = .{ .boolean = true } }};
    var o5: Object = .{ .struct_instance = .{ .typ = &dummy_type, .fields = &f5 } };
    try testing.expectError(error.TypeError, extractHandle(.{ .object = &o5 }));

    try testing.expectError(error.TypeError, extractHandle(.{ .boolean = true }));
}

test "extractUsize accepts an in-range float, rejects NaN/negative/overflow/non-numeric" {
    try testing.expectEqual(@as(usize, 4096), try extractUsize(.{ .float = 4096.0 }));
    try testing.expectError(error.TypeError, extractUsize(.{ .float = std.math.nan(f64) }));
    try testing.expectError(error.TypeError, extractUsize(.{ .float = -1.0 }));
    try testing.expectError(error.TypeError, extractUsize(.{ .float = 1e30 }));
    try testing.expectError(error.TypeError, extractUsize(.{ .boolean = true }));
}

test "extractI64 truncates a float via safeI64FromFloat, rejects NaN and non-numeric" {
    try testing.expectEqual(@as(i64, 3), try extractI64(.{ .float = 3.9 }));
    try testing.expectError(error.TypeError, extractI64(.{ .float = std.math.nan(f64) }));
    try testing.expectError(error.TypeError, extractI64(.{ .string = &.{ .bytes = "nope" } }));
}
