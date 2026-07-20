# TypeScript and JavaScript SDK

Pin matching `@gengo/engine` and engine-WASM artifacts.

## Install and load

```sh
npm install @gengo/engine
```

Build or obtain `gengo-engine.wasm` separately. From this repository root,
`zig build -Dpreset=1m engine-build` writes it to
`build/debug/gengo-engine.wasm`. In a browser, fetch its bytes. In Node.js,
read the artifact and pass its bytes to `GengoEngine.load`.

```ts
import { GengoEngine, gnum } from "@gengo/engine";

const wasm = await fetch("/gengo-engine.wasm").then((r) => r.arrayBuffer());
const engine = await GengoEngine.load(wasm, {
  onStdout: (text) => console.log(text),
  onStderr: (text) => console.error(text),
});

try {
  const run = engine.run(`
    pub func add(a int, b int) int { return a + b }
  `);
  if (!run.ok) throw new Error(`${run.kind}: ${run.message}`);
  console.log(engine.call("add", [gnum(20), gnum(22)]));
} finally {
  engine.free();
}
```

Node.js uses the same API after `readFileSync("build/debug/gengo-engine.wasm")`.
The SDK accepts bytes or a compiled `WebAssembly.Module`; it does not fetch a
URL itself.

## Lifecycle and API

`load` creates one engine. `free()`/`destroy()` releases its engine handle;
every other method then throws. `reset()` clears script state while retaining
the engine. Do not retain values as pointers into WASM memory: the SDK decodes
them into JavaScript values, and memory can grow on any call.

| Method | Result |
|---|---|
| `run(source)` / `runPath(source, path)` | `EngineResult`: `{ ok: true }` or a compile/runtime error with message, line, column, and path. |
| `call(name, args)` | `GVal`; throws for a runtime error. |
| `getGlobal(name)` | `GVal` or `undefined`. |
| `addSource(path, source)` | Adds an importable in-memory source. |
| `loadBundle(name, zip)` / `clearBundles()` | Adds/removes ZIP module bundles. |
| `registerModule(name, functions)` | Registers callbacks imported as `host:name`. |

Host callbacks run synchronously during script execution. They must not call
back into the same engine, block indefinitely, or assume operation-budget
accounting covers their work. The SDK has no documented concurrent-use
guarantee for one engine; use separate engines for independent requests.

## Values and precision

`GVal` supports null, bool, `number`, string, arrays, maps, and error values.
`fromJS`/`toJS` are best-effort convenience conversions. JavaScript `number`
cannot losslessly represent every signed 64-bit integer. It also cannot
represent Gengoscript decimal raw values and scale: the current SDK does not
encode the decimal wire flag. Do not use it for lossless decimal or large-
integer interchange.

Strings are UTF-8 encoded into WASM linear memory. Arrays and maps are copied
into temporary WASM scratch memory for a call; JavaScript arrays/maps passed to
the SDK are not retained by the engine after that call.

## Browser security

The browser host supplies stdout/stderr and registered `host:` callbacks. Do
not register callbacks that expose ambient network, storage, or secrets unless
that authority is intended. The browser origin's normal network policy still
applies; Gengoscript operation limits do not limit asynchronous or expensive
host callback work. See `security.md` and `capability-matrix.md`.
