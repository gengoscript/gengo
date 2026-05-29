const common = @import("common.zig");
const globals = @import("globals.zig");
const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const FieldTypeAlt = @import("value.zig").FieldTypeAlt;
const FieldTypeSpec = @import("value.zig").FieldTypeSpec;
const StructFieldSpec = @import("value.zig").StructFieldSpec;
const InterfaceMethodSpec = @import("value.zig").InterfaceMethodSpec;
const FuncObj = @import("value.zig").FuncObj;

pub fn findFieldIndex(fields: []const StructFieldSpec, key: []const u8) ?usize {
    var i: usize = 0;
    while (i < fields.len) : (i += 1) {
        if (common.streq(fields[i].name, key)) return i;
    }
    return null;
}

pub fn matchesTypeAlt(v: Value, alt: FieldTypeAlt) bool {
    return switch (alt.typ) {
        .any => true,
        .null_t => v == .null,
        .int => (v == .number and @trunc(v.number) == v.number) or v == .rune,
        .float => v == .number or v == .rune,
        .rune_t => v == .rune,
        .boolean => v == .boolean,
        .string => vms.isStringValue(v),
        .error_t => v == .error_value,
        .array => v == .object and vms.isArrayObject(v.object),
        .map => v == .object and vms.isMapObject(v.object),
        .struct_t => v == .object and v.object.* == .struct_instance and common.streq(v.object.struct_instance.typ.struct_type.name, alt.struct_name),
        .interface_t => matchesInterfaceType(v, alt.interface_name),
        .named_t => v == .object and switch (v.object.*) {
            .named_value => common.streq(v.object.named_value.typ.named_type.name, alt.named_name),
            .enum_value => common.streq(v.object.enum_value.typ.enum_type.name, alt.named_name),
            else => false,
        },
    };
}

pub fn matchesFieldType(v: Value, spec: StructFieldSpec) bool {
    return matchesTypeSpec(v, spec.typ);
}

pub fn matchesTypeSpec(v: Value, spec: FieldTypeSpec) bool {
    var i: usize = 0;
    while (i < spec.alts.len) : (i += 1) {
        if (matchesTypeAlt(v, spec.alts[i])) return true;
    }
    return false;
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
        const ma = m.variadic_type.alts;
        const fa = f.variadic_type.alts;
        if (ma.len != fa.len) return false;
        var vai: usize = 0;
        while (vai < ma.len) : (vai += 1) {
            if (ma[vai].typ != fa[vai].typ) return false;
            switch (ma[vai].typ) {
                .struct_t => if (!common.streq(ma[vai].struct_name, fa[vai].struct_name)) return false,
                .interface_t => if (!common.streq(ma[vai].interface_name, fa[vai].interface_name)) return false,
                .named_t => if (!common.streq(ma[vai].named_name, fa[vai].named_name)) return false,
                else => {},
            }
        }
    }
    var i: usize = 0;
    while (i < m.param_types.len) : (i += 1) {
        const ma = m.param_types[i].alts;
        const fa = f.param_types[f_param_start + i].alts;
        if (ma.len != fa.len) return false;
        var ai: usize = 0;
        while (ai < ma.len) : (ai += 1) {
            if (ma[ai].typ != fa[ai].typ) return false;
            switch (ma[ai].typ) {
                .struct_t => if (!common.streq(ma[ai].struct_name, fa[ai].struct_name)) return false,
                .interface_t => if (!common.streq(ma[ai].interface_name, fa[ai].interface_name)) return false,
                .named_t => if (!common.streq(ma[ai].named_name, fa[ai].named_name)) return false,
                else => {},
            }
        }
    }
    i = 0;
    while (i < m.return_types.len) : (i += 1) {
        const ma = m.return_types[i].alts;
        const fa = f.return_types[i].alts;
        if (ma.len != fa.len) return false;
        var ai: usize = 0;
        while (ai < ma.len) : (ai += 1) {
            if (ma[ai].typ != fa[ai].typ) return false;
            switch (ma[ai].typ) {
                .struct_t => if (!common.streq(ma[ai].struct_name, fa[ai].struct_name)) return false,
                .interface_t => if (!common.streq(ma[ai].interface_name, fa[ai].interface_name)) return false,
                .named_t => if (!common.streq(ma[ai].named_name, fa[ai].named_name)) return false,
                else => {},
            }
        }
    }
    return true;
}

pub fn matchesInterfaceType(v: Value, iname: []const u8) bool {
    if (!(v == .object and v.object.* == .struct_instance)) return false;
    const tname = v.object.struct_instance.typ.struct_type.name;
    const iv = globals.get(iname) orelse return false;
    if (!(iv == .object and iv.object.* == .interface_type)) return false;
    const it = iv.object.interface_type;
    var mi: usize = 0;
    while (mi < it.methods.len) : (mi += 1) {
        const m = it.methods[mi];
        const total = tname.len + 1 + m.name.len;
        if (total > 128) return false;
        var key_buf: [128]u8 = undefined;
        @memcpy(key_buf[0..tname.len], tname);
        key_buf[tname.len] = '.';
        @memcpy(key_buf[tname.len + 1 .. total], m.name);
        const fnv = globals.get(key_buf[0..total]) orelse return false;
        if (!(fnv == .object and (fnv.object.* == .function or fnv.object.* == .closure))) return false;
        const f = switch (fnv.object.*) {
            .function => |ff| ff,
            .closure => |cl| cl.func.function,
            else => return false,
        };
        if (!interfaceMethodMatches(m, f)) return false;
    }
    return true;
}

pub fn makeNamedValue(typ_obj: *Object, inner: Value) !Value {
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .named_value = .{ .typ = typ_obj, .value = inner } };
    return .{ .object = obj };
}

pub fn constructNamedType(typ_obj: *Object, arg: Value) !Value {
    if (typ_obj.* != .named_type) return error.TypeError;
    const nt = typ_obj.named_type;
    var base_v: Value = undefined;
    switch (nt.base) {
        .int => {
            const n = try vms.valueAsNumber(arg);
            if (@trunc(n) != n) return error.TypeError;
            base_v = .{ .number = n };
            if (nt.has_range and (n < nt.min or n > nt.max)) return error.RangeError;
        },
        .float => {
            const n = try vms.valueAsNumber(arg);
            base_v = .{ .number = n };
            if (nt.has_range and (n < nt.min or n > nt.max)) return error.RangeError;
        },
        .rune => {
            const r: u21 = switch (arg) {
                .rune => |rv| rv,
                .number => |n| blk: {
                    const t = @trunc(n);
                    if (t != n or t < 0) return error.TypeError;
                    break :blk @intFromFloat(t);
                },
                else => return error.TypeError,
            };
            const rf: f64 = @floatFromInt(r);
            base_v = .{ .rune = r };
            if (nt.has_range and (rf < nt.min or rf > nt.max)) return error.RangeError;
        },
        .string => {
            if (!vms.isStringValue(arg)) return error.TypeError;
            const s = try vms.asStringValue(arg);
            base_v = try vmgc.makeDynString(s);
        },
        .bool => {
            if (arg != .boolean) return error.TypeError;
            base_v = arg;
        },
    }
    return makeNamedValue(typ_obj, base_v);
}

pub fn enforceFuncArgTypes(f: FuncObj, argc: u8) !void {
    if (!f.has_typed_params) return;
    const fixed: usize = if (f.is_variadic) f.arity - 1 else f.arity;
    var i: usize = 0;
    while (i < fixed) : (i += 1) {
        const arg = vms.vmState().stack[vms.vmState().stack_top - argc + i];
        if (!matchesTypeSpec(arg, f.param_types[i])) return error.TypeError;
    }
    if (f.is_variadic) {
        while (i < @as(usize, argc)) : (i += 1) {
            const arg = vms.vmState().stack[vms.vmState().stack_top - argc + i];
            if (!matchesTypeSpec(arg, f.variadic_type)) return error.TypeError;
        }
    }
}

pub fn enforceFuncReturnTypes(f: FuncObj, retval: Value) !void {
    if (!f.has_typed_returns) return;
    if (f.return_types.len == 0) return;
    if (f.return_types.len == 1) {
        if (!matchesTypeSpec(retval, f.return_types[0])) return error.TypeError;
        return;
    }
    if (!(retval == .object and vms.isArrayObject(retval.object))) return error.TypeError;
    const arr = vms.asArraySlice(retval.object);
    if (arr.len != f.return_types.len) return error.ArityMismatch;
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        if (!matchesTypeSpec(arr[i], f.return_types[i])) return error.TypeError;
    }
}

pub fn frameFuncSig(func_obj: *Object) !FuncObj {
    return switch (func_obj.*) {
        .function => |f| f,
        .closure => |cl| cl.func.function,
        else => error.NotAFunction,
    };
}
