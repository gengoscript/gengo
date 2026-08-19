// Pure, VMContext-free structural type-shape comparisons shared by the
// compiler (compile-time proof) and the VM (runtime fallback checks).
//
// Split out of vm_types.zig: these four functions were the only
// VMContext-independent code in that file, and their presence there meant
// compiler.zig's compilation unit transitively pulled in all of vm.zig
// (vm_types.zig imports vm_mod for its other, genuinely VM-runtime
// functions) just to reach interfaceMethodMatches. This file must never
// import compiler.zig or vm.zig — that's the whole point of it existing.

const std = @import("std");
const common = @import("common.zig");
const value_mod = @import("value.zig");
const StructFieldSpec = value_mod.StructFieldSpec;
const FieldTypeSpec = value_mod.FieldTypeSpec;
const FieldTypeAlt = value_mod.FieldTypeAlt;
const InterfaceMethodSpec = value_mod.InterfaceMethodSpec;
const FuncObj = value_mod.FuncObj;

pub fn findFieldIndex(fields: []const StructFieldSpec, key: []const u8) ?usize {
    for (fields, 0..) |f, i| {
        if (common.streq(f.name, key)) return i;
    }
    return null;
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
            for (ap, bp) |pa, pb| {
                if (!fieldTypeSpecEqual(pa, pb)) break :blk false;
            }
            const ar = a.func_returns orelse &[_]FieldTypeSpec{};
            const br = b.func_returns orelse &[_]FieldTypeSpec{};
            if (ar.len != br.len) break :blk false;
            for (ar, br) |ra, rb| {
                if (!fieldTypeSpecEqual(ra, rb)) break :blk false;
            }
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
