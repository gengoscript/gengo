// GBC (Gengo Bytecode Cache) writer — dev-docs/design/gbc-spec.md.
//
// #5 first milestone: a minimal round-trip for a simple script (no imports,
// one bytecode section, constants, functions, empty types/exports/dependency
// tables). Serializes the DEFUSED (core-ops-only) form, per the ratified GBC
// design in dev-docs/design/vm-architecture.md §6.3 — fused/private opcodes
// never touch the wire. vm_defuse.buildDefusedCode already implements the
// fuse→defuse transform (built for differential testing); this reuses it
// rather than duplicating bytecode-rewriting logic.
//
// NOTE: buildDefusedCode mutates cs.consts[*].function.ip in place to match
// the defused bytecode it returns, while leaving cs.code untouched (still
// fused). After calling write(), `cs` is no longer a consistent, runnable
// chunk — its FuncObj.ip values point into the defused bytes returned by
// buildDefusedCode, not into cs.code. Only call write() on a chunk you are
// done executing (e.g. a dedicated compile-and-cache step), never on one you
// intend to keep running in the same process afterward.

const std = @import("std");
const chunk = @import("chunk.zig");
const value_mod = @import("value.zig");
const vm_defuse = @import("vm_defuse.zig");
const Op = @import("op.zig").Op;

pub const MAGIC = [8]u8{ 0x89, 'G', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub const HEADER_SIZE: u16 = 184;
pub const HEADER_VERSION: u16 = 1;
pub const FORMAT_MAJOR: u16 = 1;
pub const FORMAT_MINOR: u16 = 0;

pub const TargetId = enum(u32) { unspecified = 0, wasm32_wasi = 1, native_x86_64 = 2, native_aarch64 = 3 };
pub const BackendId = enum(u32) { unspecified = 0, bytevm = 1 };
pub const EntryKind = enum(u16) { unspecified = 0, script = 1, module = 2, repl_cell = 3, test_artifact = 4 };

pub const SEC_BYTECODE: u32 = 0x0001;
pub const SEC_CONSTANTS: u32 = 0x0002;
pub const SEC_FUNCTIONS: u32 = 0x0003;
pub const SEC_NATIVE_IMPORTS: u32 = 0x0004;
pub const SEC_EXPORTS: u32 = 0x0005;
pub const SEC_TYPES: u32 = 0x0006;
pub const SEC_DEPENDENCY_TABLE: u32 = 0x0007;
const SECTION_FLAG_REQUIRED: u32 = 0x0001;

pub const CONST_NUMBER: u8 = 0x01;
pub const CONST_STRING: u8 = 0x02;
pub const CONST_NULL: u8 = 0x03;
pub const CONST_BOOL: u8 = 0x04;
pub const CONST_RUNE: u8 = 0x05;
pub const CONST_FUNC_REF: u8 = 0x07;

pub const WriteOptions = struct {
    entry_kind: EntryKind = .script,
    target_id: TargetId = .native_x86_64,
    backend_id: BackendId = .bytevm,
    language_major: u16 = 0,
    language_minor: u16 = 5,
    flags: u32 = 0,
    /// The exact source text this chunk was compiled from — needed to
    /// compute source_graph_hash (§6.6). Must be the same bytes the
    /// compiler saw, for the hash to mean anything to a future loader.
    root_source: []const u8,
};

pub const WriteError = error{
    TooManyFunctions,
    UnsupportedConstant,
    BadBytecode,
    BytecodeOutOfBounds,
    BadOpcode,
    BadJumpTarget,
    DefusedCodeTooLarge,
} || std.mem.Allocator.Error;

const ByteWriter = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    alloc: std.mem.Allocator,

    fn deinit(self: *ByteWriter) void {
        self.buf.deinit(self.alloc);
    }
    fn u8_(self: *ByteWriter, v: u8) !void {
        try self.buf.append(self.alloc, v);
    }
    fn u16_(self: *ByteWriter, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }
    fn u32_(self: *ByteWriter, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }
    fn u64_(self: *ByteWriter, v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }
    fn i64_(self: *ByteWriter, v: i64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, v, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }
    fn f64_(self: *ByteWriter, v: f64) !void {
        try self.u64_(@bitCast(v));
    }
    fn bool8(self: *ByteWriter, v: bool) !void {
        try self.u8_(if (v) 1 else 0);
    }
    fn str_(self: *ByteWriter, s: []const u8) !void {
        try self.u32_(@intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
    }
    fn hash32(self: *ByteWriter, h: [32]u8) !void {
        try self.buf.appendSlice(self.alloc, &h);
    }
    fn rawBytes(self: *ByteWriter, s: []const u8) !void {
        try self.buf.appendSlice(self.alloc, s);
    }
};

fn sha256(parts: []const []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |p| h.update(p);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn lenPrefixed(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, 4 + s.len);
    std.mem.writeInt(u32, out[0..4], @intCast(s.len), .little);
    @memcpy(out[4..], s);
    return out;
}

fn sourceGraphHash(alloc: std.mem.Allocator, root_source: []const u8) ![32]u8 {
    const domain = "GENGO_SOURCE_GRAPH_V1";
    const domain_lp = try lenPrefixed(alloc, domain);
    defer alloc.free(domain_lp);
    const source_lp = try lenPrefixed(alloc, root_source);
    defer alloc.free(source_lp);
    // No file imports supported yet (milestone scope) — file_dep_count is
    // implicitly 0, matching the spec's single-file baseline form exactly.
    return sha256(&.{ domain_lp, source_lp });
}

fn optionsHash(target_id: TargetId, backend_id: BackendId, flags: u32) [32]u8 {
    var b: [13]u8 = undefined;
    b[0] = 1; // encoding version
    std.mem.writeInt(u32, b[1..5], @intFromEnum(target_id), .little);
    std.mem.writeInt(u32, b[5..9], @intFromEnum(backend_id), .little);
    std.mem.writeInt(u32, b[9..13], flags, .little);
    return sha256(&.{&b});
}

// Placeholder vm_fingerprint for native targets until a real build-id/commit
// fingerprint mechanism exists (spec §6.6 leaves this host-defined for
// non-WASM targets). Deliberately named and isolated so it's easy to find
// and replace — this must NOT be relied on for real staleness detection yet.
fn placeholderVmFingerprint() [32]u8 {
    return sha256(&.{"GENGO_VM_FINGERPRINT_PLACEHOLDER_V1"});
}

const FuncEntryInfo = struct {
    name: []const u8, // empty means anonymous
    ip: u32,
    length: u32,
    f: *const value_mod.FuncObj,
};

// Derive a function's defused-bytecode length from the jump-over-body
// convention every function-emission call site uses (compiler_stmts.zig,
// compiler.zig): a `jump` instruction sits immediately before the function's
// first instruction, and its target is exactly the end of that function's
// contiguous range. Asserts the convention holds rather than assuming it.
fn deriveFuncLength(code: []const u8, ip: u32) WriteError!u32 {
    if (ip < 5) return error.BadBytecode;
    const jump_op_pos = ip - 5;
    if (code[jump_op_pos] != @intFromEnum(Op.jump)) return error.BadBytecode;
    const off = std.mem.readInt(u32, code[jump_op_pos + 1 ..][0..4], .big);
    const target = jump_op_pos + 5 + off;
    if (target < ip) return error.BadBytecode;
    return @intCast(target - ip);
}

fn writeTypeSpecNone(w: *ByteWriter) !void {
    // A single ANY alt — used for fields this milestone doesn't populate
    // (param/return types are out of scope until TYPES-table support lands).
    try w.u8_(1); // alt_count
    try w.u8_(0x00); // ANY
}

// Index of the STRING constant equal to `name` in cs.consts[0..const_count],
// or null if none matches (spec: name_constant_idx = 0xFFFFFFFF for
// anonymous functions; also used when a named function's name string
// wasn't independently added as its own constant).
fn findStringConstIdx(cs: *chunk.State, name: []const u8) ?u32 {
    if (name.len == 0) return null;
    for (cs.consts[0..cs.const_count], 0..) |v, i| {
        if (v == .string and std.mem.eql(u8, v.string.bytes, name)) return @intCast(i);
    }
    return null;
}

fn writeFunctionsSection(w: *ByteWriter, cs: *chunk.State, funcs: []const FuncEntryInfo) !void {
    try w.u32_(@intCast(funcs.len));
    for (funcs) |fe| {
        const name_idx = findStringConstIdx(cs, fe.name);
        try w.u32_(name_idx orelse 0xFFFFFFFF);
        try w.u32_(fe.ip);
        try w.u32_(fe.length);
        // local_count is not tracked on FuncObj today — the reader doesn't
        // need it either, since frame sizing comes from chunk_verifier's
        // max_stack stamp, recomputed on load. 0 is a safe placeholder;
        // revisit if a future consumer needs it without re-verifying.
        try w.u16_(0);
        try w.u8_(fe.f.arity);
        try w.bool8(fe.f.is_variadic);
        if (fe.f.is_variadic) try writeTypeSpecNone(w);
        try w.bool8(fe.f.has_typed_params);
        try w.bool8(fe.f.has_typed_returns);
        try w.u8_(fe.f.named_return_count);
        try w.u16_(0); // param_type_count (deferred — no TYPES-table support yet)
        try w.u16_(0); // return_type_count (deferred)
        try w.u8_(@intCast(fe.f.capture_slots.len));
        try w.rawBytes(fe.f.capture_slots);
    }
}

/// Writes a GBC artifact for `cs` (which must already be compiled and fused,
/// i.e. the normal, runnable chunk.State a compile pipeline produces).
/// Returns an allocator-owned byte slice. See the module doc for the
/// critical caveat: `cs` must not be executed after calling this.
pub fn write(cs: *chunk.State, alloc: std.mem.Allocator, opts: WriteOptions) WriteError![]u8 {
    const defused_code = try vm_defuse.buildDefusedCode(cs, alloc);
    defer alloc.free(defused_code);

    // Collect function constants (must be .function objects only — closures
    // with captures, named/struct types are out of this milestone's scope).
    var funcs: std.ArrayListUnmanaged(FuncEntryInfo) = .empty;
    defer funcs.deinit(alloc);

    var consts_w = ByteWriter{ .alloc = alloc };
    defer consts_w.deinit();
    try consts_w.u32_(@intCast(cs.const_count));
    for (cs.consts[0..cs.const_count]) |v| {
        switch (v) {
            .int => |n| {
                try consts_w.u8_(CONST_NUMBER);
                try consts_w.f64_(@floatFromInt(n));
            },
            .float => |n| {
                try consts_w.u8_(CONST_NUMBER);
                try consts_w.f64_(n);
            },
            .rune => |r| {
                try consts_w.u8_(CONST_RUNE);
                try consts_w.u32_(r);
            },
            .boolean => |b| {
                try consts_w.u8_(CONST_BOOL);
                try consts_w.bool8(b);
            },
            .null => {
                try consts_w.u8_(CONST_NULL);
            },
            .string => |ss| {
                try consts_w.u8_(CONST_STRING);
                try consts_w.str_(ss.bytes);
            },
            .object => |obj| {
                if (obj.* != .function) return error.UnsupportedConstant;
                const f = &obj.function;
                const length = try deriveFuncLength(defused_code, @intCast(f.ip));
                try funcs.append(alloc, .{
                    .name = f.name,
                    .ip = @intCast(f.ip),
                    .length = length,
                    .f = f,
                });
                try consts_w.u8_(CONST_FUNC_REF);
                try consts_w.u32_(@intCast(funcs.items.len - 1));
            },
            else => return error.UnsupportedConstant,
        }
    }

    var funcs_w = ByteWriter{ .alloc = alloc };
    defer funcs_w.deinit();
    try writeFunctionsSection(&funcs_w, cs, funcs.items);

    // Empty sections for this milestone.
    var empty_u32_w = ByteWriter{ .alloc = alloc };
    defer empty_u32_w.deinit();
    try empty_u32_w.u32_(0);

    var native_imports_w = ByteWriter{ .alloc = alloc };
    defer native_imports_w.deinit();
    try native_imports_w.u32_(0);

    // Section table + body assembly.
    const Section = struct { id: u32, data: []const u8 };
    const sections = [_]Section{
        .{ .id = SEC_BYTECODE, .data = defused_code },
        .{ .id = SEC_CONSTANTS, .data = consts_w.buf.items },
        .{ .id = SEC_FUNCTIONS, .data = funcs_w.buf.items },
        .{ .id = SEC_NATIVE_IMPORTS, .data = native_imports_w.buf.items },
        .{ .id = SEC_EXPORTS, .data = empty_u32_w.buf.items },
        .{ .id = SEC_TYPES, .data = empty_u32_w.buf.items },
        .{ .id = SEC_DEPENDENCY_TABLE, .data = empty_u32_w.buf.items },
    };

    var body = ByteWriter{ .alloc = alloc };
    defer body.deinit();
    try body.u32_(@intCast(sections.len));
    const table_header_len: u64 = 4 + sections.len * (4 + 4 + 8 + 8);
    var offset: u64 = table_header_len;
    var offsets: [sections.len]u64 = undefined;
    for (sections, 0..) |s, i| {
        offsets[i] = offset;
        offset += s.data.len;
    }
    for (sections, 0..) |s, i| {
        try body.u32_(s.id);
        try body.u32_(SECTION_FLAG_REQUIRED);
        try body.u64_(offsets[i]);
        try body.u64_(@intCast(s.data.len));
    }
    for (sections) |s| try body.rawBytes(s.data);

    const body_checksum = std.hash.XxHash64.hash(0, body.buf.items);
    const src_hash = try sourceGraphHash(alloc, opts.root_source);
    const vm_fp = placeholderVmFingerprint();
    const opt_hash = optionsHash(opts.target_id, opts.backend_id, opts.flags);

    var out = ByteWriter{ .alloc = alloc };
    errdefer out.deinit();
    try out.rawBytes(&MAGIC);
    try out.u16_(HEADER_SIZE);
    try out.u16_(HEADER_VERSION);
    try out.u16_(FORMAT_MAJOR);
    try out.u16_(FORMAT_MINOR);
    try out.u16_(opts.language_major);
    try out.u16_(opts.language_minor);
    try out.u32_(opts.flags);
    try out.u32_(@intFromEnum(opts.target_id));
    try out.u32_(@intFromEnum(opts.backend_id));
    try out.u16_(@intFromEnum(opts.entry_kind));
    try out.rawBytes(&[_]u8{0} ** 6); // _reserved
    // compiled_at is diagnostics/logging only per spec §11.3 ("never used
    // for cache invalidation") — 0 rather than plumbing an Io interface
    // through just for this field. Revisit once a real caller needs it.
    try out.i64_(0);
    try out.hash32(src_hash);
    try out.hash32(vm_fp);
    try out.hash32(vm_fp); // module_provider_hash == vm_fingerprint (compiled-in stdlib, §6.6)
    try out.hash32(opt_hash);
    try out.u64_(@intCast(body.buf.items.len));
    try out.u64_(body_checksum);
    try out.rawBytes(body.buf.items);

    return out.buf.toOwnedSlice(alloc);
}
