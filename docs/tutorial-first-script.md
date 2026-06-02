# gengo Tutorial: First Script

This walkthrough takes you from build to a working script with verified output.

## 1. Build gengo (dev preset)

```bash
zig build -Dpreset=dev wasi
```

Expected tail output:

```text
Built /..././gengo-runtime.wasm
Run with: wasmtime --dir / /..././gengo-runtime.wasm -- <script>
```

## 2. Create a script

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

## 3. Run it

```bash
wasmtime --dir . ./gengo-runtime.wasm -- examples/hello_tutorial.gengo
```

Expected output:

```text
hello gengo
3
6
🙂
3
```

## 4. Try a type contract

Replace script contents with:

```gengo
std := import("std")

type User struct { name string, initial rune }
func greet(u User) {
  std.io.println(u.name, std.conv.to_string(u.initial))
}

greet(User{ name: "Mikael", initial: `M` })
```

Run again:

```bash
wasmtime --dir . ./gengo-runtime.wasm -- examples/hello_tutorial.gengo
```

Expected output:

```text
Mikael M
```

## 5. Validate your environment

Run conformance:

```bash
WASMTIME_BIN=/path/to/wasmtime zig build -Dpreset=dev test
```

Run backend parity checks:

```bash
WASMTIME_BIN=/path/to/wasmtime zig build -Dpreset=dev parity
```

Run tiny benchmark lane:

```bash
WASMTIME_BIN=/path/to/wasmtime zig build -Dpreset=tiny bench
```

Notes:
- `bench`/`bench-tiny` include policy-driven expected low-memory behavior for selected bench cases.
