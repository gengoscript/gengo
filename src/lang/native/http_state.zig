const std = @import("std");
const builtin = @import("builtin");

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

const HandlerSet = struct {
    callback: GengoHttpFetchFn,
    userdata: ?*anyopaque,
};

var g_http_handler: ?HandlerSet = null;

pub fn setHttpHandler(callback: GengoHttpFetchFn, userdata: ?*anyopaque) void {
    g_http_handler = .{ .callback = callback, .userdata = userdata };
}

pub fn hasHandler() bool {
    return g_http_handler != null;
}

pub fn resetHandler() void {
    g_http_handler = null;
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
pub fn httpFetch(
    method: []const u8,
    url: []const u8,
    body: ?[]const u8,
    headers: ?std.StringHashMap([]const u8),
    timeout_ms: i64,
) !HttpResult {
    if (g_http_handler) |h| {
        return try httpFetchHost(h, method, url, body, headers, timeout_ms);
    }

    // No host handler — use built-in default on native, fail on WASM.
    if (comptime builtin.target.cpu.arch == .wasm32) {
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
        var di: usize = 0;
        while (di < header_count) : (di += 1) {
            std.heap.page_allocator.free(host_headers_keys[di]);
            std.heap.page_allocator.free(host_headers_vals[di]);
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
    if (rc < 0) return error.CapabilityError;

    const resp_body = if (out.body_len > 0)
        out.body[0..@as(usize, @intCast(out.body_len))]
    else
        "";

    var resp_headers = std.StringHashMap([]const u8).init(std.heap.page_allocator);
    errdefer resp_headers.deinit();

    if (out.headers.count > 0 and out.headers.keys != null and out.headers.values != null) {
        const keys_ptr = out.headers.keys.?;
        const vals_ptr = out.headers.values.?;
        var i: usize = 0;
        while (i < @as(usize, @intCast(out.headers.count))) : (i += 1) {
            const key = std.mem.span(keys_ptr[i]);
            const val = std.mem.span(vals_ptr[i]);
            try resp_headers.put(key, val);
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

fn httpFetchBuiltin(
    method: []const u8,
    url: []const u8,
    maybe_body: ?[]const u8,
    maybe_headers: ?std.StringHashMap([]const u8),
    _timeout_ms: i64,
) !HttpResult {
    _ = _timeout_ms;

    const uri = std.Uri.parse(url) catch return error.CapabilityError;

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return error.CapabilityError;
    const is_tls = std.mem.eql(u8, uri.scheme, "https");
    const port = uri.port orelse if (is_tls) @as(u16, 443) else 80;

    const io = std.Io.Threaded.global_single_threaded.io();

    var stream = host.connect(io, port, .{ .mode = .stream }) catch return error.CapabilityError;
    defer stream.close(io);

    const tls_min_buf = std.crypto.tls.Client.min_buffer_len;
    var stream_read_buf: [tls_min_buf]u8 = undefined;
    var stream_write_buf: [tls_min_buf]u8 = undefined;
    var tls_read_buf: [tls_min_buf]u8 = undefined;
    var tls_write_buf: [tls_min_buf]u8 = undefined;

    var sr = stream.reader(io, &stream_read_buf);
    var sw = stream.writer(io, &stream_write_buf);

    var tls_client: ?std.crypto.tls.Client = null;
    if (is_tls) {
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.vtable.random(io.userdata, &entropy);
        const now = std.Io.Timestamp.now(io, .real);
        tls_client = std.crypto.tls.Client.init(
            &sr.interface,
            &sw.interface,
            .{
                .host = .{ .explicit = host.bytes },
                .ca = .{ .no_verification = {} },
                .write_buffer = &tls_write_buf,
                .read_buffer = &tls_read_buf,
                .entropy = &entropy,
                .realtime_now = now,
            },
        ) catch return error.CapabilityError;
    }

    const actual_reader: *std.Io.Reader = if (tls_client) |*tc| &tc.reader else &sr.interface;
    const actual_writer: *std.Io.Writer = if (tls_client) |*tc| &tc.writer else &sw.interface;

    // Build HTTP request
    var req_alloc = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer req_alloc.deinit();
    const req_w = &req_alloc.writer;

    var uri_buf: [4096]u8 = undefined;
    const path = if (uri.path.isEmpty()) "/" else (uri.path.toRaw(&uri_buf) catch "/");
    try req_w.print("{s} {s}", .{ method, path });
    if (uri.query) |q| {
        const q_raw = q.toRaw(&uri_buf) catch "";
        if (q_raw.len > 0) try req_w.print("?{s}", .{q_raw});
    }
    try req_w.writeAll(" HTTP/1.1\r\n");
    try req_w.print("Host: {s}\r\n", .{host.bytes});
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
    if (is_tls) try sw.interface.flush();

    if (maybe_body) |body| {
        _ = try actual_writer.writeVec(&.{body});
        try actual_writer.flush();
        if (is_tls) try sw.interface.flush();
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
        const line = (try actual_reader.takeDelimiter('\n')) orelse return error.CapabilityError;
        const trimmed = (if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line);
        var parts = std.mem.splitScalar(u8, trimmed, ' ');
        _ = parts.next(); // skip "HTTP/1.1"
        const status_str = parts.next() orelse return error.CapabilityError;
        status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.CapabilityError;
    }

    // Headers
    var header_values: [64]struct { name: []const u8, value: []const u8 } = undefined;
    var header_count: usize = 0;

    while (true) {
        const line = (try actual_reader.takeDelimiter('\n')) orelse break;
        const trimmed = (if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line);
        if (trimmed.len == 0) break; // end of headers

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

    var i: usize = 0;
    while (i < header_count) : (i += 1) {
        resp_headers.put(header_values[i].name, header_values[i].value) catch {};
    }

    // Read body
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(std.heap.page_allocator);

    if (transfer_chunked) {
        while (true) {
            const size_line = (try actual_reader.takeDelimiter('\n')) orelse break;
            const chunk_size_str = if (size_line.len > 0 and size_line[size_line.len - 1] == '\r') size_line[0 .. size_line.len - 1] else size_line;
            const chunk_size = std.fmt.parseInt(usize, chunk_size_str, 16) catch break;
            if (chunk_size == 0) break;

            const offset = body.items.len;
            try body.resize(std.heap.page_allocator, offset + chunk_size);
            try actual_reader.readSliceAll(body.items[offset..]);
            _ = try actual_reader.takeDelimiter('\n'); // trailing \r\n
        }
        // Skip trailers
        while (true) {
            const trail = (try actual_reader.takeDelimiter('\n')) orelse break;
            if (trail.len <= 1) break;
        }
    } else if (content_length) |len| {
        if (len > 0) {
            try body.resize(std.heap.page_allocator, len);
            try actual_reader.readSliceAll(body.items);
        }
    } else {
        // Read until connection close
        try std.Io.Reader.appendRemaining(actual_reader, std.heap.page_allocator, &body, .unlimited);
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
        decompressed_alloc = try transfer_reader.allocRemaining(std.heap.page_allocator, std.Io.Limit.unlimited);

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
