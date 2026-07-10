const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const fs_state = @import("fs_state.zig");
const chunk = @import("../chunk.zig");

const alloc = std.heap.page_allocator;

fn ioContext() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_fs_read => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try ctx.vs.vmPeek(0)) catch return error.TypeError;

            const lr = try fs_state.lookup(path);
            if (lr.mount.kind == .driver) {
                const drv = &lr.mount.driver;
                const open_fn = drv.open orelse return error.CapabilityError;
                const read_fn = drv.read orelse return error.CapabilityError;
                const close_fn = drv.close orelse return error.CapabilityError;
                var out_fd: i32 = -1;
                if (open_fn(lr.mount.userdata, lr.rest.ptr, @intCast(lr.rest.len), 0, &out_fd) < 0)
                    return error.CapabilityError;
                defer close_fn(lr.mount.userdata, out_fd);
                var chunks: std.ArrayList(u8) = .empty;
                defer chunks.deinit(alloc);
                var tmp: [4096]u8 = undefined;
                while (true) {
                    const n = read_fn(lr.mount.userdata, out_fd, &tmp, @intCast(tmp.len));
                    if (n < 0) return error.CapabilityError;
                    if (n == 0) break;
                    chunks.appendSlice(alloc, tmp[0..@intCast(n)]) catch return error.CapabilityError;
                }
                const bytes = chunks.toOwnedSlice(alloc) catch return error.CapabilityError;
                defer alloc.free(bytes);
                const out = try vmgc.makeDynString(ctx, bytes);
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(out);
                return;
            }

            if (comptime builtin.os.tag == .wasi) {
                ctx.vs.vmPopArgs(argc);
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            if (comptime builtin.os.tag == .windows) {
                const io = ioContext();
                const contents = std.Io.Dir.cwd().readFileAlloc(io, rpath, alloc, .unlimited) catch return error.CapabilityError;
                defer alloc.free(contents);
                const out = try vmgc.makeDynString(ctx, contents);
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(out);
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

            const out = try vmgc.makeDynString(ctx, contents);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(out);
        },
        .cap_fs_exists => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try ctx.vs.vmPeek(0)) catch return error.TypeError;

            const lr = try fs_state.lookup(path);
            if (lr.mount.kind == .driver) {
                const exists_fn = lr.mount.driver.exists orelse return error.CapabilityError;
                const rc = exists_fn(lr.mount.userdata, lr.rest.ptr, @intCast(lr.rest.len));
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(.{ .boolean = rc > 0 });
                return;
            }

            if (comptime builtin.os.tag == .wasi) {
                ctx.vs.vmPopArgs(argc);
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            if (comptime builtin.os.tag == .windows) {
                const io = ioContext();
                std.Io.Dir.cwd().access(io, rpath, .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        ctx.vs.vmPopArgs(argc);
                        try ctx.vs.vmPush(.{ .boolean = false });
                        return;
                    },
                    else => return error.CapabilityError,
                };
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(.{ .boolean = true });
                return;
            }

            const fd = std.posix.openat(std.posix.AT.FDCWD, rpath, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
                error.FileNotFound => {
                    ctx.vs.vmPopArgs(argc);
                    try ctx.vs.vmPush(.{ .boolean = false });
                    return;
                },
                else => return error.CapabilityError,
            };
            _ = std.posix.system.close(fd);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = true });
        },
        .cap_fs_write => {
            if (argc != 2) return error.ArityMismatch;
            const path = vms.asStringValue(try ctx.vs.vmPeek(1)) catch return error.TypeError;
            const arg1 = try ctx.vs.vmPeek(0);
            const content: []const u8 = switch (arg1) {
                .string => |s| s.bytes,
                .object => |o| if (o.* == .dyn_string) o.dyn_string else if (o.* == .string_view) o.string_view.bytes else return error.TypeError,
                else => return error.TypeError,
            };

            const lr = try fs_state.lookup(path);
            if (lr.mount.kind == .driver) {
                const open_fn = lr.mount.driver.open orelse return error.CapabilityError;
                const write_fn = lr.mount.driver.write orelse return error.CapabilityError;
                const close_fn = lr.mount.driver.close orelse return error.CapabilityError;
                var out_fd: i32 = -1;
                if (open_fn(lr.mount.userdata, lr.rest.ptr, @intCast(lr.rest.len), 1, &out_fd) < 0)
                    return error.CapabilityError;
                defer close_fn(lr.mount.userdata, out_fd);
                if (write_fn(lr.mount.userdata, out_fd, content.ptr, @intCast(content.len)) < 0)
                    return error.CapabilityError;
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(.{ .null = {} });
                return;
            }

            if (comptime builtin.os.tag == .wasi) {
                ctx.vs.vmPopArgs(argc);
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            const io = ioContext();
            const cwd = std.Io.Dir.cwd();
            const file = cwd.createFile(io, rpath, .{}) catch return error.CapabilityError;
            defer file.close(io);
            file.writeStreamingAll(io, content) catch return error.CapabilityError;
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .null = {} });
        },
        .cap_fs_list => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try ctx.vs.vmPeek(0)) catch return error.TypeError;

            const lr = try fs_state.lookup(path);
            if (lr.mount.kind == .driver) {
                const list_fn = lr.mount.driver.list orelse return error.CapabilityError;
                const list_buf = alloc.alloc(u8, 65536) catch return error.CapabilityError;
                defer alloc.free(list_buf);
                const rc = list_fn(lr.mount.userdata, lr.rest.ptr, @intCast(lr.rest.len), list_buf.ptr, @intCast(list_buf.len));
                if (rc < 0) return error.CapabilityError;
                const list_data = list_buf[0..@intCast(rc)];
                // Names are packed as consecutive null-terminated strings.
                var name_count: usize = 0;
                var pos: usize = 0;
                while (pos < list_data.len) {
                    const end = std.mem.indexOfScalarPos(u8, list_data, pos, 0) orelse break;
                    if (end == pos) break;
                    name_count += 1;
                    pos = end + 1;
                }
                const result = try vmgc.vmAllocManagedSlice(ctx, Value, name_count);
                const arr_obj = try vmgc.vmAllocObject(ctx);
                arr_obj.* = .{ .array_managed = result[0..0] };
                try ctx.vs.pushTempRoot(.{ .object = arr_obj });
                defer ctx.vs.popTempRoot();
                var idx: usize = 0;
                pos = 0;
                while (pos < list_data.len and idx < name_count) {
                    const end = std.mem.indexOfScalarPos(u8, list_data, pos, 0) orelse break;
                    if (end == pos) break;
                    result[idx] = try vmgc.makeDynString(ctx, list_data[pos..end]);
                    arr_obj.* = .{ .array_managed = result[0 .. idx + 1] };
                    idx += 1;
                    pos = end + 1;
                }
                arr_obj.* = .{ .array_managed = result };
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(.{ .object = arr_obj });
                return;
            }

            if (comptime builtin.os.tag == .wasi) {
                ctx.vs.vmPopArgs(argc);
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
            const result = try vmgc.vmAllocManagedSlice(ctx, Value, names.items.len);
            const arr_obj = try vmgc.vmAllocObject(ctx);
            arr_obj.* = .{ .array_managed = result[0..0] };
            try ctx.vs.pushTempRoot(.{ .object = arr_obj });
            defer ctx.vs.popTempRoot();
            for (names.items, 0..) |n, i| {
                result[i] = try vmgc.makeDynString(ctx, n);
                arr_obj.* = .{ .array_managed = result[0 .. i + 1] };
            }
            arr_obj.* = .{ .array_managed = result };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .object = arr_obj });
        },
        .cap_fs_delete => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try ctx.vs.vmPeek(0)) catch return error.TypeError;

            const lr = try fs_state.lookup(path);
            if (lr.mount.kind == .driver) {
                const delete_fn = lr.mount.driver.unlink orelse return error.CapabilityError;
                if (delete_fn(lr.mount.userdata, lr.rest.ptr, @intCast(lr.rest.len)) < 0)
                    return error.CapabilityError;
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(.{ .null = {} });
                return;
            }

            if (comptime builtin.os.tag == .wasi) {
                ctx.vs.vmPopArgs(argc);
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            const io = ioContext();
            const cwd = std.Io.Dir.cwd();
            cwd.deleteFile(io, rpath) catch return error.CapabilityError;
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .null = {} });
        },
        .cap_fs_mkdir => {
            if (argc != 1) return error.ArityMismatch;
            const path = vms.asStringValue(try ctx.vs.vmPeek(0)) catch return error.TypeError;

            const lr = try fs_state.lookup(path);
            if (lr.mount.kind == .driver) {
                const mkdir_fn = lr.mount.driver.mkdir orelse return error.CapabilityError;
                if (mkdir_fn(lr.mount.userdata, lr.rest.ptr, @intCast(lr.rest.len)) < 0)
                    return error.CapabilityError;
                ctx.vs.vmPopArgs(argc);
                try ctx.vs.vmPush(.{ .null = {} });
                return;
            }

            if (comptime builtin.os.tag == .wasi) {
                ctx.vs.vmPopArgs(argc);
                return error.CapabilityNotAvailable;
            }

            var rbuf: [4096]u8 = undefined;
            const rpath = try fs_state.resolve(path, &rbuf);

            const io = ioContext();
            const cwd = std.Io.Dir.cwd();
            cwd.createDirPath(io, rpath) catch return error.CapabilityError;
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .null = {} });
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

    const ctx = vms.VMContext.fromActive();

    // Literal string
    const s = vms.asStringValue(.{ .string = try ctx.cs.internStr("test.txt") }) catch return error.TestFailed;
    try std.testing.expectEqualStrings("test.txt", s);

    // Dynamic string
    const dyn = try vmgc.makeDynString(ctx, "test.txt");
    const ds = vms.asStringValue(dyn) catch return error.TestFailed;
    try std.testing.expectEqualStrings("test.txt", ds);

}
