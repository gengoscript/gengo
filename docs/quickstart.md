# gengo Quickstart

## Required Tools

- Zig `0.16.0` (same version used by CI)
- wasmtime (WASI preview1)

## Build

Default (dev preset):

```bash
zig build -Dpreset=dev wasi    # WASM/WASI runtime
zig build -Dpreset=dev cli     # native CLI binary
```

Tiny preset:

```bash
zig build -Dpreset=tiny wasi
```

Stress preset:

```bash
zig build -Dpreset=stress wasi
```

## Native CLI

```bash
zig build -Dpreset=dev cli
./zig-out/bin/gengo script.gengo
```

Run with no arguments on an interactive terminal to start the REPL:

```bash
./zig-out/bin/gengo
# Gengo REPL  (Ctrl+D to exit)
```

The REPL auto-prints the value of top-level expressions.

## Engine Libraries

WASM engine:

```bash
zig build -Dpreset=dev engine-build
# build/gengo-engine.wasm
```

Native shared library (C/C++ FFI, same API as WASM):

```bash
zig build -Dpreset=dev engine-native
# zig-out/lib/libgengo-engine.so  (Linux)
```

See `include/gengo-engine.h` for the C API and `docs/engine-api.md` for the full reference.

## Run a Script (WASI)

```bash
wasmtime --dir . ./build/gengo-runtime.wasm -- path/to/script.gengo
```

With backend selection:

```bash
wasmtime --dir . ./build/gengo-runtime.wasm -- --backend embedded path/to/script.gengo
wasmtime --dir . ./build/gengo-runtime.wasm -- --backend host path/to/script.gengo
```

With instruction budget (runtime step cap):

```bash
wasmtime --dir . ./build/gengo-runtime.wasm -- --max-ops 100000 path/to/script.gengo
```

## Conformance

`test` always resets to dev preset first.

```bash
zig build -Dpreset=dev test
```

## Host/Embedded Parity

```bash
zig build -Dpreset=dev parity
```

## Benchmarks

Default:

```bash
zig build -Dpreset=dev bench
```

Tiny and stress presets:

```bash
zig build -Dpreset=tiny bench
zig build -Dpreset=stress bench
```

With benchmark timing/throughput logs:

```bash
GENGO_BENCH_STATS=1 zig build -Dpreset=tiny bench
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
echo 'include "./editors/nano/gengo.nanorc"' >> ~/.nanorc
```

## Next Step

- Follow `docs/tutorial-first-script.md` for a step-by-step first script walkthrough.
