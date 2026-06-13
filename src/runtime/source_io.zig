const std = @import("std");
const builtin = @import("builtin");

const w32 = std.os.windows;

extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: w32.DWORD,
    dwShareMode: w32.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: w32.DWORD,
    dwFlagsAndAttributes: w32.DWORD,
    hTemplateFile: ?w32.HANDLE,
) callconv(.winapi) w32.HANDLE;
extern "kernel32" fn ReadFile(
    hFile: w32.HANDLE,
    lpBuffer: *anyopaque,
    nNumberOfBytesToRead: w32.DWORD,
    lpNumberOfBytesRead: ?*w32.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) w32.BOOL;
extern "kernel32" fn CloseHandle(hObject: w32.HANDLE) callconv(.winapi) w32.BOOL;

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
        if (total == buf.len) {
            var probe: [1]u8 = undefined;
            var iov = [1]std.os.wasi.iovec_t{.{ .base = &probe, .len = 1 }};
            var nread: usize = 0;
            const probe_rc = std.os.wasi.fd_read(fd, &iov, iov.len, &nread);
            if (probe_rc == .SUCCESS and nread > 0) return error.InputTooLong;
        }
        return total;
    }
    if (comptime builtin.os.tag == .windows) {
        const GENERIC_READ: w32.DWORD = 0x80000000;
        const FILE_SHARE_READ: w32.DWORD = 0x00000001;
        const OPEN_EXISTING: w32.DWORD = 3;
        const FILE_ATTRIBUTE_NORMAL: w32.DWORD = 0x00000080;
        const INVALID_HANDLE_VALUE: w32.HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const handle = CreateFileA(
            &path_buf,
            GENERIC_READ,
            FILE_SHARE_READ,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == INVALID_HANDLE_VALUE) return error.OpenFailed;
        defer _ = CloseHandle(handle);

        var total: usize = 0;
        while (total < buf.len) {
            var nread: w32.DWORD = 0;
            const to_read: w32.DWORD = @intCast(buf.len - total);
            const ok = ReadFile(handle, &buf[total], to_read, &nread, null);
            if (!ok.toBool() or nread == 0) break;
            total += nread;
        }
        if (total == buf.len) {
            var probe: [1]u8 = undefined;
            var nread: w32.DWORD = 0;
            const ok = ReadFile(handle, &probe, 1, &nread, null);
            if (ok.toBool() and nread > 0) return error.InputTooLong;
        }
        return total;
    }
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0);
    defer _ = std.posix.system.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    if (total == buf.len) {
        var probe: [1]u8 = undefined;
        const n = std.posix.read(fd, &probe) catch @as(usize, 0);
        if (n > 0) return error.InputTooLong;
    }
    return total;
}

test "readFile returns InputTooLong when file exceeds buffer" {
    const tmp = "/tmp/gengo_test_input_too_long.txt";
    const fd = std.posix.openat(std.posix.AT.FDCWD, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch unreachable;
    defer _ = std.posix.system.close(fd);
    const data = "x" ** 1024;
    _ = std.posix.system.write(fd, data.ptr, data.len);
    var buf: [512]u8 = undefined;
    const result = readFile(tmp, &buf);
    try std.testing.expectError(error.InputTooLong, result);
}
