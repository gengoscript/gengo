#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <sqlite3.h>
#include <gengo-engine.h>
#include <gengo-wire.h>

/* ── Policy context ───────────────────────────────────────────────────────── */

typedef struct {
    int32_t engine;
    char    last_reason[512];
} policy_ctx_t;

/*
 * Engine errors arrive as "panic: RangeError: AmountCents: 0 is outside 1..100000000".
 * Strip the "panic: XxxError: " prefix so the caller sees the readable part.
 */
static void store_engine_error(policy_ctx_t *pol)
{
    char raw[512];
    int32_t n = engine_last_error(pol->engine, raw, (int32_t)sizeof raw - 1);
    if (n <= 0) { strncpy(pol->last_reason, "policy engine error", sizeof pol->last_reason - 1); return; }
    if (n >= (int32_t)sizeof raw) n = (int32_t)sizeof raw - 1;
    raw[n] = '\0';

    const char *msg = raw;
    if (strncmp(msg, "panic: ", 7) == 0) {
        msg += 7;
        const char *colon = strstr(msg, ": ");
        if (colon) msg = colon + 2;
    }
    strncpy(pol->last_reason, msg, sizeof pol->last_reason - 1);
    pol->last_reason[sizeof pol->last_reason - 1] = '\0';
}

/* ── SQLite custom functions ──────────────────────────────────────────────── */

/*
 * gengo_validate(amount_cents, currency, qty) → INTEGER (0 = rejected, 1 = accepted)
 *
 * Used in the BEFORE INSERT/UPDATE trigger WHEN clause.  Two failure modes:
 *   rc == -2  Named-type enforcement fired a runtime panic; engine error has the reason.
 *   rc ==  0, result false  Explicit return false; script set last_reject_reason().
 */
static void sql_gengo_validate(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    policy_ctx_t *pol = (policy_ctx_t *)sqlite3_user_data(ctx);
    gengo_value_wire_t args[3];
    gengo_value_wire_t out;
    const char *currency;
    int32_t rc;

    (void)argc;

    currency = (const char *)sqlite3_value_text(argv[1]);
    if (!currency) {
        strncpy(pol->last_reason, "currency is null", sizeof pol->last_reason - 1);
        sqlite3_result_int(ctx, 0);
        return;
    }

    args[0] = gengo_wire_int(sqlite3_value_int64(argv[0]));
    args[1] = gengo_wire_str(currency);
    args[2] = gengo_wire_int(sqlite3_value_int64(argv[2]));

    out = gengo_wire_null();
    rc  = engine_call(pol->engine, "validate", 8, args, 3, &out);

    if (rc == -2) {
        /* Named-type panic — reason is in the engine error */
        store_engine_error(pol);
        sqlite3_result_int(ctx, 0);
        return;
    }
    if (rc != 0) {
        strncpy(pol->last_reason, "policy engine error", sizeof pol->last_reason - 1);
        sqlite3_result_error(ctx, pol->last_reason, -1);
        return;
    }

    if (gengo_wire_as_bool(&out)) {
        pol->last_reason[0] = '\0';
        sqlite3_result_int(ctx, 1);
    } else {
        /* Explicit return false — script stored reason in last_reject_reason() */
        gengo_value_wire_t reason_out = gengo_wire_null();
        if (engine_call(pol->engine, "last_reject_reason", 18, NULL, 0, &reason_out) == 0)
            gengo_wire_read_str(&reason_out, pol->last_reason, sizeof pol->last_reason);
        else
            strncpy(pol->last_reason, "validation failed", sizeof pol->last_reason - 1);
        sqlite3_result_int(ctx, 0);
    }
}

/*
 * gengo_reject_reason() → TEXT
 *
 * Returns the rejection reason stored by the last gengo_validate() call that
 * returned 0.  Called via SELECT after a failed INSERT to get the detail.
 */
static void sql_gengo_reject_reason(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    policy_ctx_t *pol = (policy_ctx_t *)sqlite3_user_data(ctx);
    (void)argc; (void)argv;
    sqlite3_result_text(ctx, pol->last_reason, -1, SQLITE_TRANSIENT);
}

/* ── Helpers ──────────────────────────────────────────────────────────────── */

static void exec_or_die(sqlite3 *db, const char *sql)
{
    char *errmsg = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
        fprintf(stderr, "SQL error: %s\n  %s\n", errmsg ? errmsg : "?", sql);
        sqlite3_free(errmsg);
        exit(1);
    }
}

static char *read_file(const char *path, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    long sz;
    char *buf;
    size_t nr;

    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = (char *)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return NULL; }
    nr = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[nr] = '\0';
    if (out_len) *out_len = nr;
    return buf;
}

static void fetch_reject_reason(policy_ctx_t *pol, char *buf, size_t buf_size)
{
    size_t n = strlen(pol->last_reason);
    if (n >= buf_size) n = buf_size - 1;
    memcpy(buf, pol->last_reason, n);
    buf[n] = '\0';
}

/* ── Main ─────────────────────────────────────────────────────────────────── */

typedef struct {
    int64_t     amount_cents;
    const char *currency;
    int64_t     qty;
    const char *label;
} order_t;

int main(int argc, char **argv)
{
    const char *script_path = (argc > 1) ? argv[1] : "validate.gengo";
    gengo_instance_config_t cfg;
    policy_ctx_t pol;
    sqlite3 *db = NULL;
    char *script_src = NULL;
    size_t script_len = 0;
    char errbuf[512];
    int32_t errlen;
    int i;

    static const order_t orders[] = {
        {  14999, "USD",     3, "laptop order"               },
        {    199, "EUR",     1, "single book"                },
        {  49900, "SEK",    12, "bulk stationery"            },
        {      0, "USD",     5, "zero amount"                },
        {    500, "BTC",     1, "unsupported currency"       },
        {    500, "GBP", 99999, "quantity over limit"        },
    };

    /* ── Engine setup ─────────────────────────────────────────────────────── */

    memset(&pol, 0, sizeof pol);

    cfg.heap_size_bytes = 256u * 1024u;
    cfg.max_objects     = 1024u;
    cfg.max_stack       = 256u;
    cfg.max_frames      = 32u;
    cfg.max_defers      = 64u;
    cfg.max_ops         = 100000;
    cfg.allow_io        = 0;

    pol.engine = engine_init_with_config(&cfg);
    if (pol.engine <= 0) {
        fprintf(stderr, "engine_init_with_config failed (%d)\n", (int)pol.engine);
        return 1;
    }

    script_src = read_file(script_path, &script_len);
    if (!script_src) {
        fprintf(stderr, "cannot read script: %s\n", script_path);
        engine_destroy(pol.engine);
        return 1;
    }

    if (engine_run_path(pol.engine, script_src, (int32_t)script_len,
                        script_path, (int32_t)strlen(script_path)) != 0) {
        errlen = engine_last_error(pol.engine, errbuf, (int32_t)sizeof errbuf);
        if (errlen > (int32_t)sizeof errbuf) errlen = (int32_t)sizeof errbuf;
        fprintf(stderr, "policy load failed (line %d): %.*s\n",
                engine_last_error_line(pol.engine), (int)errlen, errbuf);
        free(script_src);
        engine_destroy(pol.engine);
        return 1;
    }
    free(script_src);

    /* ── SQLite setup ─────────────────────────────────────────────────────── */

    if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
        fprintf(stderr, "sqlite3_open: %s\n", sqlite3_errmsg(db));
        engine_destroy(pol.engine);
        return 1;
    }

    if (sqlite3_create_function(db, "gengo_validate", 3,
                                SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                                &pol, sql_gengo_validate,
                                NULL, NULL) != SQLITE_OK ||
        sqlite3_create_function(db, "gengo_reject_reason", 0,
                                SQLITE_UTF8,
                                &pol, sql_gengo_reject_reason,
                                NULL, NULL) != SQLITE_OK) {
        fprintf(stderr, "sqlite3_create_function: %s\n", sqlite3_errmsg(db));
        sqlite3_close(db);
        engine_destroy(pol.engine);
        return 1;
    }

    exec_or_die(db,
        "CREATE TABLE orders ("
        "  id           INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  amount_cents INTEGER NOT NULL,"
        "  currency     TEXT    NOT NULL,"
        "  qty          INTEGER NOT NULL"
        ");");

    /*
     * The WHEN clause calls gengo_validate() — when it returns 0, the trigger
     * body fires raise(abort, ...) to block the write.  The detailed reason is
     * stored in the policy context and can be retrieved via gengo_reject_reason().
     */
    exec_or_die(db,
        "CREATE TRIGGER orders_bi BEFORE INSERT ON orders"
        " WHEN gengo_validate(NEW.amount_cents, NEW.currency, NEW.qty) = 0"
        " BEGIN SELECT raise(abort, 'order validation failed'); END;");

    exec_or_die(db,
        "CREATE TRIGGER orders_bu BEFORE UPDATE ON orders"
        " WHEN gengo_validate(NEW.amount_cents, NEW.currency, NEW.qty) = 0"
        " BEGIN SELECT raise(abort, 'order validation failed'); END;");

    /* ── Demo inserts ─────────────────────────────────────────────────────── */

    printf("\nOrders — SQLite with Gengoscript validation\n");
    printf("policy: %s\n", script_path);
    printf("============================================\n\n");

    for (i = 0; i < (int)(sizeof orders / sizeof orders[0]); i++) {
        sqlite3_stmt *stmt = NULL;
        int rc;
        char reason[512];

        printf("INSERT  amount_cents=%-10lld  currency=%-4s  qty=%-6lld  (%s)\n",
               (long long)orders[i].amount_cents,
               orders[i].currency,
               (long long)orders[i].qty,
               orders[i].label);

        sqlite3_prepare_v2(db,
            "INSERT INTO orders (amount_cents, currency, qty) VALUES (?, ?, ?);",
            -1, &stmt, NULL);
        sqlite3_bind_int64(stmt, 1, orders[i].amount_cents);
        sqlite3_bind_text(stmt, 2, orders[i].currency, -1, SQLITE_STATIC);
        sqlite3_bind_int64(stmt, 3, orders[i].qty);

        rc = sqlite3_step(stmt);
        sqlite3_finalize(stmt);

        if (rc == SQLITE_DONE) {
            printf("  -> OK  (row %lld)\n\n",
                   (long long)sqlite3_last_insert_rowid(db));
        } else {
            fetch_reject_reason(&pol, reason, sizeof reason);
            printf("  -> REJECTED  %s\n\n", reason[0] ? reason : sqlite3_errmsg(db));
        }
    }

    /* ── Print accepted rows ──────────────────────────────────────────────── */

    {
        sqlite3_stmt *stmt = NULL;
        printf("Accepted rows:\n");
        printf("  %-4s  %-12s  %-8s  %s\n", "id", "amount_cents", "currency", "qty");
        sqlite3_prepare_v2(db,
            "SELECT id, amount_cents, currency, qty FROM orders ORDER BY id;",
            -1, &stmt, NULL);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            printf("  %-4d  %-12d  %-8s  %d\n",
                   sqlite3_column_int(stmt, 0),
                   sqlite3_column_int(stmt, 1),
                   (const char *)sqlite3_column_text(stmt, 2),
                   sqlite3_column_int(stmt, 3));
        }
        sqlite3_finalize(stmt);
    }

    printf("\n");
    sqlite3_close(db);
    engine_destroy(pol.engine);
    return 0;
}
