# Improvement Plan — July 2026

Outcome of a Zig-Zen review of the codebase plus the fib(32) call-overhead
hunt (see `bench/cross-engine/RESULTS.md` 2026-07-18 entry and commits
`4600f43`, `dcdb578`). Three tracks: architecture debt, safety hardening,
performance. Ordered execution plan at the bottom.

Status legend: `[ ]` open · `[~]` in progress · `[x]` done (with commit)

---

## Track A — Architecture debt

### A1. Kill `setActive` — finish the `VMContext` migration `[x]`

The threadlocal active-pointer pattern (`chunk.setActive`, `heap.setActive`,
`vms.setActive`, `globals.setActive`, `VMContext.fromActive`) coexists with
explicit `VMContext` passing — the last "two ways to do the same thing" in
the VM, and the cause of the #190 cross-runtime stomping bug.

Scope (measured 2026-07-18): ~90 `setActive` call sites across 12 files,
~80 `fromActive`/`g_state` uses. Leaf offenders that reach for globals:
`heap.zig`, `value.zig`, `native/fs_state.zig`, `globals.zig`.

Plan: migrate file-by-file, leaves first (thread a context/allocator handle
into heap and value), engine/runtime entry points last; delete the
threadlocals and `fromActive` when the count reaches zero. Tests stay green
at every step. Medium-large effort, low per-step risk.

Survey findings (2026-07-18): VM + natives are already clean — zero
module-level heap calls, everything via `ctx.hs`. `value.zig`'s
`obj_pool_ptr` threadlocal is a deliberate perf exception (packed 16-byte
Value decode needs a pool base pointer) and stays, repointed on activate.

- Phase 1 `[x]` compiler: all 66 `heap.bump`/`heap.allocObject` calls now go
  through an explicit `Compiler.hs` handle latched at init (like `cs`);
  generics helpers (`substituteSpec`/`instQNameFromBase`/`buildInstKey`) and
  `fieldTypeAltLabel` take `hs` params.
- Phase 2 `[x]` production wrapper callers migrated: module_compile.Session
  carries an explicit `hs` (set by Runtime.initCompileSession / test
  harnesses) and uses `compiler.cs` for chunk emission; runtime.zig uses
  `self.heap_state`. The delegating wrappers remain but are fenced with a
  TEST/ENTRY-POINT ONLY comment — their only callers are the
  hand-assembled-bytecode test runners and the WASM export layer, which
  cannot receive a context.
- Phase 3 `[x]` `fs_state.lookup/resolve` take an explicit `*EngineState`;
  cap_fs reads it via `ctx.vs.fs_es`, bound per-runtime in `activate()` (not
  init — the Runtime struct may move by value before first use; entry points
  all run on the pinned address). The threadlocal remains only for the
  CLI --mount pre-runtime flow and the entry layer. The #190 isolation test
  now asserts the stronger property: each runtime's binding stays correct
  regardless of which runtime activated last.
- Phase 4 `[x]` `Compiler.init(src, cs, hs, options)` takes explicit state;
  production passes its runtime's own, test runners pass the module
  defaults explicitly. Endpoint reached: the only remaining active-state
  readers are the state modules' own fenced entry machinery (vm.run's
  setActive block, which also repoints value.zig's `obj_pool_ptr` — the
  documented perf exception for packed Value decode), the CLI --mount
  pre-runtime flow, the WASM export layer, and tests. Production
  compiler/VM/runtime code reads no hidden active state.

### A2. Consolidate the peephole trackers `[ ]`

16 `last_*_pos: ?usize` fields in `chunk.zig`, each with its own implicit
set/clear contract against `patchJump`/`emitLoop`/`emitByte`. Replace with a
small ring buffer of the last N emitted instructions `{ op, pos }` and a
single `invalidate()`; fusions pattern-match on the window.

Acceptance: `tools/perf-baseline.sh check` byte-identical (op counts prove
fusion decisions unchanged) + defuse differential green. Medium effort,
medium risk — do in one commit, revert-friendly.

Survey 2026-07-18: the invalidation is NOT uniform — 9 wholesale clear
blocks with 5 distinct tracker subsets (8/8/8/9/10/13/15/15/17 clears at
chunk.zig lines ~236, 831, 850, 871, 893, 911, 939, 980, 1000). Which
trackers deliberately survive which boundary is load-bearing for fusion
decisions, so the ring-buffer redesign needs per-block analysis first:
for each block, determine whether its subset is intentional (a fusion
that legitimately spans that boundary) or accidental drift. The
acceptance harness catches both failure directions (over-invalidation →
op counts change; under-invalidation → defuse differential/tests), so
iterate against it. Needs a fresh session with full attention — do not
attempt as a tail-end task.

### A3. Concrete types at module seams `[x]` (2026-07-18)

Replace `state: anytype` in `chunk_verifier.zig`/`chunk_decoder.zig` with
`*chunk.State` (breaking whatever import cycle motivated it — forward-decl
or a small shared-types module). Explicitly out of scope: the compiler's
`c: anytype` threading (~79 sites) — one consistent internal idiom, not
worth the churn.

### A4. Narrow error sets `[x]` — declined with reasoning (2026-07-18)

33 `anyerror` signatures in `src/lang/`, including `execOne`'s
`anyerror!bool`. Define `VmError`/`CompileError` sets for the public
surfaces so callers get exhaustive-switch checking. Do after A1 to avoid
fighting the same files twice.

Declined after survey: 151 distinct error tags exist, and no consumer
performs exhaustive error switching — the API boundary maps errors via
result unions and `@errorName` strings. Because the VM call graph is
recursive, Zig requires *explicit* (not inferred) sets on every signature
in the cycle, so a full enumeration is a permanent maintenance tax with
no safety payoff today. Revisit only when a consumer that switches on
error sets appears (the GBC loader is the likely candidate).

### A5. Verifier scratch memory `[x]` (2026-07-18)

`chunk_verifier.verify` allocates its depth array + worklist from
`page_allocator` per verify — the only ad-hoc allocation in an otherwise
statically-allocated core. Route through the runtime's allocator or a fixed
scratch region (code capped at 1 MiB → bounded worst case). Small.

Done: verify(state, alloc) — vm.run passes the runtime's allocator
(vs.allocator); the module-level test wrapper passes page_allocator
explicitly. A fixed scratch region was rejected: worst case is ~24 MB for
1 MiB of code. Done together with A3: decoder/verifier signatures are now
`*const chunk.State` / `*chunk.State` — the import cycle the `anytype`
presumably dodged is legal lazy analysis in Zig.

## Track B — Safety hardening

### B1. Debug assertions in `vmPushU`/`vmPopU` `[x]`

After `dcdb578` these are the only two functions where a verifier bug
corrupts memory instead of crashing. Add Debug-mode bounds asserts (free in
release) so Debug test runs + fuzz verify the verifier's stack-bound
guarantee on every push/pop instead of trusting it. Tiny.

### B2. Transient-peak invariant as a tested property `[x]`

The unchecked-op safety argument ("pops precede pushes within an op; the
op's declared stackEffect covers the transient peak") lives in comments.
Add a Debug-build check: record `stack_top` at dispatch, assert on the next
dispatch that the excursion stayed within the declared envelope. Catches any
future handler that pushes beyond its declared effect. Small, pairs with B1.

Done 2026-07-18. Found two real table bugs on day one: `get_field` was
modeled pop=0 (actual pop=1 — receiver) and `set_field` pop=1 (actual
pop=2 — value + receiver); both under-modeled pops are underflow-soundness
holes relevant to GBC (external bytecode). Exempt from the exact-net check:
call/ret families (frame semantics), `iter_next1/2` (variable effect, table
declares max), `loop`/`set_global_loop` (tryInlineGetGlobal swallows the
next instruction's push).

Follow-up surfaced (add to backlog): the verifier's first-visit-wins depth
marking tolerates path-dependent depth divergence (iterator exhaustion path
is 1 shallower than modeled). Harmless for compiler-emitted bytecode;
should become a hard verifier error before GBC accepts external bytecode.

### A6. Native-lane coverage for language semantics `[ ]` (added 2026-07-19)

Mikael's observation, proven by the enum-assignment regression: language
cases live overwhelmingly in the spec/.gengo conformance suite (wasmtime
lane) and the stress scripts — the slowest gates. The enum bug passed the
dev suite, fuzz, and perf-baseline, and was caught only by the pre-push
battery's stress-script lane.

Practice going forward (start applying immediately, backfill
opportunistically):
1. Every language-semantics fix gets a NATIVE test in compiler_test.zig
   alongside (not instead of) its spec case.
2. Prefer bytecode-shape assertions (compile + walk with chunk.decodeAt,
   assert op presence/absence) where the bug is a miscompile — they catch
   it in microseconds with no execution, and the pattern already exists
   (see "enum-typed assignment emits no constructor call").
3. Candidates for backfill: the typed-assignment prolog/epilog matrix
   (prim/named/erased/enum × :=/var/compound/incdec/named-return), fusion
   decisions, call-flag emission (0x80), return-proof stamping.

The spec suite remains the semantics-of-record; the native lane exists so
regressions die at `zig build test` speed instead of pre-push speed.

Progress 2026-07-19: native spec-pass output conformance landed — all
top-level spec cases now diff stdout+stderr against .out natively in
chaos_spec_test (previously only the wasm runner compared output; the
defused differential discarded it). Found on day one: 327's spec case used
the reserved `message` keyword as a variable name. Native fuzz landed
2026-07-19: fuzz_runner is dual-target (std.start entry on both), the
fuzz-native step runs the full corpus against native codegen — where the
unchecked stack ops, proof flags, and fused handlers actually live — and
the pre-push hook runs it before the wasm lanes. vm_value/vm_safety
runners are dual-target too (2026-07-19): the vm-native step runs them on
host codegen and `zig build test` gates both targets. Remaining:
parity-lane corpus expansion (only 2 files today) and the A6
bytecode-shape backfill.

## Track C — Performance (fib call-overhead hunt, remaining items)

Context: fib(32) 0.45s vs Python 0.19s (realistic target), Lua 0.095s
(needs register-VM redesign — out of scope). Per-call budget analysis in
the 2026-07-18 session: bytecode is already optimal (~3.8 dispatches/call);
cost is in call/return machinery.

### C1. "Args pre-verified" call-site flag `[x]`

The compiler statically rejects wrong-prim args at direct call sites
(compile-time prim checks, commits `a02da24`..`66d1963`), yet the VM still
runs `enforcePrimitiveFuncArgTypes` on every warm call (fib pays it per
call for `x int`). Encode one "types proven" bit at fused call sites and
skip enforcement when set. Biggest remaining identified per-call cost.

Done 2026-07-18. Measured ceiling was 0.44s → 0.33s with enforcement
removed outright; landed win: fib(32) decl form 0.44 → 0.385s. Encoding:
0x80 on the call argc byte (args capped at 64), flowing unchanged through
fusion and defuse; verifier/disasm mask it. Soundness required a language
decision (Mikael, 2026-07-18): **`func name()` declarations are immutable**
(Go semantics) — assignment is a compile error — because call sites are
checked against the declared signature. `name := func(...)` stays mutable
and is never flagged. Recursive self-calls resolve through a new
in-progress-signature stack (registration happens post-body), which also
extends the compile-time arg checks to recursion. C3 is moot.

### C4. Return-side proof flag `[x]`

`checkPrimitiveReturn` runs on every return from a typed-return function
(measured ~1-2% incl. the isPrimitiveReturn derefs in canReturnFast). The
compiler can prove return sites the same way C1 proved args: track
"all return sites proven" per function body (ExprPrimInfo vs declared
return types, prim single-alt only), stamp a `returns_proven` bit on
FuncObj, and let frame entry store `has_typed_returns and !returns_proven`.
Sound regardless of binding mutability — the proof is about the function's
own body. Bonus: provable mismatches become compile errors, implementing
the previously deferred return-type compile checking.

Done 2026-07-18 (d798578): fib(32) 0.32 → 0.31s. Soundness: the implicit
end-of-body null return must be unreachable — proven only when the body's
last top-level statement is a return (body_ends_with_return, tracked at
body block depth); bare returns clear the proof. Fixed in passing:
tryTailCall reused the frame without updating has_typed_returns /
named_return_count / func_arity — a tail call into a typed-return function
skipped return enforcement entirely (pre-existing hole). Fail test 325.

### C5. Immediate-operand fused variants `[x]` — resolved without new opcodes

From the Lua comparison (LTI/ADDI embed small ints in the instruction):
our hot fused ops load constants through the pool (`consts[idx]`) — two
pool indirections per fib node. Add i16-immediate variants of the hottest
const-fused ops using reserved opcode slots. Small win (~2-4%), moderate
surface (compiler emit, VM, verifier, defuse, disasm, opcodes.md) — do
after C2/C4, measure per the house rule.

Resolved 2026-07-18 the zero-opcode way: `constAtU` — unchecked const
access for indices the verifier already validates (chunk_verifier pass 1
rejects any decoded const_index >= const_count; audited that every
opConst/readLocalSlotAndConst caller is a decoder-extracted op; the one
unvalidated second index, cglsc's global-name idx, is cold-path-only and
keeps constAt). fib 0.305 → ~0.295s, loop_sum 0.37 → 0.36s. True i16
immediates would additionally save the 16-byte pool load, but each new
opcode costs icache (the reserved-slot padding experiment measured ~0.7%
per instantiated op) — the remaining margin doesn't clear that bar.
Revisit only with profile evidence.

### C6. Warm-IC invariant re-check `[x]` — measured out (2026-07-18): disabling it entirely is within noise on fib; the three compares ride on FuncObj data the frame entry loads anyway. Keep the check.

Three loads+compares per warm call re-verify arity/variadic/defaults
because GC pool-slot reuse can swap objects. Compile-time function objects
are const-rooted (never collected) — but ICs also cache runtime closure
objects, which die and free their slots, so naive pinning doesn't work.
Needs a design (e.g. pin function objects only + IC records whether it
cached a pinned object). Investigate before building.

### C2. Frame slimming `[x]`

8-field frame write per call includes fields most functions never use
(`defer_base`, `named_return_count`, `has_typed_returns`). Investigate
packing/lazy-fill. Measure-first (house rule: no claimed win without cycle
evidence).

Done 2026-07-18. The closure/func_obj pointer pair merged into one `callee`
(the invoked object; function derives from it), defer_base narrowed to u16.
Key lesson: the resulting 24-byte frame was ~9% SLOWER on fib — a
non-power-of-2 stride turns frames[frame_top] into a multiply (same disease
as the old IC pool-index division). Padded back to 32-byte stride with an
unwritten `_stride_pad`: best of both (fewer stores, shift indexing).
fib(32) ~0.305s. **Rule: hot-array element sizes must be powers of two.**

### C3. Precomputed prim-tag array (C1 fallback) `[x]` — moot, C1 landed fully

### Strategic note — decide Tier 2 vs Tier 3 before GBC (2026-07-18)

Bytecode-level comparison of fib across engines: Gengo dispatches ~4
instructions per call node vs Lua's ~10 and CPython's ~13, but at ~53
cycles per dispatch vs Lua's ~6 and CPython's ~10. Dispatch count is
already best-in-class — further fusion is pennies (quantitative
vindication of the opcode-caution policy). The gap is per-instruction
cost: 16-byte Value stack traffic (doReturn's movups = 60% of its time),
frame writes, IC re-verification, pool indirection.

- Tier 2: **TOS-in-register caching** (thread a tos: Value through the
  labeled-switch dispatch) — the last big win inside the stack ISA;
  compatible with GBC's frozen wire format. Est. 0.32 → ~0.22-0.25.
- Tier 3: register VM — Lua parity (~6 cycles/insn) but a new ISA.
  **Must be decided before GBC ships a stable bytecode format**; after
  that it means a translation layer or breaking the cache.

Also: --disasm prints ??? for call_global_local_sub_const's trailing
call-IC bytes — cosmetic decoder-width gap, fix in passing.

If C1's encoding is unpalatable: store expected `VTag` per param at FuncObj
creation so enforcement is a tag-compare loop with no `matchesTypeAlt`
calls.

---

## Execution order

1. **B1 + B2** — closes the one safety trade made by `dcdb578`. (start here)
2. **A1** — the debt that compounds; every new file written against
   `fromActive` adds migration cost.
3. **C1** — next fib win; benefits from the compile-time type work being
   fresh.
4. **A5, A3** — small, independent, good gap-fillers.
5. **A4** — after A1.
6. **A2** — satisfying but low urgency; only hurts when adding fusions,
   which the opcode-caution policy already rate-limits.
7. **C2/C3** — opportunistic, measure-first.
