# Gengoscript Quickstart

Gengoscript is an embeddable language for applications that need scriptable
logic without giving scripts ambient machine access. Use it when the host owns
I/O, capabilities, and resource limits; it is not a replacement for an
operating-system sandbox.

## Choose how to try or install it

- **Use the playground:** open [playground.gengoscript.org](https://playground.gengoscript.org)
  to write and run a script without installing the CLI.
- **Use a released binary:** download the artifact for your platform from the
  [GitHub Releases page](https://github.com/gengoscript/gengo/releases). Use
  the release notes and artifact checksums for that release; this main-branch
  page does not substitute for release-specific installation instructions.
- **Build from source:** use the next section when developing Gengoscript,
  testing main-branch behaviour, or when no suitable release artifact exists.

## Requirements and supported hosts

You need a normal shell, Git, and Zig **0.16.0**. Native CLI development is
tested on Linux in this checkout. The WASI CLI is run with Wasmtime in CI.
Browser use loads the separate engine WASM artifact; see `typescript-sdk.md`.

## Build from source

From the directory where you want the source checkout:

```sh
git clone https://github.com/gengoscript/gengo.git
cd gengo
zig build -Dpreset=1m cli
zig build -Dpreset=1m wasi
```

Every remaining command in the source-build route assumes the repository root
(`gengo`) as its working directory. The native artifact is `zig-out/bin/gengo`;
the WASI CLI is `build/debug/gengo-cli.wasm`.

## Your first script

Create `hello.gengo` in the repository root:

```gengo
std := import("std")
std.io.println("hello, Gengoscript")
```

Run it:

```sh
./zig-out/bin/gengo hello.gengo
```

Expected output:

```text
hello, Gengoscript
```

Start the REPL with `./zig-out/bin/gengo`; exit it with EOF (`Ctrl-D` on Unix).
Run the same file through WASI:

```sh
wasmtime --dir . ./build/debug/gengo-cli.wasm -- hello.gengo
```

The `--dir .` mount lets the WASI process read `hello.gengo`; it does not grant
a script `cap:fs` unless that capability and a mount are separately configured.

## Browser and integration paths

Build the browser-oriented engine artifact with:

```sh
zig build -Dpreset=1m engine-build
```

It writes `build/debug/gengo-engine.wasm`. Load that artifact from a browser
with the TypeScript SDK described in `typescript-sdk.md`. For Zig embedding,
read `embedding.md`; for C and other native hosts, start with `engine-api.md`
and `host-abi.md`.

## Common failures

| Symptom | What to check |
|---|---|
| `zig: command not found` or build version errors | Install Zig 0.16.0 and confirm `zig version`. |
| `wasmtime: command not found` | Install Wasmtime or pass `-Dwasmtime=/path/to/wasmtime` to test builds. |
| `gengo: compile error` | Check the file path, syntax, and imports; relative imports are restricted to the script directory unless `--modules` is supplied. |
| WASI cannot open the script | Run from the repository root and include `--dir .`. |
| Capability import rejected | The host/build has not enabled that capability; see `capability-matrix.md`. |

For a progressive language tutorial, continue to `tutorial-first-script.md`.
