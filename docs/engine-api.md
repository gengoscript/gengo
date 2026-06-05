# Gengo Engine API

`gengo-engine.wasm` exposes a C-compatible WASM API for host-driven embedding. It is the primary integration point for non-Zig hosts (JavaScript, Python, Rust FFI, etc.) that need to run and call Gengo scripts from a WebAssembly host.

For Zig hosts, use `runtime/api.zig` directly — see `docs/embedding.md`.

## Concepts

**Handle** — an opaque `i32` returned by `engine_init`. All subsequent calls pass the handle back to identify which engine instance to operate on. Up to 64 handles may be live at once.

**Lifecycle** — init → run → call* → reset? → destroy. `reset` clears runtime state (globals, heap) so the same handle can run a fresh script without re-initialising. `destroy` frees the slot.

**ValueWire** — the transfer format for passing values between host and engine. A 24-byte extern struct (see layout below). Used for `engine_call` arguments and return values.

**Error retrieval** — when any function returns a negative code, call `engine_last_error` to retrieve the message. The message is overwritten on each error; copy it before making another call.

## Exports

### `engine_init() → i32`

Allocates a new engine instance. Returns a handle `>= 1` on success, `0` if the pool is exhausted (max 64 concurrent engines).

```js
const handle = instance.exports.engine_init();
if (handle === 0) throw new Error("engine pool exhausted");
```

---

### `engine_destroy(handle: i32) → void`

Releases the engine instance identified by `handle`. The handle is invalid after this call.

---

### `engine_run(handle: i32, src_ptr: i32, src_len: i32) → i32`

Compiles and runs a Gengo source string. Source must be UTF-8, written into WASM linear memory before calling.

Returns:
- `0` — success
- `-1` — compile error; call `engine_last_error` for the message
- `-2` — runtime error; call `engine_last_error` for the message

Any globals or functions defined by the script are retained in the engine's state and can be called via `engine_call`.

```js
const src = "func greet(name string) string { return \"hello \" + name }\n";
const ptr = writeString(mem, src);
const rc = instance.exports.engine_run(handle, ptr, src.length);
if (rc !== 0) {
    const msg = readError(handle);
    throw new Error(`run failed: ${msg}`);
}
```

---

### `engine_run_path(handle: i32, src_ptr: i32, src_len: i32, path_ptr: i32, path_len: i32) → i32`

Like `engine_run` but associates a logical file path with the source. Required when the script uses relative imports (`import("./util")`). The path is used to resolve sibling modules registered via `engine_add_source`.

Returns the same codes as `engine_run`.

```js
const rc = instance.exports.engine_run_path(
    handle, srcPtr, src.length, pathPtr, path.length
);
```

---

### `engine_call(handle: i32, name_ptr: i32, name_len: i32, args_ptr: i32, argc: i32, out_ptr: i32) → i32`

Calls a Gengo function by name. The function must have been defined in a prior `engine_run` or `engine_run_path` call.

- `args_ptr` — pointer to an array of `argc` ValueWire structs in WASM memory, or `0` if no arguments
- `argc` — number of arguments; `0` for zero-argument functions
- `out_ptr` — pointer to a single ValueWire in WASM memory to receive the return value, or `0` to discard

Returns:
- `0` — success; return value written to `*out_ptr` if `out_ptr != 0`
- `-1` — function not found or engine invalid
- `-2` — runtime error during the call

```js
// Call greet("world") and read back the string result
const argBuf = allocValueWire(mem);   // 24 bytes
writeStringWire(mem, argBuf, "world");
const retBuf = allocValueWire(mem);   // 24 bytes

const namePtr = writeString(mem, "greet");
const rc = instance.exports.engine_call(
    handle, namePtr, "greet".length,
    argBuf, 1, retBuf
);
if (rc !== 0) throw new Error(readError(handle));
const result = readWireValue(mem, retBuf);  // "hello world"
```

---

### `engine_reset(handle: i32) → void`

Clears the engine's runtime state — globals, heap, call stack. The handle remains valid. Use this to run a fresh script on the same engine without destroying and re-initialising it.

---

### `engine_add_source(handle: i32, path_ptr: i32, path_len: i32, src_ptr: i32, src_len: i32) → i32`

Registers an in-memory source file. When a script imported via `engine_run_path` resolves a relative import, the engine looks up the logical path in this table before attempting filesystem access.

Returns:
- `0` — registered successfully
- `-1` — invalid handle
- `-3` — source table full (max 64 entries per engine)

Path must match exactly what the importing script uses (e.g. `"app/pkg/mod.gengo"` when the script says `import("./pkg")`).

```js
const modSrc = 'pub func answer() int { return 42 }\n';
instance.exports.engine_add_source(
    handle,
    writeString(mem, "app/pkg/mod.gengo"), "app/pkg/mod.gengo".length,
    writeString(mem, modSrc), modSrc.length
);
```

---

### `engine_last_error(handle: i32, out_ptr: i32, out_max_len: i32) → i32`

Copies the last error message into `out_ptr`. Returns the number of bytes written (0 if no error or invalid handle). The message is not null-terminated.

```js
function readError(handle) {
    const buf = alloc(mem, 512);
    const n = instance.exports.engine_last_error(handle, buf, 512);
    return new TextDecoder().decode(new Uint8Array(mem.buffer, buf, n));
}
```

---

## ValueWire layout

`ValueWire` is a 24-byte extern struct, naturally aligned. All multi-byte fields are little-endian (WASM native).

| Offset | Size | Field      | Description |
|--------|------|------------|-------------|
| 0      | 1    | `tag`      | Value type (see tags below) |
| 1      | 1    | `flags`    | Reserved, set to 0 |
| 2      | 2    | `reserved` | Reserved, set to 0 |
| 4      | 8    | `payload`  | Type-dependent (see below) |
| 12     | 4    | `len`      | String byte length (strings only), else 0 |
| 16     | 4    | `reserved2`| Reserved, set to 0 |

**Tags:**

| Value | Name      | `payload` interpretation | `len` |
|-------|-----------|--------------------------|-------|
| 0     | `null`    | ignored                  | 0     |
| 1     | `boolean` | `1` = true, `0` = false  | 0     |
| 2     | `number`  | IEEE 754 double (`f64`)  | 0     |
| 3     | `string`  | WASM memory pointer      | byte length |

For string return values from `engine_call`, the pointer points into the engine's internal scratch buffer. Copy the bytes out before making another call.

### JavaScript helper (minimal)

```js
const WIRE_SIZE = 24;

function writeWire(mem, ptr, tag, payload, len) {
    const view = new DataView(mem.buffer);
    view.setUint8(ptr, tag);
    view.setUint8(ptr + 1, 0);
    view.setUint16(ptr + 2, 0, true);
    view.setBigUint64(ptr + 4, BigInt(payload), true);
    view.setUint32(ptr + 12, len, true);
    view.setUint32(ptr + 16, 0, true);
}

function readWire(mem, ptr) {
    const view = new DataView(mem.buffer);
    const tag = view.getUint8(ptr);
    switch (tag) {
        case 0: return null;
        case 1: return view.getBigUint64(ptr + 4, true) !== 0n;
        case 2: return view.getFloat64(ptr + 4, true);
        case 3: {
            const strPtr = Number(view.getBigUint64(ptr + 4, true));
            const strLen = view.getUint32(ptr + 12, true);
            return new TextDecoder().decode(
                new Uint8Array(mem.buffer, strPtr, strLen)
            );
        }
    }
}

function writeNullWire(mem, ptr)    { writeWire(mem, ptr, 0, 0, 0); }
function writeBoolWire(mem, ptr, v) { writeWire(mem, ptr, 1, v ? 1 : 0, 0); }
function writeNumWire(mem, ptr, n) {
    const view = new DataView(mem.buffer);
    view.setUint8(ptr, 2);
    view.setFloat64(ptr + 4, n, true);
    view.setUint32(ptr + 12, 0, true);
    view.setUint32(ptr + 16, 0, true);
}
function writeStringWire(mem, ptr, s) {
    const encoded = new TextEncoder().encode(s);
    // write string bytes somewhere in WASM memory first, then point to them
    const strPtr = alloc(mem, encoded.length);
    new Uint8Array(mem.buffer, strPtr, encoded.length).set(encoded);
    writeWire(mem, ptr, 3, strPtr, encoded.length);
}
```

## Resource limits

The engine WASM module is built with the following limits (defined in `src/runtime/config.zig`):

| Limit | Value |
|---|---|
| Heap size | 2 MB |
| Max objects | 8 192 |
| Max stack depth | 2 048 |
| Max call frames | 128 |
| Max script source | 512 KB |
| Max defers | 512 |
| Concurrent engines | 64 |
| Sources per engine | 64 |
| Error message buffer | 512 bytes |

## Concurrency

Each engine handle is independent. Multiple handles may be used from the same host thread interleaved. Concurrent access to the same handle from multiple host threads is not safe — the engine uses a global active-context model internally.

## Build

```bash
zig build -Dpreset=dev engine-build
# produces: build/gengo-engine.wasm
```

To run the engine integration tests:

```bash
zig build -Dpreset=dev unit
```
