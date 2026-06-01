#!/bin/bash

# -- parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat <<EOF
Usage: $(basename "$0")

Runs one benchmark via bench.sh, with output saved to rst/. Server (memcached)
and load (memtier) settings come from env vars; defaults are baked into this
script. The output filename encodes every parameter plus a UTC timestamp, so
repeated runs accumulate in rst/ without overwriting.

Env vars: MEMCACHED_CORES MEMCACHED_THREADS MEMTIER_CORES THREADS CONNECTIONS
          PIPELINE DURATION RATIO PROTOCOL DATA_SIZE KEY_PATTERN RATE_LIMIT
          RUN_TAG
EOF
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -- memcached (server) settings
MEMCACHED_CORES="${MEMCACHED_CORES:-0-3}"
MEMCACHED_THREADS="${MEMCACHED_THREADS:-4}"

# -- memtier (load) settings
MEMTIER_CORES="${MEMTIER_CORES:-4-7}"

# THREADS defaults to the number of cores in MEMTIER_CORES (so the load generator
# uses exactly its pinned cores unless the user overrides one of them).
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
if [[ -z "${THREADS:-}" ]]; then
    THREADS=$(count_cores "$MEMTIER_CORES")
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

# -- output file (encodes server + load config plus a UTC timestamp)
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
OUT="${RST_DIR}/memcached-t${MEMCACHED_THREADS}-cpu${MEMCACHED_CORES}_memtier-cpu${MEMTIER_CORES}-t${THREADS}-c${CONNECTIONS}-p${PIPELINE}-d${DURATION}-ratio${RATIO_PART}-data${DATA_SIZE}-key${KEY_PART}${RL_PART}${TAG_PART}_${STAMP}.out"

# -- always restart memcached so the running config matches the filename
pgrep -x memcached &>/dev/null && ./stop.sh
MEMCACHED_CORES="$MEMCACHED_CORES" MEMCACHED_THREADS="$MEMCACHED_THREADS" ./start.sh

# -- assemble bench.sh args
BENCH_ARGS=(-t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" -P "$PROTOCOL"
    --pipeline "$PIPELINE" --ratio "$RATIO" --data-size "$DATA_SIZE"
    --key-pattern "$KEY_PATTERN" --keep-server)
[[ -n "$RATE_LIMIT" ]] && BENCH_ARGS+=(--rate-limit "$RATE_LIMIT")

echo "RUN"
START_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Start: $START_UTC" | tee "$OUT"
MEMTIER_CORES="$MEMTIER_CORES" ./bench.sh "${BENCH_ARGS[@]}" 2>&1 | tee -a "$OUT"
END_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "End:   $END_UTC" | tee -a "$OUT"

# -- leave a clean server state
./stop.sh

echo "DONE -> $OUT"
