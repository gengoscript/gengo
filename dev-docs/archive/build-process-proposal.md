# Build Process Proposal (archived, largely implemented)

Originally added 2026-07-18 alongside the commit that implemented most of
it (`099741e`, "build: make WASM artifacts reproducible and verified").
Was mistakenly placed under `docs/` (the published `docs.gengoscript.org`
site) instead of `dev-docs/` — nothing here is end-user or embedder
relevant. Moved here 2026-07-20; not re-verified line by line, but
confirmed substantially done at time of move: `runtime_config` build
module exists (Priority 1), `build/debug`/`build/release` distinct
install paths exist (Priority 2), a `wasm-opt` release artifact step and
`zig fmt --check` + `git diff --check` exist in CI (Priority 3). Kept for
historical traceability, not as a live checklist — if any acceptance
criterion below is still unmet, open a GitHub issue for it rather than
reviving this file.

## Goal

Make builds reproducible, composable, and explicit about which artifact they
produce. A build must not modify tracked source files or choose behaviour based
on optional tools found on `PATH`.

## Priority 1: Preset Configuration

Replace the copy of `src/runtime/config_<preset>.zig` over
`src/runtime/config.zig` with a `runtime_config` build module whose root source
is the selected preset file. Runtime code imports `runtime_config` rather than a
relative configuration file.

This removes worktree mutation, eliminates the preset-copy race, and lets Zig's
build graph and cache distinguish configurations without timing assumptions.

## Priority 2: Artifact Identity

Give Debug and release artifacts distinct install paths. Suggested layout:

```
build/debug/gengo-cli.wasm
build/release/gengo-cli.wasm
build/debug/gengo-engine.wasm
build/release/gengo-engine.wasm
build/test/gengo-cli.wasm
```

Test steps must name the artifact they execute. Release staging must consume the
release path only. A single `zig build` invocation may then safely request more
than one configuration.

## Priority 3: Tooling and Verification

- Repair or remove the obsolete `tiny` Make targets; `256k` is the supported
  constrained preset.
- Never optimise Debug output implicitly. Build a dedicated, explicit
  `wasm-opt` test artifact instead.
- Test the final ReleaseFast and `wasm-opt` release artifact before upload.
- Pin downloaded tool archives by SHA-256 and avoid piping remote installers to
  a shell.
- Add CI checks for `zig fmt --check` and `git diff --check`.
- Document the Wasmtime requirement and `-Dwasmtime=/path/to/wasmtime` override.

## Priority 4: CI Efficiency

Avoid executing the unit subset separately when the complete `test` step already
contains it. Keep separate jobs only where they validate a distinct build mode
or runtime configuration.

## Acceptance Criteria

- `git status --short` is unchanged after any build preset.
- Parallel Debug and release builds cannot overwrite each other's artifacts.
- Every documented Make target maps to a supported build preset.
- CI validates formatting, Debug test artifacts, and final release artifacts.
