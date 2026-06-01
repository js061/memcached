# memcached-bench

Standalone memcached benchmark pipeline. Replicates the [Phoronix Test Suite](https://www.phoronix-test-suite.com/) `pts/memcached` profile without the PTS wrapper, giving full control over every benchmark parameter.

Uses **memcached 1.6.42** as the server under test and **memtier_benchmark 2.3.1** (RedisLabs) as the load generator — the same pair PTS uses. Everything is compiled locally into `dist/` — no system-wide installation needed.

This is the memcached sibling of [`nginx-bench`](../nginx-bench); the script layout (`setup` → `install` → `start`/`stop` → `bench` → `run` → `batch-run`) is intentionally identical.

## Prerequisites

```bash
./setup.sh
```

Detects your distro (Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, macOS) and installs the required packages — `gcc`, `make`, the autotools (`autoconf`/`automake`/`libtool`), `pkg-config`, `libevent`, `pcre`, `zlib`, `openssl`, `curl` — via the appropriate package manager. Prints a verification summary at the end.

## Quick Start

```bash
./install.sh          # download, compile (one-time)
./bench.sh            # start memcached, run benchmark, stop memcached
./run.sh              # single run, saves output to rst/
./batch-run.sh        # sweep many configs (edit arrays at the top first)
```

## Scripts

### `install.sh`

Downloads sources (SHA256-verified), compiles memcached and memtier_benchmark. All output goes into `dist/`. memcached needs no config file or TLS certificate — it is configured entirely via CLI flags at start time.

```bash
./install.sh
```

Re-running is safe — already-downloaded files are verified by SHA256 and skipped.

> **Running as root:** memcached refuses to start as root unless `-u root` is supplied. `start.sh` and `bench.sh` add that flag automatically when they detect `EUID == 0`, so no source patch is needed.

### `start.sh` / `stop.sh`

Start and stop the memcached server manually. Useful when running multiple back-to-back benchmarks without restarting the server each time.

```bash
./start.sh
./stop.sh
```

`start.sh` is a no-op if memcached is already running (tracked via a pidfile at `dist/memcached/memcached.pid`). Server settings and CPU affinity are controlled via environment variables:

| Env var | Description |
|---------|-------------|
| `MEMCACHED_PORT` | Listen port (default: `11211`) |
| `MEMCACHED_THREADS` | Worker threads, memcached `-t` (default: `nproc`) |
| `MEMCACHED_MEMORY` | Item memory in MB, memcached `-m` (default: `1024`) |
| `MEMCACHED_MAXCONN` | Max simultaneous connections, memcached `-c` (default: `4096`) |
| `MEMCACHED_CORES` | Pin memcached to specific CPU cores via `taskset` — list (`0,2,4`), range (`0-3`), or mix (`0-3,6`) (default: unpinned) |

```bash
MEMCACHED_THREADS=4 ./start.sh                    # 4 worker threads
MEMCACHED_CORES=0-3 MEMCACHED_THREADS=4 ./start.sh # pinned to cores 0-3
```

### `bench.sh`

Runs a full benchmark with memtier_benchmark. By default it manages the memcached lifecycle (starts before, stops after). Pass `--keep-server` to skip that if memcached is already up.

```bash
./bench.sh [OPTIONS]
```

| Option | Default | memtier arg | Description |
|--------|---------|-------------|-------------|
| `-t THREADS` | `$(nproc)` | `-t` | memtier threads |
| `-c CONNECTIONS` | `1` | `-c` | connections **per thread** |
| `-d DURATION` | `60` | `--test-time` | test duration in seconds |
| `-P PROTOCOL` | `memcache_text` | `-P` | `memcache_text` or `memcache_binary` |
| `--pipeline N` | `16` | `--pipeline` | requests pipelined per connection |
| `--ratio SET:GET` | `1:10` | `--ratio` | set-to-get ratio |
| `--data-size N` | `32` | `--data-size` | value size in bytes |
| `--key-pattern P` | `R:R` | `--key-pattern` | key access pattern (see below) |
| `--key-max N` | memtier default | `--key-maximum` | highest key index used |
| `--rate-limit N` | unlimited | `--rate-limiting` | throttle to N req/s **per connection** |
| `--keep-server` | — | — | skip memcached start/stop |
| `-h` | — | — | show help |

CPU affinity for memtier is controlled via an environment variable:

| Env var | Description |
|---------|-------------|
| `MEMTIER_CORES` | Pin memtier to specific CPU cores via `taskset` — list (`0,2,4`), range (`0-3`), or mix. Pair it with `start.sh`'s `MEMCACHED_CORES` to keep the load generator and the server on separate cores. |

```bash
MEMTIER_CORES=4-7 ./bench.sh -t 4 -c 8 -d 30     # memtier on cores 4-7
```

#### Workload knobs

Where `nginx-bench` shapes the load with `--rps` / `--rps-dist` (a Lua `delay()` hook in wrk), memtier_benchmark exposes its own native controls. These are the knobs that vary the memcached workload:

| Knob | What it does |
|---|---|
| `--ratio SET:GET` | Mix of writes vs reads. `1:10` = read-heavy (typical cache); `1:1` = balanced; `5:1` = write-heavy. |
| `--key-pattern P` | Key access distribution, as `SET:GET`. Each side is one of `R` (random — uniform), `G` (gaussian — hot-spot around the middle of the key range), `S` (sequential), `P` (parallel sequential). `G:G` models a hot working set; `R:R` (default) spreads load uniformly. |
| `--pipeline N` | How many requests are in flight per connection before waiting for replies — raises throughput at the cost of per-request latency realism. |
| `--data-size N` | Value payload size in bytes. |
| `--rate-limit N` | Cap each connection at N requests/sec (the throttle analog of nginx-bench's `--rps`). Omit for max-throughput. |

### `run.sh`

Single-run driver: stops any running memcached, starts it with the configured CPU affinity, runs one benchmark via `bench.sh`, and saves the full output (with UTC `Start:` / `End:` timestamps) to a file in `rst/`. Filenames encode every config parameter plus a UTC timestamp, so repeated runs accumulate without overwriting.

```bash
./run.sh                                          # use the defaults baked into run.sh
MEMCACHED_CORES=0-7 MEMTIER_CORES=8-11 ./run.sh   # override any setting via env var
RATIO=1:1 KEY_PATTERN=G:G ./run.sh                # write-balanced, hot-spot keys
RATE_LIMIT=50000 ./run.sh                         # throttle each connection
```

**Override env vars:** `MEMCACHED_CORES`, `MEMCACHED_THREADS`, `MEMTIER_CORES`, `THREADS`, `CONNECTIONS`, `PIPELINE`, `DURATION`, `RATIO`, `PROTOCOL`, `DATA_SIZE`, `KEY_PATTERN`, `RATE_LIMIT`, plus optional `RUN_TAG` injected into the filename.

If you set `MEMTIER_CORES` but not `THREADS`, `THREADS` is auto-derived from the `MEMTIER_CORES` core count, so the load generator uses exactly its pinned cores.

The result is parsed the same way PTS does it — the `Totals` line of memtier's output carries the headline **Ops/sec**:

```
Totals      812345.67    ...    Ops/sec
```

### `batch-run.sh`

Sweeps the Cartesian product of setting arrays, optionally repeated `REPEATS` times (outermost loop). Each iteration calls `run.sh` with the right env vars; outputs go to `rst/` with the repeat number in the filename. Edit the arrays at the top of the script to define a sweep.

```bash
# inside batch-run.sh
REPEATS=3
CONNECTIONS_arr=(1 8 32)
RATIO_arr=(1:10 1:1)
KEY_PATTERN_arr=(R:R G:G)
# ... etc.

./batch-run.sh   # prints [batch X/total] progress for each combination
```

`run.sh` always restarts memcached, so each combination gets a clean server with the right affinity.

## Examples

```bash
# Match the PTS pts/memcached default exactly
./bench.sh -t 10 -c 1 -P memcache_text --pipeline 16 -d 60 --ratio 1:10

# Quick exploratory run
./bench.sh -c 16 -d 10

# Write-heavy workload
./bench.sh --ratio 5:1 -c 16 -d 30

# Hot-spot key access (gaussian) to stress a small working set
./bench.sh --key-pattern G:G --key-max 100000 -c 16 -d 30

# Binary protocol
./bench.sh -P memcache_binary -c 16 -d 30

# Throttle each connection to a fixed rate instead of max throughput
./bench.sh --rate-limit 50000 -c 8 -d 30

# Isolate load generator and server on separate cores
MEMCACHED_CORES=0-3 MEMCACHED_THREADS=4 ./start.sh
MEMTIER_CORES=4-7 ./bench.sh -t 4 -c 8 --keep-server
./stop.sh

# Sweep connection counts and key patterns (edit batch-run.sh arrays, then)
./batch-run.sh
```

## Directory Layout

After `install.sh`:

```
dist/
├── downloads/                       cached source tarballs (SHA256-verified)
│   ├── memcached-1.6.42.tar.gz
│   └── memtier_benchmark-2.3.1.tar.gz
├── memcached/
│   ├── bin/memcached                memcached binary
│   └── memcached.pid                pidfile (while running)
└── memtier_benchmark                memtier_benchmark binary

rst/                                 benchmark output files (created by run.sh / batch-run.sh)
└── memcached-t4-cpu0-3_memtier-cpu4-7-t4-c1-p16-d60-ratio1-10-data32-keyR-R_rep1_20260531-205500.out
```
