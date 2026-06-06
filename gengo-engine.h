#ifndef GENGO_ENGINE_H
#define GENGO_ENGINE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Opaque engine handle ──────────────────────────────────────────────────── */

typedef int32_t gengo_handle_t;

/* ── Wire value (used for engine_call args and results) ───────────────────── */

typedef enum {
    GENGO_WIRE_NULL = 0,
    GENGO_WIRE_BOOLEAN = 1,
    GENGO_WIRE_NUMBER = 2,
    GENGO_WIRE_STRING = 3,
    GENGO_WIRE_ARRAY = 4,
    GENGO_WIRE_MAP = 5,
} gengo_wire_tag_t;

typedef struct {
    uint8_t  tag;
    uint8_t  flags;
    uint16_t reserved;
    uint64_t payload;
    uint32_t len;
    uint32_t reserved2;
} gengo_value_wire_t;

/* ── Host module function descriptor ──────────────────────────────────────── */

typedef struct {
    uint32_t name_ptr;
    uint32_t name_len;
    uint32_t arity;
} gengo_host_module_func_def_t;

/* ── Write callback (native target only) ──────────────────────────────────── */

/*
 * In the WASM target, gengo_write is an import provided by the host runtime.
 * In the native shared-library target, the host registers this callback via
 * engine_set_write_fn().  If no callback is set, output falls through to
 * stdout / stderr directly.
 */
typedef void (*gengo_write_fn_t)(const char *ptr, int32_t len, int32_t is_stderr);

/* ── Engine lifecycle ─────────────────────────────────────────────────────── */

/* Create a new engine instance.  Returns a positive handle on success, 0 on failure. */
int32_t engine_init(void);

/* Destroy an engine instance and release its resources. */
void engine_destroy(int32_t handle);

/* Reset an engine (clear compiled state, keep config). */
void engine_reset(int32_t handle);

/* ── Compilation / execution ──────────────────────────────────────────────── */

/*
 * Compile and run Gengo source code.
 * Returns  0 on success,
 *         -1 on compile error,
 *         -2 on runtime error.
 */
int32_t engine_run(int32_t handle, const char *src, int32_t src_len);

/*
 * Compile and run Gengo source code with an explicit path.
 * Returns  0 on success,
 *         -1 on compile error,
 *         -2 on runtime error.
 */
int32_t engine_run_path(int32_t handle,
                        const char *src, int32_t src_len,
                        const char *path, int32_t path_len);

/* ── Calling exported functions ───────────────────────────────────────────── */

/*
 * Call a globally exported Gengo function by name.
 * args: pointer to an array of gengo_value_wire_t (may be NULL if argc==0).
 * out:  pointer to a gengo_value_wire_t that receives the return value (may be NULL).
 * Returns  0 on success,
 *         -2 on runtime error.
 */
int32_t engine_call(int32_t handle,
                    const char *name, int32_t name_len,
                    const gengo_value_wire_t *args, int32_t argc,
                    gengo_value_wire_t *out);

/* ── Pre-loaded sources ───────────────────────────────────────────────────── */

/*
 * Add a named source snippet that can be imported by other code.
 * Returns 0 on success, -1 if the engine handle is invalid, -3 if the source table is full.
 */
int32_t engine_add_source(int32_t handle,
                          const char *path, int32_t path_len,
                          const char *src, int32_t src_len);

/* ── Host modules ─────────────────────────────────────────────────────────── */

/*
 * Register a host module so that Gengo code can import it.
 * funcs: pointer to an array of gengo_host_module_func_def_t.
 * Returns 0 on success,
 *        -1 if the engine handle is invalid,
 *        -3 if the module table is full,
 *        -4 if funcs_count is out of range,
 *        -5 if the module name is invalid.
 */
int32_t engine_register_module(int32_t handle,
                               const char *name, int32_t name_len,
                               const gengo_host_module_func_def_t *funcs,
                               int32_t funcs_count);

/* ── Write callback registration (native target only) ────────────────────── */

/*
 * Register a host-provided write callback for an engine.
 * If the callback is NULL (or never set), output falls through to stdout/stderr.
 * On the WASM target this function is a no-op.
 */
void engine_set_write_fn(int32_t handle, gengo_write_fn_t callback);

/* ── Error inspection ─────────────────────────────────────────────────────── */

/*
 * Copy the last error message into the provided buffer.
 * Returns the full error message length (may exceed out_max_len).
 * Returns 0 if no error or the handle is invalid.
 */
int32_t engine_last_error(int32_t handle,
                          char *out, int32_t out_max_len);

/* Line number of the last error (1-based).  Returns 0 if no error. */
int32_t engine_last_error_line(int32_t handle);

/* Column number of the last error (1-based).  Returns 0 if no error. */
int32_t engine_last_error_col(int32_t handle);

#ifdef __cplusplus
}
#endif

#endif /* GENGO_ENGINE_H */
