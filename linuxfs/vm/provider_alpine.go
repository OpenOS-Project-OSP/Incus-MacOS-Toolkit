// SPDX-License-Identifier: GPL-3.0-or-later

package vm

import "fmt"

const alpineVersion = "3.21.6"

// AlpineProvider is the default microVM distro.
// Alpine images are ~50 MiB, boot in under 5 seconds, and support cloud-init
// via the alpine-cloud-init package included in the virt image.
type AlpineProvider struct{}

func (AlpineProvider) Name() string { return "alpine" }

func (AlpineProvider) ImageURL(arch Arch) string {
	// URL format changed in Alpine 3.21: generic_alpine-VERSION-ARCH-FIRMWARE-cloudinit-r0.qcow2
	// x86_64 uses BIOS; aarch64 uses UEFI.
	return fmt.Sprintf(
		"https://dl-cdn.alpinelinux.org/alpine/v%s/releases/cloud/generic_alpine-%s-%s-%s-cloudinit-r0.qcow2",
		alpineVersion[:4], alpineVersion, arch.AlpineString(), arch.AlpineFirmware(),
	)
}

// ImageSHA256 returns "" — Alpine does not publish per-file SHA-256 digests
// on the CDN path we use; integrity is verified by HTTPS.
func (AlpineProvider) ImageSHA256(_ Arch) string { return "" }

func (AlpineProvider) ImageFormat() string { return "qcow2" }

func (AlpineProvider) CloudInitPackages() []string {
	return []string{
		// Filesystem tools
		"btrfs-progs",
		"e2fsprogs",
		"xfsprogs",
		"dosfstools",
		"ntfs-3g",
		"lvm2",
		"cryptsetup",
		// FUSE3 — required by DwarFS (btrfs-dwarfs framework)
		"fuse3",
		// General utilities
		"openssh",
		"rsync",
	}
}

func (AlpineProvider) CloudInitRuncmds() []string {
	return []string{
		"rc-update add sshd default",
		"rc-service sshd start",
	}
}

func (AlpineProvider) DefaultUser() string  { return "alpine" }
func (AlpineProvider) DefaultShell() string { return "/bin/ash" }
