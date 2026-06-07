const std = @import("std");
const builtin = @import("builtin");

const MaxConns = 16;

const NetConn = struct {
    id: u32,
    socket: if (builtin.os.tag == .wasi) void else std.posix.socket_t,
};

var g_next_id: u32 = 1;
var g_conns: [MaxConns]NetConn = undefined;
var g_conn_count: usize = 0;

pub fn netReset() void {
    if (comptime builtin.os.tag == .wasi) return;
    const io_ctx = ioContext();
    var i: usize = 0;
    while (i < g_conn_count) : (i += 1) {
        io_ctx.vtable.netClose(io_ctx.userdata, (&g_conns[i].socket)[0..1]);
    }
    g_conn_count = 0;
    g_next_id = 1;
}

fn ioContext() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// std.posix.system is std.os.linux on Linux (raw syscalls, no libc needed)
// and std.c on macOS (libc always linked on Darwin). Both have getsockname.
// On Windows this code is never compiled — Windows path stubs below.
fn posixGetsockname(sock: std.posix.socket_t, addr: *std.posix.sockaddr, addrlen: *std.posix.socklen_t) !void {
    const rc = std.posix.system.getsockname(sock, addr, addrlen);
    if (std.posix.errno(rc) != .SUCCESS) return error.CapabilityError;
}

fn posixGetpeername(sock: std.posix.socket_t, addr: *std.posix.sockaddr, addrlen: *std.posix.socklen_t) !void {
    const rc = std.posix.system.getpeername(sock, addr, addrlen);
    if (std.posix.errno(rc) != .SUCCESS) return error.CapabilityError;
}

fn posixSetSockOptTimeval(fd: std.posix.socket_t, optname: u32, ms: i64) !void {
    if (ms < 0) return error.CapabilityError;
    const sec = @divTrunc(ms, 1000);
    const usec = @mod(ms, 1000) * 1000;
    const tv = std.posix.timeval{ .sec = sec, .usec = usec };
    const opt: []const u8 = std.mem.asBytes(&tv);
    const rc = std.posix.system.setsockopt(fd, std.posix.SOL.SOCKET, optname, opt.ptr, @intCast(opt.len));
    if (std.posix.errno(rc) != .SUCCESS) return error.CapabilityError;
}

fn formatIp4Address(port: u16, ip_bytes: [4]u8) ![]u8 {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}:{d}", .{
        ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3], port,
    }) catch return error.CapabilityError;
    return std.heap.page_allocator.dupe(u8, s) catch return error.OutOfMemory;
}

fn formatIp6Address(port: u16, ip_bytes: [16]u8) ![]u8 {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "[{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}]:{d}", .{
        @as(u16, ip_bytes[0]) << 8 | ip_bytes[1],
        @as(u16, ip_bytes[2]) << 8 | ip_bytes[3],
        @as(u16, ip_bytes[4]) << 8 | ip_bytes[5],
        @as(u16, ip_bytes[6]) << 8 | ip_bytes[7],
        @as(u16, ip_bytes[8]) << 8 | ip_bytes[9],
        @as(u16, ip_bytes[10]) << 8 | ip_bytes[11],
        @as(u16, ip_bytes[12]) << 8 | ip_bytes[13],
        @as(u16, ip_bytes[14]) << 8 | ip_bytes[15],
        port,
    }) catch return error.CapabilityError;
    return std.heap.page_allocator.dupe(u8, s) catch return error.OutOfMemory;
}

pub fn netDial(network: []const u8, address: []const u8) !u32 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (g_conn_count >= MaxConns) return error.CapabilityError;

    if (!std.mem.eql(u8, network, "tcp") and
        !std.mem.eql(u8, network, "tcp4") and
        !std.mem.eql(u8, network, "tcp6"))
    {
        return error.CapabilityError;
    }

    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.CapabilityError;
    const host = address[0..colon];
    const port_str = address[colon + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return error.CapabilityError;

    const io_ctx = ioContext();

    std.Io.net.HostName.validate(host) catch return error.CapabilityError;
    const host_name = std.Io.net.HostName{ .bytes = host };

    var results: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&results);

    host_name.lookup(io_ctx, &queue, .{ .port = port }) catch return error.CapabilityError;

    var ip: ?std.Io.net.IpAddress = null;
    while (true) {
        const result = queue.getOneUncancelable(io_ctx) catch |err| switch (err) {
            error.Closed => break,
        };
        switch (result) {
            .address => |addr| { if (ip == null) ip = addr; },
            .canonical_name => {},
        }
    }
    const resolved_ip = ip orelse return error.CapabilityError;

    const stream = resolved_ip.connect(io_ctx, .{ .mode = .stream }) catch return error.CapabilityError;

    const id = g_next_id;
    g_next_id += 1;
    g_conns[g_conn_count] = .{ .id = id, .socket = stream.socket.handle };
    g_conn_count += 1;
    return id;
}

fn findConn(id: u32) ?*NetConn {
    var i: usize = 0;
    while (i < g_conn_count) : (i += 1) {
        if (g_conns[i].id == id) return &g_conns[i];
    }
    return null;
}

fn removeConn(id: u32) void {
    var i: usize = 0;
    while (i < g_conn_count) : (i += 1) {
        if (g_conns[i].id == id) {
            g_conns[i] = g_conns[g_conn_count - 1];
            g_conn_count -= 1;
            return;
        }
    }
}

pub fn netRead(id: u32, max_bytes: usize) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    const buf = std.heap.page_allocator.alloc(u8, max_bytes) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(buf);

    const io_ctx = ioContext();
    var slices = [1][]u8{buf};
    const n = io_ctx.vtable.netRead(io_ctx.userdata, conn.socket, &slices) catch return error.CapabilityError;

    const out = std.heap.page_allocator.realloc(buf, n) catch return error.OutOfMemory;
    return out;
}

pub fn netWrite(id: u32, data: []const u8) !usize {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    const io_ctx = ioContext();
    const n = io_ctx.vtable.netWrite(io_ctx.userdata, conn.socket, data, &.{}, 0) catch return error.CapabilityError;
    return n;
}

pub fn netClose(id: u32) !void {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    const io_ctx = ioContext();
    io_ctx.vtable.netClose(io_ctx.userdata, (&conn.socket)[0..1]);
    removeConn(id);
}

pub fn netLocalAddr(id: u32) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock
    const conn = findConn(id) orelse return error.CapabilityError;

    var addr_storage: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try posixGetsockname(conn.socket, @ptrCast(&addr_storage), &addr_len);

    return switch (addr_storage.family) {
        std.posix.AF.INET => blk: {
            const addr: *const std.posix.sockaddr.in = @ptrCast(&addr_storage);
            break :blk formatIp4Address(std.mem.bigToNative(u16, addr.port), std.mem.asBytes(&addr.addr).*);
        },
        std.posix.AF.INET6 => blk: {
            const addr: *const std.posix.sockaddr.in6 = @ptrCast(&addr_storage);
            break :blk formatIp6Address(std.mem.bigToNative(u16, addr.port), addr.addr);
        },
        else => error.CapabilityError,
    };
}

pub fn netRemoteAddr(id: u32) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock
    const conn = findConn(id) orelse return error.CapabilityError;

    var addr_storage: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try posixGetpeername(conn.socket, @ptrCast(&addr_storage), &addr_len);

    return switch (addr_storage.family) {
        std.posix.AF.INET => blk: {
            const addr: *const std.posix.sockaddr.in = @ptrCast(&addr_storage);
            break :blk formatIp4Address(std.mem.bigToNative(u16, addr.port), std.mem.asBytes(&addr.addr).*);
        },
        std.posix.AF.INET6 => blk: {
            const addr: *const std.posix.sockaddr.in6 = @ptrCast(&addr_storage);
            break :blk formatIp6Address(std.mem.bigToNative(u16, addr.port), addr.addr);
        },
        else => error.CapabilityError,
    };
}

pub fn netSetDeadline(id: u32, ms: i64) !void {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_RCVTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.RCVTIMEO), ms);
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.SNDTIMEO), ms);
}

pub fn netSetReadDeadline(id: u32, ms: i64) !void {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_RCVTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.RCVTIMEO), ms);
}

pub fn netSetWriteDeadline(id: u32, ms: i64) !void {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_SNDTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.SNDTIMEO), ms);
}
