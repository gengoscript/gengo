const std = @import("std");
const heap = @import("../../runtime/heap.zig");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const vmtyp = @import("../vm_types.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;
const FieldTypeAlt = @import("../value.zig").FieldTypeAlt;
const FieldTypeSpec = @import("../value.zig").FieldTypeSpec;
const StructFieldSpec = @import("../value.zig").StructFieldSpec;
const StructTypeObj = @import("../value.zig").StructTypeObj;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const chunk = @import("../chunk.zig");

const TemplateTypeQualifiedName = "@std.template.obj";

const TplOp = enum(u8) {
    text = 0,
    field = 1,
    chain = 2,
    var_ref = 3,
    root_ref = 4,
    call_fn = 5,
    if_begin = 6,
    if_else = 7,
    end = 8,
    range_begin = 9,
    range_else = 10,
    with_begin = 11,
    break_inst = 12,
    continue_inst = 13,
    assign = 14,
};

const TplCtrl = enum(u8) { if_block, range_block, with_block };

const TplCtrlEntry = struct {
    kind: TplCtrl,
    if_idx: usize,
    else_idx: usize,
};

fn tplIsStringVal(v: Value) bool {
    if (v == .string) return true;
    if (v == .object) {
        return switch (v.object.*) {
            .dyn_string, .string_view => true,
            else => false,
        };
    }
    return false;
}

fn tplAsStringVal(v: Value) ![]const u8 {
    return switch (v) {
        .string => |s| s.bytes,
        .object => |o| switch (o.*) {
            .dyn_string => |s| s,
            .string_view => |sv| sv.bytes,
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn tplResolveField(data: Value, field: []const u8) !Value {
    if (data != .object) return .null;
    const obj = data.object;
    switch (obj.*) {
        .map, .map_managed, .map_hashed => {
            const items = tplAsMapSlice(obj);
            for (items) |entry| {
                if (tplIsStringVal(entry.key)) {
                    const k = try tplAsStringVal(entry.key);
                    if (std.mem.eql(u8, k, field)) return entry.value;
                }
            }
            return .null;
        },
        .struct_instance => {
            const fields = obj.struct_instance.fields;
            for (fields) |f| {
                if (vms.isStringValue(f.key)) {
                    const k = vms.asStringValue(f.key) catch continue;
                    if (std.mem.eql(u8, k, field)) return f.value;
                }
            }
            return .null;
        },
        .small_struct_instance => |ssi| {
            for (0..@as(usize, ssi.count)) |i| {
                if (std.mem.eql(u8, ssi.typ.struct_type.fields[i].name, field)) return ssi.v[i];
            }
            return .null;
        },
        else => return .null,
    }
}

fn tplFieldValue(obj: *Object, name: []const u8) Value {
    const fields = obj.struct_instance.fields;
    for (fields) |f| {
        if (vms.isStringValue(f.key)) {
            const k = vms.asStringValue(f.key) catch continue;
            if (std.mem.eql(u8, k, name)) return f.value;
        }
    }
    return .null;
}

fn tplIsArray(obj: *Object) bool {
    // Must recognize every array-like Object tag tplAsArraySlice itself
    // handles below (matches vm_state.zig's canonical vms.isArrayObject
    // tag set) -- this used to check only .array/.array_managed, so
    // {{range .}} over an array grown via std.core.append (which is always
    // .array_capacity, per vm_array.zig's arrayAppend) silently iterated
    // zero times instead of erroring OR iterating correctly, since the
    // caller gates on tplIsArray before ever calling tplAsArraySlice.
    return switch (obj.*) {
        .array, .array_managed, .array_view, .array_capacity => true,
        else => false,
    };
}

fn tplAsArraySlice(obj: *Object) []Value {
    return switch (obj.*) {
        .array => |a| a,
        .array_managed => |a| a,
        .array_view => |v| v.items,
        .array_capacity => |a| a.backing.array_managed[0..a.len],
        else => &[_]Value{},
    };
}

fn tplAsMapSlice(obj: *Object) []MapEntry {
    return switch (obj.*) {
        .map => |m| m,
        .map_managed => |m| m,
        .map_hashed => |m| m.entries[0..m.len],
        else => &[_]MapEntry{},
    };
}

fn tplEvalExpr(arg: Value, dot: Value, _funcs_val: Value) !Value {
    _ = _funcs_val;
    if (arg == .null) return dot;
    if (arg == .string) {
        return try tplResolveField(dot, arg.string.bytes);
    }
    if (arg == .object and tplIsArray(arg.object)) {
        const items = tplAsArraySlice(arg.object);
        var cur = dot;
        for (items) |item| {
            const name = try tplAsStringVal(item);
            cur = try tplResolveField(cur, name);
        }
        return cur;
    }
    return .null;
}

fn tplValToDynStr(ctx: VMContext, v: Value) !Value {
    return switch (v) {
        .null => vmgc.makeDynString(ctx, "null"),
        .boolean => |b| vmgc.makeDynString(ctx, if (b) "true" else "false"),
        .int => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(ctx, s);
        },
        .float => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(ctx, s);
        },
        .string => |s| vmgc.makeDynString(ctx, s.bytes),
        .object => |o| {
            // Root o before any allocation so GC cannot sweep it or its managed bytes.
            try ctx.vs.pushTempRoot(.{ .object = o });
            defer ctx.vs.popTempRoot();
            // Use makeDynStringFromObj so the copy re-reads o's bytes field AFTER
            // vmAllocManagedBytes, avoiding a stale pointer if compactManagedHeap
            // fires and updates o.dyn_string/o.string_view.bytes mid-allocation.
            if (o.* == .dyn_string) return vmgc.makeDynStringFromObj(ctx, o);
            if (o.* == .string_view) return vmgc.makeDynStringFromObj(ctx, o);
            // Named values render through their underlying value.
            if (o.* == .named_value) return tplValToDynStr(ctx, o.named_value.value);
            return vmgc.makeDynString(ctx, "?");
        },
        else => vmgc.makeDynString(ctx, "?"),
    };
}

/// Append a dyn_string Object's bytes to the builder, re-reading src.dyn_string
/// AFTER vmAllocManagedBytes so that a compactManagedHeap triggered inside that
/// call cannot leave us copying from a stale Zig-local []const u8.
fn tplAppendDynStrToBuilder(ctx: VMContext, sb_obj: *Object, src: *Object) !void {
    const slen = src.dyn_string.len;
    if (slen == 0) return;
    const needed = sb_obj.string_builder.len + slen;
    if (needed > sb_obj.string_builder.buf.len) {
        const new_buf = try vmgc.vmAllocManagedBytes(ctx, needed);
        const old_len = sb_obj.string_builder.len;
        @memcpy(new_buf[0..old_len], sb_obj.string_builder.buf[0..old_len]);
        @memcpy(new_buf[old_len..needed], src.dyn_string);
        const old_buf = sb_obj.string_builder.buf;
        sb_obj.string_builder.buf = new_buf;
        sb_obj.string_builder.len = needed;
        ctx.hs.freeBytesManaged(old_buf);
        return;
    }
    @memcpy(sb_obj.string_builder.buf[sb_obj.string_builder.len..needed], src.dyn_string);
    sb_obj.string_builder.len = needed;
}

fn tplAppendValToBuilder(ctx: VMContext, sb_obj: *Object, val: Value) !void {
    if (val == .object) {
        try ctx.vs.pushTempRoot(val);
        defer ctx.vs.popTempRoot();
    }
    const sv = try tplValToDynStr(ctx, val);
    try ctx.vs.pushTempRoot(sv);
    defer ctx.vs.popTempRoot();
    return tplAppendDynStrToBuilder(ctx, sb_obj, sv.object);
}

fn tplAppendToBuilder(ctx: VMContext, sb_obj: *Object, s: []const u8) !void {
    if (s.len == 0) return;
    const needed = sb_obj.string_builder.len + s.len;
    if (needed > sb_obj.string_builder.buf.len) {
        const new_buf = try vmgc.vmAllocManagedBytes(ctx, needed);
        @memcpy(new_buf[0..sb_obj.string_builder.len], sb_obj.string_builder.buf[0..sb_obj.string_builder.len]);
        const old_buf = sb_obj.string_builder.buf;
        sb_obj.string_builder.buf = new_buf; // update before free so paranoia doesn't see the old ref
        ctx.hs.freeBytesManaged(old_buf);
    }
    @memcpy(sb_obj.string_builder.buf[sb_obj.string_builder.len..needed], s);
    sb_obj.string_builder.len = needed;
}

fn tplBuilderToStr(ctx: VMContext, sb_obj: *Object) !Value {
    // makeDynStringFromObj re-reads sb_obj.string_builder after vmAllocManagedBytes,
    // avoiding a stale slice if compactManagedHeap runs inside that allocation.
    return vmgc.makeDynStringFromObj(ctx, sb_obj);
}

pub fn tplCountInsts(src: []const u8) !usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.indexOfPos(u8, src, i, "{{")) |start| {
            if (start > i) count += 1;
            const end = std.mem.indexOfPos(u8, src, start + 2, "}}") orelse return error.InvalidTemplate;
            count += 1;
            i = end + 2;
        } else {
            count += 1;
            break;
        }
    }
    return count;
}

fn tplSplitPath(ctx: VMContext, s: []const u8, sep: []const u8) !Value {
    var count: usize = 1;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
        count += 1;
        i = pos + sep.len;
    }
    const obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    const arr = try vmgc.vmAllocManagedSlice(ctx, Value, count);
    // Always copy: the template source may be a GC-managed string, and these
    // path arrays can outlive it inside a compiled template object. Attach
    // the slice as it fills so already-copied elements stay traced.
    obj.* = .{ .array_managed = arr[0..0] };
    var idx: usize = 0;
    i = 0;
    while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
        arr[idx] = try vmgc.makeDynString(ctx, s[i..pos]);
        idx += 1;
        obj.* = .{ .array_managed = arr[0..idx] };
        i = pos + sep.len;
    }
    arr[idx] = try vmgc.makeDynString(ctx, s[i..]);
    obj.* = .{ .array_managed = arr[0..count] };
    return .{ .object = obj };
}

fn tplEncodeExpr(ctx: VMContext, expr: []const u8) !Value {
    const trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return .null;
    if (std.mem.eql(u8, trimmed, ".")) return .null;
    if (trimmed[0] == '$') return .{ .string = try ctx.cs.internStr(trimmed[1..]) };
    if (trimmed[0] == '.') {
        const path = trimmed[1..];
        if (std.mem.indexOf(u8, path, ".")) |_| {
            return try tplSplitPath(ctx, path, ".");
        }
        return .{ .string = try ctx.cs.internStr(path) };
    }
    return .{ .string = try ctx.cs.internStr(trimmed) };
}

fn tplParseTag(ctx: VMContext, tag: []const u8) !struct { op: TplOp, arg: Value } {
    const trimmed = std.mem.trim(u8, tag, " \t\n\r");
    if (trimmed.len == 0) return error.InvalidTemplate;

    if (std.mem.eql(u8, trimmed, "end")) return .{ .op = .end, .arg = .null };
    if (std.mem.eql(u8, trimmed, "else")) return .{ .op = .if_else, .arg = .null };
    if (std.mem.eql(u8, trimmed, "break")) return .{ .op = .break_inst, .arg = .null };
    if (std.mem.eql(u8, trimmed, "continue")) return .{ .op = .continue_inst, .arg = .null };
    if (std.mem.eql(u8, trimmed, ".")) return .{ .op = .root_ref, .arg = .null };

    if (std.mem.startsWith(u8, trimmed, "if ")) {
        const expr = std.mem.trim(u8, trimmed[3..], " \t");
        return .{ .op = .if_begin, .arg = try tplEncodeExpr(ctx, expr) };
    }
    if (std.mem.startsWith(u8, trimmed, "range ")) {
        const expr = std.mem.trim(u8, trimmed[6..], " \t");
        return .{ .op = .range_begin, .arg = try tplEncodeExpr(ctx, expr) };
    }
    if (std.mem.startsWith(u8, trimmed, "with ")) {
        const expr = std.mem.trim(u8, trimmed[5..], " \t");
        return .{ .op = .with_begin, .arg = try tplEncodeExpr(ctx, expr) };
    }
    if (trimmed.len >= 2 and trimmed[0] == '$') {
        if (std.mem.indexOf(u8, trimmed, ":=")) |pos| {
            const vname = std.mem.trim(u8, trimmed[1..pos], " \t");
            return .{ .op = .assign, .arg = .{ .string = try ctx.cs.internStr(vname) } };
        }
        const vname = trimmed[1..];
        return .{ .op = .var_ref, .arg = .{ .string = try ctx.cs.internStr(vname) } };
    }
    if (trimmed[0] == '.') {
        const path = trimmed[1..];
        if (std.mem.indexOf(u8, path, ".")) |_| {
            return .{ .op = .chain, .arg = try tplSplitPath(ctx, path, ".") };
        }
        return .{ .op = .field, .arg = .{ .string = try ctx.cs.internStr(path) } };
    }
    const space_pos = std.mem.indexOfAny(u8, trimmed, " \t");
    if (space_pos) |pos| {
        const fname = trimmed[0..pos];
        return .{ .op = .call_fn, .arg = .{ .string = try ctx.cs.internStr(fname) } };
    }

    return error.InvalidTemplate;
}

// Every parsed template shares the exact same "Template" struct shape
// (__ops/__args/__jmp/__src/funcs never vary), so — like regexGetType/
// argGetType/timeGetType/jsonValueGetType — this is a true permanent
// singleton, built once and cached. tplBuildObj used to rebuild this (and
// bump-allocate a fresh field_specs array) on every single call, which
// leaked 5 StructFieldSpecs' worth of permanent memory per template
// render — found via a stress-preset regression
// (276_template_compact_safety.gengo) after fixing heap.zig's two-ended
// arena to properly enforce the permanent/managed boundary instead of
// silently letting permanent overflow spill into managed territory: a
// repeated render() no longer had that silent slack to hide in.
fn templateGetType(ctx: VMContext) !*Object {
    if (ctx.vs.template_type_cache) |t| return t;
    // Use a comptime constant so the alts pointer lives in rodata, not the
    // managed heap — compactManagedHeap cannot invalidate it.
    const any_spec: FieldTypeSpec = .{ .alts = @constCast(&[_]FieldTypeAlt{.{ .typ = .any }}) };
    const field_specs = ctx.hs.bump(StructFieldSpec, 5) orelse return error.OutOfMemory;
    field_specs[0] = .{ .name = "__ops", .typ = any_spec, .is_const = true };
    field_specs[1] = .{ .name = "__args", .typ = any_spec, .is_const = true };
    field_specs[2] = .{ .name = "__jmp", .typ = any_spec, .is_const = true };
    field_specs[3] = .{ .name = "__src", .typ = any_spec, .is_const = true };
    field_specs[4] = .{ .name = "funcs", .typ = any_spec, .is_const = false };
    const buf = ctx.hs.bump(Object, 1) orelse return error.OutOfMemory;
    const obj: *Object = @ptrCast(buf);
    obj.* = .{ .struct_type = StructTypeObj{
        .name = "Template",
        .qualified_name = TemplateTypeQualifiedName,
        .fields = field_specs[0..5],
    } };
    ctx.vs.template_type_cache = obj;
    return obj;
}

fn tplBuildObj(ctx: VMContext, src_val: Value, ops: []Value, args: []Value, jmp: []Value) !*Object {
    // Push any GC objects in args as temp roots before any allocation that could
    // trigger GC. Without this, chain-path arrays from tplSplitPath stored in
    // args[] are unreachable during GC and get collected.
    const args_root_base = try ctx.vs.pushObjectTempRoots(args);
    defer ctx.vs.restoreTempRoots(args_root_base);

    const typ_obj = try templateGetType(ctx);

    const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 5);
    const inst_obj = try vmgc.vmAllocObject(ctx);
    try ctx.vs.pushTempRoot(.{ .object = inst_obj });
    defer ctx.vs.popTempRoot();
    inst_obj.* = .{ .struct_instance = .{ .typ = typ_obj, .fields = inst_fields } };

    const ops_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    ops_obj.* = .{ .array_managed = ops };

    const args_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    args_obj.* = .{ .array_managed = args };

    const jmp_obj = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    jmp_obj.* = .{ .array_managed = jmp };

    const funcs_obj = try vmgc.vmAllocObject(ctx);
    funcs_obj.* = .{ .map = &[_]MapEntry{} };

    inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("__ops") }, .value = .{ .object = ops_obj } };
    inst_fields[1] = .{ .key = .{ .string = try ctx.cs.internStr("__args") }, .value = .{ .object = args_obj } };
    inst_fields[2] = .{ .key = .{ .string = try ctx.cs.internStr("__jmp") }, .value = .{ .object = jmp_obj } };
    inst_fields[3] = .{ .key = .{ .string = try ctx.cs.internStr("__src") }, .value = src_val };
    inst_fields[4] = .{ .key = .{ .string = try ctx.cs.internStr("funcs") }, .value = .{ .object = funcs_obj } };

    return inst_obj;
}

pub fn tplParse(ctx: VMContext, src_val: Value, src: []const u8) !Value {
    if (src.len == 0) {
        const obj = try tplBuildObj(ctx, src_val, &[_]Value{}, &[_]Value{}, &[_]Value{});
        return .{ .object = obj };
    }
    const inst_count = try tplCountInsts(src);
    if (inst_count == 0) {
        const obj = try tplBuildObj(ctx, src_val, &[_]Value{}, &[_]Value{}, &[_]Value{});
        return .{ .object = obj };
    }
    // Root the parse-time slices immediately so that GC triggered by tplParseTag
    // / tplSplitPath cannot sweep elements already written into args[].
    const ops_root = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    var ops = try vmgc.vmAllocManagedSlice(ctx, Value, inst_count);
    ops_root.* = .{ .array_managed = ops };
    for (ops) |*v| v.* = .null;

    const args_root = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    var args = try vmgc.vmAllocManagedSlice(ctx, Value, inst_count);
    args_root.* = .{ .array_managed = args };
    for (args) |*v| v.* = .null;

    const jmp_root = try vmgc.allocTempRooted(ctx, .{ .array = &[_]Value{} });
    defer ctx.vs.popTempRoot();
    var jmp = try vmgc.vmAllocManagedSlice(ctx, Value, inst_count);
    jmp_root.* = .{ .array_managed = jmp };
    for (jmp) |*v| v.* = .null;

    var idx: usize = 0;
    var pos: usize = 0;
    var ctrl_stack: [64]TplCtrlEntry = undefined;
    var ctrl_top: usize = 0;

    while (pos < src.len) {
        // Re-derive managed slices at the top of each iteration: tplParseTag
        // (via tplSplitPath/makeDynString) can compact the managed heap,
        // making the outer `ops`/`args`/`jmp` variables stale.
        ops = ops_root.array_managed;
        args = args_root.array_managed;
        jmp = jmp_root.array_managed;
        if (std.mem.indexOfPos(u8, src, pos, "{{")) |start| {
            if (start > pos) {
                ops[idx] = .{ .float = @floatFromInt(@intFromEnum(TplOp.text)) };
                args[idx] = .{ .string = try ctx.cs.internStr(src[pos..start]) };
                jmp[idx] = .{ .float = -1 };
                idx += 1;
            }
            const end = std.mem.indexOfPos(u8, src, start + 2, "}}") orelse return error.InvalidTemplate;
            const tag = src[start + 2 .. end];
            const trimmed_tag = std.mem.trim(u8, tag, " \t\n\r");
            if (std.mem.startsWith(u8, trimmed_tag, "/*")) {
                pos = end + 2;
                continue;
            }
            const parsed = try tplParseTag(ctx, tag);
            // Re-derive after tplParseTag which may have compacted via tplSplitPath.
            ops = ops_root.array_managed;
            args = args_root.array_managed;
            jmp = jmp_root.array_managed;

            if (parsed.op == .end) {
                var scope_pop: f64 = 0;
                if (ctrl_top > 0) {
                    ctrl_top -= 1;
                    const entry = ctrl_stack[ctrl_top];
                    switch (entry.kind) {
                        .if_block => {
                            if (entry.else_idx != std.math.maxInt(usize)) {
                                jmp[entry.if_idx] = .{ .float = @floatFromInt(entry.else_idx + 1) };
                                jmp[entry.else_idx] = .{ .float = @floatFromInt(idx) };
                            } else {
                                jmp[entry.if_idx] = .{ .float = @floatFromInt(idx) };
                            }
                            scope_pop = 0;
                        },
                        .range_block => {
                            if (entry.else_idx != std.math.maxInt(usize)) {
                                jmp[entry.else_idx] = .{ .float = @floatFromInt(idx) };
                                jmp[entry.if_idx] = .{ .float = @floatFromInt(entry.else_idx + 1) };
                            } else {
                                jmp[entry.if_idx] = .{ .float = @floatFromInt(idx) };
                            }
                            scope_pop = -2;
                        },
                        .with_block => {
                            jmp[entry.if_idx] = .{ .float = @floatFromInt(idx) };
                            scope_pop = -1;
                        },
                    }
                }
                ops[idx] = .{ .float = @floatFromInt(@intFromEnum(TplOp.end)) };
                args[idx] = .null;
                jmp[idx] = .{ .float = scope_pop };
                idx += 1;
            } else if (parsed.op == .if_else) {
                if (ctrl_top > 0) ctrl_stack[ctrl_top - 1].else_idx = idx;
                ops[idx] = .{ .float = @floatFromInt(@intFromEnum(TplOp.if_else)) };
                args[idx] = .null;
                jmp[idx] = .{ .float = -1 };
                idx += 1;
            } else if (parsed.op == .range_else) {
                if (ctrl_top > 0) ctrl_stack[ctrl_top - 1].else_idx = idx;
                ops[idx] = .{ .float = @floatFromInt(@intFromEnum(TplOp.range_else)) };
                args[idx] = .null;
                jmp[idx] = .{ .float = -1 };
                idx += 1;
            } else {
                if (parsed.op == .if_begin) {
                    if (ctrl_top >= ctrl_stack.len) return error.InvalidTemplate;
                    ctrl_stack[ctrl_top] = .{ .kind = .if_block, .if_idx = idx, .else_idx = std.math.maxInt(usize) };
                    ctrl_top += 1;
                } else if (parsed.op == .range_begin) {
                    if (ctrl_top >= ctrl_stack.len) return error.InvalidTemplate;
                    ctrl_stack[ctrl_top] = .{ .kind = .range_block, .if_idx = idx, .else_idx = std.math.maxInt(usize) };
                    ctrl_top += 1;
                } else if (parsed.op == .with_begin) {
                    if (ctrl_top >= ctrl_stack.len) return error.InvalidTemplate;
                    ctrl_stack[ctrl_top] = .{ .kind = .with_block, .if_idx = idx, .else_idx = std.math.maxInt(usize) };
                    ctrl_top += 1;
                }
                ops[idx] = .{ .float = @floatFromInt(@intFromEnum(parsed.op)) };
                args[idx] = parsed.arg;
                jmp[idx] = .{ .float = -1 };
                idx += 1;
            }
            pos = end + 2;
        } else {
            ops[idx] = .{ .float = @floatFromInt(@intFromEnum(TplOp.text)) };
            args[idx] = .{ .string = try ctx.cs.internStr(src[pos..]) };
            jmp[idx] = .{ .float = -1 };
            idx += 1;
            break;
        }
    }

    // Release the temporary root wrappers' ownership of the managed slices before
    // tplBuildObj creates its own wrapper objects for the same slices.  Leaving
    // ops_root/args_root/jmp_root pointing to the slices would cause a double-free:
    // when these objects are swept after the defers pop them, sweepObjects calls
    // freeManagedSlice on the same memory that the template's __ops/__args/__jmp
    // objects still reference.
    ops_root.* = .{ .array = &[_]Value{} };
    args_root.* = .{ .array = &[_]Value{} };
    jmp_root.* = .{ .array = &[_]Value{} };

    const obj = try tplBuildObj(ctx, src_val, ops[0..idx], args[0..idx], jmp[0..idx]);
    return .{ .object = obj };
}

const IterState = struct {
    arr: *Object,
    index: usize,
    body_ip: usize,
};

pub fn tplExec(ctx: VMContext, tmpl: *Object, data: Value) !Value {
    const ops_v = tplFieldValue(tmpl, "__ops");
    const args_v = tplFieldValue(tmpl, "__args");
    const jmp_v = tplFieldValue(tmpl, "__jmp");
    const funcs_v = tplFieldValue(tmpl, "funcs");

    if (ops_v != .object) return error.TypeError;

    const sb_obj = try vmgc.allocTempRooted(ctx, .{ .string_builder = .{ .buf = &[_]u8{}, .len = 0 } });
    defer ctx.vs.popTempRoot();

    var ip: usize = 0;
    var dot_stack: [256]Value = undefined;
    var scope_top: usize = 0;
    dot_stack[scope_top] = data;
    var iter_stack: [64]IterState = undefined;
    var iter_top: usize = 0;

    while (true) {
        // Re-derive managed slices at the top of each iteration: allocations in
        // the loop body (string appends, range, with) can compact the managed
        // heap, invalidating previously captured []Value slice variables.
        const ops = tplAsArraySlice(ops_v.object);
        if (ip >= ops.len) break;
        const args = tplAsArraySlice(args_v.object);
        const jmps = tplAsArraySlice(jmp_v.object);
        const op_v = ops[ip];
        if (op_v != .int and op_v != .float) return error.TypeError;
        const op_num: f64 = if (op_v == .int) @floatFromInt(op_v.int) else op_v.float;
        if (op_num < 0 or op_num > 14) return error.TypeError;
        const op: TplOp = @enumFromInt(@as(u8, @intFromFloat(op_num)));
        const arg = args[ip];

        switch (op) {
            .text => {
                const s = try tplAsStringVal(arg);
                try tplAppendToBuilder(ctx, sb_obj, s);
                ip += 1;
            },
            .field => {
                const fname = try tplAsStringVal(arg);
                const val = try tplResolveField(dot_stack[scope_top], fname);
                try tplAppendValToBuilder(ctx, sb_obj, val);
                ip += 1;
            },
            .chain => {
                const items = tplAsArraySlice(arg.object);
                var cur = dot_stack[scope_top];
                for (items) |item| {
                    const name = try tplAsStringVal(item);
                    cur = try tplResolveField(cur, name);
                }
                try tplAppendValToBuilder(ctx, sb_obj, cur);
                ip += 1;
            },
            .root_ref => {
                try tplAppendValToBuilder(ctx, sb_obj, dot_stack[scope_top]);
                ip += 1;
            },
            .var_ref, .call_fn, .assign, .break_inst, .continue_inst => {
                ip += 1;
            },
            .if_begin => {
                const cond = try tplEvalExpr(arg, dot_stack[scope_top], funcs_v);
                const cond_bool = cond.asBool() catch {
                    ctx.vs.setRuntimeErr("{{{{if}}}} condition must be bool, got {s}", .{vmtyp.runtimeTypeName(cond)});
                    return error.TypeError;
                };
                if (!cond_bool) {
                    const jv = jmps[ip];
                    const jv_num: f64 = if (jv == .int) @floatFromInt(jv.int) else if (jv == .float) jv.float else return error.TypeError;
                    if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                    ip = @intFromFloat(jv_num);
                } else {
                    ip += 1;
                }
            },
            .if_else => {
                const jv = jmps[ip];
                const jv_num: f64 = if (jv == .int) @floatFromInt(jv.int) else if (jv == .float) jv.float else return error.TypeError;
                if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                ip = @intFromFloat(jv_num);
            },
            .end => {
                const jv = jmps[ip];
                const jv_num: ?f64 = if (jv == .int) @floatFromInt(jv.int) else if (jv == .float) jv.float else null;
                if (jv_num != null and jv_num.? == -2) {
                    if (iter_top > 0) {
                        const iter_idx = iter_top - 1;
                        iter_stack[iter_idx].index += 1;
                        const iter_items = tplAsArraySlice(iter_stack[iter_idx].arr);
                        if (iter_stack[iter_idx].index < iter_items.len) {
                            dot_stack[scope_top] = iter_items[iter_stack[iter_idx].index];
                            ip = iter_stack[iter_idx].body_ip;
                        } else {
                            iter_top -= 1;
                            if (scope_top > 0) scope_top -= 1;
                            ip += 1;
                        }
                    } else {
                        ip += 1;
                    }
                } else if ((jv == .int or jv == .float) and (if (jv == .int) @as(f64, @floatFromInt(jv.int)) else jv.float) < 0 and (if (jv == .int) @as(f64, @floatFromInt(jv.int)) else jv.float) > -@as(f64, @floatFromInt(std.math.maxInt(usize)))) {
                    const pop = @as(usize, @intFromFloat(-(if (jv == .int) @as(f64, @floatFromInt(jv.int)) else jv.float)));
                    if (scope_top >= pop) scope_top -= pop;
                    ip += 1;
                } else {
                    ip += 1;
                }
            },
            .range_begin => {
                const rval = try tplEvalExpr(arg, dot_stack[scope_top], funcs_v);
                if (rval == .object) {
                    const obj = rval.object;
                    if (tplIsArray(obj)) {
                        if (tplAsArraySlice(obj).len > 0) {
                            if (iter_top >= iter_stack.len) return error.TypeError;
                            if (scope_top >= dot_stack.len - 1) return error.TypeError;
                            iter_stack[iter_top] = .{ .arr = obj, .index = 0, .body_ip = ip + 1 };
                            iter_top += 1;
                            scope_top += 1;
                            dot_stack[scope_top] = tplAsArraySlice(obj)[0];
                            ip += 1;
                        } else {
                            const jv = jmps[ip];
                            if ((jv != .int and jv != .float) or (if (jv == .int) @as(f64, @floatFromInt(jv.int)) else jv.float) < 0 or (if (jv == .int) @as(f64, @floatFromInt(jv.int)) else jv.float) >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                            ip = @intFromFloat(if (jv == .int) @as(f64, @floatFromInt(jv.int)) else jv.float);
                        }
                    } else {
                        const jv = jmps[ip];
                        const jv_num: f64 = if (jv == .int) @floatFromInt(jv.int) else if (jv == .float) jv.float else return error.TypeError;
                        if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                        ip = @intFromFloat(jv_num);
                    }
                } else {
                    const jv = jmps[ip];
                    const jv_num: f64 = if (jv == .int) @floatFromInt(jv.int) else if (jv == .float) jv.float else return error.TypeError;
                    if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                    ip = @intFromFloat(jv_num);
                }
            },
            .range_else => {
                const jv = jmps[ip];
                const jv_num: f64 = if (jv == .int) @floatFromInt(jv.int) else if (jv == .float) jv.float else return error.TypeError;
                if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                ip = @intFromFloat(jv_num);
            },
            .with_begin => {
                const wval = try tplEvalExpr(arg, dot_stack[scope_top], funcs_v);
                if (scope_top >= dot_stack.len - 1) return error.TypeError;
                scope_top += 1;
                dot_stack[scope_top] = wval;
                ip += 1;
            },
        }
    }

    return try tplBuilderToStr(ctx, sb_obj);
}

pub fn tplRender(ctx: VMContext, src_val: Value, src: []const u8, data: Value) !Value {
    const tmpl_val = try tplParse(ctx, src_val, src);
    if (tmpl_val != .object) return error.TypeError;
    try ctx.vs.pushTempRoot(tmpl_val);
    defer ctx.vs.popTempRoot();
    return try tplExec(ctx, tmpl_val.object, data);
}

pub fn tplValid(src: []const u8) bool {
    return (tplCountInsts(src) catch return false) > 0;
}

pub fn tplAddFunc(ctx: VMContext, tmpl_obj: *Object, name: []const u8, func_val: Value) !void {
    const funcs_v = tplFieldValue(tmpl_obj, "funcs");
    if (funcs_v != .object) return error.TypeError;
    const funcs_obj = funcs_v.object;
    switch (funcs_obj.*) {
        .map => |m| {
            for (m) |*e| {
                if (tplIsStringVal(e.key)) {
                    const k = try tplAsStringVal(e.key);
                    if (std.mem.eql(u8, k, name)) {
                        e.value = func_val;
                        return;
                    }
                }
            }
            const new_items = try vmgc.vmAllocManagedSlice(ctx, MapEntry, m.len + 1);
            @memcpy(new_items[0..m.len], m);
            new_items[m.len] = .{ .key = .{ .string = try ctx.cs.internStr(name) }, .value = func_val };
            funcs_obj.* = .{ .map_managed = new_items[0 .. m.len + 1] };
        },
        .map_managed => |m| {
            for (m) |*e| {
                if (tplIsStringVal(e.key)) {
                    const k = try tplAsStringVal(e.key);
                    if (std.mem.eql(u8, k, name)) {
                        e.value = func_val;
                        return;
                    }
                }
            }
            const old_len = m.len;
            const new_items = try vmgc.vmAllocManagedSlice(ctx, MapEntry, old_len + 1);
            // Re-derive m after the allocation which may have compacted the heap:
            // funcs_obj is reachable through the template object (a GC root), so
            // after compaction funcs_obj.map_managed is updated to the new location.
            const m_now = funcs_obj.map_managed;
            @memcpy(new_items[0..old_len], m_now[0..old_len]);
            new_items[old_len] = .{ .key = .{ .string = try ctx.cs.internStr(name) }, .value = func_val };
            // Publish before freeing the old slice so paranoia doesn't see a
            // live object (funcs_obj) still pointing at the bytes being freed.
            funcs_obj.* = .{ .map_managed = new_items[0 .. old_len + 1] };
            ctx.hs.freeManagedSlice(MapEntry, m_now);
        },
        else => return error.TypeError,
    }
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .template_add_func => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = ctx.vs.stack_top;
            const tmpl_val = ctx.vs.stack[top - 3];
            const name_val = ctx.vs.stack[top - 2];
            const func_val = ctx.vs.stack[top - 1];
            if (tmpl_val != .object) return error.TypeError;
            const name = try vms.asStringValue(name_val);
            try tplAddFunc(ctx, tmpl_val.object, name, func_val);
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .template_execute => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = ctx.vs.stack_top;
            const tmpl_val = ctx.vs.stack[top - 2];
            const data = ctx.vs.stack[top - 1];
            if (tmpl_val != .object) return error.TypeError;
            const out = try tplExec(ctx, tmpl_val.object, data);
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(out);
        },
        .template_parse => {
            if (argc != nf.arity) return error.ArityMismatch;
            const src_val = ctx.vs.stack[ctx.vs.stack_top - 1];
            const src = try vms.asStringValue(src_val);
            const out = try tplParse(ctx, src_val, src);
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(out);
        },
        .template_render => {
            if (argc != nf.arity) return error.ArityMismatch;
            const top = ctx.vs.stack_top;
            const src_val = ctx.vs.stack[top - 2];
            const data = ctx.vs.stack[top - 1];
            const src = try vms.asStringValue(src_val);
            const out = try tplRender(ctx, src_val, src, data);
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(out);
        },
        .template_valid => {
            if (argc != nf.arity) return error.ArityMismatch;
            const src = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            const is_valid = tplValid(src);
            _ = try ctx.vs.vmPop();
            _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .boolean = is_valid });
        },
        else => {},
    }
}
