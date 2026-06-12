#!/bin/bash

# -- parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat <<EOF
Usage: $(basename "$0")

Like run.sh, but additionally records per-second CPU utilization of the server
(memcached) and client (memtier) via 'perf stat -e task-clock', and plots it.
run.sh and bench.sh are reused unchanged; this script only layers perf + plotting
around them.

Outputs (in rst/, sharing one param-encoded, UTC-stamped base name prefixed
'perfcpu-'):
  BASE.out         memtier text output (same as run.sh)
  BASE.server.csv  perf task-clock time series for memcached
  BASE.client.csv  perf task-clock time series for memtier
  BASE.cpu.png     CPU-utilization-over-time plot (% of each side's pinned cores)

Server (memcached) and load (memtier) settings come from the same env vars as
run.sh; defaults are baked in below.

Env vars: MEMCACHED_CORES MEMCACHED_THREADS MEMTIER_CORES THREADS CONNECTIONS
          PIPELINE DURATION RATIO PROTOCOL DATA_SIZE KEY_PATTERN RATE_LIMIT
          RUN_TAG PERF_INTERVAL
EOF
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PID_FILE="$SCRIPT_DIR/dist/memcached/memcached.pid"
MEMTIER="$SCRIPT_DIR/dist/memtier_benchmark"

command -v perf &>/dev/null || { echo "ERROR: perf not found" >&2; exit 1; }

# -- Warn if perf can only see userspace CPU time. As a non-root user with
#    kernel.perf_event_paranoid >= 2, perf records task-clock:u (userspace only),
#    so kernel/syscall/network time is excluded and utilization UNDERCOUNTS the
#    real CPU. Run as root, or lower the gate, to capture full user+kernel time.
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 2)
if [[ "$EUID" -ne 0 && "$PARANOID" -ge 2 ]]; then
    echo "WARNING: running as non-root with kernel.perf_event_paranoid=$PARANOID —" >&2
    echo "         perf will count USERSPACE CPU time only (task-clock:u); kernel/" >&2
    echo "         syscall/network time is excluded, so utilization UNDERCOUNTS real CPU." >&2
    echo "         For full user+kernel CPU, run as root (sudo) or lower the gate once:" >&2
    echo "             sudo sysctl kernel.perf_event_paranoid=1" >&2
fi

# -- memcached (server) settings
MEMCACHED_CORES="${MEMCACHED_CORES:-0-3}"
MEMCACHED_THREADS="${MEMCACHED_THREADS:-4}"

# -- memtier (load) settings
MEMTIER_CORES="${MEMTIER_CORES:-4-7}"

# -- perf sampling interval (ms); 1000 lines up with memtier's per-second lines
PERF_INTERVAL="${PERF_INTERVAL:-1000}"

# count_cores SPEC -> number of CPUs described by a taskset spec like "0-3" or "0,2,4"
count_cores() {
    local spec="$1" n=0 t
    local IFS=','
    for t in $spec; do
        if [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            n=$(( n + ${BASH_REMATCH[2]} - ${BASH_REMATCH[1]} + 1 ))
        elif [[ "$t" =~ ^[0-9]+$ ]]; then
            n=$(( n + 1 ))
        fi
    done
    echo "$n"
}

SERVER_CORES=$(count_cores "$MEMCACHED_CORES")
CLIENT_CORES=$(count_cores "$MEMTIER_CORES")

# THREADS defaults to the number of cores in MEMTIER_CORES (matches run.sh).
if [[ -z "${THREADS:-}" ]]; then
    THREADS="$CLIENT_CORES"
    echo "THREADS auto-set to ${THREADS} from MEMTIER_CORES=${MEMTIER_CORES}"
fi

CONNECTIONS="${CONNECTIONS:-1}"
PIPELINE="${PIPELINE:-16}"
DURATION="${DURATION:-60}"
RATIO="${RATIO:-1:10}"
PROTOCOL="${PROTOCOL:-memcache_text}"
DATA_SIZE="${DATA_SIZE:-32}"
KEY_PATTERN="${KEY_PATTERN:-R:R}"
RATE_LIMIT="${RATE_LIMIT:-}"

# -- output base name (same encoding as run.sh, prefixed 'perfcpu-')
RST_DIR="rst"
mkdir -p "$RST_DIR"
STAMP=$(date -u +%Y%m%d-%H%M%S)
RUN_TAG="${RUN_TAG:-}"
TAG_PART=""
[[ -n "$RUN_TAG" ]] && TAG_PART="_${RUN_TAG}"
RATIO_PART="${RATIO//:/-}"
KEY_PART="${KEY_PATTERN//:/-}"
RL_PART=""
[[ -n "$RATE_LIMIT" ]] && RL_PART="-rl${RATE_LIMIT}"
BASE="${RST_DIR}/perfcpu-memcached-t${MEMCACHED_THREADS}-cpu${MEMCACHED_CORES}_memtier-cpu${MEMTIER_CORES}-t${THREADS}-c${CONNECTIONS}-p${PIPELINE}-d${DURATION}-ratio${RATIO_PART}-data${DATA_SIZE}-key${KEY_PART}${RL_PART}${TAG_PART}_${STAMP}"
OUT="${BASE}.out"
SERVER_CSV="${BASE}.server.csv"
CLIENT_CSV="${BASE}.client.csv"
PNG="${BASE}.cpu.png"

# -- always restart memcached so the running config matches the filename
pgrep -x memcached &>/dev/null && ./stop.sh
MEMCACHED_CORES="$MEMCACHED_CORES" MEMCACHED_THREADS="$MEMCACHED_THREADS" ./start.sh

SERVER_PID="$(cat "$PID_FILE")"

echo "RUN (perf)"
START_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Start: $START_UTC" | tee "$OUT"

# -- attach perf to the server (memcached); runs until we SIGINT it
perf stat -I "$PERF_INTERVAL" -x, -e task-clock -p "$SERVER_PID" -o "$SERVER_CSV" &
SERVER_PERF=$!

# -- assemble bench.sh args (same as run.sh)
BENCH_ARGS=(-t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" -P "$PROTOCOL"
    --pipeline "$PIPELINE" --ratio "$RATIO" --data-size "$DATA_SIZE"
    --key-pattern "$KEY_PATTERN" --keep-server)
[[ -n "$RATE_LIMIT" ]] && BENCH_ARGS+=(--rate-limit "$RATE_LIMIT")

# -- launch the load in the background so we can attach perf to memtier
MEMTIER_CORES="$MEMTIER_CORES" ./bench.sh "${BENCH_ARGS[@]}" > >(tee -a "$OUT") 2>&1 &
BENCH_PID=$!

# -- find the memtier process and attach perf to it. pgrep -f is required:
#    'comm' truncates 'memtier_benchmark' (17 chars) to 15, so pgrep -x misses it.
CLIENT_PID=""
for _ in $(seq 1 50); do
    CLIENT_PID=$(pgrep -f "$MEMTIER" | head -1)
    [[ -n "$CLIENT_PID" ]] && break
    sleep 0.1
done

CLIENT_PERF=""
if [[ -n "$CLIENT_PID" ]]; then
    perf stat -I "$PERF_INTERVAL" -x, -e task-clock -p "$CLIENT_PID" -o "$CLIENT_CSV" &
    CLIENT_PERF=$!
else
    echo "WARNING: could not find memtier process to attach perf (client CSV will be empty)" >&2
fi

# -- wait for the load to finish, then stop the perf collectors so they flush
wait "$BENCH_PID"
kill -INT "$SERVER_PERF" ${CLIENT_PERF:+"$CLIENT_PERF"} 2>/dev/null || true
wait "$SERVER_PERF" 2>/dev/null || true
[[ -n "$CLIENT_PERF" ]] && wait "$CLIENT_PERF" 2>/dev/null || true

END_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "End:   $END_UTC" | tee -a "$OUT"

# -- leave a clean server state
./stop.sh

# -- plot (non-fatal: artifacts above are already saved if this fails)
TITLE="memcached cpu${MEMCACHED_CORES}/t${MEMCACHED_THREADS} vs memtier cpu${MEMTIER_CORES}/t${THREADS} c${CONNECTIONS} p${PIPELINE} ratio${RATIO} key${KEY_PATTERN}"
if python3 plot-cpu.py \
        --server "$SERVER_CSV" --client "$CLIENT_CSV" --out "$PNG" \
        --server-cores "$SERVER_CORES" --client-cores "$CLIENT_CORES" \
        --title "$TITLE"; then
    echo "DONE -> $OUT"
    echo "        $SERVER_CSV"
    echo "        $CLIENT_CSV"
    echo "        $PNG"
else
    echo "WARNING: plotting failed; CSV time series are still available:" >&2
    echo "        $SERVER_CSV" >&2
    echo "        $CLIENT_CSV" >&2
    echo "DONE -> $OUT"
fi
