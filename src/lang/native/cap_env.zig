const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const NativeFnId = @import("native_ids.zig").NativeFnId;

// Initialized from main() at startup via setEnvironBlock().
pub var g_environ_block: std.process.Environ.Block = .empty;

pub fn setEnvironBlock(block: std.process.Environ.Block) void {
    g_environ_block = block;
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_env_get => {
            if (argc != 1) return error.ArityMismatch;
            const name_val = ctx.vs.stack[ctx.vs.stack_top - 1];
            const name = vms.asStringValue(name_val) catch return error.TypeError;
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try envGet(ctx, name));
        },
        .cap_env_list => {
            if (argc != 0) return error.ArityMismatch;
            ctx.vs.vmPopArgs(argc);
            try envList(ctx);
        },
        else => {},
    }
}

fn envGet(ctx: VMContext, name: []const u8) !Value {
    if (comptime builtin.os.tag == .wasi and !builtin.link_libc) {
        return envGetWasi(ctx, name);
    } else if (comptime builtin.os.tag == .windows) {
        return .null;
    } else {
        const environ: std.process.Environ = .{ .block = g_environ_block };
        const val = std.process.Environ.getPosix(environ, name) orelse return .null;
        return .{ .string = try ctx.cs.internStr(val) };
    }
}

fn envGetWasi(ctx: VMContext, name: []const u8) !Value {
    var count: usize = 0;
    var buf_size: usize = 0;
    if (std.os.wasi.environ_sizes_get(&count, &buf_size) != .SUCCESS or count == 0) return .null;

    const alloc = std.heap.page_allocator;
    const ptrs = alloc.alloc([*:0]u8, count) catch return .null;
    defer alloc.free(ptrs);
    const data = alloc.alloc(u8, buf_size) catch return .null;
    defer alloc.free(data);
    if (std.os.wasi.environ_get(ptrs.ptr, data.ptr) != .SUCCESS) return .null;

    for (ptrs) |ptr| {
        const entry = std.mem.span(ptr);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (!std.mem.eql(u8, entry[0..eq], name)) continue;
        return .{ .string = try ctx.cs.internStr(entry[eq + 1 ..]) };
    }
    return .null;
}

fn envList(ctx: VMContext) !void {
    if (comptime builtin.os.tag == .wasi and !builtin.link_libc) {
        try envListWasi(ctx);
    } else if (comptime builtin.os.tag == .windows) {
        try pushEmptyMap(ctx);
    } else {
        try envListPosix(ctx);
    }
}

fn envListPosix(ctx: VMContext) !void {
    const block = g_environ_block;
    if (block.isEmpty()) {
        try pushEmptyMap(ctx);
        return;
    }
    const slice = block.view().slice;
    const count = slice.len;
    if (count == 0) {
        try pushEmptyMap(ctx);
        return;
    }
    // Allocate map_obj first so entries can be stored into it before any
    // further allocation that might trigger compaction.
    const map_obj = try vmgc.allocTempRooted(ctx, .{ .map = &[_]MapEntry{} });
    defer ctx.vs.popTempRoot();
    const entries = try vmgc.vmAllocManagedSlice(ctx, MapEntry, count);
    // Root immediately so GC can trace the backing through map_obj.
    map_obj.* = .{ .map_managed = entries[0..count] };
    for (slice, 0..) |ptr, i| {
        const raw = std.mem.span(ptr);
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse raw.len;
        const k = try ctx.cs.internStr(raw[0..eq]);
        const v = try ctx.cs.internStr(if (eq < raw.len) raw[eq + 1 ..] else "");
        // Write through the object to use the current backing after any compaction.
        map_obj.map_managed[i] = .{ .key = .{ .string = k }, .value = .{ .string = v } };
    }
    try ctx.vs.vmPush(.{ .object = map_obj });
}

fn envListWasi(ctx: VMContext) !void {
    var count: usize = 0;
    var buf_size: usize = 0;
    if (std.os.wasi.environ_sizes_get(&count, &buf_size) != .SUCCESS or count == 0) {
        try pushEmptyMap(ctx);
        return;
    }
    const alloc = std.heap.page_allocator;
    const ptrs = alloc.alloc([*:0]u8, count) catch return error.OutOfMemory;
    defer alloc.free(ptrs);
    const data = alloc.alloc(u8, buf_size) catch return error.OutOfMemory;
    defer alloc.free(data);
    if (std.os.wasi.environ_get(ptrs.ptr, data.ptr) != .SUCCESS) {
        try pushEmptyMap(ctx);
        return;
    }
    // Allocate map_obj first so entries can be stored into it before any
    // further allocation that might trigger compaction.
    const map_obj = try vmgc.allocTempRooted(ctx, .{ .map = &[_]MapEntry{} });
    defer ctx.vs.popTempRoot();
    const entries = try vmgc.vmAllocManagedSlice(ctx, MapEntry, count);
    // Root immediately so GC can trace the backing through map_obj.
    map_obj.* = .{ .map_managed = entries[0..count] };
    for (ptrs, 0..) |ptr, i| {
        const raw = std.mem.span(ptr);
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse raw.len;
        const k = try ctx.cs.internStr(raw[0..eq]);
        const v = try ctx.cs.internStr(if (eq < raw.len) raw[eq + 1 ..] else "");
        // Write through the object to use the current backing after any compaction.
        map_obj.map_managed[i] = .{ .key = .{ .string = k }, .value = .{ .string = v } };
    }
    try ctx.vs.vmPush(.{ .object = map_obj });
}

fn pushEmptyMap(ctx: VMContext) !void {
    const obj = try vmgc.allocTempRooted(ctx, .{ .map = &[_]MapEntry{} });
    defer ctx.vs.popTempRoot();
    obj.* = .{ .map = &[_]MapEntry{} };
    try ctx.vs.vmPush(.{ .object = obj });
}
