const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const Compiler = @import("compiler.zig").Compiler;
const CompilerOptions = @import("compiler.zig").CompilerOptions;
const ct = @import("compiler_types.zig");
pub const ExportTypeKind = ct.ExportTypeKind;
const Lexer = @import("lexer.zig").Lexer;
const TT = @import("token.zig").TT;
const cfg = @import("runtime_config");
const globals = @import("globals.zig");
const source_io = @import("../runtime/source_io.zig");
const build_options = @import("build_options");
const module_descriptor = @import("module_descriptor.zig");
const CompileTimeConst = ct.CompileTimeConst;
const gbc_reader = @import("gbc_reader.zig");

pub const MaxModules = 64;
pub const MaxImportsPerModule = 64;
pub const MaxModulePathBytes = 256;
pub const StdModulePath = "std";
pub const StdModuleGlobalName = "module:std";

pub const SourceEntry = struct {
    path: []const u8,
    source: []const u8,
};

pub const SourceCallback = struct {
    ctx: *anyopaque,
    load: *const fn (ctx: *anyopaque, path: []const u8) anyerror!?[]const u8,
};

pub const SourceProvider = union(enum) {
    filesystem,
    table: []const SourceEntry,
    callback: SourceCallback,
};

const ModuleState = enum {
    loading,
    compiled,
    failed,
};

const MaxModuleExports = ct.MaxModuleExports;

const ModuleRecord = struct {
    path_len: usize = 0,
    path_buf: [MaxModulePathBytes]u8 = undefined,
    global_name: []const u8 = "",
    prefix: []const u8 = "",
    struct_name: []const u8 = "",
    // Set only for a linked GBC module (linkGbcModule) — the artifact's own
    // SEC_EXPORTS.module_id, which global_name/prefix/struct_name are
    // derived from (gbc-spec.md §14.3). findModule() matches on EITHER
    // .path() (the importer's local resolved specifier, e.g. "mathlib.gbc"
    // — used by beginImportedModule's dedup/cycle-check and by
    // resolveImportOpaque's own final moduleGlobalName lookup, both of
    // which only ever have the local specifier on hand) OR this field (the
    // artifact's own identity — used by the compiler's later has_module_
    // export/resolve_module_type calls, which reach this record via
    // import_module_path: derived by stripping "@mod:" off whatever
    // global_name resolveImportOpaque returned, i.e. always module_id for
    // a linked module, never the local specifier). Empty (never matches)
    // for an ordinary source-compiled module, where local path and
    // "@mod:"-stripped global_name always coincide already.
    link_module_id: []const u8 = "",
    state: ModuleState = .loading,
    export_names: [MaxModuleExports][]const u8 = undefined,
    export_type_kinds: [MaxModuleExports]ExportTypeKind = undefined,
    export_const_values: [MaxModuleExports]?CompileTimeConst = [_]?CompileTimeConst{null} ** MaxModuleExports,
    export_count: u16 = 0,

    // Saved error info when compilation fails (state == .failed)
    failure_msg_buf: [512]u8 = undefined,
    failure_msg_len: u16 = 0,
    failure_line: u32 = 0,
    failure_col: u32 = 0,
    failure_path_buf: [MaxModulePathBytes]u8 = undefined,
    failure_path_len: usize = 0,

    fn path(self: *const ModuleRecord) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub const HostModuleEntry = struct {
    name: []const u8,
};

pub const HostModuleFuncDesc = struct {
    name: []const u8,
    arity: u8,
    call_id: u16,
};

pub const HostModuleDesc = struct {
    name: []const u8,
    functions: []const HostModuleFuncDesc,
};

pub const CapModuleFuncDesc = struct {
    name: []const u8,
    arity: u8,
    native_id: u16,
};

pub const CapModuleDesc = struct {
    name: []const u8,
    functions: []const CapModuleFuncDesc,
};

pub const cap_net_desc: CapModuleDesc = .{
    .name = "net",
    .functions = &.{
        .{ .name = "dial", .arity = 2, .native_id = 163 },
        .{ .name = "dial_tls", .arity = 2, .native_id = 262 },
        .{ .name = "listen", .arity = 2, .native_id = 235 },
    },
};

pub const cap_fs_desc: CapModuleDesc = .{
    .name = "fs",
    .functions = &.{
        .{ .name = "read", .arity = 1, .native_id = 161 },
        .{ .name = "exists", .arity = 1, .native_id = 162 },
        .{ .name = "write", .arity = 2, .native_id = 188 },
        .{ .name = "list", .arity = 1, .native_id = 189 },
        .{ .name = "delete", .arity = 1, .native_id = 190 },
        .{ .name = "mkdir", .arity = 1, .native_id = 191 },
    },
};

pub const cap_http_desc: CapModuleDesc = .{
    .name = "http",
    .functions = &.{
        .{ .name = "get", .arity = 1, .native_id = 185 },
        .{ .name = "post", .arity = 2, .native_id = 186 },
        .{ .name = "fetch", .arity = 2, .native_id = 187 },
    },
};

pub const cap_env_desc: CapModuleDesc = .{
    .name = "env",
    .functions = &.{
        .{ .name = "get", .arity = 1, .native_id = 233 },
        .{ .name = "list", .arity = 0, .native_id = 234 },
    },
};

// cap:ffi is a native-CLI-only capability: it dlopens arbitrary shared
// libraries and calls into them through hand-rolled SysV trampolines
// (x86_64/aarch64). build_options.cap_ffi is only ever true in the native
// CLI build (see build.zig native_cli_opts); every other artifact gets the
// capability compiled out entirely.
pub const cap_ffi_desc: CapModuleDesc = .{
    .name = "ffi",
    .functions = &.{
        .{ .name = "load", .arity = 1, .native_id = 264 },
    },
};

const _cap_storage = blk: {
    var caps: [MaxCapabilities]CapModuleDesc = undefined;
    var i: usize = 0;
    if (build_options.cap_net) {
        caps[i] = cap_net_desc;
        i += 1;
    }
    if (build_options.cap_fs) {
        caps[i] = cap_fs_desc;
        i += 1;
    }
    if (build_options.cap_http) {
        caps[i] = cap_http_desc;
        i += 1;
    }
    if (build_options.cap_env) {
        caps[i] = cap_env_desc;
        i += 1;
    }
    if (build_options.cap_ffi) {
        caps[i] = cap_ffi_desc;
        i += 1;
    }
    break :blk caps;
};
const _cap_count: usize = @as(usize, @intFromBool(build_options.cap_net)) + @as(usize, @intFromBool(build_options.cap_fs)) + @as(usize, @intFromBool(build_options.cap_http)) + @as(usize, @intFromBool(build_options.cap_env)) + @as(usize, @intFromBool(build_options.cap_ffi));
pub const AllCapabilities = _cap_storage[0.._cap_count];

pub const MaxCapabilities = 64;
pub const MaxModuleRoots = 8;

pub const Session = struct {
    // Explicit heap handle (A1): all session allocation goes through this,
    // never through heap's threadlocal-active wrappers. Set by
    // Runtime.initCompileSession / test harnesses right after construction.
    hs: *heap.State = undefined,
    cs: *chunk.State = undefined,
    // modules is a slice allocated from _modules_arena by initArena().
    // Default is an empty slice; only populated after initArena() is called.
    modules: []ModuleRecord = &.{},
    _modules_arena: std.heap.ArenaAllocator = undefined,
    module_count: usize = 0,
    source_buf: [cfg.max_input_bytes]u8 = undefined,
    last_error_path: []const u8 = "",
    last_error_line: u32 = 0,
    last_error_col: u32 = 0,
    last_error_msg_buf: [512]u8 = undefined,
    last_error_msg_len: u16 = 0,
    provider: SourceProvider = .filesystem,
    // Import sandbox: source_root restricts file imports to one directory tree;
    // module_roots lists additional allowed trees (e.g. shared library directories).
    // Empty source_root = unrestricted (default for embedding; CLI always sets it).
    source_root: []const u8 = "",
    module_roots_buf: [MaxModuleRoots][]const u8 = undefined,
    module_roots_count: u8 = 0,
    host_module_names: []const []const u8 = &.{},
    host_module_descs: []const HostModuleDesc = &.{},
    enabled_capabilities: []const []const u8 = &.{},
    capability_modules: []const CapModuleDesc = &.{},
    known_globals: ?[*][]const u8 = null,
    known_global_count: u16 = 0,
    test_mode: bool = false,
    // Set by compileModuleRoot: a linkable module artifact must itself have
    // zero LINKED_ARTIFACT dependencies (gbc-spec.md §14.1's single-level
    // bound, enforced at write time so a loader never needs to recursively
    // load a .gbc found while loading another .gbc). compileRoot (ordinary
    // script/entry compiles) leaves this false — an executable script may
    // freely link .gbc module dependencies; only a module artifact being
    // produced for others to link against may not itself link one.
    reject_linked_deps: bool = false,
    test_count: u16 = 0,
    test_names: [ct.MaxTestBlocks][]const u8 = undefined,

    /// Allocate the modules slice from the embedded arena and zero-initialize
    /// each ModuleRecord.  Must be called once after construction.
    pub fn initArena(self: *Session) !void {
        self._modules_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const alloc = self._modules_arena.allocator();
        self.modules = try alloc.alloc(ModuleRecord, MaxModules);
        for (self.modules) |*m| m.* = .{};
    }

    /// Free the modules arena.  Call before destroying the Session.
    pub fn deinitArena(self: *Session) void {
        if (self.modules.len > 0) {
            self._modules_arena.deinit();
            self.modules = &.{};
        }
    }

    fn copyCompilerError(self: *Session, compiler: *Compiler) void {
        self.last_error_col = compiler.err_col;
        if (compiler.err_msg_len > 0) {
            @memcpy(self.last_error_msg_buf[0..compiler.err_msg_len], compiler.err_msg_buf[0..compiler.err_msg_len]);
            self.last_error_msg_len = compiler.err_msg_len;
        }
    }

    fn setScanError(self: *Session, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.last_error_msg_buf, fmt, args) catch return;
        self.last_error_msg_len = @intCast(s.len);
    }

    fn copyTestNamesFromCompiler(self: *Session, compiler: *const Compiler) void {
        self.test_count = compiler.test_count;
        @memcpy(self.test_names[0..compiler.test_count], compiler.test_names[0..compiler.test_count]);
    }

    fn isCapabilityEnabled(self: *Session, name: []const u8) bool {
        for (self.enabled_capabilities) |cap| {
            // A scoped grant ("net.listen") also satisfies the bare import
            // gate for "net" — only the per-function dispatch check cares
            // which scope was actually granted (see net_state's scope gate).
            const is_scoped_grant = cap.len > name.len and
                std.mem.startsWith(u8, cap, name) and cap[name.len] == '.';
            if (common.streq(cap, name) or is_scoped_grant) {
                for (self.capability_modules) |cm| {
                    if (common.streq(cm.name, name)) return true;
                }
                return false;
            }
        }
        return false;
    }

    // Contract: the caller resets the chunk state before invoking (the runtime
    // does so via Runtime.reset()). compileRoot must not reset it itself — the
    // chunk may already hold the compiled std-script prelude
    // (Runtime.compileStdScripts), which a reset here would silently discard.
    pub fn compileRoot(self: *Session, root_path: []const u8, src: []const u8) !void {
        self.module_count = 0;
        self.last_error_path = "";
        self.last_error_line = 0;
        self.last_error_col = 0;
        self.last_error_msg_len = 0;
        const idx = try self.beginModule(root_path, true);
        errdefer self.module_count = idx;

        try self.compileDependencies(root_path, src);
        try self.compileBegunModule(idx, src, true);
    }

    // Compiles `src` as a standalone linkable module artifact (GBC v2 §14),
    // not as a runnable script — used by --emit-gbc-module. Differs from
    // compileRoot in exactly the two ways a module artifact's own compile
    // must: beginModule(path, false) assigns it the same "@mod:<path>"/
    // "@module_type:<path>" global-name/prefix/struct-name scheme an
    // ordinary *imported* module gets (never the un-prefixed root scheme),
    // so its own compiled globals are already namespaced and collision-safe
    // before any importer ever links against it (gbc-spec.md §14.3 — that
    // identity can't be renamed post-hoc on load); and compileBegunModule's
    // emit_halt=false means no trailing `halt` opcode gets baked into the
    // bytecode a future importer will splice at a non-final position
    // (§14.4). `path` becomes this artifact's SEC_EXPORTS.module_id (§8.5)
    // — the caller (gbc_writer via WriteOptions.module_id) must pass this
    // same string back, since it's already what's baked into this compile's
    // own global names.
    pub fn compileModuleRoot(self: *Session, path: []const u8, src: []const u8) !void {
        self.module_count = 0;
        self.last_error_path = "";
        self.last_error_line = 0;
        self.last_error_col = 0;
        self.last_error_msg_len = 0;
        self.reject_linked_deps = true;
        const idx = try self.beginModule(path, false);
        errdefer self.module_count = idx;

        try self.compileDependencies(path, src);
        try self.compileBegunModule(idx, src, false);
    }

    fn isHostModule(self: *Session, name: []const u8) bool {
        for (self.host_module_names) |hm| {
            if (common.streq(hm, name)) return true;
        }
        return false;
    }

    pub fn resolveImportOpaque(ctx: *anyopaque, importer_path: []const u8, import_name: []const u8) anyerror![]const u8 {
        const self: *Session = @ptrCast(@alignCast(ctx));
        // Capability imports: cap:<name>
        if (import_name.len > 4 and std.mem.startsWith(u8, import_name, "cap:")) {
            const cap_name = import_name[4..];
            if (self.isCapabilityEnabled(cap_name)) {
                return try self.makePrefixedName("cap:", cap_name);
            }
            return error.CapabilityNotEnabled;
        }
        if (import_name.len > 5 and std.mem.startsWith(u8, import_name, "host:")) {
            const host_name = import_name[5..];
            if (self.isHostModule(host_name)) {
                return try self.makePrefixedName("host:", host_name);
            }
            return error.ImportNotFound;
        }
        const resolved = try self.resolveImportPath(importer_path, import_name);
        if (common.streq(resolved, StdModulePath)) return StdModuleGlobalName;
        try self.compileModuleFromPath(resolved);
        return self.moduleGlobalName(resolved) orelse return error.ImportNotFound;
    }

    fn compileModuleFromPath(self: *Session, path: []const u8) anyerror!void {
        // gbc-spec.md §14.2: an import resolves to a precompiled artifact
        // only when the specifier names one explicitly — resolveImportPath
        // never appends a ".gbc" suffix on its own (only ".gengo"/
        // "/mod.gengo"), so reaching here with a ".gbc"-suffixed path only
        // ever happens when the source specifier said so itself.
        if (std.mem.endsWith(u8, path, ".gbc")) {
            if (self.reject_linked_deps) {
                self.last_error_path = path;
                self.setScanError("a linkable GBC module artifact cannot itself import a .gbc ('{s}') — linking is single-level only (gbc-spec.md §14.1)", .{path});
                return error.ChainedGbcLinkingNotSupported;
            }
            return self.linkGbcModule(path);
        }
        const idx = (try self.beginImportedModule(path)) orelse return;
        const src = try self.loadImportedModuleSource(idx);
        try self.compileImportedModule(idx, src);
    }

    // Splices a precompiled GBC module artifact into this session's shared
    // chunk (gbc_reader.readIntoSession, gbc-spec.md §14) instead of
    // recompiling it from source — the single-hop linking path. Reuses
    // beginImportedModule for slot allocation/cycle detection (identical to
    // an ordinary source import) and loadImportedModuleSource to read the
    // artifact's raw bytes (it's a plain byte read with no source-specific
    // handling, so it works unmodified for a binary .gbc payload too).
    fn linkGbcModule(self: *Session, path: []const u8) anyerror!void {
        const idx = (try self.beginImportedModule(path)) orelse return;
        const bytes = self.loadImportedModuleSource(idx) catch |err| {
            self.saveFailedModule(idx);
            return err;
        };
        const raw_exports = gbc_reader.readIntoSession(bytes, self.cs, self.hs, self._modules_arena.allocator(), null) catch |err| {
            self.last_error_path = self.modules[idx].path();
            self.setScanError("failed to link GBC module '{s}': {s}", .{ self.modules[idx].path(), @errorName(err) });
            self.saveFailedModule(idx);
            return err;
        };

        if (raw_exports.exports.len > ct.MaxModuleExports) {
            self.last_error_path = self.modules[idx].path();
            self.setScanError("GBC module '{s}' declares too many exports (max {d})", .{ raw_exports.module_id, ct.MaxModuleExports });
            self.saveFailedModule(idx);
            return error.TooManyGlobals;
        }

        // Module identity travels with the artifact itself, not the
        // importer's local specifier (gbc-spec.md §14.3) — the artifact's
        // own bytecode already has "@mod:<module_id>."-qualified global
        // names baked in from its own compile time, so this session's
        // record of it must expose those, not beginImportedModule's default
        // "@mod:<local-path>" scheme.
        //
        // .path() itself (the local resolved specifier, e.g. "mathlib.gbc")
        // stays as beginImportedModule set it — two OTHER things still need
        // it unchanged: beginImportedModule's own dedup on a second import
        // of the same specifier, and resolveImportOpaque's final
        // moduleGlobalName(resolved) lookup, where `resolved` is always the
        // local specifier (fixed before this function is even called).
        // Both run again in the ordinary course of one compile — every
        // import is resolved once during compileDependencies' pre-pass and
        // again when the live compiler reaches the import(...) expression
        // itself — so findModule must still succeed on the local specifier
        // the second time too, not just the first.
        //
        // But the compiler's LATER has_module_export/resolve_module_type
        // calls (compiler_expr.zig's importExpr, compiler.zig's
        // import_module_path) reach this record differently: they strip
        // "@mod:" off whatever global_name resolveImportOpaque returned and
        // use THAT — always module_id here, never the local specifier — as
        // their own findModule key. Recording module_id as a second,
        // independent lookup key (link_module_id, checked by findModule
        // alongside .path()) satisfies both call patterns without either
        // one breaking the other.
        if (raw_exports.module_id.len > MaxModulePathBytes) {
            self.last_error_path = self.modules[idx].path();
            self.setScanError("GBC module_id '{s}' exceeds the {d}-byte path limit", .{ raw_exports.module_id, MaxModulePathBytes });
            self.saveFailedModule(idx);
            return error.ImportPathTooLong;
        }
        // No copy needed: raw_exports (from readIntoSession, called with
        // self._modules_arena.allocator() below) is already owned by this
        // Session's own arena, which outlives self.modules[] identically.
        self.modules[idx].link_module_id = raw_exports.module_id;

        const global_name = try self.makePrefixedName("@mod:", raw_exports.module_id);
        self.modules[idx].global_name = global_name;
        self.modules[idx].prefix = global_name;
        self.modules[idx].struct_name = try self.makePrefixedName("@module_type:", raw_exports.module_id);

        self.modules[idx].export_count = @intCast(raw_exports.exports.len);
        for (raw_exports.exports, 0..) |e, i| {
            self.modules[idx].export_names[i] = e.name;
            self.modules[idx].export_type_kinds[i] = @enumFromInt(e.type_kind);
            self.modules[idx].export_const_values[i] = switch (e.const_value) {
                .none => null,
                .number => |n| .{ .number = n },
                .string => |s| .{ .string = s },
                .boolean => |b| .{ .boolean = b },
            };
        }
        self.modules[idx].state = .compiled;
    }

    fn saveFailedModule(self: *Session, idx: usize) void {
        self.modules[idx].state = .failed;
        self.modules[idx].failure_msg_len = self.last_error_msg_len;
        @memcpy(self.modules[idx].failure_msg_buf[0..self.last_error_msg_len], self.last_error_msg_buf[0..self.last_error_msg_len]);
        self.modules[idx].failure_line = self.last_error_line;
        self.modules[idx].failure_col = self.last_error_col;
        const path_len = @min(self.last_error_path.len, self.modules[idx].failure_path_buf.len);
        self.modules[idx].failure_path_len = path_len;
        @memcpy(self.modules[idx].failure_path_buf[0..path_len], self.last_error_path[0..path_len]);
    }

    fn restoreFailedModule(self: *Session, idx: usize) void {
        self.last_error_msg_len = self.modules[idx].failure_msg_len;
        @memcpy(self.last_error_msg_buf[0..self.modules[idx].failure_msg_len], self.modules[idx].failure_msg_buf[0..self.modules[idx].failure_msg_len]);
        self.last_error_line = self.modules[idx].failure_line;
        self.last_error_col = self.modules[idx].failure_col;
        self.last_error_path = self.modules[idx].failure_path_buf[0..self.modules[idx].failure_path_len];
    }

    fn beginImportedModule(self: *Session, path: []const u8) anyerror!?usize {
        if (self.findModule(path)) |idx| {
            if (self.modules[idx].state == .failed) {
                self.restoreFailedModule(idx);
                return error.ImportCycle;
            }
            if (self.modules[idx].state == .loading) {
                self.last_error_path = self.modules[idx].path();
                return error.ImportCycle;
            }
            return null;
        }

        return try self.beginModule(path, false);
    }

    fn loadImportedModuleSource(self: *Session, idx: usize) ![]const u8 {
        const path = self.modules[idx].path();
        const src_raw = self.loadSource(path) catch |err| {
            self.saveFailedModule(idx);
            return err;
        };
        // Copy source to the bump heap so that recursive loadSource calls
        // (which reuse source_buf) do not overwrite it before we compile this module.
        const src_copy = self.hs.bump(u8, src_raw.len) orelse {
            self.saveFailedModule(idx);
            return error.OutOfMemory;
        };
        @memcpy(src_copy[0..src_raw.len], src_raw);
        return src_copy[0..src_raw.len];
    }

    fn compileImportedModule(self: *Session, idx: usize, src: []const u8) anyerror!void {
        const path = self.modules[idx].path();
        self.compileDependencies(path, src) catch |err| {
            self.saveFailedModule(idx);
            return err;
        };
        self.compileBegunModule(idx, src, false) catch |err| {
            self.saveFailedModule(idx);
            return err;
        };
    }

    fn registerGlobalName(self: *Session, name: []const u8, prefix: []const u8) !void {
        if (name.len > 0 and name[0] == '_') return;
        const qname = if (prefix.len > 0) blk: {
            const total = prefix.len + 1 + name.len;
            const buf = self.hs.bump(u8, total) orelse return error.OutOfMemory;
            @memcpy(buf[0..prefix.len], prefix);
            buf[prefix.len] = '.';
            @memcpy(buf[prefix.len + 1 .. total], name);
            break :blk buf[0..total];
        } else name;
        if (self.known_global_count >= chunk.MaxConst) {
            self.setScanError("too many global declarations (max {d})", .{chunk.MaxConst});
            return error.TooManyGlobals;
        }
        const copy = self.hs.bump(u8, qname.len) orelse return error.OutOfMemory;
        @memcpy(copy[0..qname.len], qname);
        self.known_globals.?[self.known_global_count] = copy[0..qname.len];
        self.known_global_count += 1;
    }

    fn scanGlobalDeclarations(self: *Session, src: []const u8, prefix: []const u8) !void {
        self.known_global_count = 0;
        if (self.known_globals == null) {
            self.known_globals = self.hs.bump([]const u8, chunk.MaxConst) orelse return error.OutOfMemory;
        }
        var lex: Lexer = .{ .src = src };
        var brace_depth: u32 = 0;
        while (true) {
            const tok = lex.next();
            switch (tok.typ) {
                .eof => break,
                .lbrace => brace_depth += 1,
                .rbrace => {
                    if (brace_depth > 0) brace_depth -= 1;
                },
                .kw_func => {
                    if (brace_depth > 0) continue;
                    const name_tok = lex.next();
                    if (name_tok.typ != .ident) continue;
                    var peek = lex;
                    const after_name = peek.next();
                    if (after_name.typ == .lparen) {
                        try self.registerGlobalName(name_tok.src, prefix);
                    } else if (after_name.typ == .lbracket) {
                        // Generic function: func name[T, U]( — skip past [...]
                        var depth: i32 = 1;
                        while (depth > 0) {
                            const t = peek.next();
                            if (t.typ == .lbracket) depth += 1 else if (t.typ == .rbracket) depth -= 1 else if (t.typ == .eof) break;
                        }
                        if (peek.next().typ == .lparen) {
                            try self.registerGlobalName(name_tok.src, prefix);
                        }
                    }
                },
                .kw_const, .kw_var => {
                    if (brace_depth > 0) continue;
                    const name_tok = lex.next();
                    if (name_tok.typ == .ident) {
                        try self.registerGlobalName(name_tok.src, prefix);
                    }
                },
                .kw_type, .kw_subtype => {
                    if (brace_depth > 0) continue;
                    const name_tok = lex.next();
                    if (name_tok.typ == .ident) {
                        try self.registerGlobalName(name_tok.src, prefix);
                    }
                },
                .ident => {
                    if (brace_depth > 0) continue;
                    var peek = lex;
                    const next1 = peek.next();
                    if (next1.typ == .colon_eq) {
                        lex = peek;
                        try self.registerGlobalName(tok.src, prefix);
                    } else if (next1.typ != .eq and next1.typ != .lparen and next1.typ != .dot) {
                        if (next1.typ == .lbracket and (tok.col + tok.src.len == next1.col)) continue;
                        var depth: i32 = 0;
                        while (true) {
                            const t = peek.next();
                            switch (t.typ) {
                                .lparen, .lbracket => depth += 1,
                                .rparen, .rbracket => {
                                    depth -= 1;
                                    if (depth < 0) break;
                                },
                                .eq, .colon_eq => {
                                    if (depth == 0) try self.registerGlobalName(tok.src, prefix);
                                    break;
                                },
                                .lbrace, .semicolon, .eof => break,
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn compileBegunModule(self: *Session, idx: usize, src: []const u8, emit_halt: bool) anyerror!void {
        self.scanGlobalDeclarations(src, self.modules[idx].prefix) catch |err| {
            self.last_error_path = self.modules[idx].path();
            return err;
        };
        var compiler = try Compiler.init(src, self.cs, self.hs, .{
            .module_path = self.modules[idx].path(),
            .module_prefix = self.modules[idx].prefix,
            .module_struct_name = self.modules[idx].struct_name,
            .module_global_name = self.modules[idx].global_name,
            .module_ctx = self,
            .resolve_import = resolveImportOpaque,
            .has_module_export = hasModuleExport,
            .resolve_module_type = resolveModuleTypeKind,
            .resolve_module_constant = resolveModuleConstant,
            .check_global_exists = checkGlobalExistsInSession,
            .check_global_ctx = self,
            .test_mode = if (emit_halt) self.test_mode else false,
        });
        defer compiler.deinit();
        compiler.cs.addModuleBoundary(self.modules[idx].path());
        compiler.compile(false) catch |err| {
            self.last_error_path = self.modules[idx].path();
            self.last_error_line = if (compiler.err_line != 0) compiler.err_line else compiler.prev.line;
            self.copyCompilerError(&compiler);
            if (self.last_error_msg_len == 0) {
                const mod_path = self.modules[idx].path();
                switch (err) {
                    error.ChunkFull => self.setScanError(
                        "compilation unit '{s}' exceeded {d}-byte bytecode limit; split into smaller files",
                        .{ mod_path, chunk.MaxCode },
                    ),
                    error.TooManyConstants => self.setScanError(
                        "compilation unit '{s}' exceeded {d}-constant limit; split into smaller files",
                        .{ mod_path, chunk.MaxConst },
                    ),
                    error.ImportNotFound => self.setScanError(
                        "import not found; checked directory relative to '{s}'",
                        .{mod_path},
                    ),
                    error.UnsupportedImportModule => self.setScanError(
                        "import paths must start with '.', 'cap:', or 'host:'; got '{s}'",
                        .{mod_path},
                    ),
                    else => {},
                }
            }
            return err;
        };
        if (emit_halt and self.test_mode) {
            self.copyTestNamesFromCompiler(&compiler);
        }
        self.modules[idx].export_count = compiler.export_count;
        for (
            self.modules[idx].export_names[0..compiler.export_count],
            self.modules[idx].export_type_kinds[0..compiler.export_count],
            compiler.exports[0..compiler.export_count],
            0..compiler.export_count,
        ) |*n, *k, e, export_index| {
            n.* = e.name;
            self.modules[idx].export_const_values[export_index] = compiler.getCompileTimeConst(e.name);
            if (compiler.registry.hasStructType(e.name)) {
                k.* = .struct_t;
            } else if (compiler.registry.hasInterfaceType(e.name)) {
                k.* = .interface_t;
            } else if (compiler.registry.hasNamedType(e.name)) {
                k.* = .named_t;
            } else if (compiler.registry.hasVariantType(e.name)) {
                k.* = .variant_t;
            } else {
                k.* = .func_or_var;
            }
        }
        try compiler.emitModuleObject();
        if (emit_halt) try compiler.cs.emitOp(.halt, compiler.prev.line);
        self.modules[idx].state = .compiled;
    }

    fn compileDependencies(self: *Session, importer_path: []const u8, src: []const u8) anyerror!void {
        var imports: [MaxImportsPerModule][MaxModulePathBytes]u8 = undefined;
        var lens: [MaxImportsPerModule]usize = undefined;
        var count: usize = 0;

        var lex: Lexer = .{ .src = src };
        while (true) {
            const tok = lex.next();
            switch (tok.typ) {
                .eof => break,
                .err_invalid_char => {
                    self.last_error_path = importer_path;
                    self.last_error_line = tok.line;
                    return error.InvalidChar;
                },
                .err_unterminated_string => {
                    self.last_error_path = importer_path;
                    self.last_error_line = tok.line;
                    self.setScanError("unterminated string literal", .{});
                    return error.UnterminatedString;
                },
                .err_string_pool_exhausted => {
                    self.last_error_path = importer_path;
                    self.last_error_line = tok.line;
                    self.setScanError("string pool exhausted (max {d}KB)", .{@import("lexer.zig").StrPoolSize / 1024});
                    return error.UnterminatedString;
                },
                .kw_import => {
                    const lp = lex.next();
                    if (lp.typ != .lparen) continue;
                    const name = lex.next();
                    if (name.typ != .string) continue;
                    const rp = lex.next();
                    if (rp.typ != .rparen) continue;
                    if (common.streq(name.src, "std")) continue;
                    if (name.src.len > 5 and std.mem.startsWith(u8, name.src, "host:")) continue;
                    if (name.src.len > 4 and std.mem.startsWith(u8, name.src, "cap:")) continue;
                    const resolved = try self.resolveImportPath(importer_path, name.src);
                    if (!containsPath(imports[0..count], lens[0..count], resolved)) {
                        if (count >= MaxImportsPerModule) {
                            self.last_error_path = importer_path;
                            return error.ModuleLimitExceeded;
                        }
                        @memcpy(imports[count][0..resolved.len], resolved);
                        lens[count] = resolved.len;
                        count += 1;
                    }
                },
                else => {},
            }
        }

        for (imports[0..count], lens[0..count]) |*imp, len| {
            try self.compileModuleFromPath(imp[0..len]);
        }
    }

    fn beginModule(self: *Session, path: []const u8, is_root: bool) !usize {
        if (self.module_count >= MaxModules) {
            self.last_error_path = path;
            return error.ModuleLimitExceeded;
        }
        if (path.len > MaxModulePathBytes) {
            self.last_error_path = path;
            return error.ImportPathTooLong;
        }

        const idx = self.module_count;
        self.modules[idx] = .{};
        self.modules[idx].path_len = path.len;
        @memcpy(self.modules[idx].path_buf[0..path.len], path);
        if (!is_root) {
            self.modules[idx].global_name = try self.makePrefixedName("@mod:", path);
            self.modules[idx].prefix = try self.makePrefixedName("@mod:", path);
            self.modules[idx].struct_name = try self.makePrefixedName("@module_type:", path);
        }
        self.modules[idx].state = .loading;
        self.module_count += 1;
        return idx;
    }

    fn makePrefixedName(self: *Session, prefix: []const u8, path: []const u8) ![]const u8 {
        const total = prefix.len + path.len;
        const buf = self.hs.bump(u8, total) orelse return error.OutOfMemory;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..total], path);
        return buf[0..total];
    }

    fn moduleGlobalName(self: *Session, path: []const u8) ?[]const u8 {
        const idx = self.findModule(path) orelse return null;
        return self.modules[idx].global_name;
    }

    fn findModule(self: *Session, path: []const u8) ?usize {
        for (self.modules[0..self.module_count], 0..) |*m, i| {
            if (common.streq(m.path(), path)) return i;
            if (m.link_module_id.len > 0 and common.streq(m.link_module_id, path)) return i;
        }
        return null;
    }

    fn isAllowedImportPath(self: *const Session, path: []const u8) bool {
        // No source_root configured: unrestricted (embedding backward compat).
        if (self.source_root.len == 0) return true;
        // The prefix check is the authoritative gate: if the resolved path
        // falls under an allowed root it is permitted regardless of how many
        // ".." segments were in the original import string.  This also handles
        // scripts invoked via a relative "../" path whose own imports resolve
        // to paths that share the same ".." prefix.
        if (pathIsUnderRoot(path, self.source_root)) return true;
        for (self.module_roots_buf[0..self.module_roots_count]) |root| {
            if (pathIsUnderRoot(path, root)) return true;
        }
        return false;
    }

    fn rejectImportOutsideRoot(self: *Session, importer_path: []const u8, import_name: []const u8) error{ImportOutsideRoot} {
        self.last_error_path = importer_path;
        self.setScanError("import '{s}' is outside the allowed source directories", .{import_name});
        return error.ImportOutsideRoot;
    }

    fn resolveImportPath(self: *Session, importer_path: []const u8, import_name: []const u8) ![]const u8 {
        if (common.streq(import_name, StdModulePath)) return StdModulePath;
        if (import_name.len == 0) return error.ImportNotFound;
        if (!(import_name[0] == '.')) {
            // Normalize first so the sandbox check is path-aware (not a raw
            // string-prefix match that "../" segments can fool).
            //
            // For paths that escape the current directory (absolute paths or
            // those that normalize to a "../"-prefixed form), the sandbox
            // check must happen BEFORE any sourceExists probe: probing an
            // out-of-tree path on the filesystem provider reveals whether the
            // file is readable, which is a side-channel even when the import
            // is ultimately rejected.
            //
            // For ordinary relative package names (no escaping traversal),
            // probe first so that a non-existent name still falls through to
            // the "not found"/UnsupportedImportModule error rather than being
            // misreported as "outside the allowed source directories".
            //
            // Return the normalized path (not the raw import_name) so that
            // two spellings of the same file deduplicate correctly in
            // findModule's exact-string compare.
            var pkg_buf: [MaxModulePathBytes]u8 = undefined;
            const normalized = try joinAndNormalize(&pkg_buf, ".", import_name);
            const might_escape = (normalized.len > 0 and normalized[0] == '/') or
                std.mem.startsWith(u8, normalized, "../");
            if (might_escape and !self.isAllowedImportPath(normalized))
                return self.rejectImportOutsideRoot(importer_path, import_name);
            if (self.sourceExists(import_name)) {
                if (!self.isAllowedImportPath(normalized)) return self.rejectImportOutsideRoot(importer_path, import_name);
                return copyResolvedPath(self, normalized);
            }

            var pkg_ext_buf: [MaxModulePathBytes]u8 = undefined;
            const with_ext = try appendSuffix(&pkg_ext_buf, import_name, ".gengo");
            var pkg_ext_norm_buf: [MaxModulePathBytes]u8 = undefined;
            const normalized_ext = try joinAndNormalize(&pkg_ext_norm_buf, ".", with_ext);
            if (might_escape and !self.isAllowedImportPath(normalized_ext))
                return self.rejectImportOutsideRoot(importer_path, import_name);
            if (self.sourceExists(with_ext)) {
                if (!self.isAllowedImportPath(normalized_ext)) return self.rejectImportOutsideRoot(importer_path, import_name);
                return copyResolvedPath(self, normalized_ext);
            }

            var pkg_mod_buf: [MaxModulePathBytes]u8 = undefined;
            const with_mod = try appendSuffix(&pkg_mod_buf, import_name, "/mod.gengo");
            var pkg_mod_norm_buf: [MaxModulePathBytes]u8 = undefined;
            const normalized_mod = try joinAndNormalize(&pkg_mod_norm_buf, ".", with_mod);
            if (might_escape and !self.isAllowedImportPath(normalized_mod))
                return self.rejectImportOutsideRoot(importer_path, import_name);
            if (self.sourceExists(with_mod)) {
                if (!self.isAllowedImportPath(normalized_mod)) return self.rejectImportOutsideRoot(importer_path, import_name);
                return copyResolvedPath(self, normalized_mod);
            }

            self.last_error_path = importer_path;
            self.setScanError("unsupported import '{s}'; relative imports must start with '.', or use 'cap:'/'host:' prefix, or register a package", .{import_name});
            return error.UnsupportedImportModule;
        }

        const base_dir = dirname(importer_path);

        var candidate_buf: [MaxModulePathBytes]u8 = undefined;
        const exact = try joinAndNormalize(&candidate_buf, base_dir, import_name);

        if (!self.isAllowedImportPath(exact)) {
            self.last_error_path = importer_path;
            self.setScanError("import '{s}' is outside the allowed source directories", .{import_name});
            return error.ImportOutsideRoot;
        }

        if (self.sourceExists(exact)) return copyResolvedPath(self, exact);

        var ext_buf: [MaxModulePathBytes]u8 = undefined;
        const with_ext = try appendSuffix(&ext_buf, exact, ".gengo");
        if (self.sourceExists(with_ext)) return copyResolvedPath(self, with_ext);

        var mod_buf: [MaxModulePathBytes]u8 = undefined;
        const with_mod = try appendSuffix(&mod_buf, exact, "/mod.gengo");
        if (self.sourceExists(with_mod)) return copyResolvedPath(self, with_mod);

        self.last_error_path = importer_path;
        self.setScanError("import '{s}' not found from '{s}'; tried '{s}', '{s}', and '{s}'", .{
            import_name, importer_path, exact, with_ext, with_mod,
        });
        return error.ImportNotFound;
    }

    fn sourceExists(self: *Session, path: []const u8) bool {
        return switch (self.provider) {
            .filesystem => fileExists(path),
            .table => |entries| findSourceEntry(entries, path) != null,
            .callback => |cb| (cb.load(cb.ctx, path) catch null) != null,
        };
    }

    fn loadSource(self: *Session, path: []const u8) ![]const u8 {
        return switch (self.provider) {
            .filesystem => blk: {
                const n = source_io.readFile(path, &self.source_buf) catch |err| {
                    self.last_error_path = path;
                    return err;
                };
                break :blk self.source_buf[0..n];
            },
            .table => |entries| blk: {
                const entry = findSourceEntry(entries, path) orelse {
                    self.last_error_path = path;
                    return error.ImportNotFound;
                };
                break :blk entry.source;
            },
            .callback => |cb| blk: {
                const src = try cb.load(cb.ctx, path);
                if (src == null) {
                    self.last_error_path = path;
                    return error.ImportNotFound;
                }
                break :blk src.?;
            },
        };
    }
};

pub fn hasModuleExport(ctx: *anyopaque, path: []const u8, field: []const u8) bool {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const idx = self.findModule(path) orelse {
        // Check capability modules
        const cap_key = if (std.mem.startsWith(u8, path, "cap:")) path[4..] else path;
        // cap:ffi additionally exports "types" (ffi.types.i32 etc.), "buf"
        // (ffi.buf(n)), and "buf_from_ptr" (ffi.buf_from_ptr(ptr, len)) that
        // are not functions in cm.functions. They are installed at runtime
        // by installFfiModule in native/main.zig. buf_from_ptr was missing
        // from this allowlist -- its runtime dispatch (cap_ffi.zig) was
        // fully implemented but permanently unreachable, since any script
        // referencing ffi.buf_from_ptr failed to compile at all
        // (UnknownField) before ever reaching it.
        if (comptime build_options.cap_ffi) {
            if (common.streq(cap_key, "ffi") and
                (common.streq(field, "types") or common.streq(field, "buf") or common.streq(field, "buf_from_ptr"))) return true;
        }
        for (self.capability_modules) |cm| {
            if (common.streq(cm.name, cap_key)) {
                for (cm.functions) |func| {
                    if (common.streq(func.name, field)) return true;
                    if (func.name.len > field.len and
                        std.mem.startsWith(u8, func.name, field) and
                        func.name[field.len] == '.') return true;
                }
                return false;
            }
        }
        // Check host modules
        const host_key = if (std.mem.startsWith(u8, path, "host:")) path[5..] else path;
        for (self.host_module_descs) |hm| {
            if (common.streq(hm.name, host_key)) {
                for (hm.functions) |func| {
                    if (common.streq(func.name, field)) return true;
                }
                return false;
            }
        }
        return false;
    };
    const exports = &self.modules[idx];
    for (exports.export_names[0..exports.export_count]) |n| {
        if (common.streq(n, field)) return true;
    }
    return false;
}

pub fn resolveModuleTypeKind(ctx: *anyopaque, path: []const u8, type_name: []const u8) ?module_descriptor.ModuleTypeInfo {
    if (module_descriptor.resolveType(path, type_name)) |info| return info;
    const s: *Session = @ptrCast(@alignCast(ctx));
    const idx = s.findModule(path) orelse return null;
    const rec = &s.modules[idx];
    for (rec.export_names[0..rec.export_count], rec.export_type_kinds[0..rec.export_count]) |n, k| {
        if (common.streq(n, type_name)) {
            var qname_buf: [MaxModulePathBytes + 64]u8 = undefined;
            const qname = std.fmt.bufPrint(&qname_buf, "@mod:{s}.{s}", .{ path, type_name }) catch return null;
            const qname_copy = s.hs.bump(u8, qname.len) orelse return null;
            @memcpy(qname_copy, qname);
            return .{ .kind = k, .qualified_name = qname_copy[0..qname.len] };
        }
    }
    return null;
}

pub fn resolveModuleConstant(ctx: *anyopaque, path: []const u8, name: []const u8) ?CompileTimeConst {
    const s: *Session = @ptrCast(@alignCast(ctx));
    const idx = s.findModule(path) orelse return null;
    const rec = &s.modules[idx];
    for (rec.export_names[0..rec.export_count], rec.export_const_values[0..rec.export_count]) |export_name, value| {
        if (common.streq(export_name, name)) return value;
    }
    return null;
}

pub fn checkGlobalExistsInSession(ctx: *anyopaque, name: []const u8) bool {
    const s: *Session = @ptrCast(@alignCast(ctx));
    for (s.known_globals.?[0..s.known_global_count]) |gn| {
        if (common.streq(gn, name)) return true;
    }
    if (common.streq(name, StdModuleGlobalName)) return true;
    if (std.mem.startsWith(u8, name, "module:std.")) return true;
    if (std.mem.startsWith(u8, name, "cap:")) return true;
    if (std.mem.startsWith(u8, name, "host:")) return true;
    if (std.mem.startsWith(u8, name, "@module_type:")) return true;
    if (std.mem.startsWith(u8, name, "@mod:")) return true;
    if (std.mem.startsWith(u8, name, "__test_")) return true;
    return false;
}

fn containsPath(paths: []const [MaxModulePathBytes]u8, lens: []const usize, needle: []const u8) bool {
    for (paths, lens) |*p, l| {
        if (common.streq(p[0..l], needle)) return true;
    }
    return false;
}

fn pathIsUnderRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return true;
    // "." means the cwd: any relative path that hasn't escaped upward is allowed.
    if (common.streq(root, ".")) {
        return !(path.len == 0 or path[0] == '/' or
            common.streq(path, "..") or std.mem.startsWith(u8, path, "../"));
    }
    // Strip leading "./" from root so "./modbus" matches normalized path "modbus/…".
    const r = if (std.mem.startsWith(u8, root, "./")) root[2..] else root;
    if (r.len == 0) return true;
    if (!std.mem.startsWith(u8, path, r)) return false;
    // Prevent "src_extra/foo" matching root "src"
    if (path.len == r.len) return true;
    return path[r.len] == '/';
}

fn copyResolvedPath(self: *Session, path: []const u8) ![]const u8 {
    const out = self.hs.bump(u8, path.len) orelse return error.OutOfMemory;
    @memcpy(out[0..path.len], path);
    return out[0..path.len];
}

fn dirname(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[0 .. i - 1];
    }
    return ".";
}

fn fileExists(path: []const u8) bool {
    var dummy: [1]u8 = undefined;
    if (source_io.readFile(path, dummy[0..1])) |_| {
        return true;
    } else |err| {
        if (err == error.InputTooLong) return true;
        return false;
    }
}

fn findSourceEntry(entries: []const SourceEntry, path: []const u8) ?SourceEntry {
    for (entries) |entry| {
        if (common.streq(entry.path, path)) return entry;
    }
    return null;
}

fn appendSuffix(buf: *[MaxModulePathBytes]u8, base: []const u8, suffix: []const u8) ![]const u8 {
    if (base.len + suffix.len > buf.len) return error.ImportPathTooLong;
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len .. base.len + suffix.len], suffix);
    return buf[0 .. base.len + suffix.len];
}

fn joinAndNormalize(buf: *[MaxModulePathBytes]u8, base_dir: []const u8, import_name: []const u8) ![]const u8 {
    var joined_len: usize = 0;
    if (import_name.len > 0 and import_name[0] == '/') {
        if (import_name.len > buf.len) return error.ImportPathTooLong;
        @memcpy(buf[0..import_name.len], import_name);
        joined_len = import_name.len;
    } else {
        if (base_dir.len + 1 + import_name.len > buf.len) return error.ImportPathTooLong;
        @memcpy(buf[0..base_dir.len], base_dir);
        joined_len = base_dir.len;
        if (!(joined_len == 1 and buf[0] == '.')) {
            buf[joined_len] = '/';
            joined_len += 1;
        } else {
            joined_len = 0;
        }
        @memcpy(buf[joined_len .. joined_len + import_name.len], import_name);
        joined_len += import_name.len;
    }
    return normalizePathInPlace(buf, joined_len);
}

fn normalizePathInPlace(buf: *[MaxModulePathBytes]u8, len: usize) ![]const u8 {
    var absolute = false;
    var read_i: usize = 0;
    var write_i: usize = 0;
    var seg_starts: [MaxModulePathBytes]usize = undefined;
    // Tracks whether each seg_starts[i] entry is a real named segment or a
    // leading, unresolvable ".." placeholder (pushed when there's no real
    // segment left to cancel). Without this, a second unresolvable ".."
    // popped the FIRST placeholder as if it were a real segment instead of
    // stacking a second placeholder — consecutive leading ".." segments
    // cancelled in pairs (2 collapse to 0, 3 collapse to 1, ...) instead of
    // accumulating, so e.g. "../../foo" and "foo" could normalize to the
    // same path from the same base_dir, silently colliding two distinct
    // imports on one resolved path/cache entry.
    var seg_is_dotdot: [MaxModulePathBytes]bool = undefined;
    var seg_count: usize = 0;

    if (len > 0 and buf[0] == '/') {
        absolute = true;
        buf[0] = '/';
        read_i = 1;
        write_i = 1;
    }

    while (read_i < len) {
        while (read_i < len and buf[read_i] == '/') : (read_i += 1) {}
        if (read_i >= len) break;
        const seg_start = read_i;
        while (read_i < len and buf[read_i] != '/') : (read_i += 1) {}
        const seg = buf[seg_start..read_i];
        if (common.streq(seg, ".")) continue;
        if (common.streq(seg, "..")) {
            if (seg_count > 0 and !seg_is_dotdot[seg_count - 1]) {
                seg_count -= 1;
                write_i = seg_starts[seg_count];
            } else if (!absolute) {
                if (write_i != 0) {
                    buf[write_i] = '/';
                    write_i += 1;
                }
                seg_starts[seg_count] = write_i;
                seg_is_dotdot[seg_count] = true;
                seg_count += 1;
                buf[write_i] = '.';
                buf[write_i + 1] = '.';
                write_i += 2;
            }
            continue;
        }
        if (write_i != 0 and buf[write_i - 1] != '/') {
            buf[write_i] = '/';
            write_i += 1;
        }
        seg_starts[seg_count] = write_i;
        seg_is_dotdot[seg_count] = false;
        seg_count += 1;
        std.mem.copyForwards(u8, buf[write_i .. write_i + seg.len], seg);
        write_i += seg.len;
    }

    if (write_i == 0) {
        buf[0] = if (absolute) '/' else '.';
        write_i = 1;
    }
    return buf[0..write_i];
}

const testing = std.testing;

fn testSession(hs: *heap.State, source_root: []const u8, entries: []const SourceEntry) Session {
    var session: Session = .{};
    session.hs = hs;
    session.source_root = source_root;
    session.provider = .{ .table = entries };
    return session;
}

// Package-style imports (no leading '.') are sandbox-checked before any
// filesystem probe: the sandbox gate (isAllowedImportPath) is applied to
// the normalized path BEFORE sourceExists is called, so a traversal or
// absolute path cannot reveal whether an out-of-sandbox file exists.
// An unregistered package name whose normalized form is within the allowed
// root still falls through to the ordinary "not found" error rather than
// being misreported as "outside the allowed source directories".
test "resolveImportPath: package-style import respects source_root sandbox" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    const entries = [_]SourceEntry{
        .{ .path = "ok/math.gengo", .source = "" },
        .{ .path = "/etc/passwd", .source = "" },
        .{ .path = "x/../../secret.gengo", .source = "" },
    };
    var session = testSession(&h, ".", &entries);

    const ok = try session.resolveImportPath("main.gengo", "ok/math");
    try testing.expectEqualStrings("ok/math.gengo", ok);

    try testing.expectError(error.ImportOutsideRoot, session.resolveImportPath("main.gengo", "/etc/passwd"));
    try testing.expectError(error.ImportOutsideRoot, session.resolveImportPath("main.gengo", "x/../../secret"));

    // An unregistered package name whose normalized form is within the
    // allowed root must still fail with the ordinary "not found" error,
    // not "outside the allowed source directories".
    try testing.expectError(error.UnsupportedImportModule, session.resolveImportPath("main.gengo", "nonexistent"));
}

// normalizePathInPlace's ".." bookkeeping used to treat the first
// unresolvable ".." placeholder the same as a real segment, so a second
// unresolvable ".." popped it instead of stacking — N leading un-cancelable
// ".." segments collapsed to N mod 2 instead of accumulating, letting e.g.
// "../../foo" and "foo" normalize to the same path from the same base.
test "normalizePathInPlace accumulates consecutive unresolvable .. segments" {
    var buf: [MaxModulePathBytes]u8 = undefined;
    {
        const src = "../../foo";
        @memcpy(buf[0..src.len], src);
        const out = try normalizePathInPlace(&buf, src.len);
        try testing.expectEqualStrings("../../foo", out);
    }
    {
        const src = "../../../bar";
        @memcpy(buf[0..src.len], src);
        const out = try normalizePathInPlace(&buf, src.len);
        try testing.expectEqualStrings("../../../bar", out);
    }
    {
        // A real segment followed by ".." still correctly cancels (this
        // path was never broken — only consecutive *unresolvable* ".."
        // segments were).
        const src = "a/../b";
        @memcpy(buf[0..src.len], src);
        const out = try normalizePathInPlace(&buf, src.len);
        try testing.expectEqualStrings("b", out);
    }
}

test "pathIsUnderRoot: '.' root allows any non-escaping relative path but rejects absolute paths and '..' escapes" {
    try testing.expect(pathIsUnderRoot("foo/bar.gengo", "."));
    try testing.expect(pathIsUnderRoot(".", "."));
    try testing.expect(!pathIsUnderRoot("/etc/passwd", "."));
    try testing.expect(!pathIsUnderRoot("..", "."));
    try testing.expect(!pathIsUnderRoot("../secret.gengo", "."));
}

test "pathIsUnderRoot: prefix match requires a path-separator boundary; an empty root is unrestricted; a leading './' on root is stripped" {
    try testing.expect(pathIsUnderRoot("anything/at/all", ""));
    try testing.expect(pathIsUnderRoot("src/foo.gengo", "src"));
    try testing.expect(pathIsUnderRoot("src", "src"));
    // "src_extra" must not match root "src" just because it shares the prefix
    // string -- only a '/'-bounded (or exact) match counts.
    try testing.expect(!pathIsUnderRoot("src_extra/foo.gengo", "src"));
    try testing.expect(pathIsUnderRoot("modbus/x.gengo", "./modbus"));
    try testing.expect(!pathIsUnderRoot("other/x.gengo", "./modbus"));
}

test "resolveImportPath: relative import falls back to '<name>.gengo' then '<name>/mod.gengo' when the bare path is absent" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    const entries = [_]SourceEntry{
        .{ .path = "sub.gengo", .source = "" },
        .{ .path = "pkgdir/mod.gengo", .source = "" },
    };
    var session = testSession(&h, "", &entries);

    const via_ext = try session.resolveImportPath("main.gengo", "./sub");
    try testing.expectEqualStrings("sub.gengo", via_ext);

    const via_mod = try session.resolveImportPath("main.gengo", "./pkgdir");
    try testing.expectEqualStrings("pkgdir/mod.gengo", via_mod);
}

test "resolveImportPath: relative import not found reports all three attempted candidate paths in the error message" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    var session = testSession(&h, "", &.{});

    try testing.expectError(error.ImportNotFound, session.resolveImportPath("main.gengo", "./missing"));
    const msg = session.last_error_msg_buf[0..session.last_error_msg_len];
    try testing.expect(std.mem.indexOf(u8, msg, "missing") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "missing.gengo") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "missing/mod.gengo") != null);
}

test "resolveImportPath: package-style (non-relative) import resolves via '.gengo' and '/mod.gengo' suffixes" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    const entries = [_]SourceEntry{
        .{ .path = "mathlib.gengo", .source = "" },
        .{ .path = "greetlib/mod.gengo", .source = "" },
    };
    var session = testSession(&h, "", &entries);

    const via_ext = try session.resolveImportPath("main.gengo", "mathlib");
    try testing.expectEqualStrings("mathlib.gengo", via_ext);

    const via_mod = try session.resolveImportPath("main.gengo", "greetlib");
    try testing.expectEqualStrings("greetlib/mod.gengo", via_mod);
}

// isAllowedImportPath's module_roots loop (checked when the resolved path
// doesn't fall under source_root) had no direct coverage: every prior
// sandbox test only ever configured source_root, never module_roots_buf.
test "isAllowedImportPath: a configured module_root permits an import path outside source_root" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    const entries = [_]SourceEntry{
        .{ .path = "vendor/lib.gengo", .source = "" },
        .{ .path = "elsewhere/lib.gengo", .source = "" },
    };
    var session: Session = .{};
    session.hs = &h;
    session.provider = .{ .table = &entries };
    session.source_root = "app";
    session.module_roots_buf[0] = "vendor";
    session.module_roots_count = 1;

    const resolved = try session.resolveImportPath("app/main.gengo", "vendor/lib");
    try testing.expectEqualStrings("vendor/lib.gengo", resolved);

    try testing.expectError(error.ImportOutsideRoot, session.resolveImportPath("app/main.gengo", "elsewhere/lib"));
}

// hasModuleExport's capability-module branch has two match rules: an exact
// function-name match, and a "scoped grant" match where a longer, dotted
// function name (e.g. a future "listen.tcp") is treated as exporting its
// bare prefix. None of the real, built-in CapModuleDesc tables use a dotted
// function name today, so that second rule was reachable only via a
// synthetic capability_modules list.
test "hasModuleExport: capability module lookup matches exact function names and dotted scope prefixes" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    const funcs = [_]CapModuleFuncDesc{
        .{ .name = "dial", .arity = 1, .native_id = 1 },
        .{ .name = "listen.tcp", .arity = 1, .native_id = 2 },
    };
    const caps = [_]CapModuleDesc{.{ .name = "netlike", .functions = &funcs }};

    var session: Session = .{};
    session.hs = &h;
    session.capability_modules = &caps;

    try testing.expect(hasModuleExport(&session, "cap:netlike", "dial"));
    try testing.expect(hasModuleExport(&session, "cap:netlike", "listen"));
    try testing.expect(!hasModuleExport(&session, "cap:netlike", "bogus"));
    try testing.expect(!hasModuleExport(&session, "cap:unknown", "dial"));
}

test "hasModuleExport: host module lookup matches by exact function name only" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    const funcs = [_]HostModuleFuncDesc{.{ .name = "ping", .arity = 0, .call_id = 1 }};
    const hosts = [_]HostModuleDesc{.{ .name = "alpha", .functions = &funcs }};

    var session: Session = .{};
    session.hs = &h;
    session.host_module_descs = &hosts;

    try testing.expect(hasModuleExport(&session, "host:alpha", "ping"));
    try testing.expect(!hasModuleExport(&session, "host:alpha", "pong"));
    try testing.expect(!hasModuleExport(&session, "host:beta", "ping"));
}

// resolveModuleTypeKind/resolveModuleConstant both walk a compiled
// ModuleRecord's export_names/export_type_kinds/export_const_values arrays
// directly -- exercised here without needing a real multi-file compile.
test "resolveModuleTypeKind and resolveModuleConstant look up exported symbols recorded on a compiled ModuleRecord" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    var session: Session = .{};
    session.hs = &h;
    try session.initArena();
    defer session.deinitArena();

    const path = "dep.gengo";
    session.modules[0].path_len = path.len;
    @memcpy(session.modules[0].path_buf[0..path.len], path);
    session.modules[0].export_count = 2;
    session.modules[0].export_names[0] = "SIZE";
    session.modules[0].export_type_kinds[0] = .func_or_var;
    session.modules[0].export_const_values[0] = .{ .number = 42 };
    session.modules[0].export_names[1] = "Widget";
    session.modules[0].export_type_kinds[1] = .struct_t;
    session.modules[0].export_const_values[1] = null;
    session.module_count = 1;

    const const_info = resolveModuleConstant(&session, path, "SIZE");
    try testing.expect(const_info != null);
    try testing.expectEqual(@as(f64, 42), const_info.?.number);
    try testing.expect(resolveModuleConstant(&session, path, "Missing") == null);
    try testing.expect(resolveModuleConstant(&session, "unknown.gengo", "SIZE") == null);

    const type_info = resolveModuleTypeKind(&session, path, "Widget");
    try testing.expect(type_info != null);
    try testing.expectEqual(ExportTypeKind.struct_t, type_info.?.kind);
    try testing.expectEqualStrings("@mod:dep.gengo.Widget", type_info.?.qualified_name);
    try testing.expect(resolveModuleTypeKind(&session, path, "Missing") == null);
    try testing.expect(resolveModuleTypeKind(&session, "unknown.gengo", "Widget") == null);
}

// isCapabilityEnabled's inner loop only returns true when the matched grant's
// bare name also has a corresponding entry in capability_modules; a grant
// whose name matches but whose module was never registered (e.g. compiled
// out, or simply not wired up for this embedding) must fall through to
// false rather than the outer loop's own "not found at all" false.
test "isCapabilityEnabled: a name present in enabled_capabilities but absent from capability_modules is not enabled" {
    var session: Session = .{};
    session.enabled_capabilities = &.{"net"};
    session.capability_modules = &.{};
    try testing.expect(!session.isCapabilityEnabled("net"));
}

// resolveImportOpaque's "host:" branch delegates to isHostModule, whose own
// false-fallthrough (the name isn't in host_module_names) had no coverage --
// every other host-module test used a name that was actually registered.
test "resolveImportOpaque: an unregistered 'host:' import name fails with ImportNotFound" {
    var session: Session = .{};
    session.host_module_names = &.{"alpha"};
    try testing.expectError(error.ImportNotFound, Session.resolveImportOpaque(&session, "main.gengo", "host:beta"));
}

// resolveImportPath's dot-prefixed ("./..."/"../...") branch has its own
// sandbox check (distinct from the package-style branch's, already covered
// above) -- a relative import whose normalized form escapes source_root must
// be rejected before any sourceExists probe.
test "resolveImportPath: a dot-prefixed relative import that escapes source_root is rejected" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    var session = testSession(&h, "sub", &.{});
    try testing.expectError(error.ImportOutsideRoot, session.resolveImportPath("sub/main.gengo", "../../etc/passwd"));
}

test "checkGlobalExistsInSession: recognizes registered globals plus std/cap/host/module-prefixed and test-block names" {
    var h: heap.State = .{};
    try h.init(64 * 1024, 256, testing.allocator);
    defer h.deinit();

    var session: Session = .{};
    session.hs = &h;
    var known: [4][]const u8 = .{ "main.counter", "", "", "" };
    session.known_globals = @ptrCast(&known);
    session.known_global_count = 1;

    try testing.expect(checkGlobalExistsInSession(&session, "main.counter"));
    try testing.expect(!checkGlobalExistsInSession(&session, "main.other"));
    try testing.expect(checkGlobalExistsInSession(&session, StdModuleGlobalName));
    try testing.expect(checkGlobalExistsInSession(&session, "module:std.time"));
    try testing.expect(checkGlobalExistsInSession(&session, "cap:net"));
    try testing.expect(checkGlobalExistsInSession(&session, "host:alpha"));
    try testing.expect(checkGlobalExistsInSession(&session, "@module_type:dep"));
    try testing.expect(checkGlobalExistsInSession(&session, "@mod:dep"));
    try testing.expect(checkGlobalExistsInSession(&session, "__test_0"));
}
