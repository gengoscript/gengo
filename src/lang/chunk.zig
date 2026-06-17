const Op = @import("op.zig").Op;
const Value = @import("value.zig").Value;
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");

// Jump offsets are 32-bit (4 bytes, big-endian u32). MaxCode can therefore be very large;
// 1 MiB is a practical ceiling that covers any realistic script.
pub const MaxCode = 1048576;
// Constant indices are two-byte (big-endian u16); 4096 is a practical ceiling well below
// the u16 maximum while fitting comfortably in the GC heap.
pub const MaxConst = 4096;

pub const State = struct {
    code: [MaxCode]u8 = undefined,
    lines: [MaxCode]u16 = undefined,
    cols: [MaxCode]u16 = undefined,
    consts: [MaxConst]Value = undefined,
    code_len: usize = 0,
    const_count: usize = 0,
    pending_col: u16 = 0,
    // Peephole: track position of last `constant` instruction for const-op fusion.
    last_const_code_pos: ?usize = null,
    last_const_idx: u16 = 0,
    // Peephole: track position of last `get_local` instruction (2 bytes: op + slot).
    // Used for triple-fusion: get_local + constant + eq/sub → get_local_const_eq/sub.
    // Verified via arithmetic (gl_pos + 2 == const_pos) rather than code inspection
    // to avoid false positives from data bytes of preceding instructions.
    last_get_local_code_pos: ?usize = null,
    // Peephole: position of the last get_local_const_eq triple-fused instruction.
    // Used for quad-fusion: get_local_const_eq + jif_pop → get_local_const_eq_jif_pop.
    last_triple_eq_pos: ?usize = null,
    // Peephole: position of the last get_local_const_lt triple-fused instruction.
    // Used for quad-fusion: get_local_const_lt + jif_pop → get_local_const_lt_jif_pop.
    last_triple_lt_pos: ?usize = null,
    // Peephole: position of the last get_local_const_sub triple-fused instruction.
    // Used for fusion: get_local_const_sub + call → get_local_const_sub_call.
    last_get_local_const_sub_pos: ?usize = null,
    // Peephole: position of the last get_local_const_add triple-fused instruction.
    // Used for fusion: get_local_const_add + set_local → local_add_const.
    last_get_local_const_add_pos: ?usize = null,
    // Peephole: position of the last set_global instruction.
    // Used for fusion: set_global + loop → set_global_loop.
    last_set_global_code_pos: ?usize = null,
};

var g_default_state: State = .{};
pub var g_state: *State = &g_default_state;

pub fn setActive(state: *State) void {
    g_state = state;
}

pub fn reset() void {
    g_state.code_len = 0;
    g_state.const_count = 0;
    g_state.pending_col = 0;
    g_state.last_const_code_pos = null;
    g_state.last_const_idx = 0;
    g_state.last_get_local_code_pos = null;
    g_state.last_triple_eq_pos = null;
    g_state.last_triple_lt_pos = null;
    g_state.last_get_local_const_sub_pos = null;
    g_state.last_get_local_const_add_pos = null;
    g_state.last_set_global_code_pos = null;
}

pub fn setCol(col: u32) void {
    g_state.pending_col = @intCast(@min(col, 0xffff));
}

pub fn emitByte(b: u8, line: u32) !void {
    if (g_state.code_len >= MaxCode) return error.ChunkFull;
    g_state.code[g_state.code_len] = b;
    g_state.lines[g_state.code_len] = @intCast(if (line > 0xffff) 0xffff else line);
    g_state.cols[g_state.code_len] = g_state.pending_col;
    g_state.code_len += 1;
}

pub fn emitOp(op: Op, line: u32) !void {
    // Peephole: constant k immediately preceding ret → ret_const k (3 bytes, 1 dispatch).
    if (op == .ret) {
        if (g_state.last_const_code_pos) |pos| {
            if (pos + 3 == g_state.code_len) {
                g_state.code[pos] = @intFromEnum(Op.ret_const);
                g_state.last_const_code_pos = null;
                return; // ret_const reuses the 3-byte constant slot; no extra byte needed
            }
        }
        // Peephole: get_local slot immediately preceding ret → get_local_ret slot (2 bytes, 1 dispatch).
        if (g_state.last_get_local_code_pos) |gl_pos| {
            if (gl_pos + 2 == g_state.code_len) {
                g_state.code[gl_pos] = @intFromEnum(Op.get_local_ret);
                g_state.last_get_local_code_pos = null;
                return; // get_local_ret reuses the 2-byte get_local slot; no extra byte needed
            }
        }
        // Peephole: add immediately preceding ret → add_ret (1 byte, 1 dispatch).
        if (g_state.code_len > 0) {
            const prev = g_state.code[g_state.code_len - 1];
            if (prev == @intFromEnum(Op.add)) {
                g_state.code[g_state.code_len - 1] = @intFromEnum(Op.add_ret);
                return; // overwrites the add opcode in place
            }
        }
    }
    // Peephole: get_local_const_sub immediately preceding call → get_local_const_sub_call (6 bytes, 1 dispatch).
    if (op == .call) {
        if (g_state.last_get_local_const_sub_pos) |sub_pos| {
            if (sub_pos + 5 == g_state.code_len) {
                g_state.code[sub_pos] = @intFromEnum(Op.get_local_const_sub_call);
                g_state.last_get_local_const_sub_pos = null;
                return; // reuses the 5-byte get_local_const_sub + 1-byte argc
            }
        }
    }
    return emitByte(@intFromEnum(op), line);
}

pub fn emit2(a: u8, b: u8, line: u32) !void {
    try emitByte(a, line);
    try emitByte(b, line);
    if (a == @intFromEnum(Op.get_local)) {
        g_state.last_get_local_code_pos = g_state.code_len - 2;
    }
    if (a == @intFromEnum(Op.call)) {
        if (g_state.last_get_local_const_sub_pos) |sub_pos| {
            if (sub_pos + 5 == g_state.code_len - 2) {
                g_state.code[sub_pos] = @intFromEnum(Op.get_local_const_sub_call);
                g_state.code[sub_pos + 5] = b; // argc moves to position 5
                g_state.code_len -= 1;
                g_state.last_get_local_const_sub_pos = null;
            } else {
                g_state.last_get_local_const_sub_pos = null; // stale tracker
            }
        }
    }
    if (a == @intFromEnum(Op.set_local)) {
        // Fusion: get_local_const_add dst K + set_local dst → local_add_const dst K_hi K_lo (4 bytes, 1 dispatch).
        if (g_state.last_get_local_const_add_pos) |pos| {
            g_state.last_get_local_const_add_pos = null;
            if (pos + 5 == g_state.code_len - 2 and g_state.code[pos + 1] == b) {
                g_state.code[pos] = @intFromEnum(Op.local_add_const);
                // Shift K_hi/K_lo left over the skipped const_add byte: [dst][skip][K_hi][K_lo] → [dst][K_hi][K_lo]
                g_state.code[pos + 2] = g_state.code[pos + 3];
                g_state.code[pos + 3] = g_state.code[pos + 4];
                g_state.code_len = pos + 4;
                return;
            }
        }
        // Fusion: get_local dst; get_local src; add; set_local dst → local_add_local dst src (3 bytes, 1 dispatch).
        if (g_state.code_len >= 7) {
            const p = g_state.code_len - 7;
            if (g_state.code[p] == @intFromEnum(Op.get_local) and
                g_state.code[p + 1] == b and
                g_state.code[p + 2] == @intFromEnum(Op.get_local) and
                g_state.code[p + 4] == @intFromEnum(Op.add))
            {
                const src = g_state.code[p + 3];
                g_state.code[p] = @intFromEnum(Op.local_add_local);
                g_state.code[p + 1] = b;   // dst
                g_state.code[p + 2] = src; // src
                g_state.code_len = p + 3;
                return;
            }
        }
    }
}

// Emit opcode + 2-byte constant index (big-endian).
pub fn emitConstIdx(op: Op, idx: u16, line: u32) !void {
    try emitByte(@intFromEnum(op), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
}

// Add constant v and emit opcode + its 2-byte index.
pub fn emitOpConst(op: Op, v: Value, line: u32) !void {
    const idx = try addConst(v);
    try emitConstIdx(op, idx, line);
    if (op == .constant) {
        g_state.last_const_code_pos = g_state.code_len - 3;
        g_state.last_const_idx = idx;
    } else {
        g_state.last_const_code_pos = null;
    }
}

// Emit a binary op, fusing with a preceding `constant` instruction when possible.
// If the last emitted instruction was `constant k`, replaces it in-place with
// const_eq/const_sub/const_add/const_lt (same bytecode layout, different opcode byte).
// If the instruction before that was `get_local`, further fuses to
// get_local_const_eq / get_local_const_sub / get_local_const_add / get_local_const_lt (triple fusion, same 5-byte layout).
pub fn emitBinOpFused(op: Op, line: u32) !void {
    if (g_state.last_const_code_pos) |pos| {
        if (pos + 3 == g_state.code_len) {
            const fused: ?Op = switch (op) {
                .eq  => .const_eq,
                .sub => .const_sub,
                .add => .const_add,
                .lt  => .const_lt,
                else => null,
            };
            if (fused) |fop| {
                g_state.code[pos] = @intFromEnum(fop);
                // Triple fusion: get_local (2 bytes) must be provably the instruction
                // immediately before the constant — use position arithmetic, not a
                // code-byte inspect, to avoid false positives from preceding data bytes.
                if (g_state.last_get_local_code_pos) |gl_pos| {
                    if (gl_pos + 2 == pos) {
                        const triple: ?Op = switch (fop) {
                            .const_eq  => .get_local_const_eq,
                            .const_sub => .get_local_const_sub,
                            .const_add => .get_local_const_add,
                            .const_lt  => .get_local_const_lt,
                            else       => null,
                        };
                        if (triple) |top| {
                            g_state.code[gl_pos] = @intFromEnum(top);
                            // Layout: [top][slot][fop_byte(skip)][idx_hi][idx_lo]
                            // code[gl_pos+1] = slot, code[pos] = fop (skip byte),
                            // code[pos+1..+2] = const_idx — all unchanged.
                            if (top == .get_local_const_eq) {
                                g_state.last_triple_eq_pos = gl_pos;
                            } else if (top == .get_local_const_lt) {
                                g_state.last_triple_lt_pos = gl_pos;
                            } else if (top == .get_local_const_sub) {
                                g_state.last_get_local_const_sub_pos = gl_pos;
                            } else if (top == .get_local_const_add) {
                                g_state.last_get_local_const_add_pos = gl_pos;
                            }
                        }
                    }
                }
                g_state.last_const_code_pos = null;
                return;
            }
        }
    }
    g_state.last_const_code_pos = null;
    try emitOp(op, line);
}

// Deduplicate + store constant; return its 2-byte index.
pub fn addConst(v: Value) !u16 {
    // Deduplicate string constants to conserve slots.
    var to_store = v;
    if (v == .string) {
        var i: usize = 0;
        while (i < g_state.const_count) : (i += 1) {
            if (g_state.consts[i] == .string and common.streq(g_state.consts[i].string, v.string)) {
                return @intCast(i);
            }
        }
        const copy = heap.bump(u8, v.string.len) orelse return error.OutOfMemory;
        @memcpy(copy[0..v.string.len], v.string);
        to_store = .{ .string = copy[0..v.string.len] };
    }
    if (g_state.const_count >= MaxConst) return error.TooManyConstants;
    const idx = g_state.const_count;
    g_state.consts[idx] = to_store;
    g_state.const_count += 1;
    return @intCast(idx);
}

// Emit .constant opcode + 2-byte index.
pub fn emitConst(v: Value, line: u32) !void {
    try emitOpConst(.constant, v, line);
}

pub fn patchByte(offset: usize, val: u8) void {
    g_state.code[offset] = val;
}

// Emit get_global: op + name_idx(2) + ic_slot(2, cold=0xFFFF).
pub fn emitGetGlobal(name: []const u8, line: u32) !void {
    const idx = try addConst(.{ .string = name });
    try emitByte(@intFromEnum(Op.get_global), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
}

// Emit get_global when constant index is already known.
pub fn emitGetGlobalIdx(idx: u16, line: u32) !void {
    try emitByte(@intFromEnum(Op.get_global), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
}

// Emit set_global: op + name_idx(2) + ic_slot(2, cold=0xFFFF).
pub fn emitSetGlobal(name: []const u8, line: u32) !void {
    const idx = try addConst(.{ .string = name });
    try emitByte(@intFromEnum(Op.set_global), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    g_state.last_set_global_code_pos = g_state.code_len - 5;
}

// Emit get_field: op + name_idx(2) + ic_type(2, cold=0xFFFF) + ic_fidx(1, cold=0xFF).
pub fn emitGetField(name: []const u8, line: u32) !void {
    const idx = try addConst(.{ .string = name });
    try emitByte(@intFromEnum(Op.get_field), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    // Peephole: get_local immediately before get_field → get_local_get_field (8 bytes, 1 dispatch).
    // Layout: [get_local_get_field][slot][get_field(skip)][name_hi][name_lo][ic_hi][ic_lo][ic_fidx]
    if (g_state.last_get_local_code_pos) |gl_pos| {
        if (gl_pos + 8 == g_state.code_len) {
            g_state.code[gl_pos] = @intFromEnum(Op.get_local_get_field);
            g_state.last_get_local_code_pos = null;
            g_state.last_const_code_pos = null;
        }
    }
}

// Emit set_field: op + name_idx(2) + ic_type(2, cold=0xFFFF) + ic_fidx(1, cold=0xFF).
pub fn emitSetField(name: []const u8, line: u32) !void {
    const idx = try addConst(.{ .string = name });
    try emitByte(@intFromEnum(Op.set_field), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
}

// Helpers for invoke_method / defer_invoke_method which interleave a const index
// with a separate argc byte: op + idx_hi + idx_lo + argc + ic_type(2) + ic_func(2).
pub fn emitInvokeMethod(name: []const u8, argc: u8, line: u32) !void {
    const idx = try addConst(.{ .string = name });
    try emitByte(@intFromEnum(Op.invoke_method), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(argc, line);
    try emitByte(0xff, line); // ic_type hi (cold)
    try emitByte(0xff, line); // ic_type lo (cold)
    try emitByte(0xff, line); // ic_func hi (cold)
    try emitByte(0xff, line); // ic_func lo (cold)
}

pub fn emitDeferInvokeMethod(name: []const u8, argc: u8, line: u32) !void {
    const idx = try addConst(.{ .string = name });
    try emitByte(@intFromEnum(Op.defer_invoke_method), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(argc, line);
}

pub fn emitJump(op: Op, line: u32) !usize {
    // Quad fusion: get_local_const_eq immediately preceding jif_pop →
    // get_local_const_eq_jif_pop (9 bytes, saves 1 dispatch per conditional check).
    if (op == .jif_pop) {
        if (g_state.last_triple_eq_pos) |tp| {
            if (tp + 5 == g_state.code_len) {
                g_state.code[tp] = @intFromEnum(Op.get_local_const_eq_jif_pop);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                g_state.last_triple_eq_pos = null;
                return g_state.code_len - 4;
            }
        }
        // Quad fusion: get_local_const_lt immediately preceding jif_pop →
        // get_local_const_lt_jif_pop (9 bytes, saves 1 dispatch per conditional check).
        if (g_state.last_triple_lt_pos) |tp| {
            if (tp + 5 == g_state.code_len) {
                g_state.code[tp] = @intFromEnum(Op.get_local_const_lt_jif_pop);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                g_state.last_triple_lt_pos = null;
                return g_state.code_len - 4;
            }
        }
    }
    try emitOp(op, line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    return g_state.code_len - 4;
}

pub fn patchJump(offset: usize) !void {
    const jump = g_state.code_len - offset - 4;
    if (jump > 0xffffffff) return error.JumpTooLarge;
    g_state.code[offset]     = @intCast((jump >> 24) & 0xff);
    g_state.code[offset + 1] = @intCast((jump >> 16) & 0xff);
    g_state.code[offset + 2] = @intCast((jump >> 8)  & 0xff);
    g_state.code[offset + 3] = @intCast(jump & 0xff);
    // The patched jump lands at the current end of code, so the next emitted
    // instruction must start exactly here. Suppress pending peephole fusion:
    // fusing across this boundary (triple get_local+const or quad +jif_pop)
    // would rewrite the preceding instruction and turn the jump target into
    // operand bytes.
    g_state.last_const_code_pos = null;
    g_state.last_get_local_code_pos = null;
    g_state.last_triple_eq_pos = null;
    g_state.last_triple_lt_pos = null;
    g_state.last_set_global_code_pos = null;
}

pub fn emitLoop(loop_start: usize, line: u32) !void {
    // Peephole: if the last emitted instruction is set_global (5 bytes), fuse it with
    // the back-edge into set_global_loop (same 5 bytes, different opcode + 4-byte offset).
    if (g_state.last_set_global_code_pos) |sg_pos| {
        if (sg_pos + 5 == g_state.code_len) {
            g_state.last_const_code_pos = null;
            g_state.last_get_local_code_pos = null;
            g_state.last_triple_eq_pos = null;
            g_state.last_triple_lt_pos = null;
            g_state.last_set_global_code_pos = null;
            g_state.code[sg_pos] = @intFromEnum(Op.set_global_loop);
            const offset = g_state.code_len - loop_start + 4;
            if (offset > 0xffffffff) return error.LoopTooLarge;
            try emitByte(@intCast((offset >> 24) & 0xff), line);
            try emitByte(@intCast((offset >> 16) & 0xff), line);
            try emitByte(@intCast((offset >> 8)  & 0xff), line);
            try emitByte(@intCast(offset & 0xff), line);
            return;
        }
    }
    g_state.last_const_code_pos = null;
    g_state.last_get_local_code_pos = null;
    g_state.last_triple_eq_pos = null;
    g_state.last_triple_lt_pos = null;
    g_state.last_set_global_code_pos = null;
    try emitOp(.loop, line);
    const offset = g_state.code_len - loop_start + 4;
    if (offset > 0xffffffff) return error.LoopTooLarge;
    try emitByte(@intCast((offset >> 24) & 0xff), line);
    try emitByte(@intCast((offset >> 16) & 0xff), line);
    try emitByte(@intCast((offset >> 8)  & 0xff), line);
    try emitByte(@intCast(offset & 0xff), line);
}

pub fn codeLen() usize {
    return g_state.code_len;
}

pub fn constCount() usize {
    return g_state.const_count;
}

pub fn codeByteAt(i: usize) u8 {
    return g_state.code[i];
}

pub fn lineAt(i: usize) u16 {
    return g_state.lines[i];
}

pub fn colAt(i: usize) u16 {
    return g_state.cols[i];
}

pub fn constAt(i: usize) !Value {
    if (i >= g_state.const_count) return error.BadConstantIndex;
    return g_state.consts[i];
}
