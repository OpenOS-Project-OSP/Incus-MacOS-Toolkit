// SPDX-License-Identifier: GPL-3.0-or-later
//
// mount/backends.go — file share backend registry and host-side mount helpers.
//
// Each backend exposes the filesystem mounted inside the Alpine VM to the host.
// Derived from AlexSSD7/linsk (share/) and nohajc/anylinuxfs (NFS backend).

package mount

import (
	"fmt"
	"os/exec"
	"runtime"
)

// Backend identifies a network file share protocol.
type Backend string

const (
	BackendAFP Backend = "afp" // Apple Filing Protocol — macOS default
	BackendNFS Backend = "nfs" // NFS — macOS alternative (anylinuxfs default)
	BackendSMB Backend = "smb" // SMB/CIFS — Windows default
	BackendFTP Backend = "ftp" // FTP — cross-platform fallback
)

// DefaultBackend returns the recommended backend for the current OS.
func DefaultBackend() Backend {
	switch runtime.GOOS {
	case "darwin":
		return BackendAFP
	case "windows":
		return BackendSMB
	default:
		return BackendFTP
	}
}

// Config holds share server configuration.
type Config struct {
	Backend      Backend
	ListenIP     string
	ListenPort   uint16
	NetworkShare bool
}

// Validate checks that the backend is supported on the current OS.
func (c Config) Validate() error {
	switch c.Backend {
	case BackendAFP:
		if runtime.GOOS != "darwin" {
			return fmt.Errorf("AFP backend is only supported on macOS")
		}
	case BackendNFS:
		if runtime.GOOS != "darwin" {
			return fmt.Errorf("NFS backend is currently only supported on macOS")
		}
	case BackendSMB, BackendFTP:
		// cross-platform
	default:
		return fmt.Errorf("unknown backend: %q", c.Backend)
	}
	return nil
}

// MountURL builds the URL the host uses to connect to the share.
func (c Config) MountURL(shareName string) string {
	ip := c.ListenIP
	if ip == "" {
		ip = "127.0.0.1"
	}
	switch c.Backend {
	case BackendAFP:
		return fmt.Sprintf("afp://%s/%s", ip, shareName)
	case BackendNFS:
		return fmt.Sprintf("nfs://%s/%s", ip, shareName)
	case BackendSMB:
		return fmt.Sprintf("smb://%s/%s", ip, shareName)
	case BackendFTP:
		port := c.ListenPort
		if port == 0 {
			port = 2121
		}
		return fmt.Sprintf("ftp://%s:%d", ip, port)
	default:
		return ""
	}
}

// AutoMount mounts the share URL at mountPoint on the host.
// On macOS it uses the `mount` command; on Linux it uses `mount.cifs` or `mount.nfs`.
func AutoMount(shareURL, mountPoint string) error {
	switch runtime.GOOS {
	case "darwin":
		// macOS: `open` triggers Finder auto-mount for AFP/SMB/NFS URLs.
		// For scripted use, `mount_afp`, `mount_smbfs`, `mount_nfs` are available.
		cmd := exec.Command("open", shareURL)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("open %s: %w\n%s", shareURL, err, out)
		}
		return nil
	case "linux":
		cmd := exec.Command("mount", shareURL, mountPoint)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("mount %s: %w\n%s", shareURL, err, out)
		}
		return nil
	default:
		return fmt.Errorf("AutoMount not implemented on %s — connect to %s manually", runtime.GOOS, shareURL)
	}
}

// AutoUnmount unmounts a previously mounted share.
func AutoUnmount(mountPoint string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("diskutil", "unmount", mountPoint)
	default:
		cmd = exec.Command("umount", mountPoint)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("unmount %s: %w\n%s", mountPoint, err, out)
	}
	return nil
}
