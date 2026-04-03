#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compatibility shim — delegates to the imt CLI.
# This file is kept so that existing scripts calling 'bash incus/setup.sh'
# continue to work.  New code should call 'imt vm <subcommand>' directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMT_CLI="$(dirname "$SCRIPT_DIR")/cli/imt.sh"

exec bash "$IMT_CLI" vm "$@"
