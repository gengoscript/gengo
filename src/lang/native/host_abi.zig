const std = @import("std");
const host_abi = @import("../../runtime/host_abi.zig");
const heap = @import("../../runtime/heap.zig");
const chunk = @import("../chunk.zig");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
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

pub fn wireFromValue(ctx: VMContext, v: Value) !host_abi.ValueWire {
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
                const wires = (ctx.hs.bump(host_abi.ValueWire, items.len) orelse return error.OutOfMemory)[0..items.len];
                for (items, 0..) |item, i| {
                    wires[i] = try wireFromValue(ctx, item);
                }
                return makeWire(.array, 0, @intCast(@intFromPtr(wires.ptr)), @intCast(items.len));
            },
            .map, .map_managed, .map_hashed => {
                const entries = try vms.asMapSlice(o);
                const wires = (ctx.hs.bump(host_abi.ValueWire, entries.len * 2) orelse return error.OutOfMemory)[0 .. entries.len * 2];
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = try wireFromValue(ctx, entry.key);
                    wires[i * 2 + 1] = try wireFromValue(ctx, entry.value);
                }
                return makeWire(.map, 0, @intCast(@intFromPtr(wires.ptr)), @intCast(entries.len));
            },
            .variant_value => |vv| {
                const wires = (ctx.hs.bump(host_abi.ValueWire, 4) orelse return error.OutOfMemory)[0..4];
                wires[0] = try wireFromValue(ctx, .{ .string = try ctx.cs.internStr("tag") });
                wires[1] = try wireFromValue(ctx, .{ .string = try ctx.cs.internStr(vv.tag) });
                wires[2] = try wireFromValue(ctx, .{ .string = try ctx.cs.internStr("value") });
                wires[3] = try wireFromValue(ctx, vv.payload);
                return makeWire(.map, 0, @intCast(@intFromPtr(wires.ptr)), 2);
            },
            else => return error.UnsupportedHostValueType,
        },
        .inline_variant => |iv| {
            const ordinal = vmod.inlineVariantOrdinal(iv);
            const tag = vmod.objectAtIdx(iv.typ_idx).variant_type.arms[ordinal].name;
            const wires = (ctx.hs.bump(host_abi.ValueWire, 4) orelse return error.OutOfMemory)[0..4];
            wires[0] = try wireFromValue(ctx, .{ .string = try ctx.cs.internStr("tag") });
            wires[1] = try wireFromValue(ctx, .{ .string = try ctx.cs.internStr(tag) });
            wires[2] = try wireFromValue(ctx, .{ .string = try ctx.cs.internStr("value") });
            wires[3] = try wireFromValue(ctx, vmod.inlineVariantPayload(iv));
            return makeWire(.map, 0, @intCast(@intFromPtr(wires.ptr)), 2);
        },
    };
}

pub fn valueFromWire(ctx: VMContext, w: host_abi.ValueWire) !Value {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    return switch (tag) {
        .null => .null,
        .boolean => .{ .boolean = w.payload != 0 },
        .number => if ((w.flags & host_abi.FLAG_DECIMAL) != 0) {
            return Value{ .decimal = @bitCast(w.payload) };
        } else if ((w.flags & host_abi.FLAG_RUNE) != 0) {
            return Value{ .rune = @intCast(w.payload) };
        } else if ((w.flags & host_abi.FLAG_INTEGER) != 0) {
            return Value{ .int = @bitCast(w.payload) };
        } else {
            return Value{ .float = @bitCast(w.payload) };
        },
        .@"error" => {
            if (w.len == 0) return Value{ .error_value = try ctx.cs.internStr("") };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..@as(usize, @intCast(w.len))];
            const copy = try vmgc.vmAllocManagedBytes(ctx, w.len);
            @memcpy(copy[0..w.len], data);
            return .{ .error_value = try ctx.cs.internStr(copy[0..w.len]) };
        },
        .string => {
            if (w.len == 0) return Value{ .string = try ctx.cs.internStr("") };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..@as(usize, @intCast(w.len))];
            return vmgc.makeDynString(ctx, data);
        },
        .array => {
            const count = w.len;
            const elem_wires = @as([*]const host_abi.ValueWire, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..count];
            const arr_obj = try vmgc.allocTempRooted(ctx, .{ .array_managed = &[_]Value{} });
            defer ctx.vs.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(ctx, Value, count);
            arr_obj.* = .{ .array_managed = items[0..0] }; // publish immediately
            for (elem_wires, 0..) |ew, i| {
                items[i] = try valueFromWire(ctx, ew);
                arr_obj.* = .{ .array_managed = items[0 .. i + 1] }; // grow visible
            }
            return .{ .object = arr_obj };
        },
        .map => {
            const count = w.len;
            const pair_wires = @as([*]const host_abi.ValueWire, @ptrFromInt(@as(usize, @intCast(w.payload))))[0 .. count * 2];
            const map_obj = try vmgc.allocTempRooted(ctx, .{ .map_managed = &[_]MapEntry{} });
            defer ctx.vs.popTempRoot();
            const entries = try vmgc.vmAllocManagedSlice(ctx, MapEntry, count);
            map_obj.* = .{ .map_managed = entries[0..0] }; // publish immediately
            for (0..count) |i| {
                const k = try valueFromWire(ctx, pair_wires[i * 2]);
                try ctx.vs.pushTempRoot(k);
                entries[i].key = k;
                entries[i].value = try valueFromWire(ctx, pair_wires[i * 2 + 1]);
                ctx.vs.popTempRoot();
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

// std natives are never host-overridable — see dev-docs/roadmap.md and
// CHANGELOG.md: a host used to be able to swap the implementation of
// std.core.len/append/bytelen and std.conv.to_int/to_float/to_bool/to_string
// (io.println had its own inline equivalent), which meant the same call
// could silently behave differently depending on the embedding host. These
// helpers now always run the embedded implementation; host modules
// (`import("host:x")`, callHostModule) are unaffected — a different,
// explicitly host-owned namespace with no bearing on std semantics.
pub fn callNativeVariadic(ctx: vms.VMContext, argc: u8, start: usize, comptime nativeFn: anytype) !void {
    const result = try @call(.auto, nativeFn, .{ ctx, start, argc });
    ctx.vs.vmPopArgs(argc);
    try ctx.vs.vmPush(result);
}

pub fn callNative1(ctx: vms.VMContext, argc: u8, comptime nativeFn: anytype) !void {
    const out = try @call(.auto, nativeFn, .{ ctx, ctx.vs.vmTop(0) });
    ctx.vs.vmPopArgs(argc);
    try ctx.vs.vmPush(out);
}

pub fn ensureHostReady(ctx: VMContext) !void {
    if (ctx.vs.policy.native_backend != .host) return;
    if (ctx.vs.host_checked) return;

    var out = nullWire();

    var empty: [0]host_abi.ValueWire = .{};
    const st_ver = host_abi.nativeCall(.abi_version, empty[0..], &out);
    switch (st_ver) {
        .ok => {},
        .unsupported => {
            ctx.vs.host_checked = true;
            return;
        },
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
    const version = try wireNumberToU64(out);
    if (version != host_abi.ABI_VERSION) return error.HostAbiVersionMismatch;
    ctx.vs.host_checked = true;
}
