# Gengo (言語)

gengo is a small embeddable scripting language/runtime implemented in Zig.

Project status: early-stage and intentionally evolving.

## Language Example

```gengo
std := import("std")

struct User {
    id: int
    name: string
    bio: ?string
}

func greet(u User) {
    # Multiline escaped string:
    # open with ", continue with " at same column, close on last line with ".
    msg := "Hello,
           "this is gengo
           "User:"
    std.io.println(msg + " " + u.name)
}

u := User{ id: 7, name: "user", bio: "こんにちは" }
greet(u)
```

Raw multiline strings use `'` with the same continuation/termination shape and keep backslashes literally.

## Toolchain

- Zig: `0.16.0` (matches CI)
- wasmtime: recent preview1-compatible release

## Quick Start

Build the WASI runtime:

```bash
zig build -Dpreset=dev wasi
```

Run a script:

```bash
wasmtime --dir . ./gengo-test.wasm -- examples/simple_math.gengo
```

Run conformance tests:

```bash
WASMTIME_BIN=/path/to/wasmtime zig build -Dpreset=dev test
```

## Repo Layout

- `lang/`: lexer, compiler, bytecode, VM logic
- `runtime/`: runtime services, host ABI, memory
- `examples/`: spec, fail-cases, benchmarks, parity cases
- `docs/`: language and runtime docs
- `tests/`: harness scripts used by `make test` / `make bench`

## Notes

- File extension is `.gengo`.
- `import("std")` is the supported builtin namespace.
- Language behavior may change as the project evolves.
- Runtime defaults are small by design (see `docs/language.md` limits section).
- Managed heap allocations are class-based; a single managed block is currently capped at `32 KiB`.

## Browser Playground

A GitHub Pages playground is included under `playground/`.

- It runs the WASI `gengo-test.wasm` in-browser.
- It mounts your script as an in-memory file (`script.gengo`) and executes it.

After pushing to `main`, the Pages workflow publishes the site.
