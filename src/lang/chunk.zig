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

// Sparse source-position table: one entry per distinct (line, col) transition.
// Only records positions where the line or column changes, so a 10 000-line
// script with ~5 instructions per line uses ~10 000 entries rather than the
// ~50 000 entries a dense table would require.  Saves ~3.9 MiB vs the old
// []u16 × MaxCode dense approach.  lineAt/colAt do a binary search (error
// path only — hot VM execution never calls them).
pub const MaxLineEntries = 16384; // 16 384 × 8 B = 128 KiB
pub const LineEntry = struct { ip: u32, line: u16, col: u16 };

pub const ModuleBoundary = struct {
    ip_start: u32 = 0,
    path_len: u8 = 0,
    path: [MaxModuleSourcePath]u8 = undefined,
};

pub const State = struct {
    // Large arrays are heap-allocated via initArrays() to keep g_default_state
    // (and the per-Runtime heap create()) tiny in the binary image.
    code: []u8 = &.{},
    line_table: []LineEntry = &.{},
    line_table_count: usize = 0,
    // Last (line, col) written to line_table — dedup guard for emitByte.
    last_emitted_line: u16 = 0,
    last_emitted_col: u16 = 0xffff, // force first emitByte to always record
    consts: []Value = &.{},
    str_slices: []StringSlice = &.{},
    code_len: usize = 0,
    const_count: usize = 0,
    // Indices of constants that hold heap objects (function prototypes, type
    // objects). The GC root-scans only these instead of walking the whole
    // constant pool every collection (#187). Constant-folding rollbacks only
    // ever retract scalar/string constants, so entries here never go stale in
    // practice; the GC still guards with `idx < const_count` so a rollback
    // could at worst re-mark a harmless slot, never miss a live object.
    obj_const_idxs: []u16 = &.{},
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
    // Peephole: position of the last true_val/false_val (1-byte, no constant-pool
    // slot — see emitFoldedResult) instruction, for the `not` fold. Same safety
    // shape as last_const_code_pos: a stale value is harmless because the fold
    // site always re-checks `pos + 1 == code_len`, which only holds when nothing
    // else was emitted since — never trust the raw byte at code_len-1 alone, since
    // that could coincidentally match a trailing operand byte of an unrelated,
    // longer instruction.
    last_bool_lit_pos: ?usize = null,
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

    // Range of const pool entries for compiled std script functions.
    // Set by runtime.compileStdScripts(); zero when not compiled (e.g. REPL).
    std_script_const_base: u16 = 0,
    std_script_const_count: u16 = 0,
    // End of std-script bytecode in the code buffer; user code starts here.
    // Set by runtime.compileStdScripts(); zero when not compiled.
    std_script_code_end: usize = 0,

    // ── State methods (used by the compiler via an explicit *State pointer) ────────

    pub fn setCol(self: *State, col: u32) void {
        self.pending_col = @intCast(@min(col, 0xffff));
    }

    pub fn emitByte(self: *State, b: u8, line: u32) !void {
        if (self.code_len >= MaxCode) return error.ChunkFull;
        self.code[self.code_len] = b;
        const line16: u16 = @intCast(if (line > 0xffff) 0xffff else line);
        if (line16 != self.last_emitted_line or self.pending_col != self.last_emitted_col) {
            if (self.line_table_count < self.line_table.len) {
                self.line_table[self.line_table_count] = .{
                    .ip = @intCast(self.code_len),
                    .line = line16,
                    .col = self.pending_col,
                };
                self.line_table_count += 1;
                self.last_emitted_line = line16;
                self.last_emitted_col = self.pending_col;
            }
        }
        self.code_len += 1;
    }

    // Emit a folded constant result. A .boolean result specifically gets the
    // dedicated true_val/false_val opcode (1 byte, no constant-pool slot)
    // instead of going through emitConst's constant+index encoding (3 bytes,
    // consumes a pool slot) — matching how a bare `true`/`false` literal
    // token already compiles (see primaryExpr's .kw_true/.kw_false handling
    // in compiler_expr.zig), so a folded boolean is exactly as cheap as one
    // written directly in source, not more expensive. This also means the
    // unary `not` peephole below (which checks for a literal true_val/
    // false_val immediately before it, not just a constant-pool boolean)
    // actually fires on the common case of folding `not <constant-folded
    // comparison>`, not just the rare case of a genuine boolean constant
    // pool entry.
    fn emitFoldedResult(self: *State, result: Value, line: u32) !void {
        if (result == .boolean) {
            self.last_const_code_pos = null;
            self.prev_const_code_pos = null;
            self.last_bool_lit_pos = self.code_len;
            return self.emitByte(@intFromEnum(if (result.boolean) Op.true_val else Op.false_val), line);
        }
        return self.emitConst(result, line);
    }

    pub fn emitOp(self: *State, op: Op, line: u32) !void {
        // Constant folding for ops that bypass emitBinOpFused (mul, div, int_div,
        // rem, mod, and — same reasoning, these are int-only so never hit the
        // string-concat special case emitBinOpFused also has to handle — the
        // bitwise/shift ops).
        switch (op) {
            .mul, .div, .int_div, .rem, .mod, .bit_and, .bit_or, .bit_xor, .shl, .shr => {
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
                                    try self.emitFoldedResult(result, line);
                                    return;
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
        // Peephole: neg/not/bit_not immediately after constant → apply in place.
        // Same shape as the binary fold above, just unary: only ever touches a
        // value that's already sitting alone in the constant pool, so there's
        // no overflow/precision case to bail out of (unlike neg's int branch,
        // which does bail on minInt(i64) — negating that overflows i64; bit_not
        // has no such case since bitwise complement can't overflow, and not's
        // operand is already a plain bool with no numeric range to exceed).
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
        if (op == .bit_not) {
            if (self.last_const_code_pos) |pos| {
                if (pos + 3 == self.code_len) {
                    const v = self.consts[self.last_const_idx];
                    if (v == .int) {
                        self.consts[self.last_const_idx] = .{ .int = ~v.int };
                        return;
                    }
                }
            }
        }
        if (op == .not) {
            // The common case: a literal true/false (or a folded boolean
            // result, since emitFoldedResult emits the same opcode for
            // those) sitting immediately before this `not` as a bare
            // true_val/false_val byte — not a constant-pool entry at all.
            // last_bool_lit_pos + 1 == code_len proves that 1-byte
            // instruction is really what's sitting right here (not just a
            // coincidentally-matching trailing operand byte of some other,
            // longer instruction) — same reasoning as last_const_code_pos's
            // `pos + 3 == code_len` check above.
            if (self.last_bool_lit_pos) |pos| {
                if (pos + 1 == self.code_len) {
                    const was_true = self.code[pos] == @intFromEnum(Op.true_val);
                    self.code_len = pos;
                    self.last_bool_lit_pos = pos;
                    return self.emitByte(@intFromEnum(if (was_true) Op.false_val else Op.true_val), line);
                }
            }
            // Belt-and-suspenders: a genuine constant-pool boolean, if one
            // ever reaches here by some other path.
            if (self.last_const_code_pos) |pos| {
                if (pos + 3 == self.code_len) {
                    const v = self.consts[self.last_const_idx];
                    if (v == .boolean) {
                        self.consts[self.last_const_idx] = .{ .boolean = !v.boolean };
                        return;
                    }
                }
            }
        }
        if (op == .true_val or op == .false_val) {
            self.last_bool_lit_pos = self.code_len;
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
                            try self.emitFoldedResult(result, line);
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
        // Deduplicate: short strings (≤32 bytes) are scanned for an existing
        // entry.  This keeps FFI key strings ("_ptr", "_len", "_sym", …) from
        // accumulating unboundedly across repeated ffi.buf / lib.declare calls.
        if (s.len <= 32) {
            for (self.str_slices[0..self.str_slice_count]) |*ss| {
                if (std.mem.eql(u8, ss.bytes, s)) return ss;
            }
        }
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
        if (self.code.len == 0) self.initArrays(std.heap.page_allocator) catch @panic("chunk.State: OOM during lazy init");
        self.code_len = 0;
        self.const_count = 0;
        self.obj_const_count = 0;
        self.str_slice_count = 0;
        self.pending_col = 0;
        self.last_const_code_pos = null;
        self.last_const_idx = 0;
        self.prev_const_code_pos = null;
        self.prev_const_idx = 0;
        self.last_bool_lit_pos = null;
        self.std_call_patch_pos = null;
        self.verify_err_len = 0;
        self.verified = false;
        self.verified_code_len = 0;
        self.module_boundary_count = 0;
        self.line_table_count = 0;
        self.last_emitted_line = 0;
        self.last_emitted_col = 0xffff;
        self.std_script_const_base = 0;
        self.std_script_const_count = 0;
        self.std_script_code_end = 0;
    }

    pub fn codeLen(self: *const State) usize {
        return self.code_len;
    }

    // Remap every FuncObj entry IP reachable from the const pool through
    // ip_map (old ip → new ip; one entry per old code position plus an
    // end-of-code sentinel). Used by passes that rewrite the code buffer
    // (fusion_pass install, vm_defuse pass 3).
    //
    // A FuncObj pointer may be reachable from multiple const-pool entries
    // (a plain function const and a closure wrapping it, or two named_type
    // consts sharing a predicate). Each FuncObj is remapped exactly once —
    // a second application would index ip_map with an already-remapped ip.
    pub fn remapConstFuncIps(self: *State, ip_map: []const u32, alloc: std.mem.Allocator) error{OutOfMemory}!void {
        var seen_func_ptrs = std.AutoHashMap(usize, void).init(alloc);
        defer seen_func_ptrs.deinit();
        for (self.consts[0..self.const_count]) |cv| {
            if (cv != .object) continue;
            const fo = funcObjOfConst(cv.object) orelse continue;
            const gop = try seen_func_ptrs.getOrPut(@intFromPtr(fo));
            if (gop.found_existing) continue;
            if (fo.function.ip < ip_map.len) fo.function.ip = ip_map[fo.function.ip];
        }
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
        // Drop all line_table entries whose ip is >= pos.
        var n = self.line_table_count;
        while (n > 0 and self.line_table[n - 1].ip >= pos) n -= 1;
        self.line_table_count = n;
        if (n > 0) {
            self.last_emitted_line = self.line_table[n - 1].line;
            self.last_emitted_col = self.line_table[n - 1].col;
        } else {
            self.last_emitted_line = 0;
            self.last_emitted_col = 0xffff;
        }
    }

    pub fn deleteCodeRange(self: *State, start: usize, len: usize) void {
        if (len == 0 or start >= self.code_len or start + len > self.code_len) return;
        const tail_start = start + len;
        const new_len = self.code_len - len;
        std.mem.copyForwards(u8, self.code[start..new_len], self.code[tail_start..self.code_len]);
        self.code_len = new_len;
        // Rebuild the sparse line table: drop entries in the deleted range and
        // shift down ips for those that were after it.
        var out: usize = 0;
        for (self.line_table[0..self.line_table_count]) |e| {
            if (e.ip >= start and e.ip < tail_start) continue; // deleted
            const new_ip: u32 = if (e.ip >= tail_start) e.ip - @as(u32, @intCast(len)) else e.ip;
            self.line_table[out] = .{ .ip = new_ip, .line = e.line, .col = e.col };
            out += 1;
        }
        self.line_table_count = out;
        if (out > 0) {
            self.last_emitted_line = self.line_table[out - 1].line;
            self.last_emitted_col = self.line_table[out - 1].col;
        } else {
            self.last_emitted_line = 0;
            self.last_emitted_col = 0xffff;
        }
        self.last_const_code_pos = null;
        self.std_call_patch_pos = null;
        self.verified = false;
        self.verified_code_len = 0;
        // Everything at or after tail_start shifted left by len bytes, but
        // absolute positions recorded elsewhere (a function's entry ip, a
        // module boundary's start) were captured before this call and don't
        // move on their own — an intrinsic call site whose argument is a
        // function literal (its body compiled, and its FuncObj.ip captured,
        // entirely after this range) would otherwise end up with a stale
        // entry point once the preamble ahead of it is deleted (found via
        // std.core.append(arr, func() ... { ... }) inside a loop). Only the
        // call-site rewrites in compiler_expr.zig ever call this, always to
        // remove a std-call's get_global preamble, so the deleted range is
        // never itself a function body or a jump target — a uniform shift
        // of anything at or after tail_start is sufficient, no per-op width
        // remapping needed (unlike fusion_pass.zig's ip_map, which handles
        // instructions changing width, not a fixed-size block removal).
        for (self.consts[0..self.const_count]) |*cv| {
            if (cv.* != .object) continue;
            switch (cv.object.*) {
                .function => |*f| if (f.ip >= tail_start) {
                    f.ip -= len;
                },
                .closure => |*cl| if (cl.func.* == .function and cl.func.function.ip >= tail_start) {
                    cl.func.function.ip -= len;
                },
                else => {},
            }
        }
        for (self.module_boundaries[0..self.module_boundary_count]) |*mb| {
            if (mb.ip_start >= tail_start) mb.ip_start -= @intCast(len);
        }
    }

    pub fn constCount(self: *const State) usize {
        return self.const_count;
    }
    pub fn codeByteAt(self: *const State, i: usize) u8 {
        return self.code[i];
    }
    pub fn lineAt(self: *const State, i: usize) u16 {
        const tbl = self.line_table[0..self.line_table_count];
        if (tbl.len == 0 or tbl[0].ip > i) return 0;
        var lo: usize = 0;
        var hi: usize = tbl.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (tbl[mid].ip <= i) lo = mid else hi = mid;
        }
        return tbl[lo].line;
    }
    pub fn colAt(self: *const State, i: usize) u16 {
        const tbl = self.line_table[0..self.line_table_count];
        if (tbl.len == 0 or tbl[0].ip > i) return 0;
        var lo: usize = 0;
        var hi: usize = tbl.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (tbl[mid].ip <= i) lo = mid else hi = mid;
        }
        return tbl[lo].col;
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

    pub fn initArrays(self: *State, allocator: std.mem.Allocator) !void {
        self.code = try allocator.alloc(u8, MaxCode + CodePad);
        self.line_table = try allocator.alloc(LineEntry, MaxLineEntries);
        self.consts = try allocator.alloc(Value, MaxConst);
        self.str_slices = try allocator.alloc(StringSlice, MaxStrSlices);
        self.obj_const_idxs = try allocator.alloc(u16, MaxConst);
    }

    pub fn deinitArrays(self: *State, allocator: std.mem.Allocator) void {
        if (self.code.len > 0) allocator.free(self.code);
        if (self.line_table.len > 0) allocator.free(self.line_table);
        if (self.consts.len > 0) allocator.free(self.consts);
        if (self.str_slices.len > 0) allocator.free(self.str_slices);
        if (self.obj_const_idxs.len > 0) allocator.free(self.obj_const_idxs);
        self.code = &.{};
        self.line_table = &.{};
        self.consts = &.{};
        self.str_slices = &.{};
        self.obj_const_idxs = &.{};
    }
};

// The function object (if any) a const-pool object leads to: a plain
// function, a closure's function, or a named type's predicate function
// (bare or closure-wrapped). Single source of the shape knowledge shared
// by chunk_verifier (collect/stamp) and remapConstFuncIps.
pub fn funcObjOfConst(obj: *val_mod.Object) ?*val_mod.Object {
    switch (obj.*) {
        .function => return obj,
        .closure => |cl| {
            if (cl.func.* == .function) return cl.func;
            return null;
        },
        .named_type => |nt| {
            const pred = nt.predicate orelse return null;
            switch (pred.*) {
                .function => return pred,
                .closure => |cl| {
                    if (cl.func.* == .function) return cl.func;
                    return null;
                },
                else => return null,
            }
        },
        // A task's behavior function is an ordinary FuncObj found through the
        // task_type const the same way a named_type's predicate is found —
        // without this case the verifier would never stamp its max_stack and
        // spawning the task would panic with StackOverflow at frame entry
        // (the exact bug class fixed by unifying this function; see
        // dev-docs' fusion-pass notes / project_fusion_double_remap memory).
        .task_type => |tt| {
            if (tt.behavior.* == .function) return tt.behavior;
            return null;
        },
        else => return null,
    }
}

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

// Comparison ops (both generic and the _float variants — see
// selectTypedComparisonOp in compiler.zig, which deliberately keeps the
// generic op instead of switching to the typed one whenever either operand
// is a compile-time constant, specifically so a fold gets a chance to run
// here). Takes plain i64/f64 rather than Values so both branches of
// foldBinOp can share it: for ints, integer `<`/`>`/`==` behave exactly
// like std.math.order without ever hitting its `unreachable` fallback
// (that fallback exists only for NaN, which no integer is); for floats,
// native f64 comparisons already implement IEEE-754 correctly for NaN
// (every comparison false except `!=`, which is true) — std.math.order
// would panic on NaN instead (its final `else => unreachable` triggers
// whenever none of ==, <, > hold), so this deliberately doesn't route
// through it despite floats being representable as an Order in the
// non-NaN case.
fn foldCompareOp(op: Op, comptime T: type, a: T, b: T) ?Value {
    return switch (op) {
        .eq, .eq_float => Value{ .boolean = a == b },
        .ne, .ne_float => Value{ .boolean = a != b },
        .lt, .lt_float => Value{ .boolean = a < b },
        .le, .le_float => Value{ .boolean = a <= b },
        .gt, .gt_float => Value{ .boolean = a > b },
        .ge, .ge_float => Value{ .boolean = a >= b },
        else => null,
    };
}

fn foldBinOp(op: Op, lhs: Value, rhs: Value) ?Value {
    if (lhs == .int and rhs == .int) {
        if (foldCompareOp(op, i64, lhs.int, rhs.int)) |v| return v;
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
            .bit_and => Value{ .int = lhs.int & rhs.int },
            .bit_or => Value{ .int = lhs.int | rhs.int },
            .bit_xor => Value{ .int = lhs.int ^ rhs.int },
            // Mirrors vm.zig's getShiftArgs/.shl/.shr exactly: negative shift
            // amount errors at runtime (RangeError) — don't fold, let that
            // still happen; shift count clamps to 63 rather than erroring;
            // shl additionally errors on magnitude overflow past what i64
            // can hold after the shift.
            .shl => blk: {
                if (rhs.int < 0) break :blk null;
                const shift: u6 = @intCast(@min(rhs.int, 63));
                if (lhs.int > 0 and lhs.int > (@as(i64, std.math.maxInt(i64)) >> shift)) break :blk null;
                if (lhs.int < 0 and lhs.int < (@as(i64, std.math.minInt(i64)) >> shift)) break :blk null;
                break :blk Value{ .int = lhs.int << shift };
            },
            .shr => blk: {
                if (rhs.int < 0) break :blk null;
                const shift: u6 = @intCast(@min(rhs.int, 63));
                break :blk Value{ .int = lhs.int >> shift };
            },
            else => null,
        };
    }
    if (lhs == .float and rhs == .float) {
        if (foldCompareOp(op, f64, lhs.float, rhs.float)) |v| return v;
        // Non-finite results must keep erroring at runtime exactly like the
        // unfolded two-constant-push-then-add path does (computeAddResult's
        // std.math.isFinite check) — don't fold those away into a silent inf.
        return switch (op) {
            .add => if (std.math.isFinite(lhs.float + rhs.float)) Value{ .float = lhs.float + rhs.float } else null,
            .sub => if (std.math.isFinite(lhs.float - rhs.float)) Value{ .float = lhs.float - rhs.float } else null,
            .mul => if (std.math.isFinite(lhs.float * rhs.float)) Value{ .float = lhs.float * rhs.float } else null,
            .div => blk: {
                if (rhs.float == 0.0) break :blk null;
                const r = lhs.float / rhs.float;
                break :blk if (std.math.isFinite(r)) Value{ .float = r } else null;
            },
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
// see the "A1 setActive migration" entry in
// dev-docs/archive/improvement-plan-2026-07.md.

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
