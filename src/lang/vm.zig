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
const vmAllocManagedSlice = vmgc.vmAllocManagedSlice;
const makeDynString = vmgc.makeDynString;
const concatDynString = vmgc.concatDynString;

fn panicMessageFromValue(v: Value) []const u8 {
    if (v == .string) return v.string;
    if (v == .object and v.object.* == .dyn_string) return v.object.dyn_string;
    if (v == .int) {
        return std.fmt.bufPrint(&vmState().str_acc, "{d}", .{v.int}) catch "AssertionFailed";
    }
    if (v == .float) {
        return std.fmt.bufPrint(&vmState().str_acc, "{d}", .{v.float}) catch "AssertionFailed";
    }
    if (v == .boolean) return if (v.boolean) "true" else "false";
    if (v == .null) return "null";
    if (v == .error_value) return v.error_value;
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

fn namedBaseName(base: vmod.NamedTypeBase) []const u8 {
    return switch (base) {
        .int => "int",
        .float => "float",
        .decimal => "decimal",
        .string => "string",
        .bool => "bool",
        .rune => "rune",
        .array_t => "array",
        .map_t => "map",
        .enum_t => "enum",
    };
}

fn runtimeTypeName(v: Value) []const u8 {
    return switch (v) {
        .int => "int",
        .float => "float",
        .decimal => "decimal",
        .rune => "rune",
        .boolean => "bool",
        .string => "string",
        .error_value => "error",
        .null => "null",
        .object => |obj| switch (obj.*) {
            .named_value => obj.named_value.typ.named_type.name,
            .dyn_string => "string",
            .array, .array_managed => "array",
            .map, .map_managed, .map_hashed => "map",
            .function, .closure => "func",
            else => "object",
        },
    };
}

// Conditions are bool-only; explain what arrived instead of a bare TypeError.
fn condAsBool(v: Value, what: []const u8) !bool {
    return v.asBool() catch {
        vms.setRuntimeErr("{s} must be bool, got {s}; use a comparison or std.conv.to_bool", .{ what, runtimeTypeName(v) });
        return error.TypeError;
    };
}

fn setBinaryTypeError(op: []const u8, a: Value, b: Value) void {
    const a_named = a == .object and a.object.* == .named_value;
    const b_named = b == .object and b.object.* == .named_value;
    if (a_named and b_named) {
        const ta = a.object.named_value.typ.named_type;
        const tb = b.object.named_value.typ.named_type;
        if (ta.base == tb.base and !namedTypeIsSubOf(a.object.named_value.typ, b.object.named_value.typ) and !namedTypeIsSubOf(b.object.named_value.typ, a.object.named_value.typ)) {
            vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}; convert one side explicitly before applying '{s}'", .{ op, ta.name, tb.name, op });
            return;
        }
    } else if (a_named != b_named) {
        const named_v = if (a_named) a else b;
        const raw_v = if (a_named) b else a;
        const named_typ = named_v.object.named_value.typ.named_type;
        const raw_name = runtimeTypeName(raw_v);
        vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}; wrap the {s} with {s}(...) or unwrap the named value with {s}(...)", .{
            op,
            named_typ.name,
            raw_name,
            raw_name,
            named_typ.name,
            namedBaseName(named_typ.base),
        });
        return;
    }
    if ((a == .int and b == .float) or (a == .float and b == .int)) {
        vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}; use matching numeric types such as 2.0 or float(2)", .{
            op,
            runtimeTypeName(a),
            runtimeTypeName(b),
        });
        return;
    }
    vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}", .{ op, runtimeTypeName(a), runtimeTypeName(b) });
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
    const ea = if (a == .object and a.object.* == .named_value) a.object.named_value.value else a;
    const eb = if (b == .object and b.object.* == .named_value) b.object.named_value.value else b;
    const ea_raw = ea == .int or ea == .float;
    const eb_raw = eb == .int or eb == .float;
    if (ea_raw and eb_raw and @as(VTag, ea) != @as(VTag, eb)) {
        vms.setRuntimeErr("cannot apply '{s}' to {s} and {s}; use matching numeric types such as 2.0 or float(2)", .{ op, runtimeTypeName(a), runtimeTypeName(b) });
        return error.TypeError;
    }
}

fn valueAsNumberForCompare(v: Value, other: Value) !f64 {
    return vms.valueAsNumber(v) catch |err| {
        if (err == error.TypeError) {
            vms.setRuntimeErr("cannot compare {s} and {s}", .{ runtimeTypeName(v), runtimeTypeName(other) });
        }
        return err;
    };
}

fn valueAsIntForOp(v: Value, other: Value, op: []const u8) !i64 {
    return vms.valueAsInt(v) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(op, v, other);
        return err;
    };
}

fn checkNamedValueCompatibility(a: Value, b: Value) !void {
    const a_named = a == .object and a.object.* == .named_value;
    const b_named = b == .object and b.object.* == .named_value;
    if (a_named and b_named) {
        if (a.object.named_value.typ != b.object.named_value.typ) {
            const ta = a.object.named_value.typ;
            const tb = b.object.named_value.typ;
            if (!namedTypeIsSubOf(ta, tb) and !namedTypeIsSubOf(tb, ta)) {
                vms.setRuntimeErr("cannot mix {s} and {s}; convert one side explicitly", .{ ta.named_type.name, tb.named_type.name });
                return error.TypeError;
            }
        }
    } else if (a_named != b_named) {
        const named = if (a_named) a else b;
        const plain = if (a_named) b else a;
        const nt_name = named.object.named_value.typ.named_type.name;
        vms.setRuntimeErr("cannot mix {s} and {s}; wrap the {s} with {s}(...) or unwrap the named value with {s}(...)", .{
            nt_name, runtimeTypeName(plain), runtimeTypeName(plain), nt_name, runtimeTypeName(plain),
        });
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

fn makeNumeric(tag: VTag, n: f64) Value {
    return switch (tag) {
        .int => .{ .int = n },
        .float => .{ .float = n },
        else => .{ .int = n },
    };
}

fn pushNumericResultWithCarrier(a: Value, b: Value, n: f64, tag: VTag, op: []const u8) !void {
    if (!std.math.isFinite(n)) {
        vms.setRuntimeErr("non-finite value in arithmetic operation", .{});
        return error.TypeError;
    }
    const val = makeNumeric(tag, n);
    const carrier = namedTypeCarrier(a, b) catch |err| {
        if (err == error.TypeError) setBinaryTypeError(op, a, b);
        return err;
    };
    if (carrier) |typ| {
        const wrapped = try vmtyp.coerceNamedTypeResult(typ, val);
        try checkNamedTypePredicate(typ, wrapped.object.named_value.value);
        try vmPush(wrapped);
    } else {
        try vmPush(val);
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
    const arr_obj = try vmAllocObject();
    arr_obj.* = .{ .array = &[_]Value{} }; // safe tag before GC can run
    try pushTempRoot(.{ .object = arr_obj });
    defer popTempRoot();
    const items = try vmAllocManagedSlice(Value, extra);
    var i: usize = 0;
    while (i < extra) : (i += 1) items[i] = vmState().stack[start + fixed + i];
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
        var pi: usize = 0;
        while (pi < parent_members.len) : (pi += 1) {
            if (common.streq(parent_members[pi], member_name)) {
                const ev = try vmAllocObject();
                ev.* = .{ .enum_value = .{ .typ = parent_obj, .name = parent_members[pi], .ordinal = @intCast(pi) } };
                return .{ .object = ev };
            }
        }
        return error.UnknownStructField;
    } else {
        // Regular enum.
        var ei: usize = 0;
        while (ei < et.members.len) : (ei += 1) {
            if (common.streq(et.members[ei], member_name)) {
                const ev = try vmAllocObject();
                ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[ei], .ordinal = @intCast(ei) } };
                return .{ .object = ev };
            }
        }
        return error.UnknownStructField;
    }
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
                .int     => |n| std.fmt.bufPrint(&vbuf, "{d}", .{@as(i64, @intFromFloat(@trunc(n)))}) catch "?",
                .float   => |n| std.fmt.bufPrint(&vbuf, "{d}", .{n}) catch "?",
                .decimal => |d| std.fmt.bufPrint(&vbuf, "{d}", .{d}) catch "?",
                .string  => |s| s,
                .boolean => |b| if (b) "true" else "false",
                .rune    => |r| blk: {
                    const n = std.unicode.utf8Encode(r, vbuf[0..4]) catch 0;
                    break :blk vbuf[0..n];
                },
                else     => "?",
            };
            if (nt.predicate_msg) |msg| {
                vms.setRuntimeErr("{s}({s}): {s}", .{ nt.name, vstr, msg });
            } else {
                vms.setRuntimeErr("predicate failed for {s}({s})", .{ nt.name, vstr });
            }
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

fn performCall(argc: u8) !void {
    if (vmState().stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const func_val = vmState().stack[vmState().stack_top - argc - 1];
    if (func_val != .object) return error.NotAFunction;
    const obj = func_val.object;
    switch (obj.*) {
        .function => |f| {
            if (f.is_variadic) {
                if (argc < f.arity - 1) {
                    if (f.name.len > 0) { vms.setRuntimeErr("{s}: expected at least {} argument(s), got {}", .{ f.name, f.arity - 1, argc }); } else { vms.setRuntimeErr("expected at least {} argument(s), got {}", .{ f.arity - 1, argc }); }
                    return error.ArityMismatch;
                }
            } else if (f.arity != argc) {
                if (f.name.len > 0) { vms.setRuntimeErr("{s}: expected {} argument(s), got {}", .{ f.name, f.arity, argc }); } else { vms.setRuntimeErr("expected {} argument(s), got {}", .{ f.arity, argc }); }
                return error.ArityMismatch;
            }
            if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
            try prepareVariadicCall(f, argc);
            if (vmState().frame_top >= vmState().frames.len) return error.CallStackOverflow;
            vmState().frames[vmState().frame_top] = .{
                .ret_ip = vmState().ip,
                .base = vmState().stack_top - f.arity,
                .closure = null,
                .func_obj = obj,
                .defer_base = vmState().defer_top,
                .has_typed_returns = f.has_typed_returns,
            };
            vmState().frame_top += 1;
            vmState().ip = f.ip;
        },
        .closure => |cl| {
            const f = cl.func.function;
            if (f.is_variadic) {
                if (argc < f.arity - 1) {
                    if (f.name.len > 0) { vms.setRuntimeErr("{s}: expected at least {} argument(s), got {}", .{ f.name, f.arity - 1, argc }); } else { vms.setRuntimeErr("expected at least {} argument(s), got {}", .{ f.arity - 1, argc }); }
                    return error.ArityMismatch;
                }
            } else if (f.arity != argc) {
                if (f.name.len > 0) { vms.setRuntimeErr("{s}: expected {} argument(s), got {}", .{ f.name, f.arity, argc }); } else { vms.setRuntimeErr("expected {} argument(s), got {}", .{ f.arity, argc }); }
                return error.ArityMismatch;
            }
            if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
            try prepareVariadicCall(f, argc);
            if (vmState().frame_top >= vmState().frames.len) return error.CallStackOverflow;
            vmState().frames[vmState().frame_top] = .{
                .ret_ip = vmState().ip,
                .base = vmState().stack_top - f.arity,
                .closure = obj,
                .func_obj = cl.func,
                .defer_base = vmState().defer_top,
                .has_typed_returns = f.has_typed_returns,
            };
            vmState().frame_top += 1;
            vmState().ip = f.ip;
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
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
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
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(arg);
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
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(.{ .object = vv });
        },
        .named_type_fn => |nf| {
            if (argc != 1) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try vmtyp.applyNamedTypeFn(nf.typ, nf.kind, arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
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
    if (callee_obj.* == .closure) {
        const cl = callee_obj.closure;
        const f = cl.func.function;
        if (f.is_variadic) return false;
        if (f.arity != argc) return false;
        if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            writeFrameLocal(frame.base + i, vmState().stack[callee_idx + 1 + i]);
        }
        frame.closure = callee_obj;
        frame.func_obj = cl.func;
        vmState().stack_top = frame.base + argc;
        vmState().ip = f.ip;
        return true;
    }
    if (callee_obj.* == .function) {
        const f = callee_obj.function;
        if (f.is_variadic) return false;
        if (f.arity != argc) return false;
        if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            writeFrameLocal(frame.base + i, vmState().stack[callee_idx + 1 + i]);
        }
        frame.closure = null;
        frame.func_obj = callee_obj;
        vmState().stack_top = frame.base + argc;
        vmState().ip = f.ip;
        return true;
    }
    return false;
}

fn iterInit(v: Value) !Value {
    const obj = try vmAllocObject();
    const iv = if (v == .object and v.object.* == .named_value) v.object.named_value.value else v;
    switch (iv) {
        .object => |o| switch (o.*) {
            .dyn_string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s, .string_managed = true, .source = o } },
            .array, .array_managed => obj.* = .{ .iterator = .{ .kind = .array, .index = 0, .array = try vms.asArraySlice(o), .source = o } },
            .map, .map_managed, .map_hashed => obj.* = .{ .iterator = .{ .kind = .map, .index = 0, .map = try vms.asMapSlice(o), .source = o } },
            .named_type => |nt| {
                if (!nt.has_range) return error.TypeError;
                obj.* = .{ .iterator = .{ .kind = .range, .index = 0, .range_current = nt.min, .range_max = nt.max, .source = o } };
            },
            else => return error.TypeError,
        },
        .string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s, .string_managed = false } },
        else => return error.TypeError,
    }
    return .{ .object = obj };
}

fn iterNext1(it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (it.index >= it.array.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const v = it.array[it.index];
            it.index += 1;
            try vmPush(v);
            try vmPush(.{ .boolean = true });
        },
        .string => {
            if (it.index >= it.string.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const ridx = it.rune_index;
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            if (it.string_managed) {
                try vmPush(try makeDynString(it.string[start..end]));
            } else {
                try vmPush(.{ .string = it.string[start..end] });
            }
            it.index = end;
            it.rune_index += 1;
            try vmPush(.{ .boolean = true });
        },
        .map => {
            if (it.index >= it.map.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
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
            const val = try vmtyp.makeNamedValue(typ_obj, if (nt.base == .float) .{ .float = it.range_current } else .{ .int = it.range_current });
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
            if (it.index >= it.array.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            try vmPush(.{ .int = @floatFromInt(it.index) });
            try vmPush(it.array[it.index]);
            it.index += 1;
            try vmPush(.{ .boolean = true });
        },
        .string => {
            if (it.index >= it.string.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const ridx = it.rune_index;
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            try vmPush(.{ .int = @floatFromInt(it.rune_index) });
            if (it.string_managed) {
                try vmPush(try makeDynString(it.string[start..end]));
            } else {
                try vmPush(.{ .string = it.string[start..end] });
            }
            it.index = end;
            it.rune_index += 1;
            try vmPush(.{ .boolean = true });
        },
        .map => {
            if (it.index >= it.map.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
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
            var di: usize = 0;
            while (di < arr.len) : (di += 1) try vmPush(arr[di]);
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
                retval = if (raw == .object and raw.object.* == .cell) raw.object.cell.value else raw;
            } else {
                const nrc: usize = fsig.named_return_count;
                const arr_obj = try vmAllocObject();
                arr_obj.* = .{ .array = &[_]Value{} };
                try pushTempRoot(.{ .object = arr_obj });
                const items = try vmAllocManagedSlice(Value, nrc);
                var ri: usize = 0;
                while (ri < nrc) : (ri += 1) {
                    if (nrbase + ri >= vmState().stack.len) return error.StackOverflow;
                    const raw = vmState().stack[nrbase + ri];
                    items[ri] = if (raw == .object and raw.object.* == .cell) raw.object.cell.value else raw;
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

fn opGetLocalGetField() !void {
    const slot = try vmByte();
    vmState().ip += 1; // skip embedded get_field opcode byte
    const name_idx = try vmShort();
    const ic_base = vmState().ip;
    const ic_type_idx = try vmShort();
    const ic_fidx = try vmByte();
    const frame_base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
    if (frame_base + slot >= vmState().stack.len) return error.StackOverflow;
    var raw = vmState().stack[frame_base + slot];
    if (raw == .object and raw.object.* == .cell) raw = raw.object.cell.value;
    const container = if (raw == .object and raw.object.* == .named_value)
        raw.object.named_value.value
    else
        raw;
    if (container != .object) return error.TypeError;
    const obj = container.object;
    switch (obj.*) {
        .array, .array_managed => {
            const name = (try chunk.constAt(name_idx)).string;
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
                const name = (try chunk.constAt(name_idx)).string;
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
            const name = (try chunk.constAt(name_idx)).string;
            if (common.streq(name, "len")) {
                const items = try vms.asMapSlice(obj);
                try vmPush(.{ .int = @floatFromInt(items.len) });
            } else {
                const items = try vms.asMapSlice(obj);
                const key_v = Value{ .string = name };
                var i: usize = 0;
                while (i < items.len) : (i += 1) {
                    if (vmmap.mapKeyEquals(items[i].key, key_v)) {
                        try vmPush(items[i].value);
                        break;
                    }
                }
                if (i == items.len) try vmPush(.null);
            }
        },
        .map_hashed => |hm| {
            const name = (try chunk.constAt(name_idx)).string;
            if (common.streq(name, "len")) {
                try vmPush(.{ .int = @floatFromInt(hm.len) });
            } else {
                const key_v = Value{ .string = name };
                if (vmmap.mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key_v)) |fi| {
                    try vmPush(hm.entries[fi].value);
                } else {
                    try vmPush(.null);
                }
            }
        },
        .enum_type => |et| {
            const name = (try chunk.constAt(name_idx)).string;
            if (common.streq(name, "name")) {
                try vmPush(.{ .string = et.name });
            } else if (common.streq(name, "first")) {
                if (et.members.len == 0) return error.IndexOutOfBounds;
                try vmPush(try enumTypeAllocValue(obj, et.members[0]));
            } else if (common.streq(name, "last")) {
                if (et.members.len == 0) return error.IndexOutOfBounds;
                try vmPush(try enumTypeAllocValue(obj, et.members[et.members.len - 1]));
            } else if (common.streq(name, "values")) {
                const arr_obj = try vmAllocObject();
                arr_obj.* = .{ .array = &[_]Value{} };
                try pushTempRoot(.{ .object = arr_obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, et.members.len);
                var ei: usize = 0;
                while (ei < et.members.len) : (ei += 1) {
                    items[ei] = try enumTypeAllocValue(obj, et.members[ei]);
                    arr_obj.* = .{ .array_managed = items[0 .. ei + 1] };
                }
                try vmPush(.{ .object = arr_obj });
            } else {
                try vmPush(try enumTypeAllocValue(obj, name));
            }
        },
        .named_type => |nt| {
            const name = (try chunk.constAt(name_idx)).string;
            if (common.streq(name, "name")) {
                try vmPush(.{ .string = nt.name });
            } else if (common.streq(name, "first")) {
                if (!nt.has_range) return error.TypeError;
                try vmPush(try vmtyp.makeNamedValue(obj, if (nt.base == .float) .{ .float = nt.min } else .{ .int = nt.min }));
            } else if (common.streq(name, "last")) {
                if (!nt.has_range) return error.TypeError;
                try vmPush(try vmtyp.makeNamedValue(obj, if (nt.base == .float) .{ .float = nt.max } else .{ .int = nt.max }));
            } else if (common.streq(name, "succ") or common.streq(name, "pred")) {
                if (!nt.has_range) return error.TypeError;
                const fn_obj = try vmAllocObject();
                const kind: @import("value.zig").NamedTypeFnKind = if (common.streq(name, "succ")) .succ else .pred;
                fn_obj.* = .{ .named_type_fn = .{ .typ = obj, .kind = kind } };
                try vmPush(.{ .object = fn_obj });
            } else return error.UnknownStructField;
        },
        .variant_type => |vt| {
            const name = (try chunk.constAt(name_idx)).string;
            if (common.streq(name, "name")) {
                try vmPush(.{ .string = vt.name });
            } else {
                var vi: usize = 0;
                while (vi < vt.arms.len) : (vi += 1) {
                    if (common.streq(vt.arms[vi].name, name)) {
                        const arm = vt.arms[vi];
                        const has_shared = vt.shared_fields.len > 0;
                        if (arm.has_payload or has_shared) {
                            const ctor = try vmAllocObject();
                            ctor.* = .{ .variant_ctor = .{
                                .typ = obj,
                                .tag = arm.name,
                                .ordinal = vi,
                                .payload_type = arm.payload_type,
                            }};
                            try vmPush(.{ .object = ctor });
                        } else {
                            const vv = try vmAllocObject();
                            vv.* = .{ .variant_value = .{
                                .typ = obj,
                                .tag = arm.name,
                                .ordinal = vi,
                                .payload = .null,
                            }};
                            try vmPush(.{ .object = vv });
                        }
                        break;
                    }
                }
                if (vi == vt.arms.len) return error.UnknownStructField;
            }
        },
        .variant_value => |vv| {
            const vt = vv.typ.variant_type;
            const vvn = (try chunk.constAt(name_idx)).string;
            if (vmtyp.findFieldIndex(vt.shared_fields, vvn)) |idx| {
                try vmPush(vv.shared_values[idx]);
                return;
            }
            const arm = vt.arms[vv.ordinal];
            if (arm.fields.len > 0) {
                for (arm.fields, 0..) |af, afi| {
                    if (common.streq(af.name, vvn)) {
                        try vmPush(vv.arm_fields[afi]);
                        return;
                    }
                }
            } else if (arm.has_payload and common.streq(arm.payload_name, vvn)) {
                try vmPush(vv.payload);
                return;
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    }
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
    const container = if (raw == .object and raw.object.* == .named_value)
        raw.object.named_value.value
    else
        raw;
    switch (container) {
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| {
                const ridx = try vms.vmIndexFromVal(idx_v);
                const start = try vmstr.utf8ByteOffsetForRuneIndexCached(s, ridx);
                const w = try vmstr.utf8NextRuneByteLen(s, start);
                try vmPush(try makeDynString(s[start .. start + w]));
            },
            .array, .array_managed => {
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
                var i: usize = 0;
                while (i < items.len) : (i += 1) {
                    if (vmmap.mapKeyEquals(items[i].key, idx_v)) {
                        try vmPush(items[i].value);
                        break;
                    }
                }
                if (i == items.len) try vmPush(.null);
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
            .enum_type => |et| {
                const key = try vms.asStringValue(idx_v);
                if (common.streq(key, "name")) {
                    try vmPush(.{ .string = et.name });
                } else if (common.streq(key, "first")) {
                    if (et.members.len == 0) return error.IndexOutOfBounds;
                    try vmPush(try enumTypeAllocValue(obj, et.members[0]));
                } else if (common.streq(key, "last")) {
                    if (et.members.len == 0) return error.IndexOutOfBounds;
                    try vmPush(try enumTypeAllocValue(obj, et.members[et.members.len - 1]));
                } else if (common.streq(key, "values")) {
                    const arr_obj = try vmAllocObject();
                    arr_obj.* = .{ .array = &[_]Value{} };
                    try pushTempRoot(.{ .object = arr_obj });
                    defer popTempRoot();
                    const items = try vmAllocManagedSlice(Value, et.members.len);
                    var ei: usize = 0;
                    while (ei < et.members.len) : (ei += 1) {
                        items[ei] = try enumTypeAllocValue(obj, et.members[ei]);
                        arr_obj.* = .{ .array_managed = items[0 .. ei + 1] };
                    }
                    try vmPush(.{ .object = arr_obj });
                } else {
                    try vmPush(try enumTypeAllocValue(obj, key));
                }
            },
            .named_type => |nt| {
                const key = try vms.asStringValue(idx_v);
                if (common.streq(key, "name")) {
                    try vmPush(.{ .string = nt.name });
                } else if (common.streq(key, "first")) {
                    if (!nt.has_range) return error.TypeError;
                    try vmPush(try vmtyp.makeNamedValue(obj, if (nt.base == .float) .{ .float = nt.min } else .{ .int = nt.min }));
                } else if (common.streq(key, "last")) {
                    if (!nt.has_range) return error.TypeError;
                    try vmPush(try vmtyp.makeNamedValue(obj, if (nt.base == .float) .{ .float = nt.max } else .{ .int = nt.max }));
                } else return error.UnknownStructField;
            },
            .variant_type => |vt| {
                const key = try vms.asStringValue(idx_v);
                if (common.streq(key, "name")) {
                    try vmPush(.{ .string = vt.name });
                } else {
                    var vi: usize = 0;
                    while (vi < vt.arms.len) : (vi += 1) {
                        if (common.streq(vt.arms[vi].name, key)) {
                            const arm = vt.arms[vi];
                            if (arm.has_payload) {
                                const ctor = try vmAllocObject();
                                ctor.* = .{ .variant_ctor = .{
                                    .typ = obj,
                                    .tag = arm.name,
                                    .ordinal = vi,
                                    .payload_type = arm.payload_type,
                                }};
                                try vmPush(.{ .object = ctor });
                            } else {
                                const vv = try vmAllocObject();
                                vv.* = .{ .variant_value = .{
                                    .typ = obj,
                                    .tag = arm.name,
                                    .ordinal = vi,
                                    .payload = .null,
                                }};
                                try vmPush(.{ .object = vv });
                            }
                            break;
                        }
                    }
                    if (vi == vt.arms.len) return error.UnknownStructField;
                }
            },
            else => return error.TypeError,
        },
        .string => |s| {
            const ridx = try vms.vmIndexFromVal(idx_v);
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(s, ridx);
            const w = try vmstr.utf8NextRuneByteLen(s, start);
            try vmPush(.{ .string = s[start .. start + w] });
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
        .array, .array_managed => {
            const items = try vms.asArraySlice(container.object);
            const idx = try vms.vmIndexFromVal(idx_v);
            if (idx >= items.len) {
                vms.setRuntimeErr("index {} out of bounds for array of length {}", .{ idx, items.len });
                return error.IndexOutOfBounds;
            }
            items[idx] = val;
        },
        .map, .map_managed => {
            const items = try vms.asMapSlice(container.object);
            var i: usize = 0;
            var updated = false;
            while (i < items.len) : (i += 1) {
                if (vmmap.mapKeyEquals(items[i].key, idx_v)) {
                    items[i].value = val;
                    updated = true;
                    break;
                }
            }
            if (!updated) {
                try pushTempRoot(container);
                defer popTempRoot();
                const ext = try vmAllocManagedSlice(MapEntry, items.len + 1);
                @memcpy(ext[0..items.len], items);
                ext[items.len] = .{ .key = idx_v, .value = val };
                const new_len = items.len + 1;
                if (container.object.* == .map_managed) heap.freeManagedSlice(MapEntry, container.object.map_managed);
                container.object.* = .{ .map_managed = ext[0..new_len] };
                // Auto-promote to hashed map once linear scan becomes expensive.
                if (new_len > 8) {
                    const bcount = vmmap.mapBucketsForCount(new_len);
                    const buckets = try vmAllocManagedSlice(i32, bcount);
                    vmmap.mapBuildHashedBuckets(ext[0..new_len], buckets);
                    container.object.* = .{ .map_hashed = .{ .entries = ext[0..new_len], .len = new_len, .buckets = buckets } };
                }
            }
        },
        .map_hashed => {
            try vmmap.mapInsertHashed(container.object, idx_v, val);
        },
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
    const mname = (try vmConst()).string;
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
            var func: Value = undefined;
            var pass_recv = true;
            if (ic_type_idx == @as(usize, tpi) and ic_func_idx != 0xFFFF) {
                if (ic_func_idx >= heap.MaxObjects) return error.NotAMethodReceiver;
                func = .{ .object = heap.objectAt(@intCast(ic_func_idx)) };
            } else {
                const tname = inst.typ.struct_type.qualified_name;
                const total = tname.len + 1 + mname.len;
                if (total > 512) return error.NotAMethodReceiver;
                var key_buf: [512]u8 = undefined;
                @memcpy(key_buf[0..tname.len], tname);
                key_buf[tname.len] = '.';
                @memcpy(key_buf[tname.len + 1 .. total], mname);
                if (globals.get(key_buf[0..total])) |method_func| {
                    func = method_func;
                } else {
                    const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, mname) orelse {
                        if (isModuleNamespaceStruct(inst.typ)) return error.UnknownStructField;
                        return error.UnknownMethod;
                    };
                    func = inst.fields[fi].value;
                    pass_recv = false;
                }
                if (pass_recv and func == .object) {
                    const fpi = heap.objectPoolIndex(func.object);
                    if (fpi != 0xFFFF) {
                        chunk.patchByte(ic_base + 0, @intCast((tpi >> 8) & 0xFF));
                        chunk.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                        chunk.patchByte(ic_base + 2, @intCast((fpi >> 8) & 0xFF));
                        chunk.patchByte(ic_base + 3, @intCast(fpi & 0xFF));
                    }
                }
            }
            if (pass_recv) {
                if (vmState().stack_top >= vmState().stack.len) return error.StackOverflow;
                var i: usize = vmState().stack_top;
                while (i > recv_idx + 1) {
                    vmState().stack[i] = vmState().stack[i - 1];
                    i -= 1;
                }
                vmState().stack_top += 1;
                vmState().stack[recv_idx] = func;
                vmState().stack[recv_idx + 1] = recv;
                try performCall(argc + 1);
            } else {
                vmState().stack[recv_idx] = func;
                try performCall(argc);
            }
        },
        .map, .map_managed, .map_hashed => {
            const items = try vms.asMapSlice(recv.object);
            var i: usize = 0;
            var maybe: ?Value = null;
            while (i < items.len) : (i += 1) {
                if (vms.isStringValue(items[i].key) and common.streq(try vms.asStringValue(items[i].key), mname)) {
                    maybe = items[i].value;
                    break;
                }
            }
            const func = maybe orelse return error.UnknownMethod;
            vmState().stack[recv_idx] = func;
            try performCall(argc);
        },
        .variant_type => |vt| {
            var vi: usize = 0;
            while (vi < vt.arms.len) : (vi += 1) {
                if (common.streq(vt.arms[vi].name, mname)) break;
            }
            if (vi == vt.arms.len) return error.UnknownStructField;
            const arm = vt.arms[vi];
            if (arm.has_payload) {
                if (argc != 1) return error.ArityMismatch;
                const payload = vmState().stack[vmState().stack_top - 1];
                if (arm.payload_type) |pt| {
                    if (!vmtyp.matchesTypeSpec(payload, pt)) return error.TypeError;
                }
                const vv = try vmAllocObject();
                vv.* = .{ .variant_value = .{ .typ = recv.object, .tag = arm.name, .ordinal = vi, .payload = payload } };
                var i: usize = @as(usize, argc) + 1;
                while (i > 0) : (i -= 1) { _ = try vmPop(); }
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
        .named_value => |nv| {
            const tname = switch (nv.typ.*) {
                .named_type => |nt| nt.qualified_name,
                else => return error.NotAMethodReceiver,
            };
            const total = tname.len + 1 + mname.len;
            if (total > 512) return error.NotAMethodReceiver;
            var key_buf: [512]u8 = undefined;
            @memcpy(key_buf[0..tname.len], tname);
            key_buf[tname.len] = '.';
            @memcpy(key_buf[tname.len + 1 .. total], mname);
            const func = globals.get(key_buf[0..total]) orelse return error.UnknownMethod;
            if (vmState().stack_top >= vmState().stack.len) return error.StackOverflow;
            var si: usize = vmState().stack_top;
            while (si > recv_idx + 1) : (si -= 1) vmState().stack[si] = vmState().stack[si - 1];
            vmState().stack_top += 1;
            vmState().stack[recv_idx] = func;
            vmState().stack[recv_idx + 1] = recv;
            try performCall(argc + 1);
        },
        .enum_value => |ev| {
            const tname = ev.typ.enum_type.qualified_name;
            const total = tname.len + 1 + mname.len;
            if (total > 512) return error.NotAMethodReceiver;
            var key_buf: [512]u8 = undefined;
            @memcpy(key_buf[0..tname.len], tname);
            key_buf[tname.len] = '.';
            @memcpy(key_buf[tname.len + 1 .. total], mname);
            const func = globals.get(key_buf[0..total]) orelse return error.UnknownMethod;
            if (vmState().stack_top >= vmState().stack.len) return error.StackOverflow;
            var si: usize = vmState().stack_top;
            while (si > recv_idx + 1) : (si -= 1) vmState().stack[si] = vmState().stack[si - 1];
            vmState().stack_top += 1;
            vmState().stack[recv_idx] = func;
            vmState().stack[recv_idx + 1] = recv;
            try performCall(argc + 1);
        },
        .variant_value => |vv| {
            const tname = vv.typ.variant_type.qualified_name;
            const total = tname.len + 1 + mname.len;
            if (total > 512) return error.NotAMethodReceiver;
            var key_buf: [512]u8 = undefined;
            @memcpy(key_buf[0..tname.len], tname);
            key_buf[tname.len] = '.';
            @memcpy(key_buf[tname.len + 1 .. total], mname);
            const func = globals.get(key_buf[0..total]) orelse return error.UnknownMethod;
            if (vmState().stack_top >= vmState().stack.len) return error.StackOverflow;
            var si: usize = vmState().stack_top;
            while (si > recv_idx + 1) : (si -= 1) vmState().stack[si] = vmState().stack[si - 1];
            vmState().stack_top += 1;
            vmState().stack[recv_idx] = func;
            vmState().stack[recv_idx + 1] = recv;
            try performCall(argc + 1);
        },
        .array, .array_managed => {
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
    const name = (try chunk.constAt(name_idx)).string;
    const raw = try vmPop();
    var rooted_raw = false;
    if (raw == .object) { try pushTempRoot(raw); rooted_raw = true; }
    defer if (rooted_raw) popTempRoot();
    const container = if (raw == .object and raw.object.* == .named_value)
        raw.object.named_value.value
    else
        raw;
    if (container != .object) return error.TypeError;
    const obj = container.object;
    switch (obj.*) {
        .array, .array_managed => {
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
            if (common.streq(name, "len")) {
                const items = try vms.asMapSlice(obj);
                try vmPush(.{ .int = @floatFromInt(items.len) });
            } else {
                const items = try vms.asMapSlice(obj);
                const key_v = Value{ .string = name };
                var i: usize = 0;
                while (i < items.len) : (i += 1) {
                    if (vmmap.mapKeyEquals(items[i].key, key_v)) {
                        try vmPush(items[i].value);
                        break;
                    }
                }
                if (i == items.len) try vmPush(.null);
            }
        },
        .map_hashed => |hm| {
            if (common.streq(name, "len")) {
                try vmPush(.{ .int = @floatFromInt(hm.len) });
            } else {
                const key_v = Value{ .string = name };
                if (vmmap.mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key_v)) |fi| {
                    try vmPush(hm.entries[fi].value);
                } else {
                    try vmPush(.null);
                }
            }
        },
        .enum_type => |et| {
            if (common.streq(name, "name")) {
                try vmPush(.{ .string = et.name });
            } else if (common.streq(name, "first")) {
                if (et.members.len == 0) return error.IndexOutOfBounds;
                try vmPush(try enumTypeAllocValue(obj, et.members[0]));
            } else if (common.streq(name, "last")) {
                if (et.members.len == 0) return error.IndexOutOfBounds;
                try vmPush(try enumTypeAllocValue(obj, et.members[et.members.len - 1]));
            } else if (common.streq(name, "values")) {
                const arr_obj = try vmAllocObject();
                arr_obj.* = .{ .array = &[_]Value{} };
                try pushTempRoot(.{ .object = arr_obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, et.members.len);
                var ei: usize = 0;
                while (ei < et.members.len) : (ei += 1) {
                    items[ei] = try enumTypeAllocValue(obj, et.members[ei]);
                    arr_obj.* = .{ .array_managed = items[0 .. ei + 1] };
                }
                try vmPush(.{ .object = arr_obj });
            } else {
                try vmPush(try enumTypeAllocValue(obj, name));
            }
        },
        .named_type => |nt| {
            if (common.streq(name, "name")) {
                try vmPush(.{ .string = nt.name });
            } else if (common.streq(name, "first")) {
                if (!nt.has_range) return error.TypeError;
                try vmPush(try vmtyp.makeNamedValue(obj, if (nt.base == .float) .{ .float = nt.min } else .{ .int = nt.min }));
            } else if (common.streq(name, "last")) {
                if (!nt.has_range) return error.TypeError;
                try vmPush(try vmtyp.makeNamedValue(obj, if (nt.base == .float) .{ .float = nt.max } else .{ .int = nt.max }));
            } else if (common.streq(name, "succ") or common.streq(name, "pred")) {
                if (!nt.has_range) return error.TypeError;
                const fn_obj = try vmAllocObject();
                const kind: @import("value.zig").NamedTypeFnKind = if (common.streq(name, "succ")) .succ else .pred;
                fn_obj.* = .{ .named_type_fn = .{ .typ = obj, .kind = kind } };
                try vmPush(.{ .object = fn_obj });
            } else return error.UnknownStructField;
        },
        .variant_type => |vt| {
            if (common.streq(name, "name")) {
                try vmPush(.{ .string = vt.name });
            } else {
                var vi: usize = 0;
                while (vi < vt.arms.len) : (vi += 1) {
                    if (common.streq(vt.arms[vi].name, name)) {
                        const arm = vt.arms[vi];
                        const has_shared = vt.shared_fields.len > 0;
                        if (arm.has_payload or has_shared) {
                            const ctor = try vmAllocObject();
                            ctor.* = .{ .variant_ctor = .{
                                .typ = obj,
                                .tag = arm.name,
                                .ordinal = vi,
                                .payload_type = arm.payload_type,
                            }};
                            try vmPush(.{ .object = ctor });
                        } else {
                            const vv = try vmAllocObject();
                            vv.* = .{ .variant_value = .{
                                .typ = obj,
                                .tag = arm.name,
                                .ordinal = vi,
                                .payload = .null,
                            }};
                            try vmPush(.{ .object = vv });
                        }
                        break;
                    }
                }
                if (vi == vt.arms.len) return error.UnknownStructField;
            }
        },
        .variant_value => |vv| {
            const vt = vv.typ.variant_type;
            if (vmtyp.findFieldIndex(vt.shared_fields, name)) |idx| {
                try vmPush(vv.shared_values[idx]);
                return;
            }
            const arm = vt.arms[vv.ordinal];
            if (arm.fields.len > 0) {
                for (arm.fields, 0..) |af, afi| {
                    if (common.streq(af.name, name)) {
                        try vmPush(vv.arm_fields[afi]);
                        return;
                    }
                }
            } else if (arm.has_payload and common.streq(arm.payload_name, name)) {
                try vmPush(vv.payload);
                return;
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    }
}

fn opSetField() !void {
    const name_idx = try vmShort();
    const ic_base = vmState().ip;
    const ic_type_idx = try vmShort();
    const ic_fidx = try vmByte();
    const name = (try chunk.constAt(name_idx)).string;
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
        .map, .map_managed => {
            const items = try vms.asMapSlice(container.object);
            const key_v = Value{ .string = name };
            var i: usize = 0;
            var updated = false;
            while (i < items.len) : (i += 1) {
                if (vmmap.mapKeyEquals(items[i].key, key_v)) {
                    items[i].value = val;
                    updated = true;
                    break;
                }
            }
            if (!updated) {
                try pushTempRoot(container);
                defer popTempRoot();
                const ext = try vmAllocManagedSlice(MapEntry, items.len + 1);
                @memcpy(ext[0..items.len], items);
                ext[items.len] = .{ .key = .{ .string = name }, .value = val };
                const new_len = items.len + 1;
                if (container.object.* == .map_managed) heap.freeManagedSlice(MapEntry, container.object.map_managed);
                container.object.* = .{ .map_managed = ext[0..new_len] };
                if (new_len > 8) {
                    const bcount = vmmap.mapBucketsForCount(new_len);
                    const buckets = try vmAllocManagedSlice(i32, bcount);
                    vmmap.mapBuildHashedBuckets(ext[0..new_len], buckets);
                    container.object.* = .{ .map_hashed = .{ .entries = ext[0..new_len], .len = new_len, .buckets = buckets } };
                }
            }
        },
        .map_hashed => {
            const key_v = Value{ .string = name };
            try vmmap.mapInsertHashed(container.object, key_v, val);
        },
        else => return error.TypeError,
    }
}

fn opDeferInvokeMethod() !void {
    const mname = (try vmConst()).string;
    const argc = try vmByte();
    if (vmState().defer_top >= vmState().defer_stack.len) return error.DeferStackOverflow;
    if (vmState().stack_top < @as(usize, argc) + 1) return error.StackUnderflow;
    const recv_idx = vmState().stack_top - @as(usize, argc) - 1;
    const recv = vmState().stack[recv_idx];
    if (recv != .object) return error.NotAMethodReceiver;
    var func: Value = undefined;
    var pass_recv: bool = undefined;
    switch (recv.object.*) {
        .struct_instance => |inst| {
            const tname = inst.typ.struct_type.qualified_name;
            const key_total = tname.len + 1 + mname.len;
            if (key_total > 512) return error.NotAMethodReceiver;
            var key_buf: [512]u8 = undefined;
            @memcpy(key_buf[0..tname.len], tname);
            key_buf[tname.len] = '.';
            @memcpy(key_buf[tname.len + 1 .. key_total], mname);
            if (globals.get(key_buf[0..key_total])) |method_func| {
                func = method_func;
                pass_recv = true;
            } else {
                const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, mname) orelse {
                    if (isModuleNamespaceStruct(inst.typ)) return error.UnknownStructField;
                    return error.UnknownMethod;
                };
                func = inst.fields[fi].value;
                pass_recv = false;
            }
        },
        .map, .map_managed, .map_hashed => {
            const map_items = try vms.asMapSlice(recv.object);
            var found: ?Value = null;
            var mi: usize = 0;
            while (mi < map_items.len) : (mi += 1) {
                if (vms.isStringValue(map_items[mi].key)) {
                    const ks = vms.asStringValue(map_items[mi].key) catch continue;
                    if (common.streq(ks, mname)) { found = map_items[mi].value; break; }
                }
            }
            func = found orelse return error.UnknownMethod;
            pass_recv = false;
        },
        .named_value => |nv| {
            const tname = switch (nv.typ.*) {
                .named_type => |nt| nt.qualified_name,
                else => return error.NotAMethodReceiver,
            };
            const key_total = tname.len + 1 + mname.len;
            if (key_total > 512) return error.NotAMethodReceiver;
            var key_buf: [512]u8 = undefined;
            @memcpy(key_buf[0..tname.len], tname);
            key_buf[tname.len] = '.';
            @memcpy(key_buf[tname.len + 1 .. key_total], mname);
            func = globals.get(key_buf[0..key_total]) orelse return error.UnknownMethod;
            pass_recv = true;
        },
        .enum_value => |ev| {
            const tname = ev.typ.enum_type.qualified_name;
            const key_total = tname.len + 1 + mname.len;
            if (key_total > 512) return error.NotAMethodReceiver;
            var key_buf: [512]u8 = undefined;
            @memcpy(key_buf[0..tname.len], tname);
            key_buf[tname.len] = '.';
            @memcpy(key_buf[tname.len + 1 .. key_total], mname);
            func = globals.get(key_buf[0..key_total]) orelse return error.UnknownMethod;
            pass_recv = true;
        },
        .variant_value => |vv| {
            const tname = vv.typ.variant_type.qualified_name;
            const key_total = tname.len + 1 + mname.len;
            if (key_total > 512) return error.NotAMethodReceiver;
            var key_buf: [512]u8 = undefined;
            @memcpy(key_buf[0..tname.len], tname);
            key_buf[tname.len] = '.';
            @memcpy(key_buf[tname.len + 1 .. key_total], mname);
            func = globals.get(key_buf[0..key_total]) orelse return error.UnknownMethod;
            pass_recv = true;
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
    var ai: usize = 0;
    while (ai < argc) : (ai += 1) items[1 + extra + ai] = vmState().stack[recv_idx + 1 + ai];
    arr_obj.* = .{ .array_managed = items[0..total] };
    vmState().defer_stack[vmState().defer_top] = .{ .object = arr_obj };
    vmState().defer_top += 1;
    vmState().stack_top = recv_idx;
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
                const name = (try vmConst()).string;
                try globals.def(name, try vmPop());
            },
            .get_global => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                if (ic_slot != 0xFFFF) {
                    try vmPush(globals.getAt(ic_slot));
                } else {
                    const name = (try chunk.constAt(name_idx)).string;
                    const slot = globals.findSlot(name) orelse {
                        vms.setRuntimeErr("'{s}' is not defined", .{name});
                        return error.NotDefined;
                    };
                    chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
                    try vmPush(globals.getAt(slot));
                }
            },
            .set_global => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                const val = try vmPop();
                if (ic_slot != 0xFFFF) {
                    globals.setAt(ic_slot, val);
                } else {
                    const name = (try chunk.constAt(name_idx)).string;
                    const slot = globals.findSlot(name) orelse return error.NotDefined;
                    chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
                    globals.setAt(slot, val);
                }
            },

            .get_local => {
                const slot = try vmByte();
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                const v = vmState().stack[base + slot];
                if (v == .object and v.object.* == .cell) {
                    try vmPush(v.object.cell.value);
                } else {
                    try vmPush(v);
                }
            },
            .set_local => {
                const slot = try vmByte();
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                const val = try vmPop();
                const cur = vmState().stack[base + slot];
                if (cur == .object and cur.object.* == .cell) {
                    cur.object.cell.value = val;
                } else {
                    vmState().stack[base + slot] = val;
                }
            },
            .get_upvalue => {
                if (vmState().frame_top == 0) return error.StackUnderflow;
                const idx = try vmByte();
                const frame = vmState().frames[vmState().frame_top - 1];
                const cl = frame.closure orelse return error.TypeError;
                if (cl.* != .closure) return error.TypeError;
                if (idx >= cl.closure.upvalues.len) return error.TypeError;
                const cell = cl.closure.upvalues[idx];
                try vmPush(cell.cell.value);
            },
            .set_upvalue => {
                if (vmState().frame_top == 0) return error.StackUnderflow;
                const idx = try vmByte();
                const frame = vmState().frames[vmState().frame_top - 1];
                const cl = frame.closure orelse return error.TypeError;
                if (cl.* != .closure) return error.TypeError;
                if (idx >= cl.closure.upvalues.len) return error.TypeError;
                const val = try vmPop();
                const cell = cl.closure.upvalues[idx];
                cell.cell.value = val;
            },
            .close_upvalue => {
                const slot = try vmByte();
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                const v = vmState().stack[base + slot];
                if (v == .object and v.object.* == .cell) {
                    vmState().stack[base + slot] = v.object.cell.value;
                }
            },

            .add => {
                const b = try vmPop();
                const a = try vmPop();
                if (isStringValueOrNamedString(a) and isStringValueOrNamedString(b)) {
                    // a and b are off the Gengo stack; protect them so GC inside
                    // concatDynString can't free their backing bytes before the
                    // copy. They must stay rooted through the carrier wrap too:
                    // makeNamedValue allocates, and a freed operand's slot can
                    // be handed back as the new named value (#120 family).
                    try pushTempRoot(a);
                    defer popTempRoot();
                    try pushTempRoot(b);
                    defer popTempRoot();
                    const sa = try vms.asStringValue(a);
                    const sb = try vms.asStringValue(b);
                    vmperf.countStringConcat(sa.len + sb.len);
                    const result = try concatDynString(sa, sb);
                    try pushStringResultWithCarrier(a, b, result);
                } else if (decimalOpValues(a, b)) |dop| {
                    const result = @addWithOverflow(dop.lhs, dop.rhs);
                    if (result[1] != 0) return error.TypeError;
                    try pushDecimalResultWithCarrier(dop.typ, result[0]);
                } else {
                    const tag = numericOpTag(a, b) catch |err| {
                        if (err == error.TypeError) setBinaryTypeError("+", a, b);
                        return err;
                    };
                    const an = try valueAsNumberForOp(a, b, "+");
                    const bn = try valueAsNumberForOp(b, a, "+");
                    try pushNumericResultWithCarrier(a, b, an + bn, tag, "+");
                }
            },
            .sub => {
                const b = try vmPop();
                const a = try vmPop();
                if (decimalOpValues(a, b)) |dop| {
                    const result = @subWithOverflow(dop.lhs, dop.rhs);
                    if (result[1] != 0) return error.TypeError;
                    try pushDecimalResultWithCarrier(dop.typ, result[0]);
                } else {
                    const tag = numericOpTag(a, b) catch |err| {
                        if (err == error.TypeError) setBinaryTypeError("-", a, b);
                        return err;
                    };
                    const an = try valueAsNumberForOp(a, b, "-");
                    const bn = try valueAsNumberForOp(b, a, "-");
                    try pushNumericResultWithCarrier(a, b, an - bn, tag, "-");
                }
            },
            .mul => {
                const b = try vmPop();
                const a = try vmPop();
                if (decimalOpValues(a, b)) |_| {
                    return error.TypeError;
                } else if (a == .object and a.object.* == .named_value and a.object.named_value.typ.named_type.base == .decimal and b == .int and b.int >= @as(f64, @floatFromInt(std.math.minInt(i64))) and b.int < std.math.pow(f64, 2.0, 63.0)) {
                    const d = vms.valueAsDecimal(a.object.named_value.value) catch return error.TypeError;
                    const other = @as(i64, @intFromFloat(b.int));
                    const result = @mulWithOverflow(d, other);
                    if (result[1] != 0) return error.TypeError;
                    try pushDecimalResultWithCarrier(a.object.named_value.typ, result[0]);
                } else if (b == .object and b.object.* == .named_value and b.object.named_value.typ.named_type.base == .decimal and a == .int and a.int >= @as(f64, @floatFromInt(std.math.minInt(i64))) and a.int < std.math.pow(f64, 2.0, 63.0)) {
                    const d = vms.valueAsDecimal(b.object.named_value.value) catch return error.TypeError;
                    const other = @as(i64, @intFromFloat(a.int));
                    const result = @mulWithOverflow(d, other);
                    if (result[1] != 0) return error.TypeError;
                    try pushDecimalResultWithCarrier(b.object.named_value.typ, result[0]);
                } else {
                    const tag = numericOpTag(a, b) catch |err| {
                        if (err == error.TypeError) setBinaryTypeError("*", a, b);
                        return err;
                    };
                    const an = try valueAsNumberForOp(a, b, "*");
                    const bn = try valueAsNumberForOp(b, a, "*");
                    try pushNumericResultWithCarrier(a, b, an * bn, tag, "*");
                }
            },
            .div => {
                const b = try vmPop();
                const a = try vmPop();
                if (decimalOpValues(a, b)) |_| {
                    return error.TypeError;
                } else if (a == .object and a.object.* == .named_value and a.object.named_value.typ.named_type.base == .decimal and b == .int and b.int >= @as(f64, @floatFromInt(std.math.minInt(i64))) and b.int < std.math.pow(f64, 2.0, 63.0)) {
                    const d = vms.valueAsDecimal(a.object.named_value.value) catch return error.TypeError;
                    const divisor = @as(i64, @intFromFloat(b.int));
                    if (divisor == 0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    if (d == std.math.minInt(i64) and divisor == -1) return error.TypeError;
                    try pushDecimalResultWithCarrier(a.object.named_value.typ, @divTrunc(d, divisor));
                } else {
                    const tag = numericOpTag(a, b) catch |err| {
                        if (err == error.TypeError) setBinaryTypeError("/", a, b);
                        return err;
                    };
                    const an = try valueAsNumberForOp(a, b, "/");
                    const bn = try valueAsNumberForOp(b, a, "/");
                    if (bn == 0.0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                    if (a == .int and b == .int) {
                        try pushNumericResultWithCarrier(a, b, an / bn, .float, "/");
                    } else {
                        try pushNumericResultWithCarrier(a, b, an / bn, tag, "/");
                    }
                }
            },
            .mod => {
                const b = try vmPop();
                const a = try vmPop();
                const tag = numericOpTag(a, b) catch |err| {
                    if (err == error.TypeError) setBinaryTypeError("%", a, b);
                    return err;
                };
                const an = try valueAsNumberForOp(a, b, "%");
                const bn = try valueAsNumberForOp(b, a, "%");
                if (bn == 0.0) { vms.setRuntimeErr("division by zero", .{}); return error.DivisionByZero; }
                try pushNumericResultWithCarrier(a, b, common.fmod(an, bn), tag, "%");
            },
            .pow => {
                const b = try vmPop();
                const a = try vmPop();
                const tag = numericOpTag(a, b) catch |err| {
                    if (err == error.TypeError) setBinaryTypeError("**", a, b);
                    return err;
                };
                const an = try valueAsNumberForOp(a, b, "**");
                const bn = try valueAsNumberForOp(b, a, "**");
                try pushNumericResultWithCarrier(a, b, std.math.pow(f64, an, bn), tag, "**");
            },
            .bit_and => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsIntForOp(a, b, "&");
                const bn = try valueAsIntForOp(b, a, "&");
                const result = an & bn;
                if (result > (1 << 53) or result < -(1 << 53)) return error.RangeError;
                try pushNumericResultWithCarrier(a, b, @floatFromInt(result), .int, "&");
            },
            .bit_or => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsIntForOp(a, b, "|");
                const bn = try valueAsIntForOp(b, a, "|");
                const result = an | bn;
                if (result > (1 << 53) or result < -(1 << 53)) return error.RangeError;
                try pushNumericResultWithCarrier(a, b, @floatFromInt(result), .int, "|");
            },
            .bit_xor => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsIntForOp(a, b, "^");
                const bn = try valueAsIntForOp(b, a, "^");
                const result = an ^ bn;
                if (result > (1 << 53) or result < -(1 << 53)) return error.RangeError;
                try pushNumericResultWithCarrier(a, b, @floatFromInt(result), .int, "^");
            },
            .bit_not => {
                const v = try vmPeek(0);
                const n = try vms.valueAsInt(v);
                const raw = ~n;
                if (raw > (1 << 53) or raw < -(1 << 53)) return error.RangeError;
                const result: f64 = @floatFromInt(raw);
                if (v == .object and v.object.* == .named_value) {
                    const wrapped = try vmtyp.coerceNamedTypeResult(v.object.named_value.typ, .{ .int = result });
                    try checkNamedTypePredicate(v.object.named_value.typ, wrapped.object.named_value.value);
                    _ = try vmPop();
                    try vmPush(wrapped);
                } else {
                    _ = try vmPop();
                    try vmPush(.{ .int = result });
                }
            },
            .shl => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsIntForOp(a, b, "<<");
                const bn = try valueAsIntForOp(b, a, "<<");
                if (bn < 0) return error.RangeError;
                const shift: u6 = @intCast(@min(bn, 63));
                // Prevent signed left-shift overflow: if magnitude exceeds what i64 can hold after shift.
                if (an > 0 and an > (@as(i64, std.math.maxInt(i64)) >> shift)) return error.RangeError;
                if (an < 0 and an < (@as(i64, std.math.minInt(i64)) >> shift)) return error.RangeError;
                const result = an << shift;
                if (result > (1 << 53) or result < -(1 << 53)) return error.RangeError;
                try pushNumericResultWithCarrier(a, b, @floatFromInt(result), .int, "<<");
            },
            .shr => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsIntForOp(a, b, ">>");
                const bn = try valueAsIntForOp(b, a, ">>");
                if (bn < 0) return error.RangeError;
                const shift: u6 = @intCast(@min(bn, 63));
                const result = an >> shift;
                if (result > (1 << 53) or result < -(1 << 53)) return error.RangeError;
                try pushNumericResultWithCarrier(a, b, @floatFromInt(result), .int, ">>");
            },
            .cast_int => {
                const raw = try vmPop();
                if (vmod.decimalLogicalNumber(raw)) |n| {
                    if (!std.math.isFinite(n) or
                        n < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                        n >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.RangeError;
                    const t = @trunc(n);
                    const as_i64: i64 = @intFromFloat(t);
                    if (@as(f64, @floatFromInt(as_i64)) != t) return error.RangeError;
                    try vmPush(.{ .int = t });
                    continue;
                }
                const v = vms.unboxNamed(raw);
                switch (v) {
                    .int => |n| try vmPush(.{ .int = n }),
                    .float => |n| {
                        if (!std.math.isFinite(n) or
                            n < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                            n >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.RangeError;
                        const t = @trunc(n);
                        const as_i64: i64 = @intFromFloat(t);
                        if (@as(f64, @floatFromInt(as_i64)) != t) return error.RangeError;
                        try vmPush(.{ .int = t });
                    },
                    .decimal => |d| try vmPush(.{ .int = @floatFromInt(d) }),
                    .rune => |r| try vmPush(.{ .int = @floatFromInt(r) }),
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
                    .int => |n| try vmPush(.{ .float = n }),
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
                    .int => |n| {
                        if (!std.math.isFinite(n)) return error.TypeError;
                        const t = @trunc(n);
                        if (t < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                            t >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                        try vmPush(.{ .decimal = @intFromFloat(t) });
                    },
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
                    .int => |n| try vmPush(.{ .boolean = n != 0.0 }),
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
                const out = try vmnative.nativeConvToString(v);
                _ = try vmPop();
                try vmPush(out);
            },
            .cast_rune => {
                const v = vms.unboxNamed(try vmPop());
                const r: u21 = switch (v) {
                    .rune => |rv| rv,
                    .int => |n| blk: {
                        const t = @trunc(n);
                        if (t != n or t < 0 or t > 0x10FFFF) return error.TypeError;
                        break :blk @intFromFloat(t);
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
                if (!ok) {
                    vms.setRuntimeErr("assert_type tag={d} failed for v={s}", .{tag, @tagName(v)});
                    return error.TypeError;
                }
            },
            .neg => {
                const v = try vmPeek(0);
                const n = vms.valueAsNumber(v) catch {
                    _ = try vmPop();
                    vms.setRuntimeErr("cannot negate {s}", .{runtimeTypeName(v)});
                    return error.TypeError;
                };
                if (v == .object and v.object.* == .named_value) {
                    const wrapped = try vmtyp.coerceNamedTypeResult(v.object.named_value.typ, if (v.object.named_value.typ.named_type.base == .float) .{ .float = -n } else .{ .int = -n });
                    try checkNamedTypePredicate(v.object.named_value.typ, wrapped.object.named_value.value);
                    _ = try vmPop();
                    try vmPush(wrapped);
                } else {
                    _ = try vmPop();
                    try vmPush(if (v == .float) .{ .float = -n } else .{ .int = -n });
                }
            },
            .not => {
                const v = try vmPop();
                try vmPush(.{ .boolean = !(try condAsBool(v, "'!' operand")) });
            },
            .eq => {
                const b = try vmPop();
                const a = try vmPop();
                try checkNamedValueCompatibility(a, b);
                const a_named = a == .object and a.object.* == .named_value;
                const b_named = b == .object and b.object.* == .named_value;
                const ea = if (a_named) a.object.named_value.value else a;
                const eb = if (b_named) b.object.named_value.value else b;
                try vmPush(.{ .boolean = Value.equals(ea, eb) });
            },
            .gt => {
                const b = try vmPop();
                const a = try vmPop();
                try checkNamedValueCompatibility(a, b);
                try checkComparableNumeric(a, b, ">");
                const an = try valueAsNumberForCompare(a, b);
                const bn = try valueAsNumberForCompare(b, a);
                if (!std.math.isFinite(an) or !std.math.isFinite(bn)) { vms.setRuntimeErr("cannot compare non-finite value", .{}); return error.TypeError; }
                try vmPush(.{ .boolean = an > bn });
            },
            .lt => {
                const b = try vmPop();
                const a = try vmPop();
                try checkNamedValueCompatibility(a, b);
                try checkComparableNumeric(a, b, "<");
                const an = try valueAsNumberForCompare(a, b);
                const bn = try valueAsNumberForCompare(b, a);
                if (!std.math.isFinite(an) or !std.math.isFinite(bn)) { vms.setRuntimeErr("cannot compare non-finite value", .{}); return error.TypeError; }
                try vmPush(.{ .boolean = an < bn });
            },

            // Fused const+op: reads rhs constant, pops lhs from stack.
            .const_eq => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                try checkNamedValueCompatibility(a, k);
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                const ea = if (a_named) a.object.named_value.value else a;
                const ek = if (k_named) k.object.named_value.value else k;
                try vmPush(.{ .boolean = Value.equals(ea, ek) });
            },
            .const_sub => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                const an = try valueAsNumberForOp(a, k, "-");
                const kn = try valueAsNumberForOp(k, a, "-");
                const tag = numericOpTag(a, k) catch |err| {
                    if (err == error.TypeError) setBinaryTypeError("-", a, k);
                    return err;
                };
                try pushNumericResultWithCarrier(a, k, an - kn, tag, "-");
            },

            // Triple-fused: get_local + constant + eq/sub.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo]
            // The skip byte (was const_eq/sub opcode) is always present in well-formed
            // bytecode; advance IP directly to avoid the bounds check in vmByte().
            .get_local_const_eq => {
                const slot = try vmByte();
                vmState().ip += 1; // skip the embedded const_eq opcode byte
                const k = try chunk.constAt(try vmShort());
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                try checkNamedValueCompatibility(a, k);
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                const ea = if (a_named) a.object.named_value.value else a;
                const ek = if (k_named) k.object.named_value.value else k;
                try vmPush(.{ .boolean = Value.equals(ea, ek) });
            },
            .get_local_const_sub => {
                const slot = try vmByte();
                vmState().ip += 1; // skip the embedded const_sub opcode byte
                const k = try chunk.constAt(try vmShort());
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                const an = try valueAsNumberForOp(a, k, "-");
                const kn = try valueAsNumberForOp(k, a, "-");
                const tag = numericOpTag(a, k) catch |err| {
                    if (err == error.TypeError) setBinaryTypeError("-", a, k);
                    return err;
                };
                try pushNumericResultWithCarrier(a, k, an - kn, tag, "-");
            },
            .get_local_const_add => {
                const slot = try vmByte();
                vmState().ip += 1; // skip the embedded const_add opcode byte
                const k = try chunk.constAt(try vmShort());
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                if (isStringValueOrNamedString(a) and isStringValueOrNamedString(k)) {
                    const sa = try vms.asStringValue(a);
                    const sk = try vms.asStringValue(k);
                    const a_is_gc_obj = (a == .object);
                    const k_is_gc_obj = (k == .object);
                    if (a_is_gc_obj) try pushTempRoot(a);
                    if (k_is_gc_obj) try pushTempRoot(k);
                    defer {
                        if (k_is_gc_obj) popTempRoot();
                        if (a_is_gc_obj) popTempRoot();
                    }
                    const result = try concatDynString(sa, sk);
                    try pushStringResultWithCarrier(a, k, result);
                } else {
                    const an = try valueAsNumberForOp(a, k, "+");
                    const kn = try valueAsNumberForOp(k, a, "+");
                    const tag = numericOpTag(a, k) catch |err| {
                        if (err == error.TypeError) setBinaryTypeError("+", a, k);
                        return err;
                    };
                    try pushNumericResultWithCarrier(a, k, an + kn, tag, "+");
                }
            },
            .get_local_const_lt => {
                const slot = try vmByte();
                vmState().ip += 1; // skip the embedded const_lt opcode byte
                const k = try chunk.constAt(try vmShort());
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                try checkNamedValueCompatibility(a, k);
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                const an = try vms.valueAsNumber(if (a_named) a.object.named_value.value else a);
                const kn = try vms.valueAsNumber(if (k_named) k.object.named_value.value else k);
                if (!std.math.isFinite(an) or !std.math.isFinite(kn)) { vms.setRuntimeErr("cannot compare non-finite value", .{}); return error.TypeError; }
                try vmPush(.{ .boolean = an < kn });
            },

            // Quad-fused: get_local + constant + eq + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][jmp_b3][jmp_b2][jmp_b1][jmp_b0]
            // Reads offset first (advancing IP past the full instruction), then branches.
            .get_local_const_eq_jif_pop => {
                const slot = try vmByte();
                vmState().ip += 1; // skip
                const k = try chunk.constAt(try vmShort());
                const off = try vms.vmInt();
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                try checkNamedValueCompatibility(a, k);
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                const ea = if (a_named) a.object.named_value.value else a;
                const ek = if (k_named) k.object.named_value.value else k;
                if (!Value.equals(ea, ek)) vmState().ip += off;
            },

            // Quad-fused: get_local + const_lt + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][jmp_b3][jmp_b2][jmp_b1][jmp_b0]
            .get_local_const_lt_jif_pop => {
                const slot = try vmByte();
                vmState().ip += 1; // skip embedded const_lt opcode byte
                const k = try chunk.constAt(try vmShort());
                const off = try vms.vmInt();
                const base = if (vmState().frame_top > 0) vmState().frames[vmState().frame_top - 1].base else 0;
                if (base + slot >= vmState().stack.len) return error.StackOverflow;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                try checkNamedValueCompatibility(a, k);
                try checkComparableNumeric(a, k, "<");
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                const an = try valueAsNumberForCompare(if (a_named) a.object.named_value.value else a, k);
                const kn = try valueAsNumberForCompare(if (k_named) k.object.named_value.value else k, a);
                if (!std.math.isFinite(an) or !std.math.isFinite(kn)) { vms.setRuntimeErr("cannot compare non-finite value", .{}); return error.TypeError; }
                if (!(an < kn)) vmState().ip += off;
            },

            // Fused: get_local + get_field. 8-byte layout:
            // [op][slot][skip=get_field_byte][name_hi][name_lo][ic_type_hi][ic_type_lo][ic_fidx]
            .get_local_get_field => {
                try opGetLocalGetField();
            },

            .const_add => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                if (isStringValueOrNamedString(a) and isStringValueOrNamedString(k)) {
                    const sa = try vms.asStringValue(a);
                    const sk = try vms.asStringValue(k);
                    // Protect GC-backed operands so concatDynString can allocate
                    // without the source bytes being freed and reused.
                    const a_is_gc_obj = (a == .object);
                    const k_is_gc_obj = (k == .object);
                    if (a_is_gc_obj) try pushTempRoot(a);
                    if (k_is_gc_obj) try pushTempRoot(k);
                    defer {
                        if (k_is_gc_obj) popTempRoot();
                        if (a_is_gc_obj) popTempRoot();
                    }
                    const result = try concatDynString(sa, sk);
                    vmperf.countStringConcat(sa.len + sk.len);
                    try pushStringResultWithCarrier(a, k, result);
                } else {
                    const an = try valueAsNumberForOp(a, k, "+");
                    const kn = try valueAsNumberForOp(k, a, "+");
                    const tag = numericOpTag(a, k) catch |err| {
                        if (err == error.TypeError) setBinaryTypeError("+", a, k);
                        return err;
                    };
                    try pushNumericResultWithCarrier(a, k, an + kn, tag, "+");
                }
            },
            .const_lt => {
                const k = try chunk.constAt(try vmShort());
                const a = try vmPop();
                try checkNamedValueCompatibility(a, k);
                try checkComparableNumeric(a, k, "<");
                const an = try valueAsNumberForCompare(a, k);
                const kn = try valueAsNumberForCompare(k, a);
                if (!std.math.isFinite(an) or !std.math.isFinite(kn)) { vms.setRuntimeErr("cannot compare non-finite value", .{}); return error.TypeError; }
                try vmPush(.{ .boolean = an < kn });
            },

            .build_array => {
                const count = try vmByte();
                const obj = try vmAllocObject();
                obj.* = .{ .array = &[_]Value{} }; // must init before temp root: GC may run during slice alloc
                try pushTempRoot(.{ .object = obj });
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
                const obj = try vmAllocObject();
                obj.* = .{ .map = &[_]MapEntry{} }; // must init before temp root: GC may run during slice alloc
                try pushTempRoot(.{ .object = obj });
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
            .build_tuple => {
                const count = try vmByte();
                const obj = try vmAllocObject();
                obj.* = .{ .array = &[_]Value{} }; // must init before temp root: GC may run during slice alloc
                try pushTempRoot(.{ .object = obj });
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

                    const obj = try vmAllocObject();
                    try pushTempRoot(.{ .object = obj });
                    defer popTempRoot();
                    obj.* = .{ .array = &[_]Value{} };

                    const base = vmState().stack_top - typ_stack_dist;
                    const shared_vals = try vmAllocManagedSlice(Value, shared_count);
                    const arm_vals = if (arm_field_count > 0) try vmAllocManagedSlice(Value, arm_field_count) else @as([]Value, &.{});

                    if (arm.has_payload and arm_field_count == 0) {
                        // Single-payload arm with shared fields
                        var shared_seen: [255]bool = [_]bool{false} ** 255;
                        var payload_val: Value = .null;
                        var payload_seen = false;
                        var ci: usize = 0;
                        while (ci < count) : (ci += 1) {
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
                        var si: usize = 0;
                        while (si < shared_count) : (si += 1) {
                            if (!shared_seen[si]) { vms.setRuntimeErr("missing required field '{s}' in variant literal", .{vt.shared_fields[si].name}); return error.MissingStructField; }
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
                        var ci: usize = 0;
                        while (ci < count) : (ci += 1) {
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
                        var fi: usize = 0;
                        while (fi < total_fields) : (fi += 1) {
                            if (!seen[fi]) {
                                const fname = if (fi < shared_count) vt.shared_fields[fi].name else arm.fields[fi - shared_count].name;
                                vms.setRuntimeErr("missing required field '{s}' in variant literal", .{fname});
                                return error.MissingStructField;
                            }
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
                    const obj = try vmAllocObject();
                    try pushTempRoot(.{ .object = obj });
                    defer popTempRoot();
                    obj.* = .{ .array = &[_]Value{} };

                    const base = vmState().stack_top - typ_stack_dist;
                    var seen: [255]bool = [_]bool{false} ** 255;
                    var ci: usize = 0;
                    while (ci < count) : (ci += 1) {
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
                        inst_fields[idx] = .{ .key = .{ .string = st.fields[idx].name }, .value = val };
                    }

                    var mi: usize = 0;
                    while (mi < st.fields.len) : (mi += 1) {
                        if (!seen[mi]) { vms.setRuntimeErr("missing required field '{s}' in struct literal", .{st.fields[mi].name}); return error.MissingStructField; }
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
                        const rune_len = try vmstr.utf8RuneCountCached(s);
                        const start_r: usize = if (has_start) try vms.vmSliceIndex(start_v, rune_len) else 0;
                        const end_r: usize = if (has_end) try vms.vmSliceIndex(end_v, rune_len) else rune_len;
                        if (start_r > end_r) return error.IndexOutOfBounds;
                        const start_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, start_r);
                        const end_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, end_r);
                        try vmPush(.{ .string = s[start_b..end_b] });
                    },
                    .object => |obj| switch (obj.*) {
                        .dyn_string => |s| {
                            const rune_len = try vmstr.utf8RuneCountCached(s);
                            const start_r: usize = if (has_start) try vms.vmSliceIndex(start_v, rune_len) else 0;
                            const end_r: usize = if (has_end) try vms.vmSliceIndex(end_v, rune_len) else rune_len;
                            if (start_r > end_r) return error.IndexOutOfBounds;
                            const start_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, start_r);
                            const end_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, end_r);
                            try vmPush(try makeDynString(s[start_b..end_b]));
                        },
                        .array, .array_managed => {
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
                var i: usize = 0;
                while (i < proto.capture_slots.len) : (i += 1) {
                    const enc = proto.capture_slots[i];
                    const is_upvalue = (enc & 0x80) != 0;
                    const idx = enc & 0x7f;
                    if (is_upvalue) {
                        const pcl = frame.closure orelse return error.TypeError;
                        if (pcl.* != .closure) return error.TypeError;
                        if (idx >= pcl.closure.upvalues.len) return error.TypeError;
                        ups[i] = pcl.closure.upvalues[idx];
                    } else {
                        const abs = frame.base + idx;
                        if (abs >= vmState().stack.len) return error.StackOverflow;
                        const cur = vmState().stack[abs];
                        if (cur == .object and cur.object.* == .cell) {
                            ups[i] = cur.object;
                            continue;
                        }
                        const cell = try vmAllocObject();
                        cell.* = .{ .cell = .{ .value = cur } };
                        vmState().stack[abs] = .{ .object = cell };
                        ups[i] = cell;
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
                const jip = vmState().ip;
                if (jip + 5 <= chunk.codeLen() and
                    chunk.codeByteAt(jip) == @intFromEnum(Op.get_global))
                {
                    const ic_slot: u16 = @intCast(
                        (@as(usize, chunk.codeByteAt(jip + 3)) << 8) | chunk.codeByteAt(jip + 4),
                    );
                    if (ic_slot != 0xffff) {
                        vmState().ip += 5;
                        try vmPush(globals.getAt(ic_slot));
                    }
                }
            },

            // Fused set_global + loop back-edge.
            // Bytecode: [op][name_hi][name_lo][ic_hi][ic_lo][off_b3][off_b2][off_b1][off_b0]
            // IC layout and patch offsets are identical to set_global.
            .set_global_loop => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                const val = try vmPop();
                if (ic_slot != 0xFFFF) {
                    globals.setAt(ic_slot, val);
                } else {
                    const name = (try chunk.constAt(name_idx)).string;
                    const slot = globals.findSlot(name) orelse return error.NotDefined;
                    chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
                    globals.setAt(slot, val);
                }
                const off = try vms.vmInt();
                if (off > vmState().ip) return error.BytecodeOutOfBounds;
                vmState().ip -= off;
                // Same inline get_global as loop: skip one dispatch if warm.
                const jip = vmState().ip;
                if (jip + 5 <= chunk.codeLen() and
                    chunk.codeByteAt(jip) == @intFromEnum(Op.get_global))
                {
                    const ic_slot2: u16 = @intCast(
                        (@as(usize, chunk.codeByteAt(jip + 3)) << 8) | chunk.codeByteAt(jip + 4),
                    );
                    if (ic_slot2 != 0xffff) {
                        vmState().ip += 5;
                        try vmPush(globals.getAt(ic_slot2));
                    }
                }
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

            .call => {
                const argc = try vmByte();
                if (try tryTailCall(argc)) continue;
                try performCall(argc);
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
                const arm = (try vms.vmConst()).string;
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
                    const map_obj = try vmAllocObject();
                    map_obj.* = .{ .map = &[_]MapEntry{} };
                    try pushTempRoot(.{ .object = map_obj });
                    defer popTempRoot();
                    const items = try vmAllocManagedSlice(MapEntry, arm.fields.len);
                    var fi: usize = 0;
                    while (fi < arm.fields.len) : (fi += 1) {
                        const fv = vv.arm_fields[fi];
                        items[fi] = .{ .key = .{ .string = arm.fields[fi].name }, .value = fv };
                    }
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
                const arr_obj = try vmAllocObject();
                arr_obj.* = .{ .array = &[_]Value{} }; // safe tag before GC can run
                try pushTempRoot(.{ .object = arr_obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, total);
                var di: usize = 0;
                while (di < total) : (di += 1) items[di] = vmState().stack[start + di];
                arr_obj.* = .{ .array_managed = items[0..total] };
                vmState().defer_stack[vmState().defer_top] = .{ .object = arr_obj };
                vmState().defer_top += 1;
                vmState().stack_top -= total;
            },
            .defer_invoke_method => try opDeferInvokeMethod(),
            .ret => {
                vmperf.breakOpChain();
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const retval = try vmPop();
                const fi = vmState().frame_top - 1;
                const frame = &vmState().frames[fi];
                if (vmState().defer_top == frame.defer_base and !frame.has_typed_returns) {
                    vmState().frame_top = fi;
                    vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
                    vmState().ip = frame.ret_ip;
                    try vmPush(retval);
                    if (vmState().call_depth_target) |d| {
                        if (vmState().frame_top == d) return;
                    }
                    continue;
                }
                if (try retSlowPath(retval)) return;
            },

            // Fused constant+ret: reads idx, pushes constant, returns.
            // Emitted when `constant k` immediately precedes `ret`.
            .ret_const => {
                vmperf.breakOpChain();
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const k = try chunk.constAt(try vmShort());
                const fi = vmState().frame_top - 1;
                const frame = &vmState().frames[fi];
                if (vmState().defer_top == frame.defer_base and !frame.has_typed_returns) {
                    vmState().frame_top = fi;
                    vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
                    vmState().ip = frame.ret_ip;
                    try vmPush(k);
                    if (vmState().call_depth_target) |d| {
                        if (vmState().frame_top == d) return;
                    }
                    continue;
                }
                if (try retSlowPath(k)) return;
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
    var di: usize = 0;
    while (di < arr.len) : (di += 1) try vmPush(arr[di]);
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
        vms.setRuntimeErr("{s}", .{msg});
        vmState().panic_value = .{ .error_value = msg };
        vmState().pending_panic_message = null;
    } else {
        vmState().panic_value = .{ .error_value = @errorName(orig_err) };
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
                    vmState().panic_value = .{ .error_value = @errorName(new_err) };
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
                    vmPush(if (raw == .object and raw.object.* == .cell) raw.object.cell.value else raw) catch {};
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
                    var ri: u8 = 0;
                    while (ri < named_ret) : (ri += 1) {
                        const raw = vmState().stack[rec_base + rec_arity + ri];
                        items[ri] = if (raw == .object and raw.object.* == .cell) raw.object.cell.value else raw;
                    }
                } else {
                    var ri: u8 = 0;
                    while (ri < n) : (ri += 1) items[ri] = .null;
                }
                tup_obj.* = .{ .array_managed = items };
                try vmPush(.{ .object = tup_obj });
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
    runInner() catch |err| return runPanicUnwind(err);
}

pub fn makeString(s: []const u8) !Value {
    return vmgc.makeDynString(s);
}

pub fn callGlobal(name: []const u8, args: []const Value) !Value {
    const fn_val = globals.get(name) orelse return error.NotDefined;
    if (fn_val != .object) return error.NotAFunction;
    const obj = fn_val.object;
    if (obj.* != .function and obj.* != .closure) return error.NotAFunction;

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

pub fn callFunction(func_val: Value, args: []const Value) anyerror!Value {
    if (args.len > 255) return error.ArityMismatch;
    try vmPush(func_val);
    for (args) |a| try vmPush(a);
    const depth_before = vmState().frame_top;
    try performCall(@intCast(args.len));
    const prev_target = vmState().call_depth_target;
    vmState().call_depth_target = depth_before;
    defer vmState().call_depth_target = prev_target;
    try run();
    return try vmPop();
}
