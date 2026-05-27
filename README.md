# Gengo (言語)

gengo is a small embeddable scripting language/runtime implemented in Zig.

Project status: early-stage and intentionally evolving.

## Quick Start

Build the WASI runtime:

```bash
make wasi
```

Run a script:

```bash
wasmtime --dir . ./gengo-test.wasm -- examples/simple_math.gengo
```

Run conformance tests:

```bash
make test
```

## Repo Layout

- `lang/`: lexer, compiler, bytecode, VM logic
- `runtime/`: runtime services, host ABI, memory
- `examples/`: spec, fail-cases, benchmarks, parity cases
- `docs/`: language and runtime docs
- `tests/`: harness scripts used by `make test` / `make bench`

## Notes

- File extension is `.gengo`.
- `import("std")` is the supported builtin namespace.
- Language behavior may change as the project evolves.
