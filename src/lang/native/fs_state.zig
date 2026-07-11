const std = @import("std");

// Host-mounted filesystem namespace for cap:fs (issue #90).
//
// Scripts never see real paths. The host registers named mounts
// ("data" -> "/var/app/data"); script paths must start with a mount
// name and resolve inside it. Absolute paths and ".." are rejected.
//
// A mount can be backed by a real directory (MountKind.real_path) or by a
// host-provided virtual driver (MountKind.driver) — see issue #183.
//
// The mount table follows the same active-pointer pattern as the other
// runtime states (#190): each Runtime owns an EngineState and Runtime.activate()
// points the module-level active pointer at it. Mount strings are stored as
// offsets into the state's own str_buf, so an EngineState is plain data and
// safe to copy by value.

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

/// Public mount description: input to addMount/setMounts, output of lookup().
/// The name/real slices of a Mount returned by lookup() point into the active
/// state's buffer and are valid for immediate use only.
pub const Mount = struct {
    name: []const u8,
    kind: MountKind = .real_path,
    real: []const u8 = "",
    driver: FsDriver = .{},
    userdata: ?*anyopaque = null,
};

const MaxMounts = 16;
const StrBufSize = 4096;

// Internal record: strings as (offset, len) into the owning state's str_buf,
// so the state has no self-referencing pointers.
const MountRec = struct {
    name_off: u32 = 0,
    name_len: u32 = 0,
    kind: MountKind = .real_path,
    real_off: u32 = 0,
    real_len: u32 = 0,
    driver: FsDriver = .{},
    userdata: ?*anyopaque = null,
};

/// Per-runtime (or per-engine) mount table. Plain data — copyable by value.
pub const EngineState = struct {
    mounts: [MaxMounts]MountRec = undefined,
    count: usize = 0,
    str_buf: [StrBufSize]u8 = undefined,
    str_used: usize = 0,

    pub fn clear(self: *EngineState) void {
        self.count = 0;
        self.str_used = 0;
    }

    fn nameOf(self: *const EngineState, rec: *const MountRec) []const u8 {
        return self.str_buf[rec.name_off..][0..rec.name_len];
    }

    pub fn mountAt(self: *const EngineState, i: usize) Mount {
        const rec = &self.mounts[i];
        return .{
            .name = self.nameOf(rec),
            .kind = rec.kind,
            .real = self.str_buf[rec.real_off..][0..rec.real_len],
            .driver = rec.driver,
            .userdata = rec.userdata,
        };
    }
};

var g_default_state: EngineState = .{};
threadlocal var g_state: *EngineState = &g_default_state;

/// Point the module at a specific runtime's mount table. Called from
/// Runtime.activate() alongside the chunk/globals/heap/vm setActive calls.
pub fn setActive(state: *EngineState) void {
    g_state = state;
}

pub fn activeState() *EngineState {
    return g_state;
}

/// The process-default table: what the CLI's --mount flag populates before a
/// Runtime exists, and what a fresh Runtime inherits at init.
pub fn defaultState() *EngineState {
    return &g_default_state;
}

pub const MountError = error{
    TooManyMounts,
    InvalidMountName,
    InvalidMountPath,
    OutOfMountSpace,
};

pub fn clearMounts() void {
    g_state.clear();
}

pub fn mountCount() usize {
    return g_state.count;
}

/// Register a mount into the active state. Strings are copied into
/// the state buffer; re-adding an existing name replaces its target.
pub fn addMount(name: []const u8, real: []const u8) MountError!void {
    try addMountToState(g_state, name, real);
}

/// Register a mount into a specific EngineState. Use this when populating
/// a runtime's per-instance state outside of a run/call (e.g. engine_mount_dir).
pub fn addMountToState(state: *EngineState, name: []const u8, real: []const u8) MountError!void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidMountName;
    if (real.len == 0) return error.InvalidMountPath;

    // Strip trailing slashes from the target (keep a bare "/").
    var r = real;
    while (r.len > 1 and r[r.len - 1] == '/') r = r[0 .. r.len - 1];

    if (state.str_used + name.len + r.len > state.str_buf.len) return error.OutOfMountSpace;
    const name_off: u32 = @intCast(state.str_used);
    const real_off: u32 = @intCast(state.str_used + name.len);
    @memcpy(state.str_buf[name_off..][0..name.len], name);
    @memcpy(state.str_buf[real_off..][0..r.len], r);
    state.str_used += name.len + r.len;

    for (state.mounts[0..state.count]) |*m| {
        if (std.mem.eql(u8, state.nameOf(m), name)) {
            m.kind = .real_path;
            m.real_off = real_off;
            m.real_len = @intCast(r.len);
            m.driver = .{};
            m.userdata = null;
            return;
        }
    }
    if (state.count >= MaxMounts) return error.TooManyMounts;
    state.mounts[state.count] = .{
        .name_off = name_off,
        .name_len = @intCast(name.len),
        .kind = .real_path,
        .real_off = real_off,
        .real_len = @intCast(r.len),
    };
    state.count += 1;
}

/// Register a virtual driver mount into a specific EngineState.
pub fn addDriverMountToState(state: *EngineState, name: []const u8, driver: FsDriver, userdata: ?*anyopaque) MountError!void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidMountName;
    if (state.str_used + name.len > state.str_buf.len) return error.OutOfMountSpace;
    const name_off: u32 = @intCast(state.str_used);
    @memcpy(state.str_buf[name_off..][0..name.len], name);
    state.str_used += name.len;
    for (state.mounts[0..state.count]) |*m| {
        if (std.mem.eql(u8, state.nameOf(m), name)) {
            m.kind = .driver;
            m.real_off = 0;
            m.real_len = 0;
            m.driver = driver;
            m.userdata = userdata;
            return;
        }
    }
    if (state.count >= MaxMounts) return error.TooManyMounts;
    state.mounts[state.count] = .{
        .name_off = name_off,
        .name_len = @intCast(name.len),
        .kind = .driver,
        .driver = driver,
        .userdata = userdata,
    };
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
    mount: Mount,
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

    for (g_state.mounts[0..g_state.count], 0..) |*m, i| {
        if (std.mem.eql(u8, g_state.nameOf(m), head)) {
            return .{ .mount = g_state.mountAt(i), .rest = rest };
        }
    }
    return error.PathNotMounted;
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
    var state: EngineState = .{};
    try addDriverMountToState(&state, "mem", .{}, null);
    setActive(&state);
    defer setActive(&g_default_state);

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

test "EngineState is safe to copy by value" {
    var state: EngineState = .{};
    var sentinel: u32 = 0xdeadbeef;
    try addMountToState(&state, "data", "/real/path");
    try addDriverMountToState(&state, "vfs", .{}, &sentinel);

    // Offsets, not pointers: a plain struct copy stays self-consistent.
    var copy = state;
    state.str_buf[0] = 'X'; // corrupt the original to prove independence

    try std.testing.expectEqual(@as(usize, 2), copy.count);
    try std.testing.expectEqualStrings("data", copy.mountAt(0).name);
    try std.testing.expectEqualStrings("/real/path", copy.mountAt(0).real);
    try std.testing.expectEqual(MountKind.driver, copy.mountAt(1).kind);
    try std.testing.expectEqualStrings("vfs", copy.mountAt(1).name);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), copy.mountAt(1).userdata);
}

test "driver mount replaces real_path mount with same name" {
    var state: EngineState = .{};
    try addMountToState(&state, "data", "/real/path");
    try addDriverMountToState(&state, "data", .{}, null);
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqual(MountKind.driver, state.mounts[0].kind);
}
