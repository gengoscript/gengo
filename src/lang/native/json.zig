const std = @import("std");
const heap = @import("../../runtime/heap.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const vmmap = @import("../vm_map.zig");
const vmod = @import("../value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

const JsonAllocator = struct {
    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ra: usize) ?[*]u8 {
        _ = ctx; _ = ra;
        if (ptr_align.toByteUnits() > 16) return null;
        return @ptrCast(heap.allocBytesManaged(len) orelse return null);
    }
    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ra: usize) bool {
        _ = ctx; _ = buf_align; _ = ra;
        if (new_len <= buf.len) return true;
        return false;
    }
    fn remapFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        _ = ctx; _ = buf_align; _ = ra;
        if (new_len <= buf.len) return buf.ptr;
        return null;
    }
    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ra: usize) void {
        _ = ctx; _ = buf_align; _ = ra;
        heap.freeBytesManaged(buf);
    }
    pub fn allocator() std.mem.Allocator {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .alloc = &allocFn,
                .resize = &resizeFn,
                .remap = &remapFn,
                .free = &freeFn,
            },
        };
    }
};

fn jsonValueToGengo(jv: std.json.Value) !Value {
    return switch (jv) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .int = @floatFromInt(i) },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .float = try std.fmt.parseFloat(f64, s) },
        .string => |s| try vmgc.makeDynString(s),
        .array => |arr| {
            const n = arr.items.len;
            if (n == 0) {
                const obj = try vmgc.vmAllocObject();
                obj.* = .{ .array_managed = &[_]Value{} };
                return .{ .object = obj };
            }
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .array_managed = &[_]Value{} }; // safe placeholder
            try vms.pushTempRoot(.{ .object = obj });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(Value, n);
            obj.* = .{ .array_managed = items[0..0] }; // publish immediately so GC traces partial contents
            for (0..n) |i| {
                items[i] = try jsonValueToGengo(arr.items[i]);
                obj.* = .{ .array_managed = items[0 .. i + 1] }; // grow visible length
            }
            return .{ .object = obj };
        },
        .object => |obj_map| {
            const n = obj_map.keys().len;
            if (n == 0) {
                const obj = try vmgc.vmAllocObject();
                obj.* = .{ .map = &[_]MapEntry{} };
                return .{ .object = obj };
            }
            const obj = try vmgc.vmAllocObject();
            obj.* = .{ .map = &[_]MapEntry{} };
            try vms.pushTempRoot(.{ .object = obj });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(MapEntry, n);
            const keys = obj_map.keys();
            const vals = obj_map.values();
            for (0..n) |i| {
                items[i] = .{
                    .key = try vmgc.makeDynString(keys[i]),
                    .value = try jsonValueToGengo(vals[i]),
                };
            }
            obj.* = .{ .map = items[0..n] };
            const bcount = vmmap.mapBucketsForCount(n);
            const buckets = try vmgc.vmAllocManagedSlice(i32, bcount);
            vmmap.mapBuildHashedBuckets(items[0..n], buckets);
            obj.* = .{ .map_hashed = .{ .entries = items[0..n], .len = n, .buckets = buckets } };
            return .{ .object = obj };
        },
    };
}

const MaxDepth = 32;

fn jsonStringifyValueDepth(s: *std.json.Stringify, gv: Value, depth: u32, ancestors: *[MaxDepth]*const Object, anc_count: *usize) !void {
    if (depth >= MaxDepth) {
        try s.write(null);
        return;
    }
    if (vmod.decimalRawAndScale(gv)) |drs| {
        var tmp: [64]u8 = undefined;
        const str = vmod.formatDecimalString(drs.raw, drs.scale, &tmp);
        try s.writer.writeAll(str);
        return;
    }
    const uv = vms.unboxNamed(gv);
    switch (uv) {
        .null => try s.write(null),
        .boolean => |b| try s.write(b),
        .int => |n| try s.write(n),
        .float => |n| try s.write(n),
        .decimal => unreachable,
        .rune => |r| try s.write(@as(i64, @intCast(r))),
        .string => |str| try s.write(str),
        .object => |obj| switch (obj.*) {
            .dyn_string => |str| try s.write(str),
            .array, .array_managed => {
                for (ancestors[0..anc_count.*]) |a| {
                    if (a == obj) {
                        try s.write(null);
                        return;
                    }
                }
                ancestors[anc_count.*] = obj;
                anc_count.* += 1;
                try s.beginArray();
                for (try vms.asArraySlice(obj)) |item| {
                    try jsonStringifyValueDepth(s, item, depth + 1, ancestors, anc_count);
                }
                try s.endArray();
                anc_count.* -= 1;
            },
            .map, .map_managed, .map_hashed => {
                for (ancestors[0..anc_count.*]) |a| {
                    if (a == obj) {
                        try s.write(null);
                        return;
                    }
                }
                ancestors[anc_count.*] = obj;
                anc_count.* += 1;
                try s.beginObject();
                for (try vms.asMapSlice(obj)) |entry| {
                    const key = vms.unboxNamed(entry.key);
                    const key_str = try vms.asStringValue(key);
                    try s.objectField(key_str);
                    try jsonStringifyValueDepth(s, entry.value, depth + 1, ancestors, anc_count);
                }
                try s.endObject();
                anc_count.* -= 1;
            },
            else => try s.write(null),
        },
        .error_value => try s.write(null),
    }
}

fn jsonStringifyValue(s: *std.json.Stringify, gv: Value) !void {
    var ancestors: [MaxDepth]*const Object = undefined;
    var anc_count: usize = 0;
    try jsonStringifyValueDepth(s, gv, 0, &ancestors, &anc_count);
}

pub fn jsonParseNative() !Value {
    const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
    const src = try vms.asStringValue(arg);
    const alloc = JsonAllocator.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, src, .{}) catch return error.TypeError;
    defer parsed.deinit();
    return jsonValueToGengo(parsed.value);
}

pub fn jsonStringifyNative() !Value {
    const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
    var out: std.Io.Writer.Allocating = .init(JsonAllocator.allocator());
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    jsonStringifyValue(&s, arg) catch return error.TypeError;
    const buf = out.written();
    return vmgc.makeDynString(buf);
}

pub fn jsonValidNative() !Value {
    const arg = vms.vmState().stack[vms.vmState().stack_top - 1];
    const src = try vms.asStringValue(arg);
    const alloc = JsonAllocator.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, src, .{}) catch return .{ .boolean = false };
    parsed.deinit();
    return .{ .boolean = true };
}

pub fn jsonIndentNative() !Value {
    const top = vms.vmState().stack_top;
    const src = try vms.asStringValue(vms.vmState().stack[top - 2]);
    const indent_str = try vms.asStringValue(vms.vmState().stack[top - 1]);
    const alloc = JsonAllocator.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, src, .{}) catch return error.TypeError;
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const Ws = @TypeOf(@as(std.json.Stringify.Options, .{}).whitespace);
    const ws: Ws = if (std.mem.eql(u8, indent_str, "\t")) .indent_tab
        else if (std.mem.eql(u8, indent_str, " ")) .indent_1
        else if (std.mem.eql(u8, indent_str, "   ")) .indent_3
        else if (std.mem.eql(u8, indent_str, "        ")) .indent_8
        else if (std.mem.eql(u8, indent_str, "    ")) .indent_4
        else .indent_2;
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = ws } };
    try s.write(parsed.value);
    return vmgc.makeDynString(out.written());
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .json_parse => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = try jsonParseNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_stringify => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = try jsonStringifyNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_valid => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = try jsonValidNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        .json_indent => {

            if (argc != nf.arity) return error.ArityMismatch;
            const out = try jsonIndentNative();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            _ = try vms.vmPop();
            try vms.vmPush(out);
        },
        else => {},
    }
}
