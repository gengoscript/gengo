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

REDEFINED by the GBC design (see checklist below): rather than
consolidating the emission-time trackers, build the load/compile-time
instruction-selection pass and delete emission-time fusion entirely —
one fusion implementation serving both fresh compiles and cache loads.
Sequence after the Tier 2 decision (the pass emits whatever instruction
set the execution model lands on).

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
- **Design proposal (2026-07-19, from Mikael's WASM-prefix question):
  serialize the DEFUSED core-ops-only form as the wire format.** Fused ops
  are provably an optimization detail (vm_defuse + the differential test);
  keeping them out of the wire format means they need zero stability — no
  format bumps for new fusions (deletes gbc-spec.md §950's accepted cache
  invalidation), a ~90-op verification surface for external bytecode, and
  a correct-by-construction v1 load path (run defused; re-fuse at load as
  v2 — which makes A2's peephole consolidation load-bearing GBC
  infrastructure, since a window-based fuser is most of a bytecode-to-
  bytecode fusion pass). A WASM-style prefix byte was considered and
  rejected for the runtime encoding: in an interpreter the fused ops are
  the hot path (~4 dispatches/node on fib, all fused), and a prefix adds a
  fetch + second indirect jump per execution — engines with JITs pay
  prefix decode once per function, we would pay it every dispatch.
  Refinement (same discussion): under this scheme the separation is POLICY,
  not encoding — no prefix bytes, no hard numeric partition. Only the core
  set carries the reserved-slot freeze (it IS the wire format, append-only
  growth); fused opcode values become fully private and freely renumberable
  (the 0xC0 boundary demotes from contract to documentation, and fused can
  take any non-core slot if it outgrows its region). GBC snapshots the core
  opcode table into its own spec rather than referencing op.zig — identity
  mapping at load while values match, a byte-translation table if the
  runtime ever diverges. Prefix/namespace ops stay reserved for the one
  scenario that reopens the question: the runtime exceeding 256 ops.
- **Ratified architecture (2026-07-19 discussion): a VM-private instruction
  tier selected by a rewriting pass.** The wire carries only the stable
  semantic set; between verify and execute, a linear instruction-selection
  pass rewrites verified core bytecode into the VM's private specialized
  set (jump-target remapping included — vm_defuse already implements the
  reverse direction with the same ip-map machinery, and the defused
  differential test is the correctness harness, already green on every
  battery). Boundary, stated honestly: FUSIONS are derivable from bytecode
  patterns alone and live in the private tier; TYPED ops (add_int, future
  add_decimal) encode compile-time type facts a loader cannot re-derive,
  so they stay on the wire side (append-only growth — permitted by
  design). A hints side-section is the documented upgrade path if typed-op
  churn ever matters.
- **Consequence for A2**: the best resolution is no longer consolidating
  the 16 emission-time peephole trackers — it is DELETING them. The
  compiler emits plain core ops; the selection pass fuses, identically for
  fresh compiles and cache loads. One fusion implementation, testable in
  isolation against the differential, instead of two that must agree.
  A2 = build the pass, then remove the emitter peephole against the
  byte-identical perf-baseline acceptance harness.

### Specialization roadmap (opcode-space spending — AFTER the Tier 2 decision)

Mikael's direction 2026-07-19: the language is near feature-complete; spend
opcode space on optimization where it pays. The bar, measured: each
instantiated op costs ~0.7% icache tax on all code (the reserved-slot
padding experiment), and specialization pays only where dispatch+tag cost
dominates the operation's real work (the engine-comparison lesson).

Ranked candidates:
1. **std.conv lowering — free win, zero new ops**: to_int/to_string/
   to_float are semantically the existing cast_* ops; extend the std-call
   peephole to emit them directly, deleting full call overhead.
2. **Decimal benchmark, then maybe decimal ops**: no decimal benchmark
   exists; write one (billing-style workload) and measure the generic
   path's dispatch share. Decimal is the one generic-routed type where
   specialization might clear the bar (inline representation, modest work,
   compile-time provable operands via ExprPrimInfo, and Gengo's declared
   domain makes it plausibly hot). Bigint and string concat stay catch-all:
   their work dwarfs dispatch.
3. **Stdlib intrinsics as ops**: len (trivial work, full call cost —
   strongest candidate), append; precedent: the math intrinsics are
   already ops.
4. **Constant-key map access**: m["literal"] via get_index today;
   011_map_lookup_heavy exists to measure against.

Not ops: GC. Allocation sites already are ops; bytecode-visible collection
would encode today's GC strategy into chunks and buy nothing (gas provides
interruption points). Revisit only if a generational GC introduces write
barriers.

Sequencing: after the Tier 2 (TOS caching) decision — it rewrites every
handler, and specialized ops added before it get rewritten twice. Wire
format: under the serialize-defused design, specialized ops normalize to
their generic forms on the wire (like fusions), so this entire program
spends no format-stability budget.

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

**SPIKE RESULTS (2026-07-19, branch spike/tos-caching, commit 53fcc56):**
a lazy one-slot cache with only the ret family converted (3 ops) measures
fib 0.31 → 0.29 (-6%) with loop_sum at exact parity, full suite +
differential + both fuzz lanes green. Mechanism validated end-to-end;
unconverted ops are shimmed (spill-first) so correctness never depends on
conversion coverage — the full sweep can proceed incrementally, op by op,
against the always-green harness. Three binding implementation constraints
recorded in the spike commit (no errdefer in the dispatch fn: +80% icache
disaster; ts must be a register-promotable local, not a pointer param;
spill helper needs exec_call_modifier for wasm/native divergence).
Honest extrapolation: -6% from the smallest possible slice supports the
0.22-0.25 estimate directionally but does not prove it; each converted
op family will report its own number during the sweep. Decision framing:
even full Tier 2 lands ~3× Lua — if Lua parity is ever the goal, Tier 3
remains the only road; if the goal is comfortable CPython dominance in an
embeddable engine, Tier 2 suffices and preserves the ratified ISA + GBC
design unchanged.

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
