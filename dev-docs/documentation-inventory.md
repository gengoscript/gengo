# Documentation inventory

Audience: maintainers and reviewers. This is the audit baseline, not a language
guarantee. Source locations were inspected on main branch 0.5.1-dev.

| Area | Primary evidence | Public location | Status |
|---|---|---|---|
| Language syntax and types | `tests/spec/`, compiler and VM | `language.md` | Implemented; breadth exceeds fully normative prose. |
| Standard library | native descriptors and spec tests | `stdlib.md` | Implemented; entries are not yet uniformly templated. |
| CLI and REPL | `src/main.zig` | `quickstart.md`, `cli.md` | Implemented. |
| Zig embedding | `src/runtime/api.zig` | `embedding.md` | Implemented; examples need compile fixtures. |
| C engine | `include/gengo-engine.h`, `src/engine.zig` | `engine-api.md` | Implemented; lifetime wording is incomplete. |
| Host ABI | `src/runtime/host_abi.zig` | `host-abi.md` | ABI v2; decimal scale is not encoded. |
| WASM engine | `src/engine.zig` exports | `engine-api.md` | Implemented; browser/WASI distinctions need expansion. |
| TypeScript SDK | `sdk/typescript/` tests and source | `typescript-sdk.md` | Supported source exists; public docs added as main-branch material. |
| Capabilities | compiler, native modules, engine API | `capability-matrix.md` | Four compile-time capability names exist. |
| Security controls | runtime config and engine API | `security.md` | Implemented controls; not an OS sandbox. |
| VM opcode table | `src/lang/op.zig` | Contributor-only | Removed from public generated navigation. |

The source-of-truth order is in `../docs/project-status.md`; the detailed
coverage matrix is in `feature-matrix.md`.
