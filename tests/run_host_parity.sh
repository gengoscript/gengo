#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WASM="$ROOT_DIR/gengo-test.wasm"
PARITY_DIR="$ROOT_DIR/examples/parity"
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

errors=0
count=0
cd "$ROOT_DIR"

while IFS= read -r script; do
  rel_script="${script#$ROOT_DIR/}"
  got_emb="${script%.gengo}.embedded.got"
  got_host="${script%.gengo}.host.got"
  echo "[PARITY] $rel_script"
  if ! "$WASMTIME_BIN" --dir . "$WASM" -- --backend embedded "$rel_script" > "$got_emb" 2>&1; then
    echo "embedded backend failed: $rel_script"
    cat "$got_emb"
    errors=$((errors + 1))
    rm -f "$got_emb" "$got_host"
    continue
  fi
  if ! "$WASMTIME_BIN" --dir . "$WASM" -- --backend host "$rel_script" > "$got_host" 2>&1; then
    echo "host backend failed: $rel_script"
    cat "$got_host"
    errors=$((errors + 1))
    rm -f "$got_emb" "$got_host"
    continue
  fi
  if ! diff -u "$got_emb" "$got_host"; then
    echo "backend output mismatch: $rel_script"
    errors=$((errors + 1))
  else
    count=$((count + 1))
  fi
  rm -f "$got_emb" "$got_host"
done < <(find "$PARITY_DIR" -maxdepth 1 -type f -name '*.gengo' | sort)

if [[ $errors -ne 0 ]]; then
  echo "Host parity FAILED: ${count} pass, ${errors} errors"
  exit 1
fi

echo "Host parity OK: ${count} cases"
