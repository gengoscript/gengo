# Gengoscript Engine API

This page documents the C-compatible engine surface for non-Zig hosts.

Two targets expose the same API:

- `gengo-engine.wasm`
- `libgengo-engine.so` and platform equivalents

For Zig hosts, use `embedding.md` instead.

## Core Concepts

### Handle

`engine_init` returns an opaque engine handle. All subsequent calls use that handle to identify the instance.

### Lifecycle

The normal lifecycle is:

1. initialise an engine;
2. run a script;
3. call exported functions;
4. reset the engine if you want to reuse it; and
5. destroy it when finished.

### Errors

When a function returns an error code, call `engine_last_error` to fetch the message. The stored error is overwritten by the next engine error.

### `ValueWire`

Arguments and return values cross the boundary as `ValueWire`. See the `ValueWire layout` section below.

## Engine Lifecycle

### `engine_init() -> i32`

Allocates an engine instance.

Returns:

- `>= 1` on success;
- `0` if no free engine slots remain.

### `engine_init_with_config(config_ptr) -> i32`

Initialises an engine with per-instance limits below the active preset ceiling.

`InstanceConfig` layout:

| Offset | Field | Type |
|---|---|---|
| `0` | `heap_size_bytes` | `u64` |
| `8` | `max_objects` | `u64` |
| `16` | `max_stack` | `u64` |
| `24` | `max_frames` | `u64` |
| `32` | `max_defers` | `u64` |
| `40` | `max_ops` | `i64` |
| `48` | `allow_io` | `u8` |

Returns:

- `>= 1` on success;
- `0` if the engine pool is exhausted;
- `-3` if a field exceeds the preset ceiling; or
- `-4` if allocation fails.

### `engine_destroy(handle) -> void`

Releases the engine instance. The handle is invalid after this call.

### `engine_reset(handle) -> void`

Clears globals, heap state, and call frames while keeping the handle valid.

## Running Scripts

### `engine_run(handle, src_ptr, src_len) -> i32`

Compiles and runs a UTF-8 source string.

Returns:

- `0` on success;
- `-1` for compile error; or
- `-2` for runtime error.

### `engine_run_path(handle, src_ptr, src_len, path_ptr, path_len) -> i32`

Like `engine_run`, but associates a logical path with the source. Use this when the script relies on relative imports.

## Calling Functions

### `engine_call(handle, name_ptr, name_len, args_ptr, argc, out_ptr) -> i32`

Calls a script function that was defined by a previous `engine_run` or `engine_run_path`.

Arguments:

- `args_ptr` points to `argc` consecutive `ValueWire` records, or `0` for no arguments;
- `out_ptr` points to one `ValueWire` for the return value, or `0` to discard it.

Returns:

- `0` on success;
- `-1` if the function is missing or the handle is invalid; or
- `-2` for runtime error during the call.

## Modules and Sources

### `engine_add_source(handle, path_ptr, path_len, src_ptr, src_len) -> i32`

Registers an in-memory source file for later import resolution.

Returns:

- `0` on success;
- `-1` for invalid handle; or
- `-3` if the source table is full.

### `engine_set_import_loader(handle, load_fn, ctx) -> i32`

Registers a callback for dynamic module loading. The callback runs before the engine falls back to `engine_add_source`.

Returns:

- `0` on success;
- `-1` for invalid handle.

Pass `NULL` to clear the callback.

### `engine_register_module(handle, name_ptr, name_len, funcs_ptr, funcs_count) -> i32`

Registers a host-defined module that scripts can import through the `host:` prefix.

**Platform restriction:** host modules are only supported on WASM targets. On
native shared-library builds this function always fails with `-6`.

Returns:

- `0` on success;
- `-1` for invalid handle;
- `-3` if the module table is full;
- `-4` if `funcs_count` is out of range;
- `-5` for invalid module name; or
- `-6` if host modules are not supported on this platform (WASM only).

## Capabilities

### `engine_mount_dir(handle, name_ptr, name_len, path_ptr, path_len) -> i32`

Registers a named filesystem mount for `cap:fs`.

Returns:

- `0` on success;
- `-1` for invalid handle; or
- `-2` for invalid mount definition.

### `engine_set_http_handler(handle, callback, userdata) -> void`

Registers the host HTTP implementation used by `cap:http`.

### `engine_set_net_handlers(handle, handlers, userdata) -> void`

Registers the host socket handlers used by `cap:net`.

## Output and Diagnostics

### `engine_set_write_fn(handle, callback) -> void`

Registers a native output callback. In the WebAssembly target, output is provided through the imported `gengo_write` function instead.

Passing `NULL` restores direct stdout and stderr output.

Signature: `void callback(const char *ptr, int len, int is_stderr)`  
`is_stderr` is `1` when the output comes from `std.io.eprint*`, `0` otherwise.

### `engine_set_read_fn(handle, callback) -> void`

Registers a native input callback used by `std.io.read` and `std.io.readline`. Not available in the WebAssembly target.

Passing `NULL` restores direct stdin reads.

Signature: `int callback(char *buf, int max_len, int is_line)`  
- `is_line` is `1` for `readline` (read until `\n` or buffer full), `0` for `read` (single raw read).
- Return value: number of bytes written into `buf`, or `-1` on EOF/error.

### `engine_last_error(handle, out_ptr, out_max_len) -> i32`

Copies the last error message into the caller buffer and returns the number of bytes written.

### `engine_last_error_line(handle) -> i32`

Returns the source line associated with the last error, or `0` if unavailable.

### `engine_last_error_col(handle) -> i32`

Returns the source column associated with the last runtime error, or `0` if unavailable.

## `ValueWire` Layout

`ValueWire` is a 24-byte extern record:

| Offset | Field | Type |
|---|---|---|
| `0` | `tag` | `u8` |
| `1` | `flags` | `u8` |
| `2` | `reserved` | `u16` |
| `4` | `payload` | `u64` |
| `12` | `len` | `u32` |
| `16` | `reserved2` | `u32` |

The public wire format covers null, booleans, numbers, and strings. Higher-level host helpers are expected to encode and decode these values correctly on behalf of the embedding application.

## JavaScript Example

```js
const handle = instance.exports.engine_init();
if (handle === 0) throw new Error("engine pool exhausted");

const src = 'pub func greet(name string) string { return "hello " + name }\n';
const srcPtr = writeString(mem, src);

if (instance.exports.engine_run(handle, srcPtr, src.length) !== 0) {
  throw new Error(readError(handle));
}
```

## Build Targets

Build the WebAssembly engine:

```bash
zig build -Dpreset=1m engine-build
```

Build the native shared library:

```bash
zig build -Dpreset=1m engine-native
```

### The `gengo_host` Import

`gengo-engine.wasm` (and the `-net`/`-fs` variants) import one function from
module `gengo_host`, even if the script never calls a host module:

```c
int32_t gengo_native_call(uint16_t id, ValueWire* args_ptr, uint16_t argc, ValueWire* out_ptr);
```

Every `WebAssembly.instantiate`/`instantiateStreaming` call must supply this
import or instantiation fails with `TypeError: import object field 'gengo_host'
is not an Object`. If the host never registers host modules, a stub that
always returns `unsupported` (`1`) is sufficient:

```js
gengo_host: {
  gengo_native_call: () => 1,
},
```

`engine-minimal` is built with the `gengo_host` build option disabled
(`zig build -Dgengo_host=false ...`) and omits this import entirely, so hosts
using that variant don't need to provide a stub. See `host-abi.md` and
`embedding.md#host-module-constraints` for the full callback ABI.

## Further Reading

- `embedding.md` for Zig embedding
- `host-abi.md` for the host backend ABI
- `security.md` for runtime controls and limits
