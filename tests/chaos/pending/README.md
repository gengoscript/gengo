# Pending chaos cases

Blocked on open bugs; not scanned by the chaos lane. When the fix lands,
move the case up (or into `fail/`), give it a `.out`/`.err`, and verify it
red with the fix reverted.

| Case | Blocked on | Expected once fixed |
|---|---|---|
| `044_named_string_gc_windows` | #120 residual GC stomper | clean output on all 10 pages |
