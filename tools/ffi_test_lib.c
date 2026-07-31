/* Shared library exercised by the tests/native-cap cap:ffi cases.
 *
 * Built as zig-out/lib/libgengo_ffi_test.so and loaded by the test scripts
 * through ffi.load. The declared signatures in the .gengo cases must stay in
 * sync with the export signatures here: cap:ffi has no type information and
 * trusts the script's declaration.
 *
 * This library is intentionally written in C rather than Zig. Zig-built shared
 * libraries loaded into Gengo's native CLI (a statically-linked musl binary
 * produced by Zig 0.16.0) interact badly with the C runtime/TLS init and can
 * corrupt their own .data.rel.ro constants at load time. A plain C .so with
 * no TLS or constructor dependencies loads and runs reliably, which is also the
 * representative case for user FFI libraries.
 */

#include <stdint.h>

__attribute__((visibility("default"))) int64_t ffi_add(int64_t a, int64_t b) {
    return a + b;
}

__attribute__((visibility("default"))) uint32_t ffi_mul(uint32_t a, uint32_t b) {
    return a * b;
}

__attribute__((visibility("default"))) double ffi_mix(double a, double b, double c, double d) {
    return a + b * c - d;
}

__attribute__((visibility("default"))) float ffi_fdiv(float a, float b) {
    return a / b;
}

__attribute__((visibility("default"))) int32_t ffi_many(int32_t a, int32_t b, int32_t c, int32_t d, int32_t e, int32_t f) {
    return a + b + c + d + e + f;
}

__attribute__((visibility("default"))) double ffi_all(double a, double b, double c, double d, double e, double f, double g, double h) {
    return a + b + c + d + e + f + g + h;
}

__attribute__((visibility("default"))) int64_t ffi_mul_i64_double(double a, int64_t b) {
    return (int64_t)(a * (double)b);
}

__attribute__((visibility("default"))) int64_t ffi_mixed(int32_t a, double b, int32_t c, double d, int32_t e) {
    return (int64_t)((double)a + b + (double)c + d + (double)e);
}

__attribute__((visibility("default"))) const char *ffi_hi(const char *s) {
    return s;
}

__attribute__((visibility("default"))) int32_t ffi_nullable(void *p) {
    return p ? 7 : -1;
}

__attribute__((visibility("default"))) int64_t ffi_cstring_len(const char *s) {
    int64_t n = 0;
    while (s[n] != 0) n += 1;
    return n;
}

__attribute__((visibility("default"))) int64_t ffi_echo_str(const char *s, int64_t n) {
    (void)s;
    return n;
}

__attribute__((visibility("default"))) void ffi_void(int32_t x) {
    (void)x;
}
