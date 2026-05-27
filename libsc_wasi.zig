// WASI compatibility shim for gengo.
// Provides the subset of the libsc interface used by gengo, backed by
// wasi_snapshot_preview1 syscalls so the binary runs under wasmtime.

const std = @import("std");
const wasi = std.os.wasi;

pub const Errno = enum(i32) {
    OK = 0,
    GENERIC = -1,
};

// ── fd ────────────────────────────────────────────────────────────────────────
pub const fd = struct {
    pub const O = struct {
        pub const read: u32 = 1;
        pub const write: u32 = 2;
    };

    pub const RWResult = struct { errno: Errno, n: usize };
    pub const FDResult = struct { errno: Errno, fd: i32 };

    pub fn writeAll(fd_: i32, bytes: []const u8) Errno {
        var remaining = bytes;
        while (remaining.len > 0) {
            const iov = [1]wasi.ciovec_t{.{ .base = remaining.ptr, .len = remaining.len }};
            var nwritten: usize = 0;
            if (wasi.fd_write(@intCast(fd_), &iov, 1, &nwritten) != .SUCCESS)
                return .GENERIC;
            remaining = remaining[nwritten..];
        }
        return .OK;
    }

    pub fn read(fd_: i32, buf: []u8) RWResult {
        const iov = [1]wasi.iovec_t{.{ .base = buf.ptr, .len = buf.len }};
        var nread: usize = 0;
        if (wasi.fd_read(@intCast(fd_), &iov, 1, &nread) != .SUCCESS)
            return .{ .errno = .GENERIC, .n = 0 };
        return .{ .errno = .OK, .n = nread };
    }

    pub fn close(fd_: i32) Errno {
        _ = wasi.fd_close(@intCast(fd_));
        return .OK;
    }
};

// ── fs ────────────────────────────────────────────────────────────────────────
pub const fs = struct {
    pub const OpenResult = struct { errno: Errno, fd: i32 };

    pub fn open(path: []const u8, flags: u32, mode: u32) OpenResult {
        _ = flags;
        _ = mode;

        // Scan preopened directories (fd 3 onward) for one that covers `path`.
        var dir_fd: wasi.fd_t = 3;
        while (dir_fd < 64) : (dir_fd += 1) {
            var prestat: wasi.prestat_t = undefined;
            switch (wasi.fd_prestat_get(dir_fd, &prestat)) {
                .SUCCESS => {},
                .BADF, .OPNOTSUPP => break,
                else => continue,
            }

            var dir_name_buf: [512]u8 = undefined;
            const name_len = prestat.u.dir.pr_name_len;
            if (name_len > dir_name_buf.len) continue;
            if (wasi.fd_prestat_dir_name(dir_fd, &dir_name_buf, name_len) != .SUCCESS) continue;
            const dir_name = dir_name_buf[0..name_len];

            // Compute the relative path inside this preopen.
            const rel: []const u8 = rel: {
                if (path.len > 0 and path[0] == '/') {
                    // Preopen is "/" or "." → strip the leading slash.
                    if (std.mem.eql(u8, dir_name, "/") or std.mem.eql(u8, dir_name, "."))
                        break :rel path[1..];
                    // Preopen is a prefix of the absolute path.
                    if (std.mem.startsWith(u8, path, dir_name))
                        break :rel path[dir_name.len..];
                    continue;
                }
                // Relative path: try every preopen.
                break :rel path;
            };

            var out_fd: wasi.fd_t = undefined;
            const err = wasi.path_open(
                dir_fd,
                .{ .SYMLINK_FOLLOW = true },
                rel.ptr,
                rel.len,
                .{}, // oflags: open existing file
                .{ .FD_READ = true, .FD_SEEK = true, .FD_TELL = true, .FD_FILESTAT_GET = true },
                .{},
                .{}, // fdflags
                &out_fd,
            );
            if (err == .SUCCESS) return .{ .errno = .OK, .fd = @intCast(out_fd) };
        }
        return .{ .errno = .GENERIC, .fd = -1 };
    }
};

// ── process ───────────────────────────────────────────────────────────────────
pub const process = struct {
    pub const ArgsResult = struct { argv: [][]const u8, errno: Errno };

    pub fn args(argv_ptrs: []u32, argv_buf: []u8, out: [][]const u8) ArgsResult {
        _ = argv_ptrs;

        var argc: usize = 0;
        var buf_size: usize = 0;
        if (wasi.args_sizes_get(&argc, &buf_size) != .SUCCESS)
            return .{ .argv = out[0..0], .errno = .GENERIC };
        if (argc == 0) return .{ .argv = out[0..0], .errno = .OK };
        if (argc > out.len) return .{ .argv = out[0..0], .errno = .GENERIC };
        if (buf_size > argv_buf.len) return .{ .argv = out[0..0], .errno = .GENERIC };

        // Stack-allocate pointer slots (matches MaxArgs = 16 in main.zig).
        var ptrs: [16][*:0]u8 = undefined;
        if (argc > ptrs.len) return .{ .argv = out[0..0], .errno = .GENERIC };

        if (wasi.args_get(@as([*][*:0]u8, @ptrCast(&ptrs)), argv_buf.ptr) != .SUCCESS)
            return .{ .argv = out[0..0], .errno = .GENERIC };

        for (0..argc) |i| {
            var len: usize = 0;
            while (ptrs[i][len] != 0) len += 1;
            out[i] = ptrs[i][0..len];
        }
        return .{ .argv = out[0..argc], .errno = .OK };
    }

    pub fn exit(code: i32) noreturn {
        const u: u32 = if (code < 0) 0 else @intCast(code);
        wasi.proc_exit(u);
    }
};
