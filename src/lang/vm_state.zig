const std = @import("std");
const chunk = @import("chunk.zig");
const heap = @import("../runtime/heap.zig");
const cfg = @import("../runtime/config.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;
const builtin = @import("builtin");

// Preset ceilings — these are the maximum any instance may request.
pub const MaxStack = cfg.max_stack;
pub const MaxFrames = cfg.max_frames;
pub const MaxTempRoots = 128;
pub const RuneCacheMax = 8192;

// On WASM, keep preset-sized backing arrays for the slices.
const WasmBacking = if (builtin.target.cpu.arch == .wasm32) struct {
    stack: [MaxStack]Value = undefined,
    frames: [MaxFrames]Frame = undefined,
    defer_stack: [cfg.max_defers]Value = undefined,
    panic_frames: [MaxFrames]PanicFrame = undefined,
} else struct {};

var g_wasm_backing: WasmBacking = .{};

pub const Policy = struct {
    pub const NativeBackend = enum {
        embedded,
        host,
    };

    allow_io: bool = true,
    native_backend: NativeBackend = .embedded,
    max_ops: ?u64 = null,
    enable_predicates: bool = true,
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
    stack: []Value = &[_]Value{},
    stack_top: usize = 0,
    ip: usize = 0,
    frames: []Frame = &[_]Frame{},
    frame_top: usize = 0,
    std_module: ?*Object = null,
    host_checked: bool = false,
    host_caps: u64 = 0,
    configured_heap_size: usize = 0,
    next_gc_objects: usize = 256,
    next_gc_heap_bytes: usize = 0,
    call_depth_target: ?usize = null,
    temp_roots: [MaxTempRoots]Value = undefined,
    temp_root_top: usize = 0,
    rune_cache_ptr: usize = 0,
    rune_cache_byte_len: usize = 0,
    rune_cache_rune_len: usize = 0,
    rune_cache_valid: bool = false,
    rune_cache_overflow: bool = false,
    rune_cache_offsets: [RuneCacheMax]usize = undefined,
    fmt_scratch: [64]u8 = undefined,
    gc_runs: u64 = 0,
    gc_time_ns: u64 = 0,
    alloc_object_calls: u64 = 0,
    alloc_managed_slice_calls: u64 = 0,
    alloc_managed_bytes_calls: u64 = 0,
    ops_budget_remaining: u64 = std.math.maxInt(u64),
    defer_stack: []Value = &[_]Value{},
    defer_top: usize = 0,
    panic_line: u32 = 0,
    panic_col: u16 = 0,
    panic_frames: []PanicFrame = &[_]PanicFrame{},
    panic_depth: usize = 0,
    is_panicking: bool = false,
    panic_value: Value = .null,
    recovered: bool = false,
    pending_panic_message: ?[]const u8 = null,
    pending_panic_value: Value = .null,
    has_pending_panic_value: bool = false,
    runtime_err_buf: [256]u8 = undefined,
    runtime_err_len: u16 = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn init(self: *State, max_stack: usize, max_frames: usize, max_defers: usize, heap_size: usize, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        if (comptime builtin.target.cpu.arch == .wasm32) {
            self.stack = &g_wasm_backing.stack;
            self.frames = &g_wasm_backing.frames;
            self.defer_stack = &g_wasm_backing.defer_stack;
            self.panic_frames = &g_wasm_backing.panic_frames;
        } else {
            self.stack = try allocator.alloc(Value, max_stack);
            self.frames = try allocator.alloc(Frame, max_frames);
            self.defer_stack = try allocator.alloc(Value, max_defers);
            self.panic_frames = try allocator.alloc(PanicFrame, max_frames);
        }
        self.configured_heap_size = heap_size;
        self.next_gc_heap_bytes = heap_size / 2;
        const saved_allocator = self.allocator;
        self.* = .{
            .stack = self.stack,
            .frames = self.frames,
            .defer_stack = self.defer_stack,
            .panic_frames = self.panic_frames,
            .configured_heap_size = self.configured_heap_size,
            .next_gc_heap_bytes = self.next_gc_heap_bytes,
            .allocator = saved_allocator,
        };
    }

    pub fn deinit(self: *State) void {
        if (comptime builtin.target.cpu.arch == .wasm32) {
            self.* = .{};
            return;
        }
        if (self.stack.len > 0) self.allocator.free(self.stack);
        if (self.frames.len > 0) self.allocator.free(self.frames);
        if (self.defer_stack.len > 0) self.allocator.free(self.defer_stack);
        if (self.panic_frames.len > 0) self.allocator.free(self.panic_frames);
        self.* = .{};
    }
};

var g_default_state: State = .{};
var g_state: *State = &g_default_state;

pub inline fn vmState() *State {
    return g_state;
}

pub fn setActive(state: *State) void {
    if (state.stack.len == 0 and state == &g_default_state) {
        _ = state.init(MaxStack, MaxFrames, cfg.max_defers, heap.HeapSize, state.allocator) catch {};
    }
    g_state = state;
}

pub fn activeState() *State {
    return g_state;
}

pub fn reset() void {
    if (vmState().stack.len == 0 and vmState() == &g_default_state) {
        _ = g_default_state.init(MaxStack, MaxFrames, cfg.max_defers, heap.HeapSize, vmState().allocator) catch {};
    }
    resetExec();
    vmState().std_module = null;
    vmState().host_checked = false;
    vmState().host_caps = 0;
    vmState().next_gc_objects = 256;
    vmState().next_gc_heap_bytes = if (vmState().configured_heap_size > 0) vmState().configured_heap_size / 2 else heap.HeapSize / 2;
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
}

// Reset only execution state; preserve globals, heap, GC objects, and std_module.
// Used by the REPL to run successive lines with shared state.
pub fn resetExec() void {
    vmState().stack_top = 0;
    vmState().ip = 0;
    vmState().frame_top = 0;
    vmState().call_depth_target = null;
    vmState().temp_root_top = 0;
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
    vmState().runtime_err_len = 0;
}

pub fn setRuntimeErr(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&vmState().runtime_err_buf, fmt, args) catch return;
    vmState().runtime_err_len = @intCast(s.len);
}

pub fn runtimeErrMsg() []const u8 {
    return vmState().runtime_err_buf[0..vmState().runtime_err_len];
}

pub fn setPolicy(policy: Policy) void {
    vmState().policy = policy;
    vmState().ops_budget_remaining = policy.max_ops orelse std.math.maxInt(u64);
}

fn currentIpIdx() usize {
    const len = chunk.codeLen();
    if (len == 0) return 0;
    return if (vmState().ip == 0) 0 else @min(vmState().ip - 1, len - 1);
}

pub fn currentLine() u32 {
    return chunk.lineAt(currentIpIdx());
}
pub fn currentCol() u16 {
    return chunk.colAt(currentIpIdx());
}

pub fn panicLine() u32 {
    return vmState().panic_line;
}
pub fn panicCol() u16 {
    return vmState().panic_col;
}
pub fn panicFrames() []const PanicFrame {
    return vmState().panic_frames[0..vmState().panic_depth];
}

pub inline fn vmPush(v: Value) !void {
    assertStringImmortal(v);
    const st = vmState();
    if (st.stack_top >= st.stack.len) return error.StackOverflow;
    st.stack[st.stack_top] = v;
    st.stack_top += 1;
}

pub inline fn vmPop() !Value {
    if (vmState().stack_top == 0) return error.StackUnderflow;
    vmState().stack_top -= 1;
    return vmState().stack[vmState().stack_top];
}

pub inline fn vmPeek(dist: usize) !Value {
    if (dist >= vmState().stack_top) return error.StackUnderflow;
    return vmState().stack[vmState().stack_top - 1 - dist];
}

// Unchecked stack read for native dispatch — safe after arity has been verified.
pub inline fn vmTop(dist: usize) Value {
    return vmState().stack[vmState().stack_top - 1 - dist];
}

// Pop all arguments of a native call: argc user args plus the function object.
// Safe to call unchecked after arity has been verified.
pub inline fn vmPopArgs(argc: u8) void {
    vmState().stack_top -= @as(usize, argc) + 1;
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

pub fn vmInt() !usize {
    const b3: usize = try vmByte();
    const b2: usize = try vmByte();
    const b1: usize = try vmByte();
    const b0: usize = try vmByte();
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
}

pub fn pushTempRoot(v: Value) !void {
    if (vmState().temp_root_top >= MaxTempRoots) return error.BadTempRootDiscipline;
    vmState().temp_roots[vmState().temp_root_top] = v;
    vmState().temp_root_top += 1;
}

pub fn popTempRoot() void {
    if (vmState().temp_root_top > 0) vmState().temp_root_top -= 1;
}

pub fn tempRootDepth() usize {
    return vmState().temp_root_top;
}

pub fn assertNoTempRoots(comptime context: []const u8) void {
    if (comptime builtin.mode != .Debug) return;
    if (vmState().temp_root_top == 0) return;
    std.debug.panic("temp root leak after {s}: depth={d}", .{ context, vmState().temp_root_top });
}

pub fn assertTempRootDepth(expected: usize, comptime context: []const u8) void {
    if (comptime builtin.mode != .Debug) return;
    if (vmState().temp_root_top == expected) return;
    std.debug.panic("temp root depth mismatch after {s}: expected {d}, found {d}", .{ context, expected, vmState().temp_root_top });
}

pub fn pushObjectTempRoots(values: []const Value) !usize {
    const base = vmState().temp_root_top;
    for (values) |value| {
        if (value == .object) try pushTempRoot(value);
    }
    return base;
}

pub fn restoreTempRoots(base: usize) void {
    vmState().temp_root_top = base;
}

pub fn vmConst() !Value {
    const idx = try vmShort();
    if (idx >= chunk.constCount()) return error.InvalidChunkShape;
    return chunk.constAt(idx) catch unreachable;
}

fn valToFloatIndex(v: Value) !f64 {
    const n: f64 = switch (v) {
        .int => |x| @floatFromInt(x),
        .decimal => |x| @floatFromInt(x),
        .rune => |x| @floatFromInt(x),
        else => return error.TypeError,
    };
    if (n < 0) return error.IndexOutOfBounds;
    const f = @trunc(n);
    if (f != n) return error.TypeError;
    if (f > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.IndexOutOfBounds;
    return f;
}

pub fn vmIndexFromVal(v: Value) !usize {
    return @intFromFloat(try valToFloatIndex(v));
}

pub fn vmSliceIndex(v: Value, upper: usize) !usize {
    const idx: usize = @intFromFloat(try valToFloatIndex(v));
    if (idx > upper) return error.IndexOutOfBounds;
    return idx;
}

fn unwrapNamed(v: Value) Value {
    return switch (v) {
        .object => |o| switch (o.*) {
            .named_value => |nv| unwrapNamed(nv.value),
            else => v,
        },
        else => v,
    };
}

pub fn valueAsNumber(v: Value) !f64 {
    return switch (unwrapNamed(v)) {
        .int => |n| @floatFromInt(n),
        .float => |n| n,
        .rune => |r| @floatFromInt(r),
        else => error.TypeError,
    };
}

pub fn valueAsDecimal(v: Value) !i64 {
    return switch (unwrapNamed(v)) {
        .decimal => |d| d,
        else => error.TypeError,
    };
}

pub fn valueAsInt(v: Value) !i64 {
    return switch (unwrapNamed(v)) {
        .int => |n| n,
        .rune => |r| @intCast(r),
        else => error.TypeError,
    };
}

pub fn unboxNamed(v: Value) Value {
    if (v == .object and v.object.* == .named_value) return v.object.named_value.value;
    return v;
}

pub fn unboxCell(v: Value) Value {
    if (v == .object and v.object.* == .cell) return v.object.cell.value;
    return v;
}

// Object classification helpers used by GC, map ops, native fns, and the exec loop.

pub fn isStringValue(v: Value) bool {
    if (v == .string) return true;
    if (v == .object) {
        return switch (v.object.*) {
            .dyn_string, .string_view => true,
            else => false,
        };
    }
    return false;
}

pub fn isArrayObject(obj: *Object) bool {
    return switch (obj.*) {
        .array, .array_managed, .array_view, .array_capacity => true,
        else => false,
    };
}

pub fn asArraySlice(obj: *Object) ![]Value {
    return switch (obj.*) {
        .array => |s| s,
        .array_managed => |s| s,
        .array_view => |v| v.items,
        .array_capacity => |a| a.backing.array_managed[0..a.len],
        else => error.TypeError,
    };
}

pub fn cloneArraySlice(obj: *Object) ![]Value {
    const items = try asArraySlice(obj);
    if (items.len == 0) return &[_]Value{};
    const out = heap.allocManagedSlice(Value, items.len) orelse return error.OutOfMemory;
    @memcpy(out[0..items.len], items);
    return out[0..items.len];
}

pub fn isMapObject(obj: *Object) bool {
    return switch (obj.*) {
        .map, .map_managed, .map_hashed => true,
        else => false,
    };
}

pub fn asMapSlice(obj: *Object) ![]MapEntry {
    return switch (obj.*) {
        .map => |s| s,
        .map_managed => |s| s,
        .map_hashed => |hm| hm.entries[0..hm.len],
        else => error.TypeError,
    };
}

pub fn asStringValue(v: Value) ![]const u8 {
    if (v == .string) return v.string.bytes;
    if (v == .object) {
        return switch (v.object.*) {
            .dyn_string => |s| s,
            .string_view => |sv| sv.bytes,
            .named_value => |nv| {
                if (nv.typ.* == .named_type and nv.typ.named_type.base == .string)
                    return asStringValue(nv.value);
                return error.TypeError;
            },
            else => error.TypeError,
        };
    }
    return error.TypeError;
}

// ── .string immortality invariant debug check ───────────────────────────────

/// Debug-build tripwire for the `.string` immortality invariant (see the
/// Value doc comment in value.zig): panics if a `.string` points into a
/// known-volatile region (VM stack, fmt_scratch buffer). Conservative — it
/// cannot prove immortality, only reject the volatile ranges we know.
/// No-op in release builds. Called from vmPush so every value entering the
/// stack is screened.
pub fn assertStringImmortal(v: Value) void {
    if (builtin.mode != .Debug) return;
    if (v != .string) return;
    const s = v.string.bytes;
    if (s.len == 0) return;
    const ptr = @intFromPtr(s.ptr);

    // 1. Reject pointers into the VM stack.
    const stack = vmState().stack;
    if (stack.len > 0) {
        const stack_base = @intFromPtr(stack.ptr);
        const stack_end = stack_base + stack.len * @sizeOf(Value);
        if (ptr >= stack_base and ptr < stack_end) {
            std.debug.panic(".string value points into VM stack: {x}..{x}\n", .{ ptr, ptr + s.len });
        }
    }

    // 2. Reject pointers into the fmt_scratch buffer.
    const scratch = &vmState().fmt_scratch;
    const scratch_base = @intFromPtr(&scratch[0]);
    const scratch_end = scratch_base + scratch.len;
    if (ptr >= scratch_base and ptr < scratch_end) {
        std.debug.panic(".string value points into fmt_scratch buffer: {x}..{x}\n", .{ ptr, ptr + s.len });
    }
}
