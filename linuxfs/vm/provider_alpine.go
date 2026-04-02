// SPDX-License-Identifier: GPL-3.0-or-later

package vm

import "fmt"

const alpineVersion = "3.21.3"

// AlpineProvider is the default microVM distro.
// Alpine images are ~50 MiB, boot in under 5 seconds, and support cloud-init
// via the alpine-cloud-init package included in the virt image.
type AlpineProvider struct{}

func (AlpineProvider) Name() string { return "alpine" }

func (AlpineProvider) ImageURL(arch Arch) string {
	return fmt.Sprintf(
		"https://dl-cdn.alpinelinux.org/alpine/v%s/releases/cloud/alpine-virt-%s.%s.qcow2",
		alpineVersion[:4], alpineVersion, arch.AlpineString(),
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
