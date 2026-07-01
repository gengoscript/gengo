#!/usr/bin/env bash
# Sample the native VM with Linux perf and write shareable text reports.
#
# This complements:
#   - tools/perf-baseline.sh  (deterministic VM counters)
#   - tools/time-bench.sh     (wall-clock timing)
# by adding:
#   - perf record/report      (CPU sampling with call stacks)
#
# Usage:
#   tools/profile-vm.sh
#   tools/profile-vm.sh run
#   tools/profile-vm.sh case tests/bench/006_call_overhead.gengo
#   tools/profile-vm.sh case tests/bench/006_call_overhead.gengo --freq 1999
#   tools/profile-vm.sh run --sudo
#
# Output:
#   build/profiles/<stamp>/<case>/
#     perf.data
#     report.symbol.txt
#     report.children.txt
#     report.callgraph.txt
#
# If perf requires root on this machine, pass --sudo. The script will chown the
# generated files back to the invoking user when possible.

set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

MODE="run"
USE_SUDO=0
FREQ=999
PRESET="1m"
OUT_ROOT="build/profiles"
BINARY="zig-out/bin/gengo-fast"

DEFAULT_CASES=(
    "tests/bench/007_dispatch_loop.gengo"
    "tests/bench/006_call_overhead.gengo"
    "tests/bench/003_fib_recursive.gengo"
    "tests/bench/001_compute_stress.gengo"
    "tests/bench/009_struct_field_access.gengo"
    "tests/bench/010_string_concat_heavy.gengo"
    "tests/bench/011_map_lookup_heavy.gengo"
)

usage() {
    cat <<'EOF'
usage:
  tools/profile-vm.sh [run] [--sudo] [--freq N] [--preset NAME]
  tools/profile-vm.sh case <bench.gengo> [--sudo] [--freq N] [--preset NAME]

examples:
  tools/profile-vm.sh
  tools/profile-vm.sh run --sudo
  tools/profile-vm.sh case tests/bench/006_call_overhead.gengo
EOF
}

die() {
    echo "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        run)
            MODE="run"
            shift
            ;;
        case)
            MODE="case"
            shift
            ;;
        --sudo)
            USE_SUDO=1
            shift
            ;;
        --freq)
            [[ $# -ge 2 ]] || die "--freq requires a value"
            FREQ="$2"
            shift 2
            ;;
        --preset)
            [[ $# -ge 2 ]] || die "--preset requires a value"
            PRESET="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

CASES=()
if [[ "$MODE" == "case" ]]; then
    [[ $# -ge 1 ]] || die "case mode requires a bench script path"
    CASES+=("$1")
    shift
else
    if [[ $# -gt 0 ]]; then
        die "unexpected arguments: $*"
    fi
    CASES=("${DEFAULT_CASES[@]}")
fi

require_cmd zig
require_cmd perf

echo "→ building native ReleaseFast CLI..." >&2
zig build cli-fast -Dpreset="$PRESET" 2>&1 | grep -v '^$' >&2

[[ -x "$BINARY" ]] || die "missing built binary: $BINARY"

timestamp="$(date +%Y%m%d-%H%M%S)"
run_dir="$OUT_ROOT/$timestamp"
mkdir -p "$run_dir"

perf_prefix=()
if [[ "$USE_SUDO" -eq 1 ]]; then
    perf_prefix=(sudo)
fi

owner_spec=""
if [[ "$USE_SUDO" -eq 1 ]]; then
    owner_spec="$(id -u):$(id -g)"
elif [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    owner_spec="${SUDO_UID}:${SUDO_GID}"
fi

record_case() {
    local script="$1"
    local base case_dir data_file symbol_file children_file graph_file

    [[ -f "$script" ]] || die "bench script not found: $script"
    base="$(basename "$script" .gengo)"
    case_dir="$run_dir/$base"
    data_file="$case_dir/perf.data"
    symbol_file="$case_dir/report.symbol.txt"
    children_file="$case_dir/report.children.txt"
    graph_file="$case_dir/report.callgraph.txt"

    mkdir -p "$case_dir"

    echo "→ profiling $script" >&2
    "${perf_prefix[@]}" perf record \
        --freq "$FREQ" \
        --call-graph fp \
        --output "$data_file" \
        -- \
        "./$BINARY" "$script"

    if [[ -n "$owner_spec" ]]; then
        sudo chown "$owner_spec" "$data_file"
    fi

    perf report --input "$data_file" --stdio --sort symbol > "$symbol_file"
    perf report --input "$data_file" --stdio --children > "$children_file"
    perf report --input "$data_file" --stdio --sort comm,dso,symbol > "$graph_file"

    echo "  data:     $data_file" >&2
    echo "  symbols:  $symbol_file" >&2
    echo "  children: $children_file" >&2
    echo "  graph:    $graph_file" >&2
}

for script in "${CASES[@]}"; do
    record_case "$script"
done

cat <<EOF
profiling complete
reports: $run_dir

share these files for analysis:
  - */report.symbol.txt
  - */report.children.txt
EOF
