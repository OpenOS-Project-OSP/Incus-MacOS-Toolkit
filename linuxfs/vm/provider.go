// SPDX-License-Identifier: GPL-3.0-or-later
//
// Provider is the interface every supported Linux distro must implement.
// It supplies the distro-specific image URL, checksum, and cloud-init
// package/setup commands so the rest of the VM layer stays distro-agnostic.

package vm

import "fmt"

// Provider describes a Linux cloud image that can be used as the microVM.
// Implement this interface to add support for a new distro.
type Provider interface {
	// Name returns a short identifier, e.g. "alpine", "debian", "ubuntu".
	Name() string

	// ImageURL returns the download URL for the cloud qcow2/img for arch.
	ImageURL(arch Arch) string

	// ImageSHA256 returns the expected SHA-256 hex digest, or "" to skip
	// verification (not recommended for production use).
	ImageSHA256(arch Arch) string

	// ImageFormat returns "qcow2" or "raw".
	ImageFormat() string

	// CloudInitPackages returns the list of packages to install on first boot.
	// These are passed to cloud-init's `packages:` key.
	CloudInitPackages() []string

	// CloudInitRuncmds returns extra shell commands for cloud-init `runcmd:`.
	// Each element is a single shell command string.
	CloudInitRuncmds() []string

	// DefaultUser returns the default SSH user created by cloud-init.
	DefaultUser() string

	// DefaultShell returns the login shell path for the default user.
	DefaultShell() string
}

// ProviderByName returns the Provider for the given name, or an error.
// Supported names: "alpine" (default), "debian", "ubuntu", "fedora".
func ProviderByName(name string) (Provider, error) {
	switch name {
	case "", "alpine":
		return AlpineProvider{}, nil
	case "debian":
		return DebianProvider{}, nil
	case "ubuntu":
		return UbuntuProvider{}, nil
	case "fedora":
		return FedoraProvider{}, nil
	default:
		return nil, fmt.Errorf(
			"unknown distro %q; supported: alpine (default), debian, ubuntu, fedora", name,
		)
	}
}
