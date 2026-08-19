# Gengoscript Host ABI

This page defines the host bridge used when the Gengoscript VM runs with the
`host` native backend, and its `gengo_native_call` dispatch entry point. The
ABI has no cross-version stability promise; hosts must require an exact
version match.

`std.*` natives (`std.core.len`/`append`/`bytelen`, `std.conv.*`,
`std.io.println`) are never routed through this bridge — a host cannot
override their behavior, so the same call means the same thing regardless of
which host it runs under. The only thing that crosses this boundary is
**host modules**: functions the host explicitly registers under an
`import("host:name")` namespace (see `engine-api.md`'s host module section).
`abi_version` exists purely to gate that a host module call is dispatched to
a compatible host before any call_id is sent.

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

C hosts should build and read these with `sdk/c/include/gengo-wire.h`'s
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

Every other call ID the host receives is a **host module** call, identified
by the `call_id` the host itself chose when registering that function (see
`engine-api.md`). There is no fixed, engine-defined call beyond `abi_version`.

## ABI Version

The current ABI version is `2`. The VM requires an exact version match when using the host backend.

## Wire Depth Limit

`ValueWire` serialization is bounded by a recursive nesting depth of 64 in
both directions. A host returning a value nested deeper than 64 levels, or a
script returning such a value to the host, produces `HostValueTooDeep` rather
than overflowing the call stack. A wire value whose `len` field (for strings,
arrays, or maps) exceeds the u32 maximum produces `HostValueTooLarge`. Design
host module return values to stay well within the depth limit; flatten deeply
nested structures before returning them.

## Safety Notes

When implementing the host ABI:

- treat guest pointers as untrusted;
- bounds-check every pointer and length before reading memory; and
- expose no ambient host access unless it is intentionally part of the embedding design.
