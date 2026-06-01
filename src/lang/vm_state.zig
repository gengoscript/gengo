const std = @import("std");
const chunk = @import("chunk.zig");
const heap = @import("../runtime/heap.zig");
const cfg = @import("../runtime/config.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;

pub const MaxStack = cfg.max_stack;
pub const MaxFrames = cfg.max_frames;
pub const MaxTempRoots = 128;
pub const RuneCacheMax = 8192;

pub const Policy = struct {
    pub const NativeBackend = enum {
        embedded,
        host,
    };

    allow_io: bool = true,
    native_backend: NativeBackend = .embedded,
    max_ops: ?u64 = null,
};

pub const Frame = struct {
    ret_ip: usize,
    base: usize,
    closure: ?*Object,
    func_obj: *Object,
    defer_base: usize,
    has_typed_returns: bool,
};

pub const PanicFrame = struct { line: u16, name: []const u8 };

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
    // String accumulation buffer: const_add uses this to avoid N-1 intermediate
    // allocations in pure string-constant chains ("a"+"b"+"c"+...).
    // str_acc_len > 0 means TOS holds a .string view into str_acc[0..str_acc_len].
    str_acc: [4096]u8 = undefined,
    str_acc_len: usize = 0,
    gc_runs: u64 = 0,
    gc_time_ns: u64 = 0,
    alloc_object_calls: u64 = 0,
    alloc_managed_slice_calls: u64 = 0,
    alloc_managed_bytes_calls: u64 = 0,
    ops_budget_remaining: u64 = std.math.maxInt(u64),
    defer_stack: [cfg.max_defers]Value = undefined,
    defer_top: usize = 0,
    panic_line: u32 = 0,
    panic_col: u16 = 0,
    panic_frames: [MaxFrames]PanicFrame = undefined,
    panic_depth: usize = 0,
    is_panicking: bool = false,
    panic_value: Value = .null,
    recovered: bool = false,
    pending_panic_message: ?[]const u8 = null,
    pending_panic_value: Value = .null,
    has_pending_panic_value: bool = false,
};

var g_default_state: State = .{};
var g_state: *State = &g_default_state;

pub inline fn vmState() *State {
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
    vmState().str_acc_len = 0;
    vmState().gc_runs = 0;
    vmState().gc_time_ns = 0;
    vmState().alloc_object_calls = 0;
    vmState().alloc_managed_slice_calls = 0;
    vmState().alloc_managed_bytes_calls = 0;
    vmState().ops_budget_remaining = std.math.maxInt(u64);
    vmState().defer_top = 0;
    vmState().panic_line = 0;
    vmState().panic_col = 0;
    vmState().panic_depth = 0;
    vmState().is_panicking = false;
    vmState().panic_value = .null;
    vmState().recovered = false;
    vmState().pending_panic_message = null;
    vmState().has_pending_panic_value = false;
}

// Reset only execution state; preserve globals, heap, GC objects, and std_module.
// Used by the REPL to run successive lines with shared state.
pub fn resetExec() void {
    vmState().stack_top = 0;
    vmState().ip = 0;
    vmState().frame_top = 0;
    vmState().call_depth_target = null;
    vmState().temp_root_top = 0;
    vmState().str_acc_len = 0;
    vmState().defer_top = 0;
    vmState().ops_budget_remaining = std.math.maxInt(u64);
    vmState().panic_line = 0;
    vmState().panic_col = 0;
    vmState().panic_depth = 0;
    vmState().is_panicking = false;
    vmState().panic_value = .null;
    vmState().recovered = false;
    vmState().pending_panic_message = null;
    vmState().has_pending_panic_value = false;
}

pub fn setPolicy(policy: Policy) void {
    vmState().policy = policy;
    vmState().ops_budget_remaining = policy.max_ops orelse std.math.maxInt(u64);
}

pub fn currentLine() u32 {
    const len = chunk.codeLen();
    if (len == 0) return 0;
    const idx: usize = if (vmState().ip == 0) 0 else @min(vmState().ip - 1, len - 1);
    return chunk.lineAt(idx);
}

pub fn currentCol() u16 {
    const len = chunk.codeLen();
    if (len == 0) return 0;
    const idx: usize = if (vmState().ip == 0) 0 else @min(vmState().ip - 1, len - 1);
    return chunk.colAt(idx);
}

pub fn panicLine() u32 { return vmState().panic_line; }
pub fn panicCol() u16 { return vmState().panic_col; }
pub fn panicFrames() []const PanicFrame { return vmState().panic_frames[0..vmState().panic_depth]; }

pub fn vmPush(v: Value) !void {
    if (vmState().stack_top >= MaxStack) return error.StackOverflow;
    vmState().stack[vmState().stack_top] = v;
    vmState().stack_top += 1;
}

pub fn vmPop() !Value {
    if (vmState().stack_top == 0) return error.StackUnderflow;
    vmState().stack_top -= 1;
    return vmState().stack[vmState().stack_top];
}

pub fn vmPeek(dist: usize) !Value {
    if (dist >= vmState().stack_top) return error.StackUnderflow;
    return vmState().stack[vmState().stack_top - 1 - dist];
}

pub fn vmByte() !u8 {
    if (vmState().ip >= chunk.codeLen()) return error.BytecodeOutOfBounds;
    const b = chunk.codeByteAt(vmState().ip);
    vmState().ip += 1;
    return b;
}

pub fn vmShort() !usize {
    const hi: usize = try vmByte();
    const lo: usize = try vmByte();
    return (hi << 8) | lo;
}

pub fn pushTempRoot(v: Value) !void {
    if (vmState().temp_root_top >= MaxTempRoots) return error.StackOverflow;
    vmState().temp_roots[vmState().temp_root_top] = v;
    vmState().temp_root_top += 1;
}

pub fn popTempRoot() void {
    if (vmState().temp_root_top > 0) vmState().temp_root_top -= 1;
}

pub fn vmConst() !Value {
    const idx = try vmShort();
    if (idx >= chunk.constCount()) return error.BadConstantIndex;
    return chunk.constAt(idx);
}

pub fn vmIndexFromVal(v: Value) !usize {
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

pub fn vmSliceIndex(v: Value, upper: usize) !usize {
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

pub fn valueAsNumber(v: Value) !f64 {
    return switch (v) {
        .number => |n| n,
        .rune => |r| @floatFromInt(r),
        .object => |o| switch (o.*) {
            .named_value => |nv| valueAsNumber(nv.value),
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

pub fn valueAsInt(v: Value) !i64 {
    return switch (v) {
        .number => |n| blk: {
            const t = @trunc(n);
            if (t != n) return error.TypeError;
            break :blk @intFromFloat(t);
        },
        .rune => |r| @intCast(r),
        .object => |o| switch (o.*) {
            .named_value => |nv| valueAsInt(nv.value),
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

pub fn unboxNamed(v: Value) Value {
    if (v == .object and v.object.* == .named_value) return v.object.named_value.value;
    return v;
}

// Object classification helpers used by GC, map ops, native fns, and the exec loop.

pub fn isStringValue(v: Value) bool {
    return v == .string or (v == .object and v.object.* == .dyn_string);
}

pub fn isArrayObject(obj: *Object) bool {
    return switch (obj.*) {
        .array, .array_managed => true,
        else => false,
    };
}

pub fn asArraySlice(obj: *Object) []Value {
    return switch (obj.*) {
        .array => |s| s,
        .array_managed => |s| s,
        else => unreachable,
    };
}

pub fn isMapObject(obj: *Object) bool {
    return switch (obj.*) {
        .map, .map_managed, .map_hashed => true,
        else => false,
    };
}

pub fn asMapSlice(obj: *Object) []MapEntry {
    return switch (obj.*) {
        .map => |s| s,
        .map_managed => |s| s,
        .map_hashed => |hm| hm.entries[0..hm.len],
        else => unreachable,
    };
}

pub fn asStringValue(v: Value) ![]const u8 {
    if (v == .string) return v.string;
    if (v == .object and v.object.* == .dyn_string) return v.object.dyn_string;
    return error.TypeError;
}
