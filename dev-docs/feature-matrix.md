# Feature and API matrix

Audience: contributors and advanced users. “Tested” means a named
conformance, runner, or SDK test exists; it does not imply a stable release.

| Feature group | Implementation | Coverage | Version/status | Public reference | Limitation or contradiction |
|---|---|---|---|---|---|
| Lexical forms, literals, operators | Compiler/lexer | `tests/spec/` | Main / unreleased | `language.md`, `error-catalogue.md` | Full grammar and precedence still need normative extraction. |
| Built-ins and named scalars | VM type system | decimal/named-type specs | Main / unreleased | `language.md` | Named decimal scale is lost at Host ABI boundary; standalone `decimal` declarations are currently rejected. |
| Range, predicate, cycle, decimal | Compiler + VM | 163–167, 214, 218 specs | Main / unreleased | `language.md` | Predicate availability is configurable. |
| Structs, enums, variants, interfaces | Compiler + VM | struct/interface/variant specs, 323 top-level exhaustiveness regression | Main / unreleased | `language.md` | Variant exhaustiveness requires unguarded coverage or `default`. |
| Generics and constraints | Compiler | 285, 287, 290, 322 specs | Main / unreleased | `language.md`, `known-limitations.md` | Explicit constraints are checked; inferred constraint checks are currently skipped. |
| Arrays, maps, strings, runes | VM/native stdlib | spec and chaos cases, docs semantic fixture | Main / unreleased | `language.md`, `stdlib.md` | Map iteration/mutation semantics remain unspecified. |
| Functions, closures, defer/recover | Compiler + VM | closure/defer specs | Main / unreleased | `language.md` | Semantics need consolidation. |
| Modules/imports/test blocks | module compiler | import/cycle specs | Main / unreleased | `language.md` | No release guarantee. |
| Standard and capability namespaces | native descriptors | namespace/cap specs | Main / unreleased | `stdlib.md`, `capability-matrix.md` | Template normalization pending. |
| CLI/REPL | `src/main.zig` | CLI build/smoke | Main / unreleased | `quickstart.md`, `cli.md` | Commands require automated fixtures. |
| Zig API | runtime API | embedding runner | Main / unreleased | `embedding.md` | Compile-ready package setup pending. |
| C/native API | public header/engine | engine runner | Main / unreleased | `engine-api.md`, `host-abi.md` | Ownership and concurrency test coverage incomplete. |
| WASM API | engine exports | engine runner | Main / unreleased | `engine-api.md` | Pointer model differs from native. |
| TypeScript SDK | SDK source/tests | `sdk/typescript/test/wire-layout.mjs` | Main / unreleased | `typescript-sdk.md` | Numbers are lossy for large integers and decimals. |
| Runtime/security controls | runtime config | runners/config tests | Main / unreleased | `security.md`, `known-limitations.md` | Host callbacks are outside VM operation budget. |
