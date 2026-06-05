# Gengo (言語)

Embeddable scripting language implemented in Zig.

It compiles in one pass to bytecode and runs on a VM.

Goal: a pragmatic language you can embed and run in a sandboxed environment, with WASM as a first-class target.

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
- interfaces (structural/duck typing)
- enums
- variant types (tagged unions with typed payloads)
- named scalar types and subtypes with range constraints, plus cyclic integer domains
- arrays, maps, strings, runes, errors, `null`, `any`
- closures with proper upvalue capture
- multi-return functions and named return values
- `var`/`const` declarations with type annotations
- `defer`, `recover`, `assert`, `trap`
- `for`, `for-in`, `switch`
- in-source `test` blocks (`--test` flag)
- `std` library: `std.io`, `std.core`, `std.string`, `std.math`, `std.conv`, `std.rand`, `std.json`, `std.template`, `std.regexp`, `std.time`
- multi-file modules via `import("./path")` with `pub` visibility

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

Build the engine WASM:

```bash
zig build -Dpreset=dev engine-build
# produces build/gengo-engine.wasm
```

Run tests:

```bash
zig build -Dpreset=dev test
```

Run benchmarks:

```bash
zig build -Dpreset=dev bench
```

## WASM Artifacts

Gengo ships two WASM artifacts for different deployment scenarios:

**`gengo-runtime.wasm`** — a WASI executable for running scripts in WASI-capable environments (wasmtime, wasmer, any WASI runtime) with zero host integration work. Feed it a script, get stdout/stderr back. No ability to call individual functions or maintain state across invocations. Use this when you want WASM sandboxing without writing host code.

**`gengo-engine.wasm`** — a library for programmatic embedding. The host calls exported functions (`engine_init`, `engine_run`, `engine_call`, …) directly against WASM linear memory, provides an I/O hook for capturing output, and manages engine instances explicitly. Supports multiple isolated instances, typed function calls, and in-memory module tables. Use this when you need to drive execution from the host.

## gengo-runtime.wasm (WASI Runner)

Download from the [latest release](https://github.com/gengoscript/gengo/releases) or build with `zig build -Dpreset=dev wasi`.

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
import { readFileSync, writeFileSync } from "node:fs";
import { WASI } from "node:wasi";

const script = `std := import("std")\nstd.io.println("hello from Gengo!")`;
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

## gengo-engine.wasm (Host Embedding)

Build with `zig build -Dpreset=dev engine-build` — produces `build/gengo-engine.wasm`.

The engine exposes 8 exports over WASM linear memory:

| Export | Description |
|---|---|
| `engine_init() → i32` | Allocate an engine instance; returns handle |
| `engine_destroy(handle)` | Free the instance |
| `engine_run(handle, src_ptr, src_len) → i32` | Compile and run a script |
| `engine_run_path(handle, src_ptr, src_len, path_ptr, path_len) → i32` | Run with a root path for relative imports |
| `engine_call(handle, name_ptr, name_len, args_ptr, argc, out_ptr) → i32` | Call a named function |
| `engine_reset(handle)` | Clear runtime state, reuse handle |
| `engine_add_source(handle, path_ptr, path_len, src_ptr, src_len) → i32` | Register an in-memory module |
| `engine_last_error(handle, out_ptr, max_len) → i32` | Retrieve last error message |

Up to 64 engine instances may be live at once. Values cross the boundary as `ValueWire` — a 24-byte struct encoding null, boolean, number, and string.

See [docs/engine-api.md](docs/engine-api.md) for the full ABI reference including `ValueWire` layout, return codes, and JavaScript helpers.

## Zig Embedding

The Zig embedding API lives in `src/runtime/api.zig`.

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
- `src/runtime/`: heap, GC, runtime, Zig embedding API
- `src/engine.zig`: WASM engine exports
- `examples/spec/`: conformance cases
- `examples/bench/`: benchmark programs
- `docs/`: language, stdlib, embedding, engine API, changelog
- `playground/`: browser playground

## Toolchain

- Zig `0.16.0`
- wasmtime for WASI testing and execution

## Docs

- [docs/language.md](docs/language.md)
- [docs/stdlib.md](docs/stdlib.md)
- [docs/embedding.md](docs/embedding.md)
- [docs/engine-api.md](docs/engine-api.md)
- [docs/changelog.md](docs/changelog.md)

## A note on authorship

Gengo is built almost entirely with the help of LLMs. It is tested, as any present-day software should be, but this is not an artisanally hand-carved compiler lovingly shaped by a lone language monk in a candlelit workshop while listening to smooth jazz.

Expect pragmatic choices, occasional rough edges, and parts of the codebase that may look like several enthusiastic monkeys tried to type on the keyboard all at once. Because, in several ways, they did.

If software with substantial LLM involvement gives you hives, moral discomfort, or a sudden urge to rewrite everything from first principles, this project may not be for you. That is fine. For everyone else: issues, tests, bug reports, and patches are welcome.

And if you feel a pressing need to rebalance the cosmic ledger, consider donating to serious climate work instead of buying that thing you don't actually need.

That said, please do not send five commits in ten minutes, each with a single spelling fix or a style-guide preference. Small fixes are welcome, but batch them, make them useful, and expect taste calls to remain taste calls.

Judgment on what goes into this alphabet soup remains with me for now.
