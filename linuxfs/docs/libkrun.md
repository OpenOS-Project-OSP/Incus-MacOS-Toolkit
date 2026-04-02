# libkrun

[libkrun](https://github.com/containers/libkrun) is a lightweight hypervisor
library that uses Apple's `Hypervisor.framework` on Apple Silicon. It provides
lower overhead than QEMU (~256 MB RAM per VM vs ~512 MB) and is the approach
used by [anylinuxfs](https://github.com/nohajc/anylinuxfs).

## Status

**Not implemented.** The QEMU backend is the only supported hypervisor.
It works on Intel and Apple Silicon Macs (using HVF acceleration), Linux
(KVM), and Windows (WHPX).

libkrun would require CGo and a dynamic library dependency, which conflicts
with the project's goal of a single static binary with no external runtime
dependencies. If you need lower VM overhead on Apple Silicon, reducing
`--vm-mem` (default: 512 MiB) is the practical lever — most filesystem
operations work fine at 256 MiB.

## Adding libkrun support

If you want to contribute a libkrun backend, the integration point is the
`vm.Provider` interface in `vm/provider.go`. A libkrun backend would
implement a separate `vm.VM`-equivalent that calls the libkrun C API via
CGo instead of shelling out to `qemu-system-*`.

The NFS/AFP/SMB share server logic in `mount/setup.go` is hypervisor-agnostic
and would work unchanged with a libkrun backend.
