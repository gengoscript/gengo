const std = @import("std");
// vm.zig imports this file (vmtyp); this reverse edge only reaches
// checkNamedTypePredicateChain, a leaf pub fn, so it does not cycle at
// comptime — verified by building successfully.
const vm_mod = @import("vm.zig");
const common = @import("common.zig");
const globals = @import("globals.zig");
const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const heap = @import("../runtime/heap.zig");
const vmod = @import("value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const FieldTypeAlt = @import("value.zig").FieldTypeAlt;
const FieldTypeSpec = @import("value.zig").FieldTypeSpec;
const StructFieldSpec = @import("value.zig").StructFieldSpec;
const FuncObj = @import("value.zig").FuncObj;

// findFieldIndex/interfaceMethodMatches live in type_shapes.zig, not here:
// they're the only VMContext-free functions this file had, and compiler.zig
// needs interfaceMethodMatches without pulling in vm_mod (see that file's
// header comment). Re-exported so vm.zig's many existing vmtyp.findFieldIndex
// call sites don't need to change.
const type_shapes = @import("type_shapes.zig");
pub const findFieldIndex = type_shapes.findFieldIndex;
pub const interfaceMethodMatches = type_shapes.interfaceMethodMatches;

// 2^63 as f64 (exact — a power of two): the i64 range boundary used to reject
// an out-of-range decimal before the f64->i64 cast. A named constant instead
// of std.math.pow(f64, 2.0, 63.0), which otherwise runs on every decimal
// construction (see decimalScaleFactor's comment in value.zig for the sibling
// fix, both found while profiling the decimal benchmark).
const i64_f64_bound: f64 = 9223372036854775808.0;

pub fn namedBaseName(base: @import("value.zig").NamedTypeBase) []const u8 {
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

pub fn runtimeTypeName(v: Value) []const u8 {
    if (v == .inline_variant) return vmod.objectAtIdx(v.inline_variant.typ_idx).variant_type.name;
    return switch (v) {
        .int => "int",
        .float => "float",
        .decimal => "decimal",
        .rune => "rune",
        .boolean => "bool",
        .string => "string",
        .error_value => "error",
        .null => "null",
        .inline_variant => unreachable,
        .actor_ref => "actor",
        .object => |obj| switch (obj.*) {
            .named_value => obj.named_value.typ.named_type.name,
            .enum_value => obj.enum_value.typ.enum_type.name,
            .variant_value => obj.variant_value.typ.variant_type.name,
            .named_error_value => |nev| nev.typ.named_error_type.name,
            .dyn_string, .string_view => "string",
            .array, .array_managed, .array_view, .array_capacity => "array",
            .map, .map_managed, .map_hashed => "map",
            .bigint => "bigint",
            else => "object",
        },
    };
}

// Set pending_panic_message to the current runtime_err_buf slice so that
// core.recover() returns the human-readable message instead of just the
// Zig error-name string.  runPanicUnwind skips the self-@memcpy when it
// detects that pending_panic_message already points into runtime_err_buf.
inline fn announcePanicMsg(ctx: VMContext) void {
    ctx.vs.pending_panic_message = ctx.vs.runtimeErrMsg();
}

pub fn setNamedRangeError(ctx: VMContext, typ_obj: *Object, value: f64) void {
    const nt = typ_obj.named_type;
    // value/nt.min/nt.max can be arbitrarily large (a user-declared range
    // literal, or a value that overflowed one) — must not @intFromFloat them
    // unchecked here, or the error-reporting path itself becomes the crash.
    int_fmt: {
        if (nt.base != .int and nt.base != .rune) break :int_fmt;
        const iv = vm_mod.floatToIntSafe(value) catch break :int_fmt;
        const imn = vm_mod.floatToIntSafe(nt.min) catch break :int_fmt;
        const imx = vm_mod.floatToIntSafe(nt.max) catch break :int_fmt;
        ctx.vs.setRuntimeErr("{s}: {d} is outside {d}..{d}", .{ nt.name, iv, imn, imx });
        announcePanicMsg(ctx);
        return;
    }
    ctx.vs.setRuntimeErr("{s}: {d} is outside {d}..{d}", .{ nt.name, value, nt.min, nt.max });
    announcePanicMsg(ctx);
}

// value can be arbitrarily large (unranged named int/decimal, or a
// user-declared range literal wider than i64) — this covers the cases
// setNamedRangeError can't, i.e. no meaningful min..max to report.
fn setNamedConversionError(ctx: VMContext, nt_name: []const u8, base_name: []const u8, value: f64) void {
    ctx.vs.setRuntimeErr("{s}: {d} cannot be represented as {s}", .{ nt_name, value, base_name });
    announcePanicMsg(ctx);
}

fn floatToRuneSafe(n: f64) !u21 {
    if (!std.math.isFinite(n) or n < 0 or n > 0x10FFFF) return error.RangeError;
    return @intFromFloat(@trunc(n));
}

// Resolve and cache the parent enum type pointer for enum subtypes.
pub fn resolveEnumParent(ctx: VMContext, obj: *Object) ?*Object {
    if (obj.* != .enum_type) return null;
    if (obj.enum_type.parent) |cached| return cached;
    const pname = obj.enum_type.parent_name orelse return null;
    const pval = ctx.gs.get(pname) orelse return null;
    if (!(pval == .object and pval.object.* == .enum_type)) return null;
    obj.enum_type.parent = pval.object;
    return pval.object;
}

// Resolve and cache the parent type pointer, avoiding repeated globals lookups.
pub fn resolveParentType(ctx: VMContext, obj: *Object) ?*Object {
    if (obj.* != .named_type) return null;
    if (obj.named_type.parent_obj) |cached| return cached;
    const pname = obj.named_type.parent_name orelse return null;
    const pval = ctx.gs.get(pname) orelse return null;
    if (!(pval == .object and pval.object.* == .named_type)) return null;
    obj.named_type.parent_obj = pval.object;
    return pval.object;
}

pub fn namedTypeIsOrExtends(ctx: VMContext, typ_obj: *Object, target_name: []const u8) bool {
    if (typ_obj.* != .named_type) return false;
    var cur: *Object = typ_obj;
    while (true) {
        if (common.streq(cur.named_type.qualified_name, target_name)) return true;
        cur = resolveParentType(ctx, cur) orelse return false;
    }
}

pub fn matchesTypeAlt(ctx: VMContext, v: Value, alt: *const FieldTypeAlt) bool {
    return switch (alt.typ) {
        .any => true,
        .null_t => v == .null,
        .int => v == .int or v == .rune,
        .float => v == .float or v == .rune,
        .decimal_t => v == .decimal,
        .rune_t => v == .rune,
        .boolean => v == .boolean,
        .string => vms.isStringValue(v),
        .error_t => v == .error_value or (v == .object and v.object.* == .named_error_value),
        .actor_ref_t => v == .actor_ref,
        .array => blk: {
            // Unwrap a named-array value first: `var xs []int = [...]` (and
            // the `[]int{...}` composite-literal sugar) both construct their
            // result via constructNamedType's .array_t case, which always
            // wraps the plain array in a .named_value carrying the
            // (possibly anonymous) array named_type — the elements were
            // already validated once at construction time, but the wrapper
            // itself is opaque to isArrayObject. Without this, passing such
            // a value to a plain `[]T`-typed function parameter always
            // failed with a confusingly identical-looking "expected []T,
            // got []T" (both sides render the same runtime type name, since
            // the type IS []T — the check just never looked inside the
            // wrapper). Checking elements structurally against the
            // unwrapped array is correct regardless of what named-type
            // wrapper (if any) produced it, matching how []T parameters
            // are meant to accept any array with T-typed elements.
            const av = v.namedInner() orelse v;
            if (!(av == .object and vms.isArrayObject(av.object))) break :blk false;
            if (alt.elem_spec) |es| {
                const items = vms.asArraySlice(av.object) catch unreachable;
                for (items) |item| {
                    if (!matchesTypeSpec(ctx, item, es)) break :blk false;
                }
            }
            break :blk true;
        },
        .map => blk: {
            // Same named_value-unwrapping fix as .array above, and for the
            // same reason: `var m [K]V = {...}` also wraps via
            // constructNamedType's .map_t case.
            const mv = v.namedInner() orelse v;
            if (!(mv == .object and vms.isMapObject(mv.object))) break :blk false;
            if (alt.key_spec) |ks| {
                const entries = vms.asMapSlice(mv.object) catch unreachable;
                for (entries) |e| {
                    if (!matchesTypeSpec(ctx, e.key, ks)) break :blk false;
                    if (alt.val_spec) |vs| {
                        if (!matchesTypeSpec(ctx, e.value, vs)) break :blk false;
                    }
                }
            }
            break :blk true;
        },
        .struct_t => blk: {
            const qname = if (v == .object and v.object.* == .struct_instance)
                v.object.struct_instance.typ.struct_type.qualified_name
            else if (v == .object and v.object.* == .small_struct_instance)
                v.object.small_struct_instance.typ.struct_type.qualified_name
            else
                break :blk false;
            // Exact match, or deferred generic: accept any instantiation of the base type.
            if (common.streq(qname, alt.struct_name)) break :blk true;
            if (alt.generic_args.len > 0) {
                if (std.mem.startsWith(u8, qname, alt.struct_name) and
                    qname.len > alt.struct_name.len and qname[alt.struct_name.len] == '[') break :blk true;
            }
            break :blk false;
        },
        .interface_t => matchesInterfaceType(ctx, v, alt.interface_name),
        .named_t => named_t_blk: {
            if (v != .object) {
                const nt_val = ctx.gs.get(alt.named_name) orelse break :named_t_blk false;
                if (nt_val != .object or nt_val.object.* != .named_type) break :named_t_blk false;
                break :named_t_blk bareScalarMatchesNamedBase(nt_val.object.named_type.base, v);
            }
            break :named_t_blk switch (v.object.*) {
                .named_value => namedTypeIsOrExtends(ctx, v.object.named_value.typ, alt.named_name),
                .enum_value => blk: {
                    if (common.streq(v.object.enum_value.typ.enum_type.qualified_name, alt.named_name)) break :blk true;
                    const sub_val = ctx.gs.get(alt.named_name) orelse break :blk false;
                    if (!(sub_val == .object and sub_val.object.* == .enum_type)) break :blk false;
                    if (sub_val.object.enum_type.parent_name == null) break :blk false;
                    const parent_obj = resolveEnumParent(ctx, sub_val.object) orelse break :blk false;
                    if (parent_obj != v.object.enum_value.typ) break :blk false;
                    for (sub_val.object.enum_type.members) |m| {
                        if (common.streq(m, v.object.enum_value.name)) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
        },
        .variant_t => blk: {
            const ref = v.asVariant() orelse break :blk false;
            const qname = ref.typ.variant_type.qualified_name;
            if (common.streq(qname, alt.named_name)) break :blk true;
            // Deferred generic: accept any instantiation of the base variant type.
            if (alt.generic_args.len > 0) {
                if (std.mem.startsWith(u8, qname, alt.named_name) and
                    qname.len > alt.named_name.len and qname[alt.named_name.len] == '[') break :blk true;
            }
            break :blk false;
        },
        .func_t => blk: {
            if (!(v == .object and (v.object.* == .function or v.object.* == .closure))) break :blk false;
            if (alt.func_params) |ps| {
                const arity: usize = switch (v.object.*) {
                    .function => |f| f.arity,
                    .closure => |cl| cl.func.function.arity,
                    else => break :blk false,
                };
                if (arity != ps.len) break :blk false;
            }
            break :blk true;
        },
        // type_param in a compiled generic function body — erased to any at runtime.
        .type_param => true,
    };
}

pub fn matchesFieldType(ctx: VMContext, v: Value, spec: StructFieldSpec) bool {
    return matchesTypeSpec(ctx, v, spec.typ);
}

pub fn matchesTypeSpec(ctx: VMContext, v: Value, spec: FieldTypeSpec) bool {
    for (spec.alts) |*alt| {
        if (matchesTypeAlt(ctx, v, alt)) return true;
    }
    return false;
}

fn fieldTypeAltStr(buf: *[128]u8, alt: FieldTypeAlt) []const u8 {
    return switch (alt.typ) {
        .any => "any",
        .null_t => "null",
        .int => "int",
        .float => "float",
        .decimal_t => "decimal",
        .rune_t => "rune",
        .boolean => "bool",
        .string => "string",
        .error_t => "error",
        .actor_ref_t => "actor",
        .array => if (alt.elem_spec) |es| blk: {
            var inner_buf: [128]u8 = undefined;
            const inner = fieldTypeSpecStr(&inner_buf, es);
            break :blk std.fmt.bufPrint(buf[0..], "[]{s}", .{inner}) catch "array";
        } else "array",
        .map => if (alt.key_spec) |ks| blk: {
            var key_buf: [128]u8 = undefined;
            const keystr = fieldTypeSpecStr(&key_buf, ks);
            if (alt.val_spec) |vs| {
                var val_buf: [128]u8 = undefined;
                const valstr = fieldTypeSpecStr(&val_buf, vs);
                break :blk std.fmt.bufPrint(buf[0..], "map[{s}]{s}", .{ keystr, valstr }) catch "map";
            }
            break :blk std.fmt.bufPrint(buf[0..], "map[{s}]", .{keystr}) catch "map";
        } else "map",
        .struct_t => alt.struct_name,
        .interface_t => alt.interface_name,
        .named_t => alt.named_name,
        .variant_t => alt.named_name,
        .func_t => "func",
        .type_param => alt.param_name,
    };
}

fn fieldTypeSpecStr(buf: *[128]u8, spec: FieldTypeSpec) []const u8 {
    return fieldTypeAltStr(buf, spec.alts[0]);
}

pub fn matchesInterfaceType(ctx: VMContext, v: Value, iname: []const u8) bool {
    const tname = if (v == .inline_variant)
        vmod.objectAtIdx(v.inline_variant.typ_idx).variant_type.qualified_name
    else switch (v) {
        .object => |obj| switch (obj.*) {
            .struct_instance => obj.struct_instance.typ.struct_type.qualified_name,
            .small_struct_instance => obj.small_struct_instance.typ.struct_type.qualified_name,
            .named_value => obj.named_value.typ.named_type.qualified_name,
            .enum_value => obj.enum_value.typ.enum_type.qualified_name,
            .variant_value => obj.variant_value.typ.variant_type.qualified_name,
            else => return false,
        },
        else => return false,
    };
    const iv = ctx.gs.get(iname) orelse return false;
    if (!(iv == .object and iv.object.* == .interface_type)) return false;
    const it = iv.object.interface_type;
    for (it.methods) |m| {
        const total = tname.len + 1 + m.name.len;
        if (total > 512) return false;
        var key_buf: [512]u8 = undefined;
        @memcpy(key_buf[0..tname.len], tname);
        key_buf[tname.len] = '.';
        @memcpy(key_buf[tname.len + 1 .. total], m.name);
        const fnv = ctx.gs.get(key_buf[0..total]) orelse return false;
        if (!(fnv == .object)) return false;
        switch (fnv.object.*) {
            .function, .closure => {
                const f: FuncObj = switch (fnv.object.*) {
                    .function => |ff| ff,
                    .closure => |cl| cl.func.function,
                    else => unreachable,
                };
                if (!interfaceMethodMatches(m, f)) return false;
            },
            .native_function => |nf| {
                // Native (cap:/std) methods: arity check only.
                // Native arity includes the receiver, interface arity does not.
                if (nf.arity != m.arity + 1) return false;
            },
            else => return false,
        }
    }
    return true;
}

const VMContext = vms.VMContext;

pub fn makeNamedValue(ctx: VMContext, typ_obj: *Object, inner: Value) !Value {
    const obj = try vmgc.vmAllocObject(ctx);
    obj.* = .{ .named_value = .{ .typ = typ_obj, .value = inner } };
    return .{ .object = obj };
}

pub fn variantConstruct(ctx: VMContext, typ: *Object, tag: []const u8, ordinal: usize, payload: Value) !Value {
    const pool_idx = ctx.hs.objectPoolIndex(typ);
    if (pool_idx <= 0x0FFF) {
        if (vmod.tryMakeInlineVariant(@intCast(pool_idx), ordinal, payload)) |iv| return iv;
    }
    const vv = try vmgc.vmAllocObject(ctx);
    vv.* = .{ .variant_value = .{ .typ = typ, .tag = tag, .ordinal = ordinal, .payload = payload } };
    return .{ .object = vv };
}

// `continuous` selects the wraparound convention:
//   - discrete (int):  domain is `span = (max - min) + 1` inclusive integer
//     steps, e.g. `cycle 0..23` has 24 distinct values and 24 wraps to 0.
//   - continuous (float/decimal): the endpoints are identified with each
//     other, e.g. `cycle 0.0..360.0` treats 360.0 as the same point as 0.0,
//     so `span = max - min` and the maximum itself wraps to the minimum.
fn wrapCycleValueWithError(ctx: VMContext, name: []const u8, min: f64, max: f64, n: f64, continuous: bool) !f64 {
    return wrapCycleValue(min, max, n, continuous) catch |err| {
        if (err == error.RangeError) {
            ctx.vs.setRuntimeErr("{s}: {d} is outside cyclic range {d}..{d}", .{ name, n, min, max });
        }
        return err;
    };
}

fn wrapCycleValue(min: f64, max: f64, n: f64, continuous: bool) !f64 {
    if (!std.math.isFinite(n)) return error.RangeError;
    if (!continuous) {
        const exact_int_limit: f64 = 9007199254740992.0;
        if (@trunc(min) == min and @trunc(max) == max and @trunc(n) == n and
            min >= -exact_int_limit and min <= exact_int_limit and
            max >= -exact_int_limit and max <= exact_int_limit and
            n >= -exact_int_limit and n <= exact_int_limit)
        {
            const imin: i64 = @intFromFloat(min);
            const imax: i64 = @intFromFloat(max);
            const inn: i64 = @intFromFloat(n);
            const sub = @subWithOverflow(imax, imin);
            if (sub[1] != 0) return error.RangeError;
            const add = @addWithOverflow(sub[0], 1);
            if (add[1] != 0) return error.RangeError;
            const ispan = add[0];
            if (ispan > 0) {
                const ioffset = @mod(inn - imin, ispan);
                return @floatFromInt(imin + ioffset);
            }
        }
    }
    const span = if (continuous) max - min else (max - min) + 1.0;
    if (span <= 0) return error.RangeError;
    if (!continuous and span == max - min) return error.RangeError;
    var offset = common.fmod(n - min, span);
    if (offset < 0) offset += span;
    const result = min + offset;
    if (result == min and offset != 0) return error.RangeError;
    return result;
}

// Saturate `n` to `min..max` instead of erroring or wrapping. Unlike
// wrapCycleValue, there's no discrete/continuous distinction to make — a
// clamped max is a valid value in both the int and float/decimal cases,
// matching plain 'range' semantics at the boundary, not 'cycle' semantics.
fn clampValue(min: f64, max: f64, n: f64) !f64 {
    if (!std.math.isFinite(n)) return error.RangeError;
    if (n < min) return min;
    if (n > max) return max;
    return n;
}

pub fn constructNamedType(ctx: VMContext, typ_obj: *Object, arg: Value) !Value {
    if (typ_obj.* != .named_type) return error.TypeError;
    const nt = typ_obj.named_type;

    // Unwrap an already-typed named value so that re-constructing a value
    // of the same named type works consistently across all bases
    // (like valueAsNumber does for numeric bases).
    const effective_arg = arg.namedInner() orelse arg;

    var base_v: Value = undefined;
    switch (nt.base) {
        .int => {
            const n = vms.valueAsNumber(effective_arg) catch |err| {
                if (err == error.TypeError) {
                    ctx.vs.setRuntimeErr("cannot construct {s} from {s}; convert to {s} first", .{ nt.name, runtimeTypeName(effective_arg), namedBaseName(nt.base) });
                    announcePanicMsg(ctx);
                }
                return err;
            };
            if (!std.math.isFinite(n)) {
                setNamedRangeError(ctx, typ_obj, n);
                return error.RangeError;
            }
            if (@trunc(n) != n) {
                ctx.vs.setRuntimeErr("cannot construct {s} from {s}; convert to {s} first", .{ nt.name, runtimeTypeName(effective_arg), namedBaseName(nt.base) });
                announcePanicMsg(ctx);
                return error.TypeError;
            }
            if (nt.has_range and (n < nt.min or n > nt.max)) {
                if (nt.is_cycle) {
                    const wrapped = try wrapCycleValueWithError(ctx, nt.name, nt.min, nt.max, n, false);
                    base_v = .{ .int = vm_mod.floatToIntSafe(wrapped) catch {
                        setNamedRangeError(ctx, typ_obj, wrapped);
                        return error.RangeError;
                    } };
                } else if (nt.is_clamp) {
                    const clamped = try clampValue(nt.min, nt.max, n);
                    base_v = .{ .int = vm_mod.floatToIntSafe(clamped) catch {
                        setNamedRangeError(ctx, typ_obj, clamped);
                        return error.RangeError;
                    } };
                } else {
                    setNamedRangeError(ctx, typ_obj, n);
                    return error.RangeError;
                }
            } else {
                base_v = .{ .int = vm_mod.floatToIntSafe(n) catch {
                    setNamedConversionError(ctx, nt.name, "int", n);
                    return error.RangeError;
                } };
            }
        },
        .float => {
            const n = vms.valueAsNumber(effective_arg) catch |err| {
                if (err == error.TypeError) {
                    ctx.vs.setRuntimeErr("cannot construct {s} from {s}; convert to {s} first", .{ nt.name, runtimeTypeName(effective_arg), namedBaseName(nt.base) });
                    announcePanicMsg(ctx);
                }
                return err;
            };
            if (!std.math.isFinite(n)) {
                setNamedRangeError(ctx, typ_obj, n);
                return error.RangeError;
            }
            // Continuous cycle: max is identified with min, so n == max must
            // also wrap (unlike a plain range, where max is a valid value).
            const out_of_bounds = if (nt.is_cycle) n < nt.min or n >= nt.max else n < nt.min or n > nt.max;
            if (nt.has_range and out_of_bounds) {
                if (nt.is_cycle) {
                    const wrapped = try wrapCycleValueWithError(ctx, nt.name, nt.min, nt.max, n, true);
                    base_v = .{ .float = wrapped };
                } else if (nt.is_clamp) {
                    const clamped = try clampValue(nt.min, nt.max, n);
                    base_v = .{ .float = clamped };
                } else {
                    setNamedRangeError(ctx, typ_obj, n);
                    return error.RangeError;
                }
            } else {
                base_v = .{ .float = n };
            }
        },
        .decimal => {
            const scale = nt.scale;
            const factor = vmod.decimalScaleFactor(scale);
            const scaled: i64 = switch (effective_arg) {
                .int => |n| blk: {
                    const raw = @round(@as(f64, @floatFromInt(n)) * factor);
                    if (!std.math.isFinite(raw)) return error.TypeError;
                    if (raw < -i64_f64_bound or raw >= i64_f64_bound) return error.TypeError;
                    break :blk @intFromFloat(raw);
                },
                .float => |n| blk: {
                    const raw = @round(n * factor);
                    if (!std.math.isFinite(raw)) return error.TypeError;
                    if (raw < -i64_f64_bound or raw >= i64_f64_bound) return error.TypeError;
                    break :blk @intFromFloat(raw);
                },
                .decimal => |d| d,
                else => return error.TypeError,
            };
            if (nt.has_range) {
                const fv = @as(f64, @floatFromInt(scaled)) / factor;
                // Continuous cycle: max is identified with min, so fv == max
                // must also wrap (unlike a plain range, where max is valid).
                const out_of_bounds = if (nt.is_cycle) fv < nt.min or fv >= nt.max else fv < nt.min or fv > nt.max;
                if (out_of_bounds) {
                    if (nt.is_cycle) {
                        base_v = .{ .decimal = try wrapDecimalCycle(ctx, nt, fv, factor) };
                    } else if (nt.is_clamp) {
                        const clamped = try clampValue(nt.min, nt.max, fv);
                        const raw = @round(clamped * factor);
                        if (!std.math.isFinite(raw) or raw < -i64_f64_bound or raw >= i64_f64_bound) return error.TypeError;
                        base_v = .{ .decimal = @intFromFloat(raw) };
                    } else {
                        setNamedRangeError(ctx, typ_obj, fv);
                        return error.RangeError;
                    }
                } else {
                    base_v = .{ .decimal = scaled };
                }
            } else {
                base_v = .{ .decimal = scaled };
            }
        },
        .rune => {
            const r: u21 = switch (effective_arg) {
                .rune => |rv| rv,
                .int => |n| blk: {
                    if (n < 0 or n > 0x10FFFF) return error.TypeError;
                    break :blk @intCast(n);
                },
                .float => |n| blk: {
                    if (!std.math.isFinite(n)) {
                        ctx.vs.setRuntimeErr("{s}: {d} is outside {d}..{d}", .{ nt.name, n, nt.min, nt.max });
                        announcePanicMsg(ctx);
                        return error.RangeError;
                    }
                    const t = @trunc(n);
                    if (t != n or t < 0 or t > 0x10FFFF) return error.TypeError;
                    break :blk @intFromFloat(t);
                },
                else => return error.TypeError,
            };
            const rf: f64 = @floatFromInt(r);
            if (nt.has_range and (rf < nt.min or rf > nt.max)) {
                if (nt.is_clamp) {
                    const clamped = try clampValue(nt.min, nt.max, rf);
                    base_v = .{ .rune = floatToRuneSafe(clamped) catch {
                        setNamedRangeError(ctx, typ_obj, clamped);
                        return error.RangeError;
                    } };
                } else {
                    setNamedRangeError(ctx, typ_obj, rf);
                    return error.RangeError;
                }
            } else {
                base_v = .{ .rune = r };
            }
        },
        .string => {
            if (!vms.isStringValue(effective_arg)) return error.TypeError;
            // For managed objects (dyn_string, string_view) use makeDynStringFromObj,
            // which re-derives the source bytes from the Object AFTER the internal
            // vmAllocManagedBytes call so any compaction cannot leave a stale slice.
            // Static .string values (immortal bytes, not GC-managed) are safe to pass
            // directly via makeDynString.
            const ds = switch (effective_arg) {
                .object => |src_obj| try vmgc.makeDynStringFromObj(ctx, src_obj),
                else => try vmgc.makeDynString(ctx, try vms.asStringValue(effective_arg)),
            };
            try ctx.vs.pushTempRoot(ds);
            defer ctx.vs.popTempRoot();
            return makeNamedValue(ctx, typ_obj, ds);
        },
        .bool => {
            if (effective_arg != .boolean) return error.TypeError;
            base_v = effective_arg;
        },
        .array_t => {
            if (!(effective_arg == .object and vms.isArrayObject(effective_arg.object))) return error.TypeError;
            if (nt.elem_spec) |es| {
                for (try vms.asArraySlice(effective_arg.object)) |item| {
                    if (!matchesTypeSpec(ctx, item, es)) return error.TypeError;
                }
            }
            return makeNamedValue(ctx, typ_obj, effective_arg);
        },
        .map_t => {
            if (!(effective_arg == .object and vms.isMapObject(effective_arg.object))) return error.TypeError;
            if (nt.key_spec) |ks| {
                for (try vms.asMapSlice(effective_arg.object)) |e| {
                    if (!matchesTypeSpec(ctx, e.key, ks)) return error.TypeError;
                    if (nt.val_spec) |vs| {
                        if (!matchesTypeSpec(ctx, e.value, vs)) return error.TypeError;
                    }
                }
            }
            return makeNamedValue(ctx, typ_obj, effective_arg);
        },
        .enum_t => return error.TypeError,
    }
    // Scalar named types (int, float, rune, bool) are erased: return the bare value.
    // Decimal stays boxed because arithmetic needs the scale from the typ carrier.
    return if (nt.base == .decimal) makeNamedValue(ctx, typ_obj, base_v) else base_v;
}

// Wraps an out-of-range decimal value (given as its unscaled real value `fv`)
// into the named type's cyclic domain and rescales it back to the fixed-point
// integer representation.
fn wrapDecimalCycle(ctx: VMContext, nt: @import("value.zig").NamedTypeObj, fv: f64, factor: f64) !i64 {
    const wrapped = try wrapCycleValueWithError(ctx, nt.name, nt.min, nt.max, fv, true);
    const raw = @round(wrapped * factor);
    if (!std.math.isFinite(raw) or raw < -i64_f64_bound or raw >= i64_f64_bound) return error.TypeError;
    return @intFromFloat(raw);
}

pub fn coerceNamedTypeResult(ctx: VMContext, typ_obj: *Object, arg: Value) !Value {
    if (typ_obj.* != .named_type) return error.TypeError;
    const nt = typ_obj.named_type;
    if (!nt.is_cycle) return constructNamedType(ctx, typ_obj, arg);
    switch (nt.base) {
        .int => {
            const n = try vms.valueAsNumber(arg);
            if (@trunc(n) != n) return error.TypeError;
            const wrapped = try wrapCycleValueWithError(ctx, nt.name, nt.min, nt.max, n, false);
            return .{ .int = vm_mod.floatToIntSafe(wrapped) catch {
                setNamedRangeError(ctx, typ_obj, wrapped);
                return error.RangeError;
            } };
        },
        .float => {
            const n = try vms.valueAsNumber(arg);
            const wrapped = try wrapCycleValueWithError(ctx, nt.name, nt.min, nt.max, n, true);
            return .{ .float = wrapped };
        },
        .decimal => {
            const d = try vms.valueAsDecimal(arg);
            const factor = vmod.decimalScaleFactor(nt.scale);
            const fv = @as(f64, @floatFromInt(d)) / factor;
            const scaled = try wrapDecimalCycle(ctx, nt, fv, factor);
            return makeNamedValue(ctx, typ_obj, .{ .decimal = scaled });
        },
        else => return error.TypeError,
    }
}

pub fn applyNamedTypeFn(ctx: VMContext, typ_obj: *Object, kind: @import("value.zig").NamedTypeFnKind, arg: Value) !Value {
    if (typ_obj.* != .named_type) return error.TypeError;
    const nt = typ_obj.named_type;
    if (!nt.has_range) return error.TypeError;
    const inner = arg.namedInner() orelse arg;
    const n = try vms.valueAsNumber(inner);
    const delta: f64 = if (kind == .succ) 1.0 else -1.0;
    const result = n + delta;
    // `result == n` alone doesn't catch a NaN input: NaN+delta is still NaN,
    // and NaN == NaN is false under IEEE 754, so this check never fired for
    // NaN and it fell through to the range/cycle/clamp branches below —
    // all of which also compare false against NaN in both directions, so a
    // NaN argument silently produced NaN as if it were a valid instance of
    // the range-constrained type. wrapCycleValue/clampValue both already
    // guard against this explicitly; the plain-range path needs the same.
    if (result == n or !std.math.isFinite(result)) {
        ctx.vs.setRuntimeErr("cannot increment non-finite or very large value", .{});
        announcePanicMsg(ctx);
        return error.RangeError;
    }
    if (nt.is_cycle) {
        if (nt.base == .float) return Value{ .float = try wrapCycleValue(nt.min, nt.max, result, true) };
        const wrapped = try wrapCycleValue(nt.min, nt.max, result, false);
        return Value{ .int = vm_mod.floatToIntSafe(wrapped) catch {
            setNamedRangeError(ctx, typ_obj, wrapped);
            return error.RangeError;
        } };
    } else if (nt.is_clamp) {
        const clamped = try clampValue(nt.min, nt.max, result);
        if (nt.base == .float) return Value{ .float = clamped };
        return Value{ .int = vm_mod.floatToIntSafe(clamped) catch {
            setNamedRangeError(ctx, typ_obj, clamped);
            return error.RangeError;
        } };
    } else {
        if (result < nt.min or result > nt.max) {
            setNamedRangeError(ctx, typ_obj, result);
            return error.RangeError;
        }
        if (nt.base == .float) return Value{ .float = result };
        return Value{ .int = vm_mod.floatToIntSafe(result) catch {
            setNamedRangeError(ctx, typ_obj, result);
            return error.RangeError;
        } };
    }
}

fn argTypeError(ctx: VMContext, f: FuncObj, i: usize, spec: FieldTypeSpec, arg: Value) error{TypeError} {
    var buf: [128]u8 = undefined;
    const expected = fieldTypeSpecStr(&buf, spec);
    if (f.name.len > 0) {
        ctx.vs.setRuntimeErr("{s}: arg {}: expected {s}, got {s}", .{ f.name, i + 1, expected, runtimeTypeName(arg) });
    } else {
        ctx.vs.setRuntimeErr("arg {}: expected {s}, got {s}", .{ i + 1, expected, runtimeTypeName(arg) });
    }
    return error.TypeError;
}

fn bareScalarMatchesNamedBase(base: @import("value.zig").NamedTypeBase, v: Value) bool {
    return switch (base) {
        .int => v == .int or v == .rune,
        .float => v == .float,
        .bool => v == .boolean,
        .rune => v == .rune,
        else => false,
    };
}

fn reifyErasedNamedInterfaceArg(ctx: VMContext, arg: Value, iname: []const u8) !?Value {
    const temp_root_base = ctx.vs.tempRootDepth();
    defer ctx.vs.restoreTempRoots(temp_root_base);
    var match: ?Value = null;
    for (0..ctx.gs.len()) |i| {
        const candidate = ctx.gs.valueAt(i);
        if (!(candidate == .object and candidate.object.* == .named_type)) continue;
        const nt_obj = candidate.object;
        const nt = nt_obj.named_type;
        if (!bareScalarMatchesNamedBase(nt.base, arg)) continue;
        const wrapped = try makeNamedValue(ctx, nt_obj, arg);
        if (!matchesInterfaceType(ctx, wrapped, iname)) continue;
        if (match != null) return null;
        match = wrapped;
        try ctx.vs.pushTempRoot(wrapped);
    }
    return match;
}

pub fn coerceErasedValueForSpec(ctx: VMContext, spec: FieldTypeSpec, arg: Value) !?Value {
    if (arg == .object or arg == .inline_variant) return null;
    if (spec.alts.len != 1) return null;
    return switch (spec.alts[0].typ) {
        .named_t => blk: {
            const nt_val = ctx.gs.get(spec.alts[0].named_name) orelse break :blk null;
            if (nt_val != .object or nt_val.object.* != .named_type) break :blk null;
            const nt = nt_val.object.named_type;
            if (!bareScalarMatchesNamedBase(nt.base, arg)) break :blk null;
            // Constructing must carry the same weight as an explicit Type(x)
            // call site: range/cycle checks happen inside constructNamedType
            // itself, and a custom `predicate` still has to run here too, or
            // an erased dynamic value (host wire, json.parse, any) could
            // reach a named-typed parameter without ever being validated.
            const constructed = try constructNamedType(ctx, nt_val.object, arg);
            try vm_mod.checkNamedTypePredicateChain(ctx, nt_val.object, constructed.namedInner() orelse constructed);
            break :blk constructed;
        },
        .interface_t => try reifyErasedNamedInterfaceArg(ctx, arg, spec.alts[0].interface_name),
        else => null,
    };
}

fn isSingleNamedTypeSpec(spec: FieldTypeSpec) bool {
    return spec.alts.len == 1 and spec.alts[0].typ == .named_t;
}

// A primitive spec is a single-alt spec whose alt is a scalar with no
// allocation overhead, making it safe to type-check inline on the IC warm path.
// Must stay in sync with the set of tags matchesTypeAlt handles without heap
// access. decimal_t is included: v == .decimal is a tag-only comparison.
// Deliberately kept as its own dense switch (tag values 1-7, contiguous) so
// the compiler can jump-table it — this is the hot path (every typed-param
// call not already proven at its call site) and must stay exactly as cheap
// as before isInlinableExtraTypeSpec was added below. Measured: folding the
// struct_t/interface_t/variant_t tags (11/12/14 — not contiguous with 1-7)
// into this same switch made the combined tag set sparse enough that the
// primitive-only case got ~5 extra instructions per call (10M-call
// call-overhead bench, ReleaseFast) even though those calls never touch a
// non-primitive param at all.
fn isPrimitiveTypeSpec(spec: FieldTypeSpec) bool {
    if (spec.alts.len != 1) return false;
    return switch (spec.alts[0].typ) {
        .int, .float, .decimal_t, .boolean, .null_t, .rune_t, .string => true,
        else => false,
    };
}

// The struct_t/interface_t/variant_t extension to isPrimitiveTypeSpec above,
// checked only when that fast check already failed — see its comment for
// why these stay a separate switch rather than one combined set.
fn isInlinableExtraTypeSpec(spec: FieldTypeSpec) bool {
    return switch (spec.alts[0].typ) {
        .struct_t, .interface_t, .variant_t => true,
        else => false,
    };
}

fn isInlinableTypeSpec(spec: FieldTypeSpec) bool {
    if (isPrimitiveTypeSpec(spec)) return true;
    if (spec.alts.len != 1) return false;
    return isInlinableExtraTypeSpec(spec);
}

pub fn canInlinePrimitiveArgs(f: FuncObj, argc: u8) bool {
    if (!f.has_typed_params) return false;
    if (f.is_variadic or f.default_count > 0) return false;
    if (f.arity != argc) return false;
    for (f.param_types[0..f.arity]) |spec| {
        if (!isInlinableTypeSpec(spec)) return false;
    }
    return true;
}

pub fn enforcePrimitiveFuncArgTypes(ctx: VMContext, f: FuncObj, argc: u8) !void {
    const vs = ctx.vs;
    const base = vs.stack_top - argc;
    for (0..f.arity) |i| {
        const spec = f.param_types[i];
        var arg = vs.stack[base + i];
        if (isPrimitiveTypeSpec(spec)) {
            if (!matchesTypeAlt(ctx, arg, &spec.alts[0])) return argTypeError(ctx, f, i, spec, arg);
            continue;
        }
        // A spec shape canInlinePrimitiveArgs wouldn't have accepted here
        // means GC pool-slot reuse; fall back to full enforcement.
        if (spec.alts.len != 1 or !isInlinableExtraTypeSpec(spec)) return enforceFuncArgTypes(ctx, f, argc);
        // interface_t is the one inlinable kind with real coercion behavior
        // (reifying an erased scalar — host wire, json.parse, any — into
        // the interface it satisfies); coerceErasedValueForSpec no-ops
        // immediately for the common case (arg already an object).
        if (spec.alts[0].typ == .interface_t) {
            if (try coerceErasedValueForSpec(ctx, spec, arg)) |coerced| {
                vs.stack[base + i] = coerced;
                arg = coerced;
            }
        }
        if (!matchesTypeAlt(ctx, arg, &spec.alts[0])) return argTypeError(ctx, f, i, spec, arg);
    }
}

pub fn enforceFuncArgTypes(ctx: VMContext, f: FuncObj, argc: u8) !void {
    if (!f.has_typed_params) return;
    const fixed: usize = if (f.is_variadic) f.arity - 1 else f.arity;
    for (0..fixed) |i| {
        const slot = ctx.vs.stack_top - argc + i;
        var arg = ctx.vs.stack[slot];
        if (try coerceErasedValueForSpec(ctx, f.param_types[i], arg)) |coerced| {
            ctx.vs.stack[slot] = coerced;
            if (isSingleNamedTypeSpec(f.param_types[i])) continue;
            arg = coerced;
        }
        if (!matchesTypeSpec(ctx, arg, f.param_types[i])) return argTypeError(ctx, f, i, f.param_types[i], arg);
    }
    if (f.is_variadic) {
        for (fixed..@as(usize, argc)) |i| {
            const slot = ctx.vs.stack_top - argc + i;
            var arg = ctx.vs.stack[slot];
            if (try coerceErasedValueForSpec(ctx, f.variadic_type, arg)) |coerced| {
                ctx.vs.stack[slot] = coerced;
                if (isSingleNamedTypeSpec(f.variadic_type)) continue;
                arg = coerced;
            }
            if (!matchesTypeSpec(ctx, arg, f.variadic_type)) return argTypeError(ctx, f, i, f.variadic_type, arg);
        }
    }
}

pub fn enforceFuncReturnTypes(ctx: VMContext, f: FuncObj, retval: Value) !void {
    if (!f.has_typed_returns) return;
    if (f.return_types.len == 0) return;
    // Named returns are programmer-controlled and may be null-initialized; skip enforcement.
    if (f.named_return_count > 0) return;
    if (f.return_types.len == 1) {
        if (try coerceErasedValueForSpec(ctx, f.return_types[0], retval)) |coerced| {
            if (isSingleNamedTypeSpec(f.return_types[0])) return;
            if (matchesTypeSpec(ctx, coerced, f.return_types[0])) return;
        }
        if (!matchesTypeSpec(ctx, retval, f.return_types[0])) {
            var buf: [128]u8 = undefined;
            const expected = fieldTypeSpecStr(&buf, f.return_types[0]);
            if (f.name.len > 0) {
                ctx.vs.setRuntimeErr("{s}: expected return {s}, got {s}", .{ f.name, expected, runtimeTypeName(retval) });
            } else {
                ctx.vs.setRuntimeErr("expected return {s}, got {s}", .{ expected, runtimeTypeName(retval) });
            }
            return error.TypeError;
        }
        return;
    }
    if (!(retval == .object and vms.isArrayObject(retval.object))) return error.TypeError;
    const arr = try vms.asArraySlice(retval.object);
    if (arr.len != f.return_types.len) return error.ArityMismatch;
    for (arr, f.return_types, 0..) |v, rt, i| {
        if (!matchesTypeSpec(ctx, v, rt)) {
            var buf: [128]u8 = undefined;
            const expected = fieldTypeSpecStr(&buf, rt);
            if (f.name.len > 0) {
                ctx.vs.setRuntimeErr("{s}: return {}: expected {s}, got {s}", .{ f.name, i + 1, expected, runtimeTypeName(v) });
            } else {
                ctx.vs.setRuntimeErr("return {}: expected {s}, got {s}", .{ i + 1, expected, runtimeTypeName(v) });
            }
            return error.TypeError;
        }
    }
}

// Returns true if the function has a single simple primitive return type
// that can be checked inline in the ret fast path.
pub fn isPrimitiveReturn(f: FuncObj) bool {
    if (f.named_return_count > 0) return false;
    if (f.return_types.len != 1) return false;
    const spec = f.return_types[0];
    if (spec.alts.len != 1) return false;
    return switch (spec.alts[0].typ) {
        .int, .float, .boolean, .null_t, .rune_t, .string => true,
        else => false,
    };
}

// Inline tag check matching enforceFuncReturnTypes for single primitive returns.
pub fn checkPrimitiveReturn(f: FuncObj, v: Value) bool {
    const alt = f.return_types[0].alts[0];
    return switch (alt.typ) {
        .int => v == .int or v == .rune,
        .float => v == .float or v == .rune,
        .boolean => v == .boolean,
        .null_t => v == .null,
        .rune_t => v == .rune,
        .string => vms.isStringValue(v),
        else => false,
    };
}

pub fn frameFuncSig(func_obj: *Object) !FuncObj {
    return switch (func_obj.*) {
        .function => |f| f,
        .closure => |cl| cl.func.function,
        else => error.NotAFunction,
    };
}

pub fn funcSignatureStr(buf: *[256]u8, f: FuncObj) []const u8 {
    if (!f.has_typed_params) {
        if (f.name.len > 0) return f.name;
        return "func";
    }
    var wi: usize = 0;
    const prefix = if (f.name.len > 0) f.name else "func";
    if (wi + prefix.len > 255) return "func";
    @memcpy(buf[wi .. wi + prefix.len], prefix);
    wi += prefix.len;
    if (wi >= 255) return buf[0..wi];
    buf[wi] = '(';
    wi += 1;
    const fixed: usize = if (f.is_variadic) f.arity - 1 else f.arity;
    var first_param = true;
    for (f.param_types[0..fixed]) |pt| {
        var tbuf: [128]u8 = undefined;
        const tstr = fieldTypeSpecStr(&tbuf, pt);
        if (!first_param and wi < 255) {
            buf[wi] = ',';
            wi += 1;
            buf[wi] = ' ';
            wi += 1;
        }
        first_param = false;
        if (wi + tstr.len > 255) break;
        @memcpy(buf[wi .. wi + tstr.len], tstr);
        wi += tstr.len;
    }
    if (f.is_variadic) {
        var vbuf: [128]u8 = undefined;
        const vstr = fieldTypeSpecStr(&vbuf, f.variadic_type);
        if (!first_param and wi < 255) {
            buf[wi] = ',';
            wi += 1;
            buf[wi] = ' ';
            wi += 1;
        }
        _ = &first_param;
        if (wi + vstr.len + 3 <= 255) {
            @memcpy(buf[wi .. wi + vstr.len], vstr);
            wi += vstr.len;
            buf[wi] = '.';
            wi += 1;
            buf[wi] = '.';
            wi += 1;
            buf[wi] = '.';
            wi += 1;
        }
    }
    if (wi < 255) {
        buf[wi] = ')';
        wi += 1;
    }
    return buf[0..wi];
}
