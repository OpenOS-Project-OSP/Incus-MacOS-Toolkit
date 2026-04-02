# linuxfs

Access Linux-native filesystems on macOS and Windows without reimplementing any
filesystem driver. Unified from
[linsk](https://github.com/AlexSSD7/linsk) (Go/QEMU) and
[anylinuxfs](https://github.com/nohajc/anylinuxfs) (Rust/libkrun).

**Supported filesystems:** ext2/3/4, btrfs, XFS, ZFS, NTFS, exFAT, and anything
else the Linux kernel supports — including LUKS encryption, LVM, BitLocker, and
Linux RAID (mdadm).

## How it works

1. A Linux microVM is started with the target block device passed through.
2. The VM mounts the device using native Linux drivers.
3. The mounted filesystem is exposed to the host via a network share:
   - **macOS**: AFP or NFS (auto-mounted under `/Volumes`)
   - **Windows**: SMB
   - **Fallback**: FTP

No kernel extensions, no lowered system security, no SIP changes required.

## Requirements

- **macOS** (Intel or Apple Silicon), **Windows**, or **Linux**
- QEMU (`qemu-system-x86_64` or `qemu-system-aarch64` depending on host arch)
- `ssh` and `scp` on PATH
- `cloud-image-utils` (`cloud-localds`) or `genisoimage` for first-run seed ISO

```bash
# macOS
brew install qemu cloud-utils

# Debian/Ubuntu
sudo apt-get install qemu-system cloud-image-utils

# Windows — install QEMU from https://www.qemu.org/download/#windows
```

## Installation

```bash
# Build from source (inside Incus-MacOS-Toolkit)
make linuxfs
sudo make linuxfs-install   # installs to /usr/local/bin

# Or cross-compile for all platforms
make linuxfs-cross
```

Pre-built binaries for macOS (amd64/arm64), Linux (amd64/arm64), and
Windows (amd64) are available on the [Releases](../../releases) page.

## Usage

```bash
# Mount an ext4 partition (auto-detects share backend)
linuxfs mount /dev/disk2s1

# Mount read-only
linuxfs mount /dev/disk2s1 --read-only

# Mount a LUKS-encrypted partition
linuxfs mount /dev/disk2s1 --luks /dev/sda1

# Mount an LVM logical volume
linuxfs mount /dev/disk2s1 --lvm vg0/home

# Mount a btrfs subvolume
linuxfs mount /dev/disk2s1 --fstype btrfs --mount-opts subvol=@home

# Mount a disk image
linuxfs mount /path/to/disk.img

# Use a specific share backend
linuxfs mount /dev/disk2s1 --backend nfs

# Use a specific Linux distro for the VM (alpine is the default)
linuxfs --distro debian mount /dev/disk2s1

# List active mounts
linuxfs list

# Unmount
linuxfs unmount /Volumes/linuxfs

# Open a shell inside the VM for manual inspection
linuxfs shell /dev/disk2s1

# Run btrfs-dwarfs commands inside the VM
linuxfs bdfs status
linuxfs bdfs partition add --type btrfs-backed --device /dev/vdb --label data
```

## VM distros

The `--distro` flag selects the Linux distribution used for the microVM.
All distros use cloud-init for first-boot setup and support the same
filesystem tools.

| Flag | Distribution | Image size |
|---|---|---|
| `--distro alpine` (default) | Alpine Linux 3.21 | ~50 MiB |
| `--distro debian` | Debian 12 (Bookworm) | ~300 MiB |
| `--distro ubuntu` | Ubuntu 24.04 (Noble) | ~250 MiB |
| `--distro fedora` | Fedora 41 Cloud | ~400 MiB |

Images are downloaded once and cached in the OS cache directory
(`~/Library/Caches/linuxfs/` on macOS, `~/.cache/linuxfs/` on Linux).

## Host architectures

The QEMU binary and VM image are selected automatically based on the host:

| Host | QEMU binary | Acceleration |
|---|---|---|
| Linux x86\_64 | `qemu-system-x86_64` | KVM (if `/dev/kvm` available) |
| macOS x86\_64 | `qemu-system-x86_64` | HVF |
| macOS arm64 | `qemu-system-aarch64` | HVF |
| Windows x86\_64 | `qemu-system-x86_64` | WHPX |
| Any (fallback) | arch-appropriate | TCG (software) |

## Share backends

| Backend | Default on | Notes |
|---|---|---|
| `afp` | macOS | Auto-mounts under `/Volumes` via `open afp://` |
| `nfs` | — | macOS alternative; lower overhead than AFP |
| `smb` | Windows | Auto-mounts via `net use` |
| `ftp` | Linux/other | Cross-platform fallback |

## Directory layout

```
linuxfs/
├── main.go
├── cmd/
│   ├── root.go       # Global flags (--distro, --vm-mem, --backend, ...)
│   ├── mount.go      # mount — starts VM, mounts fs, starts share server
│   ├── unmount.go    # unmount — stops share and VM
│   ├── list.go       # list — reads mounts.json state file
│   ├── shell.go      # shell — interactive SSH session into the VM
│   ├── bdfs.go       # bdfs — proxy for btrfs-dwarfs CLI inside the VM
│   └── version.go
├── vm/
│   ├── vm.go         # VM lifecycle: Start/Stop, QEMU args, waitForSSH
│   ├── arch.go       # HostArch(), QEMUBinary(), accelFlag()
│   ├── provider.go   # Provider interface + ProviderByName()
│   ├── provider_alpine.go
│   ├── provider_debian.go
│   ├── provider_ubuntu.go
│   ├── provider_fedora.go
│   ├── image.go      # Image download, caching, SHA-256 verification
│   ├── cloudinit.go  # cloud-init seed ISO generation (SSH key injection)
│   └── ssh.go        # Run, RunScript, WaitForPort, CopyFile helpers
├── mount/
│   ├── backends.go   # Backend type, Config, AutoMount, AutoUnmount
│   └── setup.go      # In-VM mount + share server lifecycle (Setup/Teardown)
├── go.mod
└── docs/
    └── libkrun.md    # Notes on the libkrun hypervisor alternative
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
