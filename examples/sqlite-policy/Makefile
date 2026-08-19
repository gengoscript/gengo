GENGO_ROOT ?= ../..
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

sqlite_policy: main.c $(GENGO_ROOT)/sdk/c/include/gengo-engine.h
	$(CC) $(CFLAGS) \
		-I$(GENGO_ROOT)/sdk/c/include \
		main.c -o $@ \
		-L$(GENGO_ROOT)/zig-out/lib -lgengo-engine -lsqlite3 \
		-Wl,-rpath,$(abspath $(GENGO_ROOT)/zig-out/lib)

.PHONY: clean
clean:
	rm -f sqlite_policy
