GENGO_ROOT ?= ../..
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -fPIC
# Override if mosquitto_broker.h / mosquitto_plugin.h live elsewhere
# (Debian/Ubuntu: apt install mosquitto-dev libmosquitto-dev)
MOSQ_INC ?=

gengo_acl.so: plugin.c $(GENGO_ROOT)/sdk/c/include/gengo-engine.h
	$(CC) $(CFLAGS) -shared \
		-I$(GENGO_ROOT)/sdk/c/include $(if $(MOSQ_INC),-I$(MOSQ_INC),) \
		plugin.c -o $@ \
		-L$(GENGO_ROOT)/zig-out/lib -lgengo-engine \
		-Wl,-rpath,$(abspath $(GENGO_ROOT)/zig-out/lib)

.PHONY: clean
clean:
	rm -f gengo_acl.so
