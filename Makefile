GENGO_DIR := $(abspath .)
SHIM      := $(GENGO_DIR)/libsc_wasi.zig
ZIG ?= zig
ZIG_GLOBAL_CACHE_DIR ?= /tmp/zig-cache
ZIG_LOCAL_CACHE_DIR ?= /tmp/zig-local-cache
# WASI build — runs under wasmtime for local testing.
# Usage:  make wasi                      → produces gengo-test.wasm
#         wasmtime --dir / gengo-test.wasm -- script.tengo
.PHONY: wasi
wasi:
	ZIG_GLOBAL_CACHE_DIR=$(ZIG_GLOBAL_CACHE_DIR) \
	ZIG_LOCAL_CACHE_DIR=$(ZIG_LOCAL_CACHE_DIR) \
	$(ZIG) build-exe \
		-target wasm32-wasi \
		-fno-entry -rdynamic \
		-O Debug \
		--dep libsc \
		-Mroot="$(GENGO_DIR)/main.zig" \
		-Mlibsc="$(SHIM)" \
		-femit-bin="$(GENGO_DIR)/gengo-test.wasm"
	@echo "Built $(GENGO_DIR)/gengo-test.wasm"
	@echo "Run with: wasmtime --dir / $(GENGO_DIR)/gengo-test.wasm -- <script>"

.PHONY: wasi-release
wasi-release:
	ZIG_GLOBAL_CACHE_DIR=$(ZIG_GLOBAL_CACHE_DIR) \
	ZIG_LOCAL_CACHE_DIR=$(ZIG_LOCAL_CACHE_DIR) \
	$(ZIG) build-exe \
		-target wasm32-wasi \
		-fno-entry -rdynamic \
		-O ReleaseFast \
		--dep libsc \
		-Mroot="$(GENGO_DIR)/main.zig" \
		-Mlibsc="$(SHIM)" \
		-femit-bin="$(GENGO_DIR)/gengo-test.wasm"
	@echo "Built $(GENGO_DIR)/gengo-test.wasm (ReleaseFast)"
	@echo "Run with: wasmtime --dir / $(GENGO_DIR)/gengo-test.wasm -- <script>"

.PHONY: config-dev
config-dev:
	@cp "$(GENGO_DIR)/runtime/config_dev.zig" "$(GENGO_DIR)/runtime/config.zig"
	@echo "Applied gengo config preset: dev"

.PHONY: config-tiny
config-tiny:
	@cp "$(GENGO_DIR)/runtime/config_tiny.zig" "$(GENGO_DIR)/runtime/config.zig"
	@echo "Applied gengo config preset: tiny"

.PHONY: config-stress
config-stress:
	@cp "$(GENGO_DIR)/runtime/config_stress.zig" "$(GENGO_DIR)/runtime/config.zig"
	@echo "Applied gengo config preset: stress"

.PHONY: wasi-tiny
wasi-tiny: config-tiny wasi

.PHONY: wasi-stress
wasi-stress: config-stress wasi

.PHONY: wasi-release-tiny
wasi-release-tiny: config-tiny wasi-release

.PHONY: wasi-release-stress
wasi-release-stress: config-stress wasi-release

.PHONY: conformance
conformance: wasi
	@$(GENGO_DIR)/tests/run_conformance.sh

.PHONY: test
test: config-dev conformance

.PHONY: bench
bench: config-dev wasi
	@$(GENGO_DIR)/tests/run_bench.sh

.PHONY: bench-release
bench-release: config-dev wasi-release
	@$(GENGO_DIR)/tests/run_bench.sh

.PHONY: bench-tiny
bench-tiny: wasi-tiny
	@$(GENGO_DIR)/tests/run_bench.sh

.PHONY: bench-stress
bench-stress: wasi-stress
	@GENGO_BENCH_INCLUDE_STRESS=1 $(GENGO_DIR)/tests/run_bench.sh

.PHONY: bench-release-tiny
bench-release-tiny: wasi-release-tiny
	@$(GENGO_DIR)/tests/run_bench.sh

.PHONY: bench-release-stress
bench-release-stress: wasi-release-stress
	@GENGO_BENCH_INCLUDE_STRESS=1 $(GENGO_DIR)/tests/run_bench.sh

.PHONY: bench-recursion-stress
bench-recursion-stress: wasi-release-stress
	@GENGO_BENCH_INCLUDE_STRESS=1 GENGO_BENCH_FILTER='005_fib_recursive_35_stress.gengo' $(GENGO_DIR)/tests/run_bench.sh

.PHONY: parity
parity: wasi
	@$(GENGO_DIR)/tests/run_host_parity.sh
