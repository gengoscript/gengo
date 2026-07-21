#!/usr/bin/env bash
# Wall-clock timing benchmark for gengo using hyperfine.
#
# Unlike perf-baseline.sh (which counts opcodes deterministically), this
# captures real CPU time and is the right tool for measuring changes that
# affect memory bandwidth without changing opcode count — e.g. shrinking
# the Value struct, changing stack layout, or altering hot-path data sizes.
#
# Usage:
#   tools/time-bench.sh              # build ReleaseFast binary, run, print table
#   tools/time-bench.sh save         # same, then save medians to time_baseline.txt
#   tools/time-bench.sh compare      # same, then diff against saved baseline
#
# Results are printed as a markdown table. The saved baseline stores one
# "name median_ms" line per benchmark so compare can compute % changes.

set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

MODE="${1:-run}"
if [[ "$MODE" != "run" && "$MODE" != "save" && "$MODE" != "compare" ]]; then
    echo "usage: $0 [run|save|compare]" >&2
    exit 1
fi

BASELINE="tests/bench/time_baseline.txt"
BINARY="zig-out/bin/gengo-fast"
WARMUP=3
RUNS=10

# Benchmarks that are sensitive to CPU/memory throughput (computation-heavy,
# minimal I/O). These are the scripts most likely to show Value-size wins.
BENCH_SCRIPTS=(
    "tests/bench/005_fib_recursive_35_stress.gengo"
    "tests/bench/007_dispatch_loop.gengo"
    "tests/bench/006_call_overhead.gengo"
    "tests/bench/003_fib_recursive.gengo"
    "tests/bench/001_compute_stress.gengo"
)

echo "→ building ReleaseFast binary..." >&2
# grep exits 1 on a fully-cached build (zero lines of output), which would
# otherwise abort the script under pipefail; see tools/profile-vm.sh for the
# same fix.
zig build cli-fast -Dpreset=1m 2>&1 | { grep -v "^$" || true; } >&2

echo >&2

# Run hyperfine for each script and collect median ms
declare -A medians

printf "%-42s  %9s  %9s\n" "benchmark" "median" "stddev"
printf "%-42s  %9s  %9s\n" "---------" "------" "------"

for script in "${BENCH_SCRIPTS[@]}"; do
    name="$(basename "$script" .gengo)"
    # hyperfine --export-json prints median in seconds; we extract it with python3
    tmpjson="$(mktemp /tmp/gengo-timebench-XXXXXX.json)"
    trap 'rm -f "$tmpjson"' EXIT

    hyperfine \
        --warmup "$WARMUP" \
        --runs "$RUNS" \
        --export-json "$tmpjson" \
        --style none \
        "$BINARY $script" \
        2>/dev/null

    read -r median stddev < <(LC_ALL=C python3 - "$tmpjson" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
r = d["results"][0]
print(f"{r['median']*1000:.2f} {r['stddev']*1000:.2f}")
PYEOF
)
    medians["$name"]="$median"
    printf "%-42s  %8.2f ms  %8.2f ms\n" "$name" "$median" "$stddev"
done

echo >&2

if [[ "$MODE" == "save" ]]; then
    for name in "${!medians[@]}"; do
        echo "$name ${medians[$name]}"
    done | sort > "$BASELINE"
    echo "saved: $BASELINE"
    exit 0
fi

if [[ "$MODE" == "compare" ]]; then
    if [[ ! -f "$BASELINE" ]]; then
        echo "no baseline — run '$0 save' first" >&2
        exit 1
    fi
    echo "comparison vs baseline:"
    printf "%-42s  %9s  %9s  %9s\n" "benchmark" "before" "after" "change"
    printf "%-42s  %9s  %9s  %9s\n" "---------" "------" "-----" "------"
    any_change=0
    while read -r name baseline_ms; do
        current_ms="${medians[$name]:-}"
        if [[ -z "$current_ms" ]]; then
            printf "%-42s  %9s  %9s  %9s\n" "$name" "${baseline_ms} ms" "N/A" "?"
            continue
        fi
        pct=$(LC_ALL=C python3 -c "b=$baseline_ms; c=$current_ms; print(f'{(c-b)/b*100:+.1f}%')")
        printf "%-42s  %8.2f ms  %8.2f ms  %9s\n" "$name" "$baseline_ms" "$current_ms" "$pct"
        # flag if >1% change
        significant=$(LC_ALL=C python3 -c "b=$baseline_ms; c=$current_ms; print('yes' if abs(c-b)/b > 0.01 else 'no')")
        if [[ "$significant" == "yes" ]]; then any_change=1; fi
    done < "$BASELINE"
    if [[ $any_change -eq 0 ]]; then
        echo "(all within 1% — no significant change)"
    fi
fi
