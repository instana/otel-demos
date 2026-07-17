# haproxy-otel-tracing

This repository demonstrates Instana's [HAProxy](https://www.haproxy.org/) tracing functionality
based on [OpenTelemetry](https://opentelemetry.io/).

HAProxy OTel traces are sent to the **Instana idot OTel collector** via gRPC to port 4317.
The collector forwards them to the Instana backend via OTLP HTTP.
The `client-app` and `server-app` Spring Boot services are traced by the **Instana agent**
using the native Java instrumentation.

## Prerequisites

[Docker](https://docs.docker.com/get-docker/) and [docker-compose](https://docs.docker.com/compose/install/) installed and running on your machine.

## Configure

Create a `.env` file in the root of the checked-out version of this repository and enter
the following content. The values need to be adjusted to your environment.

```text
agent_key=<agent secret key>
download_key=<download secret key (optional agent key with download privileges)>
agent_zone=<name of the zone for the agent; default: haproxy-tracing-demo>
agent_endpoint=<local ip or remote host; e.g. ingress-red-saas.instana.io>
agent_endpoint_port=<443 already set as default; or 4443 for local>

INSTANA_OTEL_ENDPOINT_HTTP=<Instana OTLP HTTP endpoint>; https://<unit>.instana.io:443
INSTANA_HOST_NAME=<hostname used to correlate agent and collector entities>
INSTANA_HOST_ID=<host machine-id, used to stamp OTel spans with host.id>
```

In most scenarios only `agent_key`, `agent_endpoint`, `INSTANA_KEY`, and
`INSTANA_OTEL_ENDPOINT_HTTP` are required.

## Build & Launch

```bash
docker-compose down && docker-compose up --build
```

This will build and launch the following components:

- `client-app` — a simple Spring Boot application that issues an HTTP request every second,
  traced by the **Instana Java agent**.
- `haproxy` — routes all incoming requests to `server-app`, instrumented with the
  **HAProxy OpenTelemetry filter** which sends spans to the idot collector via gRPC (port 4317).
- `server-app` — a simple Spring Boot application that returns `200` to any HTTP request,
  traced by the **Instana Java agent**.
- `agent` — the **Instana agent** that traces `client-app` and `server-app` and forwards
  their spans to the Instana backend.
- `collector` — the **Instana idot OTel collector** (`icr.io/instana/idot`) that receives
  HAProxy spans over gRPC OTLP and forwards them to the Instana backend via OTLP HTTP.

## Trace Flow

```
client-app: recurrent-task (ENTRY span)
  └─ client-app: HTTP GET http://haproxy:10080
      └─ haproxy-front-proxy: HAProxy request
          └─ server-app: HTTP GET /
```

## Key Configuration Files

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | Service orchestration |
| [`haproxy/haproxy.cfg`](haproxy/haproxy.cfg) | HAProxy main config with OTel filter |
| [`haproxy/otel.cfg`](haproxy/otel.cfg) | OTel span extraction / injection rules |
| [`haproxy/otel.yml.template`](haproxy/otel.yml.template) | OTel exporter & propagator config template |
| [`collector/config.yaml`](collector/config.yaml) | idot collector pipeline config |
| [`agent/configuration.yaml`](agent/configuration.yaml) | Instana agent config |