// Shared TLS infrastructure for cap:http and cap:net.
// Owns the process-global CA bundle; provides FdReader, FdWriter, and TlsConn.
const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// CA bundle — lazily loaded from the OS trust store, shared across both
// the HTTP and raw-TCP TLS stacks so a single rescan() serves both.
// ---------------------------------------------------------------------------

var g_ca_bundle: std.crypto.Certificate.Bundle = .empty;
var g_ca_bundle_lock: std.Io.RwLock = .init;
var g_ca_bundle_loaded: bool = false;

pub fn ensureCaBundle(io: std.Io) !void {
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

pub fn caBundleRef() *std.crypto.Certificate.Bundle {
    return &g_ca_bundle;
}

pub fn caBundleLockRef() *std.Io.RwLock {
    return &g_ca_bundle_lock;
}

// ---------------------------------------------------------------------------
// Monotonic clock helper
// ---------------------------------------------------------------------------

pub fn monotonicMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// ---------------------------------------------------------------------------
// FdReader / FdWriter — poll()-based deadline-aware socket I/O.
// These bypass std.Io.Threaded.netReadPosix which panics on EAGAIN (debug) /
// returns Unexpected (release) when SO_RCVTIMEO fires.
// ---------------------------------------------------------------------------

pub const FdReader = struct {
    fd: std.posix.socket_t,
    deadline_ms: i64, // absolute monotonic; 0 = no timeout
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

pub const FdWriter = struct {
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

// ---------------------------------------------------------------------------
// TlsConn — heap-allocated TLS connection state.
//
// MUST be heap-allocated at a stable address before calling initAt():
// the TLS client stores pointers into the fd_reader/fd_writer fields of
// this struct, so the struct must never be moved after init.
//
//   const tls = try std.heap.page_allocator.create(TlsConn);
//   errdefer std.heap.page_allocator.destroy(tls);
//   try tls.initAt(fd, server_name, io);
// ---------------------------------------------------------------------------

pub const TlsMinBuf = std.crypto.tls.Client.min_buffer_len;

pub const TlsConn = struct {
    fd: std.posix.socket_t,
    // Transport-layer I/O buffers (for FdReader / FdWriter)
    stream_read_buf: [TlsMinBuf]u8,
    stream_write_buf: [TlsMinBuf]u8,
    // TLS record buffers (for std.crypto.tls.Client)
    tls_read_buf: [TlsMinBuf]u8,
    tls_write_buf: [TlsMinBuf]u8,
    // Socket readers/writers (pointers into the above buffers — stable)
    fd_reader: FdReader,
    fd_writer: FdWriter,
    // TLS client (holds *std.Io.Reader / *std.Io.Writer pointing into fd_reader/fd_writer)
    client: std.crypto.tls.Client,

    pub fn initAt(self: *TlsConn, fd: std.posix.socket_t, server_name: []const u8, io: std.Io) !void {
        self.fd = fd;
        self.fd_reader = FdReader.init(fd, &self.stream_read_buf, 0);
        self.fd_writer = FdWriter.init(fd, &self.stream_write_buf, 0);
        try ensureCaBundle(io);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.vtable.random(io.userdata, &entropy);
        const now = std.Io.Timestamp.now(io, .real);
        self.client = try std.crypto.tls.Client.init(
            &self.fd_reader.interface,
            &self.fd_writer.interface,
            .{
                .host = .{ .explicit = server_name },
                .ca = .{ .bundle = .{
                    .gpa = std.heap.page_allocator,
                    .io = io,
                    .lock = &g_ca_bundle_lock,
                    .bundle = &g_ca_bundle,
                } },
                .write_buffer = &self.tls_write_buf,
                .read_buffer = &self.tls_read_buf,
                .entropy = &entropy,
                .realtime_now = now,
            },
        );
    }
};
