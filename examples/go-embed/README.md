# Go embedding

A minimal Go example that embeds `libgengo-engine.so` through `cgo`.

This is the smallest practical native-host setup:

* initialize an engine
* load a script
* call an exported Gengoscript function
* read back the result
* surface compile/runtime errors through `engine_last_error`

## Build the engine

Build the native shared library first:

```bash
zig build -Dpreset=1m engine-native
```

## Run

From the repo root:

```bash
cd examples/go-embed
CGO_LDFLAGS="-Wl,-rpath,$PWD/../../zig-out/lib" go run .
```

If you prefer, you can set `LD_LIBRARY_PATH` instead of using `rpath`:

```bash
cd examples/go-embed
LD_LIBRARY_PATH=../../zig-out/lib go run .
```

## What it shows

* `cgo` binding to the native C engine surface
* `engine_init`, `engine_run`, `engine_call`, and `engine_destroy`
* scalar wire values (int, bool, string) via `gengo-wire.h`'s builders/readers
* array and map wire values via `gengo_wire_array`/`gengo_wire_map` and
  `gengo_wire_array_at`/`gengo_wire_map_key_at`/`gengo_wire_map_value_at` —
  the backing element storage is caller-owned Go memory and must outlive the
  `engine_call` that references it
* a long-lived engine handle that loads once and calls many times

## Files

* `main.go`: minimal Go host
* `go.mod`: tiny module definition
