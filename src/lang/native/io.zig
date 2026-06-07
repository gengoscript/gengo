const std = @import("std");
const io = @import("../../runtime/io.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const heap = @import("../../runtime/heap.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const host_abi = @import("../../runtime/host_abi.zig");
const host_abi_mod = @import("host_abi.zig");
const MaxNativeArgs = @import("native_ids.zig").MaxNativeArgs;

pub fn sprintValue(buf_or_null: ?[]u8, v: Value) !usize {
    switch (v) {
        .null => {
            if (buf_or_null) |buf| @memcpy(buf[0..4], "null");
            return 4;
        },
        .boolean => |b| {
            const s = if (b) "true" else "false";
            if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
            return s.len;
        },
        .decimal => |d| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(tmp[0..], "{d}", .{d}) catch return error.TypeError;
            if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
            return s.len;
        },
        .number => |n| {
            if (n == @trunc(n) and !std.math.isInf(n) and n == n) {
                const i = @as(i64, @intFromFloat(n));
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(tmp[0..], "{d}", .{i}) catch return error.TypeError;
                if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
                return s.len;
            }
            if (n != n) {
                if (buf_or_null) |buf| @memcpy(buf[0..3], "NaN");
                return 3;
            }
            if (std.math.isInf(n)) {
                const s = if (n > 0) "Inf" else "-Inf";
                if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
                return s.len;
            }
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(tmp[0..], "{d}", .{n}) catch return error.TypeError;
            if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
            return s.len;
        },
        .string => |s| {
            if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
            return s.len;
        },
        .rune => |r| {
            var tmp: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(r, &tmp);
            if (buf_or_null) |buf| @memcpy(buf[0..n], tmp[0..n]);
            return n;
        },
        .error_value => |s| {
            const prefix = "error(";
            const suffix = ")";
            const len = prefix.len + s.len + suffix.len;
            if (buf_or_null) |buf| {
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len..][0..s.len], s);
                @memcpy(buf[prefix.len + s.len..][0..suffix.len], suffix);
            }
            return len;
        },
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| {
                if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
                return s.len;
            },
            .array, .array_managed => {
                const items = vms.asArraySlice(obj);
                var len: usize = 1;
                var needs_comma = false;
                for (items) |item| {
                    if (needs_comma) len += 2;
                    len += try sprintValue(null, item);
                    needs_comma = true;
                }
                len += 1;
                if (buf_or_null) |buf| {
                    var pos: usize = 0;
                    buf[pos] = '['; pos += 1;
                    needs_comma = false;
                    for (items) |item| {
                        if (needs_comma) { @memcpy(buf[pos..][0..2], ", "); pos += 2; }
                        pos += try sprintValue(buf[pos..], item);
                        needs_comma = true;
                    }
                    buf[pos] = ']';
                }
                return len;
            },
            .map, .map_managed, .map_hashed => {
                const items = vms.asMapSlice(obj);
                var len: usize = 1;
                var needs_comma = false;
                for (items) |item| {
                    if (needs_comma) len += 2;
                    len += try sprintValue(null, item.key);
                    len += 2;
                    len += try sprintValue(null, item.value);
                    needs_comma = true;
                }
                len += 1;
                if (buf_or_null) |buf| {
                    var pos: usize = 0;
                    buf[pos] = '{'; pos += 1;
                    needs_comma = false;
                    for (items) |item| {
                        if (needs_comma) { @memcpy(buf[pos..][0..2], ", "); pos += 2; }
                        pos += try sprintValue(buf[pos..], item.key);
                        @memcpy(buf[pos..][0..2], ": "); pos += 2;
                        pos += try sprintValue(buf[pos..], item.value);
                        needs_comma = true;
                    }
                    buf[pos] = '}';
                }
                return len;
            },
            .named_value => |nv| return try sprintValue(buf_or_null, nv.value),
            .function => {
                if (buf_or_null) |buf| @memcpy(buf[0..6], "<func>");
                return 6;
            },
            .closure => {
                if (buf_or_null) |buf| @memcpy(buf[0..9], "<closure>");
                return 9;
            },
            .native_function => {
                if (buf_or_null) |buf| @memcpy(buf[0..13], "<native-func>");
                return 13;
            },
            .struct_type => |st| {
                const prefix = "<struct ";
                const suffix = ">";
                const len = prefix.len + st.name.len + suffix.len;
                if (buf_or_null) |buf| {
                    @memcpy(buf[0..prefix.len], prefix);
                    @memcpy(buf[prefix.len..][0..st.name.len], st.name);
                    @memcpy(buf[prefix.len + st.name.len..][0..suffix.len], suffix);
                }
                return len;
            },
            .named_type => |nt| {
                const prefix = "<type ";
                const suffix = ">";
                const len = prefix.len + nt.name.len + suffix.len;
                if (buf_or_null) |buf| {
                    @memcpy(buf[0..prefix.len], prefix);
                    @memcpy(buf[prefix.len..][0..nt.name.len], nt.name);
                    @memcpy(buf[prefix.len + nt.name.len..][0..suffix.len], suffix);
                }
                return len;
            },
            .struct_instance => |inst| {
                const prefix = "<struct ";
                const suffix = ">";
                const len = prefix.len + inst.typ.struct_type.name.len + suffix.len;
                if (buf_or_null) |buf| {
                    @memcpy(buf[0..prefix.len], prefix);
                    @memcpy(buf[prefix.len..][0..inst.typ.struct_type.name.len], inst.typ.struct_type.name);
                    @memcpy(buf[prefix.len + inst.typ.struct_type.name.len..][0..suffix.len], suffix);
                }
                return len;
            },
            .interface_type => |it| {
                const prefix = "<interface ";
                const suffix = ">";
                const len = prefix.len + it.name.len + suffix.len;
                if (buf_or_null) |buf| {
                    @memcpy(buf[0..prefix.len], prefix);
                    @memcpy(buf[prefix.len..][0..it.name.len], it.name);
                    @memcpy(buf[prefix.len + it.name.len..][0..suffix.len], suffix);
                }
                return len;
            },
            .enum_type => |et| {
                const prefix = "<enum ";
                const suffix = ">";
                const len = prefix.len + et.name.len + suffix.len;
                if (buf_or_null) |buf| {
                    @memcpy(buf[0..prefix.len], prefix);
                    @memcpy(buf[prefix.len..][0..et.name.len], et.name);
                    @memcpy(buf[prefix.len + et.name.len..][0..suffix.len], suffix);
                }
                return len;
            },
            .enum_value => |ev| {
                if (buf_or_null) |buf| @memcpy(buf[0..ev.name.len], ev.name);
                return ev.name.len;
            },
            .variant_type => |vt| {
                const prefix = "<variant ";
                const suffix = ">";
                const len = prefix.len + vt.name.len + suffix.len;
                if (buf_or_null) |buf| {
                    @memcpy(buf[0..prefix.len], prefix);
                    @memcpy(buf[prefix.len..][0..vt.name.len], vt.name);
                    @memcpy(buf[prefix.len + vt.name.len..][0..suffix.len], suffix);
                }
                return len;
            },
            .variant_ctor => |vc| {
                const tn = vc.typ.variant_type.name;
                const dot = ".";
                const len = tn.len + dot.len + vc.tag.len;
                if (buf_or_null) |buf| {
                    @memcpy(buf[0..tn.len], tn);
                    @memcpy(buf[tn.len..][0..dot.len], dot);
                    @memcpy(buf[tn.len + dot.len..][0..vc.tag.len], vc.tag);
                }
                return len;
            },
            .variant_value => |vv| {
                const tn = vv.typ.variant_type.name;
                const dot = ".";
                var inner_len: usize = 0;
                if (vv.arm_fields.len > 0) {
                    for (vv.arm_fields) |f| {
                        inner_len += try sprintValue(null, f);
                    }
                    inner_len += (vv.arm_fields.len - 1) * 2; // ", " separators
                } else if (vv.payload != .null) {
                    inner_len = try sprintValue(null, vv.payload);
                }
                const open = if (vv.payload != .null or vv.arm_fields.len > 0) "(" else "";
                const close = if (vv.payload != .null or vv.arm_fields.len > 0) ")" else "";
                const len = tn.len + dot.len + vv.tag.len + open.len + inner_len + close.len;
                if (buf_or_null) |buf| {
                    @memcpy(buf[0..tn.len], tn);
                    @memcpy(buf[tn.len..][0..dot.len], dot);
                    const tag_start = tn.len + dot.len;
                    @memcpy(buf[tag_start..][0..vv.tag.len], vv.tag);
                    var pos = tag_start + vv.tag.len;
                    if (open.len > 0) {
                        buf[pos] = '('; pos += 1;
                        if (vv.arm_fields.len > 0) {
                            for (vv.arm_fields, 0..) |f, fi| {
                                if (fi > 0) { @memcpy(buf[pos..][0..2], ", "); pos += 2; }
                                pos += try sprintValue(buf[pos..], f);
                            }
                        } else {
                            pos += try sprintValue(buf[pos..], vv.payload);
                        }
                        buf[pos] = ')'; pos += 1;
                    }
                }
                return len;
            },
            else => {
                if (buf_or_null) |buf| @memcpy(buf[0..4], "null");
                return 4;
            },
        },
    }
}

pub fn nativeSprintf(start: usize, argc: u8) !Value {
    if (argc < 1) return error.ArityMismatch;
    const fmt_v = vms.vmState().stack[start];
    const fmt = try vms.asStringValue(fmt_v);
    var ai: usize = 1;

    var total: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            total += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) return error.TypeError;
        if (fmt[i] == '%') {
            total += 1;
            i += 1;
            continue;
        }
        if (ai >= @as(usize, argc)) return error.ArityMismatch;
        const arg = vms.vmState().stack[start + ai];
        ai += 1;
        while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '0' or fmt[i] == '#')) i += 1;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        }
        if (i >= fmt.len) return error.TypeError;
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            'v' => total += try sprintValue(null, arg),
            's' => total += (try vms.asStringValue(arg)).len,
            'd' => {
                const n = try vms.valueAsInt(arg);
                var tmp: [24]u8 = undefined;
                total += (std.fmt.bufPrint(tmp[0..], "{d}", .{n}) catch return error.TypeError).len;
            },
            'x' => {
                const n = try vms.valueAsInt(arg);
                var tmp: [24]u8 = undefined;
                total += (std.fmt.bufPrint(tmp[0..], "{x}", .{n}) catch return error.TypeError).len;
            },
            'X' => {
                const n = try vms.valueAsInt(arg);
                var tmp: [24]u8 = undefined;
                total += (std.fmt.bufPrint(tmp[0..], "{X}", .{n}) catch return error.TypeError).len;
            },
            'f' => {
                const n = try vms.valueAsNumber(arg);
                var tmp: [64]u8 = undefined;
                total += (std.fmt.bufPrint(tmp[0..], "{d}", .{n}) catch return error.TypeError).len;
            },
            't' => {
                if (arg != .boolean) return error.TypeError;
                total += if (arg.boolean) 4 else 5;
            },
            else => return error.TypeError,
        }
    }
    if (ai != @as(usize, argc)) return error.ArityMismatch;

    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .dyn_string = &[_]u8{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(total);

    var pos: usize = 0;
    ai = 1;
    i = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            buf[pos] = fmt[i];
            pos += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (fmt[i] == '%') {
            buf[pos] = '%';
            pos += 1;
            i += 1;
            continue;
        }
        const arg = vms.vmState().stack[start + ai];
        ai += 1;
        while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '0' or fmt[i] == '#')) i += 1;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        }
        if (i >= fmt.len) return error.TypeError;
        const spec2 = fmt[i];
        i += 1;
        switch (spec2) {
            'v' => pos += try sprintValue(buf[pos..], arg),
            's' => {
                const s = try vms.asStringValue(arg);
                @memcpy(buf[pos..][0..s.len], s);
                pos += s.len;
            },
            'd' => {
                const n = try vms.valueAsInt(arg);
                const written = std.fmt.bufPrint(buf[pos..], "{d}", .{n}) catch return error.TypeError;
                pos += written.len;
            },
            'x' => {
                const n = try vms.valueAsInt(arg);
                const written = std.fmt.bufPrint(buf[pos..], "{x}", .{n}) catch return error.TypeError;
                pos += written.len;
            },
            'X' => {
                const n = try vms.valueAsInt(arg);
                const written = std.fmt.bufPrint(buf[pos..], "{X}", .{n}) catch return error.TypeError;
                pos += written.len;
            },
            'f' => {
                const n = try vms.valueAsNumber(arg);
                const written = std.fmt.bufPrint(buf[pos..], "{d}", .{n}) catch return error.TypeError;
                pos += written.len;
            },
            't' => {
                const s = if (arg.boolean) "true" else "false";
                @memcpy(buf[pos..][0..s.len], s);
                pos += s.len;
            },
            else => unreachable,
        }
    }

    obj.* = .{ .dyn_string = buf[0..pos] };
    return .{ .object = obj };
}

pub fn nativePrintf(start: usize, argc: u8) !void {
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
        i += 1;
        if (i >= fmt.len) return error.TypeError;
        if (fmt[i] == '%') {
            io.write("%");
            i += 1;
            continue;
        }
        if (ai >= @as(usize, argc)) return error.ArityMismatch;
        const arg = vms.vmState().stack[start + ai];
        ai += 1;
        while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '0' or fmt[i] == '#')) i += 1;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        var precision: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            var prec: usize = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
                prec = prec * 10 + (fmt[i] - '0');
                i += 1;
            }
            precision = prec;
        }
        if (i >= fmt.len) return error.TypeError;
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            'v' => io.printValue(arg),
            's' => io.write(try vms.asStringValue(arg)),
            'd' => io.writeInt(try vms.valueAsInt(arg)),
            'x' => {
                const n = try vms.valueAsInt(arg);
                var tmp: [24]u8 = undefined;
                io.write((std.fmt.bufPrint(tmp[0..], "{x}", .{n}) catch unreachable));
            },
            'X' => {
                const n = try vms.valueAsInt(arg);
                var tmp: [24]u8 = undefined;
                io.write((std.fmt.bufPrint(tmp[0..], "{X}", .{n}) catch unreachable));
            },
            'f' => {
                const n = try vms.valueAsNumber(arg);
                if (precision) |prec| io.writeF64Prec(n, prec) else io.writeF64(n);
            },
            't' => {
                if (arg != .boolean) return error.TypeError;
                io.write(if (arg.boolean) "true" else "false");
            },
            else => return error.TypeError,
        }
    }
    if (ai != @as(usize, argc)) return error.ArityMismatch;
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .io_print => {

            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            var i: usize = 0;
            while (i < @as(usize, argc)) : (i += 1) io.printValue(vms.vmState().stack[start + i]);
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
        .io_println => {

            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            if (vms.vmState().policy.native_backend == .host) {
                try host_abi_mod.ensureHostReady();
                if ((vms.vmState().host_caps & host_abi.CAP_IO_PRINTLN) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    const start = vms.vmState().stack_top - argc;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try host_abi_mod.wireFromValue(vms.vmState().stack[start + i]);
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
        .io_sprintf => {

            const start = vms.vmState().stack_top - argc;
            const out = try nativeSprintf(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        else => {},
    }
}
