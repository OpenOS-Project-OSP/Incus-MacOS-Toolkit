#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Unified macOS KVM boot script.
# Supports: bare QEMU (x86_64), OpenCore, headless/VNC modes.
#
# Derived from:
#   - kholia/OSX-KVM (OpenCore-Boot.sh)
#   - foxlet/macOS-Simple-KVM (basic.sh, headless.sh)
#   - Coopydood/ultimate-macOS-KVM (boot/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Defaults (override via env or flags) ──────────────────────────────────────
RAM="${RAM:-4096}"           # MiB
CPU_SOCKETS="${CPU_SOCKETS:-1}"
CPU_CORES="${CPU_CORES:-2}"
CPU_THREADS="${CPU_THREADS:-4}"
CPU_MODEL="${CPU_MODEL:-Skylake-Client,-hle,-rtm}"
MY_OPTIONS="${MY_OPTIONS:-+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check}"
HEADLESS="${HEADLESS:-0}"
VNC_PORT="${VNC_PORT:-5900}"
MAC_ADDRESS="${MAC_ADDRESS:-52:54:00:c9:18:27}"
DISK_IMAGE="${DISK_IMAGE:-$REPO_ROOT/mac_hdd.qcow2}"
OPENCORE_IMAGE="${OPENCORE_IMAGE:-$REPO_ROOT/boot/OpenCore/OpenCore.qcow2}"
OVMF_DIR="${OVMF_DIR:-$REPO_ROOT/firmware}"
EXTRA_ARGS="${EXTRA:-}"

OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --ram <MiB>          RAM in MiB (default: $RAM)
  --cores <n>          CPU cores (default: $CPU_CORES)
  --threads <n>        CPU threads (default: $CPU_THREADS)
  --cpu <model>        QEMU CPU model (default: $CPU_MODEL)
  --disk <path>        macOS HDD image (default: $DISK_IMAGE)
  --headless           Run without display (VNC on port $VNC_PORT)
  --vnc-port <port>    VNC port when headless (default: $VNC_PORT)
  --install <img>      Boot from installer image (BaseSystem.img)
  --mac <addr>         MAC address (default: $MAC_ADDRESS)
  -h, --help           Show this help
EOF
    exit 0
}

INSTALL_MEDIA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ram)        RAM="$2";          shift 2 ;;
        --cores)      CPU_CORES="$2";    shift 2 ;;
        --threads)    CPU_THREADS="$2";  shift 2 ;;
        --cpu)        CPU_MODEL="$2";    shift 2 ;;
        --disk)       DISK_IMAGE="$2";   shift 2 ;;
        --headless)   HEADLESS=1;        shift   ;;
        --vnc-port)   VNC_PORT="$2";     shift 2 ;;
        --install)    INSTALL_MEDIA="$2";shift 2 ;;
        --mac)        MAC_ADDRESS="$2";  shift 2 ;;
        -h|--help)    usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# ── Sanity checks ─────────────────────────────────────────────────────────────
if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found. Install QEMU first."
    exit 1
fi

if [[ ! -f "$OVMF_DIR/OVMF_CODE_4M.fd" ]]; then
    echo "ERROR: OVMF firmware not found at $OVMF_DIR/OVMF_CODE_4M.fd"
    echo "       Run: make firmware"
    exit 1
fi

if [[ ! -f "$OPENCORE_IMAGE" ]]; then
    echo "ERROR: OpenCore bootloader not found at $OPENCORE_IMAGE"
    echo "       Run: make opencore"
    exit 1
fi

if [[ ! -f "$DISK_IMAGE" ]]; then
    echo "No disk image found at $DISK_IMAGE."
    echo "Create one with: qemu-img create -f qcow2 $DISK_IMAGE 128G"
    exit 1
fi

# ── KVM / ignore_msrs ─────────────────────────────────────────────────────────
if [[ -f /sys/module/kvm/parameters/ignore_msrs ]]; then
    current=$(cat /sys/module/kvm/parameters/ignore_msrs)
    if [[ "$current" != "Y" ]]; then
        echo "WARNING: Setting kvm ignore_msrs=1 (required for macOS)"
        echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
    fi
fi

# ── Build QEMU args ───────────────────────────────────────────────────────────
# SC2054: commas inside quoted strings are QEMU argument syntax, not array separators.
# shellcheck disable=SC2054
ARGS=(
    -enable-kvm
    -m "${RAM}"
    -cpu "${CPU_MODEL},kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,${MY_OPTIONS}"
    -machine q35
    -smp "${CPU_THREADS},cores=${CPU_CORES},sockets=${CPU_SOCKETS}"

    # Apple SMC
    -device "isa-applesmc,osk=${OSK}"
    -smbios type=2

    # Firmware
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_DIR}/OVMF_CODE_4M.fd"
    -drive "if=pflash,format=raw,file=${OVMF_DIR}/OVMF_VARS-1920x1080.fd"

    # USB
    -device qemu-xhci,id=xhci
    -device usb-kbd,bus=xhci.0
    -device usb-tablet,bus=xhci.0

    # Audio
    -device ich9-intel-hda
    -device hda-duplex

    # Storage controller
    -device ich9-ahci,id=sata

    # OpenCore bootloader
    -drive "id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=${OPENCORE_IMAGE}"
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot

    # macOS HDD
    -drive "id=MacHDD,if=none,file=${DISK_IMAGE},format=qcow2"
    -device ide-hd,bus=sata.4,drive=MacHDD

    # Networking
    -netdev "user,id=net0,hostfwd=tcp::10022-:22"
    -device "e1000-82545em,netdev=net0,id=net0,mac=${MAC_ADDRESS}"
)

# Optional installer media
if [[ -n "$INSTALL_MEDIA" ]]; then
    if [[ ! -f "$INSTALL_MEDIA" ]]; then
        echo "ERROR: Install media not found: $INSTALL_MEDIA"
        exit 1
    fi
    # shellcheck disable=SC2054
    ARGS+=(
        -drive "id=InstallMedia,if=none,file=${INSTALL_MEDIA},format=raw"
        -device ide-hd,bus=sata.3,drive=InstallMedia
    )
fi

# Display
if [[ "$HEADLESS" -eq 1 ]]; then
    VNC_DISPLAY=$(( VNC_PORT - 5900 ))
    ARGS+=(-nographic -vnc ":${VNC_DISPLAY}")
    echo "Running headless. Connect via VNC on port ${VNC_PORT}"
else
    ARGS+=(-vga qxl)
fi

# Extra user-supplied args
if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    ARGS+=($EXTRA_ARGS)
fi

echo "Starting macOS KVM ..."
echo "  RAM: ${RAM} MiB  CPUs: ${CPU_THREADS} (${CPU_CORES} cores)  Disk: ${DISK_IMAGE}"
exec qemu-system-x86_64 "${ARGS[@]}"
