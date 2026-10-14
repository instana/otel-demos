#!/usr/bin/env bash
# build.sh — builds all three services of the distributed tracing sample
# Usage: IDOT_OTEL_CPP_INSTALL=<path-to-otelcpp-install> ./build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the OpenTelemetry C++ SDK install directory.
# Set via: IDOT_OTEL_CPP_INSTALL=/path/to/opentelemetry-cpp ./build.sh
IDOT_OTEL_CPP_INSTALL="${IDOT_OTEL_CPP_INSTALL:-}"

if [[ -z "$IDOT_OTEL_CPP_INSTALL" ]]; then
  echo "ERROR: IDOT_OTEL_CPP_INSTALL is not set."
  echo "       Set it to the root directory of the OpenTelemetry C++ SDK install, e.g.:"
  echo "         IDOT_OTEL_CPP_INSTALL=/opt/opentelemetry-cpp ./build.sh"
  exit 1
fi

echo "==========================================="
echo " OTel C++ Distributed Tracing — Build"
echo "==========================================="
echo "OTel C++ install : $IDOT_OTEL_CPP_INSTALL"
echo ""

# ── 1. Build java-caller ─────────────────────────────────────────────────────
# Plain Spring Boot JAR — instrumented at runtime by the OTel Java Agent.
echo "[1/3] Building java-caller..."
cd "$SCRIPT_DIR/java-caller"
mvn -q --no-transfer-progress clean package -DskipTests
echo "      → target/java-caller-1.0.0.jar"

# ── 2. Build java-receiver ───────────────────────────────────────────────────
echo ""
echo "[2/3] Building java-receiver..."
cd "$SCRIPT_DIR/java-receiver"
mvn -q --no-transfer-progress clean package -DskipTests
echo "      → target/java-receiver-1.0.0.jar"

# ── 3. Build cpp-service ─────────────────────────────────────────────────────
echo ""
echo "[3/3] Building cpp-service..."
cd "$SCRIPT_DIR/cpp-service"
# grep -E (ERE) is GNU-specific; AIX default grep may not support it.
# Use grep -e with basic patterns, or skip the filter on AIX entirely.
if [[ "$(uname)" == "AIX" ]]; then
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$IDOT_OTEL_CPP_INSTALL" \
    -DCMAKE_VERBOSE_MAKEFILE=OFF \
    -Wno-dev
else
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$IDOT_OTEL_CPP_INSTALL" \
    -DCMAKE_VERBOSE_MAKEFILE=OFF \
    -Wno-dev \
    2>&1 | grep -E "^(--|CMake|Found|error)" || true
fi
# nproc is Linux-specific; on AIX use: lsdev -Cc processor | wc -l
NPROC=$(nproc 2>/dev/null || lsdev -Cc processor 2>/dev/null | wc -l || echo 1)
cmake --build build -j"$NPROC"
echo "      → build/cpp-service"

echo ""
echo "==========================================="
echo " Build complete. Run ./run.sh to start."
echo "==========================================="
