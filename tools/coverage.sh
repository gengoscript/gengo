#!/usr/bin/env bash
# Native line-coverage report for the Zig test suite, via kcov.
#
# Zig's default self-hosted x86_64 backend emits DWARF5 that kcov cannot
# resolve to project source files at all (every project file reports 0
# lines, even though the debug_line table clearly has them — confirmed by
# reading it directly with objdump). Forcing the LLVM backend (-fllvm)
# produces DWARF that kcov parses correctly and gives real per-line
# coverage; the packaged Debian kcov works fine once given an LLVM-built
# binary, no need for a newer kcov. Hence build.zig's -Dcoverage=true,
# which only flips test binaries to use_llvm=true (slower build, same
# semantics) and installs them to zig-out/coverage-bin/.
#
# This covers the 8 native Zig test binaries (lexer/build/engine-api/main/
# heap/compiler/embedding-frag/chaos-spec), which is most of what matters:
# compiler_test.zig and chaos_spec_test.zig instantiate a real Runtime and
# execute bytecode in-process, so they exercise the compiler and VM, not
# just their own harness code. Not covered: the WASM-executed test runners
# (vm-safety-runner, vm-value-runner, embedding, engine-runner, fuzz-runner)
# — those run under wasmtime, a completely different instrumentation
# problem, out of scope here.
#
# Usage:
#   tools/coverage.sh              # build, instrument, merge, print summary
#   tools/coverage.sh open         # same, then open the merged HTML report

set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if ! command -v kcov >/dev/null 2>&1; then
    echo "error: kcov not found. Install it (e.g. 'apt install kcov') and retry." >&2
    exit 1
fi

rm -rf zig-out/coverage-bin zig-out/coverage
zig build coverage-bin -Dcoverage=true

mkdir -p zig-out/coverage
names=()
for bin in zig-out/coverage-bin/*; do
    name="$(basename "$bin")"
    names+=("$name")
    echo "== $name =="
    kcov \
        --include-pattern="$ROOT/src,$ROOT/tools,$ROOT/build_test.zig" \
        "zig-out/coverage/$name" \
        "$bin"
done

merge_dirs=()
for name in "${names[@]}"; do
    merge_dirs+=("zig-out/coverage/$name")
done
kcov --merge zig-out/coverage/merged "${merge_dirs[@]}"

echo
python3 -c "
import json, glob
f = glob.glob('zig-out/coverage/merged/*/coverage.json')[0]
d = json.load(open(f))
print(f\"Overall: {d['percent_covered']}% ({d['covered_lines']}/{d['total_lines']} lines, {len(d['files'])} files)\")
for x in sorted(d['files'], key=lambda x: float(x['percent_covered'])):
    print(f\"  {x['percent_covered']:>6}%  {x['covered_lines']:>5}/{x['total_lines']:<5}  {x['file'].replace('$ROOT/', '')}\")
"

echo
echo "Full HTML report: $ROOT/zig-out/coverage/merged/index.html"

if [[ "${1:-}" == "open" ]]; then
    xdg-open "$report" 2>/dev/null || echo "(no xdg-open available; open the path above manually)"
fi
