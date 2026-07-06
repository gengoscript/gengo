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
const chunk = @import("../chunk.zig");

const PrintMaxDepth = 64;

pub fn sprintValue(buf_or_null: ?[]u8, v: Value) !usize {
    var ancestors: [PrintMaxDepth]*const Object = undefined;
    var anc_count: usize = 0;
    return sprintValueDepth(buf_or_null, v, 0, &ancestors, &anc_count);
}

fn sprintValueDepth(buf_or_null: ?[]u8, v: Value, depth: u32, ancestors: *[PrintMaxDepth]*const Object, anc_count: *usize) !usize {
    if (depth >= PrintMaxDepth) {
        if (buf_or_null) |buf| @memcpy(buf[0..3], "...");
        return 3;
    }
    if (@import("../value.zig").decimalRawAndScale(v)) |drs| {
        var tmp: [64]u8 = undefined;
        const s = @import("../value.zig").formatDecimalString(drs.raw, drs.scale, &tmp);
        if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
        return s.len;
    }
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
        .decimal => unreachable,
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(tmp[0..], "{d}", .{n}) catch return error.TypeError;
            if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
            return s.len;
        },
        .float => |n| {
            if (n == @trunc(n) and !std.math.isInf(n) and n == n) {
                if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
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
            if (buf_or_null) |buf| @memcpy(buf[0..s.bytes.len], s.bytes);
            return s.bytes.len;
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
            const len = prefix.len + s.bytes.len + suffix.len;
            if (buf_or_null) |buf| {
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len..][0..s.bytes.len], s.bytes);
                @memcpy(buf[prefix.len + s.bytes.len..][0..suffix.len], suffix);
            }
            return len;
        },
        .named_scalar => |ns| return sprintValueDepth(buf_or_null, @import("../value.zig").namedScalarInner(ns), depth, ancestors, anc_count),
        .inline_variant => |iv| {
            const vmod = @import("../value.zig");
            const ordinal = vmod.inlineVariantOrdinal(iv);
            const arm = iv.typ.variant_type.arms[ordinal];
            const payload = vmod.inlineVariantPayload(iv);
            const tn = iv.typ.variant_type.name;
            const dot = ".";
            var inner_len: usize = 0;
            if (payload != .null) inner_len = try sprintValueDepth(null, payload, depth + 1, ancestors, anc_count);
            const open = if (payload != .null) "(" else "";
            const close = if (payload != .null) ")" else "";
            const len = tn.len + dot.len + arm.name.len + open.len + inner_len + close.len;
            if (buf_or_null) |buf| {
                @memcpy(buf[0..tn.len], tn);
                @memcpy(buf[tn.len..][0..dot.len], dot);
                @memcpy(buf[tn.len + dot.len..][0..arm.name.len], arm.name);
                var pos = tn.len + dot.len + arm.name.len;
                if (open.len > 0) {
                    buf[pos] = '('; pos += 1;
                    pos += try sprintValueDepth(buf[pos..], payload, depth + 1, ancestors, anc_count);
                    buf[pos] = ')'; pos += 1;
                }
                _ = &pos;
            }
            return len;
        },
        .object => |obj| {
            for (ancestors[0..anc_count.*]) |a| {
                if (a == obj) {
                    if (buf_or_null) |buf| @memcpy(buf[0..7], "<cycle>");
                    return 7;
                }
            }
            ancestors[anc_count.*] = obj;
            anc_count.* += 1;
            defer anc_count.* -= 1;
            switch (obj.*) {
                .dyn_string => |s| {
                    if (buf_or_null) |buf| @memcpy(buf[0..s.len], s);
                    return s.len;
                },
                .string_view => |sv| {
                    if (buf_or_null) |buf| @memcpy(buf[0..sv.bytes.len], sv.bytes);
                    return sv.bytes.len;
                },
            .array, .array_managed, .array_view, .array_capacity => {
                const items = try vms.asArraySlice(obj);
                var len: usize = 1;
                var needs_comma = false;
                for (items) |item| {
                    if (needs_comma) len += 2;
                    len += try sprintValueDepth(null, item, depth + 1, ancestors, anc_count);
                    needs_comma = true;
                }
                len += 1;
                if (buf_or_null) |buf| {
                    var pos: usize = 0;
                    buf[pos] = '['; pos += 1;
                    needs_comma = false;
                    for (items) |item| {
                        if (needs_comma) { @memcpy(buf[pos..][0..2], ", "); pos += 2; }
                        pos += try sprintValueDepth(buf[pos..], item, depth + 1, ancestors, anc_count);
                        needs_comma = true;
                    }
                    buf[pos] = ']';
                }
                return len;
            },
            .map, .map_managed, .map_hashed => {
                const items = try vms.asMapSlice(obj);
                var len: usize = 1;
                var needs_comma = false;
                for (items) |item| {
                    if (needs_comma) len += 2;
                    len += try sprintValueDepth(null, item.key, depth + 1, ancestors, anc_count);
                    len += 2;
                    len += try sprintValueDepth(null, item.value, depth + 1, ancestors, anc_count);
                    needs_comma = true;
                }
                len += 1;
                if (buf_or_null) |buf| {
                    var pos: usize = 0;
                    buf[pos] = '{'; pos += 1;
                    needs_comma = false;
                    for (items) |item| {
                        if (needs_comma) { @memcpy(buf[pos..][0..2], ", "); pos += 2; }
                        pos += try sprintValueDepth(buf[pos..], item.key, depth + 1, ancestors, anc_count);
                        @memcpy(buf[pos..][0..2], ": "); pos += 2;
                        pos += try sprintValueDepth(buf[pos..], item.value, depth + 1, ancestors, anc_count);
                        needs_comma = true;
                    }
                    buf[pos] = '}';
                }
                return len;
            },
            .named_value => |nv| return try sprintValueDepth(buf_or_null, nv.value, depth + 1, ancestors, anc_count),
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
                        inner_len += try sprintValueDepth(null, f, depth + 1, ancestors, anc_count);
                    }
                    inner_len += (vv.arm_fields.len - 1) * 2; // ", " separators
                } else if (vv.payload != .null) {
                    inner_len = try sprintValueDepth(null, vv.payload, depth + 1, ancestors, anc_count);
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
                                pos += try sprintValueDepth(buf[pos..], f, depth + 1, ancestors, anc_count);
                            }
                        } else {
                            pos += try sprintValueDepth(buf[pos..], vv.payload, depth + 1, ancestors, anc_count);
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
            }
        },
    }
}

// ── Format engine ────────────────────────────────────────────────────────────

const FmtSpec = struct {
    left_align: bool = false,
    zero_pad: bool = false,
    plus_sign: bool = false,
    space_sign: bool = false,
    alt_form: bool = false,
    width: usize = 0,
    prec: i32 = -1,
    verb: u8 = 'v',
};

fn parseSpec(fmt: []const u8, i: *usize) FmtSpec {
    var s = FmtSpec{};
    while (i.* < fmt.len) : (i.* += 1) {
        switch (fmt[i.*]) {
            '-' => s.left_align = true,
            '0' => s.zero_pad = true,
            '+' => s.plus_sign = true,
            ' ' => s.space_sign = true,
            '#' => s.alt_form = true,
            else => break,
        }
    }
    while (i.* < fmt.len and fmt[i.*] >= '0' and fmt[i.*] <= '9') {
        s.width = s.width * 10 + (fmt[i.*] - '0');
        i.* += 1;
    }
    if (i.* < fmt.len and fmt[i.*] == '.') {
        i.* += 1;
        s.prec = 0;
        while (i.* < fmt.len and fmt[i.*] >= '0' and fmt[i.*] <= '9') {
            s.prec = s.prec * 10 + @as(i32, fmt[i.*] - '0');
            i.* += 1;
        }
    }
    if (i.* < fmt.len) {
        s.verb = fmt[i.*];
        i.* += 1;
    }
    return s;
}

fn isNumericVerb(v: u8) bool {
    return switch (v) {
        'd', 'x', 'X', 'o', 'b', 'f', 'e', 'E', 'g', 'G' => true,
        else => false,
    };
}

fn fmtUint64(buf: []u8, v: u64, base: u8, upper: bool) []u8 {
    if (v == 0) { buf[0] = '0'; return buf[0..1]; }
    const digs = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var tmp: [64]u8 = undefined;
    var len: usize = 0;
    var n = v;
    const b64: u64 = base;
    while (n > 0) {
        tmp[len] = digs[@intCast(n % b64)];
        len += 1;
        n /= b64;
    }
    for (0..len) |k| buf[k] = tmp[len - 1 - k];
    return buf[0..len];
}

fn fmtInt(scratch: *[2048]u8, arg: Value, spec: FmtSpec) ![]const u8 {
    const n = try vms.valueAsInt(arg);
    const neg = n < 0;
    const mag: u64 = if (neg) (if (n == std.math.minInt(i64))
        @as(u64, std.math.maxInt(i64)) + 1
    else
        @intCast(-n)) else @intCast(n);

    const base: u8 = switch (spec.verb) {
        'x', 'X' => 16,
        'o' => 8,
        'b' => 2,
        else => 10,
    };
    const upper = spec.verb == 'X';

    var sign: u8 = 0;
    if (neg) sign = '-' else if (spec.plus_sign) sign = '+' else if (spec.space_sign) sign = ' ';

    var alt: []const u8 = "";
    if (spec.alt_form and mag != 0) alt = switch (spec.verb) {
        'x' => "0x",
        'X' => "0X",
        'o' => "0",
        'b' => "0b",
        else => "",
    };

    var digits_buf: [64]u8 = undefined;
    const digits = fmtUint64(&digits_buf, mag, base, upper);

    var pos: usize = 0;
    if (sign != 0) { scratch[pos] = sign; pos += 1; }
    @memcpy(scratch[pos..][0..alt.len], alt);
    pos += alt.len;
    @memcpy(scratch[pos..][0..digits.len], digits);
    pos += digits.len;
    return scratch[0..pos];
}

fn fmtF64Fixed(buf: []u8, abs_v: f64, prec: usize) usize {
    const s: []const u8 = switch (prec) {
        0  => std.fmt.bufPrint(buf, "{d:.0}",  .{abs_v}) catch return 0,
        1  => std.fmt.bufPrint(buf, "{d:.1}",  .{abs_v}) catch return 0,
        2  => std.fmt.bufPrint(buf, "{d:.2}",  .{abs_v}) catch return 0,
        3  => std.fmt.bufPrint(buf, "{d:.3}",  .{abs_v}) catch return 0,
        4  => std.fmt.bufPrint(buf, "{d:.4}",  .{abs_v}) catch return 0,
        5  => std.fmt.bufPrint(buf, "{d:.5}",  .{abs_v}) catch return 0,
        6  => std.fmt.bufPrint(buf, "{d:.6}",  .{abs_v}) catch return 0,
        7  => std.fmt.bufPrint(buf, "{d:.7}",  .{abs_v}) catch return 0,
        8  => std.fmt.bufPrint(buf, "{d:.8}",  .{abs_v}) catch return 0,
        9  => std.fmt.bufPrint(buf, "{d:.9}",  .{abs_v}) catch return 0,
        10 => std.fmt.bufPrint(buf, "{d:.10}", .{abs_v}) catch return 0,
        11 => std.fmt.bufPrint(buf, "{d:.11}", .{abs_v}) catch return 0,
        12 => std.fmt.bufPrint(buf, "{d:.12}", .{abs_v}) catch return 0,
        13 => std.fmt.bufPrint(buf, "{d:.13}", .{abs_v}) catch return 0,
        14 => std.fmt.bufPrint(buf, "{d:.14}", .{abs_v}) catch return 0,
        15 => std.fmt.bufPrint(buf, "{d:.15}", .{abs_v}) catch return 0,
        16 => std.fmt.bufPrint(buf, "{d:.16}", .{abs_v}) catch return 0,
        else => std.fmt.bufPrint(buf, "{d:.17}", .{abs_v}) catch return 0,
    };
    return s.len;
}

fn fmtF64Sci(buf: []u8, abs_v: f64, prec: usize, upper: bool) usize {
    var pos: usize = 0;
    if (abs_v == 0.0) {
        buf[pos] = '0'; pos += 1;
        if (prec > 0) { buf[pos] = '.'; pos += 1; @memset(buf[pos..][0..prec], '0'); pos += prec; }
        buf[pos] = if (upper) 'E' else 'e'; pos += 1;
        @memcpy(buf[pos..][0..3], "+00"); pos += 3;
        return pos;
    }
    const log = std.math.log10(abs_v);
    var exp: i32 = @intFromFloat(@floor(log));
    var mant = abs_v / std.math.pow(f64, 10.0, @as(f64, @floatFromInt(exp)));
    if (mant >= 10.0) { mant /= 10.0; exp += 1; } else if (mant < 1.0) { mant *= 10.0; exp -= 1; }
    const scale = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(prec)));
    if (@round(mant * scale) >= 10.0 * scale) { mant /= 10.0; exp += 1; }
    pos += fmtF64Fixed(buf[pos..], mant, prec);
    buf[pos] = if (upper) 'E' else 'e'; pos += 1;
    buf[pos] = if (exp >= 0) '+' else '-'; pos += 1;
    const abs_exp: u32 = @intCast(@abs(exp));
    if (abs_exp < 10) { buf[pos] = '0'; pos += 1; }
    var exp_tmp: [8]u8 = undefined;
    const exp_s = fmtUint64(&exp_tmp, abs_exp, 10, false);
    @memcpy(buf[pos..][0..exp_s.len], exp_s); pos += exp_s.len;
    return pos;
}

fn stripTrailingZeros(buf: []u8, end: usize) usize {
    var dot: ?usize = null;
    for (buf[0..end], 0..) |c, k| if (c == '.') { dot = k; break; };
    const d = dot orelse return end;
    var e = end;
    while (e > d + 1 and buf[e - 1] == '0') e -= 1;
    if (e == d + 1) e -= 1;
    return e;
}

fn stripTrailingZerosBeforeExp(buf: []u8, end: usize) usize {
    var e_pos: ?usize = null;
    for (buf[0..end], 0..) |c, k| if (c == 'e' or c == 'E') { e_pos = k; break; };
    const ep = e_pos orelse return end;
    var dot: ?usize = null;
    for (buf[0..ep], 0..) |c, k| if (c == '.') { dot = k; break; };
    const d = dot orelse return end;
    var mend = ep;
    while (mend > d + 1 and buf[mend - 1] == '0') mend -= 1;
    if (mend == d + 1) mend -= 1;
    const exp_len = end - ep;
    var exp_tmp: [24]u8 = undefined;
    @memcpy(exp_tmp[0..exp_len], buf[ep..end]);
    @memcpy(buf[mend..][0..exp_len], exp_tmp[0..exp_len]);
    return mend + exp_len;
}

fn fmtF64General(buf: []u8, abs_v: f64, prec_in: usize, upper: bool) usize {
    const p = if (prec_in == 0) @as(usize, 1) else prec_in;
    if (abs_v == 0.0) { buf[0] = '0'; return 1; }
    const log = std.math.log10(abs_v);
    const exp: i32 = @intFromFloat(@floor(log));
    if (exp < -4 or exp >= @as(i32, @intCast(p))) {
        const pos = fmtF64Sci(buf, abs_v, p - 1, upper);
        return stripTrailingZerosBeforeExp(buf, pos);
    }
    const dp: usize = if (@as(i32, @intCast(p)) - 1 - exp > 0)
        @intCast(@as(i32, @intCast(p)) - 1 - exp)
    else
        0;
    const pos = fmtF64Fixed(buf, abs_v, dp);
    return stripTrailingZeros(buf, pos);
}

fn fmtFloat(buf: []u8, v: f64, verb: u8, prec_in: i32, spec: FmtSpec) usize {
    if (v != v) { @memcpy(buf[0..3], "NaN"); return 3; }
    var pos: usize = 0;
    const neg = v < 0.0 or (v == 0.0 and std.math.signbit(v));
    const abs = @abs(v);
    if (std.math.isInf(abs)) {
        if (neg) { @memcpy(buf[0..4], "-Inf"); return 4; }
        @memcpy(buf[0..3], "Inf"); return 3;
    }
    if (neg) { buf[pos] = '-'; pos += 1; }
    else if (spec.plus_sign) { buf[pos] = '+'; pos += 1; }
    else if (spec.space_sign) { buf[pos] = ' '; pos += 1; }
    const prec: usize = if (prec_in < 0) 6 else @intCast(prec_in);
    pos += switch (verb) {
        'f' => fmtF64Fixed(buf[pos..], abs, prec),
        'e' => fmtF64Sci(buf[pos..], abs, prec, false),
        'E' => fmtF64Sci(buf[pos..], abs, prec, true),
        'g' => fmtF64General(buf[pos..], abs, prec, false),
        'G' => fmtF64General(buf[pos..], abs, prec, true),
        else => 0,
    };
    return pos;
}

fn fmtQuoted(buf: []u8, s: []const u8) usize {
    var pos: usize = 0;
    if (pos + 2 > buf.len) return 0;
    buf[pos] = '"'; pos += 1;
    for (s) |c| {
        const needed: usize = switch (c) {
            '\\', '"', '\n', '\r', '\t' => 2,
            0...8, 11, 12, 14...31, 127 => 4,
            else => 1,
        };
        if (pos + needed + 1 > buf.len) break;
        switch (c) {
            '\\' => { buf[pos] = '\\'; buf[pos+1] = '\\'; pos += 2; },
            '"'  => { buf[pos] = '\\'; buf[pos+1] = '"';  pos += 2; },
            '\n' => { buf[pos] = '\\'; buf[pos+1] = 'n';  pos += 2; },
            '\r' => { buf[pos] = '\\'; buf[pos+1] = 'r';  pos += 2; },
            '\t' => { buf[pos] = '\\'; buf[pos+1] = 't';  pos += 2; },
            0...8, 11, 12, 14...31, 127 => {
                buf[pos]   = '\\'; buf[pos+1] = 'x';
                buf[pos+2] = "0123456789abcdef"[c >> 4];
                buf[pos+3] = "0123456789abcdef"[c & 0xF];
                pos += 4;
            },
            else => { buf[pos] = c; pos += 1; },
        }
    }
    buf[pos] = '"'; pos += 1;
    return pos;
}

fn fmtArg(scratch: *[2048]u8, arg: Value, spec: FmtSpec) ![]const u8 {
    switch (spec.verb) {
        's' => {
            var s = try vms.asStringValue(arg);
            if (spec.prec >= 0) {
                const limit: usize = @intCast(spec.prec);
                if (limit < s.len) s = s[0..limit];
            }
            return s;
        },
        't' => {
            if (arg != .boolean) return error.TypeError;
            return if (arg.boolean) "true" else "false";
        },
        'c' => {
            const r: u21 = switch (arg) {
                .rune => |rv| rv,
                .int => |n| blk: {
                    if (n < 0 or n > 0x10FFFF) return error.TypeError;
                    break :blk @intCast(n);
                },
                else => return error.TypeError,
            };
            const n = std.unicode.utf8Encode(r, scratch[0..4]) catch return error.TypeError;
            return scratch[0..n];
        },
        'd', 'x', 'X', 'o', 'b' => return fmtInt(scratch, arg, spec),
        'f', 'e', 'E', 'g', 'G' => {
            const n = try vms.valueAsNumber(arg);
            const flen = fmtFloat(scratch[0..], n, spec.verb, spec.prec, spec);
            return scratch[0..flen];
        },
        'q' => {
            const s = try vms.asStringValue(arg);
            const qlen = fmtQuoted(scratch[0..], s);
            return scratch[0..qlen];
        },
        else => return error.TypeError,
    }
}

// Single-pass format processor: buf_opt==null → measure, buf_opt!=null → write.
fn fmtProcess(buf_opt: ?[]u8, fmt: []const u8, args_start: usize, argc: u8) !usize {
    var total: usize = 0;
    var ai: usize = 1;
    var fi: usize = 0;
    var plain_start: usize = 0;
    var scratch: [2048]u8 = undefined;

    while (fi < fmt.len) {
        if (fmt[fi] != '%') { fi += 1; continue; }

        const plain = fmt[plain_start..fi];
        if (buf_opt) |b| @memcpy(b[total..][0..plain.len], plain);
        total += plain.len;

        fi += 1;
        if (fi >= fmt.len) return error.TypeError;

        if (fmt[fi] == '%') {
            if (buf_opt) |b| b[total] = '%';
            total += 1; fi += 1; plain_start = fi;
            continue;
        }

        const spec = parseSpec(fmt, &fi);
        plain_start = fi;

        if (ai >= @as(usize, argc)) return error.ArityMismatch;
        const arg = vms.vmState().stack[args_start + ai];
        ai += 1;

        if (spec.verb == 'v') {
            const core_len = try sprintValue(null, arg);
            const pad = if (spec.width > core_len) spec.width - core_len else 0;
            if (buf_opt) |b| {
                if (spec.left_align) {
                    _ = try sprintValue(b[total..][0..core_len], arg);
                    @memset(b[total + core_len..][0..pad], ' ');
                } else {
                    @memset(b[total..][0..pad], ' ');
                    _ = try sprintValue(b[total + pad..][0..core_len], arg);
                }
            }
            total += core_len + pad;
            continue;
        }

        const core = try fmtArg(&scratch, arg, spec);
        const pad = if (spec.width > core.len) spec.width - core.len else 0;
        if (buf_opt) |b| {
            if (spec.left_align) {
                @memcpy(b[total..][0..core.len], core);
                @memset(b[total + core.len..][0..pad], ' ');
            } else if (spec.zero_pad and isNumericVerb(spec.verb) and pad > 0) {
                if (core.len > 0 and (core[0] == '-' or core[0] == '+' or core[0] == ' ')) {
                    b[total] = core[0];
                    @memset(b[total + 1..][0..pad], '0');
                    @memcpy(b[total + 1 + pad..][0..core.len - 1], core[1..]);
                } else {
                    @memset(b[total..][0..pad], '0');
                    @memcpy(b[total + pad..][0..core.len], core);
                }
            } else {
                @memset(b[total..][0..pad], ' ');
                @memcpy(b[total + pad..][0..core.len], core);
            }
        }
        total += core.len + pad;
    }

    const tail = fmt[plain_start..];
    if (buf_opt) |b| @memcpy(b[total..][0..tail.len], tail);
    total += tail.len;

    if (ai != @as(usize, argc)) return error.ArityMismatch;
    return total;
}

fn doSprintf(fmt_str: []const u8, args_start: usize, argc: u8) !Value {
    const total = try fmtProcess(null, fmt_str, args_start, argc);
    const obj = try vmgc.allocTempRooted(.{ .dyn_string = &[_]u8{} });
    defer vms.popTempRoot();
    if (total > 0) {
        const buf = try vmgc.vmAllocManagedBytes(total);
        _ = try fmtProcess(buf, fmt_str, args_start, argc);
        obj.* = .{ .dyn_string = buf[0..total] };
    }
    return .{ .object = obj };
}

fn printArgToErr(arg: Value) !void {
    const n = try sprintValue(null, arg);
    if (n == 0) return;
    const obj = try vmgc.allocTempRooted(.{ .dyn_string = &[_]u8{} });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(n);
    _ = try sprintValue(buf, arg);
    obj.* = .{ .dyn_string = buf[0..n] };
    io.werr(buf[0..n]);
}

fn bytesToValue(bytes: []const u8) !Value {
    const obj = try vmgc.allocTempRooted(.{ .dyn_string = &[_]u8{} });
    defer vms.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(bytes.len);
    @memcpy(buf[0..bytes.len], bytes);
    obj.* = .{ .dyn_string = buf[0..bytes.len] };
    return .{ .object = obj };
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .io_print => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            for (vms.vmState().stack[start .. start + argc]) |v| io.printValue(v);
            vms.vmPopArgs(argc);
            try vms.vmPush(.null);
        },
        .io_printf => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            if (argc < 1) return error.ArityMismatch;
            const fmt_str = try vms.asStringValue(vms.vmState().stack[start]);
            const result = try doSprintf(fmt_str, start, argc);
            io.write(result.object.*.dyn_string);
            vms.vmPopArgs(argc);
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
                    for (args_wire[0..argc], vms.vmState().stack[start .. start + argc]) |*w, v| w.* = try host_abi_mod.wireFromValue(v);
                    var out = host_abi_mod.nullWire();
                    try host_abi_mod.nativeCallChecked(.io_println, args_wire[0..argc], &out);
                    vms.vmPopArgs(argc);
                    try vms.vmPush(.null);
                    return;
                }
            }
            const start = vms.vmState().stack_top - argc;
            for (vms.vmState().stack[start .. start + argc]) |v| io.printValue(v);
            io.write("\n");
            vms.vmPopArgs(argc);
            try vms.vmPush(.null);
        },
        .io_sprintf => {
            const start = vms.vmState().stack_top - argc;
            if (argc < 1) return error.ArityMismatch;
            const fmt_str = try vms.asStringValue(vms.vmState().stack[start]);
            const out = try doSprintf(fmt_str, start, argc);
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .io_eprint => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            for (vms.vmState().stack[start .. start + argc]) |v| try printArgToErr(v);
            vms.vmPopArgs(argc);
            try vms.vmPush(.null);
        },
        .io_eprintf => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            if (argc < 1) return error.ArityMismatch;
            const fmt_str = try vms.asStringValue(vms.vmState().stack[start]);
            const result = try doSprintf(fmt_str, start, argc);
            io.werr(result.object.*.dyn_string);
            vms.vmPopArgs(argc);
            try vms.vmPush(.null);
        },
        .io_eprintln => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            const start = vms.vmState().stack_top - argc;
            for (vms.vmState().stack[start .. start + argc]) |v| try printArgToErr(v);
            io.werr("\n");
            vms.vmPopArgs(argc);
            try vms.vmPush(.null);
        },
        .io_read => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            var rbuf: [4096]u8 = undefined;
            const n = io.readBytesRaw(&rbuf, false);
            const result: Value = if (n > 0) try bytesToValue(rbuf[0..@intCast(n)]) else .null;
            _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .io_readline => {
            if (!vms.vmState().policy.allow_io) return error.PermissionDenied;
            var rbuf: [4096]u8 = undefined;
            const n = io.readBytesRaw(&rbuf, true);
            const result: Value = if (n > 0) blk: {
                var cnt: usize = @intCast(n);
                if (cnt > 0 and rbuf[cnt - 1] == '\n') cnt -= 1;
                if (cnt > 0 and rbuf[cnt - 1] == '\r') cnt -= 1;
                break :blk try bytesToValue(rbuf[0..cnt]);
            } else .null;
            _ = try vms.vmPop();
            try vms.vmPush(result);
        },
        .fmt_stringify => {
            if (argc != 1) return error.ArityMismatch;
            const v = vms.vmState().stack[vms.vmState().stack_top - 1];
            const n = try sprintValue(null, v);
            const obj = try vmgc.allocTempRooted(.{ .dyn_string = &[_]u8{} });
            defer vms.popTempRoot();
            if (n > 0) {
                const buf = try vmgc.vmAllocManagedBytes(n);
                _ = try sprintValue(buf, v);
                obj.* = .{ .dyn_string = buf[0..n] };
            }
            vms.vmPopArgs(argc);
            try vms.vmPush(.{ .object = obj });
        },
        else => {},
    }
}
