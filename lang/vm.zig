const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const globals = @import("globals.zig");
const heap = @import("../runtime/heap.zig");
const host_abi = @import("../runtime/host_abi.zig");
const io = @import("../runtime/io.zig");
const cfg = @import("../runtime/config.zig");
const Op = @import("op.zig").Op;
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;
const NativeFuncObj = @import("value.zig").NativeFuncObj;
const FieldTypeAlt = @import("value.zig").FieldTypeAlt;
const FieldTypeTag = @import("value.zig").FieldTypeTag;
const StructFieldSpec = @import("value.zig").StructFieldSpec;
const FieldTypeSpec = @import("value.zig").FieldTypeSpec;
const IterObj = @import("value.zig").IterObj;
const ClosureObj = @import("value.zig").ClosureObj;

const MaxStack = cfg.max_stack;
const MaxFrames = cfg.max_frames;

pub const Policy = struct {
    pub const NativeBackend = enum {
        embedded,
        host,
    };

    allow_io: bool = true,
    native_backend: NativeBackend = .embedded,
    max_ops: ?u64 = null,
};

var g_policy: Policy = .{};

var g_stack: [MaxStack]Value = undefined;
var g_stack_top: usize = 0;
var g_ip: usize = 0;

const Frame = struct { ret_ip: usize, base: usize, closure: ?*Object, func_obj: *Object };
var g_frames: [MaxFrames]Frame = undefined;
var g_frame_top: usize = 0;
var g_std_module: ?*Object = null;
var g_host_checked: bool = false;
var g_host_caps: u64 = 0;
var g_next_gc_objects: usize = 256;
var g_next_gc_heap_bytes: usize = heap.HeapSize / 2;
var g_call_depth_target: ?usize = null;
const MaxTempRoots = 128;
var g_temp_roots: [MaxTempRoots]Value = undefined;
var g_temp_root_top: usize = 0;
const RuneCacheMax = 8192;
var g_rune_cache_ptr: usize = 0;
var g_rune_cache_byte_len: usize = 0;
var g_rune_cache_rune_len: usize = 0;
var g_rune_cache_valid: bool = false;
var g_rune_cache_overflow: bool = false;
var g_rune_cache_offsets: [RuneCacheMax]usize = undefined;
var g_gc_runs: u64 = 0;
var g_gc_time_ns: u64 = 0;
var g_alloc_object_calls: u64 = 0;
var g_alloc_managed_slice_calls: u64 = 0;
var g_alloc_managed_bytes_calls: u64 = 0;
var g_ops_budget_remaining: ?u64 = null;

const NativeFnId = enum(u8) {
    io_println = 1,
    core_len = 2,
    core_append = 3,
    core_error = 4,
    core_is_error = 5,
    core_gc = 6,
    core_gc_live_objects = 7,
    core_gc_stats = 8,
    core_bytelen = 9,
    conv_to_int = 10,
    conv_to_float = 11,
    conv_to_bool = 12,
    conv_to_string = 13,
    core_gc_stats_ext = 14,
};
const MaxNativeArgs = 255;

pub const State = struct {
    policy: Policy = .{},
    stack: [MaxStack]Value = undefined,
    stack_top: usize = 0,
    ip: usize = 0,
    frames: [MaxFrames]Frame = undefined,
    frame_top: usize = 0,
    std_module: ?*Object = null,
    host_checked: bool = false,
    host_caps: u64 = 0,
    next_gc_objects: usize = 256,
    next_gc_heap_bytes: usize = heap.HeapSize / 2,
    call_depth_target: ?usize = null,
    temp_roots: [MaxTempRoots]Value = undefined,
    temp_root_top: usize = 0,
    rune_cache_ptr: usize = 0,
    rune_cache_byte_len: usize = 0,
    rune_cache_rune_len: usize = 0,
    rune_cache_valid: bool = false,
    rune_cache_overflow: bool = false,
    rune_cache_offsets: [RuneCacheMax]usize = undefined,
    gc_runs: u64 = 0,
    gc_time_ns: u64 = 0,
    alloc_object_calls: u64 = 0,
    alloc_managed_slice_calls: u64 = 0,
    alloc_managed_bytes_calls: u64 = 0,
    ops_budget_remaining: ?u64 = null,
};

pub fn reset() void {
    g_stack_top = 0;
    g_ip = 0;
    g_frame_top = 0;
    g_std_module = null;
    g_host_checked = false;
    g_host_caps = 0;
    g_next_gc_objects = 256;
    g_next_gc_heap_bytes = heap.HeapSize / 2;
    g_call_depth_target = null;
    g_temp_root_top = 0;
    g_rune_cache_ptr = 0;
    g_rune_cache_byte_len = 0;
    g_rune_cache_rune_len = 0;
    g_rune_cache_valid = false;
    g_rune_cache_overflow = false;
    g_gc_runs = 0;
    g_gc_time_ns = 0;
    g_alloc_object_calls = 0;
    g_alloc_managed_slice_calls = 0;
    g_alloc_managed_bytes_calls = 0;
    g_ops_budget_remaining = null;
}

pub fn setPolicy(policy: Policy) void {
    g_policy = policy;
    g_ops_budget_remaining = policy.max_ops;
}

fn vmPush(v: Value) !void {
    if (g_stack_top >= MaxStack) return error.StackOverflow;
    g_stack[g_stack_top] = v;
    g_stack_top += 1;
}
fn vmPop() !Value {
    if (g_stack_top == 0) return error.StackUnderflow;
    g_stack_top -= 1;
    return g_stack[g_stack_top];
}
fn vmPeek(dist: usize) !Value {
    if (dist >= g_stack_top) return error.StackUnderflow;
    return g_stack[g_stack_top - 1 - dist];
}
fn vmByte() !u8 {
    if (g_ip >= chunk.codeLen()) return error.BytecodeOutOfBounds;
    const b = chunk.codeByteAt(g_ip);
    g_ip += 1;
    return b;
}
fn vmShort() !usize {
    const hi: usize = try vmByte();
    const lo: usize = try vmByte();
    return (hi << 8) | lo;
}

fn pushTempRoot(v: Value) !void {
    if (g_temp_root_top >= MaxTempRoots) return error.StackOverflow;
    g_temp_roots[g_temp_root_top] = v;
    g_temp_root_top += 1;
}

fn popTempRoot() void {
    if (g_temp_root_top > 0) g_temp_root_top -= 1;
}
fn vmConst() !Value {
    const idx = try vmByte();
    if (idx >= chunk.constCount()) return error.BadConstantIndex;
    return chunk.constAt(idx);
}

fn vmIndexFromVal(v: Value) !usize {
    const n: f64 = switch (v) {
        .number => |x| x,
        .rune => |x| @floatFromInt(x),
        else => return error.TypeError,
    };
    if (n < 0) return error.IndexOutOfBounds;
    const f = @trunc(n);
    if (f != n) return error.TypeError;
    return @intFromFloat(f);
}

fn vmSliceIndex(v: Value, upper: usize) !usize {
    const n: f64 = switch (v) {
        .number => |x| x,
        .rune => |x| @floatFromInt(x),
        else => return error.TypeError,
    };
    if (n < 0) return error.IndexOutOfBounds;
    const f = @trunc(n);
    if (f != n) return error.TypeError;
    const idx: usize = @intFromFloat(f);
    if (idx > upper) return error.IndexOutOfBounds;
    return idx;
}

fn valueAsNumber(v: Value) !f64 {
    return switch (v) {
        .number => |n| n,
        .rune => |r| @floatFromInt(r),
        else => error.TypeError,
    };
}

fn valueAsInt(v: Value) !i64 {
    return switch (v) {
        .number => |n| blk: {
            const t = @trunc(n);
            if (t != n) return error.TypeError;
            break :blk @intFromFloat(t);
        },
        .rune => |r| @intCast(r),
        else => error.TypeError,
    };
}

fn utf8NextRuneByteLen(s: []const u8, byte_idx: usize) !usize {
    if (byte_idx >= s.len) return error.IndexOutOfBounds;
    const w = std.unicode.utf8ByteSequenceLength(s[byte_idx]) catch return error.TypeError;
    const width: usize = @intCast(w);
    if (byte_idx + width > s.len) return error.TypeError;
    _ = std.unicode.utf8Decode(s[byte_idx .. byte_idx + width]) catch return error.TypeError;
    return width;
}

fn utf8RuneCount(s: []const u8) !usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        i += try utf8NextRuneByteLen(s, i);
        count += 1;
    }
    return count;
}

fn utf8ByteOffsetForRuneIndex(s: []const u8, rune_idx: usize) !usize {
    var r: usize = 0;
    var i: usize = 0;
    while (i < s.len and r < rune_idx) {
        i += try utf8NextRuneByteLen(s, i);
        r += 1;
    }
    if (r != rune_idx) return error.IndexOutOfBounds;
    return i;
}

fn ensureRuneCache(s: []const u8) !void {
    if (g_rune_cache_valid and g_rune_cache_ptr == @intFromPtr(s.ptr) and g_rune_cache_byte_len == s.len) return;
    g_rune_cache_ptr = @intFromPtr(s.ptr);
    g_rune_cache_byte_len = s.len;
    g_rune_cache_rune_len = 0;
    g_rune_cache_valid = true;
    g_rune_cache_overflow = false;
    var i: usize = 0;
    while (i < s.len) {
        if (g_rune_cache_rune_len < RuneCacheMax) {
            g_rune_cache_offsets[g_rune_cache_rune_len] = i;
        } else {
            g_rune_cache_overflow = true;
        }
        i += try utf8NextRuneByteLen(s, i);
        g_rune_cache_rune_len += 1;
    }
}

fn utf8RuneCountCached(s: []const u8) !usize {
    try ensureRuneCache(s);
    return g_rune_cache_rune_len;
}

fn utf8ByteOffsetForRuneIndexCached(s: []const u8, rune_idx: usize) !usize {
    try ensureRuneCache(s);
    if (rune_idx == g_rune_cache_rune_len) return s.len;
    if (rune_idx > g_rune_cache_rune_len) return error.IndexOutOfBounds;
    if (!g_rune_cache_overflow and rune_idx < RuneCacheMax) return g_rune_cache_offsets[rune_idx];
    return utf8ByteOffsetForRuneIndex(s, rune_idx);
}

fn monoNowNs() u64 {
    var ns: std.os.wasi.timestamp_t = 0;
    if (std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns) != .SUCCESS) return 0;
    return ns;
}

fn makeNative(id: NativeFnId, arity: u8) !Value {
    const obj = try vmAllocObject();
    obj.* = .{ .native_function = .{ .id = @intFromEnum(id), .arity = arity } };
    return .{ .object = obj };
}

fn buildStdModule() !*Object {
    if (g_std_module) |m| return m;

    const io_items = heap.bump(MapEntry, 1) orelse return error.OutOfMemory;
    io_items[0] = .{
        .key = .{ .string = "println" },
        .value = try makeNative(.io_println, 255),
    };
    const io_obj = try vmAllocObject();
    io_obj.* = .{ .map = io_items[0..1] };

    const core_items = heap.bump(MapEntry, 9) orelse return error.OutOfMemory;
    core_items[0] = .{
        .key = .{ .string = "len" },
        .value = try makeNative(.core_len, 1),
    };
    core_items[1] = .{
        .key = .{ .string = "append" },
        .value = try makeNative(.core_append, 255),
    };
    core_items[2] = .{
        .key = .{ .string = "error" },
        .value = try makeNative(.core_error, 1),
    };
    core_items[3] = .{
        .key = .{ .string = "is_error" },
        .value = try makeNative(.core_is_error, 1),
    };
    core_items[4] = .{
        .key = .{ .string = "gc" },
        .value = try makeNative(.core_gc, 0),
    };
    core_items[5] = .{
        .key = .{ .string = "gc_live_objects" },
        .value = try makeNative(.core_gc_live_objects, 0),
    };
    core_items[6] = .{
        .key = .{ .string = "gc_stats" },
        .value = try makeNative(.core_gc_stats, 0),
    };
    core_items[7] = .{
        .key = .{ .string = "bytelen" },
        .value = try makeNative(.core_bytelen, 1),
    };
    core_items[8] = .{
        .key = .{ .string = "gc_stats_ext" },
        .value = try makeNative(.core_gc_stats_ext, 0),
    };
    const core_obj = try vmAllocObject();
    core_obj.* = .{ .map = core_items[0..9] };

    const conv_items = heap.bump(MapEntry, 4) orelse return error.OutOfMemory;
    conv_items[0] = .{
        .key = .{ .string = "to_int" },
        .value = try makeNative(.conv_to_int, 1),
    };
    conv_items[1] = .{
        .key = .{ .string = "to_float" },
        .value = try makeNative(.conv_to_float, 1),
    };
    conv_items[2] = .{
        .key = .{ .string = "to_bool" },
        .value = try makeNative(.conv_to_bool, 1),
    };
    conv_items[3] = .{
        .key = .{ .string = "to_string" },
        .value = try makeNative(.conv_to_string, 1),
    };
    const conv_obj = try vmAllocObject();
    conv_obj.* = .{ .map = conv_items[0..4] };

    const std_items = heap.bump(MapEntry, 3) orelse return error.OutOfMemory;
    std_items[0] = .{
        .key = .{ .string = "io" },
        .value = .{ .object = io_obj },
    };
    std_items[1] = .{
        .key = .{ .string = "core" },
        .value = .{ .object = core_obj },
    };
    std_items[2] = .{
        .key = .{ .string = "conv" },
        .value = .{ .object = conv_obj },
    };

    const std_obj = try vmAllocObject();
    std_obj.* = .{ .map = std_items[0..3] };
    g_std_module = std_obj;
    return std_obj;
}

fn markValue(v: Value) void {
    if (v == .object) markObject(v.object);
}

fn markObject(obj: *Object) void {
    if (!heap.isObjectLive(obj)) return;
    if (heap.isObjectMarked(obj)) return;
    heap.markObject(obj);
    switch (obj.*) {
        .array, .array_managed => {
            const items = asArraySlice(obj);
            var i: usize = 0;
            while (i < items.len) : (i += 1) markValue(items[i]);
        },
        .map, .map_managed, .map_hashed => {
            const items = asMapSlice(obj);
            var i: usize = 0;
            while (i < items.len) : (i += 1) {
                markValue(items[i].key);
                markValue(items[i].value);
            }
        },
        .closure => |cl| {
            markObject(cl.func);
            var i: usize = 0;
            while (i < cl.upvalues.len) : (i += 1) markObject(cl.upvalues[i]);
        },
        .cell => |c| markValue(c.value),
        .struct_instance => |inst| {
            markObject(inst.typ);
            var i: usize = 0;
            while (i < inst.fields.len) : (i += 1) {
                markValue(inst.fields[i].key);
                markValue(inst.fields[i].value);
            }
        },
        .iterator => |it| switch (it.kind) {
            .array => {
                var i: usize = 0;
                while (i < it.array.len) : (i += 1) markValue(it.array[i]);
            },
            .map => {
                var i: usize = 0;
                while (i < it.map.len) : (i += 1) {
                    markValue(it.map[i].key);
                    markValue(it.map[i].value);
                }
            },
            .string => {},
        },
        .dyn_string, .function, .native_function, .struct_type => {},
    }
}

fn collectGarbage() void {
    const t0 = monoNowNs();
    var i: usize = 0;
    while (i < g_stack_top) : (i += 1) markValue(g_stack[i]);

    i = 0;
    while (i < globals.len()) : (i += 1) markValue(globals.valueAt(i));

    if (g_std_module) |m| markObject(m);

    i = 0;
    while (i < g_temp_root_top) : (i += 1) markValue(g_temp_roots[i]);

    i = 0;
    while (i < chunk.constCount()) : (i += 1) markValue(chunk.constAt(i));

    heap.sweepObjects();
    const t1 = monoNowNs();
    g_gc_runs += 1;
    if (t1 > t0) g_gc_time_ns += @intCast(t1 - t0);
}

fn vmAllocObject() !*Object {
    if (heap.liveObjectCount() >= g_next_gc_objects) {
        collectGarbage();
        const live = heap.liveObjectCount();
        g_next_gc_objects = (live * 2) + 64;
    }
    if (heap.allocObject()) |o| {
        g_alloc_object_calls += 1;
        return o;
    }
    collectGarbage();
    const live = heap.liveObjectCount();
    g_next_gc_objects = (live * 2) + 64;
    if (heap.allocObject()) |o| {
        g_alloc_object_calls += 1;
        return o;
    }
    return error.OutOfMemory;
}

fn vmAllocManagedSlice(comptime T: type, n: usize) ![]T {
    if (heap.usedBytes() >= g_next_gc_heap_bytes) {
        collectGarbage();
        const used = heap.usedBytes();
        const step = heap.HeapSize / 4;
        g_next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    }
    if (heap.allocManagedSlice(T, n)) |s| {
        g_alloc_managed_slice_calls += 1;
        return s;
    }
    collectGarbage();
    const used = heap.usedBytes();
    const step = heap.HeapSize / 4;
    g_next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    if (heap.allocManagedSlice(T, n)) |s| {
        g_alloc_managed_slice_calls += 1;
        return s;
    }
    return error.OutOfMemory;
}

fn vmAllocManagedBytes(n: usize) ![]u8 {
    if (heap.usedBytes() >= g_next_gc_heap_bytes) {
        collectGarbage();
        const used = heap.usedBytes();
        const step = heap.HeapSize / 4;
        g_next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    }
    if (heap.allocBytesManaged(n)) |s| {
        g_alloc_managed_bytes_calls += 1;
        return s;
    }
    collectGarbage();
    const used = heap.usedBytes();
    const step = heap.HeapSize / 4;
    g_next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    if (heap.allocBytesManaged(n)) |s| {
        g_alloc_managed_bytes_calls += 1;
        return s;
    }
    return error.OutOfMemory;
}

fn isStringValue(v: Value) bool {
    return v == .string or (v == .object and v.object.* == .dyn_string);
}

fn isArrayObject(obj: *Object) bool {
    return switch (obj.*) {
        .array, .array_managed => true,
        else => false,
    };
}

fn asArraySlice(obj: *Object) []Value {
    return switch (obj.*) {
        .array => |s| s,
        .array_managed => |s| s,
        else => unreachable,
    };
}

fn isMapObject(obj: *Object) bool {
    return switch (obj.*) {
        .map, .map_managed, .map_hashed => true,
        else => false,
    };
}

fn asMapSlice(obj: *Object) []MapEntry {
    return switch (obj.*) {
        .map => |s| s,
        .map_managed => |s| s,
        .map_hashed => |hm| hm.entries[0..hm.len],
        else => unreachable,
    };
}

fn asStringValue(v: Value) ![]const u8 {
    if (v == .string) return v.string;
    if (v == .object and v.object.* == .dyn_string) return v.object.dyn_string;
    return error.TypeError;
}

fn mapKeyEquals(a: Value, b: Value) bool {
    if (isStringValue(a) and isStringValue(b)) {
        const sa = asStringValue(a) catch return false;
        const sb = asStringValue(b) catch return false;
        return common.streq(sa, sb);
    }
    return Value.equals(a, b);
}

fn mapHashValue(v: Value) u64 {
    return switch (v) {
        .number => |n| @bitCast(n),
        .rune => |r| @as(u64, r) *% 11400714819323198485,
        .boolean => |b| if (b) 0x9e3779b97f4a7c15 else 0x94d049bb133111eb,
        .string => |s| common.hashBytes(s),
        .error_value => |s| common.hashBytes(s),
        .object => |o| @intFromPtr(o),
        .null => 0xcbf29ce484222325,
    };
}

fn mapBucketsForCount(entry_count: usize) usize {
    const n: usize = if (entry_count < 4) 8 else entry_count * 2;
    var p: usize = 1;
    while (p < n) p <<= 1;
    return p;
}

fn mapFindHashedIndex(entries: []MapEntry, buckets: []i32, key: Value) ?usize {
    if (buckets.len == 0) return null;
    const mask = buckets.len - 1;
    var idx: usize = @intCast(mapHashValue(key) & mask);
    var probes: usize = 0;
    while (probes < buckets.len) : (probes += 1) {
        const b = buckets[idx];
        if (b < 0) return null;
        const ei: usize = @intCast(b);
        if (ei < entries.len and mapKeyEquals(entries[ei].key, key)) return ei;
        idx = (idx + 1) & mask;
    }
    return null;
}

fn mapBuildHashedBuckets(entries: []MapEntry, buckets: []i32) void {
    var i: usize = 0;
    while (i < buckets.len) : (i += 1) buckets[i] = -1;
    if (buckets.len == 0) return;
    const mask = buckets.len - 1;
    i = 0;
    while (i < entries.len) : (i += 1) {
        var idx: usize = @intCast(mapHashValue(entries[i].key) & mask);
        var probes: usize = 0;
        while (probes < buckets.len) : (probes += 1) {
            const cur = buckets[idx];
            if (cur < 0) {
                buckets[idx] = @intCast(i);
                break;
            }
            const curi: usize = @intCast(cur);
            if (mapKeyEquals(entries[curi].key, entries[i].key)) {
                // Preserve first-in semantics for duplicate keys.
                break;
            }
            idx = (idx + 1) & mask;
        }
    }
}

fn mapInsertHashed(obj: *Object, key: Value, val: Value) !void {
    if (obj.* != .map_hashed) return error.TypeError;

    if (obj.map_hashed.buckets.len == 0 or
        obj.map_hashed.len >= obj.map_hashed.entries.len or
        ((obj.map_hashed.len + 1) * 10 >= obj.map_hashed.buckets.len * 7))
    {
        try pushTempRoot(.{ .object = obj });
        defer popTempRoot();

        const old = obj.map_hashed;
        const new_len = old.len + 1;
        const new_cap = if (old.entries.len < 8) 8 else old.entries.len * 2;
        const out_cap = if (new_cap < new_len) new_len else new_cap;
        const out_entries = try vmAllocManagedSlice(MapEntry, out_cap);
        if (old.len > 0) @memcpy(out_entries[0..old.len], old.entries[0..old.len]);
        const bcount = mapBucketsForCount(out_cap);
        const out_buckets = try vmAllocManagedSlice(i32, bcount);
        mapBuildHashedBuckets(out_entries[0..old.len], out_buckets);
        obj.* = .{ .map_hashed = .{ .entries = out_entries[0..out_cap], .len = old.len, .buckets = out_buckets } };
    }

    var hm = &obj.map_hashed;
    const mask = hm.buckets.len - 1;
    var slot: usize = @intCast(mapHashValue(key) & mask);
    var probes: usize = 0;
    while (probes < hm.buckets.len) : (probes += 1) {
        const b = hm.buckets[slot];
        if (b < 0) {
            const ei = hm.len;
            hm.entries[ei] = .{ .key = key, .value = val };
            hm.buckets[slot] = @intCast(ei);
            hm.len += 1;
            return;
        }
        const ei: usize = @intCast(b);
        if (ei < hm.len and mapKeyEquals(hm.entries[ei].key, key)) {
            hm.entries[ei].value = val;
            return;
        }
        slot = (slot + 1) & mask;
    }
    return error.OutOfMemory;
}

fn makeDynString(s: []const u8) !Value {
    const obj = try vmAllocObject();
    try pushTempRoot(.{ .object = obj });
    defer popTempRoot();
    const buf = try vmAllocManagedBytes(s.len);
    @memcpy(buf[0..s.len], s);
    obj.* = .{ .dyn_string = buf[0..s.len] };
    return .{ .object = obj };
}

fn concatDynString(a: []const u8, b: []const u8) !Value {
    const obj = try vmAllocObject();
    try pushTempRoot(.{ .object = obj });
    defer popTempRoot();
    const total = a.len + b.len;
    const buf = try vmAllocManagedBytes(total);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..total], b);
    obj.* = .{ .dyn_string = buf[0..total] };
    return .{ .object = obj };
}

fn nativeLen(v: Value) !Value {
    const n: usize = switch (v) {
        .string => |s| try utf8RuneCountCached(s),
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| try utf8RuneCountCached(s),
            .array, .array_managed => asArraySlice(obj).len,
            .map, .map_managed, .map_hashed => asMapSlice(obj).len,
            .struct_instance => |s| s.fields.len,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .number = @floatFromInt(n) };
}

fn nativeByteLen(v: Value) !Value {
    const n: usize = switch (v) {
        .string => |s| s.len,
        .object => |obj| switch (obj.*) {
            .dyn_string => |s| s.len,
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    return .{ .number = @floatFromInt(n) };
}

fn nativeAppend(start: usize, argc: u8) !Value {
    if (argc < 1) return error.ArityMismatch;
    const first = g_stack[start];
    if (first != .object or !isArrayObject(first.object)) return error.TypeError;
    const base = asArraySlice(first.object);
    const extra: usize = argc - 1;
    const obj = try vmAllocObject();
    try pushTempRoot(.{ .object = obj });
    defer popTempRoot();
    const out = try vmAllocManagedSlice(Value, base.len + extra);
    @memcpy(out[0..base.len], base);
    var i: usize = 0;
    while (i < extra) : (i += 1) {
        out[base.len + i] = g_stack[start + 1 + i];
    }
    obj.* = .{ .array_managed = out[0 .. base.len + extra] };
    return .{ .object = obj };
}

fn nativeGcStats() !Value {
    const obj = try vmAllocObject();
    try pushTempRoot(.{ .object = obj });
    defer popTempRoot();
    const items = heap.bump(MapEntry, 3) orelse return error.OutOfMemory;
    items[0] = .{
        .key = .{ .string = "heap_used_bytes" },
        .value = .{ .number = @floatFromInt(heap.usedBytes()) },
    };
    items[1] = .{
        .key = .{ .string = "heap_size_bytes" },
        .value = .{ .number = @floatFromInt(heap.HeapSize) },
    };
    items[2] = .{
        .key = .{ .string = "live_objects" },
        .value = .{ .number = @floatFromInt(heap.liveObjectCount()) },
    };
    obj.* = .{ .map = items[0..3] };
    return .{ .object = obj };
}

fn nativeGcStatsExt() !Value {
    const obj = try vmAllocObject();
    try pushTempRoot(.{ .object = obj });
    defer popTempRoot();
    const items = heap.bump(MapEntry, 8) orelse return error.OutOfMemory;
    items[0] = .{
        .key = .{ .string = "heap_used_bytes" },
        .value = .{ .number = @floatFromInt(heap.usedBytes()) },
    };
    items[1] = .{
        .key = .{ .string = "heap_size_bytes" },
        .value = .{ .number = @floatFromInt(heap.HeapSize) },
    };
    items[2] = .{
        .key = .{ .string = "live_objects" },
        .value = .{ .number = @floatFromInt(heap.liveObjectCount()) },
    };
    items[3] = .{
        .key = .{ .string = "gc_runs" },
        .value = .{ .number = @floatFromInt(g_gc_runs) },
    };
    items[4] = .{
        .key = .{ .string = "gc_time_ns" },
        .value = .{ .number = @floatFromInt(g_gc_time_ns) },
    };
    items[5] = .{
        .key = .{ .string = "alloc_object_calls" },
        .value = .{ .number = @floatFromInt(g_alloc_object_calls) },
    };
    items[6] = .{
        .key = .{ .string = "alloc_managed_slice_calls" },
        .value = .{ .number = @floatFromInt(g_alloc_managed_slice_calls) },
    };
    items[7] = .{
        .key = .{ .string = "alloc_managed_bytes_calls" },
        .value = .{ .number = @floatFromInt(g_alloc_managed_bytes_calls) },
    };
    obj.* = .{ .map = items[0..8] };
    return .{ .object = obj };
}

fn nativeConvToInt(v: Value) !Value {
    switch (v) {
        .number => |n| {
            const tr = @trunc(n);
            return .{ .number = tr };
        },
        .rune => |r| return .{ .number = @floatFromInt(r) },
        .boolean => |b| return .{ .number = if (b) 1 else 0 },
        .string => |s| {
            const n = common.parseFloat(s) orelse return error.TypeError;
            const tr = @trunc(n);
            return .{ .number = tr };
        },
        .object => |o| {
            if (o.* == .dyn_string) {
                const n = common.parseFloat(o.dyn_string) orelse return error.TypeError;
                const tr = @trunc(n);
                return .{ .number = tr };
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    }
}

fn nativeConvToFloat(v: Value) !Value {
    switch (v) {
        .number => |n| return .{ .number = n },
        .rune => |r| return .{ .number = @floatFromInt(r) },
        .boolean => |b| return .{ .number = if (b) 1 else 0 },
        .string => |s| {
            const n = common.parseFloat(s) orelse return error.TypeError;
            return .{ .number = n };
        },
        .object => |o| {
            if (o.* == .dyn_string) {
                const n = common.parseFloat(o.dyn_string) orelse return error.TypeError;
                return .{ .number = n };
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    }
}

fn nativeConvToBool(v: Value) !Value {
    switch (v) {
        .boolean => |b| return .{ .boolean = b },
        .number => |n| return .{ .boolean = n != 0.0 },
        .rune => |r| return .{ .boolean = r != 0 },
        .string => |s| return .{ .boolean = s.len != 0 },
        .error_value => |e| return .{ .boolean = e.len != 0 },
        .null => return .{ .boolean = false },
        .object => return .{ .boolean = true },
    }
}

fn nativeConvToString(v: Value) !Value {
    switch (v) {
        .string => |s| return makeDynString(s),
        .object => |o| {
            if (o.* == .dyn_string) return makeDynString(o.dyn_string);
            return error.TypeError;
        },
        .boolean => |b| return makeDynString(if (b) "true" else "false"),
        .number => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return error.TypeError;
            return makeDynString(s);
        },
        .rune => |r| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(r, buf[0..]) catch return error.TypeError;
            return makeDynString(buf[0..n]);
        },
        .null => return makeDynString("null"),
        .error_value => |e| return makeDynString(e),
    }
}

fn expectStringKey(v: Value) ![]const u8 {
    return asStringValue(v);
}

fn findFieldIndex(fields: []const StructFieldSpec, key: []const u8) ?usize {
    var i: usize = 0;
    while (i < fields.len) : (i += 1) {
        if (common.streq(fields[i].name, key)) return i;
    }
    return null;
}

fn matchesTypeAlt(v: Value, alt: FieldTypeAlt) bool {
    return switch (alt.typ) {
        .any => true,
        .null_t => v == .null,
        .int => (v == .number and @trunc(v.number) == v.number) or v == .rune,
        .float => v == .number or v == .rune,
        .rune_t => v == .rune,
        .boolean => v == .boolean,
        .string => isStringValue(v),
        .array => v == .object and isArrayObject(v.object),
        .map => v == .object and isMapObject(v.object),
        .struct_t => v == .object and v.object.* == .struct_instance and common.streq(v.object.struct_instance.typ.struct_type.name, alt.struct_name),
    };
}

fn matchesFieldType(v: Value, spec: StructFieldSpec) bool {
    return matchesTypeSpec(v, spec.typ);
}

fn matchesTypeSpec(v: Value, spec: FieldTypeSpec) bool {
    var i: usize = 0;
    while (i < spec.alts.len) : (i += 1) {
        if (matchesTypeAlt(v, spec.alts[i])) return true;
    }
    return false;
}

fn enforceFuncArgTypes(f: @import("value.zig").FuncObj, argc: u8) !void {
    if (!f.has_typed_params) return;
    var i: usize = 0;
    while (i < @as(usize, argc)) : (i += 1) {
        const arg = g_stack[g_stack_top - argc + i];
        if (!matchesTypeSpec(arg, f.param_types[i])) return error.TypeError;
    }
}

fn wireFromValue(v: Value) !host_abi.ValueWire {
    return switch (v) {
        .null => .{
            .tag = @intFromEnum(host_abi.WireTag.null),
            .flags = 0,
            .reserved = 0,
            .payload = 0,
            .len = 0,
            .reserved2 = 0,
        },
        .boolean => |b| .{
            .tag = @intFromEnum(host_abi.WireTag.boolean),
            .flags = 0,
            .reserved = 0,
            .payload = if (b) 1 else 0,
            .len = 0,
            .reserved2 = 0,
        },
        .number => |n| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = 0,
            .reserved = 0,
            .payload = @bitCast(n),
            .len = 0,
            .reserved2 = 0,
        },
        .rune => |r| .{
            .tag = @intFromEnum(host_abi.WireTag.number),
            .flags = 0,
            .reserved = 0,
            .payload = @bitCast(@as(f64, @floatFromInt(r))),
            .len = 0,
            .reserved2 = 0,
        },
        .string => |s| .{
            .tag = @intFromEnum(host_abi.WireTag.string),
            .flags = 0,
            .reserved = 0,
            .payload = @intFromPtr(s.ptr),
            .len = @intCast(s.len),
            .reserved2 = 0,
        },
        .object => |o| if (o.* == .dyn_string) .{
            .tag = @intFromEnum(host_abi.WireTag.string),
            .flags = 0,
            .reserved = 0,
            .payload = @intFromPtr(o.dyn_string.ptr),
            .len = @intCast(o.dyn_string.len),
            .reserved2 = 0,
        } else return error.UnsupportedHostValueType,
        else => return error.UnsupportedHostValueType,
    };
}

fn valueFromWire(w: host_abi.ValueWire) !Value {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    return switch (tag) {
        .null => .null,
        .boolean => .{ .boolean = w.payload != 0 },
        .number => .{ .number = @bitCast(w.payload) },
        .string => return error.UnsupportedHostReturnType,
    };
}

fn wireNumberToU64(w: host_abi.ValueWire) !u64 {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    if (tag != .number) return error.HostNativeBadReturnType;
    const n: f64 = @bitCast(w.payload);
    if (n < 0) return error.HostNativeBadReturnValue;
    const tr = @trunc(n);
    if (tr != n) return error.HostNativeBadReturnValue;
    return @intFromFloat(tr);
}

fn ensureHostReady() !void {
    if (g_policy.native_backend != .host) return;
    if (g_host_checked) return;

    var out: host_abi.ValueWire = .{
        .tag = @intFromEnum(host_abi.WireTag.null),
        .flags = 0,
        .reserved = 0,
        .payload = 0,
        .len = 0,
        .reserved2 = 0,
    };

    var empty: [0]host_abi.ValueWire = .{};
    const st_ver = host_abi.nativeCall(.abi_version, empty[0..], &out);
    switch (st_ver) {
        .ok => {},
        .unsupported => {
            // No host import available: remain in host mode but with zero
            // host-dispatched capabilities so VM-local implementations are used.
            g_host_caps = 0;
            g_host_checked = true;
            return;
        },
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
    const version = try wireNumberToU64(out);
    if (version != host_abi.ABI_VERSION) return error.HostAbiVersionMismatch;

    const st_caps = host_abi.nativeCall(.host_caps, empty[0..], &out);
    switch (st_caps) {
        .ok => {},
        .unsupported => return error.HostNativeUnsupported,
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
    g_host_caps = try wireNumberToU64(out);
    g_host_checked = true;
}

fn callNative(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .io_println => {
            if (!g_policy.allow_io) return error.PermissionDenied;
            if (g_policy.native_backend == .host) {
                try ensureHostReady();
                if ((g_host_caps & host_abi.CAP_IO_PRINTLN) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    const start = g_stack_top - argc;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try wireFromValue(g_stack[start + i]);
                    }
                    var out: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.io_println, args_wire[0..argc], &out);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    var j: usize = 0;
                    while (j < @as(usize, argc)) : (j += 1) _ = try vmPop();
                    _ = try vmPop();
                    try vmPush(.null);
                    return;
                }
            }
            const start = g_stack_top - argc;
            var i: usize = 0;
            while (i < @as(usize, argc)) : (i += 1) io.printValue(g_stack[start + i]);
            io.write("\n");
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vmPop();
            _ = try vmPop();
            try vmPush(.null);
        },
        .core_len => {
            if (argc != nf.arity) return error.ArityMismatch;
            if (g_policy.native_backend == .host) {
                try ensureHostReady();
                if ((g_host_caps & host_abi.CAP_CORE_LEN) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try wireFromValue(g_stack[g_stack_top - 1]);
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.core_len, arg_wire[0..], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try valueFromWire(out_wire);
                    _ = try vmPop();
                    _ = try vmPop();
                    try vmPush(out);
                    return;
                }
            }
            const arg = g_stack[g_stack_top - 1];
            const out = try nativeLen(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .core_append => {
            const start = g_stack_top - argc;
            if (g_policy.native_backend == .host) {
                try ensureHostReady();
                if ((g_host_caps & host_abi.CAP_CORE_APPEND) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try wireFromValue(g_stack[start + i]);
                    }
                    var out_wire: host_abi.ValueWire = .{
                        .tag = @intFromEnum(host_abi.WireTag.null),
                        .flags = 0,
                        .reserved = 0,
                        .payload = 0,
                        .len = 0,
                        .reserved2 = 0,
                    };
                    const st = host_abi.nativeCall(.core_append, args_wire[0..argc], &out_wire);
                    switch (st) {
                        .ok => {},
                        .unsupported => return error.HostNativeUnsupported,
                        .denied => return error.PermissionDenied,
                        .bad_args => return error.HostNativeBadArgs,
                        .failed => return error.HostNativeFailed,
                    }
                    const out = try valueFromWire(out_wire);
                    var j: usize = 0;
                    while (j < @as(usize, argc)) : (j += 1) _ = try vmPop();
                    _ = try vmPop();
                    try vmPush(out);
                    return;
                }
            }
            const out = try nativeAppend(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .core_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = g_stack[g_stack_top - 1];
            const msg = try asStringValue(arg);
            const copy = heap.bump(u8, msg.len) orelse return error.OutOfMemory;
            @memcpy(copy[0..msg.len], msg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(.{ .error_value = copy[0..msg.len] });
        },
        .core_is_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = g_stack[g_stack_top - 1];
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(.{ .boolean = arg == .error_value });
        },
        .core_gc => {
            if (argc != nf.arity) return error.ArityMismatch;
            collectGarbage();
            _ = try vmPop();
            try vmPush(.null);
        },
        .core_gc_live_objects => {
            if (argc != nf.arity) return error.ArityMismatch;
            _ = try vmPop();
            try vmPush(.{ .number = @floatFromInt(heap.liveObjectCount()) });
        },
        .core_gc_stats => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStats();
            _ = try vmPop();
            try vmPush(out);
        },
        .core_gc_stats_ext => {
            if (argc != nf.arity) return error.ArityMismatch;
            const out = try nativeGcStatsExt();
            _ = try vmPop();
            try vmPush(out);
        },
        .core_bytelen => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = g_stack[g_stack_top - 1];
            const out = try nativeByteLen(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .conv_to_int => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = g_stack[g_stack_top - 1];
            const out = try nativeConvToInt(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .conv_to_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = g_stack[g_stack_top - 1];
            const out = try nativeConvToFloat(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .conv_to_bool => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = g_stack[g_stack_top - 1];
            const out = try nativeConvToBool(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .conv_to_string => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = g_stack[g_stack_top - 1];
            const out = try nativeConvToString(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
    }
}

fn performCall(argc: u8) !void {
    const func_val = g_stack[g_stack_top - argc - 1];
    if (func_val != .object) return error.NotAFunction;
    const obj = func_val.object;
    switch (obj.*) {
        .function => |f| {
            if (f.arity != argc) return error.ArityMismatch;
            if (f.has_typed_params) try enforceFuncArgTypes(f, argc);
            if (g_frame_top >= MaxFrames) return error.CallStackOverflow;
            g_frames[g_frame_top] = .{
                .ret_ip = g_ip,
                .base = g_stack_top - argc,
                .closure = null,
                .func_obj = obj,
            };
            g_frame_top += 1;
            g_ip = f.ip;
        },
        .closure => |cl| {
            const f = cl.func.function;
            if (f.arity != argc) return error.ArityMismatch;
            if (f.has_typed_params) try enforceFuncArgTypes(f, argc);
            if (g_frame_top >= MaxFrames) return error.CallStackOverflow;
            g_frames[g_frame_top] = .{
                .ret_ip = g_ip,
                .base = g_stack_top - argc,
                .closure = obj,
                .func_obj = cl.func,
            };
            g_frame_top += 1;
            g_ip = f.ip;
        },
        .native_function => |nf| {
            try callNative(nf, argc);
        },
        else => return error.NotAFunction,
    }
}

fn writeFrameLocal(abs_slot: usize, v: Value) void {
    const cur = g_stack[abs_slot];
    if (cur == .object and cur.object.* == .cell) {
        cur.object.cell.value = v;
    } else {
        g_stack[abs_slot] = v;
    }
}

fn trySelfTailCall(argc: u8) !bool {
    if (g_frame_top == 0) return false;
    // Tail position pattern emitted by compiler: `call <argc>` followed by `ret`.
    if (g_ip >= chunk.codeLen()) return false;
    const next_op: Op = @enumFromInt(chunk.codeByteAt(g_ip));
    if (next_op != .ret) return false;

    const callee_idx = g_stack_top - argc - 1;
    const func_val = g_stack[callee_idx];
    if (func_val != .object) return false;
    const callee_obj = func_val.object;

    const frame_idx = g_frame_top - 1;
    const frame = g_frames[frame_idx];
    if (callee_obj.* == .closure) {
        if (frame.closure == null or frame.closure.? != callee_obj) return false;
        const f = callee_obj.closure.func.function;
        if (f.arity != argc) return false;
        if (f.has_typed_params) try enforceFuncArgTypes(f, argc);
        // Rewrite current frame arg/local prefix with new args.
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            writeFrameLocal(frame.base + i, g_stack[callee_idx + 1 + i]);
        }
        g_stack_top = frame.base + argc;
        g_ip = f.ip;
        return true;
    }
    if (callee_obj.* == .function) {
        if (frame.closure != null) return false;
        if (frame.func_obj != callee_obj) return false;
        const f = callee_obj.function;
        if (f.arity != argc) return false;
        if (f.has_typed_params) try enforceFuncArgTypes(f, argc);
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            writeFrameLocal(frame.base + i, g_stack[callee_idx + 1 + i]);
        }
        g_stack_top = frame.base + argc;
        g_ip = f.ip;
        return true;
    }
    return false;
}

fn iterInit(v: Value) !Value {
    const obj = try vmAllocObject();
    switch (v) {
        .object => |o| switch (o.*) {
            .dyn_string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s, .string_managed = true } },
            .array, .array_managed => obj.* = .{ .iterator = .{ .kind = .array, .index = 0, .array = asArraySlice(o) } },
            .map, .map_managed, .map_hashed => obj.* = .{ .iterator = .{ .kind = .map, .index = 0, .map = asMapSlice(o) } },
            else => return error.TypeError,
        },
        .string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s, .string_managed = false } },
        else => return error.TypeError,
    }
    return .{ .object = obj };
}

fn iterNext1(it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (it.index >= it.array.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const v = it.array[it.index];
            it.index += 1;
            try vmPush(v);
            try vmPush(.{ .boolean = true });
        },
        .string => {
            if (it.index >= it.string.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const ridx = it.rune_index;
            const start = try utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            if (it.string_managed) {
                try vmPush(try makeDynString(it.string[start..end]));
            } else {
                try vmPush(.{ .string = it.string[start..end] });
            }
            it.index = end;
            it.rune_index += 1;
            try vmPush(.{ .boolean = true });
        },
        .map => {
            if (it.index >= it.map.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const k = it.map[it.index].key;
            it.index += 1;
            try vmPush(k);
            try vmPush(.{ .boolean = true });
        },
    }
}

fn iterNext2(it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (it.index >= it.array.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            try vmPush(.{ .number = @floatFromInt(it.index) });
            try vmPush(it.array[it.index]);
            it.index += 1;
            try vmPush(.{ .boolean = true });
        },
        .string => {
            if (it.index >= it.string.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const ridx = it.rune_index;
            const start = try utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            try vmPush(.{ .number = @floatFromInt(it.rune_index) });
            if (it.string_managed) {
                try vmPush(try makeDynString(it.string[start..end]));
            } else {
                try vmPush(.{ .string = it.string[start..end] });
            }
            it.index = end;
            it.rune_index += 1;
            try vmPush(.{ .boolean = true });
        },
        .map => {
            if (it.index >= it.map.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            try vmPush(it.map[it.index].key);
            try vmPush(it.map[it.index].value);
            it.index += 1;
            try vmPush(.{ .boolean = true });
        },
    }
}

pub fn run() !void {
    while (true) {
        if (g_ops_budget_remaining) |remaining| {
            if (remaining == 0) return error.InstructionBudgetExceeded;
            g_ops_budget_remaining = remaining - 1;
        }
        const op_raw = try vmByte();
        if (op_raw >= std.meta.fields(Op).len) return error.BadOpcode;
        const op: Op = @enumFromInt(op_raw);
        switch (op) {
            .constant => try vmPush(try vmConst()),
            .null_val => try vmPush(.null),
            .true_val => try vmPush(.{ .boolean = true }),
            .false_val => try vmPush(.{ .boolean = false }),
            .dup => try vmPush(try vmPeek(0)),
            .dup2 => {
                try vmPush(try vmPeek(1));
                try vmPush(try vmPeek(1));
            },
            .pop => _ = try vmPop(),

            .def_global => {
                const name = (try vmConst()).string;
                try globals.def(name, try vmPop());
            },
            .get_global => {
                const name = (try vmConst()).string;
                try vmPush(globals.get(name) orelse return error.UndefinedVariable);
            },
            .set_global => {
                const name = (try vmConst()).string;
                const val = try vmPop();
                if (!globals.set(name, val)) return error.UndefinedVariable;
            },

            .get_local => {
                const slot = try vmByte();
                const base = g_frames[g_frame_top - 1].base;
                const v = g_stack[base + slot];
                if (v == .object and v.object.* == .cell) {
                    try vmPush(v.object.cell.value);
                } else {
                    try vmPush(v);
                }
            },
            .set_local => {
                const slot = try vmByte();
                const base = g_frames[g_frame_top - 1].base;
                const val = try vmPop();
                const cur = g_stack[base + slot];
                if (cur == .object and cur.object.* == .cell) {
                    cur.object.cell.value = val;
                } else {
                    g_stack[base + slot] = val;
                }
            },
            .get_upvalue => {
                const idx = try vmByte();
                const frame = g_frames[g_frame_top - 1];
                const cl = frame.closure orelse return error.TypeError;
                if (cl.* != .closure) return error.TypeError;
                if (idx >= cl.closure.upvalues.len) return error.TypeError;
                const cell = cl.closure.upvalues[idx];
                try vmPush(cell.cell.value);
            },
            .set_upvalue => {
                const idx = try vmByte();
                const frame = g_frames[g_frame_top - 1];
                const cl = frame.closure orelse return error.TypeError;
                if (cl.* != .closure) return error.TypeError;
                if (idx >= cl.closure.upvalues.len) return error.TypeError;
                const val = try vmPop();
                const cell = cl.closure.upvalues[idx];
                cell.cell.value = val;
            },

            .add => {
                const b = try vmPop();
                const a = try vmPop();
                if (isStringValue(a) and isStringValue(b)) {
                    const sa = try asStringValue(a);
                    const sb = try asStringValue(b);
                    try vmPush(try concatDynString(sa, sb));
                } else {
                    const an = try valueAsNumber(a);
                    const bn = try valueAsNumber(b);
                    try vmPush(.{ .number = an + bn });
                }
            },
            .sub => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsNumber(a);
                const bn = try valueAsNumber(b);
                try vmPush(.{ .number = an - bn });
            },
            .mul => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsNumber(a);
                const bn = try valueAsNumber(b);
                try vmPush(.{ .number = an * bn });
            },
            .div => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsNumber(a);
                const bn = try valueAsNumber(b);
                try vmPush(.{ .number = an / bn });
            },
            .mod => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsNumber(a);
                const bn = try valueAsNumber(b);
                try vmPush(.{ .number = common.fmod(an, bn) });
            },
            .bit_and => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsInt(a);
                const bn = try valueAsInt(b);
                try vmPush(.{ .number = @floatFromInt(an & bn) });
            },
            .bit_or => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsInt(a);
                const bn = try valueAsInt(b);
                try vmPush(.{ .number = @floatFromInt(an | bn) });
            },
            .bit_xor => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsInt(a);
                const bn = try valueAsInt(b);
                try vmPush(.{ .number = @floatFromInt(an ^ bn) });
            },
            .bit_not => {
                const v = try vmPop();
                const n = try valueAsInt(v);
                try vmPush(.{ .number = @floatFromInt(~n) });
            },
            .shl => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsInt(a);
                const bn = try valueAsInt(b);
                if (bn < 0) return error.RangeError;
                const shift: u6 = @intCast(@min(bn, 63));
                try vmPush(.{ .number = @floatFromInt(an << shift) });
            },
            .shr => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsInt(a);
                const bn = try valueAsInt(b);
                if (bn < 0) return error.RangeError;
                const shift: u6 = @intCast(@min(bn, 63));
                try vmPush(.{ .number = @floatFromInt(an >> shift) });
            },
            .cast_int => {
                const v = try vmPop();
                switch (v) {
                    .number => |n| try vmPush(.{ .number = @trunc(n) }),
                    .rune => |r| try vmPush(.{ .number = @floatFromInt(r) }),
                    .boolean => |b| try vmPush(.{ .number = if (b) 1 else 0 }),
                    else => return error.TypeError,
                }
            },
            .cast_float => {
                const v = try vmPop();
                switch (v) {
                    .number => |n| try vmPush(.{ .number = n }),
                    .rune => |r| try vmPush(.{ .number = @floatFromInt(r) }),
                    .boolean => |b| try vmPush(.{ .number = if (b) 1.0 else 0.0 }),
                    else => return error.TypeError,
                }
            },
            .cast_bool => {
                const v = try vmPop();
                switch (v) {
                    .number => |n| try vmPush(.{ .boolean = n != 0.0 }),
                    .rune => |r| try vmPush(.{ .boolean = r != 0 }),
                    .boolean => |b| try vmPush(.{ .boolean = b }),
                    else => return error.TypeError,
                }
            },
            .neg => {
                const v = try vmPop();
                const n = try valueAsNumber(v);
                try vmPush(.{ .number = -n });
            },
            .not => try vmPush(.{ .boolean = !(try vmPop()).isTruthy() }),
            .eq => {
                const b = try vmPop();
                const a = try vmPop();
                try vmPush(.{ .boolean = Value.equals(a, b) });
            },
            .gt => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsNumber(a);
                const bn = try valueAsNumber(b);
                try vmPush(.{ .boolean = an > bn });
            },
            .lt => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try valueAsNumber(a);
                const bn = try valueAsNumber(b);
                try vmPush(.{ .boolean = an < bn });
            },

            .build_array => {
                const count = try vmByte();
                const obj = try vmAllocObject();
                try pushTempRoot(.{ .object = obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    items[i] = try vmPop();
                }
                obj.* = .{ .array_managed = items[0..count] };
                try vmPush(.{ .object = obj });
            },
            .build_map => {
                const count = try vmByte();
                const obj = try vmAllocObject();
                try pushTempRoot(.{ .object = obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(MapEntry, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    const val = try vmPop();
                    const key = try vmPop();
                    items[i] = .{ .key = key, .value = val };
                }
                const bcount = mapBucketsForCount(count);
                const buckets = try vmAllocManagedSlice(i32, bcount);
                mapBuildHashedBuckets(items[0..count], buckets);
                obj.* = .{ .map_hashed = .{ .entries = items[0..count], .len = count, .buckets = buckets } };
                try vmPush(.{ .object = obj });
            },
            .build_tuple => {
                const count = try vmByte();
                const obj = try vmAllocObject();
                try pushTempRoot(.{ .object = obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    items[i] = try vmPop();
                }
                obj.* = .{ .array_managed = items[0..count] };
                try vmPush(.{ .object = obj });
            },
            .build_struct_instance => {
                const count = try vmByte();
                const supplied_ptr = heap.bump(MapEntry, count) orelse return error.OutOfMemory;
                const supplied = supplied_ptr[0..count];
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    const val = try vmPop();
                    const key = try vmPop();
                    supplied[i] = .{ .key = key, .value = val };
                }
                const typ_v = try vmPop();
                if (typ_v != .object or typ_v.object.* != .struct_type) return error.TypeError;
                const st = typ_v.object.struct_type;

                const seen_ptr = heap.bump(bool, st.fields.len) orelse return error.OutOfMemory;
                const seen = seen_ptr[0..st.fields.len];
                for (seen) |*b| b.* = false;
                const inst_fields_ptr = heap.bump(MapEntry, st.fields.len) orelse return error.OutOfMemory;
                const inst_fields = inst_fields_ptr[0..st.fields.len];

                var si: usize = 0;
                while (si < supplied.len) : (si += 1) {
                    const key_s = try expectStringKey(supplied[si].key);
                    const idx = findFieldIndex(st.fields, key_s) orelse return error.UnknownStructField;
                    if (seen[idx]) return error.DuplicateField;
                    seen[idx] = true;
                    if (!matchesFieldType(supplied[si].value, st.fields[idx])) return error.StructFieldTypeMismatch;
                    inst_fields[idx] = .{
                        .key = .{ .string = st.fields[idx].name },
                        .value = supplied[si].value,
                    };
                }

                var mi: usize = 0;
                while (mi < st.fields.len) : (mi += 1) {
                    if (!seen[mi]) return error.MissingStructField;
                }

                const obj = try vmAllocObject();
                obj.* = .{
                    .struct_instance = .{
                        .typ = typ_v.object,
                        .fields = inst_fields,
                    },
                };
                try vmPush(.{ .object = obj });
            },
            .tuple_check_arity => {
                const expect = try vmByte();
                const tup = try vmPeek(0);
                if (tup != .object or !isArrayObject(tup.object)) return error.TypeError;
                if (asArraySlice(tup.object).len != expect) return error.ArityMismatch;
            },
            .tuple_get => {
                const idx = try vmByte();
                const tup = try vmPop();
                if (tup != .object or !isArrayObject(tup.object)) return error.TypeError;
                const a = asArraySlice(tup.object);
                if (idx >= a.len) return error.ArityMismatch;
                try vmPush(a[idx]);
            },
            .tuple_get_keep => {
                const idx = try vmByte();
                const tup = try vmPeek(0);
                if (tup != .object or !isArrayObject(tup.object)) return error.TypeError;
                const a = asArraySlice(tup.object);
                if (idx >= a.len) return error.ArityMismatch;
                try vmPush(a[idx]);
            },
            .get_index => {
                const idx_v = try vmPop();
                const container = try vmPop();
                switch (container) {
                    .object => |obj| switch (obj.*) {
                        .dyn_string => |s| {
                            const ridx = try vmIndexFromVal(idx_v);
                            const start = try utf8ByteOffsetForRuneIndexCached(s, ridx);
                            const w = try utf8NextRuneByteLen(s, start);
                            try vmPush(try makeDynString(s[start .. start + w]));
                        },
                        .array, .array_managed => {
                            const items = asArraySlice(obj);
                            const idx = try vmIndexFromVal(idx_v);
                            if (idx >= items.len) return error.IndexOutOfBounds;
                            try vmPush(items[idx]);
                        },
                        .map, .map_managed => {
                            const items = asMapSlice(obj);
                            var i: usize = 0;
                            while (i < items.len) : (i += 1) {
                                if (mapKeyEquals(items[i].key, idx_v)) {
                                    try vmPush(items[i].value);
                                    break;
                                }
                            }
                            if (i == items.len) try vmPush(.null);
                        },
                        .map_hashed => |hm| {
                            if (mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, idx_v)) |fi| {
                                try vmPush(hm.entries[fi].value);
                            } else {
                                try vmPush(.null);
                            }
                        },
                        .struct_instance => |inst| {
                            const key = try expectStringKey(idx_v);
                            const idx = findFieldIndex(inst.typ.struct_type.fields, key) orelse return error.UnknownStructField;
                            try vmPush(inst.fields[idx].value);
                        },
                        else => return error.TypeError,
                    },
                    .string => |s| {
                        const ridx = try vmIndexFromVal(idx_v);
                        const start = try utf8ByteOffsetForRuneIndexCached(s, ridx);
                        const w = try utf8NextRuneByteLen(s, start);
                        try vmPush(.{ .string = s[start .. start + w] });
                    },
                    else => return error.TypeError,
                }
            },
            .set_index => {
                const val = try vmPop();
                const idx_v = try vmPop();
                const container = try vmPop();
                if (container != .object) return error.TypeError;
                switch (container.object.*) {
                    .array, .array_managed => {
                        const items = asArraySlice(container.object);
                        const idx = try vmIndexFromVal(idx_v);
                        if (idx >= items.len) return error.IndexOutOfBounds;
                        items[idx] = val;
                    },
                    .map, .map_managed => {
                        const items = asMapSlice(container.object);
                        var i: usize = 0;
                        var updated = false;
                        while (i < items.len) : (i += 1) {
                            if (mapKeyEquals(items[i].key, idx_v)) {
                                items[i].value = val;
                                updated = true;
                                break;
                            }
                        }
                        if (!updated) {
                            try pushTempRoot(container);
                            defer popTempRoot();
                            const ext = try vmAllocManagedSlice(MapEntry, items.len + 1);
                            @memcpy(ext[0..items.len], items);
                            ext[items.len] = .{ .key = idx_v, .value = val };
                            container.object.* = .{ .map_managed = ext[0 .. items.len + 1] };
                        }
                    },
                    .map_hashed => {
                        try mapInsertHashed(container.object, idx_v, val);
                    },
                    .struct_instance => |inst| {
                        const key = try expectStringKey(idx_v);
                        const idx = findFieldIndex(inst.typ.struct_type.fields, key) orelse return error.UnknownStructField;
                        if (!matchesFieldType(val, inst.typ.struct_type.fields[idx])) return error.StructFieldTypeMismatch;
                        inst.fields[idx].value = val;
                    },
                    else => return error.TypeError,
                }
            },
            .get_slice => {
                const flags = try vmByte();
                const has_start = (flags & 0b01) != 0;
                const has_end = (flags & 0b10) != 0;

                var end_v: Value = .null;
                var start_v: Value = .null;
                if (has_end) end_v = try vmPop();
                if (has_start) start_v = try vmPop();
                const container = try vmPop();

                switch (container) {
                    .string => |s| {
                        const rune_len = try utf8RuneCountCached(s);
                        const start_r: usize = if (has_start) try vmSliceIndex(start_v, rune_len) else 0;
                        const end_r: usize = if (has_end) try vmSliceIndex(end_v, rune_len) else rune_len;
                        if (start_r > end_r) return error.IndexOutOfBounds;
                        const start_b = try utf8ByteOffsetForRuneIndexCached(s, start_r);
                        const end_b = try utf8ByteOffsetForRuneIndexCached(s, end_r);
                        try vmPush(.{ .string = s[start_b..end_b] });
                    },
                    .object => |obj| switch (obj.*) {
                        .dyn_string => |s| {
                            const rune_len = try utf8RuneCountCached(s);
                            const start_r: usize = if (has_start) try vmSliceIndex(start_v, rune_len) else 0;
                            const end_r: usize = if (has_end) try vmSliceIndex(end_v, rune_len) else rune_len;
                            if (start_r > end_r) return error.IndexOutOfBounds;
                            const start_b = try utf8ByteOffsetForRuneIndexCached(s, start_r);
                            const end_b = try utf8ByteOffsetForRuneIndexCached(s, end_r);
                            try vmPush(try makeDynString(s[start_b..end_b]));
                        },
                        .array, .array_managed => {
                            const items = asArraySlice(obj);
                            const start: usize = if (has_start) try vmSliceIndex(start_v, items.len) else 0;
                            const end: usize = if (has_end) try vmSliceIndex(end_v, items.len) else items.len;
                            if (start > end) return error.IndexOutOfBounds;
                            const out = try vmAllocObject();
                            out.* = .{ .array = items[start..end] };
                            try vmPush(.{ .object = out });
                        },
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                }
            },
            .import_std => {
                const std_obj = try buildStdModule();
                try vmPush(.{ .object = std_obj });
            },
            .iter_init => {
                const v = try vmPop();
                try vmPush(try iterInit(v));
            },
            .iter_next1 => {
                const itv = try vmPeek(0);
                if (itv != .object or itv.object.* != .iterator) return error.TypeError;
                try iterNext1(&itv.object.iterator);
            },
            .iter_next2 => {
                const itv = try vmPeek(0);
                if (itv != .object or itv.object.* != .iterator) return error.TypeError;
                try iterNext2(&itv.object.iterator);
            },
            .make_closure => {
                const f = try vmConst();
                if (f != .object or f.object.* != .function) return error.TypeError;
                const proto = f.object.function;
                const ups = heap.bump(*Object, proto.capture_slots.len) orelse return error.OutOfMemory;
                if (g_frame_top == 0 and proto.capture_slots.len != 0) return error.TypeError;
                const frame = if (g_frame_top == 0) Frame{ .ret_ip = 0, .base = 0, .closure = null, .func_obj = f.object } else g_frames[g_frame_top - 1];
                var i: usize = 0;
                while (i < proto.capture_slots.len) : (i += 1) {
                    const enc = proto.capture_slots[i];
                    const is_upvalue = (enc & 0x80) != 0;
                    const idx = enc & 0x7f;
                    if (is_upvalue) {
                        const pcl = frame.closure orelse return error.TypeError;
                        if (pcl.* != .closure) return error.TypeError;
                        if (idx >= pcl.closure.upvalues.len) return error.TypeError;
                        ups[i] = pcl.closure.upvalues[idx];
                    } else {
                        const abs = frame.base + idx;
                        const cur = g_stack[abs];
                        if (cur == .object and cur.object.* == .cell) {
                            ups[i] = cur.object;
                            continue;
                        }
                        const cell = try vmAllocObject();
                        cell.* = .{ .cell = .{ .value = cur } };
                        g_stack[abs] = .{ .object = cell };
                        ups[i] = cell;
                    }
                }
                const clo = try vmAllocObject();
                clo.* = .{ .closure = ClosureObj{ .func = f.object, .upvalues = ups[0..proto.capture_slots.len] } };
                try vmPush(.{ .object = clo });
            },
            .invoke_method => {
                const mname = (try vmConst()).string;
                const argc = try vmByte();
                const recv_idx = g_stack_top - argc - 1;
                const recv = g_stack[recv_idx];
                if (recv != .object) return error.NotAMethodReceiver;
                switch (recv.object.*) {
                    .struct_instance => |inst| {
                        const tname = inst.typ.struct_type.name;
                        const total = tname.len + 1 + mname.len;
                        const key_buf = heap.bump(u8, total) orelse return error.OutOfMemory;
                        @memcpy(key_buf[0..tname.len], tname);
                        key_buf[tname.len] = '.';
                        @memcpy(key_buf[tname.len + 1 .. total], mname);
                        const key = key_buf[0..total];

                        const func = globals.get(key) orelse return error.UnknownMethod;
                        if (g_stack_top >= MaxStack) return error.StackOverflow;
                        var i: usize = g_stack_top;
                        while (i > recv_idx + 1) {
                            g_stack[i] = g_stack[i - 1];
                            i -= 1;
                        }
                        g_stack_top += 1;
                        g_stack[recv_idx] = func;
                        g_stack[recv_idx + 1] = recv;
                        try performCall(argc + 1);
                    },
                    .map, .map_managed, .map_hashed => {
                        const items = asMapSlice(recv.object);
                        var i: usize = 0;
                        var maybe: ?Value = null;
                        while (i < items.len) : (i += 1) {
                            if (isStringValue(items[i].key) and common.streq(try asStringValue(items[i].key), mname)) {
                                maybe = items[i].value;
                                break;
                            }
                        }
                        const func = maybe orelse return error.UnknownMethod;
                        g_stack[recv_idx] = func;
                        try performCall(argc);
                    },
                    else => return error.NotAMethodReceiver,
                }
            },

            .jump => {
                const off = try vmShort();
                g_ip += off;
            },
            .jump_if_false => {
                const off = try vmShort();
                if (!(try vmPeek(0)).isTruthy()) g_ip += off;
            },
            .loop => {
                const off = try vmShort();
                g_ip -= off;
            },

            .call => {
                const argc = try vmByte();
                if (try trySelfTailCall(argc)) continue;
                try performCall(argc);
            },
            .ret => {
                if (g_frame_top == 0) return error.ReturnAtTopLevel;
                const retval = try vmPop();
                g_frame_top -= 1;
                const frame = g_frames[g_frame_top];
                g_stack_top = frame.base - 1;
                g_ip = frame.ret_ip;
                try vmPush(retval);
                if (g_call_depth_target) |d| {
                    if (g_frame_top == d) return;
                }
            },

            .halt => return,
        }
    }
}

pub fn snapshot() State {
    return .{
        .policy = g_policy,
        .stack = g_stack,
        .stack_top = g_stack_top,
        .ip = g_ip,
        .frames = g_frames,
        .frame_top = g_frame_top,
        .std_module = g_std_module,
        .host_checked = g_host_checked,
        .host_caps = g_host_caps,
        .next_gc_objects = g_next_gc_objects,
        .next_gc_heap_bytes = g_next_gc_heap_bytes,
        .call_depth_target = g_call_depth_target,
        .temp_roots = g_temp_roots,
        .temp_root_top = g_temp_root_top,
        .rune_cache_ptr = g_rune_cache_ptr,
        .rune_cache_byte_len = g_rune_cache_byte_len,
        .rune_cache_rune_len = g_rune_cache_rune_len,
        .rune_cache_valid = g_rune_cache_valid,
        .rune_cache_overflow = g_rune_cache_overflow,
        .rune_cache_offsets = g_rune_cache_offsets,
        .gc_runs = g_gc_runs,
        .gc_time_ns = g_gc_time_ns,
        .alloc_object_calls = g_alloc_object_calls,
        .alloc_managed_slice_calls = g_alloc_managed_slice_calls,
        .alloc_managed_bytes_calls = g_alloc_managed_bytes_calls,
        .ops_budget_remaining = g_ops_budget_remaining,
    };
}

pub fn restore(state: State) void {
    g_policy = state.policy;
    g_stack = state.stack;
    g_stack_top = state.stack_top;
    g_ip = state.ip;
    g_frames = state.frames;
    g_frame_top = state.frame_top;
    g_std_module = state.std_module;
    g_host_checked = state.host_checked;
    g_host_caps = state.host_caps;
    g_next_gc_objects = state.next_gc_objects;
    g_next_gc_heap_bytes = state.next_gc_heap_bytes;
    g_call_depth_target = state.call_depth_target;
    g_temp_roots = state.temp_roots;
    g_temp_root_top = state.temp_root_top;
    g_rune_cache_ptr = state.rune_cache_ptr;
    g_rune_cache_byte_len = state.rune_cache_byte_len;
    g_rune_cache_rune_len = state.rune_cache_rune_len;
    g_rune_cache_valid = state.rune_cache_valid;
    g_rune_cache_overflow = state.rune_cache_overflow;
    g_rune_cache_offsets = state.rune_cache_offsets;
    g_gc_runs = state.gc_runs;
    g_gc_time_ns = state.gc_time_ns;
    g_alloc_object_calls = state.alloc_object_calls;
    g_alloc_managed_slice_calls = state.alloc_managed_slice_calls;
    g_alloc_managed_bytes_calls = state.alloc_managed_bytes_calls;
    g_ops_budget_remaining = state.ops_budget_remaining;
}

// makeString allocates a heap-owned copy of s. Use this when passing host
// strings as args so the script can safely store them across Dispatch calls.
pub fn makeString(s: []const u8) !Value {
    return makeDynString(s);
}

// callGlobal looks up a top-level function by name and calls it with the
// provided args. Returns .null if the function does not exist (silent no-op).
// The VM's global state (module-level variables) persists across calls.
pub fn callGlobal(name: []const u8, args: []const Value) !Value {
    const fn_val = globals.get(name) orelse return .null;
    if (fn_val != .object) return error.NotAFunction;
    const obj = fn_val.object;
    if (obj.* != .function and obj.* != .closure) return error.NotAFunction;

    try vmPush(fn_val);
    for (args) |a| try vmPush(a);

    const depth_before = g_frame_top;
    try performCall(@intCast(args.len));

    const prev_target = g_call_depth_target;
    g_call_depth_target = depth_before;
    defer g_call_depth_target = prev_target;

    try run();
    return try vmPop();
}
