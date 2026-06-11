# Gengoscript Host ABI v2 Plan

> **Status: implemented** (`a918f30`). This document is the original design record. For the current ABI definition see `docs/host-abi.md`.

## Goal

Close parity gaps for host-dispatched std natives while preserving current v1 compatibility.

Targets:
- `std.conv.to_int`
- `std.conv.to_float`
- `std.conv.to_bool`
- `std.conv.to_string`
- `std.core.bytelen`

## Versioning Strategy

- Keep ABI v1 behavior unchanged.
- Introduce ABI v2 with additive call IDs and capability bits.
- Guest checks `abi_version` and branches:
  - v1: keep current behavior (VM-local fallback for unsupported host natives).
  - v2: use host dispatch where capability is present.

## Proposed Additions

### New Call IDs
- `5`: `core_bytelen`
- `6`: `conv_to_int`
- `7`: `conv_to_float`
- `8`: `conv_to_bool`
- `9`: `conv_to_string`

### New Capability Bits
- bit `3` (`1 << 3`): `core_bytelen`
- bit `4` (`1 << 4`): `conv_to_int`
- bit `5` (`1 << 5`): `conv_to_float`
- bit `6` (`1 << 6`): `conv_to_bool`
- bit `7` (`1 << 7`): `conv_to_string`

## Semantics Contract

- Host conversion semantics must match guest VM semantics exactly:
  - conversion success/failure behavior
  - truncation rules for `to_int`
  - truthiness behavior for `to_bool`
  - UTF-8 byte length behavior for `core_bytelen`
- On capability mismatch, guest either:
  - falls back to VM-local implementation, or
  - returns `HostCapabilityMissing` for host-required policies.

## Rollout Steps

1. Extend `runtime/host_abi.zig` with v2 IDs/bits.
2. Update host reference implementation.
3. Add VM dispatch branch for v2 capabilities.
4. Add parity tests that run both embedded and host backends and diff outputs.
5. Keep v1 compatibility path until host fleet migration completes.

## Non-Goals

- No breaking changes to `ValueWire` layout in this phase.
- No implicit behavior changes for existing v1 call IDs.
