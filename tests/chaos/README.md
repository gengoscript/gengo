# Chaos lane

Limit and edge-case behavior, pinned as expectations and run against the
native CLI on every push (`zig build -Dpreset=1m chaos`).

- `*.gengo` + `*.out` — must succeed and match output exactly.
- `fail/*.gengo` + `fail/*.err` — must fail, with every `.err` line present
  in the combined output. Error files carry error names only (no byte
  counts or limits), so they stay valid across preset changes.
- `pending/` — cases blocked on open bugs; not scanned. Move them up and
  give them expectations when their fix lands — they become the
  regression tests.

Expectations pin **current** behavior at the limits. If a semantic change
moves one of these (e.g. the top-level closure capture question, #118),
the test update is part of that change — never an incidental edit.

## Hard limits documented by these cases (dev preset)

| Limit | Value | Case |
|---|---|---|
| Constant pool | 512 | `fail/013` |
| Call stack | 64 frames | `fail/005` |
| Defer stack | 128 | `fail/016` |
| String pool | 128 KB (`lexer.StrPoolSize`) | `pending/012` |
| Input size | `cfg.max_input_bytes` (128 KB dev) | `pending/029` |

## Notable pinned behaviors

- Top-level loop closures see the final loop value (globals by reference);
  this also holds for top-level `for in` with an explicit copy
  (`008`/`009`/`010`/`030`, #118).
- Defers that were pushed successfully all run before a
  `DeferStackOverflow` panic unwinds (`fail/016`) — by design.
- Division/modulo by zero panic rather than producing `Inf`/`NaN`
  (`fail/022`–`024`) — by design.
- TCO holds through multi-value returns (`007`).
- Duplicate string keys in map literals keep the first value (`033`).
- Map keys are expressions: quoted strings are literals, bare identifiers
  are variable references — affirmed design decision (`039`).
- Recursive maps are safe to compare and clone (`037`, `041`, `042`), but
  not yet safe to print or format (`pending/028`, `pending/040`).
