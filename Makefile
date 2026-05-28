ZIG ?= zig
PRESET ?= dev

.PHONY: wasi
wasi:
	$(ZIG) build -Dpreset=$(PRESET) wasi

.PHONY: wasi-release
wasi-release:
	$(ZIG) build -Dpreset=$(PRESET) wasi-release

.PHONY: config-dev
config-dev:
	@echo "Use: zig build -Dpreset=dev <step>"

.PHONY: config-tiny
config-tiny:
	@echo "Use: zig build -Dpreset=tiny <step>"

.PHONY: config-stress
config-stress:
	@echo "Use: zig build -Dpreset=stress <step>"

.PHONY: wasi-tiny
wasi-tiny:
	$(ZIG) build -Dpreset=tiny wasi

.PHONY: wasi-stress
wasi-stress:
	$(ZIG) build -Dpreset=stress wasi

.PHONY: wasi-release-tiny
wasi-release-tiny:
	$(ZIG) build -Dpreset=tiny wasi-release

.PHONY: wasi-release-stress
wasi-release-stress:
	$(ZIG) build -Dpreset=stress wasi-release

.PHONY: unit
unit:
	$(ZIG) build -Dpreset=dev unit

.PHONY: conformance
conformance:
	$(ZIG) build -Dpreset=$(PRESET) test

.PHONY: test
test:
	$(ZIG) build -Dpreset=dev test

.PHONY: bench
bench:
	$(ZIG) build -Dpreset=dev bench

.PHONY: bench-release
bench-release:
	$(ZIG) build -Dpreset=dev bench-release

.PHONY: bench-tiny
bench-tiny:
	$(ZIG) build -Dpreset=tiny bench

.PHONY: bench-stress
bench-stress:
	GENGO_BENCH_INCLUDE_STRESS=1 $(ZIG) build -Dpreset=stress bench

.PHONY: bench-release-tiny
bench-release-tiny:
	$(ZIG) build -Dpreset=tiny bench-release

.PHONY: bench-release-stress
bench-release-stress:
	GENGO_BENCH_INCLUDE_STRESS=1 $(ZIG) build -Dpreset=stress bench-release

.PHONY: bench-recursion-stress
bench-recursion-stress:
	GENGO_BENCH_INCLUDE_STRESS=1 GENGO_BENCH_FILTER='005_fib_recursive_35_stress.gengo' $(ZIG) build -Dpreset=stress bench-release

.PHONY: parity
parity:
	$(ZIG) build -Dpreset=$(PRESET) parity
