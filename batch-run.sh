#!/bin/bash

# -- number of times to repeat the whole sweep
REPEATS=1

# -- setting arrays
MEMCACHED_CORES_arr=(0-3)
MEMCACHED_THREADS_arr=(4)
MEMTIER_CORES_arr=(4-7)
THREADS_arr=(4)
CONNECTIONS_arr=(1 8 32)
PIPELINE_arr=(16)
DURATION_arr=(60)
RATIO_arr=(1:10)
PROTOCOL_arr=(memcache_text)
DATA_SIZE_arr=(32)
KEY_PATTERN_arr=(R:R)
RATE_LIMIT_arr=("")          # "" = unlimited

[[ -x ./run.sh ]] || { echo "ERROR: ./run.sh not found or not executable" >&2; exit 1; }

total=$(( REPEATS \
    * ${#MEMCACHED_CORES_arr[@]} * ${#MEMCACHED_THREADS_arr[@]} \
    * ${#MEMTIER_CORES_arr[@]} * ${#THREADS_arr[@]} \
    * ${#CONNECTIONS_arr[@]} * ${#PIPELINE_arr[@]} * ${#DURATION_arr[@]} \
    * ${#RATIO_arr[@]} * ${#PROTOCOL_arr[@]} * ${#DATA_SIZE_arr[@]} \
    * ${#KEY_PATTERN_arr[@]} * ${#RATE_LIMIT_arr[@]} ))
count=0

echo "batch-run: $total run(s) total — $REPEATS repeat(s) of the sweep"

for rep in $(seq 1 "$REPEATS"); do                      # top layer: repeats
  for mc in "${MEMCACHED_CORES_arr[@]}"; do             # sub-layers: settings
   for mt in "${MEMCACHED_THREADS_arr[@]}"; do
    for tc in "${MEMTIER_CORES_arr[@]}"; do
     for th in "${THREADS_arr[@]}"; do
      for cn in "${CONNECTIONS_arr[@]}"; do
       for pl in "${PIPELINE_arr[@]}"; do
        for du in "${DURATION_arr[@]}"; do
         for ra in "${RATIO_arr[@]}"; do
          for pr in "${PROTOCOL_arr[@]}"; do
           for ds in "${DATA_SIZE_arr[@]}"; do
            for kp in "${KEY_PATTERN_arr[@]}"; do
             for rl in "${RATE_LIMIT_arr[@]}"; do
              count=$(( count + 1 ))
              echo ""
              echo "=== [batch $count/$total] repeat=$rep | mc-cores=$mc mc-threads=$mt | memtier-cores=$tc threads=$th conn=$cn pipeline=$pl dur=$du ratio=$ra proto=$pr data=$ds key=$kp rate=${rl:-inf} ==="
              MEMCACHED_CORES="$mc" \
              MEMCACHED_THREADS="$mt" \
              MEMTIER_CORES="$tc" \
              THREADS="$th" \
              CONNECTIONS="$cn" \
              PIPELINE="$pl" \
              DURATION="$du" \
              RATIO="$ra" \
              PROTOCOL="$pr" \
              DATA_SIZE="$ds" \
              KEY_PATTERN="$kp" \
              RATE_LIMIT="$rl" \
              RUN_TAG="rep${rep}" \
              ./run.sh
             done
            done
           done
          done
         done
        done
       done
      done
     done
    done
   done
  done
done

echo ""
echo "batch-run: all $total run(s) complete -> see rst/"
