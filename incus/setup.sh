#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Set up and launch a macOS VM in Incus.
# Replaces docker/Dockerfile + docker-compose.yml.
#
# Prerequisites:
#   - Incus installed and initialised (incus admin init)
#   - KVM available (/dev/kvm)
#   - OVMF firmware downloaded (make firmware)
#   - macOS recovery image fetched (make fetch)
#
# Usage:
#   bash incus/setup.sh [--version sonoma] [--ram 4GiB] [--cpus 4] [--name macos-sonoma]
#   bash incus/setup.sh --start macos-sonoma
#   bash incus/setup.sh --stop  macos-sonoma
#   bash incus/setup.sh --shell macos-sonoma

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FIRMWARE_DIR="${REPO_ROOT}/firmware"
FETCH_DIR="${REPO_ROOT}/fetch"
INCUS_STORAGE_DIR="/var/lib/macos-kvm"

VERSION="${VERSION:-sonoma}"
RAM="${RAM:-4GiB}"
CPUS="${CPUS:-4}"
DISK="${DISK:-128GiB}"
INSTANCE_NAME="${NAME:-macos-${VERSION}}"
ACTION="${1:-launch}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [ACTION]

Actions:
  launch   Create storage, import profile, and launch the VM (default)
  start    Start an existing stopped VM
  stop     Gracefully stop a running VM
  shell    Open a shell inside the running VM
  delete   Delete the VM and its storage volume
  status   Show VM status

Options:
  --version <ver>   macOS version name (default: $VERSION)
  --ram <size>      RAM (default: $RAM)
  --cpus <n>        vCPUs (default: $CPUS)
  --disk <size>     Disk size (default: $DISK)
  --name <name>     Instance name (default: $INSTANCE_NAME)
  -h, --help        Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; INSTANCE_NAME="macos-${VERSION}"; shift 2 ;;
        --ram)     RAM="$2";     shift 2 ;;
        --cpus)    CPUS="$2";    shift 2 ;;
        --disk)    DISK="$2";    shift 2 ;;
        --name)    INSTANCE_NAME="$2"; shift 2 ;;
        launch|start|stop|shell|delete|status) ACTION="$1"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

require_incus() {
    if ! command -v incus &>/dev/null; then
        echo "ERROR: incus not found."
        echo "Install: https://linuxcontainers.org/incus/docs/main/installing/"
        exit 1
    fi
}

# ── Actions ───────────────────────────────────────────────────────────────────

case "$ACTION" in

launch)
    require_incus

    # Sanity checks
    if [[ ! -f "${FIRMWARE_DIR}/OVMF_CODE_4M.fd" ]]; then
        echo "ERROR: OVMF firmware missing. Run: make firmware"
        exit 1
    fi

    INSTALLER_IMG="${FETCH_DIR}/BaseSystem.img"
    if [[ ! -f "$INSTALLER_IMG" ]]; then
        echo "ERROR: Installer image missing. Run: make fetch VERSION=${VERSION}"
        exit 1
    fi

    # Copy firmware to the path referenced in profile.yaml's raw.qemu.conf.
    # Incus manages its own UEFI vars; we place ours here so the raw.qemu.conf
    # override takes precedence without conflicting with Incus's default pflash.
    sudo mkdir -p "$INCUS_STORAGE_DIR/firmware"
    sudo cp "${FIRMWARE_DIR}/OVMF_CODE_4M.fd" "${INCUS_STORAGE_DIR}/firmware/"
    sudo cp "${FIRMWARE_DIR}/OVMF_VARS-1920x1080.fd" "${INCUS_STORAGE_DIR}/firmware/"
    echo "Firmware copied to $INCUS_STORAGE_DIR/firmware/"

    # Create or update the Incus profile
    if incus profile show macos-kvm &>/dev/null; then
        echo "Updating existing macos-kvm profile ..."
        incus profile edit macos-kvm < "${SCRIPT_DIR}/profile.yaml"
    else
        echo "Creating macos-kvm profile ..."
        incus profile create macos-kvm
        incus profile edit macos-kvm < "${SCRIPT_DIR}/profile.yaml"
    fi

    # Import the macOS installer image as a custom storage volume.
    # --type=custom is correct for a raw image file (not a VM root disk).
    INSTALLER_VOL="${INSTANCE_NAME}-installer"
    if ! incus storage volume show default "$INSTALLER_VOL" &>/dev/null; then
        echo "Importing installer image as storage volume ..."
        incus storage volume import default "$INSTALLER_IMG" "$INSTALLER_VOL"
    fi

    # Create the VM instance (empty — no OS image from image server)
    echo "Creating VM instance: ${INSTANCE_NAME} ..."
    incus init --empty --vm \
        --profile macos-kvm \
        --config limits.cpu="${CPUS}" \
        --config limits.memory="${RAM}" \
        --config security.secureboot=false \
        --device root,size="${DISK}" \
        "${INSTANCE_NAME}"

    # Attach the installer volume as a secondary disk.
    # --type=custom is correct for a pre-imported raw image volume.
    incus config device add "${INSTANCE_NAME}" installer disk \
        pool=default \
        source="${INSTALLER_VOL}" \
        boot.priority=10 \
        type=custom

    # Set KVM ignore_msrs (required for macOS)
    if [[ -f /sys/module/kvm/parameters/ignore_msrs ]]; then
        echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
    fi

    echo "Starting ${INSTANCE_NAME} ..."
    incus start "${INSTANCE_NAME}"

    echo ""
    echo "VM launched. Connect via:"
    echo "  Console:  incus console ${INSTANCE_NAME}"
    echo "  Shell:    incus exec ${INSTANCE_NAME} -- /bin/bash  (after macOS boots)"
    echo "  Stop:     incus stop ${INSTANCE_NAME}"
    ;;

start)
    require_incus
    echo "Starting ${INSTANCE_NAME} ..."
    if [[ -f /sys/module/kvm/parameters/ignore_msrs ]]; then
        echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
    fi
    incus start "${INSTANCE_NAME}"
    ;;

stop)
    require_incus
    echo "Stopping ${INSTANCE_NAME} ..."
    incus stop "${INSTANCE_NAME}"
    ;;

shell)
    require_incus
    incus exec "${INSTANCE_NAME}" -- /bin/bash
    ;;

delete)
    require_incus
    echo "Deleting ${INSTANCE_NAME} and its storage ..."
    incus delete --force "${INSTANCE_NAME}" || true
    incus storage volume delete default "${INSTANCE_NAME}-installer" 2>/dev/null || true
    echo "Done."
    ;;

status)
    require_incus
    incus info "${INSTANCE_NAME}"
    ;;

*)
    echo "Unknown action: $ACTION"
    usage
    ;;
esac
