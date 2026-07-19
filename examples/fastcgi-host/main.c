#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gengo-engine.h>
#include <gengo-wire.h>

enum {
    fcgi_version_1 = 1,
    fcgi_begin_request = 1,
    fcgi_end_request = 3,
    fcgi_params = 4,
    fcgi_stdin = 5,
    fcgi_stdout = 6,
    fcgi_stderr = 7,
    fcgi_responder = 1,
    max_params = 16384,
    max_body = 65536,
    max_method = 32,
    max_path = 4096,
    max_query = 4096,
};

typedef struct {
    uint8_t type;
    uint16_t request_id;
    uint16_t content_len;
    uint8_t padding_len;
} record_header_t;

typedef struct {
    uint16_t request_id;
    int active;
    int params_complete;
    char params[max_params];
    size_t params_len;
    char body[max_body + 1];
    size_t body_len;
    char method[max_method];
    char path[max_path];
    char query[max_query];
} request_t;

static int read_exact(void *buf, size_t len)
{
    return len == 0 || fread(buf, 1, len, stdin) == len;
}

static int read_record_header(record_header_t *out)
{
    uint8_t raw[8];

    if (fread(raw, 1, 1, stdin) == 0) return 0;
    if (!read_exact(raw + 1, sizeof raw - 1)) return -1;
    if (raw[0] != fcgi_version_1 || raw[7] != 0) return -1;

    out->type = raw[1];
    out->request_id = ((uint16_t)raw[2] << 8) | raw[3];
    out->content_len = ((uint16_t)raw[4] << 8) | raw[5];
    out->padding_len = raw[6];
    return 1;
}

static int discard_exact(size_t len)
{
    uint8_t buf[256];
    while (len > 0) {
        size_t chunk = len < sizeof buf ? len : sizeof buf;
        if (!read_exact(buf, chunk)) return 0;
        len -= chunk;
    }
    return 1;
}

static int write_record(uint8_t type, uint16_t request_id, const void *data, size_t len)
{
    const uint8_t *ptr = data;

    while (len > 0 || (data == NULL && len == 0)) {
        uint8_t header[8];
        uint8_t padding[7] = { 0 };
        size_t chunk = len > UINT16_MAX ? UINT16_MAX : len;
        size_t pad = (8 - (chunk % 8)) % 8;

        header[0] = fcgi_version_1;
        header[1] = type;
        header[2] = (uint8_t)(request_id >> 8);
        header[3] = (uint8_t)request_id;
        header[4] = (uint8_t)(chunk >> 8);
        header[5] = (uint8_t)chunk;
        header[6] = (uint8_t)pad;
        header[7] = 0;
        if (fwrite(header, 1, sizeof header, stdout) != sizeof header) return 0;
        if (chunk != 0 && fwrite(ptr, 1, chunk, stdout) != chunk) return 0;
        if (pad != 0 && fwrite(padding, 1, pad, stdout) != pad) return 0;

        if (len == 0) break;
        ptr += chunk;
        len -= chunk;
    }
    return fflush(stdout) == 0;
}

static void send_end(uint16_t request_id, uint32_t app_status)
{
    uint8_t body[8] = {
        (uint8_t)(app_status >> 24), (uint8_t)(app_status >> 16),
        (uint8_t)(app_status >> 8), (uint8_t)app_status,
        0, 0, 0, 0,
    };
    (void)write_record(fcgi_stdout, request_id, NULL, 0);
    (void)write_record(fcgi_end_request, request_id, body, sizeof body);
}

static void send_error(uint16_t request_id, const char *message)
{
    static const char prefix[] = "Status: 500 Internal Server Error\r\n"
                                 "Content-Type: text/plain; charset=utf-8\r\n\r\n";
    (void)write_record(fcgi_stderr, request_id, message, strlen(message));
    (void)write_record(fcgi_stdout, request_id, prefix, sizeof prefix - 1);
    (void)write_record(fcgi_stdout, request_id, message, strlen(message));
    (void)write_record(fcgi_stdout, request_id, "\n", 1);
    send_end(request_id, 1);
}

static int decode_length(const uint8_t *data, size_t len, size_t *offset, size_t *out)
{
    uint8_t first;
    if (*offset >= len) return 0;
    first = data[(*offset)++];
    if ((first & 0x80u) == 0) {
        *out = first;
        return 1;
    }
    if (len - *offset < 3) return 0;
    *out = (size_t)(first & 0x7fu) << 24;
    *out |= (size_t)data[(*offset)++] << 16;
    *out |= (size_t)data[(*offset)++] << 8;
    *out |= data[(*offset)++];
    return 1;
}

static void copy_param(char *dest, size_t dest_len, const uint8_t *value, size_t value_len)
{
    size_t n = value_len < dest_len - 1 ? value_len : dest_len - 1;
    memcpy(dest, value, n);
    dest[n] = '\0';
}

static int parse_params(request_t *request)
{
    const uint8_t *data = (const uint8_t *)request->params;
    size_t offset = 0;

    request->method[0] = '\0';
    request->path[0] = '\0';
    request->query[0] = '\0';
    while (offset < request->params_len) {
        size_t name_len;
        size_t value_len;
        const uint8_t *name;
        const uint8_t *value;

        if (!decode_length(data, request->params_len, &offset, &name_len) ||
            !decode_length(data, request->params_len, &offset, &value_len) ||
            name_len > request->params_len - offset ||
            value_len > request->params_len - offset - name_len) return 0;

        name = data + offset;
        value = name + name_len;
        offset += name_len + value_len;

        if (name_len == 14 && memcmp(name, "REQUEST_METHOD", 14) == 0) {
            copy_param(request->method, sizeof request->method, value, value_len);
        } else if (name_len == 11 && memcmp(name, "SCRIPT_NAME", 11) == 0) {
            copy_param(request->path, sizeof request->path, value, value_len);
        } else if (name_len == 9 && memcmp(name, "PATH_INFO", 9) == 0 && request->path[0] == '\0') {
            copy_param(request->path, sizeof request->path, value, value_len);
        } else if (name_len == 12 && memcmp(name, "QUERY_STRING", 12) == 0) {
            copy_param(request->query, sizeof request->query, value, value_len);
        }
    }
    return request->method[0] != '\0';
}

static char *read_file(const char *path, size_t *out_len)
{
    FILE *file = fopen(path, "rb");
    long size;
    char *buf;

    if (!file || fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET) != 0) {
        if (file) fclose(file);
        return NULL;
    }
    buf = malloc((size_t)size + 1);
    if (!buf || fread(buf, 1, (size_t)size, file) != (size_t)size) {
        free(buf);
        fclose(file);
        return NULL;
    }
    fclose(file);
    buf[size] = '\0';
    *out_len = (size_t)size;
    return buf;
}

static void log_engine_error(int32_t engine, const char *prefix)
{
    char message[512];
    int32_t len = engine_last_error(engine, message, sizeof message - 1);
    if (len < 0) len = 0;
    if (len >= (int32_t)sizeof message) len = sizeof message - 1;
    message[len] = '\0';
    fprintf(stderr, "%s: %s\n", prefix, message);
}

static void run_request(int32_t engine, request_t *request)
{
    gengo_value_wire_t args[4];
    gengo_value_wire_t result = gengo_wire_null();
    const char *response;
    int32_t rc;

    if (!parse_params(request)) {
        send_error(request->request_id, "invalid or incomplete FastCGI PARAMS");
        return;
    }
    request->body[request->body_len] = '\0';
    args[0] = gengo_wire_str(request->method);
    args[1] = gengo_wire_str(request->path);
    args[2] = gengo_wire_str(request->query);
    args[3] = gengo_wire_str_n(request->body, (uint32_t)request->body_len);
    rc = engine_call(engine, "handle", 6, args, 4, &result);
    if (rc != 0) {
        log_engine_error(engine, "Gengoscript handler failed");
        send_error(request->request_id, "Gengoscript handler failed");
        return;
    }
    if (result.tag != GENGO_WIRE_STRING || !result.payload) {
        send_error(request->request_id, "Gengoscript handle() must return a string");
        return;
    }
    response = (const char *)(uintptr_t)result.payload;
    (void)write_record(fcgi_stdout, request->request_id, response, result.len);
    send_end(request->request_id, 0);
}

int main(int argc, char **argv)
{
    const char *script_path = argc == 2 ? argv[1] : "app.gengo";
    gengo_instance_config_t config = { 512u * 1024u, 2048u, 512u, 64u, 128u, 200000, 0 };
    int32_t engine;
    char *script;
    size_t script_len;
    request_t request = { 0 };

    script = read_file(script_path, &script_len);
    if (!script) {
        fprintf(stderr, "cannot read Gengoscript application: %s\n", script_path);
        return 1;
    }
    engine = engine_init_with_config(&config);
    if (engine <= 0) {
        fprintf(stderr, "engine_init_with_config failed (%d)\n", (int)engine);
        free(script);
        return 1;
    }
    if (engine_run_path(engine, script, (int32_t)script_len, script_path, (int32_t)strlen(script_path)) != 0) {
        log_engine_error(engine, "Gengoscript application failed to load");
        free(script);
        engine_destroy(engine);
        return 1;
    }
    free(script);

    for (;;) {
        record_header_t header;
        uint8_t content[UINT16_MAX];
        int header_rc = read_record_header(&header);

        if (header_rc == 0) break;
        if (header_rc < 0 || !read_exact(content, header.content_len) || !discard_exact(header.padding_len)) {
            fprintf(stderr, "invalid or truncated FastCGI record\n");
            break;
        }
        if (header.type == fcgi_begin_request) {
            if (header.content_len < 3 || request.active ||
                (((uint16_t)content[0] << 8) | content[1]) != fcgi_responder) {
                send_error(header.request_id, "only one sequential FastCGI responder request is supported");
                continue;
            }
            memset(&request, 0, sizeof request);
            request.request_id = header.request_id;
            request.active = 1;
        } else if (!request.active || header.request_id != request.request_id) {
            continue;
        } else if (header.type == fcgi_params) {
            if (header.content_len == 0) {
                request.params_complete = 1;
            } else if (request.params_len + header.content_len > sizeof request.params) {
                send_error(request.request_id, "FastCGI PARAMS exceed host limit");
                request.active = 0;
            } else {
                memcpy(request.params + request.params_len, content, header.content_len);
                request.params_len += header.content_len;
            }
        } else if (header.type == fcgi_stdin) {
            if (header.content_len == 0) {
                if (!request.params_complete) {
                    send_error(request.request_id, "FastCGI STDIN arrived before PARAMS completed");
                } else {
                    run_request(engine, &request);
                }
                request.active = 0;
            } else if (request.body_len + header.content_len > max_body) {
                send_error(request.request_id, "FastCGI request body exceeds host limit");
                request.active = 0;
            } else {
                memcpy(request.body + request.body_len, content, header.content_len);
                request.body_len += header.content_len;
            }
        }
    }
    engine_destroy(engine);
    return ferror(stdin) || ferror(stdout) ? 1 : 0;
}
