# bsdcoreutils

BSD-licensed coreutils ported from FreeBSD, OpenBSD, and NetBSD to Linux and macOS.

Derived from [DiegoMagdaleno/BSDCoreUtils](https://github.com/DiegoMagdaleno/BSDCoreUtils).

## Purpose

This component provides a BSD-licensed alternative to GNU coreutils. Useful when:

- You need BSD-compatible tools on Linux (e.g. for portability testing)
- You want BSD-licensed binaries without GPL dependencies
- You are building a minimal macOS-compatible toolchain

## Build

Requires CMake and a C compiler.

```bash
cd bsdcoreutils
mkdir build && cd build
cmake ..
make
sudo make install   # installs with 'b' prefix, e.g. bcat, bls, bcp
```

## Tools included

Sourced from FreeBSD, OpenBSD, and NetBSD userland:

`basename`, `cat`, `chmod`, `chroot`, `comm`, `cp`, `csplit`, `cut`, `date`,
`dd`, `df`, `dirname`, `du`, `echo`, `env`, `expand`, `expr`, `head`, `id`,
`join`, `kill`, `ln`, `ls`, `md5`, `mkdir`, `mktemp`, `mv`, `nice`, `nl`,
`od`, `paste`, `pathchk`, `pr`, `printf`, `pwd`, `rm`, `rmdir`, `seq`,
`sha1`, `sha256`, `sleep`, `sort`, `split`, `stat`, `stty`, `tail`, `tee`,
`test`, `touch`, `tr`, `tsort`, `uname`, `unexpand`, `uniq`, `wc`, `who`

## Source

The upstream CMakeLists.txt and source tree from DiegoMagdaleno/BSDCoreUtils
are included as a git submodule. To initialise:

```bash
git submodule update --init bsdcoreutils/upstream
```
