const std = @import("std");
const builtin = @import("builtin");

const MaxConns = 16;

const NetConn = struct {
    id: u32,
    socket: if (builtin.os.tag == .wasi) void else std.posix.fd_t,
};

var g_next_id: u32 = 1;
var g_conns: [MaxConns]NetConn = undefined;
var g_conn_count: usize = 0;

pub fn netReset() void {
    if (comptime builtin.os.tag == .wasi) return;
    var i: usize = 0;
    while (i < g_conn_count) : (i += 1) {
        std.posix.close(g_conns[i].socket);
    }
    g_conn_count = 0;
    g_next_id = 1;
}

fn ioContext() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn netDial(network: []const u8, address: []const u8) !u32 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (g_conn_count >= MaxConns) return error.CapabilityError;

    // Only TCP is supported in the built-in handler
    if (!std.mem.eql(u8, network, "tcp") and
        !std.mem.eql(u8, network, "tcp4") and
        !std.mem.eql(u8, network, "tcp6"))
    {
        return error.CapabilityError;
    }

    // Parse host:port
    const colon = std.mem.lastIndexOfScalar(u8, address, ':');
    if (colon == null) return error.CapabilityError;
    const host = address[0..colon.?];
    const port_str = address[colon.? + 1..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return error.CapabilityError;

    const io_ctx = ioContext();
    const ip = std.Io.net.IpAddress.resolve(io_ctx, host, port) catch return error.CapabilityError;

    const family: i32 = switch (ip) {
        .ip4 => std.posix.AF.INET,
        .ip6 => std.posix.AF.INET6,
    };
    const socket_fd = std.posix.socket(family, std.posix.SOCK.STREAM, 0) catch return error.CapabilityError;
    errdefer std.posix.close(socket_fd);

    var addr_storage: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = undefined;
    switch (ip) {
        .ip4 => |ip4| {
            const addr: *std.posix.sockaddr.in = @ptrCast(&addr_storage);
            addr.* = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = std.mem.nativeToBig(u32, @as(u32, @bitCast(ip4.bytes))),
                .zero = [_]u8{0} ** 8,
            };
            addr_len = @sizeOf(std.posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            const addr: *std.posix.sockaddr.in6 = @ptrCast(&addr_storage);
            addr.* = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = 0,
                .addr = ip6.bytes,
                .scope_id = 0,
            };
            addr_len = @sizeOf(std.posix.sockaddr.in6);
        },
    }

    std.posix.connect(socket_fd, @ptrCast(&addr_storage), addr_len) catch return error.CapabilityError;

    const id = g_next_id;
    g_next_id += 1;
    g_conns[g_conn_count] = .{ .id = id, .socket = socket_fd };
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

    const n = std.posix.read(conn.socket, buf) catch return error.CapabilityError;

    const out = std.heap.page_allocator.realloc(buf, n) catch return error.OutOfMemory;
    return out;
}

pub fn netWrite(id: u32, data: []const u8) !usize {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    const n = std.posix.write(conn.socket, data) catch return error.CapabilityError;
    return n;
}

pub fn netClose(id: u32) !void {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    std.posix.close(conn.socket);
    removeConn(id);
}

pub fn netLocalAddr(id: u32) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;
    _ = conn;
    return "";
}

pub fn netRemoteAddr(id: u32) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;
    _ = conn;
    return "";
}

pub fn netSetDeadline(id: u32, ms: i64) !void {
    _ = id;
    _ = ms;
}

pub fn netSetReadDeadline(id: u32, ms: i64) !void {
    _ = id;
    _ = ms;
}

pub fn netSetWriteDeadline(id: u32, ms: i64) !void {
    _ = id;
    _ = ms;
}
