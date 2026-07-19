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
 *   bit 0 (GENGO_WIRE_FLAG_INTEGER): payload is raw int64 bits (two's complement).
 *          Without this flag the number is treated as a float (f64 bits).
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
    uint64_t payload;    /* bool: 0/1 | float: f64 bits | integer: raw i64 bits | string/error: ptr | array/map: ptr */
    uint32_t len;        /* string/error: byte count | array: element count | map: entry count */
    uint32_t reserved2;
} gengo_value_wire_t;

/* ── Host module function descriptor ──────────────────────────────────────── */

typedef struct {
    uintptr_t name_ptr; /* pointer to the function name string */
    uint32_t  name_len;
    uint32_t  arity;
} gengo_host_module_func_def_t;

/*
 * Called when a Gengoscript function invokes a registered host:* module.
 * The callback must return one of the gengo host ABI status codes:
 *   0 = success, 1 = unsupported, 2 = denied, 3 = bad arguments, 4 = failed.
 * args and any memory referenced by args are valid only for this call. The
 * callback-owned data referenced by out must remain valid until the enclosing
 * engine_run or engine_call call returns.
 */
typedef int32_t (*gengo_host_call_fn)(void *ctx,
                                      uint16_t call_id,
                                      const gengo_value_wire_t *args,
                                      uint16_t argc,
                                      gengo_value_wire_t *out);

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

/*
 * Read callback for io.read() / io.readline().
 *   buf      — buffer to fill
 *   max_len  — buffer capacity in bytes
 *   is_line  — 0: read up to max_len bytes; 1: read until '\n' or max_len
 * Return value: bytes read (>= 0), or -1 for EOF / error.
 * In the WASM target, gengo_read is an import provided by the host runtime.
 * In the native target, the host registers via engine_set_read_fn().
 * If no callback is set, reads fall through to stdin directly.
 */
typedef int32_t (*gengo_read_fn_t)(char *buf, int32_t max_len, int32_t is_line);

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

/*
 * Create a new engine instance with default configuration.
 * Returns a positive handle on success.
 * Returns  0 if no engine slot is available.
 * Returns -4 on allocation failure; engine_last_error(0,...) returns a description.
 */
int32_t engine_init(void);

/*
 * Create a new engine instance with explicit configuration.
 * config must remain valid only for the duration of this call.
 * Returns a positive handle on success.
 * Returns  0 if no engine slot is available.
 * Returns -3 if a config value exceeds the compiled-in ceiling.
 * Returns -4 on allocation failure.
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

/*
 * Set the native host-module dispatcher for this engine. The callback is used
 * for host ABI negotiation and for every registered host:* function call.
 * Pass NULL to clear the dispatcher; subsequent host calls fail with
 * HostNativeUnsupported.
 * Returns 0 on success, -1 if the engine handle is invalid.
 */
int32_t engine_set_host_call_fn(int32_t handle,
                                gengo_host_call_fn callback,
                                void *ctx);

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

/*
 * Register a host-provided read callback for an engine.
 * If the callback is NULL (or never set), reads come from stdin directly.
 * On the WASM target this function is a no-op.
 */
void engine_set_read_fn(int32_t handle, gengo_read_fn_t callback);

/* ── Net dial policy ─────────────────────────────────────────────────────── */

/*
 * Add a dial policy rule for cap:net.
 *
 * Rules are evaluated most-recently-added first (LIFO stack). The first
 * matching rule wins. If no rule matches, the default is ALLOW.
 *
 * action:      0 = deny, 1 = allow
 * pattern:     One of:
 *                "*"                 — match any address
 *                "192.168.1.1"       — exact IPv4
 *                "192.168.1.0/24"    — IPv4 CIDR
 *                "::1"               — exact IPv6
 *                "fd00::/8"          — IPv6 CIDR
 *                "api.example.com"   — exact hostname
 *                "*.example.com"     — hostname suffix wildcard
 * port:        0 = any port; otherwise exact port match.
 *
 * Returns  0 on success,
 *         -1 if the handle is invalid,
 *         -2 if the per-engine rule list is full (max 32 rules),
 *         -3 if the pattern is invalid.
 */
int32_t engine_net_policy_add(int32_t handle,
                               int32_t action,
                               const char *pattern, int32_t pattern_len,
                               int32_t port);

/*
 * Remove all dial policy rules for the engine.
 * After this call the default (allow all) is restored.
 * Has no effect if the handle is invalid.
 */
void engine_net_policy_clear(int32_t handle);

/* ── Module bundles ──────────────────────────────────────────────────────── */

/*
 * Load a zip-format module bundle into the engine.
 *
 * name     — logical package name used in import paths (e.g. "mylib")
 * zip_ptr  — pointer to the raw zip bytes
 * zip_len  — byte length of the zip data
 *
 * Only .gengo files inside the zip are registered; other files are ignored.
 * Within the zip, path separators are '/' and files are stored without the
 * .gengo extension as the module path.
 *
 * Returns:
 *   0   success
 *  -1   invalid handle
 *  -2   package table full (max 32 packages)
 *  -3   file table full (max 64 files per package)
 *  -4   a file exceeds the 64 KiB per-file size limit
 *  -5   invalid zip data or package name
 */
int32_t engine_load_bundle(int32_t handle,
                            const char *name_ptr, int32_t name_len,
                            const void *zip_ptr,  int32_t zip_len);

/*
 * Load a package from a directory on the host filesystem (native builds only).
 * All .gengo files found recursively under dir_path are registered under name.
 * Not available in WebAssembly builds (returns -5).
 *
 * Returns same codes as engine_load_bundle.
 */
int32_t engine_load_bundle_dir(int32_t handle,
                                const char *name_ptr, int32_t name_len,
                                const char *dir_ptr,  int32_t dir_len);

/*
 * Remove all registered module bundles from the engine.
 * Does not affect engine_add_source entries or the import loader callback.
 */
void engine_clear_bundles(int32_t handle);

/* ── Runtime introspection (native target only) ───────────────────────────── */

/*
 * Callback for engine_list_globals.
 *   userdata  — opaque pointer passed to engine_list_globals
 *   name      — global variable name (not null-terminated)
 *   name_len  — length in bytes
 *   value     — current value as a ValueWire; valid only during the callback
 */
typedef void (*gengo_globals_callback_t)(void *userdata,
                                         const char *name, int32_t name_len,
                                         const gengo_value_wire_t *value);

/*
 * Callback for engine_list_functions.
 *   userdata  — opaque pointer passed to engine_list_functions
 *   name      — function name (not null-terminated)
 *   name_len  — length in bytes
 *   arity     — number of declared parameters
 */
typedef void (*gengo_functions_callback_t)(void *userdata,
                                           const char *name, int32_t name_len,
                                           int32_t arity);

/*
 * Trace callback registered via engine_set_trace_fn.
 *   userdata  — opaque pointer passed to engine_set_trace_fn
 *   handle    — engine handle that fired the event
 *   line      — 1-based source line
 *   col       — 1-based source column
 * Fires at most once per source line per engine_run/engine_call invocation.
 */
typedef void (*gengo_trace_fn_t)(void *userdata,
                                  int32_t handle, int32_t line, int32_t col);

/*
 * Read a global variable by name.
 * out may be NULL to test existence without copying the value.
 * Returns  0 on success,
 *         -1 if the handle is invalid,
 *         -2 if no global with that name exists,
 *         -3 if serialising the value to ValueWire fails.
 */
int32_t engine_get_global(int32_t handle,
                           const char *name, int32_t name_len,
                           gengo_value_wire_t *out);

/*
 * Enumerate all globals, invoking callback once per entry.
 * Not available on the WASM target (returns -1).
 * Returns 0 on success, -1 if the handle is invalid.
 */
int32_t engine_list_globals(int32_t handle,
                             gengo_globals_callback_t callback,
                             void *userdata);

/*
 * Enumerate all globals that hold a function or closure, invoking callback
 * once per entry with the function's arity.
 * Not available on the WASM target (returns -1).
 * Returns 0 on success, -1 if the handle is invalid.
 */
int32_t engine_list_functions(int32_t handle,
                               gengo_functions_callback_t callback,
                               void *userdata);

/*
 * Register a trace callback that fires once per source line during execution.
 * Pass NULL for callback to clear the callback.
 * Not available on the WASM target (no-op).
 * Has no effect if the handle is invalid.
 */
void engine_set_trace_fn(int32_t handle,
                          gengo_trace_fn_t callback,
                          void *userdata);

/* ── HTTP capability types ───────────────────────────────────────────────── */

typedef struct {
    const char **keys;    /* parallel array of null-terminated header key strings */
    const char **values;  /* parallel array of null-terminated header value strings */
    int32_t      count;
} gengo_http_headers_t;

typedef struct {
    const char          *method;
    const char          *url;
    const char          *body;
    int32_t              body_len;
    gengo_http_headers_t headers;
    int64_t              timeout_ms;
} gengo_http_request_t;

typedef struct {
    int32_t              status;
    const char          *body;
    int32_t              body_len;
    gengo_http_headers_t headers;
} gengo_http_response_t;

/*
 * Host-provided HTTP fetch callback.
 * Returns 0 on success (the script sees the response regardless of HTTP status).
 * Returns negative on network failure or timeout (becomes a runtime error).
 */
typedef int32_t (*gengo_http_fetch_fn_t)(const gengo_http_request_t *req,
                                         gengo_http_response_t *out,
                                         void *userdata);

/* ── Network capability handlers ─────────────────────────────────────────── */

/*
 * Function pointer types for the network handler table.
 * All pointers in the struct must be non-NULL when the struct is passed.
 */
typedef struct {
    int32_t (*dial)(const char *network, size_t network_len,
                    const char *address, size_t address_len,
                    int32_t *out_handle, void *userdata);
    int32_t (*read)(int32_t handle, char *buf, int32_t max_bytes, void *userdata);
    int32_t (*write)(int32_t handle, const char *data, int32_t len, void *userdata);
    void    (*close)(int32_t handle, void *userdata);
    void    (*local_addr)(int32_t handle, char *buf, int32_t buf_len, void *userdata);
    void    (*remote_addr)(int32_t handle, char *buf, int32_t buf_len, void *userdata);
    void    (*set_deadline)(int32_t handle, int64_t ms, void *userdata);
    void    (*set_read_deadline)(int32_t handle, int64_t ms, void *userdata);
    void    (*set_write_deadline)(int32_t handle, int64_t ms, void *userdata);
} gengo_net_handlers_t;

/*
 * Register host-provided network handlers.
 * Pass NULL for handlers to clear registered handlers.
 * Has no effect if the handle is invalid.
 */
void engine_set_net_handlers(int32_t handle,
                             const gengo_net_handlers_t *handlers,
                             void *userdata);

/* ── HTTP capability handler ─────────────────────────────────────────────── */

/*
 * Register a host-provided HTTP fetch callback.
 * Pass NULL for callback to clear the registered handler.
 * Has no effect if the handle is invalid.
 */
void engine_set_http_handler(int32_t handle,
                             gengo_http_fetch_fn_t callback,
                             void *userdata);

/* ── Filesystem capability ───────────────────────────────────────────────── */

/*
 * Mount a host directory for use by scripts with the cap:fs capability.
 * name: mount name used in import("cap:fs").open("name/path").
 * path: host filesystem path (native targets only; ignored on WASM).
 * Returns  0 on success,
 *         -1 if the handle is invalid,
 *         -2 if the mount table is full or the path is invalid.
 */
int32_t engine_mount_dir(int32_t handle,
                         const char *name, int32_t name_len,
                         const char *path, int32_t path_len);

/*
 * Virtual filesystem driver callbacks for engine_mount_driver.
 *
 * open:   opens a file; flags 0=read, 1=write. Writes *out_fd on success.
 *         Returns 0 on success, negative on error.
 * read:   reads up to max_len bytes into buf from fd. Returns bytes read (0=EOF),
 *         negative on error.
 * write:  writes len bytes from buf to fd. Returns bytes written, negative on error.
 * close:  closes fd. No return value.
 * exists: returns >0 if path exists, 0 if not, negative on error.
 * list:   fills out_buf with consecutive null-terminated file names and returns
 *         the total bytes written, negative on error. Callers provide 65536 bytes.
 * unlink: removes a file. Returns 0 on success, negative on error.
 * mkdir:  creates a directory. Returns 0 on success, negative on error.
 *
 * Any callback may be NULL; calling the corresponding cap:fs operation on a
 * mount with a NULL callback returns a CapabilityError to the script.
 *
 * path/path_len: the path component after the mount name (not null-terminated).
 * userdata: opaque pointer passed through unchanged from engine_mount_driver.
 */
typedef struct {
    int32_t (*open)  (void *userdata, const char *path, int32_t path_len,
                      int32_t flags, int32_t *out_fd);
    int32_t (*read)  (void *userdata, int32_t fd, char *buf, int32_t max_len);
    int32_t (*write) (void *userdata, int32_t fd, const char *buf, int32_t len);
    void    (*close) (void *userdata, int32_t fd);
    int32_t (*exists)(void *userdata, const char *path, int32_t path_len);
    int32_t (*list)  (void *userdata, const char *path, int32_t path_len,
                      char *out_buf, int32_t out_max_len);
    int32_t (*unlink) (void *userdata, const char *path, int32_t path_len);
    int32_t (*mkdir) (void *userdata, const char *path, int32_t path_len);
} gengo_fs_driver_t;

/*
 * Mount a virtual driver for use by scripts with the cap:fs capability.
 * Works on all targets including WASM/WASI where real filesystem mounts
 * are unavailable.
 * name:       mount name used in script paths (e.g. "data" matches "data/...").
 * driver:     pointer to a gengo_fs_driver_t; copied by value at call time.
 * userdata:   passed unchanged to every driver callback; must remain valid
 *             for the lifetime of the engine handle.
 * Returns  0 on success,
 *         -1 if the handle is invalid,
 *         -2 if the mount table is full or the name is invalid.
 */
int32_t engine_mount_driver(int32_t handle,
                             const char *name, int32_t name_len,
                             const gengo_fs_driver_t *driver,
                             void *userdata);

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

/*
 * Source file path of the last error.  Writes up to out_max_len bytes to out;
 * returns the full path length (may exceed out_max_len).
 * Returns 0 if no error, if the path is unknown, or the handle is invalid.
 */
int32_t engine_last_error_path(int32_t handle,
                                char *out, int32_t out_max_len);

#ifdef __cplusplus
}
#endif

#endif /* GENGO_ENGINE_H */
