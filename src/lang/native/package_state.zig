const std = @import("std");
const builtin = @import("builtin");
const cfg = @import("runtime_config");

pub const MaxPackages: usize = 32;
pub const MaxFilesPerPackage: usize = 64;
// Don't decompress a file the compiler can't accept; max_input_bytes is the
// exact ceiling because the compiler rejects anything larger at compile time.
pub const MaxFileSize: usize = cfg.max_input_bytes;

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

// Zip header fields (offsets/sizes) are u32 and attacker-controlled by the
// bundle's own bytes, independent of the actual data.len; a plain `a + b`
// bounds check can wrap on a 32-bit usize target (this codebase's primary
// target is WASI/wasm32) even though it can't wrap on a 64-bit usize. A
// wrapped sum passes a `> data.len` check it should have failed, and the
// (unwrapped, still-huge) offset then drives an out-of-bounds slice/pointer
// dereference. engine_load_bundle/engine_load_bundle_dir are host-only entry
// points (never reachable from a Gengo script), but a malformed/crafted zip
// bundle should still fail loudly rather than corrupt memory or trap.
fn checkedAdd(a: usize, b: usize) LoadError!usize {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.InvalidZip;
    return sum;
}

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
    const cd_range_end = try checkedAdd(cd_offset, cd_size);
    if (cd_range_end > data.len) return error.InvalidZip;

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
    const cd_end: usize = cd_range_end;

    while (cd_pos + @sizeOf(std.zip.CentralDirectoryFileHeader) <= cd_end) {
        const cd_hdr: *align(1) const std.zip.CentralDirectoryFileHeader =
            @ptrCast(data[cd_pos..].ptr);

        if (!std.mem.eql(u8, &cd_hdr.signature, &std.zip.central_file_header_sig)) break;

        const fn_start = cd_pos + @sizeOf(std.zip.CentralDirectoryFileHeader);
        const fn_len: usize = cd_hdr.filename_len;
        const fn_end = try checkedAdd(fn_start, fn_len);
        if (fn_end > data.len) return error.InvalidZip;
        const filename = data[fn_start..fn_end];

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
        const local_hdr_end = try checkedAdd(local_off, @sizeOf(std.zip.LocalFileHeader));
        if (local_hdr_end > data.len) return error.InvalidZip;
        const lhdr: *align(1) const std.zip.LocalFileHeader = @ptrCast(data[local_off..].ptr);
        if (!std.mem.eql(u8, &lhdr.signature, &std.zip.local_file_header_sig)) return error.InvalidZip;

        const data_start = try checkedAdd(try checkedAdd(local_hdr_end, lhdr.filename_len), lhdr.extra_len);
        const csize: usize = cd_hdr.compressed_size;
        const data_end = try checkedAdd(data_start, csize);
        if (data_end > data.len) return error.InvalidZip;

        const compressed = data[data_start..data_end];
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

// Regression: loadFromZip's bounds checks on zip header offset/size fields
// (all attacker-controlled u32s from the bundle's own bytes) used plain `a +
// b > data.len` additions. That can't overflow a 64-bit usize for two u32
// values, but this codebase's primary target is WASI/wasm32, where usize is
// 32-bit — there a wrapped sum can pass a bounds check it should have
// failed, and the (still-huge) unwrapped offset then drives an
// out-of-bounds slice/pointer dereference. Can't reproduce the wraparound
// itself on a 64-bit test host with real u32 zip fields, so this exercises
// checkedAdd directly with genuinely usize-overflowing input instead.
test "checkedAdd rejects usize overflow instead of wrapping" {
    try std.testing.expectError(error.InvalidZip, checkedAdd(std.math.maxInt(usize), 1));
    try std.testing.expectError(error.InvalidZip, checkedAdd(std.math.maxInt(usize) - 3, 10));
    try std.testing.expectEqual(@as(usize, 5), try checkedAdd(2, 3));
    try std.testing.expectEqual(@as(usize, 0), try checkedAdd(0, 0));
}

// ── loadFromZip test helpers ────────────────────────────────────────────────
//
// std.zip (Zig 0.16) exposes only reading/central-directory-parsing structs,
// no writer API, so these hand-roll the byte layout loadFromZip expects:
// one std.zip.LocalFileHeader (30 bytes) + name + data per entry, followed
// by one std.zip.CentralDirectoryFileHeader (46 bytes) + name per entry,
// followed by a std.zip.EndRecord (22 bytes). All entries use the `store`
// compression method (compression_method = 0) so no deflate encoder is
// needed; loadFromZip doesn't verify crc32, so it's left as 0 throughout.

const TestZipEntry = struct {
    name: []const u8,
    data: []const u8 = "",
};

fn buildZipStore(allocator: std.mem.Allocator, entries: []const TestZipEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const local_offsets = try allocator.alloc(u32, entries.len);
    defer allocator.free(local_offsets);

    for (entries, 0..) |e, i| {
        local_offsets[i] = @intCast(buf.items.len);

        var lfh: [30]u8 = undefined;
        @memcpy(lfh[0..4], &std.zip.local_file_header_sig);
        std.mem.writeInt(u16, lfh[4..6], 20, .little); // version_needed_to_extract
        std.mem.writeInt(u16, lfh[6..8], 0, .little); // flags
        std.mem.writeInt(u16, lfh[8..10], 0, .little); // compression_method = store
        std.mem.writeInt(u16, lfh[10..12], 0, .little); // last_modification_time
        std.mem.writeInt(u16, lfh[12..14], 0, .little); // last_modification_date
        std.mem.writeInt(u32, lfh[14..18], 0, .little); // crc32
        std.mem.writeInt(u32, lfh[18..22], @intCast(e.data.len), .little); // compressed_size
        std.mem.writeInt(u32, lfh[22..26], @intCast(e.data.len), .little); // uncompressed_size
        std.mem.writeInt(u16, lfh[26..28], @intCast(e.name.len), .little); // filename_len
        std.mem.writeInt(u16, lfh[28..30], 0, .little); // extra_len
        try buf.appendSlice(allocator, &lfh);
        try buf.appendSlice(allocator, e.name);
        try buf.appendSlice(allocator, e.data);
    }

    const cd_start: u32 = @intCast(buf.items.len);
    for (entries, 0..) |e, i| {
        var cdh: [46]u8 = undefined;
        @memcpy(cdh[0..4], &std.zip.central_file_header_sig);
        std.mem.writeInt(u16, cdh[4..6], 20, .little); // version_made_by
        std.mem.writeInt(u16, cdh[6..8], 20, .little); // version_needed_to_extract
        std.mem.writeInt(u16, cdh[8..10], 0, .little); // flags
        std.mem.writeInt(u16, cdh[10..12], 0, .little); // compression_method = store
        std.mem.writeInt(u16, cdh[12..14], 0, .little); // last_modification_time
        std.mem.writeInt(u16, cdh[14..16], 0, .little); // last_modification_date
        std.mem.writeInt(u32, cdh[16..20], 0, .little); // crc32
        std.mem.writeInt(u32, cdh[20..24], @intCast(e.data.len), .little); // compressed_size
        std.mem.writeInt(u32, cdh[24..28], @intCast(e.data.len), .little); // uncompressed_size
        std.mem.writeInt(u16, cdh[28..30], @intCast(e.name.len), .little); // filename_len
        std.mem.writeInt(u16, cdh[30..32], 0, .little); // extra_len
        std.mem.writeInt(u16, cdh[32..34], 0, .little); // comment_len
        std.mem.writeInt(u16, cdh[34..36], 0, .little); // disk_number
        std.mem.writeInt(u16, cdh[36..38], 0, .little); // internal_file_attributes
        std.mem.writeInt(u32, cdh[38..42], 0, .little); // external_file_attributes
        std.mem.writeInt(u32, cdh[42..46], local_offsets[i], .little); // local_file_header_offset
        try buf.appendSlice(allocator, &cdh);
        try buf.appendSlice(allocator, e.name);
    }
    const cd_size: u32 = @intCast(buf.items.len - cd_start);

    var eocd: [22]u8 = undefined;
    @memcpy(eocd[0..4], &std.zip.end_record_sig);
    std.mem.writeInt(u16, eocd[4..6], 0, .little); // disk_number
    std.mem.writeInt(u16, eocd[6..8], 0, .little); // central_directory_disk_number
    std.mem.writeInt(u16, eocd[8..10], @intCast(entries.len), .little); // record_count_disk
    std.mem.writeInt(u16, eocd[10..12], @intCast(entries.len), .little); // record_count_total
    std.mem.writeInt(u32, eocd[12..16], cd_size, .little); // central_directory_size
    std.mem.writeInt(u32, eocd[16..20], cd_start, .little); // central_directory_offset
    std.mem.writeInt(u16, eocd[20..22], 0, .little); // comment_len
    try buf.appendSlice(allocator, &eocd);

    return try buf.toOwnedSlice(allocator);
}

test "loadFromZip: happy path extracts .gengo files with store compression" {
    const allocator = std.testing.allocator;
    const src_a = "pub func a() int { return 1 }";
    const src_b = "pub func b() int { return 2 }";
    const zip_bytes = try buildZipStore(allocator, &.{
        .{ .name = "a.gengo", .data = src_a },
        .{ .name = "b.gengo", .data = src_b },
    });
    defer allocator.free(zip_bytes);

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    try loadFromZip(&reg, "mypkg", zip_bytes);

    const found_a = resolve(&reg, "mypkg/a");
    try std.testing.expect(found_a != null);
    try std.testing.expectEqualStrings(src_a, found_a.?);

    const found_b = resolve(&reg, "mypkg/b");
    try std.testing.expect(found_b != null);
    try std.testing.expectEqualStrings(src_b, found_b.?);
}

test "loadFromZip: skips non-.gengo files and directory entries" {
    const allocator = std.testing.allocator;
    const src = "pub func c() int { return 3 }";
    const zip_bytes = try buildZipStore(allocator, &.{
        .{ .name = "readme.txt", .data = "not gengo source" },
        .{ .name = "dir/", .data = "" },
        .{ .name = "c.gengo", .data = src },
    });
    defer allocator.free(zip_bytes);

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    try loadFromZip(&reg, "mypkg", zip_bytes);

    try std.testing.expect(resolve(&reg, "mypkg/readme") == null);
    try std.testing.expect(resolve(&reg, "mypkg/readme.txt") == null);
    try std.testing.expect(resolve(&reg, "mypkg/dir") == null);
    const found = resolve(&reg, "mypkg/c");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(src, found.?);
}

test "loadFromZip: skips filenames containing path traversal" {
    const allocator = std.testing.allocator;
    const zip_bytes = try buildZipStore(allocator, &.{
        .{ .name = "../evil.gengo", .data = "pub func evil() int { return 666 }" },
    });
    defer allocator.free(zip_bytes);

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    try loadFromZip(&reg, "mypkg", zip_bytes);

    try std.testing.expect(resolve(&reg, "mypkg/evil") == null);
    try std.testing.expect(resolve(&reg, "mypkg/../evil") == null);
}

test "loadFromZip: FileTooLarge when declared uncompressed_size exceeds MaxFileSize" {
    const allocator = std.testing.allocator;
    const name = "big.gengo";
    const data = "tiny";
    const zip_bytes = try buildZipStore(allocator, &.{
        .{ .name = name, .data = data },
    });
    defer allocator.free(zip_bytes);

    // Patch the central directory entry's uncompressed_size field (offset
    // +24 within CentralDirectoryFileHeader, right after the local file
    // header + name + data) to exceed MaxFileSize. loadFromZip's
    // FileTooLarge check fires before the local header or compressed data
    // are ever touched, so the (now-mismatched) local header can stay as-is.
    const local_size: u32 = 30 + @as(u32, @intCast(name.len)) + @as(u32, @intCast(data.len));
    const huge: u32 = @intCast(MaxFileSize + 1);
    std.mem.writeInt(u32, zip_bytes[local_size + 24 ..][0..4], huge, .little);

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    try std.testing.expectError(error.FileTooLarge, loadFromZip(&reg, "mypkg", zip_bytes));
}

test "loadFromZip: InvalidZip when no end-of-central-directory record is found" {
    var reg = PackageRegistry{};
    defer clearRegistry(&reg);
    try std.testing.expectError(error.InvalidZip, loadFromZip(&reg, "mypkg", "not a zip file at all"));
}

test "loadFromZip: InvalidZip when end record's cd_offset/cd_size overflow the buffer" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const padding = [_]u8{0} ** 20;
    try buf.appendSlice(allocator, &padding);

    var eocd: [22]u8 = undefined;
    @memcpy(eocd[0..4], &std.zip.end_record_sig);
    std.mem.writeInt(u16, eocd[4..6], 0, .little);
    std.mem.writeInt(u16, eocd[6..8], 0, .little);
    std.mem.writeInt(u16, eocd[8..10], 1, .little);
    std.mem.writeInt(u16, eocd[10..12], 1, .little);
    std.mem.writeInt(u32, eocd[12..16], 0x1000, .little); // cd_size
    std.mem.writeInt(u32, eocd[16..20], 0xFFFFFF00, .little); // cd_offset: nowhere near the buffer
    std.mem.writeInt(u16, eocd[20..22], 0, .little);
    try buf.appendSlice(allocator, &eocd);

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);
    try std.testing.expectError(error.InvalidZip, loadFromZip(&reg, "mypkg", buf.items));
}

test "loadFromZip: PackageTableFull after MaxPackages successful loads" {
    const allocator = std.testing.allocator;
    const zip_bytes = try buildZipStore(allocator, &.{
        .{ .name = "m.gengo", .data = "pub func m() int { return 0 }" },
    });
    defer allocator.free(zip_bytes);

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    var i: usize = 0;
    while (i < MaxPackages) : (i += 1) {
        var namebuf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "pkg{d}", .{i});
        try loadFromZip(&reg, name, zip_bytes);
    }
    try std.testing.expectEqual(@as(u8, MaxPackages), reg.count);

    try std.testing.expectError(error.PackageTableFull, loadFromZip(&reg, "one_too_many", zip_bytes));
}

test "loadFromZip: FileTableFull after MaxFilesPerPackage files in one package" {
    const allocator = std.testing.allocator;
    var entries: [MaxFilesPerPackage + 1]TestZipEntry = undefined;
    var namebufs: [MaxFilesPerPackage + 1][16]u8 = undefined;
    for (0..entries.len) |i| {
        const nm = try std.fmt.bufPrint(&namebufs[i], "f{d}.gengo", .{i});
        entries[i] = .{ .name = nm, .data = "pub func f() int { return 0 }" };
    }
    const zip_bytes = try buildZipStore(allocator, &entries);
    defer allocator.free(zip_bytes);

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    try std.testing.expectError(error.FileTableFull, loadFromZip(&reg, "manyfiles", zip_bytes));
}

test "loadFromDir: happy path walks nested directories for .gengo files" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(tmp_path);

    const src_top = "pub func top() int { return 1 }";
    const src_inner = "pub func inner() int { return 2 }";

    try tmp.dir.writeFile(io, .{ .sub_path = "top.gengo", .data = src_top });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/inner.gengo", .data = src_inner });

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    try loadFromDir(&reg, "dirpkg", tmp_path);

    const found_top = resolve(&reg, "dirpkg/top");
    try std.testing.expect(found_top != null);
    try std.testing.expectEqualStrings(src_top, found_top.?);

    const found_inner = resolve(&reg, "dirpkg/sub/inner");
    try std.testing.expect(found_inner != null);
    try std.testing.expectEqualStrings(src_inner, found_inner.?);
}

test "loadFromDir: ignores non-.gengo files" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(tmp_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "just text" });
    try tmp.dir.writeFile(io, .{ .sub_path = "real.gengo", .data = "pub func real() int { return 5 }" });

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    try loadFromDir(&reg, "dirpkg2", tmp_path);

    try std.testing.expect(resolve(&reg, "dirpkg2/notes") == null);
    try std.testing.expect(resolve(&reg, "dirpkg2/notes.txt") == null);
    const found = resolve(&reg, "dirpkg2/real");
    try std.testing.expect(found != null);
}

test "loadFromDir: FileTableFull when more than MaxFilesPerPackage .gengo files exist" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(tmp_path);

    var i: usize = 0;
    while (i < MaxFilesPerPackage + 1) : (i += 1) {
        var namebuf: [24]u8 = undefined;
        const nm = try std.fmt.bufPrint(&namebuf, "f{d}.gengo", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = nm, .data = "pub func f() int { return 0 }" });
    }

    var reg = PackageRegistry{};
    defer clearRegistry(&reg);

    try std.testing.expectError(error.FileTableFull, loadFromDir(&reg, "toomany", tmp_path));
}
