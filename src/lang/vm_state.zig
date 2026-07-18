const std = @import("std");
const chunk = @import("chunk.zig");
const heap = @import("../runtime/heap.zig");
const cfg = @import("../runtime/config.zig");
const globals_mod = @import("globals.zig");
const vmod = @import("value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const builtin = @import("builtin");
const regexp_mod = @import("native/regexp.zig");

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
    // Code, stack, and defer depths are bounded well below 4 GiB; storing them
    // as u32 cuts per-frame footprint without changing semantics.
    ret_ip: u32,
    base: u32,
    defer_base: u32,
    has_typed_returns: bool,
    named_return_count: u8,
    func_arity: u8,
    closure: ?*Object,
    func_obj: *Object,
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
    // Frame depth at which runInner should stop and return to the host
    // (re-entrant calls: engine call API, predicates, deferred calls).
    // maxInt means "no target" — frame_top can never reach it, so the hot
    // return path needs only a single integer compare, no optional unwrap.
    call_depth_target: usize = std.math.maxInt(usize),
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
    panic_path: [chunk.MaxModuleSourcePath]u8 = undefined,
    panic_path_len: u8 = 0,
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
    // Per-runtime native caches: the singleton type objects point into this
    // runtime's heap, and the regexp pattern cache is keyed by pattern pointers
    // owned by this runtime. Cleared in reset() so a reused State never hands
    // out objects from a previous heap.
    arg_type_cache: ?*Object = null,
    jv_type_cache: ?*Object = null,
    time_type_cache: ?*Object = null,
    regexp_type_cache: ?*Object = null,
    re_pattern_cache: regexp_mod.PatternCache = .{},
    // Backing for native_function Objects, indexed by NativeFnId discriminant
    // (enum(u8), so 256 slots). Outside the GC-managed heap: never marked,
    // never swept, never moved by compaction. buildStdModule refreshes the
    // slots it uses, so no reset is needed.
    native_fn_backing: [256]Object = undefined,
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

    pub fn reset(self: *State) void {
        if (self.stack.len == 0 and self == &g_default_state) {
            _ = g_default_state.init(MaxStack, MaxFrames, cfg.max_defers, heap.HeapSize, self.allocator) catch {};
        }
        self.resetExec();
        self.std_module = null;
        self.host_checked = false;
        self.host_caps = 0;
        self.next_gc_objects = 256;
        self.next_gc_heap_bytes = if (self.configured_heap_size > 0) self.configured_heap_size / 2 else heap.HeapSize / 2;
        self.rune_cache_ptr = 0;
        self.rune_cache_byte_len = 0;
        self.rune_cache_rune_len = 0;
        self.rune_cache_valid = false;
        self.rune_cache_overflow = false;
        self.gc_runs = 0;
        self.gc_time_ns = 0;
        self.alloc_object_calls = 0;
        self.alloc_managed_slice_calls = 0;
        self.alloc_managed_bytes_calls = 0;
        self.arg_type_cache = null;
        self.jv_type_cache = null;
        self.time_type_cache = null;
        self.regexp_type_cache = null;
        self.re_pattern_cache.clear();
    }

    // Reset only execution state; preserve globals, heap, GC objects, and std_module.
    // Used by the REPL to run successive lines with shared state.
    pub fn resetExec(self: *State) void {
        self.stack_top = 0;
        self.ip = 0;
        self.frame_top = 0;
        self.call_depth_target = std.math.maxInt(usize);
        self.temp_root_top = 0;
        self.defer_top = 0;
        self.ops_budget_remaining = std.math.maxInt(u64);
        self.panic_line = 0;
        self.panic_col = 0;
        self.panic_path_len = 0;
        self.panic_depth = 0;
        self.is_panicking = false;
        self.panic_value = .null;
        self.recovered = false;
        self.pending_panic_message = null;
        self.has_pending_panic_value = false;
        self.runtime_err_len = 0;
    }

    pub fn setRuntimeErr(self: *State, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.runtime_err_buf, fmt, args) catch return;
        self.runtime_err_len = @intCast(s.len);
    }

    pub fn runtimeErrMsg(self: *State) []const u8 {
        return self.runtime_err_buf[0..self.runtime_err_len];
    }

    pub fn setPolicy(self: *State, policy: Policy) void {
        self.policy = policy;
        self.ops_budget_remaining = policy.max_ops orelse std.math.maxInt(u64);
    }

    fn currentIpIdx(self: *State, cs: *const chunk.State) usize {
        const len = cs.codeLen();
        if (len == 0) return 0;
        return if (self.ip == 0) 0 else @min(self.ip - 1, len - 1);
    }

    pub fn currentLine(self: *State, cs: *const chunk.State) u32 {
        return cs.lineAt(self.currentIpIdx(cs));
    }

    pub fn currentCol(self: *State, cs: *const chunk.State) u16 {
        return cs.colAt(self.currentIpIdx(cs));
    }

    pub fn panicLine(self: *State) u32 {
        return self.panic_line;
    }

    pub fn panicCol(self: *State) u16 {
        return self.panic_col;
    }

    pub fn panicPath(self: *const State) []const u8 {
        return self.panic_path[0..self.panic_path_len];
    }

    pub fn panicFrames(self: *State) []const PanicFrame {
        return self.panic_frames[0..self.panic_depth];
    }

    pub inline fn vmPush(self: *State, v: Value) !void {
        self.assertStringImmortal(v);
        if (self.stack_top >= self.stack.len) return error.StackOverflow;
        self.stack[self.stack_top] = v;
        self.stack_top += 1;
    }

    pub inline fn vmPop(self: *State) !Value {
        if (self.stack_top == 0) return error.StackUnderflow;
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    // Unchecked stack ops. Safe ONLY inside a frame whose entry passed the
    // verifier-proved max_stack capacity check (enterFunctionFrame*/run), and
    // only in opcode handlers whose stackEffect fully accounts the transient
    // peak — pops must precede pushes within the op. Call-internal pushes
    // (callee + args beyond the op's net effect) must use the checked vmPush.
    pub inline fn vmPushU(self: *State, v: Value) void {
        self.assertStringImmortal(v);
        self.stack.ptr[self.stack_top] = v;
        self.stack_top +%= 1;
    }

    pub inline fn vmPopU(self: *State) Value {
        self.stack_top -%= 1;
        return self.stack.ptr[self.stack_top];
    }

    pub inline fn vmPeek(self: *State, dist: usize) !Value {
        if (dist >= self.stack_top) return error.StackUnderflow;
        return self.stack[self.stack_top - 1 - dist];
    }

    // Unchecked stack read for native dispatch — safe after arity has been verified.
    pub inline fn vmTop(self: *State, dist: usize) Value {
        return self.stack[self.stack_top - 1 - dist];
    }

    // Pop all arguments of a native call: argc user args plus the function object.
    // Safe to call unchecked after arity has been verified.
    pub inline fn vmPopArgs(self: *State, argc: u8) void {
        self.stack_top -= @as(usize, argc) + 1;
    }

    pub fn pushTempRoot(self: *State, v: Value) !void {
        if (self.temp_root_top >= MaxTempRoots) return error.BadTempRootDiscipline;
        self.temp_roots[self.temp_root_top] = v;
        self.temp_root_top += 1;
    }

    pub fn popTempRoot(self: *State) void {
        if (self.temp_root_top > 0) self.temp_root_top -= 1;
    }

    pub fn tempRootDepth(self: *State) usize {
        return self.temp_root_top;
    }

    pub fn assertNoTempRoots(self: *State, comptime context: []const u8) void {
        if (comptime builtin.mode != .Debug) return;
        if (self.temp_root_top == 0) return;
        std.debug.panic("temp root leak after {s}: depth={d}", .{ context, self.temp_root_top });
    }

    pub fn assertTempRootDepth(self: *State, expected: usize, comptime context: []const u8) void {
        if (comptime builtin.mode != .Debug) return;
        if (self.temp_root_top == expected) return;
        std.debug.panic("temp root depth mismatch after {s}: expected {d}, found {d}", .{ context, expected, self.temp_root_top });
    }

    pub fn pushObjectTempRoots(self: *State, values: []const Value) !usize {
        const base = self.temp_root_top;
        for (values) |value| {
            if (value == .object) try self.pushTempRoot(value);
        }
        return base;
    }

    pub fn restoreTempRoots(self: *State, base: usize) void {
        self.temp_root_top = base;
    }

    // ── .string immortality invariant debug check ───────────────────────────────

    /// Debug-build tripwire for the `.string` immortality invariant (see the
    /// Value doc comment in value.zig): panics if a `.string` points into a
    /// known-volatile region (VM stack, fmt_scratch buffer). Conservative — it
    /// cannot prove immortality, only reject the volatile ranges we know.
    /// No-op in release builds. Called from vmPush so every value entering the
    /// stack is screened.
    pub fn assertStringImmortal(self: *State, v: Value) void {
        if (builtin.mode != .Debug) return;
        if (v != .string) return;
        const s = v.string.bytes;
        if (s.len == 0) return;
        const ptr = @intFromPtr(s.ptr);

        // 1. Reject pointers into the VM stack.
        const stack = self.stack;
        if (stack.len > 0) {
            const stack_base = @intFromPtr(stack.ptr);
            const stack_end = stack_base + stack.len * @sizeOf(Value);
            if (ptr >= stack_base and ptr < stack_end) {
                std.debug.panic(".string value points into VM stack: {x}..{x}\n", .{ ptr, ptr + s.len });
            }
        }

        // 2. Reject pointers into the fmt_scratch buffer.
        const scratch = &self.fmt_scratch;
        const scratch_base = @intFromPtr(&scratch[0]);
        const scratch_end = scratch_base + scratch.len;
        if (ptr >= scratch_base and ptr < scratch_end) {
            std.debug.panic(".string value points into fmt_scratch buffer: {x}..{x}\n", .{ ptr, ptr + s.len });
        }
    }
};

var g_default_state: State = .{};
threadlocal var g_state: *State = &g_default_state;

pub inline fn vmState() *State {
    return g_state;
}

pub fn setActive(state: *State) void {
    if (state.stack.len == 0 and state == &g_default_state) {
        _ = state.init(MaxStack, MaxFrames, cfg.max_defers, heap.HeapSize, state.allocator) catch {};
    }
    g_state = state;
}

pub fn reset() void {
    return g_state.reset();
}

pub fn setPolicy(policy: Policy) void {
    return g_state.setPolicy(policy);
}

pub fn tempRootDepth() usize {
    return g_state.tempRootDepth();
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

pub fn cloneArraySlice(ctx: VMContext, obj: *Object) ![]Value {
    const items = try asArraySlice(obj);
    if (items.len == 0) return &[_]Value{};
    const out = ctx.hs.allocManagedSlice(Value, items.len) orelse return error.OutOfMemory;
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

/// Explicit execution context carrying all four state pointers.
pub const VMContext = struct {
    cs: *chunk.State,
    gs: *globals_mod.State,
    hs: *heap.State,
    vs: *State,

    pub fn fromActive() VMContext {
        return .{
            .cs = chunk.g_state,
            .gs = globals_mod.activeState(),
            .hs = heap.g_state,
            .vs = g_state,
        };
    }
};
