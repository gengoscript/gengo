# gengo Open Items

Things that are partially built or not yet complete.

---

## 1. GBC — Gengo Bytecode Cache

**Status:** spec complete (`docs/gbc-spec.md`), implementation not started.

GBC is a compiled module artifact that lets the runtime skip parsing and code generation for a known source file. It is not a heap snapshot.

Suggested first milestone: a minimal round-trip writer/reader for a simple script — no imports, one bytecode section, constants, functions, empty types, empty dependency table — then add validation failures one by one.

---

## 2. Standard Library Struct Migration

**Status:** not done, low urgency.

`std` namespaces (`std.io`, `std.math`, etc.) are currently backed by synthetic struct instances with `any`-typed fields. Field access works, but unknown field access gives a struct error rather than a clean module-missing diagnostic, and there is no static export information.

This becomes more relevant once the module system is used heavily. At that point migrating `std` to the same struct-backed module model as source modules would unify the mental model.

---

## 3. Exit Criteria

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
