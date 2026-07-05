const std = @import("std");
const host_abi = @import("../../runtime/host_abi.zig");
const heap = @import("../../runtime/heap.zig");
const chunk = @import("../chunk.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const vmod = @import("../value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const MaxNativeArgs = @import("native_ids.zig").MaxNativeArgs;

fn makeWire(tag: host_abi.WireTag, flags: u8, payload: u64, len: u32) host_abi.ValueWire {
    return .{ .tag = @intFromEnum(tag), .flags = flags, .reserved = 0, .payload = payload, .len = len, .reserved2 = 0 };
}

pub fn nullWire() host_abi.ValueWire {
    return makeWire(.null, 0, 0, 0);
}

pub fn checkCallStatus(st: host_abi.CallStatus) !void {
    switch (st) {
        .ok => {},
        .unsupported => return error.HostNativeUnsupported,
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
}

pub fn nativeCallChecked(id: host_abi.HostCall, args: []const host_abi.ValueWire, out: *host_abi.ValueWire) !void {
    try checkCallStatus(host_abi.nativeCall(id, args, out));
}

pub fn nativeCallRawChecked(id: u16, args: []const host_abi.ValueWire, out: *host_abi.ValueWire) !void {
    try checkCallStatus(host_abi.nativeCallRaw(id, args, out));
}

pub fn wireFromValue(v: Value) !host_abi.ValueWire {
    return switch (v) {
        .null => nullWire(),
        .boolean => |b| makeWire(.boolean, 0, if (b) 1 else 0, 0),
        .int => |n| makeWire(.number, host_abi.FLAG_INTEGER, @bitCast(n), 0),
        .float => |n| makeWire(.number, 0, @bitCast(n), 0),
        .rune => |r| makeWire(.number, host_abi.FLAG_RUNE, @as(u64, r), 0),
        .decimal => |d| makeWire(.number, host_abi.FLAG_DECIMAL, @as(u64, @bitCast(d)), 0),
        .string => |s| makeWire(.string, 0, @intCast(@intFromPtr(s.bytes.ptr)), @intCast(s.bytes.len)),
        .error_value => |msg| makeWire(.@"error", 0, @intCast(@intFromPtr(msg.bytes.ptr)), @intCast(msg.bytes.len)),
        .object => |o| switch (o.*) {
            .dyn_string => makeWire(.string, 0, @intCast(@intFromPtr(o.dyn_string.ptr)), @intCast(o.dyn_string.len)),
            .string_view => makeWire(.string, 0, @intCast(@intFromPtr(o.string_view.bytes.ptr)), @intCast(o.string_view.bytes.len)),
            .array, .array_managed, .array_view, .array_capacity => {
                const items = try vms.asArraySlice(o);
                const wires = (heap.bump(host_abi.ValueWire, items.len) orelse return error.OutOfMemory)[0..items.len];
                for (items, 0..) |item, i| {
                    wires[i] = try wireFromValue(item);
                }
                return makeWire(.array, 0, @intCast(@intFromPtr(wires.ptr)), @intCast(items.len));
            },
            .map, .map_managed, .map_hashed => {
                const entries = try vms.asMapSlice(o);
                const wires = (heap.bump(host_abi.ValueWire, entries.len * 2) orelse return error.OutOfMemory)[0 .. entries.len * 2];
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = try wireFromValue(entry.key);
                    wires[i * 2 + 1] = try wireFromValue(entry.value);
                }
                return makeWire(.map, 0, @intCast(@intFromPtr(wires.ptr)), @intCast(entries.len));
            },
            .variant_value => |vv| {
                const wires = (heap.bump(host_abi.ValueWire, 4) orelse return error.OutOfMemory)[0..4];
                wires[0] = try wireFromValue(.{ .string = try chunk.internStr("tag") });
                wires[1] = try wireFromValue(.{ .string = try chunk.internStr(vv.tag) });
                wires[2] = try wireFromValue(.{ .string = try chunk.internStr("value") });
                wires[3] = try wireFromValue(vv.payload);
                return makeWire(.map, 0, @intCast(@intFromPtr(wires.ptr)), 2);
            },
            else => return error.UnsupportedHostValueType,
        },
        .named_scalar => |ns| wireFromValue(vmod.namedScalarInner(ns)),
    };
}

pub fn valueFromWire(w: host_abi.ValueWire) !Value {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    return switch (tag) {
        .null => .null,
        .boolean => .{ .boolean = w.payload != 0 },
        .number => if ((w.flags & host_abi.FLAG_DECIMAL) != 0) {
            return Value{ .decimal = @bitCast(w.payload) };
        } else if ((w.flags & host_abi.FLAG_RUNE) != 0) {
            return Value{ .rune = @intCast(w.payload) };
        } else if ((w.flags & host_abi.FLAG_INTEGER) !=  0) {
            return Value{ .int = @bitCast(w.payload) };
        } else {
            return Value{ .float = @bitCast(w.payload) };
        },
        .@"error" => {
            if (w.len == 0) return Value{ .error_value = try chunk.internStr("") };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..@as(usize, @intCast(w.len))];
            const copy = try vmgc.vmAllocManagedBytes(w.len);
            @memcpy(copy[0..w.len], data);
            return .{ .error_value = try chunk.internStr(copy[0..w.len]) };
        },
        .string => {
            if (w.len == 0) return Value{ .string = try chunk.internStr("") };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..@as(usize, @intCast(w.len))];
            return vmgc.makeDynString(data);
        },
        .array => {
            const count = w.len;
            const elem_wires = @as([*]const host_abi.ValueWire, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..count];
            const arr_obj = try vmgc.allocTempRooted(.{ .array_managed = &[_]Value{} });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(Value, count);
            arr_obj.* = .{ .array_managed = items[0..0] }; // publish immediately
            for (elem_wires, 0..) |ew, i| {
                items[i] = try valueFromWire(ew);
                arr_obj.* = .{ .array_managed = items[0 .. i + 1] }; // grow visible
            }
            return .{ .object = arr_obj };
        },
        .map => {
            const count = w.len;
            const pair_wires = @as([*]const host_abi.ValueWire, @ptrFromInt(@as(usize, @intCast(w.payload))))[0 .. count * 2];
            const map_obj = try vmgc.allocTempRooted(.{ .map_managed = &[_]MapEntry{} });
            defer vms.popTempRoot();
            const entries = try vmgc.vmAllocManagedSlice(MapEntry, count);
            map_obj.* = .{ .map_managed = entries[0..0] }; // publish immediately
            for (0..count) |i| {
                const k = try valueFromWire(pair_wires[i * 2]);
                try vms.pushTempRoot(k);
                entries[i].key = k;
                entries[i].value = try valueFromWire(pair_wires[i * 2 + 1]);
                vms.popTempRoot();
                map_obj.* = .{ .map_managed = entries[0 .. i + 1] }; // grow visible
            }
            return .{ .object = map_obj };
        },
    };
}

pub fn wireNumberToU64(w: host_abi.ValueWire) !u64 {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    if (tag != .number) return error.HostNativeBadReturnType;
    const n: f64 = @bitCast(w.payload);
    if (n < 0) return error.HostNativeBadReturnValue;
    const tr = @trunc(n);
    if (tr != n) return error.HostNativeBadReturnValue;
    if (tr > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.HostNativeBadReturnValue;
    return @intFromFloat(tr);
}

pub fn dispatchHostCallVariadic(comptime cap: u64, comptime call: host_abi.HostCall, argc: u8, start: usize, comptime nativeFn: anytype) !void {
    if (vms.vmState().policy.native_backend == .host) {
        try ensureHostReady();
        if ((vms.vmState().host_caps & cap) != 0) {
            if (argc > MaxNativeArgs) return error.ArityMismatch;
            var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
            for (args_wire[0..argc], vms.vmState().stack[start .. start + argc]) |*w, v| w.* = try wireFromValue(v);
            var out = nullWire();
            try nativeCallChecked(call, args_wire[0..argc], &out);
            const result = try valueFromWire(out);
            vms.vmPopArgs(argc);
            try vms.vmPush(result);
            return;
        }
    }
    const result = try @call(.auto, nativeFn, .{start, argc});
    vms.vmPopArgs(argc);
    try vms.vmPush(result);
}

pub fn dispatchHostCall1(comptime cap: u64, comptime call: host_abi.HostCall, argc: u8, comptime nativeFn: anytype) !void {
    if (vms.vmState().policy.native_backend == .host) {
        try ensureHostReady();
        if ((vms.vmState().host_caps & cap) != 0) {
            var arg_wire: [1]host_abi.ValueWire = undefined;
            arg_wire[0] = try wireFromValue(vms.vmTop(0));
            var out_wire = nullWire();
            try nativeCallChecked(call, arg_wire[0..], &out_wire);
            const out = try valueFromWire(out_wire);
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
            return;
        }
    }
    const out = try @call(.auto, nativeFn, .{vms.vmTop(0)});
    vms.vmPopArgs(argc);
    try vms.vmPush(out);
}

pub fn ensureHostReady() !void {
    if (vms.vmState().policy.native_backend != .host) return;
    if (vms.vmState().host_checked) return;

    var out = nullWire();

    var empty: [0]host_abi.ValueWire = .{};
    const st_ver = host_abi.nativeCall(.abi_version, empty[0..], &out);
    switch (st_ver) {
        .ok => {},
        .unsupported => {
            vms.vmState().host_caps = 0;
            vms.vmState().host_checked = true;
            return;
        },
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
    const version = try wireNumberToU64(out);
    if (version != host_abi.ABI_VERSION) return error.HostAbiVersionMismatch;

    try nativeCallChecked(.host_caps, empty[0..], &out);
    vms.vmState().host_caps = try wireNumberToU64(out);
    vms.vmState().host_checked = true;
}
