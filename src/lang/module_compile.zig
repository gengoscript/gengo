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
const cfg = @import("../runtime/config.zig");
const globals = @import("globals.zig");
const source_io = @import("../runtime/source_io.zig");
const build_options = @import("build_options");

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

const MaxModuleExports = 64;

const ModuleRecord = struct {
    path_len: usize = 0,
    path_buf: [MaxModulePathBytes]u8 = undefined,
    global_name: []const u8 = "",
    prefix: []const u8 = "",
    struct_name: []const u8 = "",
    state: ModuleState = .loading,
    export_names: [MaxModuleExports][]const u8 = undefined,
    export_type_kinds: [MaxModuleExports]ExportTypeKind = undefined,
    export_count: u8 = 0,

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
    native_id: u8,
};

pub const CapModuleDesc = struct {
    name: []const u8,
    functions: []const CapModuleFuncDesc,
};

pub const cap_net_desc: CapModuleDesc = .{
    .name = "net",
    .functions = &.{
        .{ .name = "dial", .arity = 2, .native_id = 163 },
    },
};

pub const cap_fs_desc: CapModuleDesc = .{
    .name = "fs",
    .functions = &.{
        .{ .name = "read",   .arity = 1, .native_id = 161 },
        .{ .name = "exists", .arity = 1, .native_id = 162 },
        .{ .name = "write",  .arity = 2, .native_id = 188 },
        .{ .name = "list",   .arity = 1, .native_id = 189 },
        .{ .name = "delete", .arity = 1, .native_id = 190 },
        .{ .name = "mkdir",  .arity = 1, .native_id = 191 },
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
    break :blk caps;
};
const _cap_count: usize = @as(usize, @intFromBool(build_options.cap_net)) + @as(usize, @intFromBool(build_options.cap_fs)) + @as(usize, @intFromBool(build_options.cap_http));
pub const AllCapabilities = _cap_storage[0.._cap_count];

pub const MaxCapabilities = 16;
pub const MaxModuleRoots = 8;

pub const Session = struct {
    modules: [MaxModules]ModuleRecord = undefined,
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
    test_count: u16 = 0,
    test_names: [ct.MaxTestBlocks][]const u8 = undefined,

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
            if (common.streq(cap, name)) {
                for (self.capability_modules) |cm| {
                    if (common.streq(cm.name, name)) return true;
                }
                return false;
            }
        }
        return false;
    }

    pub fn compileRoot(self: *Session, root_path: []const u8, src: []const u8) !void {
        chunk.reset();
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
        const resolved = try self.resolveImportPath(importer_path, import_name);
        if (common.streq(resolved, StdModulePath)) return StdModuleGlobalName;
        if (self.isHostModule(resolved)) {
            return try self.makePrefixedName("host:", resolved);
        }
        try self.compileModuleFromPath(resolved);
        return self.moduleGlobalName(resolved) orelse return error.ImportNotFound;
    }

    fn compileModuleFromPath(self: *Session, path: []const u8) anyerror!void {
        const idx = (try self.beginImportedModule(path)) orelse return;
        const src = try self.loadImportedModuleSource(idx);
        try self.compileImportedModule(idx, src);
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
        const src_copy = heap.bump(u8, src_raw.len) orelse {
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
            const buf = heap.bump(u8, total) orelse return error.OutOfMemory;
            @memcpy(buf[0..prefix.len], prefix);
            buf[prefix.len] = '.';
            @memcpy(buf[prefix.len + 1 .. total], name);
            break :blk buf[0..total];
        } else name;
        if (self.known_global_count >= chunk.MaxConst) {
            self.setScanError("too many global declarations (max {d})", .{chunk.MaxConst});
            return error.TooManyGlobals;
        }
        const copy = heap.bump(u8, qname.len) orelse return error.OutOfMemory;
        @memcpy(copy[0..qname.len], qname);
        self.known_globals.?[self.known_global_count] = copy[0..qname.len];
        self.known_global_count += 1;
    }

    fn scanGlobalDeclarations(self: *Session, src: []const u8, prefix: []const u8) !void {
        self.known_global_count = 0;
        if (self.known_globals == null) {
            self.known_globals = heap.bump([]const u8, chunk.MaxConst) orelse return error.OutOfMemory;
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
                    if (peek.next().typ == .lparen) {
                        try self.registerGlobalName(name_tok.src, prefix);
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
        var compiler = Compiler.init(src, .{
            .module_path = self.modules[idx].path(),
            .module_prefix = self.modules[idx].prefix,
            .module_struct_name = self.modules[idx].struct_name,
            .module_global_name = self.modules[idx].global_name,
            .module_ctx = self,
            .resolve_import = resolveImportOpaque,
            .has_module_export = hasModuleExport,
            .resolve_module_type = resolveModuleTypeKind,
            .check_global_exists = checkGlobalExistsInSession,
            .check_global_ctx = self,
            .test_mode = if (emit_halt) self.test_mode else false,
        });
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
        ) |*n, *k, e| {
            n.* = e.name;
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
        if (emit_halt) try chunk.emitOp(.halt, compiler.prev.line);
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
                    if (self.isHostModule(name.src)) continue;
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
            self.modules[idx].global_name = try self.makePrefixedName("host:", path);
            self.modules[idx].prefix = try self.makePrefixedName("@mod:", path);
            self.modules[idx].struct_name = try self.makePrefixedName("@module_type:", path);
        }
        self.modules[idx].state = .loading;
        self.module_count += 1;
        return idx;
    }

    fn makePrefixedName(self: *Session, prefix: []const u8, path: []const u8) ![]const u8 {
        _ = self;
        const total = prefix.len + path.len;
        const buf = heap.bump(u8, total) orelse return error.OutOfMemory;
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

    fn resolveImportPath(self: *Session, importer_path: []const u8, import_name: []const u8) ![]const u8 {
        if (common.streq(import_name, StdModulePath)) return StdModulePath;
        if (import_name.len == 0) return error.ImportNotFound;
        // Accept optional "host:" prefix so `import("host:foo")` and `import("foo")` are equivalent.
        const bare_name = if (std.mem.startsWith(u8, import_name, "host:")) import_name[5..] else import_name;
        if (self.isHostModule(bare_name)) return bare_name;
        if (!(import_name[0] == '.')) {
            self.last_error_path = importer_path;
            self.setScanError("unsupported import '{s}'; relative imports must start with '.', or use 'cap:'/'host:' prefix", .{import_name});
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

        if (self.sourceExists(exact)) return copyResolvedPath(exact);

        var ext_buf: [MaxModulePathBytes]u8 = undefined;
        const with_ext = try appendSuffix(&ext_buf, exact, ".gengo");
        if (self.sourceExists(with_ext)) return copyResolvedPath(with_ext);

        var mod_buf: [MaxModulePathBytes]u8 = undefined;
        const with_mod = try appendSuffix(&mod_buf, exact, "/mod.gengo");
        if (self.sourceExists(with_mod)) return copyResolvedPath(with_mod);

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
        for (self.host_module_descs) |hm| {
            if (common.streq(hm.name, path)) {
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

pub fn resolveModuleTypeKind(ctx: *anyopaque, path: []const u8, type_name: []const u8) ?ExportTypeKind {
    const s: *Session = @ptrCast(@alignCast(ctx));
    const idx = s.findModule(path) orelse return null;
    const rec = &s.modules[idx];
    for (rec.export_names[0..rec.export_count], rec.export_type_kinds[0..rec.export_count]) |n, k| {
        if (common.streq(n, type_name)) return k;
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

fn copyResolvedPath(path: []const u8) ![]const u8 {
    const out = heap.bump(u8, path.len) orelse return error.OutOfMemory;
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
            if (seg_count > 0) {
                seg_count -= 1;
                write_i = seg_starts[seg_count];
            } else if (!absolute) {
                if (write_i != 0) {
                    buf[write_i] = '/';
                    write_i += 1;
                }
                seg_starts[seg_count] = write_i;
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
