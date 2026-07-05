const std = @import("std");

// Host-mounted filesystem namespace for cap:fs (issue #90).
//
// Scripts never see real paths. The host registers named mounts
// ("data" -> "/var/app/data"); script paths must start with a mount
// name and resolve inside it. Absolute paths and ".." are rejected.
//
// A mount can be backed by a real directory (MountKind.real_path) or by a
// host-provided virtual driver (MountKind.driver) — see issue #183.

pub const FsDriver = extern struct {
    open:   ?*const fn (?*anyopaque, [*]const u8, i32, i32, *i32) callconv(.c) i32 = null,
    read:   ?*const fn (?*anyopaque, i32, [*]u8, i32) callconv(.c) i32 = null,
    write:  ?*const fn (?*anyopaque, i32, [*]const u8, i32) callconv(.c) i32 = null,
    close:  ?*const fn (?*anyopaque, i32) callconv(.c) void = null,
    exists: ?*const fn (?*anyopaque, [*]const u8, i32) callconv(.c) i32 = null,
    list:   ?*const fn (?*anyopaque, [*]const u8, i32, [*]u8, i32) callconv(.c) i32 = null,
    unlink: ?*const fn (?*anyopaque, [*]const u8, i32) callconv(.c) i32 = null,
    mkdir:  ?*const fn (?*anyopaque, [*]const u8, i32) callconv(.c) i32 = null,
};

pub const MountKind = enum { real_path, driver };

pub const Mount = struct {
    name: []const u8,
    kind: MountKind = .real_path,
    real: []const u8 = "",
    driver: FsDriver = .{},
    userdata: ?*anyopaque = null,
};

const MaxMounts = 16;
const StrBufSize = 4096;

/// Per-engine mount table. Slices in `mounts` point into `str_buf` by offset;
/// copy via `loadFromEngine`/`saveToEngine` to keep pointers valid.
pub const EngineState = struct {
    mounts: [MaxMounts]Mount = undefined,
    count: usize = 0,
    str_buf: [StrBufSize]u8 = undefined,
    str_used: usize = 0,
};

var g_state: EngineState = .{};

pub const MountError = error{
    TooManyMounts,
    InvalidMountName,
    InvalidMountPath,
    OutOfMountSpace,
};

pub fn clearMounts() void {
    g_state.count = 0;
    g_state.str_used = 0;
}

pub fn mountCount() usize {
    return g_state.count;
}

/// Copy an engine's mount state into the active global, fixing up slice
/// pointers so they reference the global's str_buf rather than the engine's.
pub fn loadFromEngine(src: *const EngineState) void {
    g_state.count = src.count;
    g_state.str_used = src.str_used;
    if (src.str_used > 0)
        @memcpy(g_state.str_buf[0..src.str_used], src.str_buf[0..src.str_used]);
    const src_base = @intFromPtr(&src.str_buf);
    for (0..src.count) |i| {
        g_state.mounts[i] = src.mounts[i];
        const name_off = @intFromPtr(src.mounts[i].name.ptr) - src_base;
        g_state.mounts[i].name = g_state.str_buf[name_off..][0..src.mounts[i].name.len];
        if (src.mounts[i].kind == .real_path and src.mounts[i].real.len > 0) {
            const real_off = @intFromPtr(src.mounts[i].real.ptr) - src_base;
            g_state.mounts[i].real = g_state.str_buf[real_off..][0..src.mounts[i].real.len];
        }
    }
}

/// Register a mount into the active global state. Strings are copied into
/// the state buffer; re-adding an existing name replaces its target.
pub fn addMount(name: []const u8, real: []const u8) MountError!void {
    try addMountToState(&g_state, name, real);
}

/// Register a mount into a specific EngineState. Use this when populating
/// an engine's per-instance state outside of a run/call (e.g. engine_mount_dir).
pub fn addMountToState(state: *EngineState, name: []const u8, real: []const u8) MountError!void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidMountName;
    if (real.len == 0) return error.InvalidMountPath;

    // Strip trailing slashes from the target (keep a bare "/").
    var r = real;
    while (r.len > 1 and r[r.len - 1] == '/') r = r[0 .. r.len - 1];

    if (state.str_used + name.len + r.len > state.str_buf.len) return error.OutOfMountSpace;
    const p = state.str_buf[state.str_used + name.len ..][0..r.len];
    const n = state.str_buf[state.str_used..][0..name.len];
    @memcpy(n, name);
    @memcpy(p, r);
    state.str_used += name.len + r.len;

    for (state.mounts[0..state.count]) |*m| {
        if (std.mem.eql(u8, m.name, name)) {
            m.kind = .real_path;
            m.real = p;
            m.driver = .{};
            m.userdata = null;
            return;
        }
    }
    if (state.count >= MaxMounts) return error.TooManyMounts;
    state.mounts[state.count] = .{ .name = n, .kind = .real_path, .real = p };
    state.count += 1;
}

/// Register a virtual driver mount into a specific EngineState.
pub fn addDriverMountToState(state: *EngineState, name: []const u8, driver: FsDriver, userdata: ?*anyopaque) MountError!void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidMountName;
    if (state.str_used + name.len > state.str_buf.len) return error.OutOfMountSpace;
    const n = state.str_buf[state.str_used..][0..name.len];
    @memcpy(n, name);
    state.str_used += name.len;
    for (state.mounts[0..state.count]) |*m| {
        if (std.mem.eql(u8, m.name, name)) {
            m.kind = .driver;
            m.real = "";
            m.driver = driver;
            m.userdata = userdata;
            return;
        }
    }
    if (state.count >= MaxMounts) return error.TooManyMounts;
    state.mounts[state.count] = .{ .name = n, .kind = .driver, .driver = driver, .userdata = userdata };
    state.count += 1;
}

pub fn setMounts(mounts: []const Mount) MountError!void {
    clearMounts();
    for (mounts) |m| try addMount(m.name, m.real);
}

pub const LookupError = error{
    PathNotMounted,
    InvalidPath,
};

pub const LookupResult = struct {
    mount: *const Mount,
    rest: []const u8,
};

/// Validate a script path and return the matching mount plus the path
/// component after the mount name. Rejects absolute paths, empty
/// components, and "." / ".." traversal.
pub fn lookup(path: []const u8) LookupError!LookupResult {
    if (path.len == 0 or path[0] == '/') return error.InvalidPath;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return error.InvalidPath;
    }

    const slash = std.mem.indexOfScalar(u8, path, '/');
    const head = if (slash) |i| path[0..i] else path;
    const rest = if (slash) |i| path[i + 1 ..] else "";

    const mount = for (g_state.mounts[0..g_state.count]) |*m| {
        if (std.mem.eql(u8, m.name, head)) break m;
    } else return error.PathNotMounted;

    return .{ .mount = mount, .rest = rest };
}

pub const ResolveError = error{
    PathNotMounted,
    InvalidPath,
    PathTooLong,
};

/// Resolve a script path ("data/file.txt") to a real OS path. Only valid
/// for real_path mounts; returns PathNotMounted for driver mounts.
pub fn resolve(path: []const u8, buf: []u8) ResolveError![]const u8 {
    const lr = try lookup(path);
    if (lr.mount.kind != .real_path) return error.PathNotMounted;
    const rest = lr.rest;
    const need = lr.mount.real.len + (if (rest.len > 0) rest.len + 1 else 0);
    if (need > buf.len) return error.PathTooLong;
    @memcpy(buf[0..lr.mount.real.len], lr.mount.real);
    if (rest.len == 0) return buf[0..lr.mount.real.len];
    buf[lr.mount.real.len] = '/';
    @memcpy(buf[lr.mount.real.len + 1 ..][0..rest.len], rest);
    return buf[0..need];
}

test "resolve maps mount name to real path" {
    clearMounts();
    try addMount("data", "/var/app/data");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/var/app/data/file.txt", try resolve("data/file.txt", &buf));
    try std.testing.expectEqualStrings("/var/app/data", try resolve("data", &buf));
    try std.testing.expectEqualStrings("/var/app/data/a/b/c", try resolve("data/a/b/c", &buf));
}

test "resolve rejects unmounted prefixes" {
    clearMounts();
    try addMount("data", "/var/app/data");
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.PathNotMounted, resolve("etc/passwd", &buf));
    try std.testing.expectError(error.PathNotMounted, resolve("datax/file", &buf));
}

test "resolve rejects absolute paths and traversal" {
    clearMounts();
    try addMount("data", "/var/app/data");
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidPath, resolve("/etc/passwd", &buf));
    try std.testing.expectError(error.InvalidPath, resolve("data/../etc/passwd", &buf));
    try std.testing.expectError(error.InvalidPath, resolve("data/./x", &buf));
    try std.testing.expectError(error.InvalidPath, resolve("..", &buf));
    try std.testing.expectError(error.InvalidPath, resolve("", &buf));
    try std.testing.expectError(error.InvalidPath, resolve("data//x", &buf));
    try std.testing.expectError(error.InvalidPath, resolve("data/", &buf));
}

test "resolve with no mounts always fails" {
    clearMounts();
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.PathNotMounted, resolve("data/file.txt", &buf));
}

test "addMount validates and normalises" {
    clearMounts();
    try std.testing.expectError(error.InvalidMountName, addMount("", "/x"));
    try std.testing.expectError(error.InvalidMountName, addMount("a/b", "/x"));
    try std.testing.expectError(error.InvalidMountPath, addMount("a", ""));

    try addMount("data", "/var/data///");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/var/data/f", try resolve("data/f", &buf));

    // Replacing an existing mount keeps the count stable.
    try addMount("data", "/other");
    try std.testing.expectEqual(@as(usize, 1), mountCount());
    try std.testing.expectEqualStrings("/other/f", try resolve("data/f", &buf));
}

test "mount strings are copied, not referenced" {
    clearMounts();
    var name_buf: [4]u8 = .{ 'd', 'a', 't', 'a' };
    var real_buf: [5]u8 = .{ '/', 't', 'm', 'p', 'x' };
    try addMount(&name_buf, &real_buf);
    name_buf = .{ 'X', 'X', 'X', 'X' };
    real_buf = .{ 'X', 'X', 'X', 'X', 'X' };
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/tmpx/f", try resolve("data/f", &buf));
}

test "driver mount lookup returns mount and rest" {
    clearMounts();
    const drv: FsDriver = .{};
    var state: EngineState = .{};
    try addDriverMountToState(&state, "mem", drv, null);
    // Load so g_state has the driver mount.
    loadFromEngine(&state);

    const lr = try lookup("mem/a/b");
    try std.testing.expectEqual(MountKind.driver, lr.mount.kind);
    try std.testing.expectEqualStrings("a/b", lr.rest);

    const lr2 = try lookup("mem");
    try std.testing.expectEqual(MountKind.driver, lr2.mount.kind);
    try std.testing.expectEqualStrings("", lr2.rest);

    // resolve() must fail for a driver mount.
    var rbuf: [256]u8 = undefined;
    try std.testing.expectError(error.PathNotMounted, resolve("mem/a/b", &rbuf));
}

test "driver mount survives loadFromEngine pointer fixup" {
    clearMounts();
    var state: EngineState = .{};
    var sentinel: u32 = 0xdeadbeef;
    const drv: FsDriver = .{};
    try addDriverMountToState(&state, "vfs", drv, &sentinel);

    loadFromEngine(&state);
    try std.testing.expectEqual(@as(usize, 1), g_state.count);
    try std.testing.expectEqual(MountKind.driver, g_state.mounts[0].kind);
    try std.testing.expectEqualStrings("vfs", g_state.mounts[0].name);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), g_state.mounts[0].userdata);
}

test "driver mount replaces real_path mount with same name" {
    clearMounts();
    var state: EngineState = .{};
    try addMountToState(&state, "data", "/real/path");
    try addDriverMountToState(&state, "data", .{}, null);
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqual(MountKind.driver, state.mounts[0].kind);
}
