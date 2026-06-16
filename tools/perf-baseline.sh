#!/usr/bin/env bash
# Tracks Gengo's own bytecode-execution cost across releases.
#
# Unlike wall-clock benchmarks, this compares exact per-opcode execution
# counts, GC runs, and allocation counts captured by the perf-instrumented
# build (`zig build -Dpreset=dev bench-perf`, see tools/bench_perf_runner.zig).
# These are deterministic for a given script — no run-to-run noise, no
# machine-to-machine noise — so any difference at all is a real change in
# what the compiler/VM does for that script, not measurement jitter.
#
# Usage:
#   tools/perf-baseline.sh check    # compare against the checked-in baseline (default)
#   tools/perf-baseline.sh update   # regenerate the baseline from the current build
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-check}"
if [ "$MODE" != "check" ] && [ "$MODE" != "update" ]; then
  echo "usage: $0 [check|update]" >&2
  exit 1
fi

BASELINE="tests/bench/perf_baseline.txt"

echo "→ building perf-instrumented engine and running bench-perf..." >&2
if ! zig build -Dpreset=dev bench-perf > /tmp/gengo-bench-perf.log 2>&1; then
  cat /tmp/gengo-bench-perf.log >&2
  echo "bench-perf run failed" >&2
  exit 1
fi

CURRENT="$(mktemp)"
trap 'rm -f "$CURRENT"' EXIT

for f in build/perf/*.perf; do
  name="$(basename "$f" .perf)"
  total_ops=$(grep '^PERF:op:' "$f" | awk -F'=' '{sum+=$2} END {print sum+0}')
  gc_runs=$(grep '^PERF:gc_runs=' "$f" | cut -d= -f2)
  alloc_objects=$(grep '^PERF:alloc_objects=' "$f" | cut -d= -f2)
  string_concat_bytes=$(grep '^PERF:string_concat_bytes=' "$f" | cut -d= -f2)
  echo "${name} total_ops=${total_ops:-0} gc_runs=${gc_runs:-0} alloc_objects=${alloc_objects:-0} string_concat_bytes=${string_concat_bytes:-0}"
done | sort > "$CURRENT"

if [ "$MODE" = "update" ]; then
  cp "$CURRENT" "$BASELINE"
  echo "baseline updated: $BASELINE ($(wc -l < "$BASELINE") cases)"
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "no baseline yet — run '$0 update' to create one" >&2
  exit 1
fi

if diff -u "$BASELINE" "$CURRENT" > /tmp/gengo-perf-diff.txt; then
  echo "perf baseline: no change ($(wc -l < "$BASELINE") cases)"
  exit 0
fi

echo "PERF CHANGE DETECTED (review before accepting — could be an intentional optimization or a regression):"
cat /tmp/gengo-perf-diff.txt
echo
echo "If this change is expected, run: $0 update"
exit 1
