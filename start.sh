#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
MEMCACHED="$DIST_DIR/memcached/bin/memcached"
PID_FILE="$DIST_DIR/memcached/memcached.pid"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h]

Starts the benchmark memcached server (daemonized). No-op if already running.

Server settings and CPU affinity are controlled via environment variables:
  MEMCACHED_PORT     listen port                     (default: 11211)
  MEMCACHED_THREADS  number of worker threads (-t)   (default: nproc)
  MEMCACHED_MEMORY   item memory in MB (-m)          (default: 1024)
  MEMCACHED_MAXCONN  max simultaneous connections (-c)(default: 4096)
  MEMCACHED_CORES    pin memcached to CPU cores via taskset,
                     e.g. 0-3 or 0,2,4,6             (default: unpinned)

Options:
  -h, --help         show this help

Examples:
  ./$(basename "$0")
  MEMCACHED_THREADS=4 ./$(basename "$0")
  MEMCACHED_CORES=0-3 MEMCACHED_THREADS=4 ./$(basename "$0")
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -x "$MEMCACHED" ]] || { echo "ERROR: memcached not found — run install.sh first" >&2; exit 1; }

PORT="${MEMCACHED_PORT:-11211}"
SRV_THREADS="${MEMCACHED_THREADS:-$(nproc)}"
MEMORY="${MEMCACHED_MEMORY:-1024}"
MAXCONN="${MEMCACHED_MAXCONN:-4096}"
MEMCACHED_CORES="${MEMCACHED_CORES:-}"
NUM_CPUS=$(nproc)

for v in PORT SRV_THREADS MEMORY MAXCONN; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "ERROR: $v must be a positive integer, got: ${!v}" >&2; exit 1; }
done

# -- CPU affinity (taskset prefix)
TASKSET=()
if [[ -n "$MEMCACHED_CORES" ]]; then
    command -v taskset &>/dev/null || { echo "ERROR: taskset not found (install util-linux)" >&2; exit 1; }
    CORES=()
    IFS=',' read -ra TOKENS <<< "$MEMCACHED_CORES"
    for token in "${TOKENS[@]}"; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
            (( lo <= hi )) || { echo "ERROR: invalid range: $token" >&2; exit 1; }
            for (( c=lo; c<=hi; c++ )); do CORES+=("$c"); done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            CORES+=("$token")
        else
            echo "ERROR: invalid core spec: $token" >&2; exit 1
        fi
    done
    for core in "${CORES[@]}"; do
        (( core < NUM_CPUS )) || { echo "ERROR: core $core >= nproc ($NUM_CPUS)" >&2; exit 1; }
    done
    CORE_LIST=$(IFS=,; echo "${CORES[*]}")
    TASKSET=(taskset -c "$CORE_LIST")
    echo "CPU affinity: memcached pinned to cores [${CORE_LIST}]"
fi

# -- Already running?
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "memcached is already running (pid $(cat "$PID_FILE"))"
    exit 0
fi

# -- memcached refuses to run as root unless '-u root' is given
RUN_AS=()
if [[ "$EUID" -eq 0 ]]; then
    RUN_AS=(-u root)
fi

mkdir -p "$DIST_DIR/memcached"
"${TASKSET[@]}" "$MEMCACHED" -d -P "$PID_FILE" \
    -l 127.0.0.1 -p "$PORT" -t "$SRV_THREADS" -m "$MEMORY" -c "$MAXCONN" "${RUN_AS[@]}"
sleep 1

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "memcached started (pid $(cat "$PID_FILE"), port $PORT, ${SRV_THREADS} threads, ${MEMORY}MB)"
else
    echo "ERROR: memcached failed to start" >&2
    exit 1
fi
