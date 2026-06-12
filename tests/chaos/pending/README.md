# Pending chaos cases

Blocked on open bugs; not scanned by the chaos lane. When the fix lands,
move the case up (or into `fail/`), give it a `.out`/`.err`, and verify it
red with the fix reverted.

| Case | Blocked on | Expected once fixed |
|---|---|---|
| `003_many_long_vars` | #116 silent input truncation | loud "input exceeds max_input_bytes" error |
| `004_fewer_long_vars` | #116 | same |
| `012_string_pool_overflow` | #116 (truncation masks the pool path in dev) | pool or input error, message names the limit |
| `028_print_recursive_map` | #117 print cycle host crash | bounded output (`...` or `<cycle>`), no abort |
| `029_truncation` | #116 | loud error instead of silently running half a program |
