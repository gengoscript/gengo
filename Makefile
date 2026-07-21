ZIG ?= zig
PRESET ?= dev
WASMTIME ?= wasmtime

.PHONY: wasi
wasi:
	$(ZIG) build -Dpreset=$(PRESET) wasi

.PHONY: wasi-release
wasi-release:
	$(ZIG) build -Dpreset=$(PRESET) wasi-release

.PHONY: config-dev
config-dev:
	@echo "Use: zig build -Dpreset=dev <step>"

.PHONY: config-256k
config-256k:
	@echo "Use: zig build -Dpreset=256k <step>"

.PHONY: config-stress
config-stress:
	@echo "Use: zig build -Dpreset=stress <step>"

.PHONY: wasi-256k
wasi-256k:
	$(ZIG) build -Dpreset=256k wasi

.PHONY: wasi-stress
wasi-stress:
	$(ZIG) build -Dpreset=stress wasi

.PHONY: wasi-release-256k
wasi-release-256k:
	$(ZIG) build -Dpreset=256k wasi-release

.PHONY: wasi-release-stress
wasi-release-stress:
	$(ZIG) build -Dpreset=stress wasi-release

.PHONY: unit
unit:
	$(ZIG) build -Dpreset=dev -Dwasmtime=$(WASMTIME) unit

.PHONY: conformance
conformance:
	$(ZIG) build -Dpreset=$(PRESET) -Dwasmtime=$(WASMTIME) test

.PHONY: test
test:
	$(ZIG) build -Dpreset=dev -Dwasmtime=$(WASMTIME) test

.PHONY: bench
bench:
	$(ZIG) build -Dpreset=dev -Dwasmtime=$(WASMTIME) bench

.PHONY: bench-release
bench-release:
	$(ZIG) build -Dpreset=dev -Dwasmtime=$(WASMTIME) bench-release

.PHONY: bench-256k
bench-256k:
	$(ZIG) build -Dpreset=256k -Dwasmtime=$(WASMTIME) bench

.PHONY: bench-stress
bench-stress:
	GENGO_BENCH_INCLUDE_STRESS=1 $(ZIG) build -Dpreset=stress -Dwasmtime=$(WASMTIME) bench

.PHONY: bench-release-256k
bench-release-256k:
	$(ZIG) build -Dpreset=256k -Dwasmtime=$(WASMTIME) bench-release

.PHONY: bench-release-stress
bench-release-stress:
	GENGO_BENCH_INCLUDE_STRESS=1 $(ZIG) build -Dpreset=stress -Dwasmtime=$(WASMTIME) bench-release

.PHONY: bench-recursion-stress
bench-recursion-stress:
	GENGO_BENCH_INCLUDE_STRESS=1 GENGO_BENCH_FILTER='005_fib_recursive_35_stress.gengo' $(ZIG) build -Dpreset=stress -Dwasmtime=$(WASMTIME) bench-release
