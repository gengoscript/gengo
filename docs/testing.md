# gengo Testing and Benchmarking

## Conformance

Run full conformance suite:

```bash
make -C userland/cmd/gengo test
```

Notes:
- `test` forces dev preset (`config-dev`) first.
- Pass cases are in `examples/spec/*.gengo` with matching `.out` files.
- Fail cases are in `examples/spec/fail/*.gengo` with matching `.err` token files.

## Parity Harness

Run embedded vs host-backend parity checks:

```bash
make -C userland/cmd/gengo parity
```

Notes:
- Parity cases live in `examples/parity/*.gengo`.
- Host backend gracefully falls back to VM-local implementations when host import is unavailable.

## Bench Harness

Run benchmarks:

```bash
make -C userland/cmd/gengo bench
make -C userland/cmd/gengo bench-tiny
make -C userland/cmd/gengo bench-stress
```

Timing and throughput mode:

```bash
GENGO_BENCH_STATS=1 make -C userland/cmd/gengo bench
```

Bench files:
- `examples/bench/*.gengo`: benchmark scripts
- `*.out`: expected output
- `*.policy`: optional behavior policy
- `*.ops`: optional operation count for ops/sec logging

Policy values:
- `ALLOW_OOM`: OutOfMemory is treated as expected success for that bench case.
