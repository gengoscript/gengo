#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "gengo-engine.h"
#include "gengo-wire.h"

static void print_error(int32_t engine) {
    char message[256];
    int32_t count = engine_last_error(engine, message, (int32_t)sizeof message);
    if (count < 0) count = 0;
    fprintf(stderr, "engine error at %d:%d: %.*s\n",
            engine_last_error_line(engine), engine_last_error_col(engine),
            (int)count, message);
}

int main(void) {
    static const char source[] =
        "pub func sum(xs []int) int {\n"
        "    total := 0\n"
        "    for x in xs { total += x }\n"
        "    return total\n"
        "}\n"
        "pub func make_map() [string]int {\n"
        "    return {\"a\": 1, \"b\": 2}\n"
        "}\n";
    int32_t engine = engine_init();
    if (engine <= 0) {
        fprintf(stderr, "engine_init failed\n");
        return 1;
    }

    if (engine_run(engine, source, (int32_t)strlen(source)) != 0) {
        print_error(engine);
        engine_destroy(engine);
        return 1;
    }

    /* Build an array argument with gengo_wire_array(): the element storage
     * (elems) is caller-owned and must outlive the engine_call. */
    gengo_value_wire_t elems[4] = {
        gengo_wire_int(1), gengo_wire_int(2), gengo_wire_int(3), gengo_wire_int(4),
    };
    gengo_value_wire_t args[1] = { gengo_wire_array(elems, 4) };
    gengo_value_wire_t sum_out = {0};
    if (engine_call(engine, "sum", 3, args, 1, &sum_out) != 0) {
        print_error(engine);
        engine_destroy(engine);
        return 1;
    }
    if (gengo_wire_as_int(&sum_out) != 10) {
        fprintf(stderr, "unexpected sum: %lld\n", (long long)gengo_wire_as_int(&sum_out));
        engine_destroy(engine);
        return 1;
    }

    /* Read back a map result with gengo_wire_map_len()/_key_at()/_value_at():
     * the returned wire's referenced storage is engine scratch, valid only
     * until the next engine_run/engine_call/engine_reset/engine_destroy. */
    gengo_value_wire_t map_out = {0};
    if (engine_call(engine, "make_map", 8, NULL, 0, &map_out) != 0) {
        print_error(engine);
        engine_destroy(engine);
        return 1;
    }
    int64_t total = 0;
    for (uint32_t i = 0; i < gengo_wire_map_len(&map_out); i++) {
        total += gengo_wire_as_int(gengo_wire_map_value_at(&map_out, i));
    }
    if (gengo_wire_map_len(&map_out) != 2 || total != 3) {
        fprintf(stderr, "unexpected map result\n");
        engine_destroy(engine);
        return 1;
    }

    puts("ok");
    engine_destroy(engine);
    return 0;
}
