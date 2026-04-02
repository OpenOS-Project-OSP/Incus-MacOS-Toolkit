# linuxfs-mac

Access Linux-native filesystems on macOS and Windows without reimplementing any
filesystem driver. Unified from
[linsk](https://github.com/AlexSSD7/linsk) (Go/QEMU) and
[anylinuxfs](https://github.com/nohajc/anylinuxfs) (Rust/libkrun).

**Supported filesystems:** ext2/3/4, btrfs, XFS, ZFS, NTFS, exFAT, and anything
else the Linux kernel supports — including LUKS encryption, LVM, BitLocker, and
Linux RAID (mdadm).

## How it works

1. A lightweight Alpine Linux VM (~130 MB) is started with the target block
   device passed through.
2. The VM mounts the device using native Linux drivers.
3. The mounted filesystem is exposed to the host via a network share:
   - **macOS**: AFP or NFS (auto-mounted under `/Volumes`)
   - **Windows**: SMB
   - **Fallback**: FTP

No kernel extensions, no lowered system security, no SIP changes required.

## Requirements

- **macOS** (Intel or Apple Silicon) or **Windows**
- `qemu-system-x86_64` or `qemu-system-aarch64`

```bash
# macOS
brew install qemu

# Windows — install QEMU from https://www.qemu.org/download/#windows
```

## Installation

```bash
# Build from source
git clone https://github.com/linuxfs-mac/linuxfs-mac
cd linuxfs-mac
make build
make install        # installs to /usr/local/bin
```

Pre-built binaries for macOS (amd64/arm64) and Windows (amd64) are available
on the [Releases](../../releases) page.

## Usage

```bash
# Mount an ext4 partition (auto-detects share backend)
linuxfs-mac mount /dev/disk2s1

# Mount read-only
linuxfs-mac mount /dev/disk2s1 --read-only

# Mount a LUKS-encrypted partition (prompts for passphrase)
linuxfs-mac mount /dev/disk2s1 --luks /dev/sda1

# Mount an LVM logical volume
linuxfs-mac mount /dev/disk2s1 --lvm vg0/home

# Mount a btrfs subvolume
linuxfs-mac mount /dev/disk2s1 --fstype btrfs --mount-opts subvol=@home

# Mount a disk image
linuxfs-mac mount /path/to/disk.img

# Mount with NFS backend instead of AFP
linuxfs-mac mount /dev/disk2s1 --backend nfs

# List active mounts
linuxfs-mac list

# Unmount
linuxfs-mac unmount /dev/disk2s1

# Open a shell inside the Alpine VM for manual inspection
linuxfs-mac shell /dev/disk2s1
```

## Backends

| Backend | Default on | Notes |
|---|---|---|
| `afp` | macOS | Auto-mounts under `/Volumes` |
| `nfs` | — | macOS alternative; used by anylinuxfs |
| `smb` | Windows | |
| `ftp` | Linux/other | Cross-platform fallback |

## Apple Silicon (libkrun)

On Apple Silicon Macs, linuxfs-mac can optionally use
[libkrun](https://github.com/containers/libkrun) instead of QEMU for a
lighter-weight VM (~256 MB RAM vs ~512 MB). This is the approach used by
`anylinuxfs`. See [docs/libkrun.md](docs/libkrun.md) for build instructions.

## Directory layout

```
linuxfs-mac/
├── main.go
├── cmd/              # CLI commands (stdlib flag)
│   ├── root.go       # Global flag parsing and subcommand dispatch
│   ├── mount.go      # mount / unmount — starts VM, wires share
│   ├── list.go       # list — reads mounts.json state file
│   ├── shell.go      # shell — SSH into running Alpine VM
│   └── version.go
├── vm/               # Alpine VM lifecycle (QEMU + libkrun stub)
│   ├── vm.go         # Start/Stop, platform-aware accel (KVM/HVF/WHPX)
│   ├── image.go      # Alpine qcow2 download with progress + SHA-256
│   └── cloudinit.go  # cloud-init seed ISO (SSH key injection)
├── mount/            # Share backend registry + host-side mount helpers
│   └── backends.go   # AFP/NFS/SMB/FTP config, AutoMount, AutoUnmount
└── docs/
    └── libkrun.md
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
