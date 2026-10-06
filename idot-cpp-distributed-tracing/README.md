# IDOT OpenTelemetry C++ — Distributed Tracing Demo

This sample shows how a C++ application instrumented with the **IDOT OpenTelemetry C++ library** participates in an end-to-end distributed trace with Java services.

The C++ service uses the IDOT library for manual instrumentation. The Java services use automatic instrumentation provided by the agent attached to their JVMs. The services participate in the same distributed trace by propagating the W3C traceparent context between services.

```
  curl http://localhost:8082/order
           │
           │ HTTP
           ▼
  ┌─────────────────────┐
  │   java-caller       │  Spring Boot — auto-instrumented
  │   :8082             │
  └──────────┬──────────┘
             │ HTTP + W3C traceparent
             ▼
  ┌─────────────────────┐
  │   cpp-service       │  IDOT OpenTelemetry C++ library
  │   :8080             │  Manual instrumentation
  └──────────┬──────────┘
             │ HTTP + W3C traceparent
             ▼
  ┌─────────────────────┐
  │   java-receiver     │  Spring Boot — auto-instrumented
  │   :8081             │
  └──────────┬──────────┘
             │ OTLP/gRPC
             ▼
       OpenTelemetry Collector / Instana Agent
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
   └─ cpp-service  HTTP GET http://localhost:8081/ping  CLIENT
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
| OpenTelemetry Collector or Instana Agent | OTLP/gRPC endpoint available on port `4317` |

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

## Step 2 — Run

```bash
./run.sh
```

All three processes start in the background and write logs to `logs/`:

| Process | Port | Log |
|---|---|---|
| `java-caller` | 8082 | `logs/java-caller.log` |
| `cpp-service` | 8080 | `logs/cpp-service.log` |
| `java-receiver` | 8081 | `logs/java-receiver.log` |

---

## Step 3 — Trigger a trace

```bash
curl http://localhost:8082/order
```

Expected response:
```
order processed — notify: pong
```

To generate continuous traffic (one request every 5 seconds):

```bash
./stop.sh
SCHEDULE_ENABLED=true ./run.sh
```

---

## Step 4 — View traces

Open your trace backend and search for service `cpp-service` or the `ProcessOrder` operation. The waterfall shows all three services linked under one trace ID.

---

## What to verify

After triggering a request, verify that:

- `java-caller`, `cpp-service`, and `java-receiver` appear in the same trace.
- The C++ spans are created by the IDOT OpenTelemetry C++ library.
- The `traceparent` context is propagated from Java → C++ → Java.
- The `ProcessOrder` span contains the child spans shown in the span tree above.
- The trace is exported through OTLP/gRPC to the configured backend.

---

## Step 5 — Stop

```bash
./stop.sh
```

---

## Sending spans to Instana

If you are using an **Instana Agent** instead of a standalone OpenTelemetry Collector, enable OTLP on the agent by adding the following to `<instana-agent-config-dir>/configuration.yaml`:

```yaml
com.instana.plugin.opentelemetry:
  grpc:
    enabled: true
```

Restart the agent, then point the demo at it:

```bash
CPP_OTLP_ENDPOINT=<agent-host>:4317 ./run.sh
```

Two instrumentation modes are supported for the Java services:

- **Instana Agent mode** — when the Instana Agent is running locally, it instruments the Java services via JVM auto-attach. No `-javaagent` flag is needed.
- **Standalone OTel mode** — the Dockerfiles in this repo use the OpenTelemetry Java Agent directly, for environments where no Instana Agent is present.

### View in Instana UI

1. Open **Analytics → Calls**
2. Filter by **Service = `cpp-service`**
3. Click a **`ProcessOrder`** call to open the trace waterfall

