# Improvement Plan — July 2026 (archived)

This is the historical record of the July 2026 engine improvement plan. It no
longer defines current work — everything with lasting value has been
redistributed:

- Opcode-space policy (192/64 core/fused split, the rejected prefix-byte
  and unbuilt u16 alternatives) → `docs/opcodes.md` "Opcode space policy",
  `dev-docs/design/vm-architecture.md` §6.5, `src/lang/op.zig` comments.
- The fusion pass architecture (A2, redefined) →
  `dev-docs/design/vm-architecture.md` §6.
- TOS caching (Tier 2, the ratified Tier 2 vs Tier 3 decision, the spike
  results and implementation constraints) →
  `dev-docs/design/vm-architecture.md` §5.2.
- The native-lane test coverage practice (A6) → `dev-docs/testing.md`.
- Remaining open engineering work → GitHub issues #5 (GBC), #204 (native-lane
  test backfill), #205 (parity-lane corpus expansion), #206 (opcode
  specialization roadmap).

What follows is the original completed-items ledger, kept for commit-hash
traceability only.

---

## Completed ledger (2026-07-18..19)

Zen review + fib hunt outcomes; details in the commits.

- A1 setActive migration, 4 phases — `cb5331a` `fc04f80` `901875e` `748e7dc`
- A3 concrete decoder/verifier types + A5 verifier allocator — `dba9ab7`
- A4 narrow error sets — declined with reasoning (see GBC checklist, now GitHub issue #5)
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
- A2 (redefined): load-time fusion pass replaces the 16 emitter peephole
  trackers — `660e690` (phase A), `8f58d02` (phase B, full pattern
  parity), `4ea7207` (wired into production, trackers deleted, -525
  lines in chunk.zig). perf-baseline zero-change across 17 cases; see
  `dev-docs/design/vm-architecture.md` §6 for the design writeup.
- TOS caching spike (Tier 2), ret-family conversion, +6% on fib — branch
  `spike/tos-caching`, commit `53fcc56`; merged to main. See
  `dev-docs/design/vm-architecture.md` §5.2.
- Prefix-dispatch spike for fused opcodes (2026-07-20): built, measured
  (9% slower on fib_recursive, 25% slower on dispatch_loop), rejected,
  reverted in full. See `docs/opcodes.md` "Opcode space policy".
