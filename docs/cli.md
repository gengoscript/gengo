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
| `--test` | Run top-level `test` blocks rather than ordinary script execution. A failed test exits unsuccessfully. |
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
