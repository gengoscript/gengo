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

pub fn emitZeroValue(_: anytype, tc: TypeCheck, line: u32) !void {
    switch (tc) {
        .none => try chunk.emitOp(.null_val, line),
        .prim => |p| switch (p) {
            .int => try chunk.emitConst(.{ .int = 0.0 }, line),
            .float => try chunk.emitConst(.{ .float = 0.0 }, line),
            .decimal => try chunk.emitConst(.{ .decimal = 0 }, line),
            .bool => try chunk.emitOp(.false_val, line),
            .string => try chunk.emitConst(.{ .string = "" }, line),
            .rune => try chunk.emitConst(.{ .rune = 0 }, line),
        },
        .assert_arr => try chunk.emit2(@intFromEnum(Op.build_array), 0, line),
        .assert_map => try chunk.emit2(@intFromEnum(Op.build_map), 0, line),
        .assert_err => try chunk.emitOp(.null_val, line),
        .named => {
            try chunk.emitOp(.null_val, line);
            try chunk.emitGetGlobal(tc.named, line);
            try chunk.emit2(@intFromEnum(Op.call), 1, line);
        },
    }
}

pub fn interfaceDeclBody(c: anytype, kw: Token, name: Token, is_pub: bool) !void {
    try c.registry.addInterfaceType(name.src);
    try c.consume(.lbrace);

    var methods_tmp: [MaxLocals]InterfaceMethodSpec = undefined;
    var mcount: u8 = 0;
    while (!c.check(.rbrace)) {
        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
        if (mcount >= MaxLocals) { c.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
        const mname = try c.copyName(c.cur.src);
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
        var pi: usize = 0;
        while (pi < arity) : (pi += 1) ptypes[pi] = ptypes_tmp[pi];
        const rtypes = heap.bump(FieldTypeSpec, rcount) orelse return error.OutOfMemory;
        var ri: usize = 0;
        while (ri < rcount) : (ri += 1) rtypes[ri] = returns_tmp[ri];

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
    var i: usize = 0;
    while (i < mcount) : (i += 1) methods[i] = methods_tmp[i];
    const qname = try c.qualifyTypeName(name.src);
    const it = heap.allocObject() orelse return error.OutOfMemory;
    it.* = .{ .interface_type = InterfaceTypeObj{ .name = try c.copyName(name.src), .qualified_name = qname, .methods = methods[0..mcount] } };
    try chunk.emitConst(.{ .object = it }, kw.line);
    if (c.inFunc()) {
        _ = try c.defineLocal(name.src, false);
    } else {
        try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
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
        try chunk.emitOpConst(.def_global, .{ .string = key }, kw.line);
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
        try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
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
    if (c.registry.hasNamedType(name)) { c.setErr("duplicate type name '{s}'", .{name}); return error.DuplicateNamedType; }
    const qname = try c.qualifyTypeName(name);
    if (c.check(.kw_enum)) {
        c.advance();
        try c.consume(.lbrace);
        var members_tmp: [MaxLocals][]const u8 = undefined;
        var mcount: u8 = 0;
        if (!c.check(.rbrace)) {
            while (true) {
                if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
                members_tmp[mcount] = try c.copyName(c.cur.src);
                mcount += 1;
                c.advance();
                if (!c.match(.comma)) break;
                if (c.check(.rbrace)) break;
            }
        }
        try c.consume(.rbrace);
        const members = heap.bump([]const u8, mcount) orelse return error.OutOfMemory;
        var mi: usize = 0;
        while (mi < mcount) : (mi += 1) members[mi] = members_tmp[mi];
        try c.registry.addNamedType(.{
            .name = name,
            .base = .enum_t,
            .has_range = false,
            .is_cycle = false,
            .min = 0,
            .max = 0,
            .enum_members = members[0..mcount],
        });
        const et = heap.allocObject() orelse return error.OutOfMemory;
        et.* = .{ .enum_type = .{ .name = try c.copyName(name), .qualified_name = qname, .members = members[0..mcount] } };
        try chunk.emitConst(.{ .object = et }, kw.line);
        if (c.inFunc()) {
            _ = try c.defineLocal(name, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try c.addExport(name, qname);
        }
        c.matchOpt(.semicolon);
        return;
    }

    if (c.cur.typ == .lbracket) {
        // type Name []T — named slice type
        c.advance(); // consume '['
        try c.consume(.rbracket); // consume ']'
        const es: FieldTypeSpec = try parseFieldTypeSpec(c, );
        try c.registry.addNamedType(.{ .name = name, .base = .array_t, .elem_spec = es });
        const nt = heap.allocObject() orelse return error.OutOfMemory;
        nt.* = .{ .named_type = NamedTypeObj{ .name = try c.copyName(name), .qualified_name = qname, .base = .array_t, .elem_spec = es } };
        try chunk.emitConst(.{ .object = nt }, kw.line);
        if (c.inFunc()) {
            _ = try c.defineLocal(name, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
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
    if (common.streq(base_name, "int")) {
        base = .int;
    } else if (common.streq(base_name, "float")) {
        base = .float;
    } else if (common.streq(base_name, "decimal")) {
        base = .decimal;
    } else if (common.streq(base_name, "string")) {
        base = .string;
    } else if (common.streq(base_name, "bool")) {
        base = .bool;
    } else if (common.streq(base_name, "rune")) {
        base = .rune;
    } else if (common.streq(base_name, "array")) {
        return c.err("use '[]T' syntax for array types", .{});
    } else if (common.streq(base_name, "map")) {
        try c.consume(.lbracket);
        const ks = try parseFieldTypeSpec(c, );
        try c.consume(.rbracket);
        const vs = try parseFieldTypeSpec(c, );
        try c.registry.addNamedType(.{ .name = name, .base = .map_t, .key_spec = ks, .val_spec = vs });
        const nt = heap.allocObject() orelse return error.OutOfMemory;
        nt.* = .{ .named_type = NamedTypeObj{ .name = try c.copyName(name), .qualified_name = qname, .base = .map_t, .key_spec = ks, .val_spec = vs } };
        try chunk.emitConst(.{ .object = nt }, kw.line);
        if (c.inFunc()) {
            _ = try c.defineLocal(name, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try c.addExport(name, qname);
        }
        c.matchOpt(.semicolon);
        return;
    } else if (c.registry.getNamedTypeInfo(base_name)) |parent| {
        base = parent.base;
        parent_has_range = parent.has_range;
        parent_is_cycle = parent.is_cycle;
        parent_min = parent.min;
        parent_max = parent.max;
    } else return c.err("unknown type '{s}'", .{base_name});

    var scale: u8 = 0;
    if (base == .decimal) {
        if (c.cur.typ != .number) return c.err("decimal type requires a scale (e.g., decimal 2)", .{});
        const scale_val = common.parseFloat(c.cur.src) orelse return c.err("decimal scale must be a number", .{});
        if (scale_val < 0 or scale_val > 18 or @trunc(scale_val) != scale_val) return c.err("decimal scale must be an integer between 0 and 18", .{});
        scale = @intFromFloat(scale_val);
        c.advance();
    }

    var has_range = false;
    var is_cycle = false;
    var min: f64 = 0;
    var max: f64 = 0;
    if (c.check(.kw_range) or c.check(.kw_cycle)) {
        const constraint = try parseConstraintBounds(c, );
        if (constraint.is_cycle and base != .int) return c.err("'cycle' constraint requires integer base type", .{});
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
            const cidx: u16 = try chunk.addConst(.{ .object = func_obj });
            try chunk.emitConstIdx(.make_closure, cidx, c.prev.line);
        }
        if (c.match(.kw_message)) {
            if (c.cur.typ != .string) return c.err("expected string literal after 'message'", .{});
            predicate_msg = try c.copyName(c.cur.src);
            c.advance();
        }
    }

    try c.registry.addNamedType(.{
        .name = name,
        .base = base,
        .has_range = has_range,
        .is_cycle = is_cycle,
        .scale = scale,
        .min = min,
        .max = max,
        .predicate_msg = predicate_msg,
    });

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
        .predicate = predicate_obj,
        .predicate_msg = predicate_msg,
    } };
    try chunk.emitConst(.{ .object = nt }, kw.line);
    if (predicate_uv_count > 0) {
        try chunk.emitOp(.set_named_predicate, kw.line);
    }
    if (c.inFunc()) {
        _ = try c.defineLocal(name, false);
    } else {
        try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
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

    while (true) {
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
                // [T] array or [K]V map
                const first_spec = try parseFieldTypeSpec(c, );
                try c.consume(.rbracket);
                if (c.cur.typ == .ident or c.cur.typ == .kw_func or c.cur.typ == .lbracket or c.cur.typ == .question) {
                    // [K]V map
                    const second_spec = try parseFieldTypeSpec(c, );
                    const kp = heap.bump(FieldTypeSpec, 1) orelse return error.OutOfMemory;
                    kp[0] = first_spec;
                    const vp = heap.bump(FieldTypeSpec, 1) orelse return error.OutOfMemory;
                    vp[0] = second_spec;
                    alt = .{ .typ = .map, .key_spec = kp[0], .val_spec = vp[0] };
                } else {
                    // [T] array
                    const ep = heap.bump(FieldTypeSpec, 1) orelse return error.OutOfMemory;
                    ep[0] = first_spec;
                    alt = .{ .typ = .array, .elem_spec = ep[0] };
                }
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
                var ii: u8 = 0;
                while (ii < func_param_count) : (ii += 1) ps[ii] = func_params_tmp[ii];
                break :blk ps[0..func_param_count];
            } else @as([]FieldTypeSpec, &.{});
            const fr = if (func_return_count > 0) blk: {
                const rs = heap.bump(FieldTypeSpec, func_return_count) orelse return error.OutOfMemory;
                var ii: u8 = 0;
                while (ii < func_return_count) : (ii += 1) rs[ii] = func_returns_tmp[ii];
                break :blk rs[0..func_return_count];
            } else @as([]FieldTypeSpec, &.{});
            alt = .{ .typ = .func_t, .func_params = fp, .func_returns = fr };
        } else {
        if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
        const tname = c.cur.src;
        c.advance();

        alt = .{ .typ = .struct_t, .struct_name = tname };
        if (common.streq(tname, "any")) {
            alt = .{ .typ = .any };
        } else if (common.streq(tname, "int")) {
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
        }
        } // end else (ident type)

        var i: u8 = 0;
        while (i < count) : (i += 1) {
            if (tmp[i].typ == alt.typ and common.streq(tmp[i].struct_name, alt.struct_name) and common.streq(tmp[i].interface_name, alt.interface_name) and common.streq(tmp[i].named_name, alt.named_name)) break;
        }
        if (i == count) {
            if (count >= MaxTypeAlts) { c.setErr("too many type alternatives (max {d})", .{MaxTypeAlts}); return error.TooManyTypeAlternatives; }
            tmp[count] = alt;
            count += 1;
        }

        if (!c.match(.pipe)) break;
    }

    const alts = heap.bump(FieldTypeAlt, count) orelse return error.OutOfMemory;
    var ai: usize = 0;
    while (ai < count) : (ai += 1) {
        alts[ai] = tmp[ai];
    }
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

fn checkStructFieldType(c: anytype, spec: FieldTypeSpec, qself: []const u8) !void {
    for (spec.alts) |alt| {
        switch (alt.typ) {
            .struct_t => {
                if (common.streq(alt.struct_name, qself)) {
                    c.setErr("struct type '{s}' cannot reference itself", .{alt.struct_name});
                    return error.UnknownStructType;
                }
                if (!c.isKnownLocalStructType(alt.struct_name)) {
                    c.setErr("unknown struct type '{s}'", .{alt.struct_name});
                    return error.UnknownStructType;
                }
            },
            .array => {
                if (alt.elem_spec) |es| try checkStructFieldType(c, es, qself);
            },
            .map => {
                if (alt.key_spec) |ks| try checkStructFieldType(c, ks, qself);
                if (alt.val_spec) |vs| try checkStructFieldType(c, vs, qself);
            },
            .func_t => {
                if (alt.func_params) |params| {
                    for (params) |param| try checkStructFieldType(c, param, qself);
                }
                if (alt.func_returns) |returns| {
                    for (returns) |ret| try checkStructFieldType(c, ret, qself);
                }
            },
            else => {},
        }
    }
}

pub fn structDeclBody(c: anytype, kw: Token, name: Token, is_pub: bool) !void {
    try c.registry.addStructType(name.src);
    try c.consume(.lbrace);

    var field_specs: [MaxLocals]StructFieldSpec = undefined;
    var count: u8 = 0;
    if (!c.check(.rbrace)) {
        while (true) {
            const field_is_const = c.match(.kw_const);
            if (c.cur.typ != .ident) return c.err("expected identifier, found {s}", .{c.tokenName(c.cur.typ)});
            if (count >= MaxLocals) { c.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
            const fname = try c.copyName(c.cur.src);
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (common.streq(field_specs[i].name, fname)) { c.setErr("duplicate field name '{s}'", .{fname}); return error.DuplicateField; }
            }
            c.advance();

            var spec = StructFieldSpec{ .name = fname, .typ = .{ .alts = &[_]FieldTypeAlt{} }, .is_const = field_is_const };
            if (c.cur.typ == .ident or c.cur.typ == .question or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
                // Space syntax: field type  (colon no longer used)
                spec.typ = try parseFieldTypeSpec(c, );
                try checkStructFieldType(c, spec.typ, try c.qualifyTypeName(name.src));
            } else {
                const alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
                alts[0] = .{ .typ = .any };
                spec.typ = .{ .alts = alts[0..1] };
            }

            field_specs[count] = spec;
            count += 1;
            if (!c.match(.comma)) break;
            if (c.check(.rbrace)) break;
        }
    }
    try c.consume(.rbrace);

    const fields = heap.bump(StructFieldSpec, count) orelse return error.OutOfMemory;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        fields[i] = field_specs[i];
    }
    const qname = try c.qualifyTypeName(name.src);
    const st = heap.allocObject() orelse return error.OutOfMemory;
    st.* = .{ .struct_type = StructTypeObj{ .name = try c.copyName(name.src), .qualified_name = qname, .fields = fields[0..count] } };
    try chunk.emitConst(.{ .object = st }, kw.line);

    if (c.inFunc()) {
        _ = try c.defineLocal(name.src, false);
    } else {
        try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
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
                members_tmp[mcount] = try c.copyName(c.cur.src);
                mcount += 1;
                c.advance();
                if (!c.match(.comma)) break;
                if (c.check(.rbrace)) break;
            }
        }
        try c.consume(.rbrace);
        const members = heap.bump([]const u8, mcount) orelse return error.OutOfMemory;
        var mi: usize = 0;
        while (mi < mcount) : (mi += 1) members[mi] = members_tmp[mi];
        // Validate each member exists in the parent enum
        if (parent_info.enum_members) |parent_members| {
            var i: usize = 0;
            while (i < mcount) : (i += 1) {
                var found = false;
                var j: usize = 0;
                while (j < parent_members.len) : (j += 1) {
                    if (common.streq(members[i], parent_members[j])) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    c.setErr("'{s}' is not a member of {s}", .{ members[i], parent_name });
                    return error.UnexpectedToken;
                }
            }
        }
        try c.registry.addNamedType(.{
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
        try chunk.emitConst(.{ .object = et }, kw.line);
        if (c.inFunc()) {
            _ = try c.defineLocal(name, false);
        } else {
            try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
            if (is_pub) try c.addExport(name, qname);
        }
        c.matchOpt(.semicolon);
        return;
    }

    if (c.registry.hasNamedType(name)) { c.setErr("duplicate type name '{s}'", .{name}); return error.DuplicateNamedType; }

    const base = parent_info.base;
    var has_range = parent_info.has_range;
    var is_cycle = parent_info.is_cycle;
    var min: f64 = parent_info.min;
    var max: f64 = parent_info.max;
    const scale = parent_info.scale;
    const is_numeric = base == .int or base == .float or base == .rune;
    const is_scalar = is_numeric or base == .string or base == .bool or base == .decimal;
    if (!is_scalar)
        return c.err("subtype parent must be a scalar named type (int, float, decimal, string, bool, or rune base)", .{});

    if (c.check(.kw_range) or c.check(.kw_cycle)) {
        if (!is_numeric) return c.err("range and cycle constraints require a numeric parent type (int, float, or rune)", .{});
        const constraint = try parseConstraintBounds(c, );
        if (constraint.is_cycle and base != .int) return c.err("'cycle' constraint requires integer base type", .{});
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
            const cidx: u16 = try chunk.addConst(.{ .object = func_obj });
            try chunk.emitConstIdx(.make_closure, cidx, c.prev.line);
        }
        if (c.match(.kw_message)) {
            if (c.cur.typ != .string) return c.err("expected string literal after 'message'", .{});
            predicate_msg = try c.copyName(c.cur.src);
            c.advance();
        }
    }

    try c.registry.addNamedType(.{
        .name = name,
        .base = base,
        .has_range = has_range,
        .is_cycle = is_cycle,
        .scale = scale,
        .min = min,
        .max = max,
        .parent_name = parent_name,
        .predicate_msg = predicate_msg,
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
    } };
    try chunk.emitConst(.{ .object = nt }, kw.line);
    if (predicate_uv_count > 0) {
        try chunk.emitOp(.set_named_predicate, kw.line);
    }
    if (c.inFunc()) {
        _ = try c.defineLocal(name, false);
    } else {
        try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
        if (is_pub) try c.addExport(name, qname);
    }
    c.matchOpt(.semicolon);
}

pub fn variantDeclBody(c: anytype, kw: Token, name_tok: Token, is_pub: bool) !void {
    const name = name_tok.src;
    if (c.registry.hasVariantType(name)) { c.setErr("duplicate variant type name '{s}'", .{name}); return error.DuplicateVariantType; }
    try c.registry.addVariantType(name);
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
                        c.advance();
                        var spec = StructFieldSpec{ .name = fname, .typ = .{ .alts = &[_]FieldTypeAlt{} } };
                        if (c.cur.typ == .ident or c.cur.typ == .question or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
                            spec.typ = try parseFieldTypeSpec(c, );
                        }
                        field_specs[field_count] = spec;
                        field_count += 1;
                        if (!c.match(.comma)) break;
                        if (c.check(.rbrace)) break;
                    }
                }
                try c.consume(.rbrace);
                const fields = heap.bump(StructFieldSpec, field_count) orelse return error.OutOfMemory;
                var fi: usize = 0;
                while (fi < field_count) : (fi += 1) fields[fi] = field_specs[fi];
                if (arm_count >= MaxLocals) { c.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
                arms_tmp[arm_count] = .{
                    .name = entry_name,
                    .has_payload = field_count > 0,
                    .fields = fields[0..field_count],
                };
                arm_count += 1;
            } else if (c.cur.typ == .comma or c.cur.typ == .rbrace) {
                // No-payload arm: name
                if (arm_count >= MaxLocals) { c.setErr("too many local variables (max {d})", .{MaxLocals}); return error.TooManyLocals; }
                arms_tmp[arm_count] = .{ .name = entry_name };
                arm_count += 1;
            } else if (c.cur.typ == .ident or c.cur.typ == .question or c.cur.typ == .kw_func or c.cur.typ == .lbracket) {
                // Shared field: name type
                if (shared_count >= MaxLocals) { c.setErr("too many fields (max {d})", .{MaxLocals}); return error.TooManyFields; }
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
        var si: usize = 0;
        while (si < shared_count) : (si += 1) sf[si] = shared_tmp[si];
        break :blk sf[0..shared_count];
    } else @as([]const StructFieldSpec, &.{});

    const arms = heap.bump(VariantArmSpec, arm_count) orelse return error.OutOfMemory;
    var ai: usize = 0;
    while (ai < arm_count) : (ai += 1) arms[ai] = arms_tmp[ai];

    const qname = try c.qualifyTypeName(name);
    const vt = heap.allocObject() orelse return error.OutOfMemory;
    vt.* = .{ .variant_type = VariantTypeObj{
        .name = try c.copyName(name),
        .qualified_name = qname,
        .arms = arms[0..arm_count],
        .shared_fields = shared_fields,
    } };
    try chunk.emitConst(.{ .object = vt }, kw.line);
    if (c.inFunc()) {
        _ = try c.defineLocal(name, false);
    } else {
        try chunk.emitOpConst(.def_global, .{ .string = qname }, kw.line);
        if (is_pub) try c.addExport(name, qname);
    }
    c.matchOpt(.semicolon);
}
