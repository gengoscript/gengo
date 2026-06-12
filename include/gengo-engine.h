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
    GENGO_WIRE_NULL    = 0,
    GENGO_WIRE_BOOLEAN = 1,
    GENGO_WIRE_NUMBER  = 2,
    GENGO_WIRE_STRING  = 3,
    GENGO_WIRE_ARRAY   = 4,
    GENGO_WIRE_MAP     = 5,
    GENGO_WIRE_ERROR   = 6,  /* error_value: payload=string ptr, len=byte length */
} gengo_wire_tag_t;

/*
 * Flags for GENGO_WIRE_NUMBER (bits in the flags byte):
 *
 *   bit 0 (GENGO_WIRE_FLAG_INTEGER): payload is an integer encoded as f64 bits.
 *          Without this flag the number is treated as a float.
 *   bit 1 (GENGO_WIRE_FLAG_DECIMAL): payload is a raw i64 fixed-point value
 *          (scale ×1000, matching Gengoscript's decimal type). No f64 precision loss.
 *   bit 2 (GENGO_WIRE_FLAG_RUNE):    payload is a Unicode codepoint (u21).
 *          Decodes to Gengoscript's rune type rather than a numeric type.
 */
#define GENGO_WIRE_FLAG_INTEGER 0x01
#define GENGO_WIRE_FLAG_DECIMAL 0x02
#define GENGO_WIRE_FLAG_RUNE    0x04

typedef struct {
    uint8_t  tag;        /* gengo_wire_tag_t */
    uint8_t  flags;      /* GENGO_WIRE_FLAG_* bits (meaningful for GENGO_WIRE_NUMBER) */
    uint16_t reserved;
    uint64_t payload;    /* bool: 0/1 | number: f64 bits | string/error: ptr | array/map: ptr */
    uint32_t len;        /* string/error: byte count | array: element count | map: entry count */
    uint32_t reserved2;
} gengo_value_wire_t;

/* ── Host module function descriptor ──────────────────────────────────────── */

typedef struct {
    uintptr_t name_ptr; /* pointer to the function name string */
    uint32_t  name_len;
    uint32_t  arity;
} gengo_host_module_func_def_t;

/* ── Import loader callback ────────────────────────────────────────────────── */

/*
 * Callback for resolving module imports at runtime.
 * The engine invokes this callback when a script imports a module that is not
 * in the source table (engine_add_source).  If the callback returns 0, the
 * engine falls back to the source table.
 *
 * @param ctx        User-supplied context pointer passed to engine_set_import_loader.
 * @param path       Pointer to the import path string in engine memory.
 * @param path_len   Length of the import path in bytes.
 * @param out_buf    Buffer in engine memory where the callback writes the source.
 * @param out_max_len Size of out_buf in bytes.
 * @return           Number of bytes written to out_buf on success,
 *                   0 if the module was not found,
 *                   negative on error.
 */
typedef int32_t (*gengo_import_loader_fn)(void* ctx,
                                          const char* path, int32_t path_len,
                                          char* out_buf, int32_t out_max_len);

/* ── Write callback (native target only) ──────────────────────────────────── */

/*
 * In the WASM target, gengo_write is an import provided by the host runtime.
 * In the native shared-library target, the host registers this callback via
 * engine_set_write_fn().  If no callback is set, output falls through to
 * stdout / stderr directly.
 */
typedef void (*gengo_write_fn_t)(const char *ptr, int32_t len, int32_t is_stderr);

/* ── Instance configuration ───────────────────────────────────────────────── */

/*
 * Optional configuration passed to engine_init_with_config().
 * All fields must be set; use engine_init() for defaults.
 *
 * max_ops: instruction budget. -1 means unlimited.
 *          Scripts that exceed the budget receive InstructionBudgetExceeded.
 */
typedef struct {
    size_t   heap_size_bytes;
    size_t   max_objects;
    size_t   max_stack;
    size_t   max_frames;
    size_t   max_defers;
    int64_t  max_ops;    /* -1 = unlimited */
    uint8_t  allow_io;
} gengo_instance_config_t;

/* ── Engine lifecycle ─────────────────────────────────────────────────────── */

/* Create a new engine instance with default configuration.
 * Returns a positive handle on success, 0 on failure. */
int32_t engine_init(void);

/*
 * Create a new engine instance with explicit configuration.
 * config must remain valid only for the duration of this call.
 * Returns a positive handle on success, 0 on failure.
 * On failure, engine_last_error(0, ...) returns a description.
 */
int32_t engine_init_with_config(const gengo_instance_config_t *config);

/* Destroy an engine instance and release its resources. */
void engine_destroy(int32_t handle);

/* Reset an engine (clear compiled state, keep config). */
void engine_reset(int32_t handle);

/* ── Compilation / execution ──────────────────────────────────────────────── */

/*
 * Compile and run Gengoscript source code.
 * Returns  0 on success,
 *         -1 on compile error,
 *         -2 on runtime error.
 */
int32_t engine_run(int32_t handle, const char *src, int32_t src_len);

/*
 * Compile and run Gengoscript source code with an explicit path.
 * Returns  0 on success,
 *         -1 on compile error,
 *         -2 on runtime error.
 */
int32_t engine_run_path(int32_t handle,
                        const char *src, int32_t src_len,
                        const char *path, int32_t path_len);

/* ── Calling exported functions ───────────────────────────────────────────── */

/*
 * Call a globally exported Gengoscript function by name.
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
 * Register a host module so that Gengoscript code can import it.
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

/* ── Import loader registration ───────────────────────────────────────────── */

/*
 * Register a callback that resolves module imports at runtime.
 * When a script imports a module (e.g. import("./util")), the engine first
 * invokes this callback.  If the callback returns 0 (not found), the engine
 * falls back to sources registered via engine_add_source.
 *
 * Pass NULL for load_fn to clear the callback and use only the source table.
 * Returns 0 on success, -1 if the engine handle is invalid.
 */
int32_t engine_set_import_loader(int32_t handle,
                                 gengo_import_loader_fn load_fn,
                                 void* ctx);

/* ── Write callback registration (native target only) ────────────────────── */

/*
 * Register a host-provided write callback for an engine.
 * If the callback is NULL (or never set), output falls through to stdout/stderr.
 * On the WASM target this function is a no-op.
 */
void engine_set_write_fn(int32_t handle, gengo_write_fn_t callback);

/* ── Version ──────────────────────────────────────────────────────────────── */

/*
 * Returns the bare engine version as a null-terminated string (e.g. "0.4.0"),
 * machine-parseable; display branding is left to the caller.
 * The pointer is valid for the lifetime of the library. Do not free it.
 */
const char* gengo_engine_version(void);

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
