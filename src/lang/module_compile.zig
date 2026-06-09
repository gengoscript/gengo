const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const Compiler = @import("compiler.zig").Compiler;
const CompilerOptions = @import("compiler.zig").CompilerOptions;
const Lexer = @import("lexer.zig").Lexer;
const TT = @import("token.zig").TT;
const cfg = @import("../runtime/config.zig");
const source_io = @import("../runtime/source_io.zig");

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
    export_count: u8 = 0,

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
        .{ .name = "read", .arity = 1, .native_id = 161 },
        .{ .name = "exists", .arity = 1, .native_id = 162 },
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

pub const AllCapabilities = &.{ cap_net_desc, cap_fs_desc, cap_http_desc };

pub const MaxCapabilities = 16;

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
    host_module_names: []const []const u8 = &.{},
    enabled_capabilities: []const []const u8 = &.{},
    capability_modules: []const CapModuleDesc = &.{},
    test_mode: bool = false,
    test_count: u8 = 0,
    test_names: [64][]const u8 = undefined,

    fn copyCompilerError(self: *Session, compiler: *Compiler) void {
        self.last_error_col = compiler.err_col;
        @memcpy(self.last_error_msg_buf[0..compiler.err_msg_len], compiler.err_msg_buf[0..compiler.err_msg_len]);
        self.last_error_msg_len = compiler.err_msg_len;
    }

    fn isCapabilityEnabled(self: *Session, name: []const u8) bool {
        for (self.enabled_capabilities) |cap| {
            if (common.streq(cap, name)) return true;
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
            return try self.makePrefixedName("module:", resolved);
        }
        try self.compileModuleFromPath(resolved);
        return self.moduleGlobalName(resolved) orelse return error.ImportNotFound;
    }

    fn compileModuleFromPath(self: *Session, path: []const u8) anyerror!void {
        if (self.findModule(path)) |idx| {
            if (self.modules[idx].state == .loading) {
                self.last_error_path = self.modules[idx].path();
                return error.ImportCycle;
            }
            return;
        }

        const idx = try self.beginModule(path, false);
        errdefer self.module_count = idx;

        const src = try self.loadSource(path);
        try self.compileDependencies(path, src);
        try self.compileBegunModule(idx, src, false);
    }

    fn compileModule(self: *Session, path: []const u8, src: []const u8, emit_halt: bool) anyerror!void {
        if (self.findModule(path)) |idx| {
            if (self.modules[idx].state == .loading) {
                self.last_error_path = self.modules[idx].path();
                return error.ImportCycle;
            }
            return;
        }

        const idx = try self.beginModule(path, false);
        errdefer self.module_count = idx;

        try self.compileDependencies(path, src);
        try self.compileBegunModule(idx, src, emit_halt);
    }

    fn compileBegunModule(self: *Session, idx: usize, src: []const u8, emit_halt: bool) anyerror!void {
        var compiler = Compiler.init(src, .{
            .module_path = self.modules[idx].path(),
            .module_prefix = self.modules[idx].prefix,
            .module_struct_name = self.modules[idx].struct_name,
            .module_global_name = self.modules[idx].global_name,
            .module_ctx = self,
            .resolve_import = resolveImportOpaque,
            .has_module_export = hasModuleExport,
            .test_mode = if (emit_halt) self.test_mode else false,
        });
        compiler.compile(false) catch |err| {
            self.last_error_path = self.modules[idx].path();
            self.last_error_line = if (compiler.err_line != 0) compiler.err_line else compiler.prev.line;
            self.copyCompilerError(&compiler);
            return err;
        };
        if (emit_halt and self.test_mode) {
            self.test_count = compiler.test_count;
            var ti: usize = 0;
            while (ti < compiler.test_count) : (ti += 1) {
                self.test_names[ti] = compiler.test_names[ti];
            }
        }
        self.modules[idx].export_count = compiler.export_count;
        var ei: u8 = 0;
        while (ei < compiler.export_count) : (ei += 1) {
            self.modules[idx].export_names[ei] = compiler.exports[ei].name;
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
                    if (count >= MaxImportsPerModule) {
                        self.last_error_path = importer_path;
                        return error.ModuleLimitExceeded;
                    }
                    if (!containsPath(imports[0..count], lens[0..count], resolved)) {
                        @memcpy(imports[count][0..resolved.len], resolved);
                        lens[count] = resolved.len;
                        count += 1;
                    }
                },
                else => {},
            }
        }

        var i: usize = 0;
        while (i < count) : (i += 1) {
            try self.compileModuleFromPath(imports[i][0..lens[i]]);
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
            self.modules[idx].global_name = try self.makePrefixedName("module:", path);
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
        var i: usize = 0;
        while (i < self.module_count) : (i += 1) {
            if (common.streq(self.modules[i].path(), path)) return i;
        }
        return null;
    }

    fn resolveImportPath(self: *Session, importer_path: []const u8, import_name: []const u8) ![]const u8 {
        if (common.streq(import_name, StdModulePath)) return StdModulePath;
        if (import_name.len == 0) return error.ImportNotFound;
        if (self.isHostModule(import_name)) return import_name;
        if (!(import_name[0] == '.')) return error.UnsupportedImportModule;

        const base_dir = dirname(importer_path);

        var candidate_buf: [MaxModulePathBytes]u8 = undefined;
        const exact = try joinAndNormalize(&candidate_buf, base_dir, import_name);
        if (self.sourceExists(exact)) return copyResolvedPath(exact);

        var ext_buf: [MaxModulePathBytes]u8 = undefined;
        const with_ext = try appendSuffix(&ext_buf, exact, ".gengo");
        if (self.sourceExists(with_ext)) return copyResolvedPath(with_ext);

        var mod_buf: [MaxModulePathBytes]u8 = undefined;
        const with_mod = try appendSuffix(&mod_buf, exact, "/mod.gengo");
        if (self.sourceExists(with_mod)) return copyResolvedPath(with_mod);

        self.last_error_path = importer_path;
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
        // Check capability modules — path is "cap:<name>", cm.name is "<name>"
        const cap_key = if (std.mem.startsWith(u8, path, "cap:")) path[4..] else path;
        for (self.capability_modules) |cm| {
            if (common.streq(cm.name, cap_key)) {
                for (cm.functions) |func| {
                    if (common.streq(func.name, field)) return true;
                }
                return false;
            }
        }
        return false;
    };
    const exports = &self.modules[idx];
    var i: u8 = 0;
    while (i < exports.export_count) : (i += 1) {
        if (common.streq(exports.export_names[i], field)) return true;
    }
    return false;
}

fn containsPath(paths: []const [MaxModulePathBytes]u8, lens: []const usize, needle: []const u8) bool {
    var i: usize = 0;
    while (i < lens.len) : (i += 1) {
        if (common.streq(paths[i][0..lens[i]], needle)) return true;
    }
    return false;
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
    } else |_| {
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
