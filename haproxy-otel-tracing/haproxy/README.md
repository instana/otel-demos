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

The `Dockerfile` at the project root performs a **two-stage build** on top of `ubuntu:22.04`.

### Build arguments

| Argument | Default | Description |
|---|---|---|
| `OTEL_C_WRAPPER_VERSION` | `v2.2.0` | Git tag of [haproxytech/opentelemetry-c-wrapper](https://github.com/haproxytech/opentelemetry-c-wrapper) |
| `HAPROXY_VERSION` | `v3.5-dev1` | Git tag of [haproxy/haproxy](https://github.com/haproxy/haproxy) |
| `HAPROXY_OTEL_SHA` | `d7b406b…` | Exact commit SHA of [haproxytech/haproxy-opentelemetry](https://github.com/haproxytech/haproxy-opentelemetry) |

### Stage 1 — `deps`

```dockerfile
FROM ubuntu:22.04 AS deps
```

1. **System packages** — installs the full C/C++ toolchain (`gcc`, `g++`, `cmake`, `ninja-build`, `autoconf`, `libtool`, etc.) plus `openssl`, `zlib`, `rsyslog`, and `gettext-base` (for `envsubst`).
2. **Source clones** — three repositories are cloned at the pinned versions above:
   - `opentelemetry-c-wrapper` — C binding layer around the OpenTelemetry C++ SDK.
   - `haproxy` — the upstream HAProxy source at the target version.
   - `haproxy-opentelemetry` — the HAProxy-specific OTel module that hooks into `EXTRA_MAKE`.
3. **OTel C++ SDK bundle** — runs `build-bundle.sh` inside the wrapper scripts directory; this compiles and installs the OpenTelemetry C++ SDK into `/opt`.
4. **opentelemetry-c-wrapper** — bootstrapped, configured with `--prefix=/opt --with-opentelemetry=/opt`, then compiled and installed.

### Stage 2 — `runtime`

```dockerfile
FROM deps AS runtime
```

1. **HAProxy compile** — builds HAProxy against the OTel module:
   ```
   PKG_CONFIG_PATH=/opt/lib/pkgconfig make -j8 \
       TARGET=linux-glibc \
       EXTRA_MAKE=/opt/haproxy-opentelemetry \
       OTEL_USE_VARS=1
   ```
   - `EXTRA_MAKE` points to the `haproxy-opentelemetry` module directory so `make` picks up the extra Makefile fragment.
   - `OTEL_USE_VARS=1` enables environment-variable substitution inside the OTel YAML config at runtime.
2. **Binary install** — copies the resulting `haproxy` binary to `/usr/local/sbin/haproxy`.
3. **Least-privilege user** — creates a dedicated `haproxy` system user/group (`nologin`), and sets `/tmp` to `1777` so HAProxy's Unix socket and PID file remain accessible.
4. **Config files copied** — the three files below are placed under `/usr/local/etc/haproxy/`:
   - `haproxy.cfg`
   - `otel.cfg`
   - `docker-entrypoint.sh`

   > **Note:** `otel.yml.template` is also present in this directory and must be copied separately (or added to the `COPY` list) if it is not already in the image.

5. **Entrypoint / CMD**:
   ```dockerfile
   ENTRYPOINT ["/bin/sh", "/usr/local/etc/haproxy/docker-entrypoint.sh"]
   CMD ["/usr/local/sbin/haproxy", "-W", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
   ```
   The entrypoint renders `otel.yml` from its template (see below), then `exec`s the CMD.

### Full Dockerfile

```dockerfile
FROM ubuntu:22.04 AS deps

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    curl \
    wget \
    gcc \
    g++ \
    zlib1g-dev \
    libssl-dev \
    ca-certificates \
    autoconf \
    automake \
    libtool \
    autoconf-archive \
    gettext-base \
    rsyslog \
    && rm -rf /var/lib/apt/lists/*

ARG OTEL_C_WRAPPER_VERSION=v2.2.0
ARG HAPROXY_VERSION=v3.5-dev1
ARG HAPROXY_OTEL_SHA=d7b406bfd9f7dabba8261131e8a9d0bef91ba6cd

RUN git clone --depth=1 -b "$OTEL_C_WRAPPER_VERSION" \
        https://github.com/haproxytech/opentelemetry-c-wrapper.git /opt/opentelemetry-c-wrapper \
    && rm -rf /opt/opentelemetry-c-wrapper/.git

RUN git clone --depth=1 -b "$HAPROXY_VERSION" \
        https://github.com/haproxy/haproxy.git /opt/haproxy \
    && rm -rf /opt/haproxy/.git

RUN git clone https://github.com/haproxytech/haproxy-opentelemetry.git /opt/haproxy-opentelemetry \
    && git -C /opt/haproxy-opentelemetry checkout "$HAPROXY_OTEL_SHA" \
    && rm -rf /opt/haproxy-opentelemetry/.git

WORKDIR /opt/opentelemetry-c-wrapper/scripts/build

RUN ./build-bundle.sh /opt

WORKDIR /opt/opentelemetry-c-wrapper

RUN ./scripts/bootstrap && \
    ./configure --prefix=/opt --with-opentelemetry=/opt && \
    make -j8 && \
    make install

RUN apt update

WORKDIR /opt/haproxy

FROM deps AS runtime

RUN PKG_CONFIG_PATH=/opt/lib/pkgconfig make -j8 TARGET=linux-glibc EXTRA_MAKE=/opt/haproxy-opentelemetry OTEL_USE_VARS=1

RUN cp /opt/haproxy/haproxy /usr/local/sbin/haproxy

# Create haproxy user and group for security
RUN groupadd -r haproxy && \
    useradd -r -g haproxy -s /sbin/nologin -c "HAProxy user" haproxy && \
    chown haproxy:haproxy /tmp && \
    chmod 1777 /tmp

COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY otel.cfg /usr/local/etc/haproxy/otel.cfg
COPY docker-entrypoint.sh /usr/local/etc/haproxy/docker-entrypoint.sh

ENTRYPOINT ["/bin/sh", "/usr/local/etc/haproxy/docker-entrypoint.sh"]
CMD ["/usr/local/sbin/haproxy", "-W", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
```

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
| `otlp_file` | File (rotating) | Pattern `__ctx_<signal>_log-%F-%N` |
| `ostream` | stdout stream | `__ctx_<signal>` |
| `memory` | In-memory buffer | 256-entry ring buffer |

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
