const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const fs_state = @import("fs_state.zig");

const alloc = std.heap.page_allocator;

fn ioContext() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_fs_read => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try vms.vmPeek(0)) catch return error.TypeError;

            if (comptime builtin.os.tag == .wasi) {
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            if (comptime builtin.os.tag == .windows) {
                const io = ioContext();
                const contents = std.Io.Dir.cwd().readFileAlloc(io, rpath, alloc, .unlimited) catch return error.CapabilityError;
                defer alloc.free(contents);
                const out = try vmgc.makeDynString(contents);
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                try vms.vmPush(out);
                return;
            }

            const fd = std.posix.openat(std.posix.AT.FDCWD, rpath, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return error.CapabilityError;
            defer _ = std.posix.system.close(fd);

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(alloc);
            var temp: [4096]u8 = undefined;
            while (true) {
                const n = std.posix.read(fd, &temp) catch return error.CapabilityError;
                if (n == 0) break;
                buf.appendSlice(alloc, temp[0..n]) catch return error.CapabilityError;
            }
            const contents = buf.toOwnedSlice(alloc) catch return error.CapabilityError;
            defer alloc.free(contents);

            const out = try vmgc.makeDynString(contents);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .cap_fs_exists => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try vms.vmPeek(0)) catch return error.TypeError;

            if (comptime builtin.os.tag == .wasi) {
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            if (comptime builtin.os.tag == .windows) {
                const io = ioContext();
                std.Io.Dir.cwd().access(io, rpath, .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        _ = try vms.vmPop();
                        _ = try vms.vmPop();
                        try vms.vmPush(.{ .boolean = false });
                        return;
                    },
                    else => return error.CapabilityError,
                };
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                try vms.vmPush(.{ .boolean = true });
                return;
            }

            const fd = std.posix.openat(std.posix.AT.FDCWD, rpath, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
                error.FileNotFound => {
                    _ = try vms.vmPop();
                    _ = try vms.vmPop();
                    try vms.vmPush(.{ .boolean = false });
                    return;
                },
                else => return error.CapabilityError,
            };
            _ = std.posix.system.close(fd);
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .boolean = true });
        },
        .cap_fs_write => {
            if (argc != 2) return error.ArityMismatch;
            const path = vms.asStringValue(try vms.vmPeek(1)) catch return error.TypeError;
            const arg1 = try vms.vmPeek(0);
            const content: []const u8 = switch (arg1) {
                .string => |s| s,
                .object => |o| if (o.* == .dyn_string) o.dyn_string else return error.TypeError,
                else => return error.TypeError,
            };

            if (comptime builtin.os.tag == .wasi) {
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            const io = ioContext();
            const cwd = std.Io.Dir.cwd();
            const file = cwd.createFile(io, rpath, .{}) catch return error.CapabilityError;
            defer file.close(io);
            file.writeStreamingAll(io, content) catch return error.CapabilityError;
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .null = {} });
        },
        .cap_fs_list => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try vms.vmPeek(0)) catch return error.TypeError;

            if (comptime builtin.os.tag == .wasi) {
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            const io = ioContext();
            const cwd = std.Io.Dir.cwd();
            const dir = cwd.openDir(io, rpath, .{ .iterate = true }) catch return error.CapabilityError;
            defer dir.close(io);
            var it = dir.iterate();
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |n| alloc.free(n);
                names.deinit(alloc);
            }
            while (it.next(io) catch return error.CapabilityError) |entry| {
                const name_copy = alloc.dupe(u8, entry.name) catch return error.CapabilityError;
                names.append(alloc, name_copy) catch {
                    alloc.free(name_copy);
                    return error.CapabilityError;
                };
            }
            const result = try vmgc.vmAllocManagedSlice(Value, names.items.len);
            const arr_obj = try vmgc.vmAllocObject();
            arr_obj.* = .{ .array_managed = result[0..0] };
            try vms.pushTempRoot(.{ .object = arr_obj });
            defer vms.popTempRoot();
            for (names.items, 0..) |n, i| {
                result[i] = try vmgc.makeDynString(n);
                arr_obj.* = .{ .array_managed = result[0 .. i + 1] };
            }
            arr_obj.* = .{ .array_managed = result };
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .object = arr_obj });
        },
        .cap_fs_delete => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try vms.vmPeek(0)) catch return error.TypeError;

            if (comptime builtin.os.tag == .wasi) {
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            const io = ioContext();
            const cwd = std.Io.Dir.cwd();
            cwd.deleteFile(io, rpath) catch return error.CapabilityError;
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .null = {} });
        },
        .cap_fs_mkdir => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try vms.vmPeek(0)) catch return error.TypeError;

            if (comptime builtin.os.tag == .wasi) {
                _ = try vms.vmPop();
                _ = try vms.vmPop();
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            const io = ioContext();
            const cwd = std.Io.Dir.cwd();
            cwd.createDirPath(io, rpath) catch return error.CapabilityError;
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(.{ .null = {} });
        },
        else => unreachable,
    }
}

// Regression: cap_fs_* functions must accept both .string and .dyn_string
// path arguments (issue discovered while building the site-generator).
test "cap_fs path extraction accepts string and dyn_string" {
    const Runtime = @import("../../runtime/runtime.zig").Runtime;
    var rt: Runtime = undefined;
    rt.initWithPolicy(.{ .allow_io = false }) catch return error.TestFailed;
    defer rt.deinit();

    // Literal string
    const s = vms.asStringValue(.{ .string = "test.txt" }) catch return error.TestFailed;
    try std.testing.expectEqualStrings("test.txt", s);

    // Dynamic string
    const dyn = try vmgc.makeDynString("test.txt");
    const ds = vms.asStringValue(dyn) catch return error.TestFailed;
    try std.testing.expectEqualStrings("test.txt", ds);

}
