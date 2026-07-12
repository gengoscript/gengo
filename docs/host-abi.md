# Gengoscript Host ABI v2

This page defines the host bridge used when the Gengoscript VM runs with the `host` native backend.

Use this document when you are implementing `gengo_native_call`. For the broader embedding surface, see `engine-api.md`.

## Imported Function

The guest imports one function from module `gengo_host`:

```c
int32_t gengo_native_call(uint16_t id,
                          ValueWire* args_ptr,
                          uint16_t argc,
                          ValueWire* out_ptr);
```

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

`number` is a tagged numeric bucket. The concrete numeric kind is selected by
the `flags` field:

| Flag | Meaning |
|---|---|
| `0` | `payload` is an `f64` bit pattern (`float`) |
| `1 << 0` | `payload` is raw `i64` bits (`int`) |
| `1 << 1` | `payload` is raw fixed-point `i64` bits (`decimal`) |
| `1 << 2` | `payload` is a Unicode code point (`rune`) |

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
