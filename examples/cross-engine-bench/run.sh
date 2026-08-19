#!/usr/bin/env bash
# Cross-engine comparison: the same minimal, portable logic run in Gengo and
# a few peer scripting engines, on this machine, right now. No engine here
# uses language-specific features (no Gengo named types, no Lua metatables,
# etc.) — these are deliberately the lowest common denominator so the
# comparison is actually apples-to-apples.
#
# This is informational, not a claim of "fastest" or "slowest" in general —
# re-run it yourself; results depend on the machine, the engine version, and
# the build mode (this uses Gengo's native ReleaseSafe CLI, the same build
# mode the release pipeline ships).
#
# Usage: examples/cross-engine-bench/run.sh
set -uo pipefail
cd "$(dirname "$0")"

GENGO_BIN="${GENGO_BIN:-../../zig-out/bin/gengo}"

# 'cli' (Debug) and 'cli-release' (ReleaseSafe) both install to this same
# path, so a stale Debug binary from an earlier unrelated build can silently
# sit here and make Gengo look several times slower than it actually is.
# Always (re)build the release CLI right before timing, rather than trusting
# whatever happens to already be at GENGO_BIN.
if [ -z "${GENGO_BIN_PREBUILT:-}" ]; then
  echo "→ building native CLI (ReleaseSafe)..." >&2
  (cd ../.. && zig build -Dpreset=1m cli-release) >&2 || {
    echo "build failed" >&2
    exit 1
  }
fi

if [ ! -x "$GENGO_BIN" ]; then
  echo "gengo binary not found at $GENGO_BIN — build it first:" >&2
  echo "  zig build -Dpreset=1m cli-release" >&2
  exit 1
fi

declare -A ENGINES=(
  [gengo]="$GENGO_BIN {script}"
  [lua]="lua5.4 {script}"
  [python3]="python3 {script}"
  [node]="node {script}"
  [starlark]="starlark {script}"
  [yaegi]="yaegi run {script}"
  [anko]="anko {script}"
)

declare -A EXT=(
  [gengo]=gengo
  [lua]=lua
  [python3]=py
  [node]=js
  [starlark]=star
  [yaegi]=go
  [anko]=ank
)

# The first word of each engine's command template, used to check whether
# the engine binary is even installed before trying to run it.
declare -A BINARY=(
  [gengo]="$GENGO_BIN"
  [lua]=lua5.4
  [python3]=python3
  [node]=node
  [starlark]=starlark
  [yaegi]=yaegi
  [anko]=anko
)

ENGINE_ORDER=(gengo lua python3 node starlark yaegi anko)

run_timed() {
  local cmd="$1"
  local start_ns end_ns
  start_ns=$(date +%s%N)
  eval "$cmd" > /tmp/cross-engine-out.txt 2>&1
  local rc=$?
  end_ns=$(date +%s%N)
  if [ $rc -ne 0 ]; then
    echo "ERROR"
    return
  fi
  awk -v ns="$((end_ns - start_ns))" 'BEGIN { printf "%.3fs", ns / 1000000000 }'
}

run_case() {
  local case_name="$1"
  echo "=== ${case_name} ==="
  printf "%-10s %10s   %s\n" "engine" "time" "output"
  for engine in "${ENGINE_ORDER[@]}"; do
    local tmpl="${ENGINES[$engine]}"
    local script="${case_name}.${EXT[$engine]}"
    local bin="${BINARY[$engine]}"

    if ! command -v "$bin" >/dev/null 2>&1; then
      printf "%-10s %10s   %s\n" "$engine" "-" "(${bin} not installed)"
      continue
    fi
    if [ ! -f "$script" ]; then
      if [ "$engine" = "starlark" ] && [ "$case_name" = "fib_recursive" ]; then
        printf "%-10s %10s   %s\n" "$engine" "-" "(unsupported: Starlark forbids recursive functions)"
      else
        printf "%-10s %10s   %s\n" "$engine" "-" "(missing $script)"
      fi
      continue
    fi
    local cmd="${tmpl/\{script\}/$script}"
    local t
    t=$(run_timed "$cmd")
    local out
    out=$(tail -c 80 /tmp/cross-engine-out.txt | tr -d '\n')
    printf "%-10s %10s   %s\n" "$engine" "$t" "$out"
  done
  echo
}

echo "Cross-engine comparison — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host: $(uname -s) $(uname -m)"
echo

run_case fib_recursive
run_case loop_sum
