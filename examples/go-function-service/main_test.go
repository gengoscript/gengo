package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const greetingFunction = `
pub func handle(method string, path string, query string, body string) string {
    return "Content-Type: text/plain; charset=utf-8\r\n\r\n" + method + " " + path + " " + query + " " + body
}
`

func deploy(t *testing.T, client *http.Client, baseURL, token, name, route, source string) *http.Response {
	t.Helper()
	payload, err := json.Marshal(deployRequest{Route: route, Source: source})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, baseURL+"/v1/functions/"+name, bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func TestFunctionServiceDeployAndReload(t *testing.T) {
	dataDir := t.TempDir()
	service, err := newService(dataDir, "test-token")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(service)

	unauthenticated, err := http.Post(server.URL+"/v1/functions/greeting", "application/json", bytes.NewBufferString(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if unauthenticated.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated deploy status = %d", unauthenticated.StatusCode)
	}
	unauthenticated.Body.Close()

	deployed := deploy(t, server.Client(), server.URL, "test-token", "greeting", "/hello", greetingFunction)
	if deployed.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(deployed.Body)
		t.Fatalf("deploy status = %d: %s", deployed.StatusCode, body)
	}
	deployed.Body.Close()

	response, err := server.Client().Post(server.URL+"/hello?name=Ada", "text/plain", bytes.NewBufferString("request body"))
	if err != nil {
		t.Fatal(err)
	}
	responseBody, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("route status = %d: %s", response.StatusCode, responseBody)
	}
	if response.Header.Get("Content-Type") != "text/plain; charset=utf-8" {
		t.Fatalf("route content type = %q", response.Header.Get("Content-Type"))
	}
	if string(responseBody) != "POST /hello name=Ada request body" {
		t.Fatalf("route body = %q", responseBody)
	}

	invalid := deploy(t, server.Client(), server.URL, "test-token", "broken", "/broken", "pub func handle(")
	if invalid.StatusCode != http.StatusUnprocessableEntity {
		body, _ := io.ReadAll(invalid.Body)
		t.Fatalf("invalid deploy status = %d: %s", invalid.StatusCode, body)
	}
	invalid.Body.Close()

	missing, err := server.Client().Get(server.URL + "/broken")
	if err != nil {
		t.Fatal(err)
	}
	if missing.StatusCode != http.StatusNotFound {
		t.Fatalf("invalid route status = %d", missing.StatusCode)
	}
	missing.Body.Close()

	server.Close()
	service.Close()

	reloaded, err := newService(dataDir, "test-token")
	if err != nil {
		t.Fatal(err)
	}
	reloadedServer := httptest.NewServer(reloaded)
	defer reloadedServer.Close()
	defer reloaded.Close()

	reloadedResponse, err := reloadedServer.Client().Get(reloadedServer.URL + "/hello?name=reload")
	if err != nil {
		t.Fatal(err)
	}
	deferredBody, _ := io.ReadAll(reloadedResponse.Body)
	reloadedResponse.Body.Close()
	if reloadedResponse.StatusCode != http.StatusOK || string(deferredBody) != "GET /hello name=reload " {
		t.Fatalf("reloaded route = %d %q", reloadedResponse.StatusCode, deferredBody)
	}
}

func TestValidRouteReservesTheVersionNamespace(t *testing.T) {
	for _, route := range []string{"/v1", "/v1/", "/v1/functions/example", "/healthz"} {
		if validRoute(route) {
			t.Fatalf("validRoute(%q) = true", route)
		}
	}
}

func TestDeployRejectsTrailingJSON(t *testing.T) {
	service, err := newService(t.TempDir(), "test-token")
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	server := httptest.NewServer(service)
	defer server.Close()

	payload, err := json.Marshal(deployRequest{Route: "/hello", Source: greetingFunction})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/functions/greeting", bytes.NewBuffer(append(payload, []byte(" {}")...)))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer test-token")
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("trailing JSON status = %d", response.StatusCode)
	}
}

func TestNewServiceRejectsDuplicateManifestNames(t *testing.T) {
	dir := t.TempDir()
	data, err := json.Marshal(manifest{Functions: []storedFunction{
		{Name: "first", Route: "/first", Source: greetingFunction},
		{Name: "first", Route: "/second", Source: greetingFunction},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "functions.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	service, err := newService(dir, "test-token")
	if service != nil {
		service.Close()
	}
	if err == nil {
		t.Fatal("newService accepted duplicate function names")
	}
}

func TestParseScriptResponseRejectsUnsafeHeaders(t *testing.T) {
	for _, header := range []string{"Connection: close", "Transfer-Encoding: chunked", "Trailer: X-Internal", "Proxy-Authenticate: hidden"} {
		if _, _, _, err := parseScriptResponse(header + "\r\n\r\nok"); err == nil {
			t.Fatalf("parseScriptResponse accepted %q", header)
		}
	}
}

func TestFunctionsUseIsolatedWorkersAndRestartIndependently(t *testing.T) {
	service, err := newService(t.TempDir(), "test-token")
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	if err := service.deploy("first", deployRequest{Route: "/first", Source: greetingFunction}); err != nil {
		t.Fatal(err)
	}
	if err := service.deploy("second", deployRequest{Route: "/second", Source: greetingFunction}); err != nil {
		t.Fatal(err)
	}

	first := service.byName["first"]
	second := service.byName["second"]
	firstPID := first.worker.cmd.Process.Pid
	if firstPID == second.worker.cmd.Process.Pid {
		t.Fatal("functions share a worker process")
	}
	first.worker.close()

	response, err := first.call(http.MethodGet, "/first", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(response, "GET /first") {
		t.Fatalf("restarted function response = %q", response)
	}
	if first.worker.cmd.Process.Pid == firstPID {
		t.Fatal("failed worker was not replaced")
	}
	response, err = second.call(http.MethodGet, "/second", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(response, "GET /second") {
		t.Fatalf("unaffected function response = %q", response)
	}
}

func TestWorkerFramesPreserveRawBytes(t *testing.T) {
	fields := [][]byte{[]byte("source\x00with\nbytes"), []byte("request\r\nbody")}
	var buffer bytes.Buffer
	if err := writeWorkerFrame(&buffer, workerLoad, fields...); err != nil {
		t.Fatal(err)
	}
	kind, actual, err := readWorkerFrame(&buffer, maxSourceBytes)
	if err != nil {
		t.Fatal(err)
	}
	if kind != workerLoad || len(actual) != len(fields) {
		t.Fatalf("worker frame = kind %d fields %d", kind, len(actual))
	}
	for index := range fields {
		if !bytes.Equal(actual[index], fields[index]) {
			t.Fatalf("field %d = %q, want %q", index, actual[index], fields[index])
		}
	}
}

func TestStartupMessageExplainsServiceUse(t *testing.T) {
	message := startupMessage("127.0.0.1:8080")
	for _, want := range []string{
		"http://127.0.0.1:8080",
		"GET  http://127.0.0.1:8080/healthz",
		"POST http://127.0.0.1:8080/v1/functions/{name}",
		"Authorization: Bearer <token>",
		"curl -i http://127.0.0.1:8080/<route>",
	} {
		if !strings.Contains(message, want) {
			t.Fatalf("startup message missing %q:\n%s", want, message)
		}
	}
}

func TestBundledDemoFunctionsDeploy(t *testing.T) {
	service, err := newService(t.TempDir(), "test-token")
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()

	for _, demo := range []struct {
		name  string
		route string
		file  string
	}{
		{name: "welcome", route: "/welcome", file: "welcome.gengo"},
		{name: "request-info", route: "/request-info", file: "request-info.gengo"},
		{name: "created", route: "/created", file: "created.gengo"},
		{name: "clock", route: "/clock", file: "clock.gengo"},
	} {
		source, err := os.ReadFile(demo.file)
		if err != nil {
			t.Fatal(err)
		}
		if err := service.deploy(demo.name, deployRequest{Route: demo.route, Source: string(source)}); err != nil {
			t.Fatalf("deploy %s: %v", demo.file, err)
		}
	}
}
