const std = @import("std");
const Op = @import("op.zig").Op;
const val_mod = @import("value.zig");
const Value = val_mod.Value;
const StringSlice = val_mod.StringSlice;
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const chunk_decoder = @import("chunk_decoder.zig");
const chunk_verifier = @import("chunk_verifier.zig");

// Jump offsets are 32-bit (4 bytes, big-endian u32). MaxCode can therefore be very large;
// 1 MiB is a practical ceiling that covers any realistic script.
pub const MaxCode = 1048576;
// Tail padding past MaxCode, covering the widest instruction (13 bytes). The VM
// reads operand bytes without bounds checks after a bounds-checked opcode fetch;
// the padding guarantees those reads stay inside the array even if ip were ever
// to land on the last byte of code.
pub const CodePad = 16;
// Constant indices are two-byte (big-endian u16); 4096 is a practical ceiling well below
// the u16 maximum while fitting comfortably in the GC heap.
pub const MaxConst = 4096;
// StringSlice pool: holds the (bytes) payloads for Value.string / Value.error_value.
// Sized at MaxConst*4 to cover both constant-pool strings and runtime-created strings
// (type-name lookups, string-iterator steps, slice results, etc.) within one script run.
pub const MaxStrSlices = MaxConst * 4;
// Module boundary table — maps bytecode ranges to the source path they came from.
// Mirrors MaxModules in module_compile.zig; enough for any realistic import graph.
pub const MaxModuleBoundaries = 64;
pub const MaxModuleSourcePath = 256;

pub const ModuleBoundary = struct {
    ip_start: u32 = 0,
    path_len: u8 = 0,
    path: [MaxModuleSourcePath]u8 = undefined,
};

pub const State = struct {
    code: [MaxCode + CodePad]u8 = undefined,
    lines: [MaxCode]u16 = undefined,
    cols: [MaxCode]u16 = undefined,
    consts: [MaxConst]Value = undefined,
    str_slices: [MaxStrSlices]StringSlice = undefined,
    code_len: usize = 0,
    const_count: usize = 0,
    // Indices of constants that hold heap objects (function prototypes, type
    // objects). The GC root-scans only these instead of walking the whole
    // constant pool every collection (#187). Constant-folding rollbacks only
    // ever retract scalar/string constants, so entries here never go stale in
    // practice; the GC still guards with `idx < const_count` so a rollback
    // could at worst re-mark a harmless slot, never miss a live object.
    obj_const_idxs: [MaxConst]u16 = undefined,
    obj_const_count: usize = 0,
    str_slice_count: usize = 0,
    pending_col: u16 = 0,
    // Peephole: track position of last `constant` instruction for const-op fusion and folding.
    last_const_code_pos: ?usize = null,
    last_const_idx: u16 = 0,
    // Peephole: position of the constant emitted immediately before last_const. Set only
    // when two constants were emitted with nothing in between; used for constant folding.
    prev_const_code_pos: ?usize = null,
    prev_const_idx: u16 = 0,
    // Whether the last/prev constant was newly added (not deduplicated). Used by the
    // string-literal fold to correctly restore const_count.
    last_const_was_new: bool = false,
    prev_const_was_new: bool = false,
    // Code-position patch: position before get_global "module:std" (or get_local for a from_std local).
    // Used by the std direct-call peephole to truncate back and emit a single get_global
    // "module:std.{ns}.{func}" instead of std-namespace load + field traversal + call.
    std_call_patch_pos: ?usize = null,
    // Verifier error detail — populated before verify() returns an error.
    verify_err_buf: [256]u8 = undefined,
    verify_err_len: usize = 0,
    // Set after the first successful verify(); subsequent run() entries skip re-verification.
    // Cleared by reset() so a re-compiled chunk is re-verified.
    verified: bool = false,
    // Verifier-proved max operand-stack depth of top-level code (relative to
    // the stack position where execution starts). Function bodies carry their
    // own bound in FuncObj.max_stack.
    main_max_stack: u32 = 0,
    // Code length at the time of the last successful verify(). If code is appended
    // afterwards (REPL lines, module compiles) or replaced (defuse), the length no
    // longer matches and verify() re-runs. The VM's unchecked operand fetch relies
    // on this: only verified bytecode ever executes.
    verified_code_len: usize = 0,

    // Module boundary table: records (ip_start, path) pairs in emission order so that
    // pathAt(ip) can walk backwards and return the source file for any bytecode position.
    module_boundaries: [MaxModuleBoundaries]ModuleBoundary = undefined,
    module_boundary_count: u8 = 0,

    // ── State methods (used by the compiler via an explicit *State pointer) ────────

    pub fn setCol(self: *State, col: u32) void {
        self.pending_col = @intCast(@min(col, 0xffff));
    }

    pub fn emitByte(self: *State, b: u8, line: u32) !void {
        if (self.code_len >= MaxCode) return error.ChunkFull;
        self.code[self.code_len] = b;
        self.lines[self.code_len] = @intCast(if (line > 0xffff) 0xffff else line);
        self.cols[self.code_len] = self.pending_col;
        self.code_len += 1;
    }

    pub fn emitOp(self: *State, op: Op, line: u32) !void {
        // Constant folding for ops that bypass emitBinOpFused (mul, div, int_div, rem, mod).
        switch (op) {
            .mul, .div, .int_div, .rem, .mod => {
                if (self.last_const_code_pos) |rhs_pos| {
                    if (rhs_pos + 3 == self.code_len) {
                        if (self.prev_const_code_pos) |lhs_pos| {
                            if (lhs_pos + 3 == rhs_pos) {
                                const lhs = self.consts[self.prev_const_idx];
                                const rhs = self.consts[self.last_const_idx];
                                if (foldBinOp(op, lhs, rhs)) |result| {
                                    self.code_len = lhs_pos;
                                    self.const_count -= 2;
                                    self.last_const_code_pos = null;
                                    self.prev_const_code_pos = null;
                                    try self.emitConst(result, line);
                                    return;
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
        // Peephole: neg immediately after constant → negate the constant in place.
        if (op == .neg) {
            if (self.last_const_code_pos) |pos| {
                if (pos + 3 == self.code_len) {
                    const v = self.consts[self.last_const_idx];
                    if (v == .int and v.int != std.math.minInt(i64)) {
                        self.consts[self.last_const_idx] = .{ .int = -v.int };
                        return;
                    }
                    if (v == .float) {
                        self.consts[self.last_const_idx] = .{ .float = -v.float };
                        return;
                    }
                }
            }
        }
        return self.emitByte(@intFromEnum(op), line);
    }

    // Emit a call instruction: [call][argc][ic_hi][ic_lo] (4 bytes, cold IC = 0xFFFF).
    // Fusion into get_local_const_sub_call / call_global_local_sub_const / the
    // tail-call variants happens in the load-time fusion pass, not here.
    pub fn emitCall(self: *State, argc: u8, line: u32) !void {
        try self.emitByte(@intFromEnum(Op.call), line);
        try self.emitByte(argc, line);
        try self.emitByte(0xFF, line); // IC slot hi (cold)
        try self.emitByte(0xFF, line); // IC slot lo (cold)
    }

    // Emit a spread-return call: [call_spread][argc][spread_n][ic_hi][ic_lo].
    // The verifier knows this call pushes spread_n values; the ret handler performs
    // the actual spreading by reading named-return slots directly.
    pub fn emitCallSpread(self: *State, argc: u8, spread_n: u8, line: u32) !void {
        try self.emitByte(@intFromEnum(Op.call_spread), line);
        try self.emitByte(argc, line);
        try self.emitByte(spread_n, line);
        try self.emitByte(0xFF, line); // IC slot hi (cold)
        try self.emitByte(0xFF, line); // IC slot lo (cold)
    }

    pub fn emit2(self: *State, a: u8, b: u8, line: u32) !void {
        try self.emitByte(a, line);
        try self.emitByte(b, line);
    }

    // Emit opcode + 2-byte constant index (big-endian).
    pub fn emitConstIdx(self: *State, op: Op, idx: u16, line: u32) !void {
        try self.emitByte(@intFromEnum(op), line);
        try self.emitByte(@intCast((idx >> 8) & 0xff), line);
        try self.emitByte(@intCast(idx & 0xff), line);
    }

    // Add constant v and emit opcode + its 2-byte index.
    pub fn emitOpConst(self: *State, op: Op, v: Value, line: u32) !void {
        const pre_count = self.const_count;
        const idx = try self.addConst(v);
        try self.emitConstIdx(op, idx, line);
        if (op == .constant) {
            self.prev_const_code_pos = self.last_const_code_pos;
            self.prev_const_idx = self.last_const_idx;
            self.prev_const_was_new = self.last_const_was_new;
            self.last_const_code_pos = self.code_len - 3;
            self.last_const_idx = idx;
            self.last_const_was_new = (idx == pre_count); // addConst never deduplicates
        } else {
            self.last_const_code_pos = null;
            self.prev_const_code_pos = null;
        }
    }

    // Emit a binary op, fusing with a preceding `constant` instruction when possible.
    pub fn emitBinOpFused(self: *State, op: Op, line: u32) !void {
        if (self.last_const_code_pos) |rhs_pos| {
            if (rhs_pos + 3 == self.code_len) {
                // Constant folding: both operands are adjacent literal constants.
                if (self.prev_const_code_pos) |lhs_pos| {
                    if (lhs_pos + 3 == rhs_pos) {
                        const lhs = self.consts[self.prev_const_idx];
                        const rhs = self.consts[self.last_const_idx];
                        if (foldBinOp(op, lhs, rhs)) |result| {
                            self.code_len = lhs_pos;
                            self.const_count -= 2;
                            self.last_const_code_pos = null;
                            self.prev_const_code_pos = null;
                            try self.emitConst(result, line);
                            return;
                        }
                        // String literal concatenation: "a" + "b" → "ab" at compile time.
                        // Successive folds reduce "a"+"b"+"c"+... to a single constant.
                        if (op == .add and lhs == .string and rhs == .string) {
                            const a = lhs.string.bytes;
                            const b = rhs.string.bytes;
                            const total = a.len + b.len;
                            if (total >= a.len) { // no overflow
                                if (heap.bump(u8, total)) |buf| {
                                    @memcpy(buf[0..a.len], a);
                                    @memcpy(buf[a.len..total], b);
                                    self.code_len = lhs_pos;
                                    // Only reclaim pool slots that were freshly added (not deduped).
                                    // const_count -= 2 is wrong when either constant was a dedup hit,
                                    // because the deduped index may still be referenced by earlier code.
                                    var restore = self.const_count;
                                    if (self.last_const_was_new) restore -= 1;
                                    if (self.prev_const_was_new) restore -= 1;
                                    self.const_count = restore;
                                    self.last_const_code_pos = null;
                                    self.prev_const_code_pos = null;
                                    // Dedup: reuse existing equal constant if present.
                                    var folded_idx: ?u16 = null;
                                    for (self.consts[0..self.const_count], 0..) |c, ci| {
                                        if (c == .string and common.streq(c.string.bytes, buf[0..total])) {
                                            folded_idx = @intCast(ci);
                                            break;
                                        }
                                    }
                                    const was_new = (folded_idx == null);
                                    const idx: u16 = folded_idx orelse blk: {
                                        if (self.const_count >= MaxConst) return error.TooManyConstants;
                                        const ss = try self.internStr(buf[0..total]);
                                        const i: u16 = @intCast(self.const_count);
                                        self.consts[i] = .{ .string = ss };
                                        self.const_count += 1;
                                        break :blk i;
                                    };
                                    try self.emitConstIdx(.constant, idx, line);
                                    self.prev_const_code_pos = null;
                                    self.prev_const_was_new = false;
                                    self.last_const_code_pos = self.code_len - 3;
                                    self.last_const_idx = idx;
                                    self.last_const_was_new = was_new;
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        }
        self.last_const_code_pos = null;
        try self.emitOp(op, line);
    }

    // Allocate a StringSlice in the pool for s without copying s's bytes.
    // s MUST point at immortal data for the current script's lifetime.
    pub fn internStr(self: *State, s: []const u8) !*const StringSlice {
        if (self.str_slice_count >= MaxStrSlices) return error.TooManyConstants;
        const idx = self.str_slice_count;
        self.str_slice_count += 1;
        self.str_slices[idx] = .{ .bytes = s };
        return &self.str_slices[idx];
    }

    // Like internStr but copies s to the GC heap first so the bytes outlive any
    // caller-provided source buffer.  Use for compile-time string constants.
    pub fn internStrCopy(self: *State, s: []const u8) !*const StringSlice {
        const copy = heap.bump(u8, s.len) orelse return error.OutOfMemory;
        @memcpy(copy[0..s.len], s);
        return self.internStr(copy[0..s.len]);
    }

    // Deduplicate + store a string constant; return its 2-byte index.
    // Copies s to the GC heap for stability.
    pub fn addStringConst(self: *State, s: []const u8) !u16 {
        for (self.consts[0..self.const_count], 0..) |c, i| {
            if (c == .string and common.streq(c.string.bytes, s)) return @intCast(i);
        }
        const ss = try self.internStrCopy(s);
        if (self.const_count >= MaxConst) return error.TooManyConstants;
        const idx = self.const_count;
        self.consts[idx] = .{ .string = ss };
        self.const_count += 1;
        return @intCast(idx);
    }

    // Emit any opcode + string constant index.  Mirrors emitOpConst for strings.
    pub fn emitOpStringConst(self: *State, op: Op, s: []const u8, line: u32) !void {
        const pre_count = self.const_count;
        const idx = try self.addStringConst(s);
        try self.emitConstIdx(op, idx, line);
        if (op == .constant) {
            self.prev_const_code_pos = self.last_const_code_pos;
            self.prev_const_idx = self.last_const_idx;
            self.prev_const_was_new = self.last_const_was_new;
            self.last_const_code_pos = self.code_len - 3;
            self.last_const_idx = idx;
            self.last_const_was_new = (idx == pre_count); // false when deduplicated
        } else {
            self.last_const_code_pos = null;
            self.prev_const_code_pos = null;
        }
    }

    // Emit .constant opcode for a string literal.
    pub fn emitStringConst(self: *State, s: []const u8, line: u32) !void {
        return self.emitOpStringConst(.constant, s, line);
    }

    // Store any non-string constant; return its 2-byte index (no dedup).
    pub fn addConst(self: *State, v: Value) !u16 {
        if (self.const_count >= MaxConst) return error.TooManyConstants;
        const idx = self.const_count;
        self.consts[idx] = v;
        self.const_count += 1;
        if (v == .object) {
            self.obj_const_idxs[self.obj_const_count] = @intCast(idx);
            self.obj_const_count += 1;
        }
        return @intCast(idx);
    }

    // Emit .constant opcode + 2-byte index.
    pub fn emitConst(self: *State, v: Value, line: u32) !void {
        return self.emitOpConst(.constant, v, line);
    }

    pub fn patchByte(self: *State, offset: usize, val: u8) void {
        self.code[offset] = val;
    }

    // Emit get_global: op + name_idx(2) + ic_slot(2, cold=0xFFFF).
    pub fn emitGetGlobal(self: *State, name: []const u8, line: u32) !void {
        const idx = try self.addStringConst(name);
        try self.emitByte(@intFromEnum(Op.get_global), line);
        try self.emitByte(@intCast((idx >> 8) & 0xff), line);
        try self.emitByte(@intCast(idx & 0xff), line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
    }

    // Emit get_global when constant index is already known.
    pub fn emitGetGlobalIdx(self: *State, idx: u16, line: u32) !void {
        try self.emitByte(@intFromEnum(Op.get_global), line);
        try self.emitByte(@intCast((idx >> 8) & 0xff), line);
        try self.emitByte(@intCast(idx & 0xff), line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
    }

    // Emit set_global: op + name_idx(2) + ic_slot(2, cold=0xFFFF).
    pub fn emitSetGlobal(self: *State, name: []const u8, line: u32) !void {
        const idx = try self.addStringConst(name);
        try self.emitByte(@intFromEnum(Op.set_global), line);
        try self.emitByte(@intCast((idx >> 8) & 0xff), line);
        try self.emitByte(@intCast(idx & 0xff), line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
    }

    // Emit get_field: op + name_idx(2) + ic_type(2, cold=0xFFFF) + ic_fidx(1, cold=0xFF).
    pub fn emitGetField(self: *State, name: []const u8, line: u32) !void {
        const idx = try self.addStringConst(name);
        try self.emitByte(@intFromEnum(Op.get_field), line);
        try self.emitByte(@intCast((idx >> 8) & 0xff), line);
        try self.emitByte(@intCast(idx & 0xff), line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
    }

    // Emit set_field: op + name_idx(2) + ic_type(2, cold=0xFFFF) + ic_fidx(1, cold=0xFF).
    pub fn emitSetField(self: *State, name: []const u8, line: u32) !void {
        const idx = try self.addStringConst(name);
        try self.emitByte(@intFromEnum(Op.set_field), line);
        try self.emitByte(@intCast((idx >> 8) & 0xff), line);
        try self.emitByte(@intCast(idx & 0xff), line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
    }

    // Helpers for invoke_method / defer_invoke_method which interleave a const index
    // with a separate argc byte: op + idx_hi + idx_lo + argc + ic_type(2) + ic_func(2).
    pub fn emitInvokeMethod(self: *State, name: []const u8, argc: u8, line: u32) !void {
        const idx = try self.addStringConst(name);
        try self.emitByte(@intFromEnum(Op.invoke_method), line);
        try self.emitByte(@intCast((idx >> 8) & 0xff), line);
        try self.emitByte(@intCast(idx & 0xff), line);
        try self.emitByte(argc, line);
        try self.emitByte(0xff, line); // ic_type hi (cold)
        try self.emitByte(0xff, line); // ic_type lo (cold)
        try self.emitByte(0xff, line); // ic_func hi (cold)
        try self.emitByte(0xff, line); // ic_func lo (cold)
    }

    pub fn emitDeferInvokeMethod(self: *State, name: []const u8, argc: u8, line: u32) !void {
        const idx = try self.addStringConst(name);
        try self.emitByte(@intFromEnum(Op.defer_invoke_method), line);
        try self.emitByte(@intCast((idx >> 8) & 0xff), line);
        try self.emitByte(@intCast(idx & 0xff), line);
        try self.emitByte(argc, line);
    }

    // Jump/loop fusion (quad/quint patterns, close_upvalue+loop, etc.) happens
    // in the load-time fusion pass; the emitter always writes the plain form.
    pub fn emitJump(self: *State, op: Op, line: u32) !usize {
        try self.emitOp(op, line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
        return self.code_len - 4;
    }

    pub fn patchJump(self: *State, offset: usize) !void {
        const jump = self.code_len - offset - 4;
        if (jump > 0xffffffff) return error.JumpTooLarge;
        self.code[offset] = @intCast((jump >> 24) & 0xff);
        self.code[offset + 1] = @intCast((jump >> 16) & 0xff);
        self.code[offset + 2] = @intCast((jump >> 8) & 0xff);
        self.code[offset + 3] = @intCast(jump & 0xff);
    }

    pub fn emitLoop(self: *State, loop_start: usize, line: u32) !void {
        try self.emitOp(.loop, line);
        const offset = self.code_len - loop_start + 4;
        if (offset > 0xffffffff) return error.LoopTooLarge;
        try self.emitByte(@intCast((offset >> 24) & 0xff), line);
        try self.emitByte(@intCast((offset >> 16) & 0xff), line);
        try self.emitByte(@intCast((offset >> 8) & 0xff), line);
        try self.emitByte(@intCast(offset & 0xff), line);
    }

    pub fn reset(self: *State) void {
        self.code_len = 0;
        self.const_count = 0;
        self.obj_const_count = 0;
        self.str_slice_count = 0;
        self.pending_col = 0;
        self.last_const_code_pos = null;
        self.last_const_idx = 0;
        self.prev_const_code_pos = null;
        self.prev_const_idx = 0;
        self.std_call_patch_pos = null;
        self.verify_err_len = 0;
        self.verified = false;
        self.verified_code_len = 0;
        self.module_boundary_count = 0;
    }

    pub fn codeLen(self: *const State) usize {
        return self.code_len;
    }

    pub fn markStdCallPatchPos(self: *State) void {
        self.std_call_patch_pos = self.code_len;
    }

    pub fn stdCallPatchPos(self: *State) ?usize {
        return self.std_call_patch_pos;
    }

    pub fn clearStdCallPatchPos(self: *State) void {
        self.std_call_patch_pos = null;
    }

    pub fn truncateTo(self: *State, pos: usize) void {
        self.code_len = pos;
        self.last_const_code_pos = null;
    }

    pub fn deleteCodeRange(self: *State, start: usize, len: usize) void {
        if (len == 0 or start >= self.code_len or start + len > self.code_len) return;
        const tail_start = start + len;
        const new_len = self.code_len - len;
        std.mem.copyForwards(u8, self.code[start..new_len], self.code[tail_start..self.code_len]);
        std.mem.copyForwards(u16, self.lines[start..new_len], self.lines[tail_start..self.code_len]);
        std.mem.copyForwards(u16, self.cols[start..new_len], self.cols[tail_start..self.code_len]);
        self.code_len = new_len;
        self.last_const_code_pos = null;
        self.std_call_patch_pos = null;
        self.verified = false;
        self.verified_code_len = 0;
    }

    pub fn constCount(self: *const State) usize {
        return self.const_count;
    }
    pub fn codeByteAt(self: *const State, i: usize) u8 {
        return self.code[i];
    }
    pub fn lineAt(self: *const State, i: usize) u16 {
        return self.lines[i];
    }
    pub fn colAt(self: *const State, i: usize) u16 {
        return self.cols[i];
    }

    pub fn addModuleBoundary(self: *State, path: []const u8) void {
        if (self.module_boundary_count >= MaxModuleBoundaries) return;
        const idx = self.module_boundary_count;
        self.module_boundaries[idx].ip_start = @intCast(self.code_len);
        const copy_len = @min(path.len, MaxModuleSourcePath);
        @memcpy(self.module_boundaries[idx].path[0..copy_len], path[0..copy_len]);
        self.module_boundaries[idx].path_len = @intCast(copy_len);
        self.module_boundary_count += 1;
    }

    // Walk the boundary table backwards to find the latest entry whose ip_start <= ip.
    // Returns empty slice when no boundary covers ip (should not happen in practice).
    pub fn pathAt(self: *const State, ip: usize) []const u8 {
        var i = self.module_boundary_count;
        while (i > 0) {
            i -= 1;
            if (self.module_boundaries[i].ip_start <= ip) {
                const b = &self.module_boundaries[i];
                return b.path[0..b.path_len];
            }
        }
        return &[_]u8{};
    }
    pub fn constAt(self: *const State, i: usize) !Value {
        if (i >= self.const_count) return error.BadConstantIndex;
        return self.consts[i];
    }
    // Unchecked const access. Sound ONLY for indices the verifier validated:
    // chunk_verifier pass 1 rejects any decoded const_index >= const_count
    // before execution, so hot handlers reading those operands skip the
    // bounds branch. Indices the decoder does NOT extract (e.g. the global
    // name index embedded in call_global_local_sub_const) must use constAt.
    pub fn constAtU(self: *const State, i: usize) Value {
        return (self.consts[0..].ptr + i)[0];
    }
    pub fn decodeAt(self: *State, pos: usize) !DecodedInstruction {
        return chunk_decoder.decodeAt(self, pos);
    }
    pub fn verify(self: *State, alloc: std.mem.Allocator) !void {
        if (self.verified and self.verified_code_len == self.code_len) return;
        try chunk_verifier.verify(self, alloc);
        self.verified = true;
        self.verified_code_len = self.code_len;
    }
};

var g_default_state: State = .{};
// threadlocal: each OS thread tracks its own active runtime, so two Runtimes
// driven from different threads never stomp each other's active pointers
// (#190). Single-threaded targets (WASI) lower this to a plain global.
pub threadlocal var g_state: *State = &g_default_state;

pub fn setActive(state: *State) void {
    g_state = state;
}

pub fn reset() void {
    g_state.reset();
}

fn foldBinOp(op: Op, lhs: Value, rhs: Value) ?Value {
    if (lhs == .int and rhs == .int) {
        return switch (op) {
            .add => blk: {
                const r = @addWithOverflow(lhs.int, rhs.int);
                break :blk if (r[1] != 0) null else Value{ .int = r[0] };
            },
            .sub => blk: {
                const r = @subWithOverflow(lhs.int, rhs.int);
                break :blk if (r[1] != 0) null else Value{ .int = r[0] };
            },
            .mul => blk: {
                const r = @mulWithOverflow(lhs.int, rhs.int);
                break :blk if (r[1] != 0) null else Value{ .int = r[0] };
            },
            // int / int produces float (true division), matching the runtime .div opcode.
            .div => if (rhs.int == 0) null else Value{ .float = @as(f64, @floatFromInt(lhs.int)) / @as(f64, @floatFromInt(rhs.int)) },
            .rem => if (rhs.int == 0 or (lhs.int == std.math.minInt(i64) and rhs.int == -1)) null else Value{ .int = @rem(lhs.int, rhs.int) },
            .mod => if (rhs.int == 0 or (lhs.int == std.math.minInt(i64) and rhs.int == -1)) null else Value{ .int = @mod(lhs.int, rhs.int) },
            else => null,
        };
    }
    if (lhs == .float and rhs == .float) {
        return switch (op) {
            .add => Value{ .float = lhs.float + rhs.float },
            .sub => Value{ .float = lhs.float - rhs.float },
            .mul => Value{ .float = lhs.float * rhs.float },
            .div => if (rhs.float == 0.0) null else Value{ .float = lhs.float / rhs.float },
            .rem => if (rhs.float == 0.0) null else Value{ .float = common.fmod(lhs.float, rhs.float) },
            .mod => if (rhs.float == 0.0) null else Value{ .float = lhs.float - @floor(lhs.float / rhs.float) * rhs.float },
            else => null,
        };
    }
    return null;
}

// ── Module-level wrapper functions (delegate to g_state methods) ──────────────
// TEST/ENTRY-POINT USE ONLY. Production code (compiler, module_compile, VM,
// runtime) must go through an explicit *State handle — these wrappers exist
// for the hand-assembled-bytecode test runners (vm_value_runner,
// vm_safety_runner, fuzz_runner, compiler_test) and the WASM export layer,
// which have no way to receive a context. Do not add production callers;
// see dev-docs/improvement-plan-2026-07.md A1.

pub fn setCol(col: u32) void {
    g_state.setCol(col);
}
pub fn emitByte(b: u8, line: u32) !void {
    return g_state.emitByte(b, line);
}
pub fn emitOp(op: Op, line: u32) !void {
    return g_state.emitOp(op, line);
}
pub fn emitCall(argc: u8, line: u32) !void {
    return g_state.emitCall(argc, line);
}
pub fn emitCallSpread(argc: u8, spread_n: u8, line: u32) !void {
    return g_state.emitCallSpread(argc, spread_n, line);
}
pub fn emit2(a: u8, b: u8, line: u32) !void {
    return g_state.emit2(a, b, line);
}
pub fn emitConstIdx(op: Op, idx: u16, line: u32) !void {
    return g_state.emitConstIdx(op, idx, line);
}
pub fn emitOpConst(op: Op, v: Value, line: u32) !void {
    return g_state.emitOpConst(op, v, line);
}
pub fn emitBinOpFused(op: Op, line: u32) !void {
    return g_state.emitBinOpFused(op, line);
}
pub fn internStr(s: []const u8) !*const StringSlice {
    return g_state.internStr(s);
}
pub fn addStringConst(s: []const u8) !u16 {
    return g_state.addStringConst(s);
}
pub fn emitOpStringConst(op: Op, s: []const u8, line: u32) !void {
    return g_state.emitOpStringConst(op, s, line);
}
pub fn emitStringConst(s: []const u8, line: u32) !void {
    return g_state.emitStringConst(s, line);
}
pub fn addConst(v: Value) !u16 {
    return g_state.addConst(v);
}
pub fn emitConst(v: Value, line: u32) !void {
    return g_state.emitConst(v, line);
}
pub fn patchByte(offset: usize, val: u8) void {
    g_state.patchByte(offset, val);
}
pub fn emitGetGlobal(name: []const u8, line: u32) !void {
    return g_state.emitGetGlobal(name, line);
}
pub fn emitGetGlobalIdx(idx: u16, line: u32) !void {
    return g_state.emitGetGlobalIdx(idx, line);
}
pub fn emitSetGlobal(name: []const u8, line: u32) !void {
    return g_state.emitSetGlobal(name, line);
}
pub fn emitGetField(name: []const u8, line: u32) !void {
    return g_state.emitGetField(name, line);
}
pub fn emitSetField(name: []const u8, line: u32) !void {
    return g_state.emitSetField(name, line);
}
pub fn emitInvokeMethod(name: []const u8, argc: u8, line: u32) !void {
    return g_state.emitInvokeMethod(name, argc, line);
}
pub fn emitDeferInvokeMethod(name: []const u8, argc: u8, line: u32) !void {
    return g_state.emitDeferInvokeMethod(name, argc, line);
}
pub fn emitJump(op: Op, line: u32) !usize {
    return g_state.emitJump(op, line);
}
pub fn patchJump(offset: usize) !void {
    return g_state.patchJump(offset);
}
pub fn emitLoop(loop_start: usize, line: u32) !void {
    return g_state.emitLoop(loop_start, line);
}
pub fn markStdCallPatchPos() void {
    g_state.markStdCallPatchPos();
}
pub fn stdCallPatchPos() ?usize {
    return g_state.stdCallPatchPos();
}
pub fn clearStdCallPatchPos() void {
    g_state.clearStdCallPatchPos();
}
pub fn truncateTo(pos: usize) void {
    g_state.truncateTo(pos);
}
pub fn deleteCodeRange(start: usize, len: usize) void {
    g_state.deleteCodeRange(start, len);
}

// ── VM/verifier-only functions (unchanged, use g_state directly) ──────────────

pub fn constAt(i: usize) !Value {
    return g_state.constAt(i);
}
pub fn addModuleBoundary(path: []const u8) void {
    g_state.addModuleBoundary(path);
}

pub const DecodedInstruction = chunk_decoder.DecodedInstruction;

pub fn decodeAt(pos: usize) !DecodedInstruction {
    return g_state.decodeAt(pos);
}
pub fn verify() !void {
    return g_state.verify(std.heap.page_allocator);
}
