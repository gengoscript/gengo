const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;

const MaxConns = 16;

const NetConn = struct {
    id: u32,
    stream: if (builtin.os.tag == .wasi) void else net.Stream,
};

var g_next_id: u32 = 1;
var g_conns: [MaxConns]NetConn = undefined;
var g_conn_count: usize = 0;

pub fn netReset() void {
    if (comptime builtin.os.tag == .wasi) return;
    const io_ctx = ioContext();
    var i: usize = 0;
    while (i < g_conn_count) : (i += 1) {
        g_conns[i].stream.close(io_ctx);
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
    const ip = net.IpAddress.parse(host, port) catch return error.CapabilityError;
    const stream = ip.connect(io_ctx, .{ .mode = .stream }) catch return error.CapabilityError;

    const id = g_next_id;
    g_next_id += 1;
    g_conns[g_conn_count] = .{ .id = id, .stream = stream };
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

    const n = std.posix.read(conn.stream.socket.handle, buf) catch return error.CapabilityError;
    const out = std.heap.page_allocator.realloc(buf, n) catch return error.OutOfMemory;
    return out;
}

pub fn netWrite(id: u32, data: []const u8) !usize {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    const io_ctx = ioContext();
    const n = io_ctx.vtable.netWrite(io_ctx.userdata, conn.stream.socket.handle, data, &.{}, 0) catch return error.CapabilityError;
    return n;
}

pub fn netClose(id: u32) !void {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    const io_ctx = ioContext();
    conn.stream.close(io_ctx);
    removeConn(id);
}

pub fn netLocalAddr(id: u32) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    _ = findConn(id) orelse return error.CapabilityError;
    return "";
}

pub fn netRemoteAddr(id: u32) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.CapabilityNotAvailable;
    _ = findConn(id) orelse return error.CapabilityError;
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
