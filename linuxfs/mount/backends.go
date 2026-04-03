// SPDX-License-Identifier: GPL-3.0-or-later
//
// mount/backends.go — file share backend registry and host-side mount helpers.
//
// Each backend exposes the filesystem mounted inside the VM as a network share
// that the host OS can connect to. The share server runs inside the VM;
// QEMU user-mode networking forwards the relevant ports to the host.

package mount

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
)

// Backend identifies a network file share protocol.
type Backend string

const (
	BackendAFP   Backend = "afp"   // Apple Filing Protocol — macOS default
	BackendNFS   Backend = "nfs"   // NFS — macOS alternative
	BackendSMB   Backend = "smb"   // SMB/CIFS — Windows default
	BackendFTP   Backend = "ftp"   // FTP — cross-platform fallback
	BackendSSHFS Backend = "sshfs" // SSHFS — no root, no share server, all OSes
)

// DefaultBackend returns the recommended backend for the current OS.
// SSHFS is preferred on Linux (no root required); AFP on macOS; SMB on Windows.
func DefaultBackend() Backend {
	switch runtime.GOOS {
	case "darwin":
		return BackendAFP
	case "windows":
		return BackendSMB
	default:
		// Linux: prefer sshfs if available, fall back to FTP.
		if SSHFSAvailable() {
			return BackendSSHFS
		}
		return BackendFTP
	}
}

// Config holds host-side share connection parameters.
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
	case BackendSSHFS:
		if !SSHFSAvailable() {
			return fmt.Errorf("sshfs not found; install it (see: linuxfs mount --help)")
		}
	case BackendNFS, BackendSMB, BackendFTP:
		// supported everywhere
	default:
		return fmt.Errorf("unknown backend %q; supported: afp, nfs, smb, ftp, sshfs", c.Backend)
	}
	return nil
}

// MountURL builds the URL the host uses to connect to the share.
// For NFS the export root is /mnt/linuxfs (fsid=0), so the client path is /.
// For SMB and AFP the share name is "linuxfs".
// For FTP the URL includes the non-standard port.
func (c Config) MountURL(shareName string) string {
	ip := c.ListenIP
	if ip == "" || ip == "0.0.0.0" {
		ip = "127.0.0.1"
	}
	switch c.Backend {
	case BackendAFP:
		return fmt.Sprintf("afp://%s/%s", ip, shareName)
	case BackendNFS:
		// fsid=0 exports /mnt/linuxfs as the NFS root; client mounts /.
		return fmt.Sprintf("nfs://%s/", ip)
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

// AutoMount mounts the share at mountPoint on the host.
// mountPoint may be empty for AFP/SMB on macOS (Finder handles placement).
func AutoMount(shareURL, mountPoint string) error {
	switch runtime.GOOS {
	case "darwin":
		return autoMountDarwin(shareURL, mountPoint)
	case "linux":
		return autoMountLinux(shareURL, mountPoint)
	case "windows":
		return autoMountWindows(shareURL, mountPoint)
	default:
		return fmt.Errorf("AutoMount not implemented on %s — connect to %s manually",
			runtime.GOOS, shareURL)
	}
}

func autoMountDarwin(shareURL, mountPoint string) error {
	if mountPoint == "" {
		// No explicit mountpoint — let Finder handle it via `open`.
		// The volume appears under /Volumes/<share-name>.
		cmd := exec.Command("open", shareURL)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("open %s: %w\n%s", shareURL, err, out)
		}
		return nil
	}

	// Explicit mountpoint: use the appropriate mount_* command.
	if err := os.MkdirAll(mountPoint, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", mountPoint, err)
	}

	var cmd *exec.Cmd
	switch backendFromURL(shareURL) {
	case BackendAFP:
		cmd = exec.Command("mount_afp", shareURL, mountPoint)
	case BackendNFS:
		// mount_nfs expects host:/path syntax, not a URL.
		// Force NFSv4 so the client connects directly to port 2049 without
		// consulting rpcbind (port 111 is not forwarded by QEMU hostfwd).
		host, path := splitNFSURL(shareURL)
		cmd = exec.Command("mount_nfs", "-o", "resvport,rw,vers=4", host+":"+path, mountPoint)
	case BackendSMB:
		cmd = exec.Command("mount_smbfs", shareURL, mountPoint)
	default:
		// FTP or unknown — fall back to open.
		cmd = exec.Command("open", shareURL)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("mount %s → %s: %w\n%s", shareURL, mountPoint, err, out)
	}
	return nil
}

func autoMountLinux(shareURL, mountPoint string) error {
	if mountPoint == "" {
		return fmt.Errorf("--mountpoint is required on Linux; share URL: %s", shareURL)
	}
	if err := os.MkdirAll(mountPoint, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", mountPoint, err)
	}

	var cmd *exec.Cmd
	switch backendFromURL(shareURL) {
	case BackendNFS:
		// Force NFSv4 so the client connects directly to port 2049 without
		// consulting rpcbind (port 111 is not forwarded by QEMU hostfwd).
		host, path := splitNFSURL(shareURL)
		cmd = exec.Command("mount", "-t", "nfs",
			"-o", "nfsvers=4,port=2049,nolock",
			host+":"+path, mountPoint)
	case BackendSMB:
		cmd = exec.Command("mount", "-t", "cifs", shareURL, mountPoint,
			"-o", "guest")
	default:
		return fmt.Errorf("backend not supported for auto-mount on Linux; connect to %s manually",
			shareURL)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("mount %s → %s: %w\n%s", shareURL, mountPoint, err, out)
	}
	return nil
}

func autoMountWindows(shareURL, mountPoint string) error {
	if mountPoint == "" {
		mountPoint = "Z:"
	}
	// net use Z: \\127.0.0.1\linuxfs
	unc := smbURLToUNC(shareURL)
	cmd := exec.Command("net", "use", mountPoint, unc)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("net use %s %s: %w\n%s", mountPoint, unc, err, out)
	}
	return nil
}

// AutoUnmount unmounts a previously mounted share.
func AutoUnmount(mountPoint string) error {
	if mountPoint == "" {
		return nil
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("diskutil", "unmount", mountPoint)
	case "windows":
		cmd = exec.Command("net", "use", mountPoint, "/delete")
	default:
		cmd = exec.Command("umount", mountPoint)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("unmount %s: %w\n%s", mountPoint, err, out)
	}
	return nil
}

// backendFromURL infers the Backend from a share URL scheme.
func backendFromURL(url string) Backend {
	switch {
	case len(url) >= 6 && url[:6] == "afp://":
		return BackendAFP
	case len(url) >= 6 && url[:6] == "nfs://":
		return BackendNFS
	case len(url) >= 6 && url[:6] == "smb://":
		return BackendSMB
	case len(url) >= 6 && url[:6] == "ftp://":
		return BackendFTP
	default:
		return ""
	}
}

// splitNFSURL converts nfs://host/path → (host, /path).
func splitNFSURL(url string) (host, path string) {
	// Strip "nfs://"
	rest := url[6:]
	slash := len(rest)
	for i, c := range rest {
		if c == '/' {
			slash = i
			break
		}
	}
	host = rest[:slash]
	path = rest[slash:]
	if path == "" {
		path = "/"
	}
	return host, path
}

// smbURLToUNC converts smb://host/share → \\host\share.
func smbURLToUNC(url string) string {
	rest := url[6:] // strip "smb://"
	// Replace forward slashes with backslashes and prepend \\
	unc := "\\\\"
	for _, c := range rest {
		if c == '/' {
			unc += "\\"
		} else {
			unc += string(c)
		}
	}
	return unc
}
