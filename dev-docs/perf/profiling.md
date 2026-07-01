# VM Sampling Profiling

This complements the existing perf tooling:

- `tools/perf-baseline.sh`: deterministic VM counters
- `tools/time-bench.sh`: wall-clock timing
- `tools/profile-vm.sh`: Linux `perf` sampling on the native VM

Use sampling when you want to answer:

- where CPU time is actually going
- whether a benchmark is dispatch-bound, call-bound, GC-bound, or helper-bound
- which functions should be investigated next

## Run a curated profile sweep

```bash
tools/profile-vm.sh
```

If `perf` requires root on your machine:

```bash
tools/profile-vm.sh run --sudo
```

This builds `zig-out/bin/gengo-fast` and profiles a focused set of VM-heavy
bench cases:

- `007_dispatch_loop`
- `006_call_overhead`
- `003_fib_recursive`
- `001_compute_stress`
- `009_struct_field_access`
- `010_string_concat_heavy`
- `011_map_lookup_heavy`

Reports land under:

```bash
build/profiles/<timestamp>/<case>/
```

Each case directory contains:

- `perf.data`: raw perf capture
- `report.symbol.txt`: flat symbol view
- `report.children.txt`: caller/callee breakdown
- `report.callgraph.txt`: symbol-sorted report by command/shared object/symbol

## Profile one case

```bash
tools/profile-vm.sh case tests/bench/006_call_overhead.gengo
```

You can raise sampling frequency if the run is short:

```bash
tools/profile-vm.sh case tests/bench/006_call_overhead.gengo --freq 1999
```

## Interpreting results

Typical signals:

- `lang.vm.runInner` dominates with few large callees:
  interpreter overhead is still the main cost
- `lang.vm.performCall` / `lang.vm.enterFunctionFrame` dominate:
  call setup is expensive
- `lang.vm_types.enforceFuncArgTypes` / `matchesTypeSpec` dominate:
  type validation is on the hot path
- `lang.vm.readGlobalIC` dominates:
  global lookup is still materially expensive
- string helpers or GC dominate:
  allocation pressure is the next optimization target

For analysis, the most useful files to share are:

- `report.symbol.txt`
- `report.children.txt`
