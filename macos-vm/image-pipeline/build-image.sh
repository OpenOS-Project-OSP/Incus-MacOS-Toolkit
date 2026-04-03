#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build a macOS disk image for Incus.
#
# Creates the QCOW2 root disk and stages the OpenCore bootloader so that
# incus/setup.sh can import both as Incus storage volumes.  No QEMU process
# is launched here; all VM runtime is handled by Incus.
#
# Usage:
#   build-image.sh [options]
#
# Options:
#   --version VERSION      macOS version name (default: sonoma)
#   --firmware-dir PATH    Directory containing OVMF_CODE_4M.fd (required)
#   --opencore PATH        Path to OpenCore.qcow2 (required)
#   --installer PATH       Path to BaseSystem.img (required)
#   --output PATH          Output QCOW2 path (default: mac_hdd.qcow2)
#   --size SIZE            Disk size (default: 128G)
#   --help                 Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=cli/lib.sh disable=SC1091
source "$IMT_ROOT/cli/lib.sh"

load_config

# Defaults
VERSION="${IMT_VERSION:-sonoma}"
FIRMWARE_DIR=""
OPENCORE_IMG=""
INSTALLER_IMG=""
OUTPUT=""
DISK_SIZE="${IMT_DISK:-128G}"

usage() {
    sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)      VERSION="$2";      shift 2 ;;
            --firmware-dir) FIRMWARE_DIR="$2"; shift 2 ;;
            --opencore)     OPENCORE_IMG="$2"; shift 2 ;;
            --installer)    INSTALLER_IMG="$2";shift 2 ;;
            --output)       OUTPUT="$2";       shift 2 ;;
            --size)         DISK_SIZE="$2";    shift 2 ;;
            --help)         usage ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$FIRMWARE_DIR" ]] || die "--firmware-dir is required"
    [[ -f "$FIRMWARE_DIR/OVMF_CODE_4M.fd" ]] \
        || die "OVMF_CODE_4M.fd not found in $FIRMWARE_DIR. Run: make firmware"

    [[ -n "$OPENCORE_IMG" ]] || die "--opencore is required"
    [[ -f "$OPENCORE_IMG" ]] \
        || die "OpenCore image not found: $OPENCORE_IMG. Run: make opencore"

    [[ -n "$INSTALLER_IMG" ]] || die "--installer is required"
    [[ -f "$INSTALLER_IMG" ]] \
        || die "Installer image not found: $INSTALLER_IMG. Run: make fetch"

    [[ -z "$OUTPUT" ]] && OUTPUT="$SCRIPT_DIR/mac_hdd.qcow2"
}

stage_firmware() {
    local dest="/var/lib/macos-kvm/firmware"
    info "Staging OVMF firmware to $dest ..."
    sudo mkdir -p "$dest"
    sudo cp "$FIRMWARE_DIR/OVMF_CODE_4M.fd"        "$dest/"
    sudo cp "$FIRMWARE_DIR/OVMF_VARS-1920x1080.fd" "$dest/"
    ok "Firmware staged"
}

create_disk() {
    if [[ -f "$OUTPUT" ]]; then
        warn "Disk image already exists: $OUTPUT"
        warn "Delete it first to recreate: rm $OUTPUT"
        return 0
    fi
    info "Creating ${DISK_SIZE} QCOW2 disk: $OUTPUT ..."
    qemu-img create -f qcow2 "$OUTPUT" "$DISK_SIZE"
    ok "Disk created: $OUTPUT"
}

main() {
    parse_args "$@"
    require_cmd qemu-img

    progress_init 2
    progress_step "Staging firmware"
    stage_firmware

    progress_step "Creating disk image"
    create_disk

    echo ""
    bold "Image pipeline complete."
    info "Disk:      $OUTPUT"
    info "OpenCore:  $OPENCORE_IMG"
    info "Installer: $INSTALLER_IMG"
    echo ""
    bold "Next steps:"
    echo "  imt vm create --version $VERSION"
    echo "  imt vm console macos-$VERSION   # complete macOS installation"
    echo "  imt vm start   macos-$VERSION   # subsequent boots"
}

main "$@"
