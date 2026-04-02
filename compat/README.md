# mac-linux-compat

Unified macOS/Linux CLI compatibility toolkit. Consolidates
[linuxify](https://github.com/pkill37/linuxify),
[mlsblk](https://github.com/projectamurat/mlsblk), and
[BSDCoreUtils](https://github.com/DiegoMagdaleno/BSDCoreUtils).

## Components

| Component | What it does | Platform |
|---|---|---|
| **linuxify** | Installs GNU coreutils/findutils/sed/tar/etc. on macOS via Homebrew, replacing BSD tools | macOS |
| **mlsblk** | macOS port of Linux `lsblk` — lists block devices as a tree using `diskutil` + CoreFoundation | macOS |
| **bsdcoreutils** | BSD-licensed coreutils from FreeBSD/OpenBSD/NetBSD, portable to Linux and macOS | macOS + Linux |

## Quick install

```bash
# Install everything
bash install.sh --all

# Or pick components
bash install.sh --linuxify       # GNU tools on macOS
bash install.sh --mlsblk         # lsblk for macOS
bash install.sh --bsdcoreutils   # BSD coreutils
```

---

## linuxify

Replaces macOS's BSD userland with GNU equivalents via Homebrew. After install,
your shell gets `sed`, `grep`, `find`, `tar`, `make`, etc. behaving like Linux.

```bash
# Install
bash linuxify/linuxify install

# Activate in current shell (add to ~/.zshrc or ~/.bashrc permanently)
source linuxify/env.sh

# Uninstall
bash linuxify/linuxify uninstall
```

**What gets installed:**

- GNU coreutils, binutils, diffutils, findutils
- gnu-sed, gnu-tar, gnu-which, gnu-indent
- grep, gawk, gzip, screen, watch, wget, wdiff
- bash (latest), git, openssh, vim, perl, python, rsync

---

## mlsblk

macOS port of Linux `lsblk`. Lists block devices and partitions as a tree,
using `diskutil list -plist` and CoreFoundation.

```bash
# Build
make mlsblk

# Install to /usr/local/bin
make install-mlsblk

# Usage
mlsblk                              # tree: NAME SIZE TYPE MOUNTPOINT
mlsblk -f                           # add FSTYPE, LABEL, UUID
mlsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
mlsblk -J                           # JSON output
mlsblk -l                           # list format (no tree)
```

Example output:

```
NAME     SIZE   TYPE MOUNTPOINT
disk0    500.1G disk
├── disk0s1  524.3M part /System/Volumes/Preboot
├── disk0s2  494.4G part /
└── disk0s3  5.4G   part
disk1    128.0G disk
└── disk1s1  128.0G part /Volumes/External
```

---

## bsdcoreutils

BSD-licensed coreutils ported from FreeBSD, OpenBSD, and NetBSD. Useful for
portability testing or when GPL dependencies are undesirable.

```bash
# Initialise submodule and build
make bsdcoreutils

# Install (tools get a 'b' prefix: bcat, bls, bcp, ...)
sudo make -C bsdcoreutils/build install
```

See [bsdcoreutils/README.md](bsdcoreutils/README.md) for the full tool list.

---

## Directory layout

```
mac-linux-compat/
├── linuxify/
│   ├── linuxify      # install/uninstall script
│   └── env.sh        # PATH/MANPATH/INFOPATH setup (source in shell config)
├── mlsblk/
│   ├── mlsblk.c      # single-file C implementation
│   └── Makefile
├── bsdcoreutils/
│   ├── README.md
│   └── upstream/     # git submodule → DiegoMagdaleno/BSDCoreUtils
├── install.sh        # unified installer
└── Makefile
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
