/*
 * gengo_acl — Mosquitto v5 plugin that delegates ACL (and optionally basic
 * auth) decisions to a Gengoscript policy script.
 *
 * The script is loaded once at plugin init and re-loaded on broker reload
 * (SIGHUP). For every ACL check the plugin calls:
 *
 *     acl(client string, user string, topic string, access string) bool
 *
 * where access is one of "read", "write", "subscribe", "unsubscribe".
 * With plugin_opt_basic_auth true, it additionally calls:
 *
 *     auth(client string, user string, password string) bool
 *
 * Any script error — compile error, runtime panic, instruction budget
 * exceeded, non-boolean return — denies the request (fail closed).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mosquitto.h>
#include <mosquitto_broker.h>
#include <mosquitto_plugin.h>

#include <gengo-engine.h>

#define SCRIPT_MAX_BYTES (1024 * 1024)

static mosquitto_plugin_id_t *g_pid = NULL;
static int32_t g_engine = 0;
static char g_script_path[4096];
static int g_basic_auth = 0;

/* ── Helpers ──────────────────────────────────────────────────────────────── */

static gengo_value_wire_t wire_str(const char *s)
{
    gengo_value_wire_t v;
    memset(&v, 0, sizeof v);
    v.tag = GENGO_WIRE_STRING;
    v.payload = (uint64_t)(uintptr_t)s;
    v.len = (uint32_t)strlen(s);
    return v;
}

static void log_engine_error(const char *what)
{
    char buf[512];
    int32_t n = engine_last_error(g_engine, buf, (int32_t)sizeof buf);
    if (n > (int32_t)sizeof buf) n = (int32_t)sizeof buf;
    mosquitto_log_printf(MOSQ_LOG_WARNING, "gengo-acl: %s (line %d): %.*s",
                         what, engine_last_error_line(g_engine), (int)n, buf);
}

/* Route script std.io output into the broker log. */
static void script_write(const char *ptr, int32_t len, int32_t is_stderr)
{
    while (len > 0 && (ptr[len - 1] == '\n' || ptr[len - 1] == '\r')) len--;
    if (len <= 0) return;
    mosquitto_log_printf(is_stderr ? MOSQ_LOG_WARNING : MOSQ_LOG_INFO,
                         "gengo-acl: script: %.*s", (int)len, ptr);
}

static int load_script(void)
{
    FILE *f = fopen(g_script_path, "rb");
    if (!f) {
        mosquitto_log_printf(MOSQ_LOG_ERR, "gengo-acl: cannot open script '%s'", g_script_path);
        return MOSQ_ERR_UNKNOWN;
    }
    char *src = malloc(SCRIPT_MAX_BYTES);
    if (!src) { fclose(f); return MOSQ_ERR_NOMEM; }
    size_t n = fread(src, 1, SCRIPT_MAX_BYTES, f);
    fclose(f);

    engine_reset(g_engine);
    int32_t rc = engine_run(g_engine, src, (int32_t)n);
    free(src);
    if (rc != 0) {
        log_engine_error(rc == -1 ? "policy compile error" : "policy runtime error");
        return MOSQ_ERR_UNKNOWN;
    }
    mosquitto_log_printf(MOSQ_LOG_INFO, "gengo-acl: policy loaded from '%s'", g_script_path);
    return MOSQ_ERR_SUCCESS;
}

/* Call a script function returning bool; anything unexpected is a deny. */
static int call_bool(const char *fn, const gengo_value_wire_t *args, int argc)
{
    gengo_value_wire_t out;
    memset(&out, 0, sizeof out);
    if (engine_call(g_engine, fn, (int32_t)strlen(fn), args, argc, &out) != 0) {
        log_engine_error("policy call failed, denying");
        return 0;
    }
    return out.tag == GENGO_WIRE_BOOLEAN && out.payload == 1;
}

/* ── Event callbacks ──────────────────────────────────────────────────────── */

static int on_acl_check(int event, void *event_data, void *userdata)
{
    (void)event; (void)userdata;
    struct mosquitto_evt_acl_check *ed = event_data;

    const char *client = mosquitto_client_id(ed->client);
    const char *user = mosquitto_client_username(ed->client);
    const char *access;
    switch (ed->access) {
        case MOSQ_ACL_READ:        access = "read"; break;
        case MOSQ_ACL_WRITE:       access = "write"; break;
        case MOSQ_ACL_SUBSCRIBE:   access = "subscribe"; break;
        case MOSQ_ACL_UNSUBSCRIBE: access = "unsubscribe"; break;
        default:                   return MOSQ_ERR_ACL_DENIED;
    }

    gengo_value_wire_t args[4] = {
        wire_str(client ? client : ""),
        wire_str(user ? user : ""),
        wire_str(ed->topic ? ed->topic : ""),
        wire_str(access),
    };
    return call_bool("acl", args, 4) ? MOSQ_ERR_SUCCESS : MOSQ_ERR_ACL_DENIED;
}

static int on_basic_auth(int event, void *event_data, void *userdata)
{
    (void)event; (void)userdata;
    struct mosquitto_evt_basic_auth *ed = event_data;

    const char *client = mosquitto_client_id(ed->client);
    gengo_value_wire_t args[3] = {
        wire_str(client ? client : ""),
        wire_str(ed->username ? ed->username : ""),
        wire_str(ed->password ? ed->password : ""),
    };
    return call_bool("auth", args, 3) ? MOSQ_ERR_SUCCESS : MOSQ_ERR_AUTH;
}

static int on_reload(int event, void *event_data, void *userdata)
{
    (void)event; (void)event_data; (void)userdata;
    /* Keep serving the old policy if the new one fails to load. */
    if (load_script() != MOSQ_ERR_SUCCESS) {
        mosquitto_log_printf(MOSQ_LOG_WARNING, "gengo-acl: reload failed, keeping previous policy");
    }
    return MOSQ_ERR_SUCCESS;
}

/* ── Plugin entry points ──────────────────────────────────────────────────── */

int mosquitto_plugin_version(int supported_version_count, const int *supported_versions)
{
    for (int i = 0; i < supported_version_count; i++) {
        if (supported_versions[i] == 5) return 5;
    }
    return -1;
}

int mosquitto_plugin_init(mosquitto_plugin_id_t *identifier, void **userdata,
                          struct mosquitto_opt *options, int option_count)
{
    (void)userdata;
    g_pid = identifier;
    g_script_path[0] = '\0';
    int64_t max_ops = 100000;

    for (int i = 0; i < option_count; i++) {
        if (strcmp(options[i].key, "script") == 0) {
            snprintf(g_script_path, sizeof g_script_path, "%s", options[i].value);
        } else if (strcmp(options[i].key, "max_ops") == 0) {
            max_ops = strtoll(options[i].value, NULL, 10);
        } else if (strcmp(options[i].key, "basic_auth") == 0) {
            g_basic_auth = strcmp(options[i].value, "true") == 0;
        }
    }
    if (g_script_path[0] == '\0') {
        mosquitto_log_printf(MOSQ_LOG_ERR, "gengo-acl: plugin_opt_script is required");
        return MOSQ_ERR_UNKNOWN;
    }

    /* Values must stay within the ceilings of the preset the engine library
     * was built with (dev preset: 512 KiB heap, 2048 objects, ...). */
    gengo_instance_config_t cfg = {
        .heap_size_bytes = 512 * 1024,
        .max_objects     = 2048,
        .max_stack       = 512,
        .max_frames      = 64,
        .max_defers      = 128,
        .max_ops         = max_ops, /* hard per-call latency ceiling */
        .allow_io        = 1,       /* script println goes to the broker log */
    };
    g_engine = engine_init_with_config(&cfg);
    if (g_engine == 0) {
        mosquitto_log_printf(MOSQ_LOG_ERR, "gengo-acl: engine init failed");
        return MOSQ_ERR_UNKNOWN;
    }
    engine_set_write_fn(g_engine, script_write);

    int rc = load_script();
    if (rc != MOSQ_ERR_SUCCESS) {
        engine_destroy(g_engine);
        g_engine = 0;
        return rc;
    }

    mosquitto_callback_register(g_pid, MOSQ_EVT_ACL_CHECK, on_acl_check, NULL, NULL);
    mosquitto_callback_register(g_pid, MOSQ_EVT_RELOAD, on_reload, NULL, NULL);
    if (g_basic_auth) {
        mosquitto_callback_register(g_pid, MOSQ_EVT_BASIC_AUTH, on_basic_auth, NULL, NULL);
    }
    return MOSQ_ERR_SUCCESS;
}

int mosquitto_plugin_cleanup(void *userdata, struct mosquitto_opt *options, int option_count)
{
    (void)userdata; (void)options; (void)option_count;
    if (g_pid) {
        mosquitto_callback_unregister(g_pid, MOSQ_EVT_ACL_CHECK, on_acl_check, NULL);
        mosquitto_callback_unregister(g_pid, MOSQ_EVT_RELOAD, on_reload, NULL);
        if (g_basic_auth) {
            mosquitto_callback_unregister(g_pid, MOSQ_EVT_BASIC_AUTH, on_basic_auth, NULL);
        }
    }
    if (g_engine != 0) {
        engine_destroy(g_engine);
        g_engine = 0;
    }
    return MOSQ_ERR_SUCCESS;
}
