const std = @import("std");
const builtin = @import("builtin");

const MaxConns = 16;

const NetConn = struct {
    id: u32,
    host_handle: i32,
    socket: if (builtin.os.tag == .wasi) void else std.posix.socket_t,
};

var g_next_id: u32 = 1;
var g_conns: [MaxConns]NetConn = undefined;
var g_conn_count: usize = 0;

var g_net_err_buf: [256]u8 = undefined;
var g_net_err_len: usize = 0;

fn setNetErr(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&g_net_err_buf, fmt, args) catch g_net_err_buf[0..g_net_err_buf.len];
    g_net_err_len = s.len;
}

pub fn lastNetErr() []const u8 {
    if (g_net_err_len == 0) return "CapabilityError";
    return g_net_err_buf[0..g_net_err_len];
}

/// C-compatible struct matching GengoNetHandlers in the C API.
/// All function pointers are required when set — the entire struct
/// must be valid or operations fall back to the built-in implementation.
pub const GengoNetHandlers = extern struct {
    dial: ?*const fn (network: [*]const u8, network_len: usize, address: [*]const u8, address_len: usize, out_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32,
    read: ?*const fn (handle: i32, buf: [*]u8, max_bytes: i32, userdata: ?*anyopaque) callconv(.c) i32,
    write: ?*const fn (handle: i32, data: [*]const u8, len: i32, userdata: ?*anyopaque) callconv(.c) i32,
    close: ?*const fn (handle: i32, userdata: ?*anyopaque) callconv(.c) void,
    local_addr: ?*const fn (handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void,
    remote_addr: ?*const fn (handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void,
    set_deadline: ?*const fn (handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void,
    set_read_deadline: ?*const fn (handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void,
    set_write_deadline: ?*const fn (handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void,
};

const HandlerSet = struct {
    callbacks: GengoNetHandlers,
    userdata: ?*anyopaque,
};

var g_net_handlers: ?HandlerSet = null;

pub fn setNetHandlers(handlers: GengoNetHandlers, userdata: ?*anyopaque) void {
    g_net_handlers = .{ .callbacks = handlers, .userdata = userdata };
}

pub fn hasHandlers() bool {
    return g_net_handlers != null;
}

pub fn resetHandlers() void {
    g_net_handlers = null;
}

pub fn netReset() void {
    if (g_net_handlers) |h| {
        for (g_conns[0..g_conn_count]) |conn| {
            if (h.callbacks.close) |close_fn| close_fn(conn.host_handle, h.userdata);
        }
        g_conn_count = 0;
        g_next_id = 1;
        return;
    }
    if (comptime builtin.os.tag == .wasi) return;
    const io_ctx = ioContext();
    for (g_conns[0..g_conn_count]) |*conn| {
        io_ctx.vtable.netClose(io_ctx.userdata, (&conn.socket)[0..1]);
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
    // timeval field widths differ per OS (Linux: i64/i64, macOS: i64/i32);
    // clamp sec to the platform type, usec is < 1_000_000 and always fits.
    const SecT = @FieldType(std.posix.timeval, "sec");
    const sec: SecT = @intCast(@min(@divTrunc(ms, 1000), std.math.maxInt(SecT)));
    const usec = @mod(ms, 1000) * 1000;
    const tv = std.posix.timeval{ .sec = sec, .usec = @intCast(usec) };
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
    g_net_err_len = 0;
    if (g_net_handlers) |h| {
        if (g_conn_count >= MaxConns) {
            setNetErr("too many connections (max {d})", .{MaxConns});
            return error.NetError;
        }
        var out_handle: i32 = undefined;
        const dial_fn = h.callbacks.dial orelse {
            setNetErr("dial handler not registered", .{});
            return error.NetError;
        };
        const rc = dial_fn(network.ptr, @intCast(network.len), address.ptr, @intCast(address.len), &out_handle, h.userdata);
        if (rc < 0) {
            setNetErr("dial: host handler returned error {d}", .{rc});
            return error.NetError;
        }
        const id = g_next_id;
        g_next_id += 1;
        g_conns[g_conn_count] = .{ .id = id, .host_handle = out_handle, .socket = undefined };
        g_conn_count += 1;
        return id;
    }
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (g_conn_count >= MaxConns) {
        setNetErr("too many connections (max {d})", .{MaxConns});
        return error.NetError;
    }

    if (!std.mem.eql(u8, network, "tcp") and
        !std.mem.eql(u8, network, "tcp4") and
        !std.mem.eql(u8, network, "tcp6"))
    {
        setNetErr("dial: unsupported network \"{s}\"", .{network});
        return error.NetError;
    }

    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse {
        setNetErr("dial: invalid address \"{s}\" (expected host:port)", .{address});
        return error.NetError;
    };
    const host = address[0..colon];
    const port_str = address[colon + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch {
        setNetErr("dial: invalid port \"{s}\" in address \"{s}\"", .{ port_str, address });
        return error.NetError;
    };

    const io_ctx = ioContext();

    std.Io.net.HostName.validate(host) catch {
        setNetErr("dial: invalid hostname \"{s}\"", .{host});
        return error.NetError;
    };
    const host_name = std.Io.net.HostName{ .bytes = host };

    var results: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&results);

    host_name.lookup(io_ctx, &queue, .{ .port = port }) catch {
        setNetErr("dial: name resolution failed for \"{s}\"", .{host});
        return error.NetError;
    };

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
    const resolved_ip = ip orelse {
        setNetErr("dial: no addresses found for \"{s}\"", .{host});
        return error.NetError;
    };

    // Use posix.connect directly to get real connection errors (CONNREFUSED etc.)
    const sock_fam: u32 = switch (resolved_ip) {
        .ip4 => std.posix.AF.INET,
        .ip6 => std.posix.AF.INET6,
    };
    const sock = std.posix.system.socket(sock_fam, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(sock) != .SUCCESS) {
        setNetErr("dial: socket creation failed", .{});
        return error.NetError;
    }
    const fd: std.posix.socket_t = @intCast(sock);
    errdefer _ = std.posix.system.close(fd);

    var addr_storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
    var addr_len: std.posix.socklen_t = undefined;
    switch (resolved_ip) {
        .ip4 => |v4| {
            const sa: *std.posix.sockaddr.in = @ptrCast(&addr_storage);
            sa.family = std.posix.AF.INET;
            sa.port = std.mem.nativeToBig(u16, port);
            sa.addr = @bitCast(v4.bytes);
            addr_len = @sizeOf(std.posix.sockaddr.in);
        },
        .ip6 => |v6| {
            const sa: *std.posix.sockaddr.in6 = @ptrCast(&addr_storage);
            sa.family = std.posix.AF.INET6;
            sa.port = std.mem.nativeToBig(u16, port);
            sa.addr = v6.bytes;
            addr_len = @sizeOf(std.posix.sockaddr.in6);
        },
    }
    const rc = std.posix.system.connect(fd, @ptrCast(&addr_storage), addr_len);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .CONNREFUSED => {
            setNetErr("dial: connection refused ({s}:{d})", .{ host, port });
            return error.NetError;
        },
        .TIMEDOUT => {
            setNetErr("dial: connection timed out ({s}:{d})", .{ host, port });
            return error.NetError;
        },
        .NETUNREACH, .HOSTUNREACH => {
            setNetErr("dial: network unreachable ({s}:{d})", .{ host, port });
            return error.NetError;
        },
        .CONNRESET => {
            setNetErr("dial: connection reset ({s}:{d})", .{ host, port });
            return error.NetError;
        },
        else => |e| {
            setNetErr("dial: connect failed ({s}:{d}): {s}", .{ host, port, @tagName(e) });
            return error.NetError;
        },
    }

    const id = g_next_id;
    g_next_id += 1;
    g_conns[g_conn_count] = .{ .id = id, .host_handle = 0, .socket = fd };
    g_conn_count += 1;
    return id;
}

fn findConn(id: u32) ?*NetConn {
    for (g_conns[0..g_conn_count]) |*c| {
        if (c.id == id) return c;
    }
    return null;
}

fn removeConn(id: u32) void {
    for (g_conns[0..g_conn_count], 0..) |*c, i| {
        if (c.id == id) {
            g_conns[i] = g_conns[g_conn_count - 1];
            g_conn_count -= 1;
            return;
        }
    }
}

pub fn netRead(id: u32, max_bytes: usize) ![]u8 {
    g_net_err_len = 0;
    if (g_net_handlers) |h| {
        const conn = findConn(id) orelse {
            setNetErr("read: unknown connection handle {d}", .{id});
            return error.NetError;
        };
        const buf = std.heap.page_allocator.alloc(u8, max_bytes) catch return error.OutOfMemory;
        errdefer std.heap.page_allocator.free(buf);
        const clamped: i32 = if (max_bytes > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(max_bytes);
        const n = (h.callbacks.read orelse {
            setNetErr("read handler not registered", .{});
            return error.NetError;
        })(conn.host_handle, buf.ptr, clamped, h.userdata);
        if (n < 0) {
            std.heap.page_allocator.free(buf);
            setNetErr("read: host handler returned error {d}", .{n});
            return error.NetError;
        }
        const out = std.heap.page_allocator.realloc(buf, @intCast(n)) catch return error.OutOfMemory;
        return out;
    }
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse {
        setNetErr("read: unknown connection handle {d}", .{id});
        return error.NetError;
    };

    const buf = std.heap.page_allocator.alloc(u8, max_bytes) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(buf);

    // Use posix.read directly so EAGAIN from SO_RCVTIMEO surfaces as DeadlineExceeded
    // rather than being retried by the std.Io vtable layer.
    // Windows falls back to the vtable (set_deadline is already a no-op there).
    if (comptime builtin.os.tag == .windows) {
        const io_ctx = ioContext();
        var slices = [1][]u8{buf};
        const n = io_ctx.vtable.netRead(io_ctx.userdata, conn.socket, &slices) catch {
            setNetErr("read: I/O error", .{});
            return error.NetError;
        };
        const out = std.heap.page_allocator.realloc(buf, n) catch return error.OutOfMemory;
        return out;
    }
    const n = std.posix.read(conn.socket, buf) catch |err| switch (err) {
        error.WouldBlock => return error.DeadlineExceeded,
        error.ConnectionResetByPeer => {
            setNetErr("read: connection reset by peer", .{});
            return error.NetError;
        },
        error.SocketUnconnected => {
            setNetErr("read: socket not connected", .{});
            return error.NetError;
        },
        else => |e| {
            setNetErr("read: {s}", .{@errorName(e)});
            return error.NetError;
        },
    };

    const out = std.heap.page_allocator.realloc(buf, n) catch return error.OutOfMemory;
    return out;
}

pub fn netWrite(id: u32, data: []const u8) !usize {
    g_net_err_len = 0;
    if (g_net_handlers) |h| {
        const conn = findConn(id) orelse {
            setNetErr("write: unknown connection handle {d}", .{id});
            return error.NetError;
        };
        const n = (h.callbacks.write orelse {
            setNetErr("write handler not registered", .{});
            return error.NetError;
        })(conn.host_handle, data.ptr, @intCast(@min(data.len, @as(usize, std.math.maxInt(i32)))), h.userdata);
        if (n < 0) {
            setNetErr("write: host handler returned error {d}", .{n});
            return error.NetError;
        }
        return @intCast(n);
    }
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse {
        setNetErr("write: unknown connection handle {d}", .{id});
        return error.NetError;
    };

    // Use system.write directly so EAGAIN from SO_SNDTIMEO surfaces as DeadlineExceeded.
    // Windows falls back to the vtable (set_deadline is already a no-op there).
    if (comptime builtin.os.tag == .windows) {
        const io_ctx = ioContext();
        const write_slices = [1][]const u8{data};
        return io_ctx.vtable.netWrite(io_ctx.userdata, conn.socket, &.{}, &write_slices, 1) catch {
            setNetErr("write: I/O error", .{});
            return error.NetError;
        };
    }
    const max_count: usize = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        else => std.math.maxInt(isize),
    };
    while (true) {
        const rc = std.posix.system.write(conn.socket, data.ptr, @min(data.len, max_count));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.DeadlineExceeded,
            .CONNRESET => {
                setNetErr("write: connection reset by peer", .{});
                return error.NetError;
            },
            .PIPE => {
                setNetErr("write: broken pipe (connection closed)", .{});
                return error.NetError;
            },
            else => |e| {
                setNetErr("write: {s}", .{@tagName(e)});
                return error.NetError;
            },
        }
    }
}

pub fn netClose(id: u32) !void {
    if (g_net_handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        if (h.callbacks.close) |close_fn| close_fn(conn.host_handle, h.userdata);
        removeConn(id);
        return;
    }
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    const io_ctx = ioContext();
    io_ctx.vtable.netClose(io_ctx.userdata, (&conn.socket)[0..1]);
    removeConn(id);
}

pub fn netLocalAddr(id: u32) ![]u8 {
    if (g_net_handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        var buf: [128]u8 = std.mem.zeroes([128]u8);
        (h.callbacks.local_addr orelse return error.CapabilityError)(conn.host_handle, &buf, @intCast(buf.len), h.userdata);
        const len = std.mem.indexOfScalar(u8, buf[0..], 0) orelse buf.len;
        return std.heap.page_allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    }
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
    if (g_net_handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        var buf: [128]u8 = std.mem.zeroes([128]u8);
        (h.callbacks.remote_addr orelse return error.CapabilityError)(conn.host_handle, &buf, @intCast(buf.len), h.userdata);
        const len = std.mem.indexOfScalar(u8, buf[0..], 0) orelse buf.len;
        return std.heap.page_allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    }
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
    if (g_net_handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        if (h.callbacks.set_deadline) |fn_ptr| fn_ptr(conn.host_handle, ms, h.userdata);
        return;
    }
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_RCVTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.RCVTIMEO), ms);
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.SNDTIMEO), ms);
}

pub fn netSetReadDeadline(id: u32, ms: i64) !void {
    if (g_net_handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        if (h.callbacks.set_read_deadline) |fn_ptr| fn_ptr(conn.host_handle, ms, h.userdata);
        return;
    }
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_RCVTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.RCVTIMEO), ms);
}

pub fn netSetWriteDeadline(id: u32, ms: i64) !void {
    if (g_net_handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        if (h.callbacks.set_write_deadline) |fn_ptr| fn_ptr(conn.host_handle, ms, h.userdata);
        return;
    }
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_SNDTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.SNDTIMEO), ms);
}
