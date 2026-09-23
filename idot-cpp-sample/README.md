# IDOT OpenTelemetry C++ Sample

This sample shows how to build and run a C++ application that is instrumented
with the **Instana Distribution of OpenTelemetry (IDOT) C++ library** and sends
traces to an OTLP/gRPC collector.

The included sample application instruments a minimal order-processing workflow
and exports traces over OTLP/gRPC - giving you a working reference for span
creation, child spans, attributes, events, and context propagation with the
IDOT C++ library.

---

## Project structure

```
idot-cpp-sample/
├── CMakeLists.txt     -  build definition; selects ext_dll (Windows) or ext_so (Linux/AIX)
├── config.yaml        -  runtime configuration (endpoint, iterations, …)
├── README.md          -  this file
└── src/
    └── main.cpp       -  single source file
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| C++17 compiler | GCC 9+ or Clang 10+ (Linux); IBM Open XL C/C++ V17.1.3+ (AIX); MSVC 2019+ (Windows) |
| CMake 3.16+ | `cmake --version` |
| IDOT package | Download from [Artifactory](https://artifact-public.instana.io/artifactory/rel-generic-instana-virtual/com/instana/idot-opentelemetry-cpp/1.26.0/idot-opentelemetry-cpp-1.26.0-bin.tar.gz) and extract on your host machine (see [Step 1](#step-1---download-and-extract-the-idot-package)). |
| Instana Agent Key | Required to download the IDOT package from Artifactory |
| OTLP Collector / Receiver | [Instana Agent](https://www.ibm.com/docs/en/instana-observability/current?topic=instana-installing-agent) (with OTLP enabled) or any OTLP-compatible collector (such as OpenTelemetry Collector) |

gRPC, Protobuf, and Abseil are statically embedded inside the IDOT library, no other libraries need to be installed.

---

## Step 1 - Download and extract the IDOT package

1. Download the idot-opentelemetry-cpp package from [Artifactory](https://artifact-public.instana.io/artifactory/rel-generic-instana-virtual/com/instana/idot-opentelemetry-cpp/1.26.0/idot-opentelemetry-cpp-1.26.0-bin.tar.gz).

   > **Note:** To download the file, use the following credentials:
   > - **Username:** Underscore (`_`)
   > - **Password:** A valid agent key

2. Extract the downloaded `.tar.gz` file to a temporary location. After extraction, find five platform-specific packages in the directory:

   | Platform | Artifact filename |
   |----------|-------------------|
   | Linux x86_64 | `idot-opentelemetry-cpp-1.26.0-xLinux_64bit.tar.gz` |
   | Linux ppc64le | `idot-opentelemetry-cpp-1.26.0-pLinuxle_64bit.tar.gz` |
   | Linux s390x | `idot-opentelemetry-cpp-1.26.0-zLinux_64bit.tar.gz` |
   | AIX ppc64 | `idot-opentelemetry-cpp-1.26.0-aix_64bit.tar.gz` |
   | Windows x86_64 | `idot-opentelemetry-cpp-1.26.0-win_64bit.zip` |

3. Extract the platform-specific archive for your target system and point `OTEL_INSTALL` to the extracted directory path.

**Linux / AIX**
```bash
export OTEL_INSTALL=<path-to-extracted-idot-package>
```

**Windows (Developer PowerShell for VS 2022)**
```powershell
$env:OTEL_INSTALL = "<path-to-extracted-idot-package>"
```

---

## Step 2 - Edit `config.yaml`

Set the `endpoint` to the host and port of your collector. Use the IP address
of the machine running the collector  -  `localhost` only works if the collector
is on the same machine as the application.

```yaml
service:
  name: otel-sample
  version: "1.0"

otlp:
  # OTLP/gRPC endpoint format: host:port (no scheme prefix, e.g., 127.0.0.1:4317 or localhost:4317)
  endpoint: <OTLP_GRPC_ENDPOINT>
  insecure: true            # true = plaintext gRPC (no TLS)
  timeout_ms: 10000         # export timeout in milliseconds

sample:
  iterations: 10
```

> **Endpoint format:** `host:port` with no scheme prefix —
> `127.0.0.1:4317`, **not** `grpc://127.0.0.1:4317`.

---

## Step 3 - Build and run

Set `OTEL_INSTALL` to the directory where you extracted the IDOT package,
then follow the steps for your platform.

### Linux

```bash
# Configure
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=$OTEL_INSTALL

# Build
cmake --build build -j$(nproc)

# Run
LD_LIBRARY_PATH=$OTEL_INSTALL/lib64 ./build/otel-sample
```

### AIX

`OBJECT_MODE=64` selects the 64-bit toolchain and must be set before configuring.

```bash
export OBJECT_MODE=64

# Configure
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=$OTEL_INSTALL

# Build
cmake --build build -j$(nproc)

# 3. Run
LIBPATH=$OTEL_INSTALL/lib ./build/otel-sample
```

### Windows

Open **Developer PowerShell for VS 2022** (*Start → Visual Studio 2022 → Developer PowerShell for VS 2022*).

`opentelemetry_cpp.dll` is copied next to the executable automatically after
each build. The OpenSSL DLLs must also be on `PATH` before running.

```powershell
# Configure
cmake -B build -DCMAKE_PREFIX_PATH="$env:OTEL_INSTALL" -A x64

# Build
cmake --build build --config Release

# Add OpenSSL to PATH (adjust to your installation)
$env:PATH = "C:\Program Files\OpenSSL-Win64\bin;$env:PATH"

# Run
.\build\Release\otel-sample.exe
```

---

## Expected output

```
=========================================
 OpenTelemetry C++ Sample
=========================================
Service   : otel-sample
Version   : 1.0
Endpoint  : localhost:4317
Iterations: 10

[1/10] Processing order...
[2/10] Processing order...
...
[10/10] Processing order...

Telemetry export completed successfully.
```

Spans appear in the collector immediately after the run completes.

---

## Viewing traces in Instana

The sample sends spans via OTLP/gRPC to port `4317`. Configure the
[Instana Agent](https://www.ibm.com/docs/en/instana-observability/current?topic=instana-installing-agent)
or any OTLP-compatible collector (such as OpenTelemetry Collector) as the receiver, then navigate to **Instana UI → Analytics → Traces**.

---

## Instana UI screenshots

### IBM Instana

#### Service summary

![Instana service summary](images/total-calls.jpg)

#### Calls view

![Instana calls view with trace timeline](images/calls.jpg)

#### Trace details

![Instana trace details with resource attributes](images/trace-details.jpg)

### OpenTelemetry Collector

#### Service summary

![Service summary showing otel-sample calls and latency](images/otel_collector_calls.jpg)

#### Trace detail

![Trace detail showing Process Order with six child spans](images/otel_collector_traces.jpg)

---

## What the sample demonstrates

Each iteration emits one root span with six sequential child spans:

```
Process Order              SERVER    ~150 ms
├── Validate Request       INTERNAL   20 ms   validation.result=success
├── Read Customer          CLIENT     40 ms   db.system=postgresql
├── Process Payment        CLIENT     35 ms   payment.provider=SampleGateway
├── Update Inventory       CLIENT     15 ms   inventory.status=updated
├── Publish MQ Message     PRODUCER   25 ms   messaging.system=ibmmq
└── Send Notification      CLIENT     10 ms   notification.type=email
```

Resource attributes attached to every span:

| Attribute | Value |
|---|---|
| `service.name` | from `config.yaml` |
| `service.version` | from `config.yaml` |
| `host.name` | `gethostname()` at startup |
| `process.pid` | `getpid()` (Linux/AIX) or `GetCurrentProcessId()` (Windows) |
| `telemetry.sdk.language` | `cpp` (set automatically by the SDK) |

OpenTelemetry concepts used in `src/main.cpp`:

| Concept | Where |
|---|---|
| `TracerProvider` + `Resource` | `InitTelemetry()` |
| OTLP/gRPC exporter | `OtlpGrpcExporterFactory::Create()` |
| `SimpleSpanProcessor` | `SimpleSpanProcessorFactory::Create()` |
| Semantic conventions | `semconv::service::kServiceName` |
| Span start / end | `tracer->StartSpan()` / `span->End()` |
| Span kinds | `kServer`, `kClient`, `kProducer`, `kInternal` |
| Span attributes | `span->SetAttribute()` |
| Span events | `root->AddEvent()` |
| Context propagation | `trace::Scope` + `ChildOpts()` |
| Graceful shutdown | `ForceFlush()` + `Shutdown()` + `NoopTracerProvider` |

---

## Notes

- **`SimpleSpanProcessor`** sends each span synchronously on `span->End()`.
  For production use, switch to `BatchSpanProcessor` to avoid blocking the
  calling thread on every export.
- **`OBJECT_MODE=64`** is AIX-specific and has no effect on other platforms.
