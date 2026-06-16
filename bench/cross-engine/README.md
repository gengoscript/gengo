# Cross-engine comparison

**[See the latest captured results →](RESULTS.md)**

Two minimal, portable benchmarks — naive recursive `fib(32)` and a 20M-iteration
tight loop — implemented identically in Gengo and a few peer scripting
engines (Lua, Python, Node), so the comparison is actually apples-to-apples.

Deliberately excluded: anything Gengo-specific (named types, variants,
structs) and anything engine-specific (Lua metatables, Python comprehensions,
JS classes). These two cases only exercise function calls, arithmetic, and
loops — the lowest common denominator every scripting engine here supports
identically.

This is **informational**, not a claim of "fastest" or "slowest" in
general. Results depend on the machine, the engine version installed, and
the build mode. Re-run it yourself rather than trusting a number from a
different machine.

For Gengo's own cost model over time (not cross-engine), see
`tools/perf-baseline.sh` instead — that tracks exact per-opcode execution
counts release to release, using Gengo-specific feature scripts in
`tests/bench/`.

## Running it

```bash
bench/cross-engine/run.sh
```

`run.sh` (re)builds the native ReleaseSafe CLI itself before timing — it
doesn't trust whatever happens to already be at `zig-out/bin/gengo`, since
that path is shared with the Debug `cli` build step and a stale Debug
binary would silently make Gengo look several times slower than it is.

Requires `lua5.4` (or adjust `run.sh`'s `ENGINES` map for `lua`/`lua5.3`),
`python3`, and `node` on `PATH`. Any engine that's missing is skipped, not
fatal.

## Files

- `fib_recursive.{gengo,lua,py,js}` — naive recursive `fib(32)`, exponential
  work, exercises function-call overhead.
- `loop_sum.{gengo,lua,py,js}` — a tight 20M-iteration loop summing
  integers, exercises basic loop/arithmetic overhead without recursion.
- `run.sh` — times each engine running each case, prints a table.
