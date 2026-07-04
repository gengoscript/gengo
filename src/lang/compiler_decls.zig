const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const chunk = @import("chunk.zig");
const Op = @import("op.zig").Op;
const FuncType = @import("op.zig").FuncType;
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");
const ct = @import("compiler_types.zig");
const std_schema = @import("std_schema.zig");

const Token = token.Token;
const TT = token.TT;
const MaxLocals = ct.MaxLocals;
const Prec = ct.Prec;
const TypeCheck = ct.TypeCheck;
const FuncInfo = ct.FuncInfo;
const AssignTarget = ct.AssignTarget;
const AssignTargetStep = ct.AssignTargetStep;
const MaxSwitchJumps = ct.MaxSwitchJumps;
const MultiAssignValueScratch = ct.MultiAssignValueScratch;
const FieldTypeAlt = value_mod.FieldTypeAlt;
const FieldTypeSpec = value_mod.FieldTypeSpec;
const FieldTypeTag = value_mod.FieldTypeTag;
const StructFieldSpec = value_mod.StructFieldSpec;
const InterfaceMethodSpec = value_mod.InterfaceMethodSpec;
const NamedTypeObj = value_mod.NamedTypeObj;
const NamedTypeBase = value_mod.NamedTypeBase;
const VariantArmSpec = value_mod.VariantArmSpec;
const VariantTypeObj = value_mod.VariantTypeObj;
const Object = value_mod.Object;
const MaxTypeAlts = ct.MaxTypeAlts;
const MaxScopes = ct.MaxScopes;
const StructTypeObj = value_mod.StructTypeObj;
const InterfaceTypeObj = value_mod.InterfaceTypeObj;

pub fn emitZeroValue(c: anytype, tc: TypeCheck, line: u32) !void {
    switch (tc) {
        .none => try c.cs.emitOp(.null_val, line),
        .prim => |p| switch (p) {
            .int => try c.cs.emitConst(.{ .int = 0.0 }, line),
            .float => try c.cs.emitConst(.{ .float = 0.0 }, line),
            .decimal => try c.cs.emitConst(.{ .decimal = 0 }, line),
            .bool => try c.cs.emitOp(.false_val, line),
            .string => try c.cs.emitStringConst("", line),
            .rune => try c.cs.emitConst(.{ .rune = 0 }, line),
            .bigint => { try c.cs.emitConst(.{ .int = 0.0 }, line); try c.cs.emitOp(.cast_bigint, line); },
        },
        .assert_arr => try c.cs.emit2(@intFromEnum(Op.build_array), 0, line),
        .assert_map => try c.cs.emit2(@intFromEnum(Op.build_map), 0, line),
        .assert_err => try c.cs.emitOp(.null_val, line),
        .named => {
            try emitNamedDefault(c, tc.named, line);
            try c.cs.emitGetGlobal(tc.named, line);
            try c.cs.emitCall(1, line);
        },
        .interface_type => try c.cs.emitOp(.null_val, line),
        .struct_type => |qname| {
            try c.cs.emitGetGlobal(qname, line);
            try c.cs.emitOp(.zero_struct, line);
        },
        .anon_typed => |idx| {
            const type_obj = c.cs.consts[idx].object;
            const is_map = type_obj.named_type.base == .map_t;
            try c.cs.emitConstIdx(.constant, idx, line);
            if (is_map) {
                try c.cs.emit2(@intFromEnum(Op.build_map), 0, line);
            } else {
                try c.cs.emit2(@intFromEnum(Op.build_array), 0, line);
            }
            try c.cs.emitCall(1, line);
        },
    }
}

pub fn emitNamedDefault(c: anytype, name: []const u8, line: u32) !void {
    const type_info = c.registry.getNamedTypeInfo(name) orelse {
        try c.cs.emitOp(.null_val, line);
        return;
    };
    if (type_info.has_default) {
        switch (type_info.base) {
            .int, .float, .rune, .decimal => {
                try c.cs.emitConst(.{ .float = type_info.default_val.float }, line);
            },
            .string => {
                try c.cs.emitConst(.{ .string = type_info.default_val.string }, line);
            },
            .bool => {
                if (type_info.default_val.boolean) {
                    try c.cs.emitOp(.true_val, line);
                } else {
                    try c.cs.emitOp(.false_val, line);
                }
            },
            .array_t => try c.cs.emit2(@intFromEnum(Op.build_array), 0, line),
            .map_t => try c.cs.emit2(@intFromEnum(Op.build_map), 0, line),
            .enum_t => try c.cs.emitOp(.null_val, line),
        }
    } else {
        switch (type_info.base) {
            .int => try c.cs.emitConst(.{ .int = 0 }, line),
            .float => try c.cs.emitConst(.{ .float = 0 }, line),
            .decimal => try c.cs.emitConst(.{ .decimal = 0 }, line),
            .string => try c.cs.emitStringConst("", line),
            .rune => try c.cs.emitConst(.{ .rune = 0 }, line),
            .bool => try c.cs.emitOp(.false_val, line),
            .array_t => try c.cs.emit2(@intFromEnum(Op.build_array), 0, line),
            .map_t => try c.cs.emit2(@intFromEnum(Op.build_map), 0, line),
            .enum_t => try c.cs.emitOp(.null_val, line),
        }
    }
}

pub fn interfaceDeclBody(c: anytype, kw: Token, name: Token, is_pub: bool) !void {
    if (!c.skipping_test_body and !c.inFunc()) {
        if (c.registry.hasInterfaceType(name.src)) {
            c.setErr("duplicate interface name '{s}'", .{name.src});
            return error.DuplicateInterfaceType;
        }
        if (c.registry.hasAnyTypeName(name.src)) {
            c.setErr("type name '{s}' conflicts with an existing type declaration", .{name.src});
            return error.DuplicateNamedType;
        }
        if (c.registry.hasGlobalFunc(try c.qualifyTypeName(name.src))) {
            c.setErr("name '{s}' already declared as a function", .{name.src});
            return error.DuplicateField;
        }
    }
    if (!c.skipping_test_body) try c.registry.addInterfaceType(name.src);
    try c.consume(.lbrace);

    var methods_tmp: [MaxLocals]InterfaceMethodSpec = undefined;
    var mcount: u8 = 0;
    while (!c.check(.rbrace)) {
        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
        if (mcount >= MaxLocals) { c.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
        const mname = try c.copyName(c.cur.src);
        for (methods_tmp[0..mcount]) |m| {
            if (common.streq(m.name, mname)) {
                c.setErr("duplicate method '{s}' in interface", .{mname});
                return error.DuplicateField;
            }
        }
        c.advance();
        try c.consume(.lparen);

        var ptypes_tmp: [MaxLocals]FieldTypeSpec = undefined;
        var arity: u8 = 0;
        var is_variadic = false;
        var variadic_type: FieldTypeSpec = undefined;
        var has_typed_params = false;
        const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        any_alts[0] = .{ .typ = .any };
        const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };
        variadic_type = any_spec;
        if (!c.check(.rparen)) {
            while (true) {
                const vari = c.match(.ellipsis);
                // Parameter names in an interface spec are documentation only
                // (there is no body), so the bare-type form is allowed too:
                // add(float) float. An ident followed by a type-start token is
                // a name; an ident followed by ',' or ')' is the type itself.
                if (c.cur.typ == .ident) {
                    const after = c.peekToken();
                    if (after.typ == .question or after.typ == .ident or after.typ == .kw_func or after.typ == .lbracket) {
                        if (c.isKnownTypeName(c.cur.src))
                            return c.err("'{s}' is a type name and cannot be used as a parameter name", .{c.cur.src});
                        c.advance(); // param name
                    }
                } else if (c.cur.typ != .question and c.cur.typ != .kw_func and c.cur.typ != .lbracket) {
                    c.setErr("expected type annotation, found {s}", .{c.tokenName(c.cur.typ)});
                    return error.ExpectedTypeAnnotation;
                }
                const ptype: FieldTypeSpec = try parseFieldTypeSpec(c, );
                if (!(ptype.alts.len == 1 and ptype.alts[0].typ == .any)) has_typed_params = true;
                if (arity >= MaxLocals) { c.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
                ptypes_tmp[arity] = ptype;
                arity += 1;
                if (vari) {
                    is_variadic = true;
                    variadic_type = ptype;
                    break;
                }
                if (!c.match(.comma)) break;
                if (c.check(.rparen)) break;
            }
        }
        try c.consume(.rparen);

        var returns_tmp: [MaxLocals]FieldTypeSpec = undefined;
        var rcount: u8 = 0;
        var has_typed_returns = false;
        if (c.match(.lparen)) {
            while (true) {
                if (rcount >= MaxLocals) { c.setErr("too many return types (max {d})", .{MaxLocals}); return error.TooManyParams; }
                returns_tmp[rcount] = try parseFieldTypeSpec(c, );
                rcount += 1;
                has_typed_returns = true;
                if (!c.match(.comma)) break;
                if (c.check(.rparen)) break;
            }
            try c.consume(.rparen);
        } else if (c.cur.typ == .question or c.cur.typ == .ident or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
            returns_tmp[0] = try parseFieldTypeSpec(c, );
            rcount = 1;
            has_typed_returns = true;
        }

        const ptypes = heap.bump(FieldTypeSpec, arity) orelse return error.OutOfMemory;
        @memcpy(ptypes[0..arity], ptypes_tmp[0..arity]);
        const rtypes = heap.bump(FieldTypeSpec, rcount) orelse return error.OutOfMemory;
        @memcpy(rtypes[0..rcount], returns_tmp[0..rcount]);

        methods_tmp[mcount] = .{
            .name = mname,
            .arity = arity,
            .is_variadic = is_variadic,
            .variadic_type = variadic_type,
            .param_types = ptypes[0..arity],
            .return_types = rtypes[0..rcount],
            .has_typed_params = has_typed_params,
            .has_typed_returns = has_typed_returns,
        };
        mcount += 1;
        c.matchOpt(.comma);
    }
    try c.consume(.rbrace);
    const methods = heap.bump(InterfaceMethodSpec, mcount) orelse return error.OutOfMemory;
    @memcpy(methods[0..mcount], methods_tmp[0..mcount]);
    const qname = try c.qualifyTypeName(name.src);
    const it = heap.allocObject() orelse return error.OutOfMemory;
    it.* = .{ .interface_type = InterfaceTypeObj{ .name = try c.copyName(name.src), .qualified_name = qname, .methods = methods[0..mcount] } };
    try c.cs.emitConst(.{ .object = it }, kw.line);
    if (c.inFunc()) {
        _ = try c.defineLocal(name.src, false);
    } else {
        try c.cs.emitOpStringConst(.def_global, qname, kw.line);
        if (is_pub) try c.addExport(name.src, qname);
    }
    c.matchOpt(.semicolon);
}

pub fn isMethodDecl(c: anytype) bool {
    var lx = c.lex;
    const t1 = lx.next();
    if (t1.typ != .lparen) return false;
    const t2 = lx.next();
    if (t2.typ != .ident) return false;
    const t3 = lx.next();
    if (t3.typ != .ident) return false;
    const t4 = lx.next();
    if (t4.typ != .rparen) return false;
    const t5 = lx.next();
    if (t5.typ != .ident) return false;
    const t6 = lx.next();
    return t6.typ == .lparen;
}

pub fn isNamedFuncDecl(c: anytype) bool {
    var lx = c.lex;
    const t1 = lx.next();
    if (t1.typ != .ident) return false;
    const t2 = lx.next();
    return t2.typ == .lparen;
}

pub fn methodDecl(c: anytype) !void {
    const kw = c.cur;
    c.advance(); // func
    try c.consume(.lparen);
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const recv_name = c.cur.src;
    c.advance();
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const recv_type = c.cur.src;
    c.advance();
    if (c.registry.hasInterfaceType(recv_type)) { c.setErr("cannot define method on interface type '{s}'", .{recv_type}); return error.MethodOnInterface; }
    if (!c.skipping_test_body and !c.registry.hasStructType(recv_type) and !c.registry.hasNamedType(recv_type) and !c.registry.hasVariantType(recv_type)) {
        c.setErr("method receiver '{s}' is not a declared type", .{recv_type});
        return error.UnknownReceiverType;
    }
    try c.consume(.rparen);
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const method_name = c.cur.src;
    c.advance();

    var prefix: [1][]const u8 = .{recv_name};
    _ = try c.compileFuncWithPrefix(prefix[0..], true, null);

    const qrecv_type = try c.qualifyTypeName(recv_type);
    const total = qrecv_type.len + 1 + method_name.len;
    const key_buf = heap.bump(u8, total) orelse return error.OutOfMemory;
    @memcpy(key_buf[0..qrecv_type.len], qrecv_type);
    key_buf[qrecv_type.len] = '.';
    @memcpy(key_buf[qrecv_type.len + 1 .. total], method_name);
    const key = key_buf[0..total];
    if (c.last_func_obj) |fo| fo.function.name = key;

    if (c.inFunc()) {
        _ = try c.defineLocal(key, false);
    } else {
        if (!c.skipping_test_body) {
            if (c.registry.hasGlobalFunc(key)) {
                c.setErr("duplicate method '{s}'", .{method_name});
                return error.DuplicateField;
            }
            c.registry.addGlobalFunc(key) catch {
                c.setErr("too many global functions (limit {d})", .{ct.MaxGlobalFuncs});
                return error.TooManyGlobalFuncs;
            };
        }
        try c.cs.emitOpStringConst(.def_global, key, kw.line);
    }
    c.matchOpt(.semicolon);
}

pub fn namedFuncDecl(c: anytype, is_pub: bool) !void {
    const kw = c.cur;
    c.advance(); // consume 'func'
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const name = c.cur;
    if (c.isKnownTypeName(name.src))
        return c.err("'{s}' is a type name and cannot be used as a function name", .{name.src});
    c.advance(); // consume function name

    // current token is '('; compile as a named function for return-type enforcement
    _ = try c.compileFuncWithPrefix(&[_][]const u8{}, true, null);
    if (c.last_func_obj) |fo| fo.function.name = name.src;

    if (c.inFunc()) {
        _ = try c.defineLocal(name.src, false);
    } else {
        const qname = try c.qualifyGlobalName(name.src);
        if (!c.skipping_test_body) {
            if (c.registry.hasGlobalFunc(qname)) {
                c.setErr("duplicate function '{s}'", .{name.src});
                return error.DuplicateField;
            }
            c.registry.addGlobalFunc(qname) catch {
                c.setErr("too many global functions (limit {d})", .{ct.MaxGlobalFuncs});
                return error.TooManyGlobalFuncs;
            };
        }
        try c.cs.emitOpStringConst(.def_global, qname, kw.line);
        if (is_pub) try c.addExport(name.src, qname);
    }
    c.matchOpt(.semicolon);
}

pub fn namedTypeDecl(c: anytype, is_pub: bool) !void {
    const kw = c.cur;
    c.advance(); // type
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const name_tok = c.cur;
    c.advance(); // name
    if (c.match(.kw_struct)) return structDeclBody(c, kw, name_tok, is_pub);
    if (c.match(.kw_interface)) return interfaceDeclBody(c, kw, name_tok, is_pub);
    if (c.match(.kw_variant)) return variantDeclBody(c, kw, name_tok, is_pub);
    const name = name_tok.src;
    if (!c.skipping_test_body) {
        if (c.registry.hasNamedType(name)) { c.setErr("duplicate type name '{s}'", .{name}); return error.DuplicateNamedType; }
        if (!c.inFunc()) {
            if (c.registry.hasAnyTypeName(name)) {
                c.setErr("type name '{s}' conflicts with an existing type declaration", .{name});
                return error.DuplicateNamedType;
            }
            const _qn = try c.qualifyTypeName(name);
            if (c.registry.hasGlobalFunc(_qn)) {
                c.setErr("name '{s}' already declared as a function", .{name});
                return error.DuplicateField;
            }
        }
    }
    const qname = try c.qualifyTypeName(name);
    if (c.check(.kw_enum)) {
        c.advance();
        try c.consume(.lbrace);
        var members_tmp: [MaxLocals][]const u8 = undefined;
        var mints_tmp: [MaxLocals]i64 = undefined;
        var mcount: u8 = 0;
        var has_explicit_ints = false;
        var next_int: i64 = 0;
        if (!c.check(.rbrace)) {
            while (true) {
                if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
                if (mcount >= MaxLocals) { c.setErr("too many enum members (max {d})", .{MaxLocals}); return error.TooManyFields; }
                const mname = c.cur.src;
                for (members_tmp[0..mcount]) |m| {
                    if (common.streq(m, mname)) { c.setErr("duplicate member '{s}' in enum", .{mname}); return error.DuplicateField; }
                }
                members_tmp[mcount] = try c.copyName(mname);
                c.advance();
                if (c.match(.eq)) {
                    const v = try parseSignedNumber(c, );
                    next_int = @intFromFloat(v);
                    has_explicit_ints = true;
                }
                // Check for duplicate integer values
                for (mints_tmp[0..mcount]) |prev| {
                    if (prev == next_int) {
                        c.setErr("duplicate representation value {d} in enum '{s}'", .{ next_int, name });
                        return error.DuplicateField;
                    }
                }
                mints_tmp[mcount] = next_int;
                next_int += 1;
                mcount += 1;
                if (!c.match(.comma)) break;
                if (c.check(.rbrace)) break;
            }
        }
        try c.consume(.rbrace);
        const members = heap.bump([]const u8, mcount) orelse return error.OutOfMemory;
        @memcpy(members[0..mcount], members_tmp[0..mcount]);
        const member_ints: ?[]const i64 = if (has_explicit_ints) blk: {
            const mi = heap.bump(i64, mcount) orelse return error.OutOfMemory;
            @memcpy(mi[0..mcount], mints_tmp[0..mcount]);
            break :blk mi[0..mcount];
        } else null;
        if (!c.skipping_test_body) try c.registry.addNamedType(.{
            .name = name,
            .base = .enum_t,
            .has_range = false,
            .is_cycle = false,
            .min = 0,
            .max = 0,
            .enum_members = members[0..mcount],
        });
        const et = heap.allocObject() orelse return error.OutOfMemory;
        et.* = .{ .enum_type = .{ .name = try c.copyName(name), .qualified_name = qname, .members = members[0..mcount], .member_ints = member_ints } };
        try c.cs.emitConst(.{ .object = et }, kw.line);
        if (c.inFunc()) {
            _ = try c.defineLocal(name, false);
        } else {
            try c.cs.emitOpStringConst(.def_global, qname, kw.line);
            if (is_pub) try c.addExport(name, qname);
        }
        c.matchOpt(.semicolon);
        return;
    }

    if (c.cur.typ == .lbracket) {
        // type Name []T (named array) or type Name [K]V (named map) — shares
        // the same array/map disambiguation as struct fields and 'var'.
        const spec: FieldTypeSpec = try parseFieldTypeSpec(c, );
        if (spec.alts.len != 1 or (spec.alts[0].typ != .array and spec.alts[0].typ != .map)) {
            return c.err("expected an array ('[]T') or map ('[K]V') type", .{});
        }
        const alt = spec.alts[0];
        const nt = heap.allocObject() orelse return error.OutOfMemory;
        if (alt.typ == .array) {
            if (!c.skipping_test_body) try c.registry.addNamedType(.{ .name = name, .base = .array_t, .elem_spec = alt.elem_spec });
            nt.* = .{ .named_type = NamedTypeObj{ .name = try c.copyName(name), .qualified_name = qname, .base = .array_t, .elem_spec = alt.elem_spec } };
        } else {
            if (!c.skipping_test_body) try c.registry.addNamedType(.{ .name = name, .base = .map_t, .key_spec = alt.key_spec, .val_spec = alt.val_spec });
            nt.* = .{ .named_type = NamedTypeObj{ .name = try c.copyName(name), .qualified_name = qname, .base = .map_t, .key_spec = alt.key_spec, .val_spec = alt.val_spec } };
        }
        try c.cs.emitConst(.{ .object = nt }, kw.line);
        if (c.inFunc()) {
            _ = try c.defineLocal(name, false);
        } else {
            try c.cs.emitOpStringConst(.def_global, qname, kw.line);
            if (is_pub) try c.addExport(name, qname);
        }
        c.matchOpt(.semicolon);
        return;
    }

    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const base_name = c.cur.src;
    c.advance();

    var base: NamedTypeBase = undefined;
    var parent_has_range = false;
    var parent_is_cycle = false;
    var parent_min: f64 = 0;
    var parent_max: f64 = 0;
    var parent_name_str: ?[]const u8 = null;
    var parent_elem_spec: ?FieldTypeSpec = null;
    var parent_key_spec: ?FieldTypeSpec = null;
    var parent_val_spec: ?FieldTypeSpec = null;
    var parent_scale: u8 = 0;
    var is_primitive_base = false;
    if (common.streq(base_name, "int")) {
        base = .int;
        is_primitive_base = true;
    } else if (common.streq(base_name, "float")) {
        base = .float;
        is_primitive_base = true;
    } else if (common.streq(base_name, "decimal")) {
        base = .decimal;
        is_primitive_base = true;
    } else if (common.streq(base_name, "string")) {
        base = .string;
        is_primitive_base = true;
    } else if (common.streq(base_name, "bool")) {
        base = .bool;
        is_primitive_base = true;
    } else if (common.streq(base_name, "rune")) {
        base = .rune;
        is_primitive_base = true;
    } else if (common.streq(base_name, "array")) {
        return c.err("use '[]T' syntax for array types", .{});
    } else if (common.streq(base_name, "map")) {
        try c.consume(.lbracket);
        const ks = try parseFieldTypeSpec(c, );
        try c.consume(.rbracket);
        const vs = try parseFieldTypeSpec(c, );
        if (!c.skipping_test_body) try c.registry.addNamedType(.{ .name = name, .base = .map_t, .key_spec = ks, .val_spec = vs });
        const nt = heap.allocObject() orelse return error.OutOfMemory;
        nt.* = .{ .named_type = NamedTypeObj{ .name = try c.copyName(name), .qualified_name = qname, .base = .map_t, .key_spec = ks, .val_spec = vs } };
        try c.cs.emitConst(.{ .object = nt }, kw.line);
        if (c.inFunc()) {
            _ = try c.defineLocal(name, false);
        } else {
            try c.cs.emitOpStringConst(.def_global, qname, kw.line);
            if (is_pub) try c.addExport(name, qname);
        }
        c.matchOpt(.semicolon);
        return;
    } else if (c.registry.getNamedTypeInfo(base_name)) |parent| {
        // #80: enum aliasing is incoherent — the alias would produce a named_type
        // with base=enum_t but no members, which the runtime refuses to construct.
        if (parent.base == .enum_t) {
            return c.err("cannot alias enum type '{s}'; declare a new enum with 'type {s} enum {{ ... }}'", .{ base_name, name });
        }
        base = parent.base;
        parent_has_range = parent.has_range;
        parent_is_cycle = parent.is_cycle;
        parent_min = parent.min;
        parent_max = parent.max;
        parent_name_str = base_name;          // #78: preserve parent chain
        parent_scale = parent.scale;           // #79: inherit decimal scale
        parent_elem_spec = parent.elem_spec;   // #76: inherit collection specs
        parent_key_spec = parent.key_spec;
        parent_val_spec = parent.val_spec;
    } else return c.err("unknown type '{s}'", .{base_name});

    var scale: u8 = parent_scale;
    if (base == .decimal) {
        if (is_primitive_base) {
            // Direct primitive base: require explicit scale.
            if (c.cur.typ != .number) return c.err("decimal type requires a scale (e.g., decimal 2)", .{});
            const scale_val = common.parseFloat(c.cur.src) orelse return c.err("decimal scale must be a number", .{});
            if (scale_val < 0 or scale_val > 18 or @trunc(scale_val) != scale_val) return c.err("decimal scale must be an integer between 0 and 18", .{});
            scale = @intFromFloat(scale_val);
            c.advance();
        } else if (c.cur.typ == .number) {
            // Named-type alias: scale is inherited from parent; an explicit number overrides.
            const scale_val = common.parseFloat(c.cur.src) orelse return c.err("decimal scale must be a number", .{});
            if (scale_val < 0 or scale_val > 18 or @trunc(scale_val) != scale_val) return c.err("decimal scale must be an integer between 0 and 18", .{});
            scale = @intFromFloat(scale_val);
            c.advance();
        }
    }

    var has_range = false;
    var is_cycle = false;
    var min: f64 = 0;
    var max: f64 = 0;
    if (c.check(.kw_range) or c.check(.kw_cycle)) {
        if (base != .int and base != .float and base != .decimal and base != .rune)
            return c.err("range and cycle constraints require a numeric parent type (int, float, decimal, or rune)", .{});
        const constraint = try parseConstraintBounds(c, );
        if (constraint.is_cycle and base != .int and base != .float and base != .decimal)
            return c.err("'cycle' constraint requires a numeric base type (int, float, or decimal)", .{});
        has_range = true;
        is_cycle = constraint.is_cycle;
        min = constraint.min;
        max = constraint.max;
    }
    if (parent_has_range) {
        if (has_range) {
            if (min < parent_min or max > parent_max) return error.RangeError;
        } else {
            has_range = true;
            is_cycle = parent_is_cycle;
            min = parent_min;
            max = parent_max;
        }
    }

    var predicate_obj: ?*Object = null;
    var predicate_uv_count: u8 = 0;
    var predicate_msg: ?[]const u8 = null;

    if (c.match(.kw_predicate)) {
        if (base == .array_t or base == .map_t or base == .enum_t) {
            return c.err("predicate not supported for collection or enum types", .{});
        }
        try c.consume(.kw_func);
        predicate_uv_count = try c.compileFuncWithPrefix(&[_][]const u8{}, false, base);
        const func_obj = c.last_func_obj orelse return error.NotAFunction;
        if (predicate_uv_count == 0) {
            const cl = heap.allocObject() orelse return error.OutOfMemory;
            cl.* = .{ .closure = .{ .func = func_obj, .upvalues = &[_]*Object{} } };
            predicate_obj = cl;
        } else {
            const cidx: u16 = try c.cs.addConst(.{ .object = func_obj });
            try c.cs.emitConstIdx(.make_closure, cidx, c.prev.line);
        }
        if (c.match(.kw_message)) {
            if (c.cur.typ != .string) return c.err("expected string literal after 'message'", .{});
            predicate_msg = try c.copyName(c.cur.src);
            c.advance();
        }
    }

    var has_default = false;
    var default_val: value_mod.Value = undefined;
    if (c.match(.kw_default)) {
        switch (base) {
            .int, .float, .rune, .decimal => {
                if (c.cur.typ != .number) return c.err("expected number after 'default'", .{});
                default_val = .{ .float = common.parseFloat(c.cur.src) orelse return c.err("invalid number literal", .{}) };
                c.advance();
            },
            .string => {
                if (c.cur.typ != .string) return c.err("expected string literal after 'default'", .{});
                default_val = .{ .string = try c.cs.internStr(try c.copyName(c.cur.src)) };
                c.advance();
            },
            .bool => {
                if (c.match(.kw_true)) {
                    default_val = .{ .boolean = true };
                } else if (c.match(.kw_false)) {
                    default_val = .{ .boolean = false };
                } else {
                    return c.err("expected true or false after 'default'", .{});
                }
            },
            else => return c.err("'default' not supported for this base type", .{}),
        }
        has_default = true;
    }

    // Validate default value against range at compile time
    if (has_range and has_default) {
        const df = default_val.float;
        if (df < min or df > max) {
            c.setErr("type '{s}': default value {d} is outside range {d}..{d}", .{ name, df, min, max });
            return error.RangeError;
        }
    }

    if (!c.skipping_test_body) try c.registry.addNamedType(.{
        .name = name,
        .base = base,
        .has_range = has_range,
        .is_cycle = is_cycle,
        .scale = scale,
        .min = min,
        .max = max,
        .parent_name = parent_name_str,
        .predicate_msg = predicate_msg,
        .elem_spec = parent_elem_spec,
        .key_spec = parent_key_spec,
        .val_spec = parent_val_spec,
        .has_default = has_default,
        .default_val = default_val,
    });

    const qparent_name: ?[]const u8 = if (parent_name_str) |pn|
        try c.qualifyTypeName(pn)
    else
        null;
    const nt = heap.allocObject() orelse return error.OutOfMemory;
    nt.* = .{ .named_type = NamedTypeObj{
        .name = try c.copyName(name),
        .qualified_name = qname,
        .scale = scale,
        .base = base,
        .has_range = has_range,
        .is_cycle = is_cycle,
        .min = min,
        .max = max,
        .parent_name = qparent_name,
        .predicate = predicate_obj,
        .predicate_msg = predicate_msg,
        .elem_spec = parent_elem_spec,
        .key_spec = parent_key_spec,
        .val_spec = parent_val_spec,
        .has_default = has_default,
        .default_val = default_val,
    } };
    try c.cs.emitConst(.{ .object = nt }, kw.line);
    if (predicate_uv_count > 0) {
        try c.cs.emitOp(.set_named_predicate, kw.line);
    }
    if (has_default and predicate_obj != null) {
        try c.cs.emitOp(.validate_type_default, kw.line);
    }
    if (c.inFunc()) {
        _ = try c.defineLocal(name, false);
    } else {
        try c.cs.emitOpStringConst(.def_global, qname, kw.line);
        if (is_pub) try c.addExport(name, qname);
    }
    c.matchOpt(.semicolon);
}

pub fn parseConstraintBounds(c: anytype) !struct { is_cycle: bool, min: f64, max: f64 } {
    const is_cycle = if (c.match(.kw_range))
        false
    else if (c.match(.kw_cycle))
        true
    else
        return c.err("expected 'range' or 'cycle', found {s}", .{c.tokenName(c.cur.typ)});
    const min = try parseSignedNumber(c, );
    try c.consume(.dotdot);
    const max = try parseSignedNumber(c, );
    if (min > max) {
        c.setErr("range minimum ({d}) must not exceed maximum ({d})", .{ min, max });
        return error.RangeError;
    }
    return .{ .is_cycle = is_cycle, .min = min, .max = max };
}

pub fn parseFieldTypeSpec(c: anytype) !FieldTypeSpec {
    var tmp: [MaxTypeAlts]FieldTypeAlt = undefined;
    var count: u8 = 0;

    if (c.match(.question)) {
        if (count >= MaxTypeAlts) { c.setErr("too many type alternatives (max {d})", .{MaxTypeAlts}); return error.TooManyTypeAlternatives; }
        tmp[count] = .{ .typ = .null_t };
        count += 1;
    }

    var alt: FieldTypeAlt = undefined;
    if (c.cur.typ == .lbracket) {
        c.advance(); // consume '['
        if (c.check(.rbracket)) {
            // SliceType: []T
            c.advance(); // consume ']'
            const es = try parseFieldTypeSpec(c, );
            const ep = heap.bump(FieldTypeSpec, 1) orelse return error.OutOfMemory;
            ep[0] = es;
            alt = .{ .typ = .array, .elem_spec = ep[0] };
        } else {
            // [K]V map — a bare '[T]' with nothing after the ']' is
            // rejected rather than silently treated as an array: that
            // shape is what a forgotten map value type looks like, and
            // letting it quietly mean "array of T" instead would mask
            // exactly that mistake. Arrays are written '[]T'.
            const first_spec = try parseFieldTypeSpec(c, );
            try c.consume(.rbracket);
            if (!(c.cur.typ == .ident or c.cur.typ == .kw_func or c.cur.typ == .lbracket or c.cur.typ == .question)) {
                c.setErr("expected a value type after '[...]' — write 'map[K]V' for a map, or '[]T' for an array", .{});
                return error.ExpectedTypeName;
            }
            const second_spec = try parseFieldTypeSpec(c, );
            const kp = heap.bump(FieldTypeSpec, 1) orelse return error.OutOfMemory;
            kp[0] = first_spec;
            const vp = heap.bump(FieldTypeSpec, 1) orelse return error.OutOfMemory;
            vp[0] = second_spec;
            alt = .{ .typ = .map, .key_spec = kp[0], .val_spec = vp[0] };
        }
    } else if (c.cur.typ == .kw_func) {
        c.advance(); // consume 'func'
        try c.consume(.lparen);
        var func_params_tmp: [MaxLocals]FieldTypeSpec = undefined;
        var func_param_count: u8 = 0;
        if (!c.check(.rparen)) {
            while (true) {
                if (func_param_count >= MaxLocals) { c.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
                func_params_tmp[func_param_count] = try parseFieldTypeSpec(c, );
                func_param_count += 1;
                if (!c.match(.comma)) break;
                if (c.check(.rparen)) break;
            }
        }
        try c.consume(.rparen);
        var func_returns_tmp: [MaxLocals]FieldTypeSpec = undefined;
        var func_return_count: u8 = 0;
        if (c.match(.lparen)) {
            while (true) {
                if (func_return_count >= MaxLocals) { c.setErr("too many parameters (max {d})", .{MaxLocals}); return error.TooManyParams; }
                func_returns_tmp[func_return_count] = try parseFieldTypeSpec(c, );
                func_return_count += 1;
                if (!c.match(.comma)) break;
                if (c.check(.rparen)) break;
            }
            try c.consume(.rparen);
        } else if (c.cur.typ == .question or c.cur.typ == .ident or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
            func_returns_tmp[0] = try parseFieldTypeSpec(c, );
            func_return_count = 1;
        }
        const fp = if (func_param_count > 0) blk: {
            const ps = heap.bump(FieldTypeSpec, func_param_count) orelse return error.OutOfMemory;
            @memcpy(ps[0..func_param_count], func_params_tmp[0..func_param_count]);
            break :blk ps[0..func_param_count];
        } else @as([]FieldTypeSpec, &.{});
        const fr = if (func_return_count > 0) blk: {
            const rs = heap.bump(FieldTypeSpec, func_return_count) orelse return error.OutOfMemory;
            @memcpy(rs[0..func_return_count], func_returns_tmp[0..func_return_count]);
            break :blk rs[0..func_return_count];
        } else @as([]FieldTypeSpec, &.{});
        alt = .{ .typ = .func_t, .func_params = fp, .func_returns = fr };
    } else {
        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
        const tname = c.cur.src;
        c.advance();

        // Handle `alias.TypeName` — module-qualified type annotations.
        if (c.cur.typ == .dot) {
            if (c.resolveImportAliasPath(tname)) |mod_path| {
                c.advance(); // consume '.'
                if (c.cur.typ != .ident) return c.err("expected type name after '.', found {s}", .{c.tokenName(c.cur.typ)});
                const type_name = c.cur.src;
                c.advance();
                if (c.resolveModuleTypeName(mod_path, type_name)) |kind| {
                    // Qualified name: "@mod:PATH.TypeName" — matches how the module compiler registers types.
                    const prefix_len = "@mod:".len + mod_path.len;
                    const qname_len = prefix_len + 1 + type_name.len;
                    const qname_buf = heap.bump(u8, qname_len) orelse return error.OutOfMemory;
                    @memcpy(qname_buf[0.."@mod:".len], "@mod:");
                    @memcpy(qname_buf["@mod:".len..prefix_len], mod_path);
                    qname_buf[prefix_len] = '.';
                    @memcpy(qname_buf[prefix_len + 1 .. qname_len], type_name);
                    const qname = qname_buf[0..qname_len];
                    alt = switch (kind) {
                        .struct_t    => .{ .typ = .struct_t,    .struct_name    = qname },
                        .interface_t => .{ .typ = .interface_t, .interface_name = qname },
                        .named_t     => .{ .typ = .named_t,     .named_name     = qname },
                        .variant_t   => .{ .typ = .variant_t,   .named_name     = qname },
                        .func_or_var => return c.err("'{s}.{s}' is not a type", .{ tname, type_name }),
                    };
                } else if (!c.skipping_test_body) {
                    c.setErr("unknown type '{s}' in module '{s}'", .{ type_name, tname });
                    return error.UnknownType;
                }
            } else if (!c.skipping_test_body) {
                c.setErr("unknown type '{s}'", .{tname});
                return error.UnknownType;
            }
        } else {
        alt = .{ .typ = .struct_t, .struct_name = tname };
        if (common.streq(tname, "int")) {
            alt = .{ .typ = .int };
        } else if (common.streq(tname, "float")) {
            alt = .{ .typ = .float };
        } else if (common.streq(tname, "rune")) {
            alt = .{ .typ = .rune_t };
        } else if (common.streq(tname, "bool")) {
            alt = .{ .typ = .boolean };
        } else if (common.streq(tname, "string")) {
            alt = .{ .typ = .string };
        } else if (common.streq(tname, "error")) {
            alt = .{ .typ = .error_t };
        } else if (common.streq(tname, "bigint")) {
            alt = .{ .typ = .any };
        } else if (common.streq(tname, "array")) {
            return c.err("use '[]T' syntax for array types", .{});
        } else if (common.streq(tname, "map")) {
            var ks: ?FieldTypeSpec = null;
            var vs: ?FieldTypeSpec = null;
            if (c.match(.lbracket)) {
                ks = try parseFieldTypeSpec(c, );
                try c.consume(.rbracket);
                vs = try parseFieldTypeSpec(c, );
            } else {
                return c.err("use 'map[K]V' syntax for map types", .{});
            }
            alt = .{ .typ = .map, .key_spec = ks, .val_spec = vs };
        } else if (c.registry.hasStructTypeLocal(tname)) {
            alt = .{ .typ = .struct_t, .struct_name = try c.qualifyTypeName(tname) };
        } else if (c.registry.hasInterfaceType(tname)) {
            alt = .{ .typ = .interface_t, .interface_name = try c.qualifyTypeName(tname) };
        } else if (c.registry.hasNamedType(tname)) {
            alt = .{ .typ = .named_t, .named_name = try c.qualifyTypeName(tname) };
        } else if (c.registry.hasVariantType(tname)) {
            alt = .{ .typ = .variant_t, .named_name = try c.qualifyTypeName(tname) };
        } else if (!c.skipping_test_body) {
            c.setErr("unknown type '{s}'", .{tname});
            return error.UnknownType;
        }
        } // end else (not dot)
    }

    if (count >= MaxTypeAlts) { c.setErr("too many type alternatives (max {d})", .{MaxTypeAlts}); return error.TooManyTypeAlternatives; }
    tmp[count] = alt;
    count += 1;

    const alts = heap.bump(FieldTypeAlt, count) orelse return error.OutOfMemory;
    @memcpy(alts[0..count], tmp[0..count]);
    return .{ .alts = alts[0..count] };
}

pub fn parseSignedNumber(c: anytype) !f64 {
    var sign: f64 = 1.0;
    if (c.match(.minus)) sign = -1.0;
    if (c.cur.typ != .number) return c.err("expected number, found {s}", .{c.tokenName(c.cur.typ)});
    const n = common.parseFloat(c.cur.src) orelse {
        c.setErr("invalid number literal '{s}'", .{c.cur.src});
        return error.BadNumber;
    };
    c.advance();
    return sign * n;
}

fn checkStructFieldType(c: anytype, spec: FieldTypeSpec, qself: []const u8, inside_ref: bool) !void {
    // A ?T spec contains a null_t alt — the actual type is heap-referenced (null or pointer),
    // so self-reference is safe.
    var is_nullable = false;
    for (spec.alts) |alt| {
        if (alt.typ == .null_t) { is_nullable = true; break; }
    }
    const ref_ctx = inside_ref or is_nullable;
    for (spec.alts) |alt| {
        switch (alt.typ) {
            .null_t => {},
            .struct_t => {
                if (common.streq(alt.struct_name, qself)) {
                    if (!ref_ctx) {
                        c.setErr("struct type '{s}' cannot reference itself directly; use '[]', '[K]V', or '?' to allow recursion", .{alt.struct_name});
                        return error.UnknownStructType;
                    }
                    return; // valid self-ref through a reference type
                }
                if (!c.isKnownLocalStructType(alt.struct_name)) {
                    c.setErr("unknown struct type '{s}'", .{alt.struct_name});
                    return error.UnknownStructType;
                }
            },
            .array => {
                if (alt.elem_spec) |es| try checkStructFieldType(c, es, qself, true);
            },
            .map => {
                if (alt.key_spec) |ks| try checkStructFieldType(c, ks, qself, true);
                if (alt.val_spec) |vs| try checkStructFieldType(c, vs, qself, true);
            },
            .func_t => {
                if (alt.func_params) |params| {
                    for (params) |param| try checkStructFieldType(c, param, qself, false);
                }
                if (alt.func_returns) |returns| {
                    for (returns) |ret| try checkStructFieldType(c, ret, qself, false);
                }
            },
            else => {},
        }
    }
}

pub fn structDeclBody(c: anytype, kw: Token, name: Token, is_pub: bool) !void {
    if (!c.skipping_test_body and !c.inFunc()) {
        if (c.registry.hasStructType(name.src)) {
            c.setErr("duplicate struct name '{s}'", .{name.src});
            return error.DuplicateStructType;
        }
        if (c.registry.hasAnyTypeName(name.src)) {
            c.setErr("type name '{s}' conflicts with an existing type declaration", .{name.src});
            return error.DuplicateNamedType;
        }
        if (c.registry.hasGlobalFunc(try c.qualifyTypeName(name.src))) {
            c.setErr("name '{s}' already declared as a function", .{name.src});
            return error.DuplicateField;
        }
    }
    if (!c.skipping_test_body) try c.registry.addStructType(name.src);
    try c.consume(.lbrace);

    var field_specs: [MaxLocals]StructFieldSpec = undefined;
    var count: u8 = 0;
    if (!c.check(.rbrace)) {
        while (true) {
            const field_is_const = c.match(.kw_const);
            if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
            if (count >= MaxLocals) { c.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
            const fname = try c.copyName(c.cur.src);
            for (field_specs[0..count]) |fs| {
                if (common.streq(fs.name, fname)) { c.setErr("duplicate field name '{s}'", .{fname}); return error.DuplicateField; }
            }
            c.advance();

            var spec = StructFieldSpec{ .name = fname, .typ = .{ .alts = &[_]FieldTypeAlt{} }, .is_const = field_is_const };
            if (c.cur.typ == .ident or c.cur.typ == .question or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
                // Space syntax: field type  (colon no longer used)
                spec.typ = try parseFieldTypeSpec(c, );
                if (!c.skipping_test_body) try checkStructFieldType(c, spec.typ, try c.qualifyTypeName(name.src), false);
            } else {
                return c.err("expected type annotation for struct field '{s}'", .{fname});
            }

            field_specs[count] = spec;
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);

    const fields = heap.bump(StructFieldSpec, count) orelse return error.OutOfMemory;
    @memcpy(fields[0..count], field_specs[0..count]);
    for (fields[0..count]) |*f| f.key = .{ .string = try c.cs.internStr(f.name) };
    const qname = try c.qualifyTypeName(name.src);
    const st = heap.allocObject() orelse return error.OutOfMemory;
    st.* = .{ .struct_type = StructTypeObj{ .name = try c.copyName(name.src), .qualified_name = qname, .fields = fields[0..count] } };
    try c.cs.emitConst(.{ .object = st }, kw.line);

    if (c.inFunc()) {
        _ = try c.defineLocal(name.src, false);
    } else {
        try c.cs.emitOpStringConst(.def_global, qname, kw.line);
        if (is_pub) try c.addExport(name.src, qname);
    }
    c.matchOpt(.semicolon);
}

pub fn subtypeDecl(c: anytype, is_pub: bool) !void {
    const kw = c.cur;
    c.advance(); // subtype
    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const name_tok = c.cur;
    c.advance(); // name
    const name = name_tok.src;

    if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
    const parent_name = c.cur.src;
    c.advance(); // parent name

    const parent_info = c.registry.getNamedTypeInfo(parent_name) orelse { c.setErr("unknown type '{s}'", .{parent_name}); return error.UnexpectedToken; };

    // Handle enum subtype: subtype Weekend_Days Days { Saturday, Sunday }
    if (parent_info.base == .enum_t) {
        if (c.registry.hasNamedType(name)) { c.setErr("duplicate type name '{s}'", .{name}); return error.DuplicateNamedType; }
        const qname = try c.qualifyTypeName(name);
        const qparent = try c.qualifyTypeName(parent_name);
        if (!c.check(.lbrace))
            return c.err("enum subtype requires a member subset: subtype {s} {s} {{ member, ... }}", .{ name, parent_name });
        try c.consume(.lbrace);
        var members_tmp: [MaxLocals][]const u8 = undefined;
        var mcount: u8 = 0;
        if (!c.check(.rbrace)) {
            while (true) {
                if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
                if (mcount >= MaxLocals) { c.setErr("too many enum members (max {d})", .{MaxLocals}); return error.TooManyFields; }
                const smname = c.cur.src;
                for (members_tmp[0..mcount]) |m| {
                    if (common.streq(m, smname)) { c.setErr("duplicate member '{s}' in enum subtype", .{smname}); return error.DuplicateField; }
                }
                members_tmp[mcount] = try c.copyName(smname);
                mcount += 1;
                c.advance();
                if (!c.match(.comma)) break;
                if (c.check(.rbrace)) break;
            }
        }
        try c.consume(.rbrace);
        const members = heap.bump([]const u8, mcount) orelse return error.OutOfMemory;
        @memcpy(members[0..mcount], members_tmp[0..mcount]);
        // Validate each member exists in the parent enum
        if (parent_info.enum_members) |parent_members| {
            for (members[0..mcount]) |m| {
                var found = false;
                for (parent_members) |pm| {
                    if (common.streq(m, pm)) { found = true; break; }
                }
                if (!found) {
                    c.setErr("'{s}' is not a member of {s}", .{ m, parent_name });
                    return error.UnexpectedToken;
                }
            }
        }
        if (!c.skipping_test_body) try c.registry.addNamedType(.{
            .name = name,
            .base = .enum_t,
            .parent_name = parent_name,
            .enum_members = members[0..mcount],
        });
        const et = heap.allocObject() orelse return error.OutOfMemory;
        et.* = .{ .enum_type = .{
            .name = try c.copyName(name),
            .qualified_name = qname,
            .members = members[0..mcount],
            .parent_name = qparent,
        } };
        try c.cs.emitConst(.{ .object = et }, kw.line);
        if (c.inFunc()) {
            _ = try c.defineLocal(name, false);
        } else {
            try c.cs.emitOpStringConst(.def_global, qname, kw.line);
            if (is_pub) try c.addExport(name, qname);
        }
        c.matchOpt(.semicolon);
        return;
    }

    if (!c.skipping_test_body and c.registry.hasNamedType(name)) { c.setErr("duplicate type name '{s}'", .{name}); return error.DuplicateNamedType; }

    const base = parent_info.base;
    var has_range = parent_info.has_range;
    var is_cycle = parent_info.is_cycle;
    var min: f64 = parent_info.min;
    var max: f64 = parent_info.max;
    const scale = parent_info.scale;
    const is_numeric = base == .int or base == .float or base == .rune or base == .decimal;
    const is_scalar = is_numeric or base == .string or base == .bool;
    if (!is_scalar)
        return c.err("subtype parent must be a scalar named type (int, float, decimal, string, bool, or rune base)", .{});

    if (c.check(.kw_range) or c.check(.kw_cycle)) {
        if (!is_numeric) return c.err("range and cycle constraints require a numeric parent type (int, float, decimal, or rune)", .{});
        const constraint = try parseConstraintBounds(c, );
        if (constraint.is_cycle and base != .int and base != .float and base != .decimal)
            return c.err("'cycle' constraint requires a numeric base type (int, float, or decimal)", .{});
        if (parent_info.has_range) {
            if (constraint.min < parent_info.min or constraint.max > parent_info.max) {
                c.setErr("range {d}..{d} exceeds parent type bounds {d}..{d}", .{ constraint.min, constraint.max, parent_info.min, parent_info.max });
                return error.RangeError;
            }
        }
        has_range = true;
        is_cycle = constraint.is_cycle;
        min = constraint.min;
        max = constraint.max;
    }

    var predicate_obj: ?*Object = null;
    var predicate_uv_count: u8 = 0;
    var predicate_msg: ?[]const u8 = null;

    if (c.match(.kw_predicate)) {
        if (base == .array_t or base == .map_t or base == .enum_t) {
            return c.err("predicate not supported for collection or enum types", .{});
        }
        try c.consume(.kw_func);
        predicate_uv_count = try c.compileFuncWithPrefix(&[_][]const u8{}, false, base);
        const func_obj = c.last_func_obj orelse return error.NotAFunction;
        if (predicate_uv_count == 0) {
            const cl = heap.allocObject() orelse return error.OutOfMemory;
            cl.* = .{ .closure = .{ .func = func_obj, .upvalues = &[_]*Object{} } };
            predicate_obj = cl;
        } else {
            const cidx: u16 = try c.cs.addConst(.{ .object = func_obj });
            try c.cs.emitConstIdx(.make_closure, cidx, c.prev.line);
        }
        if (c.match(.kw_message)) {
            if (c.cur.typ != .string) return c.err("expected string literal after 'message'", .{});
            predicate_msg = try c.copyName(c.cur.src);
            c.advance();
        }
    }

    var has_default = false;
    var default_val: value_mod.Value = undefined;
    if (c.match(.kw_default)) {
        switch (base) {
            .int, .float, .rune, .decimal => {
                if (c.cur.typ != .number) return c.err("expected number after 'default'", .{});
                default_val = .{ .float = common.parseFloat(c.cur.src) orelse return c.err("invalid number literal", .{}) };
                c.advance();
            },
            .string => {
                if (c.cur.typ != .string) return c.err("expected string literal after 'default'", .{});
                default_val = .{ .string = try c.cs.internStr(try c.copyName(c.cur.src)) };
                c.advance();
            },
            .bool => {
                if (c.match(.kw_true)) {
                    default_val = .{ .boolean = true };
                } else if (c.match(.kw_false)) {
                    default_val = .{ .boolean = false };
                } else {
                    return c.err("expected true or false after 'default'", .{});
                }
            },
            else => return c.err("'default' not supported for this base type", .{}),
        }
        has_default = true;
    }

    // Inherit parent's default if subtype doesn't declare its own
    if (!has_default and parent_info.has_default) {
        default_val = parent_info.default_val;
        has_default = true;
    }

    // Validate default against subtype range at compile time
    if (has_range and has_default) {
        const df = default_val.float;
        if (df < min or df > max) {
            c.setErr("subtype '{s}': default value {d} is outside range {d}..{d}", .{ name, df, min, max });
            return error.RangeError;
        }
    }

    if (!c.skipping_test_body) try c.registry.addNamedType(.{
        .name = name,
        .base = base,
        .has_range = has_range,
        .is_cycle = is_cycle,
        .scale = scale,
        .min = min,
        .max = max,
        .parent_name = parent_name,
        .predicate_msg = predicate_msg,
        .has_default = has_default,
        .default_val = default_val,
    });

    const qname = try c.qualifyTypeName(name);
    const qparent = try c.qualifyTypeName(parent_name);
    const nt = heap.allocObject() orelse return error.OutOfMemory;
    nt.* = .{ .named_type = NamedTypeObj{
        .name = try c.copyName(name),
        .qualified_name = qname,
        .base = base,
        .has_range = has_range,
        .is_cycle = is_cycle,
        .scale = scale,
        .min = min,
        .max = max,
        .parent_name = qparent,
        .predicate = predicate_obj,
        .predicate_msg = predicate_msg,
        .has_default = has_default,
        .default_val = default_val,
    } };
    try c.cs.emitConst(.{ .object = nt }, kw.line);
    if (predicate_uv_count > 0) {
        try c.cs.emitOp(.set_named_predicate, kw.line);
    }
    if (has_default and predicate_obj != null) {
        try c.cs.emitOp(.validate_type_default, kw.line);
    }
    if (c.inFunc()) {
        _ = try c.defineLocal(name, false);
    } else {
        try c.cs.emitOpStringConst(.def_global, qname, kw.line);
        if (is_pub) try c.addExport(name, qname);
    }
    c.matchOpt(.semicolon);
}

pub fn variantDeclBody(c: anytype, kw: Token, name_tok: Token, is_pub: bool) !void {
    const name = name_tok.src;
    if (!c.skipping_test_body) {
        if (c.registry.hasVariantType(name)) { c.setErr("duplicate variant type name '{s}'", .{name}); return error.DuplicateVariantType; }
        if (!c.inFunc()) {
            if (c.registry.hasAnyTypeName(name)) {
                c.setErr("type name '{s}' conflicts with an existing type declaration", .{name});
                return error.DuplicateVariantType;
            }
            if (c.registry.hasGlobalFunc(try c.qualifyTypeName(name))) {
                c.setErr("name '{s}' already declared as a function", .{name});
                return error.DuplicateField;
            }
        }
        try c.registry.addVariantType(name);
    }
    try c.consume(.lbrace);

    var shared_tmp: [MaxLocals]StructFieldSpec = undefined;
    var shared_count: u8 = 0;
    var arms_tmp: [MaxLocals]VariantArmSpec = undefined;
    var arm_count: u8 = 0;

    if (!c.check(.rbrace)) {
        while (true) {
            if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
            const entry_name = try c.copyName(c.cur.src);
            c.advance();

            if (c.match(.lparen)) {
                // Single-payload arm: name(payloadType) or name(fieldName Type)
                var payload_name: []const u8 = "";
                var payload_type: ?FieldTypeSpec = null;
                if (c.cur.typ == .ident) {
                    var lx2 = c.lex;
                    const peek = lx2.next();
                    if (peek.typ == .ident) {
                        payload_name = try c.copyName(c.cur.src);
                        c.advance();
                    }
                }
                payload_type = try parseFieldTypeSpec(c, );
                try c.consume(.rparen);
                if (arm_count >= MaxLocals) { c.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
                for (arms_tmp[0..arm_count]) |a| {
                    if (common.streq(a.name, entry_name)) { c.setErr("duplicate arm '{s}' in variant", .{entry_name}); return error.DuplicateField; }
                }
                arms_tmp[arm_count] = .{
                    .name = entry_name,
                    .has_payload = true,
                    .payload_name = payload_name,
                    .payload_type = payload_type,
                };
                arm_count += 1;
            } else if (c.match(.lbrace)) {
                // Record arm: name { field1 type1, field2 type2, ... }
                var field_specs: [MaxLocals]StructFieldSpec = undefined;
                var field_count: u8 = 0;
                if (!c.check(.rbrace)) {
                    while (true) {
                        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
                        if (field_count >= MaxLocals) { c.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
                        const fname = try c.copyName(c.cur.src);
                        for (field_specs[0..field_count]) |fs| {
                            if (common.streq(fs.name, fname)) { c.setErr("duplicate field '{s}' in variant arm", .{fname}); return error.DuplicateField; }
                        }
                        c.advance();
                        if (!(c.cur.typ == .ident or c.cur.typ == .question or c.cur.typ == .kw_func or c.cur.typ == .lbracket))
                            return c.err("expected type annotation for variant arm field '{s}'", .{fname});
                        var spec = StructFieldSpec{ .name = fname, .typ = .{ .alts = &[_]FieldTypeAlt{} } };
                        spec.typ = try parseFieldTypeSpec(c, );
                        field_specs[field_count] = spec;
                        field_count += 1;
                        if (!c.match(.comma)) break;
                        if (c.check(.rbrace)) break;
                    }
                }
                try c.consume(.rbrace);
                const fields = heap.bump(StructFieldSpec, field_count) orelse return error.OutOfMemory;
                @memcpy(fields[0..field_count], field_specs[0..field_count]);
                for (fields[0..field_count]) |*f| f.key = .{ .string = try c.cs.internStr(f.name) };
                if (arm_count >= MaxLocals) { c.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
                for (arms_tmp[0..arm_count]) |a| {
                    if (common.streq(a.name, entry_name)) { c.setErr("duplicate arm '{s}' in variant", .{entry_name}); return error.DuplicateField; }
                }
                arms_tmp[arm_count] = .{
                    .name = entry_name,
                    .has_payload = field_count > 0,
                    .fields = fields[0..field_count],
                };
                arm_count += 1;
            } else if (c.cur.typ == .comma or c.cur.typ == .rbrace) {
                // No-payload arm: name
                if (arm_count >= MaxLocals) { c.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
                for (arms_tmp[0..arm_count]) |a| {
                    if (common.streq(a.name, entry_name)) { c.setErr("duplicate arm '{s}' in variant", .{entry_name}); return error.DuplicateField; }
                }
                arms_tmp[arm_count] = .{ .name = entry_name };
                arm_count += 1;
            } else if (c.cur.typ == .ident or c.cur.typ == .question or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
                // Shared field: name type
                if (shared_count >= MaxLocals) { c.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
                for (shared_tmp[0..shared_count]) |sf| {
                    if (common.streq(sf.name, entry_name)) { c.setErr("duplicate field '{s}' in variant shared fields", .{entry_name}); return error.DuplicateField; }
                }
                const spec = StructFieldSpec{ .name = entry_name, .typ = try parseFieldTypeSpec(c, ) };
                shared_tmp[shared_count] = spec;
                shared_count += 1;
            } else {
                return c.err("expected type, '(', or ',' after '{s}'", .{entry_name});
            }

            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);

    const shared_fields = if (shared_count > 0) blk: {
        const sf = heap.bump(StructFieldSpec, shared_count) orelse return error.OutOfMemory;
        @memcpy(sf[0..shared_count], shared_tmp[0..shared_count]);
        for (sf[0..shared_count]) |*f| f.key = .{ .string = try c.cs.internStr(f.name) };
        break :blk sf[0..shared_count];
    } else @as([]const StructFieldSpec, &.{});

    const arms = heap.bump(VariantArmSpec, arm_count) orelse return error.OutOfMemory;
    @memcpy(arms[0..arm_count], arms_tmp[0..arm_count]);

    const qname = try c.qualifyTypeName(name);
    const vt = heap.allocObject() orelse return error.OutOfMemory;
    vt.* = .{ .variant_type = VariantTypeObj{
        .name = try c.copyName(name),
        .qualified_name = qname,
        .arms = arms[0..arm_count],
        .shared_fields = shared_fields,
    } };
    try c.cs.emitConst(.{ .object = vt }, kw.line);
    if (c.inFunc()) {
        _ = try c.defineLocal(name, false);
    } else {
        try c.cs.emitOpStringConst(.def_global, qname, kw.line);
        if (is_pub) try c.addExport(name, qname);
    }
    c.matchOpt(.semicolon);
}
