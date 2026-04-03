// SPDX-License-Identifier: GPL-3.0-or-later

package vm

import "fmt"

const debianVersion = "12"

// DebianProvider uses the official Debian genericcloud images.
// Larger than Alpine (~300 MiB) but ships a full apt ecosystem.
type DebianProvider struct{}

func (DebianProvider) Name() string { return "debian" }

func (DebianProvider) ImageURL(arch Arch) string {
	// Official Debian cloud images: https://cloud.debian.org/images/cloud/
	return fmt.Sprintf(
		"https://cloud.debian.org/images/cloud/bookworm/latest/debian-%s-genericcloud-%s.qcow2",
		debianVersion, arch.DebianString(),
	)
}

func (DebianProvider) ImageSHA256(_ Arch) string { return "" }
func (DebianProvider) ImageFormat() string        { return "qcow2" }

func (DebianProvider) CloudInitPackages() []string {
	return []string{
		"btrfs-progs",
		"e2fsprogs",
		"xfsprogs",
		"dosfstools",
		"ntfs-3g",
		"lvm2",
		"cryptsetup",
		"zfsutils-linux",
		"fuse3",
		"rsync",
	}
}

func (DebianProvider) CloudInitRuncmds() []string {
	return []string{
		"systemctl enable ssh",
		"systemctl start ssh",
		// Sentinel written last so waitForCloudInit knows runcmd completed.
		"touch /run/cloud-init-custom-done",
	}
}

func (DebianProvider) DefaultUser() string  { return "debian" }
func (DebianProvider) DefaultShell() string { return "/bin/bash" }
