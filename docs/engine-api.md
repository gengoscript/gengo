# Gengo Engine API

The engine exposes a C-compatible API for host-driven embedding. It is the primary integration point for non-Zig hosts (JavaScript, Python, C/C++, Rust FFI, etc.).

Two delivery targets share the same API:

- **`gengo-engine.wasm`** — WebAssembly library for browser or WASI hosts
- **`libgengo-engine.so/.dylib/.dll`** — native shared library for in-process embedding

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

### `engine_init_with_config(config_ptr: i32) → i32`

Like `engine_init` but accepts a pointer to an `InstanceConfig` struct in WASM memory, allowing per-instance resource limits to be set below the preset ceiling.

`InstanceConfig` layout (all fields are `u64` / `i64`, little-endian, packed sequentially):

| Offset | Field | Type | Description |
|--------|-------|------|-------------|
| 0 | `heap_size_bytes` | `u64` | Gengo heap size in bytes (≤ preset ceiling) |
| 8 | `max_objects` | `u64` | Max live GC objects |
| 16 | `max_stack` | `u64` | VM value stack depth |
| 24 | `max_frames` | `u64` | Call frame limit |
| 32 | `max_defers` | `u64` | Defer stack depth |
| 40 | `max_ops` | `i64` | Instruction budget; `-1` = unlimited |
| 48 | `allow_io` | `u8` | `1` = allow `std.io`, `0` = suppress |

Returns:
- `>= 1` — handle on success
- `0` — pool exhausted
- `-3` — a field exceeds the preset ceiling; call `engine_last_error(0, ...)` to retrieve the message

```js
const cfg = allocBytes(mem, 56);
const view = new DataView(mem.buffer);
view.setBigUint64(cfg +  0, 65536n, true);  // heap_size_bytes
view.setBigUint64(cfg +  8, 256n,   true);  // max_objects
view.setBigUint64(cfg + 16, 128n,   true);  // max_stack
view.setBigUint64(cfg + 24, 32n,    true);  // max_frames
view.setBigUint64(cfg + 32, 64n,    true);  // max_defers
view.setBigInt64 (cfg + 40, -1n,    true);  // max_ops (unlimited)
view.setUint8    (cfg + 48, 1);              // allow_io
const handle = instance.exports.engine_init_with_config(cfg);
if (handle <= 0) throw new Error("engine init failed");
```

---

### `engine_destroy(handle: i32) → void`

Releases the engine instance identified by `handle`. The handle is invalid after this call.

---

### `engine_set_write_fn(handle: i32, callback: fn(ptr, len, is_stderr) → void) → void`

Registers a write callback for the engine. In the WASM target the host provides `gengo_write` as a WASM import instead. In the native shared library target this must be called before any `engine_run`; without it output goes to stdout/stderr directly.

Passing `NULL` resets to direct stdout/stderr output.

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

### `engine_register_module(handle: i32, name_ptr: i32, name_len: i32, funcs_ptr: i32, funcs_count: i32) → i32`

Registers a host-defined module that Gengo scripts can import using the `module:` prefix.

```js
// In Gengo: mylib := import("module:mylib")
```

`funcs_ptr` points to an array of `funcs_count` function descriptors, each 16 bytes:

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 4/8 | `name_ptr` | Pointer to function name string (`i32` in WASM, `uintptr_t` in native) |
| 4/8 | 4 | `name_len` | Byte length of function name |
| 8/12 | 4 | `arity` | Number of arguments the function takes |

Returns:
- `0` — registered successfully
- `-1` — invalid handle
- `-3` — module table full
- `-4` — `funcs_count` out of range
- `-5` — invalid module name

---

### `engine_set_http_handler(handle: i32, callback: ptr, userdata: ptr) → void`

Registers a host HTTP implementation for `cap:http`. The `callback` must match the C signature:

```c
int callback(
    const GengoHttpRequest* req,
    GengoHttpResponse*      out,
    void*                   userdata
);
```

Return `0` on success, negative on network failure (script receives `CapabilityError`).

`GengoHttpRequest` (all strings are pointer + length pairs, not null-terminated in the struct, but `method` and `url` are also null-terminated as a convenience):

| Field | C type | Description |
|---|---|---|
| `method` | `const char*` | HTTP method (also null-terminated) |
| `url` | `const char*` | Full URL (also null-terminated) |
| `body` | `const char*` | Request body bytes |
| `body_len` | `int` | Length of `body`; `0` if no body |
| `headers.keys` | `const char**` | Null-terminated header name strings |
| `headers.values` | `const char**` | Null-terminated header value strings |
| `headers.count` | `int` | Number of header pairs |
| `timeout_ms` | `int64_t` | Timeout in ms; `0` = no timeout |

The host fills `GengoHttpResponse`:

| Field | C type | Description |
|---|---|---|
| `status` | `int` | HTTP status code |
| `body` | `const char*` | Response body pointer (must remain valid until callback returns) |
| `body_len` | `int` | Response body byte length |
| `headers.*` | same shape | Response headers (may be null/0) |

Pass `NULL` for `callback` to remove the handler and revert to the built-in implementation.

---

### `engine_set_net_handlers(handle: i32, handlers: ptr, userdata: ptr) → void`

Registers host-side socket callbacks for `cap:net`. `handlers` points to a `GengoNetHandlers` struct:

```c
typedef struct {
    int   (*dial)(const char* network, size_t net_len,
                  const char* address, size_t addr_len,
                  int* out_handle, void* userdata);
    int   (*read)(int handle, char* buf, int max_bytes, void* userdata);
    int   (*write)(int handle, const char* data, int len, void* userdata);
    void  (*close)(int handle, void* userdata);
    void  (*local_addr)(int handle, char* buf, int buf_len, void* userdata);
    void  (*remote_addr)(int handle, char* buf, int buf_len, void* userdata);
    void  (*set_deadline)(int handle, int64_t ms, void* userdata);
    void  (*set_read_deadline)(int handle, int64_t ms, void* userdata);
    void  (*set_write_deadline)(int handle, int64_t ms, void* userdata);
} GengoNetHandlers;
```

`dial` returns `0` on success (writing a host-side connection handle to `*out_handle`), negative on error. `read` returns the number of bytes read, or negative on error. `write` returns 0 on success, negative on error.

Pass `NULL` for `handlers` to remove the handler and revert to the built-in POSIX implementation (native targets only; WASM returns `CapabilityNotAvailable` without a handler).

---

### `engine_last_error(handle: i32, out_ptr: i32, out_max_len: i32) → i32`

Copies the last error message into `out_ptr`. Returns the number of bytes written (0 if no error). The message is not null-terminated.

When `engine_init_with_config` returns `-3` (ceiling exceeded), there is no valid handle. Pass `handle = 0` to retrieve the init-time error message.

```js
function readError(handle) {
    const buf = alloc(mem, 512);
    const n = instance.exports.engine_last_error(handle, buf, 512);
    return new TextDecoder().decode(new Uint8Array(mem.buffer, buf, n));
}
```

---

### `engine_last_error_line(handle: i32) → i32`

Returns the 1-based source line of the last error, or `0` if no error.

---

### `engine_last_error_col(handle: i32) → i32`

Returns the 1-based column of the last error, or `0` if no error.

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
| 3     | `string`  | pointer into engine memory | byte length |
| 4     | `array`   | pointer to element sequence in engine memory | element count |
| 5     | `map`     | pointer to interleaved key/value `ValueWire` pairs in engine memory | pair count |

For string return values from `engine_call`, the pointer points into the engine's internal scratch buffer. Copy the bytes out before making another call.

For array and map values, elements are laid out contiguously in engine memory as `ValueWire` structs. Map entries are interleaved: key wire, value wire, key wire, value wire, … for `len` pairs total.

**Gengo → wire type mapping:**

| Gengo type | Wire tag | Notes |
|---|---|---|
| `null` | `null` | |
| `bool` | `boolean` | |
| `number` | `number` | |
| `rune` | `number` | Unicode code point value |
| `decimal` | `number` | Converted to `f64` |
| `string` | `string` | |
| `array` | `array` | Elements recursively serialized |
| `map` | `map` | Entries recursively serialized |
| struct instance | `map` | Field names as string keys |
| named scalar | unwrapped | Serialized as the underlying number/string |
| enum value | `string` | The enum member name |
| `error` | — | Serialization fails; `engine_call` returns `-2` |

If a function returns an `error` value, `engine_call` returns `-2`. Use `engine_last_error` to retrieve a description.

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

### WASM

```bash
zig build -Dpreset=dev engine-build
# produces: build/gengo-engine.wasm
```

### Native Shared Library

```bash
zig build -Dpreset=dev engine-native          # debug
zig build -Dpreset=dev engine-native-release  # optimised
# produces: zig-out/lib/libgengo-engine.so  (Linux)
#                         libgengo-engine.dylib (macOS)
#                         gengo-engine.dll      (Windows)
```

Link against the library and include `gengo-engine.h`. All pointer parameters use `uintptr_t` and work correctly on both 32-bit and 64-bit hosts.

**Native-specific notes:**

- Call `engine_set_write_fn(handle, callback)` before running any script to capture output; without it output goes directly to stdout/stderr.
- `engine_set_write_fn` is a no-op in the WASM target (the host provides `gengo_write` as a WASM import).

### Engine Integration Tests

```bash
zig build -Dpreset=dev unit
```
