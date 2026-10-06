#!/usr/bin/env bash
# build.sh — builds all three services for the end-to-end distributed trace demo
# Usage: ./build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDOT_INSTALL="${IDOT_INSTALL:-/tmp/opentelemetry-cpp}"

echo "==========================================="
echo " IDOT C++ E2E Tracing Demo — Build"
echo "==========================================="
echo "IDOT install : $IDOT_INSTALL"
echo ""

# ── 1. Build java-caller ─────────────────────────────────────────────────────
# Plain Spring Boot JAR — instrumented by the Instana agent via auto-attach.
# No -javaagent / OTel Java Agent required.
echo "[1/3] Building java-caller..."
cd "$SCRIPT_DIR/java-caller"
mvn -q clean package -DskipTests
echo "      → target/java-caller-1.0.0.jar"

# ── 2. Build java-receiver ───────────────────────────────────────────────────
echo ""
echo "[2/3] Building java-receiver..."
cd "$SCRIPT_DIR/java-receiver"
mvn -q clean package -DskipTests
echo "      → target/java-receiver-1.0.0.jar"

# ── 3. Build cpp-service ─────────────────────────────────────────────────────
echo ""
echo "[3/3] Building cpp-service..."
cd "$SCRIPT_DIR/cpp-service"
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$IDOT_INSTALL" \
  -DCMAKE_VERBOSE_MAKEFILE=OFF \
  -Wno-dev \
  2>&1 | grep -E "^(--|CMake|Found|error)" || true
cmake --build build -j"$(nproc)"
echo "      → build/cpp-service"

echo ""
echo "==========================================="
echo " Build complete. Run ./run.sh to start."
echo "==========================================="
