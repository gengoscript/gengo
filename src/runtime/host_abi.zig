const builtin = @import("builtin");

pub const WireTag = enum(u8) {
    null = 0,
    boolean = 1,
    number = 2,
    string = 3,
    array = 4,
    map = 5,
    @"error" = 6,
};

// Flags for WireTag.number to distinguish subtypes
pub const FLAG_INTEGER: u8 = 1 << 0; // bit 0: payload is raw i64 bits (two's complement)
pub const FLAG_DECIMAL: u8 = 1 << 1; // bit 1: payload is raw i64 fixed-point, not f64
pub const FLAG_RUNE: u8 = 1 << 2; // bit 2: payload is a Unicode codepoint (u21)

pub const ValueWire = extern struct {
    tag: u8,
    flags: u8,
    reserved: u16,
    payload: u64,
    len: u32,
    reserved2: u32,
};

pub const CallStatus = enum(i32) {
    ok = 0,
    unsupported = 1,
    denied = 2,
    bad_args = 3,
    failed = 4,
};

pub const NativeHostCallFn = *const fn (
    ctx: ?*anyopaque,
    id: u16,
    args: [*]const ValueWire,
    argc: u16,
    out: *ValueWire,
) callconv(.c) i32;

var native_host_call_fn: ?NativeHostCallFn = null;
var native_host_call_ctx: ?*anyopaque = null;

pub fn setNativeHostCall(fn_ptr: ?NativeHostCallFn, ctx: ?*anyopaque) void {
    native_host_call_fn = fn_ptr;
    native_host_call_ctx = ctx;
}

// std natives (std.core.len/append/bytelen, std.conv.*, std.io.println) are
// never host-overridable — see dev-docs/roadmap.md. abi_version is the only
// call a host ever receives outside of its own registered host-module
// functions (see module_compile.zig's HostModuleFuncDesc/call_id), used to
// gate compatibility before any host-module call is dispatched.
pub const HostCall = enum(u16) {
    abi_version = 0,
};

pub const ABI_VERSION: u64 = 2;

fn hasHostImport() bool {
    if (builtin.target.cpu.arch != .wasm32) return false;
    const root = @import("root");
    return @hasDecl(root, "is_embedded_engine") and root.is_embedded_engine;
}

pub fn nativeCall(id: HostCall, args: []const ValueWire, out: *ValueWire) CallStatus {
    return nativeCallRaw(@intFromEnum(id), args, out);
}

pub fn nativeCallRaw(id: u16, args: []const ValueWire, out: *ValueWire) CallStatus {
    const rc = if (comptime hasHostImport()) blk: {
        const Host = struct {
            extern "gengo_host" fn gengo_native_call(id_: u16, args_ptr: [*]const ValueWire, argc: u16, out_ptr: *ValueWire) i32;
        };
        break :blk Host.gengo_native_call(id, args.ptr, @intCast(args.len), out);
    } else if (native_host_call_fn) |callback| callback(native_host_call_ctx, id, args.ptr, @intCast(args.len), out) else return .unsupported;
    return switch (rc) {
        0 => .ok,
        1 => .unsupported,
        2 => .denied,
        3 => .bad_args,
        else => .failed,
    };
}
