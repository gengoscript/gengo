#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gengo-engine.h>
#include <gengo-wire.h>

typedef struct {
    const char *name;
    int correct;
    int total;
} student_t;

static void log_error(int32_t engine, const char *what)
{
    char buf[512];
    int32_t n = engine_last_error(engine, buf, (int32_t)sizeof buf);
    if (n < 0) n = 0;
    fprintf(stderr, "%s (line %d, col %d): %.*s\n",
            what,
            engine_last_error_line(engine),
            engine_last_error_col(engine),
            (int)n, buf);
}

static char *read_file(const char *path, size_t *out_len)
{
    FILE *f;
    long size;
    size_t nread;
    char *buf;

    f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    size = ftell(f);
    if (size < 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }

    buf = (char *)malloc((size_t)size + 1u);
    if (!buf) { fclose(f); return NULL; }

    nread = fread(buf, 1, (size_t)size, f);
    fclose(f);
    buf[nread] = '\0';
    if (out_len) *out_len = nread;
    return buf;
}

int main(int argc, char **argv)
{
    const char *zip_path   = (argc > 1) ? argv[1] : NULL;
    const char *script_path = "quiz.gengo";

    const student_t students[] = {
        { "Alice",  92, 100 },
        { "Bob",    76, 100 },
        { "Carol",  55,  80 },
        { "Dave",   88,  90 },
        { "Eve",     0,  10 },
        { "Frank",  10,  10 },
    };

    gengo_instance_config_t cfg;
    int32_t engine;
    int32_t bundle_rc;
    char *script_src;
    size_t script_len = 0;
    size_t i;

    cfg.heap_size_bytes = 512u * 1024u;
    cfg.max_objects     = 2048u;
    cfg.max_stack       = 512u;
    cfg.max_frames      = 64u;
    cfg.max_defers      = 128u;
    cfg.max_ops         = 200000;
    cfg.allow_io        = 0;

    engine = engine_init_with_config(&cfg);
    if (engine <= 0) {
        fprintf(stderr, "engine_init_with_config failed (%d)\n", (int)engine);
        return 1;
    }

    /* Load the scoring bundle — zip (production) or directory (development). */
    if (zip_path) {
        size_t zip_len = 0;
        char *zip_data = read_file(zip_path, &zip_len);
        if (!zip_data) {
            fprintf(stderr, "cannot read bundle: %s\n", zip_path);
            engine_destroy(engine);
            return 1;
        }
        bundle_rc = engine_load_bundle(engine, "scoring", 7, zip_data, (int32_t)zip_len);
        free(zip_data);
        printf("bundle: %s (zip)\n", zip_path);
    } else {
        bundle_rc = engine_load_bundle_dir(engine, "scoring", 7, "lib/scoring", 11);
        printf("bundle: lib/scoring/ (directory)\n");
    }

    if (bundle_rc != 0) {
        fprintf(stderr, "engine_load_bundle failed: code %d\n"
                "  -2 bundle table full  -3 file table full\n"
                "  -4 file too large     -5 invalid zip\n",
                (int)bundle_rc);
        engine_destroy(engine);
        return 1;
    }

    /* Compile and run the entry script. */
    script_src = read_file(script_path, &script_len);
    if (!script_src) {
        fprintf(stderr, "cannot read script: %s\n", script_path);
        engine_destroy(engine);
        return 1;
    }

    if (engine_run_path(engine,
                        script_src, (int32_t)script_len,
                        script_path, (int32_t)strlen(script_path)) != 0) {
        log_error(engine, "script load failed");
        free(script_src);
        engine_destroy(engine);
        return 1;
    }
    free(script_src);

    /* Evaluate each student. */
    printf("\nQuiz results\n");
    printf("============\n");

    for (i = 0; i < sizeof students / sizeof students[0]; i++) {
        gengo_value_wire_t args[3];
        gengo_value_wire_t out;
        char result[256];
        int32_t rc;

        args[0] = gengo_wire_str(students[i].name);
        args[1] = gengo_wire_int(students[i].correct);
        args[2] = gengo_wire_int(students[i].total);
        out = gengo_wire_null();

        rc = engine_call(engine, "evaluate", 8, args, 3, &out);
        if (rc != 0) {
            log_error(engine, "evaluate call failed");
            continue;
        }

        gengo_wire_read_str(&out, result, sizeof result);
        printf("  %s\n", result);
    }

    engine_destroy(engine);
    return 0;
}
