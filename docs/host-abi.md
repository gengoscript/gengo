# Gengoscript Host ABI v2

This document defines the host bridge used when gengo VM native backend is set to `host`.

**Version 2** adds `core_bytelen` and `std.conv.*` dispatch on top of the v1 base.  
See `docs/host-abi-v2-plan.md` for the design doc.

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

Supported tags:

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

| ID | Name | Args | Returns |
|----|------|------|---------|
| `0` | `abi_version` | none | number |
| `1` | `io_println` | variadic | null |
| `2` | `core_len` | 1 | number |
| `3` | `host_caps` | none | number (bitmask) |
| `4` | `core_append` | variadic | array value |
| `5` | `core_bytelen` | 1 | number |
| `6` | `conv_to_int` | 1 | number |
| `7` | `conv_to_float` | 1 | number |
| `8` | `conv_to_bool` | 1 | boolean |
| `9` | `conv_to_string` | 1 | string |

## ABI Version

- Current ABI version is `2`.
- VM rejects host mode if `abi_version` does not match exactly.
- ABI `1` hosts can be upgraded by adding the new call IDs and capability bits; the version check is the only breaking gate.

## Capability Bits (`host_caps`)

| Bit | Constant | Native |
|-----|----------|--------|
| `0` (`1 << 0`) | `CAP_IO_PRINTLN` | `io_println` |
| `1` (`1 << 1`) | `CAP_CORE_LEN` | `core_len` |
| `2` (`1 << 2`) | `CAP_CORE_APPEND` | `core_append` |
| `3` (`1 << 3`) | `CAP_CORE_BYTELEN` | `core_bytelen` |
| `4` (`1 << 4`) | `CAP_CONV_TO_INT` | `conv_to_int` |
| `5` (`1 << 5`) | `CAP_CONV_TO_FLOAT` | `conv_to_float` |
| `6` (`1 << 6`) | `CAP_CONV_TO_BOOL` | `conv_to_bool` |
| `7` (`1 << 7`) | `CAP_CONV_TO_STRING` | `conv_to_string` |

VM behavior:

- In host backend, VM queries `abi_version` and `host_caps` before first host native use.
- If a capability bit is absent, the VM falls back to its embedded implementation for that native; no error is raised.
- Natives that are VM-local (for example `core.gc`, `core.gc_stats`, `core.error`) execute in guest VM in both `embedded` and `host` backends.

## Safety Notes

- Host must treat guest pointers as untrusted.
- Host must bounds-check all pointer/length pairs before reading memory.
- Host should not expose ambient file/network/process access unless explicitly intended.
