#!/usr/bin/env bash
# run.sh — starts all three services of the end-to-end distributed trace demo
#
# Topology:
#   java-caller  (port 8082)  → HTTP GET /order  + W3C traceparent →
#   cpp-service  (port 8080)  → HTTP GET /ping   + W3C traceparent →
#   java-receiver(port 8081)  → OTLP/gRPC → OpenTelemetry Collector :4317
#
# Instrumentation:
#   java-caller  / java-receiver — auto-instrumented by the agent attached to
#                                  their JVMs (no -javaagent flag required).
#   cpp-service                  — IDOT OpenTelemetry C++ library; exports spans
#                                  via OTLP/gRPC to the endpoint in CPP_OTLP_ENDPOINT.
#
# Trigger a trace:
#   curl http://localhost:8082/order
#
# Enable continuous traffic (one call every 5 s):
#   SCHEDULE_ENABLED=true ./run.sh
#
# Usage:
#   ./run.sh              # start all three services in the background
#   ./run.sh --foreground # run cpp-service in foreground (Ctrl-C to stop all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDOT_INSTALL="${IDOT_INSTALL:-/tmp/opentelemetry-cpp}"
# cpp-service exports via OTLP/gRPC to this endpoint (any OTel Collector or Instana Agent).
CPP_OTLP_ENDPOINT="${CPP_OTLP_ENDPOINT:-localhost:4317}"
# Set SCHEDULE_ENABLED=true to have java-caller fire one request every 5 seconds.
SCHEDULE_ENABLED="${SCHEDULE_ENABLED:-true}"
# OTel Java agent — used by java-caller and java-receiver for auto-instrumentation.
OTEL_AGENT="${OTEL_AGENT:-/tmp/opentelemetry-javaagent.jar}"
# IBM MQ connection details for java-receiver.
MQ_HOST="${MQ_HOST:-localhost}"
MQ_PORT="${MQ_PORT:-1414}"
MQ_QMGR="${MQ_QMGR:-ACE.QUEUE.MANAGER}"
MQ_CHANNEL="${MQ_CHANNEL:-ACE.SVRCONN}"
MQ_QUEUE="${MQ_QUEUE:-TEST.QUEUE}"
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
echo " IDOT C++ E2E Tracing Demo — Start"
echo "==========================================="
echo "cpp OTLP      : $CPP_OTLP_ENDPOINT"
echo "MQ            : $MQ_HOST:$MQ_PORT  qmgr=$MQ_QMGR  channel=$MQ_CHANNEL  queue=$MQ_QUEUE"
echo "Scheduled     : $SCHEDULE_ENABLED"
echo "Logs          : $LOGS_DIR/"
echo ""
echo "  Trigger a trace:  curl http://localhost:8082/order"
if [[ "$SCHEDULE_ENABLED" == "true" ]]; then
  echo "  Scheduler: enabled (one call every 5 s)"
else
  echo "  Scheduler: disabled  (set SCHEDULE_ENABLED=false to disable)"
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
# Plain JAR. The auto-instrumentation agent attached to this JVM reads the
# W3C traceparent header injected by cpp-service and creates a SERVER span.
# The JmsTemplate.send() call inside /ping is also auto-instrumented and
# puts a message on IBM MQ, creating a PRODUCER span in the same trace.
start_bg "java-receiver" \
  env \
  MQ_HOST="$MQ_HOST" \
  MQ_PORT="$MQ_PORT" \
  MQ_QMGR="$MQ_QMGR" \
  MQ_CHANNEL="$MQ_CHANNEL" \
  MQ_QUEUE="$MQ_QUEUE" \
  java \
  -javaagent:"$OTEL_AGENT" \
  -DOTEL_SERVICE_NAME=java-receiver \
  -DOTEL_TRACES_EXPORTER=none \
  -jar "$SCRIPT_DIR/java-receiver/target/java-receiver-1.0.0.jar" \
  --server.port=8081

# Give receiver time to bind its port before the C++ service tries to call it.
sleep 5

# ── 2. cpp-service  (port 8080) ──────────────────────────────────────────────
# Instrumented by the IDOT C++ library. Exports spans via OTLP/gRPC.
CPP_ENV=(
  env
  OTEL_SERVICE_NAME=cpp-service
  OTEL_EXPORTER_OTLP_ENDPOINT="$CPP_OTLP_ENDPOINT"
  SERVER_PORT=8080
  JAVA_RECEIVER_URL=http://localhost:8081
  LD_LIBRARY_PATH="$IDOT_INSTALL/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
)
JAVA_CALLER_ARGS=(
  java
  -javaagent:"$OTEL_AGENT"
  -DOTEL_SERVICE_NAME=java-caller
  -DOTEL_TRACES_EXPORTER=none
  -DCPP_SERVICE_URL=http://localhost:8080
  -DSCHEDULE_ENABLED="$SCHEDULE_ENABLED"
  -jar "$SCRIPT_DIR/java-caller/target/java-caller-1.0.0.jar"
  --server.port=8082
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
  # Plain JAR. The auto-instrumentation agent creates a CLIENT span for each
  # outbound RestTemplate call and injects W3C traceparent automatically.
  start_bg "java-caller" "${JAVA_CALLER_ARGS[@]}"

  echo ""
  echo "==========================================="
  echo " All services started."
  echo ""
  echo "  java-caller   :8082  (log: $LOGS_DIR/java-caller.log)"
  echo "  cpp-service   :8080  (log: $LOGS_DIR/cpp-service.log)"
  echo "  java-receiver :8081  (log: $LOGS_DIR/java-receiver.log)"
  echo ""
  echo "  Trigger a trace:"
  echo "    curl http://localhost:8082/order"
  echo ""
  echo "  cpp-service spans → OTLP/gRPC → $CPP_OTLP_ENDPOINT"
  echo "  Run ./stop.sh to stop all services."
  echo "==========================================="
fi
