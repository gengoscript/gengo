const std = @import("std");
const builtin = @import("builtin");

pub fn readFile(path: []const u8, buf: []u8) !usize {
    if (comptime builtin.os.tag == .wasi) {
        const WasiCwdFd: std.os.wasi.fd_t = 3;
        var fd: std.os.wasi.fd_t = undefined;
        const rc = std.os.wasi.path_open(
            WasiCwdFd,
            .{},
            path.ptr,
            path.len,
            .{},
            std.os.wasi.rights_t{
                .FD_READ = true,
                .FD_SEEK = true,
                .FD_TELL = true,
                .FD_FILESTAT_GET = true,
            },
            .{},
            .{},
            &fd,
        );
        if (rc != .SUCCESS) return error.OpenFailed;
        defer _ = std.os.wasi.fd_close(fd);

        var total: usize = 0;
        while (total < buf.len) {
            var iov = [1]std.os.wasi.iovec_t{.{ .base = buf[total..].ptr, .len = buf.len - total }};
            var nread: usize = 0;
            const read_rc = std.os.wasi.fd_read(fd, &iov, iov.len, &nread);
            if (read_rc != .SUCCESS) return error.ReadFailed;
            if (nread == 0) break;
            total += nread;
        }
        return total;
    } else {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0);
        defer _ = std.posix.system.close(fd);

        var total: usize = 0;
        while (total < buf.len) {
            const n = try std.posix.read(fd, buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }
}
