# Project status and compatibility

## Documentation identity

This site documents **Gengoscript 0.5.1-dev**, built from the **main branch**.
It is pre-1.0 and describes unreleased work unless a page explicitly names a
release tag. Each generated page banner includes the checkout commit when it
is available. Release documentation must be generated from its annotated
release tag. See `changelog.md` for released and pending changes.

## Compatibility

| Surface | Current main-branch status | Compatibility note |
|---|---|---|
| CLI (`gengo`) | Unreleased | Native CLI and WASI CLI are built from this checkout. |
| Native engine library | Unreleased | C API is in `sdk/c/include/gengo-engine.h`; ABI version is 2. |
| WASM engine | Unreleased | `build/debug/gengo-engine.wasm`; browser hosts provide imports. |
| TypeScript package | Unreleased | `@gengo/engine` version must match `build.zig`. |
| Zig | 0.16.0 | Required by this checkout and CI. |
| Native host | Linux tested in this checkout | Other shared-library names are target-dependent; verify a release artifact. |
| WASI host | Wasmtime used in CI | Browser WASM has a distinct import and capability model. |

The project has not declared a stable language or Host ABI compatibility
policy. Hosts must require an exact Host ABI version match and should pin an
engine release rather than consume `main`.

## Authority hierarchy

When sources disagree, use this order: passing conformance/specification tests;
compiler and runtime behaviour; exported headers/APIs; release-tagged docs;
examples and SDK docs; main-branch docs; then changelog statements. Practical
consequences of unresolved discrepancies are recorded in `known-limitations.md`;
the full evidence trail is contributor-facing, in
`../dev-docs/documentation-contradictions.md`.
