# gengo Tutorial: First Script

This walkthrough takes you from build to a working script with verified output.

## 1. Build gengo (dev preset)

```bash
make -C userland/cmd/gengo config-dev
make -C userland/cmd/gengo wasi
```

Expected tail output:

```text
Built /.../userland/cmd/gengo/gengo-test.wasm
Run with: wasmtime --dir / /.../userland/cmd/gengo/gengo-test.wasm -- <script>
```

## 2. Create a script

Create `userland/cmd/gengo/examples/hello_tutorial.gengo`:

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
wasmtime --dir . userland/cmd/gengo/gengo-test.wasm -- userland/cmd/gengo/examples/hello_tutorial.gengo
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

struct User { name: string, initial: rune }
func greet(u User) {
  std.io.println(u.name, std.conv.to_string(u.initial))
}

greet(User{ name: "Mikael", initial: `M` })
```

Run again:

```bash
wasmtime --dir . userland/cmd/gengo/gengo-test.wasm -- userland/cmd/gengo/examples/hello_tutorial.gengo
```

Expected output:

```text
Mikael M
```

## 5. Validate your environment

Run conformance:

```bash
make -C userland/cmd/gengo test
```

Run backend parity checks:

```bash
make -C userland/cmd/gengo parity
```

Run tiny benchmark lane:

```bash
make -C userland/cmd/gengo bench-tiny
```

Notes:
- `test` always re-applies `config-dev` first.
- `bench-tiny` includes expected low-memory behavior for selected bench cases.
