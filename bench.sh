#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
MEMTIER="$DIST_DIR/memtier_benchmark"
MEMCACHED="$DIST_DIR/memcached/bin/memcached"
PID_FILE="$DIST_DIR/memcached/memcached.pid"

# -- Defaults (match PTS pts/memcached profile)
THREADS="$(nproc)"
CONNECTIONS="1"          # memtier -c, per thread
DURATION="60"            # seconds -> memtier --test-time
PROTOCOL="memcache_text" # memcache_text | memcache_binary
PIPELINE="16"
RATIO="1:10"             # SET:GET
DATA_SIZE="32"
KEY_PATTERN="R:R"        # R=random, G=gaussian, S=sequential, P=parallel-seq
KEY_MAX=""               # memtier --key-maximum (empty = memtier default)
RATE_LIMIT=""            # memtier --rate-limiting (per-connection RPS; empty = unlimited)
PORT="${MEMCACHED_PORT:-11211}"
KEEP_SERVER=""           # if set, don't start/stop memcached — assume it's already running

WRK_NOTE=""
MEMTIER_TASKSET=()       # taskset prefix for memtier, populated if MEMTIER_CORES is set

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Runs a memtier_benchmark load test against memcached. By default it starts
memcached before the run and stops it after; pass --keep-server to skip that.

Options:
  -t THREADS        memtier threads                  (default: nproc = $(nproc))
  -c CONNECTIONS    connections per thread           (default: 1)
  -d DURATION       test duration in seconds         (default: 60)
  -P PROTOCOL       memcache_text | memcache_binary  (default: memcache_text)
  --pipeline N      requests pipelined per connection(default: 16)
  --ratio SET:GET   set-to-get ratio                 (default: 1:10)
  --data-size N     value size in bytes              (default: 32)
  --key-pattern P   key access pattern SET:GET, each of R|G|S|P
                    (R=random G=gaussian S=sequential)(default: R:R)
  --key-max N       highest key index used           (default: memtier default)
  --rate-limit N    throttle to N requests/sec per connection (default: unlimited)
  --keep-server     skip memcached start/stop (use if it is already running)
  -h                show this help

Environment:
  MEMCACHED_PORT    memcached port to target         (default: 11211)
  MEMTIER_CORES     pin memtier to CPU cores, e.g. 0-3 or 0,2,4,6
EOF
    exit 0
}

# -- Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) THREADS="$2";     shift 2 ;;
        -c) CONNECTIONS="$2"; shift 2 ;;
        -d) DURATION="$2";    shift 2 ;;
        -P) PROTOCOL="$2";    shift 2 ;;
        --pipeline)    PIPELINE="$2";    shift 2 ;;
        --ratio)       RATIO="$2";       shift 2 ;;
        --data-size)   DATA_SIZE="$2";   shift 2 ;;
        --key-pattern) KEY_PATTERN="$2"; shift 2 ;;
        --key-max)     KEY_MAX="$2";     shift 2 ;;
        --rate-limit)  RATE_LIMIT="$2";  shift 2 ;;
        --keep-server) KEEP_SERVER=1;    shift ;;
        -h|--help)     usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -x "$MEMTIER" ]]   || { echo "ERROR: memtier_benchmark not found — run install.sh first" >&2; exit 1; }
[[ -x "$MEMCACHED" ]] || { echo "ERROR: memcached not found — run install.sh first" >&2; exit 1; }

case "$PROTOCOL" in
    memcache_text|memcache_binary) ;;
    *) echo "ERROR: -P must be memcache_text or memcache_binary" >&2; exit 1 ;;
esac
for v in THREADS CONNECTIONS DURATION PIPELINE DATA_SIZE; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "ERROR: $v must be a positive integer, got: ${!v}" >&2; exit 1; }
done
[[ "$RATIO" =~ ^[0-9]+:[0-9]+$ ]] || { echo "ERROR: --ratio must look like SET:GET, e.g. 1:10" >&2; exit 1; }
[[ -z "$KEY_MAX"    || "$KEY_MAX"    =~ ^[0-9]+$ ]] || { echo "ERROR: --key-max must be a positive integer" >&2; exit 1; }
[[ -z "$RATE_LIMIT" || "$RATE_LIMIT" =~ ^[0-9]+$ ]] || { echo "ERROR: --rate-limit must be a positive integer" >&2; exit 1; }

# -- CPU affinity for memtier
if [[ -n "${MEMTIER_CORES:-}" ]]; then
    command -v taskset &>/dev/null || { echo "ERROR: taskset not found (install util-linux)" >&2; exit 1; }
    NUM_CPUS=$(nproc)
    CORES=()
    IFS=',' read -ra TOKENS <<< "$MEMTIER_CORES"
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
    MEMTIER_TASKSET=(taskset -c "$CORE_LIST")
    echo "CPU affinity: memtier pinned to cores [${CORE_LIST}]"
fi

# -- Build memtier command
MEMTIER_CMD=("${MEMTIER_TASKSET[@]}" "$MEMTIER"
    -s 127.0.0.1 -p "$PORT" -P "$PROTOCOL"
    -t "$THREADS" -c "$CONNECTIONS"
    --test-time "$DURATION"
    --pipeline "$PIPELINE" --ratio "$RATIO"
    --data-size "$DATA_SIZE" --key-pattern "$KEY_PATTERN"
    --hide-histogram)
[[ -n "$KEY_MAX" ]]    && MEMTIER_CMD+=(--key-maximum "$KEY_MAX")
[[ -n "$RATE_LIMIT" ]] && { MEMTIER_CMD+=(--rate-limiting "$RATE_LIMIT");
                            echo "Rate limit: ${RATE_LIMIT} req/s per connection"; }

# -- Start memcached
mc_started=""
if [[ -z "$KEEP_SERVER" ]]; then
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Using existing memcached (pid $(cat "$PID_FILE"))"
    else
        RUN_AS=()
        [[ "$EUID" -eq 0 ]] && RUN_AS=(-u root)
        mkdir -p "$DIST_DIR/memcached"
        "$MEMCACHED" -d -P "$PID_FILE" -l 127.0.0.1 -p "$PORT" \
            -t "$(nproc)" -m 1024 -c 4096 "${RUN_AS[@]}"
        sleep 1
        mc_started=1
        echo "memcached started (pid $(cat "$PID_FILE"))"
    fi
fi

# -- Run benchmark
echo ""
echo "Running: ${MEMTIER_CMD[*]}"
echo ""
"${MEMTIER_CMD[@]}"

# -- Stop memcached
if [[ -n "$mc_started" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo ""
    echo "memcached stopped"
fi
