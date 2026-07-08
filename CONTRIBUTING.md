# Contributing

Thanks for helping improve gengo.

## Development Flow

- Keep changes focused and small.
- Add or update spec cases in `tests/spec/` for behavior changes.
- Prefer explicit runtime errors over implicit behavior.

## Build Presets

Four presets are available: `256k` (constrained), `1m` (default), `16m` (large), `unlimited`.

Pass `-Dpreset=<name>` to any `zig build` command. For any change that touches the runtime, heap, or VM also run with GC stress enabled:

```bash
zig build -Dpreset=1m -Dgc_stress=true test
```

`-Dgc_stress=true` forces a GC on every allocation — the harshest check for unrooted-value bugs.

## Local Validation

Run these before opening a PR:

```bash
make wasi
make test
```

For runtime, heap, or VM changes also run:

```bash
zig build -Dpreset=1m -Dgc_stress=true test
```

If relevant, also run:

```bash
make bench
make parity
```

`parity` checks that the native and WASM backends produce the same output. Run it when touching the VM or compiler.

## Profiling

Build the timing binary and profile with DWARF call graphs:

```bash
zig build -Dpreset=1m cli-fast
perf record --call-graph dwarf -F 999 -- ./zig-out/bin/gengo-fast tests/bench/007_dispatch_loop.gengo
perf report
```

Do not trust call-graph percentages from plain `perf record -g` on the
ReleaseFast binary: frame-pointer unwinding misattributes inlined frames
(e.g. allocation helpers showing up hot inside functions that never
allocate). `--call-graph dwarf` resolves inline frames correctly.

For per-opcode counters and allocation stats, build with `-Dperf=true` and
check `std.core.gc_stats_ext()` from scripts (`alloc_object_calls`,
`gc_runs`, `gc_time_ns`). Timing baselines for the benchmark set live in
`tests/bench/time_baseline.txt`.

## Docs

The public docs site is sourced from `docs/` and built by Gengoscript itself
(`tools/site-builder/site-builder.gengo`). CI rebuilds and deploys it on every
push that touches `docs/`, the site builder, or the engine.

Build the static site locally:

```bash
zig build -Dpreset=1m cli
./zig-out/bin/gengo --cap fs --mount root=. tools/site-builder/site-builder.gengo
```

Preview it:

```bash
python3 -m http.server -d build/site 8001
```

Notes:
- `dev-docs/` and `archive/` are repo documentation, not part of the published docs site.
- `docs/changelog.md` is currently a site page that points to the canonical root `CHANGELOG.md`.
- Page reading order is the `chapterOrder` list at the top of the site builder; new pages land at the end until added there.

## Commits

- One logical change per commit.
- Message format: `<type>: <short description>` — e.g. `fix: ...`, `feat: ...`, `build: ...`, `docs: ...`.
- Do not include AI tool attribution in commit messages.

## Pull Requests

- Describe what changed and why.
- Mention user-visible behavior changes.
- Include any new/updated spec cases.

## Versioning

- The canonical version string is in `build.zig` (`gengo_version`).
  `sdk/typescript/package.json` is kept in sync with it at all times.
- Tag every breaking change. Tags follow `v<major>.<minor>.<patch>` (e.g., `v0.4.0`).
- `CHANGELOG.md` entries under the new version's date go into the tag message.

### Release cycle

The version string is never ambiguous about whether a build is a release:

1. The first commit after a release bumps `gengo_version` to the next
   version with a `-dev` suffix (e.g. `0.5.0-dev`). Binaries built from
   main during a cycle always identify as pre-release.
2. When the cycle is done, a release commit drops the `-dev` suffix and
   adds the version's `CHANGELOG.md` entries.
3. The annotated tag (`v0.5.0`) goes on that release commit, and a GitHub
   release is published from it.
4. The next commit starts over at step 1.

A tagged commit is therefore the only place a bare version string exists.
