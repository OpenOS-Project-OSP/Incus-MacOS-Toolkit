#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Shared library for imt scripts.
# Source this file; do not execute directly.

# --- Colors (auto-disable if not a terminal) ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

info() { echo -e "${BLUE}::${NC} $*"; }
ok()   { echo -e "${GREEN}OK${NC} $*"; }
warn() { echo -e "${YELLOW}WARNING${NC} $*" >&2; }
err()  { echo -e "${RED}ERROR${NC} $*" >&2; }
die()  { err "$@"; exit 1; }
bold() { echo -e "${BOLD}$*${NC}"; }

# --- Progress ---
_IMT_STEP=0
_IMT_TOTAL_STEPS=0

progress_init() { _IMT_TOTAL_STEPS="$1"; _IMT_STEP=0; }
progress_step() {
    _IMT_STEP=$((_IMT_STEP + 1))
    info "[${_IMT_STEP}/${_IMT_TOTAL_STEPS}] $*"
}

# --- Dependency checking ---
require_cmd() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required commands: ${missing[*]}"
        err ""
        err "Install suggestions:"
        for cmd in "${missing[@]}"; do _suggest_install "$cmd"; done
        exit 1
    fi
}

_suggest_install() {
    local cmd="$1"
    local pkg note=""
    case "$cmd" in
        incus)        pkg="incus"; note="See https://linuxcontainers.org/incus/docs/main/installing/" ;;
        qemu-img)     pkg="qemu-utils (Debian/Ubuntu) or qemu-img (Fedora/RHEL)" ;;
        wget)         pkg="wget" ;;
        python3)      pkg="python3" ;;
        dmg2img)      pkg="dmg2img" ;;
        curl)         pkg="curl" ;;
        shellcheck)   pkg="shellcheck" ;;
        *)            pkg="$cmd" ;;
    esac
    err "  $cmd -> install package: $pkg"
    [[ -n "$note" ]] && err "  $note"
}

require_incus() {
    if ! command -v incus &>/dev/null; then
        die "incus not found. See https://linuxcontainers.org/incus/docs/main/installing/"
    fi
}

# --- Retry logic ---
retry() {
    local max_attempts="$1"; shift
    local attempt=1 delay=2
    while true; do
        "$@" && return 0
        [[ $attempt -ge $max_attempts ]] && { err "Command failed after $max_attempts attempts: $*"; return 1; }
        warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

# --- File size formatting ---
human_size() {
    local bytes="$1"
    if   [[ $bytes -ge 1073741824 ]]; then echo "$(( bytes / 1073741824 ))G"
    elif [[ $bytes -ge 1048576    ]]; then echo "$(( bytes / 1048576 ))M"
    elif [[ $bytes -ge 1024       ]]; then echo "$(( bytes / 1024 ))K"
    else echo "${bytes}B"
    fi
}

# --- Config file support ---
IMT_CONFIG_FILE="${IMT_CONFIG_FILE:-$HOME/.config/imt/config}"

load_config() {
    [[ -f "$IMT_CONFIG_FILE" ]] || return 0
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | tr -d '[:space:]')
        [[ "$key" =~ ^IMT_ ]] && export "$key=$value"
    done < "$IMT_CONFIG_FILE"
}

init_config() {
    local config_dir
    config_dir=$(dirname "$IMT_CONFIG_FILE")
    mkdir -p "$config_dir"
    if [[ -f "$IMT_CONFIG_FILE" ]]; then
        info "Config already exists: $IMT_CONFIG_FILE"
        return 0
    fi
    cat > "$IMT_CONFIG_FILE" <<'EOF'
# IMT Configuration
# Only IMT_ prefixed variables are loaded.

# Default macOS version to fetch/launch
IMT_VERSION=sonoma

# Default VM resource limits
IMT_RAM=4GiB
IMT_CPUS=4
IMT_DISK=128GiB

# Incus storage pool used for VM disks and installer volumes
IMT_STORAGE_POOL=default

# Firmware and installer storage path (host-side, referenced by raw.qemu.conf)
IMT_FIRMWARE_DIR=/var/lib/macos-kvm/firmware
EOF
    ok "Config created: $IMT_CONFIG_FILE"
}

# --- Cache directory ---
IMT_CACHE_DIR="${IMT_CACHE_DIR:-$HOME/.cache/imt}"

ensure_cache_dir() { mkdir -p "$IMT_CACHE_DIR"; }

cached_download() {
    local url="$1" filename="$2"
    local dest="$IMT_CACHE_DIR/$filename"
    ensure_cache_dir
    if [[ -f "$dest" ]]; then
        info "Using cached: $filename"
        echo "$dest"
        return 0
    fi
    info "Downloading: $filename"
    retry 3 curl -fSL --progress-bar -o "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
    echo "$dest"
}

# --- Architecture helpers ---
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "arm64"  ;;
        *)              uname -m      ;;
    esac
}
