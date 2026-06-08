const std = @import("std");
const builtin = @import("builtin");
const api = @import("runtime/api.zig");
const heap = @import("runtime/heap.zig");
const host_abi = @import("runtime/host_abi.zig");
const io = @import("runtime/io.zig");
const module_compile = @import("lang/module_compile.zig");
const vm = @import("lang/vm.zig");
const vms = @import("lang/vm_state.zig");
const vmgc = @import("lang/vm_gc.zig");
const net_state = @import("lang/native/net_state.zig");
const Value = @import("lang/value.zig").Value;
const Object = @import("lang/value.zig").Object;
const MapEntry = @import("lang/value.zig").MapEntry;
const ValueWire = host_abi.ValueWire;
const WireTag = host_abi.WireTag;

const is_wasm = builtin.target.cpu.arch == .wasm32;
// On WASM all pointers are 32-bit offsets into linear memory; on native they are
// full-width host pointers.  All exported functions use PtrInt for pointer params
// so the C header can declare them as `const char *` / `void *` on both targets.
const PtrInt = if (is_wasm) i32 else usize;
const WriteCallback = *const fn (ptr: [*]const u8, len: i32, is_stderr: i32) callconv(.c) void;
var write_callback: ?WriteCallback = null;

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

fn engineWrite(s: []const u8) void {
    WriteImpl.write(s.ptr, @intCast(s.len), 0);
}

fn engineWerr(s: []const u8) void {
    WriteImpl.write(s.ptr, @intCast(s.len), 1);
}

const MaxEngines = 64;
const MaxSources = 64;
const MaxHostModules = 16;
const MaxHostModuleFuncs = 64;
const MaxErrorLen = 512;
const MaxStringScratch = 4096;
const HostModuleCallIdBase = 0x1000;

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
    last_error_col: u16 = 0,
    string_scratch: [MaxStringScratch]u8 = undefined,
    string_scratch_len: u16 = 0,
    wire_elem_buf: [256]ValueWire = undefined,
    wire_elem_count: u16 = 0,

    fn initInPlace(self: *Engine) void {
        self.source_count = 0;
        self.host_module_count = 0;
        self.next_host_call_id = HostModuleCallIdBase;
        self.last_error_len = 0;
        self.last_error_line = 0;
        self.last_error_col = 0;
        self.runtime.initWithPolicy(.{ .allow_io = true });
        io.setWriteOverrides(engineWrite, engineWerr);
    }

    fn setError(self: *Engine, msg: []const u8) void {
        const len = @min(msg.len, self.last_error.len);
        @memcpy(self.last_error[0..len], msg[0..len]);
        self.last_error_len = @intCast(len);
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

fn getEngine(handle: i32) ?*Engine {
    if (handle <= 0 or handle > MaxEngines) return null;
    const idx = @as(usize, @intCast(handle - 1));
    if (!engine_slots[idx].active) return null;
    return &engine_slots[idx].engine;
}

fn wasmSlice(ptr: PtrInt, len: i32) []const u8 {
    if (len <= 0) return "";
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(ptr))))[0..@as(usize, @intCast(len))];
}

fn wasmSliceMut(ptr: PtrInt, len: i32) []u8 {
    if (len <= 0) return "";
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(ptr))))[0..@as(usize, @intCast(len))];
}

fn wireToValue(wire: ValueWire) Value {
    return switch (wire.tag) {
        @intFromEnum(WireTag.null) => .null,
        @intFromEnum(WireTag.boolean) => Value{ .boolean = wire.payload != 0 },
        @intFromEnum(WireTag.number) => Value{ .number = @bitCast(wire.payload) },
        @intFromEnum(WireTag.string) => {
            if (wire.len == 0) return Value{ .string = "" };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0..@as(usize, @intCast(wire.len))];
            return vm.makeString(data) catch Value.null;
        },
        @intFromEnum(WireTag.array) => {
            const count = wire.len;
            const elem_wires = @as([*]const ValueWire, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0..count];
            const arr_obj = vmgc.vmAllocObject() catch return Value.null;
            arr_obj.* = .{ .array = &[_]Value{} };
            vms.pushTempRoot(.{ .object = arr_obj }) catch return Value.null;
            defer vms.popTempRoot();
            const items = vmgc.vmAllocManagedSlice(Value, count) catch return Value.null;
            for (elem_wires, 0..) |ew, i| {
                items[i] = wireToValue(ew);
            }
            arr_obj.* = .{ .array_managed = items[0..count] };
            return .{ .object = arr_obj };
        },
        @intFromEnum(WireTag.map) => {
            const count = wire.len;
            const pair_wires = @as([*]const ValueWire, @ptrFromInt(@as(usize, @intCast(wire.payload))))[0 .. count * 2];
            const map_obj = vmgc.vmAllocObject() catch return Value.null;
            map_obj.* = .{ .map = &[_]MapEntry{} };
            vms.pushTempRoot(.{ .object = map_obj }) catch return Value.null;
            defer vms.popTempRoot();
            const entries = vmgc.vmAllocManagedSlice(MapEntry, count) catch return Value.null;
            for (0..count) |i| {
                entries[i] = .{
                    .key = wireToValue(pair_wires[i * 2]),
                    .value = wireToValue(pair_wires[i * 2 + 1]),
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

fn valueToWire(val: Value) ValueWire {
    return switch (val) {
        .null => makeWire(@intFromEnum(WireTag.null), 0, 0),
        .boolean => |b| makeWire(@intFromEnum(WireTag.boolean), @intFromBool(b), 0),
        .number => |n| makeWire(@intFromEnum(WireTag.number), @bitCast(@as(f64, n)), 0),
        .string => |s| makeWire(@intFromEnum(WireTag.string), @intFromPtr(s.ptr), @intCast(s.len)),
        .object => |obj| switch (obj.*) {
            .dyn_string => makeWire(@intFromEnum(WireTag.string), @intFromPtr(obj.dyn_string.ptr), @intCast(obj.dyn_string.len)),
            .array, .array_managed => {
                const items = vms.asArraySlice(obj);
                const wires = (heap.bump(ValueWire, items.len) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0..items.len];
                for (items, 0..) |item, i| {
                    wires[i] = valueToWire(item);
                }
                return makeWire(@intFromEnum(WireTag.array), @intFromPtr(wires.ptr), @intCast(items.len));
            },
            .map, .map_managed, .map_hashed => {
                const entries = vms.asMapSlice(obj);
                const wires = (heap.bump(ValueWire, entries.len * 2) orelse return makeWire(@intFromEnum(WireTag.null), 0, 0))[0 .. entries.len * 2];
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = valueToWire(entry.key);
                    wires[i * 2 + 1] = valueToWire(entry.value);
                }
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(entries.len));
            },
            else => makeWire(@intFromEnum(WireTag.null), 0, 0),
        },
        else => makeWire(@intFromEnum(WireTag.null), 0, 0),
    };
}

fn valueToWireWithScratch(val: Value, scratch: *Engine) ValueWire {
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
            .array, .array_managed => {
                const items = vms.asArraySlice(obj);
                const count = @min(items.len, scratch.wire_elem_buf.len);
                const wires = &scratch.wire_elem_buf;
                scratch.wire_elem_count = @intCast(count);
                for (items[0..count], 0..) |item, i| {
                    wires[i] = valueToWire(item);
                }
                return makeWire(@intFromEnum(WireTag.array), @intFromPtr(wires.ptr), @intCast(count));
            },
            .map, .map_managed, .map_hashed => {
                const entries = vms.asMapSlice(obj);
                const max_entries = scratch.wire_elem_buf.len / 2;
                const count = @min(entries.len, max_entries);
                const wires = &scratch.wire_elem_buf;
                scratch.wire_elem_count = @intCast(count * 2);
                for (entries[0..count], 0..) |entry, i| {
                    wires[i * 2] = valueToWire(entry.key);
                    wires[i * 2 + 1] = valueToWire(entry.value);
                }
                return makeWire(@intFromEnum(WireTag.map), @intFromPtr(wires.ptr), @intCast(count));
            },
            else => return valueToWire(val),
        },
        else => return valueToWire(val),
    }
}

export fn engine_init() i32 {
    for (&engine_slots, 0..) |*slot, i| {
        if (!slot.active) {
            slot.engine.initInPlace();
            slot.active = true;
            return @as(i32, @intCast(i + 1));
        }
    }
    return 0;
}

export fn engine_destroy(handle: i32) void {
    const idx = if (handle > 0 and handle <= MaxEngines) @as(usize, @intCast(handle - 1)) else return;
    engine_slots[idx].active = false;
}

export fn engine_run(handle: i32, src_ptr: PtrInt, src_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    const src = wasmSlice(src_ptr, src_len);
    setupHostModules(engine);
    const res = engine.runtime.run(src);
    return switch (res) {
        .ok => 0,
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
    const src = wasmSlice(src_ptr, src_len);
    const path = wasmSlice(path_ptr, path_len);
    setupHostModules(engine);
    const res = engine.runtime.runPath(src, path);
    return switch (res) {
        .ok => 0,
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
    const arg_count = @min(@as(usize, @intCast(@max(argc, 0))), args.len);
    if (argc > 0 and args_ptr != 0) {
        const wire_args = @as([*]const ValueWire, @ptrFromInt(@as(usize, @intCast(args_ptr))))[0..arg_count];
        for (wire_args, 0..) |wa, i| {
            args[i] = wireToValue(wa);
        }
    }

    const res = engine.runtime.call(name, args[0..arg_count]);

    return switch (res) {
        .ok => |val| {
            const wire = valueToWireWithScratch(val, engine);
            if (out_ptr != 0) {
                @as(*ValueWire, @ptrFromInt(@as(usize, @intCast(out_ptr)))).* = wire;
            }
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
    engine.runtime.reset();
}

export fn engine_add_source(handle: i32, path_ptr: PtrInt, path_len: i32, src_ptr: PtrInt, src_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    if (engine.source_count >= MaxSources) return -3;

    const path = wasmSlice(path_ptr, path_len);
    const src = wasmSlice(src_ptr, src_len);

    const sc = engine.source_count;
    const path_buf = &engine.path_bufs[sc];
    const src_buf = &engine.src_bufs[sc];

    const plen = @min(@as(usize, @intCast(path.len)), path_buf.len);
    @memcpy(path_buf[0..plen], path[0..plen]);
    const slen = @min(@as(usize, @intCast(src.len)), src_buf.len);
    @memcpy(src_buf[0..slen], src[0..slen]);

    engine.source_entries[sc] = .{ .path = path_buf[0..plen], .source = src_buf[0..slen] };
    engine.source_count = sc + 1;

    engine.runtime.initWithPolicy(.{
        .allow_io = true,
        .module_sources = engine.source_entries[0..engine.source_count],
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
    if (engine.host_module_count >= MaxHostModules) return -3;
    if (funcs_count < 0 or funcs_count > MaxHostModuleFuncs) return -4;

    const name = wasmSlice(name_ptr, name_len);
    if (!validateModuleName(name)) return -5;

    const slot = &engine.host_module_entries[engine.host_module_count];
    slot.name_len = @min(@as(usize, @intCast(name.len)), slot.name.len);
    @memcpy(slot.name[0..slot.name_len], name[0..slot.name_len]);

    const func_defs = @as([*]const HostModuleFuncDef, @ptrFromInt(@as(usize, @intCast(funcs_ptr))))[0..@as(usize, @intCast(funcs_count))];
    for (func_defs, 0..) |fd, i| {
        const fname = wasmSlice(fd.name_ptr, @intCast(fd.name_len));
        const flen = @min(@as(usize, @intCast(fname.len)), engine.host_module_func_name_bufs[engine.host_module_count][i].len);
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
        .allow_io = true,
        .module_sources = engine.source_entries[0..engine.source_count],
        .host_modules = engine.host_module_descs[0..desc_count],
    });
}

export fn engine_last_error(handle: i32, out_ptr: PtrInt, out_max_len: i32) i32 {
    const engine = getEngine(handle) orelse return 0;
    const len = @min(@as(usize, @intCast(engine.last_error_len)), @as(usize, @intCast(@max(out_max_len, 0))));
    if (len > 0 and out_ptr != 0) {
        const dest = wasmSliceMut(out_ptr, @intCast(len));
        @memcpy(dest, engine.last_error[0..len]);
    }
    return engine.last_error_len;
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

export fn engine_set_net_handlers(handle: i32, handlers: ?*const net_state.GengoNetHandlers, userdata: *anyopaque) void {
    _ = getEngine(handle) orelse return;
    if (handlers) |h| {
        net_state.setNetHandlers(h.*, userdata);
    }
}
