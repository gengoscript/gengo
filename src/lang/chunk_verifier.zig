const std = @import("std");
const Op = @import("op.zig").Op;
const chunk_decoder = @import("chunk_decoder.zig");
const chunk = @import("chunk.zig");

const DecodedInstruction = chunk_decoder.DecodedInstruction;

fn isReturnOp(op: Op) bool {
    return switch (op) {
        .ret, .ret_const, .get_local_ret, .add_ret, .get_local_const_add_ret => true,
        else => false,
    };
}

fn isUnconditionalBranch(op: Op) bool {
    return switch (op) {
        .jump, .loop, .set_global_loop, .close_upvalue_loop, .local_add_const_loop, .inc_global_const_loop, .inc_global_const_loop_nc => true,
        else => false,
    };
}

fn isConditionalBranch(op: Op) bool {
    return switch (op) {
        .jump_if_false, .jump_if_not_null, .jif_pop, .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop, .get_global_const_lt_jif_pop, .get_local_const_lt_jif_pop_jump => true,
        else => false,
    };
}

// Also used by the VM's Debug-build net-effect assertion (vm.zig runInner):
// the verifier's stack-bound proof is only as good as this table, so Debug
// runs check every executed op's actual net effect against it.
pub fn stackEffect(op: Op, code: []const u8, ip: usize) struct { pop: u16, push: u16 } {
    return switch (op) {
        .constant, .null_val, .true_val, .false_val, .get_local, .get_upvalue, .get_global, .make_closure, .tuple_get_keep, .get_local_const_eq, .get_local_const_sub, .get_local_const_add, .get_local_const_lt, .get_local_const_gt, .get_global_const_eq, .get_global_const_sub, .get_global_const_add, .get_global_const_lt, .get_local_get_field => .{ .pop = 0, .push = 1 },

        .pop, .def_global, .set_global, .set_local, .set_upvalue, .jif_pop, .op_assert, .set_named_predicate => .{ .pop = 1, .push = 0 },
        // set_field pops the value AND the receiver (found by the VM's Debug
        // net-effect assertion; it was previously modeled as pop=1).
        .set_field => .{ .pop = 2, .push = 0 },

        .add, .sub, .mul, .div, .int_div, .rem, .mod, .pow, .eq_float, .ne_float, .lt_float, .le_float, .gt_float, .ge_float, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .le, .gt, .ge, .min, .max => .{ .pop = 2, .push = 1 },
        .clamp => .{ .pop = 3, .push = 1 },
        .eqz_int, .nez_int, .ltz_int, .lez_int, .gtz_int, .gez_int => .{ .pop = 1, .push = 1 },

        .neg,
        .not,
        .bit_not,
        .abs,
        .floor,
        .ceil,
        .trunc,
        .nearest,
        .sign,
        .sqrt,
        .cast_int,
        .cast_float,
        .cast_decimal,
        .cast_bool,
        .cast_string,
        .cast_rune,
        .cast_bigint,
        .type_name,
        .len,
        .bytelen,
        .variant_check,
        .variant_payload,
        .named_inner,
        .const_eq,
        .const_sub,
        .const_add,
        .const_lt,
        .const_gt,
        .assert_type,
        .assert_interface,
        .assert_struct,
        .tuple_get,
        // get_field pops the receiver and pushes the field value. (It was
        // historically grouped with the fused get_local_get_field above, which
        // over-modeled depth by 1 per field read — found by the VM's Debug
        // net-effect assertion the day it was added.)
        .get_field,
        .get_index_const_str,
        => .{ .pop = 1, .push = 1 },

        .swap => .{ .pop = 2, .push = 2 },

        .set_index => .{ .pop = 3, .push = 0 },

        .get_index => .{ .pop = 2, .push = 1 },
        .bytes_decode => .{ .pop = 2, .push = 1 },

        .call, .call_tail => blk: {
            const argc = code[ip + 1] & 0x7F; // 0x80 = args-preverified flag
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
        .append => blk: {
            const n = code[ip + 1];
            break :blk .{ .pop = n, .push = 1 };
        },
        .build_tuple => blk: {
            const n = code[ip + 1];
            break :blk .{ .pop = n, .push = 1 };
        },
        .build_map => blk: {
            const n: u16 = code[ip + 1];
            break :blk .{ .pop = n * 2, .push = 1 };
        },
        .build_struct_instance => blk: {
            const field_count: u16 = code[ip + 1];
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

        .close_upvalue, .tuple_check_arity, .validate_type_default, .check_named_predicate, .validate_named_range => .{ .pop = 0, .push = 0 },
        .get_local_const_sub_call, .get_local_const_sub_call_tail => blk: {
            const argc = code[ip + 5] & 0x7F; // 0x80 = args-preverified flag
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
        .field_add_const => .{ .pop = 0, .push = 0 },
        .op_assert_msg => .{ .pop = 2, .push = 0 },
        .op_trap_check => .{ .pop = 1, .push = 0 },

        .ret => .{ .pop = 1, .push = 0 },
        .ret_const, .get_local_ret, .get_local_const_add_ret => .{ .pop = 0, .push = 0 },
        .add_ret => .{ .pop = 2, .push = 0 },
        .get_global_call, .get_global_call_tail => blk: {
            const argc = code[ip + 5] & 0x7F;
            break :blk .{ .pop = argc, .push = 1 };
        },
        .call_global_global, .call_global_global_tail => blk: {
            const argc = code[ip + 9] & 0x7F;
            break :blk .{ .pop = if (argc > 0) argc - 1 else 0, .push = 1 };
        },

        .jump, .loop, .set_global_loop, .close_upvalue_loop, .jump_if_false, .jump_if_not_null, .inc_global_const_loop, .inc_global_const_loop_nc => .{ .pop = 0, .push = 0 },
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop, .get_local_const_lt_jif_pop_jump, .get_global_const_lt_jif_pop => .{ .pop = 0, .push = 0 },

        .halt, .op_unreachable => .{ .pop = 0, .push = 0 },

        // Reserved slots: rejected by decodeAt before stackEffect runs.
        .reserved_2e, .reserved_2f, .reserved_30, .reserved_31, .reserved_38, .reserved_39, .reserved_3a, .reserved_3b, .reserved_3c, .reserved_3d, .reserved_3e, .reserved_3f, .reserved_40, .reserved_41, .reserved_83, .reserved_84, .reserved_85, .reserved_86, .reserved_87, .reserved_88, .reserved_89, .reserved_8a, .reserved_8b, .reserved_8c, .reserved_8d, .reserved_8e, .reserved_8f, .reserved_90, .reserved_91, .reserved_92, .reserved_93, .reserved_94, .reserved_95, .reserved_96, .reserved_97, .reserved_98, .reserved_99, .reserved_9a, .reserved_9b, .reserved_9c, .reserved_9d, .reserved_9e, .reserved_9f, .reserved_a0, .reserved_a1, .reserved_a2, .reserved_a3, .reserved_a4, .reserved_a5, .reserved_a6, .reserved_a7, .reserved_a8, .reserved_a9, .reserved_aa, .reserved_ab, .reserved_ac, .reserved_ad, .reserved_ae, .reserved_af, .reserved_b0, .reserved_b1, .reserved_b2, .reserved_b3, .reserved_b4, .reserved_b5, .reserved_b6, .reserved_b7, .reserved_b8, .reserved_b9, .reserved_ba, .reserved_bb, .reserved_bc, .reserved_bd, .reserved_be, .reserved_bf, .reserved_ea, .reserved_eb, .reserved_ec, .reserved_ed, .reserved_ee, .reserved_ef, .reserved_f0, .reserved_f1, .reserved_f2, .reserved_f3, .reserved_f4, .reserved_f5, .reserved_f6, .reserved_f7, .reserved_f8, .reserved_f9, .reserved_fa, .reserved_fb, .reserved_fc, .reserved_fd, .reserved_fe, .reserved_ff => unreachable,
    };
}

fn verifySetErr(state: *chunk.State, comptime fmt: []const u8, args: anytype) void {
    state.verify_err_len = (std.fmt.bufPrint(&state.verify_err_buf, fmt, args) catch unreachable).len;
}

pub fn verify(state: *chunk.State, alloc: std.mem.Allocator) !void {
    if (state.code_len == 0) return;

    const bit_len = (state.code_len + 7) / 8;
    const starts = try alloc.alloc(u8, bit_len);
    defer alloc.free(starts);
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
                verifySetErr(state, "ip={d}: {s}", .{ ip, @errorName(err) });
                return err;
            };
            if (inst.const_index) |idx| {
                if (idx >= state.const_count) {
                    verifySetErr(state, "ip={d} ({s}): constant index {d} >= {d}", .{ ip, @tagName(inst.op), idx, state.const_count });
                    return error.BadConstantIndex;
                }
            }
            switch (inst.op) {
                .get_local_const_eq => if (state.code[ip + 2] != @intFromEnum(Op.const_eq)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_eq, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .get_local_const_sub => if (state.code[ip + 2] != @intFromEnum(Op.const_sub)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_sub, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .get_local_const_add, .get_local_const_add_ret => if (state.code[ip + 2] != @intFromEnum(Op.const_add)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_add, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .get_local_const_lt => if (state.code[ip + 2] != @intFromEnum(Op.const_lt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_lt, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .get_local_const_gt => if (state.code[ip + 2] != @intFromEnum(Op.const_gt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_gt, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .get_local_const_gt_jif_pop => if (state.code[ip + 2] != @intFromEnum(Op.const_gt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_gt, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .get_global_const_eq => if (state.code[ip + 5] != @intFromEnum(Op.const_eq)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_eq, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 5] });
                    return error.BadOpcode;
                },
                .get_global_const_sub => if (state.code[ip + 5] != @intFromEnum(Op.const_sub)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_sub, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 5] });
                    return error.BadOpcode;
                },
                .get_global_const_add => if (state.code[ip + 5] != @intFromEnum(Op.const_add)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_add, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 5] });
                    return error.BadOpcode;
                },
                .get_global_const_lt => if (state.code[ip + 5] != @intFromEnum(Op.const_lt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_lt, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 5] });
                    return error.BadOpcode;
                },
                .get_local_const_eq_jif_pop => if (state.code[ip + 2] != @intFromEnum(Op.const_eq)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_eq, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .get_local_const_lt_jif_pop, .get_local_const_lt_jif_pop_jump => if (state.code[ip + 2] != @intFromEnum(Op.const_lt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_lt, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .get_global_const_lt_jif_pop => if (state.code[ip + 5] != @intFromEnum(Op.const_lt)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_lt, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 5] });
                    return error.BadOpcode;
                },
                .get_local_const_sub_call, .get_local_const_sub_call_tail => if (state.code[ip + 2] != @intFromEnum(Op.const_sub)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded const_sub, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .call_global_local_sub_const => if (state.code[ip + 5] != @intFromEnum(Op.get_local_const_sub_call)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded get_local_const_sub_call, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 5] });
                    return error.BadOpcode;
                },
                .call_global_local_sub_const_tail => if (state.code[ip + 5] != @intFromEnum(Op.get_local_const_sub_call)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded get_local_const_sub_call, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 5] });
                    return error.BadOpcode;
                },
                .get_local_get_field => if (state.code[ip + 2] != @intFromEnum(Op.get_field)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded get_field, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 2] });
                    return error.BadOpcode;
                },
                .local_add_field => if (state.code[ip + 3] != @intFromEnum(Op.get_field)) {
                    verifySetErr(state, "ip={d} ({s}): expected embedded get_field, got {d}", .{ ip, @tagName(inst.op), state.code[ip + 3] });
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
                verifySetErr(state, "ip={d}: {s}", .{ ip, @errorName(err) });
                return err;
            };
            if (inst.jump_target) |target| {
                if (target >= state.code_len or !Bits.has(starts, target)) {
                    verifySetErr(state, "ip={d} ({s}): jump target {d} lands inside operand bytes", .{ ip, @tagName(inst.op), target });
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
        var func_arities: [4096]u8 = undefined;
        var func_uv_counts: [4096]u8 = undefined;
        {
            // Find every function body reachable from the const pool — the
            // same shapes vm_defuse pass 3 remaps: plain function consts,
            // closure consts, and predicate functions embedded in named_type
            // consts (compile-time-attached predicates are not function
            // consts themselves).
            for (state.consts[0..state.const_count]) |cv| {
                if (cv != .object) continue;
                const fo = funcObjOfConst(cv.object) orelse continue;
                const f = fo.function;
                if (f.ip < state.code_len and Bits.has(starts, f.ip)) {
                    if (func_body_count >= func_ips.len) return error.InvalidBytecode;
                    func_ips[func_body_count] = @intCast(f.ip);
                    func_arities[func_body_count] = f.arity;
                    func_uv_counts[func_body_count] = @intCast(f.capture_slots.len);
                    func_body_count += 1;
                }
            }
        }

        const BfsRunner = struct {
            // Returns the maximum stack depth (relative to entry) reached on
            // any path — the frame-entry capacity check that makes unchecked
            // stack ops in the body safe.
            // local_base: number of pre-existing locals at entry (arity for
            //   functions, 0 for top-level). Valid local slots are
            //   0 .. local_base + current_bfs_depth - 1.
            // upvalue_count: number of upvalues the function captures.
            //   Valid upvalue indices are 0 .. upvalue_count - 1.
            fn run(entry_ip: usize, check_ret: bool, starts_arg: []u8, state_arg: *chunk.State, a: std.mem.Allocator, local_base: u32, upvalue_count: u32) !i32 {
                var depth = try a.alloc(?i32, state_arg.code_len);
                defer a.free(depth);
                @memset(depth, null);

                const WorkItem = struct { ip: usize, depth: i32 };
                var work = try std.ArrayListUnmanaged(WorkItem).initCapacity(a, state_arg.code_len);
                defer work.deinit(a);
                try work.append(a, .{ .ip = entry_ip, .depth = 0 });

                var max_depth: i32 = 0;
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
                        verifySetErr(state_arg, "ip={d}: {s}", .{ current_ip, @errorName(err) });
                        return err;
                    };

                    // Validate local-slot and upvalue-index operands.
                    switch (inst.op) {
                        .get_local, .set_local, .close_upvalue => {
                            const slot: u32 = state_arg.code[current_ip + 1];
                            const limit = local_base + @as(u32, @intCast(current_depth));
                            if (slot >= limit) {
                                verifySetErr(state_arg, "ip={d} ({s}): local slot {d} out of range (limit={d})", .{ current_ip, @tagName(inst.op), slot, limit });
                                return error.InvalidBytecode;
                            }
                        },
                        .get_upvalue, .set_upvalue => {
                            const slot: u32 = state_arg.code[current_ip + 1];
                            if (slot >= upvalue_count) {
                                verifySetErr(state_arg, "ip={d} ({s}): upvalue index {d} out of range (count={d})", .{ current_ip, @tagName(inst.op), slot, upvalue_count });
                                return error.InvalidBytecode;
                            }
                        },
                        else => {},
                    }

                    const effect = stackEffect(inst.op, state_arg.code, current_ip);
                    const is_branch = isConditionalBranch(inst.op);
                    const is_uncond = isUnconditionalBranch(inst.op);
                    const is_ret = isReturnOp(inst.op);

                    if (is_ret and check_ret) {
                        verifySetErr(state_arg, "ip={d} ({s}): return at top level", .{ current_ip, @tagName(inst.op) });
                        return error.ReturnAtTopLevel;
                    }

                    if (current_depth < effect.pop) {
                        verifySetErr(state_arg, "ip={d} ({s}): stack depth {d} < {d}", .{ current_ip, @tagName(inst.op), current_depth, effect.pop });
                        return error.StackUnderflow;
                    }

                    const new_depth = current_depth - @as(i32, effect.pop) + @as(i32, effect.push);
                    if (new_depth < 0) {
                        verifySetErr(state_arg, "ip={d} ({s}): stack underflow (new depth {d})", .{ current_ip, @tagName(inst.op), new_depth });
                        return error.StackUnderflow;
                    }
                    if (new_depth > max_depth) max_depth = new_depth;

                    if (!is_ret and !is_uncond) {
                        const next_ip = current_ip + inst.width;
                        if (next_ip < state_arg.code_len) {
                            try work.append(a, .{ .ip = next_ip, .depth = new_depth });
                        }
                    }

                    if (is_branch or is_uncond) {
                        if (inst.jump_target) |target| {
                            try work.append(a, .{ .ip = target, .depth = new_depth });
                        }
                    }
                }
                return max_depth;
            }
        };

        state.main_max_stack = @intCast(try BfsRunner.run(0, true, starts, state, alloc, 0, 0));
        for (func_ips[0..func_body_count], func_arities[0..func_body_count], func_uv_counts[0..func_body_count]) |fip, farity, fuvc| {
            const fmax = try BfsRunner.run(fip, false, starts, state, alloc, @as(u32, farity), @as(u32, fuvc));
            const fmax16 = std.math.cast(u16, fmax) orelse {
                verifySetErr(state, "ip={d}: function max stack depth {d} exceeds u16", .{ fip, fmax });
                return error.StackOverflow;
            };
            // Stamp every function object whose body starts at this entry
            // (closures over the same function share one FuncObj).
            for (state.consts[0..state.const_count]) |cv| {
                if (cv != .object) continue;
                const fo = funcObjOfConst(cv.object) orelse continue;
                if (fo.function.ip == fip) fo.function.max_stack = fmax16;
            }
        }
    }
}

const funcObjOfConst = chunk.funcObjOfConst;
