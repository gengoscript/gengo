# gengo Quickstart

## Required Tools

- Zig `0.16.0` (same version used by CI)
- wasmtime (WASI preview1)

## Build

Default (dev preset):

```bash
make config-dev
make wasi
```

Tiny preset:

```bash
make wasi-tiny
```

Stress preset:

```bash
make wasi-stress
```

## Run a Script

```bash
wasmtime --dir . ./gengo-test.wasm -- path/to/script.gengo
```

With backend selection:

```bash
wasmtime --dir . ./gengo-test.wasm -- --backend embedded path/to/script.gengo
wasmtime --dir . ./gengo-test.wasm -- --backend host path/to/script.gengo
```

## Conformance

`test` always resets to dev preset first.

```bash
make test
```

## Host/Embedded Parity

```bash
make parity
```

## Benchmarks

Default:

```bash
make bench
```

Tiny and stress presets:

```bash
make bench-tiny
make bench-stress
```

With benchmark timing/throughput logs:

```bash
GENGO_BENCH_STATS=1 make bench-tiny
```

## Common Gotchas

- If behavior looks memory-constrained unexpectedly, re-apply dev preset:

```bash
make config-dev
```

- Bench cases may define `.policy` with `ALLOW_OOM` to mark expected low-memory failures.
- Heap OOM can happen even with free bytes available when a single requested managed block exceeds the current class cap (`32 KiB`).

## Nano Syntax Highlighting

```bash
echo 'include "./docs/gengo.nanorc"' >> ~/.nanorc
```

## Next Step

- Follow `docs/tutorial-first-script.md` for a step-by-step first script walkthrough.
