const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const globals = @import("globals.zig");
const heap = @import("../runtime/heap.zig");
const cfg = @import("../runtime/config.zig");
const Op = @import("op.zig").Op;
const vmod = @import("value.zig");
const Value = vmod.Value;
const VTag = vmod.VTag;
const StringSlice = vmod.StringSlice;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const IterObj = vmod.IterObj;
const ClosureObj = vmod.ClosureObj;

const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const vmmap = @import("vm_map.zig");
const vmstr = @import("vm_string.zig");
const vmtyp = @import("vm_types.zig");
const build_options = @import("build_options");
const vmnative = @import("vm_native.zig");
const vmperf = @import("vm_perf.zig");
const io = @import("../runtime/io.zig");

// ── Public re-exports (external callers import from vm.zig unchanged) ─────────

pub const Policy = vms.Policy;
pub const State = vms.State;
pub const PanicFrame = vms.PanicFrame;
pub const MaxFrames = vmState().frames.len;

pub const setActive = vms.setActive;
pub const reset = vms.reset;
pub const resetExec = vms.resetExec;
pub const setPolicy = vms.setPolicy;
pub const currentLine = vms.currentLine;
pub const currentCol = vms.currentCol;
pub const panicLine = vms.panicLine;
pub const panicCol = vms.panicCol;
pub const panicFrames = vms.panicFrames;
pub const runtimeErrMsg = vms.runtimeErrMsg;

// ── Aliases for hot-path readability in runInner ──────────────────────────────

fn isModuleNamespaceStruct(typ: *Object) bool {
    return typ.* == .struct_type and std.mem.startsWith(u8, typ.struct_type.qualified_name, "@module_type:");
}

const vmState = vms.vmState;
const vmPush = vms.vmPush;
const vmPop = vms.vmPop;
const vmPeek = vms.vmPeek;
const vmByte = vms.vmByte;
const vmShort = vms.vmShort;
const vmConst = vms.vmConst;
const pushTempRoot = vms.pushTempRoot;
const popTempRoot = vms.popTempRoot;
const vmAllocObject = vmgc.vmAllocObject;
const allocTempRooted = vmgc.allocTempRooted;
const vmAllocManagedSlice = vmgc.vmAllocManagedSlice;
const makeDynString = vmgc.makeDynString;
const makeStringView = vmgc.makeStringView;
const concatDynString = vmgc.concatDynString;

fn panicMessageFromValue(v: Value) []const u8 {
    if (v == .string) return v.string.bytes;
    if (v == .object) {
        if (v.object.* == .dyn_string) return v.object.dyn_string;
        if (v.object.* == .string_view) return v.object.string_view.bytes;
    }
    if (v == .int) {
        return std.fmt.bufPrint(&vmState().fmt_scratch, "{d}", .{v.int}) catch "AssertionFailed";
    }
    if (v == .float) {
        return std.fmt.bufPrint(&vmState().fmt_scratch, "{d}", .{v.float}) catch "AssertionFailed";
    }
    if (v == .boolean) return if (v.boolean) "true" else "false";
    if (v == .null) return "null";
    if (v == .error_value) return v.error_value.bytes;
    return "AssertionFailed";
}

// ── Private helpers used only in the execution core ───────────────────────────

fn namedTypeIsSubOf(sub: *Object, ancestor: *Object) bool {
    if (sub == ancestor) return true;
    var cur = vmtyp.resolveParentType(sub) orelse return false;
    while (true) {
        if (cur == ancestor) return true;
        cur = vmtyp.resolveParentType(cur) orelse return false;
    }
}

fn namedTypeCommonAncestor(a: *Object, b: *Object) ?*Object {
    if (a == b) return a;
    // Walk the chain of b's ancestors; for each, check if a is a subtype of it.
    var cur = vmtyp.resolveParentType(b) orelse return null;
    while (true) {
        if (namedTypeIsSubOf(a, cur)) return cur;
        cur = vmtyp.resolveParentType(cur) orelse return null;
    }
}

fn namedTypeCarrier(a: Value, b: Value) !?*Object {
    var ta: ?*Object = null;
    var tb: ?*Object = null;
    if (a == .object and a.object.* == .named_value) ta = a.object.named_value.typ;
    if (b == .object and b.object.* == .named_value) tb = b.object.named_value.typ;
    if (ta == null and tb == null) return null;
    if (ta == null or tb == null) return error.TypeError;
    if (ta.? == tb.?) return ta;
    if (namedTypeIsSubOf(ta.?, tb.?)) return tb.?;
    if (namedTypeIsSubOf(tb.?, ta.?)) return ta.?;
    if (namedTypeCommonAncestor(ta.?, tb.?)) |lca| return lca;
    return error.TypeError;
}

fn isStringValueOrNamedString(v: Value) bool {
    if (vms.isStringValue(v)) return true;
    if (v == .object and v.object.* == .named_value) {
        const nv = v.object.named_value;
        if (nv.typ.* == .named_type and nv.typ.named_type.base == .string)
            return true;
    }
    return false;
}

fn typeAssert(v: Value, ok: bool, expected: []const u8) !void {
    if (!ok) {
        vms.setRuntimeErr("expected {s}, got {s}", .{ expected, vmtyp.runtimeTypeName(v) });
        return error.TypeError;
    }
}

// Conditions are bool-only; explain what arrived instead of a bare TypeError.
fn condAsBool(v: Value, what: []const u8) !bool {
    return v.asBool() catch {
        vms.setRuntimeErr("{s} must be bool, got {s}; use a comparison or std.conv.to_bool", .{ what, vmtyp.runtimeTypeName(v) });
        return error.TypeError;
    };
}

fn setBinaryTypeError(op: []const u8, a: Value, b: Value) void {
    const a_named = a == .object and a.object.* == .named_value;
    const b_named = b == .object and b.object.* == .named_value;
    if (a_named and b_named) {
        const ta = a.object.named_value.typ.named_type;
        const tb = b.object.named_value.typ.named_type;
        const ta_obj = a.object.named_value.typ;
        const tb_obj = b.object.named_value.typ;
        if (ta.base == tb.base and !namedTypeIsSubOf(ta_obj, tb_obj) and !namedTypeIsSubOf(tb_obj, ta_obj) and namedTypeCommonAncestor(ta_obj, tb_obj) == null) {
            vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}; convert one side explicitly before applying '{s}'", .{ op, ta.name, tb.name, op });
            return;
        }
    } else if (a_named != b_named) {
        const named_v = if (a_named) a else b;
        const raw_v = if (a_named) b else a;
        const named_typ = named_v.object.named_value.typ.named_type;
        const raw_name = vmtyp.runtimeTypeName(raw_v);
        vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}; wrap the {s} with {s}(...) or unwrap the named value with {s}(...)", .{
            op,
            named_typ.name,
            raw_name,
            raw_name,
            named_typ.name,
            vmtyp.namedBaseName(named_typ.base),
        });
        return;
    }
    if ((a == .int and b == .float) or (a == .float and b == .int)) {
        vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}; use matching numeric types such as 2.0 or float(2)", .{
            op,
            vmtyp.runtimeTypeName(a),
            vmtyp.runtimeTypeName(b),
        });
        return;
    }
    vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}", .{ op, vmtyp.runtimeTypeName(a), vmtyp.runtimeTypeName(b) });
}

fn valueAsNumberForOp(v: Value, other: Value, op: []const u8) !f64 {
    return vms.valueAsNumber(v) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(op, v, other);
        return err;
    };
}

// Ordering comparisons follow the same strictness as arithmetic: raw int
// and float do not mix (Ada/Go draw this line at typed values too).
fn checkComparableNumeric(a: Value, b: Value, op: []const u8) !void {
    const ea = vms.unboxNamed(a);
    const eb = vms.unboxNamed(b);
    const ea_raw = ea == .int or ea == .float;
    const eb_raw = eb == .int or eb == .float;
    if (ea_raw and eb_raw and @as(VTag, ea) != @as(VTag, eb)) {
        vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}; use matching numeric types such as 2.0 or float(2)", .{ op, vmtyp.runtimeTypeName(a), vmtyp.runtimeTypeName(b) });
        return error.TypeError;
    }
}

fn valueAsNumberForCompare(v: Value, other: Value) !f64 {
    return vms.valueAsNumber(v) catch |err| {
        if (err == error.TypeError) {
            vms.setRuntimeErr("cannot compare {s} and {s}", .{ vmtyp.runtimeTypeName(v), vmtyp.runtimeTypeName(other) });
        }
        return err;
    };
}

fn compareNumericPair(a: Value, b: Value, op: []const u8) !struct { an: f64, bn: f64 } {
    if (a == .int and b == .int) return .{ .an = @floatFromInt(a.int), .bn = @floatFromInt(b.int) };
    if (a == .float and b == .float) {
        if (!std.math.isFinite(a.float) or !std.math.isFinite(b.float)) {
            vms.setRuntimeErr("cannot compare non-finite value", .{});
            return error.TypeError;
        }
        return .{ .an = a.float, .bn = b.float };
    }
    try checkNamedValueCompatibility(a, b);
    try checkComparableNumeric(a, b, op);
    const an = try valueAsNumberForCompare(a, b);
    const bn = try valueAsNumberForCompare(b, a);
    if (!std.math.isFinite(an) or !std.math.isFinite(bn)) {
        vms.setRuntimeErr("cannot compare non-finite value", .{});
        return error.TypeError;
    }
    return .{ .an = an, .bn = bn };
}

fn valueAsIntForOp(v: Value, other: Value, op: []const u8) !i64 {
    return vms.valueAsInt(v) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(op, v, other);
        return err;
    };
}

const NumericOpCtx = struct { an: f64, bn: f64, tag: VTag };

fn numericBinaryOp(a: Value, b: Value, comptime op: []const u8) !NumericOpCtx {
    const tag = numericOpTag(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(op, a, b);
        return err;
    };
    const an = try valueAsNumberForOp(a, b, op);
    const bn = try valueAsNumberForOp(b, a, op);
    return .{ .an = an, .bn = bn, .tag = tag };
}

fn checkNamedValueCompatibility(a: Value, b: Value) !void {
    const a_named = a == .object and a.object.* == .named_value;
    const b_named = b == .object and b.object.* == .named_value;
    if (a_named and b_named) {
        if (a.object.named_value.typ != b.object.named_value.typ) {
            const ta = a.object.named_value.typ;
            const tb = b.object.named_value.typ;
            if (!namedTypeIsSubOf(ta, tb) and !namedTypeIsSubOf(tb, ta) and namedTypeCommonAncestor(ta, tb) == null) {
                vms.setRuntimeErr("cannot mix {s} and {s}; convert one side explicitly", .{ ta.named_type.name, tb.named_type.name });
                return error.TypeError;
            }
        }
    } else if (a_named != b_named) {
        const named = if (a_named) a else b;
        const plain = if (a_named) b else a;
        const nt_name = named.object.named_value.typ.named_type.name;
        if (plain == .null) {
            vms.setRuntimeErr("cannot compare {s} with null; {s} is non-nullable — use ?{s} to allow null", .{ nt_name, nt_name, nt_name });
        } else {
            vms.setRuntimeErr("cannot mix {s} and {s}; wrap the {s} with {s}(...) or unwrap with {s}(...)", .{
                nt_name, vmtyp.runtimeTypeName(plain), vmtyp.runtimeTypeName(plain), nt_name, vmtyp.namedBaseName(named.object.named_value.typ.named_type.base),
            });
        }
        return error.TypeError;
    }
}

fn numericOpTag(a: Value, b: Value) !VTag {
    const a_raw = a == .int or a == .float;
    const b_raw = b == .int or b == .float;
    if (a_raw and b_raw and @as(VTag, a) != @as(VTag, b)) return error.TypeError;
    if (a == .float or b == .float) return .float;
    return .int;
}

fn decimalScalarPair(dec: Value, scalar: Value) ?struct { d: i64, n: i64, typ: *Object } {
    if (dec != .object or dec.object.* != .named_value) return null;
    if (dec.object.named_value.typ.named_type.base != .decimal) return null;
    if (scalar != .int or scalar.int < std.math.minInt(i64) or scalar.int >= std.math.maxInt(i64)) return null;
    return .{
        .d = vms.valueAsDecimal(dec.object.named_value.value) catch return null,
        .n = scalar.int,
        .typ = dec.object.named_value.typ,
    };
}

fn decimalOpValues(a: Value, b: Value) ?struct { lhs: i64, rhs: i64, typ: *Object } {
    if (a == .object and a.object.* == .named_value and
        b == .object and b.object.* == .named_value and
        a.object.named_value.typ == b.object.named_value.typ and
        a.object.named_value.typ.named_type.base == .decimal)
    {
        return .{
            .lhs = vms.valueAsDecimal(a.object.named_value.value) catch return null,
            .rhs = vms.valueAsDecimal(b.object.named_value.value) catch return null,
            .typ = a.object.named_value.typ,
        };
    }
    return null;
}

fn pushDecimalResultWithCarrier(typ: *Object, d: i64) !void {
    const wrapped = try vmtyp.coerceNamedTypeResult(typ, .{ .decimal = d });
    try checkNamedTypePredicate(typ, wrapped.object.named_value.value);
    try vmPush(wrapped);
}

fn computeAddResult(a: Value, b: Value) !Value {
    if (a == .int and b == .int) return .{ .int = a.int + b.int };
    if (a == .float and b == .float) {
        const r = a.float + b.float;
        if (!std.math.isFinite(r)) { vms.setRuntimeErr("non-finite value in arithmetic operation", .{}); return error.TypeError; }
        return .{ .float = r };
    }
    if (isStringValueOrNamedString(a) and isStringValueOrNamedString(b)) {
        try pushTempRoot(a);
        defer popTempRoot();
        try pushTempRoot(b);
        defer popTempRoot();
        const sa = try vms.asStringValue(a);
        const sb = try vms.asStringValue(b);
        vmperf.countStringConcat(sa.len + sb.len);
        const result = try concatDynString(sa, sb);
        const carrier = namedTypeCarrier(a, b) catch |err| {
            if (err == error.TypeError) setBinaryTypeError("+", a, b);
            return err;
        };
        if (carrier) |typ| {
            try vms.pushTempRoot(result);
            defer vms.popTempRoot();
            return try vmtyp.makeNamedValue(typ, result);
        } else {
            return result;
        }
    } else if (decimalOpValues(a, b)) |dop| {
        const result = @addWithOverflow(dop.lhs, dop.rhs);
        if (result[1] != 0) return error.TypeError;
        return try vmtyp.coerceNamedTypeResult(dop.typ, .{ .decimal = result[0] });
    } else {
        const tag = numericOpTag(a, b) catch |err| {
            if (err == error.TypeError) setBinaryTypeError("+", a, b);
            return err;
        };
        const an = try valueAsNumberForOp(a, b, "+");
        const bn = try valueAsNumberForOp(b, a, "+");
        if (!std.math.isFinite(an + bn)) {
            vms.setRuntimeErr("non-finite value in arithmetic operation", .{});
            return error.TypeError;
        }
        return try wrapValueWithCarrier(a, b, makeNumeric(tag, an + bn), "+");
    }
}

fn pushSubResult(a: Value, b: Value) !void {
    const an = try valueAsNumberForOp(a, b, "-");
    const bn = try valueAsNumberForOp(b, a, "-");
    const tag = numericOpTag(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError("-", a, b);
        return err;
    };
    try pushNumericResultWithCarrier(a, b, an - bn, tag, "-");
}

fn makeNumeric(tag: VTag, n: f64) Value {
    return switch (tag) {
        .int => .{ .int = @intFromFloat(n) },
        .float => .{ .float = n },
        else => .{ .int = @intFromFloat(n) },
    };
}

fn wrapValueWithCarrier(a: Value, b: Value, val: Value, op: []const u8) !Value {
    // Fast path: plain scalars carry no named type.
    if (a != .object and b != .object) return val;
    const carrier = namedTypeCarrier(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(op, a, b);
        return err;
    };
    if (carrier) |typ| {
        const wrapped = try vmtyp.coerceNamedTypeResult(typ, val);
        try checkNamedTypePredicate(typ, wrapped.object.named_value.value);
        return wrapped;
    }
    return val;
}

fn pushIntResultWithCarrier(a: Value, b: Value, n: i64, op: []const u8) !void {
    try vmPush(try wrapValueWithCarrier(a, b, .{ .int = n }, op));
}

fn pushNumericResultWithCarrier(a: Value, b: Value, n: f64, tag: VTag, op: []const u8) !void {
    if (!std.math.isFinite(n)) {
        vms.setRuntimeErr("non-finite value in arithmetic operation", .{});
        return error.TypeError;
    }
    try vmPush(try wrapValueWithCarrier(a, b, makeNumeric(tag, n), op));
}

fn getShiftArgs(op: []const u8) !struct { a: Value, b: Value, an: i64, shift: u6 } {
    const b = try vmPop();
    const a = try vmPop();
    const an = try valueAsIntForOp(a, b, op);
    const bn = try valueAsIntForOp(b, a, op);
    if (bn < 0) return error.RangeError;
    return .{ .a = a, .b = b, .an = an, .shift = @intCast(@min(bn, 63)) };
}

fn pushUnaryIntResult(v: Value, result: Value) !void {
    _ = try vmPop();
    if (v == .object and v.object.* == .named_value) {
        const wrapped = try vmtyp.coerceNamedTypeResult(v.object.named_value.typ, result);
        try checkNamedTypePredicate(v.object.named_value.typ, wrapped.object.named_value.value);
        try vmPush(wrapped);
    } else {
        try vmPush(result);
    }
}

fn pushStringResultWithCarrier(a: Value, b: Value, raw: Value) !void {
    const carrier = namedTypeCarrier(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError("+", a, b);
        return err;
    };
    if (carrier) |typ| {
        try vms.pushTempRoot(raw);
        defer vms.popTempRoot();
        try vmPush(try vmtyp.makeNamedValue(typ, raw));
    } else {
        try vmPush(raw);
    }
}

fn prepareVariadicCall(f: @import("value.zig").FuncObj, argc: u8) !void {
    if (!f.is_variadic) return;
    const fixed: usize = f.arity - 1;
    if (argc < fixed) return error.ArityMismatch;
    if (vmState().stack_top < @as(usize, argc)) return error.StackUnderflow;
    const start = vmState().stack_top - argc;
    const extra: usize = argc - fixed;
    const arr_obj = try allocTempRooted(.{ .array = &[_]Value{} });
    defer popTempRoot();
    const items = try vmAllocManagedSlice(Value, extra);
    @memcpy(items[0..extra], vmState().stack[start + fixed .. start + fixed + extra]);
    arr_obj.* = .{ .array_managed = items[0..extra] };
    vmState().stack[start + fixed] = .{ .object = arr_obj };
    vmState().stack_top = start + fixed + 1;
}

// Allocate an enum_value for `member_name` on `obj` (an enum_type object).
// For subtypes, the value's typ pointer is the PARENT enum and ordinal is the
// parent's ordinal, so two values from different subtypes of the same parent
// compare equal.  Returns error.UnknownStructField if the name is not a member.
fn enumTypeAllocValue(obj: *Object, member_name: []const u8) !Value {
    const et = &obj.enum_type;
    if (et.parent_name != null) {
        // Subtype: first validate the name is in the subset members.
        var in_sub = false;
        for (et.members) |m| {
            if (common.streq(m, member_name)) { in_sub = true; break; }
        }
        if (!in_sub) return error.UnknownStructField;
        // Resolve parent and find the ordinal there.
        const parent_obj = vmtyp.resolveEnumParent(obj) orelse return error.UnknownStructField;
        const parent_members = parent_obj.enum_type.members;
        for (parent_members, 0..) |m, pi| {
            if (common.streq(m, member_name)) {
                const ev = try vmAllocObject();
                ev.* = .{ .enum_value = .{ .typ = parent_obj, .name = m, .ordinal = @intCast(pi) } };
                return .{ .object = ev };
            }
        }
        return error.UnknownStructField;
    } else {
        for (et.members, 0..) |m, ei| {
            if (common.streq(m, member_name)) {
                const ev = try vmAllocObject();
                ev.* = .{ .enum_value = .{ .typ = obj, .name = m, .ordinal = @intCast(ei) } };
                return .{ .object = ev };
            }
        }
        return error.UnknownStructField;
    }
}

fn enumTypeValuesValue(obj: *Object, et: vmod.EnumTypeObj) !Value {
    const arr_obj = try allocTempRooted(.{ .array = &[_]Value{} });
    defer popTempRoot();
    const items = try vmAllocManagedSlice(Value, et.members.len);
    for (et.members, 0..) |m, ei| {
        items[ei] = try enumTypeAllocValue(obj, m);
        arr_obj.* = .{ .array_managed = items[0 .. ei + 1] };
    }
    return .{ .object = arr_obj };
}

fn enumTypeFieldValue(obj: *Object, name: []const u8) !Value {
    const et = obj.enum_type;
    if (common.streq(name, "name")) return .{ .string = try chunk.internStr(et.name) };
    if (common.streq(name, "first")) {
        if (et.members.len == 0) return error.IndexOutOfBounds;
        return try enumTypeAllocValue(obj, et.members[0]);
    }
    if (common.streq(name, "last")) {
        if (et.members.len == 0) return error.IndexOutOfBounds;
        return try enumTypeAllocValue(obj, et.members[et.members.len - 1]);
    }
    if (common.streq(name, "values")) return try enumTypeValuesValue(obj, et);
    return try enumTypeAllocValue(obj, name);
}

fn namedTypeFieldValue(obj: *Object, name: []const u8) !Value {
    const nt = obj.named_type;
    if (common.streq(name, "name")) return .{ .string = try chunk.internStr(nt.name) };
    if (common.streq(name, "first")) {
        if (!nt.has_range) return error.TypeError;
        return try vmtyp.makeNamedValue(obj, if (nt.base == .float) .{ .float = nt.min } else .{ .int = @intFromFloat(nt.min) });
    }
    if (common.streq(name, "last")) {
        if (!nt.has_range) return error.TypeError;
        return try vmtyp.makeNamedValue(obj, if (nt.base == .float) .{ .float = nt.max } else .{ .int = @intFromFloat(nt.max) });
    }
    if (common.streq(name, "succ") or common.streq(name, "pred")) {
        if (!nt.has_range) return error.TypeError;
        const fn_obj = try vmAllocObject();
        const kind: vmod.NamedTypeFnKind = if (common.streq(name, "succ")) .succ else .pred;
        fn_obj.* = .{ .named_type_fn = .{ .typ = obj, .kind = kind } };
        return .{ .object = fn_obj };
    }
    return error.UnknownStructField;
}

fn makeVariantArmValue(obj: *Object, vt: vmod.VariantTypeObj, arm_index: usize) !Value {
    const arm = vt.arms[arm_index];
    const has_shared = vt.shared_fields.len > 0;
    if (arm.has_payload or has_shared) {
        const ctor = try vmAllocObject();
        ctor.* = .{ .variant_ctor = .{
            .typ = obj,
            .tag = arm.name,
            .ordinal = arm_index,
            .payload_type = arm.payload_type,
        } };
        return .{ .object = ctor };
    }

    const vv = try vmAllocObject();
    vv.* = .{ .variant_value = .{
        .typ = obj,
        .tag = arm.name,
        .ordinal = arm_index,
        .payload = .null,
    } };
    return .{ .object = vv };
}

fn variantTypeFieldValue(obj: *Object, name: []const u8) !Value {
    const vt = obj.variant_type;
    if (common.streq(name, "name")) return .{ .string = try chunk.internStr(vt.name) };
    for (vt.arms, 0..) |arm, vi| {
        if (common.streq(arm.name, name)) return try makeVariantArmValue(obj, vt, vi);
    }
    return error.UnknownStructField;
}

fn variantValueFieldValue(vv: vmod.VariantValueObj, name: []const u8) !Value {
    const vt = vv.typ.variant_type;
    if (vmtyp.findFieldIndex(vt.shared_fields, name)) |idx| return vv.shared_values[idx];

    const arm = vt.arms[vv.ordinal];
    if (arm.fields.len > 0) {
        for (arm.fields, vv.arm_fields) |af, fv| {
            if (common.streq(af.name, name)) return fv;
        }
    } else if (arm.has_payload and common.streq(arm.payload_name, name)) {
        return vv.payload;
    }

    return error.TypeError;
}

const MethodResolution = struct {
    func: Value,
    pass_recv: bool,
};

fn resolveQualifiedReceiverMethod(qualified_name: []const u8, mname: []const u8) !Value {
    const total = qualified_name.len + 1 + mname.len;
    if (total > 512) return error.NotAMethodReceiver;
    var key_buf: [512]u8 = undefined;
    @memcpy(key_buf[0..qualified_name.len], qualified_name);
    key_buf[qualified_name.len] = '.';
    @memcpy(key_buf[qualified_name.len + 1 .. total], mname);
    return globals.get(key_buf[0..total]) orelse error.UnknownMethod;
}

fn resolveStructMethod(inst: vmod.StructInstanceObj, mname: []const u8) !MethodResolution {
    if (resolveQualifiedReceiverMethod(inst.typ.struct_type.qualified_name, mname)) |method_func| {
        return .{ .func = method_func, .pass_recv = true };
    } else |err| switch (err) {
        error.UnknownMethod => {
            const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, mname) orelse {
                if (isModuleNamespaceStruct(inst.typ)) return error.UnknownStructField;
                return error.UnknownMethod;
            };
            return .{ .func = inst.fields[fi].value, .pass_recv = false };
        },
        else => return err,
    }
}

fn resolveMapMethod(obj: *Object, mname: []const u8) !Value {
    const items = try vms.asMapSlice(obj);
    for (items) |e| {
        if (vms.isStringValue(e.key) and common.streq(try vms.asStringValue(e.key), mname)) return e.value;
    }
    return error.UnknownMethod;
}

fn resolveMethodReceiver(recv: Value, mname: []const u8) !MethodResolution {
    if (recv != .object) return error.NotAMethodReceiver;
    switch (recv.object.*) {
        .struct_instance => |inst| return try resolveStructMethod(inst, mname),
        .map, .map_managed, .map_hashed => {
            return .{ .func = try resolveMapMethod(recv.object, mname), .pass_recv = false };
        },
        .named_value => |nv| {
            var typ_obj: *Object = nv.typ;
            while (true) {
                const nt = switch (typ_obj.*) {
                    .named_type => |nt| nt,
                    else => return error.NotAMethodReceiver,
                };
                if (resolveQualifiedReceiverMethod(nt.qualified_name, mname)) |func| {
                    return .{ .func = func, .pass_recv = true };
                } else |err| switch (err) {
                    error.UnknownMethod => {
                        typ_obj = vmtyp.resolveParentType(typ_obj) orelse return error.UnknownMethod;
                    },
                    else => return err,
                }
            }
        },
        .enum_value => |ev| {
            return .{ .func = try resolveQualifiedReceiverMethod(ev.typ.enum_type.qualified_name, mname), .pass_recv = true };
        },
        .variant_value => |vv| {
            return .{ .func = try resolveQualifiedReceiverMethod(vv.typ.variant_type.qualified_name, mname), .pass_recv = true };
        },
        else => return error.NotAMethodReceiver,
    }
}

fn floatToIntSafe(n: f64) !i64 {
    if (!std.math.isFinite(n) or
        n < @as(f64, @floatFromInt(std.math.minInt(i64))) or
        n >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.RangeError;
    const t = @trunc(n);
    const as_i64: i64 = @intFromFloat(t);
    if (@as(f64, @floatFromInt(as_i64)) != t) return error.RangeError;
    return as_i64;
}

fn checkNamedTypePredicate(nt_obj: *Object, inner: Value) !void {
    if (comptime !build_options.predicates) return;
    if (!vmState().policy.enable_predicates) return;
    const nt = nt_obj.named_type;
    if (nt.predicate) |pred| {
        const result = callFunction(.{ .object = pred }, &[_]Value{inner}) catch |err| {
            if (err != error.PredicateFailed) {
                vms.setRuntimeErr("{s}: inside predicate for {s}", .{ @errorName(err), nt.name });
            }
            return err;
        };
        if (result != .boolean or !result.boolean) {
            var vbuf: [64]u8 = undefined;
            const vstr: []const u8 = switch (inner) {
                .int     => |n| std.fmt.bufPrint(&vbuf, "{d}", .{n}) catch "?",
                .float   => |n| std.fmt.bufPrint(&vbuf, "{d}", .{n}) catch "?",
                .decimal => |d| std.fmt.bufPrint(&vbuf, "{d}", .{d}) catch "?",
                .string  => |s| s.bytes,
                .boolean => |b| if (b) "true" else "false",
                .rune    => |r| blk: {
                    const n = std.unicode.utf8Encode(r, vbuf[0..4]) catch 0;
                    break :blk vbuf[0..n];
                },
                .object  => |o| if (o.* == .dyn_string) o.dyn_string else if (o.* == .string_view) o.string_view.bytes else "?",
                else     => "?",
            };
            if (nt.predicate_msg) |msg| {
                vms.setRuntimeErr("{s}({s}): {s}", .{ nt.name, vstr, msg });
            } else {
                vms.setRuntimeErr("predicate failed for {s}({s})", .{ nt.name, vstr });
            }
            // Expose the human-readable message via core.recover() by storing a
            // pointer into runtime_err_buf as pending_panic_message.  runPanicUnwind
            // skips the @memcpy-self when it detects the alias.
            vmState().pending_panic_message = vms.runtimeErrMsg();
            return error.PredicateFailed;
        }
    }
}

// Walk the parent chain and check each predicate in order (parent first).
fn checkNamedTypePredicateChain(nt_obj: *Object, inner: Value) !void {
    if (comptime !build_options.predicates) return;
    if (!vmState().policy.enable_predicates) return;
    // Collect all types in the chain from current to root.
    var chain: [16]*Object = undefined;
    var chain_len: usize = 0;
    var cur: ?*Object = nt_obj;
    while (cur) |t| {
        if (chain_len >= chain.len) break;
        chain[chain_len] = t;
        chain_len += 1;
        cur = vmtyp.resolveParentType(t);
    }
    // Evaluate from root to current (reverse order).
    var i: usize = chain_len;
    while (i > 0) : (i -= 1) {
        try checkNamedTypePredicate(chain[i - 1], inner);
    }
}

fn canReturnFast(fi: usize, retval: Value) bool {
    const frame = &vmState().frames[fi];
    if (vmState().defer_top != frame.defer_base) return false;
    if (!frame.has_typed_returns) return true;
    const f = switch (frame.func_obj.*) {
        .function => frame.func_obj.function,
        .closure => |cl| cl.func.function,
        else => return false,
    };
    if (!vmtyp.isPrimitiveReturn(f)) return false;
    return vmtyp.checkPrimitiveReturn(f, retval);
}

fn tryInlineGetGlobal() !void {
    const jip = vmState().ip;
    if (jip + 5 > chunk.codeLen() or chunk.codeByteAt(jip) != @intFromEnum(Op.get_global)) return;
    const ic_slot: u16 = @intCast((@as(usize, chunk.codeByteAt(jip + 3)) << 8) | chunk.codeByteAt(jip + 4));
    if (ic_slot != 0xffff) {
        vmState().ip += 5;
        try vmPush(globals.getAt(ic_slot));
    }
}

fn doReturn(retval: Value) !bool {
    const fi = vmState().frame_top - 1;
    if (canReturnFast(fi, retval)) {
        try doReturnFast(fi, retval);
        if (vmState().call_depth_target) |d| {
            if (vmState().frame_top == d) return true;
        }
        return false;
    }
    return try retSlowPath(retval);
}

fn doReturnFast(fi: usize, retval: Value) !void {
    const frame = &vmState().frames[fi];
    vmState().frame_top = fi;
    vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
    vmState().ip = frame.ret_ip;
    try vmPush(retval);
}

fn readUpvalueCell(idx: usize) !*Object {
    if (vmState().frame_top == 0) return error.StackUnderflow;
    const frame = vmState().frames[vmState().frame_top - 1];
    const cl = frame.closure orelse return error.TypeError;
    if (cl.* != .closure) return error.TypeError;
    if (idx >= cl.closure.upvalues.len) return error.TypeError;
    return cl.closure.upvalues[idx];
}

// Warm call path: IC confirmed same callee — skip arity/variadic/typed-param checks.
// Only reached for non-variadic, non-typed-param functions cached by performCallIC.
fn enterFunctionFrameWarm(f: @import("value.zig").FuncObj, func_obj: *Object, closure: ?*Object) !void {
    if (vmState().frame_top >= vmState().frames.len) return error.CallStackOverflow;
    vmState().frames[vmState().frame_top] = .{
        .ret_ip = vmState().ip,
        .base = vmState().stack_top - f.arity,
        .closure = closure,
        .func_obj = func_obj,
        .defer_base = vmState().defer_top,
        .has_typed_returns = f.has_typed_returns,
    };
    vmState().frame_top += 1;
    vmState().ip = f.ip;
}

fn enterFunctionFrame(f: @import("value.zig").FuncObj, func_obj: *Object, closure: ?*Object, argc: u8) !void {
    if (f.is_variadic) {
        if (argc < f.arity - 1) {
            var sig_buf: [256]u8 = undefined;
            const sig = vmtyp.funcSignatureStr(&sig_buf, f);
            if (f.name.len > 0) { vms.setRuntimeErr("{s}: expected at least {} argument(s), got {} for {s}", .{ f.name, f.arity - 1, argc, sig }); } else { vms.setRuntimeErr("expected at least {} argument(s), got {} for {s}", .{ f.arity - 1, argc, sig }); }
            return error.ArityMismatch;
        }
    } else if (f.arity != argc) {
        var sig_buf: [256]u8 = undefined;
        const sig = vmtyp.funcSignatureStr(&sig_buf, f);
        if (f.name.len > 0) { vms.setRuntimeErr("{s}: expected {} argument(s), got {} for {s}", .{ f.name, f.arity, argc, sig }); } else { vms.setRuntimeErr("expected {} argument(s), got {} for {s}", .{ f.arity, argc, sig }); }
        return error.ArityMismatch;
    }
    if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
    try prepareVariadicCall(f, argc);
    if (vmState().frame_top >= vmState().frames.len) return error.CallStackOverflow;
    vmState().frames[vmState().frame_top] = .{
        .ret_ip = vmState().ip,
        .base = vmState().stack_top - f.arity,
        .closure = closure,
        .func_obj = func_obj,
        .defer_base = vmState().defer_top,
        .has_typed_returns = f.has_typed_returns,
    };
    vmState().frame_top += 1;
    vmState().ip = f.ip;
}

inline fn pop2push1(v: Value) !void {
    _ = try vmPop();
    _ = try vmPop();
    try vmPush(v);
}

fn performCallIC(argc: u8, ic_base: usize, ic_slot: u16) !void {
    if (vmState().stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const func_val = vmState().stack[vmState().stack_top - argc - 1];
    if (func_val == .object) {
        const obj = func_val.object;
        const obj_idx = heap.objectPoolIndex(obj);
        if (ic_slot != 0xFFFF and obj_idx == ic_slot) {
            return switch (obj.*) {
                .function => |f| enterFunctionFrameWarm(f, obj, null),
                .closure  => |cl| enterFunctionFrameWarm(cl.func.function, cl.func, obj),
                else      => performCall(argc),
            };
        }
        try performCall(argc);
        if (ic_slot == 0xFFFF and obj_idx != 0xFFFF) {
            switch (obj.*) {
                .function => |f| if (!f.is_variadic and !f.has_typed_params) {
                    chunk.patchByte(ic_base,     @intCast((obj_idx >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(obj_idx & 0xFF));
                },
                .closure => |cl| if (!cl.func.function.is_variadic and !cl.func.function.has_typed_params) {
                    chunk.patchByte(ic_base,     @intCast((obj_idx >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(obj_idx & 0xFF));
                },
                else => {},
            }
        }
        return;
    }
    return performCall(argc);
}

fn performCall(argc: u8) !void {
    if (vmState().stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const func_val = vmState().stack[vmState().stack_top - argc - 1];
    if (func_val != .object) return error.NotAFunction;
    const obj = func_val.object;
    switch (obj.*) {
        .function => |f| {
            try enterFunctionFrame(f, obj, null, argc);
        },
        .closure => |cl| {
            try enterFunctionFrame(cl.func.function, cl.func, obj, argc);
        },
        .native_function => |nf| {
            try vmnative.callNative(nf, argc);
        },
        .host_module_function => |hmf| {
            try vmnative.callHostModule(hmf, argc);
        },
        .named_type => {
            if (argc != 1) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try vmtyp.constructNamedType(obj, arg);
            try checkNamedTypePredicateChain(obj, out.object.named_value.value);
            try pop2push1(out);
        },
        .enum_type => |et| {
            if (et.parent_name == null) return error.NotAFunction;
            if (argc != 1) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            if (arg != .object or arg.object.* != .enum_value) return error.TypeError;
            const parent_obj = vmtyp.resolveEnumParent(obj) orelse return error.TypeError;
            if (arg.object.enum_value.typ != parent_obj) return error.TypeError;
            var found = false;
            for (et.members) |m| {
                if (common.streq(m, arg.object.enum_value.name)) { found = true; break; }
            }
            if (!found) return error.RangeError;
            try pop2push1(arg);
        },
        .variant_ctor => |vc| {
            if (argc != 1) return error.ArityMismatch;
            const payload = vmState().stack[vmState().stack_top - 1];
            if (vc.payload_type) |pt| {
                if (!vmtyp.matchesTypeSpec(payload, pt)) return error.TypeError;
            }
            const vv = try vmAllocObject();
            vv.* = .{ .variant_value = .{
                .typ = vc.typ,
                .tag = vc.tag,
                .ordinal = vc.ordinal,
                .payload = payload,
            }};
            try pop2push1(.{ .object = vv });
        },
        .named_type_fn => |nf| {
            if (argc != 1) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try vmtyp.applyNamedTypeFn(nf.typ, nf.kind, arg);
            try pop2push1(out);
        },
        else => return error.NotAFunction,
    }
}

fn writeFrameLocal(abs_slot: usize, v: Value) void {
    std.debug.assert(abs_slot < vmState().stack.len);
    const cur = vmState().stack[abs_slot];
    if (cur == .object and cur.object.* == .cell) {
        cur.object.cell.value = v;
    } else {
        vmState().stack[abs_slot] = v;
    }
}

fn tryTailCall(argc: u8) !bool {
    if (vmState().frame_top == 0) return false;
    if (vmState().ip >= chunk.codeLen()) return false;
    const next_op: Op = @enumFromInt(chunk.codeByteAt(vmState().ip));
    if (next_op != .ret) return false;

    if (vmState().stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const callee_idx = vmState().stack_top - argc - 1;
    const func_val = vmState().stack[callee_idx];
    if (func_val != .object) return false;
    const callee_obj = func_val.object;

    const frame_idx = vmState().frame_top - 1;
    const frame = &vmState().frames[frame_idx];
    const f_obj: *Object, const closure: ?*Object, const f = switch (callee_obj.*) {
        .closure => |cl| .{ cl.func, callee_obj, cl.func.function },
        .function => |f| .{ callee_obj, null, f },
        else => return false,
    };
    if (f.is_variadic) return false;
    if (f.arity != argc) return false;
    if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
    for (0..argc) |i| writeFrameLocal(frame.base + i, vmState().stack[callee_idx + 1 + i]);
    frame.closure = closure;
    frame.func_obj = f_obj;
    vmState().stack_top = frame.base + argc;
    vmState().ip = f.ip;
    return true;
}

fn iterInit(v: Value) !Value {
    const obj = try vmAllocObject();
    const iv = vms.unboxNamed(v);
    switch (iv) {
        .object => |o| switch (o.*) {
            .dyn_string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s, .string_managed = true, .source = o } },
            .string_view => |sv| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = sv.bytes, .string_managed = true, .source = sv.source } },
            .array, .array_managed, .array_capacity => obj.* = .{ .iterator = .{ .kind = .array, .index = 0, .array = try vms.asArraySlice(o), .source = o } },
            .map, .map_managed, .map_hashed => obj.* = .{ .iterator = .{ .kind = .map, .index = 0, .map = try vms.asMapSlice(o), .source = o } },
            .named_type => |nt| {
                if (!nt.has_range) return error.TypeError;
                obj.* = .{ .iterator = .{ .kind = .range, .index = 0, .range_current = nt.min, .range_max = nt.max, .source = o } };
            },
            else => return error.TypeError,
        },
        .string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s.bytes, .string_managed = false } },
        else => return error.TypeError,
    }
    return .{ .object = obj };
}

fn iterAdvance(cond: bool) !bool {
    if (!cond) {
        try vmPush(.{ .boolean = false });
        return false;
    }
    return true;
}

fn iterNext1(it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (!try iterAdvance(it.index < it.array.len)) return;
            const v = it.array[it.index];
            it.index += 1;
            try vmPush(v);
            try vmPush(.{ .boolean = true });
        },
        .string => {
            if (!try iterAdvance(it.index < it.string.len)) return;
            const ridx = it.rune_index;
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            if (it.string_managed) {
                try vmPush(try makeStringView(it.string[start..end], it.source.?));
            } else {
                try vmPush(try makeDynString(it.string[start..end]));
            }
            it.index = end;
            it.rune_index += 1;
            try vmPush(.{ .boolean = true });
        },
        .map => {
            if (!try iterAdvance(it.index < it.map.len)) return;
            const k = it.map[it.index].key;
            it.index += 1;
            try vmPush(k);
            try vmPush(.{ .boolean = true });
        },
        .range => {
            if (it.range_current > it.range_max) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const typ_obj = it.source.?;
            const nt = typ_obj.named_type;
            const val = try vmtyp.makeNamedValue(typ_obj, if (nt.base == .float) .{ .float = it.range_current } else .{ .int = @intFromFloat(it.range_current) });
            const next = it.range_current + 1.0;
            if (next == it.range_current) return error.RangeError;
            it.range_current = next;
            try vmPush(val);
            try vmPush(.{ .boolean = true });
        },
    }
}

fn iterNext2(it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (!try iterAdvance(it.index < it.array.len)) return;
            try vmPush(.{ .int = @intCast(it.index) });
            try vmPush(it.array[it.index]);
            it.index += 1;
            try vmPush(.{ .boolean = true });
        },
        .string => {
            if (!try iterAdvance(it.index < it.string.len)) return;
            const ridx = it.rune_index;
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            try vmPush(.{ .int = @intCast(it.rune_index) });
            if (it.string_managed) {
                try vmPush(try makeStringView(it.string[start..end], it.source.?));
            } else {
                try vmPush(try makeDynString(it.string[start..end]));
            }
            it.index = end;
            it.rune_index += 1;
            try vmPush(.{ .boolean = true });
        },
        .map => {
            if (!try iterAdvance(it.index < it.map.len)) return;
            try vmPush(it.map[it.index].key);
            try vmPush(it.map[it.index].value);
            it.index += 1;
            try vmPush(.{ .boolean = true });
        },
        .range => return error.TypeError,
    }
}

// Slow-path return: handles defers and/or typed-return enforcement.
// Returns true if runInner should stop (call_depth_target reached), false to continue.
// Fast-path returns (no defers, no typed returns) are inlined in the ret/ret_const handlers.
fn retSlowPath(retval_in: Value) !bool {
    var retval = retval_in;
    const fi = vmState().frame_top - 1;
    const frame = &vmState().frames[fi];
    const saved_temp_root = vmState().temp_root_top;
    defer vmState().temp_root_top = saved_temp_root;
    try pushTempRoot(retval);
    while (vmState().defer_top > frame.defer_base) {
        vmState().defer_top -= 1;
        const deferred = vmState().defer_stack[vmState().defer_top];
        try pushTempRoot(deferred);
        const arr = try vms.asArraySlice(deferred.object);
        if (arr.len > 0) {
            if (arr.len > 256) return error.ArityMismatch;
            const dargc: u8 = @intCast(arr.len - 1);
            for (arr) |v| try vmPush(v);
            const depth_before = vmState().frame_top;
            try performCall(dargc);
            if (vmState().frame_top > depth_before) {
                const prev_target = vmState().call_depth_target;
                vmState().call_depth_target = depth_before;
                defer vmState().call_depth_target = prev_target;
                try run();
            }
            _ = try vmPop();
        }
        popTempRoot();
    }
    const fsig_ret = vmtyp.frameFuncSig(frame.func_obj) catch null;
    if (fsig_ret) |fsig| {
        if (fsig.named_return_count > 0) {
            popTempRoot();
            const nrbase = frame.base + fsig.arity;
            if (nrbase >= vmState().stack.len) return error.StackOverflow;
            if (fsig.named_return_count == 1) {
                const raw = vmState().stack[nrbase];
                retval = vms.unboxCell(raw);
            } else {
                const nrc: usize = fsig.named_return_count;
                const arr_obj = try vmAllocObject();
                arr_obj.* = .{ .array = &[_]Value{} };
                try pushTempRoot(.{ .object = arr_obj });
                const items = try vmAllocManagedSlice(Value, nrc);
                for (0..nrc) |ri| {
                    if (nrbase + ri >= vmState().stack.len) return error.StackOverflow;
                    const raw = vmState().stack[nrbase + ri];
                    items[ri] = vms.unboxCell(raw);
                }
                arr_obj.* = .{ .array_managed = items[0..nrc] };
                popTempRoot();
                retval = .{ .object = arr_obj };
            }
            try pushTempRoot(retval);
        }
    }
    popTempRoot();
    vmState().frame_top = fi;
    if (frame.has_typed_returns) {
        if (fsig_ret) |fsig| try vmtyp.enforceFuncReturnTypes(fsig, retval);
    }
    vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
    vmState().ip = frame.ret_ip;
    try vmPush(retval);
    if (vmState().call_depth_target) |d| {
        if (vmState().frame_top == d) return true;
    }
    return false;
}

// ── Large opcode handlers (extracted from runInner for readability) ──────────

fn pushFieldFromObject(obj: *Object, name_idx: usize, ic_base: usize, ic_type_idx: usize, ic_fidx: u8) !void {
    const name = (try chunk.constAt(name_idx)).string.bytes;
    switch (obj.*) {
        .array, .array_managed, .array_capacity => {
            const items = try vms.asArraySlice(obj);
            if (common.streq(name, "first")) {
                if (items.len == 0) return error.IndexOutOfBounds;
                try vmPush(items[0]);
            } else if (common.streq(name, "last")) {
                if (items.len == 0) return error.IndexOutOfBounds;
                try vmPush(items[items.len - 1]);
            } else return error.TypeError;
        },
        .struct_instance => |inst| {
            const tpi = heap.objectPoolIndex(inst.typ);
            if (ic_type_idx == @as(usize, tpi) and ic_fidx != 0xFF) {
                try vmPush(inst.fields[ic_fidx].value);
            } else {
                const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, name) orelse {
                    vms.setRuntimeErr("no field '{s}' on type '{s}'", .{ name, inst.typ.struct_type.name });
                    return error.UnknownStructField;
                };
                if (fi <= 0xFE) {
                    chunk.patchByte(ic_base,     @intCast((tpi >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                    chunk.patchByte(ic_base + 2, @intCast(fi));
                }
                try vmPush(inst.fields[fi].value);
            }
        },
        .map, .map_managed => {
            const items = try vms.asMapSlice(obj);
            if (common.streq(name, "len")) {
                try vmPush(.{ .int = @intCast(items.len) });
            } else {
                var name_ss = StringSlice{ .bytes = name };
                const key_v = Value{ .string = &name_ss };
                try vmPush(if (vmmap.mapFindLinear(items, key_v)) |fi| items[fi].value else .null);
            }
        },
        .map_hashed => |hm| {
            if (common.streq(name, "len")) {
                try vmPush(.{ .int = @intCast(hm.len) });
            } else {
                var name_ss = StringSlice{ .bytes = name };
                const key_v = Value{ .string = &name_ss };
                if (vmmap.mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key_v)) |fi| {
                    try vmPush(hm.entries[fi].value);
                } else {
                    try vmPush(.null);
                }
            }
        },
        .enum_type => try vmPush(try enumTypeFieldValue(obj, name)),
        .named_type => try vmPush(try namedTypeFieldValue(obj, name)),
        .variant_type => try vmPush(try variantTypeFieldValue(obj, name)),
        .variant_value => |vv| try vmPush(try variantValueFieldValue(vv, name)),
        else => return error.TypeError,
    }
}

fn opGetLocalGetField() !void {
    const slot = try vmByte();
    vmState().ip += 1; // skip embedded get_field opcode byte
    const name_idx = try vmShort();
    const ic_base = vmState().ip;
    const ic_type_idx = try vmShort();
    const ic_fidx = try vmByte();
    const raw = try readLocalSlot(slot);
    const container = vms.unboxNamed(raw);
    if (container != .object) return error.TypeError;
    try pushFieldFromObject(container.object, name_idx, ic_base, ic_type_idx, ic_fidx);
}

fn opGetIndex() !void {
    const idx_v = try vmPop();
    const raw = try vmPop();
    var rooted_raw = false;
    var rooted_idx = false;
    if (raw == .object) { try pushTempRoot(raw); rooted_raw = true; }
    if (idx_v == .object) { try pushTempRoot(idx_v); rooted_idx = true; }
    defer {
        if (rooted_idx) popTempRoot();
        if (rooted_raw) popTempRoot();
    }
    const container = vms.unboxNamed(raw);
    switch (container) {
        .object => |obj| switch (obj.*) {
            .dyn_string, .string_view => {
                const bytes = if (obj.* == .dyn_string) obj.dyn_string else obj.string_view.bytes;
                const src = if (obj.* == .dyn_string) obj else obj.string_view.source;
                const ridx = try vms.vmIndexFromVal(idx_v);
                const start = try vmstr.utf8ByteOffsetForRuneIndexCached(bytes, ridx);
                const w = try vmstr.utf8NextRuneByteLen(bytes, start);
                try vmPush(try makeStringView(bytes[start .. start + w], src));
            },
            .array, .array_managed, .array_capacity => {
                const items = try vms.asArraySlice(obj);
                const idx = try vms.vmIndexFromVal(idx_v);
                if (idx >= items.len) {
                    vms.setRuntimeErr("index {} out of bounds for array of length {}", .{ idx, items.len });
                    return error.IndexOutOfBounds;
                }
                try vmPush(items[idx]);
            },
            .map, .map_managed => {
                const items = try vms.asMapSlice(obj);
                try vmPush(if (vmmap.mapFindLinear(items, idx_v)) |fi| items[fi].value else .null);
            },
            .map_hashed => |hm| {
                if (vmmap.mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, idx_v)) |fi| {
                    try vmPush(hm.entries[fi].value);
                } else {
                    try vmPush(.null);
                }
            },
            .struct_instance => |inst| {
                const key = try vms.asStringValue(idx_v);
                const idx = vmtyp.findFieldIndex(inst.typ.struct_type.fields, key) orelse return error.UnknownStructField;
                try vmPush(inst.fields[idx].value);
            },
            .enum_type => {
                try vmPush(try enumTypeFieldValue(obj, try vms.asStringValue(idx_v)));
            },
            .named_type => {
                try vmPush(try namedTypeFieldValue(obj, try vms.asStringValue(idx_v)));
            },
            .variant_type => {
                try vmPush(try variantTypeFieldValue(obj, try vms.asStringValue(idx_v)));
            },
            .variant_value => |vv| {
                const key = try vms.asStringValue(idx_v);
                try vmPush(try variantValueFieldValue(vv, key));
            },
            else => return error.TypeError,
        },
        .string => |s| {
            const ridx = try vms.vmIndexFromVal(idx_v);
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(s.bytes, ridx);
            const w = try vmstr.utf8NextRuneByteLen(s.bytes, start);
            try vmPush(try makeDynString(s.bytes[start .. start + w]));
        },
        else => return error.TypeError,
    }
}

fn opSetIndex() !void {
    const val = try vmPop();
    const idx_v = try vmPop();
    const raw_c = try vmPop();
    // Unbox named collection; enforce element/key/value type constraints
    const is_named_c = raw_c == .object and raw_c.object.* == .named_value;
    const container = if (is_named_c) raw_c.object.named_value.value else raw_c;
    if (is_named_c) {
        const nv = raw_c.object.named_value;
        if (nv.typ.* == .named_type) {
            const nt = nv.typ.named_type;
            if (nt.base == .array_t) {
                if (nt.elem_spec) |es| {
                    if (!vmtyp.matchesTypeSpec(val, es)) return error.TypeError;
                }
            } else if (nt.base == .map_t) {
                if (nt.key_spec) |ks| {
                    if (!vmtyp.matchesTypeSpec(idx_v, ks)) return error.TypeError;
                }
                if (nt.val_spec) |vs| {
                    if (!vmtyp.matchesTypeSpec(val, vs)) return error.TypeError;
                }
            }
        }
    }
    if (container != .object) return error.TypeError;
    switch (container.object.*) {
        .array, .array_managed, .array_capacity => {
            const items = try vms.asArraySlice(container.object);
            const idx = try vms.vmIndexFromVal(idx_v);
            if (idx >= items.len) {
                vms.setRuntimeErr("index {} out of bounds for array of length {}", .{ idx, items.len });
                return error.IndexOutOfBounds;
            }
            items[idx] = val;
        },
        .map, .map_managed => try mapLinearInsertOrAppend(container, idx_v, val),
        .map_hashed => try vmmap.mapInsertHashed(container.object, idx_v, val),
        .struct_instance => |inst| {
            const key = try vms.asStringValue(idx_v);
            const idx = vmtyp.findFieldIndex(inst.typ.struct_type.fields, key) orelse {
                vms.setRuntimeErr("no field '{s}' on type '{s}'", .{ key, inst.typ.struct_type.name });
                return error.UnknownStructField;
            };
            if (inst.typ.struct_type.fields[idx].is_const) { vms.setRuntimeErr("field '{s}' of '{s}' is const", .{ key, inst.typ.struct_type.name }); return error.AssignToConst; }
            if (!vmtyp.matchesFieldType(val, inst.typ.struct_type.fields[idx])) return error.StructFieldTypeMismatch;
            inst.fields[idx].value = val;
        },
        else => return error.TypeError,
    }
}

fn opInvokeMethod() !void {
    const mname = (try vmConst()).string.bytes;
    const argc = try vmByte();
    const ic_base = vmState().ip;
    const ic_type_idx = try vmShort(); // ic_type pool index (0xFFFF = cold)
    const ic_func_idx = try vmShort(); // ic_func pool index (0xFFFF = cold)
    if (vmState().stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const recv_idx = vmState().stack_top - argc - 1;
    const recv = vmState().stack[recv_idx];
    if (recv != .object) return error.NotAMethodReceiver;
    switch (recv.object.*) {
        .struct_instance => |inst| {
            const tpi = heap.objectPoolIndex(inst.typ);
            var resolved: MethodResolution = undefined;
            if (ic_type_idx == @as(usize, tpi) and ic_func_idx != 0xFFFF) {
                if (ic_func_idx >= heap.MaxObjects) return error.NotAMethodReceiver;
                resolved = .{ .func = .{ .object = heap.objectAt(@intCast(ic_func_idx)) }, .pass_recv = true };
            } else {
                resolved = try resolveStructMethod(inst, mname);
                if (resolved.pass_recv and resolved.func == .object) {
                    const fpi = heap.objectPoolIndex(resolved.func.object);
                    if (fpi != 0xFFFF) {
                        chunk.patchByte(ic_base + 0, @intCast((tpi >> 8) & 0xFF));
                        chunk.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                        chunk.patchByte(ic_base + 2, @intCast((fpi >> 8) & 0xFF));
                        chunk.patchByte(ic_base + 3, @intCast(fpi & 0xFF));
                    }
                }
            }
            if (resolved.pass_recv) {
                try insertReceiverAndCall(recv_idx, resolved.func, recv, argc);
            } else {
                vmState().stack[recv_idx] = resolved.func;
                try performCall(argc);
            }
        },
        .map, .map_managed, .map_hashed => {
            const resolved = try resolveMethodReceiver(recv, mname);
            vmState().stack[recv_idx] = resolved.func;
            try performCall(argc);
        },
        .variant_type => |vt| {
            const vi = for (vt.arms, 0..) |arm, i| {
                if (common.streq(arm.name, mname)) break i;
            } else return error.UnknownStructField;
            const arm = vt.arms[vi];
            if (arm.has_payload) {
                if (argc != 1) return error.ArityMismatch;
                const payload = vmState().stack[vmState().stack_top - 1];
                if (arm.payload_type) |pt| {
                    if (!vmtyp.matchesTypeSpec(payload, pt)) return error.TypeError;
                }
                const vv = try vmAllocObject();
                vv.* = .{ .variant_value = .{ .typ = recv.object, .tag = arm.name, .ordinal = vi, .payload = payload } };
                for (0..@as(usize, argc) + 1) |_| _ = try vmPop();
                try vmPush(.{ .object = vv });
            } else {
                if (argc != 0) return error.ArityMismatch;
                const vv = try vmAllocObject();
                vv.* = .{ .variant_value = .{ .typ = recv.object, .tag = arm.name, .ordinal = vi, .payload = .null } };
                _ = try vmPop(); // pop recv
                try vmPush(.{ .object = vv });
            }
        },
        .named_type => {
            if (argc != 1) return error.ArityMismatch;
            if (!common.streq(mname, "succ") and !common.streq(mname, "pred")) return error.UnknownMethod;
            const kind: @import("value.zig").NamedTypeFnKind = if (common.streq(mname, "succ")) .succ else .pred;
            const arg = vmState().stack[recv_idx + 1];
            const out = try vmtyp.applyNamedTypeFn(recv.object, kind, arg);
            if (recv_idx >= vmState().stack_top) return error.StackUnderflow;
            vmState().stack_top = recv_idx;
            try vmPush(out);
        },
        .string_builder => |*sb| {
            if (common.streq(mname, "write")) {
                if (argc != 1) return error.ArityMismatch;
                const s_bytes = try vms.asStringValue(vmState().stack[recv_idx + 1]);
                const needed = sb.len + s_bytes.len;
                if (needed > sb.buf.len) {
                    // Grow: receiver stays on stack so GC keeps the object alive.
                    const new_buf = try vmgc.vmAllocManagedBytes(needed);
                    @memcpy(new_buf[0..sb.len], sb.buf[0..sb.len]);
                    heap.freeBytesManaged(sb.buf);
                    sb.buf = new_buf;
                }
                @memcpy(sb.buf[sb.len..][0..s_bytes.len], s_bytes);
                sb.len = needed;
                if (recv_idx >= vmState().stack_top) return error.StackUnderflow;
                vmState().stack_top = recv_idx;
                try vmPush(.null);
            } else if (common.streq(mname, "str")) {
                if (argc != 0) return error.ArityMismatch;
                const result = try makeDynString(sb.buf[0..sb.len]);
                if (recv_idx >= vmState().stack_top) return error.StackUnderflow;
                vmState().stack_top = recv_idx;
                try vmPush(result);
            } else if (common.streq(mname, "reset")) {
                if (argc != 0) return error.ArityMismatch;
                sb.len = 0;
                if (recv_idx >= vmState().stack_top) return error.StackUnderflow;
                vmState().stack_top = recv_idx;
                try vmPush(.null);
            } else return error.UnknownMethod;
        },
        .named_value, .enum_value, .variant_value => {
            const resolved = try resolveMethodReceiver(recv, mname);
            try insertReceiverAndCall(recv_idx, resolved.func, recv, argc);
        },
        .array, .array_managed, .array_capacity => {
            if (argc != 0) return error.ArityMismatch;
            const items = try vms.asArraySlice(recv.object);
            if (common.streq(mname, "first")) {
                if (items.len == 0) return error.IndexOutOfBounds;
                vmState().stack_top = recv_idx;
                try vmPush(items[0]);
            } else if (common.streq(mname, "last")) {
                if (items.len == 0) return error.IndexOutOfBounds;
                vmState().stack_top = recv_idx;
                try vmPush(items[items.len - 1]);
            } else return error.UnknownMethod;
        },
        else => return error.NotAMethodReceiver,
    }
}

fn opGetField() !void {
    const name_idx = try vmShort();
    const ic_base = vmState().ip;
    const ic_type_idx = try vmShort();
    const ic_fidx = try vmByte();
    const raw = try vmPop();
    var rooted_raw = false;
    if (raw == .object) { try pushTempRoot(raw); rooted_raw = true; }
    defer if (rooted_raw) popTempRoot();
    const container = vms.unboxNamed(raw);
    if (container != .object) return error.TypeError;
    try pushFieldFromObject(container.object, name_idx, ic_base, ic_type_idx, ic_fidx);
}

fn opSetField() !void {
    const name_idx = try vmShort();
    const ic_base = vmState().ip;
    const ic_type_idx = try vmShort();
    const ic_fidx = try vmByte();
    const name_val = try chunk.constAt(name_idx);
    const name = name_val.string.bytes;
    const val = try vmPop();
    const raw_c = try vmPop();
    const is_named_c = raw_c == .object and raw_c.object.* == .named_value;
    const container = if (is_named_c) raw_c.object.named_value.value else raw_c;
    if (is_named_c) {
        const nv = raw_c.object.named_value;
        if (nv.typ.* == .named_type) {
            const nt = nv.typ.named_type;
            if (nt.base == .map_t) {
                if (nt.val_spec) |vs| {
                    if (!vmtyp.matchesTypeSpec(val, vs)) return error.TypeError;
                }
            }
        }
    }
    if (container != .object) return error.TypeError;
    switch (container.object.*) {
        .struct_instance => |inst| {
            const tpi = heap.objectPoolIndex(inst.typ);
            var fi: usize = undefined;
            if (ic_type_idx == @as(usize, tpi) and ic_fidx != 0xFF) {
                fi = ic_fidx;
            } else {
                const found = vmtyp.findFieldIndex(inst.typ.struct_type.fields, name) orelse {
                    vms.setRuntimeErr("no field '{s}' on type '{s}'", .{ name, inst.typ.struct_type.name });
                    return error.UnknownStructField;
                };
                fi = found;
                if (found <= 0xFE) {
                    chunk.patchByte(ic_base,     @intCast((tpi >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                    chunk.patchByte(ic_base + 2, @intCast(found));
                }
            }
            if (inst.typ.struct_type.fields[fi].is_const) { vms.setRuntimeErr("field '{s}' of '{s}' is const", .{ name, inst.typ.struct_type.name }); return error.AssignToConst; }
            if (!vmtyp.matchesFieldType(val, inst.typ.struct_type.fields[fi])) return error.StructFieldTypeMismatch;
            inst.fields[fi].value = val;
        },
        .map, .map_managed => try mapLinearInsertOrAppend(container, name_val, val),
        .map_hashed => try vmmap.mapInsertHashed(container.object, name_val, val),
        else => return error.TypeError,
    }
}

fn insertReceiverAndCall(recv_idx: usize, func: Value, recv: Value, argc: u8) !void {
    if (vmState().stack_top >= vmState().stack.len) return error.StackOverflow;
    var i: usize = vmState().stack_top;
    while (i > recv_idx + 1) : (i -= 1) vmState().stack[i] = vmState().stack[i - 1];
    vmState().stack_top += 1;
    vmState().stack[recv_idx] = func;
    vmState().stack[recv_idx + 1] = recv;
    try performCall(argc + 1);
}

fn mapLinearInsertOrAppend(container: Value, key: Value, val: Value) !void {
    const items = try vms.asMapSlice(container.object);
    if (vmmap.mapFindLinear(items, key)) |fi| {
        items[fi].value = val;
        return;
    }
    try pushTempRoot(container);
    defer popTempRoot();
    const new_len = items.len + 1;
    const ext = try vmAllocManagedSlice(MapEntry, new_len);
    @memcpy(ext[0..items.len], items);
    ext[items.len] = .{ .key = key, .value = val };
    if (container.object.* == .map_managed) heap.freeManagedSlice(MapEntry, container.object.map_managed);
    container.object.* = .{ .map_managed = ext[0..new_len] };
    if (new_len > 8) {
        const bcount = vmmap.mapBucketsForCount(new_len);
        const buckets = try vmAllocManagedSlice(i32, bcount);
        vmmap.mapBuildHashedBuckets(ext[0..new_len], buckets);
        container.object.* = .{ .map_hashed = .{ .entries = ext[0..new_len], .len = new_len, .buckets = buckets } };
    }
}

fn opDeferInvokeMethod() !void {
    const mname = (try vmConst()).string.bytes;
    const argc = try vmByte();
    if (vmState().defer_top >= vmState().defer_stack.len) return error.DeferStackOverflow;
    if (vmState().stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const recv_idx = vmState().stack_top - @as(usize, argc) - 1;
    const recv = vmState().stack[recv_idx];
    var func: Value = undefined;
    var pass_recv: bool = undefined;
    switch (recv.object.*) {
        .struct_instance, .map, .map_managed, .map_hashed, .named_value, .enum_value, .variant_value => {
            const resolved = try resolveMethodReceiver(recv, mname);
            func = resolved.func;
            pass_recv = resolved.pass_recv;
        },
        else => return error.NotAMethodReceiver,
    }
    const extra: usize = if (pass_recv) 1 else 0;
    const total: usize = 1 + extra + @as(usize, argc);
    const arr_obj = try vmAllocObject();
    try pushTempRoot(.{ .object = arr_obj });
    defer popTempRoot();
    const items = try vmAllocManagedSlice(Value, total);
    items[0] = func;
    if (pass_recv) items[1] = recv;
    @memcpy(items[1 + extra .. 1 + extra + @as(usize, argc)], vmState().stack[recv_idx + 1 .. recv_idx + 1 + @as(usize, argc)]);
    arr_obj.* = .{ .array_managed = items[0..total] };
    vmState().defer_stack[vmState().defer_top] = .{ .object = arr_obj };
    vmState().defer_top += 1;
    vmState().stack_top = recv_idx;
}

fn writeGlobalIC(name_idx: usize, ic_base: usize, ic_slot: u16, val: Value) !void {
    if (ic_slot != 0xFFFF) {
        globals.setAt(ic_slot, val);
    } else {
        const name = (try chunk.constAt(name_idx)).string.bytes;
        const slot = globals.findSlot(name) orelse {
            vms.setRuntimeErr("'{s}' is not defined", .{name});
            return error.NotDefined;
        };
        chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
        chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
        globals.setAt(slot, val);
    }
}

fn stringSliceRange(s: []const u8, has_start: bool, start_v: Value, has_end: bool, end_v: Value) !struct { start_b: usize, end_b: usize } {
    const rune_len = try vmstr.utf8RuneCountCached(s);
    const start_r: usize = if (has_start) try vms.vmSliceIndex(start_v, rune_len) else 0;
    const end_r: usize = if (has_end) try vms.vmSliceIndex(end_v, rune_len) else rune_len;
    if (start_r > end_r) return error.IndexOutOfBounds;
    return .{
        .start_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, start_r),
        .end_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, end_r),
    };
}

fn readGlobalIC(name_idx: usize, ic_base: usize, ic_slot: u16) !Value {
    if (ic_slot != 0xFFFF) return globals.getAt(ic_slot);
    const name = (try chunk.constAt(name_idx)).string.bytes;
    const slot = globals.findSlot(name) orelse {
        const suggestion = findSimilarName(name);
        if (suggestion) |s| {
            vms.setRuntimeErr("'{s}' is not defined; did you mean '{s}'?", .{ name, s });
        } else {
            vms.setRuntimeErr("'{s}' is not defined", .{name});
        }
        return error.NotDefined;
    };
    chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
    chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
    return globals.getAt(slot);
}

inline fn vmFrameBase() usize {
    return if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
}

fn readLocalSlot(slot: usize) !Value {
    const base = vmFrameBase();
    if (base + slot >= vmState().stack.len) return error.StackOverflow;
    var v = vmState().stack[base + slot];
    if (v == .object and v.object.* == .cell) v = v.object.cell.value;
    return v;
}

fn readGlobalConstPair() !struct { g: Value, k: Value } {
    const name_idx = try vmShort();
    const ic_base = vmState().ip;
    const ic_slot: u16 = @intCast(try vmShort());
    vmState().ip += 1; // skip embedded const opcode byte
    const k = try chunk.constAt(try vmShort());
    return .{ .g = try readGlobalIC(name_idx, ic_base, ic_slot), .k = k };
}

fn readLocalSlotAndConst() !struct { slot: u8, k: Value } {
    const slot = try vmByte();
    vmState().ip += 1; // skip embedded const opcode byte
    return .{ .slot = slot, .k = try chunk.constAt(try vmShort()) };
}

fn runInner() !void {
    while (true) {
        if (vmState().ops_budget_remaining < std.math.maxInt(u64)) {
            if (vmState().ops_budget_remaining == 0) return error.InstructionBudgetExceeded;
            vmState().ops_budget_remaining -= 1;
        }
        const op_raw = try vmByte();
        if (op_raw >= std.meta.fields(Op).len) return error.BadOpcode;
        vmperf.countOp(op_raw);
        const op: Op = @enumFromInt(op_raw);
        switch (op) {
            .constant => try vmPush(try vmConst()),
            .null_val => try vmPush(.null),
            .true_val => try vmPush(.{ .boolean = true }),
            .false_val => try vmPush(.{ .boolean = false }),
            .dup => try vmPush(try vmPeek(0)),
            .dup2 => {
                try vmPush(try vmPeek(1));
                try vmPush(try vmPeek(1));
            },
            .pop => _ = try vmPop(),

            .repl_print => {
                const v = try vmPop();
                if (v != .null) {
                    io.printValue(v);
                    io.write("\n");
                }
            },

            .def_global => {
                const name = (try vmConst()).string.bytes;
                try globals.def(name, try vmPop());
            },
            .get_global => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                try vmPush(try readGlobalIC(name_idx, ic_base, ic_slot));
            },
            .set_global => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                try writeGlobalIC(name_idx, ic_base, ic_slot, try vmPop());
            },
            .inc_global_const => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                _ = try vmByte(); // skip add_skip byte
                const k = try chunk.constAt(try vmShort());
                if (ic_slot != 0xFFFF) {
                    const v = globals.getAt(ic_slot);
                    const result: Value = if (v == .int and k == .int) .{ .int = v.int + k.int } else try computeAddResult(v, k);
                    globals.setAt(ic_slot, result);
                } else {
                    const name = (try chunk.constAt(name_idx)).string.bytes;
                    const slot = globals.findSlot(name) orelse {
                        vms.setRuntimeErr("'{s}' is not defined", .{name});
                        return error.NotDefined;
                    };
                    chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
                    const v = globals.getAt(slot);
                    const result: Value = if (v == .int and k == .int) .{ .int = v.int + k.int } else try computeAddResult(v, k);
                    globals.setAt(slot, result);
                }
            },

            .get_local => {
                const slot = try vmByte();
                try vmPush(try readLocalSlot(slot));
            },
            .set_local => {
                const slot = try vmByte();
                const base = vmFrameBase();
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                writeFrameLocal(base + slot, try vmPop());
            },
            .get_upvalue => {
                try vmPush((try readUpvalueCell(try vmByte())).cell.value);
            },
            .set_upvalue => {
                const idx = try vmByte();
                const val = try vmPop();
                (try readUpvalueCell(idx)).cell.value = val;
            },
            .close_upvalue => {
                const slot = try vmByte();
                const base = vmFrameBase();
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                const v = vmState().stack[base + slot];
                if (v == .object and v.object.* == .cell) {
                    vmState().stack[base + slot] = v.object.cell.value;
                }
            },
            .close_upvalue_loop => {
                const slot = try vmByte();
                const base = vmFrameBase();
                if (base + slot < vmState().stack.len) {
                    const v = vmState().stack[base + slot];
                    if (v == .object and v.object.* == .cell) {
                        vmState().stack[base + slot] = v.object.cell.value;
                    }
                }
                const off = try vms.vmInt();
                if (off > vmState().ip) return error.BytecodeOutOfBounds;
                vmState().ip -= off;
            },

            .add => {
                const b = try vmPop();
                const a = try vmPop();
                try vmPush(try computeAddResult(a, b));
            },
            .local_add_local => {
                const dst = try vmByte();
                const src = try vmByte();
                const a = try readLocalSlot(dst);
                const b = try readLocalSlot(src);
                const result: Value = if (a == .int and b == .int) .{ .int = a.int + b.int } else try computeAddResult(a, b);
                writeFrameLocal(vmFrameBase() + dst, result);
            },
            .local_add_const => {
                const dst = try vmByte();
                const k = try chunk.constAt(try vmShort());
                const a = try readLocalSlot(dst);
                const result: Value = if (a == .int and k == .int) .{ .int = a.int + k.int } else try computeAddResult(a, k);
                writeFrameLocal(vmFrameBase() + dst, result);
            },
            .local_add_const_loop => {
                const dst = try vmByte();
                const k = try chunk.constAt(try vmShort());
                const a = try readLocalSlot(dst);
                const result: Value = if (a == .int and k == .int) .{ .int = a.int + k.int } else try computeAddResult(a, k);
                writeFrameLocal(vmFrameBase() + dst, result);
                const off = try vms.vmInt();
                if (off > vmState().ip) return error.BytecodeOutOfBounds;
                vmState().ip -= off;
            },
            .add_ret => {
                vmperf.breakOpChain();
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const b = try vmPop();
                const a = try vmPop();
                const retval = try computeAddResult(a, b);
                if (try doReturn(retval)) return;
            },
            .sub => {
                const b = try vmPop();
                const a = try vmPop();
                if (a == .int and b == .int) { try vmPush(.{ .int = a.int - b.int }); continue; }
                if (a == .float and b == .float) {
                    const r = a.float - b.float;
                    if (!std.math.isFinite(r)) { vms.setRuntimeErr("non-finite value in arithmetic operation", .{}); return error.TypeError; }
                    try vmPush(.{ .float = r }); continue;
                }
                if (decimalOpValues(a, b)) |dop| {
                    const result = @subWithOverflow(dop.lhs, dop.rhs);
                    if (result[1] != 0) return error.TypeError;
                    try pushDecimalResultWithCarrier(dop.typ, result[0]);
                } else {
                    try pushSubResult(a, b);
                }
            },
            .mul => {
                const b = try vmPop();
                const a = try vmPop();
                if (a == .int and b == .int) { try vmPush(.{ .int = a.int * b.int }); continue; }
                if (a == .float and b == .float) {
                    const r = a.float * b.float;
                    if (!std.math.isFinite(r)) { vms.setRuntimeErr("non-finite value in arithmetic operation", .{}); return error.TypeError; }
                    try vmPush(.{ .float = r }); continue;
                }
                if (decimalOpValues(a, b)) |_| {
                    return error.TypeError;
                } else if (decimalScalarPair(a, b) orelse decimalScalarPair(b, a)) |p| {
                    const result = @mulWithOverflow(p.d, p.n);
                    if (result[1] != 0) return error.TypeError;
                    try pushDecimalResultWithCarrier(p.typ, result[0]);
                } else {
                    const ctx = try numericBinaryOp(a, b, "*");
                    try pushNumericResultWithCarrier(a, b, ctx.an * ctx.bn, ctx.tag, "*");
                }
            },
            .div => {
                const b = try vmPop();
                const a = try vmPop();
                if (a == .int and b == .int) {
                    if (b.int == 0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    try vmPush(.{ .float = @as(f64, @floatFromInt(a.int)) / @as(f64, @floatFromInt(b.int)) });
                    continue;
                }
                if (a == .float and b == .float) {
                    if (b.float == 0.0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    const r = a.float / b.float;
                    if (!std.math.isFinite(r)) { vms.setRuntimeErr("non-finite value in arithmetic operation", .{}); return error.TypeError; }
                    try vmPush(.{ .float = r }); continue;
                }
                if (decimalOpValues(a, b)) |_| {
                    return error.TypeError;
                } else if (decimalScalarPair(a, b)) |p| {
                    if (p.n == 0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    if (p.d == std.math.minInt(i64) and p.n == -1) return error.TypeError;
                    try pushDecimalResultWithCarrier(p.typ, @divTrunc(p.d, p.n));
                } else {
                    const ctx = try numericBinaryOp(a, b, "/");
                    if (ctx.bn == 0.0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    try pushNumericResultWithCarrier(a, b, ctx.an / ctx.bn, ctx.tag, "/");
                }
            },
            .mod => {
                const b = try vmPop();
                const a = try vmPop();
                if (a == .int and b == .int) {
                    if (b.int == 0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    const result: i64 = if (a.int == std.math.minInt(i64) and b.int == -1) 0 else @rem(a.int, b.int);
                    try vmPush(.{ .int = result }); continue;
                }
                if (a == .float and b == .float) {
                    if (b.float == 0.0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    try vmPush(.{ .float = common.fmod(a.float, b.float) }); continue;
                }
                const ctx = try numericBinaryOp(a, b, "%");
                if (ctx.bn == 0.0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                try pushNumericResultWithCarrier(a, b, common.fmod(ctx.an, ctx.bn), ctx.tag, "%");
            },
            .pow => {
                const b = try vmPop();
                const a = try vmPop();
                const ctx = try numericBinaryOp(a, b, "**");
                try pushNumericResultWithCarrier(a, b, std.math.pow(f64, ctx.an, ctx.bn), ctx.tag, "**");
            },
            .bit_and => {
                const b = try vmPop();
                const a = try vmPop();
                try pushIntResultWithCarrier(a, b, try valueAsIntForOp(a, b, "&") & try valueAsIntForOp(b, a, "&"), "&");
            },
            .bit_or => {
                const b = try vmPop();
                const a = try vmPop();
                try pushIntResultWithCarrier(a, b, try valueAsIntForOp(a, b, "|") | try valueAsIntForOp(b, a, "|"), "|");
            },
            .bit_xor => {
                const b = try vmPop();
                const a = try vmPop();
                try pushIntResultWithCarrier(a, b, try valueAsIntForOp(a, b, "^") ^ try valueAsIntForOp(b, a, "^"), "^");
            },
            .bit_not => {
                const v = try vmPeek(0);
                const n = try vms.valueAsInt(v);
                try pushUnaryIntResult(v, .{ .int = ~n });
            },
            .shl => {
                const p = try getShiftArgs("<<");
                // Prevent signed left-shift overflow: if magnitude exceeds what i64 can hold after shift.
                if (p.an > 0 and p.an > (@as(i64, std.math.maxInt(i64)) >> p.shift)) return error.RangeError;
                if (p.an < 0 and p.an < (@as(i64, std.math.minInt(i64)) >> p.shift)) return error.RangeError;
                try pushIntResultWithCarrier(p.a, p.b, p.an << p.shift, "<<");
            },
            .shr => {
                const p = try getShiftArgs(">>");
                try pushIntResultWithCarrier(p.a, p.b, p.an >> p.shift, ">>");
            },
            .cast_int => {
                const raw = try vmPop();
                if (vmod.decimalLogicalNumber(raw)) |n| {
                    try vmPush(.{ .int = try floatToIntSafe(n) });
                    continue;
                }
                const v = vms.unboxNamed(raw);
                switch (v) {
                    .int => |n| try vmPush(.{ .int = n }),
                    .float => |n| try vmPush(.{ .int = try floatToIntSafe(n) }),
                    .decimal => |d| try vmPush(.{ .int = d }),
                    .rune => |r| try vmPush(.{ .int = @intCast(r) }),
                    .boolean => |b| try vmPush(.{ .int = if (b) 1 else 0 }),
                    else => return error.TypeError,
                }
            },
            .cast_float => {
                const raw = try vmPop();
                if (vmod.decimalLogicalNumber(raw)) |n| {
                    try vmPush(.{ .float = n });
                    continue;
                }
                const v = vms.unboxNamed(raw);
                switch (v) {
                    .int => |n| try vmPush(.{ .float = @floatFromInt(n) }),
                    .float => |n| try vmPush(.{ .float = n }),
                    .decimal => |d| try vmPush(.{ .float = @floatFromInt(d) }),
                    .rune => |r| try vmPush(.{ .float = @floatFromInt(r) }),
                    .boolean => |b| try vmPush(.{ .float = if (b) 1.0 else 0.0 }),
                    else => return error.TypeError,
                }
            },
            .cast_decimal => {
                const v = vms.unboxNamed(try vmPop());
                switch (v) {
                    .int => |n| try vmPush(.{ .decimal = n }),
                    .float => |n| {
                        if (!std.math.isFinite(n)) return error.TypeError;
                        const t = @trunc(n);
                        if (t < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                            t >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                        try vmPush(.{ .decimal = @intFromFloat(t) });
                    },
                    .decimal => |d| try vmPush(.{ .decimal = d }),
                    .rune => |r| try vmPush(.{ .decimal = @intCast(r) }),
                    .boolean => |b| try vmPush(.{ .decimal = if (b) 1 else 0 }),
                    else => return error.TypeError,
                }
            },
            .cast_bool => {
                const v = vms.unboxNamed(try vmPop());
                switch (v) {
                    .int => |n| try vmPush(.{ .boolean = n != 0 }),
                    .float => |n| try vmPush(.{ .boolean = n != 0.0 }),
                    .rune => |r| try vmPush(.{ .boolean = r != 0 }),
                    .boolean => |b| try vmPush(.{ .boolean = b }),
                    else => return error.TypeError,
                }
            },
            .cast_string => {
                // Keep the operand on the stack while converting: the result
                // allocation can GC, and a popped named string's bytes would
                // be freed — possibly handed back as the destination buffer
                // (#120 window family; caught as an aliasing memcpy).
                const raw = try vmPeek(0);
                if (vmod.decimalRawAndScale(raw)) |drs| {
                    var buf: [64]u8 = undefined;
                    const s = vmod.formatDecimalString(drs.raw, drs.scale, &buf);
                    const out = try vmgc.makeDynString(s);
                    _ = try vmPop();
                    try vmPush(out);
                    continue;
                }
                const v = vms.unboxNamed(raw);
                if (v == .null) return error.TypeError;
                const out = try vmnative.nativeConvToString(v);
                _ = try vmPop();
                try vmPush(out);
            },
            .cast_rune => {
                const v = vms.unboxNamed(try vmPop());
                const r: u21 = switch (v) {
                    .rune => |rv| rv,
                    .int => |n| blk: {
                        if (n < 0 or n > 0x10FFFF) return error.TypeError;
                        break :blk @intCast(n);
                    },
                    else => return error.TypeError,
                };
                try vmPush(.{ .rune = r });
            },
            .assert_type => {
                const tag = try vmByte();
                const v = try vmPeek(0);
                const ok = switch (tag) {
                    1 => v == .object and vms.isArrayObject(v.object),
                    2 => v == .object and vms.isMapObject(v.object),
                    3 => v == .error_value,
                    else => return error.TypeError,
                };
                const expected = if (tag == 1) "array" else if (tag == 2) "map" else "error";
                try typeAssert(v, ok, expected);
            },
            .assert_interface => {
                const idx = try vmShort();
                if (idx >= chunk.constCount()) return error.BadConstantIndex;
                const name = (chunk.constAt(idx) catch unreachable).string.bytes;
                const v = try vmPeek(0);
                try typeAssert(v, vmtyp.matchesInterfaceType(v, name), name);
            },
            .assert_struct => {
                const idx = try vmShort();
                if (idx >= chunk.constCount()) return error.BadConstantIndex;
                const name = (chunk.constAt(idx) catch unreachable).string.bytes;
                const v = try vmPeek(0);
                const ok = v == .object and v.object.* == .struct_instance and common.streq(v.object.struct_instance.typ.struct_type.qualified_name, name);
                try typeAssert(v, ok, name);
            },
            .type_name => {
                const v = try vmPop();
                try vmPush(try vmnative.nativeTypeNameValue(v));
            },
            .neg => {
                const v = try vmPeek(0);
                const negated: Value = switch (vms.unboxNamed(v)) {
                    .int => |n| .{ .int = -n },
                    .float => |n| .{ .float = -n },
                    else => {
                        _ = try vmPop();
                        vms.setRuntimeErr("cannot negate {s}", .{vmtyp.runtimeTypeName(v)});
                        return error.TypeError;
                    },
                };
                try pushUnaryIntResult(v, negated);
            },
            .not => {
                const v = try vmPop();
                try vmPush(.{ .boolean = !(try condAsBool(v, "'not' operand")) });
            },
            .eq => {
                const b = try vmPop();
                const a = try vmPop();
                if (a == .int and b == .int) { try vmPush(.{ .boolean = a.int == b.int }); continue; }
                if (a == .boolean and b == .boolean) { try vmPush(.{ .boolean = a.boolean == b.boolean }); continue; }
                try checkNamedValueCompatibility(a, b);
                try vmPush(.{ .boolean = Value.equals(vms.unboxNamed(a), vms.unboxNamed(b)) });
            },
            .gt => {
                const b = try vmPop();
                const a = try vmPop();
                if (a == .int and b == .int) { try vmPush(.{ .boolean = a.int > b.int }); continue; }
                const n = try compareNumericPair(a, b, ">");
                try vmPush(.{ .boolean = n.an > n.bn });
            },
            .lt => {
                const b = try vmPop();
                const a = try vmPop();
                if (a == .int and b == .int) { try vmPush(.{ .boolean = a.int < b.int }); continue; }
                const n = try compareNumericPair(a, b, "<");
                try vmPush(.{ .boolean = n.an < n.bn });
            },

            // Fused const+op: reads rhs constant, pops lhs from stack.
            .const_eq => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                if (a == .int and k == .int) { try vmPush(.{ .boolean = a.int == k.int }); continue; }
                try checkNamedValueCompatibility(a, k);
                try vmPush(.{ .boolean = Value.equals(vms.unboxNamed(a), vms.unboxNamed(k)) });
            },
            .const_sub => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                if (a == .int and k == .int) { try vmPush(.{ .int = a.int - k.int }); continue; }
                try pushSubResult(a, k);
            },

            // Triple-fused: get_local + constant + eq/sub.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo]
            .get_local_const_eq => {
                const p = try readLocalSlotAndConst();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) { try vmPush(.{ .boolean = a.int == p.k.int }); continue; }
                try checkNamedValueCompatibility(a, p.k);
                try vmPush(.{ .boolean = Value.equals(vms.unboxNamed(a), vms.unboxNamed(p.k)) });
            },
            .get_local_const_sub => {
                const p = try readLocalSlotAndConst();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) { try vmPush(.{ .int = a.int - p.k.int }); continue; }
                try pushSubResult(a, p.k);
            },
            .get_local_const_sub_call => {
                const p = try readLocalSlotAndConst();
                const argc = try vmByte();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) {
                    try vmPush(.{ .int = a.int - p.k.int });
                } else {
                    try pushSubResult(a, p.k);
                }
                if (try tryTailCall(argc)) continue;
                try performCall(argc);
            },
            .call_global_local_sub_const => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                _ = try vmByte(); // skip get_local_const_sub_call opcode byte
                const p = try readLocalSlotAndConst();
                const argc = try vmByte();
                const callee = try readGlobalIC(name_idx, ic_base, ic_slot);
                const a = try readLocalSlot(p.slot);
                try vmPush(callee);
                if (a == .int and p.k == .int) {
                    try vmPush(.{ .int = a.int - p.k.int });
                } else {
                    try pushSubResult(a, p.k);
                }
                if (try tryTailCall(argc)) continue;
                try performCall(argc);
            },
            .get_local_const_add => {
                const p = try readLocalSlotAndConst();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) { try vmPush(.{ .int = a.int + p.k.int }); continue; }
                try vmPush(try computeAddResult(a, p.k));
            },
            .get_local_const_lt => {
                const p = try readLocalSlotAndConst();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) { try vmPush(.{ .boolean = a.int < p.k.int }); continue; }
                const n = try compareNumericPair(a, p.k, "<");
                try vmPush(.{ .boolean = n.an < n.bn });
            },
            .get_local_const_gt => {
                const p = try readLocalSlotAndConst();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) { try vmPush(.{ .boolean = a.int > p.k.int }); continue; }
                const n = try compareNumericPair(a, p.k, ">");
                try vmPush(.{ .boolean = n.an > n.bn });
            },

            // Quad-fused: get_local + constant + eq + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][jmp_b3][jmp_b2][jmp_b1][jmp_b0]
            .get_local_const_eq_jif_pop => {
                const p = try readLocalSlotAndConst();
                const off = try vms.vmInt();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) {
                    if (a.int != p.k.int) vmState().ip += off;
                } else {
                    try checkNamedValueCompatibility(a, p.k);
                    if (!Value.equals(vms.unboxNamed(a), vms.unboxNamed(p.k))) vmState().ip += off;
                }
            },

            // Quad-fused: get_local + const_lt + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0]
            .get_local_const_lt_jif_pop => {
                const p = try readLocalSlotAndConst();
                const off = try vms.vmInt();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) {
                    if (a.int >= p.k.int) vmState().ip += off;
                } else {
                    const n = try compareNumericPair(a, p.k, "<");
                    if (!(n.an < n.bn)) vmState().ip += off;
                }
            },
            // Quad-fused: get_local + const_gt + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0]
            .get_local_const_gt_jif_pop => {
                const p = try readLocalSlotAndConst();
                const off = try vms.vmInt();
                const a = try readLocalSlot(p.slot);
                if (a == .int and p.k == .int) {
                    if (a.int <= p.k.int) vmState().ip += off;
                } else {
                    const n = try compareNumericPair(a, p.k, ">");
                    if (!(n.an > n.bn)) vmState().ip += off;
                }
            },

            // Quint-fused: get_local + const_lt + jif_pop + jump (C-style for-loop header).
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0][body_b3..b0]
            // exit_off is relative to ip after reading it (ip_mid = tp+9).
            // body_off is relative to ip after reading both offsets (tp+13).
            .get_local_const_lt_jif_pop_jump => {
                const p = try readLocalSlotAndConst();
                const a = try readLocalSlot(p.slot);
                const exit_off = try vms.vmInt();
                const ip_mid = vmState().ip;
                const body_off = try vms.vmInt();
                const cond_true = if (a == .int and p.k == .int)
                    (a.int < p.k.int)
                else blk: {
                    const n = try compareNumericPair(a, p.k, "<");
                    break :blk n.an < n.bn;
                };
                if (cond_true) {
                    vmState().ip += body_off;
                } else {
                    vmState().ip = ip_mid + exit_off;
                }
            },

            // Fused: get_local + get_field. 8-byte layout:
            // [op][slot][skip=get_field_byte][name_hi][name_lo][ic_type_hi][ic_type_lo][ic_fidx]
            .get_local_get_field => {
                try opGetLocalGetField();
            },

            // Triple-fused: get_global + constant + eq.
            // Bytecode: [op][name_hi][name_lo][ic_hi][ic_lo][skip][val_hi][val_lo]
            .get_global_const_eq => {
                const p = try readGlobalConstPair();
                if (p.g == .int and p.k == .int) { try vmPush(.{ .boolean = p.g.int == p.k.int }); continue; }
                try checkNamedValueCompatibility(p.g, p.k);
                try vmPush(.{ .boolean = Value.equals(vms.unboxNamed(p.g), vms.unboxNamed(p.k)) });
            },
            .get_global_const_sub => {
                const p = try readGlobalConstPair();
                if (p.g == .int and p.k == .int) { try vmPush(.{ .int = p.g.int - p.k.int }); continue; }
                try pushSubResult(p.g, p.k);
            },
            .get_global_const_add => {
                const p = try readGlobalConstPair();
                if (p.g == .int and p.k == .int) { try vmPush(.{ .int = p.g.int + p.k.int }); continue; }
                try vmPush(try computeAddResult(p.g, p.k));
            },
            .get_global_const_lt => {
                const p = try readGlobalConstPair();
                if (p.g == .int and p.k == .int) { try vmPush(.{ .boolean = p.g.int < p.k.int }); continue; }
                const n = try compareNumericPair(p.g, p.k, "<");
                try vmPush(.{ .boolean = n.an < n.bn });
            },
            // Quad-fused: get_global + const_lt + jif_pop.
            // Bytecode: [op][name_hi][name_lo][ic_hi][ic_lo][skip][val_hi][val_lo][jmp_b3][jmp_b2][jmp_b1][jmp_b0]
            .get_global_const_lt_jif_pop => {
                const p = try readGlobalConstPair();
                const off = try vms.vmInt();
                if (p.g == .int and p.k == .int) {
                    if (p.g.int >= p.k.int) vmState().ip += off;
                } else {
                    const n = try compareNumericPair(p.g, p.k, "<");
                    if (!(n.an < n.bn)) vmState().ip += off;
                }
            },
            .const_add => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                try vmPush(try computeAddResult(a, k));
            },
            .const_lt => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                const n = try compareNumericPair(a, k, "<");
                try vmPush(.{ .boolean = n.an < n.bn });
            },
            .const_gt => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                const n = try compareNumericPair(a, k, ">");
                try vmPush(.{ .boolean = n.an > n.bn });
            },

            .build_array, .build_tuple => {
                const count = try vmByte();
                const obj = try allocTempRooted(.{ .array = &[_]Value{} });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    items[i] = try vmPop();
                }
                obj.* = .{ .array_managed = items[0..count] };
                try vmPush(.{ .object = obj });
            },
            .build_map => {
                const count = try vmByte();
                const obj = try allocTempRooted(.{ .map = &[_]MapEntry{} });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(MapEntry, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    const val = try vmPop();
                    const key = try vmPop();
                    items[i] = .{ .key = key, .value = val };
                }
                // Point obj at items before allocating buckets so GC can trace the entries
                // (they are no longer on the stack after vmPop above).
                obj.* = .{ .map = items[0..count] };
                const bcount = vmmap.mapBucketsForCount(count);
                const buckets = try vmAllocManagedSlice(i32, bcount);
                vmmap.mapBuildHashedBuckets(items[0..count], buckets);
                obj.* = .{ .map_hashed = .{ .entries = items[0..count], .len = count, .buckets = buckets } };
                try vmPush(.{ .object = obj });
            },
            .build_struct_instance => {
                const count = try vmByte();
                const typ_stack_dist = @as(usize, count) * 2;
                if (vmState().stack_top <= typ_stack_dist) return error.StackUnderflow;
                const typ_peek = vmState().stack[vmState().stack_top - 1 - typ_stack_dist];
                if (typ_peek != .object) return error.TypeError;

                if (typ_peek.object.* == .variant_ctor) {
                    const vc = typ_peek.object.variant_ctor;
                    const vt = vc.typ.variant_type;
                    const arm = vt.arms[vc.ordinal];
                    const shared_count = vt.shared_fields.len;
                    const arm_field_count = arm.fields.len;

                    const obj = try allocTempRooted(.{ .array = &[_]Value{} });
                    defer popTempRoot();

                    const base = vmState().stack_top - typ_stack_dist;
                    const shared_vals = try vmAllocManagedSlice(Value, shared_count);
                    const arm_vals = if (arm_field_count > 0) try vmAllocManagedSlice(Value, arm_field_count) else @as([]Value, &.{});

                    if (arm.has_payload and arm_field_count == 0) {
                        // Single-payload arm with shared fields
                        var shared_seen: [255]bool = [_]bool{false} ** 255;
                        var payload_val: Value = .null;
                        var payload_seen = false;
                        for (0..@as(usize, count)) |ci| {
                            const key = vmState().stack[base + ci * 2];
                            const val = vmState().stack[base + ci * 2 + 1];
                            const key_s = try vms.asStringValue(key);
                            if (vmtyp.findFieldIndex(vt.shared_fields, key_s)) |idx| {
                                if (shared_seen[idx]) { vms.setRuntimeErr("duplicate field '{s}' in variant literal", .{key_s}); return error.DuplicateField; }
                                shared_seen[idx] = true;
                                shared_vals[idx] = val;
                            } else if (common.streq(key_s, arm.payload_name)) {
                                if (payload_seen) { vms.setRuntimeErr("duplicate field '{s}' in variant literal", .{key_s}); return error.DuplicateField; }
                                payload_seen = true;
                                payload_val = val;
                            } else {
                                vms.setRuntimeErr("no field '{s}' on variant '{s}'", .{ key_s, arm.name });
                                return error.UnknownStructField;
                            }
                        }
                        for (vt.shared_fields, shared_seen[0..shared_count]) |sf, seen| {
                            if (!seen) { vms.setRuntimeErr("missing required field '{s}' in variant literal", .{sf.name}); return error.MissingStructField; }
                        }
                        if (arm.has_payload and !payload_seen) { vms.setRuntimeErr("missing required field '{s}' in variant literal", .{arm.payload_name}); return error.MissingStructField; }

                        vmState().stack_top -= typ_stack_dist + 1;
                        obj.* = .{ .variant_value = .{
                            .typ = vc.typ,
                            .tag = vc.tag,
                            .ordinal = vc.ordinal,
                            .payload = payload_val,
                            .shared_values = shared_vals[0..shared_count],
                        } };
                    } else {
                        // Record arm (multi-field arm)
                        const total_fields = shared_count + arm_field_count;
                        var seen: [255]bool = [_]bool{false} ** 255;
                        for (0..@as(usize, count)) |ci| {
                            const key = vmState().stack[base + ci * 2];
                            const val = vmState().stack[base + ci * 2 + 1];
                            const key_s = try vms.asStringValue(key);
                            if (vmtyp.findFieldIndex(vt.shared_fields, key_s)) |idx| {
                                if (seen[idx]) { vms.setRuntimeErr("duplicate field '{s}' in variant literal", .{key_s}); return error.DuplicateField; }
                                seen[idx] = true;
                                shared_vals[idx] = val;
                            } else if (vmtyp.findFieldIndex(arm.fields, key_s)) |idx| {
                                const seen_idx = shared_count + idx;
                                if (seen[seen_idx]) { vms.setRuntimeErr("duplicate field '{s}' in variant literal", .{key_s}); return error.DuplicateField; }
                                seen[seen_idx] = true;
                                arm_vals[idx] = val;
                            } else {
                                vms.setRuntimeErr("no field '{s}' on variant '{s}'", .{ key_s, arm.name });
                                return error.UnknownStructField;
                            }
                        }
                        for (seen[0..shared_count], vt.shared_fields) |s, sf| {
                            if (!s) { vms.setRuntimeErr("missing required field '{s}' in variant literal", .{sf.name}); return error.MissingStructField; }
                        }
                        for (seen[shared_count..total_fields], arm.fields) |s, af| {
                            if (!s) { vms.setRuntimeErr("missing required field '{s}' in variant literal", .{af.name}); return error.MissingStructField; }
                        }

                        vmState().stack_top -= typ_stack_dist + 1;
                        obj.* = .{ .variant_value = .{
                            .typ = vc.typ,
                            .tag = vc.tag,
                            .ordinal = vc.ordinal,
                            .payload = .null,
                            .shared_values = shared_vals[0..shared_count],
                            .arm_fields = arm_vals[0..arm_field_count],
                        } };
                    }
                    try vmPush(.{ .object = obj });
                } else if (typ_peek.object.* == .struct_type) {
                    const st = typ_peek.object.struct_type;
                    if (st.fields.len > 255) return error.TooManyStructFields;

                    const inst_fields = try vmAllocManagedSlice(MapEntry, st.fields.len);
                    const obj = try allocTempRooted(.{ .array = &[_]Value{} });
                    defer popTempRoot();

                    const base = vmState().stack_top - typ_stack_dist;
                    var seen: [255]bool = [_]bool{false} ** 255;
                    for (0..@as(usize, count)) |ci| {
                        const key = vmState().stack[base + ci * 2];
                        const val = vmState().stack[base + ci * 2 + 1];
                        const key_s = try vms.asStringValue(key);
                        const idx = vmtyp.findFieldIndex(st.fields, key_s) orelse {
                            vms.setRuntimeErr("no field '{s}' on type '{s}'", .{ key_s, st.name });
                            return error.UnknownStructField;
                        };
                        if (seen[idx]) { vms.setRuntimeErr("duplicate field '{s}' in struct literal", .{key_s}); return error.DuplicateField; }
                        seen[idx] = true;
                        if (!vmtyp.matchesFieldType(val, st.fields[idx])) return error.StructFieldTypeMismatch;
                        inst_fields[idx] = .{ .key = st.fields[idx].key, .value = val };
                    }

                    for (st.fields, seen[0..st.fields.len]) |f, s| {
                        if (!s) { vms.setRuntimeErr("missing required field '{s}' in struct literal", .{f.name}); return error.MissingStructField; }
                    }

                    vmState().stack_top -= typ_stack_dist + 1;

                    obj.* = .{
                        .struct_instance = .{ .typ = typ_peek.object, .fields = inst_fields },
                    };
                    try vmPush(.{ .object = obj });
                } else {
                    return error.TypeError;
                }
            },
            .tuple_check_arity => {
                const expect = try vmByte();
                const tup = try vmPeek(0);
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                if ((try vms.asArraySlice(tup.object)).len != expect) return error.ArityMismatch;
            },
            .tuple_get => {
                const idx = try vmByte();
                const tup = try vmPop();
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                const a = try vms.asArraySlice(tup.object);
                if (idx >= a.len) return error.ArityMismatch;
                try vmPush(a[idx]);
            },
            .tuple_get_keep => {
                const idx = try vmByte();
                const tup = try vmPeek(0);
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                const a = try vms.asArraySlice(tup.object);
                if (idx >= a.len) return error.ArityMismatch;
                try vmPush(a[idx]);
            },
            .get_index => try opGetIndex(),
            .set_index => try opSetIndex(),
            .get_slice => {
                const flags = try vmByte();
                const has_start = (flags & 0b01) != 0;
                const has_end = (flags & 0b10) != 0;

                var end_v: Value = .null;
                var start_v: Value = .null;
                if (has_end) end_v = try vmPop();
                if (has_start) start_v = try vmPop();
                const container = try vmPop();
                // The slice result is a fresh allocation; keep the popped
                // container rooted through it (#120 window family).
                try pushTempRoot(container);
                defer popTempRoot();

                switch (container) {
                    .string => |s| {
                        const r = try stringSliceRange(s.bytes, has_start, start_v, has_end, end_v);
                        try vmPush(try makeDynString(s.bytes[r.start_b..r.end_b]));
                    },
                    .object => |obj| switch (obj.*) {
                        .dyn_string, .string_view => {
                            const bytes = if (obj.* == .dyn_string) obj.dyn_string else obj.string_view.bytes;
                            const src = if (obj.* == .dyn_string) obj else obj.string_view.source;
                            const r = try stringSliceRange(bytes, has_start, start_v, has_end, end_v);
                            try vmPush(try makeStringView(bytes[r.start_b..r.end_b], src));
                        },
                        .array, .array_managed, .array_capacity => {
                            const items = try vms.asArraySlice(obj);
                            const start: usize = if (has_start) try vms.vmSliceIndex(start_v, items.len) else 0;
                            const end: usize = if (has_end) try vms.vmSliceIndex(end_v, items.len) else items.len;
                            if (start > end) return error.IndexOutOfBounds;
                            const out = try vmAllocObject();
                            out.* = .{ .array = items[start..end] };
                            try vmPush(.{ .object = out });
                        },
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                }
            },
            .iter_init => {
                // Keep the iterable on the stack while iterInit allocates the
                // iterator object: popping first leaves a temporary array's
                // only reference in a Zig local, and the GC sweeps it — often
                // reusing its slot for the iterator itself.
                const v = try vmPeek(0);
                const it = try iterInit(v);
                _ = try vmPop();
                try vmPush(it);
            },
            .iter_next1 => {
                const itv = try vmPeek(0);
                if (itv != .object or itv.object.* != .iterator) return error.TypeError;
                try iterNext1(&itv.object.iterator);
            },
            .iter_next2 => {
                const itv = try vmPeek(0);
                if (itv != .object or itv.object.* != .iterator) return error.TypeError;
                try iterNext2(&itv.object.iterator);
            },
            .make_closure => {
                const f = try vmConst();
                if (f != .object or f.object.* != .function) return error.TypeError;
                const proto = f.object.function;
                const ups = if (heap.bump(*Object, proto.capture_slots.len)) |u| u else blk: {
                    vmgc.collectGarbage();
                    break :blk (heap.bump(*Object, proto.capture_slots.len) orelse return error.OutOfMemory);
                };
                const frame = if (vmState().frame_top == 0) vms.Frame{ .ret_ip = 0, .base = 0, .closure = null, .func_obj = f.object, .defer_base = 0, .has_typed_returns = false } else vmState().frames[vmState().frame_top - 1];
                for (proto.capture_slots, ups) |enc, *u| {
                    const is_upvalue = (enc & 0x80) != 0;
                    const idx = enc & 0x7f;
                    if (is_upvalue) {
                        const pcl = frame.closure orelse return error.TypeError;
                        if (pcl.* != .closure) return error.TypeError;
                        if (idx >= pcl.closure.upvalues.len) return error.TypeError;
                        u.* = pcl.closure.upvalues[idx];
                    } else {
                        const abs = frame.base + idx;
                        if (abs >= vmState().stack.len) return error.StackOverflow;
                        const cur = vmState().stack[abs];
                        if (cur == .object and cur.object.* == .cell) {
                            u.* = cur.object;
                            continue;
                        }
                        const cell = try vmAllocObject();
                        cell.* = .{ .cell = .{ .value = cur } };
                        vmState().stack[abs] = .{ .object = cell };
                        u.* = cell;
                    }
                }
                const clo = try vmAllocObject();
                clo.* = .{ .closure = ClosureObj{ .func = f.object, .upvalues = ups[0..proto.capture_slots.len] } };
                try vmPush(.{ .object = clo });
            },
            .invoke_method => try opInvokeMethod(),

            .jump => {
                const off = try vms.vmInt();
                vmState().ip += off;
            },
            .jump_if_false => {
                const off = try vms.vmInt();
                if (!(try condAsBool(try vmPeek(0), "condition"))) vmState().ip += off;
            },
            .jif_pop => {
                const off = try vms.vmInt();
                const cond = try vmPop();
                if (!(try condAsBool(cond, "condition"))) vmState().ip += off;
            },
            .loop => {
                const off = try vms.vmInt();
                if (off > vmState().ip) return error.BytecodeOutOfBounds;
                vmState().ip -= off;
                // If the back-edge target is a warm get_global IC, execute it inline
                // to save one full dispatch iteration per loop cycle.
                try tryInlineGetGlobal();
            },

            // Fused set_global + loop back-edge.
            // Bytecode: [op][name_hi][name_lo][ic_hi][ic_lo][off_b3][off_b2][off_b1][off_b0]
            // IC layout and patch offsets are identical to set_global.
            .set_global_loop => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                try writeGlobalIC(name_idx, ic_base, ic_slot, try vmPop());
                const off = try vms.vmInt();
                if (off > vmState().ip) return error.BytecodeOutOfBounds;
                vmState().ip -= off;
                // Same inline get_global as loop: skip one dispatch if warm.
                try tryInlineGetGlobal();
            },

            .set_named_predicate => {
                const pred = try vmPop();
                const nt_val = vmState().stack[vmState().stack_top - 1];
                if (nt_val != .object or nt_val.object.* != .named_type) return error.TypeError;
                if (pred == .null) {
                    nt_val.object.named_type.predicate = null;
                } else if (pred == .object) {
                    if (pred.object.* != .function and pred.object.* != .closure) return error.TypeError;
                    nt_val.object.named_type.predicate = pred.object;
                } else {
                    return error.TypeError;
                }
            },

            .validate_type_default => {
                const nt_val = try vmPeek(0);
                if (nt_val != .object or nt_val.object.* != .named_type) return error.TypeError;
                const nt = &nt_val.object.named_type;
                if (nt.has_default and nt.predicate != null) {
                    const constructed = try vmtyp.constructNamedType(nt_val.object, nt.default_val);
                    try checkNamedTypePredicate(nt_val.object, constructed.object.named_value.value);
                }
            },

            .call => {
                const argc = try vmByte();
                const ic_base = vmState().ip;
                const ic_slot: u16 = (@as(u16, chunk.codeByteAt(ic_base)) << 8) | @as(u16, chunk.codeByteAt(ic_base + 1));
                vmState().ip += 2;
                if (try tryTailCall(argc)) continue;
                const t0 = vmperf.readTsc();
                try performCallIC(argc, ic_base, ic_slot);
                const t1 = vmperf.readTsc();
                if (t1 > t0) vmperf.callCycles(t1 - t0);
            },
            .op_assert => {
                const cond = try vmPop();
                if (cond != .boolean) return error.TypeError;
                if (!cond.boolean) return error.AssertionFailed;
            },

            .op_assert_msg => {
                const msg_val = try vmPop();
                const cond = try vmPop();
                if (cond != .boolean) return error.TypeError;
                if (!cond.boolean) {
                    vmState().pending_panic_message = panicMessageFromValue(msg_val);
                    return error.AssertionFailed;
                }
            },

            .op_trap_check => {
                const val = try vmPop();
                switch (val) {
                    .null => {},
                    else => {
                        vmState().pending_panic_value = val;
                        vmState().has_pending_panic_value = true;
                        return error.TrapFired;
                    },
                }
            },

            .variant_check => {
                const arm = (try vms.vmConst()).string.bytes;
                const v = try vmPop();
                const matches = v == .object and v.object.* == .variant_value and
                    common.streq(v.object.variant_value.tag, arm);
                try vmPush(.{ .boolean = matches });
            },

            .variant_payload => {
                const v = try vmPeek(0);
                if (v != .object or v.object.* != .variant_value) return error.TypeError;
                const vv = v.object.variant_value;
                const arm = vv.typ.variant_type.arms[vv.ordinal];
                if (arm.fields.len > 0) {
                    const map_obj = try allocTempRooted(.{ .map = &[_]MapEntry{} });
                    defer popTempRoot();
                    const items = try vmAllocManagedSlice(MapEntry, arm.fields.len);
                    for (arm.fields, vv.arm_fields, items) |f, fv, *it| it.* = .{ .key = f.key, .value = fv };
                    map_obj.* = .{ .map = items[0..arm.fields.len] };
                    _ = try vmPop();
                    try vmPush(.{ .object = map_obj });
                } else {
                    _ = try vmPop();
                    try vmPush(vv.payload);
                }
            },

            .get_field => try opGetField(),

            .set_field => try opSetField(),

            .defer_call => {
                const argc = try vmByte();
                if (vmState().defer_top >= vmState().defer_stack.len) return error.DeferStackOverflow;
                const total: usize = @as(usize, argc) + 1;
                if (vmState().stack_top < total) return error.StackUnderflow;
                const start = vmState().stack_top - total;
                const arr_obj = try allocTempRooted(.{ .array = &[_]Value{} });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, total);
                @memcpy(items[0..total], vmState().stack[start .. start + total]);
                arr_obj.* = .{ .array_managed = items[0..total] };
                vmState().defer_stack[vmState().defer_top] = .{ .object = arr_obj };
                vmState().defer_top += 1;
                vmState().stack_top -= total;
            },
            .defer_invoke_method => try opDeferInvokeMethod(),
            .ret => {
                vmperf.breakOpChain();
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const t0 = vmperf.readTsc();
                const retval = try vmPop();
                const fi = vmState().frame_top - 1;
                if (canReturnFast(fi, retval)) {
                    try doReturnFast(fi, retval);
                    if (vmState().call_depth_target) |d| {
                        if (vmState().frame_top == d) {
                            const t1 = vmperf.readTsc();
                            if (t1 > t0) vmperf.retCycles(t1 - t0);
                            return;
                        }
                    }
                    const t1 = vmperf.readTsc();
                    if (t1 > t0) vmperf.retCycles(t1 - t0);
                    continue;
                }
                if (try retSlowPath(retval)) {
                    const t1 = vmperf.readTsc();
                    if (t1 > t0) vmperf.retCycles(t1 - t0);
                    return;
                }
                const t1 = vmperf.readTsc();
                if (t1 > t0) vmperf.retCycles(t1 - t0);
            },

            // Fused constant+ret: reads idx, pushes constant, returns.
            // Emitted when `constant k` immediately precedes `ret`.
            .get_local_ret => {
                vmperf.breakOpChain();
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const v = try readLocalSlot(try vmByte());
                if (try doReturn(v)) return;
            },
            .ret_const => {
                vmperf.breakOpChain();
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const k = try chunk.constAt(try vmShort());
                if (try doReturn(k)) return;
            },

            .halt => { vmperf.breakOpChain(); return; },
        }
    }
}

fn runDeferredCall(deferred: Value) anyerror!void {
    const arr = try vms.asArraySlice(deferred.object);
    if (arr.len == 0) return;
    if (arr.len > 256) return error.ArityMismatch;
    const dargc: u8 = @intCast(arr.len - 1);
    for (arr) |v| try vmPush(v);
    const depth_before = vmState().frame_top;
    try performCall(dargc);
    if (vmState().frame_top > depth_before) {
        const prev_target = vmState().call_depth_target;
        vmState().call_depth_target = depth_before;
        defer vmState().call_depth_target = prev_target;
        try run();
    }
    _ = vmPop() catch {};
}

fn runPanicUnwind(orig_err: anyerror) anyerror!void {
    var current_err = orig_err;
    vmState().recovered = false;
    // If panic_line is already non-zero, a deeper run() has already captured the
    // true fault location (e.g. inside a predicate body). Preserve it rather than
    // overwriting with the outer call site (e.g. the named-type constructor call).
    if (vmState().panic_line == 0) {
        vmState().panic_col = 0;
        vmState().panic_depth = 0;
    }
    vmState().is_panicking = true;
    if (vmState().has_pending_panic_value) {
        vmState().panic_value = vmState().pending_panic_value;
        vmState().has_pending_panic_value = false;
    } else if (vmState().pending_panic_message) |msg| {
        // Only sync runtime_err_buf if msg doesn't already point into it —
        // when pending_panic_message was set from runtimeErrMsg() the buffer
        // is already correct, and @memcpy of a slice onto itself is UB.
        if (@intFromPtr(msg.ptr) != @intFromPtr(&vmState().runtime_err_buf[0])) {
            vms.setRuntimeErr("{s}", .{msg});
        }
        vmState().panic_value = .{ .error_value = try chunk.internStr(msg) };
        vmState().pending_panic_message = null;
    } else {
        vmState().panic_value = .{ .error_value = try chunk.internStr(@errorName(orig_err)) };
    }

    if (vmState().panic_line == 0) {
        vmState().panic_line = currentLine();
        vmState().panic_col = currentCol();
        const stop_depth = vmState().call_depth_target orelse 0;
        var depth: usize = 0;
        var fi: usize = vmState().frame_top;
        while (fi > stop_depth and depth < vmState().frames.len) {
            fi -= 1;
            const frame = vmState().frames[fi];
            const call_ip = if (frame.ret_ip > 0) frame.ret_ip - 1 else 0;
            const fname = switch (frame.func_obj.*) {
                .function => |f| f.name,
                .closure => |cl| cl.func.function.name,
                else => "",
            };
            vmState().panic_frames[depth] = .{ .line = chunk.lineAt(call_ip), .name = fname };
            depth += 1;
        }
        vmState().panic_depth = depth;
    }
    const stop_depth = vmState().call_depth_target orelse 0;
    while (vmState().frame_top > stop_depth) {
        const frame_defer_base = vmState().frames[vmState().frame_top - 1].defer_base;
        while (vmState().defer_top > frame_defer_base) {
            vmState().defer_top -= 1;
            runDeferredCall(vmState().defer_stack[vmState().defer_top]) catch |new_err| {
                if (!vmState().recovered) {
                    current_err = new_err;
                    vmState().panic_value = .{ .error_value = try chunk.internStr(@errorName(new_err)) };
                }
            };
            if (vmState().recovered) break;
        }
        if (vmState().recovered) {
            vmState().recovered = false;
            vmState().is_panicking = false;
            vmState().panic_line = 0;
            vmState().panic_col = 0;
            vmState().panic_depth = 0;
            vmState().defer_top = frame_defer_base;

            // Determine the recovered function's return arity before unwinding its frame.
            // If the function returns multiple values, callers expect a tuple; pushing a
            // bare null causes tuple_check_arity to throw TypeError.
            const rec_fobj = vmState().frames[vmState().frame_top - 1].func_obj;
            const rec_base = vmState().frames[vmState().frame_top - 1].base;
            const rec_fn: ?*@import("value.zig").FuncObj = switch (rec_fobj.*) {
                .function => &rec_fobj.function,
                .closure => |*cl| &cl.func.function,
                else => null,
            };
            const ret_count: usize = if (rec_fn) |f| f.return_types.len else 1;
            const named_ret: u8 = if (rec_fn) |f| f.named_return_count else 0;
            const rec_arity: u8 = if (rec_fn) |f| f.arity else 0;

            vmState().frame_top -= 1;
            const frame = vmState().frames[vmState().frame_top];
            vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
            vmState().ip = frame.ret_ip;

            if (ret_count <= 1) {
                if (named_ret > 0) {
                    const raw = vmState().stack[rec_base + rec_arity];
                    vmPush(vms.unboxCell(raw)) catch {};
                } else {
                    vmPush(.null) catch {};
                }
            } else {
                // Multi-value return: build a tuple of the right size.
                // Named returns: use the values from the (still-readable) stack slots;
                // unnamed returns: fill with null.
                const n: u8 = if (named_ret > 0) named_ret else @intCast(@min(ret_count, 255));
                const tup_obj = try vmAllocObject();
                tup_obj.* = .{ .array = &[_]Value{} };
                const items = try vmAllocManagedSlice(Value, n);
                if (named_ret > 0) {
                    for (0..named_ret) |ri| {
                        const raw = vmState().stack[rec_base + rec_arity + ri];
                        items[ri] = vms.unboxCell(raw);
                    }
                } else {
                    @memset(items, .null);
                }
                tup_obj.* = .{ .array_managed = items };
                try vmPush(.{ .object = tup_obj });
            }
            // If the recovered function was called via callGlobal (not from inside
            // bytecode), ret_ip points past halt/end-of-code.  The ret opcode's
            // fast path already handles this via call_depth_target; mirror that here
            // so recover() works when the caller is engine_call, not just the CLI.
            if (vmState().call_depth_target) |d| {
                if (vmState().frame_top == d) return;
            }
            return run();
        }
        vmState().frame_top -= 1;
        const frame = vmState().frames[vmState().frame_top];
        vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
        vmState().ip = frame.ret_ip;
    }
    vmState().is_panicking = false;
    return current_err;
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn run() anyerror!void {
    chunk.verify() catch |err| {
        if (chunk.g_state.verify_err_len > 0) {
            vms.setRuntimeErr("verifier: {s}", .{chunk.g_state.verify_err_buf[0..chunk.g_state.verify_err_len]});
            vms.vmState().pending_panic_message = vms.runtimeErrMsg();
        }
        return runPanicUnwind(err);
    };
    runInner() catch |err| return runPanicUnwind(err);
}

pub fn makeString(s: []const u8) !Value {
    return vmgc.makeDynString(s);
}

fn levenshteinDistance(a: []const u8, b: []const u8) usize {
    const m = a.len;
    const n = b.len;
    if (m == 0) return n;
    if (n == 0) return m;
    var prev: [128]usize = undefined;
    var cur: [128]usize = undefined;
    if (n > 127) return @max(m, n);
    if (m > 127) return @max(m, n);
    for (0..n + 1) |j| prev[j] = j;
    for (0..m) |i| {
        cur[0] = i + 1;
        for (0..n) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0..n + 1], cur[0..n + 1]);
    }
    return cur[n];
}

fn findSimilarName(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 4; // only suggest names within 2 edits
    for (0..globals.len()) |i| {
        const candidate = globals.nameAt(i);
        const d = levenshteinDistance(name, candidate);
        if (d < best_dist) { best_dist = d; best = candidate; }
    }
    return best;
}

fn callValue(fn_val: Value, args: []const Value) !Value {
    if (args.len > 255) return error.ArityMismatch;
    try vmPush(fn_val);
    for (args) |a| try vmPush(a);
    const depth_before = vmState().frame_top;
    try performCall(@intCast(args.len));
    const prev_target = vmState().call_depth_target;
    vmState().call_depth_target = depth_before;
    defer vmState().call_depth_target = prev_target;
    try run();
    return try vmPop();
}

pub fn callGlobal(name: []const u8, args: []const Value) !Value {
    const fn_val = globals.get(name) orelse return error.NotDefined;
    if (fn_val != .object) return error.NotAFunction;
    const obj = fn_val.object;
    if (obj.* != .function and obj.* != .closure) return error.NotAFunction;
    // Clear stale runtime error so runPanicUnwind won't pick up a message
    // from a previous engine_call as the fallback for pending_panic_message.
    vmState().runtime_err_len = 0;
    return callValue(fn_val, args);
}

pub fn callFunction(func_val: Value, args: []const Value) anyerror!Value {
    return callValue(func_val, args);
}
