// Bytecode fusion pass: rewrite verified core-op bytecode into the VM's
// fused/specialized instruction set. This is the forward direction of
// vm_defuse.zig and the load/compile-time half of the ratified GBC design
// (see dev-docs/design/vm-architecture.md §6.3 and GitHub issue #5): the
// wire format carries only core ops; this pass selects the VM-private
// fused tier.
//
// Every fusion is a pair of adjacent instructions where the second is not a
// branch target — the single legality rule that replaces the emitter
// peephole's per-boundary tracker invalidation. Multi-instruction fusions
// (quads, quints, loop forms) emerge by running the pair rewrite to a
// fixpoint: each iteration fuses what the previous one made adjacent,
// mirroring the emitter's staged construction.
//
// Multi-instruction fusions that are not chains of pairs (local_add_local,
// local_add_field) match as an explicit 4-instruction window with the same
// legality rule applied to each interior position. Constant folding is OUT
// OF SCOPE by design — it mutates the constant pool (wire content) and
// stays in the compiler.
//
// Tail-call note: call+ret flips to call_tail in the first round, before
// get_local_const_sub can form, so the fused call chain grows from the
// _tail variants (glc_sub + call_tail → glsc_tail → cglsc_tail); no ret
// flip is ever needed on an already-fused call op.

const std = @import("std");
const chunk = @import("chunk.zig");
const chunk_decoder = @import("chunk_decoder.zig");
const Op = @import("op.zig").Op;

fn opAt(cs: *const chunk.State, pos: usize) Op {
    return @enumFromInt(cs.code[pos]);
}

fn readU32(cs: *const chunk.State, pos: usize) u32 {
    return (@as(u32, cs.code[pos]) << 24) | (@as(u32, cs.code[pos + 1]) << 16) |
        (@as(u32, cs.code[pos + 2]) << 8) | @as(u32, cs.code[pos + 3]);
}

const Bits = struct {
    bytes: []u8,
    fn set(self: Bits, idx: usize) void {
        self.bytes[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
    }
    fn has(self: Bits, idx: usize) bool {
        return (self.bytes[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
    }
};

// The fused opcode for an adjacent (a, b) pair, or null. Pure structure —
// legality (branch targets) is the caller's job. `same_slot` carries the
// local_add_const requirement (get_local slot == set_local slot).
fn pairFusion(a: Op, b: Op, same_slot: bool) ?Op {
    return switch (a) {
        .constant => switch (b) {
            .eq => .const_eq,
            .sub => .const_sub,
            .add => .const_add,
            .lt => .const_lt,
            .gt => .const_gt,
            .ret => .ret_const,
            else => null,
        },
        .get_local => switch (b) {
            .const_eq => .get_local_const_eq,
            .const_sub => .get_local_const_sub,
            .const_add => .get_local_const_add,
            .const_lt => .get_local_const_lt,
            .const_gt => .get_local_const_gt,
            .get_field => .get_local_get_field,
            .ret => .get_local_ret,
            else => null,
        },
        .get_global => switch (b) {
            .const_eq => .get_global_const_eq,
            .const_sub => .get_global_const_sub,
            .const_add => .get_global_const_add,
            .const_lt => .get_global_const_lt,
            .get_local_const_sub_call => .call_global_local_sub_const,
            .get_local_const_sub_call_tail => .call_global_local_sub_const_tail,
            .get_global_call => .call_global_global,
            .get_global_call_tail => .call_global_global_tail,
            else => null,
        },
        .get_local_const_sub => switch (b) {
            .call => .get_local_const_sub_call,
            .call_tail => .get_local_const_sub_call_tail,
            else => null,
        },
        .get_local_const_eq => if (b == .jif_pop) .get_local_const_eq_jif_pop else null,
        .get_local_const_lt => if (b == .jif_pop) .get_local_const_lt_jif_pop else null,
        .get_local_const_gt => if (b == .jif_pop) .get_local_const_gt_jif_pop else null,
        .get_global_const_lt => if (b == .jif_pop) .get_global_const_lt_jif_pop else null,
        .get_local_const_lt_jif_pop => if (b == .jump) .get_local_const_lt_jif_pop_jump else null,
        .get_local_const_add => if (b == .set_local and same_slot) .local_add_const else null,
        .local_add_const => if (b == .loop) .local_add_const_loop else null,
        .set_global => if (b == .loop) .set_global_loop else null,
        .close_upvalue => if (b == .loop) .close_upvalue_loop else null,
        .inc_global_const => if (b == .close_upvalue_loop) .inc_global_const_loop else if (b == .loop) .inc_global_const_loop_nc else null,
        .add => if (b == .ret) .add_ret else null,
        else => null,
    };
}

fn pairFusionFull(cs: *const chunk.State, a_pos: usize, a: Op, b_pos: usize, b: Op) ?Op {
    if (a == .get_local_const_add) {
        // Two continuations share one source op.
        if (b == .set_local and cs.code[a_pos + 1] == cs.code[b_pos + 1]) return .local_add_const;
        if (b == .ret) return .get_local_const_add_ret;
        return null;
    }
    if (a == .get_global) {
        // get_global arg + call N (N > 0): the get_global is loading the last arg,
        // so only safe when argc > 0 (argc = 0 means get_global IS the function).
        if (b == .call and (cs.code[b_pos + 1] & 0x7F) > 0) return .get_global_call;
        if (b == .call_tail and (cs.code[b_pos + 1] & 0x7F) > 0) return .get_global_call_tail;
    }
    if (a == .get_global_const_add) {
        // g = g + k: only when both name operands agree.
        if (b == .set_global and
            cs.code[a_pos + 1] == cs.code[b_pos + 1] and
            cs.code[a_pos + 2] == cs.code[b_pos + 2]) return .inc_global_const;
        // Loop variant: set_global + loop already fused to set_global_loop.
        // Fuse the full inc+loop chain when the loop var is not captured.
        if (b == .set_global_loop and
            cs.code[a_pos + 1] == cs.code[b_pos + 1] and
            cs.code[a_pos + 2] == cs.code[b_pos + 2]) return .inc_global_const_loop_nc;
        return null;
    }
    const same_slot = false;
    return pairFusion(a, b, same_slot);
}

// The three 4-instruction fusions:
//   get_local dst; <src push>; add; set_local dst           -> local_add_{local,field}
//   get_local slot; get_local_get_field(same slot); const_add; set_field(same field) -> field_add_const
// Caller has already cleared b_pos as a branch target; interior positions
// (the third and fourth instructions) are checked here.
fn fuse4At(cs: *const chunk.State, a_pos: usize, b_pos: usize, b: Op, old_len: usize, targets: Bits) ?Op {
    const b_width: usize = switch (b) {
        .get_local => 2,
        .get_local_get_field => 8,
        else => return null,
    };
    const c_pos = b_pos + b_width;
    if (c_pos >= old_len) return null;
    const c = opAt(cs, c_pos);
    if (c == .const_add and b == .get_local_get_field) {
        const d_pos = c_pos + 3; // const_add width
        if (d_pos + 6 > old_len) return null;
        if (opAt(cs, d_pos) != .set_field) return null;
        if (cs.code[a_pos + 1] != cs.code[b_pos + 1]) return null; // receiver slot match
        // Field name (u16 const index): glgf's at b_pos+3, set_field's at d_pos+1.
        if (cs.code[b_pos + 3] != cs.code[d_pos + 1] or cs.code[b_pos + 4] != cs.code[d_pos + 2]) return null;
        if (targets.has(c_pos) or targets.has(d_pos)) return null;
        return .field_add_const;
    }
    const d_pos = c_pos + 1; // set_local
    if (d_pos + 2 > old_len) return null;
    if (c != .add or opAt(cs, d_pos) != .set_local) return null;
    if (cs.code[a_pos + 1] != cs.code[d_pos + 1]) return null; // dst slot match
    if (targets.has(c_pos) or targets.has(d_pos)) return null;
    return if (b == .get_local) .local_add_local else .local_add_field;
}

fn fuse4Consumed(f: Op) usize {
    return switch (f) {
        .local_add_local => 7, // get_local(2)+get_local(2)+add(1)+set_local(2)
        .local_add_field => 13, // get_local(2)+get_local_get_field(8)+add(1)+set_local(2)
        .field_add_const => 19, // get_local(2)+get_local_get_field(8)+const_add(3)+set_field(6)
        else => unreachable,
    };
}

// Width of the 3rd instruction (add / const_add) in a fuse4 window — Pass B
// uses this to mark the 3rd/4th interior positions correctly; add is 1 byte,
// const_add is 3.
fn fuse4ThirdWidth(f: Op) usize {
    return if (f == .field_add_const) 3 else 1;
}

pub const FuseError = error{ OutOfMemory, BytecodeOutOfBounds, BadOpcode, BadConstantIndex, BadJumpTarget };

/// One rewrite iteration. Returns true if anything fused.
fn fuseOnce(cs: *chunk.State, alloc: std.mem.Allocator) FuseError!bool {
    const old_len = cs.code_len;
    if (old_len == 0) return false;

    const bit_len = (old_len + 7) / 8;
    const target_bytes = try alloc.alloc(u8, bit_len);
    defer alloc.free(target_bytes);
    @memset(target_bytes, 0);
    const targets = Bits{ .bytes = target_bytes };

    // Pass A: mark every branch target and function entry — fusion may not
    // consume an instruction that control flow can enter directly.
    {
        var ip: usize = 0;
        while (ip < old_len) {
            const inst = try chunk_decoder.decodeAt(cs, ip);
            if (inst.jump_target) |t| {
                if (t < old_len) targets.set(t);
            }
            // The quint carries a second branch target (the body offset,
            // end-based) that the decoder does not surface.
            if (opAt(cs, ip) == .get_local_const_lt_jif_pop_jump) {
                const body_t = ip + 13 + @as(usize, readU32(cs, ip + 9));
                if (body_t < old_len) targets.set(body_t);
            }
            ip += inst.width;
        }
        for (cs.consts[0..cs.const_count]) |cv| {
            if (cv != .object) continue;
            switch (cv.object.*) {
                .function => {
                    const fip = cv.object.function.ip;
                    if (fip < old_len) targets.set(fip);
                },
                .closure => |cl| {
                    if (cl.func.* == .function) {
                        const fip = cl.func.function.ip;
                        if (fip < old_len) targets.set(fip);
                    }
                },
                .named_type => |nt| {
                    if (nt.predicate) |pred| {
                        switch (pred.*) {
                            .function => {
                                if (pred.function.ip < old_len) targets.set(pred.function.ip);
                            },
                            .closure => |cl| {
                                if (cl.func.* == .function and cl.func.function.ip < old_len)
                                    targets.set(cl.func.function.ip);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        // Module boundaries are entry points too: fusing across one would
        // leave its ip_start pointing into a fused pair's interior.
        for (cs.module_boundaries[0..cs.module_boundary_count]) |mb| {
            if (mb.ip_start < old_len) targets.set(mb.ip_start);
        }
    }

    // Pass B: measure — decide fusions, build old→new position map.
    const ip_map = try alloc.alloc(u32, old_len + 1);
    defer alloc.free(ip_map);
    var changed = false;
    {
        var ip: usize = 0;
        var new_ip: usize = 0;
        while (ip < old_len) {
            ip_map[ip] = @intCast(new_ip);
            const inst = try chunk_decoder.decodeAt(cs, ip);
            const decision = try decideAt(cs, ip, inst, old_len, targets);
            switch (decision) {
                .keep => new_ip += inst.width,
                .flip_tail => {
                    // Same width, but it IS a change — without this, a chunk
                    // whose only rewrite is tail upgrades would never emit.
                    new_ip += inst.width;
                    changed = true;
                },
                .fuse => |f| {
                    // Interior positions of the pair also map to the fused start
                    // (nothing may jump there — legality guaranteed above).
                    const b_inst = try chunk_decoder.decodeAt(cs, ip + inst.width);
                    ip_map[ip + inst.width] = @intCast(new_ip);
                    new_ip += fusedWidth(f);
                    ip += inst.width + b_inst.width;
                    changed = true;
                    continue;
                },
                .fuse4 => |f| {
                    // Map all three interior instruction starts to the fused start.
                    // The 3rd instruction's width varies (add=1, const_add=3 for
                    // field_add_const), so it's looked up rather than assumed.
                    const b_pos = ip + inst.width;
                    const b_inst = try chunk_decoder.decodeAt(cs, b_pos);
                    const c_pos = b_pos + b_inst.width;
                    const d_pos = c_pos + fuse4ThirdWidth(f);
                    ip_map[b_pos] = @intCast(new_ip);
                    ip_map[c_pos] = @intCast(new_ip);
                    ip_map[d_pos] = @intCast(new_ip);
                    new_ip += fusedWidth(f);
                    ip += fuse4Consumed(f);
                    changed = true;
                    continue;
                },
            }
            ip += inst.width;
        }
        ip_map[old_len] = @intCast(new_ip);
    }
    if (!changed) return false;

    // Pass C: emit into scratch, retargeting every branch through ip_map.
    const new_cap = old_len; // fusion only shrinks
    const out = try alloc.alloc(u8, new_cap);
    defer alloc.free(out);
    // Sparse line table for the fused output. Fusion only merges instructions,
    // so the number of unique (line, col) transitions can only decrease.
    const out_line_table = try alloc.alloc(chunk.LineEntry, @max(cs.line_table_count, 1));
    defer alloc.free(out_line_table);

    var new_len: usize = 0;
    var out_lt_count: usize = 0;
    var last_lt_line: u16 = 0;
    var last_lt_col: u16 = 0xffff;
    {
        var ip: usize = 0;
        while (ip < old_len) {
            const src_pos = ip;
            const inst = try chunk_decoder.decodeAt(cs, ip);
            const decision = try decideAt(cs, ip, inst, old_len, targets);
            const start = new_len;
            switch (decision) {
                .keep => {
                    @memcpy(out[new_len..][0..inst.width], cs.code[ip..][0..inst.width]);
                    new_len += inst.width;
                    try retargetCopied(cs, ip, inst, out, start, ip_map);
                    ip += inst.width;
                },
                .flip_tail => {
                    @memcpy(out[new_len..][0..inst.width], cs.code[ip..][0..inst.width]);
                    out[start] = switch (opAt(cs, ip)) {
                        .call => @intFromEnum(Op.call_tail),
                        else => out[start],
                    };
                    new_len += inst.width;
                    try retargetCopied(cs, ip, inst, out, start, ip_map);
                    ip += inst.width;
                },
                .fuse => |f| {
                    const b_pos = ip + inst.width;
                    const b_inst = try chunk_decoder.decodeAt(cs, b_pos);
                    new_len += try emitFused(cs, f, ip, inst, b_pos, b_inst, out, start, ip_map);
                    ip = b_pos + b_inst.width;
                },
                .fuse4 => |f| {
                    const b_pos = ip + inst.width;
                    new_len += emitFused4(cs, f, ip, b_pos, out, start);
                    ip += fuse4Consumed(f);
                },
            }
            // Line/col attribution: the whole (possibly fused) emission
            // carries the source position of its first origin instruction.
            // Record a sparse entry only when (line, col) changes.
            const src_line = cs.lineAt(src_pos);
            const src_col = cs.colAt(src_pos);
            if (src_line != last_lt_line or src_col != last_lt_col) {
                if (out_lt_count < out_line_table.len) {
                    out_line_table[out_lt_count] = .{
                        .ip = @intCast(start),
                        .line = src_line,
                        .col = src_col,
                    };
                    out_lt_count += 1;
                    last_lt_line = src_line;
                    last_lt_col = src_col;
                }
            }
        }
    }

    // Install: code, line_table, function entry ips, module boundaries.
    @memcpy(cs.code[0..new_len], out[0..new_len]);
    @memcpy(cs.line_table[0..out_lt_count], out_line_table[0..out_lt_count]);
    cs.line_table_count = out_lt_count;
    if (out_lt_count > 0) {
        cs.last_emitted_line = out_line_table[out_lt_count - 1].line;
        cs.last_emitted_col = out_line_table[out_lt_count - 1].col;
    } else {
        cs.last_emitted_line = 0;
        cs.last_emitted_col = 0xffff;
    }
    cs.code_len = new_len;
    try cs.remapConstFuncIps(ip_map, alloc);
    for (cs.module_boundaries[0..cs.module_boundary_count]) |*mb| {
        if (mb.ip_start <= old_len) mb.ip_start = ip_map[mb.ip_start];
    }
    if (cs.std_script_code_end <= old_len) cs.std_script_code_end = ip_map[cs.std_script_code_end];
    cs.verified = false;
    cs.verified_code_len = 0;
    return true;
}

const Decision = union(enum) { keep, flip_tail, fuse: Op, fuse4: Op };

fn decideAt(cs: *const chunk.State, ip: usize, inst: chunk_decoder.DecodedInstruction, old_len: usize, targets: Bits) FuseError!Decision {
    const b_pos = ip + inst.width;
    if (b_pos >= old_len) return .keep;
    const a = opAt(cs, ip);
    const b = opAt(cs, b_pos);
    // Tail upgrade: an opcode flip, not a merge — always safe, target or not.
    if (a == .call and b == .ret) return .flip_tail;
    if (targets.has(b_pos)) return .keep;
    if (a == .get_local) {
        if (fuse4At(cs, ip, b_pos, b, old_len, targets)) |f| return .{ .fuse4 = f };
    }
    if (pairFusionFull(cs, ip, a, b_pos, b)) |f| return .{ .fuse = f };
    return .keep;
}

fn fusedWidth(f: Op) usize {
    return switch (f) {
        .const_eq, .const_sub, .const_add, .const_lt, .const_gt, .ret_const => 3,
        .get_local_const_eq, .get_local_const_sub, .get_local_const_add, .get_local_const_lt, .get_local_const_gt => 5,
        .get_global_const_eq, .get_global_const_sub, .get_global_const_add, .get_global_const_lt => 8,
        .get_local_const_sub_call, .get_local_const_sub_call_tail => 8,
        .call_global_local_sub_const, .call_global_local_sub_const_tail => 13,
        .get_local_get_field, .inc_global_const => 8,
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop, .set_global_loop => 9,
        .inc_global_const_loop => 13,
        .inc_global_const_loop_nc => 12,
        .get_global_const_lt_jif_pop => 12,
        .get_local_const_lt_jif_pop_jump => 13,
        .local_add_const => 4,
        .local_add_const_loop => 8,
        .close_upvalue_loop => 6,
        .local_add_local => 3,
        .local_add_field => 9,
        .field_add_const => 15,
        .get_local_ret => 2,
        .add_ret => 1,
        .get_local_const_add_ret => 5,
        .get_global_call, .get_global_call_tail => 8,
        .call_global_global, .call_global_global_tail => 12,
        else => unreachable,
    };
}

fn writeU32Into(out: []u8, pos: usize, v: u32) void {
    out[pos] = @intCast((v >> 24) & 0xff);
    out[pos + 1] = @intCast((v >> 16) & 0xff);
    out[pos + 2] = @intCast((v >> 8) & 0xff);
    out[pos + 3] = @intCast(v & 0xff);
}

// Re-point the branch operand of a verbatim-copied instruction through ip_map.
fn retargetCopied(cs: *const chunk.State, ip: usize, inst: chunk_decoder.DecodedInstruction, out: []u8, start: usize, ip_map: []const u32) FuseError!void {
    const t = inst.jump_target orelse return;
    const new_target = ip_map[t];
    const new_end_or_base: usize = switch (opAt(cs, ip)) {
        // Forward branches: target = pos + base_off + off.
        .jump, .jump_if_false, .jump_if_not_null, .jif_pop => start + 5,
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop => start + 9,
        .get_global_const_lt_jif_pop => start + 12,
        .get_local_const_lt_jif_pop_jump => start + 9, // exit offset; body handled below
        // Backward: target = pos + width - off.
        .loop => start + 5,
        .set_global_loop => start + 9,
        .close_upvalue_loop => start + 6,
        .local_add_const_loop => start + 8,
        .inc_global_const_loop => start + 13,
        .inc_global_const_loop_nc => start + 12,
        else => return,
    };
    const off_pos: usize = switch (opAt(cs, ip)) {
        .jump, .jump_if_false, .jump_if_not_null, .jif_pop, .loop => start + 1,
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop, .set_global_loop => start + 5,
        .get_global_const_lt_jif_pop => start + 8,
        .get_local_const_lt_jif_pop_jump => start + 5,
        .close_upvalue_loop => start + 2,
        .local_add_const_loop => start + 4,
        .inc_global_const_loop => start + 9,
        .inc_global_const_loop_nc => start + 8,
        else => return,
    };
    switch (opAt(cs, ip)) {
        .loop, .set_global_loop, .close_upvalue_loop, .local_add_const_loop, .inc_global_const_loop, .inc_global_const_loop_nc => {
            writeU32Into(out, off_pos, @intCast(new_end_or_base - new_target));
        },
        else => {
            writeU32Into(out, off_pos, @intCast(new_target - new_end_or_base));
        },
    }
    // Quint body offset: base is instruction end (start+13).
    if (opAt(cs, ip) == .get_local_const_lt_jif_pop_jump) {
        const body_off = readU32(cs, ip + 9);
        const body_target = ip + 13 + @as(usize, body_off);
        writeU32Into(out, start + 9, @intCast(ip_map[body_target] - (start + 13)));
    }
}

fn emitFused(cs: *const chunk.State, f: Op, a_pos: usize, a_inst: chunk_decoder.DecodedInstruction, b_pos: usize, b_inst: chunk_decoder.DecodedInstruction, out: []u8, start: usize, ip_map: []const u32) FuseError!usize {
    _ = a_inst;
    const w = fusedWidth(f);
    out[start] = @intFromEnum(f);
    switch (f) {
        // [const_X][idx2] from constant[idx2] + binop
        .const_eq, .const_sub, .const_add, .const_lt, .const_gt, .ret_const => {
            out[start + 1] = cs.code[a_pos + 1];
            out[start + 2] = cs.code[a_pos + 2];
        },
        // [glcX][slot][skip=const_X op][idx2]
        .get_local_const_eq, .get_local_const_sub, .get_local_const_add, .get_local_const_lt, .get_local_const_gt => {
            out[start + 1] = cs.code[a_pos + 1];
            out[start + 2] = cs.code[b_pos]; // embedded const_X opcode (verifier checks it)
            out[start + 3] = cs.code[b_pos + 1];
            out[start + 4] = cs.code[b_pos + 2];
        },
        // [ggcX][name2][ic2][skip=const_X op][idx2]
        .get_global_const_eq, .get_global_const_sub, .get_global_const_add, .get_global_const_lt => {
            @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]);
            out[start + 5] = cs.code[b_pos];
            out[start + 6] = cs.code[b_pos + 1];
            out[start + 7] = cs.code[b_pos + 2];
        },
        // [glsc][slot][skip=const_sub op][idx2][argc][ic2] from glc_sub(5) + call(4)
        .get_local_const_sub_call, .get_local_const_sub_call_tail => {
            @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]);
            @memcpy(out[start + 5 ..][0..3], cs.code[b_pos + 1 ..][0..3]); // argc + call IC
        },
        // [cglsc][name2][ic2][skip][glsc operands verbatim]. The skip byte is
        // always the NON-tail glsc opcode — tailness lives in byte 0 only
        // (the emitter's ret-flip touched byte 0 alone; verifier checks this).
        .call_global_local_sub_const, .call_global_local_sub_const_tail => {
            @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]);
            out[start + 5] = @intFromEnum(Op.get_local_const_sub_call);
            @memcpy(out[start + 6 ..][0..7], cs.code[b_pos + 1 ..][0..7]);
        },
        // [glgf][slot][skip=get_field op][name2][ic_type2][ic_fidx] from get_local(2) + get_field(6)
        .get_local_get_field => {
            out[start + 1] = cs.code[a_pos + 1];
            @memcpy(out[start + 2 ..][0..6], cs.code[b_pos..][0..6]);
        },
        // [igc] = ggc_add's bytes with the opcode swapped; set_global (same name) dropped
        .inc_global_const => {
            @memcpy(out[start + 1 ..][0..7], cs.code[a_pos + 1 ..][0..7]);
        },
        // [quad][slot][skip][idx2][off4]: off base = start+9
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop, .get_local_const_gt_jif_pop => {
            @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]);
            const t = b_inst.jump_target.?;
            writeU32Into(out, start + 5, @intCast(ip_map[t] - (start + 9)));
        },
        // [ggc quad][name2][ic2][skip][idx2][off4]: off base = start+12
        .get_global_const_lt_jif_pop => {
            @memcpy(out[start + 1 ..][0..7], cs.code[a_pos + 1 ..][0..7]);
            const t = b_inst.jump_target.?;
            writeU32Into(out, start + 8, @intCast(ip_map[t] - (start + 12)));
        },
        // [quint][slot][skip][idx2][exit4][body4]: exit base start+9, body base start+13
        .get_local_const_lt_jif_pop_jump => {
            @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]);
            const exit_t = a_inst_target(cs, a_pos);
            writeU32Into(out, start + 5, @intCast(ip_map[exit_t] - (start + 9)));
            const body_t = b_inst.jump_target.?;
            writeU32Into(out, start + 9, @intCast(ip_map[body_t] - (start + 13)));
        },
        // [lac][dst][idx2] from glc_add[slot][skip][idx2] + set_local[dst]
        .local_add_const => {
            out[start + 1] = cs.code[a_pos + 1];
            out[start + 2] = cs.code[a_pos + 3];
            out[start + 3] = cs.code[a_pos + 4];
        },
        // [lacl][dst][idx2][off4] from lac + loop; backward: target = start+8-off
        .local_add_const_loop => {
            @memcpy(out[start + 1 ..][0..3], cs.code[a_pos + 1 ..][0..3]);
            const t = b_inst.jump_target.?;
            writeU32Into(out, start + 4, @intCast((start + 8) - ip_map[t]));
        },
        // [sgl][name2][ic2][off4]; backward: target = start+9-off
        .set_global_loop => {
            @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]);
            const t = b_inst.jump_target.?;
            writeU32Into(out, start + 5, @intCast((start + 9) - ip_map[t]));
        },
        // [cul][slot][off4]; backward: target = start+6-off
        .close_upvalue_loop => {
            out[start + 1] = cs.code[a_pos + 1];
            const t = b_inst.jump_target.?;
            writeU32Into(out, start + 2, @intCast((start + 6) - ip_map[t]));
        },
        // [igcl][name2][ic2][add_skip][val2][cup_slot][off4]; backward: target = start+13-off
        // Input: inc_global_const(8) + close_upvalue_loop(6): captured var, cup_slot from b[1].
        .inc_global_const_loop => {
            @memcpy(out[start + 1 ..][0..7], cs.code[a_pos + 1 ..][0..7]);
            out[start + 8] = cs.code[b_pos + 1]; // cup_slot from close_upvalue_loop
            const t = b_inst.jump_target.?;
            writeU32Into(out, start + 9, @intCast((start + 13) - ip_map[t]));
        },
        // [igclnc][name2][ic2][add_skip][val2][off4]; backward: target = start+12-off
        // Input: get_global_const_add(8) + set_global_loop(9): uncaptured, no cup_slot.
        .inc_global_const_loop_nc => {
            @memcpy(out[start + 1 ..][0..7], cs.code[a_pos + 1 ..][0..7]);
            const t = b_inst.jump_target.?;
            writeU32Into(out, start + 8, @intCast((start + 12) - ip_map[t]));
        },
        .get_local_ret => out[start + 1] = cs.code[a_pos + 1],
        .add_ret => {},
        // [glcar][slot][skip=const_add][idx_hi][idx_lo] — copy operand bytes from a (get_local_const_add)
        .get_local_const_add_ret => @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]),
        // [ggc][name_hi][name_lo][ic_hi][ic_lo][argc][c_ic_hi=FF][c_ic_lo=FF]
        // a=get_global(5), b=call/call_tail(4)
        .get_global_call, .get_global_call_tail => {
            @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]); // name + g_ic (cold)
            out[start + 5] = cs.code[b_pos + 1]; // argc byte
            out[start + 6] = 0xFF; // c_ic cold
            out[start + 7] = 0xFF;
        },
        // [cgg][f_hi][f_lo][f_ic_hi][f_ic_lo][a_hi][a_lo][a_ic_hi][a_ic_lo][argc][c_ic_hi][c_ic_lo]
        // a=get_global(5), b=get_global_call/tail(8)
        .call_global_global, .call_global_global_tail => {
            @memcpy(out[start + 1 ..][0..4], cs.code[a_pos + 1 ..][0..4]); // func name + f_ic
            @memcpy(out[start + 5 ..][0..7], cs.code[b_pos + 1 ..][0..7]); // arg name + a_ic + argc + c_ic
        },
        else => unreachable,
    }
    return w;
}

fn emitFused4(cs: *const chunk.State, f: Op, a_pos: usize, b_pos: usize, out: []u8, start: usize) usize {
    out[start] = @intFromEnum(f);
    if (f == .field_add_const) {
        // [fac][glgf verbatim: slot,skip,name2,ic_type2,ic_fidx (7)][k idx(2)][set_field verbatim: name2,ic_type2,ic_fidx (5)]
        @memcpy(out[start + 1 ..][0..7], cs.code[b_pos + 1 ..][0..7]);
        const c_pos = b_pos + 8; // get_local_get_field's width
        @memcpy(out[start + 8 ..][0..2], cs.code[c_pos + 1 ..][0..2]);
        const d_pos = c_pos + 3; // const_add's width
        @memcpy(out[start + 10 ..][0..5], cs.code[d_pos + 1 ..][0..5]);
        return fusedWidth(f);
    }
    out[start + 1] = cs.code[a_pos + 1]; // dst slot
    switch (f) {
        // [lal][dst][src] from get_local+get_local+add+set_local
        .local_add_local => out[start + 2] = cs.code[b_pos + 1],
        // [laf][dst][src][skip][name2][ic2][fidx]: glgf operand bytes verbatim
        .local_add_field => @memcpy(out[start + 2 ..][0..7], cs.code[b_pos + 1 ..][0..7]),
        else => unreachable,
    }
    return fusedWidth(f);
}

fn a_inst_target(cs: *const chunk.State, a_pos: usize) usize {
    // Quad exit target: pos + 9 + off (off at +5).
    return a_pos + 9 + @as(usize, readU32(cs, a_pos + 5));
}

/// Run the pair rewrite to fixpoint. The chunk must decode cleanly (verified
/// or verifiable); callers re-verify afterwards (fuseOnce clears the flag).
pub fn fuse(cs: *chunk.State, alloc: std.mem.Allocator) FuseError!void {
    var rounds: usize = 0;
    while (try fuseOnce(cs, alloc)) : (rounds += 1) {
        if (rounds > 16) return; // safety valve; fixpoint is ~4 stages deep
    }
}
