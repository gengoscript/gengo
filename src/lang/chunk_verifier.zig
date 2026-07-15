const std = @import("std");
const Op = @import("op.zig").Op;
const chunk_decoder = @import("chunk_decoder.zig");

const DecodedInstruction = chunk_decoder.DecodedInstruction;

fn isReturnOp(op: Op) bool {
    return switch (op) {
        .ret, .ret_const, .get_local_ret, .add_ret => true,
        else => false,
    };
}

fn isUnconditionalBranch(op: Op) bool {
    return switch (op) {
        .jump, .loop, .set_global_loop, .close_upvalue_loop, .local_add_const_loop => true,
        else => false,
    };
}

fn isConditionalBranch(op: Op) bool {
    return switch (op) {
        .jump_if_false, .jump_if_not_null, .jif_pop,
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop,
        .get_global_const_lt_jif_pop,
        .get_local_const_lt_jif_pop_jump => true,
        else => false,
    };
}

fn stackEffect(op: Op, code: []const u8, ip: usize) struct { pop: u8, push: u8 } {
    return switch (op) {
        .constant, .null_val, .true_val, .false_val,
        .get_local, .get_upvalue, .get_global, .get_field,
        .make_closure, .tuple_get_keep,
        .get_local_const_eq, .get_local_const_sub,
        .get_local_const_add, .get_local_const_lt, .get_local_const_gt,
        .get_global_const_eq, .get_global_const_sub,
        .get_global_const_add, .get_global_const_lt,
        .get_local_get_field => .{ .pop = 0, .push = 1 },

        .pop, .def_global, .set_global, .set_local, .set_upvalue,
        .set_field, .jif_pop, .op_assert,
        .set_named_predicate => .{ .pop = 1, .push = 0 },

        .add, .sub, .mul, .div, .int_div, .rem, .mod, .pow,
        .add_int, .sub_int, .mul_int, .div_int,
        .eq_int, .ne_int, .lt_int, .le_int, .gt_int, .ge_int,
        .add_float, .sub_float, .mul_float, .div_float,
        .eq_float, .ne_float, .lt_float, .le_float, .gt_float, .ge_float,
        .bit_and, .bit_or, .bit_xor, .shl, .shr,
        .eq, .ne, .lt, .le, .gt, .ge,
        .min, .max => .{ .pop = 2, .push = 1 },
        .clamp => .{ .pop = 3, .push = 1 },
        .eqz_int, .nez_int, .ltz_int, .lez_int, .gtz_int, .gez_int => .{ .pop = 1, .push = 1 },

        .neg, .not, .bit_not,
        .abs, .floor, .ceil, .trunc, .nearest, .sign, .sqrt,
        .cast_int, .cast_float, .cast_decimal, .cast_bool, .cast_string, .cast_rune, .cast_bigint,
        .type_name, .variant_check, .variant_payload,
        .named_inner,
        .const_eq, .const_sub, .const_add, .const_lt, .const_gt,
        .assert_type, .assert_interface, .assert_struct,
        .tuple_get => .{ .pop = 1, .push = 1 },

        .swap => .{ .pop = 2, .push = 2 },

        .set_index => .{ .pop = 3, .push = 0 },

        .get_index => .{ .pop = 2, .push = 1 },

        .call, .call_tail => blk: {
            const argc = code[ip + 1];
            break :blk .{ .pop = argc + 1, .push = 1 };
        },
        .call_spread => blk: {
            const argc = code[ip + 1];
            const spread_n = code[ip + 2];
            break :blk .{ .pop = argc + 1, .push = spread_n };
        },
        .defer_call => blk: {
            const argc = code[ip + 1];
            break :blk .{ .pop = argc + 1, .push = 0 };
        },
        .invoke_method => blk: {
            const argc = code[ip + 3];
            break :blk .{ .pop = argc + 1, .push = 1 };
        },
        .defer_invoke_method => blk: {
            const argc = code[ip + 3];
            break :blk .{ .pop = argc + 1, .push = 0 };
        },
        .build_array => blk: {
            const n = code[ip + 1];
            break :blk .{ .pop = n, .push = 1 };
        },
        .build_tuple => blk: {
            const n = code[ip + 1];
            break :blk .{ .pop = n, .push = 1 };
        },
        .build_map => blk: {
            const n = code[ip + 1];
            break :blk .{ .pop = n * 2, .push = 1 };
        },
        .build_struct_instance => blk: {
            const field_count = code[ip + 1];
            break :blk .{ .pop = 1 + field_count * 2, .push = 1 };
        },
        .zero_struct => .{ .pop = 1, .push = 1 },
        .get_slice => blk: {
            const extra: u8 = @popCount(code[ip + 1]);
            break :blk .{ .pop = 1 + extra, .push = 1 };
        },

        .iter_init => .{ .pop = 1, .push = 1 },
        .iter_next1 => .{ .pop = 0, .push = 2 },
        .iter_next2 => .{ .pop = 0, .push = 3 },

        .dup => .{ .pop = 0, .push = 1 },
        .dup2 => .{ .pop = 0, .push = 2 },

        .close_upvalue, .tuple_check_arity, .validate_type_default,
        .check_named_predicate => .{ .pop = 0, .push = 0 },
        .get_local_const_sub_call, .get_local_const_sub_call_tail => blk: {
            const argc = code[ip + 5];
            break :blk .{ .pop = argc, .push = 1 };
        },
        .call_global_local_sub_const, .call_global_local_sub_const_tail => blk: {
            const argc = code[ip + 10];
            _ = argc;
            break :blk .{ .pop = 0, .push = 1 };
        },
        .inc_global_const => .{ .pop = 0, .push = 0 },
        .local_add_local => .{ .pop = 0, .push = 0 },
        .local_add_const => .{ .pop = 0, .push = 0 },
        .local_add_const_loop => .{ .pop = 0, .push = 0 },
        .local_add_field => .{ .pop = 0, .push = 0 },
        .op_assert_msg => .{ .pop = 2, .push = 0 },
        .op_trap_check => .{ .pop = 1, .push = 0 },

        .ret => .{ .pop = 1, .push = 0 },
        .ret_const, .get_local_ret => .{ .pop = 0, .push = 0 },
        .add_ret => .{ .pop = 2, .push = 0 },

        .jump, .loop, .set_global_loop, .close_upvalue_loop, .jump_if_false, .jump_if_not_null => .{ .pop = 0, .push = 0 },
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop,
        .get_local_const_lt_jif_pop_jump,
        .get_global_const_lt_jif_pop => .{ .pop = 0, .push = 0 },

        .halt, .op_unreachable => .{ .pop = 0, .push = 0 },
    };
}

fn verifySetErr(state: anytype, comptime fmt: []const u8, args: anytype) void {
    state.verify_err_len = (std.fmt.bufPrint(&state.verify_err_buf, fmt, args) catch unreachable).len;
}

pub fn verify(state: anytype) !void {
    if (state.code_len == 0) return;

    const bit_len = (state.code_len + 7) / 8;
    const starts = try std.heap.page_allocator.alloc(u8, bit_len);
    defer std.heap.page_allocator.free(starts);
    @memset(starts, 0);

    const Bits = struct {
        fn set(bits: []u8, idx: usize) void {
            bits[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
        }
        fn has(bits: []const u8, idx: usize) bool {
            return (bits[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
        }
    };

    {
        var ip: usize = 0;
        while (ip < state.code_len) {
            Bits.set(starts, ip);
            const inst = chunk_decoder.decodeAt(state, ip) catch |err| {
                verifySetErr(state, "ip={d}: {s}", .{ip, @errorName(err)});
                return err;
            };
            if (inst.const_index) |idx| {
                if (idx >= state.const_count) {
                    verifySetErr(state, "ip={d} ({s}): constant index {d} >= {d}", .{ip, @tagName(inst.op), idx, state.const_count});
                    return error.BadConstantIndex;
                }
            }
            switch (inst.op) {
                .get_local_const_eq => if (state.code[ip + 2] != @intFromEnum(Op.const_eq)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_eq, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_sub => if (state.code[ip + 2] != @intFromEnum(Op.const_sub)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_sub, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_add => if (state.code[ip + 2] != @intFromEnum(Op.const_add)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_add, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_lt => if (state.code[ip + 2] != @intFromEnum(Op.const_lt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_lt, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_gt => if (state.code[ip + 2] != @intFromEnum(Op.const_gt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_gt, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_gt_jif_pop => if (state.code[ip + 2] != @intFromEnum(Op.const_gt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_gt, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_global_const_eq => if (state.code[ip + 5] != @intFromEnum(Op.const_eq)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_eq, got {d}", .{ip, @tagName(inst.op), state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_global_const_sub => if (state.code[ip + 5] != @intFromEnum(Op.const_sub)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_sub, got {d}", .{ip, @tagName(inst.op), state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_global_const_add => if (state.code[ip + 5] != @intFromEnum(Op.const_add)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_add, got {d}", .{ip, @tagName(inst.op), state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_global_const_lt => if (state.code[ip + 5] != @intFromEnum(Op.const_lt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_lt, got {d}", .{ip, @tagName(inst.op), state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_local_const_eq_jif_pop => if (state.code[ip + 2] != @intFromEnum(Op.const_eq)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_eq, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_lt_jif_pop,
                .get_local_const_lt_jif_pop_jump => if (state.code[ip + 2] != @intFromEnum(Op.const_lt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_lt, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_global_const_lt_jif_pop => if (state.code[ip + 5] != @intFromEnum(Op.const_lt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_lt, got {d}", .{ip, @tagName(inst.op), state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_local_const_sub_call, .get_local_const_sub_call_tail => if (state.code[ip + 2] != @intFromEnum(Op.const_sub)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_sub, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .call_global_local_sub_const => if (state.code[ip + 5] != @intFromEnum(Op.get_local_const_sub_call)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded get_local_const_sub_call, got {d}", .{ip, @tagName(inst.op), state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .call_global_local_sub_const_tail => if (state.code[ip + 5] != @intFromEnum(Op.get_local_const_sub_call)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded get_local_const_sub_call, got {d}", .{ip, @tagName(inst.op), state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_local_get_field => if (state.code[ip + 2] != @intFromEnum(Op.get_field)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded get_field, got {d}", .{ip, @tagName(inst.op), state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .local_add_field => if (state.code[ip + 3] != @intFromEnum(Op.get_field)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded get_field, got {d}", .{ip, @tagName(inst.op), state.code[ip + 3]});
                    return error.BadOpcode;
                },
                else => {},
            }
            ip += inst.width;
        }
    }

    {
        var ip: usize = 0;
        while (ip < state.code_len) {
            const inst = chunk_decoder.decodeAt(state, ip) catch |err| {
                verifySetErr(state, "ip={d}: {s}", .{ip, @errorName(err)});
                return err;
            };
            if (inst.jump_target) |target| {
                if (target >= state.code_len or !Bits.has(starts, target)) {
                    verifySetErr(state, "ip={d} ({s}): jump target {d} lands inside operand bytes", .{ip, @tagName(inst.op), target});
                    return error.BadJumpTarget;
                }
            }
            ip += inst.width;
        }
    }

    {
        var func_body_count: usize = 0;
        // u32 halves the stack footprint (16KB vs 32KB on 64-bit) — ips are
        // bounded by MaxCode (1 MiB), well inside u32.
        var func_ips: [4096]u32 = undefined;
        {
            for (state.consts[0..state.const_count]) |cv| {
                if (cv == .object) {
                    switch (cv.object.*) {
                        .function => |f| {
                            if (f.ip < state.code_len and Bits.has(starts, f.ip)) {
                                func_ips[func_body_count] = @intCast(f.ip);
                                func_body_count += 1;
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        const BfsRunner = struct {
            fn run(entry_ip: usize, check_ret: bool, starts_arg: []u8, state_arg: anytype) !void {
                var depth = try std.heap.page_allocator.alloc(?i32, state_arg.code_len);
                defer std.heap.page_allocator.free(depth);
                @memset(depth, null);

                const WorkItem = struct { ip: usize, depth: i32 };
                var work = try std.ArrayListUnmanaged(WorkItem).initCapacity(std.heap.page_allocator, state_arg.code_len);
                defer work.deinit(std.heap.page_allocator);
                try work.append(std.heap.page_allocator, .{ .ip = entry_ip, .depth = 0 });

                var head: usize = 0;
                while (head < work.items.len) {
                    const current_ip = work.items[head].ip;
                    const current_depth = work.items[head].depth;
                    head += 1;

                    if (current_ip >= state_arg.code_len) continue;
                    if (!Bits.has(starts_arg, current_ip)) continue;

                    if (depth[current_ip]) |_| continue;
                    depth[current_ip] = current_depth;

                    const inst = chunk_decoder.decodeAt(state_arg, current_ip) catch |err| {
                        verifySetErr(state_arg, "ip={d}: {s}", .{current_ip, @errorName(err)});
                        return err;
                    };
                    const effect = stackEffect(inst.op, &state_arg.code, current_ip);
                    const is_branch = isConditionalBranch(inst.op);
                    const is_uncond = isUnconditionalBranch(inst.op);
                    const is_ret = isReturnOp(inst.op);

                    if (is_ret and check_ret) {
                        verifySetErr(state_arg, "ip={d} ({s}): return at top level", .{current_ip, @tagName(inst.op)});
                        return error.ReturnAtTopLevel;
                    }

                    if (current_depth < effect.pop) {
                        verifySetErr(state_arg, "ip={d} ({s}): stack depth {d} < {d}", .{current_ip, @tagName(inst.op), current_depth, effect.pop});
                        return error.StackUnderflow;
                    }

                    const new_depth = current_depth - @as(i32, effect.pop) + @as(i32, effect.push);
                    if (new_depth < 0) {
                        verifySetErr(state_arg, "ip={d} ({s}): stack underflow (new depth {d})", .{current_ip, @tagName(inst.op), new_depth});
                        return error.StackUnderflow;
                    }

                    if (!is_ret and !is_uncond) {
                        const next_ip = current_ip + inst.width;
                        if (next_ip < state_arg.code_len) {
                            try work.append(std.heap.page_allocator, .{ .ip = next_ip, .depth = new_depth });
                        }
                    }

                    if (is_branch or is_uncond) {
                        if (inst.jump_target) |target| {
                            try work.append(std.heap.page_allocator, .{ .ip = target, .depth = new_depth });
                        }
                    }
                }
            }
        };

        try BfsRunner.run(0, true, starts, state);
        for (func_ips[0..func_body_count]) |fip| {
            try BfsRunner.run(fip, false, starts, state);
        }
    }
}
