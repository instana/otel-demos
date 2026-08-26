# IDOT OpenTelemetry C++ Sample

A minimal, self-contained C++ application that demonstrates how to link and use
the **unified Instana Distribution of OpenTelemetry (IDOT) C++ shared library**
(`libopentelemetry_cpp.so`) from a standalone project.

The sample simulates an order-processing service. It creates distributed traces
with parent and child spans, sets attributes and events, and exports them via
**OTLP/gRPC** to any OpenTelemetry-compatible collector (e.g. Instana, Jaeger,
OpenTelemetry Collector).

> The prebuilt unified shared library (`libopentelemetry_cpp.so`) is distributed
> as a ready-to-use package. Extract it to a directory of your choice and point
> the build at that location using `OTEL_INSTALL` as shown below.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| C++17 compiler | GCC 9+ or Clang 10+ (Linux); IBM XL C/C++ or GCC (AIX) |
| CMake 3.16+ | `cmake --version` |
| [IDOT package](https://link-to-idot-package) | Extracted to any directory on the build host |

No external package manager is required. gRPC, Protobuf, and Abseil are
statically embedded inside `libopentelemetry_cpp.so`.

---

## Configure

Edit `config.yaml` before building or running:

```yaml
service:
  name: otel-sample        # service.name resource attribute
  version: "1.0"           # service.version resource attribute

otlp:
  endpoint: 127.0.0.1:4317 # OTLP/gRPC endpoint — host:port, no scheme
  insecure: true            # true = plaintext gRPC (no TLS)
  timeout_ms: 10000         # export timeout in milliseconds

sample:
  iterations: 10            # number of root spans to emit
```

> **Endpoint format:** `host:port` with no scheme prefix —
> `127.0.0.1:4317`, **not** `grpc://127.0.0.1:4317`.

---

## Build

Set `OTEL_INSTALL` to the directory where you extracted the [IDOT package](https://link-to-idot-package),
then follow the steps for your platform.

### Linux

```bash
export OTEL_INSTALL=/path/to/otel-package

# 1. Configure
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=$OTEL_INSTALL

# 2. Build
cmake --build build -j$(nproc)

# 3. Run
LD_LIBRARY_PATH=$OTEL_INSTALL/lib64 ./build/otel-sample
```

### AIX

On AIX, set `OBJECT_MODE=64` before configuring to ensure the 64-bit toolchain
is used throughout the build.

```bash
export OTEL_INSTALL=/path/to/otel-package
export OBJECT_MODE=64          # required on AIX — select 64-bit object mode

# 1. Configure
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=$OTEL_INSTALL

# 2. Build
cmake --build build -j$(nproc)

# 3. Run
LIBPATH=$OTEL_INSTALL/lib64 ./build/otel-sample
```

> Run from the repository root so the binary can locate `config.yaml` in the
> current working directory.

---

## Expected output

```
=========================================
 OpenTelemetry C++ Sample
=========================================
Service   : otel-sample
Version   : 1.0
Endpoint  : 127.0.0.1:4317
Iterations: 10

[1/10] Processing order...
[2/10] Processing order...
[3/10] Processing order...
[4/10] Processing order...
[5/10] Processing order...
[6/10] Processing order...
[7/10] Processing order...
[8/10] Processing order...
[9/10] Processing order...
[10/10] Processing order...

Telemetry export completed successfully.
```

---

## Instana UI screenshots

### Total calls

![Instana total calls view](images/total-calls.jpg)

### Calls view

![Instana calls view](images/calls.jpg)

### Trace details

![Instana trace details view](images/trace-details.jpg)

---

## What the sample demonstrates

### Trace hierarchy

Each iteration emits one root span (`Process Order`, kind `SERVER`) with six
sequential child spans:

```
Process Order              SERVER    ~150 ms
├── Validate Request       INTERNAL   20 ms   validation.result=success
├── Read Customer          CLIENT     40 ms   db.system=postgresql
├── Process Payment        CLIENT     35 ms   payment.provider=SampleGateway
├── Update Inventory       CLIENT     15 ms   inventory.status=updated
├── Publish MQ Message     PRODUCER   25 ms   messaging.system=ibmmq
└── Send Notification      CLIENT     10 ms   notification.type=email
```

Resource attributes attached to every exported span:

| Attribute | Value |
|---|---|
| `service.name` | value from `config.yaml` |
| `service.version` | value from `config.yaml` |
| `host.name` | resolved at runtime via `gethostname()` |
| `process.pid` | resolved at runtime via `getpid()` |

### OpenTelemetry concepts demonstrated

| Concept | Where in `src/main.cpp` |
|---|---|
| `TracerProvider` + `Resource` | `InitTelemetry()` |
| OTLP/gRPC exporter | `OtlpGrpcExporterFactory::Create()` |
| `SimpleSpanProcessor` | `SimpleSpanProcessorFactory::Create()` |
| Semantic conventions | `semconv::service::kServiceName` |
| Span start / end | `tracer->StartSpan()` / `span->End()` |
| Span kinds | `SpanKind::kServer`, `kClient`, `kProducer`, `kInternal` |
| Span attributes | `span->SetAttribute()` |
| Span events | `root->AddEvent()` |
| Context propagation | `trace::Scope` + `ChildOpts()` |
| Graceful shutdown | `ForceFlush()` + `Shutdown()` + `NoopTracerProvider` reset |

---

## Linking model

The sample links against **one target only**:

```cmake
target_link_libraries(otel-sample PRIVATE
    opentelemetry-cpp::opentelemetry_cpp)   # → libopentelemetry_cpp.so
```

All API, SDK, exporter, and transport code — including gRPC, Protobuf,
and Abseil — is bundled inside the unified `.so`. No other libraries need
to be linked. See `CMakeLists.txt` for the complete build recipe.

---

## Project structure

```
idot-cpp-sample/
├── CMakeLists.txt    — find_package(opentelemetry-cpp COMPONENTS ext_so)
├── config.yaml       — runtime configuration (endpoint, iterations, …)
├── README.md         — this file
└── src/
    └── main.cpp      — single source file (~260 lines)
```

---

## Notes

- **`SimpleSpanProcessor`** exports each span synchronously on `span->End()`.
  Production services typically use `BatchSpanProcessor` instead to avoid
  blocking the calling thread on every export.
- If `config.yaml` is not found, the application falls back to compiled-in
  defaults (`localhost:4317`, 5 iterations).
- The `OBJECT_MODE=64` variable is AIX-specific and has no effect on Linux.
