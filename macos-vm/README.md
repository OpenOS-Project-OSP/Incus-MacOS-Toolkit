# macos-vm

Run macOS (High Sierra through Sequoia) as a KVM virtual machine on Linux,
managed entirely through [Incus](https://linuxcontainers.org/incus/).

Consolidates [OSX-KVM](https://github.com/kholia/OSX-KVM),
[macOS-Simple-KVM](https://github.com/foxlet/macOS-Simple-KVM),
[ultimate-macOS-KVM](https://github.com/Coopydood/ultimate-macOS-KVM), and
[osx-optimizer](https://github.com/sickcodes/osx-optimizer).

Incus is the only supported VM runtime. There is no bare-QEMU or libvirt path.

---

## Requirements

| Dependency | Purpose |
|---|---|
| `incus` ≥ 6.0 | VM lifecycle, storage, networking |
| `qemu-img` | QCOW2 disk creation (image pipeline only) |
| `python3` | macOS recovery image fetch |
| `wget` | Firmware and OpenCore download |
| `dmg2img` | DMG → raw image conversion |
| KVM (`/dev/kvm`) | Hardware virtualisation |

```
# Debian/Ubuntu
sudo apt install qemu-utils python3 wget dmg2img

# Arch
sudo pacman -S qemu-img python wget dmg2img

# Fedora
sudo dnf install qemu-img python3 wget dmg2img
```

Install Incus: https://linuxcontainers.org/incus/docs/main/installing/

---

## Installation

```
git clone https://github.com/Interested-Deving-1896/Incus-MacOS-Toolkit
cd Incus-MacOS-Toolkit/macos-vm
sudo make install        # installs imt to /usr/local/bin
```

Or run directly without installing:

```
bash cli/imt.sh help
```

---

## Quick start

```
# 1. Check prerequisites
imt doctor

# 2. Download firmware and OpenCore
imt image firmware
imt image opencore

# 3. Fetch macOS recovery image (default: sonoma)
imt image fetch --version sonoma

# 4. Create the QCOW2 disk and stage firmware
imt image build --version sonoma

# 5. Create and launch the VM in Incus
imt vm create --version sonoma

# 6. Attach to the console to complete macOS installation
imt vm console macos-sonoma

# 7. After installation, stop and restart normally
imt vm stop  macos-sonoma
imt vm start macos-sonoma

# 8. Open a shell once macOS is running
imt vm shell macos-sonoma
```

---

## Supported macOS versions

| Version | `--version` flag |
|---|---|
| macOS Sequoia (15) | `sequoia` |
| macOS Sonoma (14) | `sonoma` |
| macOS Ventura (13) | `ventura` |
| macOS Monterey (12) | `monterey` |
| macOS Big Sur (11) | `bigsur` |
| macOS Catalina (10.15) | `catalina` |
| macOS Mojave (10.14) | `mojave` |
| macOS High Sierra (10.13) | `high-sierra` |

---

## VM lifecycle

All VM operations go through Incus. There is no direct QEMU invocation.

```
imt vm create   --version sonoma [--name NAME] [--ram 4GiB] [--cpus 4] [--disk 128GiB]
imt vm start    --name macos-sonoma
imt vm stop     --name macos-sonoma
imt vm status   --name macos-sonoma
imt vm console  --name macos-sonoma   # serial/VGA console
imt vm shell    --name macos-sonoma   # incus exec shell
imt vm snapshot --name macos-sonoma [SNAP_NAME]
imt vm delete   --name macos-sonoma
imt vm list
```

`imt vm create` performs the following steps entirely through Incus:

1. Stages OVMF firmware to `/var/lib/macos-kvm/firmware/`
2. Creates or updates the `macos-kvm` Incus profile (QEMU overrides, network)
3. Imports the QCOW2 disk, OpenCore qcow2, and installer image as named Incus
   custom storage volumes
4. Creates an empty Incus VM instance with the `macos-kvm` profile
5. Attaches the three storage volumes as disk devices with appropriate boot
   priorities (OpenCore highest, installer second, macOS disk third)
6. Sets `kvm ignore_msrs=1` (required for macOS guests)
7. Starts the VM

---

## Multiple VMs

Each VM gets its own named storage volumes (`<name>-disk`, `<name>-opencore`,
`<name>-installer`), so multiple macOS versions can coexist:

```
imt vm create --version sonoma  --name mac-sonoma
imt vm create --version ventura --name mac-ventura
```

---

## Guest optimizations

Run inside the macOS guest after installation to improve VM performance:

```
# Push and run all safe optimizations
make optimize-guest NAME=macos-sonoma

# Or directly:
bash incus/optimize-guest.sh macos-sonoma --all

# Individual options
bash incus/optimize-guest.sh macos-sonoma --spotlight-off
bash incus/optimize-guest.sh macos-sonoma --perf-mode
bash incus/optimize-guest.sh macos-sonoma --no-updates
bash incus/optimize-guest.sh macos-sonoma --reduce-motion
```

---

## Configuration

```
imt config init   # create ~/.config/imt/config with defaults
imt config show   # print current config
imt config edit   # open in $EDITOR
```

Key config variables:

| Variable | Default | Purpose |
|---|---|---|
| `IMT_VERSION` | `sonoma` | Default macOS version |
| `IMT_RAM` | `4GiB` | Default VM RAM |
| `IMT_CPUS` | `4` | Default vCPU count |
| `IMT_DISK` | `128GiB` | Default disk size |
| `IMT_STORAGE_POOL` | `default` | Incus storage pool |

---

## Project structure

```
macos-vm/
├── cli/
│   ├── imt.sh              Main CLI entrypoint (imt)
│   └── lib.sh              Shared library (colors, logging, retry, config)
├── image-pipeline/
│   ├── fetch-macos.py      Fetch recovery images from Apple CDN
│   ├── convert-image.sh    DMG → raw image conversion
│   ├── build-image.sh      QCOW2 disk creation + firmware staging
│   └── OpenCore/           OpenCore bootloader (downloaded by imt image opencore)
├── incus/
│   ├── profile.yaml        Incus profile (QEMU overrides + network)
│   ├── setup.sh            Compatibility shim → delegates to imt vm
│   └── optimize-guest.sh   Push and run guest-tools inside the VM
├── guest-tools/
│   └── optimize.sh         macOS guest optimizations (run inside the VM)
├── firmware/               OVMF firmware blobs (downloaded by imt image firmware)
└── Makefile                Convenience wrappers over imt CLI
```

---

## Notes

- `ignore_msrs=1` is required for macOS guests. `imt vm start` and
  `imt vm create` set this automatically.
- The OSK string is publicly known and included for compatibility; it does not
  circumvent Apple DRM.
- Running macOS in a VM outside Apple hardware may violate Apple's SLA. This
  project is intended for development and testing.

---

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
