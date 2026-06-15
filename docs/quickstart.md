# Gengoscript Quickstart

This page covers the shortest path to building Gengoscript, running a script, and checking that the local toolchain works.

For a guided first example, see `tutorial-first-script.md`.

## Requirements

- Zig `0.16.0` ([download](https://ziglang.org/download/))
- wasmtime ([download](https://wasmtime.dev/)) available on `PATH`

## Build

Build the native CLI:

```bash
zig build -Dpreset=dev cli
```

Build the WASI runtime:

```bash
zig build -Dpreset=dev wasi
```

Build the embeddable engine artefacts:

```bash
zig build -Dpreset=dev engine-build
zig build -Dpreset=dev engine-native
```

Outputs:

- `zig-out/bin/gengo`
- `build/gengo-cli.wasm`
- `build/gengo-engine.wasm`
- `zig-out/lib/libgengo-engine.so` on Linux

## Run a Script

Native CLI:

```bash
./zig-out/bin/gengo script.gengo
```

WASI runtime:

```bash
wasmtime --dir . ./build/gengo-cli.wasm -- script.gengo
```

The `test`, `parity`, and `bench` build steps also invoke `wasmtime`. If it is not on `PATH`, pass `-Dwasmtime=/path/to/wasmtime` to the relevant `zig build` command.

Run the CLI with no arguments to start the REPL:

```bash
./zig-out/bin/gengo
```

## Validate the Build

Run the conformance suite:

```bash
zig build -Dpreset=dev test
```

Run parity checks between the embedded and host backends when relevant:

```bash
zig build -Dpreset=dev parity
```

Run benchmarks when you need performance data:

```bash
zig build -Dpreset=dev bench
```

For changes that touch the runtime, heap, or VM, also run:

```bash
zig build -Dpreset=stress test
```

## Presets

- `dev` is the default development preset.
- `tiny` uses tighter heap and stack limits for constrained embeddings.
- `stress` uses a larger inline heap and is the strongest check for memory behaviour.

Apply a preset with `-Dpreset=<name>`.

## Next Steps

- `tutorial-first-script.md` for a first script
- `embedding.md` for Zig embedding
- `engine-api.md` for C-compatible host integration
