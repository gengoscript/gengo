#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WASM="$ROOT_DIR/gengo-test.wasm"
PASS_DIR="$ROOT_DIR/examples/spec"
FAIL_DIR="$ROOT_DIR/examples/spec/fail"
REPO_ROOT="$(cd "$ROOT_DIR/../../.." && pwd)"

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "wasmtime not found in PATH"
  exit 1
fi

if [[ ! -f "$WASM" ]]; then
  echo "missing wasm binary: $WASM"
  echo "run: make wasi"
  exit 1
fi

pass_count=0
fail_count=0
errors=0

cd "$REPO_ROOT"

while IFS= read -r script; do
  base="${script%.gengo}"
  rel_script="${script#$REPO_ROOT/}"
  rel_base="${base#$REPO_ROOT/}"
  out_file="${rel_base}.out"
  got_file="${rel_base}.got"
  echo "[PASS-CASE] $rel_script"
  if ! wasmtime --dir . "$WASM" -- "$rel_script" > "$got_file" 2>&1; then
    echo "PASS-CASE execution failed unexpectedly: $rel_script"
    cat "$got_file"
    errors=$((errors + 1))
  elif ! diff -u "$out_file" "$got_file"; then
    echo "PASS-CASE output mismatch: $rel_script"
    errors=$((errors + 1))
  else
    pass_count=$((pass_count + 1))
  fi
  rm -f "$got_file"
done < <(find "$PASS_DIR" -maxdepth 1 -type f -name '*.gengo' | sort)

while IFS= read -r script; do
  base="${script%.gengo}"
  rel_script="${script#$REPO_ROOT/}"
  rel_base="${base#$REPO_ROOT/}"
  err_file="${rel_base}.err"
  got_file="${rel_base}.got"
  needle="$(cat "$err_file")"
  echo "[FAIL-CASE] $rel_script"
  wasmtime --dir . "$WASM" -- "$rel_script" > "$got_file" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "Expected failure but script succeeded: $rel_script"
    cat "$got_file"
    errors=$((errors + 1))
  elif ! grep -q "$needle" "$got_file"; then
    echo "Expected error token '$needle' not found for $rel_script"
    cat "$got_file"
    errors=$((errors + 1))
  else
    fail_count=$((fail_count + 1))
  fi
  rm -f "$got_file"
done < <(find "$FAIL_DIR" -maxdepth 1 -type f -name '*.gengo' | sort)

if [[ $errors -ne 0 ]]; then
  echo "Conformance FAILED: ${pass_count} pass-cases, ${fail_count} fail-cases, ${errors} errors"
  exit 1
fi

echo "Conformance OK: ${pass_count} pass-cases, ${fail_count} fail-cases"
