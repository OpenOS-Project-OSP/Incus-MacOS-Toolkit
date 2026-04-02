# Incus-MacOS-Toolkit

A unified toolkit for running macOS on Linux, accessing Linux filesystems from
macOS, and managing BTRFS+DwarFS hybrid storage — all orchestrated via
[Incus](https://linuxcontainers.org/incus/).

## Components

| Directory | Description |
|---|---|
| [`macos-vm/`](macos-vm/) | macOS KVM virtualization via QEMU + Incus |
| [`linuxfs/`](linuxfs/) | Linux filesystem access on macOS and Windows |
| [`compat/`](compat/) | macOS–Linux compatibility tools |
| [`btrfs-dwarfs/`](btrfs-dwarfs/) | BTRFS+DwarFS hybrid filesystem framework |
| [`btrfs-devel/`](btrfs-devel/) | kdave/btrfs-devel `fs/btrfs/` source reference |

---

## macos-vm

Run macOS (High Sierra through Sequoia) as a KVM virtual machine on Linux,
managed by Incus.

**Requirements:** Linux host with KVM, QEMU, Incus, OVMF firmware.

```sh
# Download macOS recovery image
make -C macos-vm fetch

# Create the VM disk
make -C macos-vm disk

# Boot the installer
make -C macos-vm boot

# After installation, manage via Incus
make -C macos-vm incus-launch
make -C macos-vm incus-start
make -C macos-vm incus-stop
```

See [`macos-vm/README.md`](macos-vm/README.md) for full setup instructions.

---

## linuxfs

Access Linux-native filesystems (ext4, btrfs, xfs, zfs, lvm, luks) from
macOS or Windows without rebooting. A Linux microVM mounts the filesystem
natively and exposes it as a network share (AFP, NFS, SMB, or FTP).

**Requirements:** QEMU, SSH, cloud-image-utils or genisoimage.

```sh
# Build
make linuxfs

# Mount a Linux partition
linuxfs mount /dev/disk2s1

# Mount with LUKS decryption
linuxfs --vm-mem 2048 mount /dev/disk2s1 --luks /dev/sda1

# Use a specific distro (alpine is the default)
linuxfs --distro debian mount /dev/disk2s1

# Open a shell inside the VM
linuxfs shell /dev/disk2s1

# Run btrfs-dwarfs commands inside the VM
linuxfs bdfs status
linuxfs bdfs partition add --type btrfs-backed --device /dev/vdb --label data
```

### Supported distros

| Flag | Image | Size |
|---|---|---|
| `--distro alpine` (default) | Alpine Linux 3.21 | ~50 MiB |
| `--distro debian` | Debian 12 (Bookworm) | ~300 MiB |
| `--distro ubuntu` | Ubuntu 24.04 (Noble) | ~250 MiB |
| `--distro fedora` | Fedora 41 Cloud | ~400 MiB |

### Supported architectures

The QEMU binary and VM image are selected automatically based on the host:

| Host | QEMU binary | Acceleration |
|---|---|---|
| Linux x86_64 | `qemu-system-x86_64` | KVM |
| macOS x86_64 | `qemu-system-x86_64` | HVF |
| macOS arm64 | `qemu-system-aarch64` | HVF |
| Windows x86_64 | `qemu-system-x86_64` | WHPX |
| Any (fallback) | arch-appropriate | TCG |

See [`linuxfs/README.md`](linuxfs/README.md) for full documentation.

---

## compat

macOS–Linux compatibility tools for developers who work across both systems.

- **linuxify** — installs GNU coreutils, findutils, sed, grep, and other
  GNU tools via Homebrew, making macOS behave more like Linux in the terminal.
- **mlsblk** — macOS port of Linux `lsblk` using CoreFoundation and
  `diskutil`, showing block devices in a familiar tree format.
- **bsdcoreutils** — BSD coreutils as a git submodule for reference and
  cross-platform builds.

```sh
# Install everything (macOS only)
bash compat/install.sh --all

# Or individually
bash compat/install.sh --linuxify
bash compat/install.sh --mlsblk
bash compat/install.sh --bsdcoreutils
```

See [`compat/README.md`](compat/README.md) for details.

---

## btrfs-dwarfs

A hybrid filesystem framework that blends BTRFS (mutable, CoW) with DwarFS
(read-only, 10–16× compressed) into a single coherent namespace.

**Requirements:** Linux ≥ 5.15, btrfs-progs, DwarFS tools, CMake ≥ 3.16.

```sh
# Build kernel module + userspace
make btrfs-dwarfs

# Build against the bundled btrfs-devel source tree
make btrfs-dwarfs-devel

# Install (requires root for kernel module)
sudo make btrfs-dwarfs-install

# Run unit tests
make btrfs-dwarfs-check

# Run integration tests (requires root + loopback devices)
sudo make btrfs-dwarfs-test
```

The `linuxfs bdfs` subcommand proxies all `bdfs` CLI commands into the
microVM over SSH, so you can manage BTRFS+DwarFS partitions from macOS:

```sh
linuxfs bdfs status
linuxfs bdfs blend mount \
  --btrfs-uuid <uuid> \
  --dwarfs-uuid <uuid> \
  --mountpoint /mnt/blend
```

See [`btrfs-dwarfs/README.md`](btrfs-dwarfs/README.md) for the full API.

---

## btrfs-devel

The `btrfs-devel/` directory contains the `fs/btrfs/` subtree from
[kdave/btrfs-devel](https://github.com/kdave/btrfs-devel) — the upstream
Linux kernel BTRFS development tree.

It is a **build and source reference**, not a runtime dependency. Use it to
build `btrfs-dwarfs/` against bleeding-edge BTRFS APIs, or to look up
internal kernel data structures.

```sh
# Sync to latest upstream
make btrfs-devel-sync
```

See [`btrfs-devel/README.md`](btrfs-devel/README.md) for details.

---

## Building everything

```sh
# Build all components that work on the current host
make all

# Install to /usr/local (may require root for kernel module)
sudo make install PREFIX=/usr/local

# Run all tests
make test
```

---

## License

- `macos-vm/`, `linuxfs/`, `compat/` — GPL-3.0-or-later
- `btrfs-dwarfs/` — GPL-2.0-or-later
- `btrfs-devel/` — GPL-2.0-only (Linux kernel)

See individual component directories for full license text.
