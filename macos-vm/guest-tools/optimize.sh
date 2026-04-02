#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest-side macOS optimizations for KVM/VM environments.
# Run this INSIDE the macOS guest after installation.
#
# Derived from sickcodes/osx-optimizer.
#
# Usage:
#   bash optimize.sh [--all] [--spotlight-off] [--perf-mode] [--no-updates]
#   bash optimize.sh --all   # apply all safe optimizations

set -euo pipefail

OPT_ALL=0
OPT_SPOTLIGHT=0
OPT_PERF=0
OPT_UPDATES=0
OPT_MOTION=0
OPT_AUTOLOGIN=0

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --all            Apply all optimizations below
  --spotlight-off  Disable Spotlight indexing (big speed boost in VMs)
  --perf-mode      Enable server performance mode (nvram boot-args)
  --no-updates     Disable automatic macOS updates
  --reduce-motion  Reduce UI motion and transparency
  --auto-login     Enable auto-login (insecure — CI/CD only)
  -h, --help       Show this help
EOF
    exit 0
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)           OPT_ALL=1 ;;
        --spotlight-off) OPT_SPOTLIGHT=1 ;;
        --perf-mode)     OPT_PERF=1 ;;
        --no-updates)    OPT_UPDATES=1 ;;
        --reduce-motion) OPT_MOTION=1 ;;
        --auto-login)    OPT_AUTOLOGIN=1 ;;
        -h|--help)       usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

if [[ "$OPT_ALL" -eq 1 ]]; then
    OPT_SPOTLIGHT=1
    OPT_PERF=1
    OPT_UPDATES=1
    OPT_MOTION=1
fi

# ── Spotlight ─────────────────────────────────────────────────────────────────
if [[ "$OPT_SPOTLIGHT" -eq 1 ]]; then
    echo "Disabling Spotlight indexing ..."
    sudo mdutil -i off -a
    echo "  Done. Re-enable with: sudo mdutil -i on -a"
fi

# ── Performance mode ──────────────────────────────────────────────────────────
if [[ "$OPT_PERF" -eq 1 ]]; then
    echo "Enabling server performance mode ..."
    sudo nvram boot-args="serverperfmode=1 $(nvram boot-args 2>/dev/null | cut -f 2-)"
    echo "  Done. Disable with: sudo nvram boot-args=\"$(nvram boot-args 2>/dev/null | sed -e $'s/boot-args\t//;s/serverperfmode=1//')\""
fi

# ── Automatic updates ─────────────────────────────────────────────────────────
if [[ "$OPT_UPDATES" -eq 1 ]]; then
    echo "Disabling automatic updates ..."
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
    sudo defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
    sudo defaults write com.apple.commerce AutoUpdate -bool false
    sudo defaults write com.apple.SoftwareUpdate ConfigDataInstall -int 0
    sudo defaults write com.apple.SoftwareUpdate CriticalUpdateInstall -int 0
    sudo defaults write com.apple.SoftwareUpdate ScheduleFrequency -int 0
    echo "  Done."
fi

# ── Reduce motion / transparency ──────────────────────────────────────────────
if [[ "$OPT_MOTION" -eq 1 ]]; then
    echo "Reducing UI motion and transparency ..."
    defaults write com.apple.Accessibility DifferentiateWithoutColor -int 1
    defaults write com.apple.Accessibility ReduceMotionEnabled -int 1
    defaults write com.apple.universalaccess reduceMotion -int 1
    defaults write com.apple.universalaccess reduceTransparency -int 1
    echo "  Done."
fi

# ── Auto-login (CI/CD only) ───────────────────────────────────────────────────
if [[ "$OPT_AUTOLOGIN" -eq 1 ]]; then
    echo "WARNING: Enabling auto-login. Only use in isolated CI/CD environments."
    sudo defaults write com.apple.loginwindow autoLoginUser -bool true
    sudo defaults write /Library/Preferences/com.apple.loginwindow DesktopPicture ""
    defaults write com.apple.loginwindow DisableScreenLock -bool true
    echo "  Done."
fi

echo "Optimization complete."
