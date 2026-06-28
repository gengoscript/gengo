# @gengo/engine

TypeScript SDK for the [Gengoscript](https://github.com/gengoscript/gengo) embeddable
scripting engine.  Load the WASM engine, run scripts, call functions, and
register host modules — all from TypeScript.

## Install

```sh
npm install @gengo/engine
```

## Usage

### Run a script

```ts
import { GengoEngine, gstr, gnum, garr } from "@gengo/engine";

// In a browser:
const engine = await GengoEngine.load(fetch("/gengo-engine.wasm"));

// In Node.js with fs:
// import { readFileSync } from "fs";
// const wasm = readFileSync("path/to/gengo-engine.wasm");
// const engine = await GengoEngine.load(wasm);

// Capture output
engine.onStdout = (text) => console.log("stdout:", text);
engine.onStderr = (text) => console.error("stderr:", text);

// Run a script
const result = engine.run(`
  std := import("std")
  std.io.println("hello from Gengoscript!")
`);

if (!result.ok) {
  console.error(`${result.kind} error: ${result.message} (${result.line}:${result.col})`);
}
```

### Call functions

```ts
// Script defines a function
engine.run(`
  func add(a int, b int) int { return a + b }
`);

// Call it from TypeScript
const sum = engine.call("add", [gnum(20), gnum(22)]);
console.log(sum); // { t: "num", v: 42 }
```

### Pass arrays and maps

```ts
engine.run(`
  func process(items []int, config [string]string) {
    for x in items { std.io.println(x) }
  }
`);

engine.call("process", [
  garr(gnum(1), gnum(2), gnum(3)),
  gmap([[gstr("mode"), gstr("fast")]]),
]);
```

### Register host modules

```ts
engine.registerModule("mydb", [
  {
    name: "query",
    arity: 2,
    fn(args) {
      const sql = args[0]; // GVal
      const params = args[1];
      return garr(gnum(1), gstr("result"));
    },
  },
]);

engine.run(`
  db := import("mydb")
  rows := db.query("SELECT 1", [])
`);
```

## API

### `GengoEngine.load(source, options?)`

Creates a new engine instance from a WASM binary (BufferSource, Response, or
already-compiled WebAssembly.Module).

Options:
- `onStdout?: (text: string) => void` — stdout output
- `onStderr?: (text: string) => void` — stderr output

### `engine.run(source): EngineResult`

Compile and run a Gengoscript script.

### `engine.runPath(source, path): EngineResult`

Same as `run` but with a virtual path for import resolution.

### `engine.call(name, args): GVal`

Call a named Gengoscript function with typed arguments.

### `engine.addSource(path, source): void`

Register a source module for import resolution.

### `engine.registerModule(name, functions): void`

Register a host module with JS callbacks.

### `engine.free()`

Release the WASM module reference.

## Types

### `GVal`

Tagged union representing a Gengoscript value:

```ts
type GVal =
  | { t: "null" }
  | { t: "bool"; v: boolean }
  | { t: "num"; v: number }
  | { t: "str"; v: string }
  | { t: "arr"; v: GVal[] }
  | { t: "map"; v: [GVal, GVal][] }
  | { t: "err"; v: string };
```

Constructors: `gnull()`, `gbool(v)`, `gnum(v)`, `gstr(v)`, `garr(...items)`, `gmap(entries?)`, `gerr(msg)`.

Conversion helpers: `fromJS(any)` and `toJS(gval)` for best-effort JS
interop.

## Building

```sh
# Build the WASM engine
cd /path/to/gengo
zig build -Dpreset=1m engine-build

# Build the TypeScript SDK
cd sdk/typescript
npm install
npm run build
```
