// SPDX-License-Identifier: GPL-3.0-or-later

package vm

import "fmt"

const ubuntuRelease = "24.04"
const ubuntuCodename = "noble"

// UbuntuProvider uses Ubuntu minimal cloud images.
// Good choice when Ubuntu-specific tooling (snap, etc.) is needed.
type UbuntuProvider struct{}

func (UbuntuProvider) Name() string { return "ubuntu" }

func (UbuntuProvider) ImageURL(arch Arch) string {
	// Ubuntu cloud images: https://cloud-images.ubuntu.com/
	return fmt.Sprintf(
		"https://cloud-images.ubuntu.com/minimal/releases/%s/release/ubuntu-%s-minimal-cloudimg-%s.img",
		ubuntuCodename, ubuntuRelease, arch.UbuntuString(),
	)
}

func (UbuntuProvider) ImageSHA256(_ Arch) string { return "" }
func (UbuntuProvider) ImageFormat() string        { return "qcow2" }

func (UbuntuProvider) CloudInitPackages() []string {
	return []string{
		"btrfs-progs",
		"e2fsprogs",
		"xfsprogs",
		"dosfstools",
		"ntfs-3g",
		"lvm2",
		"cryptsetup",
		"fuse3",
		"rsync",
	}
}

func (UbuntuProvider) CloudInitRuncmds() []string {
	return []string{
		"systemctl enable ssh",
		"systemctl start ssh",
	}
}

func (UbuntuProvider) DefaultUser() string  { return "ubuntu" }
func (UbuntuProvider) DefaultShell() string { return "/bin/bash" }
