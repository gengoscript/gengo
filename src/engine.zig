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
const cfg = @import("runtime/config.zig");
const Value = @import("lang/value.zig").Value;
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
var write_callback: ?WriteCallback = null;

const ReadCallback = *const fn (ptr: [*]u8, max_len: i32, is_line: i32) callconv(.c) i32;
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

    fn initInPlaceDefault(self: *Engine) !void {
        self.source_count = 0;
        self.host_module_count = 0;
        self.next_host_call_id = HostModuleCallIdBase;
        self.last_error_len = 0;
        self.last_error_line = 0;
        self.last_error_col = 0;
        try self.runtime.initWithPolicy(.{ .allow_io = true });
        io.setWriteOverrides(engineWrite, engineWerr);
        io.setReadOverride(engineRead);
    }

    fn initInPlaceWithConfig(self: *Engine, ic: InstanceConfig) !void {
        self.source_count = 0;
        self.host_module_count = 0;
        self.next_host_call_id = HostModuleCallIdBase;
        self.last_error_len = 0;
        self.last_error_line = 0;
        self.last_error_col = 0;
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
        const s = std.fmt.bufPrint(&self.last_error, "compile error: {s}: {s}", .{
            @errorName(e.kind), e.msg,
        }) catch "";
        self.last_error_len = @intCast(s.len);
    }

    fn setRuntimeError(self: *Engine, e: api.RuntimeError) void {
        self.last_error_line = e.line;
        self.last_error_col = e.col;
        const s = std.fmt.bufPrint(&self.last_error, "panic: {s}: {s}", .{
            @errorName(e.kind), e.msg,
        }) catch "";
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

    for (engine.source_entries[0..engine.source_count]) |entry| {
        if (std.mem.eql(u8, path, entry.path)) return entry.source;
    }
    return null;
}

fn sourceProviderFromLoader(engine: *Engine) ?api.SourceProvider {
    if (engine.import_loader_fn == null) return null;
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
            if (wire.len == 0) return Value{ .error_value = "" };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0..@as(usize, @intCast(wire.len))];
            const copy = try vmgc.vmAllocManagedBytes(wire.len);
            @memcpy(copy[0..wire.len], data);
            return Value{ .error_value = copy[0..wire.len] };
        },
        @intFromEnum(WireTag.string) => {
            if (wire.len == 0) return Value{ .string = "" };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0..@as(usize, @intCast(wire.len))];
            return try vm.makeString(data);
        },
        @intFromEnum(WireTag.array) => {
            const count = wire.len;
            const elem_wires = @as([*]const ValueWire, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0..count];
            const arr_obj = try vmgc.vmAllocObject();
            arr_obj.* = .{ .array = &[_]Value{} };
            try vms.pushTempRoot(.{ .object = arr_obj });
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
            const map_obj = try vmgc.vmAllocObject();
            map_obj.* = .{ .map = &[_]MapEntry{} };
            try vms.pushTempRoot(.{ .object = map_obj });
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
        .string => |s| makeWire(@intFromEnum(WireTag.string), @intFromPtr(s.ptr), @intCast(s.len)),
        .error_value => |msg| makeWire(@intFromEnum(WireTag.@"error"), @intFromPtr(msg.ptr), @intCast(msg.len)),
        .object => |obj| switch (obj.*) {
            .dyn_string => makeWire(@intFromEnum(WireTag.string), @intFromPtr(obj.dyn_string.ptr), @intCast(obj.dyn_string.len)),
            .string_view => makeWire(@intFromEnum(WireTag.string), @intFromPtr(obj.string_view.bytes.ptr), @intCast(obj.string_view.bytes.len)),
            .array, .array_managed, .array_capacity => {
                const items = try vms.asArraySlice(obj);
                const wires = (heap.bump(ValueWire, items.len) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0..items.len];
                for (items, 0..) |item, i| {
                    wires[i] = try valueToWire(item);
                }
                return makeWire(@intFromEnum(WireTag.array), @intFromPtr(wires.ptr), @intCast(items.len));
            },
            .map, .map_managed, .map_hashed => {
                const entries = try vms.asMapSlice(obj);
                const wires = (heap.bump(ValueWire, entries.len * 2) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0 .. entries.len * 2];
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = try valueToWire(entry.key);
                    wires[i * 2 + 1] = try valueToWire(entry.value);
                }
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(entries.len));
            },
            .struct_instance => {
                const entries = obj.struct_instance.fields;
                const wires = (heap.bump(ValueWire, entries.len * 2) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0 .. entries.len * 2];
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = try valueToWire(entry.key);
                    wires[i * 2 + 1] = try valueToWire(entry.value);
                }
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
                wires[0] = try valueToWire(.{ .string = "tag" });
                wires[1] = try valueToWire(.{ .string = vv.tag });
                wires[2] = try valueToWire(.{ .string = "value" });
                wires[3] = try valueToWire(vv.payload);
                var wi: usize = 2;
                for (vtype.shared_fields[0..shared_count], vv.shared_values[0..shared_count]) |spec, sv| {
                    wires[wi * 2] = try valueToWire(.{ .string = spec.name });
                    wires[wi * 2 + 1] = try valueToWire(sv);
                    wi += 1;
                }
                for (arm_spec.fields[0..arm_field_count], vv.arm_fields[0..arm_field_count]) |spec, af| {
                    wires[wi * 2] = try valueToWire(.{ .string = spec.name });
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
            const stable = scratch.setStringScratch(s);
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
                for (items, 0..) |item, i| {
                    wires[i] = try valueToWire(item);
                }
                return makeWire(@intFromEnum(WireTag.array), @intFromPtr(wires.ptr), @intCast(items.len));
            },
            .map, .map_managed, .map_hashed => {
                const entries = try vms.asMapSlice(obj);
                const max_entries = scratch.wire_elem_buf.len / 2;
                if (entries.len > max_entries) return error.WireBufferOverflow;
                const wires = &scratch.wire_elem_buf;
                scratch.wire_elem_count = @intCast(entries.len * 2);
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = try valueToWire(entry.key);
                    wires[i * 2 + 1] = try valueToWire(entry.value);
                }
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(entries.len));
            },
            .struct_instance => {
                const entries = obj.struct_instance.fields;
                const max_entries = scratch.wire_elem_buf.len / 2;
                if (entries.len > max_entries) return error.WireBufferOverflow;
                const wires = &scratch.wire_elem_buf;
                scratch.wire_elem_count = @intCast(entries.len * 2);
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = try valueToWire(entry.key);
                    wires[i * 2 + 1] = try valueToWire(entry.value);
                }
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
    // If this was the last active engine, tear down all process-global state so
    // that the next engine_init() starts clean.
    for (&engine_slots) |*s| {
        if (s.active) return;
    }
    io.clearWriteOverrides();
    io.clearReadOverride();
    http_state.resetHandler();
    net_state.resetHandlers();
    fs_state.clearMounts();
}

export fn engine_run(handle: i32, src_ptr: PtrInt, src_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    if (src_len < 0) { engine.setError("engine_run: src_len must not be negative"); return -1; }
    const src = wasmSlice(src_ptr, src_len);
    setupHostModules(engine);
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
    _ = getEngine(handle) orelse return;
    write_callback = callback;
}

export fn engine_set_read_fn(handle: i32, callback: ?ReadCallback) void {
    if (comptime is_wasm) return;
    _ = getEngine(handle) orelse return;
    read_callback = callback;
}

export fn engine_set_net_handlers(handle: i32, handlers: ?*const net_state.GengoNetHandlers, userdata: ?*anyopaque) void {
    _ = getEngine(handle) orelse return;
    if (handlers) |h| {
        net_state.setNetHandlers(h.*, userdata);
    } else {
        net_state.resetHandlers();
    }
}

export fn engine_set_http_handler(handle: i32, callback: ?http_state.GengoHttpFetchFn, userdata: ?*anyopaque) void {
    _ = getEngine(handle) orelse return;
    if (callback) |cb| {
        http_state.setHttpHandler(cb, userdata);
    } else {
        http_state.resetHandler();
    }
}

/// Register a host directory as a cap:fs mount ("name" -> real path).
/// Strings are copied; the caller may free them after the call returns.
/// Returns 0 on success, -1 on invalid handle, -2 on invalid mount.
export fn engine_mount_dir(handle: i32, name_ptr: PtrInt, name_len: i32, path_ptr: PtrInt, path_len: i32) i32 {
    _ = getEngine(handle) orelse return -1;
    if (name_len < 0 or path_len < 0) return -2;
    const name = wasmSlice(name_ptr, name_len);
    const path = wasmSlice(path_ptr, path_len);
    fs_state.addMount(name, path) catch return -2;
    return 0;
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
