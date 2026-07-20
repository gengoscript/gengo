# Gengoscript Host ABI v2

This page defines the ABI v2 host bridge used when the Gengoscript VM runs with
the `host` native backend. ABI v2 has no cross-version stability promise;
hosts must require an exact version match.

Use this document when you are implementing `gengo_native_call`. For the broader embedding surface, see `engine-api.md`.

## Dispatch Entry Point

Native embeddings register this callback with `engine_set_host_call_fn`:

```c
int32_t callback(void *ctx, uint16_t id,
                 const ValueWire *args_ptr, uint16_t argc,
                 ValueWire *out_ptr);
```

WASM embeddings provide the same call shape as the
`gengo_host.gengo_native_call` import (without the native `ctx` pointer).

## `ValueWire`

`ValueWire` is the transfer format for values crossing the host boundary.

| Field | Type |
|---|---|
| `tag` | `u8` |
| `flags` | `u8` |
| `reserved` | `u16` |
| `payload` | `u64` |
| `len` | `u32` |
| `reserved2` | `u32` |

Layout note: `ValueWire` is a 24-byte `extern struct`. There is a 4-byte pad
between `reserved` and `payload`, so the byte offsets are:

| Offset | Field |
|---|---|
| `0` | `tag` |
| `1` | `flags` |
| `2` | `reserved` |
| `4` | padding |
| `8` | `payload` |
| `16` | `len` |
| `20` | `reserved2` |

Supported tags:

| Tag | Meaning |
|---|---|
| `0` | `null` |
| `1` | boolean |
| `2` | number |
| `3` | string |
| `4` | array |
| `5` | map |
| `6` | error |

For booleans, `payload` is `0` or `1`. For strings and errors, `payload` is a
guest pointer and `len` is the byte length. For arrays, `payload` is a pointer
to `len` consecutive `ValueWire` elements. For maps, `payload` is a pointer to
`len * 2` consecutive `ValueWire` elements arranged as key-value pairs.

C hosts should build and read these with `include/gengo-wire.h`'s
`gengo_wire_array`/`gengo_wire_map` and `gengo_wire_array_at`/
`gengo_wire_map_key_at`/`gengo_wire_map_value_at` rather than encoding the
pointer/length convention by hand; see `engine-api.md`'s "Building values with
gengo-wire.h" section.

`number` is a tagged numeric bucket. The concrete numeric kind is selected by
the `flags` field:

| Flag | Meaning |
|---|---|
| `0` | `payload` is an `f64` bit pattern (`float`) |
| `1 << 0` | `payload` is raw `i64` bits (`int`) |
| `1 << 1` | `payload` is raw fixed-point `i64` bits (`decimal`) |
| `1 << 2` | `payload` is a Unicode code point (`rune`) |

Native `ValueWire` is a C struct, not a portable byte stream: access its fields
through the public header and use the host target's C ABI. The documented
24-byte layout applies to the supported C/Zig ABI. WASM linear-memory fields
are little-endian at the offsets above. `reserved` and `reserved2` must be
zero. Native `payload` values that address data are pointers; in WASM they are
linear-memory byte offsets.

### Decimal ABI limitation

The built-in `decimal` has scale **0**: its raw carrier represents a whole
number. A declared type such as `type Money decimal 2` has a static scale and
stores an `i64` carrier (`1234` means `12.34`). `ValueWire` v2 transmits only
that raw `i64` with `FLAG_DECIMAL`; it does not transmit scale, named type, or
constraints. A host receiving raw `1234` cannot tell whether it was built-in
decimal `1234`, `decimal 2` `12.34`, or `decimal 3` `1.234`.

On a host-to-script return, a decimal wire becomes the unscaled built-in
decimal carrier. It is neither rescaled nor checked against a named decimal
type. Overflow is limited to the signed `i64` carrier; no separate decimal
overflow conversion occurs at the wire boundary. TypeScript currently cannot
emit `FLAG_DECIMAL`, so it is not a lossless decimal binding.

Example, WASM little-endian bytes for raw carrier 1234 (`0x04d2`), with
decimal flag and zero length:

```text
02 02 00 00 00 00 00 00  d2 04 00 00 00 00 00 00  00 00 00 00  00 00 00 00
^  ^     ^ reserved/pad      payload (u64)         ^ len (u32)  ^ reserved2
tag flags                                          (0)          (0)
```

This is an ABI design limitation. A future ABI needs an explicit scale (and,
if nominal identity matters, type identity) to round-trip declared decimals.
The executable `engine_call drops named decimal scale in ValueWire v2` test in
`src/engine.zig` locks this current behaviour down.

## Ownership, lifetime, reentrancy, and concurrency

The caller owns `args_ptr`, `out_ptr`, and all memory they reference. Input
wires and nested array/map wires must remain readable for the `engine_call`.
The engine copies incoming values before returning and does not retain caller
buffers. Callback argument wires are engine-owned scratch storage and are valid
only during that callback.

The callback owns any buffer referenced by its `out_ptr`; keep it valid until
the callback returns, then the host may reclaim it because the engine converts
the value immediately. Treat callback input as read-only. The current API does
not promise callback reentrancy or concurrent use of one engine. Serialise all
engine calls: activation uses process-global runtime views even though instances
have separate VM state. Host handlers must also be made thread-safe by the
host.

## Status Codes

Return values from `gengo_native_call`:

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | unsupported |
| `2` | denied |
| `3` | invalid arguments |
| `4` or other | failure |

## Call IDs

| ID | Name | Arguments | Result |
|---|---|---|---|
| `0` | `abi_version` | none | number |
| `1` | `io_println` | variadic | `null` |
| `2` | `core_len` | 1 | number |
| `3` | `host_caps` | none | number bitmask |
| `4` | `core_append` | variadic | array value |
| `5` | `core_bytelen` | 1 | number |
| `6` | `conv_to_int` | 1 | number |
| `7` | `conv_to_float` | 1 | number |
| `8` | `conv_to_bool` | 1 | boolean |
| `9` | `conv_to_string` | 1 | string |

## ABI Version

The current ABI version is `2`.

The VM requires an exact version match when using the host backend. A host that still implements ABI v1 must be upgraded before it can be used with the current guest.

## Capability Bits

`host_caps` returns a bitmask describing which host-dispatched operations are available.

| Bit | Constant | Native |
|---|---|---|
| `1 << 0` | `CAP_IO_PRINTLN` | `io_println` |
| `1 << 1` | `CAP_CORE_LEN` | `core_len` |
| `1 << 2` | `CAP_CORE_APPEND` | `core_append` |
| `1 << 3` | `CAP_CORE_BYTELEN` | `core_bytelen` |
| `1 << 4` | `CAP_CONV_TO_INT` | `conv_to_int` |
| `1 << 5` | `CAP_CONV_TO_FLOAT` | `conv_to_float` |
| `1 << 6` | `CAP_CONV_TO_BOOL` | `conv_to_bool` |
| `1 << 7` | `CAP_CONV_TO_STRING` | `conv_to_string` |

If a capability bit is absent, the VM falls back to its embedded implementation for that native where a fallback exists.

## Safety Notes

When implementing the host ABI:

- treat guest pointers as untrusted;
- bounds-check every pointer and length before reading memory; and
- expose no ambient host access unless it is intentionally part of the embedding design.
