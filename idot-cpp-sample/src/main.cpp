#include <algorithm>
#include <chrono>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <thread>
#ifdef _WIN32
#  include <winsock2.h>   // gethostname (must precede windows.h)
#  include <windows.h>    // GetCurrentProcessId
#else
#  include <sys/types.h>
#  include <unistd.h>
#endif

#include <opentelemetry/exporters/otlp/otlp_grpc_exporter_factory.h>
#include <opentelemetry/exporters/otlp/otlp_grpc_exporter_options.h>
#include <opentelemetry/sdk/resource/resource.h>
#include <opentelemetry/semconv/service_attributes.h>
#include <opentelemetry/sdk/trace/simple_processor_factory.h>
#include <opentelemetry/sdk/trace/provider.h>
#include <opentelemetry/sdk/trace/tracer_provider.h>
#include <opentelemetry/sdk/trace/tracer_provider_factory.h>
#include <opentelemetry/trace/noop.h>
#include <opentelemetry/trace/provider.h>
#include <opentelemetry/trace/scope.h>
#include <opentelemetry/trace/span_startoptions.h>
#include <opentelemetry/context/runtime_context.h>

namespace sdktrace = opentelemetry::sdk::trace;
namespace resource = opentelemetry::sdk::resource;
namespace trace    = opentelemetry::trace;
namespace otlp     = opentelemetry::exporter::otlp;
namespace nostd    = opentelemetry::nostd;
namespace ctx      = opentelemetry::context;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

struct Config
{
    std::string service_name    = "otel-sample";
    std::string service_version = "1.0";
    std::string otlp_endpoint   = "localhost:4317";
    bool        insecure        = true;
    int         timeout_ms      = 10000;
    int         iterations      = 5;
};

// Reads config.yaml and populates a Config; falls back to defaults if not found.
static Config LoadConfig(const std::string& filename)
{
    Config cfg;

    std::ifstream file(filename);
    if (!file.is_open())
    {
        std::cerr << "config.yaml not found - using defaults." << std::endl;
        return cfg;
    }

    auto trim = [](const std::string& s) -> std::string {
        const char* ws = " \t\r\n";
        size_t a = s.find_first_not_of(ws);
        if (a == std::string::npos) return {};
        return s.substr(a, s.find_last_not_of(ws) - a + 1);
    };
    auto unquote = [](const std::string& s) -> std::string {
        if (s.size() >= 2 &&
            ((s.front() == '"' && s.back() == '"') ||
             (s.front() == '\'' && s.back() == '\'')))
            return s.substr(1, s.size() - 2);
        return s;
    };

    std::map<std::string, std::string> kv;
    std::string section, line;
    while (std::getline(file, line))
    {
        std::string tr = trim(line);
        if (tr.empty() || tr.front() == '#') continue;

        size_t indent = line.find_first_not_of(" \t");
        size_t colon  = tr.find(':');
        if (colon == std::string::npos) continue;

        std::string key   = trim(tr.substr(0, colon));
        std::string value = unquote(trim(tr.substr(colon + 1)));

        if (indent == 0)
            section = key;
        else if (!section.empty() && !value.empty())
            kv[section + "." + key] = value;
    }

    try
    {
        if (kv.count("service.name"))    cfg.service_name    = kv["service.name"];
        if (kv.count("service.version")) cfg.service_version = kv["service.version"];
        if (kv.count("otlp.endpoint"))   cfg.otlp_endpoint   = kv["otlp.endpoint"];
        if (kv.count("otlp.insecure"))
        {
            std::string v = kv["otlp.insecure"];
            std::transform(v.begin(), v.end(), v.begin(), ::tolower);
            cfg.insecure = (v == "true" || v == "1" || v == "yes");
        }
        if (kv.count("otlp.timeout_ms"))   cfg.timeout_ms  = std::stoi(kv["otlp.timeout_ms"]);
        if (kv.count("sample.iterations")) cfg.iterations  = std::stoi(kv["sample.iterations"]);
    }
    catch (const std::exception& e)
    {
        std::cerr << "Config parse error: " << e.what() << " - using defaults." << std::endl;
    }

    return cfg;
}

// ---------------------------------------------------------------------------
// Telemetry setup / teardown
// ---------------------------------------------------------------------------

static std::shared_ptr<sdktrace::TracerProvider> g_provider;

static void InitTelemetry(const Config& cfg)
{
    otlp::OtlpGrpcExporterOptions options;
    options.endpoint            = cfg.otlp_endpoint;
    options.use_ssl_credentials = !cfg.insecure;
    options.timeout             = std::chrono::milliseconds(cfg.timeout_ms);

    auto exporter  = otlp::OtlpGrpcExporterFactory::Create(options);

    // SimpleSpanProcessor exports each span synchronously on span->End(); sufficient for this sample.
    auto processor = sdktrace::SimpleSpanProcessorFactory::Create(std::move(exporter));

    char hostname[256] = {};
    ::gethostname(hostname, sizeof(hostname) - 1);

#ifdef _WIN32
    int64_t pid = static_cast<int64_t>(::GetCurrentProcessId());
#else
    int64_t pid = static_cast<int64_t>(::getpid());
#endif

    auto res = resource::Resource::Create({
        {opentelemetry::semconv::service::kServiceName,    cfg.service_name},
        {opentelemetry::semconv::service::kServiceVersion, cfg.service_version},
        {"host.name",                                      std::string(hostname)},
        {"process.pid",                                    pid},
    });

    g_provider = sdktrace::TracerProviderFactory::Create(std::move(processor), res);

    std::shared_ptr<trace::TracerProvider> api_provider = g_provider;
    sdktrace::Provider::SetTracerProvider(api_provider);
}

static nostd::shared_ptr<trace::Tracer> GetTracer(const Config& cfg)
{
    return g_provider->GetTracer(cfg.service_name, cfg.service_version);
}

static void ShutdownTelemetry()
{
    if (!g_provider) return;

    g_provider->ForceFlush(std::chrono::milliseconds(10000));
    g_provider->Shutdown();

    // Reset the global provider to a no-op before releasing the SDK provider.
    trace::Provider::SetTracerProvider(
        nostd::shared_ptr<trace::TracerProvider>(new trace::NoopTracerProvider));

    g_provider.reset();
}

// ---------------------------------------------------------------------------
// Sample workload - one root span per order with six child spans
// ---------------------------------------------------------------------------

static trace::StartSpanOptions ChildOpts(trace::SpanKind kind = trace::SpanKind::kInternal)
{
    trace::StartSpanOptions o;
    o.parent = ctx::RuntimeContext::GetCurrent();
    o.kind   = kind;
    return o;
}

static void RunWorkload(const Config& cfg)
{
    auto tracer = GetTracer(cfg);

    for (int i = 1; i <= cfg.iterations; ++i)
    {
        // Root span - SERVER kind marks this as the entry point of the request.
        auto root = tracer->StartSpan("Process Order", ChildOpts(trace::SpanKind::kServer));
        trace::Scope rootScope(root);

        root->SetAttribute("order.id", i);

        std::cout << "[" << i << "/" << cfg.iterations << "] Processing order..." << std::endl;

        // Child spans model the steps of a typical order transaction.
        // Span kinds: CLIENT = outbound call, PRODUCER = async publish.
        struct Step {
            const char*     name;
            const char*     key;
            const char*     val;
            int             ms;
            trace::SpanKind kind;
        };
        for (auto& s : std::initializer_list<Step>{
            {"Validate Request",   "validation.result", "success",       20, trace::SpanKind::kInternal},
            {"Read Customer",      "db.system",         "postgresql",    40, trace::SpanKind::kClient},
            {"Process Payment",    "payment.provider",  "SampleGateway", 35, trace::SpanKind::kClient},
            {"Update Inventory",   "inventory.status",  "updated",       15, trace::SpanKind::kClient},
            {"Publish MQ Message", "messaging.system",  "ibmmq",         25, trace::SpanKind::kProducer},
            {"Send Notification",  "notification.type", "email",         10, trace::SpanKind::kClient},
        })
        {
            auto span = tracer->StartSpan(s.name, ChildOpts(s.kind));
            trace::Scope scope(span);
            span->SetAttribute(s.key, s.val);
            std::this_thread::sleep_for(std::chrono::milliseconds(s.ms));
            span->End();
        }

        root->AddEvent("Order completed");
        root->End();
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main()
{
    Config cfg = LoadConfig("config.yaml");

    std::cout << "=========================================" << std::endl;
    std::cout << " OpenTelemetry C++ Sample"                << std::endl;
    std::cout << "=========================================" << std::endl;
    std::cout << "Service   : " << cfg.service_name         << std::endl;
    std::cout << "Version   : " << cfg.service_version      << std::endl;
    std::cout << "Endpoint  : " << cfg.otlp_endpoint        << std::endl;
    std::cout << "Iterations: " << cfg.iterations           << std::endl;
    std::cout << std::endl;

    InitTelemetry(cfg);
    RunWorkload(cfg);
    ShutdownTelemetry();

    std::cout << std::endl << "Telemetry export completed successfully." << std::endl;

    return 0;
}
