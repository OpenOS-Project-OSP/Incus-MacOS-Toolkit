#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bulk-create macOS user accounts (CI/CD use only).
# Derived from sickcodes/osx-optimizer (useradd-bulk.sh).
#
# Usage: sudo bash useradd-bulk.sh <count> <password>

set -euo pipefail

COUNT="${1:-1}"
PASSWORD="${2:-password}"

for i in $(seq 1 "$COUNT"); do
    USERNAME="user${i}"
    FULLNAME="User ${i}"
    echo "Creating $USERNAME ..."
    sudo dscl . -create "/Users/$USERNAME"
    sudo dscl . -create "/Users/$USERNAME" UserShell /bin/bash
    sudo dscl . -create "/Users/$USERNAME" RealName "$FULLNAME"
    sudo dscl . -create "/Users/$USERNAME" UniqueID "$(( 500 + i ))"
    sudo dscl . -create "/Users/$USERNAME" PrimaryGroupID 20
    sudo dscl . -create "/Users/$USERNAME" NFSHomeDirectory "/Users/$USERNAME"
    sudo dscl . -passwd "/Users/$USERNAME" "$PASSWORD"
    sudo createhomedir -c -u "$USERNAME" 2>/dev/null || true
    echo "  $USERNAME created."
done
