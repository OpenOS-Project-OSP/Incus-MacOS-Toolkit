// SPDX-License-Identifier: GPL-3.0-or-later
//
// arch.go — host architecture detection and distro-specific arch string helpers.
//
// Each Linux distro uses different CPU architecture identifiers in their image
// URLs. This file centralises the mapping so providers stay concise.

package vm

import (
	"os"
	"runtime"
)

// Arch is a normalised CPU architecture identifier.
type Arch string

const (
	ArchAMD64   Arch = "amd64"   // x86_64
	ArchARM64   Arch = "arm64"   // aarch64 — Apple Silicon, AWS Graviton, RPi 4+
	ArchRISCV64 Arch = "riscv64" // RISC-V 64-bit
	ArchPPC64LE Arch = "ppc64le" // IBM POWER (little-endian)
	ArchS390X   Arch = "s390x"   // IBM Z
)

// HostArch returns the Arch for the current process.
func HostArch() Arch {
	switch runtime.GOARCH {
	case "amd64":
		return ArchAMD64
	case "arm64":
		return ArchARM64
	case "riscv64":
		return ArchRISCV64
	case "ppc64le":
		return ArchPPC64LE
	case "s390x":
		return ArchS390X
	default:
		// Fall back to amd64 for unknown architectures.
		return ArchAMD64
	}
}

// QEMUBinary returns the qemu-system-* binary name for this architecture.
func (a Arch) QEMUBinary() string {
	switch a {
	case ArchARM64:
		return "qemu-system-aarch64"
	case ArchRISCV64:
		return "qemu-system-riscv64"
	case ArchPPC64LE:
		return "qemu-system-ppc64"
	case ArchS390X:
		return "qemu-system-s390x"
	default:
		return "qemu-system-x86_64"
	}
}

// AlpineString returns the Alpine Linux architecture identifier.
func (a Arch) AlpineString() string {
	switch a {
	case ArchARM64:
		return "aarch64"
	case ArchRISCV64:
		return "riscv64"
	case ArchPPC64LE:
		return "ppc64le"
	case ArchS390X:
		return "s390x"
	default:
		return "x86_64"
	}
}

// DebianString returns the Debian cloud image architecture identifier.
func (a Arch) DebianString() string {
	switch a {
	case ArchARM64:
		return "arm64"
	case ArchPPC64LE:
		return "ppc64el"
	case ArchS390X:
		return "s390x"
	default:
		return "amd64"
	}
}

// UbuntuString returns the Ubuntu cloud image architecture identifier.
func (a Arch) UbuntuString() string {
	switch a {
	case ArchARM64:
		return "arm64"
	default:
		return "amd64"
	}
}

// FedoraString returns the Fedora cloud image architecture directory name.
func (a Arch) FedoraString() string {
	switch a {
	case ArchARM64:
		return "aarch64"
	default:
		return "x86_64"
	}
}

// accelFlag returns the correct QEMU -accel value for the current OS.
// Linux uses KVM when /dev/kvm is available, macOS uses HVF,
// Windows uses WHPX, everything else falls back to TCG (software emulation).
func accelFlag() string {
	switch runtime.GOOS {
	case "linux":
		if _, err := os.Stat("/dev/kvm"); err == nil {
			return "kvm"
		}
		return "tcg"
	case "darwin":
		return "hvf"
	case "windows":
		return "whpx"
	default:
		return "tcg"
	}
}
