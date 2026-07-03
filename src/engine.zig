const std = @import("std");
const builtin = @import("builtin");
const build_opts = @import("build_options");
const api = @import("runtime/api.zig");
const heap = @import("runtime/heap.zig");
const host_abi = @import("runtime/host_abi.zig");
const io = @import("runtime/io.zig");
const module_compile = @import("lang/module_compile.zig");
const vm = @import("lang/vm.zig");
const vms = @import("lang/vm_state.zig");
const vmgc = @import("lang/vm_gc.zig");
const net_state = @import("lang/native/net_state.zig");
const http_state = @import("lang/native/http_state.zig");
const fs_state = @import("lang/native/fs_state.zig");
const package_state = @import("lang/native/package_state.zig");
const cfg = @import("runtime/config.zig");
const vmod = @import("lang/value.zig");
const Value = vmod.Value;
const staticSS = vmod.staticSS;
const chunk = @import("lang/chunk.zig");
const Object = @import("lang/value.zig").Object;
const MapEntry = @import("lang/value.zig").MapEntry;
const ValueWire = host_abi.ValueWire;
const WireTag = host_abi.WireTag;

const is_wasm = builtin.target.cpu.arch == .wasm32;
// Signals host_abi that gengo_native_call should be emitted as a WASM import.
// Controlled by the `gengo_host` build option so engine-minimal (and similar
// no-host-module builds) produce a WASM without a gengo_host import section entry.
pub const is_embedded_engine = build_opts.gengo_host;
// On WASM all pointers are 32-bit offsets into linear memory; on native they are
// full-width host pointers.  All exported functions use PtrInt for pointer params
// so the C header can declare them as `const char *` / `void *` on both targets.
const PtrInt = if (is_wasm) i32 else usize;
const WriteCallback = *const fn (ptr: [*]const u8, len: i32, is_stderr: i32) callconv(.c) void;
const ReadCallback = *const fn (ptr: [*]u8, max_len: i32, is_line: i32) callconv(.c) i32;
const TraceFn = io.TraceFn;
const GlobalsCallback = *const fn (?*anyopaque, [*]const u8, i32, *const ValueWire) callconv(.c) void;
const FunctionsCallback = *const fn (?*anyopaque, [*]const u8, i32, i32) callconv(.c) void;

// Active-engine state — set for the duration of engine_run / engine_call so that
// write/read callbacks and capability handlers resolve to the calling engine's
// per-instance configuration rather than a process-global slot.
var g_active_engine: ?*Engine = null;

// Process-global active slots — overwritten by pushCapState before each
// engine_run / engine_call and cleared by popCapState on return.
var write_callback: ?WriteCallback = null;
var read_callback: ?ReadCallback = null;

const ImportLoaderFn = *const fn (
    ctx: ?*anyopaque,
    path_ptr: PtrInt,
    path_len: i32,
    out_ptr: PtrInt,
    out_max_len: i32,
) callconv(.c) i32;

const WriteImpl = if (is_wasm) struct {
    extern "env" fn gengo_write(ptr: [*]const u8, len: i32, is_stderr: i32) void;
    pub fn write(ptr: [*]const u8, len: i32, is_stderr: i32) void {
        gengo_write(ptr, len, is_stderr);
    }
} else struct {
    pub fn write(ptr: [*]const u8, len: i32, is_stderr: i32) void {
        if (write_callback) |cb| {
            cb(ptr, len, is_stderr);
        } else {
            io.writeAllFd(if (is_stderr != 0) 2 else 1, ptr[0..@intCast(len)]);
        }
    }
};

const ReadImpl = if (is_wasm) struct {
    extern "env" fn gengo_read(ptr: [*]u8, max_len: i32, is_line: i32) i32;
    pub fn read(buf: []u8, is_line: bool) isize {
        return @intCast(gengo_read(buf.ptr, @intCast(buf.len), if (is_line) 1 else 0));
    }
} else struct {
    pub fn read(buf: []u8, is_line: bool) isize {
        if (read_callback) |cb| return @intCast(cb(buf.ptr, @intCast(buf.len), if (is_line) 1 else 0));
        return io.readBytesRaw(buf, is_line);
    }
};

fn engineWrite(s: []const u8) void {
    WriteImpl.write(s.ptr, @intCast(s.len), 0);
}

fn engineWerr(s: []const u8) void {
    WriteImpl.write(s.ptr, @intCast(s.len), 1);
}

fn engineRead(buf: []u8, is_line: bool) isize {
    return ReadImpl.read(buf, is_line);
}

const MaxEngines = 64;
const MaxSources = 64;
const MaxHostModules = 16;
const MaxHostModuleFuncs = 64;
const MaxErrorLen = 512;
const MaxStringScratch = 4096;
const MaxImportScratch = 16384;
const HostModuleCallIdBase = 0x1000;

// Init-time error buffer: populated when engine_init_with_config fails validation.
var g_init_error: [MaxErrorLen]u8 = undefined;
var g_init_error_len: u16 = 0;

fn setInitError(msg: []const u8) void {
    const len = @min(msg.len, g_init_error.len);
    @memcpy(g_init_error[0..len], msg[0..len]);
    g_init_error_len = @intCast(len);
}

const SourceEntry = struct {
    path: []const u8,
    src: []const u8,
};

const HostModuleFuncDef = struct {
    name_ptr: PtrInt,
    name_len: u32,
    arity: u32,
};

const HostModuleEntry = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    funcs: [MaxHostModuleFuncs]module_compile.HostModuleFuncDesc = undefined,
    func_count: u8 = 0,
};

// Explicit active flag avoids ?Engine optional which would require a large
// stack temporary when assigning — the Runtime inside Engine is too large
// for the WASM shadow stack (see runtime.zig initWithPolicy comment).
const EngineSlot = struct {
    active: bool = false,
    engine: Engine = undefined,
};
var engine_slots: [MaxEngines]EngineSlot = [_]EngineSlot{.{}} ** MaxEngines;

const Engine = struct {
    runtime: api.Runtime,
    // Per-engine capability state — applied to the process globals during
    // engine_run / engine_call via pushCapState / popCapState.
    write_callback: ?WriteCallback = null,
    read_callback: ?ReadCallback = null,
    net_handlers: ?net_state.HandlerSet = null,
    net_policy: net_state.PolicyState = .{},
    http_handler: ?http_state.HandlerSet = null,
    fs_state: fs_state.EngineState = .{},
    source_entries: [MaxSources]api.SourceEntry = undefined,
    source_count: u8 = 0,
    path_bufs: [MaxSources][256]u8 = undefined,
    src_bufs: [MaxSources][4096]u8 = undefined,
    host_module_entries: [MaxHostModules]HostModuleEntry = undefined,
    host_module_count: u8 = 0,
    next_host_call_id: u16 = HostModuleCallIdBase,
    // Owned copies of HostModuleDesc for passing to runtime
    host_module_descs: [MaxHostModules]module_compile.HostModuleDesc = undefined,
    host_module_func_name_bufs: [MaxHostModules][MaxHostModuleFuncs][64]u8 = undefined,
    host_module_func_name_lens: [MaxHostModules][MaxHostModuleFuncs]usize = undefined,
    last_error: [MaxErrorLen]u8 = undefined,
    last_error_len: u16 = 0,
    last_error_line: u32 = 0,
    last_error_col: u32 = 0,
    string_scratch: [MaxStringScratch]u8 = undefined,
    string_scratch_len: u16 = 0,
    wire_elem_buf: [256]ValueWire = undefined,
    wire_elem_count: u16 = 0,
    import_loader_fn: ?ImportLoaderFn = null,
    import_loader_ctx: ?*anyopaque = null,
    import_scratch: [MaxImportScratch]u8 = undefined,
    trace_fn: ?TraceFn = null,
    trace_userdata: ?*anyopaque = null,
    package_registry: package_state.PackageRegistry = .{},

    fn initScalars(self: *Engine) void {
        self.source_count = 0;
        self.host_module_count = 0;
        self.next_host_call_id = HostModuleCallIdBase;
        self.last_error_len = 0;
        self.last_error_line = 0;
        self.last_error_col = 0;
        self.string_scratch_len = 0;
        self.wire_elem_count = 0;
        self.write_callback = null;
        self.read_callback = null;
        self.net_handlers = null;
        self.net_policy = .{};
        self.http_handler = null;
        self.fs_state = .{};
        self.import_loader_fn = null;
        self.import_loader_ctx = null;
        self.trace_fn = null;
        self.trace_userdata = null;
        package_state.clearRegistry(&self.package_registry);
    }

    fn initInPlaceDefault(self: *Engine) !void {
        self.initScalars();
        try self.runtime.initWithPolicy(.{ .allow_io = true });
        io.setWriteOverrides(engineWrite, engineWerr);
        io.setReadOverride(engineRead);
    }

    fn initInPlaceWithConfig(self: *Engine, ic: InstanceConfig) !void {
        self.initScalars();
        const max_ops: ?u64 = if (ic.max_ops < 0) null else @intCast(ic.max_ops);
        try self.runtime.inner.initWithConfig(
            .{ .allow_io = ic.allow_io, .max_ops = max_ops },
            ic.heap_size_bytes,
            ic.max_objects,
            ic.max_stack,
            ic.max_frames,
            ic.max_defers,
            std.heap.page_allocator,
        );
        io.setWriteOverrides(engineWrite, engineWerr);
        io.setReadOverride(engineRead);
    }

    fn deinitInPlace(self: *Engine) void {
        package_state.clearRegistry(&self.package_registry);
        self.runtime.inner.deinit();
    }

    fn setError(self: *Engine, msg: []const u8) void {
        const len = @min(msg.len, self.last_error.len);
        @memcpy(self.last_error[0..len], msg[0..len]);
        self.last_error_len = @intCast(len);
    }

    fn clearError(self: *Engine) void {
        self.last_error_len = 0;
        self.last_error_line = 0;
        self.last_error_col = 0;
    }

    fn setCompileError(self: *Engine, e: api.CompileError) void {
        self.last_error_line = e.line;
        self.last_error_col = e.col;
        const s = if (e.kind == error.OutOfMemory)
            std.fmt.bufPrint(&self.last_error, "compilation failed: {s}", .{e.msg}) catch ""
        else
            std.fmt.bufPrint(&self.last_error, "compile error: {s}: {s}", .{@errorName(e.kind), e.msg}) catch "";
        self.last_error_len = @intCast(s.len);
    }

    fn setRuntimeError(self: *Engine, e: api.RuntimeError) void {
        self.last_error_line = e.line;
        self.last_error_col = e.col;
        const s = if (e.kind == error.OutOfMemory)
            std.fmt.bufPrint(&self.last_error, "panic: {s}", .{e.msg}) catch ""
        else
            std.fmt.bufPrint(&self.last_error, "panic: {s}: {s}", .{@errorName(e.kind), e.msg}) catch "";
        self.last_error_len = @intCast(s.len);
    }

    fn setStringScratch(self: *Engine, data: []const u8) []const u8 {
        const len = @min(@as(usize, @intCast(data.len)), self.string_scratch.len);
        @memcpy(self.string_scratch[0..len], data[0..len]);
        self.string_scratch_len = @intCast(len);
        return self.string_scratch[0..len];
    }
};

fn importLoaderWrapper(ctx: *anyopaque, path: []const u8) anyerror!?[]const u8 {
    const engine: *Engine = @ptrCast(@alignCast(ctx));

    if (engine.import_loader_fn) |cb| {
        const p: PtrInt = @intCast(@intFromPtr(path.ptr));
        const s: PtrInt = @intCast(@intFromPtr(&engine.import_scratch));
        const result = cb(
            engine.import_loader_ctx,
            p,
            @intCast(path.len),
            s,
            @intCast(engine.import_scratch.len),
        );
        if (result > 0) {
            const written = @as(usize, @intCast(result));
            if (written > engine.import_scratch.len) return error.ImportLoaderFailed;
            return engine.import_scratch[0..written];
        }
        if (result < 0) return error.ImportLoaderFailed;
    }

    if (package_state.resolve(&engine.package_registry, path)) |src| return src;

    for (engine.source_entries[0..engine.source_count]) |entry| {
        if (std.mem.eql(u8, path, entry.path)) return entry.source;
    }
    return null;
}

fn sourceProviderFromLoader(engine: *Engine) ?api.SourceProvider {
    if (engine.import_loader_fn == null and engine.package_registry.count == 0) return null;
    return api.SourceProvider{ .callback = .{
        .ctx = engine,
        .load = importLoaderWrapper,
    }};
}

fn getEngine(handle: i32) ?*Engine {
    if (handle <= 0 or handle > MaxEngines) return null;
    const idx = @as(usize, @intCast(handle - 1));
    if (!engine_slots[idx].active) return null;
    return &engine_slots[idx].engine;
}

fn engineToHandle(engine: *const Engine) i32 {
    for (&engine_slots, 0..) |*slot, i| {
        if (&slot.engine == engine) return @intCast(i + 1);
    }
    return -1;
}

// Push the engine's per-instance capability state into the process globals so
// that write/read hooks and capability modules use this engine's configuration.
// Returns the previous active engine for restore (supports future re-entrancy).
fn pushCapState(engine: *Engine) ?*Engine {
    const prev = g_active_engine;
    g_active_engine = engine;
    write_callback = engine.write_callback;
    read_callback = engine.read_callback;
    net_state.applyHandlers(engine.net_handlers);
    net_state.applyPolicy(engine.net_policy);
    http_state.applyHandler(engine.http_handler);
    fs_state.loadFromEngine(&engine.fs_state);
    io.setTrace(engine.trace_fn, engine.trace_userdata, engineToHandle(engine));
    return prev;
}

// Restore the process globals to the previous engine's state (or clear them).
fn popCapState(prev: ?*Engine) void {
    if (prev) |p| {
        g_active_engine = p;
        write_callback = p.write_callback;
        read_callback = p.read_callback;
        net_state.applyHandlers(p.net_handlers);
        net_state.applyPolicy(p.net_policy);
        http_state.applyHandler(p.http_handler);
        fs_state.loadFromEngine(&p.fs_state);
        io.setTrace(p.trace_fn, p.trace_userdata, engineToHandle(p));
        p.runtime.inner.activate();
    } else {
        g_active_engine = null;
        write_callback = null;
        read_callback = null;
        net_state.applyHandlers(null);
        net_state.clearPolicy();
        http_state.applyHandler(null);
        fs_state.clearMounts();
        io.clearTrace();
    }
}

fn wasmSlice(ptr: PtrInt, len: i32) []const u8 {
    if (len <= 0 or ptr == 0) return "";
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(ptr))))[0..@as(usize, @intCast(len))];
}

fn wasmSliceMut(ptr: PtrInt, len: i32) []u8 {
    if (len <= 0 or ptr == 0) return "";
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(ptr))))[0..@as(usize, @intCast(len))];
}

fn wireToValue(wire: ValueWire) !Value {
    return switch (wire.tag) {
        @intFromEnum(WireTag.null) => .null,
        @intFromEnum(WireTag.boolean) => Value{ .boolean = wire.payload != 0 },
        @intFromEnum(WireTag.number) => blk: {
            // flags bit 0: caller declares this as an integer, not a float.
            // flags bit 1: decimal (payload is raw i64 fixed-point).
            // flags bit 2: rune (payload is Unicode codepoint).
            const fval: f64 = @bitCast(wire.payload);
            if ((wire.flags & host_abi.FLAG_DECIMAL) != 0) {
                break :blk Value{ .decimal = @bitCast(wire.payload) };
            }
            if ((wire.flags & host_abi.FLAG_RUNE) != 0) {
                break :blk Value{ .rune = @intCast(wire.payload) };
            }
            break :blk if ((wire.flags & host_abi.FLAG_INTEGER) != 0) Value{ .int = @bitCast(wire.payload) } else Value{ .float = fval };
        },
        @intFromEnum(WireTag.@"error") => {
            if (wire.len == 0) return Value{ .error_value = try chunk.internStr("") };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0..@as(usize, @intCast(wire.len))];
            const copy = try vmgc.vmAllocManagedBytes(wire.len);
            @memcpy(copy[0..wire.len], data);
            return Value{ .error_value = try chunk.internStr(copy[0..wire.len]) };
        },
        @intFromEnum(WireTag.string) => {
            if (wire.len == 0) return Value{ .string = try chunk.internStr("") };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0..@as(usize, @intCast(wire.len))];
            return try vm.makeString(data);
        },
        @intFromEnum(WireTag.array) => {
            const count = wire.len;
            const elem_wires = @as([*]const ValueWire, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0..count];
            const arr_obj = try vmgc.allocTempRooted(.{ .array = &[_]Value{} });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(Value, count);
            for (elem_wires, 0..) |ew, i| {
                items[i] = try wireToValue(ew);
            }
            arr_obj.* = .{ .array_managed = items[0..count] };
            return .{ .object = arr_obj };
        },
        @intFromEnum(WireTag.map) => {
            const count = wire.len;
            const pair_wires = @as([*]const ValueWire, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0 .. count * 2];
            const map_obj = try vmgc.allocTempRooted(.{ .map = &[_]MapEntry{} });
            defer vms.popTempRoot();
            const entries = try vmgc.vmAllocManagedSlice(MapEntry, count);
            for (0..count) |i| {
                entries[i] = .{
                    .key = try wireToValue(pair_wires[i * 2]),
                    .value = try wireToValue(pair_wires[i * 2 + 1]),
                };
            }
            map_obj.* = .{ .map_managed = entries[0..count] };
            return .{ .object = map_obj };
        },
        else => .null,
    };
}

fn makeWire(tag: u8, payload: u64, len: u32) ValueWire {
    return .{
        .tag = tag,
        .flags = 0,
        .reserved = 0,
        .payload = payload,
        .len = len,
        .reserved2 = 0,
    };
}

fn fillArrayWires(items: []const Value, wires: []ValueWire) anyerror!void {
    for (items, 0..) |item, i| wires[i] = try valueToWire(item);
}

fn fillMapWires(entries: []const MapEntry, wires: []ValueWire) anyerror!void {
    for (entries, 0..) |entry, i| {
        wires[i * 2] = try valueToWire(entry.key);
        wires[i * 2 + 1] = try valueToWire(entry.value);
    }
}

fn valueToWire(val: Value) !ValueWire {
    return switch (val) {
        .null => makeWire(@intFromEnum(WireTag.null), 0, 0),
        .boolean => |b| makeWire(@intFromEnum(WireTag.boolean), @intFromBool(b), 0),
        .int => |n| .{ .tag = @intFromEnum(WireTag.number), .flags = host_abi.FLAG_INTEGER, .reserved = 0, .payload = @bitCast(n), .len = 0, .reserved2 = 0 },
        .float => |n| makeWire(@intFromEnum(WireTag.number), @bitCast(@as(f64, n)), 0),
        .decimal => |d| .{
            .tag = @intFromEnum(WireTag.number),
            .flags = host_abi.FLAG_DECIMAL,
            .reserved = 0,
            .payload = @as(u64, @bitCast(d)),
            .len = 0,
            .reserved2 = 0,
        },
        .rune => |r| .{
            .tag = @intFromEnum(WireTag.number),
            .flags = host_abi.FLAG_RUNE,
            .reserved = 0,
            .payload = @as(u64, r),
            .len = 0,
            .reserved2 = 0,
        },
        .string => |s| makeWire(@intFromEnum(WireTag.string), @intFromPtr(s.bytes.ptr), @intCast(s.bytes.len)),
        .error_value => |msg| makeWire(@intFromEnum(WireTag.@"error"), @intFromPtr(msg.bytes.ptr), @intCast(msg.bytes.len)),
        .object => |obj| switch (obj.*) {
            .dyn_string => makeWire(@intFromEnum(WireTag.string), @intFromPtr(obj.dyn_string.ptr), @intCast(obj.dyn_string.len)),
            .string_view => makeWire(@intFromEnum(WireTag.string), @intFromPtr(obj.string_view.bytes.ptr), @intCast(obj.string_view.bytes.len)),
            .array, .array_managed, .array_capacity => {
                const items = try vms.asArraySlice(obj);
                const wires = (heap.bump(ValueWire, items.len) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0..items.len];
                try fillArrayWires(items, wires);
                return makeWire(@intFromEnum(WireTag.array), @intFromPtr(wires.ptr), @intCast(items.len));
            },
            .map, .map_managed, .map_hashed => {
                const entries = try vms.asMapSlice(obj);
                const wires = (heap.bump(ValueWire, entries.len * 2) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0 .. entries.len * 2];
                try fillMapWires(entries, wires);
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(entries.len));
            },
            .struct_instance => {
                const entries = obj.struct_instance.fields;
                const wires = (heap.bump(ValueWire, entries.len * 2) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0 .. entries.len * 2];
                try fillMapWires(entries, wires);
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(entries.len));
            },
            .named_value => |nv| return valueToWire(nv.value),
            .enum_value => |ev| makeWire(@intFromEnum(WireTag.string), @intFromPtr(ev.name.ptr), @intCast(ev.name.len)),
            .variant_value => |vv| {
                const vtype = vv.typ.variant_type;
                const arm_spec = vtype.arms[vv.ordinal];
                const shared_count = @min(vv.shared_values.len, vtype.shared_fields.len);
                const arm_field_count = @min(vv.arm_fields.len, arm_spec.fields.len);
                const total_entries = 2 + shared_count + arm_field_count;
                const wires = (heap.bump(ValueWire, total_entries * 2) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0..total_entries * 2];
                wires[0] = try valueToWire(.{ .string = staticSS("tag") });
                wires[1] = try valueToWire(.{ .string = try chunk.internStr(vv.tag) });
                wires[2] = try valueToWire(.{ .string = staticSS("value") });
                wires[3] = try valueToWire(vv.payload);
                var wi: usize = 2;
                for (vtype.shared_fields[0..shared_count], vv.shared_values[0..shared_count]) |spec, sv| {
                    wires[wi * 2] = try valueToWire(.{ .string = try chunk.internStr(spec.name) });
                    wires[wi * 2 + 1] = try valueToWire(sv);
                    wi += 1;
                }
                for (arm_spec.fields[0..arm_field_count], vv.arm_fields[0..arm_field_count]) |spec, af| {
                    wires[wi * 2] = try valueToWire(.{ .string = try chunk.internStr(spec.name) });
                    wires[wi * 2 + 1] = try valueToWire(af);
                    wi += 1;
                }
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(total_entries));
            },
            else => return error.UnsupportedWireType,
        },
    };
}

fn valueToWireWithScratch(val: Value, scratch: *Engine) !ValueWire {
    switch (val) {
        .string => |s| {
            const stable = scratch.setStringScratch(s.bytes);
            return makeWire(@intFromEnum(WireTag.string), @intFromPtr(stable.ptr), @intCast(stable.len));
        },
        .object => |obj| switch (obj.*) {
            .dyn_string => {
                const s = obj.dyn_string;
                const stable = scratch.setStringScratch(s);
                return makeWire(@intFromEnum(WireTag.string), @intFromPtr(stable.ptr), @intCast(stable.len));
            },
            .string_view => {
                const s = obj.string_view.bytes;
                const stable = scratch.setStringScratch(s);
                return makeWire(@intFromEnum(WireTag.string), @intFromPtr(stable.ptr), @intCast(stable.len));
            },
            .array, .array_managed, .array_capacity => {
                const items = try vms.asArraySlice(obj);
                if (items.len > scratch.wire_elem_buf.len) return error.WireBufferOverflow;
                const wires = &scratch.wire_elem_buf;
                scratch.wire_elem_count = @intCast(items.len);
                try fillArrayWires(items, wires);
                return makeWire(@intFromEnum(WireTag.array), @intFromPtr(wires.ptr), @intCast(items.len));
            },
            .map, .map_managed, .map_hashed => {
                const entries = try vms.asMapSlice(obj);
                const max_entries = scratch.wire_elem_buf.len / 2;
                if (entries.len > max_entries) return error.WireBufferOverflow;
                const wires = &scratch.wire_elem_buf;
                scratch.wire_elem_count = @intCast(entries.len * 2);
                try fillMapWires(entries, wires);
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(entries.len));
            },
            .struct_instance => {
                const entries = obj.struct_instance.fields;
                const max_entries = scratch.wire_elem_buf.len / 2;
                if (entries.len > max_entries) return error.WireBufferOverflow;
                const wires = &scratch.wire_elem_buf;
                scratch.wire_elem_count = @intCast(entries.len * 2);
                try fillMapWires(entries, wires);
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(entries.len));
            },
            else => return try valueToWire(val),
        },
        else => return try valueToWire(val),
    }
}

pub const InstanceConfig = extern struct {
    heap_size_bytes: usize,
    max_objects: usize,
    max_stack: usize,
    max_frames: usize,
    max_defers: usize,
    max_ops: i64, // -1 means null (unlimited)
    allow_io: bool,
};

fn validateCeiling(name: []const u8, requested: usize, ceiling: usize) bool {
    if (requested > ceiling) {
        const s = std.fmt.bufPrint(&g_init_error, "config exceeds preset ceiling: {s} ({d} > {d})", .{ name, requested, ceiling }) catch "";
        g_init_error_len = @intCast(s.len);
        return false;
    }
    return true;
}

// Dereference into a real array so the export hands out a pointer to the
// bytes, not to a slice descriptor.
const engine_version_bytes = build_opts.version[0..].* ++ [_]u8{0};

export fn gengo_engine_version() [*:0]const u8 {
    return @ptrCast(&engine_version_bytes);
}

export fn engine_init() i32 {
    g_init_error_len = 0;
    for (&engine_slots, 0..) |*slot, i| {
        if (!slot.active) {
            slot.engine.initInPlaceDefault() catch {
                setInitError("engine_init: allocation failed");
                return -4;
            };
            slot.active = true;
            return @as(i32, @intCast(i + 1));
        }
    }
    return 0;
}

export fn engine_init_with_config(config_ptr: PtrInt) i32 {
    g_init_error_len = 0;
    if (config_ptr == 0) {
        setInitError("engine_init_with_config: config pointer is null");
        return -3;
    }
    const config = @as(*const InstanceConfig, @ptrFromInt(@as(usize, @intCast(config_ptr)))).*;

    const ceiling_heap = cfg.heap_size_bytes;
    const ceiling_objects = cfg.max_objects;
    const ceiling_stack = cfg.max_stack;
    const ceiling_frames = cfg.max_frames;
    const ceiling_defers = cfg.max_defers;

    if (!validateCeiling("heap_size_bytes", config.heap_size_bytes, ceiling_heap)) return -3;
    if (!validateCeiling("max_objects", config.max_objects, ceiling_objects)) return -3;
    if (!validateCeiling("max_stack", config.max_stack, ceiling_stack)) return -3;
    if (!validateCeiling("max_frames", config.max_frames, ceiling_frames)) return -3;
    if (!validateCeiling("max_defers", config.max_defers, ceiling_defers)) return -3;

    for (&engine_slots, 0..) |*slot, i| {
        if (!slot.active) {
            slot.engine.initInPlaceWithConfig(config) catch {
                setInitError("engine_init_with_config: allocation failed");
                return -4;
            };
            slot.active = true;
            return @as(i32, @intCast(i + 1));
        }
    }
    return 0;
}

export fn engine_destroy(handle: i32) void {
    const idx = if (handle > 0 and handle <= MaxEngines) @as(usize, @intCast(handle - 1)) else return;
    engine_slots[idx].engine.deinitInPlace();
    engine_slots[idx].active = false;
    // If this was the last active engine, clear I/O overrides so the next
    // engine_init() starts clean. Capability state (net/http/fs) is already
    // per-engine and cleared by popCapState on each run/call exit.
    for (&engine_slots) |*s| {
        if (s.active) return;
    }
    io.clearWriteOverrides();
    io.clearReadOverride();
}

export fn engine_run(handle: i32, src_ptr: PtrInt, src_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    if (src_len < 0) { engine.setError("engine_run: src_len must not be negative"); return -1; }
    const src = wasmSlice(src_ptr, src_len);
    setupHostModules(engine);
    const prev = pushCapState(engine);
    defer popCapState(prev);
    const res = engine.runtime.run(src);
    return switch (res) {
        .ok => { engine.clearError(); return 0; },
        .compile_error => |e| {
            engine.setCompileError(e);
            return -1;
        },
        .runtime_error => |e| {
            engine.setRuntimeError(e);
            return -2;
        },
    };
}

export fn engine_run_path(handle: i32, src_ptr: PtrInt, src_len: i32, path_ptr: PtrInt, path_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    if (src_len < 0 or path_len < 0) { engine.setError("engine_run_path: lengths must not be negative"); return -1; }
    const src = wasmSlice(src_ptr, src_len);
    const path = wasmSlice(path_ptr, path_len);
    setupHostModules(engine);
    const prev = pushCapState(engine);
    defer popCapState(prev);
    const res = engine.runtime.runPath(src, path);
    return switch (res) {
        .ok => { engine.clearError(); return 0; },
        .compile_error => |e| {
            engine.setCompileError(e);
            return -1;
        },
        .runtime_error => |e| {
            engine.setRuntimeError(e);
            return -2;
        },
    };
}

export fn engine_call(handle: i32, name_ptr: PtrInt, name_len: i32, args_ptr: PtrInt, argc: i32, out_ptr: PtrInt) i32 {
    const engine = getEngine(handle) orelse return -1;
    const name = wasmSlice(name_ptr, name_len);
    setupHostModules(engine);
    const prev = pushCapState(engine);
    defer popCapState(prev);

    var args: [64]Value = undefined;
    if (argc < 0) {
        engine.setError("engine_call: argc must not be negative");
        return -3;
    }
    if (argc > @as(i32, args.len)) {
        engine.setError("too many arguments: engine_call supports at most 64");
        return -3;
    }
    const arg_count = @as(usize, @intCast(argc));
    if (argc > 0 and args_ptr != 0) {
        const wire_args = @as([*]const ValueWire, @ptrFromInt(@as(usize, @intCast(args_ptr))))[0..arg_count];
        for (wire_args, 0..) |wa, i| {
            args[i] = wireToValue(wa) catch {
                engine.setError("argument wire conversion failed: out of memory");
                return -2;
            };
        }
    }

    const res = engine.runtime.call(name, args[0..arg_count]);

    return switch (res) {
        .ok => |val| {
            const wire = valueToWireWithScratch(val, engine) catch |err| {
                engine.setRuntimeError(.{ .kind = err, .msg = "value cannot be serialized to wire" });
                return -2;
            };
            if (out_ptr != 0) {
                @as(*ValueWire, @ptrFromInt(@as(usize, @intCast(out_ptr)))).* = wire;
            }
            engine.clearError();
            return 0;
        },
        .runtime_error => |e| {
            engine.setRuntimeError(e);
            return -2;
        },
    };
}

export fn engine_reset(handle: i32) void {
    const engine = getEngine(handle) orelse return;
    engine.clearError();
    engine.runtime.reset();
}

export fn engine_add_source(handle: i32, path_ptr: PtrInt, path_len: i32, src_ptr: PtrInt, src_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    if (path_len < 0 or src_len < 0) return -5;
    if (engine.source_count >= MaxSources) return -3;

    const path = wasmSlice(path_ptr, path_len);
    const src = wasmSlice(src_ptr, src_len);

    if (path.len > engine.path_bufs[0].len) return -5;
    if (src.len > engine.src_bufs[0].len) return -5;

    const sc = engine.source_count;
    const path_buf = &engine.path_bufs[sc];
    const src_buf = &engine.src_bufs[sc];

    const plen = @as(usize, @intCast(path.len));
    @memcpy(path_buf[0..plen], path);
    const slen = @as(usize, @intCast(src.len));
    @memcpy(src_buf[0..slen], src);

    engine.source_entries[sc] = .{ .path = path_buf[0..plen], .source = src_buf[0..slen] };
    engine.source_count = sc + 1;

    // Use setConfig (not initWithPolicy) to update the source table without
    // discarding compiled state or leaking prior heap allocations (#13).
    engine.runtime.setConfig(.{
        .allow_io = engine.runtime.inner.policy.allow_io,
        .native_backend = engine.runtime.inner.policy.native_backend,
        .max_ops = engine.runtime.inner.policy.max_ops,
        .module_sources = engine.source_entries[0..engine.source_count],
        .module_source_provider = sourceProviderFromLoader(engine),
    });

    return 0;
}

export fn engine_set_import_loader(handle: i32, load_fn: ?ImportLoaderFn, ctx: ?*anyopaque) i32 {
    const engine = getEngine(handle) orelse return -1;
    engine.import_loader_fn = load_fn;
    engine.import_loader_ctx = ctx;
    engine.runtime.setConfig(.{
        .allow_io = engine.runtime.inner.policy.allow_io,
        .native_backend = engine.runtime.inner.policy.native_backend,
        .max_ops = engine.runtime.inner.policy.max_ops,
        .module_sources = engine.source_entries[0..engine.source_count],
        .module_source_provider = sourceProviderFromLoader(engine),
    });
    return 0;
}

fn validateModuleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '@') return false;
    for (name) |c| {
        if (c == '.') return false;
        if (c < ' ' or c > '~') return false;
    }
    return true;
}

export fn engine_register_module(handle: i32, name_ptr: PtrInt, name_len: i32, funcs_ptr: PtrInt, funcs_count: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    if (comptime !is_wasm) {
        engine.setError("host modules are not supported on native targets (WASM only)");
        return -6;
    }
    if (engine.host_module_count >= MaxHostModules) return -3;
    if (funcs_count < 0 or funcs_count > MaxHostModuleFuncs) return -4;

    const name = wasmSlice(name_ptr, name_len);
    if (!validateModuleName(name)) return -5;

    const slot = &engine.host_module_entries[engine.host_module_count];
    if (name.len > slot.name.len) return -5;
    slot.name_len = @as(usize, @intCast(name.len));
    @memcpy(slot.name[0..slot.name_len], name[0..slot.name_len]);

    if (funcs_count > 0 and funcs_ptr == 0) return -4;
    const func_defs = @as([*]const HostModuleFuncDef, @ptrFromInt(@as(usize, @intCast(funcs_ptr))))[0..@as(usize, @intCast(funcs_count))];
    for (func_defs, 0..) |fd, i| {
        const fname = wasmSlice(fd.name_ptr, @intCast(fd.name_len));
        if (fname.len > engine.host_module_func_name_bufs[engine.host_module_count][i].len) return -5;
        if (fd.arity > 255) return -4;
        const flen = @as(usize, @intCast(fname.len));
        @memcpy(engine.host_module_func_name_bufs[engine.host_module_count][i][0..flen], fname[0..flen]);
        engine.host_module_func_name_lens[engine.host_module_count][i] = flen;
        const call_id = engine.next_host_call_id;
        engine.next_host_call_id += 1;
        slot.funcs[i] = .{
            .name = engine.host_module_func_name_bufs[engine.host_module_count][i][0..flen],
            .arity = @intCast(fd.arity),
            .call_id = call_id,
        };
    }
    slot.func_count = @intCast(funcs_count);
    engine.host_module_count += 1;
    return 0;
}

fn setupHostModules(engine: *Engine) void {
    var desc_count: u8 = 0;
    while (desc_count < engine.host_module_count) : (desc_count += 1) {
        const entry = &engine.host_module_entries[desc_count];
        engine.host_module_descs[desc_count] = .{
            .name = entry.name[0..entry.name_len],
            .functions = entry.funcs[0..entry.func_count],
        };
    }
    engine.runtime.setConfig(.{
        .allow_io = engine.runtime.inner.policy.allow_io,
        .native_backend = if (desc_count > 0) .host else .embedded,
        .module_sources = engine.source_entries[0..engine.source_count],
        .module_source_provider = sourceProviderFromLoader(engine),
        .host_modules = engine.host_module_descs[0..desc_count],
        // Preserve the per-instance instruction budget set via engine_init_with_config.
        // Without this, setConfig resets policy.max_ops to null (unlimited) every run.
        .max_ops = engine.runtime.inner.policy.max_ops,
    });
}

export fn engine_last_error(handle: i32, out_ptr: PtrInt, out_max_len: i32) i32 {
    const engine = getEngine(handle);
    if (engine) |e| {
        const len = @min(@as(usize, @intCast(e.last_error_len)), @as(usize, @intCast(@max(out_max_len, 0))));
        if (len > 0 and out_ptr != 0) {
            const dest = wasmSliceMut(out_ptr, @intCast(len));
            @memcpy(dest, e.last_error[0..len]);
        }
        return e.last_error_len;
    }
    // Fall back to init-time error only when handle is the init sentinel (0).
    if (handle != 0) return 0;
    const len = @min(@as(usize, @intCast(g_init_error_len)), @as(usize, @intCast(@max(out_max_len, 0))));
    if (len > 0 and out_ptr != 0) {
        const dest = wasmSliceMut(out_ptr, @intCast(len));
        @memcpy(dest, g_init_error[0..len]);
    }
    return g_init_error_len;
}

export fn engine_last_error_line(handle: i32) i32 {
    const engine = getEngine(handle) orelse return 0;
    return @intCast(engine.last_error_line);
}

export fn engine_last_error_col(handle: i32) i32 {
    const engine = getEngine(handle) orelse return 0;
    return @intCast(engine.last_error_col);
}

export fn engine_set_write_fn(handle: i32, callback: ?WriteCallback) void {
    if (comptime is_wasm) return;
    const engine = getEngine(handle) orelse return;
    engine.write_callback = callback;
}

export fn engine_set_read_fn(handle: i32, callback: ?ReadCallback) void {
    if (comptime is_wasm) return;
    const engine = getEngine(handle) orelse return;
    engine.read_callback = callback;
}

export fn engine_set_net_handlers(handle: i32, handlers: ?*const net_state.GengoNetHandlers, userdata: ?*anyopaque) void {
    const engine = getEngine(handle) orelse return;
    engine.net_handlers = if (handlers) |h|
        .{ .callbacks = h.*, .userdata = userdata }
    else
        null;
}

export fn engine_set_http_handler(handle: i32, callback: ?http_state.GengoHttpFetchFn, userdata: ?*anyopaque) void {
    const engine = getEngine(handle) orelse return;
    engine.http_handler = if (callback) |cb|
        .{ .callback = cb, .userdata = userdata }
    else
        null;
}

/// Register a host directory as a cap:fs mount ("name" -> real path).
/// Strings are copied; the caller may free them after the call returns.
/// Returns 0 on success, -1 on invalid handle, -2 on invalid mount.
export fn engine_mount_dir(handle: i32, name_ptr: PtrInt, name_len: i32, path_ptr: PtrInt, path_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    if (name_len < 0 or path_len < 0) return -2;
    const name = wasmSlice(name_ptr, name_len);
    const path = wasmSlice(path_ptr, path_len);
    fs_state.addMountToState(&engine.fs_state, name, path) catch return -2;
    return 0;
}

/// Read a named global by value after engine_run. Writes the ValueWire
/// representation to *out_ptr. Returns 0 on success, -1 if the handle is
/// invalid, -2 if the name is not defined.
export fn engine_get_global(handle: i32, name_ptr: PtrInt, name_len: i32, out_ptr: PtrInt) i32 {
    const engine = getEngine(handle) orelse return -1;
    const name = wasmSlice(name_ptr, name_len);
    const gs = &engine.runtime.inner.globals_state;
    const val = gs.get(name) orelse return -2;
    if (out_ptr != 0) {
        const wire = valueToWireWithScratch(val, engine) catch return -3;
        @as(*ValueWire, @ptrFromInt(@as(usize, @intCast(out_ptr)))).* = wire;
    }
    return 0;
}

/// Enumerate all defined globals. For each global the callback receives
/// (userdata, name_ptr, name_len, wire_ptr); wire_ptr is valid only during
/// the call. Returns 0 on success, -1 if the handle is invalid.
export fn engine_list_globals(handle: i32, callback: ?GlobalsCallback, userdata: ?*anyopaque) i32 {
    if (comptime is_wasm) return -1;
    const engine = getEngine(handle) orelse return -1;
    const cb = callback orelse return 0;
    const gs = &engine.runtime.inner.globals_state;
    var i: usize = 0;
    while (i < gs.len()) : (i += 1) {
        const name = gs.nameAt(i);
        const val = gs.valueAt(i);
        const wire = valueToWireWithScratch(val, engine) catch continue;
        cb(userdata, name.ptr, @intCast(name.len), &wire);
    }
    return 0;
}

/// Enumerate callable globals (user-defined functions and closures). For each
/// the callback receives (userdata, name_ptr, name_len, arity).
/// Returns 0 on success, -1 if the handle is invalid.
export fn engine_list_functions(handle: i32, callback: ?FunctionsCallback, userdata: ?*anyopaque) i32 {
    if (comptime is_wasm) return -1;
    const engine = getEngine(handle) orelse return -1;
    const cb = callback orelse return 0;
    const gs = &engine.runtime.inner.globals_state;
    var i: usize = 0;
    while (i < gs.len()) : (i += 1) {
        const name = gs.nameAt(i);
        const val = gs.valueAt(i);
        if (val != .object) continue;
        const obj = val.object;
        const arity: i32 = switch (obj.*) {
            .function => |f| @intCast(f.arity),
            .closure => |cl| switch (cl.func.*) {
                .function => |f| @intCast(f.arity),
                else => continue,
            },
            else => continue,
        };
        cb(userdata, name.ptr, @intCast(name.len), arity);
    }
    return 0;
}

/// Register a per-source-line trace callback fired during script execution.
/// The callback receives (userdata, handle, line, col) on each new source line.
/// Pass null to disable tracing.
export fn engine_set_trace_fn(handle: i32, callback: ?TraceFn, userdata: ?*anyopaque) void {
    if (comptime is_wasm) return;
    const engine = getEngine(handle) orelse return;
    engine.trace_fn = callback;
    engine.trace_userdata = userdata;
}

/// Add a dial policy rule. Rules are evaluated most-recently-added first (LIFO).
/// action: 0 = deny, 1 = allow.
/// pattern: exact IP, CIDR (192.168.1.0/24), exact hostname, wildcard (*.example.com), or "*".
/// port: 0 = any port; otherwise exact port match.
/// Returns 0 on success, -1 for invalid handle, -2 if the rule list is full,
/// -3 for an invalid pattern.
export fn engine_net_policy_add(handle: i32, action: i32, pattern_ptr: PtrInt, pattern_len: i32, port: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    const pattern = wasmSlice(pattern_ptr, pattern_len);
    const act: net_state.PolicyAction = if (action == 0) .deny else .allow;
    const p: u16 = if (port <= 0 or port > 65535) 0 else @intCast(port);
    const rc = blk: {
        // Temporarily apply this engine's policy so addPolicyRule modifies it.
        const saved = net_state.currentPolicy();
        net_state.applyPolicy(engine.net_policy);
        const r = net_state.addPolicyRule(act, pattern, p);
        engine.net_policy = net_state.currentPolicy();
        net_state.applyPolicy(saved);
        break :blk r;
    };
    return switch (rc) {
        0 => 0,
        -1 => -2,
        else => -3,
    };
}

/// Clear all dial policy rules for the engine. After this call the default
/// (allow all) is restored.
export fn engine_net_policy_clear(handle: i32) void {
    const engine = getEngine(handle) orelse return;
    engine.net_policy = .{};
}

// Returns:
//   0  success
//  -1  invalid handle
//  -2  package table full (max 32)
//  -3  file table full (max 64 files per package)
//  -4  a file exceeds the 64 KiB size limit
//  -5  invalid zip or package name
export fn engine_load_package(handle: i32, name_ptr: PtrInt, name_len: i32, zip_ptr: PtrInt, zip_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    if (name_len <= 0 or zip_len <= 0) return -5;
    const name = wasmSlice(name_ptr, name_len);
    const zip_data = wasmSlice(zip_ptr, zip_len);
    package_state.loadFromZip(&engine.package_registry, name, zip_data) catch |err| return switch (err) {
        error.PackageTableFull => -2,
        error.FileTableFull => -3,
        error.FileTooLarge => -4,
        error.InvalidZip, error.InvalidPath => -5,
        error.OutOfMemory => -5,
    };
    engine.runtime.setConfig(.{
        .allow_io = engine.runtime.inner.policy.allow_io,
        .native_backend = engine.runtime.inner.policy.native_backend,
        .max_ops = engine.runtime.inner.policy.max_ops,
        .module_sources = engine.source_entries[0..engine.source_count],
        .module_source_provider = sourceProviderFromLoader(engine),
    });
    return 0;
}

// Native-only: load package files from a directory on the host filesystem.
// Not available in WebAssembly builds.
// Returns same codes as engine_load_package.
export fn engine_load_package_dir(handle: i32, name_ptr: PtrInt, name_len: i32, dir_ptr: PtrInt, dir_len: i32) i32 {
    if (comptime is_wasm) return -5;
    const engine = getEngine(handle) orelse return -1;
    if (name_len <= 0 or dir_len <= 0) return -5;
    const name = wasmSlice(name_ptr, name_len);
    const dir_path = wasmSlice(dir_ptr, dir_len);
    package_state.loadFromDir(&engine.package_registry, name, dir_path) catch |err| return switch (err) {
        error.PackageTableFull => -2,
        error.FileTableFull => -3,
        error.FileTooLarge => -4,
        error.InvalidZip, error.InvalidPath => -5,
        error.OutOfMemory => -5,
    };
    engine.runtime.setConfig(.{
        .allow_io = engine.runtime.inner.policy.allow_io,
        .native_backend = engine.runtime.inner.policy.native_backend,
        .max_ops = engine.runtime.inner.policy.max_ops,
        .module_sources = engine.source_entries[0..engine.source_count],
        .module_source_provider = sourceProviderFromLoader(engine),
    });
    return 0;
}

export fn engine_clear_packages(handle: i32) void {
    const engine = getEngine(handle) orelse return;
    package_state.clearRegistry(&engine.package_registry);
    engine.runtime.setConfig(.{
        .allow_io = engine.runtime.inner.policy.allow_io,
        .native_backend = engine.runtime.inner.policy.native_backend,
        .max_ops = engine.runtime.inner.policy.max_ops,
        .module_sources = engine.source_entries[0..engine.source_count],
        .module_source_provider = sourceProviderFromLoader(engine),
    });
}

test "engine_add_source rejects path and source exceeding buffer" {
    const MaxPath = 256;
    const MaxSource = 4096;

    // Initialize an engine
    const h = engine_init();
    try std.testing.expect(h > 0);

    // Path exactly at limit should succeed
    const ok_path = "a" ** MaxPath;
    const ok_src = "b" ** MaxSource;
    const ok = engine_add_source(h, @intCast(@intFromPtr(ok_path.ptr)), @intCast(ok_path.len), @intCast(@intFromPtr(ok_src.ptr)), @intCast(ok_src.len));
    try std.testing.expectEqual(0, ok);

    // Path one byte over limit should fail
    const h2 = engine_init();
    try std.testing.expect(h2 > 0);
    const long_path = "a" ** (MaxPath + 1);
    const fail_path = engine_add_source(h2, @intCast(@intFromPtr(long_path.ptr)), @intCast(long_path.len), @intCast(@intFromPtr(ok_src.ptr)), @intCast(ok_src.len));
    try std.testing.expectEqual(-5, fail_path);

    // Source one byte over limit should fail
    const h3 = engine_init();
    try std.testing.expect(h3 > 0);
    const long_src = "b" ** (MaxSource + 1);
    const fail_src = engine_add_source(h3, @intCast(@intFromPtr(ok_path.ptr)), @intCast(ok_path.len), @intCast(@intFromPtr(long_src.ptr)), @intCast(long_src.len));
    try std.testing.expectEqual(-5, fail_src);
}

test "engine_call rejects wire serialization overflow" {
    const h = engine_init();
    try std.testing.expect(h > 0);

    // Build a source string that returns an array with exactly 256 elements
    var src_buf: [2048]u8 = undefined;
    var src_len: usize = 0;
    const prefix = "func ok() []int { return [";
    @memcpy(src_buf[0..prefix.len], prefix);
    src_len = prefix.len;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const n = std.fmt.bufPrint(src_buf[src_len..], "{d}", .{i}) catch break;
        src_len += n.len;
        if (i < 255) {
            src_buf[src_len] = ',';
            src_len += 1;
        }
    }
    const suffix = "] }\n";
    @memcpy(src_buf[src_len..][0..suffix.len], suffix);
    src_len += suffix.len;

    const ok = engine_run(h, @intCast(@intFromPtr(src_buf[0..src_len].ptr)), @intCast(src_len));
    try std.testing.expectEqual(0, ok);

    var out_wire: ValueWire = undefined;
    const call_ok = engine_call(h, @intCast(@intFromPtr("ok".ptr)), 2, 0, 0, @intCast(@intFromPtr(&out_wire)));
    try std.testing.expectEqual(0, call_ok);

    // Build a source string that returns an array with 257 elements (one over)
    const h2 = engine_init();
    try std.testing.expect(h2 > 0);
    var src_buf2: [2048]u8 = undefined;
    var src_len2: usize = 0;
    const prefix2 = "func fail() []int { return [";
    @memcpy(src_buf2[0..prefix2.len], prefix2);
    src_len2 = prefix2.len;
    var j: usize = 0;
    while (j < 257) : (j += 1) {
        const n = std.fmt.bufPrint(src_buf2[src_len2..], "{d}", .{j}) catch break;
        src_len2 += n.len;
        if (j < 256) {
            src_buf2[src_len2] = ',';
            src_len2 += 1;
        }
    }
    const suffix2 = "] }\n";
    @memcpy(src_buf2[src_len2..][0..suffix2.len], suffix2);
    src_len2 += suffix2.len;

    const fail_run = engine_run(h2, @intCast(@intFromPtr(src_buf2[0..src_len2].ptr)), @intCast(src_len2));
    try std.testing.expectEqual(0, fail_run);

    var out_wire2: ValueWire = undefined;
    const call_fail = engine_call(h2, @intCast(@intFromPtr("fail".ptr)), 4, 0, 0, @intCast(@intFromPtr(&out_wire2)));
    try std.testing.expectEqual(-2, call_fail);
}

test "engine_call: recover() in defer intercepts panic" {
    // Regression test for issue #140: core.recover() inside a deferred function
    // must intercept panics even when the function is called via engine_call
    // (not via the CLI / top-level bytecode).  Previously the recovery path
    // called run() with ret_ip pointing past end-of-bytecode, producing a
    // spurious BytecodeOutOfBounds error instead of returning the recovered value.
    //
    // Also verifies that core.recover() returns the full human-readable error
    // message (e.g. "predicate failed for Region(mars)") rather than the bare
    // Zig error-name string ("PredicateFailed").
    const h = engine_init();
    try std.testing.expect(h > 0);

    const src =
        \\std  := import("std")
        \\core := std.core
        \\
        \\type Region string predicate func(x) {
        \\    return x == "eu" or x == "us"
        \\}
        \\
        \\var last_err string = ""
        \\
        \\pub func check(region string) (ok bool) {
        \\    defer func() {
        \\        if e := core.recover(); core.is_error(e) {
        \\            last_err = string(e)
        \\            ok = false
        \\        }
        \\    }()
        \\    _ = Region(region)
        \\    return true
        \\}
        \\
        \\pub func get_last_err() string { return last_err }
    ;
    const run_rc = engine_run(h, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
    try std.testing.expectEqual(0, run_rc);

    // "eu" is a valid region — should return true.
    var arg_wire: ValueWire = .{ .tag = 3, .flags = 0, .payload = @bitCast(@intFromPtr("eu".ptr)), .len = 2 };
    var out_wire: ValueWire = undefined;
    const rc_good = engine_call(h, @intCast(@intFromPtr("check".ptr)), 5,
                                @intCast(@intFromPtr(&arg_wire)), 1,
                                @intCast(@intFromPtr(&out_wire)));
    try std.testing.expectEqual(0, rc_good);
    try std.testing.expectEqual(@as(u8, 1), out_wire.tag); // boolean
    try std.testing.expect(out_wire.payload != 0);         // true

    // "mars" fails the predicate; recover() should intercept and return false.
    var bad_arg: ValueWire = .{ .tag = 3, .flags = 0, .payload = @bitCast(@intFromPtr("mars".ptr)), .len = 4 };
    var bad_out: ValueWire = undefined;
    const rc_bad = engine_call(h, @intCast(@intFromPtr("check".ptr)), 5,
                               @intCast(@intFromPtr(&bad_arg)), 1,
                               @intCast(@intFromPtr(&bad_out)));
    // Must return 0 (recover handled it), NOT -2.
    try std.testing.expectEqual(0, rc_bad);
    try std.testing.expectEqual(@as(u8, 1), bad_out.tag); // boolean
    try std.testing.expect(bad_out.payload == 0);         // false

    // The recovered error message must be the human-readable predicate message,
    // not the bare Zig error name "PredicateFailed".
    var err_out: ValueWire = undefined;
    const rc_err = engine_call(h, @intCast(@intFromPtr("get_last_err".ptr)), 12,
                               0, 0,
                               @intCast(@intFromPtr(&err_out)));
    try std.testing.expectEqual(0, rc_err);
    try std.testing.expectEqual(@as(u8, 3), err_out.tag); // string
    const err_str = @as([*]const u8, @ptrFromInt(@as(usize, @bitCast(err_out.payload))))[0..err_out.len];
    try std.testing.expect(std.mem.indexOf(u8, err_str, "predicate failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_str, "Region") != null);
}

test "engine_get_global and engine_list_globals" {
    const h = engine_init();
    try std.testing.expect(h > 0);
    defer engine_destroy(h);

    const src = "x := 42\ny := \"hello\"\n";
    const run_rc = engine_run(h, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
    try std.testing.expectEqual(0, run_rc);

    // engine_get_global: existing key
    var wire: ValueWire = undefined;
    const rc = engine_get_global(h, @intCast(@intFromPtr("x".ptr)), 1, @intCast(@intFromPtr(&wire)));
    try std.testing.expectEqual(0, rc);
    // wire should be an integer 42
    try std.testing.expectEqual(@as(u8, @intFromEnum(WireTag.number)), wire.tag);
    try std.testing.expect((wire.flags & host_abi.FLAG_INTEGER) != 0);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, 42))), wire.payload);

    // engine_get_global: missing key returns -2
    const rc_miss = engine_get_global(h, @intCast(@intFromPtr("zz".ptr)), 2, @intCast(@intFromPtr(&wire)));
    try std.testing.expectEqual(-2, rc_miss);

    // engine_list_globals: collect names
    const Ctx = struct {
        count: usize = 0,
        found_x: bool = false,
        found_y: bool = false,

        fn cb(userdata: ?*anyopaque, name_ptr: [*]const u8, name_len: i32, _: *const ValueWire) callconv(.c) void {
            const self = @as(*@This(), @ptrCast(@alignCast(userdata.?)));
            self.count += 1;
            const name = name_ptr[0..@intCast(name_len)];
            if (std.mem.eql(u8, name, "x")) self.found_x = true;
            if (std.mem.eql(u8, name, "y")) self.found_y = true;
        }
    };
    var ctx: Ctx = .{};
    const list_rc = engine_list_globals(h, Ctx.cb, &ctx);
    try std.testing.expectEqual(0, list_rc);
    try std.testing.expect(ctx.found_x);
    try std.testing.expect(ctx.found_y);
}

test "engine_list_functions" {
    const h = engine_init();
    try std.testing.expect(h > 0);
    defer engine_destroy(h);

    const src = "func add(a int, b int) int { return a + b }\nfunc greet() string { return \"hi\" }\n";
    const run_rc = engine_run(h, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
    try std.testing.expectEqual(0, run_rc);

    const Ctx = struct {
        found_add: bool = false,
        found_greet: bool = false,
        add_arity: i32 = -1,
        greet_arity: i32 = -1,

        fn cb(userdata: ?*anyopaque, name_ptr: [*]const u8, name_len: i32, arity: i32) callconv(.c) void {
            const self = @as(*@This(), @ptrCast(@alignCast(userdata.?)));
            const name = name_ptr[0..@intCast(name_len)];
            if (std.mem.eql(u8, name, "add")) { self.found_add = true; self.add_arity = arity; }
            if (std.mem.eql(u8, name, "greet")) { self.found_greet = true; self.greet_arity = arity; }
        }
    };
    var ctx: Ctx = .{};
    const list_rc = engine_list_functions(h, Ctx.cb, &ctx);
    try std.testing.expectEqual(0, list_rc);
    try std.testing.expect(ctx.found_add);
    try std.testing.expect(ctx.found_greet);
    try std.testing.expectEqual(2, ctx.add_arity);
    try std.testing.expectEqual(0, ctx.greet_arity);
}

test "engine_set_trace_fn fires per source line" {
    const h = engine_init();
    try std.testing.expect(h > 0);
    defer engine_destroy(h);

    const Ctx = struct {
        lines: [64]i32 = undefined,
        count: usize = 0,

        fn cb(userdata: ?*anyopaque, _: i32, line: i32, _: i32) callconv(.c) void {
            const self = @as(*@This(), @ptrCast(@alignCast(userdata.?)));
            if (self.count < self.lines.len) {
                self.lines[self.count] = line;
                self.count += 1;
            }
        }
    };
    var ctx: Ctx = .{};
    engine_set_trace_fn(h, Ctx.cb, &ctx);

    const src = "a := 1\nb := 2\nc := a + b\n";
    const run_rc = engine_run(h, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
    try std.testing.expectEqual(0, run_rc);

    // Three source lines — we should see exactly three distinct line numbers fired.
    try std.testing.expectEqual(@as(usize, 3), ctx.count);
    try std.testing.expectEqual(@as(i32, 1), ctx.lines[0]);
    try std.testing.expectEqual(@as(i32, 2), ctx.lines[1]);
    try std.testing.expectEqual(@as(i32, 3), ctx.lines[2]);
}

test "engine_net_policy_add rule registration" {
    const h = engine_init();
    try std.testing.expect(h > 0);
    defer engine_destroy(h);

    // Invalid handle → -1
    const pat_star = "*";
    try std.testing.expectEqual(@as(i32, -1), engine_net_policy_add(0, 0, @intCast(@intFromPtr(pat_star.ptr)), @intCast(pat_star.len), 0));

    // Valid patterns
    try std.testing.expectEqual(@as(i32, 0), engine_net_policy_add(h, 0, @intCast(@intFromPtr(pat_star.ptr)), @intCast(pat_star.len), 0));
    const pat_cidr = "192.168.1.0/24";
    try std.testing.expectEqual(@as(i32, 0), engine_net_policy_add(h, 1, @intCast(@intFromPtr(pat_cidr.ptr)), @intCast(pat_cidr.len), 0));
    const pat_wild = "*.example.com";
    try std.testing.expectEqual(@as(i32, 0), engine_net_policy_add(h, 1, @intCast(@intFromPtr(pat_wild.ptr)), @intCast(pat_wild.len), 443));

    // Invalid CIDR → -3
    const pat_bad = "not/a/cidr";
    try std.testing.expectEqual(@as(i32, -3), engine_net_policy_add(h, 1, @intCast(@intFromPtr(pat_bad.ptr)), @intCast(pat_bad.len), 0));

    // clear resets count
    engine_net_policy_clear(h);
    try std.testing.expectEqual(@as(u8, 0), getEngine(h).?.net_policy.count);

    // Per-engine isolation
    const h2 = engine_init();
    try std.testing.expect(h2 > 0);
    defer engine_destroy(h2);
    try std.testing.expectEqual(@as(i32, 0), engine_net_policy_add(h, 0, @intCast(@intFromPtr(pat_star.ptr)), @intCast(pat_star.len), 0));
    try std.testing.expectEqual(@as(u8, 1), getEngine(h).?.net_policy.count);
    try std.testing.expectEqual(@as(u8, 0), getEngine(h2).?.net_policy.count);
}

test "engine_net_policy checkDialPolicy semantics" {
    // Default allow: no rules
    net_state.clearPolicy();
    try std.testing.expect(net_state.checkDialPolicy("192.168.1.1:80"));

    // Deny all, then allow one IP (LIFO: allow is added last → evaluated first)
    net_state.clearPolicy();
    _ = net_state.addPolicyRule(.deny, "*", 0);
    _ = net_state.addPolicyRule(.allow, "192.168.1.1", 0);
    try std.testing.expect(net_state.checkDialPolicy("192.168.1.1:80"));
    try std.testing.expect(!net_state.checkDialPolicy("10.0.0.1:80"));

    // CIDR
    net_state.clearPolicy();
    _ = net_state.addPolicyRule(.deny, "*", 0);
    _ = net_state.addPolicyRule(.allow, "10.0.0.0/8", 0);
    try std.testing.expect(net_state.checkDialPolicy("10.1.2.3:443"));
    try std.testing.expect(!net_state.checkDialPolicy("192.168.1.1:443"));

    // Wildcard hostname
    net_state.clearPolicy();
    _ = net_state.addPolicyRule(.deny, "*", 0);
    _ = net_state.addPolicyRule(.allow, "*.example.com", 0);
    try std.testing.expect(net_state.checkDialPolicy("api.example.com:443"));
    try std.testing.expect(!net_state.checkDialPolicy("other.net:443"));

    // Port-specific rule
    net_state.clearPolicy();
    _ = net_state.addPolicyRule(.deny, "*", 0);
    _ = net_state.addPolicyRule(.allow, "192.168.1.1", 443);
    try std.testing.expect(net_state.checkDialPolicy("192.168.1.1:443"));
    try std.testing.expect(!net_state.checkDialPolicy("192.168.1.1:80"));

    net_state.clearPolicy();
}

test "engine_load_package loads zip and resolves imports" {
    const h = engine_init();
    try std.testing.expect(h > 0);
    defer engine_destroy(h);

    // Minimal ZIP containing:
    //   utils/greet.gengo  — pub func greet(name string) string { return "hello " + name }
    //   utils/math.gengo   — pub func add(a int b int) int { return a + b }
    //   README.md          — skipped (not .gengo)
    const zip_data = [_]u8{
        80,75,3,4,20,0,0,0,0,0,185,174,227,92,149,106,139,212,61,0,0,0,61,0,0,0,17,0,0,0,
        117,116,105,108,115,47,103,114,101,101,116,46,103,101,110,103,111,112,117,98,32,102,
        117,110,99,32,103,114,101,101,116,40,110,97,109,101,32,115,116,114,105,110,103,41,32,
        115,116,114,105,110,103,32,123,32,114,101,116,117,114,110,32,34,104,101,108,108,111,
        32,34,32,43,32,110,97,109,101,32,125,80,75,3,4,20,0,0,0,0,0,185,174,227,92,105,177,
        238,211,46,0,0,0,46,0,0,0,16,0,0,0,117,116,105,108,115,47,109,97,116,104,46,103,101,
        110,103,111,112,117,98,32,102,117,110,99,32,97,100,100,40,97,32,105,110,116,32,98,32,
        105,110,116,41,32,105,110,116,32,123,32,114,101,116,117,114,110,32,97,32,43,32,98,32,
        125,80,75,3,4,20,0,0,0,0,0,185,174,227,92,97,57,152,145,12,0,0,0,12,0,0,0,9,0,0,0,
        82,69,65,68,77,69,46,109,100,112,97,99,107,97,103,101,32,100,111,99,115,80,75,1,2,20,
        3,20,0,0,0,0,0,185,174,227,92,149,106,139,212,61,0,0,0,61,0,0,0,17,0,0,0,0,0,0,0,0,
        0,0,0,128,1,0,0,0,0,117,116,105,108,115,47,103,114,101,101,116,46,103,101,110,103,111,
        80,75,1,2,20,3,20,0,0,0,0,0,185,174,227,92,105,177,238,211,46,0,0,0,46,0,0,0,16,0,0,
        0,0,0,0,0,0,0,0,0,128,1,108,0,0,0,117,116,105,108,115,47,109,97,116,104,46,103,101,
        110,103,111,80,75,1,2,20,3,20,0,0,0,0,0,185,174,227,92,97,57,152,145,12,0,0,0,12,0,0,
        0,9,0,0,0,0,0,0,0,0,0,0,0,128,1,200,0,0,0,82,69,65,68,77,69,46,109,100,80,75,5,6,0,0,
        0,0,3,0,3,0,180,0,0,0,251,0,0,0,0,0,
    };

    const rc = engine_load_package(
        h,
        @intCast(@intFromPtr("mylib".ptr)), 5,
        @intCast(@intFromPtr(&zip_data)), @intCast(zip_data.len),
    );
    try std.testing.expectEqual(@as(i32, 0), rc);

    // Run a script that imports from the package
    const src =
        \\const greet = import("mylib/utils/greet")
        \\const math = import("mylib/utils/math")
        \\pub func main() string {
        \\    const g = greet.greet("world")
        \\    const n = math.add(3 5)
        \\    return g + " " + std.conv.intToStr(n)
        \\}
    ;
    const run_rc = engine_run(h, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
    try std.testing.expectEqual(@as(i32, 0), run_rc);

    var result: ValueWire = undefined;
    const call_rc = engine_call(h, @intCast(@intFromPtr("main".ptr)), 4, 0, 0, @intCast(@intFromPtr(&result)));
    try std.testing.expectEqual(@as(i32, 0), call_rc);
    try std.testing.expectEqual(@as(u8, 3), result.tag); // string
    const str_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(result.payload)));
    const str = str_ptr[0..result.len];
    try std.testing.expectEqualStrings("hello world 8", str);

    // Clear packages
    engine_clear_packages(h);
    const engine = getEngine(h).?;
    try std.testing.expectEqual(@as(u8, 0), engine.package_registry.count);
}
