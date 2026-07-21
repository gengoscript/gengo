# Gengoscript Developer Docs

This directory holds contributor and project-internal documentation rather than end-user docs.

Contents:

- `testing.md` — conformance and benchmark harnesses
- `roadmap.md` — current open items and exit criteria
- `opcodes.md` — VM opcode reference (fused-op internals; not public language semantics)
- `design/compiler-architecture.md` — compiler conceptual reference: single-pass Pratt parser, expression/statement/declaration compilation, type system, scope/upvalues, module resolution
- `design/vm-architecture.md` — bytecode VM conceptual reference: values, stack, chunk format, GC, call protocol, peephole fusions, invariants
- `design/gbc-spec.md` — bytecode cache format specification
- `perf/metrics.md` — performance instrumentation reference
- `perf/baseline-2026-06-01.md` — recorded benchmark baseline
- `documentation-inventory.md` — public-docs coverage audit baseline
- `documentation-contradictions.md` — recorded documentation/implementation contradictions and their resolutions
- `documentation-plan.md` — remaining public-documentation work
- `feature-matrix.md` — feature/API implementation and test-coverage matrix

Historical design records that no longer define the current public behavior live in `../archive/`.
