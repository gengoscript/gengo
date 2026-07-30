// Bytecode defuse pass: expand fused opcodes into constituent primitives and
// reset inline caches to cold state. Used by differential testing to verify
// that fused fast paths produce identical semantics to the unoptimized forms.

const std = @import("std");
const chunk = @import("chunk.zig");
const Op = @import("op.zig").Op;

// Read one byte from the given bytecode at old_ip+off.
inline fn rb(code: []const u8, old_ip: usize, off: usize) u8 {
    return code[old_ip + off];
}

// Write big-endian u32 into dst at offset off.
inline fn pu32(dst: []u8, off: usize, v: u32) void {
    dst[off] = @intCast((v >> 24) & 0xFF);
    dst[off + 1] = @intCast((v >> 16) & 0xFF);
    dst[off + 2] = @intCast((v >> 8) & 0xFF);
    dst[off + 3] = @intCast(v & 0xFF);
}

inline fn opByte(op: Op) u8 {
    return @intFromEnum(op);
}

// Forward jump offset: new_target - new_instruction_end.
inline fn fwdOff(ip_map: []const u32, old_target: usize, new_end: usize) u32 {
    return @intCast(@as(usize, ip_map[old_target]) - new_end);
}

// Backward jump offset: new_instruction_end - new_target.
inline fn bwdOff(ip_map: []const u32, old_target: usize, new_end: usize) u32 {
    return @intCast(new_end - @as(usize, ip_map[old_target]));
}

// Returns the size of the defused form of an instruction.
fn expandedWidth(op: Op, old_width: usize) usize {
    return switch (op) {
        // Fused return variants
        .ret_const => 4, // constant(3) + ret(1)
        .get_local_ret => 3, // get_local(2) + ret(1)
        .add_ret => 2, // add(1) + ret(1)
        // Fused local-slot mutations
        .local_add_local => 7, // get_local(2)+get_local(2)+add(1)+set_local(2)
        .local_add_const => 8, // get_local(2)+constant(3)+add(1)+set_local(2)
        // Fused const+binop (stack-top = left, const = right)
        .const_eq, .const_sub, .const_add, .const_lt, .const_gt => 4, // constant(3) + binop(1)
        // Fused get_local+const+binop
        .get_local_const_eq, .get_local_const_sub, .get_local_const_add, .get_local_const_lt, .get_local_const_gt => 6, // get_local(2)+constant(3)+binop(1)
        // Fused get_local+const+sub+call
        .get_local_const_sub_call, .get_local_const_sub_call_tail => 10, // get_local(2)+constant(3)+sub(1)+call(4)
        // Fused quad with jif_pop
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop => 10, // get_local(2)+const_cmp(3)+jif_pop(5)
        .get_global_const_lt_jif_pop => 13, // get_global(5)+const_cmp(3)+jif_pop(5)
        // Fused set_global+loop
        .set_global_loop => 10, // set_global(5)+loop(5)
        // Fused close_upvalue+loop
        .close_upvalue_loop => 7, // close_upvalue(2)+loop(5)
        // Fused local_add_const+loop
        .local_add_const_loop => 13, // get_local(2)+constant(3)+add(1)+set_local(2)+loop(5)
        // Hexa-fused get_global+get_local_const_sub_call: same 13 bytes, just byte 0 changes
        .call_global_local_sub_const, .call_global_local_sub_const_tail => 13, // get_global(5)+get_local_const_sub_call(8)
        // Fused get_global_const_add+set_global (same global): expands to 8+5=13 bytes
        .inc_global_const => 13, // get_global_const_add(8)+set_global(5)
        // Fused inc_global_const+close_upvalue_loop: expands to 8+2+5=15 bytes
        .inc_global_const_loop => 15, // inc_global_const(8)+close_upvalue(2)+loop(5)
        // Quint-fused: get_local+const_lt+jif_pop+jump
        .get_local_const_lt_jif_pop_jump => 15, // get_local(2)+const_lt(3)+jif_pop(5)+jump(5)
        // get_global_const_*: same 8 bytes, but expand to get_global+const_op
        .get_global_const_eq, .get_global_const_sub, .get_global_const_add, .get_global_const_lt => 8, // get_global(5)+const_op(3)
        // get_local_get_field: same 8 bytes, but expand to get_local+get_field
        .get_local_get_field => 8, // get_local(2)+get_field(6)
        // local_add_field expands to get_local+get_local_get_field+add+set_local
        .local_add_field => 13, // get_local(2)+get_local_get_field(8)+add(1)+set_local(2)
        // Everything else: same size
        else => old_width,
    };
}

// Copy n bytes verbatim from old_ip into dst.
fn copyBytes(code: []const u8, dst: []u8, old_ip: usize, n: usize) void {
    for (0..n) |i| dst[i] = code[old_ip + i];
}

// Emit the defused form of one instruction into dst.
// dst.len == expandedWidth(instr.op, instr.width).
// new_ip is the start position of this instruction in the new bytecode.
fn emitExpanded(
    code: []const u8,
    dst: []u8,
    old_ip: usize,
    instr: chunk.DecodedInstruction,
    ip_map: []const u32,
    new_ip: usize,
) void {
    const op = instr.op;
    const new_end = new_ip + dst.len;

    switch (op) {
        // ── Fused return variants ────────────────────────────────────────────
        .ret_const => {
            dst[0] = opByte(.constant);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = opByte(.ret);
        },
        .get_local_ret => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.ret);
        },
        .add_ret => {
            dst[0] = opByte(.add);
            dst[1] = opByte(.ret);
        },

        // ── Fused local-slot mutations ───────────────────────────────────────
        .local_add_local => {
            // [op][dst][src] — dst += src
            const d = rb(code, old_ip, 1);
            const s = rb(code, old_ip, 2);
            dst[0] = opByte(.get_local);
            dst[1] = d;
            dst[2] = opByte(.get_local);
            dst[3] = s;
            dst[4] = opByte(.add);
            dst[5] = opByte(.set_local);
            dst[6] = d;
        },
        .local_add_const => {
            // [op][dst][idx_hi][idx_lo] — dst += k
            const d = rb(code, old_ip, 1);
            const ih = rb(code, old_ip, 2);
            const il = rb(code, old_ip, 3);
            dst[0] = opByte(.get_local);
            dst[1] = d;
            dst[2] = opByte(.constant);
            dst[3] = ih;
            dst[4] = il;
            dst[5] = opByte(.add);
            dst[6] = opByte(.set_local);
            dst[7] = d;
        },
        .local_add_field => {
            // [op][dst][src][skip][name_hi][name_lo][ic_hi][ic_lo][ic_fidx]
            // expands to: get_local dst; get_local_get_field src skip name ic; add; set_local dst
            const d = rb(code, old_ip, 1);
            dst[0] = opByte(.get_local);
            dst[1] = d;
            dst[2] = opByte(.get_local_get_field);
            dst[3] = rb(code, old_ip, 2); // src slot
            dst[4] = rb(code, old_ip, 3); // skip byte
            dst[5] = rb(code, old_ip, 4); // name_hi
            dst[6] = rb(code, old_ip, 5); // name_lo
            dst[7] = rb(code, old_ip, 6); // ic_hi
            dst[8] = rb(code, old_ip, 7); // ic_lo
            dst[9] = rb(code, old_ip, 8); // ic_fidx
            dst[10] = opByte(.add);
            dst[11] = opByte(.set_local);
            dst[12] = d;
        },

        // ── const+binop (pop left, push left op const) ───────────────────────
        .const_eq => {
            dst[0] = opByte(.constant);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = opByte(.eq);
        },
        .const_sub => {
            dst[0] = opByte(.constant);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = opByte(.sub);
        },
        .const_add => {
            dst[0] = opByte(.constant);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = opByte(.add);
        },
        .const_lt => {
            dst[0] = opByte(.constant);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = opByte(.lt);
        },
        .const_gt => {
            dst[0] = opByte(.constant);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = opByte(.gt);
        },

        // ── get_local + const + binop ────────────────────────────────────────
        // Layout: [op][slot][skip_byte][idx_hi][idx_lo]
        .get_local_const_eq => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.constant);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.eq);
        },
        .get_local_const_sub => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.constant);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.sub);
        },
        .get_local_const_add => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.constant);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.add);
        },
        .get_local_const_lt => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.constant);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.lt);
        },
        .get_local_const_gt => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.constant);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.gt);
        },

        // ── get_local + const + sub + call ───────────────────────────────────
        // Layout: [op][slot][skip][idx_hi][idx_lo][argc][ic_hi][ic_lo]
        .get_local_const_sub_call => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.constant);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.sub);
            dst[6] = opByte(.call);
            dst[7] = rb(code, old_ip, 5);
            dst[8] = 0xFF;
            dst[9] = 0xFF;
        },
        .get_local_const_sub_call_tail => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.constant);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.sub);
            dst[6] = opByte(.call_tail);
            dst[7] = rb(code, old_ip, 5);
            dst[8] = 0xFF;
            dst[9] = 0xFF;
        },

        // ── quad: get_local + const_cmp + jif_pop ────────────────────────────
        // Layout: [op][slot][skip][idx_hi][idx_lo][jmp_b3..b0]  (9 bytes)
        .get_local_const_eq_jif_pop => {
            const tgt = instr.jump_target.?;
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.const_eq);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.jif_pop);
            pu32(dst, 6, fwdOff(ip_map, tgt, new_end));
        },
        .get_local_const_lt_jif_pop => {
            const tgt = instr.jump_target.?;
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.const_lt);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.jif_pop);
            pu32(dst, 6, fwdOff(ip_map, tgt, new_end));
        },
        .get_local_const_gt_jif_pop => {
            const tgt = instr.jump_target.?;
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.const_gt);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.jif_pop);
            pu32(dst, 6, fwdOff(ip_map, tgt, new_end));
        },

        // ── quad: get_global + const_lt + jif_pop ────────────────────────────
        // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][skip][k_hi][k_lo][jmp*4]  (12 bytes)
        .get_global_const_lt_jif_pop => {
            const tgt = instr.jump_target.?;
            dst[0] = opByte(.get_global);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = 0xFF;
            dst[4] = 0xFF;
            dst[5] = opByte(.const_lt);
            dst[6] = rb(code, old_ip, 6);
            dst[7] = rb(code, old_ip, 7);
            dst[8] = opByte(.jif_pop);
            pu32(dst, 9, fwdOff(ip_map, tgt, new_end));
        },

        // ── fused set_global + loop ───────────────────────────────────────────
        // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][jmp*4]  (9 bytes)
        .set_global_loop => {
            const tgt = instr.jump_target.?;
            dst[0] = opByte(.set_global);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = 0xFF;
            dst[4] = 0xFF;
            dst[5] = opByte(.loop);
            pu32(dst, 6, bwdOff(ip_map, tgt, new_end));
        },

        // ── fused get_global_const_add + set_global (same global) ────────────
        // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][add_skip][val_hi][val_lo] (8 bytes, same as get_global_const_add)
        // Expands to: get_global_const_add(8) + set_global(5) = 13 bytes
        .inc_global_const => {
            dst[0] = opByte(.get_global_const_add);
            for (1..8) |i| dst[i] = rb(code, old_ip, i);
            // set_global for the same name with cold IC
            dst[8] = opByte(.set_global);
            dst[9] = rb(code, old_ip, 1); // name_hi
            dst[10] = rb(code, old_ip, 2); // name_lo
            dst[11] = 0xff; // ic_hi (cold)
            dst[12] = 0xff; // ic_lo (cold)
        },
        // ── fused inc_global_const + close_upvalue_loop ──────────────────────
        // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][add_skip][val_hi][val_lo][cup_slot][jmp*4]
        // Expands to: inc_global_const(8) + close_upvalue(2) + loop(5) = 15 bytes
        .inc_global_const_loop => {
            const tgt = instr.jump_target.?;
            dst[0] = opByte(.get_global_const_add);
            for (1..8) |i| dst[i] = rb(code, old_ip, i);
            dst[8] = opByte(.set_global);
            dst[9] = rb(code, old_ip, 1); // name_hi
            dst[10] = rb(code, old_ip, 2); // name_lo
            dst[11] = 0xff; // ic_hi (cold)
            dst[12] = 0xff; // ic_lo (cold)
            dst[13] = opByte(.close_upvalue);
            dst[14] = rb(code, old_ip, 8); // cup_slot
            dst[15] = opByte(.loop);
            pu32(dst, 16, bwdOff(ip_map, tgt, new_end));
        },

        // ── hexa-fused get_global + get_local_const_sub_call ─────────────────
        // Layout: [call_global_local_sub_const][name_hi][name_lo][ic_hi][ic_lo][glcs_skip][slot][sub_skip][idx_hi][idx_lo][argc][c_ic_hi][c_ic_lo]
        // Expands to: get_global(5) + get_local_const_sub_call(8) = 13 bytes (just byte 0 changes)
        .call_global_local_sub_const => {
            dst[0] = opByte(.get_global);
            for (1..13) |i| dst[i] = rb(code, old_ip, i);
        },
        .call_global_local_sub_const_tail => {
            dst[0] = opByte(.get_global);
            for (1..5) |i| dst[i] = rb(code, old_ip, i);
            dst[5] = opByte(.get_local_const_sub_call_tail);
            for (6..13) |i| dst[i] = rb(code, old_ip, i);
        },

        // ── fused local_add_const + loop ─────────────────────────────────────
        // Layout: [op][dst][idx_hi][idx_lo][jmp*4] (8 bytes)
        // Expands to: get_local(2)+constant(3)+add(1)+set_local(2)+loop(5) = 13 bytes
        .local_add_const_loop => {
            const tgt = instr.jump_target.?;
            const d = rb(code, old_ip, 1);
            const ih = rb(code, old_ip, 2);
            const il = rb(code, old_ip, 3);
            dst[0] = opByte(.get_local);
            dst[1] = d;
            dst[2] = opByte(.constant);
            dst[3] = ih;
            dst[4] = il;
            dst[5] = opByte(.add);
            dst[6] = opByte(.set_local);
            dst[7] = d;
            dst[8] = opByte(.loop);
            pu32(dst, 9, bwdOff(ip_map, tgt, new_end));
        },

        // ── fused close_upvalue + loop ────────────────────────────────────────
        // Layout: [op][slot][jmp*4]  (6 bytes) → close_upvalue(2) + loop(5)
        .close_upvalue_loop => {
            const tgt = instr.jump_target.?;
            dst[0] = opByte(.close_upvalue);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.loop);
            pu32(dst, 3, bwdOff(ip_map, tgt, new_end));
        },

        // ── quint: get_local + const_lt + jif_pop + jump ─────────────────────
        // Layout: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0][body_b3..b0] (13 bytes)
        // Expands to: get_local(2) + const_lt(3) + jif_pop(5) + jump(5) = 15 bytes
        .get_local_const_lt_jif_pop_jump => {
            const exit_tgt = instr.jump_target.?;
            // body_off is at bytes 9-12 of the original instruction
            const body_off_raw = (@as(u32, rb(code, old_ip, 9)) << 24) |
                (@as(u32, rb(code, old_ip, 10)) << 16) |
                (@as(u32, rb(code, old_ip, 11)) << 8) |
                @as(u32, rb(code, old_ip, 12));
            const body_tgt = old_ip + 13 + @as(usize, body_off_raw);
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.const_lt);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4);
            dst[5] = opByte(.jif_pop);
            pu32(dst, 6, fwdOff(ip_map, exit_tgt, new_end - 5));
            dst[10] = opByte(.jump);
            pu32(dst, 11, fwdOff(ip_map, body_tgt, new_end));
        },

        // ── get_global_const_* (same size): expand to get_global + const_op ──
        // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][skip][val_hi][val_lo]  (8 bytes)
        .get_global_const_eq, .get_global_const_sub, .get_global_const_add, .get_global_const_lt => {
            const nh = rb(code, old_ip, 1);
            const nl = rb(code, old_ip, 2);
            const vh = rb(code, old_ip, 6);
            const vl = rb(code, old_ip, 7);
            const prim: Op = switch (op) {
                .get_global_const_eq => .const_eq,
                .get_global_const_sub => .const_sub,
                .get_global_const_add => .const_add,
                .get_global_const_lt => .const_lt,
                else => unreachable,
            };
            dst[0] = opByte(.get_global);
            dst[1] = nh;
            dst[2] = nl;
            dst[3] = 0xFF;
            dst[4] = 0xFF; // cold IC
            dst[5] = opByte(prim);
            dst[6] = vh;
            dst[7] = vl;
        },

        // ── get_local_get_field (same size): expand + clear IC ────────────────
        // Layout: [op][slot][skip=get_field_byte][name_hi][name_lo][ic_type_hi][ic_type_lo][ic_fidx]
        .get_local_get_field => {
            dst[0] = opByte(.get_local);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = opByte(.get_field);
            dst[3] = rb(code, old_ip, 3);
            dst[4] = rb(code, old_ip, 4); // name_hi, name_lo
            dst[5] = 0xFF;
            dst[6] = 0xFF;
            dst[7] = 0xFF; // cold IC
        },

        // ── jump ops: recompute offset to account for IP shifts ───────────────
        .jump, .jump_if_false, .jif_pop => {
            dst[0] = rb(code, old_ip, 0);
            pu32(dst, 1, fwdOff(ip_map, instr.jump_target.?, new_end));
        },
        .loop => {
            dst[0] = opByte(.loop);
            pu32(dst, 1, bwdOff(ip_map, instr.jump_target.?, new_end));
        },

        // ── IC-bearing ops with no size change: reset IC bytes ────────────────
        .get_global, .set_global => {
            // Layout: [op][name_hi][name_lo][ic_hi][ic_lo]  (5 bytes)
            dst[0] = rb(code, old_ip, 0);
            dst[1] = rb(code, old_ip, 1);
            dst[2] = rb(code, old_ip, 2);
            dst[3] = 0xFF;
            dst[4] = 0xFF;
        },
        .get_field, .set_field => {
            // Layout: [op][name_hi][name_lo][ic_type_hi][ic_type_lo][ic_fidx]  (6 bytes)
            copyBytes(code, dst, old_ip, 6);
            dst[3] = 0xFF;
            dst[4] = 0xFF;
            dst[5] = 0xFF;
        },
        .invoke_method => {
            // Layout: [op][name_hi][name_lo][argc][ic_type_hi][ic_type_lo][ic_func_hi][ic_func_lo]  (8 bytes)
            copyBytes(code, dst, old_ip, 8);
            dst[4] = 0xFF;
            dst[5] = 0xFF;
            dst[6] = 0xFF;
            dst[7] = 0xFF;
        },

        // ── everything else: copy verbatim ────────────────────────────────────
        else => copyBytes(code, dst, old_ip, instr.width),
    }
}

// Build the defused bytecode from the given chunk state.
// Returns an allocator-owned slice. The caller must free it.
// Errors if decodeAt encounters bad bytecode (should not happen for valid compiled code).
pub fn buildDefusedCode(cs: *chunk.State, alloc: std.mem.Allocator) ![]u8 {
    const old_len = cs.code_len;
    if (old_len == 0) return try alloc.alloc(u8, 0);

    // Pass 1: walk bytecode and compute old_ip → new_ip for every instruction start.
    const ip_map = try alloc.alloc(u32, old_len + 1);
    defer alloc.free(ip_map);
    @memset(ip_map, 0);

    var old_ip: usize = 0;
    var new_ip: usize = 0;
    while (old_ip < old_len) {
        ip_map[old_ip] = @intCast(new_ip);
        const instr = try cs.decodeAt(old_ip);
        new_ip += expandedWidth(instr.op, instr.width);
        old_ip += instr.width;
    }
    ip_map[old_len] = @intCast(new_ip); // sentinel for end-of-code
    const new_len = new_ip;

    if (new_len > chunk.MaxCode) return error.DefusedCodeTooLarge;

    // Pass 2: emit expanded instructions with corrected jump offsets.
    const out = try alloc.alloc(u8, new_len);
    old_ip = 0;
    new_ip = 0;
    while (old_ip < old_len) {
        const instr = try cs.decodeAt(old_ip);
        const ew = expandedWidth(instr.op, instr.width);
        emitExpanded(cs.code[0..cs.code_len], out[new_ip .. new_ip + ew], old_ip, instr, ip_map, new_ip);
        new_ip += ew;
        old_ip += instr.width;
    }

    // Pass 3: update FuncObj.ip values in the constants pool.
    // Function objects store bytecode entry IPs; after defusing, those positions
    // shift due to expanded instructions and must be remapped through ip_map.
    // Also handles closures and predicates embedded in named_type constants.
    //
    // A FuncObj pointer may be shared across multiple const-pool entries (e.g.,
    // a plain .function entry and a .closure wrapping the same object). Track
    // which Object pointers have already been remapped so we never apply
    // ip_map twice to the same FuncObj.
    var seen_func_ptrs = std.AutoHashMap(usize, void).init(alloc);
    defer seen_func_ptrs.deinit();

    for (cs.consts[0..cs.const_count]) |v| {
        if (v != .object) continue;
        switch (v.object.*) {
            .function => |*f| {
                const key = @intFromPtr(v.object);
                const res = try seen_func_ptrs.getOrPut(key);
                if (res.found_existing) continue;
                if (f.ip < ip_map.len) f.ip = @intCast(ip_map[f.ip]);
            },
            .closure => |*cl| {
                if (cl.func.* == .function) {
                    const key = @intFromPtr(cl.func);
                    const res = try seen_func_ptrs.getOrPut(key);
                    if (res.found_existing) continue;
                    if (cl.func.function.ip < ip_map.len)
                        cl.func.function.ip = @intCast(ip_map[cl.func.function.ip]);
                }
            },
            .named_type => |nt| {
                if (nt.predicate) |pred| {
                    switch (pred.*) {
                        .function => |*f| {
                            const key = @intFromPtr(pred);
                            const res = try seen_func_ptrs.getOrPut(key);
                            if (res.found_existing) continue;
                            if (f.ip < ip_map.len) f.ip = @intCast(ip_map[f.ip]);
                        },
                        .closure => |*cl| {
                            if (cl.func.* == .function) {
                                const key = @intFromPtr(cl.func);
                                const res = try seen_func_ptrs.getOrPut(key);
                                if (res.found_existing) continue;
                                if (cl.func.function.ip < ip_map.len)
                                    cl.func.function.ip = @intCast(ip_map[cl.func.function.ip]);
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return out;
}
