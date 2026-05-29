const std = @import("std");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const host_abi = @import("../runtime/host_abi.zig");
const io = @import("../runtime/io.zig");
const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const vmstr = @import("vm_string.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;
const NativeFuncObj = @import("value.zig").NativeFuncObj;

const NativeFnId = enum(u8) {
    io_println = 1,
    io_printf = 15,
    core_len = 2,
    core_append = 3,
    core_error = 4,
    core_is_error = 5,
    core_gc = 6,
    core_gc_live_objects = 7,
    core_gc_stats = 8,
    core_bytelen = 9,
    conv_to_int = 10,
    conv_to_float = 11,
    conv_to_bool = 12,
    conv_to_string = 13,
    core_gc_stats_ext = 14,
};
const MaxNativeArgs = 255;

fn makeNative(id: NativeFnId, arity: u8) !Value {
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .native_function = .{ .id = @intFromEnum(id), .arity = arity } };
    return .{ .object = obj };
}

pub fn buildStdModule() !*Object {
    if (vms.vmState().std_module) |m| return m;

    const io_items = heap.bump(MapEntry, 2) orelse return error.OutOfMemory;
    io_items[0] = .{
        .key = .{ .string = "println" },
        .value = try makeNative(.io_println, 255),
    };
    io_items[1] = .{
        .key = .{ .string = "printf" },
        .value = try makeNative(.io_printf, 255),
    };
    const io_obj = try vmgc.vmAllocObject();
    io_obj.* = .{ .map = io_items[0..2] };

    const core_items = heap.bump(MapEntry, 9) orelse return error.OutOfMemory;
    core_items[0] = .{
        .key = .{ .string = "len" },
        .value = try makeNative(.core_len, 1),
    };
    core_items[1] = .{
        .key = .{ .string = "append" },
        .value = try makeNative(.core_append, 255),
    };
    core_items[2] = .{
        .key = .{ .string = "error" },
        .value = try makeNative(.core_error, 1),
    };
    core_items[3] = .{
        .key = .{ .string = "is_error" },
        .value = try makeNative(.core_is_error, 1),
    };
    core_items[4] = .{
        .key = .{ .string = "gc" },
        .value = try makeNative(.core_gc, 0),
    };
    core_items[5] = .{
        .key = .{ .string = "gc_live_objects" },
        .value = try makeNative(.core_gc_live_objects, 0),
    };
    core_items[6] = .{
        .key = .{ .string = "gc_stats" },
        .value = try makeNative(.core_gc_stats, 0),
    };
    core_items[7] = .{
        .key = .{ .string = "bytelen" },
        .value = try makeNative(.core_bytelen, 1),
    };
    core_items[8] = .{
        .key = .{ .string = "gc_stats_ext" },
        .value = try makeNative(.core_gc_stats_ext, 0),
    };
    const core_obj = try vmgc.vmAllocObject();
    core_obj.* = .{ .map = core_items[0..9] };

    const conv_items = heap.bump(MapEntry, 4) orelse return error.OutOfMemory;
    conv_items[0] = .{
        .key = .{ .string = "to_int" },
        .value = try makeNative(.conv_to_int, 1),
    };
    conv_items[1] = .{
        .key = .{ .string = "to_float" },
        .value = try makeNative(.conv_to_float, 1),
    };
    conv_items[2] = .{
        .key = .{ .string = "to_bool" },
        .value = try makeNative(.conv_to_bool, 1),
    };
    conv_items[3] = .{
        .key = .{ .string = "to_string" },
        .value = try makeNative(.conv_to_string, 1),
    };
    const conv_obj = try vmgc.vmAllocObject();
    conv_obj.* = .{ .map = conv_items[0..4] };

    const std_items = heap.bump(MapEntry, 3) orelse return error.OutOfMemory;
    std_items[0] = .{
        .key = .{ .string = "io" },
        .value = .{ .object = io_obj },
    };
    std_items[1] = .{
        .key = .{ .string = "core" },
        .value = .{ .object = core_obj },
    };
    std_items[2] = .{
        .key = .{ .string = "conv" },
        .value = .{ .object = conv_obj },
    };

    const std_obj = try vmgc.vmAllocObject();
    std_obj.* = .{ .map = std_items[0..3] };
    vms.vmState().std_module = std_obj;
    return std_obj;
}

fn nativeLen(v: Value) !Value {
    const n: usize = switch (v) {
        .string => |s| try vmstr.utf8RuneCountCached(s),
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| try vmstr.utf8RuneCountCached(s),
            .array, .array_managed => vms.asArraySlice(obj).len,
            .map, .map_managed, .map_hashed => vms.asMapSlice(obj).len,
            .struct_instance => |s| s.fields.len,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .number = @floatFromInt(n) };
}

fn nativeByteLen(v: Value) !Value {
    const n: usize = switch (v) {
        .string => |s| s.len,
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| s.len,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .number = @floatFromInt(n) };
}

fn nativePrintf(start: usize, argc: u8) !void {
    if (argc < 1) return error.ArityMismatch;
    const fmt_v = vms.vmState().stack[start];
    const fmt = try vms.asStringValue(fmt_v);
    var ai: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            io.write(fmt[i .. i + 1]);
            i += 1;
            continue;
        }
        if (i + 1 >= fmt.len) return error.TypeError;
        const spec = fmt[i + 1];
        if (spec == '%') {
            io.write("%");
            i += 2;
            continue;
        }
        if (ai >= @as(usize, argc)) return error.ArityMismatch;
        const arg = vms.vmState().stack[start + ai];
        ai += 1;
        switch (spec) {
            'v' => io.printValue(arg),
            's' => io.write(try vms.asStringValue(arg)),
            'd' => io.writeInt(try vms.valueAsInt(arg)),
            'f' => io.writeF64(try vms.valueAsNumber(arg)),
            't' => {
                if (arg != .boolean) return error.TypeError;
                io.write(if (arg.boolean) "true" else "false");
            },
            else => return error.TypeError,
        }
        i += 2;
    }
    if (ai != @as(usize, argc)) return error.ArityMismatch;
}

fn nativeAppend(start: usize, argc: u8) !Value {
    if (argc < 1) return error.ArityMismatch;
    const first = vms.vmState().stack[start];
    if (first != .object or !vms.isArrayObject(first.object)) return error.TypeError;
    const base = vms.asArraySlice(first.object);
    const extra: usize = argc - 1;
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const out = try vmgc.vmAllocManagedSlice(Value, base.len + extra);
    @memcpy(out[0..base.len], base);
    var i: usize = 0;
    while (i < extra) : (i += 1) {
        out[base.len + i] = vms.vmState().stack[start + 1 + i];
    }
    obj.* = .{ .array_managed = out[0 .. base.len + extra] };
    return .{ .object = obj };
}

fn nativeGcStats() !Value {
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const items = heap.bump(MapEntry, 3) orelse return error.OutOfMemory;
    items[0] = .{
        .key = .{ .string = "heap_used_bytes" },
        .value = .{ .number = @floatFromInt(heap.usedBytes()) },
    };
    items[1] = .{
        .key = .{ .string = "heap_size_bytes" },
        .value = .{ .number = @floatFromInt(heap.HeapSize) },
    };
    items[2] = .{
        .key = .{ .string = "live_objects" },
        .value = .{ .number = @floatFromInt(heap.liveObjectCount()) },
    };
    obj.* = .{ .map = items[0..3] };
    return .{ .object = obj };
}

fn nativeGcStatsExt() !Value {
    const obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const items = heap.bump(MapEntry, 8) orelse return error.OutOfMemory;
    items[0] = .{
        .key = .{ .string = "heap_used_bytes" },
        .value = .{ .number = @floatFromInt(heap.usedBytes()) },
    };
    items[1] = .{
        .key = .{ .string = "heap_size_bytes" },
        .value = .{ .number = @floatFromInt(heap.HeapSize) },
    };
    items[2] = .{
        .key = .{ .string = "live_objects" },
        .value = .{ .number = @floatFromInt(heap.liveObjectCount()) },
    };
    items[3] = .{
        .key = .{ .string = "gc_runs" },
        .value = .{ .number = @floatFromInt(vms.vmState().gc_runs) },
    };
    items[4] = .{
        .key = .{ .string = "gc_time_ns" },
        .value = .{ .number = @floatFromInt(vms.vmState().gc_time_ns) },
    };
    items[5] = .{
        .key = .{ .string = "alloc_object_calls" },
        .value = .{ .number = @floatFromInt(vms.vmState().alloc_object_calls) },
    };
    items[6] = .{
        .key = .{ .string = "alloc_managed_slice_calls" },
        .value = .{ .number = @floatFromInt(vms.vmState().alloc_managed_slice_calls) },
    };
    items[7] = .{
        .key = .{ .string = "alloc_managed_bytes_calls" },
        .value = .{ .number = @floatFromInt(vms.vmState().alloc_managed_bytes_calls) },
    };
    obj.* = .{ .map = items[0..8] };
    return .{ .object = obj };
}

pub fn nativeConvToInt(v: Value) !Value {
    switch (v) {
        .number => |n| {
            const tr = @trunc(n);
            return .{ .number = tr };
        },
        .rune => |r| return .{ .number = @floatFromInt(r) },
        .boolean => |b| return .{ .number = if (b) 1 else 0 },
        .string => |s| {
            const n = common.parseFloat(s) orelse return error.TypeError;
            const tr = @trunc(n);
            return .{ .number = tr };
        },
        .object => |o| {
            if (o.* == .dyn_string) {
                const n = common.parseFloat(o.dyn_string) orelse return error.TypeError;
                const tr = @trunc(n);
                return .{ .number = tr };
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    }
}

pub fn nativeConvToFloat(v: Value) !Value {
    switch (v) {
        .number => |n| return .{ .number = n },
        .rune => |r| return .{ .number = @floatFromInt(r) },
        .boolean => |b| return .{ .number = if (b) 1 else 0 },
        .string => |s| {
            const n = common.parseFloat(s) orelse return error.TypeError;
            return .{ .number = n };
        },
        .object => |o| {
            if (o.* == .dyn_string) {
                const n = common.parseFloat(o.dyn_string) orelse return error.TypeError;
                return .{ .number = n };
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    }
}

pub fn nativeConvToBool(v: Value) !Value {
    switch (v) {
        .boolean => |b| return .{ .boolean = b },
        .number => |n| return .{ .boolean = n != 0.0 },
        .rune => |r| return .{ .boolean = r != 0 },
        .string => |s| return .{ .boolean = s.len != 0 },
        .error_value => |e| return .{ .boolean = e.len != 0 },
        .null => return .{ .boolean = false },
        .object => return .{ .boolean = true },
    }
}

pub fn nativeConvToString(v: Value) !Value {
    switch (v) {
        .string => |s| return vmgc.makeDynString(s),
        .object => |o| {
            if (o.* == .dyn_string) return vmgc.makeDynString(o.dyn_string);
            return error.TypeError;
        },
        .boolean => |b| return vmgc.makeDynString(if (b) "true" else "false"),
        .number => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .rune => |r| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(r, buf[0..]) catch return error.TypeError;
            return vmgc.makeDynString(buf[0..n]);
        },
        .null => return vmgc.makeDynString("null"),
        .error_value => |e| return vmgc.makeDynString(e),
    }
}

// ── Host ABI bridge ───────────────────────────────────────────────────────────

fn wireFromValue(v: Value) !host_abi.ValueWire {
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
        .number => |n| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = 0,
            .reserved = 0,
            .payload = @bitCast(n),
            .len = 0,
            .reserved2 = 0,
        },
        .rune => |r| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = 0,
            .reserved = 0,
            .payload = @bitCast(@as(f64, @floatFromInt(r))),
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
        .object => |o| if (o.* == .dyn_string) .{
            .tag = @intFromEnum(host_abi.WireTag.string),
            .flags = 0,
            .reserved = 0,
            .payload = @intFromPtr(o.dyn_string.ptr),
            .len = @intCast(o.dyn_string.len),
            .reserved2 = 0,
        } else return error.UnsupportedHostValueType,
        else => return error.UnsupportedHostValueType,
    };
}

fn valueFromWire(w: host_abi.ValueWire) !Value {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    return switch (tag) {
        .null => .null,
        .boolean => .{ .boolean = w.payload != 0 },
        .number => .{ .number = @bitCast(w.payload) },
        .string => return error.UnsupportedHostReturnType,
    };
}

fn wireNumberToU64(w: host_abi.ValueWire) !u64 {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    if (tag != .number) return error.HostNativeBadReturnType;
    const n: f64 = @bitCast(w.payload);
    if (n < 0) return error.HostNativeBadReturnValue;
    const tr = @trunc(n);
    if (tr != n) return error.HostNativeBadReturnValue;
    return @intFromFloat(tr);
}

fn ensureHostReady() !void {
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

// ── Native function dispatch ──────────────────────────────────────────────────

pub fn callNative(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .io_println => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            if (vms.vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_IO_PRINTLN) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    const start = vms.vmState().stack_top - argc;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try wireFromValue(vms.vmState().stack[start + i]);
                    }
                    var out: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.io_println, args_wire[0..argc], &out);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    var j: usize = 0;
                    while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(.null);
                    return;
                }
            }
            const start = vms.vmState().stack_top - argc;
            var i: usize = 0;
            while (i < @as(usize, argc)) : (i += 1) io.printValue(vms.vmState().stack[start + i]);
            io.write("\n");
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .io_printf => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            try nativePrintf(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .core_len => {
            if (argc != nf.arity) return error.ArityMismatch;
            if (vms.vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CORE_LEN) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try wireFromValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.core_len, arg_wire[0..], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try valueFromWire(out_wire);
                    _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeLen(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_append => {
            const start = vms.vmState().stack_top - argc;
            if (vms.vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_CORE_APPEND) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try wireFromValue(vms.vmState().stack[start + i]);
                    }
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.core_append, args_wire[0..argc], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try valueFromWire(out_wire);
                    var j: usize = 0;
                    while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(out);
                    return;
                }
            }
            const out = try nativeAppend(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const msg = try vms.asStringValue(arg);
            const copy = heap.bump(u8, msg.len) orelse return error.OutOfMemory;
            @memcpy(copy[0..msg.len], msg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .error_value = copy[0..msg.len] });
        },
        .core_is_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = arg == .error_value });
        },
        .core_gc => {
            if (argc != nf.arity) return error.ArityMismatch;
            vmgc.collectGarbage();
            _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .core_gc_live_objects => {
            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vms.vmPop();
            try vms.vmPush(.{ .number = @floatFromInt(heap.liveObjectCount()) });
        },
        .core_gc_stats => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStats();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_gc_stats_ext => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStatsExt();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .core_bytelen => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeByteLen(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_int => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeConvToInt(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeConvToFloat(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_bool => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeConvToBool(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .conv_to_string => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
            const out = try nativeConvToString(arg);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
    }
}
