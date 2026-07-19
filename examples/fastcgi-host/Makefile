GENGO_ROOT ?= ../..
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror

fastcgi_host: main.c $(GENGO_ROOT)/include/gengo-engine.h $(GENGO_ROOT)/include/gengo-wire.h
	$(CC) $(CFLAGS) -I$(GENGO_ROOT)/include main.c -o $@ \
		-L$(GENGO_ROOT)/zig-out/lib -lgengo-engine \
		-Wl,-rpath,$(abspath $(GENGO_ROOT)/zig-out/lib)

test: fastcgi_host
	python3 test_fastcgi.py
	python3 test_server.py

.PHONY: clean test
clean:
	rm -f fastcgi_host
