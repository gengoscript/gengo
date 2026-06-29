const std = @import("std");

// Host-mounted filesystem namespace for cap:fs (issue #90).
//
// Scripts never see real paths. The host registers named mounts
// ("data" -> "/var/app/data"); script paths must start with a mount
// name and resolve inside it. Absolute paths and ".." are rejected.

pub const Mount = struct {
    name: []const u8,
    real: []const u8,
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
        const name_off = @intFromPtr(src.mounts[i].name.ptr) - src_base;
        const real_off = @intFromPtr(src.mounts[i].real.ptr) - src_base;
        g_state.mounts[i] = .{
            .name = g_state.str_buf[name_off..][0..src.mounts[i].name.len],
            .real = g_state.str_buf[real_off..][0..src.mounts[i].real.len],
        };
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
            m.real = p;
            return;
        }
    }
    if (state.count >= MaxMounts) return error.TooManyMounts;
    state.mounts[state.count] = .{ .name = n, .real = p };
    state.count += 1;
}

pub fn setMounts(mounts: []const Mount) MountError!void {
    clearMounts();
    for (mounts) |m| try addMount(m.name, m.real);
}

pub const ResolveError = error{
    PathNotMounted,
    InvalidPath,
    PathTooLong,
};

/// Resolve a script path ("data/file.txt") to a real path using the
/// registered mounts. Rejects absolute paths, empty components, and
/// "." / ".." traversal.
pub fn resolve(path: []const u8, buf: []u8) ResolveError![]const u8 {
    if (path.len == 0 or path[0] == '/') return error.InvalidPath;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return error.InvalidPath;
    }

    const slash = std.mem.indexOfScalar(u8, path, '/');
    const head = if (slash) |i| path[0..i] else path;
    const rest = if (slash) |i| path[i + 1 ..] else "";

    const mount = for (g_state.mounts[0..g_state.count]) |m| {
        if (std.mem.eql(u8, m.name, head)) break m;
    } else return error.PathNotMounted;

    const need = mount.real.len + (if (rest.len > 0) rest.len + 1 else 0);
    if (need > buf.len) return error.PathTooLong;
    @memcpy(buf[0..mount.real.len], mount.real);
    if (rest.len == 0) return buf[0..mount.real.len];
    buf[mount.real.len] = '/';
    @memcpy(buf[mount.real.len + 1 ..][0..rest.len], rest);
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
