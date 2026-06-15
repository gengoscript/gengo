#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gengo-engine.h>
#include <gengo-wire.h>

typedef struct {
    const char *model;
    const char *serial;
    const char *region;
    int current_build;
    int target_build;
    int battery_percent;
} device_case_t;

static const char *enabled_models[] = {
    "meter-v1",
    "gateway-x",
    "sensor-pro",
};

static const char *blocked_serials[] = {
    "SN-BLOCK-77",
    "SN-REVOKED-13",
};

static int str_in_list(const char *s, const char *const *list, size_t count)
{
    size_t i;
    for (i = 0; i < count; i++) {
        if (strcmp(s, list[i]) == 0) return 1;
    }
    return 0;
}

static int model_enabled(const char *model)
{
    return str_in_list(model, enabled_models, sizeof enabled_models / sizeof enabled_models[0]);
}

static int serial_blocked(const char *serial)
{
    return str_in_list(serial, blocked_serials, sizeof blocked_serials / sizeof blocked_serials[0]);
}

static void log_engine_error(int32_t engine, const char *what)
{
    char buf[512];
    int32_t n = engine_last_error(engine, buf, (int32_t)sizeof buf);

    if (n < 0) n = 0;
    if (n > (int32_t)sizeof buf) n = (int32_t)sizeof buf;

    fprintf(stderr, "%s (line %d, col %d): %.*s\n",
            what,
            engine_last_error_line(engine),
            engine_last_error_col(engine),
            (int)n,
            buf);
}

static void script_write(const char *ptr, int32_t len, int32_t is_stderr)
{
    FILE *out = is_stderr ? stderr : stdout;
    fprintf(out, "[script] %.*s", (int)len, ptr);
}

static char *read_file(const char *path, size_t *out_len)
{
    FILE *f;
    long size;
    size_t nread;
    char *buf;

    f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    size = ftell(f);
    if (size < 0) {
        fclose(f);
        return NULL;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return NULL;
    }

    buf = (char *)malloc((size_t)size + 1u);
    if (!buf) {
        fclose(f);
        return NULL;
    }

    nread = fread(buf, 1, (size_t)size, f);
    fclose(f);
    buf[nread] = '\0';
    if (out_len) *out_len = nread;
    return buf;
}

static int call_bool_fn(int32_t engine,
                        const char *fn_name,
                        const gengo_value_wire_t *args,
                        int argc,
                        int *out_value)
{
    gengo_value_wire_t out = gengo_wire_null();
    int32_t rc = engine_call(engine, fn_name, (int32_t)strlen(fn_name), args, argc, &out);
    if (rc != 0) return rc;
    *out_value = gengo_wire_as_bool(&out);
    return 0;
}

static int call_string_fn(int32_t engine,
                          const char *fn_name,
                          char *buf,
                          size_t buf_size)
{
    gengo_value_wire_t out = gengo_wire_null();
    int32_t rc = engine_call(engine, fn_name, (int32_t)strlen(fn_name), NULL, 0, &out);
    if (rc != 0) return rc;
    gengo_wire_read_str(&out, buf, buf_size);
    return 0;
}

int main(int argc, char **argv)
{
    const char *script_path = (argc > 1) ? argv[1] : "policy.gengo";
    const device_case_t cases[] = {
        { "meter-v1", "SN-1001",       "eu",   4100, 4200, 82 },
        { "meter-v1", "SN-1002",       "us",   4100, 4200, 76 },
        { "gateway-x", "SN-2001",      "us",   4800, 4900, 88 },
        { "gateway-x", "SN-REVOKED-13","us",   4800, 5200, 91 },
        { "sensor-pro", "SN-3001",     "apac", 2000, 2100, 12 },
        { "sensor-pro", "SN-3002",     "mars", 2000, 2100, 55 },
    };
    gengo_instance_config_t cfg;
    int32_t engine;
    char *script_src;
    size_t script_len = 0;
    size_t i;

    cfg.heap_size_bytes = 512u * 1024u;
    cfg.max_objects = 2048u;
    cfg.max_stack = 512u;
    cfg.max_frames = 64u;
    cfg.max_defers = 128u;
    cfg.max_ops = 200000;
    cfg.allow_io = 0;

    engine = engine_init_with_config(&cfg);
    if (engine <= 0) {
        fprintf(stderr, "engine_init_with_config failed (%d)\n", (int)engine);
        return 1;
    }

    engine_set_write_fn(engine, script_write);

    script_src = read_file(script_path, &script_len);
    if (!script_src) {
        fprintf(stderr, "cannot read script: %s\n", script_path);
        engine_destroy(engine);
        return 1;
    }

    if (engine_run_path(engine,
                        script_src, (int32_t)script_len,
                        script_path, (int32_t)strlen(script_path)) != 0) {
        log_engine_error(engine, "policy load failed");
        free(script_src);
        engine_destroy(engine);
        return 1;
    }

    free(script_src);

    printf("\nFirmware rollout gate — native C host with Gengoscript policy\n");
    printf("====================================================================\n");
    printf("script: %s\n\n", script_path);
    fflush(stdout);

    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        gengo_value_wire_t args[8];
        int allowed = 0;
        int32_t rc;
        char reason[256];

        args[0] = gengo_wire_str(cases[i].model);
        args[1] = gengo_wire_str(cases[i].region);
        args[2] = gengo_wire_int(cases[i].current_build);
        args[3] = gengo_wire_int(cases[i].target_build);
        args[4] = gengo_wire_bool(model_enabled(cases[i].model));
        args[5] = gengo_wire_bool(serial_blocked(cases[i].serial));
        args[6] = gengo_wire_int(cases[i].battery_percent);

        printf("device model=%s serial=%s region=%s current=%d target=%d battery=%d%%\n",
               cases[i].model,
               cases[i].serial,
               cases[i].region,
               cases[i].current_build,
               cases[i].target_build,
               cases[i].battery_percent);
        fflush(stdout);

        rc = call_bool_fn(engine, "allow_update", args, 7, &allowed);
        if (rc != 0) {
            log_engine_error(engine, "policy call failed");
            printf("  -> FAIL CLOSED\n\n");
            fflush(stdout);
            continue;
        }

        if (allowed) {
            printf("  -> ALLOW\n\n");
            fflush(stdout);
            continue;
        }

        if (call_string_fn(engine, "last_reason", reason, sizeof reason) != 0) {
            log_engine_error(engine, "could not fetch reject reason");
            printf("  -> DENY\n\n");
            fflush(stdout);
            continue;
        }

        printf("  -> DENY (%s)\n\n", reason[0] ? reason : "no reason");
        fflush(stdout);
    }

    engine_destroy(engine);
    return 0;
}
