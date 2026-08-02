# HAProxy OpenTelemetry — `haproxy/`

This directory contains all configuration files and the build artefact (Dockerfile at the project root) that produce the custom HAProxy image with native OpenTelemetry tracing support.

---

## Directory layout

```
haproxy/
├── haproxy.cfg             # Main HAProxy configuration (global, defaults, frontend, backend)
├── otel.cfg                # OTel filter scopes, spans, metrics, and event triggers
├── otel.yml.template       # OTel SDK exporter/processor/signal config (envsubst template)
├── docker-entrypoint.sh    # Container entrypoint — renders otel.yml, then exec's HAProxy
├── logs/                   # Bind-mounted log directory (empty at build time)
└── .dockerignore
```

---

## Dockerfile build

```bash
docker build -t haproxy-otel ../
```

See [`../Dockerfile`](../Dockerfile) for the full source.

---

## HAProxy configuration — `haproxy.cfg`

### `global` section

| Directive | Value | Purpose |
|---|---|---|
| `maxconn` | `5000` | Maximum total concurrent connections |
| `hard-stop-after` | `10s` | Grace period before forcing shutdown on reload/stop |
| `log` | `stdout … local0 debug` | Forwards all log messages to stdout (Docker-friendly) |
| `stats socket` | `/tmp/haproxy.sock mode 666 level admin` | Unix socket for runtime API (`haproxy -w` / `socat`) |
| `pidfile` | `/var/run/haproxy.pid` | PID file location (used with master-worker mode `-W`) |

### `defaults` section

All proxies inherit HTTP mode, `httplog`, `dontlognull`, 3 retries, and the standard connect/client/server timeouts (5 s / 50 s / 50 s).

### `listen stats` (port 8001)

Exposes the HAProxy statistics dashboard at `http://<host>:8001/` with admin-level access and a 10-second auto-refresh.

### `frontend otel-test-frontend` (port 10080)

This is the main ingress point for traced HTTP traffic.

| Directive | Purpose |
|---|---|
| `filter opentelemetry id otel-tracing-test config otel.cfg` | Attaches the OTel filter to this frontend; the filter ID must match the section header in `otel.cfg` |
| `http-request del-header X-INSTANA-T` | Strips the Instana trace-ID header forwarded by the client app |
| `http-request del-header X-INSTANA-S` | Strips the Instana span-ID header so the backend reads only the W3C `traceparent` injected by HAProxy |
| `http-request del-header tracestate` | Removes upstream `tracestate` to prevent conflicts |

By deleting the Instana propagation headers and keeping only the `traceparent` that the OTel filter injects, `server-app` correctly identifies HAProxy's span as its parent.

### `backend servers-backend`

Routes all traffic to `server-app:8080`. Docker's embedded DNS resolver (`127.0.0.11:53`) is used so service names resolve correctly inside the Compose network.

---

## OTel filter configuration — `otel.cfg`

The OTel filter is composed of one **instrumentation** block and two **scope** blocks.

### Instrumentation block `[otel-tracing-test]`

Matches the filter `id` declared in `haproxy.cfg`. Key settings:

| Option | Value | Meaning |
|---|---|---|
| `debug-level` | `0x77f` | Verbose debug bitmask (logs context extract/inject, span lifecycle, etc.) |
| `log` | `localhost:514 local7 debug` | Sends OTel-level debug logs to syslog |
| `config` | `/usr/local/etc/haproxy/otel.yml` | Path to the rendered SDK config (produced by `docker-entrypoint.sh`) |
| `rate-limit` | `100.0` | Allow 100 % of requests to be traced |
| `scopes` | `request_scope response_scope` | Names the two scopes defined below |

### `otel-scope request_scope`

Triggered on **`on-frontend-http-request`** (every inbound HTTP request).

1. **`extract "-" use-headers`** — reads W3C `traceparent` / `tracestate` from the incoming request headers. If absent, a new root context is created automatically.
2. **`span "HAProxy-request" parent "-" root`** — creates a span as a child of the extracted context (or a root span if none exists). Attributes captured:
   - `client.ip` — source IP (`src` fetch)
   - `frontend.name` — HAProxy frontend name
   - `http.method`, `http.target`, `http.host`
3. **`inject "-" use-headers use-vars`** — writes HAProxy's own `traceparent` into the backend request headers, making the HAProxy span the parent of any downstream span.
4. **`instrument cnt_int "haproxy.http.requests"`** — emits a counter metric (`{request}`) for every inbound request.

### `otel-scope response_scope`

Triggered on **`on-http-response`** (every outbound HTTP response).

1. Adds `http.status_code` and `backend.name` to the open `"HAProxy-request"` span.
2. Updates both the request and response counters.
3. **`finish "HAProxy-request"`** — closes and exports the span.
4. **`log-record`** — emits an OTel log record (`info`) carrying `fe_name`, `be_name`, and `status`.

---

## OTel SDK configuration — `otel.yml.template`

The template is rendered at container start by `docker-entrypoint.sh` using `envsubst` to replace `${INSTANA_HOST_NAME}`.

### Exporters

All three signal types (traces, metrics, logs) define four exporter variants each:

| Exporter | Transport | Destination |
|---|---|---|
| `otlp_grpc` | gRPC/OTLP | `instana-collector:4317` (active signal exporter) |

The **active exporter** for all three signals is `otlp_grpc`, pointing to the Instana collector container.

### Processors

Traces and logs use a **batch processor** (queue 2 048, batch 512, flush every 5 s). A single-record processor is also defined but not wired to active signals.

### Sampler

`parent_based` with delegate `always_on` — if an incoming `traceparent` marks the trace as sampled, HAProxy honours it; all root spans are always sampled.

### Resource attributes (`providers`)

Each signal provider stamps exported data with:

| Attribute | Value |
|---|---|
| `service.name` | `haproxy-front-proxy` |
| `service.instance.id` | `${INSTANA_HOST_NAME}-proxy` |
| `host.name` | `${INSTANA_HOST_NAME}` |
| `service.version` | `1.0.0` |

---

## Container entrypoint — `docker-entrypoint.sh`

```sh
#!/bin/sh
set -e

# Substitute environment variables into otel.yml before starting HAProxy
envsubst '${INSTANA_HOST_NAME}' \
  < /usr/local/etc/haproxy/otel.yml.template \
  > /usr/local/etc/haproxy/otel.yml

exec "$@"
```

`envsubst` is scoped to `${INSTANA_HOST_NAME}` only, so any other `${}` placeholders in the template are preserved verbatim. After rendering, the script `exec`s the CMD (`haproxy -W -f haproxy.cfg`), replacing itself with the HAProxy process so signals are delivered directly.

---

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `INSTANA_HOST_NAME` | Yes | Host/node name injected into OTel resource attributes and used to differentiate instances |
