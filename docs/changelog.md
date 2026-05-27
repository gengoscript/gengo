# gengo Changelog

This changelog tracks notable language/runtime changes by implementation date.

## 2026-05-27

### Language
- Added multiline string literals for both escaped (`"`) and raw (`'`) modes.
- Added explicit multiline continuation marker behavior based on opening-quote indentation column.
- Added function parameter annotation support in both forms:
  - `param: Type`
  - `param Type`
- Added anonymous-function typed-parameter parser regression coverage (`t.value` selector case).
- Added `std.conv` namespace:
  - `to_int`
  - `to_float`
  - `to_bool`
  - `to_string`
- Switched string semantics to UTF-8 rune-oriented behavior:
  - `std.core.len` counts runes
  - string index/slice operate on rune positions
  - string iteration yields runes and rune indexes
- Added `std.core.bytelen` for raw UTF-8 byte length.
- Added first-class `rune` scalar and rune literals using backticks (single code point).
- Added rune/number numeric operator compatibility and cast coverage.

### Runtime / VM
- Added first-class `error` value helpers:
  - `std.core.error(msg)`
  - `std.core.is_error(v)`
- Added map/array/tuple multi-assignment and multi-return destructuring support.
- Added `switch` support (`case`/`default`, no fallthrough).
- Added GC-managed dynamic strings and managed collection storage paths.
- Added mark-sweep GC improvements:
  - proactive object threshold collection
  - heap-pressure-triggered collection
  - temp GC roots for in-flight allocations during native/build paths
  - stale/non-live object guard during mark traversal
- Added `std.core.gc_stats()` with:
  - `heap_used_bytes`
  - `heap_size_bytes`
  - `live_objects`
- Enabled host-backend parity for VM-local natives (`core.error`, `core.is_error`, `core.gc*`, `conv.*`) by executing them in guest VM.

### Limits / Memory
- Increased runtime heap arena default to `512 KiB`.
- Fixed managed block free behavior for dynamic-string class-sized blocks.
- Added build-time runtime limit presets:
  - `runtime/config_dev.zig`
  - `runtime/config_tiny.zig`
  - `runtime/config_stress.zig`
  - Make targets: `config-*`, `wasi-tiny`, `wasi-stress`

### Conformance
- Expanded spec coverage across:
  - struct contracts and methods
  - closures/upvalues
  - iteration forms
  - multi-return and path assignment
  - GC stress and dynamic string churn
  - multiline string pass/fail cases
- Added benchmark suite harness:
  - `examples/bench/*` with checked outputs
  - `tests/run_bench.sh`
  - Make targets: `bench`, `bench-tiny`, `bench-stress`
  - bench `.policy` support (`ALLOW_OOM`) for expected low-memory outcomes
  - `GENGO_BENCH_STATS=1` mode for elapsed/ops reporting
- Added backend parity harness:
  - `examples/parity/*`
  - `tests/run_host_parity.sh`
  - Make target: `parity`
- Added host-backend graceful fallback when host import is unavailable.

### Planning
- Added Host ABI parity roadmap document: `docs/host-abi-v2-plan.md`.

## 2026-05-26

### Language Foundation
- Established `std`-only import policy (`import("std")`).
- Added named function declaration sugar (`func name(...) { ... }`).
- Added strong struct contracts with typed/nullable/union fields.
