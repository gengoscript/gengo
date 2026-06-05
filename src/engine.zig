const std = @import("std");
const api = @import("runtime/api.zig");
const host_abi = @import("runtime/host_abi.zig");
const io = @import("runtime/io.zig");
const vm = @import("lang/vm.zig");
const Value = @import("lang/value.zig").Value;
const ValueWire = host_abi.ValueWire;
const WireTag = host_abi.WireTag;

extern "env" fn gengo_write(ptr: [*]const u8, len: i32, is_stderr: i32) void;

fn engineWrite(s: []const u8) void {
    gengo_write(s.ptr, @intCast(s.len), 0);
}

fn engineWerr(s: []const u8) void {
    gengo_write(s.ptr, @intCast(s.len), 1);
}

const MaxEngines = 64;
const MaxSources = 64;
const MaxErrorLen = 512;
const MaxStringScratch = 4096;

const SourceEntry = struct {
    path: []const u8,
    src: []const u8,
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
    last_error: [MaxErrorLen]u8 = undefined,
    last_error_len: u16 = 0,
    last_error_line: u32 = 0,
    last_error_col: u16 = 0,
    string_scratch: [MaxStringScratch]u8 = undefined,
    string_scratch_len: u16 = 0,

    fn initInPlace(self: *Engine) void {
        self.source_count = 0;
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

fn wasmSlice(ptr: i32, len: i32) []const u8 {
    if (len <= 0) return "";
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(ptr))))[0..@as(usize, @intCast(len))];
}

fn wasmSliceMut(ptr: i32, len: i32) []u8 {
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
        .object => |obj| {
            if (obj.* == .dyn_string) {
                return makeWire(@intFromEnum(WireTag.string), @intFromPtr(obj.dyn_string.ptr), @intCast(obj.dyn_string.len));
            }
            return makeWire(@intFromEnum(WireTag.null), 0, 0);
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
        .object => |obj| {
            if (obj.* == .dyn_string) {
                const s = obj.dyn_string;
                const stable = scratch.setStringScratch(s);
                return makeWire(@intFromEnum(WireTag.string), @intFromPtr(stable.ptr), @intCast(stable.len));
            }
            return valueToWire(val);
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

export fn engine_run(handle: i32, src_ptr: i32, src_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    const src = wasmSlice(src_ptr, src_len);
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

export fn engine_run_path(handle: i32, src_ptr: i32, src_len: i32, path_ptr: i32, path_len: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    const src = wasmSlice(src_ptr, src_len);
    const path = wasmSlice(path_ptr, path_len);
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

export fn engine_call(handle: i32, name_ptr: i32, name_len: i32, args_ptr: i32, argc: i32, out_ptr: i32) i32 {
    const engine = getEngine(handle) orelse return -1;
    const name = wasmSlice(name_ptr, name_len);

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

export fn engine_add_source(handle: i32, path_ptr: i32, path_len: i32, src_ptr: i32, src_len: i32) i32 {
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

export fn engine_last_error(handle: i32, out_ptr: i32, out_max_len: i32) i32 {
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
