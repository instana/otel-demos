# IDOT OpenTelemetry C++ — Distributed Tracing Demo

This sample shows how a C++ application instrumented with the **IDOT OpenTelemetry C++ library** participates in an end-to-end distributed trace with Java services.

The C++ service uses the IDOT library for manual instrumentation. The Java services use automatic instrumentation provided by the agent attached to their JVMs. The services participate in the same distributed trace by propagating the W3C traceparent context between services.

```
  curl http://<caller-host>:<caller-port>/order
           │
           │ HTTP
           ▼
  ┌─────────────────────┐
  │   java-caller       │  Spring Boot — auto-instrumented
  │   :<caller-port>    │
  └──────────┬──────────┘
             │ HTTP + W3C traceparent
             ▼
  ┌─────────────────────┐
  │   cpp-service       │  IDOT OpenTelemetry C++ library
  │   :<cpp-port>       │  Manual instrumentation
  └──────────┬──────────┘
             │ HTTP + W3C traceparent
             ▼
  ┌─────────────────────┐
  │   java-receiver     │  Spring Boot — auto-instrumented
  │   :<receiver-port>  │
  └──────────┬──────────┘
             │ OTLP/gRPC
             ▼
  OpenTelemetry Collector / Backend Endpoint
```

---

## What this demo shows

The focus is [`cpp-service/src/main.cpp`](cpp-service/src/main.cpp). It demonstrates the core IDOT C++ library features needed to participate in a distributed trace:

- **Initialise** an OTLP/gRPC exporter and `TracerProvider` with resource attributes
- **Extract** the incoming W3C `traceparent` header from `java-caller` to join its trace
- **Create spans** with appropriate kinds (`SERVER`, `CLIENT`, `INTERNAL`, `PRODUCER`), attributes, and events
- **Inject** a `traceparent` header into the outgoing call to `java-receiver`
- **Shut down** gracefully with `ForceFlush` to ensure all spans are exported

The Java services are plain Spring Boot applications and require no manual instrumentation. The agent instruments them automatically.

> **Note on simulated spans:** `ReadCustomerDB`, `ChargePayment`, and `PublishShipment` do not connect to real external systems. They are included to demonstrate the correct OpenTelemetry semantic attributes for database, RPC, and messaging operations.

---

## Span tree per request

Each `GET /order` produces a trace waterfall like this:

```
java-caller   GET /order                              SERVER  (auto-instrumented)
│
└─ cpp-service  ProcessOrder                          SERVER
   ├─ cpp-service  ValidateOrder                      INTERNAL
   ├─ cpp-service  ReadCustomerDB                     CLIENT   (simulated)
   ├─ cpp-service  ChargePayment                      CLIENT   (simulated)
   ├─ cpp-service  UpdateInventory                    INTERNAL
   ├─ cpp-service  PublishShipment                    PRODUCER (simulated)
   └─ cpp-service  HTTP GET http://<receiver-host>:<receiver-port>/ping  CLIENT
      │
      └─ java-receiver  GET /ping                     SERVER   (auto-instrumented)
```

---

## Project structure

```
idot-cpp-distributed-tracing/
├── build.sh                     — build all three services
├── run.sh                       — start all three services
├── stop.sh                      — stop all running services
│
├── cpp-service/                 ← IDOT C++ instrumentation is here
│   ├── CMakeLists.txt
│   ├── vendor/httplib.h         — vendored header-only HTTP server
│   └── src/main.cpp             — full IDOT C++ instrumentation example
│
├── java-caller/                 — Spring Boot, exposes GET /order
│   ├── pom.xml
│   └── src/main/java/com/instana/demo/CallerApplication.java
│
└── java-receiver/               — Spring Boot, answers GET /ping
    ├── pom.xml
    └── src/main/java/com/instana/demo/ReceiverApplication.java
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| GCC 9+ / g++ | `g++ --version` |
| CMake 3.16+ | `cmake --version` |
| libcurl dev headers | e.g. `apt install libcurl4-openssl-dev` (Debian/Ubuntu) or equivalent for your OS |
| IDOT OpenTelemetry C++ package | Extracted at `<path-to-idot-package>` — set via `IDOT_INSTALL` env var |
| Java 8+ | `java -version` |
| Maven 3.6+ | `mvn --version` |
| OpenTelemetry Collector / OTLP backend | OTLP/gRPC endpoint available on `<collector-host>:<collector-port>` |

---

## Step 1 — Build

```bash
cd idot-cpp-distributed-tracing
./build.sh
```

Set the IDOT package path via the `IDOT_INSTALL` environment variable:

```bash
IDOT_INSTALL=/path/to/idot-package ./build.sh
```

---

## Step 2 — Configuration & Environment Variables

The demo services can be configured via environment variables.

### Environment Variables Reference

| Variable | Description | Value / Format |
|---|---|---|
| `CPP_OTLP_ENDPOINT` | OTLP/gRPC target endpoint for `cpp-service` (e.g., OpenTelemetry Collector, telemetry agent, or observability backend). | `<collector-host>:<collector-port>` |
| `OTEL_SERVICE_NAME` | Logical service name emitted in the trace resource attributes. | `<service-name>` |
| `IDOT_INSTALL` | Root directory of the extracted IDOT OpenTelemetry C++ package. | `<path-to-idot-install>` |
| `SCHEDULE_ENABLED` | When `true`, `java-caller` automatically issues a test request every 5 seconds. Set to `false` for manual testing via `curl`. | `true` \| `false` |
| `SERVER_PORT` | HTTP listening port for `cpp-service`. | `<cpp-port>` |
| `JAVA_RECEIVER_URL` | Downstream endpoint URL that `cpp-service` calls. | `http://<receiver-host>:<receiver-port>` |
| `CPP_SERVICE_URL` | Target URL used by `java-caller` to forward `/order` requests. | `http://<cpp-host>:<cpp-port>` |

---

## Step 3 — Run

Start all three services in the background:

```bash
./run.sh
```

To configure specific endpoints or disable automated scheduling:

```bash
# Example: Send traces to a remote OpenTelemetry Collector or backend
CPP_OTLP_ENDPOINT=<collector-host>:<collector-port> ./run.sh

# Example: Disable automatic scheduling for manual testing
SCHEDULE_ENABLED=false ./run.sh

# Example: Custom endpoints and ports
IDOT_INSTALL=<path-to-idot-package> \
CPP_OTLP_ENDPOINT=<collector-host>:<collector-port> \
./run.sh
```

All three processes write logs to the `logs/` directory:

| Process | Port | Log |
|---|---|---|
| `java-caller` | `<caller-port>` | `logs/java-caller.log` |
| `cpp-service` | `<cpp-port>` | `logs/cpp-service.log` |
| `java-receiver` | `<receiver-port>` | `logs/java-receiver.log` |

---

## Step 4 — Trigger a trace

```bash
curl http://<caller-host>:<caller-port>/order
```

Expected response:
```
order processed — notify: pong
```

---

## Step 5 — View traces

Open your observability backend or trace visualization UI and search for service `cpp-service` (or your configured `OTEL_SERVICE_NAME`) or the `ProcessOrder` operation. The waterfall displays all three services linked under a single unified trace ID.

---

## What to verify

After triggering a request, verify that:

- `java-caller`, `cpp-service`, and `java-receiver` appear in the same trace.
- The C++ spans are created by the IDOT OpenTelemetry C++ library.
- The `traceparent` context is propagated from Java → C++ → Java.
- The `ProcessOrder` span contains the expected child spans and operations.
- Telemetry spans are exported through OTLP/gRPC to the configured collector or backend.

---

## Step 6 — Stop

```bash
./stop.sh
```

---

## Connecting to an OpenTelemetry Collector or Backend

This demo exports standard OpenTelemetry data over OTLP/gRPC. It is compatible with any OpenTelemetry Collector, telemetry proxy, or compliant observability platform.

To point `cpp-service` to your collector or backend:

```bash
CPP_OTLP_ENDPOINT=<collector-host>:<collector-port> ./run.sh
```

### Collector Configuration (OTLP gRPC Receiver)

If running an OpenTelemetry Collector, ensure the OTLP gRPC receiver is configured with your desired endpoint:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: <collector-bind-address>:<collector-port>
```

### Viewing Traces in your Observability Platform

1. Open your observability / trace analysis UI.
2. Filter by service name (e.g., `service.name = cpp-service`) or endpoint (e.g., `ProcessOrder`).
3. Click on the trace entry to open the full distributed trace waterfall.

