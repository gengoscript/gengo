# Improvement Plan — July 2026

Live work queue. Completed items are one-line ledger entries at the bottom —
their full context lives in the referenced commits, code comments, and
`bench/cross-engine/RESULTS.md`; do not re-litigate them here.

---

## Open

### A2. Consolidate the peephole trackers

16 `last_*_pos: ?usize` fields in `chunk.zig`, each with its own implicit
set/clear contract against `patchJump`/`emitLoop`/`emitByte`. Replace with a
small ring buffer of the last N emitted instructions `{ op, pos }` and a
single `invalidate()`; fusions pattern-match on the window.

Survey 2026-07-18: the invalidation is NOT uniform — 9 wholesale clear
blocks with 5 distinct tracker subsets (8/8/8/9/10/13/15/15/17 clears at
chunk.zig lines ~236, 831, 850, 871, 893, 911, 939, 980, 1000). Which
trackers deliberately survive which boundary is load-bearing for fusion
decisions, so the redesign needs per-block analysis first: for each block,
determine whether its subset is intentional (a fusion that legitimately
spans that boundary) or accidental drift.

Acceptance: `tools/perf-baseline.sh check` byte-identical (op counts prove
fusion decisions unchanged) + defuse differential green. The harness
catches both failure directions (over-invalidation → op counts change;
under-invalidation → differential/tests). Needs a fresh session with full
attention — do not attempt as a tail-end task.

### A6. Native-lane test coverage (ongoing practice + backfill)

Practice (permanent): every language-semantics fix gets a NATIVE test in
compiler_test.zig alongside its spec case; prefer bytecode-shape assertions
(compile + walk with chunk.decodeAt, assert op presence/absence) when the
bug is a miscompile — they catch it with zero execution.

Backfill candidates: the typed-assignment prolog/epilog matrix
(prim/named/erased/enum × :=/var/compound/incdec/named-return), fusion
trigger decisions, call-flag emission (0x80), return-proof stamping.

### Parity-lane corpus expansion

`tests/parity/` holds 2 files. Point the parity mode (native CLI vs wasm
CLI output diff) at the full spec corpus to make it the real cross-target
gate; CI's wasm conformance sweep can then eventually retire.

### Docs: the 2026-07-18 language changes are undocumented

`docs/language.md` does not yet cover: `func name()` declarations are
immutable (assignment is a compile error; `name := func(...)` is the
mutable form); provable arg/return type mismatches at direct call sites
and return statements are now compile errors; and the clause words
(range, cycle, default, predicate, message) are contextual — usable as
identifiers — with only `type`/`subtype` reserved (decided 2026-07-19).
The reserved-words list needs updating accordingly. User-facing docs gap.

### GBC preparation checklist (before the bytecode cache accepts external chunks)

- **Decide Tier 2 vs Tier 3 first** — see strategic note below.
- Verifier: make path-dependent depth divergence a hard error
  (first-visit-wins marking currently tolerates it; the iterator
  exhaustion path is 1 shallower than modeled — found by the B2 net-effect
  assertion, harmless for compiler-emitted bytecode only).
- Decoder: extract and validate second const indices (e.g. cglsc's
  embedded global-name idx) so `constAt`'s checked path can be reasoned
  about uniformly.
- A4 revisit trigger: the GBC loader will be the first consumer that
  switches on error sets; define typed error sets then, not before.

### Strategic decision — Tier 2 vs Tier 3 (blocks GBC format freeze)

Bytecode comparison across engines: Gengo dispatches ~4 insns per fib call
node (Lua ~10, CPython ~13) at ~53 cycles each (Lua ~6, CPython ~10).
Dispatch count is solved; ALL remaining wins are per-instruction cost
(16-byte Value stack traffic — doReturn's movups is 60% of its samples —
frame writes, pool indirection).

- Tier 2: **TOS-in-register caching** (thread a tos: Value through the
  labeled-switch dispatch) — the last big win inside the stack ISA;
  compatible with GBC's frozen wire format. Est. fib 0.30 → ~0.22-0.25s.
- Tier 3: register VM — Lua parity (~6 cycles/insn) but a new ISA. Must be
  decided BEFORE GBC ships a stable format; after that it means a
  translation layer or breaking the cache.

### Minor

- `--disasm` prints `???` for `call_global_local_sub_const`'s trailing
  call-IC bytes (decoder-width gap in disasm) — fix in passing.

---

## Completed ledger (2026-07-18..19)

Zen review + fib hunt outcomes; details in the commits.

- A1 setActive migration, 4 phases — `cb5331a` `fc04f80` `901875e` `748e7dc`
- A3 concrete decoder/verifier types + A5 verifier allocator — `dba9ab7`
- A4 narrow error sets — declined with reasoning (see GBC checklist above)
- B1+B2 unchecked-op asserts + stackEffect verification (found the
  get_field/set_field table bugs) — `2e9a8bf`
- C1 args-preverified call flag + immutable func decls — `3a7620f`
- C2 frame slimming (callee merge, 32-byte stride rule) — `6f2549e`
- C3 moot (C1 landed fully); C6 measured out (re-check rides free)
- C4 return-proof flag + compile-time return checking — `d798578`
- C5 resolved zero-opcode via constAtU — `084415d`
- A6 progress: native spec output conformance — `ab323ae`; native fuzz
  lane — in `e7efc92`; native vm_value/vm_safety runners — `e7efc92`
- Related same-window work: reserved opcode slots `4600f43`, stack bounds
  `dcdb578`, profile-guided inlining `0f8d60e`, engine #203 `0bff256`,
  api.run provider fix `dc5521b`, enum-typed bindings `c3af28b`, native
  host modules `ff920e6`
