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

### Ownership and lifetime

The caller allocates the `ValueWire` argument array and the top-level output
record. Keep input records, strings, and nested array/map records readable for
the duration of `engine_call`; the engine copies input values before returning.
Treat them as read-only while the call runs.

On success, `out` itself remains caller-owned. Its referenced strings and
nested records are engine-owned scratch storage. Copy them before the next
operation on the same engine (`engine_run`, `engine_call`, `engine_get_global`,
or enumeration), `engine_reset`, or `engine_destroy`; none may be retained
after destruction. A returned collection is limited by the engine's current
wire scratch capacity (256 element records; maps consume two records per
entry), and serialization failure is reported as a runtime error.

Wire serialization is bounded by a recursive nesting depth of 64 on both
the input and output sides. A script returning (or receiving) a value nested
deeper than 64 levels causes the call to fail with `HostValueTooDeep` rather
than overflowing the host call stack. A wire value whose `len` field exceeds
the u32 maximum returns `HostValueTooLarge`. Both conditions surface as
runtime errors through the normal `engine_last_error` path.

`gengo_host_call_fn` arguments are engine-owned and valid only while the
callback is executing. A callback may provide an output wire backed by host
memory, but that memory must remain valid until the callback returns; the
engine converts it immediately. Do not mutate callback input, re-enter the
same engine, or call one engine concurrently. Engine activation uses
process-global runtime views, so separate instances should also be serialized
unless the implementation explicitly gains a concurrency guarantee.

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

### Complete native C example

This minimal host loads a script, calls its exported `add` function, checks the
integer `ValueWire` result, and destroys the engine on every path. It is kept
as the executable fixture `tools/site-builder/fixtures/c_engine/add.c`.

```c
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "gengo-engine.h"

int main(void) {
    static const char source[] =
        "pub func add(a int, b int) int { return a + b }\n";
    int32_t engine = engine_init();
    if (engine <= 0) return 1;

    if (engine_run(engine, source, (int32_t)strlen(source)) != 0) {
        engine_destroy(engine);
        return 1;
    }

    gengo_value_wire_t args[2] = {
        { .tag = GENGO_WIRE_NUMBER, .flags = GENGO_WIRE_FLAG_INTEGER, .payload = 40 },
        { .tag = GENGO_WIRE_NUMBER, .flags = GENGO_WIRE_FLAG_INTEGER, .payload = 2 },
    };
    gengo_value_wire_t out = {0};
    int32_t rc = engine_call(engine, "add", 3, args, 2, &out);
    if (rc != 0 || out.tag != GENGO_WIRE_NUMBER ||
        out.flags != GENGO_WIRE_FLAG_INTEGER || out.payload != 42) {
        engine_destroy(engine);
        return 1;
    }

    puts("42");
    engine_destroy(engine);
    return 0;
}
```

From the repository root on Linux, build the native engine and fixture:

```bash
zig build -Dpreset=1m engine-native
cc -std=c11 -Wall -Wextra -Iinclude tools/site-builder/fixtures/c_engine/add.c \
  -Lzig-out/lib -Wl,-rpath,'$ORIGIN/../zig-out/lib' -lgengo-engine -o build/gengo-c-add
./build/gengo-c-add
```

Expected output is `42`. On macOS or Windows, use the shared-library naming
and runtime search-path convention for that platform. After a successful
`engine_call`, `out` remains caller-owned but any string, array, or map data it
references is engine scratch storage; copy it before the next engine operation.

### Building values with `gengo-wire.h`

`include/gengo-wire.h` has `static inline` builders and readers for every
`ValueWire` tag, including composite ones: `gengo_wire_array`/`gengo_wire_map`
build array/map arguments or return values without hand-encoding the pointer
and length convention from the layout table above, and
`gengo_wire_array_at`/`gengo_wire_map_key_at`/`gengo_wire_map_value_at` read
them back. The element/pair storage passed to `gengo_wire_array`/
`gengo_wire_map` is caller-owned and must remain valid for the duration of the
`engine_call` that references it, exactly like a string wire's backing buffer.

`tools/site-builder/fixtures/c_engine/composite.c` is the executable fixture:
it passes an array argument and reads back a map result. Any C-ABI host
language (including Go through `cgo`) can call these inline functions
directly; see `examples/go-embed` for a worked Go version of the same pattern.

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

Returns:

- `0` on success;
- `-1` for invalid handle;
- `-3` if the module table is full;
- `-4` if `funcs_count` is out of range;
- `-5` for invalid module name.

Register the native dispatcher with `engine_set_host_call_fn` before a script
invokes a registered module. WASM hosts provide the same dispatcher through
the `gengo_host.gengo_native_call` import.

### `engine_set_host_call_fn(handle, callback, ctx) -> i32`

Registers the native dispatcher for this engine's `host:*` modules. The
callback receives the module function call ID and `ValueWire` arguments, and
returns a `ValueWire` result plus a host ABI status code. Pass `NULL` to clear
the dispatcher.

This callback and context are per-engine. They are activated only while that
engine is running or calling an exported function. The callback may not safely
re-enter or concurrently use the engine; separate engines may use different
contexts when calls are serialized.

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

## Module Bundles

Scripts can import modules from a bundle registered on the engine. Bundles require no special prefix in the script — `import("mylib/utils/strings")` resolves against registered bundles transparently.

### Evaluation order

Module resolution follows this order:

1. Stdlib (`std`)
2. Host modules (`host:` prefix)
3. Import loader callback (if registered via `engine_set_import_loader`)
4. Module bundles (registered via `engine_load_bundle` / `engine_load_bundle_dir`)
5. In-memory sources (`engine_add_source`)

### Package format

A module bundle is a standard ZIP file. Only `.gengo` files are loaded; other files are ignored. The module path within the bundle is the zip entry path with the `.gengo` extension stripped. For example, a zip entry `utils/strings.gengo` is importable as `import("mylib/utils/strings")` when loaded under the name `"mylib"`.

Limits per bundle call:

| Limit | Value |
|---|---|
| Max packages per engine | 32 |
| Max files per package | 64 |
| Max file size | 64 KiB |
| Supported compression | store, deflate |

### `engine_load_bundle(handle, name_ptr, name_len, zip_ptr, zip_len) -> i32`

Load a zip-format module bundle.

Returns:

- `0` on success;
- `-1` if the handle is invalid;
- `-2` if the package table is full (max 32);
- `-3` if a package file table is full (max 64 files);
- `-4` if a file exceeds 64 KiB; or
- `-5` for invalid zip data or package name.

### `engine_load_bundle_dir(handle, name_ptr, name_len, dir_ptr, dir_len) -> i32`

Load all `.gengo` files found recursively under `dir_path` into a bundle named `name`. This is a convenience for development — in production, use `engine_load_bundle` with a pre-built zip. Not available in WebAssembly builds (returns `-5`).

Returns the same codes as `engine_load_bundle`.

### `engine_clear_bundles(handle) -> void`

Remove all registered module bundles. Does not affect `engine_add_source` entries or the import loader callback.

### Bundle-loading C example

```c
/* Load a pre-built package zip from disk */
FILE *f = fopen("mylib-1.0.zip", "rb");
fseek(f, 0, SEEK_END);
long size = ftell(f);
rewind(f);
void *buf = malloc(size);
fread(buf, 1, size, f);
fclose(f);

int h = engine_init();
engine_load_bundle(h, "mylib", 5, buf, (int32_t)size);
free(buf);

/* Script imports work without any prefix */
const char *src = "m := import(\"mylib/utils\")\n"
                  "pub func run() string { return m.greet(\"world\") }\n";
engine_run(h, src, (int32_t)strlen(src));
```

## Net Dial Policy

`cap:net` is unrestricted by default — any script with the capability can dial any address. `engine_net_policy_add` lets the host add allow/deny rules that gate every `net.dial()` call without replacing the entire net handler.

### Evaluation model

Rules form a stack. The **most recently added rule is evaluated first**. The first matching rule wins. If no rule matches, the default is **allow** — so with no rules set, behaviour is unchanged from today.

To restrict to an allowlist, add a `deny *` rule first, then add `allow` rules for what you want to permit. Because `allow` rules are added after (and therefore evaluated before) the `deny *`, they take priority:

```c
engine_net_policy_add(h, 0, "*", 1, 0);              // deny all   (added first, evaluated last)
engine_net_policy_add(h, 1, "10.0.0.0/8", 8, 0);    // allow range (evaluated before deny *)
engine_net_policy_add(h, 1, "*.internal.corp", 14, 0); // allow domain
```

### Pattern format

| Pattern | Example | Matches |
|---|---|---|
| `*` | `*` | any address |
| IPv4 exact | `192.168.1.1` | that IP only |
| IPv4 CIDR | `192.168.1.0/24` | IPs in that range |
| IPv6 exact | `::1` | that address only |
| IPv6 CIDR | `fd00::/8` | addresses in that range |
| Hostname exact | `api.example.com` | that hostname |
| Hostname wildcard | `*.example.com` | any subdomain of `example.com` |

The `port` argument is `0` for any port, or an exact port number.

### `engine_net_policy_add(handle, action, pattern_ptr, pattern_len, port) -> i32`

Add a rule to the end of the stack (making it the first to be evaluated).

`action`: `0` = deny, `1` = allow.

Returns:

- `0` on success;
- `-1` if the handle is invalid;
- `-2` if the rule list is full (max 32); or
- `-3` if the pattern is invalid.

### `engine_net_policy_clear(handle) -> void`

Remove all rules. Default-allow is restored.

### Net-policy C example

```c
/* Allowlist: only internal network and one external API */
engine_net_policy_add(h, 0, "*", 1, 0);
engine_net_policy_add(h, 1, "10.0.0.0/8", 8, 0);
engine_net_policy_add(h, 1, "api.example.com", 15, 443);

/* Single deny: block one bad actor, allow everything else */
engine_net_policy_add(h, 0, "198.51.100.0/24", 15, 0);
```

## Runtime Introspection

These functions let the host inspect the state of a running engine: read individual globals, enumerate all globals, filter to callable functions, and hook into the VM's execution line by line.

All four are available on **native** targets. `engine_get_global` also works on WebAssembly (it writes to WASM linear memory). The callback-based APIs (`engine_list_globals`, `engine_list_functions`, `engine_set_trace_fn`) are **not supported** on WebAssembly and return `-1` or are no-ops there.

Call these functions between or after `engine_run` / `engine_call` — not while a script is actively running on another thread.

### `engine_get_global(handle, name_ptr, name_len, out_ptr) -> i32`

Reads a single global variable by name and writes its current value into `*out_ptr` as a `ValueWire`.

`out_ptr` may be `NULL` to test existence without copying the value.

Returns:

- `0` on success;
- `-1` if the handle is invalid;
- `-2` if no global with that name exists; or
- `-3` if serialising the value to `ValueWire` fails.

### `engine_list_globals(handle, callback, userdata) -> i32`

Enumerates every global variable, invoking `callback` once per entry.

Callback signature:

```c
void callback(void *userdata, const char *name, int32_t name_len,
              const gengo_value_wire_t *value);
```

`name` is not null-terminated. `value` is valid only for the duration of the callback.

Passing `NULL` for `callback` is a no-op and returns `0`.

Returns:

- `0` on success;
- `-1` if the handle is invalid; or
- `-1` on WASM targets (not supported).

### `engine_list_functions(handle, callback, userdata) -> i32`

Like `engine_list_globals`, but only calls `callback` for globals that hold a script-defined function or closure. The arity (number of declared parameters) is passed instead of a `ValueWire`.

Callback signature:

```c
void callback(void *userdata, const char *name, int32_t name_len,
              int32_t arity);
```

Returns:

- `0` on success;
- `-1` if the handle is invalid; or
- `-1` on WASM targets (not supported).

### `engine_set_trace_fn(handle, callback, userdata) -> void`

Registers a callback that fires **once per source line** during script execution. The engine suppresses duplicate fires when multiple bytecode instructions map to the same line.

Callback signature:

```c
void callback(void *userdata, int32_t handle, int32_t line, int32_t col);
```

`line` and `col` are 1-based.

The callback fires inside the VM dispatch loop. Avoid calling `engine_run` or `engine_call` from within the callback.

Pass `NULL` for `callback` to clear the hook.

No-op on WASM targets.

### Introspection C example

```c
/* Dump all globals after running a script. */
static void print_global(void *ud, const char *name, int32_t name_len,
                          const gengo_value_wire_t *v) {
    (void)ud;
    printf("  %.*s  (tag=%d)\n", name_len, name, v->tag);
}

int handle = engine_init();
engine_run(handle, src, (int32_t)strlen(src));
engine_list_globals(handle, print_global, NULL);

/* Trace execution line by line. */
static void on_line(void *ud, int32_t h, int32_t line, int32_t col) {
    printf("engine %d  line %d  col %d\n", h, line, col);
}

engine_set_trace_fn(handle, on_line, NULL);
engine_call(handle, "main", 4, NULL, 0, NULL);
engine_set_trace_fn(handle, NULL, NULL);  /* clear */
```

## `ValueWire` Layout

`ValueWire` is a 24-byte extern record:

| Offset | Field | Type |
|---|---|---|
| `0` | `tag` | `u8` |
| `1` | `flags` | `u8` |
| `2` | `reserved` | `u16` |
| `4` | padding | `u32` |
| `8` | `payload` | `u64` |
| `16` | `len` | `u32` |
| `20` | `reserved2` | `u32` |

Supported tags: `null` (0), `boolean` (1), `number` (2), `string` (3), `array` (4), `map` (5), `error` (6). `number` uses the `flags` byte to distinguish `float`, `int`, `decimal`, and `rune`. For arrays, `payload` is a pointer to `len` consecutive `ValueWire` elements. For maps, `payload` is a pointer to `len * 2` elements arranged as key-value pairs. For strings and errors, `payload` is a guest pointer and `len` is the byte length. See `host-abi.md` for the full wire format reference.

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
