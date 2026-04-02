# Credits

## Upstream projects

This toolkit builds on and integrates the following upstream projects:

| Project | Author / Maintainer | License | Role |
|---|---|---|---|
| [kdave/btrfs-devel](https://github.com/kdave/btrfs-devel) | David Sterba and BTRFS contributors | GPL-2.0-only | BTRFS kernel development tree (`btrfs-devel/`) |
| [mhx/dwarfs](https://github.com/mhx/dwarfs) | Marcus Holland-Moritz | GPL-2.0-or-later | DwarFS compressed filesystem (runtime dependency of `btrfs-dwarfs/`) |
| [OSX-KVM](https://github.com/kholia/OSX-KVM) | Dhiru Kholia | GPL-2.0-only | macOS KVM setup reference (`macos-vm/`) |
| [OpenCore](https://github.com/acidanthera/OpenCorePkg) | Acidanthera | BSD-3-Clause | macOS bootloader (`macos-vm/`) |
| [AlexSSD7/linsk](https://github.com/AlexSSD7/linsk) | Alexander Smirnov | Apache-2.0 | Linux filesystem access architecture reference (`linuxfs/`) |
| [nohajc/anylinuxfs](https://github.com/nohajc/anylinuxfs) | nohajc | MIT | NFS backend reference (`linuxfs/`) |
| [DiegoMagdaleno/BSDCoreUtils](https://github.com/DiegoMagdaleno/BSDCoreUtils) | Diego Magdaleno | BSD-2-Clause | BSD coreutils submodule (`compat/bsdcoreutils/`) |

## Component authors

- **macos-vm/** — derived from OSX-KVM; Incus integration and CI by this project.
- **linuxfs/** — architecture inspired by linsk and anylinuxfs; distro-agnostic
  provider system, arch detection, and `bdfs` proxy by this project.
- **compat/** — linuxify script by the linuxify project contributors; mlsblk
  and unified installer by this project.
- **btrfs-dwarfs/** — kernel module, daemon, CLI, and test suite by this project.
- **btrfs-devel/** — upstream Linux kernel `fs/btrfs/` by David Sterba and
  the BTRFS kernel team.
