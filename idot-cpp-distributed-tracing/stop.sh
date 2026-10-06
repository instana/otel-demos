#!/usr/bin/env bash
# stop.sh — stops all services started by run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS_FILE="$SCRIPT_DIR/.pids"

echo "Stopping services..."

# ── 1. Kill by recorded PIDs ──────────────────────────────────────────────────
if [[ -f "$PIDS_FILE" ]]; then
  while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    pid=$(echo "$line"  | awk '{print $2}')
    if kill -0 "$pid" 2>/dev/null; then
      echo "  Stopping $name (PID $pid)..."
      kill "$pid"
    else
      echo "  $name (PID $pid) already stopped."
    fi
  done < "$PIDS_FILE"
  rm -f "$PIDS_FILE"
fi

# ── 2. Force-free the ports in case any process survived ─────────────────────
for port in 8080 8081 8082; do
  fuser -k "${port}/tcp" 2>/dev/null && echo "  Killed stale process on port $port" || true
done

echo "Done."
