const std = @import("std");
const builtin = @import("builtin");

// Response body size cap for the built-in HTTP client (applies to
// Content-Length, cumulative chunked-transfer, unbounded/no-length bodies,
// and post-decompression size alike) — cap:http has no host allowlist, so
// any server a script can reach could otherwise exhaust host memory with an
// oversized or endless response.
const MaxResponseBodyBytes: usize = 64 * 1024 * 1024;

pub const HttpResult = struct {
    status: i32,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
    ok: bool,
    body_needs_free: bool = false,

    pub fn deinit(self: *HttpResult) void {
        if (self.body_needs_free) std.heap.page_allocator.free(self.body);
        self.headers.deinit();
    }
};

/// C-compatible struct for HTTP headers in the host API.
/// `keys` and `values` are parallel arrays of null-terminated strings.
/// In C: const char** keys;  →  ?[*]const [*:0]const u8 in Zig.
pub const GengoHttpHeaders = extern struct {
    keys: ?[*]const [*:0]const u8,
    values: ?[*]const [*:0]const u8,
    count: c_int,
};

/// C-compatible request struct for the host API.
pub const GengoHttpRequest = extern struct {
    method: [*:0]const u8,
    url: [*:0]const u8,
    body: [*]const u8,
    body_len: c_int,
    headers: GengoHttpHeaders,
    timeout_ms: i64,
};

/// C-compatible response struct for the host API.
/// The host fills this in; the engine copies data out.
pub const GengoHttpResponse = extern struct {
    status: c_int,
    body: [*]const u8,
    body_len: c_int,
    headers: GengoHttpHeaders,
};

/// Host-provided HTTP fetch callback.
/// Returns negative on network failure / timeout (becomes runtime error).
/// Returns 0 on success — the script sees the response regardless of status code.
pub const GengoHttpFetchFn = *const fn (
    req: *const GengoHttpRequest,
    out: *GengoHttpResponse,
    userdata: ?*anyopaque,
) callconv(.c) c_int;

pub const HandlerSet = struct {
    callback: GengoHttpFetchFn,
    userdata: ?*anyopaque,
};

// Per-runtime HTTP handler state. Each Runtime owns an HttpEngineState; activate()
// points g_state at it, mirroring the fs_state/net_state pattern (#216).
pub const HttpEngineState = struct {
    handler: ?HandlerSet = null,
};

pub var g_default_state: HttpEngineState = .{};
threadlocal var g_state: *HttpEngineState = &g_default_state;

pub fn setActive(state: *HttpEngineState) void {
    g_state = state;
}

pub fn defaultState() *HttpEngineState {
    return &g_default_state;
}

// Lazily-populated system CA trust store for the built-in HTTPS client,
// shared across requests (rescanning the OS trust store per-request would be
// slow). Mirrors the pattern std.http.Client itself uses (Client.zig's
// ca_bundle/ca_bundle_lock fields + the lazy-rescan-on-first-use in
// Client.request).
var g_ca_bundle: std.crypto.Certificate.Bundle = .empty;
var g_ca_bundle_lock: std.Io.RwLock = .init;
var g_ca_bundle_loaded: bool = false;

fn ensureCaBundle(io: std.Io) !void {
    {
        try g_ca_bundle_lock.lockShared(io);
        defer g_ca_bundle_lock.unlockShared(io);
        if (g_ca_bundle_loaded) return;
    }
    var bundle: std.crypto.Certificate.Bundle = .empty;
    errdefer bundle.deinit(std.heap.page_allocator);
    const now = std.Io.Timestamp.now(io, .real);
    try bundle.rescan(std.heap.page_allocator, io, now);
    try g_ca_bundle_lock.lock(io);
    defer g_ca_bundle_lock.unlock(io);
    if (!g_ca_bundle_loaded) {
        std.mem.swap(std.crypto.Certificate.Bundle, &g_ca_bundle, &bundle);
        g_ca_bundle_loaded = true;
    }
    bundle.deinit(std.heap.page_allocator);
}

pub fn setHttpHandler(callback: GengoHttpFetchFn, userdata: ?*anyopaque) void {
    g_state.handler = .{ .callback = callback, .userdata = userdata };
}

pub fn hasHandler() bool {
    return g_state.handler != null;
}

pub fn resetHandler() void {
    g_state.handler = null;
}

/// Perform an HTTP fetch. Uses the host handler if registered, otherwise falls
/// back to the built-in default on native targets. On WASI with no handler,
/// returns CapabilityNotAvailable.
///
/// Returns a struct with:
///   status: HTTP status code (int)
///   body: response body string
///   headers: map of lower-cased header names to values
///   ok: true if status is 200–299
fn containsCrlf(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\r') != null or std.mem.indexOfScalar(u8, s, '\n') != null;
}

pub fn httpFetch(
    method: []const u8,
    url: []const u8,
    body: ?[]const u8,
    headers: ?std.StringHashMap([]const u8),
    timeout_ms: i64,
) !HttpResult {
    // Reject CR/LF in the method or any header name/value before it ever
    // reaches a raw request-line/header write (built-in client) or a host
    // handler — otherwise a script-controlled method/header lets it inject
    // arbitrary extra headers or smuggle a second request.
    if (containsCrlf(method)) return error.InvalidRequest;
    if (headers) |hdrs| {
        var it = hdrs.iterator();
        while (it.next()) |entry| {
            if (containsCrlf(entry.key_ptr.*) or containsCrlf(entry.value_ptr.*)) return error.InvalidRequest;
        }
    }

    if (g_state.handler) |h| {
        return try httpFetchHost(h, method, url, body, headers, timeout_ms);
    }

    // No host handler — use built-in default on Linux/macOS only.
    // Windows lacks ws2_32.pollfd in Zig 0.16.0 and requires a host handler.
    if (comptime builtin.target.cpu.arch == .wasm32 or builtin.target.os.tag == .windows) {
        return error.CapabilityNotAvailable;
    }

    return try httpFetchBuiltin(method, url, body, headers, timeout_ms);
}

fn httpFetchHost(
    h: HandlerSet,
    method: []const u8,
    url: []const u8,
    maybe_body: ?[]const u8,
    maybe_headers: ?std.StringHashMap([]const u8),
    timeout_ms: i64,
) !HttpResult {
    const body_ptr: [*]const u8 = if (maybe_body) |b| b.ptr else "";
    // A request body over c_int's ~2GB range would make @intCast panic;
    // only reachable via a custom-registered host handler (setHttpHandler),
    // but a script could still construct such a body.
    if (maybe_body) |b| {
        if (b.len > std.math.maxInt(c_int)) return error.RequestTooLarge;
    }
    const body_len: c_int = if (maybe_body) |b| @intCast(b.len) else 0;

    // Null-terminate method and url for the C API
    const method_z = std.heap.page_allocator.dupeZ(u8, method) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(method_z);
    const url_z = std.heap.page_allocator.dupeZ(u8, url) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(url_z);

    var req = GengoHttpRequest{
        .method = method_z,
        .url = url_z,
        .body = body_ptr,
        .body_len = body_len,
        .headers = .{ .keys = null, .values = null, .count = 0 },
        .timeout_ms = timeout_ms,
    };

    // Null-terminate headers for the C API
    var host_headers_keys: [64][:0]const u8 = undefined;
    var host_headers_vals: [64][:0]const u8 = undefined;
    var header_count: usize = 0;

    if (maybe_headers) |hdrs| {
        var it = hdrs.iterator();
        while (it.next()) |entry| {
            if (header_count >= 64) break;
            const k = std.heap.page_allocator.dupeZ(u8, entry.key_ptr.*) catch continue;
            const v = std.heap.page_allocator.dupeZ(u8, entry.value_ptr.*) catch {
                std.heap.page_allocator.free(k);
                continue;
            };
            host_headers_keys[header_count] = k;
            host_headers_vals[header_count] = v;
            header_count += 1;
        }
    }
    defer {
        for (host_headers_keys[0..header_count], host_headers_vals[0..header_count]) |k, v| {
            std.heap.page_allocator.free(k);
            std.heap.page_allocator.free(v);
        }
    }

    var c_keys: ?[*]const [*:0]const u8 = null;
    var c_vals: ?[*]const [*:0]const u8 = null;
    if (header_count > 0) {
        c_keys = @ptrCast(&host_headers_keys[0]);
        c_vals = @ptrCast(&host_headers_vals[0]);
    }
    req.headers = .{ .keys = c_keys, .values = c_vals, .count = @intCast(header_count) };

    var out = GengoHttpResponse{
        .status = 0,
        .body = undefined,
        .body_len = 0,
        .headers = .{ .keys = null, .values = null, .count = 0 },
    };

    const rc = h.callback(&req, &out, h.userdata);
    if (rc < 0) return error.HttpHandlerError;

    const resp_body = if (out.body_len > 0)
        out.body[0..@as(usize, @intCast(out.body_len))]
    else
        "";

    var resp_headers = std.StringHashMap([]const u8).init(std.heap.page_allocator);
    errdefer resp_headers.deinit();

    if (out.headers.count > 0 and out.headers.keys != null and out.headers.values != null) {
        const count: usize = @intCast(out.headers.count);
        const keys_ptr = out.headers.keys.?;
        const vals_ptr = out.headers.values.?;
        for (0..count) |i| {
            try resp_headers.put(std.mem.span(keys_ptr[i]), std.mem.span(vals_ptr[i]));
        }
    }

    const ok = out.status >= 200 and out.status < 300;
    return .{
        .status = out.status,
        .body = resp_body,
        .headers = resp_headers,
        .ok = ok,
    };
}

// Returns milliseconds since an arbitrary monotonic epoch.
fn monotonicMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// FdReader wraps a raw socket fd with poll()-based deadline enforcement.
// It bypasses std.Io.Threaded.netReadPosix which panics on EAGAIN (debug) /
// returns Unexpected (release) when SO_RCVTIMEO fires.
const FdReader = struct {
    fd: std.posix.socket_t,
    deadline_ms: i64, // absolute monotonic deadline; 0 = no timeout
    timed_out: bool,
    interface: std.Io.Reader,

    const vtable = std.Io.Reader.VTable{ .stream = streamFn };

    pub fn init(fd: std.posix.socket_t, buf: []u8, deadline_ms: i64) FdReader {
        return .{
            .fd = fd,
            .deadline_ms = deadline_ms,
            .timed_out = false,
            .interface = .{ .vtable = &vtable, .buffer = buf, .seek = 0, .end = 0 },
        };
    }

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *FdReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.deadline_ms > 0) {
            const remaining = self.deadline_ms - monotonicMs();
            if (remaining <= 0) {
                self.timed_out = true;
                return error.ReadFailed;
            }
            const poll_ms: i32 = @intCast(@min(remaining, std.math.maxInt(i32)));
            var pfd = [1]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const rc = std.posix.poll(&pfd, poll_ms) catch return error.ReadFailed;
            if (rc == 0) {
                self.timed_out = true;
                return error.ReadFailed;
            }
        }
        const dest = limit.slice(w.writableSliceGreedy(1) catch return error.WriteFailed);
        const n = std.posix.read(self.fd, dest) catch |err| {
            if (err == error.WouldBlock) self.timed_out = true;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }
};

// FdWriter wraps a raw socket fd with poll()-based deadline enforcement.
const FdWriter = struct {
    fd: std.posix.socket_t,
    deadline_ms: i64,
    timed_out: bool,
    interface: std.Io.Writer,

    const vtable = std.Io.Writer.VTable{ .drain = drainFn };

    pub fn init(fd: std.posix.socket_t, buf: []u8, deadline_ms: i64) FdWriter {
        return .{
            .fd = fd,
            .deadline_ms = deadline_ms,
            .timed_out = false,
            .interface = .{ .vtable = &vtable, .buffer = buf, .end = 0 },
        };
    }

    fn writeFd(self: *FdWriter, data: []const u8) std.Io.Writer.Error!void {
        var remaining = data;
        const max_count: usize = if (builtin.os.tag == .linux) 0x7ffff000 else std.math.maxInt(isize);
        while (remaining.len > 0) {
            if (self.deadline_ms > 0) {
                const rem_time = self.deadline_ms - monotonicMs();
                if (rem_time <= 0) {
                    self.timed_out = true;
                    return error.WriteFailed;
                }
                const poll_ms: i32 = @intCast(@min(rem_time, std.math.maxInt(i32)));
                var pfd = [1]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                const rc = std.posix.poll(&pfd, poll_ms) catch return error.WriteFailed;
                if (rc == 0) {
                    self.timed_out = true;
                    return error.WriteFailed;
                }
            }
            while (true) {
                const rc = std.posix.system.write(self.fd, remaining.ptr, @min(remaining.len, max_count));
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {
                        remaining = remaining[@intCast(rc)..];
                        break;
                    },
                    .INTR => continue,
                    .AGAIN => {
                        self.timed_out = true;
                        return error.WriteFailed;
                    },
                    else => return error.WriteFailed,
                }
            }
        }
    }

    fn drainFn(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @alignCast(@fieldParentPtr("interface", w));
        const buffered = w.buffered();
        var total_in: usize = buffered.len;
        for (data) |s| total_in += s.len;
        if (splat > 1 and data.len > 0) total_in += data[data.len - 1].len * (splat - 1);
        if (buffered.len > 0) try self.writeFd(buffered);
        for (data, 0..) |s, i| {
            const count: usize = if (i == data.len - 1) splat else 1;
            var j: usize = 0;
            while (j < count) : (j += 1) try self.writeFd(s);
        }
        return w.consume(total_in);
    }
};

fn httpFetchBuiltin(
    method: []const u8,
    url: []const u8,
    maybe_body: ?[]const u8,
    maybe_headers: ?std.StringHashMap([]const u8),
    timeout_ms: i64,
) !HttpResult {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return error.InvalidUrl;
    const is_tls = std.mem.eql(u8, uri.scheme, "https");
    const port = uri.port orelse if (is_tls) @as(u16, 443) else 80;

    const io = std.Io.Threaded.global_single_threaded.io();

    var stream = host.connect(io, port, .{ .mode = .stream }) catch |e| return e;
    defer stream.close(io);

    // Compute absolute deadline (0 means no timeout)
    // timeout_ms is a script-supplied argument (cap_http.zig accepts any
    // .int with no upper bound) — a raw `+` here panics on overflow for a
    // huge value (e.g. i64::max), same class of bug already fixed in
    // vm.zig's arithmetic opcodes. Saturate instead of trapping.
    const deadline_ms: i64 = if (timeout_ms > 0) (std.math.add(i64, monotonicMs(), timeout_ms) catch std.math.maxInt(i64)) else 0;

    const tls_min_buf = std.crypto.tls.Client.min_buffer_len;
    var stream_read_buf: [tls_min_buf]u8 = undefined;
    var stream_write_buf: [tls_min_buf]u8 = undefined;
    var tls_read_buf: [tls_min_buf]u8 = undefined;
    var tls_write_buf: [tls_min_buf]u8 = undefined;

    // Use deadline-aware fd readers/writers instead of the std.Io vtable path,
    // which panics on EAGAIN in debug builds when a socket timeout fires.
    var fd_reader = FdReader.init(stream.socket.handle, &stream_read_buf, deadline_ms);
    var fd_writer = FdWriter.init(stream.socket.handle, &stream_write_buf, deadline_ms);

    var tls_client: ?std.crypto.tls.Client = null;
    if (is_tls) {
        // `.ca = .no_verification` accepts ANY certificate for ANY host —
        // it explicitly documents itself as "prevents a trusted connection
        // from being established" and was silently making every https://
        // request MITM-able. Use the real OS trust store instead, matching
        // how std.http.Client itself wires up TLS.
        try ensureCaBundle(io);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.vtable.random(io.userdata, &entropy);
        const now = std.Io.Timestamp.now(io, .real);
        tls_client = std.crypto.tls.Client.init(
            &fd_reader.interface,
            &fd_writer.interface,
            .{
                .host = .{ .explicit = host.bytes },
                .ca = .{ .bundle = .{
                    .gpa = std.heap.page_allocator,
                    .io = io,
                    .lock = &g_ca_bundle_lock,
                    .bundle = &g_ca_bundle,
                } },
                .write_buffer = &tls_write_buf,
                .read_buffer = &tls_read_buf,
                .entropy = &entropy,
                .realtime_now = now,
            },
        ) catch |e| return e;
    }

    const actual_reader: *std.Io.Reader = if (tls_client) |*tc| &tc.reader else &fd_reader.interface;
    const actual_writer: *std.Io.Writer = if (tls_client) |*tc| &tc.writer else &fd_writer.interface;

    return httpExchange(method, uri, host.bytes, maybe_body, maybe_headers, actual_reader, actual_writer) catch |err| {
        if (fd_reader.timed_out or fd_writer.timed_out) return error.Timeout;
        return err;
    };
}

fn httpExchange(
    method: []const u8,
    uri: std.Uri,
    host_bytes: []const u8,
    maybe_body: ?[]const u8,
    maybe_headers: ?std.StringHashMap([]const u8),
    actual_reader: *std.Io.Reader,
    actual_writer: *std.Io.Writer,
) !HttpResult {
    // Build HTTP request
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    const req_w = &req_alloc.writer;

    var uri_buf: [4096]u8 = undefined;
    const path = if (uri.path.isEmpty()) "/" else (uri.path.toRaw(&uri_buf) catch "/");
    // toRaw() percent-decodes the component, so a URL-encoded CR/LF
    // (%0d%0a) becomes a literal one right here — reject it rather than
    // write it straight into the request line (request-splitting/header
    // injection via the URL alone, no headers option needed).
    if (containsCrlf(path)) return error.InvalidRequest;
    try req_w.print("{s} {s}", .{ method, path });
    if (uri.query) |q| {
        var q_buf: [4096]u8 = undefined;
        const q_raw = q.toRaw(&q_buf) catch "";
        if (containsCrlf(q_raw)) return error.InvalidRequest;
        if (q_raw.len > 0) try req_w.print("?{s}", .{q_raw});
    }
    try req_w.writeAll(" HTTP/1.1\r\n");
    try req_w.print("Host: {s}\r\n", .{host_bytes});
    try req_w.writeAll("User-Agent: gengo\r\n");
    try req_w.writeAll("Accept: */*\r\n");
    if (maybe_body) |body| try req_w.print("Content-Length: {d}\r\n", .{body.len});
    if (maybe_headers) |hdrs| {
        var it = hdrs.iterator();
        while (it.next()) |entry| try req_w.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    try req_w.writeAll("\r\n");

    _ = try actual_writer.writeVec(&.{req_alloc.written()});
    try actual_writer.flush();

    if (maybe_body) |body| {
        _ = try actual_writer.writeVec(&.{body});
        try actual_writer.flush();
    }

    // Parse response status line and headers
    var status_code: u16 = 0;
    var content_length: ?u64 = null;
    var transfer_chunked = false;
    var content_encoding: std.http.ContentEncoding = .identity;
    var resp_headers = std.StringHashMap([]const u8).init(std.heap.page_allocator);
    errdefer resp_headers.deinit();

    // Status line: "HTTP/1.1 200 OK\r\n"
    {
        const line = (try actual_reader.takeDelimiter('\n')) orelse return error.InvalidResponse;
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        var parts = std.mem.splitScalar(u8, trimmed, ' ');
        _ = parts.next();
        const status_str = parts.next() orelse return error.InvalidResponse;
        status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidResponse;
    }

    // Headers
    var header_values: [64]struct { name: []const u8, value: []const u8 } = undefined;
    var header_count: usize = 0;

    while (true) {
        const line = (try actual_reader.takeDelimiter('\n')) orelse break;
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (trimmed.len == 0) break;

        const colon_idx = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = trimmed[0..colon_idx];
        const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " ");

        if (header_count < header_values.len) {
            const name_dup = std.heap.page_allocator.dupe(u8, name) catch continue;
            const value_dup = std.heap.page_allocator.dupe(u8, value) catch {
                std.heap.page_allocator.free(name_dup);
                continue;
            };
            header_values[header_count] = .{ .name = name_dup, .value = value_dup };
            header_count += 1;
        }

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.mem.indexOf(u8, value, "chunked") != null) transfer_chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-encoding")) {
            if (std.mem.eql(u8, value, "gzip")) content_encoding = .gzip;
        }
    }

    for (header_values[0..header_count]) |hv| resp_headers.put(hv.name, hv.value) catch {};

    // Read body
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(std.heap.page_allocator);

    // A malicious/misbehaving server otherwise has no way for a script's
    // http.fetch to be bounded: an oversized (or attacker-claimed, since
    // cap:http has no host allowlist) Content-Length or an endless chunked/
    // unbounded body can exhaust host memory. Cap total body size the same
    // way regardless of transfer encoding.
    if (transfer_chunked) {
        while (true) {
            const size_line = (try actual_reader.takeDelimiter('\n')) orelse break;
            const chunk_size_str = if (size_line.len > 0 and size_line[size_line.len - 1] == '\r') size_line[0 .. size_line.len - 1] else size_line;
            const chunk_size = std.fmt.parseInt(usize, chunk_size_str, 16) catch break;
            if (chunk_size == 0) break;

            const offset = body.items.len;
            if (chunk_size > MaxResponseBodyBytes - offset) return error.ResponseTooLarge;
            try body.resize(std.heap.page_allocator, offset + chunk_size);
            try actual_reader.readSliceAll(body.items[offset..]);
            _ = try actual_reader.takeDelimiter('\n');
        }
        while (true) {
            const trail = (try actual_reader.takeDelimiter('\n')) orelse break;
            if (trail.len <= 1) break;
        }
    } else if (content_length) |len| {
        if (len > MaxResponseBodyBytes) return error.ResponseTooLarge;
        if (len > 0) {
            try body.resize(std.heap.page_allocator, len);
            try actual_reader.readSliceAll(body.items);
        }
    } else {
        try std.Io.Reader.appendRemaining(actual_reader, std.heap.page_allocator, &body, .limited(MaxResponseBodyBytes));
    }

    // Decompress gzip body
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressed_alloc: ?[]u8 = null;

    if (content_encoding != .identity) {
        var body_reader = std.Io.Reader.fixed(body.items);
        const transfer_reader = switch (content_encoding) {
            .gzip => blk: {
                decompress = .{ .flate = .init(&body_reader, .gzip, &decompress_buf) };
                break :blk &decompress.flate.reader;
            },
            .deflate => blk: {
                decompress = .{ .flate = .init(&body_reader, .zlib, &decompress_buf) };
                break :blk &decompress.flate.reader;
            },
            else => &body_reader,
        };
        // Cap decompressed size too — otherwise a small compressed body
        // (well under MaxResponseBodyBytes) can still "bomb" to gigabytes.
        decompressed_alloc = try transfer_reader.allocRemaining(std.heap.page_allocator, .limited(MaxResponseBodyBytes));

        resp_headers.put("content-encoding", "identity") catch {};
        body.deinit(std.heap.page_allocator);
    }

    const ok = status_code >= 200 and status_code < 300;

    if (decompressed_alloc) |d| {
        return .{
            .status = @intCast(status_code),
            .body = d,
            .headers = resp_headers,
            .ok = ok,
            .body_needs_free = true,
        };
    }

    return .{
        .status = @intCast(status_code),
        .body = body.items,
        .headers = resp_headers,
        .ok = ok,
        .body_needs_free = true,
    };
}

const testing = std.testing;

test "containsCrlf detects CR and LF anywhere in the string" {
    try testing.expect(!containsCrlf("GET"));
    try testing.expect(!containsCrlf("X-Custom-Header"));
    try testing.expect(containsCrlf("GET /x HTTP/1.1\r\nHost: evil"));
    try testing.expect(containsCrlf("value\r"));
    try testing.expect(containsCrlf("value\n"));
}

// httpFetch used to build the raw request line/headers directly from
// script-controlled method/url/header strings with no validation at all —
// a CRLF anywhere in them (raw, or percent-decoded out of the URL's path/
// query) let a script inject arbitrary extra headers or smuggle a second
// request. The method/header check runs before any dispatch (host handler
// or built-in client), so this doesn't need a real network connection to
// verify.
test "httpFetch rejects CRLF in method or headers before any dispatch" {
    try testing.expectError(error.InvalidRequest, httpFetch("GET /x HTTP/1.1\r\nX-Injected: evil", "http://example.com/", null, null, 0));

    var headers = std.StringHashMap([]const u8).init(testing.allocator);
    defer headers.deinit();
    try headers.put("X-Custom", "evil\r\nX-Injected: yes");
    try testing.expectError(error.InvalidRequest, httpFetch("GET", "http://example.com/", null, headers, 0));

    var headers2 = std.StringHashMap([]const u8).init(testing.allocator);
    defer headers2.deinit();
    try headers2.put("X-Bad\r\nX-Injected", "value");
    try testing.expectError(error.InvalidRequest, httpFetch("GET", "http://example.com/", null, headers2, 0));
}
