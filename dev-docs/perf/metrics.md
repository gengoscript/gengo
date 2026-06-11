# Performance Metrics Reference

Instrumentation is compiled into `gengo-perf.wasm` when built with `-Dperf=true`.
Normal builds (`wasi`, `cli-release`, etc.) compile out all counter code — no runtime overhead.

## Enabling

```bash
# Build the perf-instrumented binary and run all bench cases:
zig build -Dpreset=dev bench-perf

# Per-case perf data is written to build/perf/<case>.perf
# Each line has the form:  PERF:<metric>=<value>
```

## Metric Reference

### GC Metrics

| Metric | Description |
|---|---|
| `gc_runs` | Total GC collections triggered during the run |
| `gc_time_ns` | Total nanoseconds spent in GC (mark + sweep) |
| `gc_marked_total` | Total objects found live across all GC runs |
| `gc_swept_total` | Total objects freed across all GC runs |

Derived: `gc_swept_total / gc_runs` = average objects freed per collection.
Derived: `gc_time_ns / gc_runs` = average GC pause in ns.

### Allocation Metrics

| Metric | Description |
|---|---|
| `alloc_objects` | Total `vmAllocObject()` calls (includes GC-triggered retries) |
| `alloc_managed_slices` | Total `vmAllocManagedSlice()` calls |
| `alloc_managed_bytes_calls` | Total `vmAllocManagedBytes()` calls (string backing store) |

### String Metrics

| Metric | Description |
|---|---|
| `string_concat_bytes` | Total bytes copied by string `+` concat operations |

High values indicate concat-chain workloads that could benefit from a string-builder lowering pass.

### Map Metrics

| Metric | Description |
|---|---|
| `map_probe_total` | Total hash probes across all hashed-map lookups |
| `map_probe_ops` | Total hashed-map lookup operations |

Derived: `map_probe_total / map_probe_ops` = average probes per lookup (ideal = 1.0).
Only `map_hashed` (large maps) contributes; linear `map` and `map_managed` do not.

### Opcode Counts

```
PERF:op:<opcode_name>=<count>
```

One line per opcode that executed at least once, in the order they appear in `op.zig`.
Use these to identify the hottest opcodes for superinstruction candidates.

### Opcode Pair Counts

```
PERF:pair:<first_op>,<second_op>=<count>
```

Counts consecutive opcode pairs within the same function (pairs spanning `ret`/`halt` are not counted).
Use these to identify the most frequent sequential op sequences for superinstruction candidates.

Top pairs across typical workloads:

| Pair | Likely pattern |
|---|---|
| `constant,eq` | `if x == K` comparisons |
| `get_local,add` | `x + y` where x is a local |
| `loop,get_global` | loop body starting with a global load |
| `jump_if_false,loop` | loop-closing branch |

### Hostcall Counts

```
PERF:hostcall:<id>=<count>
```

Counts calls to each native function by its numeric ID (see `NativeFnId` in `vm_native.zig`).

| ID | Function |
|---|---|
| 1 | `io_println` |
| 46 | `io_print` |
| 15 | `io_printf` |
| 2 | `core_len` |
| 3 | `core_append` |
| 6 | `core_gc` |

## Adding New Metrics

1. Add counter field to `PerfCounters` in `src/lang/vm_perf.zig`.
2. Add an `inline countXxx(...)` function guarded by `if (!perf_enabled) return`.
3. Call it at the relevant site.
4. Add a `PERF:<metric>=<value>` print line in `printSummary`.
5. Document it here.
