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

## Embedding the WASM

Download `gengo-runtime.wasm` from the [latest release](https://github.com/gengoscript/gengo/releases) or build it with `zig build wasi`.

**Browser** — pass the script as a virtual file using [`@bjorn3/browser_wasi_shim`](https://www.npmjs.com/package/@bjorn3/browser_wasi_shim):

```js
import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory }
  from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/+esm";

const script = `std := import("std")
std.io.println("hello from Gengo!")`;

const enc  = new TextEncoder();
const fds  = [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered(line => console.log(line)),
  ConsoleStdout.lineBuffered(line => console.error(line)),
  new PreopenDirectory(".", new Map([["script.gengo", new File(enc.encode(script))]])),
];

const wasi = new WASI(["gengo-runtime.wasm", "script.gengo"], [], fds);
const wasm = await WebAssembly.instantiateStreaming(fetch("gengo-runtime.wasm"), {
  wasi_snapshot_preview1: wasi.wasiImport,
});
wasi.start(wasm.instance);
```

**Node.js 22+** — use the built-in `node:wasi` module:

```js
import { readFileSync } from "node:fs";
import { WASI } from "node:wasi";

const script = `std := import("std")\nstd.io.println("hello from Gengo!")`;

// write script to a temp file, or use a real path
import { writeFileSync } from "node:fs";
writeFileSync("/tmp/script.gengo", script);

const wasi = new WASI({
  version: "preview1",
  args: ["gengo-runtime.wasm", "script.gengo"],
  preopens: { ".": "/tmp" },
});

const wasm = await WebAssembly.compile(readFileSync("gengo-runtime.wasm"));
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
wasi.start(instance);
```

**wasmtime CLI** — run a script directly from the shell:

```bash
wasmtime --dir . gengo-runtime.wasm script.gengo
```

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
- named scalar types and subtypes with range constraints, plus cyclic integer domains
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

The language is defined by the implementation in this repository.

## Quick Start

Build the native CLI:

```bash
zig build -Dpreset=dev cli
./zig-out/bin/gengo script.gengo
```

Build the WASI runtime:

```bash
zig build -Dpreset=dev wasi
wasmtime --dir . ./build/gengo-runtime.wasm -- script.gengo
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

## A note on authorship

Gengo is built almost entirely with the help of LLMs. It is tested, as any present-day software should be, but this is not an artisanally hand-carved compiler lovingly shaped by a lone language monk in a candlelit workshop while listening to smooth jazz.

Expect pragmatic choices, occasional rough edges, and parts of the codebase that may look like several enthusiastic monkeys tried to type on the keyboard all at once. Because, in several ways, they did.

If software with substantial LLM involvement gives you hives, moral discomfort, or a sudden urge to rewrite everything from first principles, this project may not be for you. That is fine. For everyone else: issues, tests, bug reports, and patches are welcome.

That said, please do not send five commits in ten minutes, each with a single spelling fix or a style-guide preference. Small fixes are welcome, but batch them, make them useful, and expect taste calls to remain taste calls.

Judgment on what goes into this alphabet soup remains with me for now.
