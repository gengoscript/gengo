// GBC (Gengo Bytecode Cache) reader — dev-docs/design/gbc-spec.md.
//
// Reader half of the minimal round-trip. Loads the
// wire format's core-op bytecode + constants into a fresh chunk.State, then
// hands off to fusion_pass.fuse() — the exact same step the normal compile
// pipeline (runtime.zig's compileProgram) already runs — so a loaded chunk
// becomes runnable through the identical path a freshly-compiled one does.
// Globals (functions, top-level vars) are NOT pre-populated from any table:
// running the loaded chunk's top-level code (make_closure + def_global) is
// what populates them, exactly like an ordinary script run.
//
// This milestone implements the checks needed for a correct round-trip
// (magic, header/body bounds, body checksum, section presence) plus the
// Phase 3 staleness gauntlet's four header hash fields (§11.1 checks
// 22-25): source_graph_hash (only when the caller passes the source it
// expects this artifact to match — see read()'s expected_root_source
// param), and self-consistency checks on options_hash/vm_fingerprint/
// module_provider_hash (recomputed from the artifact's own other header
// fields and compared, catching a header hash that doesn't match the
// values it claims to summarize — e.g. bit-corruption the body checksum
// doesn't cover, since it only hashes the body). Phase 4's exhaustive
// per-field validation is still not implemented. See dev-docs/design/
// gbc-spec.md §11.1 for the full validation phase list.

const std = @import("std");
const chunk = @import("chunk.zig");
const heap = @import("../runtime/heap.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const FuncObj = value_mod.FuncObj;
const ct = @import("compiler_types.zig");
const chunk_decoder = @import("chunk_decoder.zig");
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
    BadFieldTypeTag,
    FuncRefOutOfRange,
    TypeRefOutOfRange,
    TooManyFunctions,
    TooManyTypes,
    TooManyConstants,
    TooManyExports,
    CodeTooLarge,
    SourceGraphStale,
    OptionsMismatch,
    VMFingerprintMismatch,
} || std.mem.Allocator.Error;

const ByteReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn need(self: *ByteReader, n: usize) !void {
        // self.pos + n as a raw add can itself overflow/wrap on a
        // file-controlled n (e.g. str_'s u32 length): on 32-bit usize
        // (wasm32) this wraps well within u32's range, and even on 64-bit
        // it's one more overflow site to close on principle. Subtract
        // instead of add so this can never wrap.
        if (n > self.bytes.len - self.pos) return error.TruncatedBody;
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
    variadic_type: value_mod.FieldTypeSpec,
    param_types: []value_mod.FieldTypeSpec,
    return_types: []value_mod.FieldTypeSpec,
    has_typed_params: bool,
    has_typed_returns: bool,
    named_return_count: u8,
    capture_slots: []const u8,
};

fn findSection(sections: []const SectionEntry, id: u32) ?SectionEntry {
    for (sections) |s| if (s.id == id) return s;
    return null;
}

// Where to re-find a raw_funcs[i]'s FuncObj through cs.consts, deferred
// until after the whole constants loop finishes (see that loop's comment).
// Deliberately a const-pool INDEX, not the *Object itself: cs.consts is
// GC-rooted, so the object stored there — and anything transitively
// reachable from it — gets correctly relocated by any compaction that runs
// later in the same loop (allocObject/bump calls for later constants can
// each trigger one, especially under -Dgc_stress). A raw pointer captured
// earlier in the loop has no such protection and silently goes stale the
// moment that happens; direct_const/predicate_const only ever get
// dereferenced through cs.consts[idx], never cached, so they can't.
const FuncNamePatchTarget = union(enum) {
    direct_const: u16, // cs.consts[idx] IS the FuncObj (a plain CONST_FUNC_REF)
    predicate_const: u16, // cs.consts[idx] is the named_type; the FuncObj is .named_type.predicate.?.closure.func
};

// Builds the .function-tagged heap object a SEC_FUNCTIONS entry describes —
// shared by a plain CONST_FUNC_REF constant and a named type's predicate
// (whose FuncObj is registered into SEC_FUNCTIONS the same way, but is
// referenced from a NAMED TypeEntry's predicate_func_idx instead of its own
// CONST_FUNC_REF constant — see read()'s CONST_TYPE_REF/TYPE_KIND_NAMED case).
// name is left "" here — see the comment at read()'s post-constants-loop
// name-patching pass for why it can't be resolved yet at this point.
// code_base: 0 for a standalone read() (the artifact's own code starts at
// chunk offset 0); the destination chunk's pre-splice code_len when
// readIntoSession is appending this artifact's code after existing code
// (loadSections' splice path) — rf.ip is this artifact's own 0-based
// offset into ITS bytecode, which becomes invalid once that bytecode is
// copied in anywhere but position 0.
fn buildFuncObjFromRaw(hs: *heap.State, rf: RawFuncEntry, code_base: usize) !*value_mod.Object {
    const obj = hs.allocObject() orelse return error.OutOfMemory;
    obj.* = .{
        .function = FuncObj{
            .ip = code_base + @as(usize, rf.ip),
            .arity = rf.arity,
            .is_variadic = rf.is_variadic,
            .variadic_type = rf.variadic_type,
            .capture_slots = rf.capture_slots,
            .param_types = rf.param_types,
            .has_typed_params = rf.has_typed_params,
            .return_types = rf.return_types,
            .has_typed_returns = rf.has_typed_returns,
            .name = "",
            .named_return_count = rf.named_return_count,
        },
    };
    return obj;
}

// Real decoder for struct field / named-collection elem/key/val specs and
// function/interface-method param/return/variadic types — mirrors
// gbc_writer.zig's writeTypeSpec exactly. Strings embedded in alts
// (struct_name/interface_name/named_name) are copied to the heap (via
// copyStr), not left as slices into the wire buffer: unlike CONST_STRING
// constants (which already go through cs.internStr's own heap copy), these
// live inside a FieldTypeSpec attached to a long-lived StructTypeObj/
// NamedTypeObj, and the caller's wire-bytes buffer is not guaranteed to
// outlive that object (it isn't, in general — only happens to for the CLI's
// static g_src_buf).
// A crafted FT_ARRAY/FT_MAP chain can recurse arbitrarily deep (each level
// costs as little as 3 bytes: alt_count=1, tag, has_elem/has_key flag) with
// no other bound on file size — unlike everything else in this reader,
// unbounded recursion isn't a catchable Zig error, it's a native stack
// overflow (SIGSEGV/abort). This is the only recursive shape in the whole
// GBC format (FT_STRUCT_T/FT_VARIANT_T store a name, not inline structure).
const MaxTypeSpecDepth: u32 = 64;

fn readTypeSpec(r: *ByteReader, hs: *heap.State, alloc: std.mem.Allocator) ReadError!value_mod.FieldTypeSpec {
    return readTypeSpecDepth(r, hs, alloc, 0);
}

fn readTypeSpecDepth(r: *ByteReader, hs: *heap.State, alloc: std.mem.Allocator, depth: u32) ReadError!value_mod.FieldTypeSpec {
    if (depth >= MaxTypeSpecDepth) return error.MalformedSection;
    const alt_count = try r.u8_();
    // A legitimately-compiled chunk always has at least one alt; nothing
    // downstream (matchesTypeSpec, fieldTypeSpecStr's unconditional
    // alts[0], coerceErasedValueForSpec) expects/handles an empty slice.
    if (alt_count == 0) return error.MalformedSection;
    // hs.bump (GC heap), not alloc — this FieldTypeSpec gets embedded into a
    // long-lived StructFieldSpec/NamedTypeObj, same reasoning as
    // readFunctionsSection's capture_slots above.
    const alts = (hs.bump(value_mod.FieldTypeAlt, alt_count) orelse return error.OutOfMemory)[0..alt_count];
    var i: u8 = 0;
    while (i < alt_count) : (i += 1) {
        const tag = try r.u8_();
        alts[i] = switch (tag) {
            gbc_writer.FT_ANY => .{ .typ = .any },
            gbc_writer.FT_NULL_T => .{ .typ = .null_t },
            gbc_writer.FT_INT => .{ .typ = .int },
            gbc_writer.FT_FLOAT => .{ .typ = .float },
            gbc_writer.FT_DECIMAL_T => .{ .typ = .decimal_t },
            gbc_writer.FT_RUNE_T => .{ .typ = .rune_t },
            gbc_writer.FT_BOOLEAN => .{ .typ = .boolean },
            gbc_writer.FT_STRING => .{ .typ = .string },
            gbc_writer.FT_ERROR_T => .{ .typ = .error_t },
            gbc_writer.FT_ACTOR_REF_T => .{ .typ = .actor_ref_t },
            gbc_writer.FT_ARRAY => blk: {
                const has_elem = try r.bool8();
                const elem: ?value_mod.FieldTypeSpec = if (has_elem) try readTypeSpecDepth(r, hs, alloc, depth + 1) else null;
                break :blk .{ .typ = .array, .elem_spec = elem };
            },
            gbc_writer.FT_MAP => blk: {
                const has_key = try r.bool8();
                const key: ?value_mod.FieldTypeSpec = if (has_key) try readTypeSpecDepth(r, hs, alloc, depth + 1) else null;
                const has_val = try r.bool8();
                const val: ?value_mod.FieldTypeSpec = if (has_val) try readTypeSpecDepth(r, hs, alloc, depth + 1) else null;
                break :blk .{ .typ = .map, .key_spec = key, .val_spec = val };
            },
            gbc_writer.FT_STRUCT_T => .{ .typ = .struct_t, .struct_name = try copyStr(hs, try r.str_()) },
            gbc_writer.FT_INTERFACE_T => .{ .typ = .interface_t, .interface_name = try copyStr(hs, try r.str_()) },
            gbc_writer.FT_NAMED_T => .{ .typ = .named_t, .named_name = try copyStr(hs, try r.str_()) },
            gbc_writer.FT_VARIANT_T => .{ .typ = .variant_t, .named_name = try copyStr(hs, try r.str_()) },
            gbc_writer.FT_FUNC_T => blk: {
                const param_count = try r.u16_();
                const params = (hs.bump(value_mod.FieldTypeSpec, param_count) orelse return error.OutOfMemory)[0..param_count];
                for (params) |*p| p.* = try readTypeSpecDepth(r, hs, alloc, depth + 1);
                const return_count = try r.u16_();
                const returns = (hs.bump(value_mod.FieldTypeSpec, return_count) orelse return error.OutOfMemory)[0..return_count];
                for (returns) |*rt| rt.* = try readTypeSpecDepth(r, hs, alloc, depth + 1);
                break :blk .{ .typ = .func_t, .func_params = params, .func_returns = returns };
            },
            else => return error.BadFieldTypeTag,
        };
    }
    return .{ .alts = alts };
}

fn copyStr(hs: *heap.State, s: []const u8) ![]const u8 {
    if (s.len == 0) return "";
    const buf = hs.bump(u8, s.len) orelse return error.OutOfMemory;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

// A well-formed writer always emits param_types with exactly `arity` entries
// (or `arity - 1` for a variadic function, since the variadic slot itself
// counts toward arity but is described separately by variadic_type). Nothing
// downstream re-derives this relationship — vm_types.zig's
// canInlinePrimitiveArgs/enforceFuncArgTypes index param_types[0..fixed]
// assuming it holds — so a crafted file that decouples the two fields
// (e.g. arity=5, param_type_count=0) causes an unconditional out-of-bounds
// panic the moment the function is called, no type mismatch required. Also
// rejects is_variadic=true with arity==0, which would separately underflow
// enforceFuncArgTypes's `arity - 1` (a variadic function's own variadic
// parameter always contributes at least 1 to arity in any real compile).
fn validateArityShape(arity: u8, is_variadic: bool, has_typed_params: bool, param_type_count: usize) ReadError!void {
    if (is_variadic and arity == 0) return error.MalformedSection;
    if (!has_typed_params) return;
    const expected: usize = if (is_variadic) arity - 1 else arity;
    if (param_type_count != expected) return error.MalformedSection;
}

// Shared by STRUCT type entries, a variant's shared_fields, and a record-
// shaped variant arm's fields — mirrors gbc_writer.zig's writeFieldList.
// hs.bump, not alloc: the returned slice is embedded into a long-lived
// StructTypeObj/VariantTypeObj/VariantArmSpec (see read()'s CONST_TYPE_REF
// case), not just used for the duration of read().
fn readFieldList(r: *ByteReader, cs: *chunk.State, hs: *heap.State, alloc: std.mem.Allocator) ReadError![]value_mod.StructFieldSpec {
    const field_count = try r.u16_();
    const fields = (hs.bump(value_mod.StructFieldSpec, field_count) orelse return error.OutOfMemory)[0..field_count];
    var fi: u16 = 0;
    while (fi < field_count) : (fi += 1) {
        const fname = try copyStr(hs, try r.str_());
        const ftype = try readTypeSpec(r, hs, alloc);
        const is_const = try r.bool8();
        // key is derivable from name (matches how the compiler itself sets
        // it — see compiler_decls.zig — so it's not written to the wire at
        // all): internStr doesn't copy, and fname is already a heap-owned
        // copy from copyStr above, so this is safe without a second
        // allocation.
        fields[fi] = .{ .name = fname, .typ = ftype, .is_const = is_const, .key = .{ .string = try cs.internStr(fname) } };
    }
    return fields;
}

fn readVariantArm(r: *ByteReader, cs: *chunk.State, hs: *heap.State, alloc: std.mem.Allocator) ReadError!value_mod.VariantArmSpec {
    const name = try copyStr(hs, try r.str_());
    const arm_kind = try r.u8_();
    return switch (arm_kind) {
        gbc_writer.VARIANT_ARM_NONE => .{ .name = name },
        gbc_writer.VARIANT_ARM_SINGLE_PAYLOAD => blk: {
            const payload_name = try copyStr(hs, try r.str_());
            const payload_type = try readTypeSpec(r, hs, alloc);
            break :blk .{ .name = name, .has_payload = true, .payload_name = payload_name, .payload_type = payload_type };
        },
        gbc_writer.VARIANT_ARM_RECORD => blk: {
            const fields = try readFieldList(r, cs, hs, alloc);
            break :blk .{ .name = name, .has_payload = fields.len > 0, .fields = fields };
        },
        else => return error.MalformedSection,
    };
}

// Mirrors gbc_writer.zig's writeInterfaceMethod exactly.
fn readInterfaceMethod(r: *ByteReader, hs: *heap.State, alloc: std.mem.Allocator) ReadError!value_mod.InterfaceMethodSpec {
    const name = try copyStr(hs, try r.str_());
    const arity = try r.u8_();
    const is_variadic = try r.bool8();
    const variadic_type: value_mod.FieldTypeSpec = if (is_variadic) try readTypeSpec(r, hs, alloc) else any_type_spec;
    const has_typed_params = try r.bool8();
    const has_typed_returns = try r.bool8();
    const param_type_count = try r.u16_();
    try validateArityShape(arity, is_variadic, has_typed_params, param_type_count);
    const param_types = (hs.bump(value_mod.FieldTypeSpec, param_type_count) orelse return error.OutOfMemory)[0..param_type_count];
    for (param_types) |*pt| pt.* = try readTypeSpec(r, hs, alloc);
    const return_type_count = try r.u16_();
    const return_types = (hs.bump(value_mod.FieldTypeSpec, return_type_count) orelse return error.OutOfMemory)[0..return_type_count];
    for (return_types) |*rt| rt.* = try readTypeSpec(r, hs, alloc);
    return .{
        .name = name,
        .arity = arity,
        .is_variadic = is_variadic,
        .variadic_type = variadic_type,
        .param_types = param_types,
        .return_types = return_types,
        .has_typed_params = has_typed_params,
        .has_typed_returns = has_typed_returns,
    };
}

const RawTypeEntry = struct {
    kind: u8,
    name: []const u8,
    qualified_name: []const u8,
    // STRUCT
    fields: []value_mod.StructFieldSpec = &.{},
    // VARIANT
    shared_fields: []value_mod.StructFieldSpec = &.{},
    arms: []value_mod.VariantArmSpec = &.{},
    // INTERFACE
    methods: []value_mod.InterfaceMethodSpec = &.{},
    // NAMED
    base: value_mod.NamedTypeBase = .int,
    has_range: bool = false,
    is_cycle: bool = false,
    is_clamp: bool = false,
    min: f64 = 0,
    max: f64 = 0,
    parent_name: []const u8 = "",
    elem_spec: ?value_mod.FieldTypeSpec = null,
    key_spec: ?value_mod.FieldTypeSpec = null,
    val_spec: ?value_mod.FieldTypeSpec = null,
    is_anonymous: bool = false,
    scale: u8 = 0,
    // Deferred, not resolved here: resolving to a real predicate *Object
    // needs raw_funcs, which isn't in scope until read()'s CONSTANTS loop
    // (see the CONST_TYPE_REF/TYPE_KIND_NAMED case below).
    predicate_func_idx: ?u32 = null,
    predicate_msg: ?[]const u8 = null,
    has_default: bool = false,
    default_val: Value = .null,
    // ENUM
    members: [][]const u8 = &.{},
    member_ints: ?[]i64 = null,
    // parent_name is shared with NAMED above — same field, same "" == no
    // parent convention.
};

fn readTypesSection(r: *ByteReader, cs: *chunk.State, hs: *heap.State, alloc: std.mem.Allocator) ReadError![]RawTypeEntry {
    const count = try r.u32_();
    if (count > 65536) return error.TooManyTypes;
    const out = try alloc.alloc(RawTypeEntry, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const kind = try r.u8_();
        const name = try copyStr(hs, try r.str_());
        const qualified_name = try copyStr(hs, try r.str_());
        switch (kind) {
            gbc_writer.TYPE_KIND_STRUCT => {
                const fields = try readFieldList(r, cs, hs, alloc);
                out[i] = .{ .kind = kind, .name = name, .qualified_name = qualified_name, .fields = fields };
            },
            gbc_writer.TYPE_KIND_VARIANT => {
                const shared_fields = try readFieldList(r, cs, hs, alloc);
                const arm_count = try r.u16_();
                const arms = (hs.bump(value_mod.VariantArmSpec, arm_count) orelse return error.OutOfMemory)[0..arm_count];
                var ai: u16 = 0;
                while (ai < arm_count) : (ai += 1) arms[ai] = try readVariantArm(r, cs, hs, alloc);
                out[i] = .{ .kind = kind, .name = name, .qualified_name = qualified_name, .shared_fields = shared_fields, .arms = arms };
            },
            gbc_writer.TYPE_KIND_NAMED => {
                const base_byte = try r.u8_();
                if (base_byte > @intFromEnum(value_mod.NamedTypeBase.enum_t)) return error.MalformedSection;
                const base: value_mod.NamedTypeBase = @enumFromInt(base_byte);
                const has_range = try r.bool8();
                const is_cycle = try r.bool8();
                const is_clamp = try r.bool8();
                const min = try r.f64_();
                const max = try r.f64_();
                const parent_name = try copyStr(hs, try r.str_());
                const has_elem = try r.bool8();
                const elem_spec: ?value_mod.FieldTypeSpec = if (has_elem) try readTypeSpec(r, hs, alloc) else null;
                const has_key = try r.bool8();
                const key_spec: ?value_mod.FieldTypeSpec = if (has_key) try readTypeSpec(r, hs, alloc) else null;
                const has_val = try r.bool8();
                const val_spec: ?value_mod.FieldTypeSpec = if (has_val) try readTypeSpec(r, hs, alloc) else null;
                const is_anonymous = try r.bool8();
                const scale = try r.u8_();
                const has_predicate = try r.bool8();
                var predicate_func_idx: ?u32 = null;
                var predicate_msg: ?[]const u8 = null;
                if (has_predicate) {
                    predicate_func_idx = try r.u32_();
                    const has_msg = try r.bool8();
                    if (has_msg) predicate_msg = try copyStr(hs, try r.str_());
                }
                const has_default = try r.bool8();
                var default_val: Value = .null;
                if (has_default) {
                    default_val = switch (base) {
                        .int, .float, .rune, .decimal => Value{ .float = try r.f64_() },
                        .string => blk: {
                            const s = try copyStr(hs, try r.str_());
                            break :blk Value{ .string = try cs.internStr(s) };
                        },
                        .bool => Value{ .boolean = try r.bool8() },
                        .array_t, .map_t, .enum_t => return error.MalformedSection,
                    };
                }
                out[i] = .{
                    .kind = kind,
                    .name = name,
                    .qualified_name = qualified_name,
                    .base = base,
                    .has_range = has_range,
                    .is_cycle = is_cycle,
                    .is_clamp = is_clamp,
                    .min = min,
                    .max = max,
                    .parent_name = parent_name,
                    .elem_spec = elem_spec,
                    .key_spec = key_spec,
                    .val_spec = val_spec,
                    .is_anonymous = is_anonymous,
                    .scale = scale,
                    .predicate_func_idx = predicate_func_idx,
                    .predicate_msg = predicate_msg,
                    .has_default = has_default,
                    .default_val = default_val,
                };
            },
            gbc_writer.TYPE_KIND_INTERFACE => {
                const method_count = try r.u16_();
                const methods = (hs.bump(value_mod.InterfaceMethodSpec, method_count) orelse return error.OutOfMemory)[0..method_count];
                var mi: u16 = 0;
                while (mi < method_count) : (mi += 1) methods[mi] = try readInterfaceMethod(r, hs, alloc);
                out[i] = .{ .kind = kind, .name = name, .qualified_name = qualified_name, .methods = methods };
            },
            gbc_writer.TYPE_KIND_ENUM => {
                const member_count = try r.u16_();
                const members = (hs.bump([]const u8, member_count) orelse return error.OutOfMemory)[0..member_count];
                var emi: u16 = 0;
                while (emi < member_count) : (emi += 1) members[emi] = try copyStr(hs, try r.str_());
                const has_ints = try r.bool8();
                var member_ints: ?[]i64 = null;
                if (has_ints) {
                    const mints = (hs.bump(i64, member_count) orelse return error.OutOfMemory)[0..member_count];
                    var mii: u16 = 0;
                    while (mii < member_count) : (mii += 1) mints[mii] = try r.i64_();
                    member_ints = mints;
                }
                const parent_name = try copyStr(hs, try r.str_());
                out[i] = .{ .kind = kind, .name = name, .qualified_name = qualified_name, .members = members, .member_ints = member_ints, .parent_name = parent_name };
            },
            else => return error.MalformedSection,
        }
    }
    return out;
}

// Mirrors compiler_types.CompileTimeConst's own three payload shapes plus a
// NONE case (gbc-spec.md §8.5's OptConstValue) — a raw, not-yet-installed
// decode of one ExportEntry.const_value.
pub const OptConstValueRaw = union(enum) {
    none: void,
    number: f64,
    string: []const u8,
    boolean: bool,
};

pub const RawExportEntry = struct {
    name: []const u8,
    qualified_name: []const u8,
    type_kind: u8,
    const_value: OptConstValueRaw,
};

pub const RawExportsSection = struct {
    module_id: []const u8,
    exports: []RawExportEntry,
};

fn readOptConstValue(r: *ByteReader) ReadError!OptConstValueRaw {
    const tag = try r.u8_();
    return switch (tag) {
        0x00 => .none,
        0x01 => .{ .number = try r.f64_() },
        0x02 => .{ .string = try r.str_() },
        0x03 => .{ .boolean = try r.bool8() },
        else => error.MalformedSection,
    };
}

// Parses SEC_EXPORTS (gbc-spec.md §8.5) into raw, not-yet-installed entries
// — this milestone's read-side counterpart to gbc_writer.writeExportsSection,
// verifying the bytes it produces decode correctly. Installing these into a
// live compile session (building a ModuleRecord-shaped symbol table from
// them with no live Compiler involved) is a later increment (gbc-spec.md
// §14.3) — this function only decodes the wire shape.
pub fn readExportsSection(bytes: []const u8, alloc: std.mem.Allocator) ReadError!RawExportsSection {
    var r = ByteReader{ .bytes = bytes };
    const module_id = try r.str_();
    const count = try r.u32_();
    if (count > ct.MaxModuleExports) return error.TooManyExports;
    const out = try alloc.alloc(RawExportEntry, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try r.str_();
        const qualified_name = try r.str_();
        const type_kind = try r.u8_();
        if (type_kind > @intFromEnum(ct.ExportTypeKind.variant_t)) return error.MalformedSection;
        const const_value = try readOptConstValue(&r);
        out[i] = .{ .name = name, .qualified_name = qualified_name, .type_kind = type_kind, .const_value = const_value };
    }
    return .{ .module_id = module_id, .exports = out };
}

fn readFunctionsSection(r: *ByteReader, hs: *heap.State, alloc: std.mem.Allocator) ![]RawFuncEntry {
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
        const variadic_type: value_mod.FieldTypeSpec = if (is_variadic) try readTypeSpec(r, hs, alloc) else any_type_spec;
        const has_typed_params = try r.bool8();
        const has_typed_returns = try r.bool8();
        const named_return_count = try r.u8_();
        // named_return_count indexes into a [64]Value spread buffer in the VM;
        // a crafted GBC file can set this to any u8, so cap it here at the
        // same limit the VM uses.
        if (named_return_count > 64) return error.MalformedSection;
        const param_type_count = try r.u16_();
        try validateArityShape(arity, is_variadic, has_typed_params, param_type_count);
        const param_types = (hs.bump(value_mod.FieldTypeSpec, param_type_count) orelse return error.OutOfMemory)[0..param_type_count];
        for (param_types) |*pt| pt.* = try readTypeSpec(r, hs, alloc);
        const return_type_count = try r.u16_();
        const return_types = (hs.bump(value_mod.FieldTypeSpec, return_type_count) orelse return error.OutOfMemory)[0..return_type_count];
        for (return_types) |*rt| rt.* = try readTypeSpec(r, hs, alloc);
        const capture_slot_count = try r.u8_();
        // hs.bump (GC heap), not alloc: this slice is embedded directly into
        // the FuncObj constant this entry builds (see read()'s CONST_FUNC_REF
        // case) and must live as long as that object does, not just for the
        // duration of read() — alloc is freed/reused after read() returns.
        const capture_slots = (hs.bump(u8, capture_slot_count) orelse return error.OutOfMemory)[0..capture_slot_count];
        var ci: u8 = 0;
        while (ci < capture_slot_count) : (ci += 1) capture_slots[ci] = try r.u8_();
        out[i] = .{
            .name_constant_idx = name_constant_idx,
            .ip = ip,
            .length = length,
            .arity = arity,
            .is_variadic = is_variadic,
            .variadic_type = variadic_type,
            .param_types = param_types,
            .return_types = return_types,
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
// expected_root_source: when non-null, must be the exact source bytes this
// artifact claims to have been compiled from (gbc_writer.WriteOptions.
// root_source) — checked against the header's source_graph_hash, giving
// real staleness detection for a .gbc whose backing .gengo file has since
// changed. Pass null when no separate source is available to compare
// against (e.g. running a standalone .gbc with no source on hand), which
// skips that one check but leaves the other three header-hash
// self-consistency checks (see module doc) in effect either way.
const ParsedHeader = struct {
    body: []const u8,
    sections: []SectionEntry,
};

// Magic + header (including the Phase 3 self-consistency/staleness hash
// checks, see read()'s own doc comment) + body checksum + section table —
// everything both read() (which goes on to actually install BYTECODE/
// CONSTANTS/FUNCTIONS/TYPES into a fresh chunk.State) and findSectionBytes
// (which just wants one section's raw bytes, e.g. to inspect SEC_EXPORTS on
// a candidate dependency artifact without committing to a full load) need
// in common. Caller owns freeing the returned `sections` slice.
fn parseHeaderAndSections(bytes: []const u8, alloc: std.mem.Allocator, expected_root_source: ?[]const u8) ReadError!ParsedHeader {
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
    const flags = try r.u32_();
    const target_id = try r.u32_();
    const backend_id = try r.u32_();
    _ = try r.u16_(); // entry_kind
    const reserved = bytes[r.pos..][0..6];
    if (!std.mem.allEqual(u8, reserved, 0)) return error.NonZeroReserved;
    r.pos += 6;
    _ = try r.i64_(); // compiled_at — diagnostics only, never checked
    const src_hash = try r.hash32();
    const vm_fp = try r.hash32();
    const module_provider_hash = try r.hash32();
    const opt_hash = try r.hash32();
    const body_length = try r.u64_();
    const body_checksum = try r.u64_();

    // Self-consistency: each of these three is a hash of other header
    // fields also present in this same header, so recomputing and
    // comparing catches header corruption the body checksum can't (it only
    // covers the body) — not "did the build config change" (this loader
    // has no separate "expected options" input to compare against; that's
    // a job for a future caller-supplied-options parameter, not this one).
    const expected_opt_hash = gbc_writer.optionsHash(target_id, backend_id, flags);
    if (!std.mem.eql(u8, &opt_hash, &expected_opt_hash)) return error.OptionsMismatch;
    const expected_vm_fp = gbc_writer.placeholderVmFingerprint();
    if (!std.mem.eql(u8, &vm_fp, &expected_vm_fp)) return error.VMFingerprintMismatch;
    // module_provider_hash == vm_fingerprint whenever stdlib is compiled-in
    // (gbc-spec.md §6.6) — the only case this writer ever produces today.
    if (!std.mem.eql(u8, &module_provider_hash, &expected_vm_fp)) return error.VMFingerprintMismatch;
    if (expected_root_source) |want_src| {
        const expected_src_hash = try gbc_writer.sourceGraphHash(alloc, want_src);
        if (!std.mem.eql(u8, &src_hash, &expected_src_hash)) return error.SourceGraphStale;
    }

    // header_size may be larger than what this reader understands (forward
    // compatibility, §6): skip any trailing header bytes this version
    // doesn't define.
    const header_end = 8 + @as(usize, header_size);
    if (header_end > bytes.len) return error.TruncatedHeader;
    r.pos = header_end;

    // body_length is a raw u64 straight off disk (fully attacker-controlled
    // for a crafted .gbc file); header_end + body_length as a raw add can
    // itself overflow/wrap for a huge body_length, which would trap in
    // Debug/ReleaseSafe but silently bypass the check in ReleaseFast (the
    // CLI's actual build mode) — subtracting instead can't wrap, since
    // header_end <= bytes.len is already established above.
    if (body_length > bytes.len - header_end) return error.TruncatedBody;
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
    var i: u32 = 0;
    while (i < section_count) : (i += 1) {
        const id = try br.u32_();
        const sec_flags = try br.u32_();
        const offset = try br.u64_();
        const length = try br.u64_();
        // Same overflow hazard as the body-length check above: offset/length
        // are raw file u64s, so `offset + length` can itself wrap for huge
        // values instead of correctly failing the bounds check.
        if (offset > body.len) return error.SectionOutOfBounds;
        if (length > body.len - offset) return error.SectionOutOfBounds;
        // Proven to fit, same reasoning as body_len above.
        sections[i] = .{ .id = id, .flags = sec_flags, .offset = @intCast(offset), .length = @intCast(length) };
    }
    return .{ .body = body, .sections = sections };
}

// Returns one section's raw bytes without installing anything into a
// chunk.State — e.g. to inspect a candidate dependency artifact's
// SEC_EXPORTS (gbc-spec.md §14) before deciding whether to splice it in.
// Runs the same header/staleness/body-checksum validation read() does
// (parseHeaderAndSections), so a truncated/corrupted/stale artifact is
// rejected here exactly as it would be by a full read() — this is a
// narrower *result*, not a weaker *check*. Returns null if the section is
// absent (distinct from a present-but-empty section, e.g. `export_count ==
// 0`).
pub fn findSectionBytes(bytes: []const u8, alloc: std.mem.Allocator, section_id: u32, expected_root_source: ?[]const u8) ReadError!?[]const u8 {
    const parsed = try parseHeaderAndSections(bytes, alloc, expected_root_source);
    defer alloc.free(parsed.sections);
    const sec = findSection(parsed.sections, section_id) orelse return null;
    return parsed.body[sec.offset..][0..sec.length];
}

const LoadResult = struct {
    // Non-null only when `splice` was true (readIntoSession) — a standalone
    // read() has no need for its own exports (nothing links against a
    // directly-run artifact), so it doesn't pay to parse SEC_EXPORTS there.
    exports: ?RawExportsSection,
};

// Shared by read() (splice=false: install into a freshly-.reset() chunk,
// overwriting from offset 0 — the original behavior, byte-for-
// byte) and readIntoSession (splice=true: append onto whatever `cs` already
// holds, for gbc-spec.md §14 linking). Deliberately ONE implementation of
// the constants/functions/types loading, not two — that loop is exactly
// where the FuncNamePatchTarget GC-safety discipline lives (see its doc
// comment), and a second, parallel copy would be a second place for that
// discipline to be gotten wrong.
//
// What "splice" actually changes, precisely:
//   - BYTECODE lands at cs.code_len (append) instead of offset 0 (overwrite).
//   - Every function built from this artifact's SEC_FUNCTIONS gets that same
//     code-offset added to its FuncObj.ip — its own bytecode's jump/loop
//     offsets are all relative (no adjustment needed there, verified against
//     vm.zig's .jump/.loop handling), but ip is an absolute chunk offset.
//   - CONSTANTS need no base-offset math at all: cs.addConst always appends
//     at cs.const_count, whatever that already was — so a spliced artifact's
//     constants simply land after the destination's existing ones, for free.
//   - What DOES still need patching: this artifact's own bytecode encodes
//     const-pool operands (e.g. `constant`, `get_global`) as indices that
//     were valid in ITS OWN 0-based pool at compile time. Once its constants
//     move to a nonzero base in the destination pool, those operands must
//     move by the same amount — the post-constants-loop pass at the bottom
//     does this by decoding only the just-appended code range and patching
//     each const_index_pos in place (chunk_decoder.zig).
//   - SEC_STD_SCRIPT_INFO/line-table reset are meaningless for a splice (the
//     destination chunk already has its own, from its own compile) and are
//     skipped.
//   - SEC_EXPORTS is parsed and returned only for a splice — the caller
//     (module_compile.zig, gbc-spec.md §14.3) builds a ModuleRecord-shaped
//     symbol table from it; a standalone read() has nothing to link against.
fn loadSections(bytes: []const u8, cs: *chunk.State, hs: *heap.State, alloc: std.mem.Allocator, expected_root_source: ?[]const u8, splice: bool) ReadError!LoadResult {
    const parsed = try parseHeaderAndSections(bytes, alloc, expected_root_source);
    const sections = parsed.sections;
    defer alloc.free(sections);
    const body = parsed.body;

    const bytecode_sec = findSection(sections, gbc_writer.SEC_BYTECODE) orelse return error.MissingRequiredSection;
    const constants_sec = findSection(sections, gbc_writer.SEC_CONSTANTS) orelse return error.MissingRequiredSection;
    const functions_sec = findSection(sections, gbc_writer.SEC_FUNCTIONS) orelse return error.MissingRequiredSection;
    const types_sec = findSection(sections, gbc_writer.SEC_TYPES) orelse return error.MissingRequiredSection;

    // BYTECODE: overwrite from 0 (standalone) or append after whatever the
    // destination chunk already holds (splice).
    const code_bytes = body[bytecode_sec.offset..][0..bytecode_sec.length];
    const code_base: usize = if (splice) cs.code_len else 0;
    if (code_base + code_bytes.len > chunk.MaxCode) return error.CodeTooLarge;
    @memcpy(cs.code[code_base..][0..code_bytes.len], code_bytes);
    cs.code_len = code_base + code_bytes.len;
    if (!splice) {
        cs.line_table_count = 0;
        cs.last_emitted_line = 0;
        cs.last_emitted_col = 0xffff;

        // SEC_STD_SCRIPT_INFO: optional, vendor-range section — see its
        // writer-side comment. Absent (older or foreign-produced .gbc) means
        // these stay at chunk.State's own zero defaults, same as before this
        // section existed; buildStdModule's script_function lookup
        // (native/main.zig) then just finds nothing and resolves those std
        // entries to null, exactly the pre-fix behavior, not a hard load
        // failure. Splicing a dependency's own std-script metadata into an
        // importer would be meaningless — the importer compiled its own std
        // prelude already — so this whole block is standalone-only.
        if (findSection(sections, gbc_writer.SEC_STD_SCRIPT_INFO)) |sec| {
            const std_script_bytes = body[sec.offset..][0..sec.length];
            var sr = ByteReader{ .bytes = std_script_bytes };
            cs.std_script_const_base = try sr.u16_();
            cs.std_script_const_count = try sr.u16_();
            cs.std_script_code_end = try sr.u32_();
        } else {
            cs.std_script_const_base = 0;
            cs.std_script_const_count = 0;
            cs.std_script_code_end = 0;
        }
    }

    // Base for remapping this artifact's own bytecode's const-pool operands
    // after splicing (see the pass at the bottom) — captured now, before any
    // of this artifact's constants are added, so it's exactly "how many
    // constants the destination already had."
    const const_base: u32 = @intCast(cs.const_count);

    // FUNCTIONS/TYPES: parsed before CONSTANTS since FUNC_REF/TYPE_REF
    // constants index into them.
    const functions_bytes = body[functions_sec.offset..][0..functions_sec.length];
    var fr = ByteReader{ .bytes = functions_bytes };
    const raw_funcs = try readFunctionsSection(&fr, hs, alloc);
    defer alloc.free(raw_funcs);

    const types_bytes = body[types_sec.offset..][0..types_sec.length];
    var tr = ByteReader{ .bytes = types_bytes };
    const raw_types = try readTypesSection(&tr, cs, hs, alloc);
    defer alloc.free(raw_types);

    // Tracks, per raw_funcs[i], how to re-find its FuncObj through cs.consts
    // (NOT a raw pointer — see the comment after this loop for why holding
    // one across the rest of this loop is unsafe) so names can be resolved
    // in a pass after ALL constants exist.
    const func_patch = try alloc.alloc(?FuncNamePatchTarget, raw_funcs.len);
    defer alloc.free(func_patch);
    @memset(func_patch, null);

    // CONSTANTS.
    const constants_bytes = body[constants_sec.offset..][0..constants_sec.length];
    var cr = ByteReader{ .bytes = constants_bytes };
    const const_count = try cr.u32_();
    if (const_count > chunk.MaxConst) return error.TooManyConstants;
    var ci: u32 = 0;
    while (ci < const_count) : (ci += 1) {
        const tag = try cr.u8_();
        // Set inside CONST_FUNC_REF/a named type's predicate below, consumed
        // right after this constant's addConst() call returns its final,
        // stable index — see FuncNamePatchTarget's doc comment.
        var pending_patch: ?struct { fidx: u32, kind: enum { direct, predicate } } = null;
        const v: Value = switch (tag) {
            gbc_writer.CONST_NUMBER => Value{ .float = try cr.f64_() },
            gbc_writer.CONST_INT => Value{ .int = try cr.i64_() },
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
                const obj = try buildFuncObjFromRaw(hs, raw_funcs[fidx], code_base);
                pending_patch = .{ .fidx = fidx, .kind = .direct };
                break :blk Value{ .object = obj };
            },
            gbc_writer.CONST_TYPE_REF => blk: {
                const tidx = try cr.u32_();
                if (tidx >= raw_types.len) return error.TypeRefOutOfRange;
                const rt = raw_types[tidx];
                const obj = hs.allocObject() orelse return error.OutOfMemory;
                switch (rt.kind) {
                    gbc_writer.TYPE_KIND_STRUCT => {
                        obj.* = .{ .struct_type = .{
                            .name = rt.name,
                            .qualified_name = rt.qualified_name,
                            .fields = rt.fields,
                        } };
                    },
                    gbc_writer.TYPE_KIND_NAMED => {
                        // Predicate: resolve predicate_func_idx (deferred by
                        // readTypesSection, since raw_funcs isn't in scope
                        // there) through the same SEC_FUNCTIONS machinery a
                        // CONST_FUNC_REF constant uses, then wrap in a
                        // zero-upvalue closure — matching what the compiler
                        // itself always produces for a captureless predicate
                        // (compiler_decls.zig's namedTypeDecl/subtypeDecl).
                        var predicate: ?*value_mod.Object = null;
                        if (rt.predicate_func_idx) |pidx| {
                            if (pidx >= raw_funcs.len) return error.FuncRefOutOfRange;
                            const fobj = try buildFuncObjFromRaw(hs, raw_funcs[pidx], code_base);
                            pending_patch = .{ .fidx = pidx, .kind = .predicate };
                            const closure_obj = hs.allocObject() orelse return error.OutOfMemory;
                            closure_obj.* = .{ .closure = .{ .func = fobj, .upvalues = &[_]*value_mod.Object{} } };
                            predicate = closure_obj;
                        }
                        obj.* = .{
                            .named_type = .{
                                .name = rt.name,
                                .qualified_name = rt.qualified_name,
                                .base = rt.base,
                                .is_anonymous = rt.is_anonymous,
                                .has_range = rt.has_range,
                                .is_cycle = rt.is_cycle,
                                .is_clamp = rt.is_clamp,
                                .scale = rt.scale,
                                .min = rt.min,
                                .max = rt.max,
                                // Empty string means "no parent" (matches the
                                // writer, which writes "" for a null
                                // parent_name) — never a real qualified name,
                                // since qualified names are always non-empty.
                                .parent_name = if (rt.parent_name.len == 0) null else rt.parent_name,
                                .elem_spec = rt.elem_spec,
                                .key_spec = rt.key_spec,
                                .val_spec = rt.val_spec,
                                .predicate = predicate,
                                .predicate_msg = rt.predicate_msg,
                                .has_default = rt.has_default,
                                .default_val = rt.default_val,
                            },
                        };
                    },
                    gbc_writer.TYPE_KIND_VARIANT => {
                        obj.* = .{ .variant_type = .{
                            .name = rt.name,
                            .qualified_name = rt.qualified_name,
                            .arms = rt.arms,
                            .shared_fields = rt.shared_fields,
                        } };
                    },
                    gbc_writer.TYPE_KIND_INTERFACE => {
                        obj.* = .{ .interface_type = .{
                            .name = rt.name,
                            .qualified_name = rt.qualified_name,
                            .methods = rt.methods,
                        } };
                    },
                    gbc_writer.TYPE_KIND_ENUM => {
                        obj.* = .{
                            .enum_type = .{
                                .name = rt.name,
                                .qualified_name = rt.qualified_name,
                                .members = rt.members,
                                .member_ints = rt.member_ints,
                                // Empty string means "no parent", same convention
                                // as TYPE_KIND_NAMED above. parent (the resolved
                                // *Object pointer) stays null — resolved lazily
                                // on first use by vm_types.zig's
                                // resolveEnumParent, identical to a normally
                                // compiled enum subtype.
                                .parent_name = if (rt.parent_name.len == 0) null else rt.parent_name,
                            },
                        };
                    },
                    else => return error.MalformedSection,
                }
                break :blk Value{ .object = obj };
            },
            else => return error.BadConstantTag,
        };
        const stored_idx = try cs.addConst(v);
        if (pending_patch) |pp| func_patch[pp.fidx] = switch (pp.kind) {
            .direct => .{ .direct_const = stored_idx },
            .predicate => .{ .predicate_const = stored_idx },
        };
    }

    // Deferred name patching: a FunctionEntry's name_constant_idx can point
    // anywhere in the constant pool, including at a STRING constant that
    // gbc_writer appended AFTER the function's own position (needed for any
    // function whose bare name — e.g. "count" — wasn't already present as an
    // independent string constant; see writeFunctionsSection's comment).
    // Resolving names inline inside the loop above (as buildFuncObjFromRaw
    // used to) can't see those forward references: cs.addConst builds
    // cs.consts incrementally, so mid-loop cs.const_count/cs.consts only
    // reflect what's been added so far, not the final pool. Now that every
    // constant exists, this pass can look any name_constant_idx up
    // unconditionally, regardless of where it landed — and re-finds each
    // FuncObj through cs.consts (via func_patch, never a cached pointer;
    // see FuncNamePatchTarget) so it's the GC-relocated-if-necessary object,
    // not a possibly-stale one.
    for (raw_funcs, 0..) |rf, fi| {
        const target = func_patch[fi] orelse continue;
        if (rf.name_constant_idx == 0xFFFFFFFF or rf.name_constant_idx >= const_count) continue;
        // rf.name_constant_idx is this artifact's own 0-based constant-pool
        // index (as originally written) — same base-offset requirement as
        // every other cross-reference in this artifact's wire data (ip,
        // FUNC_REF/TYPE_REF indices are all resolved before this point;
        // this is the one that's resolved AFTER, in this deferred pass, so
        // it's easy to miss applying const_base to it too — caught by the
        // splice test intentionally checking the *name*, not just that
        // *a* function got called).
        const nv = cs.consts[const_base + rf.name_constant_idx];
        if (nv != .string) continue;
        const fobj: *value_mod.Object = switch (target) {
            .direct_const => |idx| blk: {
                const cv = cs.consts[idx];
                if (cv != .object or cv.object.* != .function) continue;
                break :blk cv.object;
            },
            .predicate_const => |idx| blk: {
                const cv = cs.consts[idx];
                if (cv != .object or cv.object.* != .named_type) continue;
                const pred = cv.object.named_type.predicate orelse continue;
                if (pred.* != .closure) continue;
                break :blk pred.closure.func;
            },
        };
        fobj.function.name = nv.string.bytes;
    }

    // Remap this artifact's own just-appended bytecode's const-pool
    // operands by const_base — see loadSections' doc comment for why this
    // is the one piece of bytecode that genuinely needs patching (jump/loop
    // targets are self-relative and need none). Skipped for a standalone
    // read() (const_base is always 0 there — cs is always freshly .reset()
    // — so it would be a no-op walk over the whole program on every load).
    if (splice) {
        var pos: usize = code_base;
        while (pos < cs.code_len) {
            const decoded = chunk_decoder.decodeAt(cs, pos) catch return error.MalformedSection;
            if (decoded.const_index_pos) |cip| {
                const old_idx = (@as(u32, cs.code[cip]) << 8) | @as(u32, cs.code[cip + 1]);
                const new_idx = old_idx + const_base;
                if (new_idx > 0xFFFF) return error.TooManyConstants;
                cs.code[cip] = @intCast((new_idx >> 8) & 0xFF);
                cs.code[cip + 1] = @intCast(new_idx & 0xFF);
            }
            if (decoded.width == 0) return error.MalformedSection;
            pos += decoded.width;
        }
    }

    cs.verified = false;
    cs.verified_code_len = 0;

    var exports: ?RawExportsSection = null;
    if (splice) {
        const exports_sec = findSection(sections, gbc_writer.SEC_EXPORTS) orelse return error.MissingRequiredSection;
        exports = try readExportsSection(body[exports_sec.offset..][0..exports_sec.length], alloc);
    }
    return .{ .exports = exports };
}

pub fn read(bytes: []const u8, cs: *chunk.State, hs: *heap.State, alloc: std.mem.Allocator, expected_root_source: ?[]const u8) ReadError!void {
    _ = try loadSections(bytes, cs, hs, alloc, expected_root_source, false);
}

// Loads a precompiled .gbc MODULE artifact by appending its constants,
// functions, types, and bytecode onto whatever `cs` already holds (rather
// than replacing it, as read() does) — gbc-spec.md §14's single-level
// linking. `cs`/`hs` must be the SAME chunk/heap state the importing
// compile is already writing into (module_compile.Session's own cs/hs),
// not a fresh pair — this is a splice into an in-progress compile, not a
// standalone load. Returns the artifact's own SEC_EXPORTS data (module_id +
// per-export name/qualified_name/type_kind/const_value) for the caller to
// build a ModuleRecord-shaped symbol table from (module_compile.zig,
// §14.3) — no live Compiler for the dependency is ever constructed.
pub fn readIntoSession(bytes: []const u8, cs: *chunk.State, hs: *heap.State, alloc: std.mem.Allocator, expected_root_source: ?[]const u8) ReadError!RawExportsSection {
    const result = try loadSections(bytes, cs, hs, alloc, expected_root_source, true);
    return result.exports.?;
}

const testing = std.testing;

fn testHeap() !heap.State {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    return h;
}

// alt_count=0 used to build an empty FieldTypeAlt slice — nothing
// downstream expects that (fieldTypeSpecStr unconditionally indexes
// alts[0] once a type mismatch needs formatting), so it's rejected outright
// rather than allowed through to crash later.
test "gbc: readTypeSpec rejects alt_count == 0" {
    var h = try testHeap();
    defer h.deinit();
    var r = ByteReader{ .bytes = &.{0} };
    try testing.expectError(error.MalformedSection, readTypeSpec(&r, &h, testing.allocator));
}

test "gbc: readTypeSpec accepts a simple scalar spec" {
    var h = try testHeap();
    defer h.deinit();
    var r = ByteReader{ .bytes = &.{ 1, gbc_writer.FT_INT } };
    const spec = try readTypeSpec(&r, &h, testing.allocator);
    try testing.expectEqual(@as(usize, 1), spec.alts.len);
    try testing.expectEqual(value_mod.FieldTypeTag.int, spec.alts[0].typ);
}

// A crafted FT_ARRAY/FT_MAP chain recurses arbitrarily deep with no other
// bound on file size (each level costs as little as 3 bytes) — unbounded
// recursion isn't a catchable Zig error, it's a native stack overflow.
test "gbc: readTypeSpec rejects excessive FT_ARRAY nesting depth" {
    var h = try testHeap();
    defer h.deinit();
    var bytes: [3 * (MaxTypeSpecDepth + 4)]u8 = undefined;
    var pos: usize = 0;
    var depth: u32 = 0;
    while (depth < MaxTypeSpecDepth + 2) : (depth += 1) {
        bytes[pos] = 1; // alt_count
        bytes[pos + 1] = gbc_writer.FT_ARRAY;
        bytes[pos + 2] = 1; // has_elem
        pos += 3;
    }
    // Innermost: a real scalar so a within-bound depth would parse cleanly.
    bytes[pos] = 1;
    bytes[pos + 1] = gbc_writer.FT_INT;
    pos += 2;
    var r = ByteReader{ .bytes = bytes[0..pos] };
    try testing.expectError(error.MalformedSection, readTypeSpec(&r, &h, testing.allocator));
}

test "gbc: readTypeSpec accepts nesting within the depth limit" {
    var h = try testHeap();
    defer h.deinit();
    var bytes: [3 * 10 + 2]u8 = undefined;
    var pos: usize = 0;
    var depth: u32 = 0;
    while (depth < 10) : (depth += 1) {
        bytes[pos] = 1;
        bytes[pos + 1] = gbc_writer.FT_ARRAY;
        bytes[pos + 2] = 1;
        pos += 3;
    }
    bytes[pos] = 1;
    bytes[pos + 1] = gbc_writer.FT_INT;
    pos += 2;
    var r = ByteReader{ .bytes = bytes[0..pos] };
    const spec = try readTypeSpec(&r, &h, testing.allocator);
    try testing.expectEqual(value_mod.FieldTypeTag.array, spec.alts[0].typ);
}

// A crafted FUNCTIONS entry could previously set arity/param_type_count
// independently (e.g. arity=5, param_type_count=0) — vm_types.zig's
// canInlinePrimitiveArgs/enforceFuncArgTypes index param_types[0..fixed]
// assuming they're consistent, so the mismatch caused an unconditional
// out-of-bounds panic the moment the function was called.
test "gbc: validateArityShape rejects a param_type_count/arity mismatch" {
    try testing.expectError(error.MalformedSection, validateArityShape(5, false, true, 0));
    try testing.expectError(error.MalformedSection, validateArityShape(5, false, true, 4));
    try testing.expectError(error.MalformedSection, validateArityShape(5, false, true, 6));
    try testing.expect(std.meta.isError(validateArityShape(5, false, true, 0)));
}

test "gbc: validateArityShape accepts the exact expected shape" {
    try validateArityShape(5, false, true, 5);
    try validateArityShape(3, true, true, 2); // variadic: fixed = arity - 1
    try validateArityShape(0, false, false, 0); // has_typed_params=false: no shape required
    try validateArityShape(0, false, false, 999); // ditto — untyped, count is unchecked
}

// is_variadic with arity==0 would separately underflow enforceFuncArgTypes's
// `arity - 1` (a real compile never produces this: a variadic function's
// own variadic parameter always contributes at least 1 to arity).
test "gbc: validateArityShape rejects is_variadic with arity == 0" {
    try testing.expectError(error.MalformedSection, validateArityShape(0, true, false, 0));
    try testing.expectError(error.MalformedSection, validateArityShape(0, true, true, 0));
}

// A file-controlled length that would make pos+n overflow/wrap (rather than
// cleanly fail) must instead subtract to compare, so it can never wrap.
test "gbc: ByteReader.need rejects a length claim exceeding the buffer without overflowing" {
    var r = ByteReader{ .bytes = "abc", .pos = 1 };
    try testing.expectError(error.TruncatedBody, r.need(std.math.maxInt(usize)));
    try r.need(2); // "bc" remains — must still succeed
    try testing.expectError(error.TruncatedBody, r.need(3));
}

// A crafted FUNCTIONS entry with named_return_count > 64 must be rejected
// before the entry reaches the VM, where three [64]Value spread buffers would
// OOB if indexed by the raw u8 value.
test "gbc: readFunctionsSection rejects named_return_count > 64" {
    var h = try testHeap();
    defer h.deinit();
    // Use an arena so the RawFuncEntry slice allocated before the error fires
    // is freed without triggering testing.allocator's leak detection.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = [_]u8{
        // count = 1 (u32 LE)
        0x01, 0x00, 0x00, 0x00,
        // name_constant_idx = 0xFFFFFFFF (u32 LE)
        0xFF, 0xFF, 0xFF, 0xFF,
        // ip = 0 (u32 LE)
        0x00, 0x00, 0x00, 0x00,
        // length = 0 (u32 LE)
        0x00, 0x00, 0x00, 0x00,
        // local_count = 0 (u16 LE)
        0x00, 0x00,
        // arity = 0
        0x00,
        // is_variadic = false
        0x00,
        // has_typed_params = false
        0x00,
        // has_typed_returns = false
        0x00,
        // named_return_count = 65 — exceeds the VM's [64]Value spread buffer
        65,
    };
    var r = ByteReader{ .bytes = &bytes };
    try testing.expectError(error.MalformedSection, readFunctionsSection(&r, &h, arena.allocator()));
}
