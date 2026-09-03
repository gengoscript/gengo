const std = @import("std");
const builtin = @import("builtin");
const tls_common = @import("tls_common.zig");

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
// points g_state at it, mirroring the fs_state/net_state pattern.
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

// CA bundle and TLS helpers live in tls_common (shared with cap:net TLS).
const ensureCaBundle = tls_common.ensureCaBundle;

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

const monotonicMs = tls_common.monotonicMs;
const FdReader = tls_common.FdReader;
const FdWriter = tls_common.FdWriter;

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
                    .lock = tls_common.caBundleLockRef(),
                    .bundle = tls_common.caBundleRef(),
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
            // "deflate" was never recognized here, leaving content_encoding
            // at .identity — the .deflate case in the decompression switch
            // below was completely unreachable dead code, silently handing
            // scripts the raw zlib-compressed bytes as if they were the
            // real body whenever a server sent Content-Encoding: deflate.
            if (std.mem.eql(u8, value, "gzip")) {
                content_encoding = .gzip;
            } else if (std.mem.eql(u8, value, "deflate")) {
                content_encoding = .deflate;
            }
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

// httpExchange takes already-abstracted *std.Io.Reader/*std.Io.Writer, so the
// request-building and response-parsing halves can be exercised directly
// with a Writer.Allocating (to capture/discard the outgoing request) and a
// Reader.fixed preloaded with a canned HTTP/1.1 response, with no real
// socket involved.

test "httpExchange parses a 200 response with a Content-Length body" {
    const uri = try std.Uri.parse("http://example.com/path?q=1");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");

    var result = try httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer);
    defer result.deinit();

    try testing.expectEqual(@as(i32, 200), result.status);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("hello", result.body);
}

test "httpExchange sets ok=false for a non-2xx status" {
    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 5\r\n\r\nnope!");

    var result = try httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer);
    defer result.deinit();

    try testing.expectEqual(@as(i32, 500), result.status);
    try testing.expect(!result.ok);
    try testing.expectEqualStrings("nope!", result.body);
}

test "httpExchange reassembles a chunked-transfer-encoded body" {
    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n\r\n");

    var result = try httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer);
    defer result.deinit();

    try testing.expectEqual(@as(i32, 200), result.status);
    try testing.expectEqualStrings("hello world", result.body);
}

test "httpExchange rejects a Content-Length above the response size cap" {
    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    // 70_000_000 > MaxResponseBodyBytes (64 MiB); the check fires before any
    // body bytes are read, so the fixed reader need not contain a body.
    var resp_reader = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\nContent-Length: 70000000\r\n\r\n");

    try testing.expectError(error.ResponseTooLarge, httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer));
}

test "httpExchange rejects an oversized chunk size in a chunked response" {
    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    // 0x5000000 == 83_886_080 bytes, over the 64 MiB cap; the size check
    // fires right after parsing the hex chunk-size line, before any chunk
    // data would be read.
    var resp_reader = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5000000\r\n");

    try testing.expectError(error.ResponseTooLarge, httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer));
}

test "httpExchange reads an unbounded body to EOF when no Content-Length or chunking is present" {
    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\n\r\nsome body text");

    var result = try httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer);
    defer result.deinit();

    try testing.expectEqualStrings("some body text", result.body);
}

test "httpExchange rejects a response with no parseable status line" {
    const uri = try std.Uri.parse("http://example.com/");

    var req_alloc1 = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc1.deinit();
    var empty_reader = std.Io.Reader.fixed("");
    try testing.expectError(error.InvalidResponse, httpExchange("GET", uri, "example.com", null, null, &empty_reader, &req_alloc1.writer));

    var req_alloc2 = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc2.deinit();
    var bad_status_reader = std.Io.Reader.fixed("HTTP/1.1 notanumber OK\r\n\r\n");
    try testing.expectError(error.InvalidResponse, httpExchange("GET", uri, "example.com", null, null, &bad_status_reader, &req_alloc2.writer));
}

test "httpExchange parses response headers with names/values split on the first colon and trimmed" {
    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\n" ++
        "X-Custom: value1\r\n" ++
        "X-Another:   value2\r\n" ++
        "Content-Length: 2\r\n" ++
        "\r\nhi");

    var result = try httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer);
    defer result.deinit();

    try testing.expectEqualStrings("hi", result.body);
    try testing.expectEqualStrings("value1", result.headers.get("X-Custom").?);
    try testing.expectEqualStrings("value2", result.headers.get("X-Another").?);
}

test "httpExchange decompresses a gzip Content-Encoding body and rewrites the header to identity" {
    const plaintext = "hello world";

    // Compress `plaintext` into a real gzip stream using std.compress.flate,
    // the same API httpExchange uses to decompress on the way in.
    var flate_out_buf: [4096]u8 = undefined;
    var flate_w: std.Io.Writer = .fixed(&flate_out_buf);
    var deflate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&flate_w, &deflate_buf, .gzip, .default);
    try compressor.writer.writeAll(plaintext);
    try compressor.finish();
    const gzip_bytes = flate_w.buffered();

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(testing.allocator);
    const header = try std.fmt.allocPrint(
        testing.allocator,
        "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
        .{gzip_bytes.len},
    );
    defer testing.allocator.free(header);
    try response.appendSlice(testing.allocator, header);
    try response.appendSlice(testing.allocator, gzip_bytes);

    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed(response.items);

    var result = try httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer);
    defer result.deinit();

    try testing.expectEqual(@as(i32, 200), result.status);
    try testing.expectEqualStrings(plaintext, result.body);
    try testing.expectEqualStrings("identity", result.headers.get("content-encoding").?);
}

// httpFetch's CRLF check on the raw method/header strings runs before any
// dispatch and is already covered above. httpExchange has its OWN, separate
// check: the URI's path/query are percent-decoded via toRaw() inside
// httpExchange itself, so a URL-encoded CRLF (%0d%0a) that only becomes a
// literal CR/LF after decoding is a different code path, exercised here.
test "httpExchange rejects a CRLF that only appears after percent-decoding the URI path" {
    const uri = try std.Uri.parse("http://example.com/%0d%0aX-Injected:%20evil");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    // No response bytes needed: the path is validated before anything is written or read.
    var resp_reader = std.Io.Reader.fixed("");

    try testing.expectError(error.InvalidRequest, httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer));
}

test "httpExchange rejects a CRLF that only appears after percent-decoding the URI query" {
    const uri = try std.Uri.parse("http://example.com/path?q=%0d%0aX-Injected:%20evil");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed("");

    try testing.expectError(error.InvalidRequest, httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer));
}

// Coverage-audit 2026-09: every httpExchange test above passes `null` for
// both maybe_body and maybe_headers, so the request-building side's own
// header-writing loop and body-writing call had never run — only the
// response-parsing half's headers were ever exercised.
test "httpExchange writes request headers and a request body" {
    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");

    var headers = std.StringHashMap([]const u8).init(testing.allocator);
    defer headers.deinit();
    try headers.put("X-Custom", "value1");

    var result = try httpExchange("POST", uri, "example.com", "payload", headers, &resp_reader, &req_alloc.writer);
    defer result.deinit();

    try testing.expectEqualStrings("ok", result.body);
    const written = req_alloc.written();
    try testing.expect(std.mem.indexOf(u8, written, "X-Custom: value1\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "Content-Length: 7\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, written, "payload"));
}

// Coverage-audit 2026-09: only the gzip Content-Encoding branch had ever
// been exercised; the sibling `deflate` (zlib-wrapped) branch had not.
test "httpExchange decompresses a deflate Content-Encoding body" {
    const plaintext = "hello deflate world";

    var flate_out_buf: [4096]u8 = undefined;
    var flate_w: std.Io.Writer = .fixed(&flate_out_buf);
    var deflate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&flate_w, &deflate_buf, .zlib, .default);
    try compressor.writer.writeAll(plaintext);
    try compressor.finish();
    const zlib_bytes = flate_w.buffered();

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(testing.allocator);
    const header = try std.fmt.allocPrint(
        testing.allocator,
        "HTTP/1.1 200 OK\r\ncontent-encoding: deflate\r\nContent-Length: {d}\r\n\r\n",
        .{zlib_bytes.len},
    );
    defer testing.allocator.free(header);
    try response.appendSlice(testing.allocator, header);
    try response.appendSlice(testing.allocator, zlib_bytes);

    const uri = try std.Uri.parse("http://example.com/");
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    var resp_reader = std.Io.Reader.fixed(response.items);

    var result = try httpExchange("GET", uri, "example.com", null, null, &resp_reader, &req_alloc.writer);
    defer result.deinit();

    try testing.expectEqualStrings(plaintext, result.body);
    try testing.expectEqualStrings("identity", result.headers.get("content-encoding").?);
}

// Coverage-audit 2026-09: httpFetchBuiltin (the real socket-connecting
// client used whenever no host handler is registered) had zero native test
// coverage — every existing cap:http test in compiler_test.zig registers a
// fake host handler, which takes an entirely different code path
// (httpFetchHost). This drives the actual URL-parse/TCP-connect/request-
// write/response-read path end to end against a real loopback listener, the
// same raw-POSIX-socket technique net_state.zig's own dial tests use (a
// plain http:// URL so no TLS handshake is involved).
test "httpFetch performs a real loopback HTTP request when no host handler is registered" {
    // g_state's handler is threadlocal, process-lifetime state shared by
    // every test in this binary — don't assume another test left it unset.
    resetHandler();
    defer resetHandler();

    const listen_sock = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    try testing.expect(std.posix.errno(listen_sock) == .SUCCESS);
    const listen_fd: std.posix.socket_t = @intCast(listen_sock);
    defer _ = std.posix.system.close(listen_fd);

    var addr_storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
    const sa: *std.posix.sockaddr.in = @ptrCast(&addr_storage);
    sa.family = std.posix.AF.INET;
    sa.port = 0;
    sa.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
    try testing.expect(std.posix.errno(std.posix.system.bind(listen_fd, @ptrCast(&addr_storage), @sizeOf(std.posix.sockaddr.in))) == .SUCCESS);
    try testing.expect(std.posix.errno(std.posix.system.listen(listen_fd, 1)) == .SUCCESS);

    var actual_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try testing.expect(std.posix.errno(std.posix.system.getsockname(listen_fd, @ptrCast(&addr_storage), &actual_len)) == .SUCCESS);
    const port = std.mem.bigToNative(u16, sa.port);

    const Worker = struct {
        fn run(fd: std.posix.socket_t) void {
            const crc = std.posix.system.accept(fd, null, null);
            if (std.posix.errno(crc) != .SUCCESS) return;
            const conn: std.posix.socket_t = @intCast(crc);
            defer _ = std.posix.system.close(conn);
            // Drain the request up to the blank line terminating headers —
            // proves the real client actually wrote a well-formed request,
            // not just that some bytes arrived.
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = std.posix.read(conn, buf[total..]) catch return;
                if (n == 0) return;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            if (!std.mem.startsWith(u8, buf[0..total], "GET / HTTP/1.1\r\n")) return;
            const resp = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
            _ = std.posix.system.write(conn, resp.ptr, resp.len);
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{listen_fd});
    defer thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var result = try httpFetch("GET", url, null, null, 0);
    defer result.deinit();

    try testing.expectEqual(@as(i32, 200), result.status);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("hello", result.body);
}
