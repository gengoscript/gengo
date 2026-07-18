const std = @import("std");
const Op = @import("op.zig").Op;

pub const DecodedInstruction = struct {
    op: Op,
    width: usize,
    const_index: ?usize = null,
    jump_target: ?usize = null,
};

fn readU16At(state: anytype, pos: usize) !u16 {
    if (pos + 1 >= state.code_len) return error.BytecodeOutOfBounds;
    return (@as(u16, state.code[pos]) << 8) | @as(u16, state.code[pos + 1]);
}

fn readU32At(state: anytype, pos: usize) !u32 {
    if (pos + 3 >= state.code_len) return error.BytecodeOutOfBounds;
    return (@as(u32, state.code[pos]) << 24) |
        (@as(u32, state.code[pos + 1]) << 16) |
        (@as(u32, state.code[pos + 2]) << 8) |
        @as(u32, state.code[pos + 3]);
}

pub fn decodeAt(state: anytype, pos: usize) !DecodedInstruction {
    if (pos >= state.code_len) return error.BytecodeOutOfBounds;

    const raw = state.code[pos];
    if (@import("op.zig").is_reserved[raw]) return error.BadOpcode;
    const op: Op = @enumFromInt(raw);

    return switch (op) {
        .constant, .def_global, .make_closure, .ret_const,
        .const_eq, .const_sub, .const_add, .const_lt, .const_gt,
        .assert_interface, .assert_struct, .variant_check,
        .check_named_predicate, .validate_named_range => .{
            .op = op,
            .width = 3,
            .const_index = try readU16At(state, pos + 1),
        },

        .jump, .jump_if_false, .jump_if_not_null, .jif_pop => blk: {
            const off = try readU32At(state, pos + 1);
            break :blk .{
                .op = op,
                .width = 5,
                .jump_target = pos + 5 + @as(usize, off),
            };
        },

        .loop => blk: {
            const off = try readU32At(state, pos + 1);
            const width: usize = 5;
            if (@as(usize, off) > pos + width) return error.BadJumpTarget;
            break :blk .{
                .op = op,
                .width = width,
                .jump_target = pos + width - @as(usize, off),
            };
        },

        // call: [op][argc][ic_hi][ic_lo] — 4 bytes (IC slot = object pool index, 0xFFFF = cold)
        .call => .{ .op = op, .width = 4 },
        .call_tail => .{ .op = op, .width = 4 },
        // call_spread: [op][argc][spread_n][ic_hi][ic_lo] — 5 bytes
        .call_spread => .{ .op = op, .width = 5 },

        .get_local, .set_local, .get_upvalue, .set_upvalue, .close_upvalue,
        .get_local_ret, .defer_call,
        .build_array, .build_map, .build_tuple, .build_struct_instance,
        .tuple_check_arity, .tuple_get, .tuple_get_keep,
        .get_slice, .assert_type => .{
            .op = op,
            .width = 2,
        },

        .get_global, .set_global => .{
            .op = op,
            .width = 5,
            .const_index = try readU16At(state, pos + 1),
        },

        .get_field, .set_field => .{
            .op = op,
            .width = 6,
            .const_index = try readU16At(state, pos + 1),
        },

        .invoke_method, .defer_invoke_method => .{
            .op = op,
            .width = if (op == .invoke_method) 8 else 4,
            .const_index = try readU16At(state, pos + 1),
        },

        .get_local_const_eq, .get_local_const_sub,
        .get_local_const_add, .get_local_const_lt,
        .get_local_const_gt => .{
            .op = op,
            .width = 5,
            .const_index = try readU16At(state, pos + 3),
        },

        .get_local_const_sub_call, .get_local_const_sub_call_tail => .{
            .op = op,
            .width = 8,
            .const_index = try readU16At(state, pos + 3),
        },

        .call_global_local_sub_const, .call_global_local_sub_const_tail => .{
            .op = op,
            .width = 13,
            .const_index = try readU16At(state, pos + 8),
        },

        .inc_global_const => .{
            .op = op,
            .width = 8,
            .const_index = try readU16At(state, pos + 6),
        },

        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop,
        .get_local_const_gt_jif_pop => blk: {
            const off = try readU32At(state, pos + 5);
            break :blk .{
                .op = op,
                .width = 9,
                .const_index = try readU16At(state, pos + 3),
                .jump_target = pos + 9 + @as(usize, off),
            };
        },

        .get_local_const_lt_jif_pop_jump => blk: {
            const exit_off = try readU32At(state, pos + 5);
            const body_off = try readU32At(state, pos + 9);
            _ = body_off;
            break :blk .{
                .op = op,
                .width = 13,
                .const_index = try readU16At(state, pos + 3),
                .jump_target = pos + 9 + @as(usize, exit_off),
            };
        },

        .get_global_const_eq, .get_global_const_sub,
        .get_global_const_add, .get_global_const_lt => .{
            .op = op,
            .width = 8,
            .const_index = try readU16At(state, pos + 6),
        },

        .get_global_const_lt_jif_pop => blk: {
            const off = try readU32At(state, pos + 8);
            break :blk .{
                .op = op,
                .width = 12,
                .const_index = try readU16At(state, pos + 6),
                .jump_target = pos + 12 + @as(usize, off),
            };
        },

        .get_local_get_field => .{
            .op = op,
            .width = 8,
            .const_index = try readU16At(state, pos + 3),
        },

        .set_global_loop => blk: {
            const off = try readU32At(state, pos + 5);
            const width: usize = 9;
            if (@as(usize, off) > pos + width) return error.BadJumpTarget;
            break :blk .{
                .op = op,
                .width = width,
                .const_index = try readU16At(state, pos + 1),
                .jump_target = pos + width - @as(usize, off),
            };
        },

        .close_upvalue_loop => blk: {
            const off = try readU32At(state, pos + 2);
            const width: usize = 6;
            if (@as(usize, off) > pos + width) return error.BadJumpTarget;
            break :blk .{
                .op = op,
                .width = width,
                .jump_target = pos + width - @as(usize, off),
            };
        },

        .local_add_local => .{
            .op = op,
            .width = 3,
        },

        .local_add_const => .{
            .op = op,
            .width = 4,
            .const_index = try readU16At(state, pos + 2),
        },

        .local_add_const_loop => blk: {
            const off = try readU32At(state, pos + 4);
            const width: usize = 8;
            if (@as(usize, off) > pos + width) return error.BadJumpTarget;
            break :blk .{
                .op = op,
                .width = width,
                .const_index = try readU16At(state, pos + 2),
                .jump_target = pos + width - @as(usize, off),
            };
        },

        .local_add_field => .{
            .op = op,
            .width = 9,
            .const_index = try readU16At(state, pos + 4),
        },

        else => .{
            .op = op,
            .width = 1,
        },
    };
}
