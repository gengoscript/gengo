const std = @import("std");
const host_abi = @import("../../runtime/host_abi.zig");
const heap = @import("../../runtime/heap.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;

pub fn wireFromValue(v: Value) !host_abi.ValueWire {
    return switch (v) {
        .null => .{
            .tag = @intFromEnum(host_abi.WireTag.null),
            .flags = 0,
            .reserved = 0,
            .payload = 0,
            .len = 0,
            .reserved2 = 0,
        },
        .boolean => |b| .{
            .tag = @intFromEnum(host_abi.WireTag.boolean),
            .flags = 0,
            .reserved = 0,
            .payload = if (b) 1 else 0,
            .len = 0,
            .reserved2 = 0,
        },
        .int => |n| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = 0,
            .reserved = 0,
            .payload = @bitCast(n),
            .len = 0,
            .reserved2 = 0,
        },
        .float => |n| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = 0,
            .reserved = 0,
            .payload = @bitCast(n),
            .len = 0,
            .reserved2 = 0,
        },
        .rune => |r| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = host_abi.FLAG_RUNE,
            .reserved = 0,
            .payload = @as(u64, r),
            .len = 0,
            .reserved2 = 0,
        },
        .decimal => |d| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = host_abi.FLAG_DECIMAL,
            .reserved = 0,
            .payload = @as(u64, @bitCast(d)),
            .len = 0,
            .reserved2 = 0,
        },
        .string => |s| .{
            .tag = @intFromEnum(host_abi.WireTag.string),
            .flags = 0,
            .reserved = 0,
            .payload = @intFromPtr(s.ptr),
            .len = @intCast(s.len),
            .reserved2 = 0,
        },
        .error_value => |msg| .{
            .tag = @intFromEnum(host_abi.WireTag.@"error"),
            .flags = 0,
            .reserved = 0,
            .payload = @intFromPtr(msg.ptr),
            .len = @intCast(msg.len),
            .reserved2 = 0,
        },
        .object => |o| switch (o.*) {
            .dyn_string => .{
                .tag = @intFromEnum(host_abi.WireTag.string),
                .flags = 0,
                .reserved = 0,
                .payload = @intFromPtr(o.dyn_string.ptr),
                .len = @intCast(o.dyn_string.len),
                .reserved2 = 0,
            },
            .array, .array_managed => {
                const items = try vms.asArraySlice(o);
                const wires = (heap.bump(host_abi.ValueWire, items.len) orelse return error.OutOfMemory)[0..items.len];
                for (items, 0..) |item, i| {
                    wires[i] = try wireFromValue(item);
                }
                return .{
                    .tag = @intFromEnum(host_abi.WireTag.array),
                    .flags = 0,
                    .reserved = 0,
                    .payload = @intFromPtr(wires.ptr),
                    .len = @intCast(items.len),
                    .reserved2 = 0,
                };
            },
            .map, .map_managed, .map_hashed => {
                const entries = try vms.asMapSlice(o);
                const wires = (heap.bump(host_abi.ValueWire, entries.len * 2) orelse return error.OutOfMemory)[0 .. entries.len * 2];
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = try wireFromValue(entry.key);
                    wires[i * 2 + 1] = try wireFromValue(entry.value);
                }
                return .{
                    .tag = @intFromEnum(host_abi.WireTag.map),
                    .flags = 0,
                    .reserved = 0,
                    .payload = @intFromPtr(wires.ptr),
                    .len = @intCast(entries.len),
                    .reserved2 = 0,
                };
            },
            .variant_value => |vv| {
                const wires = (heap.bump(host_abi.ValueWire, 4) orelse return error.OutOfMemory)[0..4];
                wires[0] = try wireFromValue(.{ .string = "tag" });
                wires[1] = try wireFromValue(.{ .string = vv.tag });
                wires[2] = try wireFromValue(.{ .string = "value" });
                wires[3] = try wireFromValue(vv.payload);
                return .{
                    .tag = @intFromEnum(host_abi.WireTag.map),
                    .flags = 0,
                    .reserved = 0,
                    .payload = @intFromPtr(wires.ptr),
                    .len = 2,
                    .reserved2 = 0,
                };
            },
            else => return error.UnsupportedHostValueType,
        },
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
        } else {
            return Value{ .float = @bitCast(w.payload) };
        },
        .@"error" => {
            if (w.len == 0) return Value{ .error_value = "" };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..@as(usize, @intCast(w.len))];
            const copy = try vmgc.vmAllocManagedBytes(w.len);
            @memcpy(copy[0..w.len], data);
            return .{ .error_value = copy[0..w.len] };
        },
        .string => {
            if (w.len == 0) return Value{ .string = "" };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..@as(usize, @intCast(w.len))];
            return vmgc.makeDynString(data);
        },
        .array => {
            const count = w.len;
            const elem_wires = @as([*]const host_abi.ValueWire, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..count];
            const arr_obj = try vmgc.vmAllocObject();
            arr_obj.* = .{ .array_managed = &[_]Value{} }; // safe placeholder
            try vms.pushTempRoot(.{ .object = arr_obj });
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
            const map_obj = try vmgc.vmAllocObject();
            map_obj.* = .{ .map_managed = &[_]MapEntry{} }; // safe placeholder
            try vms.pushTempRoot(.{ .object = map_obj });
            defer vms.popTempRoot();
            const entries = try vmgc.vmAllocManagedSlice(MapEntry, count);
            map_obj.* = .{ .map_managed = entries[0..0] }; // publish immediately
            for (0..count) |i| {
                entries[i] = .{
                    .key = try valueFromWire(pair_wires[i * 2]),
                    .value = try valueFromWire(pair_wires[i * 2 + 1]),
                };
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

pub fn ensureHostReady() !void {
    if (vms.vmState().policy.native_backend != .host) return;
    if (vms.vmState().host_checked) return;

    var out: host_abi.ValueWire = .{
        .tag = @intFromEnum(host_abi.WireTag.null),
        .flags = 0,
        .reserved = 0,
        .payload = 0,
        .len = 0,
        .reserved2 = 0,
    };

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

    const st_caps = host_abi.nativeCall(.host_caps, empty[0..], &out);
    switch (st_caps) {
        .ok => {},
        .unsupported => return error.HostNativeUnsupported,
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
    vms.vmState().host_caps = try wireNumberToU64(out);
    vms.vmState().host_checked = true;
}
