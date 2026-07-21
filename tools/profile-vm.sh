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
#   tools/profile-vm.sh net-case script.gengo --modules path --cap net [--duration 30]
#
# The 'net-case' mode profiles a long-running script (e.g. an MQTT listener)
# for a fixed duration (default 30 s) then kills it and generates reports.
# Additional gengo flags (--cap, --modules) are passed through after the script.
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
NET_DURATION=30

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
  tools/profile-vm.sh net-case <script.gengo> [gengo-flags...] [--duration N] [--sudo] [--freq N]

examples:
  tools/profile-vm.sh
  tools/profile-vm.sh run --sudo
  tools/profile-vm.sh case tests/bench/006_call_overhead.gengo
  tools/profile-vm.sh net-case ../gengo-mqtt/listener-all.gengo --cap net --modules ../gengo-mqtt/mqtt
  tools/profile-vm.sh net-case ../gengo-mqtt/listener-all.gengo --cap net --modules ../gengo-mqtt/mqtt --duration 60
  tools/profile-vm.sh net-case --duration 60 ../gengo-mqtt/listener-all.gengo --cap net --modules ../gengo-mqtt/mqtt
  # high-traffic wildcard subscription needs more GC heap:
  tools/profile-vm.sh net-case ../gengo-mqtt/listener-all.gengo --cap net --modules ../gengo-mqtt/mqtt --heap 4m
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
        net-case)
            MODE="net-case"
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
        --duration)
            [[ $# -ge 2 ]] || die "--duration requires a value"
            NET_DURATION="$2"
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
NET_SCRIPT=""
NET_EXTRA_ARGS=()
if [[ "$MODE" == "case" ]]; then
    [[ $# -ge 1 ]] || die "case mode requires a bench script path"
    CASES+=("$1")
    shift
elif [[ "$MODE" == "net-case" ]]; then
    [[ $# -ge 1 ]] || die "net-case mode requires a script path"
    NET_SCRIPT="$1"
    shift
    # Secondary parse: strip profile-vm.sh flags from the remaining args;
    # everything else is forwarded to gengo as-is.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration)
                [[ $# -ge 2 ]] || die "--duration requires a value"
                NET_DURATION="$2"
                shift 2
                ;;
            --freq)
                [[ $# -ge 2 ]] || die "--freq requires a value"
                FREQ="$2"
                shift 2
                ;;
            --sudo)
                USE_SUDO=1
                shift
                ;;
            *)
                NET_EXTRA_ARGS+=("$1")
                shift
                ;;
        esac
    done
else
    if [[ $# -gt 0 ]]; then
        die "unexpected arguments: $*"
    fi
    CASES=("${DEFAULT_CASES[@]}")
fi

require_cmd zig
require_cmd perf

echo "→ building native ReleaseFast CLI..." >&2
# grep exits 1 on a fully-cached build (zero lines of output, so nothing to
# filter) which would otherwise kill the script under pipefail before
# profiling starts; `|| true` keeps that case from aborting the run.
zig build cli-fast -Dpreset="$PRESET" 2>&1 | { grep -v '^$' || true; } >&2

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

record_net_case() {
    local script="$1"
    shift
    local extra_args=("$@")
    local base case_dir data_file symbol_file children_file graph_file

    [[ -f "$script" ]] || die "script not found: $script"
    base="$(basename "$script" .gengo)"
    case_dir="$run_dir/$base"
    data_file="$case_dir/perf.data"
    symbol_file="$case_dir/report.symbol.txt"
    children_file="$case_dir/report.children.txt"
    graph_file="$case_dir/report.callgraph.txt"

    mkdir -p "$case_dir"

    echo "→ profiling $script for ${NET_DURATION}s (extra: ${extra_args[*]+"${extra_args[*]}"})" >&2

    # Launch the process under perf; let perf manage timing via --sleep.
    # perf record exits once the process exits.  We kill the target after
    # NET_DURATION seconds by running it inside a timeout wrapper.
    "${perf_prefix[@]}" perf record \
        --freq "$FREQ" \
        --call-graph fp \
        --output "$data_file" \
        -- \
        timeout --signal=SIGINT "$NET_DURATION" \
        "./$BINARY" "$script" "${extra_args[@]}" || true

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

if [[ "$MODE" == "net-case" ]]; then
    record_net_case "$NET_SCRIPT" "${NET_EXTRA_ARGS[@]+"${NET_EXTRA_ARGS[@]}"}"
else
    for script in "${CASES[@]}"; do
        record_case "$script"
    done
fi

cat <<EOF
profiling complete
reports: $run_dir

share these files for analysis:
  - */report.symbol.txt
  - */report.children.txt
EOF
