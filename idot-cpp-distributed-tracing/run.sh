#!/usr/bin/env bash
# run.sh — starts all three services of the distributed tracing sample
#
# Supported on: Linux, AIX (Bash required)
# Windows: see README.md — "Building and running on Windows"
#
# Topology:
#   java-caller  (port 8082)  → HTTP GET /order  + W3C traceparent →
#   cpp-service  (port 8080)  → HTTP GET /ping   + W3C traceparent →
#   java-receiver(port 8081)  → OTLP/gRPC → OpenTelemetry Collector
#
# Instrumentation:
#   java-caller  / java-receiver — auto-instrumented by the OpenTelemetry Java Agent
#                                  attached to their JVMs via -javaagent.
#   cpp-service                  — OpenTelemetry C++ SDK; exports spans via OTLP/gRPC
#                                  to the endpoint in CPP_OTLP_ENDPOINT.
#
# Required environment variable:
#   OTEL_AGENT   — path to opentelemetry-javaagent.jar
#                  Download from:
#                  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases
#
# Trigger a trace:
#   curl http://$(hostname -f):8082/order
#
# Enable continuous traffic (one call every 5 s):
#   SCHEDULE_ENABLED=true ./run.sh
#
# Usage:
#   ./run.sh              # start all three services in the background
#   ./run.sh --foreground # run cpp-service in foreground (Ctrl-C to stop all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the OpenTelemetry C++ SDK install directory.
# Override with: IDOT_OTEL_CPP_INSTALL=/path/to/opentelemetry-cpp ./run.sh
IDOT_OTEL_CPP_INSTALL="${IDOT_OTEL_CPP_INSTALL:-}"

# Path to the OpenTelemetry Java Agent JAR.
# Download from:
#   https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases
# Example: OTEL_AGENT=/opt/otel/opentelemetry-javaagent.jar ./run.sh
OTEL_AGENT="${OTEL_AGENT:-}"

if [[ -z "$OTEL_AGENT" ]]; then
  echo "ERROR: OTEL_AGENT is not set."
  echo "       Set it to the path of opentelemetry-javaagent.jar, e.g.:"
  echo "         OTEL_AGENT=/opt/otel/opentelemetry-javaagent.jar ./run.sh"
  echo "       Download from:"
  echo "         https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases"
  exit 1
fi

if [[ ! -f "$OTEL_AGENT" ]]; then
  echo "ERROR: OTEL_AGENT file not found: $OTEL_AGENT"
  exit 1
fi

if [[ -z "$IDOT_OTEL_CPP_INSTALL" ]]; then
  echo "ERROR: IDOT_OTEL_CPP_INSTALL is not set."
  echo "       Set it to the root directory of the OpenTelemetry C++ SDK install, e.g.:"
  echo "         IDOT_OTEL_CPP_INSTALL=/opt/opentelemetry-cpp ./run.sh"
  exit 1
fi

# OTLP/gRPC endpoint that cpp-service sends spans to (any OTel Collector or backend).
CPP_OTLP_ENDPOINT="${CPP_OTLP_ENDPOINT:-localhost:4317}"

# OTLP/gRPC endpoint that the Java services send spans to.
# Defaults to the same collector as cpp-service.
JAVA_OTLP_ENDPOINT="${JAVA_OTLP_ENDPOINT:-http://localhost:4317}"

# Set SCHEDULE_ENABLED=true to have java-caller fire one request every 5 seconds.
# Defaults to false so the developer triggers traces manually with curl.
SCHEDULE_ENABLED="${SCHEDULE_ENABLED:-false}"

# Service ports — override if the defaults conflict with something already on the host.
SERVER_PORT="${SERVER_PORT:-8080}"           # cpp-service listen port
JAVA_RECEIVER_PORT="${JAVA_RECEIVER_PORT:-8081}"  # java-receiver listen port
JAVA_CALLER_PORT="${JAVA_CALLER_PORT:-8082}"      # java-caller listen port

# Inter-service URLs — derived from the ports above, but can be overridden explicitly
# (e.g. when services run on different hosts).
JAVA_RECEIVER_URL="${JAVA_RECEIVER_URL:-http://localhost:${JAVA_RECEIVER_PORT}}"
CPP_SERVICE_URL="${CPP_SERVICE_URL:-http://localhost:${SERVER_PORT}}"

LOGS_DIR="$SCRIPT_DIR/logs"
PIDS_FILE="$SCRIPT_DIR/.pids"
FOREGROUND="${1:-}"

mkdir -p "$LOGS_DIR"

# ── Guard: check artifacts exist ─────────────────────────────────────────────
if [[ ! -f "$SCRIPT_DIR/java-caller/target/java-caller-1.0.0.jar" || \
      ! -f "$SCRIPT_DIR/java-receiver/target/java-receiver-1.0.0.jar" || \
      ! -f "$SCRIPT_DIR/cpp-service/build/cpp-service" ]]; then
  echo "ERROR: Artifacts missing. Run ./build.sh first."
  exit 1
fi

echo "==========================================="
echo " OTel C++ Distributed Tracing — Start"
echo "==========================================="
echo "cpp OTLP      : $CPP_OTLP_ENDPOINT"
echo "Java OTLP     : $JAVA_OTLP_ENDPOINT"
echo "Scheduled     : $SCHEDULE_ENABLED"
echo "cpp-service   : :${SERVER_PORT}  (JAVA_RECEIVER_URL=$JAVA_RECEIVER_URL)"
echo "java-receiver : :${JAVA_RECEIVER_PORT}"
echo "java-caller   : :${JAVA_CALLER_PORT}  (CPP_SERVICE_URL=$CPP_SERVICE_URL)"
echo "Logs          : $LOGS_DIR/"
echo ""
HOST_ADDR="$(hostname -f)"
echo "  Trigger a trace:  curl http://${HOST_ADDR}:${JAVA_CALLER_PORT}/order"
if [[ "$SCHEDULE_ENABLED" == "true" ]]; then
  echo "  Scheduler: enabled (one call every 5 s)"
else
  echo "  Scheduler: disabled — trigger traces manually:"
  echo "    curl http://${HOST_ADDR}:${JAVA_CALLER_PORT}/order"
  echo "  (set SCHEDULE_ENABLED=true to enable continuous traffic)"
fi
echo ""

# ── Helper: start a background process and record its PID ────────────────────
start_bg() {
  local name="$1"; shift
  local log="$LOGS_DIR/${name}.log"
  echo "  Starting $name..."
  "$@" >"$log" 2>&1 &
  local pid=$!
  echo "$name $pid" >> "$PIDS_FILE"
  echo "    PID=$pid  log=$log"
}

# Clear previous PID file
> "$PIDS_FILE"

# ── 1. java-receiver  (port 8081) ────────────────────────────────────────────
# The OTel Java Agent reads the W3C traceparent header injected by cpp-service
# and automatically creates a SERVER child span.
start_bg "java-receiver" \
  java \
  -javaagent:"$OTEL_AGENT" \
  -DOTEL_SERVICE_NAME=java-receiver \
  -DOTEL_EXPORTER_OTLP_ENDPOINT="$JAVA_OTLP_ENDPOINT" \
  -jar "$SCRIPT_DIR/java-receiver/target/java-receiver-1.0.0.jar" \
  --server.port="${JAVA_RECEIVER_PORT}"

# Give receiver time to bind its port before the C++ service tries to call it.
sleep 5

# ── 2. cpp-service  (port 8080) ──────────────────────────────────────────────
# Instrumented by the OpenTelemetry C++ SDK. Exports spans via OTLP/gRPC.
#
# Runtime shared-library path differs by platform:
#   Linux  — LD_LIBRARY_PATH, SDK libraries in lib64/
#   AIX    — LIBPATH,         SDK libraries in lib/
# Detect AIX via uname and set the correct variable and directory.
if [[ "$(uname)" == "AIX" ]]; then
  SDK_LIB_DIR="$IDOT_OTEL_CPP_INSTALL/lib"
  CPP_ENV=(
    env
    OTEL_SERVICE_NAME=cpp-service
    OTEL_EXPORTER_OTLP_ENDPOINT="$CPP_OTLP_ENDPOINT"
    SERVER_PORT="$SERVER_PORT"
    JAVA_RECEIVER_URL="$JAVA_RECEIVER_URL"
    LIBPATH="$SDK_LIB_DIR${LIBPATH:+:$LIBPATH}"
  )
else
  SDK_LIB_DIR="$IDOT_OTEL_CPP_INSTALL/lib64"
  CPP_ENV=(
    env
    OTEL_SERVICE_NAME=cpp-service
    OTEL_EXPORTER_OTLP_ENDPOINT="$CPP_OTLP_ENDPOINT"
    SERVER_PORT="$SERVER_PORT"
    JAVA_RECEIVER_URL="$JAVA_RECEIVER_URL"
    LD_LIBRARY_PATH="$SDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  )
fi

JAVA_CALLER_ARGS=(
  java
  -javaagent:"$OTEL_AGENT"
  -DOTEL_SERVICE_NAME=java-caller
  -DOTEL_EXPORTER_OTLP_ENDPOINT="$JAVA_OTLP_ENDPOINT"
  -DCPP_SERVICE_URL="$CPP_SERVICE_URL"
  -DSCHEDULE_ENABLED="$SCHEDULE_ENABLED"
  -jar "$SCRIPT_DIR/java-caller/target/java-caller-1.0.0.jar"
  --server.port="${JAVA_CALLER_PORT}"
)

if [[ "$FOREGROUND" == "--foreground" ]]; then
  echo "  Starting cpp-service in foreground (Ctrl-C to stop all)..."

  # java-caller in background
  start_bg "java-caller" "${JAVA_CALLER_ARGS[@]}"
  sleep 2

  trap 'echo ""; echo "Stopping..."; kill $(awk "{print \$2}" "$PIDS_FILE") 2>/dev/null; exit 0' INT TERM
  "${CPP_ENV[@]}" "$SCRIPT_DIR/cpp-service/build/cpp-service"
else
  start_bg "cpp-service" "${CPP_ENV[@]}" "$SCRIPT_DIR/cpp-service/build/cpp-service"
  sleep 2

  # ── 3. java-caller  (port 8082) ──────────────────────────────────────────────
  # The OTel Java Agent creates a CLIENT span for each outbound RestTemplate call
  # and injects W3C traceparent automatically.
  start_bg "java-caller" "${JAVA_CALLER_ARGS[@]}"

  echo ""
  echo "==========================================="
  echo " All services started."
  echo ""
  echo "  java-caller   :${JAVA_CALLER_PORT}  (log: $LOGS_DIR/java-caller.log)"
  echo "  cpp-service   :${SERVER_PORT}  (log: $LOGS_DIR/cpp-service.log)"
  echo "  java-receiver :${JAVA_RECEIVER_PORT}  (log: $LOGS_DIR/java-receiver.log)"
  echo ""
  echo "  Trigger a trace:"
  echo "    curl http://${HOST_ADDR}:${JAVA_CALLER_PORT}/order"
  echo ""
  echo "  cpp-service spans → OTLP/gRPC → $CPP_OTLP_ENDPOINT"
  echo "  Run ./stop.sh to stop all services."
  echo "==========================================="
fi
