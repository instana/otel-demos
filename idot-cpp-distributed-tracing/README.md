# IDOT OpenTelemetry C++ — Distributed Tracing Sample

This sample shows how a C++ service instrumented with the **IDOT OpenTelemetry C++ SDK** participates in an end-to-end distributed trace together with Java services. When you send a single HTTP request, all three services produce spans that appear under one shared trace ID in your observability backend.

---

## Table of contents

1. [What is distributed tracing?](#what-is-distributed-tracing-and-why-does-it-matter)
2. [How it works](#how-it-works)
3. [Prerequisites](#prerequisites)
4. [Quick start](#quick-start)
5. [Step 0 — Set up your collector or backend](#step-0--set-up-your-collector-or-backend)
6. [Step 1 — Build](#step-1--build)
7. [Step 2 — Start the services](#step-2--start-the-services)
8. [Step 3 — Trigger a trace](#step-3--trigger-a-trace)
9. [Step 4 — View and verify traces](#step-4--view-and-verify-traces)
10. [Step 5 — Stop](#step-5--stop)
11. [Environment variables reference](#environment-variables-reference)
12. [Project structure](#project-structure)
13. [Span tree](#span-tree)
14. [What the sample covers](#what-the-sample-covers)
15. [Applying this to your own C++ service](#applying-this-to-your-own-c-service)
16. [Troubleshooting](#troubleshooting)

---

## What is distributed tracing and why does it matter?

In a microservices or multi-language architecture, a single user request typically crosses several services — a gateway, a business logic service, a database proxy, a notification service. When something goes wrong or is slow, a traditional log search tells you only what each individual service saw in isolation. You cannot easily answer:

- Which service in the call chain is responsible for the latency?
- Did the C++ service call the downstream Java service successfully, and how long did it take?
- Did a database query inside the C++ service time out, or did the problem originate upstream?

**Distributed tracing** solves this by stitching together the work done across all services into a single, end-to-end **trace**. Each unit of work is recorded as a **span**. Spans carry a shared **trace ID** so your observability backend can reconstruct the full call graph — showing you every service, every operation, and how long each one took, all in one view.

### How trace context is carried between services — W3C `traceparent`

The mechanism that links spans across service boundaries is context propagation. This sample uses the **W3C Trace Context** standard, which defines a single HTTP header:

```
traceparent: 00-<traceId>-<parentSpanId>-<flags>
```

| Field | What it contains |
|---|---|
| `traceId` | A 16-byte (32 hex character) ID unique to the entire request chain. Every span in the trace shares this ID. |
| `parentSpanId` | The span ID of the caller's span. This is how the backend knows which span is the parent of which. |
| `flags` | Sampling flags (`01` = sampled). |

When `java-caller` calls `cpp-service`, the OTel Java Agent automatically injects this header into the outgoing HTTP request. `cpp-service` reads the header, extracts the trace context, and creates its spans as children of the caller's span — preserving the same `traceId`. When `cpp-service` then calls `java-receiver`, it injects a new `traceparent` carrying the same `traceId` and its own `spanId` as the parent. The result is a single connected trace visible in your backend.

---

## How it works

```
  curl http://<host>:8082/order
           │
           │ HTTP GET /order
           ▼
  ┌─────────────────────┐
  │   java-caller       │  Spring Boot — OTel Java Agent (auto-instrumented)
  └──────────┬──────────┘
             │ HTTP GET /order  +  W3C traceparent header
             ▼
  ┌─────────────────────┐
  │   cpp-service       │  IDOT OpenTelemetry C++ SDK — manual instrumentation
  └──────────┬──────────┘
             │ HTTP GET /ping  +  W3C traceparent header
             ▼
  ┌─────────────────────┐
  │   java-receiver     │  Spring Boot — OTel Java Agent (auto-instrumented)
  └──────────┬──────────┘
             │ OTLP/gRPC  (all three services export independently)
             ▼
  OpenTelemetry Collector / Backend (e.g. <collector-host>:<grpc-port>)
```

Each service exports its own spans to the configured OTLP/gRPC endpoint. The W3C `traceparent` header carries the trace context from service to service so all spans share the same trace ID.

---

## Prerequisites

The C++ source code (`main.cpp`) and its build system (`CMakeLists.txt`) support **Windows**, **Linux**, and **AIX**.

| Platform | Build script | Run script | Stop script |
|---|---|---|---|
| Linux / AIX | `build.sh` (Bash) | `run.sh` (Bash) | `stop.sh` (Bash) |
| Windows | `build.ps1` (PowerShell) | `run.ps1` (PowerShell) | `stop.ps1` (PowerShell) |

### Software requirements

| Requirement | Minimum version | Notes |
|---|---|---|
| C++ compiler | C++17 capable | Linux: GCC (`g++ --version`) · AIX: XL C++ or GCC from AIX Toolbox · Windows: MSVC via **Developer PowerShell for VS 2022** |
| CMake | 3.16 | `cmake --version` — available from AIX Toolbox on AIX |
| Bash | 4.0 or later | Linux/AIX only. AIX ships `/bin/sh` (ksh) — install Bash from AIX Toolbox: `rpm -i bash-*.rpm` |
| libcurl | any | Linux: `dnf install libcurl-devel` or `apt install libcurl4-openssl-dev` · AIX: `rpm -i curl-devel-*.rpm` · Windows: must be an **MSVC build** — see [Windows curl note](#windows-curl-note) below |
| IDOT OpenTelemetry C++ SDK | — | An installed or extracted SDK directory. Set via `IDOT_OTEL_CPP_INSTALL`. See [SDK directory layout](#sdk-directory-layout-by-platform). |
| Java | 8 or later | `java -version` |
| Maven | 3.6 or later | `mvn --version` |
| OpenTelemetry Java Agent JAR | — | Download once from [opentelemetry-java-instrumentation releases](https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases). Set path via `OTEL_AGENT`. |
| OTLP/gRPC backend or collector | — | Must be running **before** the services start. See [Step 0](#step-0--set-up-your-collector-or-backend). |

### SDK directory layout by platform

The IDOT OpenTelemetry C++ SDK install directory structure differs by platform. CMake locates headers and libraries through `IDOT_OTEL_CPP_INSTALL`; the shared libraries must also be on the runtime library search path.

| Platform | CMake config file location | Shared library location | Runtime path variable |
|---|---|---|---|
| Linux | `$IDOT_OTEL_CPP_INSTALL/lib64/cmake/opentelemetry-cpp/` | `$IDOT_OTEL_CPP_INSTALL/lib64/` | `LD_LIBRARY_PATH` |
| AIX | `$IDOT_OTEL_CPP_INSTALL/lib/cmake/opentelemetry-cpp/` | `$IDOT_OTEL_CPP_INSTALL/lib/` | `LIBPATH` |
| Windows | `%IDOT_OTEL_CPP_INSTALL%\lib\cmake\opentelemetry-cpp\` | `%IDOT_OTEL_CPP_INSTALL%\bin\` | `PATH` (set by `run.ps1`) |

> If your SDK layout differs from the table above, pass the correct path directly to CMake: `cmake -B build -DCMAKE_PREFIX_PATH=<path>`.

### Windows curl note

Prebuilt packages from [curl.se/windows](https://curl.se/windows/) are **MinGW/GCC builds** — they contain `.dll.a` / `.a` import libraries, **not** `.lib` files. MSVC's linker cannot use them. You have two options:

- **Build curl from source** in Developer PowerShell using CMake — this produces a native `libcurl.lib` and `libcurl.dll`.
- **Use vcpkg** — `vcpkg install curl:x64-windows` downloads, builds, and installs an MSVC-native curl automatically.

After building, `libcurl.dll` and `opentelemetry_cpp.dll` are both copied next to `cpp-service.exe` automatically as part of the CMake post-build step.

---

## Quick start

If you already have all prerequisites in place, here is the minimal command sequence for each platform. If you are setting up for the first time, follow the numbered steps starting at [Step 0](#step-0--set-up-your-collector-or-backend) instead.

### Linux / AIX

```bash
# 1. Download the OpenTelemetry Java Agent (once)
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar

# 2. Build all three services
cd idot-cpp-distributed-tracing
IDOT_OTEL_CPP_INSTALL=<path-to-opentelemetry-cpp> ./build.sh

# 3. Start your collector or backend first, then start the services
IDOT_OTEL_CPP_INSTALL=<path-to-opentelemetry-cpp> \
OTEL_AGENT=<path-to-opentelemetry-javaagent.jar> \
CPP_OTLP_ENDPOINT=<collector-host>:<grpc-port> \
JAVA_OTLP_ENDPOINT=http://<collector-host>:<grpc-port> \
./run.sh

# 4. Trigger a trace (wait ~20 s for the JVMs to start)
curl http://$(hostname -f):8082/order

# 5. Stop all services
./stop.sh
```

### Windows (Developer PowerShell for VS 2022)

```powershell
# 1. Download the OpenTelemetry Java Agent (once)
Invoke-WebRequest `
  -Uri "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar" `
  -OutFile "$HOME\Downloads\opentelemetry-javaagent.jar"

# 2. Build all three services
cd idot-cpp-distributed-tracing
$env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
$env:CURL_INCLUDE_DIR       = "<path-to-curl>\include"
$env:CURL_LIBRARY           = "<path-to-curl>\lib\libcurl.lib"
.\build.ps1

# 3. Start your collector or backend first, then start the services
$env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
$env:OTEL_AGENT             = "$HOME\Downloads\opentelemetry-javaagent.jar"
$env:CPP_OTLP_ENDPOINT      = "<collector-host>:<grpc-port>"
$env:JAVA_OTLP_ENDPOINT     = "http://<collector-host>:<grpc-port>"
.\run.ps1

# 4. Trigger a trace (wait ~20 s for the JVMs to start)
curl.exe http://localhost:8082/order

# 5. Stop all services
.\stop.ps1
```

See [Environment variables reference](#environment-variables-reference) for a full description of each variable.

---

## Step 0 — Set up your collector or backend

> **This step must be completed before starting the services.** If no OTLP/gRPC listener is running at the configured endpoint when `cpp-service` starts, the gRPC channel will log `Connection refused` errors. The channel reconnects automatically once the collector is up, but starting it first avoids the noise.

This sample exports spans over **OTLP/gRPC** and works with any OpenTelemetry-compatible backend.

### Option A — Collector on the same host (simplest)

Install an OTLP-capable agent or collector on the same machine. It must listen on `<grpc-port>` (default `4317`) for OTLP/gRPC. Examples:

- **OpenTelemetry Collector** — [opentelemetry.io/docs/collector](https://opentelemetry.io/docs/collector/)
- **IBM Instana agent** — [Installing host agents](https://www.ibm.com/docs/en/instana-observability?topic=agents-installing-host); accepts OTLP on port 4317 by default
- **Jaeger** (v1.35+) — accepts OTLP/gRPC directly on port 4317

Verify the collector is listening on `<grpc-port>` before proceeding:

| Platform | Command |
|---|---|
| Linux | `nc -zv <collector-host> <grpc-port>` |
| AIX | `netstat -an \| grep <grpc-port>` |
| Windows | `Test-NetConnection <collector-host> -Port <grpc-port>` |

### Option B — Remote collector

If the collector is on a different host, set `CPP_OTLP_ENDPOINT` and `JAVA_OTLP_ENDPOINT` when you start the services in [Step 2](#step-2--start-the-services).

For a standalone OpenTelemetry Collector, a minimal configuration that receives OTLP/gRPC and forwards to a backend is:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:<grpc-port>"

exporters:
  otlp/backend:
    endpoint: "<backend-host>:<port>"
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlp/backend]
```

Replace `otlp/backend` with the exporter for your backend (Jaeger, Zipkin, a SaaS platform, etc.). See the [OpenTelemetry Collector documentation](https://opentelemetry.io/docs/collector/) for all available exporters.

---

## Step 1 — Build

Before building, ensure all [software requirements](#software-requirements) are met and `IDOT_OTEL_CPP_INSTALL` points to your SDK directory.

### Linux

```bash
cd idot-cpp-distributed-tracing
IDOT_OTEL_CPP_INSTALL=<path-to-opentelemetry-cpp> ./build.sh
```

### AIX

`OBJECT_MODE=64` selects the 64-bit toolchain and must be exported before building.

```bash
export OBJECT_MODE=64
cd idot-cpp-distributed-tracing
IDOT_OTEL_CPP_INSTALL=<path-to-opentelemetry-cpp> ./build.sh
```

### Windows

Open **Developer PowerShell for VS 2022** (*Start → Visual Studio 2022 → Developer PowerShell for VS 2022*).

> **Execution policy:** If you see `cannot be loaded because running scripts is disabled`, run once:
> `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`

Supply the paths to your MSVC-built curl (see [Windows curl note](#windows-curl-note)):

```powershell
$env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
$env:CURL_INCLUDE_DIR       = "<path-to-curl>\include"
$env:CURL_LIBRARY           = "<path-to-curl>\lib\libcurl.lib"
.\build.ps1
```

Or pass them directly as parameters:

```powershell
.\build.ps1 -IdotOtelCppInstall "<path-to-opentelemetry-cpp>" `
            -CurlIncludeDir     "<path-to-curl>\include" `
            -CurlLibrary        "<path-to-curl>\lib\libcurl.lib"
```

### What gets built

All three platforms produce the same three artefacts:

| # | Service | Output (Linux/AIX) | Output (Windows) |
|---|---|---|---|
| 1 | `java-caller` | `java-caller/target/java-caller-1.0.0.jar` | `java-caller\target\java-caller-1.0.0.jar` |
| 2 | `java-receiver` | `java-receiver/target/java-receiver-1.0.0.jar` | `java-receiver\target\java-receiver-1.0.0.jar` |
| 3 | `cpp-service` | `cpp-service/build/cpp-service` | `cpp-service\build\Release\cpp-service.exe` |

On Windows, `libcurl.dll` and `opentelemetry_cpp.dll` are automatically copied next to `cpp-service.exe` by CMake post-build steps.

Once the build succeeds, proceed to [Step 2](#step-2--start-the-services).

---

## Step 2 — Start the services

> **Prerequisite:** Complete [Step 0](#step-0--set-up-your-collector-or-backend) — your collector or backend must be running before starting the services.

The run scripts start all three services in the correct order (`java-receiver` → `cpp-service` → `java-caller`) and redirect each service's output to a log file under `logs/`.

### Linux and AIX — collector on the same host

```bash
IDOT_OTEL_CPP_INSTALL=<path-to-opentelemetry-cpp> \
OTEL_AGENT=<path-to-opentelemetry-javaagent.jar> \
./run.sh
```

### Linux and AIX — remote collector

```bash
IDOT_OTEL_CPP_INSTALL=<path-to-opentelemetry-cpp> \
OTEL_AGENT=<path-to-opentelemetry-javaagent.jar> \
CPP_OTLP_ENDPOINT=<collector-host>:<grpc-port> \
JAVA_OTLP_ENDPOINT=http://<collector-host>:<grpc-port> \
./run.sh
```

### Linux and AIX — continuous traffic (enable the automatic scheduler)

```bash
IDOT_OTEL_CPP_INSTALL=<path-to-opentelemetry-cpp> \
OTEL_AGENT=<path-to-opentelemetry-javaagent.jar> \
SCHEDULE_ENABLED=true \
./run.sh
```

### Windows

`run.ps1` starts each service as a background process using `System.Diagnostics.Process`, redirects stdout and stderr to `logs\`, and writes `.pids.json` so `stop.ps1` can terminate the correct processes. It also adds `$IdotOtelCppInstall\bin` to `PATH` for the SDK DLLs.

**Collector on the same host:**
```powershell
$env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
$env:OTEL_AGENT             = "<path-to-opentelemetry-javaagent.jar>"
.\run.ps1
```

**Remote collector:**
```powershell
$env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
$env:OTEL_AGENT             = "<path-to-opentelemetry-javaagent.jar>"
$env:CPP_OTLP_ENDPOINT      = "<collector-host>:<grpc-port>"
$env:JAVA_OTLP_ENDPOINT     = "http://<collector-host>:<grpc-port>"
.\run.ps1
```

**Continuous traffic (automatic scheduler):**
```powershell
$env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
$env:OTEL_AGENT             = "<path-to-opentelemetry-javaagent.jar>"
.\run.ps1 -ScheduleEnabled $true
```

### Confirming all services are up

After starting, check the logs before sending requests. Each service writes to `logs/`:

| Service | Port | Log file | Ready when you see |
|---|---|---|---|
| `java-receiver` | `8081` | `logs/java-receiver.log` | `Started ReceiverApplication in ...` |
| `cpp-service` | `8080` | `logs/cpp-service.log` | `Listening on :8080 — waiting for requests from java-caller...` |
| `java-caller` | `8082` | `logs/java-caller.log` | `Started CallerApplication in ...` |

> **The JVM takes ~20 seconds to start.** Wait for all three "ready" lines before proceeding to [Step 3](#step-3--trigger-a-trace).
>
> Monitor in real time:
> - **Linux/AIX:** `tail -f logs/java-caller.log`
> - **Windows:** `Get-Content logs\java-caller.log -Wait`

---

## Step 3 — Trigger a trace

Once all three services are up (see [Confirming all services are up](#confirming-all-services-are-up)), send a single request to `java-caller`:

**Linux / AIX:**
```bash
curl http://$(hostname -f):8082/order
```

**Windows:**
```powershell
curl.exe http://localhost:8082/order
```

Expected response:
```
order processed — notify: pong
```

The `cpp-service` log immediately prints the extracted and injected `traceparent` values, confirming context propagation across all three services:

```
[cpp-service] Extracted traceparent from java-caller : 00-<traceId>-<spanId>-01
[cpp-service] Injected  traceparent into java-receiver: 00-<traceId>-<spanId>-01
```

The trace ID is identical in both lines — that is the single trace ID shared by `java-caller`, `cpp-service`, and `java-receiver` in your backend.

Once you see the expected response, proceed to [Step 4](#step-4--view-and-verify-traces).

---

## Step 4 — View and verify traces

Open your observability backend and filter by `service.name = cpp-service` or operation name `ProcessOrder`. The trace waterfall should show all three services linked under a single trace ID.

The screenshot below shows an example trace as it appears in IBM Instana. The same end-to-end waterfall is visible in any OTLP-compatible backend (Jaeger, Zipkin, Grafana Tempo, etc.).

![Distributed trace waterfall showing all three services — java-caller, cpp-service, and java-receiver — linked under a single trace ID](images/distributed_tracing.jpg)

*End-to-end distributed trace (IBM Instana). The `ProcessOrder` SERVER span in `cpp-service` contains all expected child spans: `ValidateOrder` (INTERNAL, 8ms), `ReadCustomerDB` (DATABASE, 22ms), `ChargePayment` (RPC, 35ms), `UpdateInventory` (INTERNAL, 12ms), `PublishShipment` (MESSAGING, 18ms), and `GET /ping` (HTTP, 9ms) — which continues the trace into `java-receiver`. Total root call latency: ~111ms.*

**Confirm the following:**

- `java-caller`, `cpp-service`, and `java-receiver` appear in the same trace under one trace ID.
- The span tree matches the structure shown in [Span tree](#span-tree).
- The `traceparent` header carries the same trace ID Java → C++ → Java (visible in the `cpp-service` log output).
- `cpp-service` spans carry the attribute `service.name = cpp-service`.
- All spans are exported to the configured OTLP/gRPC endpoint.

---

## Step 5 — Stop

### Linux and AIX

```bash
./stop.sh
```

### Windows

```powershell
.\stop.ps1
```

`stop.ps1` reads `.pids.json` written by `run.ps1` and calls `Stop-Process` for each recorded PID. It then scans ports 8080–8082 with `netstat` and force-kills any remaining processes — the PowerShell equivalent of `fuser -k <port>/tcp`.

---

## Environment variables reference

This section is a full reference for all variables used by the build and run scripts. The [Quick start](#quick-start) and individual step sections show the minimal set needed for each scenario.

### Required on all platforms

| Variable | Used by | Description |
|---|---|---|
| `IDOT_OTEL_CPP_INSTALL` | `build.sh` / `build.ps1`, `run.sh` / `run.ps1` | Absolute path to the root of the IDOT OpenTelemetry C++ SDK install directory. Used by CMake at build time (`CMAKE_PREFIX_PATH`) and by the run scripts to set the runtime library path. |
| `OTEL_AGENT` | `run.sh` / `run.ps1` | Absolute path to the OpenTelemetry Java Agent JAR. Attached to `java-caller` and `java-receiver` via `-javaagent`. |

### Windows-only build variables

Required by `build.ps1` to locate the MSVC-compatible curl headers and import library. See [Windows curl note](#windows-curl-note).

| Variable | Description |
|---|---|
| `CURL_INCLUDE_DIR` | Directory containing `curl\curl.h` (e.g. `C:\curl-msvc\include`). |
| `CURL_LIBRARY` | Full path to the MSVC curl import library (e.g. `C:\curl-msvc\lib\libcurl.lib`). Must be a `.lib` — not a MinGW `.a` file. |

### Collector / backend endpoints

Both variables default to `localhost:4317` / `http://localhost:4317`. Set them if your collector is on a different host or port.

| Variable | Used by | Format | Default |
|---|---|---|---|
| `CPP_OTLP_ENDPOINT` | `run.sh` / `run.ps1` → `cpp-service` | Bare `host:port` — **no** URL scheme | `localhost:4317` |
| `JAVA_OTLP_ENDPOINT` | `run.sh` / `run.ps1` → `java-caller`, `java-receiver` | Full URL `http://host:port` | `http://localhost:4317` |

> `CPP_OTLP_ENDPOINT` and `JAVA_OTLP_ENDPOINT` must be set **independently**. The C++ gRPC exporter requires a bare `host:port`; the Java Agent requires a full `http://` URL. If your collector is remote, set both.

### Scheduler

| Variable | Used by | Description | Default |
|---|---|---|---|
| `SCHEDULE_ENABLED` | `run.sh` / `run.ps1` → `java-caller` | `true` — `java-caller` automatically sends one `GET /order` every 5 seconds. `false` — trigger traces manually with `curl`. | `false` |

### Service ports and inter-service URLs

All port and URL variables can be set as environment variables or passed as parameters to `run.ps1`. The inter-service URLs default to `localhost` with the corresponding port, but can be overridden independently when services run on different hosts.

| Variable | Consumed by | Description | Default |
|---|---|---|---|
| `SERVER_PORT` | `run.sh` / `run.ps1` → `cpp-service` | TCP port `cpp-service` listens on. | `8080` |
| `JAVA_RECEIVER_PORT` | `run.sh` / `run.ps1` → `java-receiver` | TCP port `java-receiver` listens on. | `8081` |
| `JAVA_CALLER_PORT` | `run.sh` / `run.ps1` → `java-caller` | TCP port `java-caller` listens on. | `8082` |
| `JAVA_RECEIVER_URL` | `run.sh` / `run.ps1` → `cpp-service` | Base URL `cpp-service` uses to call `java-receiver`. Defaults to `http://localhost:$JAVA_RECEIVER_PORT`. | `http://localhost:8081` |
| `CPP_SERVICE_URL` | `run.sh` / `run.ps1` → `java-caller` | Base URL `java-caller` uses to call `cpp-service`. Defaults to `http://localhost:$SERVER_PORT`. | `http://localhost:8080` |
| `SERVER_HOST` | `cpp-service` | Hostname written into span attributes only. Does not change the bind address (`0.0.0.0`). | _(not set)_ |

**Example — run all services on non-default ports:**

```bash
# Linux / AIX
SERVER_PORT=9080 JAVA_RECEIVER_PORT=9081 JAVA_CALLER_PORT=9082 \
IDOT_OTEL_CPP_INSTALL=<path> OTEL_AGENT=<path> ./run.sh
```

```powershell
# Windows
.\run.ps1 -IdotOtelCppInstall "<path>" -OtelAgent "<path>" `
          -ServerPort 9080 -JavaReceiverPort 9081 -JavaCallerPort 9082
```

**Example — services on different hosts:**

```bash
# Linux / AIX
JAVA_RECEIVER_URL=http://receiver-host:8081 \
CPP_SERVICE_URL=http://cpp-host:8080 \
IDOT_OTEL_CPP_INSTALL=<path> OTEL_AGENT=<path> ./run.sh
```

```powershell
# Windows
.\run.ps1 -IdotOtelCppInstall "<path>" -OtelAgent "<path>" `
          -JavaReceiverUrl "http://receiver-host:8081" `
          -CppServiceUrl   "http://cpp-host:8080"
```

### Service names

The run scripts assign a distinct `OTEL_SERVICE_NAME` to each service. These values are fixed and appear as separate service nodes in your observability backend.

| Service | `OTEL_SERVICE_NAME` |
|---|---|
| `java-caller` | `java-caller` |
| `cpp-service` | `cpp-service` |
| `java-receiver` | `java-receiver` |

---

## Project structure

```
idot-cpp-distributed-tracing/
├── build.sh                     — build all three services         (Linux / AIX)
├── build.ps1                    — build all three services         (Windows)
├── run.sh                       — start all three services         (Linux / AIX)
├── run.ps1                      — start all three services         (Windows)
├── stop.sh                      — stop all running services        (Linux / AIX)
├── stop.ps1                     — stop all running services        (Windows)
│
├── images/
│   └── distributed_tracing.jpg  — example trace waterfall screenshot
│
├── cpp-service/                 ← IDOT OTel C++ SDK instrumentation is here
│   ├── CMakeLists.txt
│   ├── vendor/httplib.h         — vendored header-only HTTP server
│   └── src/main.cpp             — full OTel C++ SDK instrumentation example
│
├── java-caller/                 — Spring Boot, exposes GET /order
│   ├── pom.xml
│   └── src/main/java/com/example/demo/CallerApplication.java
│
└── java-receiver/               — Spring Boot, answers GET /ping
    ├── pom.xml
    └── src/main/java/com/example/demo/ReceiverApplication.java
```

---

## Span tree

Each `GET /order` request produces the following trace waterfall. This is what you should see in [Step 4](#step-4--view-and-verify-traces).

```
java-caller   GET /order                                  SERVER  (auto-instrumented)
│
└─ java-caller  HTTP GET                                  CLIENT  (auto-instrumented)
   │
   └─ cpp-service  ProcessOrder                           SERVER
      ├─ cpp-service  ValidateOrder                       INTERNAL
      ├─ cpp-service  ReadCustomerDB                      CLIENT   (simulated)
      ├─ cpp-service  ChargePayment                       CLIENT   (simulated)
      ├─ cpp-service  UpdateInventory                     INTERNAL
      ├─ cpp-service  PublishShipment                     PRODUCER (simulated)
      └─ cpp-service  HTTP GET <java-receiver-url>/ping   CLIENT
         │
         └─ java-receiver  GET /ping                      SERVER   (auto-instrumented)
```

`ReadCustomerDB`, `ChargePayment`, and `PublishShipment` are simulated — they demonstrate OpenTelemetry semantic attributes for database, RPC, and messaging operations without requiring a real database, payment gateway, or message broker.

---

## What the sample covers

The instrumentation in [`cpp-service/src/main.cpp`](cpp-service/src/main.cpp) demonstrates the key OTel C++ SDK patterns needed in any production service:

| Concept | Where in the code |
|---|---|
| SDK initialisation — tracer provider, OTLP/gRPC exporter, resource attributes | `InitTelemetry()` |
| SimpleSpanProcessor — synchronous, per-span export | `InitTelemetry()` |
| W3C Trace Context extraction — join the trace started by `java-caller` | `HandleOrder()` |
| Span creation — `SERVER`, `CLIENT`, `INTERNAL`, `PRODUCER` span kinds | `HandleOrder()` |
| Span attributes — HTTP, database, RPC, and messaging semantic conventions | `HandleOrder()` |
| Span events — timestamped annotations attached to a span | `HandleOrder()` — `ChargePayment`, `PublishShipment` |
| W3C Trace Context injection — propagate to `java-receiver` | `CallDownstream()` |
| Span status — `kOk` and `kError` | `CallDownstream()`, `HandleOrder()` |
| Graceful shutdown — `ForceFlush` then `Shutdown` | `ShutdownTelemetry()`, `main()` |

The Java services use the OpenTelemetry Java Agent for automatic instrumentation — no manual instrumentation is required in their code.

---

## Applying this to your own C++ service

The patterns in [`cpp-service/src/main.cpp`](cpp-service/src/main.cpp) are designed to be copied into your own service. Here is the sequence every instrumented C++ service must follow:

### 1. Initialise the SDK once at startup

Call `InitTelemetry()` (or equivalent) before serving any requests. This sets up:
- The **OTLP/gRPC exporter** — points to your collector via `OTEL_EXPORTER_OTLP_ENDPOINT`
- The **SimpleSpanProcessor** — exports each span synchronously as it ends; swap for `BatchSpanProcessorFactory` in production for non-blocking, buffered export
- **Resource attributes** — `service.name`, `host.name`, `process.pid` — attached to every span this process emits
- The **global W3C propagator** — registers `HttpTraceContext` so `Extract` and `Inject` work correctly

### 2. Extract incoming trace context at the start of each request handler

If your service receives HTTP requests from an upstream service that is also instrumented with OpenTelemetry, the upstream will have injected a `traceparent` header. Extract it and attach the resulting context so your spans become children of the upstream span:

```cpp
// Create a carrier that reads from your framework's request headers
HttplibRequestCarrier carrier(req.headers);

// Extract the upstream context
auto parent_ctx = propagation::GlobalTextMapPropagator::GetGlobalPropagator()
                      ->Extract(carrier, ctx::RuntimeContext::GetCurrent());

// Attach it — all spans created on this thread will carry the same traceId
auto token = ctx::RuntimeContext::Attach(parent_ctx);
```

If no `traceparent` header is present (e.g. the request originates from outside an instrumented system), `Extract` returns an empty context and the SDK starts a new trace automatically.

### 3. Create a SERVER span for the inbound request

Mark the entry point of your handler with `SpanKind::kServer`:

```cpp
trace::StartSpanOptions opts;
opts.parent = parent_ctx;
opts.kind   = trace::SpanKind::kServer;
auto root = tracer->StartSpan("YourOperationName", opts);
trace::Scope root_scope(root);   // makes root the active span on this thread
```

Add HTTP semantic attributes so your backend correlates this SERVER span with the CLIENT span from the caller:

```cpp
root->SetAttribute("http.method",    req.method);   // "GET", "POST", ...
root->SetAttribute("http.route",     "/your-path");
root->SetAttribute("server.address", srv_host);
root->SetAttribute("server.port",    srv_port);
```

### 4. Create child spans for each unit of work

Each distinct operation in your handler — a database query, an RPC call, internal business logic — should be its own span. Use the correct `SpanKind` for each:

| `SpanKind` | Use for |
|---|---|
| `kInternal` | Work done entirely inside this service (validation, computation, in-process logic) |
| `kClient` | Outbound synchronous calls — database queries, HTTP calls to other services, RPC |
| `kProducer` | Fire-and-forget message publishes to a queue or topic |

```cpp
// INTERNAL span — in-process work
{
    auto span = tracer->StartSpan("ValidateInput", ChildOf(trace::SpanKind::kInternal));
    trace::Scope s(span);
    // ... your logic ...
    span->SetStatus(trace::StatusCode::kOk);
    span->End();
}

// CLIENT span — outbound database call
{
    auto span = tracer->StartSpan("QueryDatabase", ChildOf(trace::SpanKind::kClient));
    trace::Scope s(span);
    span->SetAttribute("db.system",    "postgresql");
    span->SetAttribute("db.name",      "orders");
    span->SetAttribute("db.operation", "SELECT");
    // ... your query ...
    span->SetStatus(trace::StatusCode::kOk);
    span->End();
}
```

Use `ChildOf()` (the helper in [`main.cpp`](cpp-service/src/main.cpp)) to parent each child span under the current active context automatically.

### 5. Inject trace context into outbound HTTP calls

When your service calls a downstream service that is also instrumented, inject the `traceparent` header so the downstream spans become children of your CLIENT span:

```cpp
// Create a carrier that collects headers to add to the outbound request
CurlHeaderCarrier carrier;
propagation::GlobalTextMapPropagator::GetGlobalPropagator()
    ->Inject(carrier, ctx::RuntimeContext::GetCurrent());

// Add the collected headers to your HTTP request (example using libcurl)
struct curl_slist* hlist = nullptr;
for (auto& [k, v] : carrier.headers)
    hlist = curl_slist_append(hlist, (k + ": " + v).c_str());
curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hlist);
```

The downstream service calls `Extract` on the same header to continue the trace — no manual trace ID passing is required.

### 6. Set span status and end every span

Always call `SetStatus` and `End` on every span you create. An unended span is never exported.

```cpp
if (/* operation succeeded */) {
    span->SetStatus(trace::StatusCode::kOk);
} else {
    span->SetStatus(trace::StatusCode::kError, "descriptive error message");
}
span->End();
```

### 7. Detach the context and shut down cleanly

After the request is complete, detach the extracted context:

```cpp
ctx::RuntimeContext::Detach(*token);
```

At process shutdown, flush and release the SDK before exiting. Without this, spans still in-flight (or buffered if using `BatchSpanProcessor`) are lost:

```cpp
g_provider->ForceFlush(std::chrono::milliseconds(10'000));
g_provider->Shutdown();
```

### Span attributes — semantic conventions

OpenTelemetry defines standard attribute names for common operations. Using them ensures your backend can automatically interpret and display spans correctly. Key conventions used in this sample:

| Operation type | Key attributes |
|---|---|
| HTTP server (inbound) | `http.method`, `http.route`, `http.status_code`, `server.address`, `server.port` |
| HTTP client (outbound) | `http.method`, `http.url`, `http.status_code`, `server.address`, `server.port` |
| Database | `db.system`, `db.name`, `db.operation`, `db.statement` |
| RPC | `rpc.system`, `rpc.service`, `rpc.method` |
| Messaging | `messaging.system`, `messaging.destination`, `messaging.operation` |

See the full [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/) reference for all supported attribute names.

---

## Troubleshooting

### No spans appear in the backend

1. **Verify the collector was running before the services started.** If `cpp-service` started before the collector, check `logs/cpp-service.log` for `Connection refused`. The gRPC channel reconnects automatically — wait 30 seconds and trigger a new request before assuming the connection is broken.

2. **Verify the OTLP endpoint variables are set correctly.**
   - `CPP_OTLP_ENDPOINT` must be a bare `host:port` with no scheme (e.g. `collector:4317`).
   - `JAVA_OTLP_ENDPOINT` must be a full URL (e.g. `http://collector:4317`).

3. **Check the collector is reachable** from the host running the services:

   | Platform | Command |
   |---|---|
   | Linux | `nc -zv <collector-host> <grpc-port>` |
   | AIX | `netstat -an \| grep <grpc-port>` |
   | Windows | `Test-NetConnection <collector-host> -Port <grpc-port>` |

4. **Check the log files** under `logs/` for connection errors or stack traces.

### `cpp-service` fails to start — shared library not found

The SDK shared libraries must be on the runtime library search path. Verify by platform:

| Platform | Command | Path variable |
|---|---|---|
| Linux | `ls $IDOT_OTEL_CPP_INSTALL/lib64/libopentelemetry*.so` | `LD_LIBRARY_PATH` |
| AIX | `ls $IDOT_OTEL_CPP_INSTALL/lib/libopentelemetry*.so` | `LIBPATH` |
| Windows | `dir %IDOT_OTEL_CPP_INSTALL%\bin\opentelemetry*.dll` | `PATH` |

`run.sh` sets `LD_LIBRARY_PATH` (Linux) or `LIBPATH` (AIX) automatically. `run.ps1` adds the SDK `bin\` directory to `PATH`.

### `cpp-service.exe` crashes silently on Windows — `libcurl.dll` not found

If `cpp-service` exits immediately with no log output, a required DLL is missing. Verify both DLLs are present next to the executable:

```powershell
Get-ChildItem "cpp-service\build\Release\*.dll"
# Expected: libcurl.dll  and  opentelemetry_cpp.dll
```

If `libcurl.dll` is missing, copy it manually then rebuild so CMake's post-build step handles it going forward:

```powershell
Copy-Item "<path-to-curl>\bin\libcurl.dll" "cpp-service\build\Release\"
.\build.ps1   # future builds copy it automatically
```

### Build fails — `opentelemetry-cpp` package not found

CMake searches for `opentelemetry-cpp-config.cmake` inside `IDOT_OTEL_CPP_INSTALL`. Verify the file exists at the platform-specific path:

| Platform | Expected path |
|---|---|
| Linux | `$IDOT_OTEL_CPP_INSTALL/lib64/cmake/opentelemetry-cpp/opentelemetry-cpp-config.cmake` |
| AIX | `$IDOT_OTEL_CPP_INSTALL/lib/cmake/opentelemetry-cpp/opentelemetry-cpp-config.cmake` |
| Windows | `%IDOT_OTEL_CPP_INSTALL%\lib\cmake\opentelemetry-cpp\opentelemetry-cpp-config.cmake` |

### Port already in use

The default ports are `8080` (`cpp-service`), `8081` (`java-receiver`), and `8082` (`java-caller`). Identify conflicting processes:

| Platform | Command |
|---|---|
| Linux | `ss -tlnp \| grep -E '8080\|8081\|8082'` |
| AIX | `netstat -an \| grep -E '8080\|8081\|8082'` |
| Windows | `netstat -ano \| findstr "8080 8081 8082"` |

To use different ports, edit `run.sh` (Linux/AIX) or `run.ps1` (Windows) and update `SERVER_PORT`, `JAVA_RECEIVER_URL`, and `CPP_SERVICE_URL` to match.

### `curl` returns an error or no response

The JVM takes ~20 seconds to fully start. Monitor the log and wait for `Started CallerApplication` before sending requests:

**Linux / AIX:**
```bash
tail -f logs/java-caller.log
```

**Windows:**
```powershell
Get-Content logs\java-caller.log -Wait
```

Once you see `Started CallerApplication`, retry:

**Linux / AIX:** `curl http://$(hostname -f):8082/order`

**Windows:** `curl.exe http://localhost:8082/order`

### Trace shows only one or two services

This usually means one service is not exporting to the same backend. Verify:
- All three `OTEL_SERVICE_NAME` values (`java-caller`, `cpp-service`, `java-receiver`) appear in your backend's service list.
- `CPP_OTLP_ENDPOINT` and `JAVA_OTLP_ENDPOINT` both point to the same collector.
- The `traceparent` header appears in the `cpp-service` log output (printed on every request).
