# Gengoscript Testing and Benchmarking

## Harness layout

Standalone orchestrators that only shell out to wasmtime (`test_runner.zig`,
`bench_perf_runner.zig`) live in `tools/`. White-box harness roots that import
VM internals (`fuzz_runner.zig`, `vm_safety_runner.zig`, `compiler_test.zig`,
etc.) must stay at the top of `src/`: a Zig module root cannot import files
outside its own directory tree, and moving the two test roots behind a module
boundary would also silently drop their `test` blocks from collection.

## Conformance

Run full conformance suite:

```bash
zig build -Dpreset=1m test
```

Notes:
- `test` forces `1m` preset (`config-1m`) first.
- Pass cases are in `tests/spec/*.gengo` with matching `.out` files.
- Fail cases are in `tests/spec/fail/*.gengo` with matching `.err` token files.

## Parity Harness

Run embedded vs host-backend parity checks:

```bash
zig build -Dpreset=1m parity
```

Notes:
- Parity cases live in `tests/parity/*.gengo`.
- Host backend gracefully falls back to VM-local implementations when host import is unavailable.

## Bench Harness

Run benchmarks:

```bash
zig build -Dpreset=1m bench
zig build -Dpreset=256k bench
zig build -Dpreset=16m bench
```

Timing and throughput mode (set via `GENGO_BENCH_STATS=1`):

```bash
GENGO_BENCH_STATS=1 zig build -Dpreset=1m bench
```

Bench files:
- `tests/bench/*.gengo`: benchmark scripts
- `*.out`: expected output
- `*.policy`: optional behavior policy
- `*.ops`: optional operation count for ops/sec logging

Policy values:
- `ALLOW_OOM`: OutOfMemory is treated as expected success for that bench case.

## Native VM Sampling Profiles

For Linux `perf` sampling against the native VM:

```bash
tools/profile-vm.sh
tools/profile-vm.sh case tests/bench/006_call_overhead.gengo
```

If `perf` requires elevated privileges on your machine:

```bash
tools/profile-vm.sh run --sudo
```

See `dev-docs/perf/profiling.md` for the report layout and interpretation.
