const std = @import("std");
const package_state = @import("lang/native/package_state.zig");

pub const Root = struct {
    name: []const u8,
    directory: []const u8,
};

pub const Error = error{
    InvalidRootName,
    InvalidRelativePath,
    ArchivePathTooLong,
    DuplicateArchivePath,
    EntryNotFound,
    TooManySourceFiles,
};

pub const ArchiveFile = struct {
    path: []const u8,
    contents: []const u8,
};

pub const BuildResult = struct {
    archive: []u8,
    source_count: usize,
};

const CollectedFile = struct {
    path: []u8,
    contents: []u8,
};

const ZipRecord = struct {
    file: ArchiveFile,
    crc32: u32,
    local_offset: u32,
};

pub fn writeStoredZip(allocator: std.mem.Allocator, files: []const ArchiveFile) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    const records = try allocator.alloc(ZipRecord, files.len);
    defer allocator.free(records);

    for (files, 0..) |file, index| {
        if (file.path.len == 0 or file.path.len > std.math.maxInt(u16) or file.contents.len > std.math.maxInt(u32)) {
            return error.InvalidZipEntry;
        }
        records[index] = .{
            .file = file,
            .crc32 = std.hash.crc.Crc32.hash(file.contents),
            .local_offset = try u32Offset(bytes.items.len),
        };
        try appendU32(&bytes, allocator, 0x04034b50);
        try appendU16(&bytes, allocator, 20);
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU32(&bytes, allocator, records[index].crc32);
        try appendU32(&bytes, allocator, @intCast(file.contents.len));
        try appendU32(&bytes, allocator, @intCast(file.contents.len));
        try appendU16(&bytes, allocator, @intCast(file.path.len));
        try appendU16(&bytes, allocator, 0);
        try bytes.appendSlice(allocator, file.path);
        try bytes.appendSlice(allocator, file.contents);
    }

    const central_offset = try u32Offset(bytes.items.len);
    for (records) |record| {
        try appendU32(&bytes, allocator, 0x02014b50);
        try appendU16(&bytes, allocator, 20);
        try appendU16(&bytes, allocator, 20);
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU32(&bytes, allocator, record.crc32);
        try appendU32(&bytes, allocator, @intCast(record.file.contents.len));
        try appendU32(&bytes, allocator, @intCast(record.file.contents.len));
        try appendU16(&bytes, allocator, @intCast(record.file.path.len));
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU16(&bytes, allocator, 0);
        try appendU32(&bytes, allocator, 0);
        try appendU32(&bytes, allocator, record.local_offset);
        try bytes.appendSlice(allocator, record.file.path);
    }

    const central_size = try u32Offset(bytes.items.len - central_offset);
    if (records.len > std.math.maxInt(u16)) return error.InvalidZipEntry;
    try appendU32(&bytes, allocator, 0x06054b50);
    try appendU16(&bytes, allocator, 0);
    try appendU16(&bytes, allocator, 0);
    try appendU16(&bytes, allocator, @intCast(records.len));
    try appendU16(&bytes, allocator, @intCast(records.len));
    try appendU32(&bytes, allocator, central_size);
    try appendU32(&bytes, allocator, central_offset);
    try appendU16(&bytes, allocator, 0);

    return bytes.toOwnedSlice(allocator);
}

fn appendU16(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var raw: [2]u8 = undefined;
    std.mem.writeInt(u16, &raw, value, .little);
    try bytes.appendSlice(allocator, &raw);
}

fn appendU32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var raw: [4]u8 = undefined;
    std.mem.writeInt(u32, &raw, value, .little);
    try bytes.appendSlice(allocator, &raw);
}

fn u32Offset(value: usize) !u32 {
    if (value > std.math.maxInt(u32)) return error.ArchiveTooLarge;
    return @intCast(value);
}

pub fn buildFromRoots(
    allocator: std.mem.Allocator,
    roots: []const Root,
    entry: []const u8,
    includes: []const []const u8,
    excludes: []const []const u8,
) !BuildResult {
    if (roots.len == 0) return error.InvalidRootName;
    if (!std.mem.endsWith(u8, entry, ".gengo")) return error.EntryNotFound;

    var collected: std.ArrayList(CollectedFile) = .empty;
    defer {
        for (collected.items) |file| {
            allocator.free(file.path);
            allocator.free(file.contents);
        }
        collected.deinit(allocator);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    for (roots) |root| {
        try validateRootName(root.name);

        const dir = std.Io.Dir.cwd().openDir(io, root.directory, .{ .iterate = true }) catch return error.InvalidRelativePath;
        defer dir.close(io);
        var walker = dir.walk(allocator) catch return error.OutOfMemory;
        defer walker.deinit();

        while (walker.next(io) catch return error.InvalidRelativePath) |file| {
            if (file.kind != .file) continue;
            const relative_path: []const u8 = file.path;
            if (!shouldInclude(relative_path, includes, excludes)) continue;
            if (collected.items.len >= package_state.MaxFilesPerPackage) return error.TooManySourceFiles;

            const archive_path = try allocator.alloc(u8, root.name.len + 1 + relative_path.len);
            errdefer allocator.free(archive_path);
            const full_path = try archivePath(root, relative_path, archive_path);
            if (full_path.len - ".gengo".len > 127) return error.ArchivePathTooLong;
            for (collected.items) |existing| {
                if (std.mem.eql(u8, existing.path, full_path)) return error.DuplicateArchivePath;
            }

            const contents = file.dir.readFileAlloc(io, file.basename, allocator, .limited(package_state.MaxFileSize)) catch |err| {
                if (err == error.StreamTooLong) return error.FileTooLarge;
                return err;
            };
            try collected.append(allocator, .{ .path = archive_path, .contents = contents });
        }
    }

    var entry_found = false;
    for (collected.items) |file| {
        if (std.mem.eql(u8, file.path, entry)) {
            entry_found = true;
            break;
        }
    }
    if (!entry_found) return error.EntryNotFound;

    const manifest = try std.fmt.allocPrint(allocator, "format=gengo.bundle.v1\nentry={s}\n", .{entry});
    const manifest_path = try allocator.dupe(u8, "gengo.manifest");
    try collected.append(allocator, .{ .path = manifest_path, .contents = manifest });

    const archive_files = try allocator.alloc(ArchiveFile, collected.items.len);
    defer allocator.free(archive_files);
    for (collected.items, 0..) |file, index| {
        archive_files[index] = .{ .path = file.path, .contents = file.contents };
    }
    return .{
        .archive = try writeStoredZip(allocator, archive_files),
        .source_count = collected.items.len - 1,
    };
}

pub fn archivePath(root: Root, relative_path: []const u8, out: []u8) Error![]const u8 {
    try validateRootName(root.name);
    if (relative_path.len == 0 or relative_path[0] == '/' or std.mem.indexOf(u8, relative_path, "..") != null) {
        return error.InvalidRelativePath;
    }
    const len = root.name.len + 1 + relative_path.len;
    if (len > out.len) return error.ArchivePathTooLong;
    @memcpy(out[0..root.name.len], root.name);
    out[root.name.len] = '/';
    @memcpy(out[root.name.len + 1 .. len], relative_path);
    return out[0..len];
}

fn validateRootName(name: []const u8) Error!void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOf(u8, name, "..") != null) {
        return error.InvalidRootName;
    }
}

pub fn shouldInclude(path: []const u8, includes: []const []const u8, excludes: []const []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".gengo")) return false;
    if (includes.len > 0) {
        var matched = false;
        for (includes) |pattern| {
            if (globMatch(pattern, path)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    for (excludes) |pattern| {
        if (globMatch(pattern, path)) return false;
    }
    return true;
}

pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globMatchAt(pattern, path, 0, 0);
}

fn globMatchAt(pattern: []const u8, path: []const u8, pattern_pos: usize, path_pos: usize) bool {
    if (pattern_pos == pattern.len) return path_pos == path.len;
    if (pattern[pattern_pos] == '*') {
        if (pattern_pos + 1 < pattern.len and pattern[pattern_pos + 1] == '*') {
            var next = pattern_pos + 2;
            if (next < pattern.len and pattern[next] == '/') next += 1;
            var pos = path_pos;
            while (true) {
                if (globMatchAt(pattern, path, next, pos)) return true;
                if (pos == path.len) return false;
                pos += 1;
            }
        }
        var pos = path_pos;
        while (true) {
            if (globMatchAt(pattern, path, pattern_pos + 1, pos)) return true;
            if (pos == path.len or path[pos] == '/') return false;
            pos += 1;
        }
    }
    if (path_pos == path.len or pattern[pattern_pos] != path[path_pos]) return false;
    return globMatchAt(pattern, path, pattern_pos + 1, path_pos + 1);
}

test "archive paths preserve roots and reject escapes" {
    var out: [128]u8 = undefined;
    const path = try archivePath(.{ .name = "shared", .directory = "./shared" }, "net/http.gengo", &out);
    try std.testing.expectEqualStrings("shared/net/http.gengo", path);
    try std.testing.expectError(error.InvalidRootName, archivePath(.{ .name = "../shared", .directory = "./shared" }, "http.gengo", &out));
    try std.testing.expectError(error.InvalidRelativePath, archivePath(.{ .name = "shared", .directory = "./shared" }, "../http.gengo", &out));
}

test "filters default to Gengoscript sources and exclusions win" {
    try std.testing.expect(shouldInclude("net/http.gengo", &.{}, &.{}));
    try std.testing.expect(!shouldInclude("README.md", &.{}, &.{}));
    try std.testing.expect(shouldInclude("net/http.gengo", &.{"**/*.gengo"}, &.{}));
    try std.testing.expect(!shouldInclude("net/http_test.gengo", &.{"**/*.gengo"}, &.{"**/*_test.gengo"}));
    try std.testing.expect(!shouldInclude("internal/debug.gengo", &.{"public/**/*.gengo"}, &.{}));
}

test "stored bundles preserve multiple roots for the package loader" {
    const files = [_]ArchiveFile{
        .{ .path = "app/main.gengo", .contents = "pub const answer = 42\n" },
        .{ .path = "shared/math.gengo", .contents = "pub const pi = 3\n" },
        .{ .path = "gengo.manifest", .contents = "format=gengo.bundle.v1\nentry=app/main.gengo\n" },
    };
    const archive = try writeStoredZip(std.testing.allocator, &files);
    defer std.testing.allocator.free(archive);

    var registry = package_state.PackageRegistry{};
    defer package_state.clearRegistry(&registry);
    try package_state.loadFromZip(&registry, "demo", archive);

    try std.testing.expectEqualStrings("pub const answer = 42\n", package_state.resolve(&registry, "demo/app/main").?);
    try std.testing.expectEqualStrings("pub const pi = 3\n", package_state.resolve(&registry, "demo/shared/math").?);
}
