#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WASM="$ROOT_DIR/build/gengo-runtime.wasm"
BENCH_DIR="$ROOT_DIR/examples/bench"
WASMTIME_BIN="${WASMTIME_BIN:-wasmtime}"

if ! command -v "$WASMTIME_BIN" >/dev/null 2>&1; then
  echo "wasmtime not found: $WASMTIME_BIN"
  exit 1
fi

if [[ ! -f "$WASM" ]]; then
  echo "missing wasm binary: $WASM"
  echo "run: make wasi"
  exit 1
fi

pass_count=0
errors=0

cd "$ROOT_DIR"

BENCH_INCLUDE_STRESS="${GENGO_BENCH_INCLUDE_STRESS:-0}"
BENCH_FILTER="${GENGO_BENCH_FILTER:-}"
BENCH_STATS="${GENGO_BENCH_STATS:-0}"

while IFS= read -r script; do
  if [[ "$BENCH_INCLUDE_STRESS" != "1" ]] && [[ "$script" =~ 005_fib_recursive_35_stress\.gengo$ ]]; then
    continue
  fi
  if [[ -n "$BENCH_FILTER" ]] && [[ ! "$script" =~ $BENCH_FILTER ]]; then
    continue
  fi
  base="${script%.gengo}"
  rel_script="${script#$ROOT_DIR/}"
  out_file="${base}.out"
  policy_file="${base}.policy"
  ops_file="${base}.ops"
  got_file="${base}.got"
  if [[ ! -f "$out_file" ]]; then
    echo "missing expected output file: $out_file"
    errors=$((errors + 1))
    continue
  fi
  allow_oom=0
  if [[ -f "$policy_file" ]] && grep -q "ALLOW_OOM" "$policy_file"; then
    allow_oom=1
  fi
  echo "[BENCH] $rel_script"
  start_ns=0
  end_ns=0
  if [[ "$BENCH_STATS" == "1" ]]; then
    start_ns="$(date +%s%N)"
  fi
  if ! "$WASMTIME_BIN" --dir . "$WASM" -- "$rel_script" > "$got_file" 2>&1; then
    if [[ $allow_oom -eq 1 ]] && grep -q "OutOfMemory" "$got_file"; then
      echo "BENCH expected OOM accepted: $rel_script"
      pass_count=$((pass_count + 1))
    else
      echo "BENCH execution failed unexpectedly: $rel_script"
      cat "$got_file"
      errors=$((errors + 1))
    fi
  elif ! diff -u "$out_file" "$got_file"; then
    echo "BENCH output mismatch: $rel_script"
    errors=$((errors + 1))
  else
    pass_count=$((pass_count + 1))
    if [[ "$BENCH_STATS" == "1" ]]; then
      end_ns="$(date +%s%N)"
      elapsed_ns=$((end_ns - start_ns))
      elapsed_ms=$((elapsed_ns / 1000000))
      echo "[BENCH-STATS] elapsed_ms=$elapsed_ms case=$rel_script"
      if [[ -f "$ops_file" ]]; then
        ops="$(cat "$ops_file")"
        if [[ "$elapsed_ns" -gt 0 ]]; then
          ops_per_sec=$((ops * 1000000000 / elapsed_ns))
          echo "[BENCH-STATS] ops=$ops ops_per_sec=$ops_per_sec case=$rel_script"
        fi
      fi
    fi
  fi
  rm -f "$got_file"
done < <(find "$BENCH_DIR" -maxdepth 1 -type f -name '*.gengo' | sort)

if [[ $errors -ne 0 ]]; then
  echo "Bench FAILED: ${pass_count} cases, ${errors} errors"
  exit 1
fi

echo "Bench OK: ${pass_count} cases"
