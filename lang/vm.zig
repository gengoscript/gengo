const std = @import("std");
const builtin = @import("builtin");
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
const InterfaceMethodSpec = @import("value.zig").InterfaceMethodSpec;
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

const Frame = struct { ret_ip: usize, base: usize, closure: ?*Object, func_obj: *Object };
const MaxTempRoots = 128;
const RuneCacheMax = 8192;

const NativeFnId = enum(u8) {
    io_println = 1,
    io_printf = 15,
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

var g_default_state: State = .{};
var g_state: *State = &g_default_state;

inline fn vmState() *State {
    return g_state;
}

pub fn setActive(state: *State) void {
    g_state = state;
}

pub fn reset() void {
    vmState().stack_top = 0;
    vmState().ip = 0;
    vmState().frame_top = 0;
    vmState().std_module = null;
    vmState().host_checked = false;
    vmState().host_caps = 0;
    vmState().next_gc_objects = 256;
    vmState().next_gc_heap_bytes = heap.HeapSize / 2;
    vmState().call_depth_target = null;
    vmState().temp_root_top = 0;
    vmState().rune_cache_ptr = 0;
    vmState().rune_cache_byte_len = 0;
    vmState().rune_cache_rune_len = 0;
    vmState().rune_cache_valid = false;
    vmState().rune_cache_overflow = false;
    vmState().gc_runs = 0;
    vmState().gc_time_ns = 0;
    vmState().alloc_object_calls = 0;
    vmState().alloc_managed_slice_calls = 0;
    vmState().alloc_managed_bytes_calls = 0;
    vmState().ops_budget_remaining = null;
}

pub fn setPolicy(policy: Policy) void {
    vmState().policy = policy;
    vmState().ops_budget_remaining = policy.max_ops;
}

fn vmPush(v: Value) !void {
    if (vmState().stack_top >= MaxStack) return error.StackOverflow;
    vmState().stack[vmState().stack_top] = v;
    vmState().stack_top += 1;
}
fn vmPop() !Value {
    if (vmState().stack_top == 0) return error.StackUnderflow;
    vmState().stack_top -= 1;
    return vmState().stack[vmState().stack_top];
}
fn vmPeek(dist: usize) !Value {
    if (dist >= vmState().stack_top) return error.StackUnderflow;
    return vmState().stack[vmState().stack_top - 1 - dist];
}
fn vmByte() !u8 {
    if (vmState().ip >= chunk.codeLen()) return error.BytecodeOutOfBounds;
    const b = chunk.codeByteAt(vmState().ip);
    vmState().ip += 1;
    return b;
}
fn vmShort() !usize {
    const hi: usize = try vmByte();
    const lo: usize = try vmByte();
    return (hi << 8) | lo;
}

fn pushTempRoot(v: Value) !void {
    if (vmState().temp_root_top >= MaxTempRoots) return error.StackOverflow;
    vmState().temp_roots[vmState().temp_root_top] = v;
    vmState().temp_root_top += 1;
}

fn popTempRoot() void {
    if (vmState().temp_root_top > 0) vmState().temp_root_top -= 1;
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
    if (vmState().rune_cache_valid and vmState().rune_cache_ptr == @intFromPtr(s.ptr) and vmState().rune_cache_byte_len == s.len) return;
    vmState().rune_cache_ptr = @intFromPtr(s.ptr);
    vmState().rune_cache_byte_len = s.len;
    vmState().rune_cache_rune_len = 0;
    vmState().rune_cache_valid = true;
    vmState().rune_cache_overflow = false;
    var i: usize = 0;
    while (i < s.len) {
        if (vmState().rune_cache_rune_len < RuneCacheMax) {
            vmState().rune_cache_offsets[vmState().rune_cache_rune_len] = i;
        } else {
            vmState().rune_cache_overflow = true;
        }
        i += try utf8NextRuneByteLen(s, i);
        vmState().rune_cache_rune_len += 1;
    }
}

fn utf8RuneCountCached(s: []const u8) !usize {
    try ensureRuneCache(s);
    return vmState().rune_cache_rune_len;
}

fn utf8ByteOffsetForRuneIndexCached(s: []const u8, rune_idx: usize) !usize {
    try ensureRuneCache(s);
    if (rune_idx == vmState().rune_cache_rune_len) return s.len;
    if (rune_idx > vmState().rune_cache_rune_len) return error.IndexOutOfBounds;
    if (!vmState().rune_cache_overflow and rune_idx < RuneCacheMax) return vmState().rune_cache_offsets[rune_idx];
    return utf8ByteOffsetForRuneIndex(s, rune_idx);
}

fn monoNowNs() u64 {
    if (comptime builtin.os.tag != .wasi) {
        return 0;
    }
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
    if (vmState().std_module) |m| return m;

    const io_items = heap.bump(MapEntry, 2) orelse return error.OutOfMemory;
    io_items[0] = .{
        .key = .{ .string = "println" },
        .value = try makeNative(.io_println, 255),
    };
    io_items[1] = .{
        .key = .{ .string = "printf" },
        .value = try makeNative(.io_printf, 255),
    };
    const io_obj = try vmAllocObject();
    io_obj.* = .{ .map = io_items[0..2] };

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
    vmState().std_module = std_obj;
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
        .named_value => |nv| {
            markObject(nv.typ);
            markValue(nv.value);
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
        .enum_value => |ev| markObject(ev.typ),
        .dyn_string, .function, .native_function, .struct_type, .interface_type, .named_type, .enum_type => {},
    }
}

fn collectGarbage() void {
    const t0 = monoNowNs();
    var i: usize = 0;
    while (i < vmState().stack_top) : (i += 1) markValue(vmState().stack[i]);

    i = 0;
    while (i < globals.len()) : (i += 1) markValue(globals.valueAt(i));

    if (vmState().std_module) |m| markObject(m);

    i = 0;
    while (i < vmState().temp_root_top) : (i += 1) markValue(vmState().temp_roots[i]);

    i = 0;
    while (i < chunk.constCount()) : (i += 1) markValue(chunk.constAt(i));

    heap.sweepObjects();
    const t1 = monoNowNs();
    vmState().gc_runs += 1;
    if (t1 > t0) vmState().gc_time_ns += @intCast(t1 - t0);
}

fn vmAllocObject() !*Object {
    if (heap.liveObjectCount() >= vmState().next_gc_objects) {
        collectGarbage();
        const live = heap.liveObjectCount();
        vmState().next_gc_objects = (live * 2) + 64;
    }
    if (heap.allocObject()) |o| {
        vmState().alloc_object_calls += 1;
        return o;
    }
    collectGarbage();
    const live = heap.liveObjectCount();
    vmState().next_gc_objects = (live * 2) + 64;
    if (heap.allocObject()) |o| {
        vmState().alloc_object_calls += 1;
        return o;
    }
    return error.OutOfMemory;
}

fn vmAllocManagedSlice(comptime T: type, n: usize) ![]T {
    if (heap.usedBytes() >= vmState().next_gc_heap_bytes) {
        collectGarbage();
        const used = heap.usedBytes();
        const step = heap.HeapSize / 4;
        vmState().next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    }
    if (heap.allocManagedSlice(T, n)) |s| {
        vmState().alloc_managed_slice_calls += 1;
        return s;
    }
    collectGarbage();
    const used = heap.usedBytes();
    const step = heap.HeapSize / 4;
    vmState().next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    if (heap.allocManagedSlice(T, n)) |s| {
        vmState().alloc_managed_slice_calls += 1;
        return s;
    }
    return error.OutOfMemory;
}

fn vmAllocManagedBytes(n: usize) ![]u8 {
    if (heap.usedBytes() >= vmState().next_gc_heap_bytes) {
        collectGarbage();
        const used = heap.usedBytes();
        const step = heap.HeapSize / 4;
        vmState().next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    }
    if (heap.allocBytesManaged(n)) |s| {
        vmState().alloc_managed_bytes_calls += 1;
        return s;
    }
    collectGarbage();
    const used = heap.usedBytes();
    const step = heap.HeapSize / 4;
    vmState().next_gc_heap_bytes = if (used + step > heap.HeapSize) heap.HeapSize else used + step;
    if (heap.allocBytesManaged(n)) |s| {
        vmState().alloc_managed_bytes_calls += 1;
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

fn nativePrintf(start: usize, argc: u8) !void {
    if (argc < 1) return error.ArityMismatch;
    const fmt_v = vmState().stack[start];
    const fmt = try asStringValue(fmt_v);
    var ai: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            io.write(fmt[i .. i + 1]);
            i += 1;
            continue;
        }
        if (i + 1 >= fmt.len) return error.TypeError;
        const spec = fmt[i + 1];
        if (spec == '%') {
            io.write("%");
            i += 2;
            continue;
        }
        if (ai >= @as(usize, argc)) return error.ArityMismatch;
        const arg = vmState().stack[start + ai];
        ai += 1;
        switch (spec) {
            'v' => io.printValue(arg),
            's' => io.write(try asStringValue(arg)),
            'd' => io.writeInt(try valueAsInt(arg)),
            'f' => io.writeF64(try valueAsNumber(arg)),
            't' => {
                if (arg != .boolean) return error.TypeError;
                io.write(if (arg.boolean) "true" else "false");
            },
            else => return error.TypeError,
        }
        i += 2;
    }
    if (ai != @as(usize, argc)) return error.ArityMismatch;
}

fn nativeAppend(start: usize, argc: u8) !Value {
    if (argc < 1) return error.ArityMismatch;
    const first = vmState().stack[start];
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
        out[base.len + i] = vmState().stack[start + 1 + i];
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
        .value = .{ .number = @floatFromInt(vmState().gc_runs) },
    };
    items[4] = .{
        .key = .{ .string = "gc_time_ns" },
        .value = .{ .number = @floatFromInt(vmState().gc_time_ns) },
    };
    items[5] = .{
        .key = .{ .string = "alloc_object_calls" },
        .value = .{ .number = @floatFromInt(vmState().alloc_object_calls) },
    };
    items[6] = .{
        .key = .{ .string = "alloc_managed_slice_calls" },
        .value = .{ .number = @floatFromInt(vmState().alloc_managed_slice_calls) },
    };
    items[7] = .{
        .key = .{ .string = "alloc_managed_bytes_calls" },
        .value = .{ .number = @floatFromInt(vmState().alloc_managed_bytes_calls) },
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
        .error_t => v == .error_value,
        .array => v == .object and isArrayObject(v.object),
        .map => v == .object and isMapObject(v.object),
        .struct_t => v == .object and v.object.* == .struct_instance and common.streq(v.object.struct_instance.typ.struct_type.name, alt.struct_name),
        .interface_t => matchesInterfaceType(v, alt.interface_name),
        .named_t => v == .object and switch (v.object.*) {
            .named_value => common.streq(v.object.named_value.typ.named_type.name, alt.named_name),
            .enum_value => common.streq(v.object.enum_value.typ.enum_type.name, alt.named_name),
            else => false,
        },
    };
}

fn makeNamedValue(typ_obj: *Object, inner: Value) !Value {
    const obj = try vmAllocObject();
    obj.* = .{ .named_value = .{ .typ = typ_obj, .value = inner } };
    return .{ .object = obj };
}

fn constructNamedType(typ_obj: *Object, arg: Value) !Value {
    if (typ_obj.* != .named_type) return error.TypeError;
    const nt = typ_obj.named_type;
    var base_v: Value = undefined;
    switch (nt.base) {
        .int => {
            const n = try valueAsNumber(arg);
            if (@trunc(n) != n) return error.TypeError;
            base_v = .{ .number = n };
            if (nt.has_range and (n < nt.min or n > nt.max)) return error.RangeError;
        },
        .float => {
            const n = try valueAsNumber(arg);
            base_v = .{ .number = n };
            if (nt.has_range and (n < nt.min or n > nt.max)) return error.RangeError;
        },
        .rune => {
            const r: u21 = switch (arg) {
                .rune => |rv| rv,
                .number => |n| blk: {
                    const t = @trunc(n);
                    if (t != n or t < 0) return error.TypeError;
                    break :blk @intFromFloat(t);
                },
                else => return error.TypeError,
            };
            const rf: f64 = @floatFromInt(r);
            base_v = .{ .rune = r };
            if (nt.has_range and (rf < nt.min or rf > nt.max)) return error.RangeError;
        },
        .string => {
            if (!isStringValue(arg)) return error.TypeError;
            const s = try asStringValue(arg);
            base_v = try makeDynString(s);
        },
        .bool => {
            if (arg != .boolean) return error.TypeError;
            base_v = arg;
        },
    }
    return makeNamedValue(typ_obj, base_v);
}

fn interfaceMethodMatches(m: InterfaceMethodSpec, f: @import("value.zig").FuncObj) bool {
    if (m.is_variadic != f.is_variadic) return false;
    var f_param_start: usize = 0;
    if (f.arity == m.arity + 1 and f.param_types.len == m.param_types.len + 1) {
        // Struct receiver methods are compiled with an implicit first parameter.
        f_param_start = 1;
    } else if (m.arity != f.arity) {
        return false;
    }
    if (m.has_typed_params != f.has_typed_params) return false;
    if (m.has_typed_returns != f.has_typed_returns) return false;
    if (m.param_types.len + f_param_start != f.param_types.len) return false;
    if (m.return_types.len != f.return_types.len) return false;
    if (m.is_variadic) {
        const ma = m.variadic_type.alts;
        const fa = f.variadic_type.alts;
        if (ma.len != fa.len) return false;
        var vai: usize = 0;
        while (vai < ma.len) : (vai += 1) {
            if (ma[vai].typ != fa[vai].typ) return false;
            switch (ma[vai].typ) {
                .struct_t => if (!common.streq(ma[vai].struct_name, fa[vai].struct_name)) return false,
                .interface_t => if (!common.streq(ma[vai].interface_name, fa[vai].interface_name)) return false,
                .named_t => if (!common.streq(ma[vai].named_name, fa[vai].named_name)) return false,
                else => {},
            }
        }
    }
    var i: usize = 0;
    while (i < m.param_types.len) : (i += 1) {
        const ma = m.param_types[i].alts;
        const fa = f.param_types[f_param_start + i].alts;
        if (ma.len != fa.len) return false;
        var ai: usize = 0;
        while (ai < ma.len) : (ai += 1) {
            if (ma[ai].typ != fa[ai].typ) return false;
            switch (ma[ai].typ) {
                .struct_t => if (!common.streq(ma[ai].struct_name, fa[ai].struct_name)) return false,
                .interface_t => if (!common.streq(ma[ai].interface_name, fa[ai].interface_name)) return false,
                .named_t => if (!common.streq(ma[ai].named_name, fa[ai].named_name)) return false,
                else => {},
            }
        }
    }
    i = 0;
    while (i < m.return_types.len) : (i += 1) {
        const ma = m.return_types[i].alts;
        const fa = f.return_types[i].alts;
        if (ma.len != fa.len) return false;
        var ai: usize = 0;
        while (ai < ma.len) : (ai += 1) {
            if (ma[ai].typ != fa[ai].typ) return false;
            switch (ma[ai].typ) {
                .struct_t => if (!common.streq(ma[ai].struct_name, fa[ai].struct_name)) return false,
                .interface_t => if (!common.streq(ma[ai].interface_name, fa[ai].interface_name)) return false,
                .named_t => if (!common.streq(ma[ai].named_name, fa[ai].named_name)) return false,
                else => {},
            }
        }
    }
    return true;
}

fn matchesInterfaceType(v: Value, iname: []const u8) bool {
    if (!(v == .object and v.object.* == .struct_instance)) return false;
    const tname = v.object.struct_instance.typ.struct_type.name;
    const iv = globals.get(iname) orelse return false;
    if (!(iv == .object and iv.object.* == .interface_type)) return false;
    const it = iv.object.interface_type;
    var mi: usize = 0;
    while (mi < it.methods.len) : (mi += 1) {
        const m = it.methods[mi];
        const total = tname.len + 1 + m.name.len;
        if (total > 128) return false;
        var key_buf: [128]u8 = undefined;
        @memcpy(key_buf[0..tname.len], tname);
        key_buf[tname.len] = '.';
        @memcpy(key_buf[tname.len + 1 .. total], m.name);
        const fnv = globals.get(key_buf[0..total]) orelse return false;
        if (!(fnv == .object and (fnv.object.* == .function or fnv.object.* == .closure))) return false;
        const f = switch (fnv.object.*) {
            .function => |ff| ff,
            .closure => |cl| cl.func.function,
            else => return false,
        };
        if (!interfaceMethodMatches(m, f)) return false;
    }
    return true;
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
    const fixed: usize = if (f.is_variadic) f.arity - 1 else f.arity;
    var i: usize = 0;
    while (i < fixed) : (i += 1) {
        const arg = vmState().stack[vmState().stack_top - argc + i];
        if (!matchesTypeSpec(arg, f.param_types[i])) return error.TypeError;
    }
    if (f.is_variadic) {
        while (i < @as(usize, argc)) : (i += 1) {
            const arg = vmState().stack[vmState().stack_top - argc + i];
            if (!matchesTypeSpec(arg, f.variadic_type)) return error.TypeError;
        }
    }
}

fn enforceFuncReturnTypes(f: @import("value.zig").FuncObj, retval: Value) !void {
    if (!f.has_typed_returns) return;
    if (f.return_types.len == 0) return;
    if (f.return_types.len == 1) {
        if (!matchesTypeSpec(retval, f.return_types[0])) return error.TypeError;
        return;
    }
    if (!(retval == .object and isArrayObject(retval.object))) return error.TypeError;
    const arr = asArraySlice(retval.object);
    if (arr.len != f.return_types.len) return error.ArityMismatch;
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        if (!matchesTypeSpec(arr[i], f.return_types[i])) return error.TypeError;
    }
}

fn frameFuncSig(func_obj: *Object) !@import("value.zig").FuncObj {
    return switch (func_obj.*) {
        .function => |f| f,
        .closure => |cl| cl.func.function,
        else => error.NotAFunction,
    };
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
    if (vmState().policy.native_backend != .host) return;
    if (vmState().host_checked) return;

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
            vmState().host_caps = 0;
            vmState().host_checked = true;
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
    vmState().host_caps = try wireNumberToU64(out);
    vmState().host_checked = true;
}

fn callNative(nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .io_println => {
            if (!vmState().policy.allow_io) return error.PermissionDenied;
            if (vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vmState().host_caps & host_abi.CAP_IO_PRINTLN) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    const start = vmState().stack_top - argc;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try wireFromValue(vmState().stack[start + i]);
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
            const start = vmState().stack_top - argc;
            var i: usize = 0;
            while (i < @as(usize, argc)) : (i += 1) io.printValue(vmState().stack[start + i]);
            io.write("\n");
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vmPop();
            _ = try vmPop();
            try vmPush(.null);
        },
        .io_printf => {
            if (!vmState().policy.allow_io) return error.PermissionDenied;
            const start = vmState().stack_top - argc;
            try nativePrintf(start, argc);
            var j: usize = 0;
            while (j < @as(usize, argc)) : (j += 1) _ = try vmPop();
            _ = try vmPop();
            try vmPush(.null);
        },
        .core_len => {
            if (argc != nf.arity) return error.ArityMismatch;
            if (vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vmState().host_caps & host_abi.CAP_CORE_LEN) != 0) {
                    var arg_wire: [1]host_abi.ValueWire = undefined;
                    arg_wire[0] = try wireFromValue(vmState().stack[vmState().stack_top - 1]);
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
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try nativeLen(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .core_append => {
            const start = vmState().stack_top - argc;
            if (vmState().policy.native_backend == .host) {
                try ensureHostReady();
                if ((vmState().host_caps & host_abi.CAP_CORE_APPEND) != 0) {
                    if (argc > MaxNativeArgs) return error.ArityMismatch;
                    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
                    var i: usize = 0;
                    while (i < @as(usize, argc)) : (i += 1) {
                        args_wire[i] = try wireFromValue(vmState().stack[start + i]);
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
            const arg = vmState().stack[vmState().stack_top - 1];
            const msg = try asStringValue(arg);
            const copy = heap.bump(u8, msg.len) orelse return error.OutOfMemory;
            @memcpy(copy[0..msg.len], msg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(.{ .error_value = copy[0..msg.len] });
        },
        .core_is_error => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
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
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try nativeByteLen(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .conv_to_int => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try nativeConvToInt(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .conv_to_float => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try nativeConvToFloat(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .conv_to_bool => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try nativeConvToBool(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .conv_to_string => {
            if (argc != nf.arity) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try nativeConvToString(arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
    }
}

fn prepareVariadicCall(f: @import("value.zig").FuncObj, argc: u8) !void {
    if (!f.is_variadic) return;
    const fixed: usize = f.arity - 1;
    if (argc < fixed) return error.ArityMismatch;
    const start = vmState().stack_top - argc;
    const extra: usize = argc - fixed;
    const arr_obj = try vmAllocObject();
    try pushTempRoot(.{ .object = arr_obj });
    defer popTempRoot();
    const items = try vmAllocManagedSlice(Value, extra);
    var i: usize = 0;
    while (i < extra) : (i += 1) items[i] = vmState().stack[start + fixed + i];
    arr_obj.* = .{ .array_managed = items[0..extra] };
    vmState().stack[start + fixed] = .{ .object = arr_obj };
    vmState().stack_top = start + fixed + 1;
}

fn performCall(argc: u8) !void {
    const func_val = vmState().stack[vmState().stack_top - argc - 1];
    if (func_val != .object) return error.NotAFunction;
    const obj = func_val.object;
    switch (obj.*) {
        .function => |f| {
            if (f.is_variadic) {
                if (argc < f.arity - 1) return error.ArityMismatch;
            } else if (f.arity != argc) return error.ArityMismatch;
            if (f.has_typed_params) try enforceFuncArgTypes(f, argc);
            try prepareVariadicCall(f, argc);
            if (vmState().frame_top >= MaxFrames) return error.CallStackOverflow;
            vmState().frames[vmState().frame_top] = .{
                .ret_ip = vmState().ip,
                .base = vmState().stack_top - f.arity,
                .closure = null,
                .func_obj = obj,
            };
            vmState().frame_top += 1;
            vmState().ip = f.ip;
        },
        .closure => |cl| {
            const f = cl.func.function;
            if (f.is_variadic) {
                if (argc < f.arity - 1) return error.ArityMismatch;
            } else if (f.arity != argc) return error.ArityMismatch;
            if (f.has_typed_params) try enforceFuncArgTypes(f, argc);
            try prepareVariadicCall(f, argc);
            if (vmState().frame_top >= MaxFrames) return error.CallStackOverflow;
            vmState().frames[vmState().frame_top] = .{
                .ret_ip = vmState().ip,
                .base = vmState().stack_top - f.arity,
                .closure = obj,
                .func_obj = cl.func,
            };
            vmState().frame_top += 1;
            vmState().ip = f.ip;
        },
        .native_function => |nf| {
            try callNative(nf, argc);
        },
        .named_type => {
            if (argc != 1) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try constructNamedType(obj, arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        else => return error.NotAFunction,
    }
}

fn writeFrameLocal(abs_slot: usize, v: Value) void {
    const cur = vmState().stack[abs_slot];
    if (cur == .object and cur.object.* == .cell) {
        cur.object.cell.value = v;
    } else {
        vmState().stack[abs_slot] = v;
    }
}

fn trySelfTailCall(argc: u8) !bool {
    if (vmState().frame_top == 0) return false;
    // Tail position pattern emitted by compiler: `call <argc>` followed by `ret`.
    if (vmState().ip >= chunk.codeLen()) return false;
    const next_op: Op = @enumFromInt(chunk.codeByteAt(vmState().ip));
    if (next_op != .ret) return false;

    const callee_idx = vmState().stack_top - argc - 1;
    const func_val = vmState().stack[callee_idx];
    if (func_val != .object) return false;
    const callee_obj = func_val.object;

    const frame_idx = vmState().frame_top - 1;
    const frame = vmState().frames[frame_idx];
    if (callee_obj.* == .closure) {
        if (frame.closure == null or frame.closure.? != callee_obj) return false;
        const f = callee_obj.closure.func.function;
        if (f.is_variadic) return false;
        if (f.arity != argc) return false;
        if (f.has_typed_params) try enforceFuncArgTypes(f, argc);
        // Rewrite current frame arg/local prefix with new args.
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            writeFrameLocal(frame.base + i, vmState().stack[callee_idx + 1 + i]);
        }
        vmState().stack_top = frame.base + argc;
        vmState().ip = f.ip;
        return true;
    }
    if (callee_obj.* == .function) {
        if (frame.closure != null) return false;
        if (frame.func_obj != callee_obj) return false;
        const f = callee_obj.function;
        if (f.is_variadic) return false;
        if (f.arity != argc) return false;
        if (f.has_typed_params) try enforceFuncArgTypes(f, argc);
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            writeFrameLocal(frame.base + i, vmState().stack[callee_idx + 1 + i]);
        }
        vmState().stack_top = frame.base + argc;
        vmState().ip = f.ip;
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
        if (vmState().ops_budget_remaining) |remaining| {
            if (remaining == 0) return error.InstructionBudgetExceeded;
            vmState().ops_budget_remaining = remaining - 1;
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
                const base = vmState().frames[vmState().frame_top - 1].base;
                const v = vmState().stack[base + slot];
                if (v == .object and v.object.* == .cell) {
                    try vmPush(v.object.cell.value);
                } else {
                    try vmPush(v);
                }
            },
            .set_local => {
                const slot = try vmByte();
                const base = vmState().frames[vmState().frame_top - 1].base;
                const val = try vmPop();
                const cur = vmState().stack[base + slot];
                if (cur == .object and cur.object.* == .cell) {
                    cur.object.cell.value = val;
                } else {
                    vmState().stack[base + slot] = val;
                }
            },
            .get_upvalue => {
                const idx = try vmByte();
                const frame = vmState().frames[vmState().frame_top - 1];
                const cl = frame.closure orelse return error.TypeError;
                if (cl.* != .closure) return error.TypeError;
                if (idx >= cl.closure.upvalues.len) return error.TypeError;
                const cell = cl.closure.upvalues[idx];
                try vmPush(cell.cell.value);
            },
            .set_upvalue => {
                const idx = try vmByte();
                const frame = vmState().frames[vmState().frame_top - 1];
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
                        .enum_type => |et| {
                            const key = try expectStringKey(idx_v);
                            var ei: usize = 0;
                            while (ei < et.members.len) : (ei += 1) {
                                if (common.streq(et.members[ei], key)) {
                                    const ev = try vmAllocObject();
                                    ev.* = .{ .enum_value = .{
                                        .typ = obj,
                                        .name = et.members[ei],
                                        .ordinal = @intCast(ei),
                                    } };
                                    try vmPush(.{ .object = ev });
                                    break;
                                }
                            }
                            if (ei == et.members.len) return error.UnknownStructField;
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
                if (vmState().frame_top == 0 and proto.capture_slots.len != 0) return error.TypeError;
                const frame = if (vmState().frame_top == 0) Frame{ .ret_ip = 0, .base = 0, .closure = null, .func_obj = f.object } else vmState().frames[vmState().frame_top - 1];
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
                        const cur = vmState().stack[abs];
                        if (cur == .object and cur.object.* == .cell) {
                            ups[i] = cur.object;
                            continue;
                        }
                        const cell = try vmAllocObject();
                        cell.* = .{ .cell = .{ .value = cur } };
                        vmState().stack[abs] = .{ .object = cell };
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
                const recv_idx = vmState().stack_top - argc - 1;
                const recv = vmState().stack[recv_idx];
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
                        if (vmState().stack_top >= MaxStack) return error.StackOverflow;
                        var i: usize = vmState().stack_top;
                        while (i > recv_idx + 1) {
                            vmState().stack[i] = vmState().stack[i - 1];
                            i -= 1;
                        }
                        vmState().stack_top += 1;
                        vmState().stack[recv_idx] = func;
                        vmState().stack[recv_idx + 1] = recv;
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
                        vmState().stack[recv_idx] = func;
                        try performCall(argc);
                    },
                    else => return error.NotAMethodReceiver,
                }
            },

            .jump => {
                const off = try vmShort();
                vmState().ip += off;
            },
            .jump_if_false => {
                const off = try vmShort();
                if (!(try vmPeek(0)).isTruthy()) vmState().ip += off;
            },
            .loop => {
                const off = try vmShort();
                vmState().ip -= off;
            },

            .call => {
                const argc = try vmByte();
                if (try trySelfTailCall(argc)) continue;
                try performCall(argc);
            },
            .ret => {
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const retval = try vmPop();
                vmState().frame_top -= 1;
                const frame = vmState().frames[vmState().frame_top];
                const fsig = try frameFuncSig(frame.func_obj);
                try enforceFuncReturnTypes(fsig, retval);
                vmState().stack_top = frame.base - 1;
                vmState().ip = frame.ret_ip;
                try vmPush(retval);
                if (vmState().call_depth_target) |d| {
                    if (vmState().frame_top == d) return;
                }
            },

            .halt => return,
        }
    }
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

    const depth_before = vmState().frame_top;
    try performCall(@intCast(args.len));

    const prev_target = vmState().call_depth_target;
    vmState().call_depth_target = depth_before;
    defer vmState().call_depth_target = prev_target;

    try run();
    return try vmPop();
}
