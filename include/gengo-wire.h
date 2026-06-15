#ifndef GENGO_WIRE_H
#define GENGO_WIRE_H

/*
 * Inline helpers for building and reading gengo_value_wire_t values.
 * Include this alongside gengo-engine.h in any native C embedding.
 */

#include <stdint.h>
#include <string.h>
#include "gengo-engine.h"

static inline uint64_t gengo__f64_bits(double x)
{
    uint64_t bits = 0;
    memcpy(&bits, &x, sizeof bits);
    return bits;
}

static inline gengo_value_wire_t gengo_wire_null(void)
{
    gengo_value_wire_t v;
    memset(&v, 0, sizeof v);
    v.tag = GENGO_WIRE_NULL;
    return v;
}

static inline gengo_value_wire_t gengo_wire_bool(int value)
{
    gengo_value_wire_t v = gengo_wire_null();
    v.tag     = GENGO_WIRE_BOOLEAN;
    v.payload = value ? 1u : 0u;
    return v;
}

static inline gengo_value_wire_t gengo_wire_int(int64_t value)
{
    gengo_value_wire_t v = gengo_wire_null();
    v.tag     = GENGO_WIRE_NUMBER;
    v.flags   = GENGO_WIRE_FLAG_INTEGER;
    v.payload = gengo__f64_bits((double)value);
    return v;
}

static inline gengo_value_wire_t gengo_wire_float(double value)
{
    gengo_value_wire_t v = gengo_wire_null();
    v.tag     = GENGO_WIRE_NUMBER;
    v.payload = gengo__f64_bits(value);
    return v;
}

/* String must remain valid for the duration of the engine_call. */
static inline gengo_value_wire_t gengo_wire_str_n(const char *s, uint32_t len)
{
    gengo_value_wire_t v = gengo_wire_null();
    if (!s) return v;
    v.tag     = GENGO_WIRE_STRING;
    v.payload = (uint64_t)(uintptr_t)s;
    v.len     = len;
    return v;
}

static inline gengo_value_wire_t gengo_wire_str(const char *s)
{
    return gengo_wire_str_n(s, s ? (uint32_t)strlen(s) : 0u);
}

/* ── Readers ──────────────────────────────────────────────────────────────── */

static inline int gengo_wire_as_bool(const gengo_value_wire_t *v)
{
    return v->tag == GENGO_WIRE_BOOLEAN && v->payload == 1u;
}

static inline int64_t gengo_wire_as_int(const gengo_value_wire_t *v)
{
    double d;
    if (v->tag != GENGO_WIRE_NUMBER) return 0;
    memcpy(&d, &v->payload, sizeof d);
    return (int64_t)d;
}

static inline double gengo_wire_as_float(const gengo_value_wire_t *v)
{
    double d = 0.0;
    if (v->tag != GENGO_WIRE_NUMBER) return d;
    memcpy(&d, &v->payload, sizeof d);
    return d;
}

/*
 * Copy a string wire value into buf.  Always NUL-terminates.
 * Returns the number of bytes written (not counting the NUL).
 */
static inline size_t gengo_wire_read_str(const gengo_value_wire_t *v,
                                         char *buf, size_t buf_size)
{
    size_t n;
    if (buf_size == 0) return 0;
    if (v->tag != GENGO_WIRE_STRING || !v->payload || !v->len) {
        buf[0] = '\0';
        return 0;
    }
    n = v->len < buf_size ? v->len : buf_size - 1;
    memcpy(buf, (const void *)(uintptr_t)v->payload, n);
    buf[n] = '\0';
    return n;
}

#endif /* GENGO_WIRE_H */
