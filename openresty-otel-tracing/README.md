# Instana OpenResty OTel Tracing Demo

This directory demonstrates Instana integration with [OpenResty](https://openresty.org/) OpenTelemetry tracing functionality
based on [OpenTelemetry (OTel)](https://opentelemetry.io/).

OpenResty is basically [NGINX](https://nginx.org/) enhanced by the [Lua programming language](https://www.lua.org/).

This demo contains the Spring Boot services `client-app` and `server-app`, which are traced by the Instana agent
using the native Java instrumentation.
OpenResty is located between these services and proxies their HTTP requests.

The OpenResty instrumentation is based on the Instana variant of the [NGINX OpenTelemetry (nginx-otel) module](https://github.com/nginx/nginx-otel)
and a [lua-resty-http greater or equal 0.18.0](https://github.com/ledgetech/lua-resty-http/releases/tag/v0.18.0) with added W3C `traceparent` header support.

NGINX OTel traces are sent to the [Instana distribution of OTel collector (IDOT)](https://github.com/instana/instana-otel-collector) via gRPC to port 4317.
The collector forwards them to the Instana backend via the [OpenTelemetry protocol (OTLP)](https://opentelemetry.io/docs/specs/otel/protocol/) HTTP.

**Note:** Instana support does not cover the `lua-resty-http` OpenSource project, any other Lua HTTP client, the NGINX Lua module, NGINX, or OpenResty.
Please refer to the support options of those projects in case you need help with those.

**Note:** This demo has been created under a very controlled environment. Customization and your own Lua code are out of Instana scope.

## Prerequisites

[Docker](https://docs.docker.com/get-docker/) and [docker-compose](https://docs.docker.com/compose/install/) installed and running on your machine.

## Configure

Create a `.env` file in the root of this directory (copy from `.env.example`):

```bash
cp .env.example .env
```

Then fill in the values:

```text
agent_key=<agent secret key>
download_key=<download secret key (optional agent key with download privileges)>
agent_zone=<name of the zone for the agent; default: openresty-tracing-demo>
agent_endpoint=<local ip or remote host; e.g. ingress-red-saas.instana.io>
agent_endpoint_port=<443 already set as default; or 4443 for local>

# IDOT config:
INSTANA_OTEL_ENDPOINT_HTTP=<Instana OTLP HTTP endpoint; e.g. https://otlp-red-saas.instana.io:4318
INSTANA_HOST_NAME=<hostname used to identify collector entities>
INSTANA_HOST_ID=<host machine-id, used to stamp OTel spans with host.id>
```

The host's `/etc/machine-id` file is bind-mounted (read-only) into the OTel collector container:

```yaml
/etc/machine-id:/etc/machine-id:ro
```

The Instana agent is also configured with `pid: "host"` and `privileged: true` in `docker-compose.yml`,
which allows it to read the same `/etc/machine-id` directly and report the identical `host.id`.
The Instana backend therefore receives the same `host.id` from both the OTel collector and the agent,
confirming they are running on the same host and merging them into a single infrastructure entity.

## Build & Launch

```bash
docker-compose down && docker-compose up --build
```

This will build and launch the following components:

- `client-app` — a simple Spring Boot application that issues an HTTP request every second to OpenResty location `/openresty-otel-demo`
- `openresty` — which routes all incoming requests to the `server-app`
- `server-app` — a simple Spring Boot application that returns `200` to any HTTP request
- `client-app-lua` — same as `client-app`, but sends HTTP requests to the `lua-resty-http` target `/lua-otel-demo` of OpenResty instead
- `agent` — the Instana agent that traces `client-app` and `server-app` and forwards
  their spans to the Instana backend
- `collector` — the IDOT collector (`icr.io/instana/idot`) that receives
  OpenResty/NGINX spans over gRPC OTLP and forwards them to the Instana backend via OTLP HTTP

## Viewing in Instana

Once the stack is running and traces are flowing, you can locate the NGINX service in the Instana UI.

The NGINX service name is set by the `otel_service_name` directive in [`openresty/nginx.conf`](openresty/nginx.conf):

```nginx
# Service identity stamped on every span exported by this NGINX instance.
otel_service_name "openresty-otel-proxy";
```

Change this value to any name you prefer before starting the stack — the new name will appear in
Instana as the service name for all OpenResty/NGINX spans.

- **Applications** — open *Applications* and search for the service name **`openresty-otel-proxy`**
  (or whatever you set `otel_service_name` to) to see NGINX spans and end-to-end traces.
- **Analytics** — use the *Analytics* trace/span search and filter by `service.name = openresty-otel-proxy`
  (substituting your configured name) to query individual spans.
- **Infrastructure** — navigate to *Infrastructure* and filter by zone using the `agent_zone` value
  configured in `.env` (default: `openresty-tracing-demo`) to find the host where the Instana agent is running.

In the service dashboard, this appears as follows:

![Service dashboard](images/openresty-demo-1-service-dashboard.png)

In the flow graph, this appears as follows:

![Flow graph](images/openresty-demo-2-flow-graph.png)

In the analyze view for the `/lua-otel-demo` target, this appears as follows:

![Analyze view Lua](images/openresty-demo-3-analyze-lua.png)

In the analyze view for the regular NGINX `/openresty-otel-demo` target, this appears as follows:

![Analyze view NGINX](images/openresty-demo-4-analyze-nginx-otel.png)

## Setup an Application Perspective for the Demo

The simplest way is just to assign to the agent a unique zone (the `docker-compose.yml` file comes with the pre-defined `openresty-tracing-demo` zone), and simply create the application to contain all calls with the `agent.zone` tag to have the value `openresty-tracing-demo`.

## Edit the NGINX Configuration

* add loading of the Instana `nginx-otel` module
* add the upstream for proxying requests to the server-app
* add the OTel exporter config
* configure the Instana `nginx-otel` to be enabled with a service name
* configure a resolver for HTTP requests from `lua-resty-http`
* enable OTel trace context propagation for every location
* let `lua-resty-http` greater equal 0.18.0 do the W3C `traceparent` header handling for you automatically

See [openresty/nginx.conf](openresty/nginx.conf) for details.

## How SSL Variant Selection Works

The Instana NGINX OTel module ships two `.so` variants in one zip:

| File | For |
|---|---|
| `ngx_otel_module_ssl1.1x.so` |  OpenSSL 1.1.x |
| `ngx_otel_module_ssl3x.so`   |  OpenSSL 3.x   |

Both files are copied into the image. During the **Docker build**, the Dockerfile runs
`openssl version`. It is detected which variant matches the base image and creates the symlink
as a `RUN` step :

```dockerfile
RUN set -x; \
    ssl_ver=$(openssl version | awk '{print $2}'); \
    case "$ssl_ver" in \
      1.1.*) variant="ssl1.1x" ;; \
      3.*)   variant="ssl3x"   ;; \
      *) echo "ERROR: Unsupported OpenSSL version '${ssl_ver}'" >&2; exit 1 ;; \
    esac; \
    ln -s "/usr/local/lib/instana/ngx_otel_module_${variant}.so" \
          /usr/local/lib/instana/ngx_otel_module.so; \
    echo "Symlink: ngx_otel_module.so → ngx_otel_module_${variant}.so"
```

[`openresty/nginx.conf`](openresty/nginx.conf) always references the fixed symlink path
via `load_module /usr/local/lib/instana/ngx_otel_module.so;` — it never needs to know about SSL variants.

## Key Configuration Files

| File | Purpose |
|---|---|
| [`openresty/Dockerfile`](openresty/Dockerfile) | Multi-stage build: downloads both .so variants in stage 1; uses official OpenResty Docker image, detects OpenSSL version, and creates symlink in stage 2 |
| [`docker-compose.yml`](docker-compose.yml) | Service orchestration |
| [`openresty/nginx.conf`](openresty/nginx.conf) | OpenResty/NGINX main config with OTel directives; bind-mounted into the container |
| [`collector/config.yaml`](collector/config.yaml) | [IDOT collector](https://github.com/instana/instana-otel-collector) pipeline config |
| [`agent/configuration.yaml`](agent/configuration.yaml) | Instana agent config |
| [`.env.example`](.env.example) | Template for the required `.env` file |

## Trace Context Propagation

The NGINX OTel module uses `otel_trace_context propagate` which:

1. **Extracts** the W3C `traceparent` injected by the Instana Java traces on `client-app`
2. Creates a **child span** under the client's trace (same traceId, new NGINX spanId)
3. **Injects** a new `traceparent` carrying NGINX's spanId into the upstream request to `server-app`

For Lua code, `lua-resty-http` >= 0.18.0 propagates the `traceparent` header updated by Instana `nginx-otel` further.
