# Gengo (言語)

A small embeddable scripting language implemented in Zig. Single-pass Pratt compiler → bytecode VM. Runs natively or as a WASI module.

**[Try it in the browser →](https://gengoscript.github.io/gengo/)**

Project status: early-stage and intentionally evolving.

## Language at a Glance

```gengo
std := import("std")

type Shape interface {
    area() float
}

type Rect struct { w float, h float }

func (r Rect) area() float {
    return r.w * r.h
}

func printArea(s Shape) {
    std.io.printf("area: %f\n", s.area())
}

printArea(Rect{w: 4.0, h: 3.0})
```

```gengo
std := import("std")

// Named types with range constraints
type Celsius float range -273.15..1000.0

// Multi-return with trap binding — panics on error, caught by defer/recover
func parseTemp(s string) {
    defer func() {
        err := std.core.recover()
        if err != null { std.io.println("bad input:", err) }
    }()

    n, trap := std.conv.to_float(s)
    std.io.printf("%.1f °C\n", float(Celsius(n)))
}

parseTemp("98.6")
parseTemp("not a number")
```

## Features

**Types**
- Structs with typed fields, nullable (`?T`), union (`A|B`), and method receivers
- Interfaces with structural satisfaction checking
- Enums with qualified member access (`Status.pending`)
- Named scalar types: `type UserId string`, `type Month int range 1..12`
- First-class `error` values; `any` as the empty interface

**Functions**
- Typed parameters (mandatory); `any` to opt out
- Variadic: `func sum(...xs int) int`
- Multi-return: `return value, err`
- Named return variables: `func f() (result float, err ?error)`
- Closures with upvalue capture

**Error Handling**
- `defer` — runs on function exit in LIFO order
- `std.core.recover()` — intercepts panics from inside a defer
- `assert condition` / `assert condition, "message"` — panic if false
- `x, trap := f()` — panic if the bound slot is non-null, pass through if null

**Control Flow**
- `if / else if / else` with optional init statement
- `for cond`, `for init; cond; post`, `for v in seq`, `for i, v in seq`
- `switch expr { case v { } default { } }`
- `break`, `continue`, `return`

**Declarations**
- `x := expr` — inferred mutable
- `x Type = expr` — explicit typed mutable
- `const x Type = expr` — immutable
- `_` discard in destructure: `val, _ := f()`

## Standard Library

| Namespace | Functions |
|---|---|
| `std.io` | `println`, `printf` |
| `std.core` | `len`, `bytelen`, `append`, `contains`, `remove`, `has`, `delete`, `keys`, `values`, `error`, `is_error`, `recover`, `gc`, `gc_live_objects`, `gc_stats` |
| `std.string` | `split`, `join`, `trim`, `upper`, `lower`, `starts_with`, `ends_with`, `index_of` |
| `std.math` | `abs`, `sqrt`, `floor`, `ceil`, `round`, `sin`, `cos`, `tan`, `log`, `log2`, `log10`, `pow`, `min`, `max`, `pi`, `e`, `inf` |
| `std.conv` | `to_int`, `to_float`, `to_bool`, `to_string` |

## Quick Start

**Native CLI** (recommended for development):

```bash
zig build -Dpreset=dev cli
./zig-out/bin/gengo script.gengo
```

**WASI runtime** (for browser/sandboxed embedding):

```bash
zig build -Dpreset=dev wasi
wasmtime --dir . ./zig-out/lib/gengo-test.wasm -- script.gengo
```

**Conformance tests:**

```bash
zig build -Dpreset=dev test
```

**Benchmarks:**

```bash
zig build -Dpreset=dev bench
```

## Build Presets

| Preset | Use |
|---|---|
| `dev` | Default — generous limits, debug-friendly |
| `tiny` | Minimal heap and stack for constrained embedding |
| `stress` | Tight limits to catch edge cases in tests |

Pass with `-Dpreset=<name>` to any build step.

## Toolchain

- Zig `0.16.0`
- wasmtime (any recent preview1-compatible release) — only needed for WASM target

## Repo Layout

```
src/
  lang/        lexer, compiler, bytecode, VM
  runtime/     heap, GC, host ABI, embedding API
examples/
  spec/        conformance pass-cases (+ .out expected output)
  spec/fail/   conformance fail-cases (+ .err expected error)
  bench/       benchmark scripts
docs/          language reference, embedding guide, changelog
playground/    browser playground (GitHub Pages)
```

## Embedding

Gengo is designed to be embedded in Zig hosts. See `docs/embedding.md` and `src/runtime/api.zig`.

Runtime limits (heap, stack, call depth, etc.) are configured via preset files in `src/runtime/`.

## Notes

- File extension: `.gengo`
- Only `import("std")` is currently supported; file imports are planned
- A single managed heap block is capped at 32 KiB regardless of total heap size
- Language surface is still evolving; breaking changes are expected
