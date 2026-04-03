#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# vm-install.sh — build and install btrfs-dwarfs inside a running microVM.
#
# This script runs INSIDE the VM (uploaded and executed via SSH by the
# Makefile's bdfs-vm-install target).  It installs build dependencies,
# builds the kernel module and userspace tools from the source tree that
# was uploaded to /opt/bdfs-src/, and installs everything so the module
# loads on every boot.
#
# Usage (called by Makefile, not directly):
#   make -C btrfs-dwarfs bdfs-vm-install VM_SSH_PORT=10022 VM_USER=alpine
#
# The Makefile uploads the source tree and then runs this script via SSH.

set -e

INSTALL_PREFIX=/usr/local
SRC_DIR=/opt/bdfs-src
MODULE_DIR=/opt/bdfs

log() { echo "[bdfs-vm-install] $*"; }

# ── Detect distro and install build dependencies ─────────────────────────

log "Detecting package manager ..."

if command -v apk >/dev/null 2>&1; then
    log "Alpine Linux detected"
    apk add --no-cache \
        linux-headers \
        build-base \
        cmake \
        ninja \
        git \
        btrfs-progs \
        fuse3 \
        fuse3-dev \
        eudev-dev \
        kmod

elif command -v apt-get >/dev/null 2>&1; then
    log "Debian/Ubuntu detected"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        "linux-headers-$(uname -r)" \
        build-essential \
        cmake \
        ninja-build \
        git \
        btrfs-progs \
        fuse3 \
        libfuse3-dev \
        kmod

elif command -v dnf >/dev/null 2>&1; then
    log "Fedora/RHEL detected"
    dnf install -y \
        kernel-devel \
        gcc \
        make \
        cmake \
        ninja-build \
        git \
        btrfs-progs \
        fuse3 \
        fuse3-devel \
        kmod

else
    echo "ERROR: unsupported distro — install build deps manually" >&2
    exit 1
fi

# ── Install DwarFS static binaries ───────────────────────────────────────

log "Installing DwarFS tools ..."

DWARFS_VER="0.9.10"
ARCH="$(uname -m)"
DWARFS_URL="https://github.com/mhx/dwarfs/releases/download/v${DWARFS_VER}/dwarfs-universal-${DWARFS_VER}-Linux-${ARCH}.tar.zst"

if ! command -v mkdwarfs >/dev/null 2>&1; then
    TMP_DIR="$(mktemp -d)"
    if wget -q "$DWARFS_URL" -O "$TMP_DIR/dwarfs.tar.zst" 2>/dev/null || \
       curl -fsSL "$DWARFS_URL" -o "$TMP_DIR/dwarfs.tar.zst" 2>/dev/null; then
        tar --zstd -xf "$TMP_DIR/dwarfs.tar.zst" -C "$TMP_DIR"
        install -m755 "$TMP_DIR"/dwarfs-universal-*/sbin/mkdwarfs      "${INSTALL_PREFIX}/bin/mkdwarfs"
        install -m755 "$TMP_DIR"/dwarfs-universal-*/sbin/dwarfs        "${INSTALL_PREFIX}/bin/dwarfs"
        install -m755 "$TMP_DIR"/dwarfs-universal-*/sbin/dwarfsextract "${INSTALL_PREFIX}/bin/dwarfsextract"
        install -m755 "$TMP_DIR"/dwarfs-universal-*/sbin/dwarfsck      "${INSTALL_PREFIX}/bin/dwarfsck"
        log "DwarFS tools installed"
    else
        log "WARNING: could not download DwarFS tools — bdfs export/import will not work"
    fi
    rm -rf "$TMP_DIR"
else
    log "DwarFS tools already installed"
fi

# ── Build kernel module ───────────────────────────────────────────────────

log "Building kernel module ..."

KDIR="/lib/modules/$(uname -r)/build"

if [ ! -d "$KDIR" ]; then
    log "WARNING: kernel headers not found at $KDIR — skipping module build"
    log "Install linux-headers-$(uname -r) and re-run this script"
else
    make -C "$SRC_DIR" kernel KDIR="$KDIR"

    mkdir -p "$MODULE_DIR"
    cp "$SRC_DIR/kernel/btrfs_dwarfs/btrfs_dwarfs.ko" "$MODULE_DIR/"

    # Register with depmod so modprobe works.
    KMOD_DIR="/lib/modules/$(uname -r)/extra"
    mkdir -p "$KMOD_DIR"
    cp "$MODULE_DIR/btrfs_dwarfs.ko" "$KMOD_DIR/"
    depmod -a
    log "Kernel module installed: $KMOD_DIR/btrfs_dwarfs.ko"
fi

# ── Build userspace (daemon + CLI) ────────────────────────────────────────

log "Building userspace tools ..."

cmake -S "$SRC_DIR/userspace" -B "$SRC_DIR/build/release" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DBUILD_DAEMON=ON \
    -DBUILD_CLI=ON \
    -DBUILD_TESTS=OFF

cmake --build "$SRC_DIR/build/release" --parallel
cmake --install "$SRC_DIR/build/release"

log "Installed: ${INSTALL_PREFIX}/bin/bdfs  ${INSTALL_PREFIX}/sbin/bdfs_daemon"

# ── Install systemd / OpenRC service ─────────────────────────────────────

log "Installing bdfs_daemon service ..."

if command -v systemctl >/dev/null 2>&1; then
    # Render the .in template: replace @BDFS_DAEMON_BIN@ with the installed path.
    sed "s|@BDFS_DAEMON_BIN@|${INSTALL_PREFIX}/sbin/bdfs_daemon|g" \
        "$SRC_DIR/configs/bdfs_daemon.service.in" \
        > /etc/systemd/system/bdfs_daemon.service
    systemctl daemon-reload
    systemctl enable bdfs_daemon
    log "systemd service enabled: bdfs_daemon"

elif command -v rc-update >/dev/null 2>&1; then
    # Alpine OpenRC: write a simple init script.
    cat > /etc/init.d/bdfs_daemon << RCEOF
#!/sbin/openrc-run
name="bdfs_daemon"
description="BTRFS+DwarFS framework daemon"
command="${INSTALL_PREFIX}/sbin/bdfs_daemon"
command_background=true
pidfile="/run/bdfs_daemon.pid"
depend() { need localmount; }
RCEOF
    chmod +x /etc/init.d/bdfs_daemon
    rc-update add bdfs_daemon default
    log "OpenRC service enabled: bdfs_daemon"
fi

# ── Auto-load module on boot ──────────────────────────────────────────────

if [ -f "/lib/modules/$(uname -r)/extra/btrfs_dwarfs.ko" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        echo "btrfs_dwarfs" > /etc/modules-load.d/btrfs_dwarfs.conf
        log "Module auto-load configured via /etc/modules-load.d/"
    elif [ -f /etc/modules ]; then
        grep -qF btrfs_dwarfs /etc/modules || echo "btrfs_dwarfs" >> /etc/modules
        log "Module auto-load configured via /etc/modules"
    fi
fi

log "Installation complete."
log "  Kernel module: modprobe btrfs_dwarfs"
log "  Daemon:        systemctl start bdfs_daemon  (or rc-service bdfs_daemon start)"
log "  CLI:           bdfs status"
