GENGO_ROOT ?= ../..
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

firmware_gate: main.c $(GENGO_ROOT)/include/gengo-engine.h
	$(CC) $(CFLAGS) \
		-I$(GENGO_ROOT)/include \
		main.c -o $@ \
		-L$(GENGO_ROOT)/zig-out/lib -lgengo-engine \
		-Wl,-rpath,$(abspath $(GENGO_ROOT)/zig-out/lib)

.PHONY: clean
clean:
	rm -f firmware_gate
