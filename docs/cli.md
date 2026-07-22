# Gengoscript CLI and REPL Reference

Commands on this page use `gengo` as an installed executable. If you built
this checkout from source and have not installed it, substitute
`./zig-out/bin/gengo` while working from the repository root.

## Invocation

```text
gengo [options] [script.gengo]
```

Run a source file:

```bash
gengo hello.gengo
```

Use `-e` or `--eval` for a short program. It cannot be combined with a script
path:

```bash
gengo --eval 'std := import("std"); std.io.println("hello")'
```

If no script and no `--eval` source are given, the CLI starts the REPL only
when standard input is a terminal. With piped standard input, it reads the
script from standard input instead.

## Options

| Option | Meaning |
|---|---|
| `--help`, `-h` | Print the option summary and exit. |
| `--version` | Print the CLI version and exit. |
| `--disasm` | Compile and print a bytecode disassembly without running the script. This is an implementation-debugging aid, not language semantics. |
| `--emit-gbc path` | Compile the script and write a GBC (Gengo Bytecode Cache) artifact to `path`; do not run. See below. |
| `--test` | Run top-level `test` blocks rather than ordinary script execution. A failed test exits unsuccessfully. |
| `--profile` | With `--test`, print each block's instruction count and peak heap bytes/stack depth/live object count, plus a final peak-across-all-blocks summary line. Does not affect pass/fail behavior or the exit code. Forces per-instruction instruction counting on for the run, which costs real speed — a diagnostic aid, not something to leave on by default. |
| `--cap name` | Enable one named capability. Repeat for several capabilities. See `capabilities.md`; no capability is enabled merely by importing it. |
| `--modules path` | Permit source imports from one additional directory. Repeatable, up to eight paths. The script directory remains the default source root. |
| `--max-ops n` | Limit VM instruction execution to `n`. `0` means unlimited. This limit does not account for work inside host callbacks. |
| `--heap size` | Set the GC heap size. A size may be bytes or end in `k`, `m`, or `g`; the default is `1m`. |
| `--backend embedded\|host` | Select the native-call backend. `embedded` is the default; `host` is an embedding/debugging configuration. |
| `--mount name=path` | Add a named filesystem mount for `cap:fs`. A mount is not itself authority: also enable `--cap fs`. |
| `--` | End option parsing. The next argument is treated as a script path even if it begins with `-`. |

For example, a bounded script with narrowly enabled environment access is:

```bash
APP_REGION=production gengo --cap env --max-ops 100000 policy.gengo
```

`cap:env` exposes the process environment available to the CLI. It should not
be enabled for untrusted scripts unless the inherited environment is already
safe to disclose; see `capabilities.md` and `security.md`.

## Imports and Filesystem Mounts

When a script path is supplied, source imports are restricted to its directory
by default. `--modules` adds roots; it does not make arbitrary paths readable.

```bash
gengo --modules ./shared app/main.gengo
```

Filesystem capability paths use a mount name, not an unrestricted native path:

```bash
gengo --cap fs --mount assets=./assets app/main.gengo
```

The script can then use paths under `assets/...`. See the capability reference
for traversal, symlink, and host-platform limits.

## GBC (Bytecode Cache)

`--emit-gbc path` compiles a script and writes a `.gbc` artifact instead of
running it. A `.gbc` file passed as the script argument runs directly,
skipping parsing and compilation entirely — the file is recognized by its
magic bytes, not its extension, though naming it `.gbc` is the convention:

```bash
gengo --emit-gbc app.gbc app.gengo    # compile once
gengo app.gbc                         # run the cached artifact, repeatedly
```

This is early — the current implementation covers a first milestone (see
`dev-docs/design/gbc-spec.md` and GitHub issue #5), not the full format:

- `struct`, named-type, and `variant` values (including range/cycle/clamp-
  constrained named types, and a struct field, variant arm/shared field, or
  named collection referencing another type by name) are supported. Not yet
  supported: enums, interfaces, a named type with a `predicate`, or a closure
  with captures stored as a constant (a plain top-level function, or a
  captureless closure attached via ordinary bytecode execution rather than
  embedded as a constant, both work). `--emit-gbc` fails with a clear error
  naming the limitation rather than producing a broken artifact.
- The artifact records a hash of the source it was compiled from, but the
  CLI does not yet check it against the current source file before running
  a `.gbc` — nothing currently stops you from running a `.gbc` that no
  longer matches its `.gengo` source. Treat a `.gbc` as something you
  regenerate whenever its source changes, not as a transparent, self-invalidating
  cache yet.
- `--emit-gbc` is not currently supported when running the WASI build.

## REPL

Start the REPL by running the executable with no source while attached to a
terminal:

```bash
gengo
```

It prints `Gengo REPL  (Ctrl+D to exit)` and accepts one input line at a time.
Definitions from successful lines persist for later lines, including type
declarations. Exit with EOF (`Ctrl-D` on Unix-like terminals).

The REPL accepts `--cap`, `--max-ops`, and `--backend` before it starts. It
does not take a script path, so `--modules` does not establish entry-script
import roots. A `--mount` still configures the process-wide filesystem mount
table and can be used by an enabled `cap:fs` import from a REPL line.

## Diagnostics and Exit Status

The CLI writes script output to standard output and diagnostics to standard
error. Compile errors identify a source location; runtime panics identify the
failure location and may include a stack trace. An option error, unreadable
input, compile error, runtime panic, or failed test exits with status `1`.
Successful execution, `--help`, `--version`, and normal REPL EOF exit with
status `0`.

See also: `quickstart.md` for installation and first use, `language.md` for
imports and test blocks, and `security.md` for limits appropriate to untrusted
scripts.
