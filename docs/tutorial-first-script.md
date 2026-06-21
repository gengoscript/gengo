# Gengoscript Tutorial: First Script

This walkthrough takes you from a fresh build to a small working script.

If you only need the command summary, see `quickstart.md`.

This walkthrough assumes `wasmtime` is installed and available on `PATH`.

## 1. Build the WASI Runtime

```bash
zig build -Dpreset=1m wasi
```

## 2. Create a Script

Create `examples/hello_tutorial.gengo`:

```gengo
std := import("std")

name := "gengo"
nums := [2, 3, 4]

std.io.println("hello", name)
std.io.println(std.core.len("åäö"))
std.io.println(std.core.bytelen("åäö"))
std.io.println(std.conv.to_string(`🙂`))
std.io.println(nums[1])
```

## 3. Run It

```bash
wasmtime --dir . ./build/gengo-cli.wasm -- examples/hello_tutorial.gengo
```

Expected output:

```text
hello gengo
3
6
🙂
3
```

## 4. Add a Type Contract

Replace the file contents with:

```gengo
std := import("std")

type User struct { name string, initial rune }

func greet(u User) {
  std.io.println(u.name, std.conv.to_string(u.initial))
}

greet(User{ name: "Ada", initial: `A` })
```

Run it again:

```bash
wasmtime --dir . ./build/gengo-cli.wasm -- examples/hello_tutorial.gengo
```

Expected output:

```text
Ada A
```

The important point is that the type contract lives inside the script. Invalid values fail where they are constructed, not later in host-side validation code.

## 5. Named Types and Domain Rules

Replace the file with a script that uses named types to enforce domain rules:

```gengo
std := import("std")

type Port int range 1..65535
type Percent int range 0..100

func scale(port Port, factor Percent) int {
    return int(port) * int(factor) / 100
}

p := Port(443)
// Port(0)          // runtime range error — 0 is outside 1..65535

pct := Percent(50)
std.io.println(scale(p, pct))
```

Run it:

```bash
wasmtime --dir . ./build/gengo-cli.wasm -- examples/hello_tutorial.gengo
```

Expected output:

```text
221
```

Named types keep domain rules inside the script. A `Port` rejects out-of-range values at construction time. Two different named types cannot be mixed directly — `scale(Port(80), Percent(50))` is fine, but `scale(80, 50)` is a type error because bare `int` and named `Port` do not mix. This prevents accidental misuse where the wrong kind of number is passed to the wrong place.

## 6. Error Handling and Recovery

Add a script that uses `defer` and `recover` to handle panics:

```gengo
std  := import("std")
core := std.core

func divide(a int, b int) (result int) {
    defer func() {
        e := core.recover()
        if core.is_error(e) {
            std.io.println("recovered:", e)
        }
    }()
    return a / b
}

std.io.println(divide(10, 2))
std.io.println(divide(10, 0))
```

Run it:

```bash
wasmtime --dir . ./build/gengo-cli.wasm -- examples/hello_tutorial.gengo
```

Expected output:

```text
5
recovered: DivisionByZero
0
```

`defer` schedules a function to run when the current function returns, even during a panic unwind. `std.core.recover()` catches the panic payload inside a `defer` function and stops the unwind.

## 7. Check the Environment

Run the conformance suite:

```bash
zig build -Dpreset=1m test
```

Run parity checks:

```bash
zig build -Dpreset=1m parity
```

If you are working on runtime behaviour, also run:

```bash
zig build -Dpreset=1m test
```
