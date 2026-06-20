const std = @import("std");
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
    // Peephole: track position of last `get_global` instruction (5 bytes: op + name_idx(2) + ic_slot(2)).
    // Used for triple-fusion: get_global + constant + eq/sub → get_global_const_eq/sub.
    last_get_global_code_pos: ?usize = null,
    // Peephole: position of the last get_global_const_eq triple-fused instruction.
    // Used for quad-fusion: get_global_const_eq + jif_pop → get_global_const_eq_jif_pop.
    last_triple_global_eq_pos: ?usize = null,
    // Peephole: position of the last get_global_const_lt triple-fused instruction.
    // Used for quad-fusion: get_global_const_lt + jif_pop → get_global_const_lt_jif_pop.
    last_triple_global_lt_pos: ?usize = null,
    // Peephole: position of the last set_global instruction.
    // Used for fusion: set_global + loop → set_global_loop.
    last_set_global_code_pos: ?usize = null,
    // Peephole: position of last get_local_const_lt_jif_pop quad-fused instruction (9 bytes).
    // Used for quint-fusion: get_local_const_lt_jif_pop + jump → get_local_const_lt_jif_pop_jump.
    last_quad_lt_jif_pos: ?usize = null,
    // Peephole: position of last close_upvalue instruction (2 bytes: op + slot).
    // Used for fusion: close_upvalue + loop → close_upvalue_loop.
    last_close_upvalue_pos: ?usize = null,
    // Peephole: position of last local_add_const instruction (4 bytes: op + dst + idx_hi + idx_lo).
    // Used for fusion: local_add_const + loop → local_add_const_loop.
    last_local_add_const_pos: ?usize = null,
    // Code-position patch: position before get_global "module:std" (or get_local for a from_std local).
    // Used by the std direct-call peephole to truncate back and emit a single get_global
    // "module:std.{ns}.{func}" instead of std-namespace load + field traversal + call.
    std_call_patch_pos: ?usize = null,
    // Verifier error detail — populated before verify() returns an error.
    verify_err_buf: [256]u8 = undefined,
    verify_err_len: usize = 0,
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
    g_state.last_get_global_code_pos = null;
    g_state.last_triple_global_eq_pos = null;
    g_state.last_triple_global_lt_pos = null;
    g_state.last_set_global_code_pos = null;
    g_state.last_quad_lt_jif_pos = null;
    g_state.last_close_upvalue_pos = null;
    g_state.last_local_add_const_pos = null;
    g_state.std_call_patch_pos = null;
    g_state.verify_err_len = 0;
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
    if (a == @intFromEnum(Op.close_upvalue)) {
        g_state.last_close_upvalue_pos = g_state.code_len - 2;
    } else {
        g_state.last_close_upvalue_pos = null;
    }
    if (a == @intFromEnum(Op.call)) {
        if (g_state.last_get_local_const_sub_pos) |sub_pos| {
            if (sub_pos + 5 == g_state.code_len - 2) {
                g_state.code[sub_pos] = @intFromEnum(Op.get_local_const_sub_call);
                g_state.code[sub_pos + 5] = b; // argc moves to position 5
                g_state.code_len -= 1;
                g_state.last_get_local_const_sub_pos = null;
                // Hexa-fusion: get_global immediately before get_local_const_sub_call
                // → call_global_local_sub_const (11 bytes, 1 dispatch).
                if (g_state.last_get_global_code_pos) |gg_pos| {
                    if (gg_pos + 5 == sub_pos) {
                        g_state.code[gg_pos] = @intFromEnum(Op.call_global_local_sub_const);
                        g_state.last_get_global_code_pos = null;
                    }
                }
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
                g_state.last_local_add_const_pos = pos;
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
                // Triple fusion: get_global (5 bytes) immediately before constant (3 bytes).
                // get_global + const_eq/sub/add/lt → get_global_const_eq/sub/add/lt (8 bytes, 1 dispatch).
                if (g_state.last_get_global_code_pos) |gg_pos| {
                    if (gg_pos + 5 == pos) {
                        const triple: ?Op = switch (fop) {
                            .const_eq  => .get_global_const_eq,
                            .const_sub => .get_global_const_sub,
                            .const_add => .get_global_const_add,
                            .const_lt  => .get_global_const_lt,
                            else       => null,
                        };
                        if (triple) |top| {
                            g_state.code[gg_pos] = @intFromEnum(top);
                            // Layout: [top][glob_hi][glob_lo][ic_hi][ic_lo][fop_byte(skip)][val_hi][val_lo]
                            // All bytes already in place — just change the opcode.
                            if (top == .get_global_const_eq) {
                                g_state.last_triple_global_eq_pos = gg_pos;
                            } else if (top == .get_global_const_lt) {
                                g_state.last_triple_global_lt_pos = gg_pos;
                            }
                            g_state.last_get_global_code_pos = null;
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
        for (g_state.consts[0..g_state.const_count], 0..) |c, i| {
            if (c == .string and common.streq(c.string, v.string)) return @intCast(i);
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
    g_state.last_get_global_code_pos = g_state.code_len - 5;
}

// Emit get_global when constant index is already known.
pub fn emitGetGlobalIdx(idx: u16, line: u32) !void {
    try emitByte(@intFromEnum(Op.get_global), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    g_state.last_get_global_code_pos = g_state.code_len - 5;
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
    // Quint fusion: get_local_const_lt_jif_pop immediately preceding jump →
    // get_local_const_lt_jif_pop_jump (13 bytes): reads exit_off then body_off; dispatches
    // to body (ip += body_off) when condition true, exits loop (ip_mid += exit_off) when false.
    // This saves the per-iteration `jump` that C-style for-loops emit after the condition.
    if (op == .jump) {
        if (g_state.last_quad_lt_jif_pos) |tp| {
            if (tp + 9 == g_state.code_len) {
                g_state.code[tp] = @intFromEnum(Op.get_local_const_lt_jif_pop_jump);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                g_state.last_quad_lt_jif_pos = null;
                return g_state.code_len - 4;
            }
        }
    }
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
                const result = g_state.code_len - 4;
                g_state.last_quad_lt_jif_pos = tp; // track for quint-fusion
                return result;
            }
        }
        // Quad fusion: get_global_const_eq immediately preceding jif_pop →
        // get_global_const_eq_jif_pop (12 bytes, saves 1 dispatch per conditional check).
        if (g_state.last_triple_global_eq_pos) |tp| {
            if (tp + 8 == g_state.code_len) {
                g_state.code[tp] = @intFromEnum(Op.get_global_const_eq_jif_pop);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                g_state.last_triple_global_eq_pos = null;
                return g_state.code_len - 4;
            }
        }
        // Quad fusion: get_global_const_lt immediately preceding jif_pop →
        // get_global_const_lt_jif_pop (12 bytes, saves 1 dispatch per conditional check).
        if (g_state.last_triple_global_lt_pos) |tp| {
            if (tp + 8 == g_state.code_len) {
                g_state.code[tp] = @intFromEnum(Op.get_global_const_lt_jif_pop);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                try emitByte(0xff, line);
                g_state.last_triple_global_lt_pos = null;
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
    g_state.last_get_global_code_pos = null;
    g_state.last_triple_global_eq_pos = null;
    g_state.last_triple_global_lt_pos = null;
    g_state.last_set_global_code_pos = null;
    g_state.last_quad_lt_jif_pos = null;
    g_state.last_close_upvalue_pos = null;
    g_state.last_local_add_const_pos = null;
}

pub fn emitLoop(loop_start: usize, line: u32) !void {
    // Peephole: close_upvalue (2 bytes) immediately preceding loop → close_upvalue_loop (6 bytes).
    // Saves 1 dispatch per C-style for-loop iteration (common pattern at end of loop body).
    if (g_state.last_close_upvalue_pos) |cu_pos| {
        if (cu_pos + 2 == g_state.code_len) {
            g_state.last_const_code_pos = null;
            g_state.last_get_local_code_pos = null;
            g_state.last_triple_eq_pos = null;
            g_state.last_triple_lt_pos = null;
            g_state.last_set_global_code_pos = null;
            g_state.last_quad_lt_jif_pos = null;
            g_state.last_close_upvalue_pos = null;
            g_state.last_local_add_const_pos = null;
            g_state.code[cu_pos] = @intFromEnum(Op.close_upvalue_loop);
            const offset = g_state.code_len - loop_start + 4;
            if (offset > 0xffffffff) return error.LoopTooLarge;
            try emitByte(@intCast((offset >> 24) & 0xff), line);
            try emitByte(@intCast((offset >> 16) & 0xff), line);
            try emitByte(@intCast((offset >> 8)  & 0xff), line);
            try emitByte(@intCast(offset & 0xff), line);
            return;
        }
    }
    // Peephole: local_add_const (4 bytes) immediately preceding loop → local_add_const_loop (8 bytes).
    // Saves 1 dispatch per C-style for-loop iteration (i++ post-increment in common loop pattern).
    if (g_state.last_local_add_const_pos) |lac_pos| {
        if (lac_pos + 4 == g_state.code_len) {
            g_state.last_const_code_pos = null;
            g_state.last_get_local_code_pos = null;
            g_state.last_triple_eq_pos = null;
            g_state.last_triple_lt_pos = null;
            g_state.last_set_global_code_pos = null;
            g_state.last_quad_lt_jif_pos = null;
            g_state.last_close_upvalue_pos = null;
            g_state.last_local_add_const_pos = null;
            g_state.code[lac_pos] = @intFromEnum(Op.local_add_const_loop);
            const offset = g_state.code_len - loop_start + 4;
            if (offset > 0xffffffff) return error.LoopTooLarge;
            try emitByte(@intCast((offset >> 24) & 0xff), line);
            try emitByte(@intCast((offset >> 16) & 0xff), line);
            try emitByte(@intCast((offset >> 8)  & 0xff), line);
            try emitByte(@intCast(offset & 0xff), line);
            return;
        }
    }
    // Peephole: if the last emitted instruction is set_global (5 bytes), fuse it with
    // the back-edge into set_global_loop (same 5 bytes, different opcode + 4-byte offset).
    if (g_state.last_set_global_code_pos) |sg_pos| {
        if (sg_pos + 5 == g_state.code_len) {
            g_state.last_const_code_pos = null;
            g_state.last_get_local_code_pos = null;
            g_state.last_triple_eq_pos = null;
            g_state.last_triple_lt_pos = null;
            g_state.last_set_global_code_pos = null;
            g_state.last_quad_lt_jif_pos = null;
            g_state.last_close_upvalue_pos = null;
            g_state.last_local_add_const_pos = null;
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
    g_state.last_quad_lt_jif_pos = null;
    g_state.last_close_upvalue_pos = null;
    g_state.last_local_add_const_pos = null;
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

pub fn markStdCallPatchPos() void {
    g_state.std_call_patch_pos = g_state.code_len;
}

pub fn stdCallPatchPos() ?usize {
    return g_state.std_call_patch_pos;
}

pub fn clearStdCallPatchPos() void {
    g_state.std_call_patch_pos = null;
}

pub fn truncateTo(pos: usize) void {
    g_state.code_len = pos;
    // Clear all position-based peephole trackers whose stored positions now lie
    // in the truncated region. Every fusion guards with position arithmetic
    // (gl_pos + N == code_len), so stale values can't fire incorrectly today,
    // but raw-byte inspections (local_add_local) are not position-guarded and
    // would silently corrupt bytecode if a future peephole forgot to add the guard.
    g_state.last_get_local_code_pos = null;
    g_state.last_const_code_pos = null;
    g_state.last_set_global_code_pos = null;
    g_state.last_triple_eq_pos = null;
    g_state.last_triple_lt_pos = null;
    g_state.last_get_local_const_sub_pos = null;
    g_state.last_get_local_const_add_pos = null;
    g_state.last_quad_lt_jif_pos = null;
    g_state.last_close_upvalue_pos = null;
}

pub fn constAt(i: usize) !Value {
    if (i >= g_state.const_count) return error.BadConstantIndex;
    return g_state.consts[i];
}

pub const DecodedInstruction = struct {
    op: Op,
    width: usize,
    const_index: ?usize = null,
    jump_target: ?usize = null,
};

fn readU16At(pos: usize) !u16 {
    if (pos + 1 >= g_state.code_len) return error.BytecodeOutOfBounds;
    return (@as(u16, g_state.code[pos]) << 8) | @as(u16, g_state.code[pos + 1]);
}

fn readU32At(pos: usize) !u32 {
    if (pos + 3 >= g_state.code_len) return error.BytecodeOutOfBounds;
    return (@as(u32, g_state.code[pos]) << 24) |
        (@as(u32, g_state.code[pos + 1]) << 16) |
        (@as(u32, g_state.code[pos + 2]) << 8) |
        @as(u32, g_state.code[pos + 3]);
}

pub fn decodeAt(pos: usize) !DecodedInstruction {
    if (pos >= g_state.code_len) return error.BytecodeOutOfBounds;

    const raw = g_state.code[pos];
    const max_op = @intFromEnum(Op.halt);
    if (raw > max_op) return error.BadOpcode;
    const op: Op = @enumFromInt(raw);

    return switch (op) {
        .constant, .def_global, .make_closure, .ret_const,
        .const_eq, .const_sub, .const_add, .const_lt,
        .assert_interface, .assert_struct, .variant_check => .{
            .op = op,
            .width = 3,
            .const_index = try readU16At(pos + 1),
        },

        .jump, .jump_if_false, .jif_pop => blk: {
            const off = try readU32At(pos + 1);
            break :blk .{
                .op = op,
                .width = 5,
                .jump_target = pos + 5 + @as(usize, off),
            };
        },

        .loop => blk: {
            const off = try readU32At(pos + 1);
            const width: usize = 5;
            if (@as(usize, off) > pos + width) return error.BadJumpTarget;
            break :blk .{
                .op = op,
                .width = width,
                .jump_target = pos + width - @as(usize, off),
            };
        },

        .get_local, .set_local, .get_upvalue, .set_upvalue, .close_upvalue,
        .get_local_ret, .call, .defer_call,
        .build_array, .build_map, .build_tuple, .build_struct_instance,
        .tuple_check_arity, .tuple_get, .tuple_get_keep,
        .get_slice, .assert_type => .{
            .op = op,
            .width = 2,
        },

        .get_global, .set_global => .{
            .op = op,
            .width = 5,
            .const_index = try readU16At(pos + 1),
        },

        .get_field, .set_field => .{
            .op = op,
            .width = 6,
            .const_index = try readU16At(pos + 1),
        },

        .invoke_method, .defer_invoke_method => .{
            .op = op,
            .width = if (op == .invoke_method) 8 else 4,
            .const_index = try readU16At(pos + 1),
        },

        .get_local_const_eq, .get_local_const_sub,
        .get_local_const_add, .get_local_const_lt => .{
            .op = op,
            .width = 5,
            .const_index = try readU16At(pos + 3),
        },

        .get_local_const_sub_call => .{
            .op = op,
            .width = 6,
            .const_index = try readU16At(pos + 3),
        },

        .call_global_local_sub_const => .{
            .op = op,
            .width = 11,
            .const_index = try readU16At(pos + 8),
        },

        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop => blk: {
            const off = try readU32At(pos + 5);
            break :blk .{
                .op = op,
                .width = 9,
                .const_index = try readU16At(pos + 3),
                .jump_target = pos + 9 + @as(usize, off),
            };
        },

        .get_local_const_lt_jif_pop_jump => blk: {
            const exit_off = try readU32At(pos + 5);
            const body_off = try readU32At(pos + 9);
            _ = body_off;
            break :blk .{
                .op = op,
                .width = 13,
                .const_index = try readU16At(pos + 3),
                .jump_target = pos + 9 + @as(usize, exit_off), // exit target
            };
        },

        .get_global_const_eq, .get_global_const_sub,
        .get_global_const_add, .get_global_const_lt => .{
            .op = op,
            .width = 8,
            .const_index = try readU16At(pos + 6),
        },

        .get_global_const_eq_jif_pop, .get_global_const_lt_jif_pop => blk: {
            const off = try readU32At(pos + 8);
            break :blk .{
                .op = op,
                .width = 12,
                .const_index = try readU16At(pos + 6),
                .jump_target = pos + 12 + @as(usize, off),
            };
        },

        .get_local_get_field => .{
            .op = op,
            .width = 8,
            .const_index = try readU16At(pos + 3),
        },

        .set_global_loop => blk: {
            const off = try readU32At(pos + 5);
            const width: usize = 9;
            if (@as(usize, off) > pos + width) return error.BadJumpTarget;
            break :blk .{
                .op = op,
                .width = width,
                .const_index = try readU16At(pos + 1),
                .jump_target = pos + width - @as(usize, off),
            };
        },

        .close_upvalue_loop => blk: {
            const off = try readU32At(pos + 2);
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
            .const_index = try readU16At(pos + 2),
        },

        .local_add_const_loop => blk: {
            const off = try readU32At(pos + 4);
            const width: usize = 8;
            if (@as(usize, off) > pos + width) return error.BadJumpTarget;
            break :blk .{
                .op = op,
                .width = width,
                .const_index = try readU16At(pos + 2),
                .jump_target = pos + width - @as(usize, off),
            };
        },

        else => .{
            .op = op,
            .width = 1,
        },
    };
}

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
        .jump_if_false, .jif_pop,
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop,
        .get_global_const_eq_jif_pop, .get_global_const_lt_jif_pop,
        .get_local_const_lt_jif_pop_jump => true,
        else => false,
    };
}

fn stackEffect(op: Op, ip: usize) struct { pop: u8, push: u8 } {
    return switch (op) {
        // Push 1
        .constant, .null_val, .true_val, .false_val,
        .get_local, .get_upvalue, .get_global, .get_field,
        .make_closure, .tuple_get_keep,
        .get_local_const_eq, .get_local_const_sub,
        .get_local_const_add, .get_local_const_lt,
        .get_global_const_eq, .get_global_const_sub,
        .get_global_const_add, .get_global_const_lt,
        .get_local_get_field => .{ .pop = 0, .push = 1 },

        // Pop 1
        .pop, .def_global, .set_global, .set_local, .set_upvalue,
        .set_field, .jif_pop, .op_assert, .repl_print,
        .set_named_predicate => .{ .pop = 1, .push = 0 },

        // Pop 2, push 1 (binary operators)
        .add, .sub, .mul, .div, .mod, .pow,
        .bit_and, .bit_or, .bit_xor, .shl, .shr,
        .eq, .gt, .lt => .{ .pop = 2, .push = 1 },

        // Pop 1, push 1 (unary / type ops)
        .neg, .not, .bit_not,
        .cast_int, .cast_float, .cast_decimal, .cast_bool, .cast_string, .cast_rune,
        .type_name, .variant_check, .variant_payload,
        .const_eq, .const_sub, .const_add, .const_lt,
        .assert_type, .assert_interface, .assert_struct,
        .tuple_get => .{ .pop = 1, .push = 1 },

        // Pop 3, push 0
        .set_index => .{ .pop = 3, .push = 0 },

        // Pop 2, push 1
        .get_index => .{ .pop = 2, .push = 1 },

        // Variable pop counts — read operand byte
        .call => blk: {
            const argc = g_state.code[ip + 1];
            break :blk .{ .pop = argc + 1, .push = 1 };
        },
        .defer_call => blk: {
            const argc = g_state.code[ip + 1];
            break :blk .{ .pop = argc + 1, .push = 0 };
        },
        .invoke_method => blk: {
            const argc = g_state.code[ip + 3];
            break :blk .{ .pop = argc + 1, .push = 1 };
        },
        .defer_invoke_method => blk: {
            const argc = g_state.code[ip + 3];
            break :blk .{ .pop = argc + 1, .push = 0 };
        },
        .build_array => blk: {
            const n = g_state.code[ip + 1];
            break :blk .{ .pop = n, .push = 1 };
        },
        .build_tuple => blk: {
            const n = g_state.code[ip + 1];
            break :blk .{ .pop = n, .push = 1 };
        },
        .build_map => blk: {
            const n = g_state.code[ip + 1];
            break :blk .{ .pop = n * 2, .push = 1 };
        },
        .build_struct_instance => blk: {
            const field_count = g_state.code[ip + 1];
            break :blk .{ .pop = 1 + field_count * 2, .push = 1 };
        },
        .get_slice => blk: {
            const extra: u8 = @popCount(g_state.code[ip + 1]);
            break :blk .{ .pop = 1 + extra, .push = 1 };
        },

        // Iteration — iter_next1 peeks iterator and pushes value+flag (+2),
        // iter_next2 peeks iterator and pushes key+value+flag (+3).
        // The "done" case pushes only flag (+1), but modeling the max case
        // avoids depth underestimation in the loop body (which fires on the
        // "more" path). Exit-path overestimation is harmless because loops
        // have a single successor at the target.
        .iter_init => .{ .pop = 1, .push = 1 },
        .iter_next1 => .{ .pop = 0, .push = 2 },
        .iter_next2 => .{ .pop = 0, .push = 3 },

        // Duplication
        .dup => .{ .pop = 0, .push = 1 },
        .dup2 => .{ .pop = 0, .push = 2 },

        // Special / no stack effect
        .close_upvalue, .tuple_check_arity, .validate_type_default => .{ .pop = 0, .push = 0 },
        .get_local_const_sub_call => blk: {
            const argc = g_state.code[ip + 5];
            break :blk .{ .pop = argc, .push = 1 };
        },
        .call_global_local_sub_const => blk: {
            // Equivalent to get_global (pop=0,push=1) + get_local_const_sub_call (pop=argc,push=1).
            // Combined net: push=2, pop=argc. For argc=1: net height +1.
            const argc = g_state.code[ip + 10];
            _ = argc;
            break :blk .{ .pop = 0, .push = 1 };
        },
        .local_add_local => .{ .pop = 0, .push = 0 },
        .local_add_const => .{ .pop = 0, .push = 0 },
        .local_add_const_loop => .{ .pop = 0, .push = 0 },
        .op_assert_msg => .{ .pop = 2, .push = 0 },
        .op_trap_check => .{ .pop = 1, .push = 0 },

        // Return instructions (handled specially by control-flow logic)
        .ret => .{ .pop = 1, .push = 0 },
        .ret_const, .get_local_ret => .{ .pop = 0, .push = 0 },
        .add_ret => .{ .pop = 2, .push = 0 },

        // Branch instructions (pop already accounted for)
        .jump, .loop, .set_global_loop, .close_upvalue_loop, .jump_if_false => .{ .pop = 0, .push = 0 },
        .get_local_const_eq_jif_pop, .get_local_const_lt_jif_pop,
        .get_local_const_lt_jif_pop_jump,
        .get_global_const_eq_jif_pop, .get_global_const_lt_jif_pop => .{ .pop = 0, .push = 0 },

        .halt => .{ .pop = 0, .push = 0 },
    };
}

fn verifySetErr(comptime fmt: []const u8, args: anytype) void {
    g_state.verify_err_len = (std.fmt.bufPrint(&g_state.verify_err_buf, fmt, args) catch unreachable).len;
}

pub fn verify() !void {
    if (g_state.code_len == 0) return;

    const bit_len = (g_state.code_len + 7) / 8;
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

    // Pass 1: mark instruction starts, validate const indices, fused skip bytes.
    {
        var ip: usize = 0;
        while (ip < g_state.code_len) {
            Bits.set(starts, ip);
            const inst = decodeAt(ip) catch |err| {
                verifySetErr("ip={d}: {s}", .{ip, @errorName(err)});
                return err;
            };
            if (inst.const_index) |idx| {
                if (idx >= g_state.const_count) {
                    verifySetErr("ip={d} ({s}): constant index {d} >= {d}", .{ip, @tagName(inst.op), idx, g_state.const_count});
                    return error.BadConstantIndex;
                }
            }
            // Fused opcode skip-byte validation: the byte that was the original
            // inner opcode must match the expected value.
            switch (inst.op) {
                .get_local_const_eq => if (g_state.code[ip + 2] != @intFromEnum(Op.const_eq)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_eq, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_sub => if (g_state.code[ip + 2] != @intFromEnum(Op.const_sub)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_sub, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_add => if (g_state.code[ip + 2] != @intFromEnum(Op.const_add)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_add, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_lt => if (g_state.code[ip + 2] != @intFromEnum(Op.const_lt)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_lt, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_global_const_eq => if (g_state.code[ip + 5] != @intFromEnum(Op.const_eq)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_eq, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_global_const_sub => if (g_state.code[ip + 5] != @intFromEnum(Op.const_sub)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_sub, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_global_const_add => if (g_state.code[ip + 5] != @intFromEnum(Op.const_add)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_add, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_global_const_lt => if (g_state.code[ip + 5] != @intFromEnum(Op.const_lt)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_lt, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_local_const_eq_jif_pop => if (g_state.code[ip + 2] != @intFromEnum(Op.const_eq)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_eq, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_const_lt_jif_pop,
                .get_local_const_lt_jif_pop_jump => if (g_state.code[ip + 2] != @intFromEnum(Op.const_lt)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_lt, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_global_const_eq_jif_pop => if (g_state.code[ip + 5] != @intFromEnum(Op.const_eq)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_eq, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_global_const_lt_jif_pop => if (g_state.code[ip + 5] != @intFromEnum(Op.const_lt)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_lt, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 5]});
                    return error.BadOpcode;
                },
                .get_local_const_sub_call => if (g_state.code[ip + 2] != @intFromEnum(Op.const_sub)) {
                    verifySetErr("ip={d} ({s}): expected embedded const_sub, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 2]});
                    return error.BadOpcode;
                },
                .get_local_get_field => if (g_state.code[ip + 2] != @intFromEnum(Op.get_field)) {
                    verifySetErr("ip={d} ({s}): expected embedded get_field, got {d}", .{ip, @tagName(inst.op), g_state.code[ip + 2]});
                    return error.BadOpcode;
                },
                else => {},
            }
            ip += inst.width;
        }
    }

    // Pass 2: validate jump targets land on instruction starts.
    {
        var ip: usize = 0;
        while (ip < g_state.code_len) {
            const inst = decodeAt(ip) catch |err| {
                verifySetErr("ip={d}: {s}", .{ip, @errorName(err)});
                return err;
            };
            if (inst.jump_target) |target| {
                if (target >= g_state.code_len or !Bits.has(starts, target)) {
                    verifySetErr("ip={d} ({s}): jump target {d} lands inside operand bytes", .{ip, @tagName(inst.op), target});
                    return error.BadJumpTarget;
                }
            }
            ip += inst.width;
        }
    }

    // Pass 3: stack depth analysis via worklist-based BFS.
    // Also verifies that ret/ret_const/get_local_ret/add_ret are never
    // reachable from the top-level entry point (ip=0).
    {
        // Collect function body entry points from the constant pool.
        var func_body_count: usize = 0;
        var func_ips: [256]usize = undefined;
        {
            for (g_state.consts[0..g_state.const_count]) |cv| {
                if (cv == .object) {
                    switch (cv.object.*) {
                        .function => |f| {
                            if (f.ip < g_state.code_len and Bits.has(starts, f.ip)) {
                                func_ips[func_body_count] = f.ip;
                                func_body_count += 1;
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        const BfsRunner = struct {
            fn run(entry_ip: usize, check_ret: bool, starts_arg: []u8) !void {
                var depth = try std.heap.page_allocator.alloc(?i32, g_state.code_len);
                defer std.heap.page_allocator.free(depth);
                @memset(depth, null);

                const WorkItem = struct { ip: usize, depth: i32 };
                var work = try std.ArrayListUnmanaged(WorkItem).initCapacity(std.heap.page_allocator, g_state.code_len);
                defer work.deinit(std.heap.page_allocator);
                try work.append(std.heap.page_allocator, .{ .ip = entry_ip, .depth = 0 });

                var head: usize = 0;
                while (head < work.items.len) {
                    const current_ip = work.items[head].ip;
                    const current_depth = work.items[head].depth;
                    head += 1;

                    if (current_ip >= g_state.code_len) continue;
                    if (!Bits.has(starts_arg, current_ip)) continue;

                    // Different paths can legitimately arrive with different
                    // depths (e.g., for_in break path vs natural exit path).
                    // The first-visited depth is used for downstream checks.
                    if (depth[current_ip]) |_| continue;
                    depth[current_ip] = current_depth;

                    const inst = decodeAt(current_ip) catch |err| {
                        verifySetErr("ip={d}: {s}", .{current_ip, @errorName(err)});
                        return err;
                    };
                    const effect = stackEffect(inst.op, current_ip);
                    const is_branch = isConditionalBranch(inst.op);
                    const is_uncond = isUnconditionalBranch(inst.op);
                    const is_ret = isReturnOp(inst.op);

                    if (is_ret and check_ret) {
                        verifySetErr("ip={d} ({s}): return at top level", .{current_ip, @tagName(inst.op)});
                        return error.ReturnAtTopLevel;
                    }

                    if (current_depth < effect.pop) {
                        verifySetErr("ip={d} ({s}): stack depth {d} < {d}", .{current_ip, @tagName(inst.op), current_depth, effect.pop});
                        return error.StackUnderflow;
                    }

                    const new_depth = current_depth - @as(i32, effect.pop) + @as(i32, effect.push);
                    if (new_depth < 0) {
                        verifySetErr("ip={d} ({s}): stack underflow (new depth {d})", .{current_ip, @tagName(inst.op), new_depth});
                        return error.StackUnderflow;
                    }

                    if (!is_ret and !is_uncond) {
                        const next_ip = current_ip + inst.width;
                        if (next_ip < g_state.code_len) {
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

        try BfsRunner.run(0, true, starts);
        for (func_ips[0..func_body_count]) |fip| {
            try BfsRunner.run(fip, false, starts);
        }
    }
}
