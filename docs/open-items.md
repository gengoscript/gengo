# gengo Open Items

Things that are designed or partially built but not yet complete.

---

## 1. GBC — Gengo Bytecode Cache

**Status:** spec complete (`docs/gbc-spec.md`), implementation not started.

GBC is a compiled module artifact that lets the runtime skip parsing and code generation for a known source file. It is not a heap snapshot.

Suggested first milestone: a minimal round-trip writer/reader for a simple script — no imports, one bytecode section, constants, functions, empty types, empty dependency table — then add validation failures one by one.

---

## 2. Exit Criteria

These were the v0 exit criteria. They now apply to whatever the next milestone is declared to be:

1. All core capabilities are `done` and covered by conformance cases.
2. Conformance suite runs in CI on every PR.
3. No `partial` items remain without a written deferral note.
