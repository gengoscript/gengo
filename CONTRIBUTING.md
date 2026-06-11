# Contributing

Thanks for helping improve gengo.

## Development Flow

- Keep changes focused and small.
- Add or update spec cases in `tests/spec/` for behavior changes.
- Prefer explicit runtime errors over implicit behavior.

## Build Presets

Three presets are available: `dev` (default), `tiny` (constrained limits), `stress` (larger heap, stress-tests memory).

Pass `-Dpreset=<name>` to any `zig build` command. `make test` uses `dev`. For any change that touches the runtime, heap, or VM also run:

```bash
zig build -Dpreset=stress test
```

The stress preset allocates a much larger inline heap (`~4 MB` for `Runtime`) and is the harshest test for stack and memory correctness.

## Local Validation

Run these before opening a PR:

```bash
make wasi
make test
```

For runtime, heap, or VM changes also run:

```bash
zig build -Dpreset=stress test
```

If relevant, also run:

```bash
make bench
make parity
```

`parity` checks that the native and WASM backends produce the same output. Run it when touching the VM or compiler.

## Docs

The public docs site is sourced from `docs/` and built with `mkdocs`.

Install the local docs dependency:

```bash
python3 -m pip install -r requirements-docs.txt
```

Run a local preview server:

```bash
python3 -m mkdocs serve
```

Build the static site:

```bash
python3 -m mkdocs build
```

Notes:
- `dev-docs/` and `archive/` are repo documentation, not part of the published docs site.
- `docs/changelog.md` is currently a site page that points to the canonical root `CHANGELOG.md`.

## Commits

- One logical change per commit.
- Message format: `<type>: <short description>` — e.g. `fix: ...`, `feat: ...`, `build: ...`, `docs: ...`.
- Do not include AI tool attribution in commit messages.

## Pull Requests

- Describe what changed and why.
- Mention user-visible behavior changes.
- Include any new/updated spec cases.
