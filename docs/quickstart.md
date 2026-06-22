# Gengoscript Quickstart

This page covers the shortest path to building Gengoscript, running a script, and checking that the local toolchain works.

For a guided first example, see `tutorial-first-script.md`.

## Requirements

- Zig `0.16.0` ([download](https://ziglang.org/download/))
- wasmtime ([download](https://wasmtime.dev/)) available on `PATH`

## Build

Build the native CLI:

```bash
zig build -Dpreset=1m cli
```

Build the WASI runtime:

```bash
zig build -Dpreset=1m wasi
```

Build the embeddable engine artefacts:

```bash
zig build -Dpreset=1m engine-build
zig build -Dpreset=1m engine-native
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

### Allowing Extra Module Directories

By default, file imports are restricted to the script's own directory. Pass `--modules` (repeatable) to allow additional directories:

```bash
./zig-out/bin/gengo --modules /app/lib --modules /app/shared script.gengo
```

For the WASI binary, ensure wasmtime mounts any extra directories too:

```bash
wasmtime --dir . --dir /app/lib ./build/gengo-cli.wasm -- --modules /app/lib script.gengo
```

## Validate the Build

Run the conformance suite:

```bash
zig build -Dpreset=1m test
```

Run parity checks between the embedded and host backends when relevant:

```bash
zig build -Dpreset=1m parity
```

Run benchmarks when you need performance data:

```bash
zig build -Dpreset=1m bench
```

## Presets

Presets control the heap and stack budgets baked into the binary:

| Preset | Heap | Use |
|---|---|---|
| `256k` | 256 KiB | Constrained embedded targets |
| `1m` | 1 MiB | Default — CLI and general scripting |
| `16m` | 16 MiB | Production embedding / large workloads |
| `unlimited` | 256 MiB | No practical limits |

Apply a preset with `-Dpreset=<name>`.

For GC correctness testing, combine any preset with `-Dgc_stress=true` (forces GC on every allocation).

## Next Steps

- `tutorial-first-script.md` for a first script
- `embedding.md` for Zig embedding
- `engine-api.md` for C-compatible host integration
