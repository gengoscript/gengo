GENGO_ROOT ?= ../..
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

BUNDLE_SRCS = lib/scoring/grade.gengo lib/scoring/calc.gengo

quiz_grader: main.c $(GENGO_ROOT)/sdk/c/include/gengo-engine.h
	$(CC) $(CFLAGS) \
		-I$(GENGO_ROOT)/sdk/c/include \
		main.c -o $@ \
		-L$(GENGO_ROOT)/zig-out/lib -lgengo-engine \
		-Wl,-rpath,$(abspath $(GENGO_ROOT)/zig-out/lib)

scoring.zip: $(BUNDLE_SRCS)
	cd lib/scoring && zip ../../scoring.zip grade.gengo calc.gengo

# Development: load modules directly from the source directory.
run: quiz_grader
	./quiz_grader

# Production: load modules from a prebuilt zip bundle.
run-zip: quiz_grader scoring.zip
	./quiz_grader scoring.zip

.PHONY: clean run run-zip
clean:
	rm -f quiz_grader scoring.zip
