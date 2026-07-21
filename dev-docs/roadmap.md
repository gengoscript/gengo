# Gengoscript Open Items

Things that are partially built or not yet complete.

---

## 1. GBC — Gengoscript Bytecode Cache

**Status:** spec complete (`dev-docs/design/gbc-spec.md`), implementation not started.

GBC is a compiled module artifact that lets the runtime skip parsing and code generation for a known source file. It is not a heap snapshot.

Suggested first milestone: a minimal round-trip writer/reader for a simple script — no imports, one bytecode section, constants, functions, empty types, empty dependency table — then add validation failures one by one.

---

## 2. Standard Library Struct Migration

**Status:** not done, low urgency.

`std` namespaces (`std.io`, `std.math`, etc.) are currently backed by synthetic struct instances with `any`-typed fields. Field access works, but unknown field access gives a struct error rather than a clean module-missing diagnostic, and there is no static export information.

This becomes more relevant once the module system is used heavily. At that point migrating `std` to the same struct-backed module model as source modules would unify the mental model.

---

## 3. Host-backend override parity has no real test coverage

**Status:** gap identified 2026-07-21, not scheduled.

The VM's `native_backend` policy (`--backend embedded`/`--backend host`) lets a host override built-in natives (`std.core.len`/`append`/`bytelen`, `std.conv.*`, `std.io.println` — the 8 `CAP_*` capabilities in `src/runtime/host_abi.zig`) with its own implementation, dispatched through `gengo_native_call`. No test ever registers a *real* alternate implementation and diffs its output against the embedded one.

`tests/parity/` (removed, see #205) ran the plain CLI/WASM binary under `wasmtime run` with `--backend host` — but `hasHostImport()` is gated on `builtin.target.cpu.arch == .wasm32 and root.is_embedded_engine`, true only for the `gengo-engine.wasm`/`libgengo-engine.so` embedding targets, never for the CLI. The CLI never registers `native_host_call_fn` either, so `nativeCallRaw` always returns `.unsupported` and every call falls back to the embedded path — `--backend host` on the CLI is architecturally a no-op, for any input, always. `engine_runner.zig`'s existing host-module tests only check that calling an *unregistered* host function produces the correct error; they don't register real implementations of the 8 override capabilities either.

Real coverage would need a native (or WASM component-model) test harness that registers a genuine `native_host_call_fn` implementing those 8 capabilities, runs scripts with `--backend host` against it, and diffs the result against both golden output and the embedded-backend result. That's new test infrastructure, not a corpus expansion.

---

## 4. Exit Criteria

1. All core capabilities are `done` and covered by conformance cases.
2. Conformance suite runs in CI on every PR.
3. No `partial` items remain without a written deferral note.

---

## Previously open — now resolved

| Item | Resolution |
|------|-----------|
| Host ABI v2 (`std.conv.*`, `std.core.bytelen` host dispatch) | Implemented: `a918f30` |
| Tail-call optimisation (self + mutual recursion) | Implemented: `e3cca78` |
| Multi-field variant arms (#45) | Implemented: `2b486d5` |
| Variant records — shared fields in variants (#46) | Implemented: `2b486d5` |
| Predicate closure collected by GC in long loops (#47) | Fixed: `21f85bd` |
| Per-instance resource limits (#57) | Implemented: `c5c75b6` |
| ValueWire silently drops structs/runes/named/error types (#70) | Fixed: `327b760` |
| Custom allocator in engine config (#71) | Implemented: `6e2332a` |
| `cap:fs` ~900 ms cold-start from `std.Io.Threaded` (#73) | Fixed: `cb7bb89` |
| `engine_last_error` unreachable after `engine_init_with_config` failure (#74) | Fixed: `19972f6` |
| Engine Improvement Plan (July 2026) architecture debt sweep | Redistributed 2026-07-20: durable content → `dev-docs/design/vm-architecture.md` §5.2/§6, standing test practice → `dev-docs/testing.md`, remaining work → issues #5, #204, #205, #206; historical record archived at `dev-docs/archive/improvement-plan-2026-07.md` |
