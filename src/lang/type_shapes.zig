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

const testing = std.testing;
const FieldTypeTag = value_mod.FieldTypeTag;

fn scalarAlt(t: FieldTypeTag) FieldTypeAlt {
    return .{ .typ = t };
}

// A comptime-keyed static backing array (same trick as value.zig's
// staticSS): scalarSpec must not return a slice into a stack-local array,
// since FieldTypeSpec.alts is a plain slice with no lifetime of its own —
// the caller's copy would dangle the moment this function returns.
fn scalarSpec(comptime t: FieldTypeTag) FieldTypeSpec {
    const S = struct {
        var arr = [_]FieldTypeAlt{.{ .typ = t }};
    };
    return .{ .alts = &S.arr };
}

test "findFieldIndex returns the matching field's index, or null on no match" {
    const fields = [_]StructFieldSpec{
        .{ .name = "a", .typ = scalarSpec(.int) },
        .{ .name = "b", .typ = scalarSpec(.string) },
    };
    try testing.expectEqual(@as(?usize, 0), findFieldIndex(&fields, "a"));
    try testing.expectEqual(@as(?usize, 1), findFieldIndex(&fields, "b"));
    try testing.expectEqual(@as(?usize, null), findFieldIndex(&fields, "missing"));
}

test "fieldTypeAltEqual: struct_t/interface_t/named_t/variant_t compare by name" {
    try testing.expect(fieldTypeAltEqual(.{ .typ = .struct_t, .struct_name = "Foo" }, .{ .typ = .struct_t, .struct_name = "Foo" }));
    try testing.expect(!fieldTypeAltEqual(.{ .typ = .struct_t, .struct_name = "Foo" }, .{ .typ = .struct_t, .struct_name = "Bar" }));

    try testing.expect(fieldTypeAltEqual(.{ .typ = .interface_t, .interface_name = "Shape" }, .{ .typ = .interface_t, .interface_name = "Shape" }));
    try testing.expect(!fieldTypeAltEqual(.{ .typ = .interface_t, .interface_name = "Shape" }, .{ .typ = .interface_t, .interface_name = "Other" }));

    try testing.expect(fieldTypeAltEqual(.{ .typ = .named_t, .named_name = "UserId" }, .{ .typ = .named_t, .named_name = "UserId" }));
    try testing.expect(!fieldTypeAltEqual(.{ .typ = .named_t, .named_name = "UserId" }, .{ .typ = .named_t, .named_name = "OrderId" }));

    try testing.expect(fieldTypeAltEqual(.{ .typ = .variant_t, .named_name = "Shape" }, .{ .typ = .variant_t, .named_name = "Shape" }));

    // Different tags are never equal even with matching names.
    try testing.expect(!fieldTypeAltEqual(.{ .typ = .struct_t, .struct_name = "Foo" }, .{ .typ = .interface_t, .interface_name = "Foo" }));
}

test "fieldTypeAltEqual: array/map alts compare nested elem/key/val specs, including null-vs-null and null-vs-some" {
    const int_spec = scalarSpec(.int);
    const str_spec = scalarSpec(.string);

    try testing.expect(fieldTypeAltEqual(.{ .typ = .array, .elem_spec = null }, .{ .typ = .array, .elem_spec = null }));
    try testing.expect(!fieldTypeAltEqual(.{ .typ = .array, .elem_spec = null }, .{ .typ = .array, .elem_spec = int_spec }));
    try testing.expect(fieldTypeAltEqual(.{ .typ = .array, .elem_spec = int_spec }, .{ .typ = .array, .elem_spec = int_spec }));
    try testing.expect(!fieldTypeAltEqual(.{ .typ = .array, .elem_spec = int_spec }, .{ .typ = .array, .elem_spec = str_spec }));

    try testing.expect(fieldTypeAltEqual(
        .{ .typ = .map, .key_spec = str_spec, .val_spec = int_spec },
        .{ .typ = .map, .key_spec = str_spec, .val_spec = int_spec },
    ));
    try testing.expect(!fieldTypeAltEqual(
        .{ .typ = .map, .key_spec = str_spec, .val_spec = int_spec },
        .{ .typ = .map, .key_spec = str_spec, .val_spec = str_spec },
    ));
    try testing.expect(!fieldTypeAltEqual(
        .{ .typ = .map, .key_spec = null, .val_spec = int_spec },
        .{ .typ = .map, .key_spec = str_spec, .val_spec = int_spec },
    ));
}

test "fieldTypeAltEqual: func_t alts compare param/return list lengths and element types" {
    const int_spec = scalarSpec(.int);
    const str_spec = scalarSpec(.string);
    const params_a = [_]FieldTypeSpec{int_spec};
    const params_b = [_]FieldTypeSpec{str_spec};
    const returns_a = [_]FieldTypeSpec{int_spec};

    try testing.expect(fieldTypeAltEqual(
        .{ .typ = .func_t, .func_params = &params_a, .func_returns = &returns_a },
        .{ .typ = .func_t, .func_params = &params_a, .func_returns = &returns_a },
    ));
    try testing.expect(!fieldTypeAltEqual(
        .{ .typ = .func_t, .func_params = &params_a, .func_returns = &returns_a },
        .{ .typ = .func_t, .func_params = &params_b, .func_returns = &returns_a },
    ));
    try testing.expect(!fieldTypeAltEqual(
        .{ .typ = .func_t, .func_params = &params_a, .func_returns = &returns_a },
        .{ .typ = .func_t, .func_params = &[_]FieldTypeSpec{}, .func_returns = &returns_a },
    ));
    try testing.expect(fieldTypeAltEqual(
        .{ .typ = .func_t, .func_params = null, .func_returns = null },
        .{ .typ = .func_t, .func_params = null, .func_returns = null },
    ));
}

test "fieldTypeAltEqual: plain scalar alts (int/string/etc.) compare by tag alone" {
    try testing.expect(fieldTypeAltEqual(scalarAlt(.int), scalarAlt(.int)));
    try testing.expect(!fieldTypeAltEqual(scalarAlt(.int), scalarAlt(.string)));
    try testing.expect(fieldTypeAltEqual(scalarAlt(.boolean), scalarAlt(.boolean)));
}

test "fieldTypeSpecEqual: alt-count and per-alt comparison" {
    const one_int = scalarSpec(.int);
    const one_int_2 = scalarSpec(.int);
    try testing.expect(fieldTypeSpecEqual(one_int, one_int_2));

    const two_alts = FieldTypeSpec{ .alts = @constCast(&[_]FieldTypeAlt{ scalarAlt(.int), scalarAlt(.string) }) };
    try testing.expect(!fieldTypeSpecEqual(one_int, two_alts));

    const one_string = scalarSpec(.string);
    try testing.expect(!fieldTypeSpecEqual(one_int, one_string));
}

test "interfaceMethodMatches: matching signature, arity mismatch, variadic mismatch, and struct-receiver implicit first param" {
    const int_spec = scalarSpec(.int);
    const str_spec = scalarSpec(.string);

    const method = InterfaceMethodSpec{
        .name = "greet",
        .arity = 1,
        .is_variadic = false,
        .variadic_type = scalarSpec(.any),
        .param_types = @constCast(&[_]FieldTypeSpec{str_spec}),
        .return_types = @constCast(&[_]FieldTypeSpec{int_spec}),
        .has_typed_params = true,
        .has_typed_returns = true,
    };

    const matching_fn = FuncObj{
        .ip = 0,
        .arity = 1,
        .is_variadic = false,
        .variadic_type = scalarSpec(.any),
        .capture_slots = &.{},
        .param_types = @constCast(&[_]FieldTypeSpec{str_spec}),
        .has_typed_params = true,
        .return_types = @constCast(&[_]FieldTypeSpec{int_spec}),
        .has_typed_returns = true,
    };
    try testing.expect(interfaceMethodMatches(method, matching_fn));

    var arity_mismatch_fn = matching_fn;
    arity_mismatch_fn.arity = 3;
    arity_mismatch_fn.param_types = @constCast(&[_]FieldTypeSpec{ str_spec, int_spec, int_spec });
    try testing.expect(!interfaceMethodMatches(method, arity_mismatch_fn));

    var variadic_mismatch_fn = matching_fn;
    variadic_mismatch_fn.is_variadic = true;
    try testing.expect(!interfaceMethodMatches(method, variadic_mismatch_fn));

    // Struct receiver: f.arity == m.arity + 1 with one extra leading param
    // (the implicit receiver), skipped via f_param_start = 1.
    const receiver_fn = FuncObj{
        .ip = 0,
        .arity = 2,
        .is_variadic = false,
        .variadic_type = scalarSpec(.any),
        .capture_slots = &.{},
        .param_types = @constCast(&[_]FieldTypeSpec{ scalarSpec(.struct_t), str_spec }),
        .has_typed_params = true,
        .return_types = @constCast(&[_]FieldTypeSpec{int_spec}),
        .has_typed_returns = true,
    };
    try testing.expect(interfaceMethodMatches(method, receiver_fn));
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
