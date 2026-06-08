const std = @import("std");
const builtin = @import("builtin");

pub const HttpResult = struct {
    status: i32,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
    ok: bool,
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
        while (it.next()) |entry| : (header_count += 1) {
            if (header_count >= 64) break;
            host_headers_keys[header_count] = std.heap.page_allocator.dupeZ(u8, entry.key_ptr.*) catch continue;
            host_headers_vals[header_count] = std.heap.page_allocator.dupeZ(u8, entry.value_ptr.*) catch continue;
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
    _ = _timeout_ms; // TODO: std.http.Client does not expose per-request timeout easily

    const io_ctx = std.Io.Threaded.global_single_threaded.io();
    var client = std.http.Client{
        .allocator = std.heap.page_allocator,
        .io = io_ctx,
    };
    defer client.deinit();

    var writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer writer.deinit();

    // Build extra headers if provided
    var extra_headers: [16]std.http.Header = undefined;
    var extra_header_count: usize = 0;
    if (maybe_headers) |hdrs| {
        var it = hdrs.iterator();
        while (it.next()) |entry| : (extra_header_count += 1) {
            if (extra_header_count >= 16) break;
            extra_headers[extra_header_count] = .{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
        }
    }

    const method_enum: std.http.Method = blk: {
        if (std.mem.eql(u8, method, "GET")) break :blk .GET;
        if (std.mem.eql(u8, method, "POST")) break :blk .POST;
        if (std.mem.eql(u8, method, "PUT")) break :blk .PUT;
        if (std.mem.eql(u8, method, "DELETE")) break :blk .DELETE;
        if (std.mem.eql(u8, method, "HEAD")) break :blk .HEAD;
        if (std.mem.eql(u8, method, "PATCH")) break :blk .PATCH;
        if (std.mem.eql(u8, method, "OPTIONS")) break :blk .OPTIONS;
        break :blk .GET;
    };

    const payload: ?[]const u8 = maybe_body;

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = method_enum,
        .payload = if (payload) |p| p else "",
        .extra_headers = if (extra_header_count > 0) extra_headers[0..extra_header_count] else &.{},
        .response_writer = &writer.writer,
    }) catch return error.CapabilityError;

    const resp_body = writer.written();

    var resp_headers = std.StringHashMap([]const u8).init(std.heap.page_allocator);
    errdefer resp_headers.deinit();

    // std.http.Client.fetch response headers are not easily accessible in this Zig version.
    // For the built-in default, we leave headers empty — the host handler is the path
    // for full header fidelity.

    const status = @as(i32, @intCast(@intFromEnum(res.status)));
    const ok = status >= 200 and status < 300;
    return .{
        .status = status,
        .body = resp_body,
        .headers = resp_headers,
        .ok = ok,
    };
}
