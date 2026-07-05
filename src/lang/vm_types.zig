const std = @import("std");
const common = @import("common.zig");
const globals = @import("globals.zig");
const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const vmod = @import("value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const FieldTypeAlt = @import("value.zig").FieldTypeAlt;
const FieldTypeSpec = @import("value.zig").FieldTypeSpec;
const StructFieldSpec = @import("value.zig").StructFieldSpec;
const InterfaceMethodSpec = @import("value.zig").InterfaceMethodSpec;
const FuncObj = @import("value.zig").FuncObj;

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
    if (v == .named_scalar) return v.named_scalar.typ.named_type.name;
    return switch (v) {
        .int => "int",
        .float => "float",
        .decimal => "decimal",
        .rune => "rune",
        .boolean => "bool",
        .string => "string",
        .error_value => "error",
        .null => "null",
        .named_scalar => unreachable,
        .object => |obj| switch (obj.*) {
            .named_value => obj.named_value.typ.named_type.name,
            .enum_value => obj.enum_value.typ.enum_type.name,
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
inline fn announcePanicMsg() void {
    vms.vmState().pending_panic_message = vms.runtimeErrMsg();
}

fn setNamedRangeError(typ_obj: *Object, value: f64) void {
    const nt = typ_obj.named_type;
    if (!std.math.isFinite(value)) {
        vms.setRuntimeErr("{s}: {d} is outside {d}..{d}", .{ nt.name, value, nt.min, nt.max });
    } else switch (nt.base) {
        .int, .rune => vms.setRuntimeErr("{s}: {d} is outside {d}..{d}", .{
            nt.name,
            @as(i64, @intFromFloat(@trunc(value))),
            @as(i64, @intFromFloat(@trunc(nt.min))),
            @as(i64, @intFromFloat(@trunc(nt.max))),
        }),
        else => vms.setRuntimeErr("{s}: {d} is outside {d}..{d}", .{ nt.name, value, nt.min, nt.max }),
    }
    announcePanicMsg();
}

// Resolve and cache the parent enum type pointer for enum subtypes.
pub fn resolveEnumParent(obj: *Object) ?*Object {
    if (obj.* != .enum_type) return null;
    if (obj.enum_type.parent) |cached| return cached;
    const pname = obj.enum_type.parent_name orelse return null;
    const pval = globals.get(pname) orelse return null;
    if (!(pval == .object and pval.object.* == .enum_type)) return null;
    obj.enum_type.parent = pval.object;
    return pval.object;
}

// Resolve and cache the parent type pointer, avoiding repeated globals lookups.
pub fn resolveParentType(obj: *Object) ?*Object {
    if (obj.* != .named_type) return null;
    if (obj.named_type.parent_obj) |cached| return cached;
    const pname = obj.named_type.parent_name orelse return null;
    const pval = globals.get(pname) orelse return null;
    if (!(pval == .object and pval.object.* == .named_type)) return null;
    obj.named_type.parent_obj = pval.object;
    return pval.object;
}

pub fn namedTypeIsOrExtends(typ_obj: *Object, target_name: []const u8) bool {
    if (typ_obj.* != .named_type) return false;
    var cur: *Object = typ_obj;
    while (true) {
        if (common.streq(cur.named_type.qualified_name, target_name)) return true;
        cur = resolveParentType(cur) orelse return false;
    }
}

pub fn findFieldIndex(fields: []const StructFieldSpec, key: []const u8) ?usize {
    for (fields, 0..) |f, i| {
        if (common.streq(f.name, key)) return i;
    }
    return null;
}

pub fn matchesTypeAlt(v: Value, alt: FieldTypeAlt) bool {
    return switch (alt.typ) {
        .any => true,
        .null_t => v == .null,
        .int => v == .int or v == .rune,
        .float => v == .float or v == .rune,
        .decimal_t => v == .decimal,
        .rune_t => v == .rune,
        .boolean => v == .boolean,
        .string => vms.isStringValue(v),
        .error_t => v == .error_value,
        .array => blk: {
            if (!(v == .object and vms.isArrayObject(v.object))) break :blk false;
            if (alt.elem_spec) |es| {
                const items = vms.asArraySlice(v.object) catch unreachable;
                for (items) |item| {
                    if (!matchesTypeSpec(item, es)) break :blk false;
                }
            }
            break :blk true;
        },
        .map => blk: {
            if (!(v == .object and vms.isMapObject(v.object))) break :blk false;
            if (alt.key_spec) |ks| {
                const entries = vms.asMapSlice(v.object) catch unreachable;
                for (entries) |e| {
                    if (!matchesTypeSpec(e.key, ks)) break :blk false;
                    if (alt.val_spec) |vs| {
                        if (!matchesTypeSpec(e.value, vs)) break :blk false;
                    }
                }
            }
            break :blk true;
        },
        .struct_t => v == .object and v.object.* == .struct_instance and common.streq(v.object.struct_instance.typ.struct_type.qualified_name, alt.struct_name),
        .interface_t => matchesInterfaceType(v, alt.interface_name),
        .named_t => named_t_blk: {
            if (v == .named_scalar) break :named_t_blk namedTypeIsOrExtends(v.named_scalar.typ, alt.named_name);
            if (!(v == .object)) break :named_t_blk false;
            break :named_t_blk switch (v.object.*) {
                .named_value => namedTypeIsOrExtends(v.object.named_value.typ, alt.named_name),
                .enum_value => blk: {
                    if (common.streq(v.object.enum_value.typ.enum_type.qualified_name, alt.named_name)) break :blk true;
                    const sub_val = globals.get(alt.named_name) orelse break :blk false;
                    if (!(sub_val == .object and sub_val.object.* == .enum_type)) break :blk false;
                    if (sub_val.object.enum_type.parent_name == null) break :blk false;
                    const parent_obj = resolveEnumParent(sub_val.object) orelse break :blk false;
                    if (parent_obj != v.object.enum_value.typ) break :blk false;
                    for (sub_val.object.enum_type.members) |m| {
                        if (common.streq(m, v.object.enum_value.name)) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
        },
        .variant_t => v == .object and v.object.* == .variant_value and
            common.streq(v.object.variant_value.typ.variant_type.qualified_name, alt.named_name),
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
    };
}

pub fn matchesFieldType(v: Value, spec: StructFieldSpec) bool {
    return matchesTypeSpec(v, spec.typ);
}

pub fn matchesTypeSpec(v: Value, spec: FieldTypeSpec) bool {
    for (spec.alts) |alt| {
        if (matchesTypeAlt(v, alt)) return true;
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
    };
}

fn fieldTypeSpecStr(buf: *[128]u8, spec: FieldTypeSpec) []const u8 {
    return fieldTypeAltStr(buf, spec.alts[0]);
}

fn fieldTypeSpecEqual(a: FieldTypeSpec, b: FieldTypeSpec) bool {
    if (a.alts.len != b.alts.len) return false;
    for (a.alts, b.alts) |aa, ba| {
        if (!fieldTypeAltEqual(aa, ba)) return false;
    }
    return true;
}

fn fieldTypeAltEqual(a: FieldTypeAlt, b: FieldTypeAlt) bool {
    if (a.typ != b.typ) return false;
    return switch (a.typ) {
        .struct_t => common.streq(a.struct_name, b.struct_name),
        .interface_t => common.streq(a.interface_name, b.interface_name),
        .named_t, .variant_t => common.streq(a.named_name, b.named_name),
        .array => blk: {
            const ae = a.elem_spec orelse break :blk b.elem_spec == null;
            const be = b.elem_spec orelse break :blk false;
            break :blk fieldTypeSpecEqual(ae, be);
        },
        .map => blk: {
            const ak = a.key_spec orelse break :blk b.key_spec == null;
            const bk = b.key_spec orelse break :blk false;
            if (!fieldTypeSpecEqual(ak, bk)) break :blk false;
            const av = a.val_spec orelse break :blk b.val_spec == null;
            const bv = b.val_spec orelse break :blk false;
            break :blk fieldTypeSpecEqual(av, bv);
        },
        .func_t => blk: {
            const ap = a.func_params orelse &[_]FieldTypeSpec{};
            const bp = b.func_params orelse &[_]FieldTypeSpec{};
            if (ap.len != bp.len) break :blk false;
            for (ap, bp) |pa, pb| { if (!fieldTypeSpecEqual(pa, pb)) break :blk false; }
            const ar = a.func_returns orelse &[_]FieldTypeSpec{};
            const br = b.func_returns orelse &[_]FieldTypeSpec{};
            if (ar.len != br.len) break :blk false;
            for (ar, br) |ra, rb| { if (!fieldTypeSpecEqual(ra, rb)) break :blk false; }
            break :blk true;
        },
        else => true,
    };
}

pub fn interfaceMethodMatches(m: InterfaceMethodSpec, f: FuncObj) bool {
    if (m.is_variadic != f.is_variadic) return false;
    var f_param_start: usize = 0;
    if (f.arity == m.arity + 1 and f.param_types.len == m.param_types.len + 1) {
        // Struct receiver methods are compiled with an implicit first parameter.
        f_param_start = 1;
    } else if (m.arity != f.arity) {
        return false;
    }
    if (m.has_typed_params != f.has_typed_params) return false;
    if (m.has_typed_returns != f.has_typed_returns) return false;
    if (m.param_types.len + f_param_start != f.param_types.len) return false;
    if (m.return_types.len != f.return_types.len) return false;
    if (m.is_variadic) {
        if (!fieldTypeSpecEqual(m.variadic_type, f.variadic_type)) return false;
    }
    for (m.param_types, f.param_types[f_param_start..]) |mp, fp| {
        if (!fieldTypeSpecEqual(mp, fp)) return false;
    }
    for (m.return_types, f.return_types) |mr, fr| {
        if (!fieldTypeSpecEqual(mr, fr)) return false;
    }
    return true;
}

pub fn matchesInterfaceType(v: Value, iname: []const u8) bool {
    const tname = if (v == .named_scalar)
        v.named_scalar.typ.named_type.qualified_name
    else switch (v) {
        .object => |obj| switch (obj.*) {
            .struct_instance => obj.struct_instance.typ.struct_type.qualified_name,
            .named_value => obj.named_value.typ.named_type.qualified_name,
            .enum_value => obj.enum_value.typ.enum_type.qualified_name,
            .variant_value => obj.variant_value.typ.variant_type.qualified_name,
            else => return false,
        },
        else => return false,
    };
    const iv = globals.get(iname) orelse return false;
    if (!(iv == .object and iv.object.* == .interface_type)) return false;
    const it = iv.object.interface_type;
    for (it.methods) |m| {
        const total = tname.len + 1 + m.name.len;
        if (total > 512) return false;
        var key_buf: [512]u8 = undefined;
        @memcpy(key_buf[0..tname.len], tname);
        key_buf[tname.len] = '.';
        @memcpy(key_buf[tname.len + 1 .. total], m.name);
        const fnv = globals.get(key_buf[0..total]) orelse return false;
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

pub fn makeNamedValue(typ_obj: *Object, inner: Value) !Value {
    if (typ_obj.* == .named_type) {
        const bits: ?u64 = switch (typ_obj.named_type.base) {
            .int     => @as(u64, @bitCast(inner.int)),
            .float   => @as(u64, @bitCast(inner.float)),
            .decimal => @as(u64, @bitCast(inner.decimal)),
            .rune    => @as(u64, inner.rune),
            .bool    => if (inner.boolean) @as(u64, 1) else @as(u64, 0),
            else     => null,
        };
        if (bits) |b| return .{ .named_scalar = .{ .typ = typ_obj, .bits = b } };
    }
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .named_value = .{ .typ = typ_obj, .value = inner } };
    return .{ .object = obj };
}

pub fn variantConstruct(typ: *Object, tag: []const u8, ordinal: usize, payload: Value) !Value {
    const vv = try vmgc.vmAllocObject();
    vv.* = .{ .variant_value = .{ .typ = typ, .tag = tag, .ordinal = ordinal, .payload = payload } };
    return .{ .object = vv };
}

// `continuous` selects the wraparound convention:
//   - discrete (int):  domain is `span = (max - min) + 1` inclusive integer
//     steps, e.g. `cycle 0..23` has 24 distinct values and 24 wraps to 0.
//   - continuous (float/decimal): the endpoints are identified with each
//     other, e.g. `cycle 0.0..360.0` treats 360.0 as the same point as 0.0,
//     so `span = max - min` and the maximum itself wraps to the minimum.
fn wrapCycleValueWithError(name: []const u8, min: f64, max: f64, n: f64, continuous: bool) !f64 {
    return wrapCycleValue(min, max, n, continuous) catch |err| {
        if (err == error.RangeError) {
            vms.setRuntimeErr("{s}: {d} is outside cyclic range {d}..{d}", .{ name, n, min, max });
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

pub fn constructNamedType(typ_obj: *Object, arg: Value) !Value {
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
                    vms.setRuntimeErr("cannot construct {s} from {s}; convert to {s} first", .{ nt.name, runtimeTypeName(effective_arg), namedBaseName(nt.base) });
                    announcePanicMsg();
                }
                return err;
            };
            if (!std.math.isFinite(n)) {
                setNamedRangeError(typ_obj, n);
                return error.RangeError;
            }
            if (@trunc(n) != n) {
                vms.setRuntimeErr("cannot construct {s} from {s}; convert to {s} first", .{ nt.name, runtimeTypeName(effective_arg), namedBaseName(nt.base) });
                announcePanicMsg();
                return error.TypeError;
            }
            if (nt.has_range and (n < nt.min or n > nt.max)) {
                if (nt.is_cycle) {
                    const wrapped = try wrapCycleValueWithError(nt.name, nt.min, nt.max, n, false);
                    base_v = .{ .int = @intFromFloat(wrapped) };
                } else {
                    setNamedRangeError(typ_obj, n);
                    return error.RangeError;
                }
            } else {
                base_v = .{ .int = @intFromFloat(n) };
            }
        },
        .float => {
            const n = vms.valueAsNumber(effective_arg) catch |err| {
                if (err == error.TypeError) {
                    vms.setRuntimeErr("cannot construct {s} from {s}; convert to {s} first", .{ nt.name, runtimeTypeName(effective_arg), namedBaseName(nt.base) });
                    announcePanicMsg();
                }
                return err;
            };
            if (!std.math.isFinite(n)) {
                setNamedRangeError(typ_obj, n);
                return error.RangeError;
            }
            // Continuous cycle: max is identified with min, so n == max must
            // also wrap (unlike a plain range, where max is a valid value).
            const out_of_bounds = if (nt.is_cycle) n < nt.min or n >= nt.max else n < nt.min or n > nt.max;
            if (nt.has_range and out_of_bounds) {
                if (nt.is_cycle) {
                    const wrapped = try wrapCycleValueWithError(nt.name, nt.min, nt.max, n, true);
                    base_v = .{ .float = wrapped };
                } else {
                    setNamedRangeError(typ_obj, n);
                    return error.RangeError;
                }
            } else {
                base_v = .{ .float = n };
            }
        },
        .decimal => {
            const scale = nt.scale;
            const factor = std.math.pow(f64, 10.0, @floatFromInt(scale));
            const scaled: i64 = switch (effective_arg) {
                .int => |n| blk: {
                    const raw = @round(@as(f64, @floatFromInt(n)) * factor);
                    if (!std.math.isFinite(raw)) return error.TypeError;
                    if (raw < -std.math.pow(f64, 2.0, 63.0) or raw >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                    break :blk @intFromFloat(raw);
                },
                .float => |n| blk: {
                    const raw = @round(n * factor);
                    if (!std.math.isFinite(raw)) return error.TypeError;
                    if (raw < -std.math.pow(f64, 2.0, 63.0) or raw >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
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
                        base_v = .{ .decimal = try wrapDecimalCycle(nt, fv, factor) };
                    } else {
                        setNamedRangeError(typ_obj, fv);
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
                        vms.setRuntimeErr("{s}: {d} is outside {d}..{d}", .{ nt.name, n, nt.min, nt.max });
                        announcePanicMsg();
                        return error.RangeError;
                    }
                    const t = @trunc(n);
                    if (t != n or t < 0) return error.TypeError;
                    break :blk @intFromFloat(t);
                },
                else => return error.TypeError,
            };
            const rf: f64 = @floatFromInt(r);
            base_v = .{ .rune = r };
            if (nt.has_range and (rf < nt.min or rf > nt.max)) {
                setNamedRangeError(typ_obj, rf);
                return error.RangeError;
            }
        },
        .string => {
            if (!vms.isStringValue(effective_arg)) return error.TypeError;
            const s = try vms.asStringValue(effective_arg);
            const ds = try vmgc.makeDynString(s);
            try vms.pushTempRoot(ds);
            defer vms.popTempRoot();
            return makeNamedValue(typ_obj, ds);
        },
        .bool => {
            if (effective_arg != .boolean) return error.TypeError;
            base_v = effective_arg;
        },
        .array_t => {
            if (!(effective_arg == .object and vms.isArrayObject(effective_arg.object))) return error.TypeError;
            if (nt.elem_spec) |es| {
                for (try vms.asArraySlice(effective_arg.object)) |item| {
                    if (!matchesTypeSpec(item, es)) return error.TypeError;
                }
            }
            return makeNamedValue(typ_obj, effective_arg);
        },
        .map_t => {
            if (!(effective_arg == .object and vms.isMapObject(effective_arg.object))) return error.TypeError;
            if (nt.key_spec) |ks| {
                for (try vms.asMapSlice(effective_arg.object)) |e| {
                    if (!matchesTypeSpec(e.key, ks)) return error.TypeError;
                    if (nt.val_spec) |vs| {
                        if (!matchesTypeSpec(e.value, vs)) return error.TypeError;
                    }
                }
            }
            return makeNamedValue(typ_obj, effective_arg);
        },
        .enum_t => return error.TypeError,
    }
    return makeNamedValue(typ_obj, base_v);
}

// Wraps an out-of-range decimal value (given as its unscaled real value `fv`)
// into the named type's cyclic domain and rescales it back to the fixed-point
// integer representation.
fn wrapDecimalCycle(nt: @import("value.zig").NamedTypeObj, fv: f64, factor: f64) !i64 {
    const wrapped = try wrapCycleValueWithError(nt.name, nt.min, nt.max, fv, true);
    const raw = @round(wrapped * factor);
    if (!std.math.isFinite(raw) or raw < -std.math.pow(f64, 2.0, 63.0) or raw >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
    return @intFromFloat(raw);
}

pub fn coerceNamedTypeResult(typ_obj: *Object, arg: Value) !Value {
    if (typ_obj.* != .named_type) return error.TypeError;
    const nt = typ_obj.named_type;
    if (!nt.is_cycle) return constructNamedType(typ_obj, arg);
    switch (nt.base) {
        .int => {
            const n = try vms.valueAsNumber(arg);
            if (@trunc(n) != n) return error.TypeError;
            const wrapped = try wrapCycleValueWithError(nt.name, nt.min, nt.max, n, false);
            return makeNamedValue(typ_obj, .{ .int = @intFromFloat(wrapped) });
        },
        .float => {
            const n = try vms.valueAsNumber(arg);
            const wrapped = try wrapCycleValueWithError(nt.name, nt.min, nt.max, n, true);
            return makeNamedValue(typ_obj, .{ .float = wrapped });
        },
        .decimal => {
            const d = try vms.valueAsDecimal(arg);
            const factor = std.math.pow(f64, 10.0, @floatFromInt(nt.scale));
            const fv = @as(f64, @floatFromInt(d)) / factor;
            const scaled = try wrapDecimalCycle(nt, fv, factor);
            return makeNamedValue(typ_obj, .{ .decimal = scaled });
        },
        else => return error.TypeError,
    }
}

pub fn applyNamedTypeFn(typ_obj: *Object, kind: @import("value.zig").NamedTypeFnKind, arg: Value) !Value {
    if (typ_obj.* != .named_type) return error.TypeError;
    const nt = typ_obj.named_type;
    if (!nt.has_range) return error.TypeError;
    const inner = arg.namedInner() orelse arg;
    const n = try vms.valueAsNumber(inner);
    const delta: f64 = if (kind == .succ) 1.0 else -1.0;
    const result = n + delta;
    if (result == n) { vms.setRuntimeErr("cannot increment non-finite or very large value", .{}); announcePanicMsg(); return error.RangeError; }
    if (nt.is_cycle) {
        return makeNamedValue(typ_obj, if (nt.base == .float) .{ .float = try wrapCycleValue(nt.min, nt.max, result, true) } else .{ .int = @intFromFloat(try wrapCycleValue(nt.min, nt.max, result, false)) });
    } else {
        if (result < nt.min or result > nt.max) {
            setNamedRangeError(typ_obj, result);
            return error.RangeError;
        }
        return makeNamedValue(typ_obj, if (nt.base == .float) .{ .float = result } else .{ .int = @intFromFloat(result) });
    }
}

fn argTypeError(f: FuncObj, i: usize, spec: FieldTypeSpec, arg: Value) error{TypeError} {
    var buf: [128]u8 = undefined;
    const expected = fieldTypeSpecStr(&buf, spec);
    if (f.name.len > 0) {
        vms.setRuntimeErr("{s}: arg {}: expected {s}, got {s}", .{ f.name, i + 1, expected, runtimeTypeName(arg) });
    } else {
        vms.setRuntimeErr("arg {}: expected {s}, got {s}", .{ i + 1, expected, runtimeTypeName(arg) });
    }
    return error.TypeError;
}

// A primitive spec is a single-alt spec whose alt is a scalar with no
// allocation overhead, making it safe to type-check inline on the IC warm path.
// Must stay in sync with the set of tags matchesTypeAlt handles without heap
// access. decimal_t is included: v == .decimal is a tag-only comparison.
fn isPrimitiveTypeSpec(spec: FieldTypeSpec) bool {
    if (spec.alts.len != 1) return false;
    return switch (spec.alts[0].typ) {
        .int, .float, .decimal_t, .boolean, .null_t, .rune_t, .string => true,
        else => false,
    };
}

pub fn canInlinePrimitiveArgs(f: FuncObj, argc: u8) bool {
    if (!f.has_typed_params) return false;
    if (f.is_variadic or f.default_count > 0) return false;
    if (f.arity != argc) return false;
    for (f.param_types[0..f.arity]) |spec| {
        if (!isPrimitiveTypeSpec(spec)) return false;
    }
    return true;
}

pub fn enforcePrimitiveFuncArgTypes(f: FuncObj, argc: u8) !void {
    const vs = vms.vmState();
    const base = vs.stack_top - argc;
    for (0..f.arity) |i| {
        const spec = f.param_types[i];
        // A non-primitive spec here means GC pool-slot reuse; fall back.
        if (!isPrimitiveTypeSpec(spec)) return enforceFuncArgTypes(f, argc);
        const arg = vs.stack[base + i];
        if (!matchesTypeAlt(arg, spec.alts[0])) return argTypeError(f, i, spec, arg);
    }
}

pub fn enforceFuncArgTypes(f: FuncObj, argc: u8) !void {
    if (!f.has_typed_params) return;
    const fixed: usize = if (f.is_variadic) f.arity - 1 else f.arity;
    for (0..fixed) |i| {
        const arg = vms.vmState().stack[vms.vmState().stack_top - argc + i];
        if (!matchesTypeSpec(arg, f.param_types[i])) return argTypeError(f, i, f.param_types[i], arg);
    }
    if (f.is_variadic) {
        for (fixed..@as(usize, argc)) |i| {
            const arg = vms.vmState().stack[vms.vmState().stack_top - argc + i];
            if (!matchesTypeSpec(arg, f.variadic_type)) return argTypeError(f, i, f.variadic_type, arg);
        }
    }
}

pub fn enforceFuncReturnTypes(f: FuncObj, retval: Value) !void {
    if (!f.has_typed_returns) return;
    if (f.return_types.len == 0) return;
    // Named returns are programmer-controlled and may be null-initialized; skip enforcement.
    if (f.named_return_count > 0) return;
    if (f.return_types.len == 1) {
        if (!matchesTypeSpec(retval, f.return_types[0])) {
            var buf: [128]u8 = undefined;
            const expected = fieldTypeSpecStr(&buf, f.return_types[0]);
            if (f.name.len > 0) {
                vms.setRuntimeErr("{s}: expected return {s}, got {s}", .{ f.name, expected, runtimeTypeName(retval) });
            } else {
                vms.setRuntimeErr("expected return {s}, got {s}", .{ expected, runtimeTypeName(retval) });
            }
            return error.TypeError;
        }
        return;
    }
    if (!(retval == .object and vms.isArrayObject(retval.object))) return error.TypeError;
    const arr = try vms.asArraySlice(retval.object);
    if (arr.len != f.return_types.len) return error.ArityMismatch;
    for (arr, f.return_types, 0..) |v, rt, i| {
        if (!matchesTypeSpec(v, rt)) {
            var buf: [128]u8 = undefined;
            const expected = fieldTypeSpecStr(&buf, rt);
            if (f.name.len > 0) {
                vms.setRuntimeErr("{s}: return {}: expected {s}, got {s}", .{ f.name, i + 1, expected, runtimeTypeName(v) });
            } else {
                vms.setRuntimeErr("return {}: expected {s}, got {s}", .{ i + 1, expected, runtimeTypeName(v) });
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
    @memcpy(buf[wi..wi + prefix.len], prefix);
    wi += prefix.len;
    if (wi >= 255) return buf[0..wi];
    buf[wi] = '(';
    wi += 1;
    const fixed: usize = if (f.is_variadic) f.arity - 1 else f.arity;
    var first_param = true;
    for (f.param_types[0..fixed]) |pt| {
        var tbuf: [128]u8 = undefined;
        const tstr = fieldTypeSpecStr(&tbuf, pt);
        if (!first_param and wi < 255) { buf[wi] = ','; wi += 1; buf[wi] = ' '; wi += 1; }
        first_param = false;
        if (wi + tstr.len > 255) break;
        @memcpy(buf[wi..wi + tstr.len], tstr);
        wi += tstr.len;
    }
    if (f.is_variadic) {
        var vbuf: [128]u8 = undefined;
        const vstr = fieldTypeSpecStr(&vbuf, f.variadic_type);
        if (!first_param and wi < 255) { buf[wi] = ','; wi += 1; buf[wi] = ' '; wi += 1; }
        _ = &first_param;
        if (wi + vstr.len + 3 <= 255) {
            @memcpy(buf[wi..wi + vstr.len], vstr);
            wi += vstr.len;
            buf[wi] = '.'; wi += 1; buf[wi] = '.'; wi += 1; buf[wi] = '.'; wi += 1;
        }
    }
    if (wi < 255) { buf[wi] = ')'; wi += 1; }
    return buf[0..wi];
}
