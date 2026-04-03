#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Convert a downloaded .dmg BaseSystem image to a raw .img suitable for QEMU.
# Requires: dmg2img (apt install dmg2img  /  brew install dmg2img)

set -euo pipefail

usage() {
    echo "Usage: $0 <BaseSystem.dmg> [output.img]"
    exit 1
}

[[ $# -lt 1 ]] && usage

INPUT="$1"
OUTPUT="${2:-BaseSystem.img}"

if ! command -v dmg2img &>/dev/null; then
    echo "ERROR: dmg2img not found. Install with: apt install dmg2img"
    exit 1
fi

echo "Converting $INPUT → $OUTPUT ..."
dmg2img -i "$INPUT" -o "$OUTPUT"
echo "Done: $OUTPUT"
