#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
MEMCACHED_VERSION="1.6.42"
MEMTIER_VERSION="2.3.1"
THREADS="$(nproc)"

MEMCACHED_URL="http://www.memcached.org/files/memcached-${MEMCACHED_VERSION}.tar.gz"
MEMCACHED_SHA256="50f08b879d4f9d36dea9d905e9eaade15c708e38db7e9a73fc21dc8b45395de7"
MEMTIER_URL="https://github.com/RedisLabs/memtier_benchmark/archive/refs/tags/${MEMTIER_VERSION}.tar.gz"
MEMTIER_SHA256="0b63a9289399dbf7e04ee2213d0229c831274bb8f64ef8ff2e8f36896aa34146"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

check_sha256() {
    local file="$1" expected="$2"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "SHA256 mismatch for $file (got $actual, expected $expected)"
}

download() {
    local url="$1" dest="$2" sha256="$3"
    if [[ -f "$dest" ]]; then
        info "Already downloaded: $(basename "$dest"), verifying..."
        check_sha256 "$dest" "$sha256"
        return
    fi
    info "Downloading $(basename "$dest")..."
    curl -fL --progress-bar "$url" -o "${dest}.tmp"
    check_sha256 "${dest}.tmp" "$sha256"
    mv "${dest}.tmp" "$dest"
}

# -- Setup
mkdir -p "$DIST_DIR/downloads"

# -- Download
download "$MEMCACHED_URL" "$DIST_DIR/downloads/memcached-${MEMCACHED_VERSION}.tar.gz"          "$MEMCACHED_SHA256"
download "$MEMTIER_URL"   "$DIST_DIR/downloads/memtier_benchmark-${MEMTIER_VERSION}.tar.gz"    "$MEMTIER_SHA256"

# -- Build memcached
info "Building memcached ${MEMCACHED_VERSION}..."
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

tar -xf "$DIST_DIR/downloads/memcached-${MEMCACHED_VERSION}.tar.gz" -C "$BUILD_DIR"
pushd "$BUILD_DIR/memcached-${MEMCACHED_VERSION}" > /dev/null
# memcached refuses to run as root unless '-u root' is passed (handled in start.sh /
# bench.sh) — no source patch needed.
CFLAGS="-O3 -march=native" \
    ./configure --prefix="$DIST_DIR/memcached"
make -j "$THREADS"
make install
popd > /dev/null

# -- Build memtier_benchmark
info "Building memtier_benchmark ${MEMTIER_VERSION}..."
tar -xf "$DIST_DIR/downloads/memtier_benchmark-${MEMTIER_VERSION}.tar.gz" -C "$BUILD_DIR"
pushd "$BUILD_DIR/memtier_benchmark-${MEMTIER_VERSION}" > /dev/null
autoreconf -ivf
./configure
make -j "$THREADS"
cp memtier_benchmark "$DIST_DIR/memtier_benchmark"
popd > /dev/null

info "Installation complete."
echo ""
echo "  memcached binary : $DIST_DIR/memcached/bin/memcached"
echo "  memtier binary   : $DIST_DIR/memtier_benchmark"
echo "  serving on       : 127.0.0.1:11211 (plaintext)"
echo ""
echo "Usage:"
echo "  ./start.sh          # start memcached"
echo "  ./bench.sh          # run benchmark with defaults"
echo "  ./bench.sh -c 50    # 50 connections per thread"
echo "  ./stop.sh           # stop memcached"
