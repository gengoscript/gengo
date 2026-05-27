#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WASM="$ROOT_DIR/gengo-test.wasm"
PARITY_DIR="$ROOT_DIR/examples/parity"
REPO_ROOT="$(cd "$ROOT_DIR/../../.." && pwd)"

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "wasmtime not found in PATH"
  exit 1
fi

if [[ ! -f "$WASM" ]]; then
  echo "missing wasm binary: $WASM"
  echo "run: make -C userland/cmd/gengo wasi"
  exit 1
fi

errors=0
count=0
cd "$REPO_ROOT"

while IFS= read -r script; do
  rel_script="${script#$REPO_ROOT/}"
  got_emb="${rel_script%.gengo}.embedded.got"
  got_host="${rel_script%.gengo}.host.got"
  echo "[PARITY] $rel_script"
  if ! wasmtime --dir . "$WASM" -- --backend embedded "$rel_script" > "$got_emb" 2>&1; then
    echo "embedded backend failed: $rel_script"
    cat "$got_emb"
    errors=$((errors + 1))
    rm -f "$got_emb" "$got_host"
    continue
  fi
  if ! wasmtime --dir . "$WASM" -- --backend host "$rel_script" > "$got_host" 2>&1; then
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
