// SPDX-License-Identifier: GPL-3.0-or-later

package vm

import "fmt"

const fedoraVersion = "41"

// FedoraProvider uses Fedora Cloud Base images.
// Useful when SELinux or RPM-based tooling is required.
type FedoraProvider struct{}

func (FedoraProvider) Name() string { return "fedora" }

func (FedoraProvider) ImageURL(arch Arch) string {
	// Fedora cloud images: https://fedoraproject.org/cloud/download
	// The filename encodes the arch twice: once in the directory path and
	// once in the filename itself (e.g. Fedora-Cloud-Base-41-1.4.aarch64.qcow2).
	return fmt.Sprintf(
		"https://download.fedoraproject.org/pub/fedora/linux/releases/%s/Cloud/%s/images/Fedora-Cloud-Base-%s-1.4.%s.qcow2",
		fedoraVersion, arch.FedoraString(), fedoraVersion, arch.FedoraString(),
	)
}

func (FedoraProvider) ImageSHA256(_ Arch) string { return "" }
func (FedoraProvider) ImageFormat() string        { return "qcow2" }

func (FedoraProvider) CloudInitPackages() []string {
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

func (FedoraProvider) CloudInitRuncmds() []string {
	return []string{
		"systemctl enable sshd",
		"systemctl start sshd",
		// Sentinel written last so waitForCloudInit knows runcmd completed.
		"touch /run/cloud-init-custom-done",
	}
}

func (FedoraProvider) DefaultUser() string  { return "fedora" }
func (FedoraProvider) DefaultShell() string { return "/bin/bash" }
