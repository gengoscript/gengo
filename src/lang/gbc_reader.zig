// GBC (Gengo Bytecode Cache) reader — dev-docs/design/gbc-spec.md.
//
// #5 first milestone: the reader half of the minimal round-trip. Loads the
// wire format's core-op bytecode + constants into a fresh chunk.State, then
// hands off to fusion_pass.fuse() — the exact same step the normal compile
// pipeline (runtime.zig's compileProgram) already runs — so a loaded chunk
// becomes runnable through the identical path a freshly-compiled one does.
// Globals (functions, top-level vars) are NOT pre-populated from any table:
// running the loaded chunk's top-level code (make_closure + def_global) is
// what populates them, exactly like an ordinary script run.
//
// This milestone implements only the checks needed for a correct round-trip
// (magic, header/body bounds, body checksum, section presence) — not the
// full Phase 3 staleness gauntlet (source_graph_hash/vm_fingerprint/
// module_provider_hash/options_hash comparison against "current" state) or
// Phase 4's exhaustive per-field validation. See dev-docs/design/gbc-spec.md
// §11.1 for the full validation phase list this intentionally does not yet
// enforce — a deliberate, documented gap for this first slice, not an
// oversight.

const std = @import("std");
const chunk = @import("chunk.zig");
const heap = @import("../runtime/heap.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const FuncObj = value_mod.FuncObj;
const gbc_writer = @import("gbc_writer.zig");

pub const ReadError = error{
    InvalidMagic,
    TruncatedHeader,
    UnsupportedHeaderVersion,
    HeaderTooSmall,
    NonZeroReserved,
    FormatMajorMismatch,
    TruncatedBody,
    BodyChecksumMismatch,
    MalformedSectionTable,
    MissingRequiredSection,
    SectionOutOfBounds,
    MalformedSection,
    BadConstantTag,
    FuncRefOutOfRange,
    TooManyFunctions,
    TooManyConstants,
    CodeTooLarge,
} || std.mem.Allocator.Error;

const ByteReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn need(self: *ByteReader, n: usize) !void {
        if (self.pos + n > self.bytes.len) return error.TruncatedBody;
    }
    fn u8_(self: *ByteReader) !u8 {
        try self.need(1);
        const v = self.bytes[self.pos];
        self.pos += 1;
        return v;
    }
    fn u16_(self: *ByteReader) !u16 {
        try self.need(2);
        const v = std.mem.readInt(u16, self.bytes[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn u32_(self: *ByteReader) !u32 {
        try self.need(4);
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn u64_(self: *ByteReader) !u64 {
        try self.need(8);
        const v = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn i64_(self: *ByteReader) !i64 {
        try self.need(8);
        const v = std.mem.readInt(i64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn f64_(self: *ByteReader) !f64 {
        const bits = try self.u64_();
        return @bitCast(bits);
    }
    fn bool8(self: *ByteReader) !bool {
        const b = try self.u8_();
        if (b != 0 and b != 1) return error.MalformedSection;
        return b == 1;
    }
    fn str_(self: *ByteReader) ![]const u8 {
        const len = try self.u32_();
        try self.need(len);
        const s = self.bytes[self.pos..][0..len];
        self.pos += len;
        return s;
    }
    fn hash32(self: *ByteReader) ![32]u8 {
        try self.need(32);
        var out: [32]u8 = undefined;
        @memcpy(&out, self.bytes[self.pos..][0..32]);
        self.pos += 32;
        return out;
    }
    fn skip(self: *ByteReader, n: usize) !void {
        try self.need(n);
        self.pos += n;
    }
};

// Matches compileFuncWithPrefix's own placeholder for a non-variadic
// function's variadic_type field (compiler_stmts.zig) — a single .any alt,
// not an empty alts slice, since that's what real compiled functions carry.
const any_type_alts = [1]value_mod.FieldTypeAlt{.{ .typ = .any }};
const any_type_spec: value_mod.FieldTypeSpec = .{ .alts = @constCast(&any_type_alts) };

// offset/length are stored as usize, not the wire's u64: on the loop that
// builds these (in read()), each entry is validated against body.len (a
// usize) before being cast down, so the cast is proven safe there — every
// downstream use (slicing BYTECODE/CONSTANTS/FUNCTIONS out of body) then
// needs no cast of its own. Doing the narrowing once, right after the bound
// check, instead of at every slice site also avoids a real portability bug:
// a bare u64 doesn't implicitly narrow to usize, and usize is 32-bit on
// wasm32 — this doesn't compile-error on a 64-bit host build but does on
// wasm32-wasi (found via the wasm32 CI/pre-push build, not the native one).
const SectionEntry = struct { id: u32, flags: u32, offset: usize, length: usize };

const RawFuncEntry = struct {
    name_constant_idx: u32,
    ip: u32,
    length: u32,
    arity: u8,
    is_variadic: bool,
    has_typed_params: bool,
    has_typed_returns: bool,
    named_return_count: u8,
    capture_slots: []const u8,
};

fn findSection(sections: []const SectionEntry, id: u32) ?SectionEntry {
    for (sections) |s| if (s.id == id) return s;
    return null;
}

fn readAnyTypeSpec(r: *ByteReader) !void {
    const alt_count = try r.u8_();
    var i: u8 = 0;
    while (i < alt_count) : (i += 1) {
        // This milestone never writes a non-ANY TypeSpec, so a single tag
        // byte with no further fields is all any current writer emits.
        // (Fuller decoding — array/map/struct/etc. alt shapes — comes with
        // TYPES-table support.)
        _ = try r.u8_();
    }
}

fn readFunctionsSection(r: *ByteReader, alloc: std.mem.Allocator) ![]RawFuncEntry {
    const count = try r.u32_();
    if (count > 65536) return error.TooManyFunctions;
    const out = try alloc.alloc(RawFuncEntry, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name_constant_idx = try r.u32_();
        const ip = try r.u32_();
        const length = try r.u32_();
        _ = try r.u16_(); // local_count — unused by this reader (see writer's comment)
        const arity = try r.u8_();
        const is_variadic = try r.bool8();
        if (is_variadic) try readAnyTypeSpec(r);
        const has_typed_params = try r.bool8();
        const has_typed_returns = try r.bool8();
        const named_return_count = try r.u8_();
        const param_type_count = try r.u16_();
        var pi: u16 = 0;
        while (pi < param_type_count) : (pi += 1) try readAnyTypeSpec(r);
        const return_type_count = try r.u16_();
        var ri: u16 = 0;
        while (ri < return_type_count) : (ri += 1) try readAnyTypeSpec(r);
        const capture_slot_count = try r.u8_();
        const capture_slots = try alloc.alloc(u8, capture_slot_count);
        var ci: u8 = 0;
        while (ci < capture_slot_count) : (ci += 1) capture_slots[ci] = try r.u8_();
        out[i] = .{
            .name_constant_idx = name_constant_idx,
            .ip = ip,
            .length = length,
            .arity = arity,
            .is_variadic = is_variadic,
            .has_typed_params = has_typed_params,
            .has_typed_returns = has_typed_returns,
            .named_return_count = named_return_count,
            .capture_slots = capture_slots,
        };
    }
    return out;
}

/// Loads a GBC artifact's bytecode and constants into `cs` (must already be
/// `.reset()` and the active chunk for `hs`'s allocations to land in the
/// right heap). Does not run fusion_pass.fuse() or verify() — the caller
/// does that next, exactly as the normal compile pipeline does after
/// producing core-op bytecode (see runtime.zig's compileProgram).
pub fn read(bytes: []const u8, cs: *chunk.State, hs: *heap.State, alloc: std.mem.Allocator) ReadError!void {
    var r = ByteReader{ .bytes = bytes };

    // Magic.
    try r.need(8);
    if (!std.mem.eql(u8, bytes[0..8], &gbc_writer.MAGIC)) return error.InvalidMagic;
    r.pos = 8;

    // Header.
    const header_size = try r.u16_();
    if (header_size < gbc_writer.HEADER_SIZE) return error.HeaderTooSmall;
    const header_version = try r.u16_();
    if (header_version != gbc_writer.HEADER_VERSION) return error.UnsupportedHeaderVersion;
    const format_major = try r.u16_();
    if (format_major != gbc_writer.FORMAT_MAJOR) return error.FormatMajorMismatch;
    _ = try r.u16_(); // format_minor — accepted <= loader's; this loader has only one version so far
    _ = try r.u16_(); // language_major
    _ = try r.u16_(); // language_minor
    _ = try r.u32_(); // flags
    _ = try r.u32_(); // target_id
    _ = try r.u32_(); // backend_id
    _ = try r.u16_(); // entry_kind
    const reserved = bytes[r.pos..][0..6];
    if (!std.mem.allEqual(u8, reserved, 0)) return error.NonZeroReserved;
    r.pos += 6;
    _ = try r.i64_(); // compiled_at — diagnostics only, never checked
    _ = try r.hash32(); // source_graph_hash — Phase 3 staleness check deferred, see module doc
    _ = try r.hash32(); // vm_fingerprint — deferred
    _ = try r.hash32(); // module_provider_hash — deferred
    _ = try r.hash32(); // options_hash — deferred
    const body_length = try r.u64_();
    const body_checksum = try r.u64_();

    // header_size may be larger than what this reader understands (forward
    // compatibility, §6): skip any trailing header bytes this version
    // doesn't define.
    const header_end = 8 + @as(usize, header_size);
    if (header_end > bytes.len) return error.TruncatedHeader;
    r.pos = header_end;

    if (header_end + body_length > bytes.len) return error.TruncatedBody;
    // Proven to fit (body_length <= bytes.len - header_end <= bytes.len, and
    // bytes.len is already a usize) — safe to narrow now that the check above
    // has run. A bare u64 doesn't implicitly narrow to usize (32-bit on
    // wasm32), so this cast can't be deferred to the slice expression itself.
    const body_len: usize = @intCast(body_length);
    const body = bytes[header_end..][0..body_len];
    if (std.hash.XxHash64.hash(0, body) != body_checksum) return error.BodyChecksumMismatch;

    // Body: section table.
    var br = ByteReader{ .bytes = body };
    const section_count = try br.u32_();
    if (section_count > 64) return error.MalformedSectionTable;
    var sections = try alloc.alloc(SectionEntry, section_count);
    defer alloc.free(sections);
    var i: u32 = 0;
    while (i < section_count) : (i += 1) {
        const id = try br.u32_();
        const flags = try br.u32_();
        const offset = try br.u64_();
        const length = try br.u64_();
        if (offset + length > body.len) return error.SectionOutOfBounds;
        // Proven to fit, same reasoning as body_len above.
        sections[i] = .{ .id = id, .flags = flags, .offset = @intCast(offset), .length = @intCast(length) };
    }

    const bytecode_sec = findSection(sections, gbc_writer.SEC_BYTECODE) orelse return error.MissingRequiredSection;
    const constants_sec = findSection(sections, gbc_writer.SEC_CONSTANTS) orelse return error.MissingRequiredSection;
    const functions_sec = findSection(sections, gbc_writer.SEC_FUNCTIONS) orelse return error.MissingRequiredSection;

    // BYTECODE: copy directly into the fresh chunk.
    const code_bytes = body[bytecode_sec.offset..][0..bytecode_sec.length];
    if (code_bytes.len > chunk.MaxCode) return error.CodeTooLarge;
    @memcpy(cs.code[0..code_bytes.len], code_bytes);
    cs.code_len = code_bytes.len;
    @memset(cs.lines[0..code_bytes.len], 0);
    @memset(cs.cols[0..code_bytes.len], 0);

    // FUNCTIONS: parsed before CONSTANTS since FUNC_REF constants index into it.
    const functions_bytes = body[functions_sec.offset..][0..functions_sec.length];
    var fr = ByteReader{ .bytes = functions_bytes };
    const raw_funcs = try readFunctionsSection(&fr, alloc);
    defer alloc.free(raw_funcs);

    // CONSTANTS.
    const constants_bytes = body[constants_sec.offset..][0..constants_sec.length];
    var cr = ByteReader{ .bytes = constants_bytes };
    const const_count = try cr.u32_();
    if (const_count > chunk.MaxConst) return error.TooManyConstants;
    var ci: u32 = 0;
    while (ci < const_count) : (ci += 1) {
        const tag = try cr.u8_();
        const v: Value = switch (tag) {
            gbc_writer.CONST_NUMBER => blk: {
                const n = try cr.f64_();
                // The wire format doesn't distinguish int/float (both are
                // NUMBER/f64, matching the current VM's f64-only constant
                // representation, §8.2) — round-trip through int if exact,
                // matching how the compiler itself decides int vs float at
                // parse time (this reader has no source text to re-parse,
                // so it recovers the same decision from the value shape).
                break :blk if (@trunc(n) == n and n >= -9007199254740992.0 and n <= 9007199254740992.0)
                    Value{ .int = @intFromFloat(n) }
                else
                    Value{ .float = n };
            },
            gbc_writer.CONST_STRING => blk: {
                const s = try cr.str_();
                const copy = hs.bump(u8, s.len) orelse return error.OutOfMemory;
                @memcpy(copy[0..s.len], s);
                const ss = try cs.internStr(copy[0..s.len]);
                break :blk Value{ .string = ss };
            },
            gbc_writer.CONST_NULL => .null,
            gbc_writer.CONST_BOOL => Value{ .boolean = try cr.bool8() },
            gbc_writer.CONST_RUNE => blk: {
                const cp = try cr.u32_();
                if (cp > 0x10FFFF) return error.MalformedSection;
                break :blk Value{ .rune = @intCast(cp) };
            },
            gbc_writer.CONST_FUNC_REF => blk: {
                const fidx = try cr.u32_();
                if (fidx >= raw_funcs.len) return error.FuncRefOutOfRange;
                const rf = raw_funcs[fidx];
                const name: []const u8 = if (rf.name_constant_idx == 0xFFFFFFFF or rf.name_constant_idx >= cs.const_count)
                    ""
                else if (cs.consts[rf.name_constant_idx] == .string)
                    cs.consts[rf.name_constant_idx].string.bytes
                else
                    "";
                const obj = hs.allocObject() orelse return error.OutOfMemory;
                obj.* = .{
                    .function = FuncObj{
                        .ip = rf.ip,
                        .arity = rf.arity,
                        .is_variadic = rf.is_variadic,
                        .variadic_type = any_type_spec,
                        .capture_slots = rf.capture_slots,
                        .param_types = &.{},
                        // Forced false regardless of the wire value: param_types/
                        // return_types are always empty until TYPES-table
                        // support lands (param_type_count is always written as
                        // 0 today — see the writer). vm_types.zig only ever
                        // indexes param_types/return_types when has_typed_params/
                        // has_typed_returns is true, so leaving the original
                        // (possibly-true) wire value here with an empty slice
                        // would be an out-of-bounds read the first time a typed
                        // arg-check ran. Correctness-safe (just skips runtime
                        // argument/return type checks for loaded functions,
                        // same as an unproven function), not silently unsafe.
                        .has_typed_params = false,
                        .return_types = &.{},
                        .has_typed_returns = false,
                        .name = name,
                        .named_return_count = rf.named_return_count,
                    },
                };
                break :blk Value{ .object = obj };
            },
            else => return error.BadConstantTag,
        };
        _ = try cs.addConst(v);
    }

    cs.verified = false;
    cs.verified_code_len = 0;
}
