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
# fuser -k is Linux-specific and not available by default on AIX.
# Use a portable fallback: find the PID via netstat then kill it.
for port in 8080 8081 8082; do
  if command -v fuser >/dev/null 2>&1; then
    # Linux (and AIX with proctools package installed)
    fuser -k "${port}/tcp" 2>/dev/null && echo "  Killed stale process on port $port" || true
  else
    # AIX fallback: netstat -Aan lists sockets with PID; extract and kill
    stale_pid=$(netstat -Aan 2>/dev/null | awk -v p=".$port " '$0 ~ p && /LISTEN/ {print $NF}' | head -1)
    if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
      kill "$stale_pid" 2>/dev/null && echo "  Killed stale process on port $port (PID $stale_pid)" || true
    fi
  fi
done

echo "Done."
