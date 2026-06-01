#!/usr/bin/env bash
# Run all bench cases with the perf-instrumented WASM binary.
# stdout is compared to expected output (correctness gate).
# stderr (PERF: lines) is captured per-case to build/perf/<case>.perf.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WASM="$ROOT_DIR/build/gengo-perf.wasm"
BENCH_DIR="$ROOT_DIR/examples/bench"
PERF_OUT_DIR="$ROOT_DIR/build/perf"
WASMTIME_BIN="${WASMTIME_BIN:-wasmtime}"

if ! command -v "$WASMTIME_BIN" >/dev/null 2>&1; then
  echo "wasmtime not found: $WASMTIME_BIN"; exit 1
fi
if [[ ! -f "$WASM" ]]; then
  echo "missing perf wasm: $WASM"; echo "run: zig build -Dpreset=dev bench-perf"; exit 1
fi

mkdir -p "$PERF_OUT_DIR"
pass_count=0
errors=0

while IFS= read -r script; do
  base="${script%.gengo}"
  rel="${script#$ROOT_DIR/}"
  out_file="${base}.out"
  got_file="${base}.got"
  perf_file="$PERF_OUT_DIR/$(basename "${base}").perf"
  policy_file="${base}.policy"

  [[ ! -f "$out_file" ]] && { echo "missing .out: $rel"; errors=$((errors+1)); continue; }
  allow_oom=0
  [[ -f "$policy_file" ]] && grep -q "ALLOW_OOM" "$policy_file" && allow_oom=1

  echo "[BENCH-PERF] $rel"

  if ! "$WASMTIME_BIN" --dir . "$WASM" -- "$rel" > "$got_file" 2>"$perf_file"; then
    if [[ $allow_oom -eq 1 ]] && grep -q "OutOfMemory" "$got_file"; then
      echo "  expected OOM accepted"
      pass_count=$((pass_count+1))
      continue
    fi
    echo "  FAIL (execution error)"; cat "$got_file"; errors=$((errors+1)); continue
  fi

  if ! diff -u "$out_file" "$got_file" > /dev/null 2>&1; then
    echo "  FAIL (output mismatch)"; diff -u "$out_file" "$got_file"; errors=$((errors+1)); continue
  fi

  pass_count=$((pass_count+1))

  # Print top-20 opcode counts from perf file
  if [[ -f "$perf_file" ]]; then
    grep '^PERF:op:' "$perf_file" | \
      sed 's/PERF:op://;s/=/ /' | \
      sort -k2 -rn | head -20 | \
      awk '{printf "  op %-30s %s\n", $1, $2}'
    grep '^PERF:gc_runs\|^PERF:alloc_objects\|^PERF:string_concat\|^PERF:map_probe' "$perf_file" | \
      sed 's/^PERF://;s/=/ = /' | \
      awk '{printf "  %-38s %s\n", $1, $3}'
    echo "  full perf data: $perf_file"
  fi
done < <(find "$BENCH_DIR" -maxdepth 1 -type f -name '*.gengo' | sort)

if [[ $errors -ne 0 ]]; then
  echo "bench-perf FAILED: ${pass_count} pass, ${errors} errors"; exit 1
fi
echo "bench-perf OK: ${pass_count} cases"
