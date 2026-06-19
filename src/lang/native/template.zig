const std = @import("std");
const heap = @import("../../runtime/heap.zig");
const vms = @import("../vm_state.zig");
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
        .string => |s| s,
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
                if (f.key == .string and std.mem.eql(u8, f.key.string, field)) return f.value;
            }
            return .null;
        },
        else => return .null,
    }
}

fn tplFieldValue(obj: *Object, name: []const u8) Value {
    const fields = obj.struct_instance.fields;
    for (fields) |f| {
        if (f.key == .string and std.mem.eql(u8, f.key.string, name)) return f.value;
    }
    return .null;
}

fn tplIsArray(obj: *Object) bool {
    return obj.* == .array or obj.* == .array_managed;
}

fn tplAsArraySlice(obj: *Object) []Value {
    return switch (obj.*) {
        .array => |a| a,
        .array_managed => |a| a,
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
        return try tplResolveField(dot, arg.string);
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

fn tplValToDynStr(v: Value) !Value {
    return switch (v) {
        .null => vmgc.makeDynString("null"),
        .boolean => |b| vmgc.makeDynString(if (b) "true" else "false"),
        .int => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .float => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return vmgc.makeDynString(s);
        },
        .string => |s| vmgc.makeDynString(s),
        .object => |o| {
            // Root o before any allocation so GC cannot sweep it or its managed bytes.
            try vms.pushTempRoot(.{ .object = o });
            defer vms.popTempRoot();
            if (o.* == .dyn_string) return vmgc.makeDynString(o.dyn_string);
            if (o.* == .string_view) return vmgc.makeDynString(o.string_view.bytes);
            // Named values render through their underlying value.
            if (o.* == .named_value) return tplValToDynStr(o.named_value.value);
            return vmgc.makeDynString("?");
        },
        else => vmgc.makeDynString("?"),
    };
}

fn tplAppendValToBuilder(sb_obj: *Object, val: Value) !void {
    if (val == .object) {
        try vms.pushTempRoot(val);
        defer vms.popTempRoot();
        const sv = try tplValToDynStr(val);
        try vms.pushTempRoot(sv);
        defer vms.popTempRoot();
        return tplAppendToBuilder(sb_obj, try tplAsStringVal(sv));
    }
    const sv = try tplValToDynStr(val);
    try vms.pushTempRoot(sv);
    defer vms.popTempRoot();
    try tplAppendToBuilder(sb_obj, try tplAsStringVal(sv));
}

fn tplAppendToBuilder(sb_obj: *Object, s: []const u8) !void {
    if (s.len == 0) return;
    const needed = sb_obj.string_builder.len + s.len;
    if (needed > sb_obj.string_builder.buf.len) {
        const new_buf = try vmgc.vmAllocManagedBytes(needed);
        @memcpy(new_buf[0..sb_obj.string_builder.len], sb_obj.string_builder.buf[0..sb_obj.string_builder.len]);
        heap.freeBytesManaged(sb_obj.string_builder.buf);
        sb_obj.string_builder.buf = new_buf;
    }
    @memcpy(sb_obj.string_builder.buf[sb_obj.string_builder.len..needed], s);
    sb_obj.string_builder.len = needed;
}

fn tplBuilderToStr(sb_obj: *Object) !Value {
    return vmgc.makeDynString(sb_obj.string_builder.buf[0..sb_obj.string_builder.len]);
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

fn tplSplitPath(s: []const u8, sep: []const u8) !Value {
    var count: usize = 1;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
        count += 1;
        i = pos + sep.len;
    }
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = obj });
    defer vms.popTempRoot();
    const arr = try vmgc.vmAllocManagedSlice(Value, count);
    // Always copy: the template source may be a GC-managed string, and these
    // path arrays can outlive it inside a compiled template object. Attach
    // the slice as it fills so already-copied elements stay traced.
    obj.* = .{ .array_managed = arr[0..0] };
    var idx: usize = 0;
    i = 0;
    while (std.mem.indexOfPos(u8, s, i, sep)) |pos| {
        arr[idx] = try vmgc.makeDynString(s[i..pos]);
        idx += 1;
        obj.* = .{ .array_managed = arr[0..idx] };
        i = pos + sep.len;
    }
    arr[idx] = try vmgc.makeDynString(s[i..]);
    obj.* = .{ .array_managed = arr[0..count] };
    return .{ .object = obj };
}

fn tplEncodeExpr(expr: []const u8) !Value {
    const trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return .null;
    if (std.mem.eql(u8, trimmed, ".")) return .null;
    if (trimmed[0] == '$') return .{ .string = trimmed[1..] };
    if (trimmed[0] == '.') {
        const path = trimmed[1..];
        if (std.mem.indexOf(u8, path, ".")) |_| {
            return try tplSplitPath(path, ".");
        }
        return .{ .string = path };
    }
    return .{ .string = trimmed };
}

fn tplParseTag(tag: []const u8) !struct { op: TplOp, arg: Value } {
    const trimmed = std.mem.trim(u8, tag, " \t\n\r");
    if (trimmed.len == 0) return error.InvalidTemplate;

    if (std.mem.eql(u8, trimmed, "end")) return .{ .op = .end, .arg = .null };
    if (std.mem.eql(u8, trimmed, "else")) return .{ .op = .if_else, .arg = .null };
    if (std.mem.eql(u8, trimmed, "break")) return .{ .op = .break_inst, .arg = .null };
    if (std.mem.eql(u8, trimmed, "continue")) return .{ .op = .continue_inst, .arg = .null };
    if (std.mem.eql(u8, trimmed, ".")) return .{ .op = .root_ref, .arg = .null };

    if (std.mem.startsWith(u8, trimmed, "if ")) {
        const expr = std.mem.trim(u8, trimmed[3..], " \t");
        return .{ .op = .if_begin, .arg = try tplEncodeExpr(expr) };
    }
    if (std.mem.startsWith(u8, trimmed, "range ")) {
        const expr = std.mem.trim(u8, trimmed[6..], " \t");
        return .{ .op = .range_begin, .arg = try tplEncodeExpr(expr) };
    }
    if (std.mem.startsWith(u8, trimmed, "with ")) {
        const expr = std.mem.trim(u8, trimmed[5..], " \t");
        return .{ .op = .with_begin, .arg = try tplEncodeExpr(expr) };
    }
    if (trimmed.len >= 2 and trimmed[0] == '$') {
        if (std.mem.indexOf(u8, trimmed, ":=")) |pos| {
            const vname = std.mem.trim(u8, trimmed[1..pos], " \t");
            return .{ .op = .assign, .arg = .{ .string = vname } };
        }
        const vname = trimmed[1..];
        return .{ .op = .var_ref, .arg = .{ .string = vname } };
    }
    if (trimmed[0] == '.') {
        const path = trimmed[1..];
        if (std.mem.indexOf(u8, path, ".")) |_| {
            return .{ .op = .chain, .arg = try tplSplitPath(path, ".") };
        }
        return .{ .op = .field, .arg = .{ .string = path } };
    }
    const space_pos = std.mem.indexOfAny(u8, trimmed, " \t");
    if (space_pos) |pos| {
        const fname = trimmed[0..pos];
        return .{ .op = .call_fn, .arg = .{ .string = fname } };
    }

    return error.InvalidTemplate;
}

fn tplBuildObj(src_val: Value, ops: []Value, args: []Value, jmp: []Value) !*Object {
    // Push any GC objects in args as temp roots before any allocation that could
    // trigger GC. Without this, chain-path arrays from tplSplitPath stored in
    // args[] are unreachable during GC and get collected.
    const args_root_base = vms.vmState().temp_root_top;
    for (args) |arg| {
        if (arg == .object) try vms.pushTempRoot(arg);
    }
    defer vms.vmState().temp_root_top = args_root_base;

    const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
    any_alts[0] = .{ .typ = .any };
    const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

    const field_specs = heap.bump(StructFieldSpec, 5) orelse return error.OutOfMemory;
    field_specs[0] = .{ .name = "__ops", .typ = any_spec, .is_const = true };
    field_specs[1] = .{ .name = "__args", .typ = any_spec, .is_const = true };
    field_specs[2] = .{ .name = "__jmp", .typ = any_spec, .is_const = true };
    field_specs[3] = .{ .name = "__src", .typ = any_spec, .is_const = true };
    field_specs[4] = .{ .name = "funcs", .typ = any_spec, .is_const = false };

    const typ_obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = typ_obj });
    defer vms.popTempRoot();
    typ_obj.* = .{ .struct_type = StructTypeObj{
        .name = "Template",
        .qualified_name = TemplateTypeQualifiedName,
        .fields = field_specs[0..5],
    } };

    const inst_fields = try vmgc.vmAllocManagedSlice(MapEntry, 5);
    const inst_obj = try vmgc.vmAllocObject();
    try vms.pushTempRoot(.{ .object = inst_obj });
    defer vms.popTempRoot();
    inst_obj.* = .{ .struct_instance = .{ .typ = typ_obj, .fields = inst_fields } };

    const ops_obj = try vmgc.vmAllocObject();
    ops_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = ops_obj });
    defer vms.popTempRoot();
    ops_obj.* = .{ .array_managed = ops };

    const args_obj = try vmgc.vmAllocObject();
    args_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = args_obj });
    defer vms.popTempRoot();
    args_obj.* = .{ .array_managed = args };

    const jmp_obj = try vmgc.vmAllocObject();
    jmp_obj.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = jmp_obj });
    defer vms.popTempRoot();
    jmp_obj.* = .{ .array_managed = jmp };

    const funcs_obj = try vmgc.vmAllocObject();
    funcs_obj.* = .{ .map = &[_]MapEntry{} };

    inst_fields[0] = .{ .key = .{ .string = "__ops" }, .value = .{ .object = ops_obj } };
    inst_fields[1] = .{ .key = .{ .string = "__args" }, .value = .{ .object = args_obj } };
    inst_fields[2] = .{ .key = .{ .string = "__jmp" }, .value = .{ .object = jmp_obj } };
    inst_fields[3] = .{ .key = .{ .string = "__src" }, .value = src_val };
    inst_fields[4] = .{ .key = .{ .string = "funcs" }, .value = .{ .object = funcs_obj } };

    return inst_obj;
}

pub fn tplParse(src_val: Value, src: []const u8) !Value {
    if (src.len == 0) {
        const obj = try tplBuildObj(src_val, &[_]Value{}, &[_]Value{}, &[_]Value{});
        return .{ .object = obj };
    }
    const inst_count = try tplCountInsts(src);
    if (inst_count == 0) {
        const obj = try tplBuildObj(src_val, &[_]Value{}, &[_]Value{}, &[_]Value{});
        return .{ .object = obj };
    }
    // Root the parse-time slices immediately so that GC triggered by tplParseTag
    // / tplSplitPath cannot sweep elements already written into args[].
    const ops_root = try vmgc.vmAllocObject();
    ops_root.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = ops_root });
    defer vms.popTempRoot();
    const ops = try vmgc.vmAllocManagedSlice(Value, inst_count);
    ops_root.* = .{ .array_managed = ops };
    for (ops) |*v| v.* = .null;

    const args_root = try vmgc.vmAllocObject();
    args_root.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = args_root });
    defer vms.popTempRoot();
    const args = try vmgc.vmAllocManagedSlice(Value, inst_count);
    args_root.* = .{ .array_managed = args };
    for (args) |*v| v.* = .null;

    const jmp_root = try vmgc.vmAllocObject();
    jmp_root.* = .{ .array = &[_]Value{} };
    try vms.pushTempRoot(.{ .object = jmp_root });
    defer vms.popTempRoot();
    const jmp = try vmgc.vmAllocManagedSlice(Value, inst_count);
    jmp_root.* = .{ .array_managed = jmp };
    for (jmp) |*v| v.* = .null;

    var idx: usize = 0;
    var pos: usize = 0;
    var ctrl_stack: [64]TplCtrlEntry = undefined;
    var ctrl_top: usize = 0;

    while (pos < src.len) {
        if (std.mem.indexOfPos(u8, src, pos, "{{")) |start| {
            if (start > pos) {
                ops[idx] = .{ .float = @floatFromInt(@intFromEnum(TplOp.text)) };
                args[idx] = .{ .string = src[pos..start] };
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
            const parsed = try tplParseTag(tag);

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
                    ctrl_stack[ctrl_top] = .{ .kind = .if_block, .if_idx = idx, .else_idx = std.math.maxInt(usize) };
                    ctrl_top += 1;
                } else if (parsed.op == .range_begin) {
                    ctrl_stack[ctrl_top] = .{ .kind = .range_block, .if_idx = idx, .else_idx = std.math.maxInt(usize) };
                    ctrl_top += 1;
                } else if (parsed.op == .with_begin) {
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
            args[idx] = .{ .string = src[pos..] };
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

    const obj = try tplBuildObj(src_val, ops[0..idx], args[0..idx], jmp[0..idx]);
    return .{ .object = obj };
}

const IterState = struct {
    arr: *Object,
    index: usize,
    body_ip: usize,
};

pub fn tplExec(tmpl: *Object, data: Value) !Value {
    const ops_v = tplFieldValue(tmpl, "__ops");
    const args_v = tplFieldValue(tmpl, "__args");
    const jmp_v = tplFieldValue(tmpl, "__jmp");
    const funcs_v = tplFieldValue(tmpl, "funcs");

    if (ops_v != .object) return error.TypeError;
    const ops = tplAsArraySlice(ops_v.object);
    const args = tplAsArraySlice(args_v.object);
    const jmps = tplAsArraySlice(jmp_v.object);

    const sb_obj = try vmgc.vmAllocObject();
    sb_obj.* = .{ .string_builder = .{ .buf = &[_]u8{}, .len = 0 } };
    try vms.pushTempRoot(.{ .object = sb_obj });
    defer vms.popTempRoot();

    var ip: usize = 0;
    var dot_stack: [256]Value = undefined;
    var scope_top: usize = 0;
    dot_stack[scope_top] = data;
    var iter_stack: [64]IterState = undefined;
    var iter_top: usize = 0;

    while (ip < ops.len) {
        const op_v = ops[ip];
        if (op_v != .int and op_v != .float) return error.TypeError;
        const op_num = if (op_v == .int) op_v.int else op_v.float;
        if (op_num < 0 or op_num > 14) return error.TypeError;
        const op: TplOp = @enumFromInt(@as(u8, @intFromFloat(op_num)));
        const arg = args[ip];

        switch (op) {
            .text => {
                const s = try tplAsStringVal(arg);
                try tplAppendToBuilder(sb_obj, s);
                ip += 1;
            },
            .field => {
                const fname = try tplAsStringVal(arg);
                const val = try tplResolveField(dot_stack[scope_top], fname);
                try tplAppendValToBuilder(sb_obj, val);
                ip += 1;
            },
            .chain => {
                const items = tplAsArraySlice(arg.object);
                var cur = dot_stack[scope_top];
                for (items) |item| {
                    const name = try tplAsStringVal(item);
                    cur = try tplResolveField(cur, name);
                }
                try tplAppendValToBuilder(sb_obj, cur);
                ip += 1;
            },
            .root_ref => {
                try tplAppendValToBuilder(sb_obj, dot_stack[scope_top]);
                ip += 1;
            },
            .var_ref, .call_fn, .assign, .break_inst, .continue_inst => {
                ip += 1;
            },
            .if_begin => {
                const cond = try tplEvalExpr(arg, dot_stack[scope_top], funcs_v);
                const cond_bool = cond.asBool() catch {
                    vms.setRuntimeErr("{{{{if}}}} condition must be bool, got {s}", .{vmtyp.runtimeTypeName(cond)});
                    return error.TypeError;
                };
                if (!cond_bool) {
                    const jv = jmps[ip];
                    const jv_num = if (jv == .int) jv.int else if (jv == .float) jv.float else return error.TypeError;
                    if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                    ip = @intFromFloat(jv_num);
                } else {
                    ip += 1;
                }
            },
            .if_else => {
                const jv = jmps[ip];
                const jv_num = if (jv == .int) jv.int else if (jv == .float) jv.float else return error.TypeError;
                if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                ip = @intFromFloat(jv_num);
            },
            .end => {
                const jv = jmps[ip];
                const jv_num = if (jv == .int) jv.int else if (jv == .float) jv.float else null;
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
                } else if ((jv == .int or jv == .float) and (if (jv == .int) jv.int else jv.float) < 0 and (if (jv == .int) jv.int else jv.float) > -@as(f64, @floatFromInt(std.math.maxInt(usize)))) {
                    const pop = @as(usize, @intFromFloat(-(if (jv == .int) jv.int else jv.float)));
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
                    if ((jv != .int and jv != .float) or (if (jv == .int) jv.int else jv.float) < 0 or (if (jv == .int) jv.int else jv.float) >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                    ip = @intFromFloat(if (jv == .int) jv.int else jv.float);
                        }
                    } else {
                        const jv = jmps[ip];
                        const jv_num = if (jv == .int) jv.int else if (jv == .float) jv.float else return error.TypeError;
                        if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                        ip = @intFromFloat(jv_num);
                    }
                } else {
                    const jv = jmps[ip];
                    const jv_num = if (jv == .int) jv.int else if (jv == .float) jv.float else return error.TypeError;
                    if (jv_num < 0 or jv_num >= @as(f64, @floatFromInt(ops.len))) return error.TypeError;
                    ip = @intFromFloat(jv_num);
                }
            },
            .range_else => {
                const jv = jmps[ip];
                const jv_num = if (jv == .int) jv.int else if (jv == .float) jv.float else return error.TypeError;
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

    return try tplBuilderToStr(sb_obj);
}

pub fn tplRender(src_val: Value, src: []const u8, data: Value) !Value {
    const tmpl_val = try tplParse(src_val, src);
    if (tmpl_val != .object) return error.TypeError;
    try vms.pushTempRoot(tmpl_val);
    defer vms.popTempRoot();
    return try tplExec(tmpl_val.object, data);
}

pub fn tplValid(src: []const u8) bool {
    return (tplCountInsts(src) catch return false) > 0;
}

pub fn tplAddFunc(tmpl_obj: *Object, name: []const u8, func_val: Value) !void {
    const funcs_v = tplFieldValue(tmpl_obj, "funcs");
    if (funcs_v != .object) return error.TypeError;
    const funcs_obj = funcs_v.object;
    switch (funcs_obj.*) {
        .map => |m| {
            var fi: usize = 0;
            while (fi < m.len) : (fi += 1) {
                if (tplIsStringVal(m[fi].key)) {
                    const k = try tplAsStringVal(m[fi].key);
                    if (std.mem.eql(u8, k, name)) {
                        m[fi].value = func_val;
                        return;
                    }
                }
            }
            const new_items = try vmgc.vmAllocManagedSlice(MapEntry, m.len + 1);
            @memcpy(new_items[0..m.len], m);
            new_items[m.len] = .{ .key = .{ .string = name }, .value = func_val };
            funcs_obj.* = .{ .map_managed = new_items[0 .. m.len + 1] };
        },
        .map_managed => |m| {
            var fi: usize = 0;
            while (fi < m.len) : (fi += 1) {
                if (tplIsStringVal(m[fi].key)) {
                    const k = try tplAsStringVal(m[fi].key);
                    if (std.mem.eql(u8, k, name)) {
                        m[fi].value = func_val;
                        return;
                    }
                }
            }
            const new_items = try vmgc.vmAllocManagedSlice(MapEntry, m.len + 1);
            @memcpy(new_items[0..m.len], m);
            new_items[m.len] = .{ .key = .{ .string = name }, .value = func_val };
            heap.freeManagedSlice(MapEntry, m);
            funcs_obj.* = .{ .map_managed = new_items[0 .. m.len + 1] };
        },
        else => return error.TypeError,
    }
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .template_add_func => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const tmpl_val = vms.vmState().stack[top - 3];
            const name_val = vms.vmState().stack[top - 2];
            const func_val = vms.vmState().stack[top - 1];
            if (tmpl_val != .object) return error.TypeError;
            const name = try vms.asStringValue(name_val);
            try tplAddFunc(tmpl_val.object, name, func_val);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.null);
        },
        .template_execute => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const tmpl_val = vms.vmState().stack[top - 2];
            const data = vms.vmState().stack[top - 1];
            if (tmpl_val != .object) return error.TypeError;
            const out = try tplExec(tmpl_val.object, data);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_parse => {

            if (argc != nf.arity) return error.ArityMismatch;
            const src_val = vms.vmState().stack[vms.vmState().stack_top - 1];
            const src = try vms.asStringValue(src_val);
            const out = try tplParse(src_val, src);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_render => {

            if (argc != nf.arity) return error.ArityMismatch;
            const top = vms.vmState().stack_top;
            const src_val = vms.vmState().stack[top - 2];
            const data = vms.vmState().stack[top - 1];
            const src = try vms.asStringValue(src_val);
            const out = try tplRender(src_val, src, data);
            _ = try vms.vmPop(); _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .template_valid => {

            if (argc != nf.arity) return error.ArityMismatch;
            const src = try vms.asStringValue(vms.vmState().stack[vms.vmState().stack_top - 1]);
            const is_valid = tplValid(src);
            _ = try vms.vmPop(); _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = is_valid });
        },
        else => {},
    }
}
