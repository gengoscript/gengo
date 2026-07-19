package main

/*
#cgo CFLAGS: -I../../include
#cgo LDFLAGS: -L../../zig-out/lib -lgengo-engine
#include "gengo-engine.h"
#include "gengo-wire.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HTTP_HOST_RESPONSE_CAP (128 * 1024)

typedef struct {
    char response[HTTP_HOST_RESPONSE_CAP];
} gengo_http_context;

static uint64_t gengo_f64_bits(double value) {
    union { double value; uint64_t bits; } data = { .value = value };
    return data.bits;
}

static int gengo_http_wire_status(const gengo_value_wire_t *wire, int *out) {
    if (wire->tag != GENGO_WIRE_NUMBER || (wire->flags & GENGO_WIRE_FLAG_INTEGER) == 0) return 0;
    int64_t value = (int64_t)wire->payload;
    if (value < 100 || value > 599) return 0;
    *out = (int)value;
    return 1;
}

static int gengo_wire_string(const gengo_value_wire_t *wire, const char **data, uint32_t *len) {
    if (wire->tag != GENGO_WIRE_STRING || wire->payload == 0) return 0;
    *data = (const char *)(uintptr_t)wire->payload;
    *len = wire->len;
    return 1;
}

static int gengo_safe_content_type(const char *data, uint32_t len) {
    if (len == 0 || len > 256) return 0;
    for (uint32_t i = 0; i < len; i++) {
        if (data[i] == '\r' || data[i] == '\n' || data[i] < 0x20 || data[i] == 0x7f) return 0;
    }
    return 1;
}

static int32_t gengo_http_response(gengo_http_context *context, int status,
                                   const char *content_type, uint32_t content_type_len,
                                   const char *body, uint32_t body_len,
                                   gengo_value_wire_t *out) {
    if (!gengo_safe_content_type(content_type, content_type_len)) return 3;
    int header_len = snprintf(context->response, sizeof(context->response),
                              "Status: %d\r\nContent-Type: %.*s\r\n\r\n",
                              status, (int)content_type_len, content_type);
    if (header_len < 0 || (size_t)header_len + body_len > sizeof(context->response)) return 4;
    memcpy(context->response + header_len, body, body_len);
    *out = (gengo_value_wire_t){
        .tag = GENGO_WIRE_STRING,
        .flags = 0,
        .reserved = 0,
        .payload = (uintptr_t)context->response,
        .len = (uint32_t)header_len + body_len,
        .reserved2 = 0,
    };
    return 0;
}

static int32_t gengo_http_call(void *raw_context, uint16_t call_id,
                                const gengo_value_wire_t *args, uint16_t argc,
                                gengo_value_wire_t *out) {
    gengo_http_context *context = raw_context;
    if (context == NULL || out == NULL) return 4;
    if (call_id == 0 || call_id == 3) {
        double value = call_id == 0 ? 2.0 : 0.0;
        *out = (gengo_value_wire_t){ .tag = GENGO_WIRE_NUMBER, .flags = 0, .reserved = 0, .payload = gengo_f64_bits(value), .len = 0, .reserved2 = 0 };
        return 0;
    }
    if (argc != 2) return 3;
    int status;
    const char *body;
    uint32_t body_len;
    if (!gengo_http_wire_status(&args[0], &status) || !gengo_wire_string(&args[1], &body, &body_len)) return 3;
    switch (call_id) {
        case 0x1000: return gengo_http_response(context, status, "text/plain; charset=utf-8", 25, body, body_len, out);
        case 0x1001: return gengo_http_response(context, status, "text/html; charset=utf-8", 24, body, body_len, out);
        case 0x1002: return gengo_http_response(context, status, "application/json; charset=utf-8", 31, body, body_len, out);
        default: return 1;
    }
}

static gengo_http_context *gengo_http_context_new(void) {
    return calloc(1, sizeof(gengo_http_context));
}

static void gengo_http_context_free(gengo_http_context *context) {
    free(context);
}

static int32_t gengo_register_http_module(int32_t handle, gengo_http_context *context) {
    static const gengo_host_module_func_def_t functions[] = {
        { (uintptr_t)"text", 4, 2 },
        { (uintptr_t)"html", 4, 2 },
        { (uintptr_t)"json", 4, 2 },
    };
    int32_t rc = engine_set_host_call_fn(handle, gengo_http_call, context);
    if (rc != 0) return rc;
    return engine_register_module(handle, "http", 4, functions, 3);
}
*/
import "C"

import (
	"bufio"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"
)

const (
	maxSourceBytes         = 64 << 10
	maxRequestBytes        = 64 << 10
	maxScriptResponseBytes = 128 << 10
	maxDeployBytes         = maxSourceBytes*6 + 4096
	functionTimeout        = 2 * time.Second
	workerEnvironment      = "GENGO_FUNCTION_WORKER"
	workerLoad             = 1
	workerCall             = 2
	workerOK               = 3
	workerError            = 4
)

type deployRequest struct {
	Route  string `json:"route"`
	Source string `json:"source"`
}

type storedFunction struct {
	Name   string `json:"name"`
	Route  string `json:"route"`
	Source string `json:"source"`
}

type manifest struct {
	Functions []storedFunction `json:"functions"`
}

type scriptEngine struct {
	handle   C.int32_t
	httpHost *C.gengo_http_context
}

type scriptWorker struct {
	cmd    *exec.Cmd
	input  io.WriteCloser
	output *bufio.Reader
	done   chan struct{}

	mu   sync.Mutex
	dead bool
}

type function struct {
	name   string
	route  string
	source string

	mu     sync.Mutex
	worker *scriptWorker
}

type service struct {
	token string
	dir   string

	mu      sync.RWMutex
	byName  map[string]*function
	byRoute map[string]*function
}

func init() {
	if os.Getenv(workerEnvironment) == "1" {
		workerMain()
		os.Exit(0)
	}
}

func engineError(handle C.int32_t) string {
	buf := (*C.char)(C.malloc(512))
	if buf == nil {
		return "could not allocate engine error buffer"
	}
	defer C.free(unsafe.Pointer(buf))
	n := C.engine_last_error(handle, buf, 512)
	if n <= 0 {
		return "unknown engine error"
	}
	if n > 511 {
		n = 511
	}
	return C.GoStringN(buf, n)
}

func newScriptEngine(source, path string) (scriptEngine, error) {
	config := C.gengo_instance_config_t{
		heap_size_bytes: 512 << 10,
		max_objects:     2048,
		max_stack:       512,
		max_frames:      64,
		max_defers:      128,
		max_ops:         200000,
		allow_io:        0,
	}
	handle := C.engine_init_with_config(&config)
	if handle <= 0 {
		return scriptEngine{}, fmt.Errorf("engine initialization failed: %s", engineError(handle))
	}
	httpHost := C.gengo_http_context_new()
	if httpHost == nil {
		C.engine_destroy(handle)
		return scriptEngine{}, errors.New("could not allocate host:http context")
	}
	engine := scriptEngine{handle: handle, httpHost: httpHost}
	if rc := C.gengo_register_http_module(handle, httpHost); rc != 0 {
		engine.close()
		return scriptEngine{}, fmt.Errorf("register host:http: %s", engineError(handle))
	}
	if err := engine.load(source, path); err != nil {
		engine.close()
		return scriptEngine{}, err
	}
	return engine, nil
}

func (engine scriptEngine) load(source, path string) error {
	csource := C.CString(source)
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(csource))
	defer C.free(unsafe.Pointer(cpath))
	if rc := C.engine_run_path(engine.handle, csource, C.int32_t(len(source)), cpath, C.int32_t(len(path))); rc != 0 {
		return errors.New(engineError(engine.handle))
	}
	return nil
}

func (engine scriptEngine) close() {
	if engine.handle > 0 {
		C.engine_destroy(engine.handle)
	}
	if engine.httpHost != nil {
		C.gengo_http_context_free(engine.httpHost)
	}
}

func (engine scriptEngine) call(method, path, query string, body []byte) (string, error) {
	args := [4]C.gengo_value_wire_t{}
	values := []string{method, path, query, string(body)}
	cvalues := make([]*C.char, len(values))
	for i, value := range values {
		cvalues[i] = C.CString(value)
		defer C.free(unsafe.Pointer(cvalues[i]))
		args[i] = C.gengo_wire_str_n(cvalues[i], C.uint32_t(len(value)))
	}

	name := C.CString("handle")
	defer C.free(unsafe.Pointer(name))
	var out C.gengo_value_wire_t
	if rc := C.engine_call(engine.handle, name, 6, &args[0], 4, &out); rc != 0 {
		return "", errors.New(engineError(engine.handle))
	}
	if out.tag != C.GENGO_WIRE_STRING || out.payload == 0 {
		return "", errors.New("handle must return a string")
	}
	if out.len > maxScriptResponseBytes {
		return "", errors.New("handle response exceeds limit")
	}
	return string(C.GoBytes(unsafe.Pointer(uintptr(out.payload)), C.int(out.len))), nil
}

func startScriptWorker(source, path string) (*scriptWorker, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(executable)
	cmd.Env = append(os.Environ(), workerEnvironment+"=1")
	input, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	worker := &scriptWorker{cmd: cmd, input: input, output: bufio.NewReader(output), done: make(chan struct{})}
	go func() {
		_ = cmd.Wait()
		close(worker.done)
	}()
	if _, err := worker.request(workerLoad, []byte(source), []byte(path)); err != nil {
		worker.close()
		return nil, err
	}
	return worker, nil
}

func (worker *scriptWorker) request(kind byte, fields ...[]byte) ([]byte, error) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	if worker.dead {
		return nil, errors.New("function worker is unavailable")
	}
	if err := writeWorkerFrame(worker.input, kind, fields...); err != nil {
		worker.killLocked()
		return nil, errors.New("function worker request failed")
	}
	replies := make(chan []byte, 1)
	errs := make(chan error, 1)
	go func() {
		replyKind, replyFields, err := readWorkerFrame(worker.output, maxScriptResponseBytes)
		if err != nil {
			errs <- errors.New("function worker exited without a response")
			return
		}
		if len(replyFields) != 1 {
			errs <- errors.New("function worker returned an invalid response")
			return
		}
		if replyKind == workerError {
			errs <- errors.New(string(replyFields[0]))
			return
		}
		if replyKind != workerOK {
			errs <- errors.New("function worker returned an invalid response")
			return
		}
		replies <- replyFields[0]
	}()
	select {
	case reply := <-replies:
		return reply, nil
	case err := <-errs:
		worker.killLocked()
		return nil, err
	case <-time.After(functionTimeout):
		worker.killLocked()
		return nil, errors.New("function exceeded execution time limit")
	}
}

func (worker *scriptWorker) killLocked() {
	if worker.dead {
		return
	}
	worker.dead = true
	_ = worker.input.Close()
	if worker.cmd.Process != nil {
		_ = worker.cmd.Process.Kill()
	}
	<-worker.done
}

func (worker *scriptWorker) close() {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	worker.killLocked()
}

func workerMain() {
	reader := bufio.NewReader(os.Stdin)
	writer := bufio.NewWriter(os.Stdout)
	var engine scriptEngine
	defer engine.close()
	for {
		kind, fields, err := readWorkerFrame(reader, maxScriptResponseBytes)
		if err != nil {
			return
		}
		var response []byte
		switch kind {
		case workerLoad:
			if len(fields) != 2 {
				writeWorkerReply(writer, errors.New("invalid worker load request"), nil)
				continue
			}
			engine.close()
			engine, err = newScriptEngine(string(fields[0]), string(fields[1]))
		case workerCall:
			if len(fields) != 4 {
				writeWorkerReply(writer, errors.New("invalid worker call request"), nil)
				continue
			}
			if engine.handle <= 0 {
				err = errors.New("function worker is not initialized")
			} else {
				var value string
				value, err = engine.call(string(fields[0]), string(fields[1]), string(fields[2]), fields[3])
				response = []byte(value)
			}
		default:
			err = errors.New("unknown function worker request")
		}
		if err := writeWorkerReply(writer, err, response); err != nil {
			return
		}
	}
}

func writeWorkerFrame(writer io.Writer, kind byte, fields ...[]byte) error {
	if len(fields) > 255 {
		return errors.New("too many worker frame fields")
	}
	if _, err := writer.Write([]byte{kind, byte(len(fields))}); err != nil {
		return err
	}
	for _, field := range fields {
		if len(field) > maxScriptResponseBytes {
			return errors.New("worker frame field exceeds limit")
		}
		var length [4]byte
		binary.LittleEndian.PutUint32(length[:], uint32(len(field)))
		if _, err := writer.Write(length[:]); err != nil {
			return err
		}
		if _, err := writer.Write(field); err != nil {
			return err
		}
	}
	return nil
}

func readWorkerFrame(reader io.Reader, maximum int) (byte, [][]byte, error) {
	var prefix [2]byte
	if _, err := io.ReadFull(reader, prefix[:]); err != nil {
		return 0, nil, err
	}
	fields := make([][]byte, prefix[1])
	total := 0
	for index := range fields {
		var length [4]byte
		if _, err := io.ReadFull(reader, length[:]); err != nil {
			return 0, nil, err
		}
		size := int(binary.LittleEndian.Uint32(length[:]))
		if size > maximum-total {
			return 0, nil, errors.New("worker frame exceeds limit")
		}
		fields[index] = make([]byte, size)
		if _, err := io.ReadFull(reader, fields[index]); err != nil {
			return 0, nil, err
		}
		total += size
	}
	return prefix[0], fields, nil
}

func writeWorkerReply(writer *bufio.Writer, err error, response []byte) error {
	if err != nil {
		if writeErr := writeWorkerFrame(writer, workerError, []byte(err.Error())); writeErr != nil {
			return writeErr
		}
	} else if err := writeWorkerFrame(writer, workerOK, response); err != nil {
		return err
	}
	return writer.Flush()
}

func validName(name string) bool {
	if name == "" || len(name) > 64 {
		return false
	}
	for _, char := range name {
		if !(char >= 'a' && char <= 'z' || char >= '0' && char <= '9' || char == '-') {
			return false
		}
	}
	return true
}

func validRoute(route string) bool {
	return strings.HasPrefix(route, "/") && route != "/healthz" && route != "/v1" && !strings.HasPrefix(route, "/v1/")
}

func newFunction(name, route, source string) (*function, error) {
	worker, err := startScriptWorker(source, "functions/"+name+".gengo")
	if err != nil {
		return nil, err
	}
	return &function{name: name, route: route, source: source, worker: worker}, nil
}

func (fn *function) call(method, path, query string, body []byte) (string, error) {
	fn.mu.Lock()
	defer fn.mu.Unlock()
	if fn.worker.dead {
		worker, err := startScriptWorker(fn.source, "functions/"+fn.name+".gengo")
		if err != nil {
			return "", err
		}
		fn.worker = worker
	}
	reply, err := fn.worker.request(workerCall, []byte(method), []byte(path), []byte(query), body)
	if err != nil {
		return "", err
	}
	return string(reply), nil
}

func (fn *function) close() {
	fn.mu.Lock()
	defer fn.mu.Unlock()
	fn.worker.close()
}

func newService(dir, token string) (*service, error) {
	if token == "" {
		return nil, errors.New("function service token is required")
	}
	if err := os.MkdirAll(dir, 0750); err != nil {
		return nil, err
	}
	service := &service{token: token, dir: dir, byName: map[string]*function{}, byRoute: map[string]*function{}}
	data, err := os.ReadFile(filepath.Join(dir, "functions.json"))
	if errors.Is(err, os.ErrNotExist) {
		return service, nil
	}
	if err != nil {
		return nil, err
	}
	var saved manifest
	if err := json.Unmarshal(data, &saved); err != nil {
		return nil, fmt.Errorf("read functions manifest: %w", err)
	}
	for _, item := range saved.Functions {
		if !validName(item.Name) || !validRoute(item.Route) || service.byName[item.Name] != nil || service.byRoute[item.Route] != nil {
			service.Close()
			return nil, errors.New("functions manifest contains duplicate or invalid names or routes")
		}
		if len(item.Source) == 0 || len(item.Source) > maxSourceBytes {
			service.Close()
			return nil, errors.New("functions manifest contains invalid source")
		}
		fn, err := newFunction(item.Name, item.Route, item.Source)
		if err != nil {
			service.Close()
			return nil, fmt.Errorf("load %s: %w", item.Name, err)
		}
		service.byName[fn.name] = fn
		service.byRoute[fn.route] = fn
	}
	return service, nil
}

func writeAtomic(path string, data []byte) error {
	temporary := path + ".tmp"
	file, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func (service *service) persistLocked() error {
	names := make([]string, 0, len(service.byName))
	for name := range service.byName {
		names = append(names, name)
	}
	sort.Strings(names)
	saved := manifest{Functions: make([]storedFunction, 0, len(names))}
	for _, name := range names {
		fn := service.byName[name]
		saved.Functions = append(saved.Functions, storedFunction{Name: fn.name, Route: fn.route, Source: fn.source})
	}
	data, err := json.MarshalIndent(saved, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(service.dir, "functions.json"), append(data, '\n'))
}

func (service *service) deploy(name string, request deployRequest) error {
	if !validName(name) {
		return errors.New("function name must contain only lowercase letters, digits, and hyphens")
	}
	if !validRoute(request.Route) {
		return errors.New("route must start with / and cannot use /v1 or /healthz")
	}
	if len(request.Source) == 0 || len(request.Source) > maxSourceBytes {
		return fmt.Errorf("source must be between 1 and %d bytes", maxSourceBytes)
	}
	fn, err := newFunction(name, request.Route, request.Source)
	if err != nil {
		return fmt.Errorf("compile: %w", err)
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if current := service.byRoute[request.Route]; current != nil && current.name != name {
		fn.close()
		return errors.New("route is already registered")
	}
	previous := service.byName[name]
	if previous != nil {
		delete(service.byRoute, previous.route)
	}
	service.byName[name] = fn
	service.byRoute[fn.route] = fn
	if err := service.persistLocked(); err != nil {
		delete(service.byName, name)
		delete(service.byRoute, fn.route)
		if previous != nil {
			service.byName[name] = previous
			service.byRoute[previous.route] = previous
		}
		fn.close()
		return err
	}
	if previous != nil {
		previous.close()
	}
	return nil
}

func (service *service) Close() {
	service.mu.Lock()
	defer service.mu.Unlock()
	for _, fn := range service.byName {
		fn.close()
	}
	service.byName = map[string]*function{}
	service.byRoute = map[string]*function{}
}

func authorized(request *http.Request, token string) bool {
	expected := "Bearer " + token
	provided := request.Header.Get("Authorization")
	return len(provided) == len(expected) && subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
}

func validHeaderName(name string) bool {
	if name == "" {
		return false
	}
	for _, char := range name {
		if !(char >= '0' && char <= '9' || char >= 'A' && char <= 'Z' || char >= 'a' && char <= 'z' || strings.ContainsRune("!#$%&'*+-.^_`|~", char)) {
			return false
		}
	}
	return true
}

func unsafeResponseHeader(name string) bool {
	switch strings.ToLower(name) {
	case "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade":
		return true
	}
	return false
}

func validHeaderValue(value string) bool {
	for _, char := range value {
		if char == '\r' || char == '\n' || (char < 0x20 && char != '\t') || char == 0x7f {
			return false
		}
	}
	return true
}

func parseScriptResponse(response string) (int, http.Header, []byte, error) {
	headersText, body, found := strings.Cut(response, "\r\n\r\n")
	if !found {
		return 0, nil, nil, errors.New("script response is missing CGI headers")
	}
	status := http.StatusOK
	headers := make(http.Header)
	for _, line := range strings.Split(headersText, "\r\n") {
		name, value, found := strings.Cut(line, ":")
		if !found || !validHeaderName(name) || !validHeaderValue(value) {
			return 0, nil, nil, errors.New("script response has an invalid CGI header")
		}
		if strings.EqualFold(name, "Status") {
			parsed, err := strconv.Atoi(strings.TrimSpace(value))
			if err != nil || parsed < 100 || parsed > 599 {
				return 0, nil, nil, errors.New("script response has an invalid Status header")
			}
			status = parsed
			continue
		}
		if strings.EqualFold(name, "Content-Length") {
			continue
		}
		if unsafeResponseHeader(name) {
			return 0, nil, nil, errors.New("script response controls a host-managed header")
		}
		headers.Add(name, strings.TrimSpace(value))
	}
	return status, headers, []byte(body), nil
}

func (service *service) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if request.URL.Path == "/healthz" {
		writer.WriteHeader(http.StatusNoContent)
		return
	}
	if strings.HasPrefix(request.URL.Path, "/v1/functions/") {
		service.handleDeploy(writer, request)
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(writer, request.Body, maxRequestBytes))
	if err != nil {
		http.Error(writer, "request body exceeds limit", http.StatusRequestEntityTooLarge)
		return
	}
	service.mu.RLock()
	fn := service.byRoute[request.URL.Path]
	service.mu.RUnlock()
	if fn == nil {
		http.NotFound(writer, request)
		return
	}
	response, err := fn.call(request.Method, request.URL.Path, request.URL.RawQuery, body)
	if err != nil {
		http.Error(writer, "function failed", http.StatusBadGateway)
		return
	}
	status, headers, responseBody, err := parseScriptResponse(response)
	if err != nil {
		http.Error(writer, "invalid function response", http.StatusBadGateway)
		return
	}
	for name, values := range headers {
		for _, value := range values {
			writer.Header().Add(name, value)
		}
	}
	writer.WriteHeader(status)
	_, _ = writer.Write(responseBody)
}

func (service *service) handleDeploy(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.Header().Set("Allow", http.MethodPost)
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !authorized(request, service.token) {
		writer.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	mediaType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		http.Error(writer, "deployment requires application/json", http.StatusUnsupportedMediaType)
		return
	}
	name := strings.TrimPrefix(request.URL.Path, "/v1/functions/")
	if strings.Contains(name, "/") {
		http.NotFound(writer, request)
		return
	}
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, maxDeployBytes))
	decoder.DisallowUnknownFields()
	var deployment deployRequest
	if err := decoder.Decode(&deployment); err != nil {
		http.Error(writer, "invalid deployment JSON", http.StatusBadRequest)
		return
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		http.Error(writer, "deployment must contain one JSON object", http.StatusBadRequest)
		return
	}
	if err := service.deploy(name, deployment); err != nil {
		status := http.StatusUnprocessableEntity
		if err.Error() == "route is already registered" {
			status = http.StatusConflict
		}
		http.Error(writer, err.Error(), status)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(http.StatusCreated)
	_, _ = fmt.Fprintf(writer, `{"name":%q,"route":%q}`+"\n", name, deployment.Route)
}

func startupMessage(address string) string {
	baseURL := "http://" + address
	return fmt.Sprintf(`Gengo function service listening on %s

  Health:  GET  %s/healthz
  Deploy:  POST %s/v1/functions/{name}
           Authorization: Bearer <token>
           Content-Type: application/json
           {"route":"/example","source":"... Gengoscript source ..."}
  Invoke:  curl -i %s/<route>

`, baseURL, baseURL, baseURL, baseURL)
}

func main() {
	address := flag.String("listen", "127.0.0.1:8080", "HTTP listen address")
	dataDir := flag.String("data", "./function-data", "function source and manifest directory")
	token := flag.String("token", os.Getenv("GENGO_FUNCTION_TOKEN"), "Bearer token for function deployment")
	flag.Parse()

	service, err := newService(*dataDir, *token)
	if err != nil {
		fmt.Fprintln(os.Stderr, "gengo-function-service:", err)
		os.Exit(1)
	}
	defer service.Close()
	fmt.Print(startupMessage(*address))
	if err := http.ListenAndServe(*address, service); err != nil {
		fmt.Fprintln(os.Stderr, "gengo-function-service:", err)
	}
}
