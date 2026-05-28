# gengo Quickstart

## Required Tools

- Zig `0.16.0` (same version used by CI)
- wasmtime (WASI preview1)

## Build

Default (dev preset):

```bash
zig build -Dpreset=dev wasi
```

Tiny preset:

```bash
zig build -Dpreset=tiny wasi
```

Stress preset:

```bash
zig build -Dpreset=stress wasi
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
WASMTIME_BIN=/path/to/wasmtime zig build -Dpreset=dev test
```

## Host/Embedded Parity

```bash
WASMTIME_BIN=/path/to/wasmtime zig build -Dpreset=dev parity
```

## Benchmarks

Default:

```bash
WASMTIME_BIN=/path/to/wasmtime zig build -Dpreset=dev bench
```

Tiny and stress presets:

```bash
WASMTIME_BIN=/path/to/wasmtime zig build -Dpreset=tiny bench
WASMTIME_BIN=/path/to/wasmtime GENGO_BENCH_INCLUDE_STRESS=1 zig build -Dpreset=stress bench
```

With benchmark timing/throughput logs:

```bash
WASMTIME_BIN=/path/to/wasmtime GENGO_BENCH_STATS=1 zig build -Dpreset=tiny bench
```

## Common Gotchas

- If behavior looks memory-constrained unexpectedly, re-apply dev preset:

```bash
zig build -Dpreset=dev wasi
```

- Bench cases may define `.policy` with `ALLOW_OOM` to mark expected low-memory failures.
- Heap OOM can happen even with free bytes available when a single requested managed block exceeds the current class cap (`32 KiB`).

## Nano Syntax Highlighting

```bash
echo 'include "./docs/gengo.nanorc"' >> ~/.nanorc
```

## Next Step

- Follow `docs/tutorial-first-script.md` for a step-by-step first script walkthrough.
