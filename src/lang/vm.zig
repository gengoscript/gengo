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
const vm_integrity = @import("vm_integrity.zig");
const vmmap = @import("vm_map.zig");
const vmarr = @import("vm_array.zig");
const vmstr = @import("vm_string.zig");
const vmtyp = @import("vm_types.zig");
const vmbigint = @import("vm_bigint.zig");
const build_options = @import("build_options");
const vmnative = @import("vm_native.zig");
const vmperf = @import("vm_perf.zig");
const io = @import("../runtime/io.zig");

// ── Public re-exports (external callers import from vm.zig unchanged) ─────────

pub const Policy = vms.Policy;
pub const State = vms.State;
pub const PanicFrame = vms.PanicFrame;
pub const MaxFrames = vms.MaxFrames;

pub const setActive = vms.setActive;
pub const reset = vms.reset;
pub const resetExec = vms.resetExec;
pub const setPolicy = vms.setPolicy;
pub const currentLine = vms.currentLine;
pub const currentCol = vms.currentCol;
pub const panicLine = vms.panicLine;
pub const panicCol = vms.panicCol;
pub const panicPath = vms.panicPath;
pub const panicFrames = vms.panicFrames;
pub const runtimeErrMsg = vms.runtimeErrMsg;

/// Explicit VM execution context. Re-exported from vm_state so callers
/// that use vm.VMContext continue to work unchanged.
pub const VMContext = vms.VMContext;

// ── Private helpers used only in the execution core ───────────────────────────

fn isModuleNamespaceStruct(typ: *Object) bool {
    return typ.* == .struct_type and std.mem.startsWith(u8, typ.struct_type.qualified_name, "@module_type:");
}

fn panicMessageFromValue(ctx: VMContext, v: Value) []const u8 {
    if (v == .string) return v.string.bytes;
    if (v == .object) {
        if (v.object.* == .dyn_string) return v.object.dyn_string;
        if (v.object.* == .string_view) return v.object.string_view.bytes;
    }
    if (v == .int) {
        return std.fmt.bufPrint(&ctx.vs.fmt_scratch, "{d}", .{v.int}) catch "AssertionFailed";
    }
    if (v == .float) {
        return std.fmt.bufPrint(&ctx.vs.fmt_scratch, "{d}", .{v.float}) catch "AssertionFailed";
    }
    if (v == .boolean) return if (v.boolean) "true" else "false";
    if (v == .null) return "null";
    if (v == .error_value) return v.error_value.bytes;
    return "AssertionFailed";
}

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

fn typeAssert(ctx: VMContext, v: Value, ok: bool, expected: []const u8) !void {
    if (!ok) {
        ctx.vs.setRuntimeErr("expected {s}, got {s}", .{ expected, vmtyp.runtimeTypeName(v) });
        return error.TypeError;
    }
}

// Conditions are bool-only; explain what arrived instead of a bare TypeError.
fn condAsBool(ctx: VMContext, v: Value, what: []const u8) !bool {
    return v.asBool() catch {
        ctx.vs.setRuntimeErr("{s} must be bool, got {s}; use a comparison or std.conv.to_bool", .{ what, vmtyp.runtimeTypeName(v) });
        return error.TypeError;
    };
}

fn setBinaryTypeError(ctx: VMContext, op: []const u8, a: Value, b: Value) void {
    const a_named = a == .object and a.object.* == .named_value;
    const b_named = b == .object and b.object.* == .named_value;
    if (a_named and b_named) {
        const ta = a.object.named_value.typ.named_type;
        const tb = b.object.named_value.typ.named_type;
        const ta_obj = a.object.named_value.typ;
        const tb_obj = b.object.named_value.typ;
        if (ta.base == tb.base and !namedTypeIsSubOf(ta_obj, tb_obj) and !namedTypeIsSubOf(tb_obj, ta_obj) and namedTypeCommonAncestor(ta_obj, tb_obj) == null) {
            ctx.vs.setRuntimeErr("cannot apply '{s}' to {s} and {s}; convert one side explicitly before applying '{s}'", .{ op, ta.name, tb.name, op });
            return;
        }
    } else if (a_named != b_named) {
        const named_v = if (a_named) a else b;
        const raw_v = if (a_named) b else a;
        const named_typ = named_v.object.named_value.typ.named_type;
        const raw_name = vmtyp.runtimeTypeName(raw_v);
        ctx.vs.setRuntimeErr("cannot apply '{s}' to {s} and {s}; wrap the {s} with {s}(...) or unwrap the named value with {s}(...)", .{
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
        ctx.vs.setRuntimeErr("cannot apply '{s}' to {s} and {s}; use matching numeric types such as 2.0 or float(2)", .{
            op,
            vmtyp.runtimeTypeName(a),
            vmtyp.runtimeTypeName(b),
        });
        return;
    }
    ctx.vs.setRuntimeErr("cannot apply '{s}' to {s} and {s}", .{ op, vmtyp.runtimeTypeName(a), vmtyp.runtimeTypeName(b) });
}

fn valueAsNumberForOp(ctx: VMContext, v: Value, other: Value, op: []const u8) !f64 {
    return vms.valueAsNumber(v) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(ctx, op, v, other);
        return err;
    };
}

// Ordering comparisons follow the same strictness as arithmetic: raw int
// and float do not mix (Ada/Go draw this line at typed values too).
fn checkComparableNumeric(ctx: VMContext, a: Value, b: Value, op: []const u8) !void {
    const ea = vms.unboxNamed(a);
    const eb = vms.unboxNamed(b);
    const ea_raw = ea == .int or ea == .float;
    const eb_raw = eb == .int or eb == .float;
    if (ea_raw and eb_raw and @as(VTag, ea) != @as(VTag, eb)) {
        ctx.vs.setRuntimeErr("cannot apply '{s}' to {s} and {s}; use matching numeric types such as 2.0 or float(2)", .{ op, vmtyp.runtimeTypeName(a), vmtyp.runtimeTypeName(b) });
        return error.TypeError;
    }
}

fn valueAsNumberForCompare(ctx: VMContext, v: Value, other: Value) !f64 {
    return vms.valueAsNumber(v) catch |err| {
        if (err == error.TypeError) {
            ctx.vs.setRuntimeErr("cannot compare {s} and {s}", .{ vmtyp.runtimeTypeName(v), vmtyp.runtimeTypeName(other) });
        }
        return err;
    };
}

fn compareNumericPair(ctx: VMContext, a: Value, b: Value, op: []const u8) !struct { an: f64, bn: f64 } {
    if (a == .int and b == .int) return .{ .an = @floatFromInt(a.int), .bn = @floatFromInt(b.int) };
    if (a == .float and b == .float) {
        if (!std.math.isFinite(a.float) or !std.math.isFinite(b.float)) {
            ctx.vs.setRuntimeErr("cannot compare non-finite value", .{});
            return error.TypeError;
        }
        return .{ .an = a.float, .bn = b.float };
    }
    try checkNamedValueCompatibility(ctx, a, b);
    try checkComparableNumeric(ctx, a, b, op);
    const an = try valueAsNumberForCompare(ctx, a, b);
    const bn = try valueAsNumberForCompare(ctx, b, a);
    if (!std.math.isFinite(an) or !std.math.isFinite(bn)) {
        ctx.vs.setRuntimeErr("cannot compare non-finite value", .{});
        return error.TypeError;
    }
    return .{ .an = an, .bn = bn };
}

fn valueAsIntForOp(ctx: VMContext, v: Value, other: Value, op: []const u8) !i64 {
    return vms.valueAsInt(v) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(ctx, op, v, other);
        return err;
    };
}

const NumericOpCtx = struct { an: f64, bn: f64, tag: VTag };

fn numericBinaryOp(ctx: VMContext, a: Value, b: Value, comptime op: []const u8) !NumericOpCtx {
    const tag = numericOpTag(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(ctx, op, a, b);
        return err;
    };
    const an = try valueAsNumberForOp(ctx, a, b, op);
    const bn = try valueAsNumberForOp(ctx, b, a, op);
    return .{ .an = an, .bn = bn, .tag = tag };
}

fn checkNamedValueCompatibility(ctx: VMContext, a: Value, b: Value) !void {
    const a_named = a == .object and a.object.* == .named_value;
    const b_named = b == .object and b.object.* == .named_value;
    if (a_named and b_named) {
        if (a.object.named_value.typ != b.object.named_value.typ) {
            const ta = a.object.named_value.typ;
            const tb = b.object.named_value.typ;
            // Two anonymous typed collections are compatible when they share the same
            // synthesized name (e.g. both "[]int") — each var decl creates its own
            // type object, so pointer equality would reject them.
            if (ta.named_type.is_anonymous and tb.named_type.is_anonymous and
                ta.named_type.base == tb.named_type.base and
                std.mem.eql(u8, ta.named_type.name, tb.named_type.name)) return;
            if (!namedTypeIsSubOf(ta, tb) and !namedTypeIsSubOf(tb, ta) and namedTypeCommonAncestor(ta, tb) == null) {
                ctx.vs.setRuntimeErr("cannot mix {s} and {s}; convert one side explicitly", .{ ta.named_type.name, tb.named_type.name });
                return error.TypeError;
            }
        }
    } else if (a_named != b_named) {
        const named = if (a_named) a else b;
        const plain = if (a_named) b else a;
        const nt = named.object.named_value.typ.named_type;
        // Anonymous typed arrays/maps compare transparently with plain arrays/maps.
        if (nt.is_anonymous and (nt.base == .array_t or nt.base == .map_t)) return;
        const nt_name = nt.name;
        if (plain == .null) {
            ctx.vs.setRuntimeErr("cannot compare {s} with null; {s} is non-nullable — use ?{s} to allow null", .{ nt_name, nt_name, nt_name });
        } else {
            ctx.vs.setRuntimeErr("cannot mix {s} and {s}; wrap the {s} with {s}(...) or unwrap with {s}(...)", .{
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

fn pushDecimalResultWithCarrier(ctx: VMContext, typ: *Object, d: i64) !void {
    const wrapped = try vmtyp.coerceNamedTypeResult(typ, .{ .decimal = d });
    try checkNamedTypePredicate(ctx, typ, wrapped.object.named_value.value);
    try ctx.vs.vmPush(wrapped);
}

fn bigIntBinOpWithPromotion(ctx: VMContext, a: Value, b: Value, op: enum { add, sub, mul, int_div, rem, mod }) !Value {
    const a_bi = vmbigint.isBigInt(a);
    const b_bi = vmbigint.isBigInt(b);
    var a_big = a;
    var b_big = b;
    if (!a_bi) {
        if (a != .int) {
            ctx.vs.setRuntimeErr("cannot apply '{s}' to bigint and {s}", .{ @tagName(op), vmtyp.runtimeTypeName(a) });
            return error.TypeError;
        }
        a_big = try vmbigint.promoteInt(a.int, b);
    }
    if (!b_bi) {
        if (b != .int) {
            ctx.vs.setRuntimeErr("cannot apply '{s}' to bigint and {s}", .{ @tagName(op), vmtyp.runtimeTypeName(b) });
            return error.TypeError;
        }
        b_big = try vmbigint.promoteInt(b.int, a_big);
    }
    return switch (op) {
        .add => vmbigint.addBi(a_big, b_big),
        .sub => vmbigint.subBi(a_big, b_big),
        .mul => vmbigint.mulBi(a_big, b_big),
        .int_div => vmbigint.intDivBi(a_big, b_big),
        .rem => vmbigint.remBi(a_big, b_big),
        .mod => vmbigint.modBi(a_big, b_big),
    };
}

fn computeAddResult(ctx: VMContext, a: Value, b: Value) !Value {
    if (a == .int and b == .int) return .{ .int = a.int + b.int };
    if (a == .float and b == .float) {
        const r = a.float + b.float;
        if (!std.math.isFinite(r)) { ctx.vs.setRuntimeErr("non-finite value in arithmetic operation", .{}); return error.TypeError; }
        return .{ .float = r };
    }
    if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
        return bigIntBinOpWithPromotion(ctx, a, b, .add);
    }
    if (isStringValueOrNamedString(a) and isStringValueOrNamedString(b)) {
        try ctx.vs.pushTempRoot(a);
        defer ctx.vs.popTempRoot();
        try ctx.vs.pushTempRoot(b);
        defer ctx.vs.popTempRoot();
        const sa = try vms.asStringValue(a);
        const sb = try vms.asStringValue(b);
        vmperf.countStringConcat(sa.len + sb.len);
        const result = try vmgc.concatDynString(sa, sb);
        const carrier = namedTypeCarrier(a, b) catch |err| {
            if (err == error.TypeError) setBinaryTypeError(ctx, "+", a, b);
            return err;
        };
        if (carrier) |typ| {
            try ctx.vs.pushTempRoot(result);
            defer ctx.vs.popTempRoot();
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
            if (err == error.TypeError) setBinaryTypeError(ctx, "+", a, b);
            return err;
        };
        const an = try valueAsNumberForOp(ctx, a, b, "+");
        const bn = try valueAsNumberForOp(ctx, b, a, "+");
        if (!std.math.isFinite(an + bn)) {
            ctx.vs.setRuntimeErr("non-finite value in arithmetic operation", .{});
            return error.TypeError;
        }
        return try wrapValueWithCarrier(ctx, a, b, makeNumeric(tag, an + bn), "+");
    }
}

fn pushSubResult(ctx: VMContext, a: Value, b: Value) !void {
    const an = try valueAsNumberForOp(ctx, a, b, "-");
    const bn = try valueAsNumberForOp(ctx, b, a, "-");
    const tag = numericOpTag(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(ctx, "-", a, b);
        return err;
    };
    try pushNumericResultWithCarrier(ctx, a, b, an - bn, tag, "-");
}

fn makeNumeric(tag: VTag, n: f64) Value {
    return switch (tag) {
        .int => .{ .int = @intFromFloat(n) },
        .float => .{ .float = n },
        else => .{ .int = @intFromFloat(n) },
    };
}

fn wrapValueWithCarrier(ctx: VMContext, a: Value, b: Value, val: Value, op: []const u8) !Value {
    // Fast path: plain scalars carry no named type.
    if (a != .object and b != .object) return val;
    const carrier = namedTypeCarrier(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(ctx, op, a, b);
        return err;
    };
    if (carrier) |typ| {
        const wrapped = try vmtyp.coerceNamedTypeResult(typ, val);
        try checkNamedTypePredicate(ctx, typ, wrapped.object.named_value.value);
        return wrapped;
    }
    return val;
}

fn pushIntResultWithCarrier(ctx: VMContext, a: Value, b: Value, n: i64, op: []const u8) !void {
    try ctx.vs.vmPush(try wrapValueWithCarrier(ctx, a, b, .{ .int = n }, op));
}

fn pushNumericResultWithCarrier(ctx: VMContext, a: Value, b: Value, n: f64, tag: VTag, op: []const u8) !void {
    if (!std.math.isFinite(n)) {
        ctx.vs.setRuntimeErr("non-finite value in arithmetic operation", .{});
        return error.TypeError;
    }
    try ctx.vs.vmPush(try wrapValueWithCarrier(ctx, a, b, makeNumeric(tag, n), op));
}

fn getShiftArgs(ctx: VMContext, op: []const u8) !struct { a: Value, b: Value, an: i64, shift: u6 } {
    const b = try ctx.vs.vmPop();
    const a = try ctx.vs.vmPop();
    const an = try valueAsIntForOp(ctx, a, b, op);
    const bn = try valueAsIntForOp(ctx, b, a, op);
    if (bn < 0) return error.RangeError;
    return .{ .a = a, .b = b, .an = an, .shift = @intCast(@min(bn, 63)) };
}

fn pushUnaryIntResult(ctx: VMContext, v: Value, result: Value) !void {
    _ = try ctx.vs.vmPop();
    if (v == .object and v.object.* == .named_value) {
        const wrapped = try vmtyp.coerceNamedTypeResult(v.object.named_value.typ, result);
        try checkNamedTypePredicate(ctx, v.object.named_value.typ, wrapped.object.named_value.value);
        try ctx.vs.vmPush(wrapped);
    } else {
        try ctx.vs.vmPush(result);
    }
}

fn pushStringResultWithCarrier(ctx: VMContext, a: Value, b: Value, raw: Value) !void {
    const carrier = namedTypeCarrier(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(ctx, "+", a, b);
        return err;
    };
    if (carrier) |typ| {
        try ctx.vs.pushTempRoot(raw);
        defer ctx.vs.popTempRoot();
        try ctx.vs.vmPush(try vmtyp.makeNamedValue(typ, raw));
    } else {
        try ctx.vs.vmPush(raw);
    }
}

fn prepareVariadicCall(ctx: VMContext, f: @import("value.zig").FuncObj, argc: u8) !void {
    if (!f.is_variadic) return;
    const fixed: usize = f.arity - 1;
    if (argc < fixed) return error.ArityMismatch;
    if (ctx.vs.stack_top < @as(usize, argc)) return error.StackUnderflow;
    const start = ctx.vs.stack_top - argc;
    const extra: usize = argc - fixed;
    const arr_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(Value, extra);
    @memcpy(items[0..extra], ctx.vs.stack[start + fixed .. start + fixed + extra]);
    arr_obj.* = .{ .array_managed = items[0..extra] };
    ctx.vs.stack[start + fixed] = .{ .object = arr_obj };
    ctx.vs.stack_top = start + fixed + 1;
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
        const parent_et = &parent_obj.enum_type;
        for (parent_et.members, 0..) |m, pi| {
            if (common.streq(m, member_name)) {
                const ordinal = if (parent_et.member_ints) |mi| mi[pi] else @as(i64, @intCast(pi));
                const ev = try vmgc.vmAllocObject();
                ev.* = .{ .enum_value = .{ .typ = parent_obj, .name = m, .ordinal = ordinal } };
                return .{ .object = ev };
            }
        }
        return error.UnknownStructField;
    } else {
        for (et.members, 0..) |m, ei| {
            if (common.streq(m, member_name)) {
                const ordinal = if (et.member_ints) |mi| mi[ei] else @as(i64, @intCast(ei));
                const ev = try vmgc.vmAllocObject();
                ev.* = .{ .enum_value = .{ .typ = obj, .name = m, .ordinal = ordinal } };
                return .{ .object = ev };
            }
        }
        return error.UnknownStructField;
    }
}

fn enumTypeValuesValue(ctx: VMContext, obj: *Object, et: vmod.EnumTypeObj) !Value {
    const arr_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(Value, et.members.len);
    for (et.members, 0..) |m, ei| {
        items[ei] = try enumTypeAllocValue(obj, m);
        arr_obj.* = .{ .array_managed = items[0 .. ei + 1] };
    }
    return .{ .object = arr_obj };
}

fn zeroValueForFieldSpec(spec: vmod.FieldTypeSpec) Value {
    for (spec.alts) |alt| {
        switch (alt.typ) {
            .null_t   => return .null,
            .int      => return .{ .int = 0 },
            .float    => return .{ .float = 0 },
            .decimal_t => return .{ .decimal = 0 },
            .boolean  => return .{ .boolean = false },
            .rune_t   => return .{ .rune = 0 },
            else      => {},
        }
    }
    return .null;
}

fn enumTypeFieldValue(ctx: VMContext, obj: *Object, name: []const u8) !Value {
    const et = obj.enum_type;
    if (common.streq(name, "name")) return .{ .string = try ctx.cs.internStr(et.name) };
    if (common.streq(name, "first")) {
        if (et.members.len == 0) return error.IndexOutOfBounds;
        return try enumTypeAllocValue(obj, et.members[0]);
    }
    if (common.streq(name, "last")) {
        if (et.members.len == 0) return error.IndexOutOfBounds;
        return try enumTypeAllocValue(obj, et.members[et.members.len - 1]);
    }
    if (common.streq(name, "values")) return try enumTypeValuesValue(ctx, obj, et);
    if (common.streq(name, "from_int")) {
        const fn_obj = try vmgc.vmAllocObject();
        fn_obj.* = .{ .enum_type_fn = .{ .typ = obj, .kind = .from_int } };
        return .{ .object = fn_obj };
    }
    if (common.streq(name, "succ") or common.streq(name, "pred")) {
        const fn_obj = try vmgc.vmAllocObject();
        const kind: vmod.EnumTypeFnKind = if (common.streq(name, "succ")) .succ else .pred;
        fn_obj.* = .{ .enum_type_fn = .{ .typ = obj, .kind = kind } };
        return .{ .object = fn_obj };
    }
    return try enumTypeAllocValue(obj, name);
}

fn namedTypeFieldValue(ctx: VMContext, obj: *Object, name: []const u8) !Value {
    const nt = obj.named_type;
    if (common.streq(name, "name")) return .{ .string = try ctx.cs.internStr(nt.name) };
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
        const fn_obj = try vmgc.vmAllocObject();
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
        const ctor = try vmgc.vmAllocObject();
        ctor.* = .{ .variant_ctor = .{
            .typ = obj,
            .tag = arm.name,
            .ordinal = arm_index,
            .payload_type = arm.payload_type,
        } };
        return .{ .object = ctor };
    }

    return vmtyp.variantConstruct(obj, arm.name, arm_index, .null);
}

fn variantTypeFieldValue(ctx: VMContext, obj: *Object, name: []const u8) !Value {
    const vt = obj.variant_type;
    if (common.streq(name, "name")) return .{ .string = try ctx.cs.internStr(vt.name) };
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

fn resolveQualifiedReceiverMethod(ctx: VMContext, qualified_name: []const u8, mname: []const u8) !Value {
    const total = qualified_name.len + 1 + mname.len;
    if (total > 512) return error.NotAMethodReceiver;
    var key_buf: [512]u8 = undefined;
    @memcpy(key_buf[0..qualified_name.len], qualified_name);
    key_buf[qualified_name.len] = '.';
    @memcpy(key_buf[qualified_name.len + 1 .. total], mname);
    return ctx.gs.get(key_buf[0..total]) orelse error.UnknownMethod;
}

fn resolveStructMethod(ctx: VMContext, inst: vmod.StructInstanceObj, mname: []const u8) !MethodResolution {
    if (resolveQualifiedReceiverMethod(ctx, inst.typ.struct_type.qualified_name, mname)) |method_func| {
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

fn resolveMethodReceiver(ctx: VMContext, recv: Value, mname: []const u8) !MethodResolution {
    if (recv != .object) return error.NotAMethodReceiver;
    switch (recv.object.*) {
        .struct_instance => |inst| return try resolveStructMethod(ctx, inst, mname),
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
                if (resolveQualifiedReceiverMethod(ctx, nt.qualified_name, mname)) |func| {
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
            return .{ .func = try resolveQualifiedReceiverMethod(ctx, ev.typ.enum_type.qualified_name, mname), .pass_recv = true };
        },
        .variant_value => |vv| {
            return .{ .func = try resolveQualifiedReceiverMethod(ctx, vv.typ.variant_type.qualified_name, mname), .pass_recv = true };
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

fn checkNamedTypePredicate(ctx: VMContext, nt_obj: *Object, inner: Value) !void {
    if (comptime !build_options.predicates) return;
    if (!ctx.vs.policy.enable_predicates) return;
    const nt = nt_obj.named_type;
    if (nt.predicate) |pred| {
        const result = callFunction(.{ .object = pred }, &[_]Value{inner}) catch |err| {
            if (err != error.PredicateFailed) {
                ctx.vs.setRuntimeErr("{s}: inside predicate for {s}", .{ @errorName(err), nt.name });
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
                ctx.vs.setRuntimeErr("{s}({s}): {s}", .{ nt.name, vstr, msg });
            } else {
                ctx.vs.setRuntimeErr("predicate failed for {s}({s})", .{ nt.name, vstr });
            }
            // Expose the human-readable message via core.recover() by storing a
            // pointer into runtime_err_buf as pending_panic_message.  runPanicUnwind
            // skips the @memcpy-self when it detects the alias.
            ctx.vs.pending_panic_message = ctx.vs.runtimeErrMsg();
            return error.PredicateFailed;
        }
    }
}

// Walk the parent chain and check each predicate in order (parent first).
fn checkNamedTypePredicateChain(ctx: VMContext, nt_obj: *Object, inner: Value) !void {
    if (comptime !build_options.predicates) return;
    if (!ctx.vs.policy.enable_predicates) return;
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
        try checkNamedTypePredicate(ctx, chain[i - 1], inner);
    }
}

fn canReturnFast(ctx: VMContext, fi: usize, retval: Value) bool {
    const frame = &ctx.vs.frames[fi];
    if (ctx.vs.defer_top != frame.defer_base) return false;
    if (!frame.has_typed_returns) return true;
    const f = switch (frame.func_obj.*) {
        .function => frame.func_obj.function,
        .closure => |cl| cl.func.function,
        else => return false,
    };
    if (!vmtyp.isPrimitiveReturn(f)) return false;
    return vmtyp.checkPrimitiveReturn(f, retval);
}

fn tryInlineGetGlobal(ctx: VMContext) !void {
    const jip = ctx.vs.ip;
    if (jip + 5 > ctx.cs.codeLen() or ctx.cs.codeByteAt(jip) != @intFromEnum(Op.get_global)) return;
    const ic_slot: u16 = @intCast((@as(usize, ctx.cs.codeByteAt(jip + 3)) << 8) | ctx.cs.codeByteAt(jip + 4));
    if (ic_slot != 0xffff) {
        ctx.vs.ip += 5;
        try ctx.vs.vmPush(ctx.gs.getAt(ic_slot));
    }
}

fn doReturn(ctx: VMContext, retval: Value) !bool {
    const fi = ctx.vs.frame_top - 1;
    if (canReturnFast(ctx, fi, retval)) {
        try doReturnFast(ctx, fi, retval);
        if (ctx.vs.call_depth_target) |d| {
            if (ctx.vs.frame_top == d) return true;
        }
        return false;
    }
    return try retSlowPath(ctx, retval);
}

fn doReturnFast(ctx: VMContext, fi: usize, retval: Value) !void {
    const frame = &ctx.vs.frames[fi];
    ctx.vs.frame_top = fi;
    ctx.vs.stack_top = if (frame.base > 0) frame.base - 1 else 0;
    ctx.vs.ip = frame.ret_ip;
    try ctx.vs.vmPush(retval);
}

fn readUpvalueCell(ctx: VMContext, idx: usize) !*Object {
    if (ctx.vs.frame_top == 0) return error.StackUnderflow;
    const frame = ctx.vs.frames[ctx.vs.frame_top - 1];
    const cl = frame.closure orelse return error.ImpossibleOpcodeState;
    if (cl.* != .closure) return error.ImpossibleOpcodeState;
    if (idx >= cl.closure.upvalues.len) return error.ImpossibleOpcodeState;
    return cl.closure.upvalues[idx];
}

// Warm call path: IC confirmed same callee.
// Arity/default/variadic checks are only skipped for call sites we explicitly
// decided were safe to cache in performCallIC.
fn enterFunctionFrameWarm(ctx: VMContext, f: @import("value.zig").FuncObj, func_obj: *Object, closure: ?*Object, argc: u8) !void {
    // GC pool-slot reuse can put a different function at the cached index.
    // Re-verify the IC invariants before trusting f.arity for the frame base.
    if (f.arity != argc or f.is_variadic or f.default_count != 0) {
        return enterFunctionFrame(ctx, f, func_obj, closure, argc);
    }
    if (f.has_typed_params) try vmtyp.enforcePrimitiveFuncArgTypes(f, argc);
    if (ctx.vs.frame_top >= ctx.vs.frames.len) return error.CallStackOverflow;
    ctx.vs.frames[ctx.vs.frame_top] = .{
        .ret_ip = ctx.vs.ip,
        .base = ctx.vs.stack_top - f.arity,
        .closure = closure,
        .func_obj = func_obj,
        .defer_base = ctx.vs.defer_top,
        .has_typed_returns = f.has_typed_returns,
    };
    ctx.vs.frame_top += 1;
    ctx.vs.ip = f.ip;
}

fn enterFunctionFrame(ctx: VMContext, f: @import("value.zig").FuncObj, func_obj: *Object, closure: ?*Object, argc: u8) !void {
    var effective_argc = argc;
    if (f.is_variadic) {
        if (argc < f.arity - 1) {
            var sig_buf: [256]u8 = undefined;
            const sig = vmtyp.funcSignatureStr(&sig_buf, f);
            if (f.name.len > 0) { ctx.vs.setRuntimeErr("{s}: expected at least {} argument(s), got {} for {s}", .{ f.name, f.arity - 1, argc, sig }); } else { ctx.vs.setRuntimeErr("expected at least {} argument(s), got {} for {s}", .{ f.arity - 1, argc, sig }); }
            return error.ArityMismatch;
        }
    } else if (f.arity != argc) {
        if (f.default_count > 0 and argc >= f.arity - f.default_count and argc < f.arity) {
            const first_default_param = f.arity - f.default_count;
            for (@as(usize, argc)..@as(usize, f.arity)) |pi| {
                const di = pi - @as(usize, first_default_param);
                try ctx.vs.vmPush(f.defaults[di]);
            }
            effective_argc = f.arity;
        } else {
            var sig_buf: [256]u8 = undefined;
            const sig = vmtyp.funcSignatureStr(&sig_buf, f);
            const min_argc = f.arity - f.default_count;
            if (f.name.len > 0) {
                if (f.default_count > 0) { ctx.vs.setRuntimeErr("{s}: expected {}-{} argument(s), got {} for {s}", .{ f.name, min_argc, f.arity, argc, sig }); } else { ctx.vs.setRuntimeErr("{s}: expected {} argument(s), got {} for {s}", .{ f.name, f.arity, argc, sig }); }
            } else {
                if (f.default_count > 0) { ctx.vs.setRuntimeErr("expected {}-{} argument(s), got {} for {s}", .{ min_argc, f.arity, argc, sig }); } else { ctx.vs.setRuntimeErr("expected {} argument(s), got {} for {s}", .{ f.arity, argc, sig }); }
            }
            return error.ArityMismatch;
        }
    }
    if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, effective_argc);
    try prepareVariadicCall(ctx, f, effective_argc);
    if (ctx.vs.frame_top >= ctx.vs.frames.len) return error.CallStackOverflow;
    ctx.vs.frames[ctx.vs.frame_top] = .{
        .ret_ip = ctx.vs.ip,
        .base = ctx.vs.stack_top - f.arity,
        .closure = closure,
        .func_obj = func_obj,
        .defer_base = ctx.vs.defer_top,
        .has_typed_returns = f.has_typed_returns,
    };
    ctx.vs.frame_top += 1;
    ctx.vs.ip = f.ip;
}

inline fn pop2push1(ctx: VMContext, v: Value) !void {
    _ = try ctx.vs.vmPop();
    _ = try ctx.vs.vmPop();
    try ctx.vs.vmPush(v);
}

fn performCallIC(ctx: VMContext, argc: u8, ic_base: usize, ic_slot: u16) !void {
    if (ctx.vs.stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const func_val = ctx.vs.stack[ctx.vs.stack_top - argc - 1];
    if (func_val == .object) {
        const obj = func_val.object;
        const obj_idx = heap.objectPoolIndex(obj);
        if (ic_slot != 0xFFFF and obj_idx == ic_slot) {
            return switch (obj.*) {
                .function => |f| enterFunctionFrameWarm(ctx, f, obj, null, argc),
                .closure  => |cl| enterFunctionFrameWarm(ctx, cl.func.function, cl.func, obj, argc),
                else      => performCall(ctx, argc),
            };
        }
        try performCall(ctx, argc);
        if (ic_slot == 0xFFFF and obj_idx != 0xFFFF) {
            switch (obj.*) {
                .function => |f| if (!f.is_variadic and f.default_count == 0 and (f.arity == argc) and (!f.has_typed_params or vmtyp.canInlinePrimitiveArgs(f, argc))) {
                    ctx.cs.patchByte(ic_base,     @intCast((obj_idx >> 8) & 0xFF));
                    ctx.cs.patchByte(ic_base + 1, @intCast(obj_idx & 0xFF));
                },
                .closure => |cl| if (!cl.func.function.is_variadic and cl.func.function.default_count == 0 and (cl.func.function.arity == argc) and (!cl.func.function.has_typed_params or vmtyp.canInlinePrimitiveArgs(cl.func.function, argc))) {
                    ctx.cs.patchByte(ic_base,     @intCast((obj_idx >> 8) & 0xFF));
                    ctx.cs.patchByte(ic_base + 1, @intCast(obj_idx & 0xFF));
                },
                else => {},
            }
        }
        return;
    }
    return performCall(ctx, argc);
}

fn performCall(ctx: VMContext, argc: u8) !void {
    if (ctx.vs.stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const func_val = ctx.vs.stack[ctx.vs.stack_top - argc - 1];
    if (func_val != .object) {
        return error.NotAFunction;
    }
    const obj = func_val.object;
    switch (obj.*) {
        .function => |f| {
            try enterFunctionFrame(ctx, f, obj, null, argc);
        },
        .closure => |cl| {
            try enterFunctionFrame(ctx, cl.func.function, cl.func, obj, argc);
        },
        .native_function => |nf| {
            try vmnative.callNative(nf, argc);
        },
        .host_module_function => |hmf| {
            try vmnative.callHostModule(hmf, argc);
        },
        .named_type => {
            if (argc != 1) return error.ArityMismatch;
            const arg = ctx.vs.stack[ctx.vs.stack_top - 1];
            const out = try vmtyp.constructNamedType(obj, arg);
            try checkNamedTypePredicateChain(ctx, obj, out.object.named_value.value);
            try pop2push1(ctx, out);
        },
        .enum_type => |et| {
            if (et.parent_name == null) return error.NotAFunction;
            if (argc != 1) return error.ArityMismatch;
            const arg = ctx.vs.stack[ctx.vs.stack_top - 1];
            if (arg != .object or arg.object.* != .enum_value) return error.TypeError;
            const parent_obj = vmtyp.resolveEnumParent(obj) orelse return error.TypeError;
            if (arg.object.enum_value.typ != parent_obj) return error.TypeError;
            var found = false;
            for (et.members) |m| {
                if (common.streq(m, arg.object.enum_value.name)) { found = true; break; }
            }
            if (!found) return error.RangeError;
            try pop2push1(ctx, arg);
        },
        .variant_ctor => |vc| {
            if (argc != 1) return error.ArityMismatch;
            const payload = ctx.vs.stack[ctx.vs.stack_top - 1];
            if (vc.payload_type) |pt| {
                if (!vmtyp.matchesTypeSpec(payload, pt)) return error.TypeError;
            }
            try pop2push1(ctx, try vmtyp.variantConstruct(vc.typ, vc.tag, vc.ordinal, payload));
        },
        .named_type_fn => |nf| {
            if (argc != 1) return error.ArityMismatch;
            const arg = ctx.vs.stack[ctx.vs.stack_top - 1];
            const out = try vmtyp.applyNamedTypeFn(nf.typ, nf.kind, arg);
            try pop2push1(ctx, out);
        },
        .enum_type_fn => |ef| {
            if (argc != 1) return error.ArityMismatch;
            const arg = ctx.vs.stack[ctx.vs.stack_top - 1];
            const et = &ef.typ.enum_type;
            switch (ef.kind) {
                .from_int => {
                    if (arg != .int) return error.TypeError;
                    const n = arg.int;
                    for (et.members, 0..) |m, mi| {
                        const ordinal = if (et.member_ints) |ints| ints[mi] else @as(i64, @intCast(mi));
                        if (ordinal == n) {
                            const ev = try vmgc.vmAllocObject();
                            ev.* = .{ .enum_value = .{ .typ = ef.typ, .name = m, .ordinal = ordinal } };
                            try pop2push1(ctx, .{ .object = ev });
                            return;
                        }
                    }
                    try pop2push1(ctx, .null);
                },
                .succ, .pred => {
                    if (arg != .object or arg.object.* != .enum_value) return error.TypeError;
                    const ev = arg.object.enum_value;
                    var cur_idx: usize = 0;
                    var found: bool = false;
                    for (et.members, 0..) |m, mi| {
                        if (common.streq(m, ev.name)) { cur_idx = mi; found = true; break; }
                    }
                    if (!found) return error.UnknownStructField;
                    const next_idx: usize = if (ef.kind == .succ)
                        (cur_idx + 1) % et.members.len
                    else
                        if (cur_idx == 0) et.members.len - 1 else cur_idx - 1;
                    const next_ordinal = if (et.member_ints) |ints| ints[next_idx] else @as(i64, @intCast(next_idx));
                    const new_ev = try vmgc.vmAllocObject();
                    new_ev.* = .{ .enum_value = .{ .typ = ef.typ, .name = et.members[next_idx], .ordinal = next_ordinal } };
                    try pop2push1(ctx, .{ .object = new_ev });
                },
            }
        },
        else => return error.NotAFunction,
    }
}

fn writeFrameLocal(ctx: VMContext, abs_slot: usize, v: Value) void {
    std.debug.assert(abs_slot < ctx.vs.stack.len);
    const cur = ctx.vs.stack[abs_slot];
    if (cur == .object and cur.object.* == .cell) {
        cur.object.cell.value = v;
    } else {
        ctx.vs.stack[abs_slot] = v;
    }
}

fn tryTailCall(ctx: VMContext, argc: u8) !bool {
    if (ctx.vs.frame_top == 0) return false;
    if (ctx.vs.ip >= ctx.cs.codeLen()) return false;
    const next_op: Op = @enumFromInt(ctx.cs.codeByteAt(ctx.vs.ip));
    if (next_op != .ret) return false;

    if (ctx.vs.stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const callee_idx = ctx.vs.stack_top - argc - 1;
    const func_val = ctx.vs.stack[callee_idx];
    if (func_val != .object) return false;
    const callee_obj = func_val.object;

    const frame_idx = ctx.vs.frame_top - 1;
    const frame = &ctx.vs.frames[frame_idx];
    const f_obj: *Object, const closure: ?*Object, const f = switch (callee_obj.*) {
        .closure => |cl| .{ cl.func, callee_obj, cl.func.function },
        .function => |f| .{ callee_obj, null, f },
        else => return false,
    };
    if (f.is_variadic) return false;
    if (f.arity != argc) return false;
    if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
    for (0..argc) |i| writeFrameLocal(ctx, frame.base + i, ctx.vs.stack[callee_idx + 1 + i]);
    frame.closure = closure;
    frame.func_obj = f_obj;
    ctx.vs.stack_top = frame.base + argc;
    ctx.vs.ip = f.ip;
    return true;
}

fn iterInit(v: Value) !Value {
    const obj = try vmgc.vmAllocObject();
    const iv = vms.unboxNamed(v);
    switch (iv) {
        .object => |o| switch (o.*) {
            .dyn_string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s, .string_managed = true, .source = o } },
            .string_view => |sv| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = sv.bytes, .string_managed = true, .source = sv.source } },
            .array_view => |av| obj.* = .{ .iterator = .{ .kind = .array, .index = 0, .array = av.items, .source = o } },
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

fn iterAdvance(ctx: VMContext, cond: bool) !bool {
    if (!cond) {
        try ctx.vs.vmPush(.{ .boolean = false });
        return false;
    }
    return true;
}

fn iterNext1(ctx: VMContext, it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (!try iterAdvance(ctx, it.index < it.array.len)) return;
            const v = it.array[it.index];
            it.index += 1;
            try ctx.vs.vmPush(v);
            try ctx.vs.vmPush(.{ .boolean = true });
        },
        .string => {
            if (!try iterAdvance(ctx, it.index < it.string.len)) return;
            const ridx = it.rune_index;
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            if (it.string_managed) {
                try ctx.vs.vmPush(try vmgc.makeStringView(it.string[start..end], it.source.?));
            } else {
                try ctx.vs.vmPush(try vmgc.makeDynString(it.string[start..end]));
            }
            it.index = end;
            it.rune_index += 1;
            try ctx.vs.vmPush(.{ .boolean = true });
        },
        .map => {
            if (!try iterAdvance(ctx, it.index < it.map.len)) return;
            const k = it.map[it.index].key;
            it.index += 1;
            try ctx.vs.vmPush(k);
            try ctx.vs.vmPush(.{ .boolean = true });
        },
        .range => {
            if (it.range_current > it.range_max) {
                try ctx.vs.vmPush(.{ .boolean = false });
                return;
            }
            const typ_obj = it.source.?;
            const nt = typ_obj.named_type;
            const val = try vmtyp.makeNamedValue(typ_obj, if (nt.base == .float) .{ .float = it.range_current } else .{ .int = @intFromFloat(it.range_current) });
            const next = it.range_current + 1.0;
            if (next == it.range_current) return error.RangeError;
            it.range_current = next;
            try ctx.vs.vmPush(val);
            try ctx.vs.vmPush(.{ .boolean = true });
        },
    }
}

fn iterNext2(ctx: VMContext, it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (!try iterAdvance(ctx, it.index < it.array.len)) return;
            try ctx.vs.vmPush(.{ .int = @intCast(it.index) });
            try ctx.vs.vmPush(it.array[it.index]);
            it.index += 1;
            try ctx.vs.vmPush(.{ .boolean = true });
        },
        .string => {
            if (!try iterAdvance(ctx, it.index < it.string.len)) return;
            const ridx = it.rune_index;
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            try ctx.vs.vmPush(.{ .int = @intCast(it.rune_index) });
            if (it.string_managed) {
                try ctx.vs.vmPush(try vmgc.makeStringView(it.string[start..end], it.source.?));
            } else {
                try ctx.vs.vmPush(try vmgc.makeDynString(it.string[start..end]));
            }
            it.index = end;
            it.rune_index += 1;
            try ctx.vs.vmPush(.{ .boolean = true });
        },
        .map => {
            if (!try iterAdvance(ctx, it.index < it.map.len)) return;
            try ctx.vs.vmPush(it.map[it.index].key);
            try ctx.vs.vmPush(it.map[it.index].value);
            it.index += 1;
            try ctx.vs.vmPush(.{ .boolean = true });
        },
        .range => return error.TypeError,
    }
}

// Slow-path return: handles defers and/or typed-return enforcement.
// Returns true if runInner should stop (call_depth_target reached), false to continue.
// Fast-path returns (no defers, no typed returns) are inlined in the ret/ret_const handlers.
fn retSlowPath(ctx: VMContext, retval_in: Value) !bool {
    var retval = retval_in;
    const fi = ctx.vs.frame_top - 1;
    const frame = &ctx.vs.frames[fi];
    const saved_temp_root = ctx.vs.tempRootDepth();
    defer ctx.vs.restoreTempRoots(saved_temp_root);
    try ctx.vs.pushTempRoot(retval);
    while (ctx.vs.defer_top > frame.defer_base) {
        ctx.vs.defer_top -= 1;
        const deferred = ctx.vs.defer_stack[ctx.vs.defer_top];
        try ctx.vs.pushTempRoot(deferred);
        const arr = try vms.asArraySlice(deferred.object);
        if (arr.len > 0) {
            if (arr.len > 256) return error.ArityMismatch;
            const dargc: u8 = @intCast(arr.len - 1);
            for (arr) |v| try ctx.vs.vmPush(v);
            const depth_before = ctx.vs.frame_top;
            try performCall(ctx, dargc);
            if (ctx.vs.frame_top > depth_before) {
                const prev_target = ctx.vs.call_depth_target;
                ctx.vs.call_depth_target = depth_before;
                defer ctx.vs.call_depth_target = prev_target;
                try run(ctx);
            }
            _ = try ctx.vs.vmPop();
        }
        ctx.vs.popTempRoot();
    }
    const fsig_ret = vmtyp.frameFuncSig(frame.func_obj) catch null;
    if (fsig_ret) |fsig| {
        if (fsig.named_return_count > 0) {
            ctx.vs.popTempRoot();
            const nrbase = frame.base + fsig.arity;
            if (nrbase >= ctx.vs.stack.len) return error.StackOverflow;
            if (fsig.named_return_count == 1) {
                const raw = ctx.vs.stack[nrbase];
                retval = vms.unboxCell(raw);
            } else {
                const nrc: usize = fsig.named_return_count;
                const arr_obj = try vmgc.vmAllocObject();
                arr_obj.* = .{ .array = &[_]Value{} };
                try ctx.vs.pushTempRoot(.{ .object = arr_obj });
                const items = try vmgc.vmAllocManagedSlice(Value, nrc);
                for (0..nrc) |ri| {
                    if (nrbase + ri >= ctx.vs.stack.len) return error.StackOverflow;
                    const raw = ctx.vs.stack[nrbase + ri];
                    items[ri] = vms.unboxCell(raw);
                }
                arr_obj.* = .{ .array_managed = items[0..nrc] };
                ctx.vs.popTempRoot();
                retval = .{ .object = arr_obj };
            }
            try ctx.vs.pushTempRoot(retval);
        }
    }
    ctx.vs.popTempRoot();
    ctx.vs.frame_top = fi;
    if (frame.has_typed_returns) {
        if (fsig_ret) |fsig| try vmtyp.enforceFuncReturnTypes(fsig, retval);
    }
    ctx.vs.stack_top = if (frame.base > 0) frame.base - 1 else 0;
    ctx.vs.ip = frame.ret_ip;
    try ctx.vs.vmPush(retval);
    if (ctx.vs.call_depth_target) |d| {
        if (ctx.vs.frame_top == d) return true;
    }
    return false;
}

// ── Large opcode handlers (extracted from runInner for readability) ──────────

fn pushFieldFromObject(ctx: VMContext, obj: *Object, name_idx: usize, ic_base: usize, ic_type_idx: usize, ic_fidx: u8) !void {
    const name = (try ctx.cs.constAt(name_idx)).string.bytes;
    switch (obj.*) {
        .array, .array_managed, .array_view, .array_capacity => {
            const items = try vms.asArraySlice(obj);
            if (common.streq(name, "first")) {
                if (items.len == 0) return error.IndexOutOfBounds;
                try ctx.vs.vmPush(items[0]);
            } else if (common.streq(name, "last")) {
                if (items.len == 0) return error.IndexOutOfBounds;
                try ctx.vs.vmPush(items[items.len - 1]);
            } else return error.TypeError;
        },
        .struct_instance => |inst| {
            const tpi = heap.objectPoolIndex(inst.typ);
            if (ic_type_idx == @as(usize, tpi) and ic_fidx != 0xFF) {
                try ctx.vs.vmPush(inst.fields[ic_fidx].value);
            } else {
                const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, name) orelse {
                    ctx.vs.setRuntimeErr("no field '{s}' on type '{s}'", .{ name, inst.typ.struct_type.name });
                    return error.UnknownStructField;
                };
                if (fi <= 0xFE) {
                    ctx.cs.patchByte(ic_base,     @intCast((tpi >> 8) & 0xFF));
                    ctx.cs.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                    ctx.cs.patchByte(ic_base + 2, @intCast(fi));
                }
                try ctx.vs.vmPush(inst.fields[fi].value);
            }
        },
        .map, .map_managed, .map_hashed => {
            if (common.streq(name, "len")) {
                const items = try vms.asMapSlice(obj);
                try ctx.vs.vmPush(.{ .int = @intCast(items.len) });
            } else {
                var name_ss = StringSlice{ .bytes = name };
                const key_v = Value{ .string = &name_ss };
                try ctx.vs.vmPush(try vmmap.mapGet(obj, key_v) orelse .null);
            }
        },
        .enum_type => try ctx.vs.vmPush(try enumTypeFieldValue(ctx, obj, name)),
        .enum_value => |ev| {
            if (common.streq(name, "name")) {
                try ctx.vs.vmPush(.{ .string = try ctx.cs.internStr(ev.name) });
            } else if (common.streq(name, "int")) {
                try ctx.vs.vmPush(.{ .int = ev.ordinal });
            } else if (common.streq(name, "ordinal")) {
                const et = &ev.typ.enum_type;
                var found_ord: bool = false;
                for (et.members, 0..) |m, mi| {
                    if (common.streq(m, ev.name)) {
                        try ctx.vs.vmPush(.{ .int = @as(i64, @intCast(mi)) });
                        found_ord = true;
                        break;
                    }
                }
                if (!found_ord) return error.UnknownStructField;
            } else return error.UnknownStructField;
        },
        .named_type => try ctx.vs.vmPush(try namedTypeFieldValue(ctx, obj, name)),
        .variant_type => try ctx.vs.vmPush(try variantTypeFieldValue(ctx, obj, name)),
        .variant_value => |vv| try ctx.vs.vmPush(try variantValueFieldValue(vv, name)),
        else => return error.TypeError,
    }
}

fn opGetLocalGetField(ctx: VMContext) !void {
    const slot = try ctx.vs.vmByte();
    ctx.vs.ip += 1; // skip embedded get_field opcode byte
    const name_idx = try ctx.vs.vmShort();
    const ic_base = ctx.vs.ip;
    const ic_type_idx = try ctx.vs.vmShort();
    const ic_fidx = try ctx.vs.vmByte();
    const raw = try readLocalSlot(ctx, slot);
    const container = vms.unboxNamed(raw);
    if (container != .object) return error.TypeError;
    try pushFieldFromObject(ctx, container.object, name_idx, ic_base, ic_type_idx, ic_fidx);
}

fn opGetIndex(ctx: VMContext) !void {
    const idx_v = try ctx.vs.vmPop();
    const raw = try ctx.vs.vmPop();
    // Fast path: hashed-map lookup never allocates → no GC roots needed,
    // no unboxNamed, no full container-kind switch.
    if (raw == .object and raw.object.* == .map_hashed) {
        try ctx.vs.vmPush(try vmmap.mapGet(raw.object, idx_v) orelse .null);
        return;
    }
    var rooted_raw = false;
    var rooted_idx = false;
    if (raw == .object) { try ctx.vs.pushTempRoot(raw); rooted_raw = true; }
    if (idx_v == .object) { try ctx.vs.pushTempRoot(idx_v); rooted_idx = true; }
    defer {
        if (rooted_idx) ctx.vs.popTempRoot();
        if (rooted_raw) ctx.vs.popTempRoot();
    }
    const container = vms.unboxNamed(raw);
    switch (container) {
        .object => |obj| switch (obj.*) {
            .dyn_string, .string_view => {
                try ctx.vs.vmPush(try vmstr.stringIndex(container, idx_v));
            },
            .array, .array_managed, .array_view, .array_capacity => {
                try ctx.vs.vmPush(try vmarr.arrayRead(obj, idx_v));
            },
            .map, .map_managed, .map_hashed => {
                try ctx.vs.vmPush(try vmmap.mapGet(obj, idx_v) orelse .null);
            },
            .struct_instance => |inst| {
                const key = try vms.asStringValue(idx_v);
                const idx = vmtyp.findFieldIndex(inst.typ.struct_type.fields, key) orelse return error.UnknownStructField;
                try ctx.vs.vmPush(inst.fields[idx].value);
            },
            .enum_type => {
                try ctx.vs.vmPush(try enumTypeFieldValue(ctx, obj, try vms.asStringValue(idx_v)));
            },
            .named_type => {
                try ctx.vs.vmPush(try namedTypeFieldValue(ctx, obj, try vms.asStringValue(idx_v)));
            },
            .variant_type => {
                try ctx.vs.vmPush(try variantTypeFieldValue(ctx, obj, try vms.asStringValue(idx_v)));
            },
            .variant_value => |vv| {
                const key = try vms.asStringValue(idx_v);
                try ctx.vs.vmPush(try variantValueFieldValue(vv, key));
            },
            else => return error.TypeError,
        },
        .string => {
            try ctx.vs.vmPush(try vmstr.stringIndex(container, idx_v));
        },
        else => return error.TypeError,
    }
}

fn opSetIndex(ctx: VMContext) !void {
    const val = try ctx.vs.vmPop();
    const idx_v = try ctx.vs.vmPop();
    const raw_c = try ctx.vs.vmPop();
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
        .array, .array_managed, .array_view, .array_capacity => {
            try vmarr.arrayWrite(container.object, idx_v, val);
        },
        .map, .map_managed, .map_hashed => try vmmap.mapSet(container, idx_v, val),
        .struct_instance => |inst| {
            const key = try vms.asStringValue(idx_v);
            const idx = vmtyp.findFieldIndex(inst.typ.struct_type.fields, key) orelse {
                ctx.vs.setRuntimeErr("no field '{s}' on type '{s}'", .{ key, inst.typ.struct_type.name });
                return error.UnknownStructField;
            };
            if (inst.typ.struct_type.fields[idx].is_const) { ctx.vs.setRuntimeErr("field '{s}' of '{s}' is const", .{ key, inst.typ.struct_type.name }); return error.AssignToConst; }
            if (!vmtyp.matchesFieldType(val, inst.typ.struct_type.fields[idx])) return error.StructFieldTypeMismatch;
            inst.fields[idx].value = val;
        },
        else => return error.TypeError,
    }
}

fn opInvokeMethod(ctx: VMContext) !void {
    const mname = (try ctx.vs.vmConst()).string.bytes;
    const argc = try ctx.vs.vmByte();
    const ic_base = ctx.vs.ip;
    const ic_type_idx = try ctx.vs.vmShort(); // ic_type pool index (0xFFFF = cold)
    const ic_func_idx = try ctx.vs.vmShort(); // ic_func pool index (0xFFFF = cold)
    if (ctx.vs.stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const recv_idx = ctx.vs.stack_top - argc - 1;
    const recv = ctx.vs.stack[recv_idx];
    if (recv != .object) return error.NotAMethodReceiver;
    switch (recv.object.*) {
        .struct_instance => |inst| {
            const tpi = heap.objectPoolIndex(inst.typ);
            var resolved: MethodResolution = undefined;
            if (ic_type_idx == @as(usize, tpi) and ic_func_idx != 0xFFFF) {
                if (ic_func_idx >= heap.MaxObjects) return error.NotAMethodReceiver;
                resolved = .{ .func = .{ .object = heap.objectAt(@intCast(ic_func_idx)) }, .pass_recv = true };
            } else {
                resolved = try resolveStructMethod(ctx, inst, mname);
                if (resolved.pass_recv and resolved.func == .object) {
                    const fpi = heap.objectPoolIndex(resolved.func.object);
                    if (fpi != 0xFFFF) {
                        ctx.cs.patchByte(ic_base + 0, @intCast((tpi >> 8) & 0xFF));
                        ctx.cs.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                        ctx.cs.patchByte(ic_base + 2, @intCast((fpi >> 8) & 0xFF));
                        ctx.cs.patchByte(ic_base + 3, @intCast(fpi & 0xFF));
                    }
                }
            }
            if (resolved.pass_recv) {
                try insertReceiverAndCall(ctx, recv_idx, resolved.func, recv, argc);
            } else {
                ctx.vs.stack[recv_idx] = resolved.func;
                try performCall(ctx, argc);
            }
        },
        .map, .map_managed, .map_hashed => {
            const resolved = try resolveMethodReceiver(ctx, recv, mname);
            ctx.vs.stack[recv_idx] = resolved.func;
            try performCall(ctx, argc);
        },
        .variant_type => |vt| {
            const vi = for (vt.arms, 0..) |arm, i| {
                if (common.streq(arm.name, mname)) break i;
            } else return error.UnknownStructField;
            const arm = vt.arms[vi];
            if (arm.has_payload) {
                if (argc != 1) return error.ArityMismatch;
                const payload = ctx.vs.stack[ctx.vs.stack_top - 1];
                if (arm.payload_type) |pt| {
                    if (!vmtyp.matchesTypeSpec(payload, pt)) return error.TypeError;
                }
                const vv = try vmtyp.variantConstruct(recv.object, arm.name, vi, payload);
                for (0..@as(usize, argc) + 1) |_| _ = try ctx.vs.vmPop();
                try ctx.vs.vmPush(vv);
            } else {
                if (argc != 0) return error.ArityMismatch;
                const vv = try vmtyp.variantConstruct(recv.object, arm.name, vi, .null);
                _ = try ctx.vs.vmPop(); // pop recv
                try ctx.vs.vmPush(vv);
            }
        },
        .named_type => {
            if (argc != 1) return error.ArityMismatch;
            if (!common.streq(mname, "succ") and !common.streq(mname, "pred")) return error.UnknownMethod;
            const kind: @import("value.zig").NamedTypeFnKind = if (common.streq(mname, "succ")) .succ else .pred;
            const arg = ctx.vs.stack[recv_idx + 1];
            const out = try vmtyp.applyNamedTypeFn(recv.object, kind, arg);
            if (recv_idx >= ctx.vs.stack_top) return error.StackUnderflow;
            ctx.vs.stack_top = recv_idx;
            try ctx.vs.vmPush(out);
        },
        .string_builder => |*sb| {
            if (common.streq(mname, "write")) {
                if (argc != 1) return error.ArityMismatch;
                const s_bytes = try vms.asStringValue(ctx.vs.stack[recv_idx + 1]);
                const needed = sb.len + s_bytes.len;
                if (needed > sb.buf.len) {
                    // Grow: receiver stays on stack so GC keeps the object alive.
                    const new_buf = try vmgc.vmAllocManagedBytes(needed);
                    @memcpy(new_buf[0..sb.len], sb.buf[0..sb.len]);
                    const old_buf = sb.buf;
                    sb.buf = new_buf; // update before free so paranoia doesn't see the old ref
                    heap.freeBytesManaged(old_buf);
                }
                @memcpy(sb.buf[sb.len..][0..s_bytes.len], s_bytes);
                sb.len = needed;
                if (recv_idx >= ctx.vs.stack_top) return error.StackUnderflow;
                ctx.vs.stack_top = recv_idx;
                try ctx.vs.vmPush(.null);
            } else if (common.streq(mname, "str")) {
                if (argc != 0) return error.ArityMismatch;
                const result = try vmgc.makeDynString(sb.buf[0..sb.len]);
                if (recv_idx >= ctx.vs.stack_top) return error.StackUnderflow;
                ctx.vs.stack_top = recv_idx;
                try ctx.vs.vmPush(result);
            } else if (common.streq(mname, "reset")) {
                if (argc != 0) return error.ArityMismatch;
                sb.len = 0;
                if (recv_idx >= ctx.vs.stack_top) return error.StackUnderflow;
                ctx.vs.stack_top = recv_idx;
                try ctx.vs.vmPush(.null);
            } else return error.UnknownMethod;
        },
        .named_value, .enum_value, .variant_value => {
            const resolved = try resolveMethodReceiver(ctx, recv, mname);
            try insertReceiverAndCall(ctx, recv_idx, resolved.func, recv, argc);
        },
        .enum_type => {
            const callable = try enumTypeFieldValue(ctx, recv.object, mname);
            ctx.vs.stack[recv_idx] = callable;
            try performCall(ctx, argc);
        },
        .array, .array_managed, .array_view, .array_capacity => {
            if (argc != 0) return error.ArityMismatch;
            const items = try vms.asArraySlice(recv.object);
            if (common.streq(mname, "first")) {
                if (items.len == 0) return error.IndexOutOfBounds;
                ctx.vs.stack_top = recv_idx;
                try ctx.vs.vmPush(items[0]);
            } else if (common.streq(mname, "last")) {
                if (items.len == 0) return error.IndexOutOfBounds;
                ctx.vs.stack_top = recv_idx;
                try ctx.vs.vmPush(items[items.len - 1]);
            } else return error.UnknownMethod;
        },
        else => return error.NotAMethodReceiver,
    }
}

fn opGetField(ctx: VMContext) !void {
    const name_idx = try ctx.vs.vmShort();
    const ic_base = ctx.vs.ip;
    const ic_type_idx = try ctx.vs.vmShort();
    const ic_fidx = try ctx.vs.vmByte();
    const raw = try ctx.vs.vmPop();
    var rooted_raw = false;
    if (raw == .object) { try ctx.vs.pushTempRoot(raw); rooted_raw = true; }
    defer if (rooted_raw) ctx.vs.popTempRoot();
    const container = vms.unboxNamed(raw);
    if (container != .object) return error.TypeError;
    try pushFieldFromObject(ctx, container.object, name_idx, ic_base, ic_type_idx, ic_fidx);
}

fn opSetField(ctx: VMContext) !void {
    const name_idx = try ctx.vs.vmShort();
    const ic_base = ctx.vs.ip;
    const ic_type_idx = try ctx.vs.vmShort();
    const ic_fidx = try ctx.vs.vmByte();
    const name_val = try ctx.cs.constAt(name_idx);
    const name = name_val.string.bytes;
    const val = try ctx.vs.vmPop();
    const raw_c = try ctx.vs.vmPop();
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
                    ctx.vs.setRuntimeErr("no field '{s}' on type '{s}'", .{ name, inst.typ.struct_type.name });
                    return error.UnknownStructField;
                };
                fi = found;
                if (found <= 0xFE) {
                    ctx.cs.patchByte(ic_base,     @intCast((tpi >> 8) & 0xFF));
                    ctx.cs.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                    ctx.cs.patchByte(ic_base + 2, @intCast(found));
                }
            }
            if (inst.typ.struct_type.fields[fi].is_const) { ctx.vs.setRuntimeErr("field '{s}' of '{s}' is const", .{ name, inst.typ.struct_type.name }); return error.AssignToConst; }
            if (!vmtyp.matchesFieldType(val, inst.typ.struct_type.fields[fi])) return error.StructFieldTypeMismatch;
            inst.fields[fi].value = val;
        },
        .map, .map_managed, .map_hashed => try vmmap.mapSet(container, name_val, val),
        else => return error.TypeError,
    }
}

fn insertReceiverAndCall(ctx: VMContext, recv_idx: usize, func: Value, recv: Value, argc: u8) !void {
    if (ctx.vs.stack_top >= ctx.vs.stack.len) return error.StackOverflow;
    var i: usize = ctx.vs.stack_top;
    while (i > recv_idx + 1) : (i -= 1) ctx.vs.stack[i] = ctx.vs.stack[i - 1];
    ctx.vs.stack_top += 1;
    ctx.vs.stack[recv_idx] = func;
    ctx.vs.stack[recv_idx + 1] = recv;
    try performCall(ctx, argc + 1);
}

fn opDeferInvokeMethod(ctx: VMContext) !void {
    const mname = (try ctx.vs.vmConst()).string.bytes;
    const argc = try ctx.vs.vmByte();
    if (ctx.vs.defer_top >= ctx.vs.defer_stack.len) return error.DeferStackOverflow;
    if (ctx.vs.stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const recv_idx = ctx.vs.stack_top - @as(usize, argc) - 1;
    const recv = ctx.vs.stack[recv_idx];
    var func: Value = undefined;
    var pass_recv: bool = undefined;
    switch (recv.object.*) {
        .struct_instance, .map, .map_managed, .map_hashed, .named_value, .enum_value, .variant_value => {
            const resolved = try resolveMethodReceiver(ctx, recv, mname);
            func = resolved.func;
            pass_recv = resolved.pass_recv;
        },
        else => return error.NotAMethodReceiver,
    }
    const extra: usize = if (pass_recv) 1 else 0;
    const total: usize = 1 + extra + @as(usize, argc);
    const arr_obj = try vmgc.vmAllocObject();
    arr_obj.* = .{ .array_managed = &[_]Value{} }; // safe init before GC can see it via temp root
    try ctx.vs.pushTempRoot(.{ .object = arr_obj });
    defer ctx.vs.popTempRoot();
    const items = try vmgc.vmAllocManagedSlice(Value, total);
    items[0] = func;
    if (pass_recv) items[1] = recv;
    @memcpy(items[1 + extra .. 1 + extra + @as(usize, argc)], ctx.vs.stack[recv_idx + 1 .. recv_idx + 1 + @as(usize, argc)]);
    arr_obj.* = .{ .array_managed = items[0..total] };
    ctx.vs.defer_stack[ctx.vs.defer_top] = .{ .object = arr_obj };
    ctx.vs.defer_top += 1;
    ctx.vs.stack_top = recv_idx;
}

fn writeGlobalIC(ctx: VMContext, name_idx: usize, ic_base: usize, ic_slot: u16, val: Value) !void {
    if (ic_slot != 0xFFFF) {
        ctx.gs.setAt(ic_slot, val);
    } else {
        const name = (try ctx.cs.constAt(name_idx)).string.bytes;
        const slot = ctx.gs.findSlot(name) orelse {
            ctx.vs.setRuntimeErr("'{s}' is not defined", .{name});
            return error.NotDefined;
        };
        ctx.cs.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
        ctx.cs.patchByte(ic_base + 1, @intCast(slot & 0xFF));
        ctx.gs.setAt(slot, val);
    }
}

fn readGlobalIC(ctx: VMContext, name_idx: usize, ic_base: usize, ic_slot: u16) !Value {
    if (ic_slot != 0xFFFF) return ctx.gs.getAt(ic_slot);
    const name = (try ctx.cs.constAt(name_idx)).string.bytes;
    const slot = ctx.gs.findSlot(name) orelse {
        const suggestion = findSimilarName(ctx, name);
        if (suggestion) |s| {
            ctx.vs.setRuntimeErr("'{s}' is not defined; did you mean '{s}'?", .{ name, s });
        } else {
            ctx.vs.setRuntimeErr("'{s}' is not defined", .{name});
        }
        return error.NotDefined;
    };
    ctx.cs.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
    ctx.cs.patchByte(ic_base + 1, @intCast(slot & 0xFF));
    return ctx.gs.getAt(slot);
}

inline fn vmFrameBase(ctx: VMContext) usize {
    return if (ctx.vs.frame_top > 0) ctx.vs.frames[ctx.vs.frame_top - 1].base else 0;
}

fn readLocalSlot(ctx: VMContext, slot: usize) !Value {
    const base = vmFrameBase(ctx);
    if (base + slot >= ctx.vs.stack.len) return error.StackOverflow;
    var v = ctx.vs.stack[base + slot];
    if (v == .object and v.object.* == .cell) v = v.object.cell.value;
    return v;
}

fn readGlobalConstPair(ctx: VMContext) !struct { g: Value, k: Value } {
    const name_idx = try ctx.vs.vmShort();
    const ic_base = ctx.vs.ip;
    const ic_slot: u16 = @intCast(try ctx.vs.vmShort());
    ctx.vs.ip += 1; // skip embedded const opcode byte
    const k = try ctx.cs.constAt(try ctx.vs.vmShort());
    return .{ .g = try readGlobalIC(ctx, name_idx, ic_base, ic_slot), .k = k };
}

fn readLocalSlotAndConst(ctx: VMContext) !struct { slot: u8, k: Value } {
    const slot = try ctx.vs.vmByte();
    ctx.vs.ip += 1; // skip embedded const opcode byte
    return .{ .slot = slot, .k = try ctx.cs.constAt(try ctx.vs.vmShort()) };
}

fn runInner(ctx: VMContext) !void {
    while (true) {
        if (ctx.vs.ops_budget_remaining < std.math.maxInt(u64)) {
            if (ctx.vs.ops_budget_remaining == 0) return error.InstructionBudgetExceeded;
            ctx.vs.ops_budget_remaining -= 1;
        }
        const op_raw = try ctx.vs.vmByte();
        if (op_raw >= std.meta.fields(Op).len) return error.InvalidChunkShape;
        if (io.traceActive()) io.fireTrace(ctx.cs.lineAt(ctx.vs.ip - 1), ctx.cs.colAt(ctx.vs.ip - 1));
        vmperf.countOp(op_raw);
        const op: Op = @enumFromInt(op_raw);
        switch (op) {
            .constant => try ctx.vs.vmPush(try ctx.vs.vmConst()),
            .null_val => try ctx.vs.vmPush(.null),
            .true_val => try ctx.vs.vmPush(.{ .boolean = true }),
            .false_val => try ctx.vs.vmPush(.{ .boolean = false }),
            .dup => try ctx.vs.vmPush(try ctx.vs.vmPeek(0)),
            .dup2 => {
                try ctx.vs.vmPush(try ctx.vs.vmPeek(1));
                try ctx.vs.vmPush(try ctx.vs.vmPeek(1));
            },
            .pop => _ = try ctx.vs.vmPop(),

            .repl_print => {
                const v = try ctx.vs.vmPop();
                if (v != .null) {
                    io.printValue(v);
                    io.write("\n");
                }
            },

            .def_global => {
                const name = (try ctx.vs.vmConst()).string.bytes;
                try ctx.gs.def(name, try ctx.vs.vmPop());
            },
            .get_global => {
                const name_idx = try ctx.vs.vmShort();
                const ic_base = ctx.vs.ip;
                const ic_slot: u16 = @intCast(try ctx.vs.vmShort());
                try ctx.vs.vmPush(try readGlobalIC(ctx, name_idx, ic_base, ic_slot));
            },
            .set_global => {
                const name_idx = try ctx.vs.vmShort();
                const ic_base = ctx.vs.ip;
                const ic_slot: u16 = @intCast(try ctx.vs.vmShort());
                try writeGlobalIC(ctx, name_idx, ic_base, ic_slot, try ctx.vs.vmPop());
            },
            .inc_global_const => {
                const name_idx = try ctx.vs.vmShort();
                const ic_base = ctx.vs.ip;
                const ic_slot: u16 = @intCast(try ctx.vs.vmShort());
                _ = try ctx.vs.vmByte(); // skip add_skip byte
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                if (ic_slot != 0xFFFF) {
                    const v = ctx.gs.getAt(ic_slot);
                    const result: Value = if (v == .int and k == .int) .{ .int = v.int + k.int } else try computeAddResult(ctx, v, k);
                    ctx.gs.setAt(ic_slot, result);
                } else {
                    const name = (try ctx.cs.constAt(name_idx)).string.bytes;
                    const slot = ctx.gs.findSlot(name) orelse {
                        ctx.vs.setRuntimeErr("'{s}' is not defined", .{name});
                        return error.NotDefined;
                    };
                    ctx.cs.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
                    ctx.cs.patchByte(ic_base + 1, @intCast(slot & 0xFF));
                    const v = ctx.gs.getAt(slot);
                    const result: Value = if (v == .int and k == .int) .{ .int = v.int + k.int } else try computeAddResult(ctx, v, k);
                    ctx.gs.setAt(slot, result);
                }
            },

            .get_local => {
                const slot = try ctx.vs.vmByte();
                try ctx.vs.vmPush(try readLocalSlot(ctx, slot));
            },
            .set_local => {
                const slot = try ctx.vs.vmByte();
                const base = vmFrameBase(ctx);
                if (base + slot >= ctx.vs.stack.len) return error.StackOverflow;
                writeFrameLocal(ctx, base + slot, try ctx.vs.vmPop());
            },
            .get_upvalue => {
                try ctx.vs.vmPush((try readUpvalueCell(ctx, try ctx.vs.vmByte())).cell.value);
            },
            .set_upvalue => {
                const idx = try ctx.vs.vmByte();
                const val = try ctx.vs.vmPop();
                (try readUpvalueCell(ctx, idx)).cell.value = val;
            },
            .close_upvalue => {
                const slot = try ctx.vs.vmByte();
                const base = vmFrameBase(ctx);
                if (base + slot >= ctx.vs.stack.len) return error.StackOverflow;
                const v = ctx.vs.stack[base + slot];
                if (v == .object and v.object.* == .cell) {
                    ctx.vs.stack[base + slot] = v.object.cell.value;
                }
            },
            .close_upvalue_loop => {
                const slot = try ctx.vs.vmByte();
                const base = vmFrameBase(ctx);
                if (base + slot < ctx.vs.stack.len) {
                    const v = ctx.vs.stack[base + slot];
                    if (v == .object and v.object.* == .cell) {
                        ctx.vs.stack[base + slot] = v.object.cell.value;
                    }
                }
                const off = try ctx.vs.vmInt();
                if (off > ctx.vs.ip) return error.InvalidChunkShape;
                ctx.vs.ip -= off;
            },

            .add => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                try ctx.vs.vmPush(try computeAddResult(ctx, a, b));
            },
            .local_add_local => {
                const dst = try ctx.vs.vmByte();
                const src = try ctx.vs.vmByte();
                const a = try readLocalSlot(ctx, dst);
                const b = try readLocalSlot(ctx, src);
                const result: Value = if (a == .int and b == .int) .{ .int = a.int + b.int } else try computeAddResult(ctx, a, b);
                writeFrameLocal(ctx, vmFrameBase(ctx) + dst, result);
            },
            .local_add_const => {
                const dst = try ctx.vs.vmByte();
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                const a = try readLocalSlot(ctx, dst);
                const result: Value = if (a == .int and k == .int) .{ .int = a.int + k.int } else try computeAddResult(ctx, a, k);
                writeFrameLocal(ctx, vmFrameBase(ctx) + dst, result);
            },
            .local_add_const_loop => {
                const dst = try ctx.vs.vmByte();
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                const a = try readLocalSlot(ctx, dst);
                const result: Value = if (a == .int and k == .int) .{ .int = a.int + k.int } else try computeAddResult(ctx, a, k);
                writeFrameLocal(ctx, vmFrameBase(ctx) + dst, result);
                const off = try ctx.vs.vmInt();
                if (off > ctx.vs.ip) return error.InvalidChunkShape;
                ctx.vs.ip -= off;
            },
            .add_ret => {
                vmperf.breakOpChain();
                if (ctx.vs.frame_top == 0) return error.ImpossibleOpcodeState;
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                const retval = try computeAddResult(ctx, a, b);
                if (try doReturn(ctx, retval)) return;
            },
            .sub => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) { try ctx.vs.vmPush(.{ .int = a.int - b.int }); continue; }
                if (a == .float and b == .float) {
                    const r = a.float - b.float;
                    if (!std.math.isFinite(r)) { ctx.vs.setRuntimeErr("non-finite value in arithmetic operation", .{}); return error.TypeError; }
                    try ctx.vs.vmPush(.{ .float = r }); continue;
                }
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    try ctx.vs.vmPush(try bigIntBinOpWithPromotion(ctx, a, b, .sub)); continue;
                }
                if (decimalOpValues(a, b)) |dop| {
                    const result = @subWithOverflow(dop.lhs, dop.rhs);
                    if (result[1] != 0) return error.TypeError;
                    try pushDecimalResultWithCarrier(ctx, dop.typ, result[0]);
                } else {
                    try pushSubResult(ctx, a, b);
                }
            },
            .mul => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) { try ctx.vs.vmPush(.{ .int = a.int * b.int }); continue; }
                if (a == .float and b == .float) {
                    const r = a.float * b.float;
                    if (!std.math.isFinite(r)) { ctx.vs.setRuntimeErr("non-finite value in arithmetic operation", .{}); return error.TypeError; }
                    try ctx.vs.vmPush(.{ .float = r }); continue;
                }
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    try ctx.vs.vmPush(try bigIntBinOpWithPromotion(ctx, a, b, .mul)); continue;
                }
                if (decimalOpValues(a, b)) |_| {
                    return error.TypeError;
                } else if (decimalScalarPair(a, b) orelse decimalScalarPair(b, a)) |p| {
                    const result = @mulWithOverflow(p.d, p.n);
                    if (result[1] != 0) return error.TypeError;
                    try pushDecimalResultWithCarrier(ctx, p.typ, result[0]);
                } else {
                    const nop = try numericBinaryOp(ctx, a, b, "*");
                    try pushNumericResultWithCarrier(ctx, a, b, nop.an * nop.bn, nop.tag, "*");
                }
            },
            .div => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) {
                    if (b.int == 0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    try ctx.vs.vmPush(.{ .float = @as(f64, @floatFromInt(a.int)) / @as(f64, @floatFromInt(b.int)) });
                    continue;
                }
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    const af: f64 = if (vmbigint.isBigInt(a)) vmbigint.toFloat(a) else @floatFromInt(a.int);
                    const bf: f64 = if (vmbigint.isBigInt(b)) vmbigint.toFloat(b) else @floatFromInt(b.int);
                    if (bf == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    try ctx.vs.vmPush(.{ .float = af / bf }); continue;
                }
                if (a == .float and b == .float) {
                    if (b.float == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    const r = a.float / b.float;
                    if (!std.math.isFinite(r)) { ctx.vs.setRuntimeErr("non-finite value in arithmetic operation", .{}); return error.TypeError; }
                    try ctx.vs.vmPush(.{ .float = r }); continue;
                }
                if (decimalOpValues(a, b)) |_| {
                    return error.TypeError;
                } else if (decimalScalarPair(a, b)) |p| {
                    if (p.n == 0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    if (p.d == std.math.minInt(i64) and p.n == -1) return error.TypeError;
                    try pushDecimalResultWithCarrier(ctx, p.typ, @divTrunc(p.d, p.n));
                } else {
                    const nop = try numericBinaryOp(ctx, a, b, "/");
                    if (nop.bn == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    try pushNumericResultWithCarrier(ctx, a, b, nop.an / nop.bn, nop.tag, "/");
                }
            },
            .int_div => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) {
                    if (b.int == 0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    const result: i64 = if (a.int == std.math.minInt(i64) and b.int == -1) std.math.minInt(i64) else @divTrunc(a.int, b.int);
                    try ctx.vs.vmPush(.{ .int = result }); continue;
                }
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    try ctx.vs.vmPush(try bigIntBinOpWithPromotion(ctx, a, b, .int_div)); continue;
                }
                if (a == .float and b == .float) {
                    if (b.float == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    try ctx.vs.vmPush(.{ .float = @floor(a.float / b.float) }); continue;
                }
                const nop = try numericBinaryOp(ctx, a, b, "div");
                if (nop.bn == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                const an_int: i64 = @intFromFloat(nop.an);
                const bn_int: i64 = @intFromFloat(nop.bn);
                if (bn_int == 0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                const result: i64 = if (an_int == std.math.minInt(i64) and bn_int == -1) std.math.minInt(i64) else @divTrunc(an_int, bn_int);
                try pushNumericResultWithCarrier(ctx, a, b, @floatFromInt(result), nop.tag, "div");
            },
            .rem => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) {
                    if (b.int == 0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    const result: i64 = if (a.int == std.math.minInt(i64) and b.int == -1) 0 else @rem(a.int, b.int);
                    try ctx.vs.vmPush(.{ .int = result }); continue;
                }
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    try ctx.vs.vmPush(try bigIntBinOpWithPromotion(ctx, a, b, .rem)); continue;
                }
                if (a == .float and b == .float) {
                    if (b.float == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    try ctx.vs.vmPush(.{ .float = common.fmod(a.float, b.float) }); continue;
                }
                const nop = try numericBinaryOp(ctx, a, b, "rem");
                if (nop.bn == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                try pushNumericResultWithCarrier(ctx, a, b, common.fmod(nop.an, nop.bn), nop.tag, "rem");
            },
            .mod => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) {
                    if (b.int == 0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    const result: i64 = @mod(a.int, b.int);
                    try ctx.vs.vmPush(.{ .int = result }); continue;
                }
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    try ctx.vs.vmPush(try bigIntBinOpWithPromotion(ctx, a, b, .mod)); continue;
                }
                if (a == .float and b == .float) {
                    if (b.float == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    const r = a.float - @floor(a.float / b.float) * b.float;
                    try ctx.vs.vmPush(.{ .float = r }); continue;
                }
                const nop = try numericBinaryOp(ctx, a, b, "mod");
                if (nop.bn == 0.0) { ctx.vs.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                const r = nop.an - @floor(nop.an / nop.bn) * nop.bn;
                try pushNumericResultWithCarrier(ctx, a, b, r, nop.tag, "mod");
            },
            .pow => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    const exp_i64: i64 = if (b == .int) b.int
                    else if (vmbigint.isBigInt(b)) vmbigint.toInt(b) catch {
                        ctx.vs.setRuntimeErr("bigint: exponent too large", .{});
                        return error.RangeError;
                    }
                    else {
                        ctx.vs.setRuntimeErr("bigint ** {s}: exponent must be int or bigint", .{vmtyp.runtimeTypeName(b)});
                        return error.TypeError;
                    };
                    if (exp_i64 < 0) { ctx.vs.setRuntimeErr("bigint: negative exponent not supported", .{}); return error.TypeError; }
                    if (exp_i64 > std.math.maxInt(u32)) { ctx.vs.setRuntimeErr("bigint: exponent too large", .{}); return error.RangeError; }
                    const exp: u32 = @intCast(exp_i64);
                    var a_big = a;
                    if (!vmbigint.isBigInt(a)) {
                        if (a != .int) { ctx.vs.setRuntimeErr("{s} ** bigint: base must be int or bigint", .{vmtyp.runtimeTypeName(a)}); return error.TypeError; }
                        a_big = try vmbigint.fromInt(a.int);
                    }
                    try ctx.vs.vmPush(try vmbigint.powBi(a_big, exp)); continue;
                }
                const nop = try numericBinaryOp(ctx, a, b, "**");
                try pushNumericResultWithCarrier(ctx, a, b, std.math.pow(f64, nop.an, nop.bn), nop.tag, "**");
            },
            .bit_and => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                try pushIntResultWithCarrier(ctx, a, b, try valueAsIntForOp(ctx, a, b, "&") & try valueAsIntForOp(ctx, b, a, "&"), "&");
            },
            .bit_or => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                try pushIntResultWithCarrier(ctx, a, b, try valueAsIntForOp(ctx, a, b, "|") | try valueAsIntForOp(ctx, b, a, "|"), "|");
            },
            .bit_xor => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                try pushIntResultWithCarrier(ctx, a, b, try valueAsIntForOp(ctx, a, b, "^") ^ try valueAsIntForOp(ctx, b, a, "^"), "^");
            },
            .bit_not => {
                const v = try ctx.vs.vmPeek(0);
                const n = try vms.valueAsInt(v);
                try pushUnaryIntResult(ctx, v, .{ .int = ~n });
            },
            .shl => {
                const p = try getShiftArgs(ctx, "<<");
                // Prevent signed left-shift overflow: if magnitude exceeds what i64 can hold after shift.
                if (p.an > 0 and p.an > (@as(i64, std.math.maxInt(i64)) >> p.shift)) return error.RangeError;
                if (p.an < 0 and p.an < (@as(i64, std.math.minInt(i64)) >> p.shift)) return error.RangeError;
                try pushIntResultWithCarrier(ctx, p.a, p.b, p.an << p.shift, "<<");
            },
            .shr => {
                const p = try getShiftArgs(ctx, ">>");
                try pushIntResultWithCarrier(ctx, p.a, p.b, p.an >> p.shift, ">>");
            },
            .cast_int => {
                const raw = try ctx.vs.vmPop();
                if (vmod.decimalLogicalNumber(raw)) |n| {
                    try ctx.vs.vmPush(.{ .int = try floatToIntSafe(n) });
                    continue;
                }
                const v = vms.unboxNamed(raw);
                if (vmbigint.isBigInt(v)) {
                    try ctx.vs.vmPush(.{ .int = try vmbigint.toInt(v) });
                    continue;
                }
                switch (v) {
                    .int => |n| try ctx.vs.vmPush(.{ .int = n }),
                    .float => |n| try ctx.vs.vmPush(.{ .int = try floatToIntSafe(n) }),
                    .decimal => |d| try ctx.vs.vmPush(.{ .int = d }),
                    .rune => |r| try ctx.vs.vmPush(.{ .int = @intCast(r) }),
                    .boolean => |b| try ctx.vs.vmPush(.{ .int = if (b) 1 else 0 }),
                    else => return error.TypeError,
                }
            },
            .cast_float => {
                const raw = try ctx.vs.vmPop();
                if (vmod.decimalLogicalNumber(raw)) |n| {
                    try ctx.vs.vmPush(.{ .float = n });
                    continue;
                }
                const v = vms.unboxNamed(raw);
                if (vmbigint.isBigInt(v)) {
                    try ctx.vs.vmPush(.{ .float = vmbigint.toFloat(v) });
                    continue;
                }
                switch (v) {
                    .int => |n| try ctx.vs.vmPush(.{ .float = @floatFromInt(n) }),
                    .float => |n| try ctx.vs.vmPush(.{ .float = n }),
                    .decimal => |d| try ctx.vs.vmPush(.{ .float = @floatFromInt(d) }),
                    .rune => |r| try ctx.vs.vmPush(.{ .float = @floatFromInt(r) }),
                    .boolean => |b| try ctx.vs.vmPush(.{ .float = if (b) 1.0 else 0.0 }),
                    else => return error.TypeError,
                }
            },
            .cast_decimal => {
                const v = vms.unboxNamed(try ctx.vs.vmPop());
                switch (v) {
                    .int => |n| try ctx.vs.vmPush(.{ .decimal = n }),
                    .float => |n| {
                        if (!std.math.isFinite(n)) return error.TypeError;
                        const t = @trunc(n);
                        if (t < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                            t >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                        try ctx.vs.vmPush(.{ .decimal = @intFromFloat(t) });
                    },
                    .decimal => |d| try ctx.vs.vmPush(.{ .decimal = d }),
                    .rune => |r| try ctx.vs.vmPush(.{ .decimal = @intCast(r) }),
                    .boolean => |b| try ctx.vs.vmPush(.{ .decimal = if (b) 1 else 0 }),
                    else => return error.TypeError,
                }
            },
            .cast_bool => {
                const v = vms.unboxNamed(try ctx.vs.vmPop());
                switch (v) {
                    .int => |n| try ctx.vs.vmPush(.{ .boolean = n != 0 }),
                    .float => |n| try ctx.vs.vmPush(.{ .boolean = n != 0.0 }),
                    .rune => |r| try ctx.vs.vmPush(.{ .boolean = r != 0 }),
                    .boolean => |b| try ctx.vs.vmPush(.{ .boolean = b }),
                    else => return error.TypeError,
                }
            },
            .cast_string => {
                // Keep the operand on the stack while converting: the result
                // allocation can GC, and a popped named string's bytes would
                // be freed — possibly handed back as the destination buffer
                // (#120 window family; caught as an aliasing memcpy).
                const raw = try ctx.vs.vmPeek(0);
                if (vmod.decimalRawAndScale(raw)) |drs| {
                    var buf: [64]u8 = undefined;
                    const s = vmod.formatDecimalString(drs.raw, drs.scale, &buf);
                    const out = try vmgc.makeDynString(s);
                    _ = try ctx.vs.vmPop();
                    try ctx.vs.vmPush(out);
                    continue;
                }
                const v = vms.unboxNamed(raw);
                if (v == .null) return error.TypeError;
                const out = try vmnative.nativeConvToString(v);
                _ = try ctx.vs.vmPop();
                try ctx.vs.vmPush(out);
            },
            .cast_rune => {
                const v = vms.unboxNamed(try ctx.vs.vmPop());
                const r: u21 = switch (v) {
                    .rune => |rv| rv,
                    .int => |n| blk: {
                        if (n < 0 or n > 0x10FFFF) return error.TypeError;
                        break :blk @intCast(n);
                    },
                    else => return error.TypeError,
                };
                try ctx.vs.vmPush(.{ .rune = r });
            },
            .cast_bigint => {
                // Keep operand on stack during string parse (allocation may GC)
                const raw = try ctx.vs.vmPeek(0);
                const v = vms.unboxNamed(raw);
                const result = if (vmbigint.isBigInt(v))
                    v
                else if (v == .int)
                    try vmbigint.fromInt(v.int)
                else if (vms.isStringValue(v))
                    vmbigint.fromStrVal(v) catch return error.TypeError
                else if (v == .float) blk: {
                    if (!std.math.isFinite(v.float) or @trunc(v.float) != v.float) return error.TypeError;
                    if (v.float < -9.223372036854776e18 or v.float >= 9.223372036854776e18) return error.TypeError;
                    break :blk try vmbigint.fromInt(@intFromFloat(v.float));
                } else return error.TypeError;
                _ = try ctx.vs.vmPop();
                try ctx.vs.vmPush(result);
            },
            .assert_type => {
                const tag = try ctx.vs.vmByte();
                const v = try ctx.vs.vmPeek(0);
                const ok = switch (tag) {
                    1 => v == .object and vms.isArrayObject(v.object),
                    2 => v == .object and vms.isMapObject(v.object),
                    3 => v == .error_value,
                    else => return error.TypeError,
                };
                const expected = if (tag == 1) "array" else if (tag == 2) "map" else "error";
                try typeAssert(ctx, v, ok, expected);
            },
            .assert_interface => {
                const idx = try ctx.vs.vmShort();
                if (idx >= ctx.cs.constCount()) return error.InvalidChunkShape;
                const name = (ctx.cs.constAt(idx) catch unreachable).string.bytes;
                const v = try ctx.vs.vmPeek(0);
                try typeAssert(ctx, v, vmtyp.matchesInterfaceType(v, name), name);
            },
            .assert_struct => {
                const idx = try ctx.vs.vmShort();
                if (idx >= ctx.cs.constCount()) return error.InvalidChunkShape;
                const name = (ctx.cs.constAt(idx) catch unreachable).string.bytes;
                const v = try ctx.vs.vmPeek(0);
                const ok = v == .object and v.object.* == .struct_instance and common.streq(v.object.struct_instance.typ.struct_type.qualified_name, name);
                try typeAssert(ctx, v, ok, name);
            },
            .type_name => {
                const v = try ctx.vs.vmPop();
                try ctx.vs.vmPush(try vmnative.nativeTypeNameValue(v));
            },
            .neg => {
                const v = try ctx.vs.vmPeek(0);
                const unboxed = vms.unboxNamed(v);
                if (vmbigint.isBigInt(unboxed)) {
                    _ = try ctx.vs.vmPop();
                    try ctx.vs.vmPush(try vmbigint.negBi(unboxed));
                    continue;
                }
                const negated: Value = switch (unboxed) {
                    .int => |n| .{ .int = -n },
                    .float => |n| .{ .float = -n },
                    else => {
                        _ = try ctx.vs.vmPop();
                        ctx.vs.setRuntimeErr("cannot negate {s}", .{vmtyp.runtimeTypeName(v)});
                        return error.TypeError;
                    },
                };
                try pushUnaryIntResult(ctx, v, negated);
            },
            .not => {
                const v = try ctx.vs.vmPop();
                try ctx.vs.vmPush(.{ .boolean = !(try condAsBool(ctx, v, "'not' operand")) });
            },
            .eq => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) { try ctx.vs.vmPush(.{ .boolean = a.int == b.int }); continue; }
                if (a == .boolean and b == .boolean) { try ctx.vs.vmPush(.{ .boolean = a.boolean == b.boolean }); continue; }
                try checkNamedValueCompatibility(ctx, a, b);
                try ctx.vs.vmPush(.{ .boolean = Value.equals(vms.unboxNamed(a), vms.unboxNamed(b)) });
            },
            .gt => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) { try ctx.vs.vmPush(.{ .boolean = a.int > b.int }); continue; }
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    const ord = vmbigint.compareValues(a, b) catch {
                        ctx.vs.setRuntimeErr("cannot compare bigint and {s}", .{vmtyp.runtimeTypeName(if (vmbigint.isBigInt(a)) b else a)});
                        return error.TypeError;
                    };
                    try ctx.vs.vmPush(.{ .boolean = ord == .gt }); continue;
                }
                const n = try compareNumericPair(ctx, a, b, ">");
                try ctx.vs.vmPush(.{ .boolean = n.an > n.bn });
            },
            .lt => {
                const b = try ctx.vs.vmPop();
                const a = try ctx.vs.vmPop();
                if (a == .int and b == .int) { try ctx.vs.vmPush(.{ .boolean = a.int < b.int }); continue; }
                if (vmbigint.isBigInt(a) or vmbigint.isBigInt(b)) {
                    const ord = vmbigint.compareValues(a, b) catch {
                        ctx.vs.setRuntimeErr("cannot compare bigint and {s}", .{vmtyp.runtimeTypeName(if (vmbigint.isBigInt(a)) b else a)});
                        return error.TypeError;
                    };
                    try ctx.vs.vmPush(.{ .boolean = ord == .lt }); continue;
                }
                const n = try compareNumericPair(ctx, a, b, "<");
                try ctx.vs.vmPush(.{ .boolean = n.an < n.bn });
            },

            // Fused const+op: reads rhs constant, pops lhs from stack.
            .const_eq => {
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                const a = try ctx.vs.vmPop();
                if (a == .int and k == .int) { try ctx.vs.vmPush(.{ .boolean = a.int == k.int }); continue; }
                try checkNamedValueCompatibility(ctx, a, k);
                try ctx.vs.vmPush(.{ .boolean = Value.equals(vms.unboxNamed(a), vms.unboxNamed(k)) });
            },
            .const_sub => {
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                const a = try ctx.vs.vmPop();
                if (a == .int and k == .int) { try ctx.vs.vmPush(.{ .int = a.int - k.int }); continue; }
                try pushSubResult(ctx, a, k);
            },

            // Triple-fused: get_local + constant + eq/sub.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo]
            .get_local_const_eq => {
                const p = try readLocalSlotAndConst(ctx);
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) { try ctx.vs.vmPush(.{ .boolean = a.int == p.k.int }); continue; }
                try checkNamedValueCompatibility(ctx, a, p.k);
                try ctx.vs.vmPush(.{ .boolean = Value.equals(vms.unboxNamed(a), vms.unboxNamed(p.k)) });
            },
            .get_local_const_sub => {
                const p = try readLocalSlotAndConst(ctx);
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) { try ctx.vs.vmPush(.{ .int = a.int - p.k.int }); continue; }
                try pushSubResult(ctx, a, p.k);
            },
            .get_local_const_sub_call => {
                const p = try readLocalSlotAndConst(ctx);
                const argc = try ctx.vs.vmByte();
                const ic_base = ctx.vs.ip;
                const ic_slot: u16 = (@as(u16, ctx.cs.codeByteAt(ic_base)) << 8) | @as(u16, ctx.cs.codeByteAt(ic_base + 1));
                ctx.vs.ip += 2;
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) {
                    try ctx.vs.vmPush(.{ .int = a.int - p.k.int });
                } else {
                    try pushSubResult(ctx, a, p.k);
                }
                if (try tryTailCall(ctx, argc)) continue;
                try performCallIC(ctx, argc, ic_base, ic_slot);
            },
            .call_global_local_sub_const => {
                const name_idx = try ctx.vs.vmShort();
                const g_ic_base = ctx.vs.ip;
                const g_ic_slot: u16 = @intCast(try ctx.vs.vmShort());
                _ = try ctx.vs.vmByte(); // skip get_local_const_sub_call opcode byte
                const p = try readLocalSlotAndConst(ctx);
                const argc = try ctx.vs.vmByte();
                const c_ic_base = ctx.vs.ip;
                const c_ic_slot: u16 = (@as(u16, ctx.cs.codeByteAt(c_ic_base)) << 8) | @as(u16, ctx.cs.codeByteAt(c_ic_base + 1));
                ctx.vs.ip += 2;
                const callee = try readGlobalIC(ctx, name_idx, g_ic_base, g_ic_slot);
                const a = try readLocalSlot(ctx, p.slot);
                try ctx.vs.vmPush(callee);
                if (a == .int and p.k == .int) {
                    try ctx.vs.vmPush(.{ .int = a.int - p.k.int });
                } else {
                    try pushSubResult(ctx, a, p.k);
                }
                if (try tryTailCall(ctx, argc)) continue;
                try performCallIC(ctx, argc, c_ic_base, c_ic_slot);
            },
            .get_local_const_add => {
                const p = try readLocalSlotAndConst(ctx);
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) { try ctx.vs.vmPush(.{ .int = a.int + p.k.int }); continue; }
                try ctx.vs.vmPush(try computeAddResult(ctx, a, p.k));
            },
            .get_local_const_lt => {
                const p = try readLocalSlotAndConst(ctx);
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) { try ctx.vs.vmPush(.{ .boolean = a.int < p.k.int }); continue; }
                const n = try compareNumericPair(ctx, a, p.k, "<");
                try ctx.vs.vmPush(.{ .boolean = n.an < n.bn });
            },
            .get_local_const_gt => {
                const p = try readLocalSlotAndConst(ctx);
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) { try ctx.vs.vmPush(.{ .boolean = a.int > p.k.int }); continue; }
                const n = try compareNumericPair(ctx, a, p.k, ">");
                try ctx.vs.vmPush(.{ .boolean = n.an > n.bn });
            },

            // Quad-fused: get_local + constant + eq + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][jmp_b3][jmp_b2][jmp_b1][jmp_b0]
            .get_local_const_eq_jif_pop => {
                const p = try readLocalSlotAndConst(ctx);
                const off = try ctx.vs.vmInt();
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) {
                    if (a.int != p.k.int) ctx.vs.ip += off;
                } else {
                    try checkNamedValueCompatibility(ctx, a, p.k);
                    if (!Value.equals(vms.unboxNamed(a), vms.unboxNamed(p.k))) ctx.vs.ip += off;
                }
            },

            // Quad-fused: get_local + const_lt + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0]
            .get_local_const_lt_jif_pop => {
                const p = try readLocalSlotAndConst(ctx);
                const off = try ctx.vs.vmInt();
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) {
                    if (a.int >= p.k.int) ctx.vs.ip += off;
                } else {
                    const n = try compareNumericPair(ctx, a, p.k, "<");
                    if (!(n.an < n.bn)) ctx.vs.ip += off;
                }
            },
            // Quad-fused: get_local + const_gt + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0]
            .get_local_const_gt_jif_pop => {
                const p = try readLocalSlotAndConst(ctx);
                const off = try ctx.vs.vmInt();
                const a = try readLocalSlot(ctx, p.slot);
                if (a == .int and p.k == .int) {
                    if (a.int <= p.k.int) ctx.vs.ip += off;
                } else {
                    const n = try compareNumericPair(ctx, a, p.k, ">");
                    if (!(n.an > n.bn)) ctx.vs.ip += off;
                }
            },

            // Quint-fused: get_local + const_lt + jif_pop + jump (C-style for-loop header).
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0][body_b3..b0]
            // exit_off is relative to ip after reading it (ip_mid = tp+9).
            // body_off is relative to ip after reading both offsets (tp+13).
            .get_local_const_lt_jif_pop_jump => {
                const p = try readLocalSlotAndConst(ctx);
                const a = try readLocalSlot(ctx, p.slot);
                const exit_off = try ctx.vs.vmInt();
                const ip_mid = ctx.vs.ip;
                const body_off = try ctx.vs.vmInt();
                const cond_true = if (a == .int and p.k == .int)
                    (a.int < p.k.int)
                else blk: {
                    const n = try compareNumericPair(ctx, a, p.k, "<");
                    break :blk n.an < n.bn;
                };
                if (cond_true) {
                    ctx.vs.ip += body_off;
                } else {
                    ctx.vs.ip = ip_mid + exit_off;
                }
            },

            // Fused: get_local + get_field. 8-byte layout:
            // [op][slot][skip=get_field_byte][name_hi][name_lo][ic_type_hi][ic_type_lo][ic_fidx]
            .get_local_get_field => {
                try opGetLocalGetField(ctx);
            },

            // Triple-fused: get_global + constant + eq.
            // Bytecode: [op][name_hi][name_lo][ic_hi][ic_lo][skip][val_hi][val_lo]
            .get_global_const_eq => {
                const p = try readGlobalConstPair(ctx);
                if (p.g == .int and p.k == .int) { try ctx.vs.vmPush(.{ .boolean = p.g.int == p.k.int }); continue; }
                try checkNamedValueCompatibility(ctx, p.g, p.k);
                try ctx.vs.vmPush(.{ .boolean = Value.equals(vms.unboxNamed(p.g), vms.unboxNamed(p.k)) });
            },
            .get_global_const_sub => {
                const p = try readGlobalConstPair(ctx);
                if (p.g == .int and p.k == .int) { try ctx.vs.vmPush(.{ .int = p.g.int - p.k.int }); continue; }
                try pushSubResult(ctx, p.g, p.k);
            },
            .get_global_const_add => {
                const p = try readGlobalConstPair(ctx);
                if (p.g == .int and p.k == .int) { try ctx.vs.vmPush(.{ .int = p.g.int + p.k.int }); continue; }
                try ctx.vs.vmPush(try computeAddResult(ctx, p.g, p.k));
            },
            .get_global_const_lt => {
                const p = try readGlobalConstPair(ctx);
                if (p.g == .int and p.k == .int) { try ctx.vs.vmPush(.{ .boolean = p.g.int < p.k.int }); continue; }
                const n = try compareNumericPair(ctx, p.g, p.k, "<");
                try ctx.vs.vmPush(.{ .boolean = n.an < n.bn });
            },
            // Quad-fused: get_global + const_lt + jif_pop.
            // Bytecode: [op][name_hi][name_lo][ic_hi][ic_lo][skip][val_hi][val_lo][jmp_b3][jmp_b2][jmp_b1][jmp_b0]
            .get_global_const_lt_jif_pop => {
                const p = try readGlobalConstPair(ctx);
                const off = try ctx.vs.vmInt();
                if (p.g == .int and p.k == .int) {
                    if (p.g.int >= p.k.int) ctx.vs.ip += off;
                } else {
                    const n = try compareNumericPair(ctx, p.g, p.k, "<");
                    if (!(n.an < n.bn)) ctx.vs.ip += off;
                }
            },
            .const_add => {
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                const a = try ctx.vs.vmPop();
                try ctx.vs.vmPush(try computeAddResult(ctx, a, k));
            },
            .const_lt => {
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                const a = try ctx.vs.vmPop();
                const n = try compareNumericPair(ctx, a, k, "<");
                try ctx.vs.vmPush(.{ .boolean = n.an < n.bn });
            },
            .const_gt => {
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                const a = try ctx.vs.vmPop();
                const n = try compareNumericPair(ctx, a, k, ">");
                try ctx.vs.vmPush(.{ .boolean = n.an > n.bn });
            },

            .build_array => {
                const count = try ctx.vs.vmByte();
                const obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
                defer ctx.vs.popTempRoot();
                const items = try vmgc.vmAllocManagedSlice(Value, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    items[i] = try ctx.vs.vmPop();
                }
                if (count > 0) {
                    if (items[0] == .null) {
                        ctx.vs.setRuntimeErr("array literal: element 0 is null; null cannot declare the element type", .{});
                        return error.TypeError;
                    }
                    const first_name = vmtyp.runtimeTypeName(items[0]);
                    const first_is_float = items[0] == .float;
                    for (items[1..], 0..) |*item, rel| {
                        if (item.* == .null) {
                            ctx.vs.setRuntimeErr("array literal: element {d} is null; expected {s} (from element 0)", .{ rel + 1, first_name });
                            return error.TypeError;
                        }
                        if (first_is_float) {
                            switch (item.*) {
                                .int => |n| { item.* = .{ .float = @floatFromInt(n) }; continue; },
                                else => {},
                            }
                        }
                        const item_name = vmtyp.runtimeTypeName(item.*);
                        if (!std.mem.eql(u8, item_name, first_name)) {
                            ctx.vs.setRuntimeErr("array literal: element {d} is {s}, expected {s} (from element 0)", .{ rel + 1, item_name, first_name });
                            return error.TypeError;
                        }
                    }
                }
                obj.* = .{ .array_managed = items[0..count] };
                try ctx.vs.vmPush(.{ .object = obj });
            },
            .build_tuple => {
                const count = try ctx.vs.vmByte();
                const obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
                defer ctx.vs.popTempRoot();
                const items = try vmgc.vmAllocManagedSlice(Value, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    items[i] = try ctx.vs.vmPop();
                }
                obj.* = .{ .array_managed = items[0..count] };
                try ctx.vs.vmPush(.{ .object = obj });
            },
            .build_map => {
                const count = try ctx.vs.vmByte();
                const obj = try vmgc.allocTempRooted(.{ .map = &[_]MapEntry{} });
                defer ctx.vs.popTempRoot();
                const items = try vmgc.vmAllocManagedSlice(MapEntry, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    const val = try ctx.vs.vmPop();
                    const key = try ctx.vs.vmPop();
                    items[i] = .{ .key = key, .value = val };
                }
                // Point obj at items before allocating buckets so GC can trace the entries
                // (they are no longer on the stack after vmPop above).
                obj.* = .{ .map = items[0..count] };
                const bcount = vmmap.mapBucketsForCount(count);
                const buckets = try vmgc.vmAllocManagedSlice(i32, bcount);
                vmmap.mapBuildHashedBuckets(items[0..count], buckets);
                obj.* = .{ .map_hashed = .{ .entries = items[0..count], .len = count, .buckets = buckets } };
                try ctx.vs.vmPush(.{ .object = obj });
            },
            .zero_struct => {
                const typ_val = try ctx.vs.vmPop();
                if (typ_val != .object or typ_val.object.* != .struct_type) return error.TypeError;
                const st = typ_val.object.struct_type;
                const n = st.fields.len;
                const inst_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
                defer ctx.vs.popTempRoot();
                const fields = try vmgc.vmAllocManagedSlice(MapEntry, n);
                for (fields, 0..) |*f, i| {
                    f.* = .{
                        .key = .{ .string = try ctx.cs.internStr(st.fields[i].name) },
                        .value = zeroValueForFieldSpec(st.fields[i].typ),
                    };
                }
                inst_obj.* = .{ .struct_instance = .{ .typ = typ_val.object, .fields = fields } };
                try ctx.vs.vmPush(.{ .object = inst_obj });
            },
            .build_struct_instance => {
                const count = try ctx.vs.vmByte();
                const typ_stack_dist = @as(usize, count) * 2;
                if (ctx.vs.stack_top <= typ_stack_dist) return error.StackUnderflow;
                const typ_peek = ctx.vs.stack[ctx.vs.stack_top - 1 - typ_stack_dist];
                if (typ_peek != .object) return error.TypeError;

                if (typ_peek.object.* == .variant_ctor) {
                    const vc = typ_peek.object.variant_ctor;
                    const vt = vc.typ.variant_type;
                    const arm = vt.arms[vc.ordinal];
                    const shared_count = vt.shared_fields.len;
                    const arm_field_count = arm.fields.len;

                    const obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
                    defer ctx.vs.popTempRoot();

                    const base = ctx.vs.stack_top - typ_stack_dist;
                    const shared_vals = try vmgc.vmAllocManagedSlice(Value, shared_count);
                    const arm_vals = if (arm_field_count > 0) try vmgc.vmAllocManagedSlice(Value, arm_field_count) else @as([]Value, &.{});

                    if (arm.has_payload and arm_field_count == 0) {
                        // Single-payload arm with shared fields
                        var shared_seen: [255]bool = [_]bool{false} ** 255;
                        var payload_val: Value = .null;
                        var payload_seen = false;
                        for (0..@as(usize, count)) |ci| {
                            const key = ctx.vs.stack[base + ci * 2];
                            const val = ctx.vs.stack[base + ci * 2 + 1];
                            const key_s = try vms.asStringValue(key);
                            if (vmtyp.findFieldIndex(vt.shared_fields, key_s)) |idx| {
                                if (shared_seen[idx]) { ctx.vs.setRuntimeErr("duplicate field '{s}' in variant literal", .{key_s}); return error.DuplicateField; }
                                shared_seen[idx] = true;
                                shared_vals[idx] = val;
                            } else if (common.streq(key_s, arm.payload_name)) {
                                if (payload_seen) { ctx.vs.setRuntimeErr("duplicate field '{s}' in variant literal", .{key_s}); return error.DuplicateField; }
                                payload_seen = true;
                                payload_val = val;
                            } else {
                                ctx.vs.setRuntimeErr("no field '{s}' on variant '{s}'", .{ key_s, arm.name });
                                return error.UnknownStructField;
                            }
                        }
                        for (vt.shared_fields, shared_seen[0..shared_count]) |sf, seen| {
                            if (!seen) { ctx.vs.setRuntimeErr("missing required field '{s}' in variant literal", .{sf.name}); return error.MissingStructField; }
                        }
                        if (arm.has_payload and !payload_seen) { ctx.vs.setRuntimeErr("missing required field '{s}' in variant literal", .{arm.payload_name}); return error.MissingStructField; }

                        ctx.vs.stack_top -= typ_stack_dist + 1;
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
                            const key = ctx.vs.stack[base + ci * 2];
                            const val = ctx.vs.stack[base + ci * 2 + 1];
                            const key_s = try vms.asStringValue(key);
                            if (vmtyp.findFieldIndex(vt.shared_fields, key_s)) |idx| {
                                if (seen[idx]) { ctx.vs.setRuntimeErr("duplicate field '{s}' in variant literal", .{key_s}); return error.DuplicateField; }
                                seen[idx] = true;
                                shared_vals[idx] = val;
                            } else if (vmtyp.findFieldIndex(arm.fields, key_s)) |idx| {
                                const seen_idx = shared_count + idx;
                                if (seen[seen_idx]) { ctx.vs.setRuntimeErr("duplicate field '{s}' in variant literal", .{key_s}); return error.DuplicateField; }
                                seen[seen_idx] = true;
                                arm_vals[idx] = val;
                            } else {
                                ctx.vs.setRuntimeErr("no field '{s}' on variant '{s}'", .{ key_s, arm.name });
                                return error.UnknownStructField;
                            }
                        }
                        for (seen[0..shared_count], vt.shared_fields) |s, sf| {
                            if (!s) { ctx.vs.setRuntimeErr("missing required field '{s}' in variant literal", .{sf.name}); return error.MissingStructField; }
                        }
                        for (seen[shared_count..total_fields], arm.fields) |s, af| {
                            if (!s) { ctx.vs.setRuntimeErr("missing required field '{s}' in variant literal", .{af.name}); return error.MissingStructField; }
                        }

                        ctx.vs.stack_top -= typ_stack_dist + 1;
                        obj.* = .{ .variant_value = .{
                            .typ = vc.typ,
                            .tag = vc.tag,
                            .ordinal = vc.ordinal,
                            .payload = .null,
                            .shared_values = shared_vals[0..shared_count],
                            .arm_fields = arm_vals[0..arm_field_count],
                        } };
                    }
                    try ctx.vs.vmPush(.{ .object = obj });
                } else if (typ_peek.object.* == .struct_type) {
                    const st = typ_peek.object.struct_type;
                    if (st.fields.len > 255) return error.TooManyStructFields;

                    const inst_fields = try vmgc.vmAllocManagedSlice(MapEntry, st.fields.len);
                    const obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
                    defer ctx.vs.popTempRoot();

                    const base = ctx.vs.stack_top - typ_stack_dist;
                    var seen: [255]bool = [_]bool{false} ** 255;
                    for (0..@as(usize, count)) |ci| {
                        const key = ctx.vs.stack[base + ci * 2];
                        const val = ctx.vs.stack[base + ci * 2 + 1];
                        const key_s = try vms.asStringValue(key);
                        const idx = vmtyp.findFieldIndex(st.fields, key_s) orelse {
                            ctx.vs.setRuntimeErr("no field '{s}' on type '{s}'", .{ key_s, st.name });
                            return error.UnknownStructField;
                        };
                        if (seen[idx]) { ctx.vs.setRuntimeErr("duplicate field '{s}' in struct literal", .{key_s}); return error.DuplicateField; }
                        seen[idx] = true;
                        if (!vmtyp.matchesFieldType(val, st.fields[idx])) return error.StructFieldTypeMismatch;
                        inst_fields[idx] = .{ .key = st.fields[idx].key, .value = val };
                    }

                    for (st.fields, seen[0..st.fields.len]) |f, s| {
                        if (!s) { ctx.vs.setRuntimeErr("missing required field '{s}' in struct literal", .{f.name}); return error.MissingStructField; }
                    }

                    ctx.vs.stack_top -= typ_stack_dist + 1;

                    obj.* = .{
                        .struct_instance = .{ .typ = typ_peek.object, .fields = inst_fields },
                    };
                    try ctx.vs.vmPush(.{ .object = obj });
                } else {
                    return error.TypeError;
                }
            },
            .tuple_check_arity => {
                const expect = try ctx.vs.vmByte();
                const tup = try ctx.vs.vmPeek(0);
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                if ((try vms.asArraySlice(tup.object)).len != expect) return error.ArityMismatch;
            },
            .tuple_get => {
                const idx = try ctx.vs.vmByte();
                const tup = try ctx.vs.vmPop();
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                const a = try vms.asArraySlice(tup.object);
                if (idx >= a.len) return error.ArityMismatch;
                try ctx.vs.vmPush(a[idx]);
            },
            .tuple_get_keep => {
                const idx = try ctx.vs.vmByte();
                const tup = try ctx.vs.vmPeek(0);
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                const a = try vms.asArraySlice(tup.object);
                if (idx >= a.len) return error.ArityMismatch;
                try ctx.vs.vmPush(a[idx]);
            },
            .get_index => try opGetIndex(ctx),
            .set_index => try opSetIndex(ctx),
            .get_slice => {
                const flags = try ctx.vs.vmByte();
                const has_start = (flags & 0b01) != 0;
                const has_end = (flags & 0b10) != 0;

                var end_v: Value = .null;
                var start_v: Value = .null;
                if (has_end) end_v = try ctx.vs.vmPop();
                if (has_start) start_v = try ctx.vs.vmPop();
                const container = try ctx.vs.vmPop();
                // The slice result is a fresh allocation; keep the popped
                // container rooted through it (#120 window family).
                try ctx.vs.pushTempRoot(container);
                defer ctx.vs.popTempRoot();

                switch (container) {
                    .string => {
                        try ctx.vs.vmPush(try vmstr.stringSlice(container, has_start, start_v, has_end, end_v));
                    },
                    .object => |obj| switch (obj.*) {
                        .dyn_string, .string_view => {
                            try ctx.vs.vmPush(try vmstr.stringSlice(container, has_start, start_v, has_end, end_v));
                        },
                        .array, .array_managed, .array_view, .array_capacity => {
                            try ctx.vs.vmPush(try vmarr.arraySlice(obj, has_start, start_v, has_end, end_v));
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
                const v = try ctx.vs.vmPeek(0);
                const it = try iterInit(v);
                _ = try ctx.vs.vmPop();
                try ctx.vs.vmPush(it);
            },
            .iter_next1 => {
                const itv = try ctx.vs.vmPeek(0);
                if (itv != .object or itv.object.* != .iterator) return error.TypeError;
                try iterNext1(ctx, &itv.object.iterator);
            },
            .iter_next2 => {
                const itv = try ctx.vs.vmPeek(0);
                if (itv != .object or itv.object.* != .iterator) return error.TypeError;
                try iterNext2(ctx, &itv.object.iterator);
            },
            .make_closure => {
                const f = try ctx.vs.vmConst();
                if (f != .object or f.object.* != .function) return error.InvalidChunkShape;
                const proto = f.object.function;
                const ups = if (heap.bump(*Object, proto.capture_slots.len)) |u| u else blk: {
                    vmgc.collectGarbage();
                    break :blk (heap.bump(*Object, proto.capture_slots.len) orelse return error.OutOfMemory);
                };
                const frame = if (ctx.vs.frame_top == 0) vms.Frame{ .ret_ip = 0, .base = 0, .closure = null, .func_obj = f.object, .defer_base = 0, .has_typed_returns = false } else ctx.vs.frames[ctx.vs.frame_top - 1];
                for (proto.capture_slots, ups) |enc, *u| {
                    const is_upvalue = (enc & 0x80) != 0;
                    const idx = enc & 0x7f;
                    if (is_upvalue) {
                        const pcl = frame.closure orelse return error.ImpossibleOpcodeState;
                        if (pcl.* != .closure) return error.ImpossibleOpcodeState;
                        if (idx >= pcl.closure.upvalues.len) return error.ImpossibleOpcodeState;
                        u.* = pcl.closure.upvalues[idx];
                    } else {
                        const abs = frame.base + idx;
                        if (abs >= ctx.vs.stack.len) return error.StackOverflow;
                        const cur = ctx.vs.stack[abs];
                        if (cur == .object and cur.object.* == .cell) {
                            u.* = cur.object;
                            continue;
                        }
                        const cell = try vmgc.vmAllocObject();
                        cell.* = .{ .cell = .{ .value = cur } };
                        ctx.vs.stack[abs] = .{ .object = cell };
                        u.* = cell;
                    }
                }
                const clo = try vmgc.vmAllocObject();
                clo.* = .{ .closure = ClosureObj{ .func = f.object, .upvalues = ups[0..proto.capture_slots.len] } };
                try ctx.vs.vmPush(.{ .object = clo });
            },
            .invoke_method => try opInvokeMethod(ctx),

            .jump => {
                const off = try ctx.vs.vmInt();
                ctx.vs.ip += off;
            },
            .jump_if_false => {
                const off = try ctx.vs.vmInt();
                if (!(try condAsBool(ctx, try ctx.vs.vmPeek(0), "condition"))) ctx.vs.ip += off;
            },
            .jif_pop => {
                const off = try ctx.vs.vmInt();
                const cond = try ctx.vs.vmPop();
                if (!(try condAsBool(ctx, cond, "condition"))) ctx.vs.ip += off;
            },
            .loop => {
                const off = try ctx.vs.vmInt();
                if (off > ctx.vs.ip) return error.InvalidChunkShape;
                ctx.vs.ip -= off;
                // If the back-edge target is a warm get_global IC, execute it inline
                // to save one full dispatch iteration per loop cycle.
                try tryInlineGetGlobal(ctx);
            },

            // Fused set_global + loop back-edge.
            // Bytecode: [op][name_hi][name_lo][ic_hi][ic_lo][off_b3][off_b2][off_b1][off_b0]
            // IC layout and patch offsets are identical to set_global.
            .set_global_loop => {
                const name_idx = try ctx.vs.vmShort();
                const ic_base = ctx.vs.ip;
                const ic_slot: u16 = @intCast(try ctx.vs.vmShort());
                try writeGlobalIC(ctx, name_idx, ic_base, ic_slot, try ctx.vs.vmPop());
                const off = try ctx.vs.vmInt();
                if (off > ctx.vs.ip) return error.InvalidChunkShape;
                ctx.vs.ip -= off;
                // Same inline get_global as loop: skip one dispatch if warm.
                try tryInlineGetGlobal(ctx);
            },

            .set_named_predicate => {
                const pred = try ctx.vs.vmPop();
                const nt_val = ctx.vs.stack[ctx.vs.stack_top - 1];
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
                const nt_val = try ctx.vs.vmPeek(0);
                if (nt_val != .object or nt_val.object.* != .named_type) return error.TypeError;
                const nt = &nt_val.object.named_type;
                if (nt.has_default and nt.predicate != null) {
                    const constructed = try vmtyp.constructNamedType(nt_val.object, nt.default_val);
                    try checkNamedTypePredicate(ctx, nt_val.object, constructed.object.named_value.value);
                }
            },

            .call => {
                const argc = try ctx.vs.vmByte();
                const ic_base = ctx.vs.ip;
                const ic_slot: u16 = (@as(u16, ctx.cs.codeByteAt(ic_base)) << 8) | @as(u16, ctx.cs.codeByteAt(ic_base + 1));
                ctx.vs.ip += 2;
                if (try tryTailCall(ctx, argc)) continue;
                const t0 = vmperf.readTsc();
                try performCallIC(ctx, argc, ic_base, ic_slot);
                const t1 = vmperf.readTsc();
                if (t1 > t0) vmperf.callCycles(t1 - t0);
            },
            .op_assert => {
                const cond = try ctx.vs.vmPop();
                if (cond != .boolean) return error.TypeError;
                if (!cond.boolean) return error.AssertionFailed;
            },

            .op_assert_msg => {
                const msg_val = try ctx.vs.vmPop();
                const cond = try ctx.vs.vmPop();
                if (cond != .boolean) return error.TypeError;
                if (!cond.boolean) {
                    ctx.vs.pending_panic_message = panicMessageFromValue(ctx, msg_val);
                    return error.AssertionFailed;
                }
            },

            .op_trap_check => {
                const val = try ctx.vs.vmPop();
                switch (val) {
                    .null => {},
                    else => {
                        ctx.vs.pending_panic_value = val;
                        ctx.vs.has_pending_panic_value = true;
                        return error.TrapFired;
                    },
                }
            },

            .variant_check => {
                const arm = (try ctx.vs.vmConst()).string.bytes;
                const v = try ctx.vs.vmPop();
                const matches = v == .object and v.object.* == .variant_value and
                    common.streq(v.object.variant_value.tag, arm);
                try ctx.vs.vmPush(.{ .boolean = matches });
            },

            .variant_payload => {
                const v = try ctx.vs.vmPeek(0);
                if (v != .object or v.object.* != .variant_value) return error.TypeError;
                const vv = v.object.variant_value;
                const arm = vv.typ.variant_type.arms[vv.ordinal];
                if (arm.fields.len > 0) {
                    const map_obj = try vmgc.allocTempRooted(.{ .map = &[_]MapEntry{} });
                    defer ctx.vs.popTempRoot();
                    const items = try vmgc.vmAllocManagedSlice(MapEntry, arm.fields.len);
                    for (arm.fields, vv.arm_fields, items) |f, fv, *it| it.* = .{ .key = f.key, .value = fv };
                    map_obj.* = .{ .map = items[0..arm.fields.len] };
                    _ = try ctx.vs.vmPop();
                    try ctx.vs.vmPush(.{ .object = map_obj });
                } else {
                    _ = try ctx.vs.vmPop();
                    try ctx.vs.vmPush(vv.payload);
                }
            },

            .get_field => try opGetField(ctx),

            .set_field => try opSetField(ctx),

            .defer_call => {
                const argc = try ctx.vs.vmByte();
                if (ctx.vs.defer_top >= ctx.vs.defer_stack.len) return error.DeferStackOverflow;
                const total: usize = @as(usize, argc) + 1;
                if (ctx.vs.stack_top < total) return error.StackUnderflow;
                const start = ctx.vs.stack_top - total;
                const arr_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
                defer ctx.vs.popTempRoot();
                const items = try vmgc.vmAllocManagedSlice(Value, total);
                @memcpy(items[0..total], ctx.vs.stack[start .. start + total]);
                arr_obj.* = .{ .array_managed = items[0..total] };
                ctx.vs.defer_stack[ctx.vs.defer_top] = .{ .object = arr_obj };
                ctx.vs.defer_top += 1;
                ctx.vs.stack_top -= total;
            },
            .defer_invoke_method => try opDeferInvokeMethod(ctx),
            .ret => {
                vmperf.breakOpChain();
                if (ctx.vs.frame_top == 0) return error.ImpossibleOpcodeState;
                const t0 = vmperf.readTsc();
                const retval = try ctx.vs.vmPop();
                const fi = ctx.vs.frame_top - 1;
                if (canReturnFast(ctx, fi, retval)) {
                    try doReturnFast(ctx, fi, retval);
                    if (ctx.vs.call_depth_target) |d| {
                        if (ctx.vs.frame_top == d) {
                            const t1 = vmperf.readTsc();
                            if (t1 > t0) vmperf.retCycles(t1 - t0);
                            return;
                        }
                    }
                    const t1 = vmperf.readTsc();
                    if (t1 > t0) vmperf.retCycles(t1 - t0);
                    continue;
                }
                if (try retSlowPath(ctx, retval)) {
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
                if (ctx.vs.frame_top == 0) return error.ImpossibleOpcodeState;
                const v = try readLocalSlot(ctx, try ctx.vs.vmByte());
                if (try doReturn(ctx, v)) return;
            },
            .ret_const => {
                vmperf.breakOpChain();
                if (ctx.vs.frame_top == 0) return error.ImpossibleOpcodeState;
                const k = try ctx.cs.constAt(try ctx.vs.vmShort());
                if (try doReturn(ctx, k)) return;
            },

            .halt => { vmperf.breakOpChain(); return; },
        }
    }
}

fn runDeferredCall(ctx: VMContext, deferred: Value) anyerror!void {
    const arr = try vms.asArraySlice(deferred.object);
    if (arr.len == 0) return;
    if (arr.len > 256) return error.ArityMismatch;
    const dargc: u8 = @intCast(arr.len - 1);
    for (arr) |v| try ctx.vs.vmPush(v);
    const depth_before = ctx.vs.frame_top;
    try performCall(ctx, dargc);
    if (ctx.vs.frame_top > depth_before) {
        const prev_target = ctx.vs.call_depth_target;
        ctx.vs.call_depth_target = depth_before;
        defer ctx.vs.call_depth_target = prev_target;
        try run(ctx);
    }
    _ = ctx.vs.vmPop() catch {};
}

fn runPanicUnwind(ctx: VMContext, orig_err: anyerror) anyerror!void {
    var current_err = orig_err;
    ctx.vs.recovered = false;
    // If panic_line is already non-zero, a deeper run() has already captured the
    // true fault location (e.g. inside a predicate body). Preserve it rather than
    // overwriting with the outer call site (e.g. the named-type constructor call).
    if (ctx.vs.panic_line == 0) {
        ctx.vs.panic_col = 0;
        ctx.vs.panic_depth = 0;
    }
    ctx.vs.is_panicking = true;
    if (ctx.vs.has_pending_panic_value) {
        ctx.vs.panic_value = ctx.vs.pending_panic_value;
        ctx.vs.has_pending_panic_value = false;
    } else if (ctx.vs.pending_panic_message) |msg| {
        // Only sync runtime_err_buf if msg doesn't already point into it —
        // when pending_panic_message was set from runtimeErrMsg() the buffer
        // is already correct, and @memcpy of a slice onto itself is UB.
        if (@intFromPtr(msg.ptr) != @intFromPtr(&ctx.vs.runtime_err_buf[0])) {
            ctx.vs.setRuntimeErr("{s}", .{msg});
        }
        ctx.vs.panic_value = .{ .error_value = try ctx.cs.internStr(msg) };
        ctx.vs.pending_panic_message = null;
    } else {
        ctx.vs.panic_value = .{ .error_value = try ctx.cs.internStr(@errorName(orig_err)) };
    }

    if (ctx.vs.panic_line == 0) {
        ctx.vs.panic_line = currentLine();
        ctx.vs.panic_col = currentCol();
        const _path = ctx.cs.pathAt(if (ctx.vs.ip > 0) ctx.vs.ip - 1 else 0);
        const _plen: u8 = @intCast(@min(_path.len, ctx.vs.panic_path.len));
        @memcpy(ctx.vs.panic_path[0.._plen], _path[0.._plen]);
        ctx.vs.panic_path_len = _plen;
        const stop_depth = ctx.vs.call_depth_target orelse 0;
        var depth: usize = 0;
        var fi: usize = ctx.vs.frame_top;
        while (fi > stop_depth and depth < ctx.vs.frames.len) {
            fi -= 1;
            const frame = ctx.vs.frames[fi];
            const call_ip = if (frame.ret_ip > 0) frame.ret_ip - 1 else 0;
            const fname = switch (frame.func_obj.*) {
                .function => |f| f.name,
                .closure => |cl| cl.func.function.name,
                else => "",
            };
            ctx.vs.panic_frames[depth] = .{ .line = ctx.cs.lineAt(call_ip), .name = fname };
            depth += 1;
        }
        ctx.vs.panic_depth = depth;
    }
    const stop_depth = ctx.vs.call_depth_target orelse 0;
    while (ctx.vs.frame_top > stop_depth) {
        const frame_defer_base = ctx.vs.frames[ctx.vs.frame_top - 1].defer_base;
        while (ctx.vs.defer_top > frame_defer_base) {
            ctx.vs.defer_top -= 1;
            runDeferredCall(ctx, ctx.vs.defer_stack[ctx.vs.defer_top]) catch |new_err| {
                if (!ctx.vs.recovered) {
                    current_err = new_err;
                    ctx.vs.panic_value = .{ .error_value = try ctx.cs.internStr(@errorName(new_err)) };
                }
            };
            if (ctx.vs.recovered) break;
        }
        if (ctx.vs.recovered) {
            ctx.vs.recovered = false;
            ctx.vs.is_panicking = false;
            ctx.vs.panic_line = 0;
            ctx.vs.panic_col = 0;
            ctx.vs.panic_path_len = 0;
            ctx.vs.panic_depth = 0;
            ctx.vs.runtime_err_len = 0;
            ctx.vs.defer_top = frame_defer_base;

            // Determine the recovered function's return arity before unwinding its frame.
            // If the function returns multiple values, callers expect a tuple; pushing a
            // bare null causes tuple_check_arity to throw TypeError.
            const rec_fobj = ctx.vs.frames[ctx.vs.frame_top - 1].func_obj;
            const rec_base = ctx.vs.frames[ctx.vs.frame_top - 1].base;
            const rec_fn: ?*@import("value.zig").FuncObj = switch (rec_fobj.*) {
                .function => &rec_fobj.function,
                .closure => |*cl| &cl.func.function,
                else => null,
            };
            const ret_count: usize = if (rec_fn) |f| f.return_types.len else 1;
            const named_ret: u8 = if (rec_fn) |f| f.named_return_count else 0;
            const rec_arity: u8 = if (rec_fn) |f| f.arity else 0;

            ctx.vs.frame_top -= 1;
            const frame = ctx.vs.frames[ctx.vs.frame_top];
            ctx.vs.stack_top = if (frame.base > 0) frame.base - 1 else 0;
            ctx.vs.ip = frame.ret_ip;

            if (ret_count <= 1) {
                if (named_ret > 0) {
                    const raw = ctx.vs.stack[rec_base + rec_arity];
                    ctx.vs.vmPush(vms.unboxCell(raw)) catch {};
                } else {
                    ctx.vs.vmPush(.null) catch {};
                }
            } else {
                // Multi-value return: build a tuple of the right size.
                // Named returns: use the values from the (still-readable) stack slots;
                // unnamed returns: fill with null.
                const n: u8 = if (named_ret > 0) named_ret else @intCast(@min(ret_count, 255));
                const tup_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
                const items = try vmgc.vmAllocManagedSlice(Value, n);
                if (named_ret > 0) {
                    for (0..named_ret) |ri| {
                        const raw = ctx.vs.stack[rec_base + rec_arity + ri];
                        items[ri] = vms.unboxCell(raw);
                    }
                } else {
                    @memset(items, .null);
                }
                tup_obj.* = .{ .array_managed = items };
                ctx.vs.popTempRoot();
                try ctx.vs.vmPush(.{ .object = tup_obj });
            }
            // If the recovered function was called via callGlobal (not from inside
            // bytecode), ret_ip points past halt/end-of-code.  The ret opcode's
            // fast path already handles this via call_depth_target; mirror that here
            // so recover() works when the caller is engine_call, not just the CLI.
            if (ctx.vs.call_depth_target) |d| {
                if (ctx.vs.frame_top == d) return;
            }
            return run(ctx);
        }
        ctx.vs.frame_top -= 1;
        const frame = ctx.vs.frames[ctx.vs.frame_top];
        ctx.vs.stack_top = if (frame.base > 0) frame.base - 1 else 0;
        ctx.vs.ip = frame.ret_ip;
    }
    ctx.vs.is_panicking = false;
    return current_err;
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn run(ctx: VMContext) anyerror!void {
    chunk.setActive(ctx.cs);
    globals.setActive(ctx.gs);
    heap.setActive(ctx.hs);
    vms.setActive(ctx.vs);
    ctx.cs.verify() catch |err| {
        if (ctx.cs.verify_err_len > 0) {
            ctx.vs.setRuntimeErr("verifier: {s}", .{ctx.cs.verify_err_buf[0..ctx.cs.verify_err_len]});
            ctx.vs.pending_panic_message = ctx.vs.runtimeErrMsg();
        }
        return runPanicUnwind(ctx, err);
    };
    runInner(ctx) catch |err| {
        // Runtime integrity failures hard-stop with diagnostics — they represent
        // impossible VM states in a program that already passed the verifier.
        if (vm_integrity.isIntegrityError(err)) vm_integrity.fatal(err);
        return runPanicUnwind(ctx, err);
    };
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

fn findSimilarName(ctx: VMContext, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 4; // only suggest names within 2 edits
    for (0..ctx.gs.len()) |i| {
        const candidate = ctx.gs.nameAt(i);
        const d = levenshteinDistance(name, candidate);
        if (d < best_dist) { best_dist = d; best = candidate; }
    }
    return best;
}

fn callValue(ctx: VMContext, fn_val: Value, args: []const Value) !Value {
    if (args.len > 255) return error.ArityMismatch;
    try ctx.vs.vmPush(fn_val);
    for (args) |a| try ctx.vs.vmPush(a);
    const depth_before = ctx.vs.frame_top;
    try performCall(ctx, @intCast(args.len));
    const prev_target = ctx.vs.call_depth_target;
    ctx.vs.call_depth_target = depth_before;
    defer ctx.vs.call_depth_target = prev_target;
    try run(ctx);
    return try ctx.vs.vmPop();
}

pub fn callGlobal(ctx: VMContext, name: []const u8, args: []const Value) !Value {
    chunk.setActive(ctx.cs);
    globals.setActive(ctx.gs);
    heap.setActive(ctx.hs);
    vms.setActive(ctx.vs);
    const fn_val = globals.get(name) orelse return error.NotDefined;
    if (fn_val != .object) return error.NotAFunction;
    const obj = fn_val.object;
    if (obj.* != .function and obj.* != .closure) return error.NotAFunction;
    // Clear stale runtime error so runPanicUnwind won't pick up a message
    // from a previous engine_call as the fallback for pending_panic_message.
    ctx.vs.runtime_err_len = 0;
    return callValue(ctx, fn_val, args);
}

pub fn callFunction(func_val: Value, args: []const Value) anyerror!Value {
    return callValue(VMContext.fromActive(), func_val, args);
}
