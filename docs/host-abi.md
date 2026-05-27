# gengo Host ABI v1

This document defines the current host bridge used when gengo VM native backend is set to `host`.

## Import

The guest imports one function from module `gengo_host`:

- `gengo_native_call(id: u16, args_ptr: *ValueWire, argc: u16, out_ptr: *ValueWire) -> i32`

## ValueWire

`ValueWire` layout (extern struct):

- `tag: u8`
- `flags: u8`
- `reserved: u16`
- `payload: u64`
- `len: u32`
- `reserved2: u32`

Supported tags currently:

- `0`: null
- `1`: boolean (`payload` is `0` or `1`)
- `2`: number (`payload` is bitcast f64)
- `3`: string (`payload` is guest pointer, `len` bytes)

## Status Codes

Return value from `gengo_native_call`:

- `0`: ok
- `1`: unsupported
- `2`: denied
- `3`: bad_args
- `4` (or anything else): failed

## Call IDs

- `0`: `abi_version` (no args, returns number)
- `1`: `io_println` (variadic args, returns null)
- `2`: `core_len` (1 arg, returns number)
- `3`: `host_caps` (no args, returns number bitmask)
- `4`: `core_append` (variadic args, returns array value)

## ABI Version

- Current ABI version is `1`.
- VM rejects host mode if `abi_version` does not match exactly.

## Capability Bits (`host_caps`)

- bit `0` (`1 << 0`): supports `io_println`
- bit `1` (`1 << 1`): supports `core_len`
- bit `2` (`1 << 2`): supports `core_append`

VM behavior:

- In host backend, VM queries `abi_version` and `host_caps` before first host native use.
- If required capability bit is missing, VM raises `HostCapabilityMissing`.
- Natives that are VM-local (for example `core.gc`, `core.gc_stats`, `core.error`, `std.conv.*`) execute in guest VM in both `embedded` and `host` backends.

## Safety Notes

- Host must treat guest pointers as untrusted.
- Host must bounds-check all pointer/length pairs before reading memory.
- Host should not expose ambient file/network/process access unless explicitly intended.
