# gengo Quickstart

## Build

Default (dev preset):

```bash
make -C userland/cmd/gengo config-dev
make -C userland/cmd/gengo wasi
```

Tiny preset:

```bash
make -C userland/cmd/gengo wasi-tiny
```

Stress preset:

```bash
make -C userland/cmd/gengo wasi-stress
```

## Run a Script

```bash
wasmtime --dir . userland/cmd/gengo/gengo-test.wasm -- path/to/script.gengo
```

With backend selection:

```bash
wasmtime --dir . userland/cmd/gengo/gengo-test.wasm -- --backend embedded path/to/script.gengo
wasmtime --dir . userland/cmd/gengo/gengo-test.wasm -- --backend host path/to/script.gengo
```

## Conformance

`test` always resets to dev preset first.

```bash
make -C userland/cmd/gengo test
```

## Host/Embedded Parity

```bash
make -C userland/cmd/gengo parity
```

## Benchmarks

Default:

```bash
make -C userland/cmd/gengo bench
```

Tiny and stress presets:

```bash
make -C userland/cmd/gengo bench-tiny
make -C userland/cmd/gengo bench-stress
```

With benchmark timing/throughput logs:

```bash
GENGO_BENCH_STATS=1 make -C userland/cmd/gengo bench-tiny
```

## Common Gotchas

- If behavior looks memory-constrained unexpectedly, re-apply dev preset:

```bash
make -C userland/cmd/gengo config-dev
```

- Bench cases may define `.policy` with `ALLOW_OOM` to mark expected low-memory failures.

## Nano Syntax Highlighting

```bash
echo 'include "/home/mikael/Project/github/shellcraft/userland/cmd/gengo/docs/gengo.nanorc"' >> ~/.nanorc
```

## Next Step

- Follow `docs/tutorial-first-script.md` for a step-by-step first script walkthrough.
