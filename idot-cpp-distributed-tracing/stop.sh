#!/usr/bin/env bash
# stop.sh — stops all services started by run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS_FILE="$SCRIPT_DIR/.pids"

if [[ ! -f "$PIDS_FILE" ]]; then
  echo "No .pids file found. Services may not be running."
  exit 0
fi

echo "Stopping services..."
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
echo "Done."
