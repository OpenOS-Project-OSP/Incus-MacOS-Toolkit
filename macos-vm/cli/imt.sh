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
  image       Manage macOS disk images (fetch, build)
  vm          Manage macOS VMs in Incus (create, start, stop, backup, restore, ...)
  cloud-sync  Sync VM backups to cloud storage via rclone
  demo        Manage a local incus-demo-server instance
  winesapos   Fetch, import, and launch winesapOS gaming VMs
  publish         Create, list, and delete Incus images from macOS VMs
  host-exec       Run a host command from inside the macOS VM via nsenter
  tui             Launch interactive terminal UI (requires dialog or whiptail)
  dashboard       Launch web monitoring dashboard (requires socat/ncat/python3)
  profiles        Manage Incus profiles (list, install, diff, apply)
  setup-rootless  Configure the system for rootless VM operation via incus-user
  update          Check for and install imt updates
  doctor          Check prerequisites
  config          Show or initialise configuration (show|init|edit|path)
  completion      Generate shell completion script (bash|zsh|fish)
  version         Print version

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
        snapshot-auto) cmd_vm_snapshot auto "$@" ;;
        export)   cmd_vm_export  "$@" ;;
        import)   cmd_vm_import  "$@" ;;
        fleet)    cmd_vm_fleet    "$@" ;;
        monitor)  cmd_vm_monitor  "$@" ;;
        net)      cmd_vm_net      "$@" ;;
        usb)      cmd_vm_usb      "$@" ;;
        gpu)      cmd_vm_gpu      "$@" ;;
        template) cmd_vm_template "$@" ;;
        backup)   cmd_vm_backup  "$@" ;;
        restore)  cmd_vm_restore "$@" ;;
        assemble) cmd_vm_assemble "$@" ;;
        delete)   cmd_vm_delete  "$@" ;;
        list)     cmd_vm_list    "$@" ;;
        upgrade)  cmd_vm_upgrade "$@" ;;
        disk)     cmd_vm_disk    "$@" ;;
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
  template  List and inspect VM creation templates
  snapshot      Create, list, restore, and delete VM snapshots
  snapshot-auto Manage automatic snapshot schedules (alias: vm snapshot auto)
  export        Publish VM as a reusable Incus image
  import    Create a VM from a published image or backup
  fleet     Multi-VM orchestration (start-all, stop-all, backup-all)
  monitor   Show VM resource usage and stats
  net       Manage network port forwarding (proxy devices)
  usb       Manage USB device passthrough
  gpu       Manage GPU passthrough
  backup    Export the VM and its storage volumes to a directory
  restore   Import a VM from a backup directory
  assemble  Create/update VMs from a declarative YAML file
  delete    Delete the VM and its installer storage volume
  list      List all imt-managed VMs
  upgrade   Run macOS Software Update inside a running VM
  disk      Live disk resize (resize, info)

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

_imt_template_dir() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local d="${IMT_TEMPLATES_DIR:-}"
    [[ -z "$d" ]] && d="${script_dir}/../templates"
    [[ -d "$d" ]] && { realpath "$d" 2>/dev/null || echo "$d"; return; }
    echo "${script_dir}/../templates"
}

_imt_tpl_get() {
    local file="$1" key="$2"
    grep "^${key}:" "${file}" | head -1 | sed "s/^${key}:[[:space:]]*//" | tr -d '"'
}

_imt_tpl_nested() {
    local file="$1" section="$2" key="$3"
    local in_section=false val=""
    while IFS= read -r line; do
        echo "${line}" | grep -q "^${section}:" && { in_section=true; continue; }
        ${in_section} && echo "${line}" | grep -qE "^[a-z]" && break
        if ${in_section}; then
            local t="${line#"${line%%[^[:space:]]*}"}"; t="${t%%[[:space:]]}"
            echo "${t}" | grep -q "^${key}:" && {
                # shellcheck disable=SC2001  # variable in sed pattern; ${//} cannot replicate
                val=$(echo "${t}" | sed "s/^${key}:[[:space:]]*//" | tr -d '"'); break; }
        fi
    done < "${file}"
    echo "${val}"
}

cmd_vm_template() {
    local subcmd="${1:-list}"; shift || true
    local tpl_dir; tpl_dir="$(_imt_template_dir)"

    case "${subcmd}" in
        list|ls)
            bold "VM Templates: ${tpl_dir}"
            echo ""
            printf "  %-14s %s\n" "NAME" "DESCRIPTION"
            printf "  %-14s %s\n" "----" "-----------"
            local found=false
            for f in "${tpl_dir}"/*.yaml; do
                [[ -f "$f" ]] || continue
                found=true
                local n desc
                n=$(basename "$f" .yaml)
                desc=$(_imt_tpl_get "$f" "description")
                printf "  %-14s %s\n" "$n" "$desc"
            done
            ${found} || info "No templates found in ${tpl_dir}"
            echo ""
            info "Use: imt vm create --template <name> [options]"
            ;;
        show)
            local name="${1:?Usage: imt vm template show <name>}"
            local f="${tpl_dir}/${name}.yaml"
            [[ -f "$f" ]] || die "Template not found: ${name}"
            bold "Template: ${name}"
            echo ""
            echo "  Description : $(_imt_tpl_get "$f" "description")"
            echo "  CPU         : $(_imt_tpl_nested "$f" "resources" "cpu")"
            echo "  Memory      : $(_imt_tpl_nested "$f" "resources" "memory")"
            ;;
        help|--help|-h)
            echo "Usage: imt vm template <list|show NAME>"
            ;;
        *) die "Unknown template subcommand: ${subcmd}" ;;
    esac
}

cmd_vm_create() {
    local ram="${IMT_RAM:-4GiB}"
    local cpus="${IMT_CPUS:-4}"
    local version="${IMT_VERSION:-sonoma}"
    local name=""
    local template=""

    # --disk is intentionally absent: disk size is baked into the QCOW2
    # image at build time (imt image build --size). Incus has no
    # limits.disk config key; size is set by the storage volume itself.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)  version="$2";  shift 2 ;;
            --name)     name="$2";     shift 2 ;;
            --ram)      ram="$2";      shift 2 ;;
            --cpus)     cpus="$2";     shift 2 ;;
            --template) template="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "$name" ]] && name="macos-${version}"

    # Apply template defaults (CLI flags already parsed above take precedence)
    if [[ -n "${template}" ]]; then
        local _tdir; _tdir="$(_imt_template_dir)"
        local _tf="${_tdir}/${template}.yaml"
        [[ -f "${_tf}" ]] || die "Template not found: ${template} (looked in ${_tdir})"
        local _tcpu _tmem
        _tcpu=$(_imt_tpl_nested "${_tf}" "resources" "cpu")
        _tmem=$(_imt_tpl_nested "${_tf}" "resources" "memory")
        # Only override if user didn't pass explicit --cpus / --ram
        [[ -n "${_tcpu}" && "${cpus}" == "${IMT_CPUS:-4}" ]] && cpus="${_tcpu}"
        [[ -n "${_tmem}" && "${ram}"  == "${IMT_RAM:-4GiB}" ]] && ram="${_tmem}"
        info "Applying template '${template}': cpu=${cpus} ram=${ram}"
    fi

    require_incus

    local firmware_dir="$IMT_ROOT/firmware"
    local opencore_img="$IMT_ROOT/image-pipeline/OpenCore/OpenCore.qcow2"
    local installer_img="$IMT_ROOT/image-pipeline/BaseSystem.img"
    local disk_img="$IMT_ROOT/image-pipeline/mac_hdd.qcow2"

    [[ -f "$firmware_dir/OVMF_CODE_4M.fd" ]] \
        || die "OVMF firmware missing. Run: imt image firmware"
    [[ -f "$firmware_dir/OVMF_VARS-1920x1080.fd" ]] \
        || die "OVMF_VARS-1920x1080.fd missing. Run: imt image firmware"
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
    local subcmd="${1:-help}"
    shift || true

    case "${subcmd}" in
        create)  _cmd_vm_snapshot_create "$@" ;;
        list|ls) _cmd_vm_snapshot_list   "$@" ;;
        restore) _cmd_vm_snapshot_restore "$@" ;;
        delete|rm|remove) _cmd_vm_snapshot_delete "$@" ;;
        auto)    _cmd_vm_snapshot_auto   "$@" ;;
        help|--help|-h)
            cat <<EOF
Usage: imt vm snapshot <subcommand> [options]

Subcommands:
  create  [NAME] [--name VM]                    Take a snapshot
  list           [--name VM]                    List all snapshots
  restore NAME   [--name VM]                    Restore to a snapshot
  delete  NAME   [--name VM]                    Delete a snapshot
  auto    <set|show|disable> [--name VM]        Manage auto-snapshot schedule

Auto subcommands:
  auto set SCHEDULE [--expiry DURATION] [--pattern PATTERN]
  auto show
  auto disable

Examples:
  imt vm snapshot create --name macos-sonoma
  imt vm snapshot create before-update --name macos-sonoma
  imt vm snapshot list --name macos-sonoma
  imt vm snapshot restore before-update --name macos-sonoma
  imt vm snapshot delete before-update --name macos-sonoma
  imt vm snapshot auto set "@daily" --expiry 7d --name macos-sonoma
  imt vm snapshot auto show --name macos-sonoma
  imt vm snapshot auto disable --name macos-sonoma
EOF
            ;;
        # Legacy: bare 'imt vm snapshot' with no subcommand → create
        *)
            _cmd_vm_snapshot_create "${subcmd}" "$@" ;;
    esac
}

_cmd_vm_snapshot_auto() {
    local subcmd="${1:-help}"
    shift || true

    case "${subcmd}" in
        set)
            local schedule="${1:?Usage: imt vm snapshot auto set <schedule> [--expiry DURATION] [--pattern PATTERN] [--name VM]}"
            shift
            local expiry="" pattern="snap-%d" version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --expiry)  expiry="$2";  shift 2 ;;
                    --pattern) pattern="$2"; shift 2 ;;
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            info "Setting snapshot schedule for '${vm_name}': ${schedule}"
            incus config set "${vm_name}" snapshots.schedule "${schedule}"
            incus config set "${vm_name}" snapshots.pattern  "${pattern}"
            incus config set "${vm_name}" snapshots.schedule.stopped false
            if [[ -n "${expiry}" ]]; then
                info "Setting snapshot expiry: ${expiry}"
                incus config set "${vm_name}" snapshots.expiry "${expiry}"
            fi
            ok "Auto-snapshot configured for '${vm_name}'"
            info "  Schedule : ${schedule}"
            info "  Pattern  : ${pattern}"
            [[ -n "${expiry}" ]] && info "  Expiry   : ${expiry}"
            ;;
        show)
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            local schedule expiry pattern
            schedule=$(incus config get "${vm_name}" snapshots.schedule 2>/dev/null || echo "(not set)")
            expiry=$(incus config get   "${vm_name}" snapshots.expiry   2>/dev/null || echo "(not set)")
            pattern=$(incus config get  "${vm_name}" snapshots.pattern  2>/dev/null || echo "(not set)")
            printf "VM       : %s\n" "${vm_name}"
            printf "Schedule : %s\n" "${schedule}"
            printf "Expiry   : %s\n" "${expiry}"
            printf "Pattern  : %s\n" "${pattern}"
            ;;
        disable)
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            incus config unset "${vm_name}" snapshots.schedule 2>/dev/null || true
            ok "Auto-snapshot disabled for '${vm_name}'"
            ;;
        help|--help|-h)
            echo "Usage: imt vm snapshot auto <set|show|disable> [options]"
            echo "Run 'imt vm snapshot --help' for details."
            ;;
        *)
            die "Unknown auto subcommand: ${subcmd}" ;;
    esac
}

_cmd_vm_snapshot_create() {
    local snap_name="" version="${IMT_VERSION:-sonoma}" vm_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --name)    vm_name="$2"; shift 2 ;;
            -*)        die "Unknown option: $1" ;;
            *)         snap_name="$1"; shift ;;
        esac
    done
    [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
    [[ -z "${snap_name}" ]] && snap_name="snap-$(date +%Y%m%d-%H%M%S)"
    require_incus
    info "Creating snapshot '${snap_name}' of '${vm_name}' ..."
    incus snapshot create "${vm_name}" "${snap_name}"
    ok "Snapshot created: ${vm_name}/${snap_name}"
}

_cmd_vm_snapshot_list() {
    local version="${IMT_VERSION:-sonoma}" vm_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --name)    vm_name="$2"; shift 2 ;;
            -*)        die "Unknown option: $1" ;;
            *)         shift ;;
        esac
    done
    [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
    require_incus
    info "Snapshots of '${vm_name}':"
    incus info "${vm_name}" | awk '
        /^Snapshots:/ { in_snap=1; next }
        in_snap && /^[[:space:]]/ { print }
        in_snap && /^[^[:space:]]/ { in_snap=0 }
    '
}

_cmd_vm_snapshot_restore() {
    local snap_name="" version="${IMT_VERSION:-sonoma}" vm_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --name)    vm_name="$2"; shift 2 ;;
            -*)        die "Unknown option: $1" ;;
            *)         snap_name="$1"; shift ;;
        esac
    done
    [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
    [[ -z "${snap_name}" ]] && die "Snapshot name required. Usage: imt vm snapshot restore NAME [--name VM]"
    require_incus
    info "Restoring '${vm_name}' to snapshot '${snap_name}' ..."
    incus snapshot restore "${vm_name}" "${snap_name}"
    ok "Restored: ${vm_name} → ${snap_name}"
}

_cmd_vm_snapshot_delete() {
    local snap_name="" version="${IMT_VERSION:-sonoma}" vm_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --name)    vm_name="$2"; shift 2 ;;
            -*)        die "Unknown option: $1" ;;
            *)         snap_name="$1"; shift ;;
        esac
    done
    [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
    [[ -z "${snap_name}" ]] && die "Snapshot name required. Usage: imt vm snapshot delete NAME [--name VM]"
    require_incus
    info "Deleting snapshot '${snap_name}' from '${vm_name}' ..."
    incus snapshot delete "${vm_name}" "${snap_name}"
    ok "Deleted: ${vm_name}/${snap_name}"
}

cmd_vm_assemble() {
    local assemble_file=""
    local dryrun=false
    local replace=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)    assemble_file="$2"; shift 2 ;;
            -d|--dry-run) dryrun=true;        shift ;;
            --replace)    replace=true;       shift ;;
            -h|--help)
                cat <<EOF
Usage: imt vm assemble [OPTIONS] --file FILE

Create or update macOS VMs from a declarative YAML file.

Options:
  -f, --file FILE   YAML file describing VMs (required)
      --replace     Stop and recreate existing VMs
  -d, --dry-run     Print commands without executing
  -h, --help        Show this help

YAML schema:
  vms:
    - name: macos-sonoma          # VM name (required)
      version: sonoma             # macOS version (default: sonoma)
      ram: 4GiB                   # RAM (default: 4GiB)
      cpus: 4                     # CPU count (default: 4)
      # disk: not supported here — set via 'imt image build --size'

Example:
  vms:
    - name: macos-sonoma
      version: sonoma
      ram: 8GiB
      cpus: 6
    - name: macos-ventura
      version: ventura
EOF
                return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$assemble_file" ]] && die "--file is required"
    [[ -f "$assemble_file" ]] || die "File not found: $assemble_file"

    require_incus

    # ── minimal YAML parser ───────────────────────────────────────────────────
    # Reads the 'vms:' list and extracts per-VM fields.
    # Outputs: VM_COUNT=N  V0_name=...  V0_version=...  etc.
    local parsed
    parsed="$(awk '
        /^vms:/ { in_vms=1; next }
        in_vms && /^[[:space:]]+-[[:space:]]+name:/ {
            idx++
            val=$0; sub(/.*name:[[:space:]]*/, "", val)
            print "V" (idx-1) "_name=" val
            next
        }
        in_vms && idx>0 && /^[[:space:]]+[a-z]+:/ {
            key=$0; sub(/[[:space:]]*/,"",key); sub(/:.*$/,"",key)
            val=$0; sub(/.*:[[:space:]]*/,"",val)
            print "V" (idx-1) "_" key "=" val
            next
        }
        in_vms && /^[^[:space:]]/ && !/^vms:/ { in_vms=0 }
        END { print "VM_COUNT=" idx }
    ' "$assemble_file")"

    local vm_count=0
    while IFS= read -r line; do
        [[ "$line" =~ ^VM_COUNT=([0-9]+)$ ]] && vm_count="${BASH_REMATCH[1]}"
    done <<< "$parsed"

    if [[ "$vm_count" -eq 0 ]]; then
        die "No VMs found in $assemble_file"
    fi

    info "Found $vm_count VM(s) in $assemble_file"

    local i=0
    while [[ "$i" -lt "$vm_count" ]]; do
        # Extract per-VM variables from parsed output
        local vm_name="" vm_version="" vm_ram="" vm_cpus=""
        while IFS= read -r line; do
            [[ "$line" =~ ^V${i}_name=(.+)$    ]] && vm_name="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^V${i}_version=(.+)$ ]] && vm_version="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^V${i}_ram=(.+)$     ]] && vm_ram="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^V${i}_cpus=(.+)$    ]] && vm_cpus="${BASH_REMATCH[1]}"
            # disk: field is parsed but not used — disk size is set by the
            # storage volume, not passed to imt vm create.
        done <<< "$parsed"

        [[ -z "$vm_name" ]] && { warn "VM $i has no name, skipping"; i=$((i+1)); continue; }

        log ""
        log "── VM: $vm_name ──"

        # Handle --replace
        if [[ "$replace" == true ]] && incus info "$vm_name" &>/dev/null 2>&1; then
            if [[ "$dryrun" == true ]]; then
                log "[dry-run] imt vm delete $vm_name"
            else
                log "Removing existing VM '$vm_name' (--replace) ..."
                incus stop --force "$vm_name" 2>/dev/null || true
                incus delete "$vm_name" 2>/dev/null || true
            fi
        fi

        # Build create args
        local create_args=()
        [[ -n "$vm_name"    ]] && create_args+=(--name    "$vm_name")
        [[ -n "$vm_version" ]] && create_args+=(--version "$vm_version")
        [[ -n "$vm_ram"     ]] && create_args+=(--ram     "$vm_ram")
        [[ -n "$vm_cpus"    ]] && create_args+=(--cpus    "$vm_cpus")
        # --disk is not passed: imt vm create has no --disk flag; disk size
        # is set by the storage volume built by 'imt image build --size'.

        if incus info "$vm_name" &>/dev/null 2>&1; then
            log "VM '$vm_name' already exists — skipping (use --replace to recreate)."
        elif [[ "$dryrun" == true ]]; then
            log "[dry-run] imt vm create ${create_args[*]}"
        else
            cmd_vm_create "${create_args[@]}" || \
                warn "Failed to create VM '$vm_name'"
        fi

        i=$((i+1))
    done

    log ""
    log "Assembly complete."
}

cmd_vm_export() {
    local version="${IMT_VERSION:-sonoma}" vm_name="" alias="" output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)    version="$2";  shift 2 ;;
            --name)       vm_name="$2";  shift 2 ;;
            --alias|-a)   alias="$2";    shift 2 ;;
            --output|-o)  output="$2";   shift 2 ;;
            -h|--help)
                cat <<EOF
Usage: imt vm export [OPTIONS]

Publish a macOS VM as a reusable Incus image.

Options:
  --name NAME       VM name (default: macos-<version>)
  --version VER     macOS version (default: \${IMT_VERSION:-sonoma})
  --alias ALIAS     Image alias (default: imt-<name>)
  --output PATH     Also export image to a file at PATH
  -h, --help        Show this help

The published image can be used to create new VMs:
  incus init <alias> <new-name> --vm

Examples:
  imt vm export --name macos-sonoma
  imt vm export --name macos-sonoma --alias imt-sonoma-golden
  imt vm export --name macos-sonoma --output /backups/sonoma.tar.gz
EOF
                return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
    [[ -z "${alias}" ]]   && alias="imt-${vm_name}"

    require_incus

    incus info "${vm_name}" &>/dev/null || die "VM '${vm_name}' not found"

    # Stop if running — Incus requires a stopped VM to publish
    local was_running=false
    if incus info "${vm_name}" 2>/dev/null | grep -q "^Status:.*Running"; then
        was_running=true
        info "Stopping '${vm_name}' for export ..."
        incus stop "${vm_name}"
        local wait=0
        while incus info "${vm_name}" 2>/dev/null | grep -q "^Status:.*Running" && [[ ${wait} -lt 30 ]]; do
            sleep 1; wait=$((wait+1))
        done
    fi

    info "Publishing '${vm_name}' as image '${alias}' ..."
    incus publish "${vm_name}" --alias "${alias}"
    ok "Published: ${alias}"

    if [[ -n "${output}" ]]; then
        info "Exporting image to file: ${output} ..."
        incus image export "${alias}" "${output}"
        ok "Image file: ${output}"
    fi

    [[ "${was_running}" == true ]] && { info "Restarting '${vm_name}' ..."; incus start "${vm_name}"; }

    info "Create a new VM from this image:"
    info "  incus init ${alias} <new-name> --vm"
}

cmd_vm_import() {
    local source="" vm_name="" alias="" version="${IMT_VERSION:-sonoma}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)   version="$2";  shift 2 ;;
            --name)      vm_name="$2";  shift 2 ;;
            --alias|-a)  alias="$2";    shift 2 ;;
            --from|-f)   source="$2";   shift 2 ;;
            -h|--help)
                cat <<EOF
Usage: imt vm import [OPTIONS]

Import a VM from a published Incus image or a backup file.

Options:
  --from PATH       Image file to import (required unless --alias given)
  --alias ALIAS     Use an already-imported image alias
  --name NAME       Name for the new VM (default: macos-<version>)
  --version VER     macOS version used to derive default name
  -h, --help        Show this help

Examples:
  imt vm import --from /backups/sonoma.tar.gz --name macos-sonoma-2
  imt vm import --alias imt-macos-sonoma --name macos-sonoma-clone
EOF
                return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${vm_name}" ]] && vm_name="macos-${version}-imported"

    require_incus

    if [[ -n "${source}" ]]; then
        [[ -f "${source}" ]] || die "File not found: ${source}"
        [[ -z "${alias}" ]] && alias="imt-imported-$(date +%s)"
        info "Importing image from '${source}' as '${alias}' ..."
        incus image import "${source}" --alias "${alias}"
        ok "Image imported: ${alias}"
    elif [[ -z "${alias}" ]]; then
        die "Either --from PATH or --alias ALIAS is required"
    fi

    info "Creating VM '${vm_name}' from image '${alias}' ..."
    incus init "${alias}" "${vm_name}" --vm
    ok "VM created: ${vm_name}"
    info "Start with: imt vm start --name ${vm_name}"
}

cmd_vm_fleet() {
    local subcmd="${1:-help}"
    shift || true

    case "${subcmd}" in
        list|ls|all) _fleet_list "${subcmd}" ;;
        running)    _fleet_list running ;;
        stopped)    _fleet_list stopped ;;
        start-all)  _fleet_start_all ;;
        stop-all)   _fleet_stop_all "$@" ;;
        backup-all) _fleet_backup_all ;;
        status)     _fleet_status ;;
        exec)       _fleet_exec "$@" ;;
        help|--help|-h)
            cat <<EOF
Usage: imt vm fleet <subcommand>

Subcommands:
  list          List all imt-managed VMs with status
  start-all     Start all stopped VMs
  stop-all      Stop all running VMs (--force for immediate)
  backup-all    Backup all VMs
  status        Overview of all VMs
  exec CMD      Run a command on all running VMs via incus exec

Examples:
  imt vm fleet list
  imt vm fleet start-all
  imt vm fleet stop-all --force
  imt vm fleet backup-all
  imt vm fleet exec -- uname -a
EOF
            ;;
        *) die "Unknown fleet subcommand: ${subcmd}. Run: imt vm fleet help" ;;
    esac
}

_fleet_get_vms() {
    local filter="${1:-all}"
    local vm_list
    vm_list=$(incus list --format csv -c n,s,t 2>/dev/null | grep ",virtual-machine" || true)
    [[ -z "${vm_list}" ]] && return
    case "${filter}" in
        running) echo "${vm_list}" | grep ",RUNNING,"  | cut -d',' -f1 ;;
        stopped) echo "${vm_list}" | grep -v ",RUNNING," | cut -d',' -f1 ;;
        all)     echo "${vm_list}" | cut -d',' -f1 ;;
    esac
}

_fleet_list() {
    bold "imt VMs"
    echo ""
    printf "  %-24s %-10s %-8s %-10s\n" "NAME" "STATUS" "CPU" "MEMORY"
    printf "  %-24s %-10s %-8s %-10s\n" "----" "------" "---" "------"
    local vm_list total=0 running=0
    vm_list=$(incus list --format csv -c n,s,t 2>/dev/null | grep ",virtual-machine" || true)
    [[ -z "${vm_list}" ]] && { info "  No VMs found"; return; }
    while IFS=',' read -r name status _type; do
        total=$((total+1))
        local cpu mem
        cpu=$(incus config get "${name}" limits.cpu    2>/dev/null || echo "?")
        mem=$(incus config get "${name}" limits.memory 2>/dev/null || echo "?")
        if [[ "${status}" == "RUNNING" ]]; then
            running=$((running+1))
            printf "  %-24s \033[32m%-10s\033[0m %-8s %-10s\n" "${name}" "${status}" "${cpu}" "${mem}"
        else
            printf "  %-24s %-10s %-8s %-10s\n" "${name}" "${status}" "${cpu}" "${mem}"
        fi
    done <<< "${vm_list}"
    echo ""
    info "Total: ${running} running / ${total} VMs"
}

_fleet_start_all() {
    local vms count=0
    vms=$(_fleet_get_vms stopped)
    [[ -z "${vms}" ]] && { info "No stopped VMs"; return; }
    while IFS= read -r vm; do
        [[ -n "${vm}" ]] || continue
        info "Starting: ${vm}"
        if incus start "${vm}"; then ok "  Started: ${vm}"; else warn "  Failed: ${vm}"; fi
        count=$((count+1))
    done <<< "${vms}"
    ok "Started ${count} VM(s)"
}

_fleet_stop_all() {
    local force=false
    [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]] && force=true
    local vms count=0
    vms=$(_fleet_get_vms running)
    [[ -z "${vms}" ]] && { info "No running VMs"; return; }
    while IFS= read -r vm; do
        [[ -n "${vm}" ]] || continue
        info "Stopping: ${vm}"
        if [[ "${force}" == true ]]; then
            if incus stop "${vm}" --force; then ok "  Stopped: ${vm}"; else warn "  Failed: ${vm}"; fi
        else
            if incus stop "${vm}"; then ok "  Stopped: ${vm}"; else warn "  Failed: ${vm}"; fi
        fi
        count=$((count+1))
    done <<< "${vms}"
    ok "Stopped ${count} VM(s)"
}

_fleet_backup_all() {
    local vms count=0 failed=0
    vms=$(_fleet_get_vms all)
    [[ -z "${vms}" ]] && { info "No VMs to backup"; return; }
    while IFS= read -r vm; do
        [[ -n "${vm}" ]] || continue
        info "Backing up: ${vm}"
        if _cmd_vm_backup_create --name "${vm}"; then
            count=$((count+1))
        else
            warn "  Failed: ${vm}"
            failed=$((failed+1))
        fi
    done <<< "${vms}"
    ok "Backed up ${count} VM(s)"
    [[ ${failed} -gt 0 ]] && warn "${failed} backup(s) failed"
}

_fleet_status() {
    _fleet_list
}

_fleet_exec() {
    [[ $# -gt 0 ]] || die "Usage: imt vm fleet exec -- <command>"
    local vms
    vms=$(_fleet_get_vms running)
    [[ -z "${vms}" ]] && { info "No running VMs"; return; }
    while IFS= read -r vm; do
        [[ -n "${vm}" ]] || continue
        bold "[${vm}]"
        incus exec "${vm}" -- "$@" 2>&1 | sed 's/^/  /' || warn "  Command failed on ${vm}"
        echo ""
    done <<< "${vms}"
}

cmd_vm_monitor() {
    local subcmd="${1:-status}"
    shift || true

    case "${subcmd}" in
        status)  _monitor_status "$@" ;;
        stats)   _monitor_stats  "$@" ;;
        top)     _monitor_top    "$@" ;;
        disk)    _monitor_disk   "$@" ;;
        uptime)  _monitor_uptime "$@" ;;
        health)  _monitor_health ;;
        help|--help|-h)
            cat <<EOF
Usage: imt vm monitor <subcommand> [--name VM]

Subcommands:
  status [--name VM]   Detailed VM status with resource info
  stats  [--name VM]   CPU, memory, disk, and network stats
  top                  Live overview of all VMs (refreshes every 2s)
  disk   [--name VM]   Disk usage breakdown
  uptime [--name VM]   VM uptime and creation history
  health               Host-level health check

Examples:
  imt vm monitor status --name macos-sonoma
  imt vm monitor stats  --name macos-sonoma
  imt vm monitor top
  imt vm monitor disk   --name macos-sonoma
  imt vm monitor uptime --name macos-sonoma
  imt vm monitor health
EOF
            ;;
        *) die "Unknown monitor subcommand: ${subcmd}. Run: imt vm monitor help" ;;
    esac
}

_monitor_uptime() {
    local vm_name
    vm_name=$(_monitor_parse_name "$@")
    require_incus
    incus info "${vm_name}" &>/dev/null || die "VM '${vm_name}' not found"

    local info_out status created last_used
    info_out=$(incus info "${vm_name}" 2>/dev/null)
    status=$(echo "${info_out}"    | grep "^Status:"    | awk '{print $2}')
    created=$(echo "${info_out}"   | grep "^Created:"   | sed 's/^Created:[[:space:]]*//')
    last_used=$(echo "${info_out}" | grep "^Last Used:" | sed 's/^Last Used:[[:space:]]*//')

    bold "Uptime: ${vm_name}"
    echo ""
    echo "  Created   : ${created:-unknown}"
    echo "  Last used : ${last_used:-unknown}"
    echo "  Status    : ${status:-unknown}"

    local snaps
    snaps=$(echo "${info_out}" | grep -A1 "^Snapshots:" | tail -1 || true)
    if [[ -n "${snaps}" && "${snaps}" != *"Snapshots:"* ]]; then
        echo ""
        info "Recent snapshots:"
        echo "${info_out}" | sed -n '/^Snapshots:/,/^$/p' | tail -n +2 | head -5 | sed 's/^/  /'
    fi
}

_monitor_health() {
    bold "imt System Health"
    echo ""

    if incus info >/dev/null 2>&1; then
        ok "Incus daemon: reachable"
    else
        err "Incus daemon: not reachable"
    fi

    if [[ -e /dev/kvm ]]; then
        ok "KVM: available"
    else
        warn "KVM: /dev/kvm not found"
    fi

    local pools networks vm_total vm_running
    pools=$(incus storage list --format csv 2>/dev/null | wc -l || echo "0")
    networks=$(incus network list --format csv 2>/dev/null | wc -l || echo "0")
    vm_total=$(incus list --format csv -c t 2>/dev/null | grep -c "virtual-machine" || echo "0")
    vm_running=$(incus list --format csv -c s,t 2>/dev/null | grep -c "RUNNING,virtual-machine" || echo "0")
    echo "  Storage pools : ${pools}"
    echo "  Networks      : ${networks}"
    echo "  VMs           : ${vm_running} running / ${vm_total} total"

    echo ""
    info "Host disk:"
    df -h / 2>/dev/null | tail -1 | awk '{printf "  Used: %s / %s (%s)\n", $3, $2, $5}'

    info "Host memory:"
    free -h 2>/dev/null | grep "^Mem:" | awk '{printf "  Used: %s / %s\n", $3, $2}' || true

    echo ""
    ok "Health check complete"
}

_monitor_parse_name() {
    local version="${IMT_VERSION:-sonoma}" vm_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --name)    vm_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
    echo "${vm_name}"
}

_monitor_status() {
    local vm_name
    vm_name=$(_monitor_parse_name "$@")
    require_incus
    incus info "${vm_name}" &>/dev/null || die "VM '${vm_name}' not found"

    local info_out status
    info_out=$(incus info "${vm_name}" 2>/dev/null)
    status=$(echo "${info_out}" | grep "^Status:" | awk '{print $2}')

    bold "VM: ${vm_name}"
    echo ""
    case "${status}" in
        Running) ok  "  Status: Running" ;;
        Stopped) info "  Status: Stopped" ;;
        *)       info "  Status: ${status}" ;;
    esac

    local arch created profiles
    arch=$(echo "${info_out}"     | grep "^Architecture:" | sed 's/^Architecture:[[:space:]]*//')
    created=$(echo "${info_out}"  | grep "^Created:"      | sed 's/^Created:[[:space:]]*//')
    profiles=$(echo "${info_out}" | grep "^Profiles:"     | sed 's/^Profiles:[[:space:]]*//')
    echo "  Architecture : ${arch}"
    echo "  Created      : ${created}"
    echo "  Profiles     : ${profiles}"

    local cpu mem
    cpu=$(incus config get "${vm_name}" limits.cpu    2>/dev/null || echo "?")
    mem=$(incus config get "${vm_name}" limits.memory 2>/dev/null || echo "?")
    echo "  CPU limit    : ${cpu}"
    echo "  Memory limit : ${mem}"

    if [[ "${status}" == "Running" ]]; then
        echo ""
        _monitor_stats "$@"
    fi
}

_monitor_stats() {
    local vm_name
    vm_name=$(_monitor_parse_name "$@")
    require_incus
    incus info "${vm_name}" &>/dev/null || die "VM '${vm_name}' not found"

    local info_out status
    info_out=$(incus info "${vm_name}" 2>/dev/null)
    status=$(echo "${info_out}" | grep "^Status:" | awk '{print $2}')
    [[ "${status}" != "Running" ]] && { info "'${vm_name}' is not running"; return 0; }

    bold "Resources: ${vm_name}"
    echo ""

    local cpu mem_limit mem_usage net_state ip
    cpu=$(incus config get "${vm_name}" limits.cpu    2>/dev/null || echo "?")
    mem_limit=$(incus config get "${vm_name}" limits.memory 2>/dev/null || echo "?")
    mem_usage=$(echo "${info_out}" | grep "Memory usage:" | awk '{print $NF}' || echo "")
    echo "  CPU    : ${cpu} vCPU(s)"
    if [[ -n "${mem_usage}" ]]; then
        echo "  Memory : ${mem_usage} / ${mem_limit}"
    else
        echo "  Memory : limit ${mem_limit}"
    fi

    net_state=$(echo "${info_out}" | grep -A20 "^Network usage:" || true)
    if [[ -n "${net_state}" ]]; then
        echo ""
        info "Network:"
        echo "${net_state}" | grep -E "Bytes|Packets" | sed 's/^/  /'
    fi

    ip=$(incus list "${vm_name}" --format csv -c 4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    [[ -n "${ip}" ]] && echo "" && echo "  IP: ${ip}"
}

_monitor_top() {
    bold "imt VM Monitor"
    echo ""
    printf "  %-24s %-10s %-6s %-10s %-15s\n" "NAME" "STATUS" "CPU" "MEMORY" "IP"
    printf "  %-24s %-10s %-6s %-10s %-15s\n" "----" "------" "---" "------" "--"

    local vm_list
    vm_list=$(incus list --format csv -c n,s,t 2>/dev/null | grep ",virtual-machine" || true)
    [[ -z "${vm_list}" ]] && { info "  No VMs found"; return; }

    local running=0 total=0
    while IFS=',' read -r name status _type; do
        total=$((total+1))
        local cpu mem ip
        cpu=$(incus config get "${name}" limits.cpu    2>/dev/null || echo "?")
        mem=$(incus config get "${name}" limits.memory 2>/dev/null || echo "?")
        if [[ "${status}" == "RUNNING" ]]; then
            running=$((running+1))
            ip=$(incus list "${name}" --format csv -c 4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "-")
            printf "  %-24s \033[32m%-10s\033[0m %-6s %-10s %-15s\n" "${name}" "${status}" "${cpu}" "${mem}" "${ip}"
        else
            printf "  %-24s %-10s %-6s %-10s %-15s\n" "${name}" "${status}" "${cpu}" "${mem}" "-"
        fi
    done <<< "${vm_list}"
    echo ""
    info "VMs: ${running} running / ${total} total"
}

_monitor_disk() {
    local vm_name
    vm_name=$(_monitor_parse_name "$@")
    require_incus
    incus info "${vm_name}" &>/dev/null || die "VM '${vm_name}' not found"

    bold "Disk: ${vm_name}"
    echo ""
    local disk_size
    disk_size=$(incus config device get "${vm_name}" root size 2>/dev/null || echo "?")
    echo "  Root disk allocated: ${disk_size}"

    # Custom volumes
    for suffix in disk opencore installer; do
        local vol="${vm_name}-${suffix}"
        if incus storage volume show "${IMT_STORAGE_POOL:-default}" "${vol}" &>/dev/null 2>&1; then
            local vol_size
            vol_size=$(incus storage volume get "${IMT_STORAGE_POOL:-default}" "${vol}" size 2>/dev/null || echo "?")
            echo "  Volume ${vol}: ${vol_size}"
        fi
    done
}

_IMT_BACKUP_STORE="${IMT_BACKUP_STORE:-${HOME}/.local/share/imt/vm-backups}"

cmd_vm_backup() {
    local subcmd="${1:-create}"
    # If first arg looks like an option or is absent, treat as 'create'
    [[ "${subcmd}" == -* ]] && subcmd="create"
    case "${subcmd}" in
        create|list|ls|delete|rm|help|--help|-h) shift || true ;;
        *) subcmd="create" ;;
    esac

    case "${subcmd}" in
        create)  _cmd_vm_backup_create "$@" ;;
        list|ls) _cmd_vm_backup_list ;;
        delete|rm) _cmd_vm_backup_delete "$@" ;;
        help|--help|-h)
            cat <<EOF
Usage: imt vm backup <subcommand> [options]

Subcommands:
  create [options]    Back up a VM and its storage volumes
  list                List available local backups
  delete NAME         Delete a local backup directory

Create options:
  --name VM           VM name (default: macos-<version>)
  --version VER       macOS version (default: \${IMT_VERSION:-sonoma})
  --output|-o DIR     Output directory (default: auto-named in \$IMT_BACKUP_STORE)

Backup store: \${IMT_BACKUP_STORE:-~/.local/share/imt/vm-backups}
EOF
            ;;
        *) die "Unknown backup subcommand: ${subcmd}. Run: imt vm backup help" ;;
    esac
}

_cmd_vm_backup_create() {
    local output_dir=""
    local version="${IMT_VERSION:-sonoma}"
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)   version="$2";    shift 2 ;;
            --name)      name="$2";       shift 2 ;;
            --output|-o) output_dir="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "$name" ]] && name="macos-${version}"
    if [[ -z "$output_dir" ]]; then
        mkdir -p "${_IMT_BACKUP_STORE}"
        output_dir="${_IMT_BACKUP_STORE}/${name}-backup-$(date +%Y%m%d-%H%M%S)"
    fi

    require_incus

    mkdir -p "$output_dir"
    info "Backing up VM '$name' to '$output_dir' ..."

    # Export the Incus instance (metadata + root disk if managed by Incus)
    info "Exporting instance metadata ..."
    incus export "$name" "${output_dir}/${name}.tar.gz" 2>/dev/null || \
        warn "Instance export failed or VM has no Incus-managed root disk — skipping."

    # Export each custom storage volume
    for suffix in disk opencore installer; do
        local vol="${name}-${suffix}"
        if incus storage volume show "$IMT_STORAGE_POOL" "$vol" &>/dev/null 2>&1; then
            info "Exporting storage volume '$vol' ..."
            incus storage volume export \
                "$IMT_STORAGE_POOL" "$vol" \
                "${output_dir}/${vol}.tar.gz"
            ok "Exported: ${output_dir}/${vol}.tar.gz"
        else
            info "Volume '$vol' not found — skipping."
        fi
    done

    ok "Backup complete: $output_dir"
    echo ""
    bold "To restore:"
    echo "  imt vm restore --name $name --from $output_dir"
}

_cmd_vm_backup_list() {
    mkdir -p "${_IMT_BACKUP_STORE}"
    bold "VM Backups: ${_IMT_BACKUP_STORE}"
    echo ""
    printf "  %-40s %-12s %s\n" "NAME" "SIZE" "DATE"
    printf "  %-40s %-12s %s\n" "----" "----" "----"

    local found=false
    for d in "${_IMT_BACKUP_STORE}"/*/; do
        [[ -d "$d" ]] || continue
        found=true
        local bname size date_str
        bname="$(basename "$d")"
        size="$(du -sh "$d" 2>/dev/null | awk '{print $1}' || echo "?")"
        date_str="$(stat -c%y "$d" 2>/dev/null | cut -d. -f1 || stat -f%Sm "$d" 2>/dev/null || echo "unknown")"
        printf "  %-40s %-12s %s\n" "$bname" "$size" "$date_str"
    done

    if [[ "$found" == false ]]; then
        info "  No backups found in ${_IMT_BACKUP_STORE}"
    fi
    echo ""
    info "Backup store: ${_IMT_BACKUP_STORE}"
}

_cmd_vm_backup_delete() {
    local backup_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) cmd_vm_backup help; return ;;
            -*) die "Unknown option: $1" ;;
            *) backup_name="$1"; shift ;;
        esac
    done
    [[ -n "$backup_name" ]] || die "Backup name required. Usage: imt vm backup delete <name>"

    local backup_path="${_IMT_BACKUP_STORE}/${backup_name}"
    [[ -d "$backup_path" ]] || die "Backup not found: ${backup_path}"

    info "Deleting backup: $backup_name"
    rm -rf "$backup_path"
    ok "Backup deleted: $backup_name"
}

cmd_vm_restore() {
    local from_dir=""
    local version="${IMT_VERSION:-sonoma}"
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)   version="$2";  shift 2 ;;
            --name)      name="$2";     shift 2 ;;
            --from|-f)   from_dir="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "$from_dir" ]] && die "--from DIR is required"
    [[ -d "$from_dir" ]] || die "Backup directory not found: $from_dir"
    [[ -z "$name" ]] && name="macos-${version}"

    require_incus

    info "Restoring VM '$name' from '$from_dir' ..."

    # Restore custom storage volumes first
    for suffix in disk opencore installer; do
        local vol="${name}-${suffix}"
        local archive="${from_dir}/${vol}.tar.gz"
        if [[ -f "$archive" ]]; then
            if incus storage volume show "$IMT_STORAGE_POOL" "$vol" &>/dev/null 2>&1; then
                warn "Volume '$vol' already exists — skipping import."
            else
                info "Importing storage volume '$vol' ..."
                incus storage volume import "$IMT_STORAGE_POOL" "$archive" "$vol"
                ok "Imported: $vol"
            fi
        else
            info "No archive for '$vol' in $from_dir — skipping."
        fi
    done

    # Restore the instance if an instance archive exists
    local instance_archive="${from_dir}/${name}.tar.gz"
    if [[ -f "$instance_archive" ]]; then
        if incus info "$name" &>/dev/null 2>&1; then
            warn "Instance '$name' already exists — skipping instance import."
        else
            info "Importing instance '$name' ..."
            incus import "$instance_archive" --storage "$IMT_STORAGE_POOL"
            ok "Instance imported: $name"
        fi
    else
        info "No instance archive found in $from_dir."
        info "If the VM was created with 'imt vm create', re-run it to recreate the instance."
    fi

    ok "Restore complete."
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
    # --columns nstL adds a PROFILES column so we can filter on macos-kvm.
    # The default table format has no PROFILES column, so grep/awk on the
    # profile name would never match any data row.
    incus list --format table --columns nstL | \
        awk 'NR<=2 || /macos-kvm/'
}

# ── vm disk ──────────────────────────────────────────────────────────────────

cmd_vm_disk() {
    # Live disk resize for macOS VMs.
    #
    # macOS VMs use a QCOW2 storage volume (<name>-disk) in Incus.
    # Resizing requires:
    #   1. Stopping the VM
    #   2. Resizing the Incus storage volume (incus storage volume set size)
    #   3. Restarting the VM — macOS will see the larger disk on next boot
    #
    # Usage: imt vm disk <subcommand> [options]
    #
    # Subcommands:
    #   resize   Resize the VM disk
    #   info     Show current disk size

    local subcmd="${1:-help}"; shift || true

    case "${subcmd}" in
        resize)
            local name="" version="${IMT_VERSION:-sonoma}" new_size=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)    name="$2";     shift 2 ;;
                    --version) version="$2";  shift 2 ;;
                    --size)    new_size="$2"; shift 2 ;;
                    --help|-h)
                        cat <<EOF
imt vm disk resize — resize a macOS VM's disk

Usage: imt vm disk resize --size SIZE [--name NAME] [--version VER]

Options:
  --size SIZE      New disk size (e.g. 128G, 256G) — required
  --name NAME      VM name (default: macos-<version>)
  --version VER    macOS version (default: sonoma)

Note: The VM must be stopped before resizing. macOS will see the
larger disk on next boot; use Disk Utility to expand the partition.

Examples:
  imt vm disk resize --size 256G
  imt vm disk resize --name macos-ventura --size 200G
EOF
                        return 0 ;;
                    *) die "Unknown option: $1. Run: imt vm disk resize --help" ;;
                esac
            done

            [[ -z "${name}" ]] && name="macos-${version}"
            [[ -n "${new_size}" ]] || die "--size is required"
            require_incus

            if ! incus info "${name}" &>/dev/null 2>&1; then
                die "VM '${name}' does not exist"
            fi

            local state
            state=$(incus list --format csv -c s "${name}" 2>/dev/null | head -1)
            if [[ "${state}" = "RUNNING" ]]; then
                die "VM '${name}' is running. Stop it first: imt vm stop --name ${name}"
            fi

            local vol="${name}-disk"
            local pool="${IMT_STORAGE_POOL:-default}"

            info "Resizing storage volume '${vol}' in pool '${pool}' to ${new_size}..."
            incus storage volume set "${pool}" "${vol}" size "${new_size}"
            ok "Disk resized to ${new_size}"
            info "Start the VM and use Disk Utility to expand the partition:"
            info "  imt vm start --name ${name}"
            ;;

        info)
            local name="" version="${IMT_VERSION:-sonoma}"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)    name="$2";    shift 2 ;;
                    --version) version="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done

            [[ -z "${name}" ]] && name="macos-${version}"
            require_incus

            if ! incus info "${name}" &>/dev/null 2>&1; then
                die "VM '${name}' does not exist"
            fi

            local vol="${name}-disk"
            local pool="${IMT_STORAGE_POOL:-default}"

            info "Disk info for VM: ${name}"
            echo ""
            info "  Storage volume : ${vol}"
            info "  Pool           : ${pool}"
            echo ""
            incus storage volume show "${pool}" "${vol}" 2>/dev/null \
                | grep -E 'name:|config:|size:' | sed 's/^/  /' || true
            ;;

        help|--help|-h)
            cat <<EOF
imt vm disk — live disk resize for macOS VMs

Usage: imt vm disk <subcommand> [options]

Subcommands:
  resize   Resize the VM's QCOW2 storage volume
  info     Show current disk size and pool info

Examples:
  imt vm disk info
  imt vm disk resize --size 256G
  imt vm disk resize --name macos-ventura --size 200G
EOF
            ;;

        *) die "Unknown disk subcommand: ${subcmd}. Run: imt vm disk help" ;;
    esac
}

# ── vm upgrade ───────────────────────────────────────────────────────────────

cmd_vm_upgrade() {
    # Run macOS Software Update inside a running VM.
    #
    # Usage: imt vm upgrade [--name NAME] [--version VER] [--list] [--restart]
    #
    # Options:
    #   --name NAME      Incus instance name (default: macos-<version>)
    #   --version VER    macOS version used to derive default name
    #   --list           List available updates without installing
    #   --restart        Restart the VM after updates are applied
    #   --no-snapshot    Skip the pre-upgrade snapshot
    #   --help           Show this help

    local name="" version="${IMT_VERSION:-sonoma}" list_only=0 do_restart=0 no_snapshot=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)      name="$2";    shift 2 ;;
            --version)   version="$2"; shift 2 ;;
            --list)      list_only=1;  shift ;;
            --restart)   do_restart=1; shift ;;
            --no-snapshot) no_snapshot=1; shift ;;
            --help|-h)
                cat <<EOF
imt vm upgrade — run macOS Software Update inside a running VM

Usage: imt vm upgrade [options]

Options:
  --name NAME      Incus instance name (default: macos-<version>)
  --version VER    macOS version used to derive default name (default: sonoma)
  --list           List available updates without installing
  --restart        Restart the VM after updates are applied
  --no-snapshot    Skip the pre-upgrade snapshot (not recommended)

Examples:
  imt vm upgrade
  imt vm upgrade --name macos-ventura --list
  imt vm upgrade --name macos-sonoma --restart
EOF
                return 0 ;;
            *) die "Unknown option: $1. Run: imt vm upgrade --help" ;;
        esac
    done

    [[ -z "$name" ]] && name="macos-${version}"
    require_incus

    # Verify the VM exists and is running
    if ! incus info "$name" &>/dev/null; then
        die "VM '$name' does not exist"
    fi
    local state
    state=$(incus list --format csv -c s "$name" 2>/dev/null | head -1)
    if [[ "$state" != "RUNNING" ]]; then
        die "VM '$name' is not running. Start it first: imt vm start --name $name"
    fi

    if [[ "$list_only" -eq 1 ]]; then
        info "Checking for available updates in '$name'..."
        incus exec "$name" -- /bin/bash -c \
            'softwareupdate --list 2>&1' \
            || die "softwareupdate --list failed (is macOS booted?)"
        return 0
    fi

    # Pre-upgrade snapshot
    if [[ "$no_snapshot" -eq 0 ]]; then
        local snap_name
        snap_name="pre-upgrade-$(date +%Y%m%d-%H%M%S)"
        info "Creating pre-upgrade snapshot: $snap_name"
        if incus snapshot create "$name" "$snap_name"; then
            ok "Snapshot created: $snap_name"
        else
            warn "Snapshot failed — continuing without it"
        fi
    fi

    info "Running Software Update in '$name' (this may take a while)..."
    incus exec "$name" -- /bin/bash -c \
        'softwareupdate --install --all --verbose 2>&1' \
        || die "softwareupdate failed"

    ok "Software Update complete in '$name'"

    if [[ "$do_restart" -eq 1 ]]; then
        info "Restarting '$name'..."
        incus exec "$name" -- /bin/bash -c 'shutdown -r now' 2>/dev/null || true
        ok "Restart initiated"
    else
        info "Restart may be required. Run: imt vm upgrade --name $name --restart"
    fi
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
        path)
            printf '%s\n' "$IMT_CONFIG_FILE"
            ;;
        *) die "Unknown config subcommand: $subcmd (show|init|edit|path)" ;;
    esac
}

# ── version ───────────────────────────────────────────────────────────────────

cmd_version() {
    echo "imt $VERSION"
}

# ── Net / port forwarding ─────────────────────────────────────────────────────

cmd_vm_net() {
    local subcmd="${1:-help}"; shift || true

    case "${subcmd}" in
        forward|fwd)
            local host_port="${1:?Usage: imt vm net forward HOST_PORT [CONTAINER_PORT] [--proto tcp|udp] [--name VM]}"
            shift
            local container_port="${host_port}"
            local proto="tcp"
            local listen_addr="0.0.0.0"
            local proxy_name=""
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --proto)   proto="$2";        shift 2 ;;
                    --listen)  listen_addr="$2";  shift 2 ;;
                    --proxy)   proxy_name="$2";   shift 2 ;;
                    --version) version="$2";      shift 2 ;;
                    --name)    vm_name="$2";       shift 2 ;;
                    -*) die "Unknown option: $1" ;;
                    *)  container_port="$1";      shift ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            [[ -z "${proxy_name}" ]] && proxy_name="fwd-${host_port}"
            require_incus
            info "Adding port forward: ${listen_addr}:${host_port} → ${vm_name}:${container_port} (${proto})"
            incus config device add "${vm_name}" "${proxy_name}" proxy \
                "listen=${proto}:${listen_addr}:${host_port}" \
                "connect=${proto}:127.0.0.1:${container_port}"
            ok "Port forward added: ${proxy_name}"
            info "  Host     : ${listen_addr}:${host_port}"
            info "  VM       : 127.0.0.1:${container_port}"
            ;;

        unforward|unfwd|rm)
            local proxy_name="${1:?Usage: imt vm net unforward PROXY_NAME [--name VM]}"
            shift
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            incus config device remove "${vm_name}" "${proxy_name}"
            ok "Removed port forward: ${proxy_name}"
            ;;

        list|ls)
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            bold "Port forwards: ${vm_name}"
            echo ""
            printf "  %-20s %-30s %s\n" "DEVICE" "LISTEN" "CONNECT"
            printf "  %-20s %-30s %s\n" "------" "------" "-------"
            local found=false
            while IFS= read -r dev; do
                [[ -n "${dev}" ]] || continue
                local listen connect
                listen=$(incus config device get "${vm_name}" "${dev}" listen 2>/dev/null || echo "")
                connect=$(incus config device get "${vm_name}" "${dev}" connect 2>/dev/null || echo "")
                [[ -n "${listen}" ]] || continue
                found=true
                printf "  %-20s %-30s %s\n" "${dev}" "${listen}" "${connect}"
            done < <(incus config device list "${vm_name}" 2>/dev/null | grep "proxy" | awk '{print $1}' || true)
            ${found} || info "  No port forwards configured"
            ;;

        status)
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            bold "Network status: ${vm_name}"
            echo ""
            incus info "${vm_name}" 2>/dev/null | awk '
                /^Network usage:/ { in_net=1; next }
                in_net && /^[A-Z]/ { in_net=0 }
                in_net { print "  " $0 }
            '
            echo ""
            info "Proxy devices:"
            incus config device show "${vm_name}" 2>/dev/null \
            | awk '/type: proxy/{found=1} found{print "  " $0; if(/^$/)found=0}' \
            || info "  None"
            ;;

        help|--help|-h)
            cat <<EOF
Usage: imt vm net <subcommand> [--name VM] [options]

Subcommands:
  forward HOST_PORT [CONTAINER_PORT]   Add a port forward proxy device
  unforward PROXY_NAME                 Remove a port forward
  list                                 List all port forwards
  status                               Show network interfaces and forwards

Options:
  --name VM       VM name (default: macos-<version>)
  --version VER   macOS version (default: \${IMT_VERSION:-sonoma})
  --proto tcp|udp Protocol (default: tcp)
  --listen ADDR   Listen address (default: 0.0.0.0)

Examples:
  imt vm net forward 8080 --name macos-sonoma
  imt vm net forward 8080 80 --proto tcp --name macos-sonoma
  imt vm net list --name macos-sonoma
  imt vm net unforward fwd-8080 --name macos-sonoma
  imt vm net status --name macos-sonoma
EOF
            ;;


        nic)
            cmd_vm_net_nic "$@"
            ;;
        *) die "Unknown net subcommand: ${subcmd}. Run: imt vm net help" ;;

    esac
}

# ── GPU passthrough ───────────────────────────────────────────────────────────

cmd_vm_gpu() {
    local subcmd="${1:-help}"; shift || true

    case "${subcmd}" in
        list-host|host)
            bold "GPUs available on host:"
            echo ""
            if incus info --resources >/dev/null 2>&1; then
                incus info --resources 2>/dev/null | awk '
                    /^  GPUs:/,/^  [A-Z][a-z]/ {
                        if (!/^  GPUs:/ && !/^  [A-Z][a-z]/) print "  " $0
                    }
                '
            else
                warn "Could not retrieve GPU info from incus"
            fi
            if command -v lspci >/dev/null 2>&1; then
                echo ""
                info "PCI GPU devices:"
                lspci 2>/dev/null | grep -iE "VGA|3D|Display|NVIDIA|AMD|Intel.*Graphics" \
                | sed 's/^/  /' || info "  None found"
            fi
            ;;

        attach|add)
            local gpu_type="physical" pci_addr="" dev_name="gpu0" vendor=""
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --type)     gpu_type="$2"; shift 2 ;;
                    --pci)      pci_addr="$2"; shift 2 ;;
                    --dev-name) dev_name="$2"; shift 2 ;;
                    --vendor)   vendor="$2";   shift 2 ;;
                    --version)  version="$2";  shift 2 ;;
                    --name)     vm_name="$2";  shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            local device_args=("${vm_name}" "${dev_name}" gpu "gputype=${gpu_type}")
            [[ -n "${pci_addr}" ]] && device_args+=("pci=${pci_addr}")
            [[ -n "${vendor}" ]]   && device_args+=("vendorid=${vendor}")
            info "Attaching GPU to '${vm_name}' (type=${gpu_type}${pci_addr:+, pci=${pci_addr}})"
            incus config device add "${device_args[@]}"
            ok "GPU attached: ${dev_name} → ${vm_name}"
            info "  Type : ${gpu_type}"
            [[ -n "${pci_addr}" ]] && info "  PCI  : ${pci_addr}"
            ;;

        detach|remove|rm)
            local dev_name="${1:?Usage: imt vm gpu detach DEV_NAME [--name VM]}"
            shift
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            incus config device remove "${vm_name}" "${dev_name}"
            ok "GPU removed: ${dev_name} from '${vm_name}'"
            ;;

        list|ls)
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            bold "GPUs attached to '${vm_name}':"
            echo ""
            printf "  %-20s %-12s %s\n" "DEVICE" "TYPE" "PCI"
            printf "  %-20s %-12s %s\n" "------" "----" "---"
            local found=false
            while IFS= read -r dev; do
                [[ -n "${dev}" ]] || continue
                local gtype pci
                gtype=$(incus config device get "${vm_name}" "${dev}" gputype  2>/dev/null || echo "physical")
                pci=$(incus config device get   "${vm_name}" "${dev}" pci      2>/dev/null || echo "")
                found=true
                printf "  %-20s %-12s %s\n" "${dev}" "${gtype}" "${pci}"
            done < <(incus config device list "${vm_name}" 2>/dev/null | grep "gpu" | awk '{print $1}' || true)
            ${found} || info "  No GPU devices attached"
            ;;

        status)
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            bold "GPU status: ${vm_name}"
            echo ""
            cmd_vm_gpu list --name "${vm_name}"
            echo ""
            info "Host GPU resources:"
            incus info --resources 2>/dev/null | awk '
                /^  GPUs:/,/^  [A-Z][a-z]/ {
                    if (!/^  GPUs:/ && !/^  [A-Z][a-z]/) print "  " $0
                }
            ' || true
            ;;

        help|--help|-h)
            cat <<EOF
Usage: imt vm gpu <subcommand> [--name VM] [options]

Subcommands:
  list-host              List GPUs available on the host
  attach                 Attach a GPU to the VM
  detach DEV_NAME        Remove a GPU from the VM
  list                   List GPUs attached to the VM
  status                 Show GPU status

Attach options:
  --type physical|mdev|mig|virtio   GPU type (default: physical)
  --pci ADDR                        PCI address (e.g. 0000:01:00.0)
  --dev-name NAME                   Device name (default: gpu0)
  --vendor VENDOR                   GPU vendor filter

Options:
  --name VM       VM name (default: macos-<version>)
  --version VER   macOS version (default: \${IMT_VERSION:-sonoma})

Examples:
  imt vm gpu list-host
  imt vm gpu attach --name macos-sonoma
  imt vm gpu attach --pci 0000:01:00.0 --type physical --name macos-sonoma
  imt vm gpu list --name macos-sonoma
  imt vm gpu detach gpu0 --name macos-sonoma
EOF
            ;;
        *) die "Unknown gpu subcommand: ${subcmd}. Run: imt vm gpu help" ;;
    esac
}

# ── USB passthrough ───────────────────────────────────────────────────────────

cmd_vm_usb() {
    local subcmd="${1:-help}"; shift || true

    case "${subcmd}" in
        list-host|host)
            bold "USB devices on host:"
            echo ""
            if command -v lsusb >/dev/null 2>&1; then
                printf "  %-12s %s\n" "VENDOR:ID" "DESCRIPTION"
                printf "  %-12s %s\n" "---------" "-----------"
                lsusb | while IFS= read -r line; do
                    local vid pid desc
                    vid=$(echo "${line}" | awk '{print $6}' | cut -d: -f1)
                    pid=$(echo "${line}" | awk '{print $6}' | cut -d: -f2)
                    desc=$(echo "${line}" | cut -d: -f3- | sed 's/^ //')
                    printf "  %-12s %s\n" "${vid}:${pid}" "${desc}"
                done
            else
                warn "lsusb not found — install usbutils"
            fi
            ;;

        attach|add)
            local vid="${1:?Usage: imt vm usb attach VID PID [--name VM]}"
            local pid="${2:-}"
            # Support VID:PID as a single argument (e.g. 046d:c52b)
            if [[ -z "${pid}" && "${vid}" == *:* ]]; then
                pid="${vid##*:}"
                vid="${vid%%:*}"
                shift 1
            else
                [[ -n "${pid}" ]] || die "Usage: imt vm usb attach VID PID [--name VM]"
                shift 2
            fi
            local dev_name="" version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dev-name) dev_name="$2"; shift 2 ;;
                    --version)  version="$2";  shift 2 ;;
                    --name)     vm_name="$2";  shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            [[ -z "${dev_name}" ]] && dev_name="usb-${vid}-${pid}"
            require_incus
            info "Attaching USB ${vid}:${pid} to '${vm_name}' as '${dev_name}'"
            incus config device add "${vm_name}" "${dev_name}" usb \
                "vendorid=${vid}" "productid=${pid}"
            ok "USB device attached: ${dev_name} (${vid}:${pid}) → ${vm_name}"
            ;;

        detach|remove|rm)
            local dev_name="${1:?Usage: imt vm usb detach DEV_NAME [--name VM]}"
            shift
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            incus config device remove "${vm_name}" "${dev_name}"
            ok "USB device removed: ${dev_name} from '${vm_name}'"
            ;;

        list|ls)
            local version="${IMT_VERSION:-sonoma}" vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --name)    vm_name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -z "${vm_name}" ]] && vm_name="macos-${version}"
            require_incus
            bold "USB devices attached to '${vm_name}':"
            echo ""
            printf "  %-20s %-10s %s\n" "DEVICE" "VENDOR" "PRODUCT"
            printf "  %-20s %-10s %s\n" "------" "------" "-------"
            local found=false
            while IFS= read -r dev; do
                [[ -n "${dev}" ]] || continue
                local vid pid
                vid=$(incus config device get "${vm_name}" "${dev}" vendorid  2>/dev/null || echo "")
                pid=$(incus config device get "${vm_name}" "${dev}" productid 2>/dev/null || echo "")
                [[ -n "${vid}" ]] || continue
                found=true
                printf "  %-20s %-10s %s\n" "${dev}" "${vid}" "${pid}"
            done < <(incus config device list "${vm_name}" 2>/dev/null | grep "usb" | awk '{print $1}' || true)
            ${found} || info "  No USB devices attached"
            ;;

        help|--help|-h)
            cat <<EOF
Usage: imt vm usb <subcommand> [--name VM] [options]

Subcommands:
  list-host              List USB devices available on the host
  attach VID PID         Attach a USB device to the VM
  detach DEV_NAME        Remove a USB device from the VM
  list                   List USB devices attached to the VM

Options:
  --name VM       VM name (default: macos-<version>)
  --version VER   macOS version (default: \${IMT_VERSION:-sonoma})
  --dev-name NAME Custom device name for attach (default: usb-<VID>-<PID>)

Examples:
  imt vm usb list-host
  imt vm usb attach 046d c52b --name macos-sonoma
  imt vm usb list --name macos-sonoma
  imt vm usb detach usb-046d-c52b --name macos-sonoma
EOF
            ;;
        *) die "Unknown usb subcommand: ${subcmd}. Run: imt vm usb help" ;;
    esac
}

# ── Cloud sync ────────────────────────────────────────────────────────────────

IMT_BACKUP_DIR="${IMT_BACKUP_DIR:-${HOME}/.local/share/imt/backups}"
IMT_CLOUD_REMOTE="${IMT_CLOUD_REMOTE:-imt-backups}"
IMT_CLOUD_PATH="${IMT_CLOUD_PATH:-imt/backups}"

_require_rclone() {
    if ! command -v rclone >/dev/null 2>&1; then
        die "rclone is required for cloud sync. Install: https://rclone.org/install/"
    fi
}

_remote_configured() {
    rclone listremotes 2>/dev/null | grep -q "^${IMT_CLOUD_REMOTE}:" 2>/dev/null
}

cmd_cloud_sync() {
    local subcmd="${1:-help}"; shift || true

    case "${subcmd}" in
        push)
            _require_rclone
            mkdir -p "${IMT_BACKUP_DIR}"
            _remote_configured || die "Remote '${IMT_CLOUD_REMOTE}' not configured. Run: imt cloud-sync config"
            local file_filter="${1:-}"
            info "Cloud Sync: Push"
            info "  Local  : ${IMT_BACKUP_DIR}"
            info "  Remote : ${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}"
            local count=0
            for f in "${IMT_BACKUP_DIR}"/*.tar.gz "${IMT_BACKUP_DIR}"/*.tar; do
                [[ -f "${f}" ]] || continue
                local filename; filename="$(basename "${f}")"
                if [[ -n "${file_filter}" ]] && ! printf '%s' "${filename}" | grep -q "${file_filter}"; then
                    continue
                fi
                local size; size="$(stat -c%s "${f}" 2>/dev/null || stat -f%z "${f}" 2>/dev/null || echo 0)"
                info "  Uploading: ${filename} ($(human_size "${size}"))"
                rclone copy "${f}" "${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}/" --progress --transfers 1 || {
                    warn "Failed to upload: ${filename}"; continue
                }
                count=$(( count + 1 ))
            done
            for f in "${IMT_BACKUP_DIR}"/*.meta; do
                [[ -f "${f}" ]] || continue
                rclone copy "${f}" "${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}/" 2>/dev/null || true
            done
            if [[ ${count} -eq 0 ]]; then info "No backups to upload"; else ok "Uploaded ${count} backup(s)"; fi
            ;;

        pull)
            _require_rclone
            mkdir -p "${IMT_BACKUP_DIR}"
            _remote_configured || die "Remote '${IMT_CLOUD_REMOTE}' not configured. Run: imt cloud-sync config"
            local file_filter="${1:-}"
            info "Cloud Sync: Pull"
            info "  Remote : ${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}"
            info "  Local  : ${IMT_BACKUP_DIR}"
            if [[ -n "${file_filter}" ]]; then
                rclone copy "${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}/" "${IMT_BACKUP_DIR}/" \
                    --include "*${file_filter}*" --progress --transfers 1 || die "Pull failed"
            else
                rclone copy "${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}/" "${IMT_BACKUP_DIR}/" \
                    --progress --transfers 1 || die "Pull failed"
            fi
            ok "Pull complete"
            ;;

        list|ls)
            _require_rclone
            _remote_configured || die "Remote '${IMT_CLOUD_REMOTE}' not configured. Run: imt cloud-sync config"
            bold "Remote Backups: ${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}"
            printf "  %-40s %-12s %s\n" "FILENAME" "SIZE" "MODIFIED"
            printf "  %-40s %-12s %s\n" "--------" "----" "--------"
            rclone lsf "${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}/" --format "psm" 2>/dev/null | \
            while IFS=';' read -r path size mod; do
                [[ -n "${path}" ]] || continue
                [[ "${path}" == *.meta ]] && continue
                printf "  %-40s %-12s %s\n" "${path}" "${size}" "${mod}"
            done || info "  No remote backups found"
            local local_count remote_count
            local_count="$(find "${IMT_BACKUP_DIR}" -name '*.tar*' 2>/dev/null | wc -l)"
            remote_count="$(rclone lsf "${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}/" --include '*.tar*' 2>/dev/null | wc -l || echo 0)"
            info "Local: ${local_count} backups | Remote: ${remote_count} backups"
            ;;

        config)
            _require_rclone
            local cfg_sub="${1:-interactive}"; shift || true
            case "${cfg_sub}" in
                show)
                    bold "Cloud Sync Configuration"
                    printf "  Remote name : %s\n" "${IMT_CLOUD_REMOTE}"
                    printf "  Remote path : %s\n" "${IMT_CLOUD_PATH}"
                    printf "  Local dir   : %s\n" "${IMT_BACKUP_DIR}"
                    if _remote_configured; then ok "Remote '${IMT_CLOUD_REMOTE}' is configured"
                    else warn "Remote '${IMT_CLOUD_REMOTE}' is not configured"; fi
                    ;;
                s3)
                    info "Configuring S3-compatible remote..."
                    rclone config create "${IMT_CLOUD_REMOTE}" s3 provider "AWS" env_auth "false" \
                        || die "S3 config failed"
                    ok "S3 remote configured as '${IMT_CLOUD_REMOTE}'"
                    ;;
                b2)
                    info "Configuring Backblaze B2 remote..."
                    rclone config create "${IMT_CLOUD_REMOTE}" b2 || die "B2 config failed"
                    ok "B2 remote configured as '${IMT_CLOUD_REMOTE}'"
                    ;;
                interactive|setup)
                    info "Launching rclone interactive config..."
                    printf "Create a remote named: %s\n" "${IMT_CLOUD_REMOTE}"
                    rclone config
                    ;;
                *)
                    cat <<EOF
imt cloud-sync config - Configure cloud storage

Subcommands:
  show          Show current configuration
  s3            Configure S3-compatible storage
  b2            Configure Backblaze B2
  interactive   Launch rclone interactive config (default)

Environment variables (set in ~/.config/imt/config):
  IMT_CLOUD_REMOTE   rclone remote name (default: imt-backups)
  IMT_CLOUD_PATH     Remote path (default: imt/backups)
  IMT_BACKUP_DIR     Local backup directory
EOF
                    ;;
            esac
            ;;

        status)
            _require_rclone
            bold "Cloud Sync Status"
            if ! _remote_configured; then
                warn "Remote '${IMT_CLOUD_REMOTE}' not configured"
                info "Run: imt cloud-sync config"
                return 1
            fi
            ok "Remote: ${IMT_CLOUD_REMOTE} (configured)"
            info "Path: ${IMT_CLOUD_PATH}"
            local local_count local_size remote_count
            local_count="$(find "${IMT_BACKUP_DIR}" -name '*.tar*' 2>/dev/null | wc -l)"
            local_size="$(du -sh "${IMT_BACKUP_DIR}" 2>/dev/null | awk '{print $1}' || echo 0)"
            remote_count="$(rclone lsf "${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}/" --include '*.tar*' 2>/dev/null | wc -l || echo '?')"
            printf "  Local backups  : %s (%s)\n" "${local_count}" "${local_size}"
            printf "  Remote backups : %s\n" "${remote_count}"
            local unsynced=0
            for f in "${IMT_BACKUP_DIR}"/*.tar.gz "${IMT_BACKUP_DIR}"/*.tar; do
                [[ -f "${f}" ]] || continue
                local fname; fname="$(basename "${f}")"
                if ! rclone lsf "${IMT_CLOUD_REMOTE}:${IMT_CLOUD_PATH}/${fname}" >/dev/null 2>&1; then
                    unsynced=$(( unsynced + 1 ))
                fi
            done
            if [[ ${unsynced} -gt 0 ]]; then
                warn "${unsynced} local backup(s) not yet synced"
                info "Run: imt cloud-sync push"
            else
                ok "All local backups synced"
            fi
            ;;

        help|--help|-h)
            cat <<EOF
imt cloud-sync — sync VM backups to cloud storage

Usage: imt cloud-sync <subcommand> [options]

Subcommands:
  push [filter]     Upload local backups to remote
  pull [filter]     Download remote backups to local
  list              List remote backups
  config [type]     Configure remote storage (s3, b2, interactive)
  status            Show sync status

Options:
  filter   Optional filename filter (e.g. VM name)

Environment (set in ~/.config/imt/config):
  IMT_CLOUD_REMOTE   rclone remote name (default: imt-backups)
  IMT_CLOUD_PATH     Remote path (default: imt/backups)
  IMT_BACKUP_DIR     Local backup directory

Examples:
  imt cloud-sync config s3
  imt cloud-sync push
  imt cloud-sync push macos-sonoma
  imt cloud-sync pull
  imt cloud-sync list
  imt cloud-sync status
EOF
            ;;

        *) die "Unknown cloud-sync subcommand: ${subcmd}. Run: imt cloud-sync help" ;;
    esac
}

# ── dashboard ────────────────────────────────────────────────────────────────

cmd_dashboard() {
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local dash_script="${_script_dir}/../tui/imt-dashboard.sh"

    if [[ -x "${dash_script}" ]]; then
        exec "${dash_script}" "$@"
    else
        die "Dashboard script not found at ${dash_script}"
    fi
}

# ── tui ──────────────────────────────────────────────────────────────────────

cmd_tui() {
    # Interactive terminal UI for imt.
    # Requires dialog or whiptail.

    local _imt_script_dir
    _imt_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local tui_script="${_imt_script_dir}/../tui/imt-tui.sh"

    if [[ -x "${tui_script}" ]]; then
        exec "${tui_script}" "$@"
    else
        die "TUI script not found at ${tui_script}. Run: imt tui --help"
    fi
}

# ── setup-rootless ───────────────────────────────────────────────────────────

cmd_setup_rootless() {
    # Guided setup for running macOS VMs as a non-root user via incus-user.
    #
    # Checks and optionally fixes:
    #   1. Not running as root
    #   2. incus-user daemon (systemd user service + socket)
    #   3. KVM device access (/dev/kvm, kvm group)
    #   4. subuid/subgid delegation
    #   5. macos-kvm Incus profile registered in incus-user
    #
    # Usage: imt setup-rootless [--fix] [--yes] [--help]

    local fix=0
    local issues=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix)       fix=1; shift ;;
            -Y|--yes)    fix=1; shift ;;
            --help|-h)
                cat <<EOF
imt setup-rootless — configure the system for rootless macOS VM operation

Checks and configures:
  1. User is not root
  2. incus-user daemon (systemd user service)
  3. KVM device access (/dev/kvm, kvm group membership)
  4. UID/GID delegation (subuid/subgid)
  5. macos-kvm Incus profile registered in incus-user

Usage: imt setup-rootless [--fix] [--yes]

Options:
  --fix    Attempt to automatically fix detected issues
  --yes    Non-interactive (implies --fix)
EOF
                return 0 ;;
            *) die "Unknown option: $1. Run: imt setup-rootless --help" ;;
        esac
    done

    _sr_ok()   { printf '  \033[32m✔\033[0m  %s\n' "$*"; }
    _sr_warn() { printf '  \033[33m⚠\033[0m  %s\n' "$*"; }
    _sr_fail() { printf '  \033[31m✘\033[0m  %s\n' "$*"; issues=$((issues+1)); }
    _sr_section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

    _sr_ask_fix() {
        local msg="$1" cmd="$2"
        if [[ "$fix" -eq 1 ]]; then
            info "  Fixing: $msg"
            if eval "$cmd"; then
                _sr_ok "Fixed: $msg"
            else
                _sr_fail "Failed to fix: $msg"
            fi
        else
            _sr_warn "$msg"
            info "    Run: $cmd"
            issues=$((issues+1))
        fi
    }

    # 1. Not root
    _sr_section "1. User check"
    if [[ "$(id -ru)" -eq 0 ]]; then
        die "Run as a regular user, not root."
    fi
    _sr_ok "Running as ${USER} (uid=$(id -ru))"

    # 2. incus-user daemon
    _sr_section "2. incus-user daemon"
    local incus_user_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -ru)}/incus/incus.socket"

    if ! command -v incus &>/dev/null; then
        _sr_fail "incus not found — install Incus: https://linuxcontainers.org/incus/"
    else
        _sr_ok "incus found: $(incus --version 2>/dev/null || true)"
    fi

    if [[ -S "${incus_user_socket}" ]]; then
        _sr_ok "incus-user socket: ${incus_user_socket}"
    else
        if systemctl --user list-unit-files incus-user.service &>/dev/null 2>&1; then
            if systemctl --user is-active incus-user.service &>/dev/null 2>&1; then
                _sr_warn "incus-user.service active but socket not found — check: systemctl --user status incus-user.service"
                issues=$((issues+1))
            else
                _sr_ask_fix \
                    "Start and enable incus-user.service" \
                    "systemctl --user enable --now incus-user.service"
            fi
        else
            _sr_fail "incus-user.service not found — install incus-user package"
        fi
    fi

    # 3. KVM access
    _sr_section "3. KVM device access"
    if [[ -c /dev/kvm ]]; then
        local kvm_group
        kvm_group="$(stat -c '%G' /dev/kvm 2>/dev/null || echo kvm)"
        if id -nG "${USER}" | grep -qw "${kvm_group}"; then
            _sr_ok "/dev/kvm accessible (member of group ${kvm_group})"
        else
            _sr_ask_fix \
                "Add ${USER} to ${kvm_group} group for /dev/kvm access" \
                "sudo usermod -aG ${kvm_group} ${USER}"
            _sr_warn "Log out and back in (or run: newgrp ${kvm_group}) for group change to take effect"
        fi
    else
        _sr_fail "/dev/kvm not found — KVM not available on this host"
        info "    Check: lsmod | grep kvm && ls -la /dev/kvm"
    fi

    # 4. subuid/subgid
    _sr_section "4. UID/GID delegation (subuid/subgid)"
    for pair in "subuid:subuid" "subgid:subgid"; do
        local file="/etc/${pair%%:*}" label="${pair##*:}"
        if grep -q "^${USER}:" "${file}" 2>/dev/null; then
            local range
            range="$(grep "^${USER}:" "${file}" | head -1)"
            _sr_ok "${label}: ${range}"
        else
            _sr_ask_fix \
                "Add ${USER} to ${file}" \
                "sudo usermod --add-sub${label}s 65536-131071 ${USER}"
        fi
    done

    # 5. macos-kvm profile in incus-user
    _sr_section "5. macos-kvm Incus profile"
    local incus_cmd="incus"
    [[ -S "${incus_user_socket}" ]] && export INCUS_SOCKET="${incus_user_socket}"

    if ${incus_cmd} profile show macos-kvm &>/dev/null 2>&1; then
        _sr_ok "macos-kvm profile registered"
    else
        local profile_yaml=""
        local search_dir
        search_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        for f in \
            "${search_dir}/../incus/profile.yaml" \
            "${HOME}/.local/share/imt/profiles/macos-kvm.yaml" \
            "/usr/local/share/imt/profiles/macos-kvm.yaml"; do
            [[ -f "$f" ]] && profile_yaml="$f" && break
        done

        if [[ -n "${profile_yaml}" ]]; then
            _sr_ask_fix \
                "Register macos-kvm profile" \
                "${incus_cmd} profile create macos-kvm && ${incus_cmd} profile edit macos-kvm < ${profile_yaml}"
        else
            _sr_warn "macos-kvm profile not registered and YAML not found"
            info "    Run: imt profiles install"
            issues=$((issues+1))
        fi
    fi

    # Summary
    printf '\n'
    if [[ "${issues}" -eq 0 ]]; then
        printf '\033[32mAll checks passed. Rootless imt is ready.\033[0m\n\n'
        printf 'Quick start:\n'
        printf '  imt vm create --version sonoma --name macos-sonoma\n'
    else
        printf '\033[33m%d issue(s) found.\033[0m\n' "${issues}"
        if [[ "${fix}" -eq 0 ]]; then
            printf 'Re-run with --fix to attempt automatic fixes:\n'
            printf '  imt setup-rootless --fix\n'
        else
            printf 'Some issues could not be fixed automatically.\n'
        fi
    fi
}

# ── profiles ─────────────────────────────────────────────────────────────────

cmd_profiles() {
    local subcmd="${1:-help}"; shift || true

    # Profile directory: alongside this script, then standard locations
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _profile_dirs=(
        "${_script_dir}/../incus"
        "${HOME}/.local/share/imt/profiles"
        "/usr/local/share/imt/profiles"
        "/usr/share/imt/profiles"
    )

    _imt_find_profile_dir() {
        local d
        for d in "${_profile_dirs[@]}"; do
            [ -d "$d" ] && echo "$d" && return 0
        done
        die "No profile directory found"
    }

    _imt_find_profile_file() {
        local name="$1"
        local d
        for d in "${_profile_dirs[@]}"; do
            local f="${d}/${name}.yaml"
            [ -f "$f" ] && echo "$f" && return 0
        done
        return 1
    }

    _imt_install_one() {
        local name="$1" file="$2"
        if incus profile show "$name" &>/dev/null 2>&1; then
            incus profile edit "$name" < "$file"
            ok "  updated : $name"
        else
            incus profile create "$name"
            incus profile edit "$name" < "$file"
            ok "  created : $name"
        fi
    }

    case "$subcmd" in
        list)
            local pdir
            pdir=$(_imt_find_profile_dir)
            info "Available profiles (${pdir}):"
            for f in "${pdir}"/*.yaml; do
                [ -f "$f" ] || continue
                local pname desc
                pname=$(basename "$f" .yaml)
                desc=$(grep -m1 '^description:' "$f" 2>/dev/null \
                       | sed 's/^description:[[:space:]]*//' | tr -d '"' || true)
                if [ -n "$desc" ]; then
                    printf "  %-30s  %s\n" "$pname" "$desc"
                else
                    printf "  %s\n" "$pname"
                fi
            done
            ;;

        show)
            local name="${1:?Usage: imt profiles show <name>}"
            local file
            file=$(_imt_find_profile_file "$name") \
                || die "Profile not found: $name"
            cat "$file"
            ;;

        install)
            require_incus
            local all=0 names=()
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --all) all=1; shift ;;
                    -*) die "Unknown option: $1" ;;
                    *) names+=("$1"); shift ;;
                esac
            done
            local pdir
            pdir=$(_imt_find_profile_dir)
            if [[ "$all" -eq 1 ]] || [[ "${#names[@]}" -eq 0 ]]; then
                for f in "${pdir}"/*.yaml; do
                    [ -f "$f" ] || continue
                    _imt_install_one "$(basename "$f" .yaml)" "$f"
                done
            else
                for n in "${names[@]}"; do
                    local file
                    file=$(_imt_find_profile_file "$n") \
                        || die "Profile not found: $n"
                    _imt_install_one "$n" "$file"
                done
            fi
            ;;

        diff)
            require_incus
            local pdir
            pdir=$(_imt_find_profile_dir)
            for f in "${pdir}"/*.yaml; do
                [ -f "$f" ] || continue
                local pname
                pname=$(basename "$f" .yaml)
                if incus profile show "$pname" &>/dev/null 2>&1; then
                    local d
                    d=$(diff <(incus profile show "$pname") "$f" || true)
                    if [ -n "$d" ]; then
                        info "--- $pname (incus vs local) ---"
                        echo "$d"
                    else
                        ok "  $pname: in sync"
                    fi
                else
                    warn "  $pname: not installed (run: imt profiles install $pname)"
                fi
            done
            ;;

        apply)
            local ct="${1:?Usage: imt profiles apply <vm> <profile>}"
            local profile="${2:?Usage: imt profiles apply <vm> <profile>}"
            require_incus
            incus profile show "$profile" &>/dev/null 2>&1 \
                || die "Profile '$profile' not installed. Run: imt profiles install $profile"
            incus profile add "$ct" "$profile"
            ok "Applied profile '$profile' to VM '$ct'"
            ;;

        remove)
            local ct="${1:?Usage: imt profiles remove <vm> <profile>}"
            local profile="${2:?Usage: imt profiles remove <vm> <profile>}"
            require_incus
            incus profile remove "$ct" "$profile"
            ok "Removed profile '$profile' from VM '$ct'"
            ;;

        help|--help|-h)
            cat <<EOF
imt profiles — manage Incus profiles for macOS VMs

Usage: imt profiles <subcommand> [options]

Subcommands:
  list                    List available profile files
  show <name>             Print a profile's YAML
  install [--all] [name]  Install profile(s) into Incus
  diff                    Compare local files with Incus
  apply <vm> <profile>    Apply a profile to a VM
  remove <vm> <profile>   Remove a profile from a VM

Available profiles:
  macos-kvm    macOS KVM profile (QEMU overrides, network, firmware paths)

Examples:
  imt profiles install
  imt profiles show macos-kvm
  imt profiles diff
  imt profiles apply macos-sonoma macos-kvm
EOF
            ;;

        *) die "Unknown profiles subcommand: $subcmd. Run: imt profiles help" ;;
    esac
}

# ── Self-update ───────────────────────────────────────────────────────────────

_IMT_GITHUB_REPO="Interested-Deving-1896/Incus-MacOS-Toolkit"
_IMT_GITHUB_API="https://api.github.com/repos/${_IMT_GITHUB_REPO}/releases/latest"
_IMT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IMT_ROOT="$(cd "${_IMT_SCRIPT_DIR}/.." && pwd)"

_imt_version_gt() {
    local v1="${1#v}" v2="${2#v}"
    local IFS=.
    # shellcheck disable=SC2206
    local a1=($v1) a2=($v2)
    local i
    for i in 0 1 2; do
        local n1="${a1[$i]:-0}" n2="${a2[$i]:-0}"
        [[ "$n1" -gt "$n2" ]] && return 0
        [[ "$n1" -lt "$n2" ]] && return 1
    done
    return 1
}

_imt_fetch_release() {
    curl --disable --silent --fail \
        -H "Accept: application/vnd.github.v3+json" \
        "${_IMT_GITHUB_API}" 2>/dev/null \
    || { warn "Could not reach GitHub API"; return 1; }
}

# ── publish ───────────────────────────────────────────────────────────────────

cmd_publish() {
    local subcmd="${1:-help}"; shift || true
    case "$subcmd" in
        create)
            # Delegate to vm export which publishes the VM as an Incus image
            cmd_vm_export "$@"
            ;;
        list|ls)
            require_incus
            info "Published imt images:"
            incus image list --format table 2>/dev/null | grep -E "ALIAS|macos" || \
                info "No published images found. Use: imt publish create --name VM"
            ;;
        delete|rm)
            local alias_name="${1:-}"
            [[ -n "$alias_name" ]] || die "Usage: imt publish delete ALIAS"
            require_incus
            info "Deleting image '$alias_name' ..."
            incus image delete "$alias_name"
            ok "Deleted: $alias_name"
            ;;
        help|--help|-h)
            cat <<EOF
imt publish — create and manage Incus images from macOS VMs

Usage:
  imt publish create [--name VM] [--alias ALIAS]
  imt publish list
  imt publish delete ALIAS

Subcommands:
  create    Publish a VM as a reusable Incus image (wraps: imt vm export)
  list      List published macOS images
  delete    Delete a published image by alias

Examples:
  imt publish create --name macos-sonoma --alias macos/golden
  imt publish list
  imt publish delete macos/golden
EOF
            ;;
        *) die "Unknown publish subcommand: $subcmd. Run: imt publish help" ;;
    esac
}

cmd_update() {
    local subcmd="${1:-check}"; shift || true

    case "${subcmd}" in
        check)
            local current="${VERSION}"
            info "Current version : v${current}"
            info "Checking GitHub for updates..."

            local release_json latest_tag latest
            release_json=$(_imt_fetch_release) || {
                info "Check manually: https://github.com/${_IMT_GITHUB_REPO}/releases"
                return 1
            }
            latest_tag=$(echo "${release_json}" | grep '"tag_name"' | head -1 \
                         | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')
            latest="${latest_tag#v}"
            [[ -n "${latest}" ]] || { warn "Could not determine latest version"; return 1; }
            info "Latest version  : v${latest}"

            if _imt_version_gt "${latest}" "${current}"; then
                echo ""
                ok "Update available: v${current} → v${latest}"
                info "Update with: imt update install"
            else
                ok "imt is up to date (v${current})"
            fi
            ;;

        install|upgrade)
            local current="${VERSION}"
            info "Current version : v${current}"
            info "Fetching latest release..."

            local release_json latest_tag latest tarball_url
            release_json=$(_imt_fetch_release) || die "Could not reach GitHub API"
            latest_tag=$(echo "${release_json}" | grep '"tag_name"' | head -1 \
                         | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')
            latest="${latest_tag#v}"
            [[ -n "${latest}" ]] || die "Could not determine latest version"

            if ! _imt_version_gt "${latest}" "${current}"; then
                ok "Already up to date (v${current})"
                return 0
            fi

            info "Updating: v${current} → v${latest}"
            tarball_url=$(echo "${release_json}" | grep '"tarball_url"' | head -1 \
                          | sed 's/.*"tarball_url":[[:space:]]*"\([^"]*\)".*/\1/')
            [[ -n "${tarball_url}" ]] || die "No tarball URL in release"

            if [[ -d "${_IMT_ROOT}/.git" ]]; then
                info "Git repository detected — pulling latest..."
                ( cd "${_IMT_ROOT}" && git fetch origin \
                  && git checkout "v${latest}" 2>/dev/null \
                  || git pull origin main ) || die "Git pull failed"
                ok "Updated via git to v${latest}"
            else
                local tmp_dir; tmp_dir=$(mktemp -d)
                info "Downloading v${latest}..."
                curl --disable --silent --location --fail \
                    --output "${tmp_dir}/imt-${latest}.tar.gz" "${tarball_url}" \
                    || die "Download failed"
                info "Extracting..."
                tar xzf "${tmp_dir}/imt-${latest}.tar.gz" -C "${tmp_dir}" --strip-components=1
                info "Installing..."
                ( cd "${tmp_dir}" && bash macos-vm/install 2>/dev/null \
                  || cp -r . "${_IMT_ROOT}/" ) || die "Install failed"
                rm -rf "${tmp_dir}"
                ok "Updated to v${latest}"
            fi
            ;;

        help|--help|-h)
            cat <<EOF
imt update — check for and install imt updates

Usage: imt update [check|install]

Subcommands:
  check     Check for a newer version (default)
  install   Download and install the latest version
EOF
            ;;
        *) die "Unknown update subcommand: ${subcmd}" ;;
    esac
}

# ── demo ─────────────────────────────────────────────────────────────────────

cmd_demo() {
    # Manage a local incus-demo-server instance.
    # incus-demo-server: https://github.com/lxc/incus-demo-server
    local subcmd="${1:-help}"; shift || true

    local _demo_dir="${IMT_DEMO_DIR:-${HOME}/.local/share/imt/demo-server}"
    local _demo_bin="${_demo_dir}/incus-demo-server"
    local _demo_cfg="${_demo_dir}/config.yaml"
    local _demo_pid="${_demo_dir}/demo-server.pid"
    local _demo_log="${_demo_dir}/demo-server.log"
    local _demo_addr="${IMT_DEMO_ADDR:-[::]:8080}"
    local _demo_port; _demo_port="$(printf '%s' "${_demo_addr}" | sed 's/.*://')"
    local _demo_url="http://localhost:${_demo_port}"
    local _demo_image="${IMT_DEMO_IMAGE:-ubuntu/24.04}"
    local _demo_expiry="${IMT_DEMO_EXPIRY:-3600}"
    local _demo_total="${IMT_DEMO_TOTAL:-10}"
    local _demo_ip="${IMT_DEMO_IP_LIMIT:-2}"
    local _demo_cpu="${IMT_DEMO_CPU:-1}"
    local _demo_mem="${IMT_DEMO_MEMORY:-512MiB}"
    local _demo_disk="${IMT_DEMO_DISK:-5GiB}"
    local _demo_pre="${IMT_DEMO_PREALLOCATE:-2}"
    local _demo_mod="github.com/lxc/incus-demo-server/cmd/incus-demo-server@latest"

    _demo_running() { [ -f "${_demo_pid}" ] && kill -0 "$(cat "${_demo_pid}")" 2>/dev/null; }

    _demo_write_config() {
        mkdir -p "${_demo_dir}"
        cat > "${_demo_cfg}" <<EOF
server:
  api:
    address: "${_demo_addr}"
  limits:
    total: ${_demo_total}
    ip: ${_demo_ip}
  terms: |
    This is a local imt demo server.
    Instances expire after ${_demo_expiry} seconds.
incus:
  instance:
    allocate:
      count: ${_demo_pre}
    expiry: ${_demo_expiry}
    source:
      image: "${_demo_image}"
      type: "container"
    profiles:
      - default
    limits:
      cpu: ${_demo_cpu}
      disk: ${_demo_disk}
      memory: ${_demo_mem}
  session:
    command: ["bash"]
    expiry: ${_demo_expiry}
    console_only: true
EOF
    }

    case "${subcmd}" in
        install)
            command -v go >/dev/null 2>&1 || die "go is required. See https://go.dev/dl/"
            mkdir -p "${_demo_dir}"
            info "Installing incus-demo-server..."
            GOBIN="${_demo_dir}" go install "${_demo_mod}"
            ok "Installed: ${_demo_bin}"
            ;;
        config)
            mkdir -p "${_demo_dir}"
            [ -f "${_demo_cfg}" ] || { _demo_write_config; ok "Config written: ${_demo_cfg}"; }
            if [[ "${1:-}" == "--edit" || "${1:-}" == "-e" ]]; then
                "${EDITOR:-vi}" "${_demo_cfg}"
            else
                cat "${_demo_cfg}"
            fi
            ;;
        start)
            [ -f "${_demo_bin}" ] || die "Not installed. Run: imt demo install"
            [ -f "${_demo_cfg}" ] || { _demo_write_config; info "Generated config: ${_demo_cfg}"; }
            _demo_running && { info "Already running (PID $(cat "${_demo_pid}"))"; return 0; }
            mkdir -p "${_demo_dir}"
            ( cd "${_demo_dir}" && "${_demo_bin}" >> "${_demo_log}" 2>&1 & echo $! > "${_demo_pid}" )
            sleep 1
            if _demo_running; then
                ok "Demo server started (PID $(cat "${_demo_pid}")) — ${_demo_url}"
            else
                die "Failed to start. Check: imt demo logs"
            fi
            ;;
        stop)
            _demo_running || { info "Not running"; return 0; }
            kill "$(cat "${_demo_pid}")"; rm -f "${_demo_pid}"
            ok "Demo server stopped"
            ;;
        restart)
            cmd_demo stop; sleep 1; cmd_demo start
            ;;
        status)
            if _demo_running; then
                ok "Running (PID $(cat "${_demo_pid}")) — ${_demo_url}"
            else
                info "Stopped"
            fi
            ;;
        logs)
            [ -f "${_demo_log}" ] || die "No log file: ${_demo_log}"
            if [[ "${1:-}" == "--follow" || "${1:-}" == "-f" ]]; then
                tail -f "${_demo_log}"
            else
                cat "${_demo_log}"
            fi
            ;;
        url)  printf '%s\n' "${_demo_url}" ;;
        test)
            command -v curl >/dev/null 2>&1 || die "curl is required"
            curl --silent --fail --max-time 5 "${_demo_url}/1.0" >/dev/null \
                || die "Server not responding at ${_demo_url}/1.0 — run: imt demo start"
            ok "${_demo_url}/1.0 — OK"
            curl --silent --fail --max-time 5 "${_demo_url}/1.0/terms" >/dev/null \
                && ok "${_demo_url}/1.0/terms — OK"
            ;;
        help|--help|-h)
            cat <<EOF
imt demo — manage a local incus-demo-server instance
  https://github.com/lxc/incus-demo-server

Usage: imt demo <subcommand> [options]

Subcommands:
  install          Install the demo server binary (requires Go)
  config [--edit]  Show or edit the generated config.yaml
  start            Start the demo server in the background
  stop             Stop the running demo server
  restart          Stop then start
  status           Show whether the server is running
  logs [--follow]  Show server logs
  url              Print the API base URL
  test             Smoke-test the running server via curl

Environment overrides:
  IMT_DEMO_DIR, IMT_DEMO_ADDR, IMT_DEMO_EXPIRY, IMT_DEMO_TOTAL,
  IMT_DEMO_IP_LIMIT, IMT_DEMO_IMAGE, IMT_DEMO_CPU, IMT_DEMO_MEMORY,
  IMT_DEMO_DISK, IMT_DEMO_PREALLOCATE
EOF
            ;;
        *) die "Unknown demo subcommand: ${subcmd}. Run: imt demo help" ;;
    esac
}

# ── winesapos ─────────────────────────────────────────────────────────────────

cmd_winesapos() {
    # Fetch, import, and launch winesapOS gaming VMs.
    # winesapOS: https://github.com/winesapOS/winesapOS
    local subcmd="${1:-help}"; shift || true

    local _ws_version="${IMT_WINESAPOS_VERSION:-4.5.0}"
    local _ws_edition="${IMT_WINESAPOS_EDITION:-minimal}"
    local _ws_dir="${IMT_WINESAPOS_DIR:-${HOME}/.local/share/imt/winesapos}"
    local _ws_cpus="${IMT_WINESAPOS_CPUS:-4}"
    local _ws_mem="${IMT_WINESAPOS_MEMORY:-8192}"
    local _ws_disk="${IMT_WINESAPOS_DISK:-64GiB}"
    local _ws_base="https://github.com/winesapOS/winesapOS/releases/download"

    _ws_filename() { printf 'winesapos-%s-%s.img.zst' "$1" "$2"; }
    _ws_alias()    { printf 'winesapos/%s/%s' "$1" "$2"; }
    _ws_img_exists() {
        incus image list --format csv 2>/dev/null | grep -q "^$(_ws_alias "$1" "$2"),"
    }

    case "${subcmd}" in
        fetch)
            local version="${_ws_version}" edition="${_ws_edition}"
            while [[ "$#" -gt 0 ]]; do
                case "$1" in
                    --edition|-e) edition="$2"; shift 2 ;;
                    --version|-v) version="$2"; shift 2 ;;
                    *) version="$1"; shift ;;
                esac
            done
            command -v curl >/dev/null 2>&1 || die "curl is required"
            command -v zstd >/dev/null 2>&1 || die "zstd is required: apt install zstd"
            local fname url dest
            fname="$(_ws_filename "${version}" "${edition}")"
            url="${_ws_base}/${version}/${fname}"
            dest="${_ws_dir}/${fname}"
            mkdir -p "${_ws_dir}"
            if [ -f "${dest%.zst}" ]; then
                info "Already fetched: ${dest%.zst}"; return 0
            fi
            [ -f "${dest}" ] || { info "Downloading ${fname}..."; curl -L --progress-bar --fail -o "${dest}" "${url}"; }
            info "Decompressing..."
            zstd --decompress --rm "${dest}" -o "${dest%.zst}"
            ok "Image ready: ${dest%.zst}"
            ;;
        import)
            local version="${_ws_version}" edition="${_ws_edition}"
            while [[ "$#" -gt 0 ]]; do
                case "$1" in
                    --edition|-e) edition="$2"; shift 2 ;;
                    --version|-v) version="$2"; shift 2 ;;
                    *) version="$1"; shift ;;
                esac
            done
            command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required: apt install qemu-utils"
            local img alias qcow2
            img="${_ws_dir}/$(_ws_filename "${version}" "${edition}" | sed 's/\.zst$//')"
            alias="$(_ws_alias "${version}" "${edition}")"
            qcow2="${img%.img}.qcow2"
            [ -f "${img}" ] || die "Image not found: ${img}. Run: imt winesapos fetch ${version} --edition ${edition}"
            _ws_img_exists "${version}" "${edition}" && { info "Already imported: ${alias}"; return 0; }
            [ -f "${qcow2}" ] || { info "Converting to qcow2..."; qemu-img convert -f raw -O qcow2 -p "${img}" "${qcow2}"; }
            incus image import "${qcow2}" --alias "${alias}" --type virtual-machine
            ok "Imported: ${alias}"
            ;;
        launch)
            [[ "$#" -ge 1 ]] || die "Usage: imt winesapos launch NAME [options]"
            local name="$1"; shift
            local version="${_ws_version}" edition="${_ws_edition}"
            local cpus="${_ws_cpus}" memory="${_ws_mem}" disk="${_ws_disk}"
            while [[ "$#" -gt 0 ]]; do
                case "$1" in
                    --version|-v) version="$2"; shift 2 ;;
                    --edition|-e) edition="$2"; shift 2 ;;
                    --cpus|-c)    cpus="$2";    shift 2 ;;
                    --memory|-m)  memory="$2";  shift 2 ;;
                    --disk|-d)    disk="$2";    shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            local alias; alias="$(_ws_alias "${version}" "${edition}")"
            if ! _ws_img_exists "${version}" "${edition}"; then
                info "Image '${alias}' not found — fetching and importing..."
                cmd_winesapos fetch "${version}" --edition "${edition}"
                cmd_winesapos import "${version}" --edition "${edition}"
            fi
            info "Launching winesapOS VM: ${name} (${alias}, ${cpus} CPUs, ${memory} MiB, ${disk})"
            incus launch "${alias}" "${name}" --vm \
                --config limits.cpu="${cpus}" \
                --config limits.memory="${memory}MiB" \
                --device root,size="${disk}"
            ok "VM launched: ${name}"
            ;;
        list)
            incus list --format table | grep -i "winesapos" \
                || info "No winesapOS VMs found. Launch with: imt winesapos launch NAME"
            ;;
        versions)
            command -v curl >/dev/null 2>&1 || die "curl is required"
            info "winesapOS releases:"
            curl --silent --fail \
                "https://api.github.com/repos/winesapOS/winesapOS/releases?per_page=10" \
                | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)".*/  \1/'
            ;;
        help|--help|-h)
            cat <<EOF
imt winesapos — fetch, import, and launch winesapOS gaming VMs
  https://github.com/winesapOS/winesapOS

Usage: imt winesapos <subcommand> [options]

Subcommands:
  fetch   [VERSION] [--edition minimal|performance|secure]
  import  [VERSION] [--edition ...]
  launch  NAME [--version V] [--edition E] [--cpus N] [--memory MiB] [--disk SIZE]
  list    List winesapOS VMs
  versions  List available releases

Environment overrides:
  IMT_WINESAPOS_VERSION, IMT_WINESAPOS_EDITION, IMT_WINESAPOS_DIR,
  IMT_WINESAPOS_CPUS, IMT_WINESAPOS_MEMORY, IMT_WINESAPOS_DISK
EOF
            ;;
        *) die "Unknown winesapos subcommand: ${subcmd}. Run: imt winesapos help" ;;
    esac
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

# ── host-exec ─────────────────────────────────────────────────────────────────

cmd_host_exec() {
    [[ $# -gt 0 ]] || die "Usage: imt host-exec COMMAND [ARGS...]"
    local vm_name="${IMT_VM_NAME:-macos-${IMT_VERSION:-sonoma}}"

    # Allow --name to override the VM
    if [[ "${1:-}" == "--name" ]]; then
        vm_name="$2"; shift 2
    fi

    require_incus

    # Run the command on the host via nsenter from inside the VM.
    # Falls back to chroot /run/host for unprivileged VMs.
    local cmd_str
    cmd_str="$(printf '%q ' "$@")"
    incus exec "${vm_name}" -- sh -c \
        "if [ -r /proc/1/ns/mnt ]; then
             exec nsenter --mount=/proc/1/ns/mnt --uts=/proc/1/ns/uts \
                          --ipc=/proc/1/ns/ipc --net=/proc/1/ns/net \
                          --pid=/proc/1/ns/pid --target=1 -- ${cmd_str}
         else
             exec chroot /run/host ${cmd_str}
         fi"
}

# ── shell completion ──────────────────────────────────────────────────────────

cmd_completion() {
    local shell_type="${1:-bash}"
    case "$shell_type" in
        bash)
            cat <<'BASH_COMPLETION'
# imt bash completion
_imt_completion() {
    local cur prev words
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words="${COMP_WORDS[*]}"

    local top_cmds="image vm cloud-sync demo winesapos tui dashboard profiles publish setup-rootless update doctor config completion version help"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$top_cmds" -- "$cur") )
        return
    fi

    case "$prev" in
        vm)
            COMPREPLY=( $(compgen -W "create start stop status console shell snapshot export import fleet monitor net usb gpu template backup restore assemble delete list upgrade disk help" -- "$cur") )
            ;;
        publish)
            COMPREPLY=( $(compgen -W "create list delete help" -- "$cur") )
            ;;
        profiles)
            COMPREPLY=( $(compgen -W "list show install diff apply remove help" -- "$cur") )
            ;;
        config)
            COMPREPLY=( $(compgen -W "show init edit path" -- "$cur") )
            ;;
        update)
            COMPREPLY=( $(compgen -W "check install" -- "$cur") )
            ;;
        completion)
            COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
            ;;
    esac
}
complete -F _imt_completion imt
BASH_COMPLETION
            ;;
        zsh)
            cat <<'ZSH_COMPLETION'
#compdef imt
_imt() {
    local state
    _arguments '1: :->cmd' '*: :->args'
    case $state in
        cmd)
            _values 'command' \
                'image[Manage macOS VM images]' \
                'vm[Manage macOS VMs]' \
                'cloud-sync[Sync backups to cloud storage]' \
                'demo[Manage incus-demo-server]' \
                'winesapos[Manage winesapOS VMs]' \
                'tui[Launch terminal UI]' \
                'dashboard[Launch web dashboard]' \
                'profiles[Manage Incus profiles]' \
                'publish[Create and manage Incus images]' \
                'setup-rootless[Configure rootless operation]' \
                'update[Check for and install updates]' \
                'doctor[Check prerequisites]' \
                'config[Manage configuration]' \
                'completion[Generate shell completion]' \
                'version[Show version]' \
                'help[Show help]'
            ;;
        args)
            case ${words[2]} in
                vm) _values 'subcommand' create start stop status console shell snapshot export import fleet monitor net usb gpu template backup restore assemble delete list upgrade disk help ;;
                publish) _values 'subcommand' create list delete help ;;
                profiles) _values 'subcommand' list show install diff apply remove help ;;
                config) _values 'subcommand' show init edit path ;;
            esac
            ;;
    esac
}
_imt
ZSH_COMPLETION
            ;;
        fish)
            cat <<'FISH_COMPLETION'
# imt fish completion
set -l top_cmds image vm cloud-sync demo winesapos tui dashboard profiles publish setup-rootless update doctor config completion version help
complete -c imt -f -n '__fish_use_subcommand' -a "$top_cmds"
complete -c imt -f -n '__fish_seen_subcommand_from vm'      -a 'create start stop status console shell snapshot export import fleet monitor net usb gpu template backup restore assemble delete list upgrade disk help'
complete -c imt -f -n '__fish_seen_subcommand_from publish'  -a 'create list delete help'
complete -c imt -f -n '__fish_seen_subcommand_from profiles' -a 'list show install diff apply remove help'
complete -c imt -f -n '__fish_seen_subcommand_from config'   -a 'show init edit path'
FISH_COMPLETION
            ;;
        *)
            die "Unknown shell: $shell_type. Supported: bash, zsh, fish"
            ;;
    esac
}

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        image)          cmd_image      "$@" ;;
        vm)             cmd_vm         "$@" ;;
        cloud-sync)     cmd_cloud_sync "$@" ;;
        demo)           cmd_demo       "$@" ;;
        winesapos)      cmd_winesapos  "$@" ;;
        tui)            cmd_tui        "$@" ;;
        dashboard)      cmd_dashboard  "$@" ;;
        profiles)       cmd_profiles   "$@" ;;
        publish)        cmd_publish    "$@" ;;
        setup-rootless) cmd_setup_rootless "$@" ;;
        host-exec)      cmd_host_exec  "$@" ;;
        update)         cmd_update     "$@" ;;
        doctor)         cmd_doctor     "$@" ;;
        config)         cmd_config     "$@" ;;
        completion)     cmd_completion "$@" ;;
        version|--version) cmd_version ;;
        help|--help|-h) usage_global ;;
        *) err "Unknown command: $cmd"; usage_global ;;
    esac
}

main "$@"
