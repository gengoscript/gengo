# gengo Open Items

Things that are designed or partially built but not yet complete.

---

## 1. Tail Call Optimisation

**Status:** not implemented.

Recursive functions work but deep recursion will overflow the call stack. No TCO pass exists in the compiler or VM. This is a known limitation for recursion-heavy programs.

When this matters: any algorithm expressed as mutual or deep self-recursion — most everything else is covered by `for`/`for-in`.

---

## 2. GBC — Gengo Bytecode Cache

**Status:** spec complete (`docs/gbc-spec.md`), implementation not started.

GBC is a compiled module artifact that lets the runtime skip parsing and code generation for a known source file. It is not a heap snapshot.

Suggested first milestone: a minimal round-trip writer/reader for a simple script — no imports, one bytecode section, constants, functions, empty types, empty dependency table — then add validation failures one by one.

---

## 3. Standard Library Struct Migration

**Status:** not done, low urgency.

`std` namespaces (`std.io`, `std.math`, etc.) are currently backed by synthetic struct instances with `any`-typed fields. Field access works, but unknown field access gives a struct error rather than a clean module-missing diagnostic, and there is no static export information.

This becomes more relevant once the module system is used heavily. At that point migrating `std` to the same struct-backed module model as source modules would unify the mental model.

---

## 4. Exit Criteria

These were the v0 exit criteria. They now apply to whatever the next milestone is declared to be:

1. All core capabilities are `done` and covered by conformance cases.
2. Conformance suite runs in CI on every PR.
3. No `partial` items remain without a written deferral note.
