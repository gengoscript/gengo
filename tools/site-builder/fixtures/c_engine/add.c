#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "gengo-engine.h"

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
        "pub func add(a int, b int) int { return a + b }\n";
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

    gengo_value_wire_t args[2] = {
        { .tag = GENGO_WIRE_NUMBER, .flags = GENGO_WIRE_FLAG_INTEGER, .payload = 40 },
        { .tag = GENGO_WIRE_NUMBER, .flags = GENGO_WIRE_FLAG_INTEGER, .payload = 2 },
    };
    gengo_value_wire_t out = {0};
    if (engine_call(engine, "add", 3, args, 2, &out) != 0) {
        print_error(engine);
        engine_destroy(engine);
        return 1;
    }

    if (out.tag != GENGO_WIRE_NUMBER ||
        out.flags != GENGO_WIRE_FLAG_INTEGER || out.payload != 42) {
        fprintf(stderr, "unexpected result wire\n");
        engine_destroy(engine);
        return 1;
    }

    puts("42");
    engine_destroy(engine);
    return 0;
}
