# libkrun backend (Apple Silicon)

[libkrun](https://github.com/containers/libkrun) is a lightweight hypervisor
library that uses Apple's `Hypervisor.framework` on Apple Silicon. It provides
lower overhead than QEMU (~256 MB RAM per VM vs ~512 MB) and is the approach
used by [anylinuxfs](https://github.com/nohajc/anylinuxfs).

## Status

The libkrun backend is a stub in the current release. The QEMU backend works
on both Intel and Apple Silicon Macs.

## Building with libkrun support

libkrun requires CGo and the libkrun dynamic library:

```bash
# Install libkrun (Apple Silicon only)
brew install libkrun   # if available, or build from source:
# git clone https://github.com/containers/libkrun
# cd libkrun && make && sudo make install

# Build linuxfs-mac with libkrun
CGO_ENABLED=1 go build -tags libkrun -o linuxfs-mac .

# Use the libkrun backend
linuxfs-mac mount /dev/disk2s1 --backend nfs --vm-backend libkrun
```

## Architecture

With libkrun, the VM lifecycle is:

1. `krun_create_ctx()` — allocate a VM context
2. `krun_set_vm_config()` — set vCPUs and RAM
3. `krun_set_root_disk()` — attach Alpine root image
4. `krun_add_disk()` — pass through the target block device
5. `krun_set_net_cfg()` — configure virtio-net
6. `krun_start_enter()` — start the VM (blocks until shutdown)

The NFS server runs inside the Alpine VM and is exposed on a `vmnet` interface
visible only to the host, matching the anylinuxfs architecture.
