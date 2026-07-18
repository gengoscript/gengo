const std = @import("std");
const builtin = @import("builtin");

pub const MaxPackages: usize = 32;
pub const MaxFilesPerPackage: usize = 64;
pub const MaxFileSize: usize = 65536;

pub const PackageFile = struct {
    path: [128]u8 = undefined,
    path_len: u8 = 0,
    src_ptr: [*]u8 = undefined,
    src_len: u32 = 0,
};

pub const Package = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    files: [MaxFilesPerPackage]PackageFile = undefined,
    file_count: u8 = 0,
};

pub const PackageRegistry = struct {
    packages: [MaxPackages]Package = undefined,
    count: u8 = 0,
};

pub fn clearRegistry(reg: *PackageRegistry) void {
    for (reg.packages[0..reg.count]) |*pkg| {
        for (pkg.files[0..pkg.file_count]) |*f| {
            std.heap.page_allocator.free(f.src_ptr[0..f.src_len]);
        }
    }
    reg.count = 0;
}

pub fn resolve(reg: *const PackageRegistry, import_path: []const u8) ?[]const u8 {
    const path = if (std.mem.endsWith(u8, import_path, ".gengo"))
        import_path[0 .. import_path.len - 6]
    else
        import_path;

    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const pkg_name = path[0..slash];
    const file_path = path[slash + 1 ..];
    if (file_path.len == 0) return null;

    for (reg.packages[0..reg.count]) |*pkg| {
        if (!std.mem.eql(u8, pkg.name[0..pkg.name_len], pkg_name)) continue;
        for (pkg.files[0..pkg.file_count]) |*f| {
            if (std.mem.eql(u8, f.path[0..f.path_len], file_path)) {
                return f.src_ptr[0..f.src_len];
            }
        }
        return null;
    }
    return null;
}

pub const LoadError = error{
    PackageTableFull,
    FileTableFull,
    FileTooLarge,
    InvalidZip,
    InvalidPath,
    OutOfMemory,
};

// std.zip.EndRecord.findBuffer has a bug (returns error.EndOfStream not in its error set).
// Walk the buffer manually to find the end-of-central-directory record.
fn findEndRecord(data: []const u8) ?struct { cd_offset: u32, cd_size: u32 } {
    const end_sig = std.zip.end_record_sig;
    const min_end = @sizeOf(std.zip.EndRecord);
    if (data.len < min_end) return null;
    var i: usize = data.len - min_end;
    while (true) {
        if (std.mem.eql(u8, data[i .. i + 4], &end_sig)) {
            const cd_size = std.mem.readInt(u32, data[i + 12 ..][0..4], .little);
            const cd_offset = std.mem.readInt(u32, data[i + 16 ..][0..4], .little);
            return .{ .cd_offset = cd_offset, .cd_size = cd_size };
        }
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

pub fn loadFromZip(reg: *PackageRegistry, name: []const u8, data: []const u8) LoadError!void {
    if (reg.count >= MaxPackages) return error.PackageTableFull;
    if (name.len == 0 or name.len > 64) return error.InvalidPath;

    const end_rec = findEndRecord(data) orelse return error.InvalidZip;
    const cd_offset: usize = @intCast(end_rec.cd_offset);
    const cd_size: usize = @intCast(end_rec.cd_size);
    if (cd_offset + cd_size > data.len) return error.InvalidZip;

    var pkg = &reg.packages[reg.count];
    pkg.name_len = @intCast(name.len);
    @memcpy(pkg.name[0..name.len], name);
    pkg.file_count = 0;

    errdefer {
        for (pkg.files[0..pkg.file_count]) |*f| {
            std.heap.page_allocator.free(f.src_ptr[0..f.src_len]);
        }
        pkg.file_count = 0;
    }

    var cd_pos: usize = cd_offset;
    const cd_end: usize = cd_offset + cd_size;

    while (cd_pos + @sizeOf(std.zip.CentralDirectoryFileHeader) <= cd_end) {
        const cd_hdr: *align(1) const std.zip.CentralDirectoryFileHeader =
            @ptrCast(data[cd_pos..].ptr);

        if (!std.mem.eql(u8, &cd_hdr.signature, &std.zip.central_file_header_sig)) break;

        const fn_start = cd_pos + @sizeOf(std.zip.CentralDirectoryFileHeader);
        const fn_len: usize = cd_hdr.filename_len;
        if (fn_start + fn_len > data.len) return error.InvalidZip;
        const filename = data[fn_start .. fn_start + fn_len];

        cd_pos += @sizeOf(std.zip.CentralDirectoryFileHeader) +
            @as(usize, cd_hdr.filename_len) +
            @as(usize, cd_hdr.extra_len) +
            @as(usize, cd_hdr.comment_len);

        if (filename.len == 0 or filename[filename.len - 1] == '/') continue;
        if (!std.mem.endsWith(u8, filename, ".gengo")) continue;
        if (std.mem.indexOf(u8, filename, "..") != null) continue;

        const module_path = filename[0 .. filename.len - 6];
        if (module_path.len == 0 or module_path.len > 127) continue;

        if (pkg.file_count >= MaxFilesPerPackage) return error.FileTableFull;
        if (cd_hdr.uncompressed_size > MaxFileSize) return error.FileTooLarge;

        const method = cd_hdr.compression_method;
        if (method != .store and method != .deflate) continue;

        const local_off: usize = cd_hdr.local_file_header_offset;
        if (local_off + @sizeOf(std.zip.LocalFileHeader) > data.len) return error.InvalidZip;
        const lhdr: *align(1) const std.zip.LocalFileHeader = @ptrCast(data[local_off..].ptr);
        if (!std.mem.eql(u8, &lhdr.signature, &std.zip.local_file_header_sig)) return error.InvalidZip;

        const data_start = local_off + @sizeOf(std.zip.LocalFileHeader) +
            @as(usize, lhdr.filename_len) + @as(usize, lhdr.extra_len);
        const csize: usize = cd_hdr.compressed_size;
        if (data_start + csize > data.len) return error.InvalidZip;

        const compressed = data[data_start .. data_start + csize];
        const usize_unc: usize = cd_hdr.uncompressed_size;

        const src_buf = std.heap.page_allocator.alloc(u8, usize_unc) catch return error.OutOfMemory;
        errdefer std.heap.page_allocator.free(src_buf);

        switch (method) {
            .store => {
                if (compressed.len != usize_unc) return error.InvalidZip;
                @memcpy(src_buf, compressed);
            },
            .deflate => {
                var comp_reader = std.Io.Reader.fixed(compressed);
                var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
                var decomp: std.compress.flate.Decompress = .init(&comp_reader, .raw, &flate_buf);
                decomp.reader.readSliceAll(src_buf) catch return error.InvalidZip;
            },
            else => unreachable,
        }

        const fi = &pkg.files[pkg.file_count];
        fi.path_len = @intCast(module_path.len);
        @memcpy(fi.path[0..module_path.len], module_path);
        fi.src_ptr = src_buf.ptr;
        fi.src_len = @intCast(usize_unc);
        pkg.file_count += 1;
    }

    reg.count += 1;
}

pub fn loadFromDir(reg: *PackageRegistry, name: []const u8, dir_path: []const u8) LoadError!void {
    if (comptime builtin.os.tag == .wasi) return error.InvalidPath;
    if (reg.count >= MaxPackages) return error.PackageTableFull;
    if (name.len == 0 or name.len > 64) return error.InvalidPath;

    const io = std.Io.Threaded.global_single_threaded.io();
    const page_alloc = std.heap.page_allocator;

    var pkg = &reg.packages[reg.count];
    pkg.name_len = @intCast(name.len);
    @memcpy(pkg.name[0..name.len], name);
    pkg.file_count = 0;

    errdefer {
        for (pkg.files[0..pkg.file_count]) |*f| {
            page_alloc.free(f.src_ptr[0..f.src_len]);
        }
        pkg.file_count = 0;
    }

    const dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.InvalidPath;
    defer dir.close(io);

    var walker = dir.walk(page_alloc) catch return error.OutOfMemory;
    defer walker.deinit();

    while (walker.next(io) catch return error.InvalidPath) |entry| {
        if (entry.kind != .file) continue;
        const bname: []const u8 = entry.basename;
        if (!std.mem.endsWith(u8, bname, ".gengo")) continue;
        const raw_path: []const u8 = entry.path;
        if (std.mem.indexOf(u8, raw_path, "..") != null) continue;
        if (raw_path.len < 6) continue;
        const mod_path = raw_path[0 .. raw_path.len - 6];
        if (mod_path.len == 0 or mod_path.len > 127) continue;
        if (pkg.file_count >= MaxFilesPerPackage) return error.FileTableFull;

        const contents = entry.dir.readFileAlloc(io, bname, page_alloc, .limited(MaxFileSize)) catch |err| {
            if (err == error.StreamTooLong) return error.FileTooLarge;
            continue;
        };

        const fi = &pkg.files[pkg.file_count];
        fi.path_len = @intCast(mod_path.len);
        @memcpy(fi.path[0..mod_path.len], mod_path);
        fi.src_ptr = contents.ptr;
        fi.src_len = @intCast(contents.len);
        pkg.file_count += 1;
    }

    reg.count += 1;
}

test "resolve finds file in package" {
    var reg = PackageRegistry{};
    const src = "pub func hello() string { return \"hi\" }";
    var pkg = Package{};
    pkg.name_len = 5;
    @memcpy(pkg.name[0..5], "mylib");
    var fi = PackageFile{};
    fi.path_len = 4;
    @memcpy(fi.path[0..4], "core");
    fi.src_ptr = @constCast(src.ptr);
    fi.src_len = @intCast(src.len);
    pkg.files[0] = fi;
    pkg.file_count = 1;
    reg.packages[0] = pkg;
    reg.count = 1;

    const found = resolve(&reg, "mylib/core");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(src, found.?);

    const not_found = resolve(&reg, "mylib/missing");
    try std.testing.expect(not_found == null);

    const wrong_pkg = resolve(&reg, "other/core");
    try std.testing.expect(wrong_pkg == null);

    const with_ext = resolve(&reg, "mylib/core.gengo");
    try std.testing.expect(with_ext != null);
}
