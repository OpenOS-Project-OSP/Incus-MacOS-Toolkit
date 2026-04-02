#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# mac-linux-compat — unified installer.
# Installs any combination of the three components:
#   linuxify   — replace macOS BSD tools with GNU equivalents via Homebrew
#   mlsblk     — macOS port of lsblk
#   bsdcoreutils — BSD coreutils for Linux/macOS
#
# Usage:
#   bash install.sh [--all] [--linuxify] [--mlsblk] [--bsdcoreutils]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPT_ALL=0
OPT_LINUXIFY=0
OPT_MLSBLK=0
OPT_BSD=0

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --all           Install all components
  --linuxify      Install GNU tools on macOS via Homebrew
  --mlsblk        Build and install mlsblk (macOS only, requires clang)
  --bsdcoreutils  Build and install BSD coreutils (requires cmake)
  -h, --help      Show this help
EOF
    exit 0
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)          OPT_ALL=1 ;;
        --linuxify)     OPT_LINUXIFY=1 ;;
        --mlsblk)       OPT_MLSBLK=1 ;;
        --bsdcoreutils) OPT_BSD=1 ;;
        -h|--help)      usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

if [[ "$OPT_ALL" -eq 1 ]]; then
    OPT_LINUXIFY=1
    OPT_MLSBLK=1
    OPT_BSD=1
fi

# ── linuxify ──────────────────────────────────────────────────────────────────
if [[ "$OPT_LINUXIFY" -eq 1 ]]; then
    echo "==> Installing linuxify (GNU tools on macOS) ..."
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "  SKIP: linuxify is macOS-only."
    else
        bash "$SCRIPT_DIR/linuxify/linuxify" install
        echo "  Done. Source ~/.linuxify in your shell config."
    fi
fi

# ── mlsblk ────────────────────────────────────────────────────────────────────
if [[ "$OPT_MLSBLK" -eq 1 ]]; then
    echo "==> Building and installing mlsblk ..."
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "  SKIP: mlsblk requires macOS (CoreFoundation)."
    else
        make -C "$SCRIPT_DIR/mlsblk" install
        echo "  Done. mlsblk installed to /usr/local/bin/mlsblk"
    fi
fi

# ── bsdcoreutils ──────────────────────────────────────────────────────────────
if [[ "$OPT_BSD" -eq 1 ]]; then
    echo "==> Building and installing bsdcoreutils ..."
    if [[ ! -d "$SCRIPT_DIR/bsdcoreutils/upstream/.git" ]]; then
        echo "  Initialising bsdcoreutils submodule ..."
        git -C "$SCRIPT_DIR" submodule update --init bsdcoreutils/upstream
    fi
    mkdir -p "$SCRIPT_DIR/bsdcoreutils/build"
    cmake -S "$SCRIPT_DIR/bsdcoreutils/upstream" -B "$SCRIPT_DIR/bsdcoreutils/build" -DCMAKE_BUILD_TYPE=Release
    make -C "$SCRIPT_DIR/bsdcoreutils/build" -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
    sudo make -C "$SCRIPT_DIR/bsdcoreutils/build" install
    echo "  Done. BSD tools installed with 'b' prefix (e.g. bcat, bls)."
fi

echo "Installation complete."
