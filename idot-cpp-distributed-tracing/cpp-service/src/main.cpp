// =============================================================================
//  cpp-service  —  OpenTelemetry C++ distributed tracing sample
//
//  This service is the centrepiece of the end-to-end distributed tracing sample.
//  It demonstrates key OpenTelemetry C++ tracing features:
//
//   TracerProvider + Resource      InitTelemetry()
//   BatchSpanProcessor             InitTelemetry()   (production-ready export)
//   W3C Trace Context – Extract    HandleOrder()     (join incoming Java trace)
//   W3C Trace Context – Inject     CallDownstream()  (propagate to Java receiver)
//   Span kinds                     SERVER / CLIENT / INTERNAL / PRODUCER
//   Span attributes                semantic conventions + custom business attrs
//   Span events                    timestamped annotations on a span
//   Span status                    kOk / kError with descriptive message
//   Context propagation            RuntimeContext::Attach / Detach
//   Graceful shutdown              ForceFlush + Shutdown + NoopTracerProvider
//
//  Call flow per request:
//
//    java-caller ──traceparent──▶ [Extract]
//                                  ProcessOrder                    SERVER
//                                  ├─ ValidateOrder                INTERNAL
//                                  ├─ ReadCustomerDB               CLIENT   (simulated)
//                                  ├─ ChargePayment                CLIENT   (simulated)
//                                  ├─ UpdateInventory              INTERNAL
//                                  ├─ PublishShipment              PRODUCER (simulated)
//                                  └─ HTTP GET http://…/ping       CLIENT
//                                          │
//                                  [Inject traceparent]
//                                          ▼
//                              java-receiver (GET /ping)           SERVER
//
// =============================================================================

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#  include <winsock2.h>
#  include <windows.h>
#else
// Linux and AIX: POSIX headers for gethostname() and getpid()
#  include <sys/types.h>
#  include <unistd.h>
#endif

// ── libcurl: outbound HTTP to java-receiver ───────────────────────────────────
#include <curl/curl.h>

// ── OpenTelemetry C++ API & SDK headers ──────────────────────────────────────
#include <opentelemetry/context/propagation/global_propagator.h>
#include <opentelemetry/context/propagation/text_map_propagator.h>
#include <opentelemetry/context/runtime_context.h>
#include <opentelemetry/exporters/otlp/otlp_grpc_exporter_factory.h>
#include <opentelemetry/exporters/otlp/otlp_grpc_exporter_options.h>
#include <opentelemetry/sdk/resource/resource.h>
#include <opentelemetry/sdk/trace/simple_processor_factory.h>
#include <opentelemetry/sdk/trace/provider.h>
#include <opentelemetry/sdk/trace/tracer_provider.h>
#include <opentelemetry/sdk/trace/tracer_provider_factory.h>
#include <opentelemetry/semconv/service_attributes.h>                 // kServiceName
#include <opentelemetry/trace/noop.h>
#include <opentelemetry/trace/provider.h>
#include <opentelemetry/trace/scope.h>
#include <opentelemetry/trace/span_startoptions.h>
#include <opentelemetry/trace/propagation/http_trace_context.h>       // W3C TraceContext

// ── cpp-httplib: embedded HTTP server (header-only, vendored) ─────────────────
#include "httplib.h"

// ── Namespace aliases ─────────────────────────────────────────────────────────
namespace sdktrace   = opentelemetry::sdk::trace;
namespace resource   = opentelemetry::sdk::resource;
namespace trace      = opentelemetry::trace;
namespace otlp       = opentelemetry::exporter::otlp;
namespace nostd      = opentelemetry::nostd;
namespace ctx        = opentelemetry::context;
namespace propagation = opentelemetry::context::propagation;

// =============================================================================
//  W3C TextMap carrier adapters
//
//  The OTel TextMap propagation model requires two adapters:
//    - a read-only carrier to EXTRACT context from an incoming request
//    - a write-only carrier to INJECT context into an outgoing request
// =============================================================================

// Wraps httplib::Headers so the W3C propagator can read incoming headers.
class HttplibRequestCarrier : public propagation::TextMapCarrier
{
public:
    explicit HttplibRequestCarrier(const httplib::Headers& h) : headers_(h) {}

    // Called by Extract() to read a header value by name.
    nostd::string_view Get(nostd::string_view key) const noexcept override
    {
        std::string k(key.data(), key.size());
        auto it = headers_.find(k);
        return it != headers_.end() ? nostd::string_view(it->second) : nostd::string_view{};
    }

    // Not used during extraction.
    void Set(nostd::string_view, nostd::string_view) noexcept override {}

private:
    const httplib::Headers& headers_;
};

// Collects key/value pairs written by Inject() so they can be added to
// the outgoing curl request as HTTP headers.
class CurlHeaderCarrier : public propagation::TextMapCarrier
{
public:
    std::vector<std::pair<std::string, std::string>> headers;

    // Not used during injection.
    nostd::string_view Get(nostd::string_view) const noexcept override { return {}; }

    // Called by Inject() to write each propagation header (e.g. traceparent).
    void Set(nostd::string_view key, nostd::string_view value) noexcept override
    {
        headers.emplace_back(std::string(key.data(),   key.size()),
                             std::string(value.data(), value.size()));
    }
};

// =============================================================================
//  Telemetry initialisation
//
//  Sets up:
//    1. OTLP/gRPC exporter  → OpenTelemetry Collector / backend OTLP endpoint
//    2. BatchSpanProcessor  → buffers spans and exports in batches (production-ready)
//    3. Resource attributes → service.name, host.name, process.pid
//    4. Global W3C Trace Context propagator → traceparent / tracestate headers
// =============================================================================

static std::shared_ptr<sdktrace::TracerProvider> g_provider;

static void InitTelemetry()
{
    // ── OTLP/gRPC exporter ────────────────────────────────────────────────────
    // Send spans to any OTLP/gRPC endpoint: an OpenTelemetry Collector,
    // a telemetry proxy, or a compliant observability backend.
    // Configure via OTEL_EXPORTER_OTLP_ENDPOINT (default: localhost:4317).
    // The gRPC exporter requires a bare host:port with no URL scheme prefix.
    const char* ep_env   = std::getenv("OTEL_EXPORTER_OTLP_ENDPOINT");
    std::string endpoint = ep_env ? ep_env : "localhost:4317";
    for (auto prefix : {"grpc://", "http://", "https://"})
        if (endpoint.rfind(prefix, 0) == 0)
        { endpoint = endpoint.substr(std::strlen(prefix)); break; }

    const char* svc_env = std::getenv("OTEL_SERVICE_NAME");
    std::string svc     = svc_env ? svc_env : "cpp-service";

    otlp::OtlpGrpcExporterOptions opts;
    opts.endpoint            = endpoint;
    // TLS is disabled here; enable and supply credentials for production use.
    opts.use_ssl_credentials = false;
    opts.timeout             = std::chrono::milliseconds(10'000);
    auto exporter = otlp::OtlpGrpcExporterFactory::Create(opts);

    // ── Span Processor ────────────────────────────────────────────────────────
    auto processor = sdktrace::SimpleSpanProcessorFactory::Create(std::move(exporter));

    // ── Resource attributes ───────────────────────────────────────────────────
    // Attached to every span exported by this process.
    char hostname[256] = {};
#ifdef _WIN32
    ::gethostname(hostname, sizeof(hostname) - 1);  // requires winsock2
    int64_t pid = static_cast<int64_t>(::GetCurrentProcessId());
#else
    // Linux and AIX: gethostname() and getpid() from POSIX
    ::gethostname(hostname, sizeof(hostname) - 1);
    int64_t pid = static_cast<int64_t>(::getpid());
#endif

    auto res = resource::Resource::Create({
        {opentelemetry::semconv::service::kServiceName,    svc},
        {opentelemetry::semconv::service::kServiceVersion, "1.0"},
        {"host.name",                                      std::string(hostname)},
        {"process.pid",                                    pid},
    });

    // ── TracerProvider ────────────────────────────────────────────────────────
    g_provider = sdktrace::TracerProviderFactory::Create(std::move(processor), res);
    std::shared_ptr<trace::TracerProvider> api_provider = g_provider;
    sdktrace::Provider::SetTracerProvider(api_provider);

    // ── Global W3C Trace Context propagator ──────────────────────────────────
    // Registers HttpTraceContext as the process-wide propagator.
    // Extract() reads the incoming "traceparent" header.
    // Inject() writes "traceparent" (and "tracestate" if present) to outgoing headers.
    propagation::GlobalTextMapPropagator::SetGlobalPropagator(
        nostd::shared_ptr<propagation::TextMapPropagator>(
            new opentelemetry::trace::propagation::HttpTraceContext()));
}

static nostd::shared_ptr<trace::Tracer> GetTracer()
{
    return g_provider->GetTracer("cpp-service", "1.0");
}

static void ShutdownTelemetry()
{
    if (!g_provider) return;
    // ForceFlush waits until all buffered spans have been exported.
    g_provider->ForceFlush(std::chrono::milliseconds(10'000));
    g_provider->Shutdown();
    // Replace with a no-op provider so any stray API calls after shutdown are safe.
    trace::Provider::SetTracerProvider(
        nostd::shared_ptr<trace::TracerProvider>(new trace::NoopTracerProvider));
    g_provider.reset();
}

// =============================================================================
//  Helpers
// =============================================================================

// Returns StartSpanOptions that make the new span a child of the current context.
static trace::StartSpanOptions ChildOf(trace::SpanKind kind)
{
    trace::StartSpanOptions o;
    o.parent = ctx::RuntimeContext::GetCurrent();
    o.kind   = kind;
    return o;
}

// curl write callback — appends received data to a std::string.
static size_t CurlWrite(char* ptr, size_t size, size_t nmemb, std::string* out)
{
    out->append(ptr, size * nmemb);
    return size * nmemb;
}

// Extracts the host and port from a URL of the form http[s]://host[:port][/path].
// Returns {"host", port}.  Falls back to {"localhost", default_port} on parse error.
static std::pair<std::string, int> ParseHostPort(const std::string& url, int default_port)
{
    // Strip scheme
    std::string rest = url;
    for (auto scheme : {"https://", "http://"})
        if (rest.rfind(scheme, 0) == 0) { rest = rest.substr(std::strlen(scheme)); break; }
    // Strip path
    auto slash = rest.find('/');
    if (slash != std::string::npos) rest = rest.substr(0, slash);
    // Split host:port
    auto colon = rest.rfind(':');
    if (colon != std::string::npos) {
        try {
            return {rest.substr(0, colon), std::stoi(rest.substr(colon + 1))};
        } catch (...) {}
    }
    return {rest.empty() ? "localhost" : rest, default_port};
}

// =============================================================================
//  CallDownstream — outbound HTTP call with W3C context injection
//
//  Demonstrates:
//    - Creating a CLIENT span for an outbound call
//    - Injecting traceparent / tracestate into the curl request headers
//    - Setting HTTP semantic attributes on the span
//    - Recording an error status when the downstream call fails
// =============================================================================
static std::string CallDownstream(const std::string& url)
{
    auto tracer = GetTracer();

    // CLIENT span: represents the outbound call from this service's perspective.
    auto span  = tracer->StartSpan("HTTP GET " + url, ChildOf(trace::SpanKind::kClient));
    trace::Scope scope(span);

    // Derive host/port from the actual URL so span attributes reflect the real target.
    auto [peer_host, peer_port] = ParseHostPort(url, 80);

    span->SetAttribute("http.method",         "GET");
    span->SetAttribute("http.url",            url);
    // Old semconv peer attributes (OTel < 1.20)
    span->SetAttribute("net.peer.name",       peer_host);
    span->SetAttribute("net.peer.port",       peer_port);
    // New semconv equivalents (OTel >= 1.20) — allows backends to correlate this
    // CLIENT span with the downstream service's SERVER span across semconv versions.
    span->SetAttribute("server.address",      peer_host);
    span->SetAttribute("server.port",         peer_port);
    span->SetAttribute("url.full",            url);
    span->SetAttribute("http.request.method", "GET");

    // ── Inject W3C context into outgoing headers ──────────────────────────────
    // The propagator writes "traceparent: 00-<traceId>-<spanId>-01" (and
    // optionally "tracestate") into carrier.headers.  The java-receiver's OTel
    // Java Agent reads those headers and automatically creates a SERVER child span,
    // connecting the Java span to this C++ CLIENT span in a single trace.
    CurlHeaderCarrier carrier;
    propagation::GlobalTextMapPropagator::GetGlobalPropagator()
        ->Inject(carrier, ctx::RuntimeContext::GetCurrent());

    // Log the injected traceparent to confirm the same trace ID is carried forward
    // to java-receiver.
    for (auto& [k, v] : carrier.headers)
        if (k == "traceparent")
            std::cout << "[cpp-service] Injected  traceparent into java-receiver: "
                      << v << std::endl;

    struct curl_slist* hlist = nullptr;
    for (auto& [k, v] : carrier.headers)
        hlist = curl_slist_append(hlist, (k + ": " + v).c_str());

    std::string body;
    long        status = 0;
    CURL* curl = curl_easy_init();
    if (curl)
    {
        curl_easy_setopt(curl, CURLOPT_URL,           url.c_str());
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER,    hlist);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, CurlWrite);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA,     &body);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT,       5L);
        curl_easy_perform(curl);
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        curl_easy_cleanup(curl);
    }
    curl_slist_free_all(hlist);

    span->SetAttribute("http.status_code", static_cast<int>(status));
    if (status == 0 || status >= 400)
        span->SetStatus(trace::StatusCode::kError, "downstream call failed");
    else
        span->SetStatus(trace::StatusCode::kOk);

    span->End();
    return body;
}

// =============================================================================
//  HandleOrder — main request handler
//
//  Demonstrates the full OTel C++ instrumentation lifecycle for one HTTP request:
//
//  1. Extract  — read the incoming W3C traceparent header from java-caller
//  2. Attach   — make the extracted context active so child spans inherit it
//  3. SERVER span  — root span for this service's work
//  4. Child spans  — INTERNAL, CLIENT, and PRODUCER spans for each step
//  5. Span events  — timestamped annotations attached to a span
//  6. Inject   — write traceparent into the downstream call to java-receiver
//  7. Detach   — restore the previous context after the request is done
// =============================================================================

static void HandleOrder(const httplib::Request& req, httplib::Response& res)
{
    auto tracer = GetTracer();

    // ── 1. Extract incoming W3C Trace Context ────────────────────────────────
    // The OTel Java Agent on java-caller automatically injects a "traceparent"
    // header into every outbound RestTemplate call.  Extract() parses it and
    // returns a Context containing the remote SpanContext as the parent.
    // The W3C traceparent format is: 00-<traceId>-<spanId>-<flags>
    // The OTel C++ SDK preserves the trace ID exactly, so the C++ spans share
    // the same trace ID as the java-caller spans in the observability backend.
    HttplibRequestCarrier in_carrier(req.headers);
    auto current_ctx = ctx::RuntimeContext::GetCurrent();
    auto parent_ctx  = propagation::GlobalTextMapPropagator::GetGlobalPropagator()
                           ->Extract(in_carrier, current_ctx);

    // Log the incoming traceparent to confirm context propagation from java-caller.
    auto incoming_tp = req.headers.find("traceparent");
    if (incoming_tp != req.headers.end())
        std::cout << "[cpp-service] Extracted traceparent from java-caller : "
                  << incoming_tp->second << std::endl;
    else
        std::cout << "[cpp-service] No traceparent header — starting a new trace." << std::endl;

    // ── 2. Attach the extracted context ──────────────────────────────────────
    // Attach() installs parent_ctx as the active context on this thread.
    // All spans created while this token is alive will carry the same traceId.
    auto token = ctx::RuntimeContext::Attach(parent_ctx);

    // ── 3. Root SERVER span ───────────────────────────────────────────────────
    // SpanKind::kServer marks this as the entry point of an inbound request.
    // opts.parent = parent_ctx makes it a child of the java-caller CLIENT span.
    trace::StartSpanOptions root_opts;
    root_opts.parent = parent_ctx;
    root_opts.kind   = trace::SpanKind::kServer;

    auto root = tracer->StartSpan("ProcessOrder", root_opts);
    trace::Scope root_scope(root);

    // Derive the listening host/port from the same env vars used at startup.
    const char* srv_host_env = std::getenv("SERVER_HOST");
    const char* srv_port_env = std::getenv("SERVER_PORT");
    std::string srv_host = srv_host_env ? srv_host_env : "localhost";
    int         srv_port = srv_port_env ? std::stoi(std::string(srv_port_env)) : 8080;

    // HTTP semantic attributes — both old semconv (http.*) and new semconv
    // (server.*, network.*) so backends can correlate the inbound CLIENT span
    // from java-caller with this SERVER span regardless of which convention they use.
    root->SetAttribute("http.method",      req.method);
    root->SetAttribute("http.target",      req.path);
    root->SetAttribute("http.route",       "/order");
    root->SetAttribute("http.server_name", "cpp-service");
    root->SetAttribute("http.scheme",      "http");
    root->SetAttribute("http.flavor",      "1.1");
    root->SetAttribute("net.host.name",    srv_host);
    root->SetAttribute("net.host.port",    srv_port);
    // New semconv equivalents (OTel 1.20+)
    root->SetAttribute("server.address",   srv_host);
    root->SetAttribute("server.port",      srv_port);
    root->SetAttribute("url.path",         req.path);
    root->SetAttribute("url.scheme",       "http");
    // Business attributes — describe the work being done
    root->SetAttribute("order.source",     "java-caller");
    root->SetAttribute("order.priority",   "standard");

    // ── 4a. ValidateOrder — INTERNAL span ────────────────────────────────────
    // Demonstrates a fine-grained INTERNAL span for work done entirely within
    // this service.  Uses ChildOf() so it is parented under root via context.
    {
        auto span = tracer->StartSpan("ValidateOrder", ChildOf(trace::SpanKind::kInternal));
        trace::Scope s(span);
        span->SetAttribute("validation.schema",  "order-v2");
        span->SetAttribute("validation.result",  "passed");
        std::this_thread::sleep_for(std::chrono::milliseconds(8));
        span->SetStatus(trace::StatusCode::kOk);
        span->End();
    }

    // ── 4b. ReadCustomerDB — CLIENT span (simulated) ─────────────────────────
    // SpanKind::kClient marks outbound calls.  DB semantic attributes follow
    // the OpenTelemetry database conventions.
    // NOTE: This is a simulated operation — no real database is required.
    // It demonstrates how to annotate a database call with the correct
    // OpenTelemetry semantic attributes.
    {
        auto span = tracer->StartSpan("ReadCustomerDB", ChildOf(trace::SpanKind::kClient));
        trace::Scope s(span);
        span->SetAttribute("db.system",    "sample-db");
        span->SetAttribute("db.name",      "customers");
        span->SetAttribute("db.operation", "SELECT");
        span->SetAttribute("db.statement", "SELECT id, tier FROM customers WHERE id=?");
        std::this_thread::sleep_for(std::chrono::milliseconds(22));
        span->SetStatus(trace::StatusCode::kOk);
        span->End();
    }

    // ── 4c. ChargePayment — CLIENT span (simulated) ──────────────────────────
    // NOTE: This is a simulated operation — no real payment gateway is called.
    // It demonstrates RPC semantic attributes and span events.
    {
        auto span = tracer->StartSpan("ChargePayment", ChildOf(trace::SpanKind::kClient));
        trace::Scope s(span);
        span->SetAttribute("rpc.system",       "http");
        span->SetAttribute("rpc.service",      "PaymentGateway");
        span->SetAttribute("rpc.method",       "Charge");
        span->SetAttribute("payment.method",   "credit_card");
        span->SetAttribute("payment.currency", "USD");
        // Span event: a timestamped annotation on this span (not a new span).
        // Use events for discrete moments within a span's lifetime — here, the
        // instant the authorisation response arrives back from the gateway.
        span->AddEvent("payment.processed",
            std::initializer_list<std::pair<nostd::string_view,
                                            opentelemetry::common::AttributeValue>>{
                {"payment.result",  "authorized"},
                {"payment.gateway", "SampleGateway"},
            });
        std::this_thread::sleep_for(std::chrono::milliseconds(35));
        span->SetStatus(trace::StatusCode::kOk);
        span->End();
    }

    // ── 4d. UpdateInventory — INTERNAL span ──────────────────────────────────
    {
        auto span = tracer->StartSpan("UpdateInventory", ChildOf(trace::SpanKind::kInternal));
        trace::Scope s(span);
        span->SetAttribute("inventory.warehouse", "WH-EAST-01");
        span->SetAttribute("inventory.action",    "decrement");
        span->SetAttribute("inventory.qty",        1);
        std::this_thread::sleep_for(std::chrono::milliseconds(12));
        span->SetStatus(trace::StatusCode::kOk);
        span->End();
    }

    // ── 4e. PublishShipment — PRODUCER span (simulated) ──────────────────────
    // SpanKind::kProducer marks a fire-and-forget message publish.
    // Messaging semantic conventions (messaging.system, messaging.destination,
    // messaging.operation) distinguish async publish spans from synchronous
    // CLIENT spans in trace visualisation tools.
    // NOTE: This is a simulated operation — no real message broker is required.
    // Replace messaging.system with your actual broker (rabbitmq, kafka, etc.)
    // when connecting to a real system.
    {
        auto span = tracer->StartSpan("PublishShipment", ChildOf(trace::SpanKind::kProducer));
        trace::Scope s(span);
        span->SetAttribute("messaging.system",      "sample-mq");
        span->SetAttribute("messaging.destination", "shipment.queue");
        span->SetAttribute("messaging.operation",   "publish");
        span->SetAttribute("messaging.message_id",  "msg-sample-001");
        span->AddEvent("message.enqueued",
            std::initializer_list<std::pair<nostd::string_view,
                                            opentelemetry::common::AttributeValue>>{
                {"queue.depth", 3},
            });
        std::this_thread::sleep_for(std::chrono::milliseconds(18));
        span->SetStatus(trace::StatusCode::kOk);
        span->End();
    }

    // ── 4f. NotifyCustomer — CLIENT span to java-receiver ────────────────────
    // This is the live downstream call that carries the real traceparent header.
    // CallDownstream() creates the CLIENT span and injects the context itself.
    root->AddEvent("downstream.notification.start");
    const char* recv_env = std::getenv("JAVA_RECEIVER_URL");
    std::string recv_url = recv_env
        ? std::string(recv_env) + "/ping"
        : "http://localhost:8081/ping";
    std::string downstream_reply = CallDownstream(recv_url);
    root->AddEvent("downstream.notification.complete");

    // ── 5. Finalise root span ─────────────────────────────────────────────────
    root->SetAttribute("http.status_code", 200);
    root->SetAttribute("order.processed",  true);
    root->SetStatus(trace::StatusCode::kOk);
    root->End();

    // ── 6. Detach the extracted context ──────────────────────────────────────
    // Restores the context that was active before Attach() was called.
    ctx::RuntimeContext::Detach(*token);

    res.set_content("order processed — notify: " + downstream_reply, "text/plain");
}

// =============================================================================
//  main
// =============================================================================

int main()
{
    curl_global_init(CURL_GLOBAL_DEFAULT);
    InitTelemetry();

    const char* port_env = std::getenv("SERVER_PORT");
    int port = port_env ? std::stoi(std::string(port_env)) : 8080;

    const char* svc = std::getenv("OTEL_SERVICE_NAME");
    std::cout << "=============================================" << std::endl;
    std::cout << " OpenTelemetry C++ — cpp-service"             << std::endl;
    std::cout << "=============================================" << std::endl;
    std::cout << " Service  : " << (svc ? svc : "cpp-service")  << std::endl;
    std::cout << " Port     : " << port                          << std::endl;
    std::cout << " OTLP     : " << (std::getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
                                     ? std::getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
                                     : "localhost:4317")         << std::endl;
    std::cout << " Receiver : " << (std::getenv("JAVA_RECEIVER_URL")
                                     ? std::getenv("JAVA_RECEIVER_URL")
                                     : "http://localhost:8081")  << std::endl;
    std::cout << "=============================================" << std::endl;
    std::cout << std::endl;

    httplib::Server svr;

    // ── /order — full instrumentation showcase ────────────────────────────────
    svr.Get("/order",  HandleOrder);

    // ── /health — liveness probe (no tracing needed) ─────────────────────────
    svr.Get("/health", [](const httplib::Request&, httplib::Response& r) {
        r.set_content("OK", "text/plain");
    });

    // ── Signal handler — graceful shutdown on SIGTERM / SIGINT ───────────────
    // Stops the HTTP server so svr.listen() returns and the shutdown sequence
    // (ForceFlush + Shutdown) runs before the process exits.  Without this,
    // a process termination signal would discard spans still buffered in the
    // BatchSpanProcessor queue.
    //
    // SIGTERM and SIGINT are POSIX signals supported on Linux and AIX.
    // On Windows, CTRL_C_EVENT/CTRL_BREAK_EVENT are used instead; std::signal
    // with SIGINT maps to Ctrl-C in a Windows console, which is sufficient for
    // interactive use.  For Windows service scenarios, replace with
    // SetConsoleCtrlHandler().
    //
    // An atomic flag is set by the signal handler.  A watcher thread polls the
    // flag and calls svr.stop() — signal handlers must not call non-async-safe
    // functions directly, so the stop is delegated to the watcher thread.
    static std::atomic<bool> g_stop{false};
    std::signal(SIGINT,  [](int) { g_stop.store(true); });
    std::signal(SIGTERM, [](int) { g_stop.store(true); });

    std::thread watcher([&svr]() {
        while (!g_stop.load())
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        svr.stop();
    });

    std::cout << "Listening on :" << port
              << " — waiting for requests from java-caller..." << std::endl;
    svr.listen("0.0.0.0", port);   // blocks until svr.stop() is called

    watcher.join();
    ShutdownTelemetry();           // ForceFlush + Shutdown — flushes all buffered spans
    curl_global_cleanup();
    return 0;
}
