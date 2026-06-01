const Op = @import("op.zig").Op;
const Value = @import("value.zig").Value;
const common = @import("common.zig");

pub const MaxCode = 16384;
// Constant indices are encoded as two bytes (big-endian u16), supporting up to 512 distinct
// values per compilation unit. Previously the limit was 256 (single-byte index).
pub const MaxConst = 512;

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
};

var g_default_state: State = .{};
var g_state: *State = &g_default_state;

pub fn setActive(state: *State) void {
    g_state = state;
}

pub fn reset() void {
    g_state.code_len = 0;
    g_state.const_count = 0;
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
    return emitByte(@intFromEnum(op), line);
}

pub fn emit2(a: u8, b: u8, line: u32) !void {
    if (a == @intFromEnum(Op.get_local)) {
        g_state.last_get_local_code_pos = g_state.code_len;
    }
    try emitByte(a, line);
    try emitByte(b, line);
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
    if (op == .constant) {
        g_state.last_const_code_pos = g_state.code_len;
        g_state.last_const_idx = idx;
    } else {
        g_state.last_const_code_pos = null;
    }
    try emitConstIdx(op, idx, line);
}

// Emit a binary op, fusing with a preceding `constant` instruction when possible.
// If the last emitted instruction was `constant k`, replaces it in-place with
// const_eq/const_sub/const_add/const_lt (same bytecode layout, different opcode byte).
// If the instruction before that was `get_local`, further fuses to
// get_local_const_eq / get_local_const_sub (triple fusion, same 5-byte layout).
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
                            else       => null,
                        };
                        if (triple) |top| {
                            g_state.code[gl_pos] = @intFromEnum(top);
                            // Layout: [top][slot][fop_byte(skip)][idx_hi][idx_lo]
                            // code[gl_pos+1] = slot, code[pos] = fop (skip byte),
                            // code[pos+1..+2] = const_idx — all unchanged.
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
    if (v == .string) {
        var i: usize = 0;
        while (i < g_state.const_count) : (i += 1) {
            if (g_state.consts[i] == .string and common.streq(g_state.consts[i].string, v.string)) {
                return @intCast(i);
            }
        }
    }
    if (g_state.const_count >= MaxConst) return error.TooManyConstants;
    const idx = g_state.const_count;
    g_state.consts[idx] = v;
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
    try emitOp(op, line);
    try emitByte(0xff, line);
    try emitByte(0xff, line);
    return g_state.code_len - 2;
}

pub fn patchJump(offset: usize) !void {
    const jump = g_state.code_len - offset - 2;
    if (jump > 0xffff) return error.JumpTooLarge;
    g_state.code[offset] = @intCast((jump >> 8) & 0xff);
    g_state.code[offset + 1] = @intCast(jump & 0xff);
}

pub fn emitLoop(loop_start: usize, line: u32) !void {
    // Peephole: if the last emitted instruction is set_global (5 bytes), fuse it with
    // the back-edge into set_global_loop (same 5 bytes, different opcode + 2-byte offset).
    if (g_state.code_len >= 5 and
        g_state.code[g_state.code_len - 5] == @intFromEnum(Op.set_global))
    {
        g_state.last_const_code_pos = null; // invalidate const peephole
        g_state.code[g_state.code_len - 5] = @intFromEnum(Op.set_global_loop);
        const offset = g_state.code_len - loop_start + 2;
        if (offset > 0xffff) return error.LoopTooLarge;
        try emitByte(@intCast((offset >> 8) & 0xff), line);
        try emitByte(@intCast(offset & 0xff), line);
        return;
    }
    try emitOp(.loop, line);
    const offset = g_state.code_len - loop_start + 2;
    if (offset > 0xffff) return error.LoopTooLarge;
    try emitByte(@intCast((offset >> 8) & 0xff), line);
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

pub fn constAt(i: usize) Value {
    return g_state.consts[i];
}
