#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Substitute @@REPO_ROOT@@ placeholders in libvirt-domain.xml and import
# the domain into libvirt.
#
# Usage:
#   bash boot/libvirt-configure.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATE="${SCRIPT_DIR}/libvirt-domain.xml"
OUTPUT="${SCRIPT_DIR}/libvirt-domain-configured.xml"
DRY_RUN=0

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ ! -f "$TEMPLATE" ]]; then
    echo "ERROR: $TEMPLATE not found"
    exit 1
fi

echo "Substituting paths (REPO_ROOT=$REPO_ROOT) ..."
sed "s|@@REPO_ROOT@@|${REPO_ROOT}|g" "$TEMPLATE" > "$OUTPUT"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run — configured XML written to $OUTPUT"
    echo "Review it, then run: sudo virsh define $OUTPUT"
    exit 0
fi

if ! command -v virsh &>/dev/null; then
    echo "ERROR: virsh not found. Install libvirt-clients."
    echo "Configured XML written to $OUTPUT"
    exit 1
fi

echo "Importing domain into libvirt ..."
sudo virsh define "$OUTPUT"
echo "Done. Start with: sudo virsh start macos-kvm"
