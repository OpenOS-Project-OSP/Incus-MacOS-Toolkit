#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# imt — Incus macOS Toolkit
# Unified CLI for macOS VM management on Incus.
#
# Usage: imt <command> [subcommand] [options]

set -euo pipefail

VERSION="1.0.0"

# Resolve install location
if [[ -L "${BASH_SOURCE[0]}" ]]; then
    IMT_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && cd .. && pwd)"
else
    IMT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
fi

# If installed to /usr/local/bin, data is in /usr/local/share/imt
if [[ ! -d "$IMT_ROOT/image-pipeline" ]]; then
    IMT_ROOT="${IMT_ROOT%/bin}/share/imt"
fi

export IMT_ROOT

# shellcheck source=cli/lib.sh disable=SC1091
source "$IMT_ROOT/cli/lib.sh"
load_config

IMT_STORAGE_DIR="${IMT_STORAGE_DIR:-/var/lib/macos-kvm}"
IMT_STORAGE_POOL="${IMT_STORAGE_POOL:-default}"

# ── Global usage ──────────────────────────────────────────────────────────────

usage_global() {
    cat <<EOF
imt $VERSION — Incus macOS Toolkit

Usage: imt <command> [options]

Commands:
  image     Manage macOS disk images (fetch, build)
  vm        Manage macOS VMs in Incus (create, start, stop, ...)
  doctor    Check prerequisites
  config    Show or initialise configuration
  version   Print version

Run 'imt <command> help' for command-specific usage.
EOF
    exit 0
}

# ── image command ─────────────────────────────────────────────────────────────

cmd_image() {
    local subcmd="${1:-help}"; shift || true
    case "$subcmd" in
        fetch)    cmd_image_fetch "$@" ;;
        build)    cmd_image_build "$@" ;;
        firmware) cmd_image_firmware "$@" ;;
        opencore) cmd_image_opencore "$@" ;;
        help|--help|-h)
            cat <<EOF
Usage: imt image <subcommand> [options]

Subcommands:
  firmware              Download OVMF firmware blobs
  opencore              Download OpenCore bootloader qcow2
  fetch [--version V]   Fetch macOS recovery image from Apple CDN
  build [options]       Create QCOW2 disk and stage firmware for Incus

Options for 'build':
  --version VERSION     macOS version (default: \${IMT_VERSION:-sonoma})
  --size SIZE           Disk size (default: \${IMT_DISK:-128G})
  --output PATH         Output QCOW2 path (default: image-pipeline/mac_hdd.qcow2)
EOF
            ;;
        *) die "Unknown image subcommand: $subcmd. Run: imt image help" ;;
    esac
}

cmd_image_firmware() {
    local firmware_dir="$IMT_ROOT/firmware"
    mkdir -p "$firmware_dir"
    require_cmd wget
    info "Downloading OVMF firmware ..."
    wget -q -nc -P "$firmware_dir" \
        https://github.com/kholia/OSX-KVM/raw/master/OVMF_CODE_4M.fd \
        https://github.com/kholia/OSX-KVM/raw/master/OVMF_VARS-1920x1080.fd \
        https://github.com/kholia/OSX-KVM/raw/master/OVMF_VARS-1024x768.fd
    ok "Firmware ready in $firmware_dir"
}

cmd_image_opencore() {
    local opencore_dir="$IMT_ROOT/image-pipeline/OpenCore"
    mkdir -p "$opencore_dir"
    require_cmd wget
    info "Downloading OpenCore bootloader ..."
    wget -q -nc -O "$opencore_dir/OpenCore.qcow2" \
        https://github.com/kholia/OSX-KVM/raw/master/OpenCore/OpenCore.qcow2
    ok "OpenCore ready at $opencore_dir/OpenCore.qcow2"
}

cmd_image_fetch() {
    local version="${IMT_VERSION:-sonoma}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    require_cmd python3
    local outdir="$IMT_ROOT/image-pipeline"
    info "Fetching macOS $version recovery image ..."
    python3 "$IMT_ROOT/image-pipeline/fetch-macos.py" \
        --version "$version" --outdir "$outdir"
    if [[ -f "$outdir/BaseSystem.dmg" ]]; then
        bash "$IMT_ROOT/image-pipeline/convert-image.sh" \
            "$outdir/BaseSystem.dmg" "$outdir/BaseSystem.img"
    elif [[ -f "$outdir/RecoveryImage.dmg" ]]; then
        bash "$IMT_ROOT/image-pipeline/convert-image.sh" \
            "$outdir/RecoveryImage.dmg" "$outdir/BaseSystem.img"
    else
        warn "No .dmg found in $outdir — conversion skipped."
    fi
    ok "Installer image ready: $outdir/BaseSystem.img"
}

cmd_image_build() {
    local version="${IMT_VERSION:-sonoma}"
    local size="${IMT_DISK:-128G}"
    local output=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --size)    size="$2";    shift 2 ;;
            --output)  output="$2";  shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    bash "$IMT_ROOT/image-pipeline/build-image.sh" \
        --version "$version" \
        --firmware-dir "$IMT_ROOT/firmware" \
        --opencore "$IMT_ROOT/image-pipeline/OpenCore/OpenCore.qcow2" \
        --installer "$IMT_ROOT/image-pipeline/BaseSystem.img" \
        --size "$size" \
        ${output:+--output "$output"}
}

# ── vm command ────────────────────────────────────────────────────────────────

cmd_vm() {
    local subcmd="${1:-help}"; shift || true
    case "$subcmd" in
        create)   cmd_vm_create "$@" ;;
        start)    cmd_vm_start "$@" ;;
        stop)     cmd_vm_stop "$@" ;;
        status)   cmd_vm_status "$@" ;;
        console)  cmd_vm_console "$@" ;;
        shell)    cmd_vm_shell "$@" ;;
        snapshot) cmd_vm_snapshot "$@" ;;
        delete)   cmd_vm_delete "$@" ;;
        list)     cmd_vm_list "$@" ;;
        help|--help|-h)
            cat <<EOF
Usage: imt vm <subcommand> [options]

Subcommands:
  create    Create and launch a macOS VM in Incus
  start     Start a stopped VM
  stop      Stop a running VM
  status    Show VM info
  console   Attach to the VM console (serial/VGA)
  shell     Open a shell inside the running VM via incus exec
  snapshot  Create a named snapshot
  delete    Delete the VM and its installer storage volume
  list      List all imt-managed VMs

Common options:
  --name NAME       Incus instance name (default: macos-<version>)
  --version VER     macOS version, used to derive default name (default: \${IMT_VERSION:-sonoma})
EOF
            ;;
        *) die "Unknown vm subcommand: $subcmd. Run: imt vm help" ;;
    esac
}

_vm_parse_name() {
    # Sets NAME and VERSION from args; remaining args returned via _VM_EXTRA
    local version="${IMT_VERSION:-sonoma}"
    local name=""
    _VM_EXTRA=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --name)    name="$2";    shift 2 ;;
            *)         _VM_EXTRA+=("$1"); shift ;;
        esac
    done
    [[ -z "$name" ]] && name="macos-${version}"
    VM_NAME="$name"
}

cmd_vm_create() {
    local ram="${IMT_RAM:-4GiB}"
    local cpus="${IMT_CPUS:-4}"
    local disk="${IMT_DISK:-128GiB}"
    local version="${IMT_VERSION:-sonoma}"
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --name)    name="$2";    shift 2 ;;
            --ram)     ram="$2";     shift 2 ;;
            --cpus)    cpus="$2";    shift 2 ;;
            --disk)    disk="$2";    shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "$name" ]] && name="macos-${version}"

    require_incus

    local firmware_dir="$IMT_ROOT/firmware"
    local opencore_img="$IMT_ROOT/image-pipeline/OpenCore/OpenCore.qcow2"
    local installer_img="$IMT_ROOT/image-pipeline/BaseSystem.img"
    local disk_img="$IMT_ROOT/image-pipeline/mac_hdd.qcow2"

    [[ -f "$firmware_dir/OVMF_CODE_4M.fd" ]] \
        || die "OVMF firmware missing. Run: imt image firmware"
    [[ -f "$opencore_img" ]] \
        || die "OpenCore not found. Run: imt image opencore"
    [[ -f "$installer_img" ]] \
        || die "Installer image missing. Run: imt image fetch --version $version"
    [[ -f "$disk_img" ]] \
        || die "Disk image missing. Run: imt image build --version $version"

    # Stage firmware to the host path referenced by raw.qemu.conf in profile.yaml
    info "Staging firmware ..."
    sudo mkdir -p "$IMT_STORAGE_DIR/firmware"
    sudo cp "$firmware_dir/OVMF_CODE_4M.fd"        "$IMT_STORAGE_DIR/firmware/"
    sudo cp "$firmware_dir/OVMF_VARS-1920x1080.fd" "$IMT_STORAGE_DIR/firmware/"

    # Install or update the Incus profile
    if incus profile show macos-kvm &>/dev/null 2>&1; then
        info "Updating macos-kvm Incus profile ..."
        incus profile edit macos-kvm < "$IMT_ROOT/incus/profile.yaml"
    else
        info "Creating macos-kvm Incus profile ..."
        incus profile create macos-kvm
        incus profile edit macos-kvm < "$IMT_ROOT/incus/profile.yaml"
    fi

    # Import the macOS disk image as a custom storage volume
    local disk_vol="${name}-disk"
    if ! incus storage volume show "$IMT_STORAGE_POOL" "$disk_vol" &>/dev/null 2>&1; then
        info "Importing disk image as storage volume '$disk_vol' ..."
        incus storage volume import "$IMT_STORAGE_POOL" "$disk_img" "$disk_vol"
    else
        info "Storage volume '$disk_vol' already exists, skipping import."
    fi

    # Import the installer image as a custom storage volume
    local installer_vol="${name}-installer"
    if ! incus storage volume show "$IMT_STORAGE_POOL" "$installer_vol" &>/dev/null 2>&1; then
        info "Importing installer image as storage volume '$installer_vol' ..."
        incus storage volume import "$IMT_STORAGE_POOL" "$installer_img" "$installer_vol"
    else
        info "Storage volume '$installer_vol' already exists, skipping import."
    fi

    # Import the OpenCore bootloader as a custom storage volume
    local opencore_vol="${name}-opencore"
    if ! incus storage volume show "$IMT_STORAGE_POOL" "$opencore_vol" &>/dev/null 2>&1; then
        info "Importing OpenCore as storage volume '$opencore_vol' ..."
        incus storage volume import "$IMT_STORAGE_POOL" "$opencore_img" "$opencore_vol"
    else
        info "Storage volume '$opencore_vol' already exists, skipping import."
    fi

    # Create the VM instance (empty — Incus does not provide a macOS image)
    info "Creating VM instance: $name ..."
    incus init --empty --vm \
        --profile macos-kvm \
        --config limits.cpu="$cpus" \
        --config limits.memory="$ram" \
        --config limits.disk="$disk" \
        --config security.secureboot=false \
        "$name"

    # Attach the macOS disk as the primary drive (boot.priority=1)
    incus config device add "$name" macos-disk disk \
        pool="$IMT_STORAGE_POOL" \
        source="$disk_vol" \
        boot.priority=1

    # Attach OpenCore bootloader (highest boot priority — boots first)
    incus config device add "$name" opencore disk \
        pool="$IMT_STORAGE_POOL" \
        source="$opencore_vol" \
        boot.priority=10

    # Attach the installer image (lower priority — only needed during install)
    incus config device add "$name" installer disk \
        pool="$IMT_STORAGE_POOL" \
        source="$installer_vol" \
        boot.priority=5

    # Enable KVM ignore_msrs (required for macOS guests)
    if [[ -f /sys/module/kvm/parameters/ignore_msrs ]]; then
        echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
    fi

    info "Starting $name ..."
    incus start "$name"

    echo ""
    ok "VM '$name' created and started."
    echo ""
    bold "Next steps:"
    echo "  imt vm console $name    # attach to console to complete macOS install"
    echo "  imt vm stop    $name    # after install, detach installer and reboot"
    echo "  imt vm start   $name"
    echo "  imt vm shell   $name    # open a shell once macOS is running"
}

cmd_vm_start() {
    _vm_parse_name "$@"
    require_incus
    if [[ -f /sys/module/kvm/parameters/ignore_msrs ]]; then
        echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
    fi
    info "Starting $VM_NAME ..."
    incus start "$VM_NAME"
    ok "$VM_NAME started."
}

cmd_vm_stop() {
    _vm_parse_name "$@"
    require_incus
    local force=false
    for arg in "${_VM_EXTRA[@]+"${_VM_EXTRA[@]}"}"; do
        [[ "$arg" == "--force" ]] && force=true
    done
    info "Stopping $VM_NAME ..."
    if [[ "$force" == true ]]; then
        incus stop --force "$VM_NAME"
    else
        incus stop "$VM_NAME"
    fi
    ok "$VM_NAME stopped."
}

cmd_vm_status() {
    _vm_parse_name "$@"
    require_incus
    incus info "$VM_NAME"
}

cmd_vm_console() {
    _vm_parse_name "$@"
    require_incus
    info "Attaching to console of $VM_NAME (Ctrl-a q to detach) ..."
    incus console "$VM_NAME"
}

cmd_vm_shell() {
    _vm_parse_name "$@"
    require_incus
    incus exec "$VM_NAME" -- /bin/bash
}

cmd_vm_snapshot() {
    _vm_parse_name "$@"
    require_incus
    local snap_name
    snap_name="snap-$(date +%Y%m%d-%H%M%S)"
    # Allow caller to pass a custom snapshot name as first extra arg
    [[ ${#_VM_EXTRA[@]} -gt 0 ]] && snap_name="${_VM_EXTRA[0]}"
    info "Creating snapshot '$snap_name' of $VM_NAME ..."
    incus snapshot create "$VM_NAME" "$snap_name"
    ok "Snapshot created: $VM_NAME/$snap_name"
}

cmd_vm_delete() {
    _vm_parse_name "$@"
    require_incus

    warn "This will permanently delete VM '$VM_NAME' and all its storage volumes."
    read -r -p "Type the VM name to confirm: " confirm
    [[ "$confirm" == "$VM_NAME" ]] || die "Aborted."

    info "Stopping $VM_NAME (if running) ..."
    incus stop --force "$VM_NAME" 2>/dev/null || true

    info "Deleting VM instance ..."
    incus delete "$VM_NAME" 2>/dev/null || true

    for vol in "${VM_NAME}-disk" "${VM_NAME}-installer" "${VM_NAME}-opencore"; do
        if incus storage volume show "$IMT_STORAGE_POOL" "$vol" &>/dev/null 2>&1; then
            info "Deleting storage volume '$vol' ..."
            incus storage volume delete "$IMT_STORAGE_POOL" "$vol"
        fi
    done

    ok "VM '$VM_NAME' deleted."
}

cmd_vm_list() {
    require_incus
    # Filter Incus VM list to only show instances using the macos-kvm profile
    incus list --format table | grep -E "^[|+]" | \
        awk 'NR==1 || /macos-kvm/' || \
        incus list --format table
}

# ── doctor command ────────────────────────────────────────────────────────────

cmd_doctor() {
    bold "imt doctor — checking prerequisites"
    echo ""

    local ok_count=0 fail_count=0

    _check() {
        local label="$1" cmd="$2"
        if command -v "$cmd" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $label ($cmd)"
            ok_count=$((ok_count + 1))
        else
            echo -e "  ${RED}✗${NC} $label ($cmd) — not found"
            fail_count=$((fail_count + 1))
        fi
    }

    _check "Incus"       incus
    _check "qemu-img"    qemu-img
    _check "wget"        wget
    _check "python3"     python3
    _check "dmg2img"     dmg2img
    _check "curl"        curl

    echo ""
    _check_file() {
        local label="$1" path="$2"
        if [[ -f "$path" ]]; then
            echo -e "  ${GREEN}✓${NC} $label"
            ok_count=$((ok_count + 1))
        else
            echo -e "  ${YELLOW}!${NC} $label — missing ($path)"
        fi
    }
    _check_file "OVMF firmware"    "$IMT_ROOT/firmware/OVMF_CODE_4M.fd"
    _check_file "OpenCore"         "$IMT_ROOT/image-pipeline/OpenCore/OpenCore.qcow2"
    _check_file "Installer image"  "$IMT_ROOT/image-pipeline/BaseSystem.img"
    _check_file "Disk image"       "$IMT_ROOT/image-pipeline/mac_hdd.qcow2"

    echo ""
    if [[ -e /dev/kvm ]]; then
        echo -e "  ${GREEN}✓${NC} KVM available (/dev/kvm)"
        ok_count=$((ok_count + 1))
    else
        echo -e "  ${RED}✗${NC} KVM not available (/dev/kvm missing)"
        fail_count=$((fail_count + 1))
    fi

    if [[ -f /sys/module/kvm/parameters/ignore_msrs ]]; then
        local msrs
        msrs=$(cat /sys/module/kvm/parameters/ignore_msrs)
        if [[ "$msrs" == "Y" ]]; then
            echo -e "  ${GREEN}✓${NC} kvm ignore_msrs=1 (required for macOS)"
        else
            echo -e "  ${YELLOW}!${NC} kvm ignore_msrs not set — 'imt vm start' sets this automatically"
        fi
    fi

    echo ""
    if [[ $fail_count -eq 0 ]]; then
        ok "All checks passed ($ok_count ok)."
    else
        warn "$fail_count check(s) failed, $ok_count passed."
        exit 1
    fi
}

# ── config command ────────────────────────────────────────────────────────────

cmd_config() {
    local subcmd="${1:-show}"; shift || true
    case "$subcmd" in
        show)
            if [[ -f "$IMT_CONFIG_FILE" ]]; then
                info "Config: $IMT_CONFIG_FILE"
                cat "$IMT_CONFIG_FILE"
            else
                info "No config file found at $IMT_CONFIG_FILE"
                info "Run: imt config init"
            fi
            ;;
        init) init_config ;;
        edit)
            [[ -f "$IMT_CONFIG_FILE" ]] || init_config
            "${EDITOR:-vi}" "$IMT_CONFIG_FILE"
            ;;
        *) die "Unknown config subcommand: $subcmd (show|init|edit)" ;;
    esac
}

# ── version ───────────────────────────────────────────────────────────────────

cmd_version() {
    echo "imt $VERSION"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        image)          cmd_image "$@" ;;
        vm)             cmd_vm "$@" ;;
        doctor)         cmd_doctor "$@" ;;
        config)         cmd_config "$@" ;;
        version|--version) cmd_version ;;
        help|--help|-h) usage_global ;;
        *) err "Unknown command: $cmd"; usage_global ;;
    esac
}

main "$@"
