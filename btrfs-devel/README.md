# btrfs-devel

This directory contains the `fs/btrfs/` subtree from
[kdave/btrfs-devel](https://github.com/kdave/btrfs-devel) — the upstream
Linux kernel development tree for BTRFS.

## Purpose

It serves two roles in this repository:

1. **Build reference** — the `btrfs-dwarfs/` kernel module can be compiled
   against this tree instead of the system kernel headers, which is useful
   for testing against bleeding-edge BTRFS APIs before they land in a
   distribution kernel:

   ```sh
   # Build btrfs_dwarfs.ko against the in-tree btrfs-devel source
   make -C btrfs-dwarfs kernel-devel
   ```

2. **Source reference** — the internal BTRFS data structures and APIs used
   by `btrfs-dwarfs/` (partition backends, blend layer) are documented here.
   When upstream changes an API, this tree shows the new signature.

## Runtime dependency

This directory is **not** a runtime dependency. At runtime, the BTRFS kernel
module is the one built into (or loaded by) the Linux distribution running
inside the microVM. Any modern distribution kernel (≥ 5.15) includes BTRFS.

The userspace tools (`btrfs-progs`) are installed inside the VM by the
cloud-init setup in `linuxfs/`.

## Keeping in sync

To pull the latest `fs/btrfs/` from upstream:

```sh
# From the repository root
git fetch btrfs-devel master
BTRFS_TREE=$(git ls-tree btrfs-devel/master fs/btrfs | awk '{print $3}')
git read-tree --prefix=btrfs-devel/ -u "${BTRFS_TREE}"
git commit -m "btrfs-devel: sync with kdave/btrfs-devel $(date +%Y-%m-%d)"
```

## License

The files in this directory are part of the Linux kernel and are licensed
under GPL-2.0-only. See individual file headers.
