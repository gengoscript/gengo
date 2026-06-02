#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

WASM_SRC="build/gengo-runtime.wasm"
WASM_DST="playground/gengo-runtime.wasm"

if [ ! -f "$WASM_SRC" ]; then
  echo "error: $WASM_SRC not found — run 'zig build wasi' first" >&2
  exit 1
fi

cp "$WASM_SRC" "$WASM_DST"

V=$(sha256sum "$WASM_DST" | cut -c1-8)

perl -i -pe "s/\?v=[0-9a-f]{8}/?v=$V/g" \
  playground/index.html \
  playground/playground.js

echo "deployed $WASM_DST  (cache version: $V)"
