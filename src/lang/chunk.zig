const Op = @import("op.zig").Op;
const Value = @import("value.zig").Value;
const common = @import("common.zig");

pub const MaxCode = 16384;
// Bytecode currently encodes constant indexes as a single byte.
pub const MaxConst = 256;

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

pub fn addConst(v: Value) !u8 {
    // Deduplicate string constants to stay within the 256-slot limit.
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

pub fn emitConst(v: Value, line: u32) !void {
    const idx = try addConst(v);
    try emit2(@intFromEnum(Op.constant), idx, line);
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
