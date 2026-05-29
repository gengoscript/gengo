const builtin = @import("builtin");

pub const WireTag = enum(u8) {
    null = 0,
    boolean = 1,
    number = 2,
    string = 3,
};

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

pub const HostCall = enum(u16) {
    abi_version = 0,
    io_println = 1,
    core_len = 2,
    host_caps = 3,
    core_append = 4,
};

pub const ABI_VERSION: u64 = 1;
pub const CAP_IO_PRINTLN: u64 = 1 << 0;
pub const CAP_CORE_LEN: u64 = 1 << 1;
pub const CAP_CORE_APPEND: u64 = 1 << 2;

fn hasHostImport() bool {
    return builtin.target.os.tag == .freestanding and builtin.target.cpu.arch == .wasm32;
}

pub fn nativeCall(id: HostCall, args: []const ValueWire, out: *ValueWire) CallStatus {
    if (!comptime hasHostImport()) return .unsupported;
    const Host = struct {
        extern "gengo_host" fn gengo_native_call(id: u16, args_ptr: [*]const ValueWire, argc: u16, out_ptr: *ValueWire) i32;
    };
    const rc = Host.gengo_native_call(@intFromEnum(id), args.ptr, @intCast(args.len), out);
    return switch (rc) {
        0 => .ok,
        1 => .unsupported,
        2 => .denied,
        3 => .bad_args,
        else => .failed,
    };
}
