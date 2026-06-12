#!/usr/bin/env bash
set -euo pipefail

# Packages needed before running install.sh:
#   gcc/g++, make           — compile memcached and memtier_benchmark
#   autoconf/automake/libtool — memtier_benchmark autoreconf build
#   pkg-config              — locate libevent / libssl during configure
#   libevent (dev)          — memcached event loop + memtier
#   zlib (dev), openssl (dev) — memtier_benchmark (TLS auto-detected via libssl)
#   curl, ca-certificates   — download source tarballs over HTTPS
#
# Note: memtier_benchmark 2.3.1 no longer depends on PCRE, so libpcre*-dev is
# intentionally omitted. This keeps a single package list valid on Ubuntu 20.04,
# 22.04 and 24.04 — on 24.04 libpcre3-dev is EOL and lives in the (often
# disabled) "universe" component, which would otherwise break the install there.

PKGS_DEBIAN="build-essential autoconf automake libtool pkg-config libevent-dev zlib1g-dev libssl-dev curl ca-certificates"
PKGS_RPM="gcc gcc-c++ make autoconf automake libtool pkgconfig libevent-devel pcre-devel zlib-devel openssl-devel curl"
PKGS_ARCH="base-devel libevent pcre zlib openssl curl"
PKGS_BREW="libevent pcre openssl curl autoconf automake libtool pkg-config"

info()  { echo "==> $*"; }
ok()    { echo "  [OK]  $*"; }
fail()  { echo "  [MISSING] $*"; }

# -- Distro detection
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "macos"
        return
    fi
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|linuxmint|pop)      echo "debian" ;;
            rhel|centos|rocky|almalinux|ol)   echo "rhel"   ;;
            fedora)                            echo "fedora" ;;
            arch|manjaro|endeavouros)          echo "arch"   ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*)  echo "debian" ;;
                    *rhel*|*fedora*) echo "rhel" ;;
                    *arch*)    echo "arch"   ;;
                    *)         echo "unknown" ;;
                esac
                ;;
        esac
    else
        echo "unknown"
    fi
}

# -- Install
OS="$(detect_os)"
info "Detected OS: $OS"

case "$OS" in
    debian)
        info "Installing packages via apt-get..."
        sudo apt-get update -qq
        # shellcheck disable=SC2086
        sudo apt-get install -y $PKGS_DEBIAN
        ;;
    rhel)
        info "Installing packages via dnf/yum..."
        if command -v dnf &>/dev/null; then
            # shellcheck disable=SC2086
            sudo dnf install -y $PKGS_RPM
        else
            # shellcheck disable=SC2086
            sudo yum install -y $PKGS_RPM
        fi
        ;;
    fedora)
        info "Installing packages via dnf..."
        # shellcheck disable=SC2086
        sudo dnf install -y $PKGS_RPM
        ;;
    arch)
        info "Installing packages via pacman..."
        # shellcheck disable=SC2086
        sudo pacman -S --noconfirm $PKGS_ARCH
        ;;
    macos)
        info "Installing packages via Homebrew..."
        if ! command -v brew &>/dev/null; then
            echo "ERROR: Homebrew not found. Install it from https://brew.sh, then re-run." >&2
            echo "       Also ensure Xcode Command Line Tools are installed:" >&2
            echo "         xcode-select --install" >&2
            exit 1
        fi
        # shellcheck disable=SC2086
        brew install $PKGS_BREW
        ;;
    *)
        echo "ERROR: Unrecognised OS. Install these packages manually:" >&2
        echo "" >&2
        echo "  gcc, g++, make, autoconf, automake, libtool, pkg-config," >&2
        echo "  libevent (dev), pcre (dev), zlib (dev), openssl (dev), curl" >&2
        echo "" >&2
        echo "  Debian/Ubuntu : sudo apt-get install $PKGS_DEBIAN" >&2
        echo "  RHEL/CentOS   : sudo dnf install $PKGS_RPM" >&2
        echo "  Arch          : sudo pacman -S $PKGS_ARCH" >&2
        exit 1
        ;;
esac

# -- Verify
echo ""
info "Verifying required tools..."
ALL_OK=1
for cmd in gcc make autoconf automake libtool pkg-config curl; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd  ($(command -v "$cmd"))"
    else
        fail "$cmd"
        ALL_OK=0
    fi
done

echo ""
if [[ "$ALL_OK" -eq 1 ]]; then
    info "All prerequisites satisfied. Run ./install.sh to build memcached and memtier_benchmark."
else
    echo "ERROR: Some tools are still missing — check your package manager output above." >&2
    exit 1
fi
