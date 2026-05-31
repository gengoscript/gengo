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
    try emitConstIdx(op, idx, line);
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

// Helpers for invoke_method / defer_invoke_method which interleave a const index
// with a separate argc byte: op + idx_hi + idx_lo + argc.
pub fn emitInvokeMethod(name: []const u8, argc: u8, line: u32) !void {
    const idx = try addConst(.{ .string = name });
    try emitByte(@intFromEnum(Op.invoke_method), line);
    try emitByte(@intCast((idx >> 8) & 0xff), line);
    try emitByte(@intCast(idx & 0xff), line);
    try emitByte(argc, line);
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
