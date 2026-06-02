# Gengo (言語)

Embeddable scripting language implemented in Zig.

It compiles in one pass to bytecode and runs on a VM.

Goal: a pragmatic language you can embed and run in a sandboxed environment, with WASM as a first-class target.

- bytecode VM
- native CLI for development
- WASI build for sandboxed execution
- Zig embedding API
- relative source-file modules

**[Try it in the browser](https://gengoscript.github.io/gengo/)**

Project status: early and still evolving. Breaking changes are expected while the language and runtime are being tightened.

## Example

```gengo
std := import("std")
math := import("./math")

type Point struct {
    x int
    y int
}

func (p Point) sum() int {
    return p.x + p.y
}

p := Point{ x: 3, y: 4 }
std.io.println(math.add(p.sum(), 10))
```

```gengo
// math.gengo
pub func add(a int, b int) int {
    return a + b
}
```

## What It Has

- structs and methods
- interfaces
- enums
- variant types
- named scalar types and subtypes with range constraints
- arrays, maps, strings, runes, errors, `null`, `any`
- closures
- multi-return functions
- `defer`, `recover`, `assert`
- `for`, `for-in`, `switch`
- `std` library namespaces such as `std.io`, `std.core`, `std.string`, `std.math`, `std.conv`
- source-file modules via `import("./path")`

## What It Is Aiming For

- embeddable by default
- predictable sandboxed execution
- good WASM story
- simple implementation that is still worth optimizing

This is not trying to preserve Tengo compatibility. The language is defined by the implementation in this repository.

## Quick Start

Build the native CLI:

```bash
zig build -Dpreset=dev cli
./zig-out/bin/gengo script.gengo
```

Build the WASI runtime:

```bash
zig build -Dpreset=dev wasi
wasmtime --dir . ./build/gengo-test.wasm -- script.gengo
```

Run tests:

```bash
zig build -Dpreset=dev test
```

Run benchmarks:

```bash
zig build -Dpreset=dev bench
```

## Embedding

The embedding API lives in `src/runtime/api.zig`.

It supports:

- running a script and calling exported globals
- instruction budgets
- relative imports with a root path
- in-memory module tables
- host-provided source callbacks

See [docs/embedding.md](docs/embedding.md).

## Build Presets

- `dev`: default development preset
- `tiny`: tighter limits for constrained embedding
- `stress`: tighter limits for edge-case testing

Use `-Dpreset=<name>` with build commands.

## Repo Layout

- `src/lang/`: lexer, compiler, bytecode, VM
- `src/runtime/`: heap, GC, runtime, embedding API
- `examples/spec/`: conformance cases
- `examples/bench/`: benchmark programs
- `docs/`: language, stdlib, embedding, changelog
- `playground/`: browser playground

## Toolchain

- Zig `0.16.0`
- wasmtime for WASI testing and execution

## Docs

- [docs/language.md](docs/language.md)
- [docs/stdlib.md](docs/stdlib.md)
- [docs/embedding.md](docs/embedding.md)
- [docs/changelog.md](docs/changelog.md)
