GENGO_ROOT ?= ../..
DEMO_PORT ?= 8091

test:
	LD_LIBRARY_PATH=$(abspath $(GENGO_ROOT)/zig-out/lib) go test ./...

run:
	LD_LIBRARY_PATH=$(abspath $(GENGO_ROOT)/zig-out/lib) go run . -token dev-token

demo:
	@set -eu; \
	command -v jq >/dev/null || { echo "demo requires jq" >&2; exit 1; }; \
	(cd $(GENGO_ROOT) && zig build -Dpreset=1m engine-native-release); \
	bin=$$(mktemp /tmp/gengo-function-service.XXXXXX); \
	data=$$(mktemp -d /tmp/gengo-function-service-data.XXXXXX); \
	log=$$(mktemp /tmp/gengo-function-service.XXXXXX.log); \
	pid=; \
	trap 'if [ -n "$$pid" ]; then kill $$pid 2>/dev/null || true; wait $$pid 2>/dev/null || true; fi; rm -f $$bin $$log; rm -rf $$data' EXIT INT TERM; \
	go build -o $$bin .; \
	LD_LIBRARY_PATH=$(abspath $(GENGO_ROOT)/zig-out/lib) $$bin -listen 127.0.0.1:$(DEMO_PORT) -data $$data -token demo-token >$$log 2>&1 & \
	pid=$$!; \
	for attempt in $$(seq 1 20); do curl -fsS http://127.0.0.1:$(DEMO_PORT)/healthz >/dev/null && break; sleep 0.1; done; \
	if ! curl -fsS http://127.0.0.1:$(DEMO_PORT)/healthz >/dev/null; then cat $$log >&2; exit 1; fi; \
	cat $$log; \
	deploy() { \
		name=$$1; route=$$2; source=$$3; \
		payload=$$(jq -n --rawfile source "$$source" --arg route "$$route" '{route: $$route, source: $$source}'); \
		echo "Deploying $$source at $$route..."; \
		curl -fsS -X POST http://127.0.0.1:$(DEMO_PORT)/v1/functions/$$name \
		-H 'Authorization: Bearer demo-token' \
		-H 'Content-Type: application/json' \
		--data "$$payload"; \
		echo; \
	}; \
	deploy welcome /welcome welcome.gengo; \
	deploy request-info /request-info request-info.gengo; \
	deploy created /created created.gengo; \
	deploy clock /clock clock.gengo; \
	echo 'Invoking /welcome?name=Ada...'; \
	curl -fsS 'http://127.0.0.1:$(DEMO_PORT)/welcome?name=Ada'; \
	echo; \
	echo 'POSTing /request-info?source=demo...'; \
	curl -isS -X POST 'http://127.0.0.1:$(DEMO_PORT)/request-info?source=demo' --data 'request body'; \
	echo; \
	echo 'Invoking /created...'; \
	curl -isS http://127.0.0.1:$(DEMO_PORT)/created; \
	echo; \
	echo 'Invoking /clock...'; \
	curl -isS http://127.0.0.1:$(DEMO_PORT)/clock; \
	echo

.PHONY: demo run test
