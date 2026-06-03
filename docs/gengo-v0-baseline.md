# gengo v0 Baseline

This document defines the **minimum capability baseline** for `gengo v0`.

Important:
- gengo semantics may differ from other languages when that improves clarity, contracts, or safety.

## Status Legend

- `done`: implemented and covered in conformance
- `partial`: implemented but not complete for v0 goals
- `missing`: not implemented yet

## 1. Core Data Capabilities

1. Scalars (`number`, `boolean`, `string`, `null`, `error`): `done`
2. Arrays (literal/index/set/slice): `done`
3. Maps (literal/index/read/missing->null/set inserts): `done`
   - note: map field values are dynamic; overwriting a nested map field with a scalar may make later nested access fail with `TypeError` (for example `obj.a = 11` then `obj.a.b`)
4. Structs with strong contracts: `done`
5. Typed struct fields (`int/float/bool/string/array/map/struct`): `done`
6. Nullable/union typed fields (`?T`, `A|B`): `done`
7. Char/rune support: `done` (rune scalar + rune literals)

## 2. Control-Flow Capabilities

1. `if / else if / else`: `done`
2. `for` (condition style + C-style): `done`
3. `break` / `continue`: `done`
4. `switch` (`case`/`default`, no fallthrough): `done`
5. Sequence iteration (`for x in seq`): `done`
6. Map iteration (`for k, v in map`): `done`

## 3. Functions & Calls

1. Function literals: `done`
2. Named function sugar (`func name(...)`): `done`
3. Struct receiver methods (`func (u User) m(...)` + `u.m(...)`): `done`
4. Recursion: `done`
5. Closures/upvalues (capturing outer locals): `done`
6. Parameter type enforcement for function signatures: `done` (runtime call-boundary checks)

## 4. Standard Library Surface (`std`)

1. `import("std")`: `done`
2. `std.io.println(...)`: `done`
3. `std.core.len(...)`: `done`
4. `append(...)` capability (as gengo-native API): `done`
5. `error(...)` and `is_error(...)` capability (as gengo-native API): `done`
6. `gc()` and `gc_live_objects()` capability (as gengo-native API): `done`
7. `gc_stats()` capability (as gengo-native API): `done`
8. Conversion APIs (`std.conv.*`): `done`

## 5. Runtime/Backend Capabilities

1. Embedded native backend: `done`
2. Host native backend scaffold + ABI version/caps handshake: `done`
3. Host support for values beyond primitives/strings: `partial`
4. Host parity for all std natives: `partial`
5. Mark-sweep object GC (`std.core.gc()` trigger): `done` (object pool + managed dynamic string/owned array/owned map buffers)
6. Proactive GC threshold for object allocations: `done`
7. Managed heap pressure collection threshold: `done`
8. Dynamic string GC lifecycle coverage: `done`
9. Build-time tunable runtime limits via presets: `done`

## 6. Capability Coverage Buckets

The v0-ready capability requirements:

1. nested data + slicing: `done`
2. higher-order sequence operations via iteration + closures: `done`
3. append accumulation patterns: `done`
4. conversion/coercion examples: `done`
5. large-loop recursion pattern: `partial` (recursion yes, TCO not guaranteed)

## 7. v0 Priority Order

1. host backend parity for host-dispatched std APIs
2. optional panic/recover design (currently non-goal for v0)

## 8. Non-Goals for v0

1. Cross-language module compatibility (`import("fmt")`-style aliases)
2. Global compatibility aliases that dilute `std` namespacing
3. Silent weakening of struct contracts
4. try/catch-style exception syntax
5. mandatory panic/recover runtime model

## 9. Exit Criteria for v0

gengo v0 is considered baseline-complete when:

1. all items in Sections 1-4 are `done` except explicitly deferred by design note,
2. conformance suite covers each capability with pass/fail assertions,
3. CI runs `make test` on every PR touching gengo.

## 10. Change History

For dated implementation changes, see `docs/changelog.md`.

Host ABI roadmap notes are tracked in `docs/host-abi-v2-plan.md`.
