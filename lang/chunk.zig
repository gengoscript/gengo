const Op = @import("op.zig").Op;
const Value = @import("value.zig").Value;
const common = @import("common.zig");

pub const MaxCode = 16384;
// Bytecode currently encodes constant indexes as a single byte.
pub const MaxConst = 256;

pub var g_code: [MaxCode]u8 = undefined;
pub var g_lines: [MaxCode]u16 = undefined;
pub var g_consts: [MaxConst]Value = undefined;
pub var g_code_len: usize = 0;
pub var g_const_count: usize = 0;

pub fn reset() void {
    g_code_len = 0;
    g_const_count = 0;
}

pub fn emitByte(b: u8, line: u32) !void {
    if (g_code_len >= MaxCode) return error.ChunkFull;
    g_code[g_code_len] = b;
    g_lines[g_code_len] = @intCast(if (line > 0xffff) 0xffff else line);
    g_code_len += 1;
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
        while (i < g_const_count) : (i += 1) {
            if (g_consts[i] == .string and common.streq(g_consts[i].string, v.string)) {
                return @intCast(i);
            }
        }
    }
    if (g_const_count >= MaxConst) return error.TooManyConstants;
    const idx = g_const_count;
    g_consts[idx] = v;
    g_const_count += 1;
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
    return g_code_len - 2;
}

pub fn patchJump(offset: usize) !void {
    const jump = g_code_len - offset - 2;
    if (jump > 0xffff) return error.JumpTooLarge;
    g_code[offset] = @intCast((jump >> 8) & 0xff);
    g_code[offset + 1] = @intCast(jump & 0xff);
}

pub fn emitLoop(loop_start: usize, line: u32) !void {
    try emitOp(.loop, line);
    const offset = g_code_len - loop_start + 2;
    if (offset > 0xffff) return error.LoopTooLarge;
    try emitByte(@intCast((offset >> 8) & 0xff), line);
    try emitByte(@intCast(offset & 0xff), line);
}
