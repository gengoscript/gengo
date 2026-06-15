# Gengoscript Tutorial: First Script

This walkthrough takes you from a fresh build to a small working script.

If you only need the command summary, see `quickstart.md`.

This walkthrough assumes `wasmtime` is installed and available on `PATH`.

## 1. Build the WASI Runtime

```bash
zig build -Dpreset=dev wasi
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

## 5. Check the Environment

Run the conformance suite:

```bash
zig build -Dpreset=dev test
```

Run parity checks:

```bash
zig build -Dpreset=dev parity
```

If you are working on runtime behaviour, also run:

```bash
zig build -Dpreset=stress test
```
