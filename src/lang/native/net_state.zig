const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
// Import real TLS only when cap:net is enabled; otherwise stub so that
// std.crypto is not pulled into builds compiled with -Dcap_net=false.
const tls_common = if (builtin.os.tag != .wasi and build_options.cap_net)
    @import("tls_common.zig")
else
    struct {
        pub const TlsConn = opaque {};
    };

const MaxConns = 16;
const ReadBufSize = 4096;
// Kernel-level pending-connection queue depth for listen(); fixed, not
// script-controlled (§9 of the design note).
const ListenBacklog = 128;

// ---------------------------------------------------------------------------
// Net dial policy — stacked allow/deny rules, LIFO evaluation
// ---------------------------------------------------------------------------

const MaxPolicyRules = 32;

pub const PolicyAction = enum(u8) { deny = 0, allow = 1 };

const PatternKind = enum(u8) {
    match_all, // "*"
    hostname_exact, // "api.example.com"
    wildcard_suffix, // "*.example.com" — suffix stored as ".example.com"
    ipv4_exact, // stored as 4 bytes in data[0..4]
    ipv4_cidr, // stored as 4 bytes + prefix_len
    ipv6_exact, // stored as 16 bytes in data[0..16]
    ipv6_cidr, // stored as 16 bytes + prefix_len
};

const NetPolicyRule = struct {
    action: PolicyAction,
    kind: PatternKind,
    port: u16, // 0 = any port
    data: [64]u8 = undefined,
    data_len: u8 = 0,
    prefix_len: u8 = 0,
};

pub const PolicyState = struct {
    rules: [MaxPolicyRules]NetPolicyRule = undefined,
    count: u8 = 0,
};

// Listen policy — same rule shape and matcher as dial's, but a separate
// instance (a host restricting outbound destinations shouldn't also have to
// reuse those same rules for its own listening ports; the authority is
// different) and default-DENY rather than default-ALLOW (see checkPolicy).

const NetConn = struct {
    id: u32,
    host_handle: i32,
    socket: if (builtin.os.tag == .wasi) void else std.posix.socket_t,
    rbuf: [ReadBufSize]u8 = undefined,
    rbuf_pos: usize = 0,
    rbuf_end: usize = 0,
    // Non-null for TLS connections (heap-allocated; freed in netClose).
    tls: if (builtin.os.tag == .wasi or !build_options.cap_net) void else ?*tls_common.TlsConn = if (builtin.os.tag == .wasi or !build_options.cap_net) {} else null,
};

// Listening sockets — independent ceiling from MaxConns (§9 of the design
// note: a script needing many listening ports is a different shape of
// program than one needing many connections). Accepted connections still
// draw from conns/MaxConns above, same pool dial uses.
const MaxListeners = 8;

const NetListener = struct {
    id: u32,
    host_handle: i32,
    socket: if (builtin.os.tag == .wasi) void else std.posix.socket_t,
};

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
    // Listener support — optional even when the rest of the struct is set,
    // since a host may support dialing but not listening (or vice versa).
    // A null field here just means "listen unsupported by this host."
    listen: ?*const fn (network: [*]const u8, network_len: usize, address: [*]const u8, address_len: usize, out_listener_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 = null,
    // Returns: 1 = got a connection, 0 = would-block/timeout, <0 = error.
    accept: ?*const fn (listener_handle: i32, out_conn_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 = null,
    listener_close: ?*const fn (listener_handle: i32, userdata: ?*anyopaque) callconv(.c) void = null,
    listener_local_addr: ?*const fn (listener_handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void = null,
    set_accept_deadline: ?*const fn (listener_handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void = null,
};

pub const HandlerSet = struct {
    callbacks: GengoNetHandlers,
    userdata: ?*anyopaque,
};

// ---------------------------------------------------------------------------
// Per-runtime state — everything that was previously process-global.
// Each Runtime owns a NetEngineState embedded in its struct; Runtime.activate()
// points g_state at it, mirroring the fs_state / chunk / heap pattern.
// ---------------------------------------------------------------------------

pub const NetEngineState = struct {
    policy: PolicyState = .{},
    listen_policy: PolicyState = .{},
    handlers: ?HandlerSet = null,
    conns: []NetConn = &.{},
    conn_count: usize = 0,
    next_id: u32 = 1,
    listeners: []NetListener = &.{},
    listener_count: usize = 0,
    next_listener_id: u32 = 1,
    net_err_buf: [256]u8 = undefined,
    net_err_len: usize = 0,

    pub fn initArrays(self: *NetEngineState, allocator: std.mem.Allocator) !void {
        self.conns = try allocator.alloc(NetConn, MaxConns);
        errdefer {
            allocator.free(self.conns);
            self.conns = &.{};
        }
        self.listeners = try allocator.alloc(NetListener, MaxListeners);
    }

    pub fn deinitArrays(self: *NetEngineState, allocator: std.mem.Allocator) void {
        allocator.free(self.conns);
        allocator.free(self.listeners);
        self.conns = &.{};
        self.listeners = &.{};
    }
};

pub var g_default_state: NetEngineState = .{};
threadlocal var g_state: *NetEngineState = &g_default_state;

pub fn setActive(state: *NetEngineState) void {
    g_state = state;
}

pub fn defaultState() *NetEngineState {
    return &g_default_state;
}

// ---------------------------------------------------------------------------
// Policy management
// ---------------------------------------------------------------------------

// clearPolicy/clearListenPolicy/addPolicyRule/addListenPolicyRule are
// "default state setup" functions called by the CLI and tests before a
// Runtime exists. They redirect g_state to &g_default_state so the write
// target and subsequent checkDialPolicy/checkListenPolicy reads are
// consistent, and so Runtime.initWithConfig()'s seed-from-g_default_state
// picks the rules up correctly.
pub fn clearPolicy() void {
    g_state = &g_default_state;
    g_default_state.policy = .{};
}

pub fn clearListenPolicy() void {
    g_state = &g_default_state;
    g_default_state.listen_policy = .{};
}

// Returns 0 on success, -1 if the rule list is full, -2 for invalid pattern.
fn buildPolicyRule(action: PolicyAction, pattern: []const u8, port: u16) union(enum) { ok: NetPolicyRule, err: i32 } {
    var rule: NetPolicyRule = .{ .action = action, .kind = undefined, .port = port };

    if (std.mem.eql(u8, pattern, "*")) {
        rule.kind = .match_all;
    } else if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[1..]; // ".example.com"
        if (suffix.len > 63) return .{ .err = -2 };
        rule.kind = .wildcard_suffix;
        rule.data_len = @intCast(suffix.len);
        @memcpy(rule.data[0..suffix.len], suffix);
    } else if (std.mem.indexOfScalar(u8, pattern, '/')) |slash| {
        const addr_part = pattern[0..slash];
        const prefix_str = pattern[slash + 1 ..];
        const prefix_len = std.fmt.parseInt(u8, prefix_str, 10) catch return .{ .err = -2 };
        if (parseIPv4(addr_part)) |ip4| {
            if (prefix_len > 32) return .{ .err = -2 };
            rule.kind = .ipv4_cidr;
            rule.data[0..4].* = ip4;
            rule.data_len = 4;
            rule.prefix_len = prefix_len;
        } else if (parseIPv6(addr_part)) |ip6| {
            if (prefix_len > 128) return .{ .err = -2 };
            rule.kind = .ipv6_cidr;
            rule.data[0..16].* = ip6;
            rule.data_len = 16;
            rule.prefix_len = prefix_len;
        } else {
            return .{ .err = -2 };
        }
    } else if (parseIPv4(pattern)) |ip4| {
        rule.kind = .ipv4_exact;
        rule.data[0..4].* = ip4;
        rule.data_len = 4;
    } else if (parseIPv6(pattern)) |ip6| {
        rule.kind = .ipv6_exact;
        rule.data[0..16].* = ip6;
        rule.data_len = 16;
    } else {
        if (pattern.len > 63) return .{ .err = -2 };
        rule.kind = .hostname_exact;
        rule.data_len = @intCast(pattern.len);
        @memcpy(rule.data[0..pattern.len], pattern);
    }

    return .{ .ok = rule };
}

// Adds a rule to an arbitrary PolicyState. pub so engine.zig can target a
// specific engine's policy directly without touching g_state.
pub fn addRuleTo(policy: *PolicyState, action: PolicyAction, pattern: []const u8, port: u16) i32 {
    if (policy.count >= MaxPolicyRules) return -1;
    const rule = switch (buildPolicyRule(action, pattern, port)) {
        .ok => |r| r,
        .err => |e| return e,
    };
    policy.rules[policy.count] = rule;
    policy.count += 1;
    return 0;
}

pub fn addPolicyRule(action: PolicyAction, pattern: []const u8, port: u16) i32 {
    g_state = &g_default_state;
    return addRuleTo(&g_default_state.policy, action, pattern, port);
}

pub fn clearPolicyRules() void {
    g_state = &g_default_state;
    g_default_state.policy.count = 0;
}

pub fn addListenPolicyRule(action: PolicyAction, pattern: []const u8, port: u16) i32 {
    g_state = &g_default_state;
    return addRuleTo(&g_default_state.listen_policy, action, pattern, port);
}

pub fn clearListenPolicyRules() void {
    g_state = &g_default_state;
    g_default_state.listen_policy.count = 0;
}

// Rules are evaluated LIFO — most recently added rule wins on first match.
// If no rule matches (or none are configured), `default_allow` decides.
fn matchPolicy(policy: *const PolicyState, address: []const u8, default_allow: bool) bool {
    if (policy.count == 0) return default_allow;

    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return default_allow;
    var host = address[0..colon];
    const port_str = address[colon + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return default_allow;

    // Strip IPv6 brackets: "[::1]" → "::1"
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }

    var host_ip4 = parseIPv4(host);
    var host_ip6: ?[16]u8 = if (host_ip4 == null) parseIPv6(host) else null;
    // An empty host ("host:port" written as ":port") is POSIX's "any
    // interface" bind — equivalent to 0.0.0.0 for an AF_INET socket or ::
    // for AF_INET6 (netListen picks the family from the `network` argument,
    // which isn't visible here). Match it against a rule targeting either
    // spelling of "any", so a deny rule authored as "0.0.0.0" or "::" can't
    // be silently bypassed by binding ":port" instead.
    if (host.len == 0) {
        host_ip4 = [4]u8{ 0, 0, 0, 0 };
        host_ip6 = [_]u8{0} ** 16;
    }

    // LIFO: walk from last rule down to first
    var i = policy.count;
    while (i > 0) {
        i -= 1;
        const rule = &policy.rules[i];
        if (rule.port != 0 and rule.port != port) continue;
        const matches = switch (rule.kind) {
            .match_all => true,
            .hostname_exact => eqlIgnoreCase(host, rule.data[0..rule.data_len]),
            .wildcard_suffix => endsWithIgnoreCase(host, rule.data[0..rule.data_len]),
            .ipv4_exact => if (host_ip4) |ip| std.mem.eql(u8, &ip, rule.data[0..4]) else false,
            .ipv4_cidr => if (host_ip4) |ip| ipv4InCidr(ip, rule.data[0..4].*, rule.prefix_len) else false,
            .ipv6_exact => if (host_ip6) |ip| std.mem.eql(u8, &ip, rule.data[0..16]) else false,
            .ipv6_cidr => if (host_ip6) |ip| ipv6InCidr(ip, rule.data[0..16].*, rule.prefix_len) else false,
        };
        if (matches) return rule.action == .allow;
    }

    return default_allow;
}

// DNS hostnames are case-insensitive; policy rules authored against one
// case (e.g. "api.example.com") must not be bypassable by dialing/listening
// with different casing (e.g. "API.Example.COM").
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

// Returns true if the dial is allowed. No rules → DENY (changed from
// the original default-allow — an unconfigured policy must not silently
// permit unrestricted outbound access for a capability model built around
// untrusted scripts). Now symmetric with checkListenPolicy below: a host
// must affirmatively add at least one allow rule before either dial or
// listen succeeds on anything.
pub fn checkDialPolicy(address: []const u8) bool {
    return matchPolicy(&g_state.policy, address, false);
}

// Returns true if the bind is allowed. No rules → DENY, same reasoning as
// checkDialPolicy above (they used to differ).
pub fn checkListenPolicy(address: []const u8) bool {
    return matchPolicy(&g_state.listen_policy, address, false);
}

fn parseIPv4(s: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        result[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    return result;
}

fn parseIPv6(s: []const u8) ?[16]u8 {
    const addr = std.Io.net.Ip6Address.parse(s, 0) catch return null;
    return addr.bytes;
}

fn ipv4InCidr(ip: [4]u8, network: [4]u8, prefix_len: u8) bool {
    if (prefix_len == 0) return true;
    const ip_u32 = std.mem.readInt(u32, &ip, .big);
    const net_u32 = std.mem.readInt(u32, &network, .big);
    const shift: u5 = @intCast(32 - prefix_len);
    const mask = ~@as(u32, 0) << shift;
    return (ip_u32 & mask) == (net_u32 & mask);
}

fn ipv6InCidr(ip: [16]u8, network: [16]u8, prefix_len: u8) bool {
    if (prefix_len == 0) return true;
    var remaining: u8 = prefix_len;
    for (0..16) |idx| {
        if (remaining == 0) break;
        // Found via a coverage-audit test: @min(remaining, 8) legitimately
        // equals 8 for any full byte of prefix (i.e. almost every
        // real-world prefix_len, since most are byte-aligned or exceed 8
        // in an early byte) — u3's max representable value is 7, so this
        // panicked (Debug/ReleaseSafe) or hit @intCast's undefined
        // behavior (ReleaseFast, what the shipped CLI actually runs) on
        // virtually every ipv6_cidr policy rule. u4 covers the real 1..8
        // range; the shift amount below already up-casts to u4 first, so
        // this was a pure type-sizing bug, not a logic bug.
        const bits: u4 = @intCast(@min(remaining, 8));
        const mask: u8 = ~@as(u8, 0) << @intCast(8 - bits);
        if ((ip[idx] & mask) != (network[idx] & mask)) return false;
        remaining -= bits;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Handler management
// ---------------------------------------------------------------------------

pub fn setNetHandlers(handlers: GengoNetHandlers, userdata: ?*anyopaque) void {
    g_state.handlers = .{ .callbacks = handlers, .userdata = userdata };
}

pub fn hasHandlers() bool {
    return g_state.handlers != null;
}

pub fn resetHandlers() void {
    g_state.handlers = null;
}

// ---------------------------------------------------------------------------
// Error buffer
// ---------------------------------------------------------------------------

fn setNetErr(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&g_state.net_err_buf, fmt, args) catch g_state.net_err_buf[0..g_state.net_err_buf.len];
    g_state.net_err_len = s.len;
}

pub fn lastNetErr() []const u8 {
    if (g_state.net_err_len == 0) return "CapabilityError";
    return g_state.net_err_buf[0..g_state.net_err_len];
}

// ---------------------------------------------------------------------------
// Connection and listener tables
// ---------------------------------------------------------------------------

pub fn netReset() void {
    if (g_state.handlers) |h| {
        for (g_state.conns[0..g_state.conn_count]) |conn| {
            if (h.callbacks.close) |close_fn| close_fn(conn.host_handle, h.userdata);
        }
        g_state.conn_count = 0;
        g_state.next_id = 1;
        for (g_state.listeners[0..g_state.listener_count]) |l| {
            if (h.callbacks.listener_close) |close_fn| close_fn(l.host_handle, h.userdata);
        }
        g_state.listener_count = 0;
        g_state.next_listener_id = 1;
        return;
    }
    if (comptime builtin.os.tag == .wasi) return;
    const io_ctx = ioContext();
    for (g_state.conns[0..g_state.conn_count]) |*conn| {
        io_ctx.vtable.netClose(io_ctx.userdata, (&conn.socket)[0..1]);
    }
    g_state.conn_count = 0;
    g_state.next_id = 1;
    for (g_state.listeners[0..g_state.listener_count]) |*l| {
        io_ctx.vtable.netClose(io_ctx.userdata, (&l.socket)[0..1]);
    }
    g_state.listener_count = 0;
    g_state.next_listener_id = 1;
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
    g_state.net_err_len = 0;
    if (g_state.handlers) |h| {
        if (g_state.conn_count >= MaxConns) {
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
        const id = g_state.next_id;
        g_state.next_id += 1;
        g_state.conns[g_state.conn_count] = .{ .id = id, .host_handle = out_handle, .socket = undefined };
        g_state.conn_count += 1;
        return id;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    if (g_state.conn_count >= MaxConns) {
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
    var host = address[0..colon];
    const port_str = address[colon + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch {
        setNetErr("dial: invalid port \"{s}\" in address \"{s}\"", .{ port_str, address });
        return error.NetError;
    };
    // Strip IPv6 brackets: "[::1]" → "::1" (matches netListen, which already
    // does this).
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }

    const io_ctx = ioContext();

    // IP-literal fast path (mirrors netListen's parseIPv4/parseIPv6-first
    // handling): std.Io.net.HostName.validate rejects any non-alphanumeric
    // byte, including every colon in an IPv6 literal — so "::1" (bracketed
    // or not) always failed validation before ever reaching DNS lookup,
    // even though the exact same bracket syntax already worked for
    // net.listen. Try parsing host as a literal IPv4/IPv6 address first and
    // skip HostName validate/lookup entirely when it is one; only an actual
    // DNS hostname falls through to the lookup path below.
    const resolved_ip: std.Io.net.IpAddress = blk: {
        if (parseIPv4(host)) |v4| {
            if (std.mem.eql(u8, network, "tcp6")) {
                setNetErr("dial: IPv4 address \"{s}\" not valid for network \"tcp6\"", .{host});
                return error.NetError;
            }
            break :blk .{ .ip4 = .{ .bytes = v4, .port = port } };
        }
        if (parseIPv6(host)) |v6| {
            if (std.mem.eql(u8, network, "tcp4")) {
                setNetErr("dial: IPv6 address \"{s}\" not valid for network \"tcp4\"", .{host});
                return error.NetError;
            }
            break :blk .{ .ip6 = .{ .bytes = v6, .port = port } };
        }

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
                .address => |addr| {
                    if (ip == null) ip = addr;
                },
                .canonical_name => {},
            }
        }
        break :blk ip orelse {
            setNetErr("dial: no addresses found for \"{s}\"", .{host});
            return error.NetError;
        };
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

    const id = g_state.next_id;
    g_state.next_id += 1;
    g_state.conns[g_state.conn_count] = .{ .id = id, .host_handle = 0, .socket = fd };
    g_state.conn_count += 1;
    return id;
}

// netDialTls connects over TCP then performs a TLS handshake.
// Returns a connection ID usable with netRead/netWrite/netClose.
// Native-only: WASM/Windows return CapabilityNotAvailable.
// SNI is derived from the host part of address (e.g. "example.com:443" → "example.com").
pub fn netDialTls(network: []const u8, address: []const u8) !u32 {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    // Host-callback path cannot provide a raw fd for TLS layering.
    if (g_state.handlers != null) {
        setNetErr("dial_tls: TLS is not supported with host net callbacks", .{});
        return error.NetError;
    }

    // Reuse the full netDial TCP connect path, then wrap with TLS.
    const id = try netDial(network, address);
    const conn = findConn(id) orelse return error.CapabilityError;

    // Extract the hostname for SNI (strip IPv6 brackets if present).
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse {
        removeConn(id);
        _ = std.posix.system.close(conn.socket);
        setNetErr("dial_tls: invalid address \"{s}\"", .{address});
        return error.NetError;
    };
    var sni = address[0..colon];
    if (sni.len >= 2 and sni[0] == '[' and sni[sni.len - 1] == ']') sni = sni[1 .. sni.len - 1];

    const io = ioContext();
    const tls = std.heap.page_allocator.create(tls_common.TlsConn) catch {
        removeConn(id);
        _ = std.posix.system.close(conn.socket);
        return error.OutOfMemory;
    };
    tls.initAt(conn.socket, sni, io) catch |err| {
        std.heap.page_allocator.destroy(tls);
        removeConn(id);
        _ = std.posix.system.close(conn.socket);
        setNetErr("dial_tls: TLS handshake failed: {s}", .{@errorName(err)});
        return error.NetError;
    };
    conn.tls = tls;
    return id;
}

pub fn netListen(network: []const u8, address: []const u8) !u32 {
    g_state.net_err_len = 0;
    if (g_state.handlers) |h| {
        if (g_state.listener_count >= MaxListeners) {
            setNetErr("too many listeners (max {d})", .{MaxListeners});
            return error.NetError;
        }
        var out_handle: i32 = undefined;
        const listen_fn = h.callbacks.listen orelse {
            setNetErr("listen handler not registered", .{});
            return error.NetError;
        };
        const rc = listen_fn(network.ptr, @intCast(network.len), address.ptr, @intCast(address.len), &out_handle, h.userdata);
        if (rc < 0) {
            setNetErr("listen: host handler returned error {d}", .{rc});
            return error.NetError;
        }
        const id = g_state.next_listener_id;
        g_state.next_listener_id += 1;
        g_state.listeners[g_state.listener_count] = .{ .id = id, .host_handle = out_handle, .socket = undefined };
        g_state.listener_count += 1;
        return id;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    if (g_state.listener_count >= MaxListeners) {
        setNetErr("too many listeners (max {d})", .{MaxListeners});
        return error.NetError;
    }

    if (!std.mem.eql(u8, network, "tcp") and
        !std.mem.eql(u8, network, "tcp4") and
        !std.mem.eql(u8, network, "tcp6"))
    {
        setNetErr("listen: unsupported network \"{s}\"", .{network});
        return error.NetError;
    }

    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse {
        setNetErr("listen: invalid address \"{s}\" (expected host:port)", .{address});
        return error.NetError;
    };
    var host = address[0..colon];
    const port_str = address[colon + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch {
        setNetErr("listen: invalid port \"{s}\" in address \"{s}\"", .{ port_str, address });
        return error.NetError;
    };
    // Strip IPv6 brackets: "[::1]" → "::1"
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }

    const want_v6 = std.mem.eql(u8, network, "tcp6");
    var addr_storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
    var addr_len: std.posix.socklen_t = undefined;
    const sock_fam: u32 = blk: {
        if (host.len == 0) {
            // Any-interface bind (":8080"): family follows the requested
            // network kind, since there's no address to infer it from.
            if (want_v6) {
                const sa: *std.posix.sockaddr.in6 = @ptrCast(&addr_storage);
                sa.family = std.posix.AF.INET6;
                sa.port = std.mem.nativeToBig(u16, port);
                addr_len = @sizeOf(std.posix.sockaddr.in6);
                break :blk std.posix.AF.INET6;
            }
            const sa: *std.posix.sockaddr.in = @ptrCast(&addr_storage);
            sa.family = std.posix.AF.INET;
            sa.port = std.mem.nativeToBig(u16, port);
            addr_len = @sizeOf(std.posix.sockaddr.in);
            break :blk std.posix.AF.INET;
        }
        if (parseIPv4(host)) |ip4| {
            if (want_v6) {
                setNetErr("listen: IPv4 address \"{s}\" not valid for network \"tcp6\"", .{host});
                return error.NetError;
            }
            const sa: *std.posix.sockaddr.in = @ptrCast(&addr_storage);
            sa.family = std.posix.AF.INET;
            sa.port = std.mem.nativeToBig(u16, port);
            sa.addr = @bitCast(ip4);
            addr_len = @sizeOf(std.posix.sockaddr.in);
            break :blk std.posix.AF.INET;
        }
        if (parseIPv6(host)) |ip6| {
            if (std.mem.eql(u8, network, "tcp4")) {
                setNetErr("listen: IPv6 address \"{s}\" not valid for network \"tcp4\"", .{host});
                return error.NetError;
            }
            const sa: *std.posix.sockaddr.in6 = @ptrCast(&addr_storage);
            sa.family = std.posix.AF.INET6;
            sa.port = std.mem.nativeToBig(u16, port);
            sa.addr = ip6;
            addr_len = @sizeOf(std.posix.sockaddr.in6);
            break :blk std.posix.AF.INET6;
        }
        setNetErr("listen: bind address must be an IP literal or empty (any-interface), not \"{s}\"", .{host});
        return error.NetError;
    };

    const sock = std.posix.system.socket(sock_fam, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(sock) != .SUCCESS) {
        setNetErr("listen: socket creation failed", .{});
        return error.NetError;
    }
    const fd: std.posix.socket_t = @intCast(sock);
    errdefer _ = std.posix.system.close(fd);

    // SO_REUSEADDR: standard for listeners, avoids "address already in use"
    // on quick restart while a prior connection is still in TIME_WAIT.
    const reuse: c_int = 1;
    _ = std.posix.system.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse).ptr, @sizeOf(c_int));

    const brc = std.posix.system.bind(fd, @ptrCast(&addr_storage), addr_len);
    if (std.posix.errno(brc) != .SUCCESS) {
        setNetErr("listen: bind failed on \"{s}\"", .{address});
        return error.NetError;
    }

    const lrc = std.posix.system.listen(fd, ListenBacklog);
    if (std.posix.errno(lrc) != .SUCCESS) {
        setNetErr("listen: listen() failed", .{});
        return error.NetError;
    }

    const id = g_state.next_listener_id;
    g_state.next_listener_id += 1;
    g_state.listeners[g_state.listener_count] = .{ .id = id, .host_handle = 0, .socket = fd };
    g_state.listener_count += 1;
    return id;
}

fn findListener(id: u32) ?*NetListener {
    for (g_state.listeners[0..g_state.listener_count]) |*l| {
        if (l.id == id) return l;
    }
    return null;
}

fn removeListener(id: u32) void {
    for (g_state.listeners[0..g_state.listener_count], 0..) |*l, i| {
        if (l.id == id) {
            g_state.listeners[i] = g_state.listeners[g_state.listener_count - 1];
            g_state.listener_count -= 1;
            return;
        }
    }
}

// Accept deadline reuses posixSetSockOptTimeval/SO_RCVTIMEO on the
// *listening* socket (netListenerSetAcceptDeadline below) — the same
// mechanism dial connections already use, just applied to a different
// socket, so EAGAIN here maps to DeadlineExceeded exactly like netRead's
// existing WouldBlock => DeadlineExceeded arm.
pub fn netListenerAccept(listener_id: u32) !u32 {
    g_state.net_err_len = 0;
    if (g_state.handlers) |h| {
        const l = findListener(listener_id) orelse {
            setNetErr("accept: unknown listener handle {d}", .{listener_id});
            return error.NetError;
        };
        var out_conn_handle: i32 = undefined;
        const accept_fn = h.callbacks.accept orelse {
            setNetErr("accept handler not registered", .{});
            return error.NetError;
        };
        const rc = accept_fn(l.host_handle, &out_conn_handle, h.userdata);
        if (rc == 0) return error.DeadlineExceeded;
        if (rc < 0) {
            setNetErr("accept: host handler returned error {d}", .{rc});
            return error.NetError;
        }
        if (g_state.conn_count >= MaxConns) {
            setNetErr("too many connections (max {d})", .{MaxConns});
            return error.NetError;
        }
        const id = g_state.next_id;
        g_state.next_id += 1;
        g_state.conns[g_state.conn_count] = .{ .id = id, .host_handle = out_conn_handle, .socket = undefined };
        g_state.conn_count += 1;
        return id;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    const l = findListener(listener_id) orelse {
        setNetErr("accept: unknown listener handle {d}", .{listener_id});
        return error.NetError;
    };
    if (g_state.conn_count >= MaxConns) {
        setNetErr("too many connections (max {d})", .{MaxConns});
        return error.NetError;
    }

    while (true) {
        const rc = std.posix.system.accept(l.socket, null, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const fd: std.posix.socket_t = @intCast(rc);
                const id = g_state.next_id;
                g_state.next_id += 1;
                g_state.conns[g_state.conn_count] = .{ .id = id, .host_handle = 0, .socket = fd };
                g_state.conn_count += 1;
                return id;
            },
            .INTR => continue,
            .AGAIN => return error.DeadlineExceeded,
            else => |e| {
                setNetErr("accept: {s}", .{@tagName(e)});
                return error.NetError;
            },
        }
    }
}

pub fn netListenerClose(id: u32) !void {
    if (g_state.handlers) |h| {
        const l = findListener(id) orelse return error.CapabilityError;
        if (h.callbacks.listener_close) |close_fn| close_fn(l.host_handle, h.userdata);
        removeListener(id);
        return;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    const l = findListener(id) orelse return error.CapabilityError;

    const io_ctx = ioContext();
    io_ctx.vtable.netClose(io_ctx.userdata, (&l.socket)[0..1]);
    removeListener(id);
}

pub fn netListenerLocalAddr(id: u32) ![]u8 {
    if (g_state.handlers) |h| {
        const l = findListener(id) orelse return error.CapabilityError;
        var buf: [128]u8 = std.mem.zeroes([128]u8);
        (h.callbacks.listener_local_addr orelse return error.CapabilityError)(l.host_handle, &buf, @intCast(buf.len), h.userdata);
        const len = std.mem.indexOfScalar(u8, buf[0..], 0) orelse buf.len;
        return std.heap.page_allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock
    const l = findListener(id) orelse return error.CapabilityError;

    var addr_storage: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try posixGetsockname(l.socket, @ptrCast(&addr_storage), &addr_len);

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

pub fn netListenerSetAcceptDeadline(id: u32, ms: i64) !void {
    if (g_state.handlers) |h| {
        const l = findListener(id) orelse return error.CapabilityError;
        if (h.callbacks.set_accept_deadline) |fn_ptr| fn_ptr(l.host_handle, ms, h.userdata);
        return;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_RCVTIMEO DWORD
    const l = findListener(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(l.socket, @intCast(std.posix.SO.RCVTIMEO), ms);
}

fn findConn(id: u32) ?*NetConn {
    for (g_state.conns[0..g_state.conn_count]) |*c| {
        if (c.id == id) return c;
    }
    return null;
}

fn removeConn(id: u32) void {
    for (g_state.conns[0..g_state.conn_count], 0..) |*c, i| {
        if (c.id == id) {
            g_state.conns[i] = g_state.conns[g_state.conn_count - 1];
            g_state.conn_count -= 1;
            return;
        }
    }
}

pub fn netRead(id: u32, max_bytes: usize) ![]u8 {
    g_state.net_err_len = 0;
    if (g_state.handlers) |h| {
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
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse {
        setNetErr("read: unknown connection handle {d}", .{id});
        return error.NetError;
    };

    // TLS path: stream one TLS record worth of plaintext through the client reader.
    if (conn.tls) |tls| {
        const buf = std.heap.page_allocator.alloc(u8, max_bytes) catch return error.OutOfMemory;
        errdefer std.heap.page_allocator.free(buf);
        var w = std.Io.Writer.fixed(buf);
        const n = tls.client.reader.stream(&w, .limited(max_bytes)) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => {
                setNetErr("read: TLS error: {s}", .{@errorName(err)});
                return error.NetError;
            },
        };
        return std.heap.page_allocator.realloc(buf, n) catch return error.OutOfMemory;
    }

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

// netReadInto reads up to dest.len bytes into dest, returning how many bytes
// were written. Data is served from a per-connection 4 KiB read buffer, which
// is refilled in one syscall when empty — so many small reads cost only one
// posix.read per 4 KiB consumed. Only available on POSIX (not host/WASM paths).
pub fn netReadInto(id: u32, dest: []u8) !usize {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    g_state.net_err_len = 0;
    const conn = findConn(id) orelse {
        setNetErr("read: unknown connection handle {d}", .{id});
        return error.NetError;
    };
    // TLS path: delegate to the client reader (has its own internal buffer).
    if (conn.tls) |tls| {
        var w = std.Io.Writer.fixed(dest);
        return tls.client.reader.stream(&w, .limited(dest.len)) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => {
                setNetErr("read: TLS error: {s}", .{@errorName(err)});
                return error.NetError;
            },
        };
    }
    if (conn.rbuf_pos >= conn.rbuf_end) {
        // Buffer empty: fill from socket with a large read.
        const n = std.posix.read(conn.socket, &conn.rbuf) catch |err| switch (err) {
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
        conn.rbuf_pos = 0;
        conn.rbuf_end = n;
    }
    const avail = conn.rbuf_end - conn.rbuf_pos;
    const n = @min(dest.len, avail);
    @memcpy(dest[0..n], conn.rbuf[conn.rbuf_pos .. conn.rbuf_pos + n]);
    conn.rbuf_pos += n;
    return n;
}

pub fn netWrite(id: u32, data: []const u8) !usize {
    g_state.net_err_len = 0;
    if (g_state.handlers) |h| {
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
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse {
        setNetErr("write: unknown connection handle {d}", .{id});
        return error.NetError;
    };

    // TLS path: encrypt via the TLS client writer.
    if (conn.tls) |tls| {
        _ = tls.client.writer.writeVec(&.{data}) catch |err| {
            setNetErr("write: TLS error: {s}", .{@errorName(err)});
            return error.NetError;
        };
        tls.client.writer.flush() catch |err| {
            setNetErr("write: TLS flush error: {s}", .{@errorName(err)});
            return error.NetError;
        };
        return data.len;
    }

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
    if (g_state.handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        if (h.callbacks.close) |close_fn| close_fn(conn.host_handle, h.userdata);
        removeConn(id);
        return;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    const conn = findConn(id) orelse return error.CapabilityError;

    if (conn.tls) |tls| {
        std.heap.page_allocator.destroy(tls);
        conn.tls = null;
    }
    const io_ctx = ioContext();
    io_ctx.vtable.netClose(io_ctx.userdata, (&conn.socket)[0..1]);
    removeConn(id);
}

pub fn netLocalAddr(id: u32) ![]u8 {
    if (g_state.handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        var buf: [128]u8 = std.mem.zeroes([128]u8);
        (h.callbacks.local_addr orelse return error.CapabilityError)(conn.host_handle, &buf, @intCast(buf.len), h.userdata);
        const len = std.mem.indexOfScalar(u8, buf[0..], 0) orelse buf.len;
        return std.heap.page_allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
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
    if (g_state.handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        var buf: [128]u8 = std.mem.zeroes([128]u8);
        (h.callbacks.remote_addr orelse return error.CapabilityError)(conn.host_handle, &buf, @intCast(buf.len), h.userdata);
        const len = std.mem.indexOfScalar(u8, buf[0..], 0) orelse buf.len;
        return std.heap.page_allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
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
    if (g_state.handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        if (h.callbacks.set_deadline) |fn_ptr| fn_ptr(conn.host_handle, ms, h.userdata);
        return;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_RCVTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.RCVTIMEO), ms);
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.SNDTIMEO), ms);
}

pub fn netSetReadDeadline(id: u32, ms: i64) !void {
    if (g_state.handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        if (h.callbacks.set_read_deadline) |fn_ptr| fn_ptr(conn.host_handle, ms, h.userdata);
        return;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_RCVTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.RCVTIMEO), ms);
}

pub fn netSetWriteDeadline(id: u32, ms: i64) !void {
    if (g_state.handlers) |h| {
        const conn = findConn(id) orelse return error.CapabilityError;
        if (h.callbacks.set_write_deadline) |fn_ptr| fn_ptr(conn.host_handle, ms, h.userdata);
        return;
    }
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows or !build_options.cap_net) return error.CapabilityNotAvailable;
    if (comptime builtin.os.tag == .windows) return error.CapabilityError; // TODO: Winsock SO_SNDTIMEO DWORD
    const conn = findConn(id) orelse return error.CapabilityError;
    try posixSetSockOptTimeval(conn.socket, @intCast(std.posix.SO.SNDTIMEO), ms);
}

// ---------------------------------------------------------------------------
// Policy matching tests
// ---------------------------------------------------------------------------
//
// A coverage audit found matchPolicy's CIDR matching, wildcard-suffix
// matching, and the deliberate any-interface anti-bypass guard (see its own
// comment above) had zero test coverage anywhere in the codebase — every
// existing cap:net test only exercised the basic allow/deny toggle. These
// operate on a local PolicyState directly (not g_state), so they need no
// process-global setup/teardown and can't interfere with any other test.

const testing = std.testing;

test "net policy: ipv4 CIDR matches within the subnet and rejects outside it" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .allow, "10.0.0.0/24", 0));
    try testing.expect(matchPolicy(&policy, "10.0.0.1:80", false));
    try testing.expect(matchPolicy(&policy, "10.0.0.255:80", false));
    try testing.expect(!matchPolicy(&policy, "10.0.1.0:80", false)); // one past the /24 boundary
    try testing.expect(!matchPolicy(&policy, "10.1.0.1:80", false));
}

test "net policy: ipv4 CIDR /32 behaves as an exact-host match" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .allow, "192.168.1.5/32", 0));
    try testing.expect(matchPolicy(&policy, "192.168.1.5:80", false));
    try testing.expect(!matchPolicy(&policy, "192.168.1.6:80", false));
}

test "net policy: ipv4 CIDR /0 matches every address" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .allow, "0.0.0.0/0", 0));
    try testing.expect(matchPolicy(&policy, "1.2.3.4:80", false));
    try testing.expect(matchPolicy(&policy, "255.255.255.255:80", false));
}

test "net policy: ipv6 CIDR matches within the subnet and rejects outside it" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .allow, "2001:db8::/32", 0));
    try testing.expect(matchPolicy(&policy, "[2001:db8::1]:80", false));
    try testing.expect(matchPolicy(&policy, "[2001:db8:ffff::1]:80", false));
    try testing.expect(!matchPolicy(&policy, "[2001:db9::1]:80", false));
}

test "net policy: ipv6 CIDR /128 behaves as an exact-host match" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .allow, "::1/128", 0));
    try testing.expect(matchPolicy(&policy, "[::1]:80", false));
    try testing.expect(!matchPolicy(&policy, "[::2]:80", false));
}

test "net policy: wildcard suffix matches subdomains but not a lookalike bare domain" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .allow, "*.example.com", 0));
    try testing.expect(matchPolicy(&policy, "api.example.com:443", false));
    try testing.expect(matchPolicy(&policy, "deep.sub.example.com:443", false));
    // Must not match a domain that merely ends with the same letters but has
    // no separating dot — "evilexample.com" is not a subdomain of
    // "example.com". The rule stores the suffix WITH its leading "." (see
    // buildPolicyRule) precisely to guard against this; a naive
    // endsWith(host, "example.com") check would wrongly allow it.
    try testing.expect(!matchPolicy(&policy, "evilexample.com:443", false));
    try testing.expect(!matchPolicy(&policy, "example.com:443", false)); // bare domain, not a subdomain
}

test "net policy: a deny rule on 0.0.0.0 blocks binding the empty (any-interface) host" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .deny, "0.0.0.0", 0));
    // ":8080" (no host) is POSIX's any-interface bind — must not silently
    // bypass a deny rule authored against its canonical "0.0.0.0" spelling.
    try testing.expect(!matchPolicy(&policy, ":8080", true));
}

test "net policy: a deny rule on :: blocks binding the empty (any-interface) host" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .deny, "::", 0));
    try testing.expect(!matchPolicy(&policy, ":8080", true));
}

test "net policy: a deny-all CIDR on the empty host also can't be bypassed" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .deny, "0.0.0.0/0", 0));
    try testing.expect(!matchPolicy(&policy, ":8080", true));
}

test "net policy: rules are evaluated LIFO — the most recently added rule wins" {
    var policy: PolicyState = .{};
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .deny, "10.0.0.0/8", 0));
    try testing.expect(!matchPolicy(&policy, "10.1.2.3:80", true));
    try testing.expectEqual(@as(i32, 0), addRuleTo(&policy, .allow, "10.1.2.3", 0));
    // The narrower, later allow rule overrides the earlier broad deny.
    try testing.expect(matchPolicy(&policy, "10.1.2.3:80", true));
}

// ---------------------------------------------------------------------------
// Host-handler round-trip tests
// ---------------------------------------------------------------------------
//
// netDial/netListen/etc. delegate entirely to a registered GengoNetHandlers
// when one is set (the embedding-API host-callback path) instead of touching
// real POSIX sockets at all. A fake handler set lets every one of those
// delegation branches run for real — argument marshaling, handle bookkeeping,
// error mapping — with no actual network I/O, the same technique that closed
// cap_http.zig/http_state.zig's coverage gap.

const FakeNetHandlerState = struct {
    buf: [2][256]u8 = undefined,
    buf_len: [2]usize = .{ 0, 0 },
    buf_pos: [2]usize = .{ 0, 0 },
    listener_handle: i32 = 100,
    last_deadline_ms: i64 = -1,
    last_read_deadline_ms: i64 = -1,
    last_write_deadline_ms: i64 = -1,
    last_accept_deadline_ms: i64 = -1,
    dial_network: [16]u8 = undefined,
    dial_network_len: usize = 0,
    dial_address: [64]u8 = undefined,
    dial_address_len: usize = 0,
    accept_should_block: bool = false,
};

var g_fake_net: FakeNetHandlerState = .{};

fn fakeDial(network: [*]const u8, network_len: usize, address: [*]const u8, address_len: usize, out_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = userdata;
    const nw = network[0..network_len];
    const addr = address[0..address_len];
    @memcpy(g_fake_net.dial_network[0..nw.len], nw);
    g_fake_net.dial_network_len = nw.len;
    @memcpy(g_fake_net.dial_address[0..addr.len], addr);
    g_fake_net.dial_address_len = addr.len;
    out_handle.* = 1;
    return 0;
}

fn fakeRead(handle: i32, buf: [*]u8, max_bytes: i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = userdata;
    const idx: usize = @intCast(handle - 1);
    const avail = g_fake_net.buf_len[idx] - g_fake_net.buf_pos[idx];
    const n = @min(avail, @as(usize, @intCast(max_bytes)));
    @memcpy(buf[0..n], g_fake_net.buf[idx][g_fake_net.buf_pos[idx] .. g_fake_net.buf_pos[idx] + n]);
    g_fake_net.buf_pos[idx] += n;
    return @intCast(n);
}

fn fakeWrite(handle: i32, data: [*]const u8, len: i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = userdata;
    const idx: usize = @intCast(handle - 1);
    const n: usize = @intCast(len);
    @memcpy(g_fake_net.buf[idx][g_fake_net.buf_len[idx] .. g_fake_net.buf_len[idx] + n], data[0..n]);
    g_fake_net.buf_len[idx] += n;
    return @intCast(n);
}

fn fakeClose(handle: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    _ = userdata;
}

fn fakeLocalAddr(handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    _ = userdata;
    const s = "127.0.0.1:9001";
    const n = @min(s.len, @as(usize, @intCast(buf_len)) - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

fn fakeRemoteAddr(handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    _ = userdata;
    const s = "203.0.113.7:443";
    const n = @min(s.len, @as(usize, @intCast(buf_len)) - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

fn fakeSetDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    _ = userdata;
    g_fake_net.last_deadline_ms = ms;
}

fn fakeSetReadDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    _ = userdata;
    g_fake_net.last_read_deadline_ms = ms;
}

fn fakeSetWriteDeadline(handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    _ = handle;
    _ = userdata;
    g_fake_net.last_write_deadline_ms = ms;
}

fn fakeListen(network: [*]const u8, network_len: usize, address: [*]const u8, address_len: usize, out_listener_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = network;
    _ = network_len;
    _ = address;
    _ = address_len;
    _ = userdata;
    out_listener_handle.* = g_fake_net.listener_handle;
    return 0;
}

fn fakeAccept(listener_handle: i32, out_conn_handle: *i32, userdata: ?*anyopaque) callconv(.c) i32 {
    _ = listener_handle;
    _ = userdata;
    if (g_fake_net.accept_should_block) return 0;
    out_conn_handle.* = 2;
    return 1;
}

fn fakeListenerClose(listener_handle: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = listener_handle;
    _ = userdata;
}

fn fakeListenerLocalAddr(listener_handle: i32, buf: [*]u8, buf_len: i32, userdata: ?*anyopaque) callconv(.c) void {
    _ = listener_handle;
    _ = userdata;
    const s = "0.0.0.0:9000";
    const n = @min(s.len, @as(usize, @intCast(buf_len)) - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

fn fakeSetAcceptDeadline(listener_handle: i32, ms: i64, userdata: ?*anyopaque) callconv(.c) void {
    _ = listener_handle;
    _ = userdata;
    g_fake_net.last_accept_deadline_ms = ms;
}

const fake_net_handlers: GengoNetHandlers = .{
    .dial = fakeDial,
    .read = fakeRead,
    .write = fakeWrite,
    .close = fakeClose,
    .local_addr = fakeLocalAddr,
    .remote_addr = fakeRemoteAddr,
    .set_deadline = fakeSetDeadline,
    .set_read_deadline = fakeSetReadDeadline,
    .set_write_deadline = fakeSetWriteDeadline,
    .listen = fakeListen,
    .accept = fakeAccept,
    .listener_close = fakeListenerClose,
    .listener_local_addr = fakeListenerLocalAddr,
    .set_accept_deadline = fakeSetAcceptDeadline,
};

test "net_state: dial/write/read/close and listen/accept/write/read/close round-trip through a fake host handler set" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    g_fake_net = .{};
    setNetHandlers(fake_net_handlers, null);
    defer resetHandlers();
    try testing.expect(hasHandlers());

    const conn_id = try netDial("tcp", "example.com:443");
    try testing.expectEqualStrings("tcp", g_fake_net.dial_network[0..g_fake_net.dial_network_len]);
    try testing.expectEqualStrings("example.com:443", g_fake_net.dial_address[0..g_fake_net.dial_address_len]);

    const written = try netWrite(conn_id, "hello");
    try testing.expectEqual(@as(usize, 5), written);

    const data = try netRead(conn_id, 5);
    defer std.heap.page_allocator.free(data);
    try testing.expectEqualStrings("hello", data);

    const local = try netLocalAddr(conn_id);
    defer std.heap.page_allocator.free(local);
    try testing.expectEqualStrings("127.0.0.1:9001", local);

    const remote = try netRemoteAddr(conn_id);
    defer std.heap.page_allocator.free(remote);
    try testing.expectEqualStrings("203.0.113.7:443", remote);

    try netSetDeadline(conn_id, 1000);
    try testing.expectEqual(@as(i64, 1000), g_fake_net.last_deadline_ms);
    try netSetReadDeadline(conn_id, 2000);
    try testing.expectEqual(@as(i64, 2000), g_fake_net.last_read_deadline_ms);
    try netSetWriteDeadline(conn_id, 3000);
    try testing.expectEqual(@as(i64, 3000), g_fake_net.last_write_deadline_ms);

    try netClose(conn_id);

    const listener_id = try netListen("tcp", "0.0.0.0:9000");
    const accepted_id = try netListenerAccept(listener_id);

    _ = try netWrite(accepted_id, "world");
    const data2 = try netRead(accepted_id, 5);
    defer std.heap.page_allocator.free(data2);
    try testing.expectEqualStrings("world", data2);

    const listener_local = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(listener_local);
    try testing.expectEqualStrings("0.0.0.0:9000", listener_local);

    try netListenerSetAcceptDeadline(listener_id, 4000);
    try testing.expectEqual(@as(i64, 4000), g_fake_net.last_accept_deadline_ms);

    try netListenerClose(listener_id);
}

test "net_state: accept returns DeadlineExceeded when the host handler reports would-block" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    g_fake_net = .{ .accept_should_block = true };
    setNetHandlers(fake_net_handlers, null);
    defer resetHandlers();

    const listener_id = try netListen("tcp", "0.0.0.0:9000");
    try testing.expectError(error.DeadlineExceeded, netListenerAccept(listener_id));
    try netListenerClose(listener_id);
}

test "net_state: dial/listen surface 'too many connections/listeners' once the fixed-size pools fill up" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    g_fake_net = .{};
    setNetHandlers(fake_net_handlers, null);
    defer resetHandlers();

    var i: usize = 0;
    while (i < MaxConns) : (i += 1) _ = try netDial("tcp", "x:1");
    try testing.expectError(error.NetError, netDial("tcp", "x:1"));
    try testing.expectEqualStrings("too many connections (max 16)", lastNetErr());

    i = 0;
    while (i < MaxListeners) : (i += 1) _ = try netListen("tcp", "x:1");
    try testing.expectError(error.NetError, netListen("tcp", "x:1"));
    try testing.expectEqualStrings("too many listeners (max 8)", lastNetErr());
}

// ---------------------------------------------------------------------------
// Native POSIX socket path tests
// ---------------------------------------------------------------------------
//
// Everything above exercises the hasHandlers()==true (host-callback) path.
// The functions in this file also have a native fast path — taken whenever
// no GengoNetHandlers are registered — that talks directly to std.posix TCP
// sockets. That path was almost entirely uncovered. It's fully testable
// without any external network access: a listener and a dialer on
// 127.0.0.1/::1 inside this same (single-threaded) test process. POSIX
// listen() backlog semantics complete a loopback TCP handshake at the kernel
// level as soon as connect() is called, independent of whether accept() has
// run yet — so a synchronous dial-then-accept sequence (no worker thread)
// is sufficient and was confirmed to work reliably here.
//
// Each test below builds its own local NetEngineState and setActive()s it
// (the same isolation pattern as the host-handler tests above), so no
// handlers are ever registered here and hasHandlers() is false throughout.

fn testPort(addr: []const u8) u16 {
    const colon = std.mem.lastIndexOfScalar(u8, addr, ':').?;
    return std.fmt.parseUnsigned(u16, addr[colon + 1 ..], 10) catch unreachable;
}

test "net_state (native): dial+listen+accept+read+write+close round-trips real bytes over IPv4 loopback" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    const listener_id = try netListen("tcp", "127.0.0.1:0");
    const listener_addr = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(listener_addr);
    try testing.expect(std.mem.startsWith(u8, listener_addr, "127.0.0.1:"));
    const port = testPort(listener_addr);

    var dial_buf: [32]u8 = undefined;
    const dial_addr = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});

    const dial_id = try netDial("tcp", dial_addr);
    const accept_id = try netListenerAccept(listener_id);

    try testing.expectEqual(@as(usize, 5), try netWrite(dial_id, "hello"));
    const from_dial = try netRead(accept_id, 16);
    defer std.heap.page_allocator.free(from_dial);
    try testing.expectEqualStrings("hello", from_dial);

    try testing.expectEqual(@as(usize, 5), try netWrite(accept_id, "world"));
    const from_accept = try netRead(dial_id, 16);
    defer std.heap.page_allocator.free(from_accept);
    try testing.expectEqualStrings("world", from_accept);

    const dial_local = try netLocalAddr(dial_id);
    defer std.heap.page_allocator.free(dial_local);
    try testing.expect(std.mem.startsWith(u8, dial_local, "127.0.0.1:"));

    const dial_remote = try netRemoteAddr(dial_id);
    defer std.heap.page_allocator.free(dial_remote);
    try testing.expectEqualStrings(listener_addr, dial_remote);

    const accept_local = try netLocalAddr(accept_id);
    defer std.heap.page_allocator.free(accept_local);
    try testing.expectEqualStrings(listener_addr, accept_local);

    const accept_remote = try netRemoteAddr(accept_id);
    defer std.heap.page_allocator.free(accept_remote);
    try testing.expectEqualStrings(dial_local, accept_remote);

    try netClose(dial_id);
    try netClose(accept_id);
    try netListenerClose(listener_id);
}

test "net_state (native): netReadInto serves several small reads from one buffered socket fill" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    const listener_id = try netListen("tcp", "127.0.0.1:0");
    const listener_addr = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(listener_addr);
    const port = testPort(listener_addr);
    var dial_buf: [32]u8 = undefined;
    const dial_addr = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});

    const dial_id = try netDial("tcp", dial_addr);
    const accept_id = try netListenerAccept(listener_id);
    defer netClose(dial_id) catch {};
    defer netClose(accept_id) catch {};
    defer netListenerClose(listener_id) catch {};

    const payload = "abcdefghijklmnopqrst"; // 20 bytes, written in one shot
    try testing.expectEqual(payload.len, try netWrite(dial_id, payload));

    var assembled: [64]u8 = undefined;
    var got: usize = 0;
    while (got < payload.len) {
        var small: [3]u8 = undefined;
        const n = try netReadInto(accept_id, &small);
        try testing.expect(n > 0);
        @memcpy(assembled[got .. got + n], small[0..n]);
        got += n;
    }
    try testing.expectEqualStrings(payload, assembled[0..got]);

    // Buffer now empty and nothing more written: a short read deadline should
    // surface DeadlineExceeded rather than blocking forever.
    try netSetReadDeadline(accept_id, 50);
    try testing.expectError(error.DeadlineExceeded, netReadInto(accept_id, &assembled));
    try testing.expectError(error.DeadlineExceeded, netRead(accept_id, 16));
}

test "net_state (native): netListenerAccept surfaces DeadlineExceeded when nothing dials before the accept deadline" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    const listener_id = try netListen("tcp", "127.0.0.1:0");
    defer netListenerClose(listener_id) catch {};

    try netListenerSetAcceptDeadline(listener_id, 50);
    try testing.expectError(error.DeadlineExceeded, netListenerAccept(listener_id));
}

test "net_state (native): netSetDeadline/netSetWriteDeadline succeed on a real connection" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    const listener_id = try netListen("tcp", "127.0.0.1:0");
    const listener_addr = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(listener_addr);
    const port = testPort(listener_addr);
    var dial_buf: [32]u8 = undefined;
    const dial_addr = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});

    const dial_id = try netDial("tcp", dial_addr);
    const accept_id = try netListenerAccept(listener_id);
    defer netClose(dial_id) catch {};
    defer netClose(accept_id) catch {};
    defer netListenerClose(listener_id) catch {};

    try netSetDeadline(dial_id, 1000);
    try netSetWriteDeadline(dial_id, 1000);

    // Negative ms is rejected by posixSetSockOptTimeval's own guard, for all
    // three deadline setters plus the listener's accept-deadline setter.
    try testing.expectError(error.CapabilityError, netSetDeadline(dial_id, -1));
    try testing.expectError(error.CapabilityError, netSetReadDeadline(dial_id, -1));
    try testing.expectError(error.CapabilityError, netSetWriteDeadline(dial_id, -1));
    try testing.expectError(error.CapabilityError, netListenerSetAcceptDeadline(listener_id, -1));
}

test "net_state (native): dial validates network kind, address shape, and port before touching sockets" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    try testing.expectError(error.NetError, netDial("udp", "127.0.0.1:80"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "unsupported network") != null);

    try testing.expectError(error.NetError, netDial("tcp", "no-port-here"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "invalid address") != null);

    try testing.expectError(error.NetError, netDial("tcp", "127.0.0.1:notaport"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "invalid port") != null);
}

test "net_state (native): listen validates network kind, address shape, port, and family mismatches" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    try testing.expectError(error.NetError, netListen("udp", "127.0.0.1:0"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "unsupported network") != null);

    try testing.expectError(error.NetError, netListen("tcp", "no-port-here"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "invalid address") != null);

    try testing.expectError(error.NetError, netListen("tcp", "127.0.0.1:notaport"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "invalid port") != null);

    try testing.expectError(error.NetError, netListen("tcp6", "127.0.0.1:0"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "not valid for network \"tcp6\"") != null);

    try testing.expectError(error.NetError, netListen("tcp4", "[::1]:0"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "not valid for network \"tcp4\"") != null);

    try testing.expectError(error.NetError, netListen("tcp", "not-an-ip:0"));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "bind address must be an IP literal") != null);
}

test "net_state (native): listen binds the any-interface address for an empty host, on both tcp and tcp6" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    const l4 = try netListen("tcp", ":0");
    const addr4 = try netListenerLocalAddr(l4);
    defer std.heap.page_allocator.free(addr4);
    try testing.expect(std.mem.startsWith(u8, addr4, "0.0.0.0:"));
    try netListenerClose(l4);

    const l6 = try netListen("tcp6", ":0");
    const addr6 = try netListenerLocalAddr(l6);
    defer std.heap.page_allocator.free(addr6);
    try testing.expect(std.mem.startsWith(u8, addr6, "[0000:0000:0000:0000:0000:0000:0000:0000]:"));
    try netListenerClose(l6);
}

test "net_state (native): listen accepts an IPv6 loopback bind and formats its address via formatIp6Address" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    const listener_id = try netListen("tcp6", "[::1]:0");
    defer netListenerClose(listener_id) catch {};
    const addr = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(addr);
    try testing.expect(std.mem.startsWith(u8, addr, "[0000:0000:0000:0000:0000:0000:0000:0001]:"));
}

// Regression: netDial split "host:port" on the last colon (same as
// netListen) but, unlike netListen, never stripped IPv6 brackets from the
// resulting host before passing it to HostName.validate — so dialing any
// bracketed IPv6 literal like "[::1]:PORT" always failed validation with
// "invalid hostname", even though the exact same bracket syntax already
// worked for net.listen. Fixed netDial to strip brackets identically.
test "net_state (native): dial reaches a real IPv6 loopback listener via a bracketed \"[::1]:port\" address" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    const listener_id = try netListen("tcp6", "[::1]:0");
    defer netListenerClose(listener_id) catch {};
    const addr = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(addr);
    const port = testPort(addr);

    var dial_buf: [32]u8 = undefined;
    const dial_addr = try std.fmt.bufPrint(&dial_buf, "[::1]:{d}", .{port});
    const conn_id = try netDial("tcp6", dial_addr);
    defer netClose(conn_id) catch {};

    const accepted_id = try netListenerAccept(listener_id);
    defer netClose(accepted_id) catch {};
    _ = try netWrite(conn_id, "hi");
    const got = try netRead(accepted_id, 16);
    defer std.heap.page_allocator.free(got);
    try testing.expectEqualStrings("hi", got);
}

test "net_state (native): dial reaches a real connect() attempt and surfaces connection-refused for a closed loopback port" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    // Reserve then immediately release a real ephemeral port: nothing is
    // listening on it afterward, so a loopback connect() reaches the OS and
    // is refused right away (unlike a remote host, which would just time out).
    const listener_id = try netListen("tcp", "127.0.0.1:0");
    const addr = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(addr);
    const port = testPort(addr);
    try netListenerClose(listener_id);

    var dial_buf: [32]u8 = undefined;
    const dial_addr = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});
    try testing.expectError(error.NetError, netDial("tcp", dial_addr));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "connection refused") != null);
}

test "net_state (native): dial/listen surface the real-path 'too many connections/listeners' pool limits" {
    var conn_state: NetEngineState = .{};
    try conn_state.initArrays(testing.allocator);
    defer conn_state.deinitArrays(testing.allocator);
    setActive(&conn_state);

    const listener_id = try netListen("tcp", "127.0.0.1:0");
    const listener_addr = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(listener_addr);
    const port = testPort(listener_addr);
    var dial_buf: [32]u8 = undefined;
    const dial_addr = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});

    var dial_ids: [MaxConns]u32 = undefined;
    var i: usize = 0;
    while (i < MaxConns) : (i += 1) dial_ids[i] = try netDial("tcp", dial_addr);
    try testing.expectError(error.NetError, netDial("tcp", dial_addr));
    try testing.expectEqualStrings("too many connections (max 16)", lastNetErr());

    for (dial_ids) |id| try netClose(id);
    try netListenerClose(listener_id);
    setActive(defaultState());

    var listener_state: NetEngineState = .{};
    try listener_state.initArrays(testing.allocator);
    defer listener_state.deinitArrays(testing.allocator);
    setActive(&listener_state);
    defer setActive(defaultState());

    var listener_ids: [MaxListeners]u32 = undefined;
    i = 0;
    while (i < MaxListeners) : (i += 1) listener_ids[i] = try netListen("tcp", "127.0.0.1:0");
    try testing.expectError(error.NetError, netListen("tcp", "127.0.0.1:0"));
    try testing.expectEqualStrings("too many listeners (max 8)", lastNetErr());

    for (listener_ids) |id| try netListenerClose(id);
}

test "net_state (native): read surfaces 'connection reset by peer' when the peer aborts with SO_LINGER(0)" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    const listener_id = try netListen("tcp", "127.0.0.1:0");
    const listener_addr = try netListenerLocalAddr(listener_id);
    defer std.heap.page_allocator.free(listener_addr);
    const port = testPort(listener_addr);
    var dial_buf: [32]u8 = undefined;
    const dial_addr = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});

    const dial_id = try netDial("tcp", dial_addr);
    const accept_id = try netListenerAccept(listener_id);
    defer netClose(dial_id) catch {};
    defer netListenerClose(listener_id) catch {};

    // Force an RST instead of a graceful FIN on the accept side, by closing
    // it with SO_LINGER{onoff=1, linger=0}. Bypasses netClose (which would
    // go through the normal close path) so we can set the socket option
    // directly on the underlying fd; the connection-table entry is then
    // dropped by hand so a later netClose(accept_id) doesn't double-close it.
    const accept_conn = findConn(accept_id).?;
    const lg = std.posix.linger{ .onoff = 1, .linger = 0 };
    _ = std.posix.system.setsockopt(accept_conn.socket, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&lg).ptr, @sizeOf(std.posix.linger));
    _ = std.posix.system.close(accept_conn.socket);
    removeConn(accept_id);

    // Blocking read (no deadline set): returns as soon as the local TCP
    // stack observes the RST, which on loopback is effectively immediate.
    try testing.expectError(error.NetError, netRead(dial_id, 16));
    try testing.expectEqualStrings("read: connection reset by peer", lastNetErr());
}

test "net_state (native): real POSIX path surfaces CapabilityError/NetError for unknown handles" {
    var state: NetEngineState = .{};
    try state.initArrays(testing.allocator);
    defer state.deinitArrays(testing.allocator);
    setActive(&state);
    defer setActive(defaultState());

    try testing.expectError(error.NetError, netRead(999, 1));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "unknown connection handle") != null);
    try testing.expectError(error.NetError, netWrite(999, "x"));
    var buf: [4]u8 = undefined;
    try testing.expectError(error.NetError, netReadInto(999, &buf));
    try testing.expectError(error.CapabilityError, netClose(999));
    try testing.expectError(error.CapabilityError, netLocalAddr(999));
    try testing.expectError(error.CapabilityError, netRemoteAddr(999));
    try testing.expectError(error.CapabilityError, netSetDeadline(999, 10));
    try testing.expectError(error.CapabilityError, netSetReadDeadline(999, 10));
    try testing.expectError(error.CapabilityError, netSetWriteDeadline(999, 10));

    try testing.expectError(error.NetError, netListenerAccept(999));
    try testing.expect(std.mem.indexOf(u8, lastNetErr(), "unknown listener handle") != null);
    try testing.expectError(error.CapabilityError, netListenerClose(999));
    try testing.expectError(error.CapabilityError, netListenerLocalAddr(999));
    try testing.expectError(error.CapabilityError, netListenerSetAcceptDeadline(999, 10));
}
