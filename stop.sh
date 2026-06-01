#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
PID_FILE="$DIST_DIR/memcached/memcached.pid"

if [[ ! -f "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "memcached is not running"
    rm -f "$PID_FILE"
    exit 0
fi

PID="$(cat "$PID_FILE")"
kill "$PID"
# Wait for it to actually exit (memcached has no graceful subcommand)
for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.1
done
rm -f "$PID_FILE"
echo "memcached stopped"
