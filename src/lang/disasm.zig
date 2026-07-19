const std = @import("std");
const chunk = @import("chunk.zig");
const Op = @import("op.zig").Op;
const io = @import("../runtime/io.zig");
const value = @import("value.zig");
const Value = value.Value;

fn readU16(cs: *const chunk.State, pos: usize) u16 {
    return (@as(u16, cs.codeByteAt(pos)) << 8) | @as(u16, cs.codeByteAt(pos + 1));
}

fn readU32(cs: *const chunk.State, pos: usize) u32 {
    return (@as(u32, cs.codeByteAt(pos)) << 24) |
        (@as(u32, cs.codeByteAt(pos + 1)) << 16) |
        (@as(u32, cs.codeByteAt(pos + 2)) << 8) |
        @as(u32, cs.codeByteAt(pos + 3));
}

fn writeOffset(n: usize) void {
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{x:0>4}", .{n}) catch return;
    io.write(s);
}

fn writeNum(n: usize) void {
    io.writeUint(@intCast(n));
}

fn writeConst(cs: *const chunk.State, idx: u16) void {
    const v = cs.constAt(idx) catch {
        io.write("<?>");
        return;
    };
    switch (v) {
        .int => |n| io.writeInt(n),
        .float => |n| io.writeF64(n),
        .decimal => |n| io.writeInt(n),
        .rune => |r| {
            io.write("`");
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(r, &buf) catch 0;
            if (len > 0) io.write(buf[0..len]);
            io.write("`");
        },
        .boolean => |b| io.write(if (b) "true" else "false"),
        .string => |s| {
            io.write("\"");
            io.write(s.bytes);
            io.write("\"");
        },
        .error_value => |s| {
            io.write("error(\"");
            io.write(s.bytes);
            io.write("\")");
        },
        .object => |obj| switch (obj.*) {
            .function => |f| {
                io.write("<func");
                if (f.name.len > 0) {
                    io.write(" ");
                    io.write(f.name);
                }
                io.write(" @");
                writeNum(f.ip);
                io.write(" arity=");
                writeNum(f.arity);
                io.write(">");
            },
            .named_type => |nt| {
                io.write("<type ");
                io.write(nt.name);
                io.write(">");
            },
            .struct_type => |st| {
                io.write("<struct ");
                io.write(st.name);
                io.write(">");
            },
            .variant_type => |vt| {
                io.write("<variant ");
                io.write(vt.name);
                io.write(">");
            },
            .enum_type => |et| {
                io.write("<enum ");
                io.write(et.name);
                io.write(">");
            },
            .variant_ctor => |vc| {
                io.write("<ctor ");
                io.write(vc.tag);
                io.write(">");
            },
            else => io.write("<object>"),
        },
        .null => io.write("null"),
        .inline_variant => |iv| {
            io.write("<variant:");
            io.write(value.objectAtIdx(iv.typ_idx).variant_type.name);
            io.write(">");
        },
    }
}

fn printConstPool(cs: *const chunk.State) void {
    const n = cs.constCount();
    io.write("constants (");
    writeNum(n);
    io.write("):\n");
    for (0..n) |i| {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "  {d:>3}  ", .{i}) catch "  ???  ";
        io.write(s);
        writeConst(cs, @intCast(i));
        io.write("\n");
    }
}

// Collect function entry IPs from the constant pool.
fn collectFuncLabels(cs: *const chunk.State, ips: []usize, names: [][]const u8) usize {
    var count: usize = 0;
    const n = cs.constCount();
    for (0..n) |i| {
        if (count >= ips.len) break;
        const v = cs.constAt(i) catch continue;
        if (v == .object and v.object.* == .function) {
            ips[count] = v.object.function.ip;
            names[count] = v.object.function.name;
            count += 1;
        }
    }
    return count;
}

fn printFuncLabel(pos: usize, ips: []const usize, names: []const []const u8) void {
    for (ips, names) |ip, name| {
        if (ip == pos) {
            io.write("\n<");
            io.write(if (name.len > 0) name else "anon");
            io.write(">:\n");
            return;
        }
    }
}

fn printLine(line: u16) void {
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:>4}  ", .{line}) catch " ???  ";
    io.write(s);
}

pub fn disassemble(cs: *const chunk.State) void {
    printConstPool(cs);
    io.write("\n");

    var func_ips: [512]usize = undefined;
    var func_names: [512][]const u8 = undefined;
    const func_count = collectFuncLabels(cs, &func_ips, &func_names);

    io.write("bytecode:\n");
    io.write("<main>:\n");

    const code_len = cs.codeLen();
    var i: usize = 0;
    while (i < code_len) {
        printFuncLabel(i, func_ips[0..func_count], func_names[0..func_count]);

        const start = i;
        writeOffset(start);
        io.write("  ");
        printLine(cs.lineAt(start));

        const raw = cs.codeByteAt(i);
        i += 1;

        if ((raw > @intFromEnum(Op.validate_named_range) and raw < @intFromEnum(Op.const_eq)) or raw > @intFromEnum(Op.inc_global_const)) {
            io.write("???\n");
            continue;
        }
        const op: Op = @enumFromInt(raw);

        switch (op) {
            // --- 2-byte const index ops ---
            .constant, .def_global, .make_closure, .ret_const, .const_eq, .const_sub, .const_add, .const_lt, .const_gt, .variant_check, .assert_interface, .assert_struct, .check_named_predicate, .validate_named_range => {
                const idx = readU16(cs, i);
                i += 2;
                io.write(@tagName(op));
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write("\n");
            },

            // --- jumps: 4-byte forward offset ---
            .jump, .jump_if_false, .jump_if_not_null, .jif_pop => {
                const off = readU32(cs, i);
                i += 4;
                const target = start + 5 + @as(usize, off);
                io.write(@tagName(op));
                io.write(" -> ");
                writeOffset(target);
                io.write("\n");
            },

            // --- loop: 4-byte backward offset ---
            .loop => {
                const off = readU32(cs, i);
                i += 4;
                const target = start + 5 - @as(usize, off);
                io.write("loop -> ");
                writeOffset(target);
                io.write("\n");
            },

            // call: [op][argc][ic_hi][ic_lo]
            .call, .call_tail => {
                const argc = cs.codeByteAt(i) & 0x7F;
                const ic = (@as(u16, cs.codeByteAt(i + 1)) << 8) | @as(u16, cs.codeByteAt(i + 2));
                i += 3;
                io.write(@tagName(op));
                io.write(" ");
                writeNum(argc);
                if (ic != 0xFFFF) {
                    io.write(" [ic=");
                    writeNum(ic);
                    io.write("]");
                }
                io.write("\n");
            },
            .call_spread => {
                const argc = cs.codeByteAt(i) & 0x7F;
                const spread_n = cs.codeByteAt(i + 1);
                const ic = (@as(u16, cs.codeByteAt(i + 2)) << 8) | @as(u16, cs.codeByteAt(i + 3));
                i += 4;
                io.write("call_spread ");
                writeNum(argc);
                io.write(" n=");
                writeNum(spread_n);
                if (ic != 0xFFFF) {
                    io.write(" [ic=");
                    writeNum(ic);
                    io.write("]");
                }
                io.write("\n");
            },

            // --- 1-byte operand ops ---
            .get_local, .set_local, .get_upvalue, .set_upvalue, .close_upvalue, .get_local_ret, .defer_call, .build_array, .build_map, .build_tuple, .build_struct_instance, .tuple_check_arity, .tuple_get, .tuple_get_keep, .get_slice, .assert_type => {
                const slot = cs.codeByteAt(i);
                i += 1;
                io.write(@tagName(op));
                io.write(" ");
                writeNum(slot);
                io.write("\n");
            },

            // --- get_global / set_global: op + name(2) + ic(2) ---
            .get_global, .set_global => {
                const name_idx = readU16(cs, i);
                i += 2;
                const ic = readU16(cs, i);
                i += 2;
                io.write(@tagName(op));
                io.write(" ");
                writeConst(cs, name_idx);
                if (ic != 0xffff) {
                    io.write(" ic=");
                    writeNum(ic);
                }
                io.write("\n");
            },

            // --- get_field / set_field: op + name(2) + ic_type(2) + ic_fidx(1) ---
            .get_field, .set_field => {
                const name_idx = readU16(cs, i);
                i += 2;
                const ic_type = readU16(cs, i);
                i += 2;
                const ic_fidx = cs.codeByteAt(i);
                i += 1;
                io.write(@tagName(op));
                io.write(" ");
                writeConst(cs, name_idx);
                if (ic_type != 0xffff) {
                    io.write(" ic_type=");
                    writeNum(ic_type);
                    io.write(" ic_fidx=");
                    writeNum(ic_fidx);
                }
                io.write("\n");
            },

            // --- invoke_method: op + name(2) + argc(1) + ic_type(2) + ic_func(2) ---
            .invoke_method => {
                const name_idx = readU16(cs, i);
                i += 2;
                const argc = cs.codeByteAt(i) & 0x7F;
                i += 1;
                const ic_type = readU16(cs, i);
                i += 2;
                const ic_func = readU16(cs, i);
                i += 2;
                io.write("invoke_method ");
                writeConst(cs, name_idx);
                io.write(" argc=");
                writeNum(argc);
                if (ic_type != 0xffff) {
                    io.write(" ic=");
                    writeNum(ic_type);
                    io.write("/");
                    writeNum(ic_func);
                }
                io.write("\n");
            },

            // --- defer_invoke_method: op + name(2) + argc(1) ---
            .defer_invoke_method => {
                const name_idx = readU16(cs, i);
                i += 2;
                const argc = cs.codeByteAt(i) & 0x7F;
                i += 1;
                io.write("defer_invoke_method ");
                writeConst(cs, name_idx);
                io.write(" argc=");
                writeNum(argc);
                io.write("\n");
            },

            // --- triple-fused: op + slot(1) + skip(1) + idx(2) ---
            .get_local_const_eq, .get_local_const_sub, .get_local_const_add, .get_local_const_lt, .get_local_const_gt => {
                const slot = cs.codeByteAt(i);
                i += 1;
                i += 1; // skip byte
                const idx = readU16(cs, i);
                i += 2;
                io.write(@tagName(op));
                io.write(" local=");
                writeNum(slot);
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write("\n");
            },
            // --- get_local_const_sub + call fused: op + slot(1) + skip(1) + idx(2) + argc(1) ---
            .get_local_const_sub_call, .get_local_const_sub_call_tail => {
                const slot = cs.codeByteAt(i);
                i += 1;
                i += 1; // skip byte
                const idx = readU16(cs, i);
                i += 2;
                const argc = cs.codeByteAt(i) & 0x7F;
                i += 1;
                io.write(@tagName(op));
                io.write(" local=");
                writeNum(slot);
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write(" argc=");
                writeNum(argc);
                io.write("\n");
            },
            // --- inc_global_const: op + name(2) + ic(2) + add_skip(1) + val(2) ---
            .inc_global_const => {
                const name_idx = readU16(cs, i);
                i += 2;
                const ic = readU16(cs, i);
                i += 2;
                i += 1; // skip add byte
                const val_idx = readU16(cs, i);
                i += 2;
                io.write("inc_global_const ");
                writeConst(cs, name_idx);
                if (ic != 0xffff) {
                    io.write(" ic=");
                    writeNum(ic);
                }
                io.write(" [");
                writeNum(val_idx);
                io.write("] ");
                writeConst(cs, val_idx);
                io.write("\n");
            },

            // --- hexa-fused: op + name(2) + ic(2) + glcs_skip(1) + slot(1) + sub_skip(1) + idx(2) + argc(1) ---
            .call_global_local_sub_const, .call_global_local_sub_const_tail => {
                const name_idx = readU16(cs, i);
                i += 2;
                const ic = readU16(cs, i);
                i += 2;
                i += 1; // skip get_local_const_sub_call byte
                const slot = cs.codeByteAt(i);
                i += 1;
                i += 1; // skip const_sub byte
                const idx = readU16(cs, i);
                i += 2;
                const argc = cs.codeByteAt(i) & 0x7F;
                i += 1;
                // Trailing call-IC slot (2 bytes) — previously unconsumed,
                // which made the decoder print the bytes as ??? opcodes.
                const call_ic = readU16(cs, i);
                i += 2;
                io.write(@tagName(op));
                io.write(" ");
                writeConst(cs, name_idx);
                if (ic != 0xffff) {
                    io.write(" ic=");
                    writeNum(ic);
                }
                io.write(" local=");
                writeNum(slot);
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write(" argc=");
                writeNum(argc);
                if (call_ic != 0xffff) {
                    io.write(" call_ic=");
                    writeNum(call_ic);
                }
                io.write("\n");
            },

            // --- quad-fused: op + slot(1) + skip(1) + idx(2) + jmp(4) ---
            .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop => {
                const slot = cs.codeByteAt(i);
                i += 1;
                i += 1; // skip byte
                const idx = readU16(cs, i);
                i += 2;
                const jmp = readU32(cs, i);
                i += 4;
                const target = start + 9 + @as(usize, jmp);
                io.write(@tagName(op));
                io.write(" local=");
                writeNum(slot);
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write(" -> ");
                writeOffset(target);
                io.write("\n");
            },

            // --- quint-fused: op + slot(1) + skip(1) + idx(2) + exit_jmp(4) + body_jmp(4) ---
            .get_local_const_lt_jif_pop_jump => {
                const slot = cs.codeByteAt(i);
                i += 1;
                i += 1; // skip byte
                const idx = readU16(cs, i);
                i += 2;
                const exit_jmp = readU32(cs, i);
                i += 4;
                const body_jmp = readU32(cs, i);
                i += 4;
                const exit_target = start + 9 + @as(usize, exit_jmp);
                const body_target = start + 13 + @as(usize, body_jmp);
                io.write("get_local_const_lt_jif_pop_jump local=");
                writeNum(slot);
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write(" exit->");
                writeOffset(exit_target);
                io.write(" body->");
                writeOffset(body_target);
                io.write("\n");
            },

            // --- global triple-fused: op + name(2) + ic(2) + skip(1) + idx(2) ---
            .get_global_const_eq, .get_global_const_sub, .get_global_const_add, .get_global_const_lt => {
                const name_idx = readU16(cs, i);
                i += 2;
                const ic = readU16(cs, i);
                i += 2;
                i += 1; // skip byte
                const idx = readU16(cs, i);
                i += 2;
                io.write(@tagName(op));
                io.write(" ");
                writeConst(cs, name_idx);
                if (ic != 0xffff) {
                    io.write(" ic=");
                    writeNum(ic);
                }
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write("\n");
            },
            // --- global quad-fused: op + name(2) + ic(2) + skip(1) + idx(2) + jmp(4) ---
            .get_global_const_lt_jif_pop => {
                const name_idx = readU16(cs, i);
                i += 2;
                const ic = readU16(cs, i);
                i += 2;
                i += 1; // skip byte
                const idx = readU16(cs, i);
                i += 2;
                const jmp = readU32(cs, i);
                i += 4;
                const target = start + 12 + @as(usize, jmp);
                io.write(@tagName(op));
                io.write(" ");
                writeConst(cs, name_idx);
                if (ic != 0xffff) {
                    io.write(" ic=");
                    writeNum(ic);
                }
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write(" -> ");
                writeOffset(target);
                io.write("\n");
            },
            // --- get_local_get_field: op + slot(1) + skip(1) + name(2) + ic_type(2) + ic_fidx(1) ---
            .get_local_get_field => {
                const slot = cs.codeByteAt(i);
                i += 1;
                i += 1; // skip byte
                const name_idx = readU16(cs, i);
                i += 2;
                const ic_type = readU16(cs, i);
                i += 2;
                const ic_fidx = cs.codeByteAt(i);
                i += 1;
                io.write("get_local_get_field local=");
                writeNum(slot);
                io.write(" field=");
                writeConst(cs, name_idx);
                if (ic_type != 0xffff) {
                    io.write(" ic_type=");
                    writeNum(ic_type);
                    io.write(" ic_fidx=");
                    writeNum(ic_fidx);
                }
                io.write("\n");
            },

            // --- close_upvalue_loop: op + slot(1) + off(4) ---
            .close_upvalue_loop => {
                const slot = cs.codeByteAt(i);
                i += 1;
                const off = readU32(cs, i);
                i += 4;
                const target = start + 6 - @as(usize, off);
                io.write("close_upvalue_loop slot=");
                writeNum(slot);
                io.write(" -> ");
                writeOffset(target);
                io.write("\n");
            },

            // --- set_global_loop: op + name(2) + ic(2) + off(4) ---
            .set_global_loop => {
                const name_idx = readU16(cs, i);
                i += 2;
                const ic = readU16(cs, i);
                i += 2;
                const off = readU32(cs, i);
                i += 4;
                const target = start + 9 - @as(usize, off);
                io.write("set_global_loop ");
                writeConst(cs, name_idx);
                if (ic != 0xffff) {
                    io.write(" ic=");
                    writeNum(ic);
                }
                io.write(" -> ");
                writeOffset(target);
                io.write("\n");
            },

            // --- fused binop+ret: no operands ---
            .add_ret => {
                io.write("add_ret\n");
            },
            // --- fused local += local: op + dst(1) + src(1) ---
            .local_add_local => {
                const dst = cs.codeByteAt(i);
                i += 1;
                const src = cs.codeByteAt(i);
                i += 1;
                io.write("local_add_local dst=");
                writeNum(dst);
                io.write(" src=");
                writeNum(src);
                io.write("\n");
            },
            // --- fused local += const: op + dst(1) + idx(2) ---
            .local_add_const => {
                const dst = cs.codeByteAt(i);
                i += 1;
                const idx = readU16(cs, i);
                i += 2;
                io.write("local_add_const dst=");
                writeNum(dst);
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write("\n");
            },
            // --- local_add_field: op + dst(1) + src(1) + skip(1) + name(2) + ic_type(2) + ic_fidx(1) ---
            .local_add_field => {
                const dst = cs.codeByteAt(i);
                i += 1;
                const src = cs.codeByteAt(i);
                i += 1;
                i += 1; // skip byte
                const name_idx = readU16(cs, i);
                i += 2;
                const ic_type = readU16(cs, i);
                i += 2;
                const ic_fidx = cs.codeByteAt(i);
                i += 1;
                io.write("local_add_field dst=");
                writeNum(dst);
                io.write(" src=");
                writeNum(src);
                io.write(" field=");
                writeConst(cs, name_idx);
                if (ic_type != 0xffff) {
                    io.write(" ic_type=");
                    writeNum(ic_type);
                    io.write(" ic_fidx=");
                    writeNum(ic_fidx);
                }
                io.write("\n");
            },
            // --- fused local += const + loop: op + dst(1) + idx(2) + off(4) ---
            .local_add_const_loop => {
                const dst = cs.codeByteAt(i);
                i += 1;
                const idx = readU16(cs, i);
                i += 2;
                const off = readU32(cs, i);
                i += 4;
                const target = start + 8 - @as(usize, off);
                io.write("local_add_const_loop dst=");
                writeNum(dst);
                io.write(" [");
                writeNum(idx);
                io.write("] ");
                writeConst(cs, idx);
                io.write(" -> ");
                writeOffset(target);
                io.write("\n");
            },
            // --- no operands ---
            else => {
                io.write(@tagName(op));
                io.write("\n");
            },
        }
    }
}
