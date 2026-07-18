# Improvement Plan — July 2026

Outcome of a Zig-Zen review of the codebase plus the fib(32) call-overhead
hunt (see `bench/cross-engine/RESULTS.md` 2026-07-18 entry and commits
`4600f43`, `dcdb578`). Three tracks: architecture debt, safety hardening,
performance. Ordered execution plan at the bottom.

Status legend: `[ ]` open · `[~]` in progress · `[x]` done (with commit)

---

## Track A — Architecture debt

### A1. Kill `setActive` — finish the `VMContext` migration `[~]`

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
- Phase 4 `[ ]` entry points: Compiler.init/test runners stop reading
  g_state; `setActive` shrinks to Runtime.activate repointing
  `obj_pool_ptr` only.

### A2. Consolidate the peephole trackers `[ ]`

16 `last_*_pos: ?usize` fields in `chunk.zig`, each with its own implicit
set/clear contract against `patchJump`/`emitLoop`/`emitByte`. Replace with a
small ring buffer of the last N emitted instructions `{ op, pos }` and a
single `invalidate()`; fusions pattern-match on the window.

Acceptance: `tools/perf-baseline.sh check` byte-identical (op counts prove
fusion decisions unchanged) + defuse differential green. Medium effort,
medium risk — do in one commit, revert-friendly.

### A3. Concrete types at module seams `[ ]`

Replace `state: anytype` in `chunk_verifier.zig`/`chunk_decoder.zig` with
`*chunk.State` (breaking whatever import cycle motivated it — forward-decl
or a small shared-types module). Explicitly out of scope: the compiler's
`c: anytype` threading (~79 sites) — one consistent internal idiom, not
worth the churn.

### A4. Narrow error sets `[ ]`

33 `anyerror` signatures in `src/lang/`, including `execOne`'s
`anyerror!bool`. Define `VmError`/`CompileError` sets for the public
surfaces so callers get exhaustive-switch checking. Do after A1 to avoid
fighting the same files twice.

### A5. Verifier scratch memory `[ ]`

`chunk_verifier.verify` allocates its depth array + worklist from
`page_allocator` per verify — the only ad-hoc allocation in an otherwise
statically-allocated core. Route through the runtime's allocator or a fixed
scratch region (code capped at 1 MiB → bounded worst case). Small.

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

## Track C — Performance (fib call-overhead hunt, remaining items)

Context: fib(32) 0.45s vs Python 0.19s (realistic target), Lua 0.095s
(needs register-VM redesign — out of scope). Per-call budget analysis in
the 2026-07-18 session: bytecode is already optimal (~3.8 dispatches/call);
cost is in call/return machinery.

### C1. "Args pre-verified" call-site flag `[ ]`

The compiler statically rejects wrong-prim args at direct call sites
(compile-time prim checks, commits `a02da24`..`66d1963`), yet the VM still
runs `enforcePrimitiveFuncArgTypes` on every warm call (fib pays it per
call for `x int`). Encode one "types proven" bit at fused call sites and
skip enforcement when set. Biggest remaining identified per-call cost.

### C2. Frame slimming `[ ]`

8-field frame write per call includes fields most functions never use
(`defer_base`, `named_return_count`, `has_typed_returns`). Investigate
packing/lazy-fill. Measure-first (house rule: no claimed win without cycle
evidence).

### C3. Precomputed prim-tag array (C1 fallback) `[ ]`

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
