#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Push and run guest-tools/optimize.sh inside a running Incus macOS VM.
#
# Usage:
#   bash incus/optimize-guest.sh <instance-name> [--all | --spotlight-off ...]

set -euo pipefail

INSTANCE="${1:?Usage: $0 <instance-name> [optimize flags]}"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if ! command -v incus &>/dev/null; then
    echo "ERROR: incus not found."
    exit 1
fi

echo "Pushing optimize.sh to ${INSTANCE} ..."
incus file push "${REPO_ROOT}/guest-tools/optimize.sh" \
    "${INSTANCE}/tmp/optimize.sh"

echo "Running optimize.sh ${*} ..."
incus exec "${INSTANCE}" -- bash /tmp/optimize.sh "$@"
