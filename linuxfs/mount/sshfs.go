// SPDX-License-Identifier: GPL-3.0-or-later
//
// sshfs.go — SSHFS backend for linuxfs.
//
// SSHFS mounts the VM's /mnt/linuxfs directly over the existing SSH tunnel.
// No share server is needed inside the VM, no extra ports are forwarded,
// and no root privileges are required on the host.
//
// Requirements:
//   macOS:   brew install macfuse sshfs   (or use macFUSE + sshfs from macfuse.io)
//   Linux:   apt install sshfs  /  dnf install fuse-sshfs
//   Windows: WinFsp + SSHFS-Win (https://github.com/winfsp/sshfs-win)

package mount

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
)

const (
	BackendSSHFS Backend = "sshfs"
	vmSSHFSPath         = "/mnt/linuxfs"
)

// SSHFSOptions holds the parameters needed to mount via SSHFS.
type SSHFSOptions struct {
	// SSHPort is the host-side forwarded SSH port (vm.SSHPort).
	SSHPort uint16
	// User is the VM login user (provider.DefaultUser()).
	User string
	// KeyPath is the path to the SSH private key. Empty = default keys.
	KeyPath string
	// MountPoint is the local directory to mount at.
	MountPoint string
	// ReadOnly mounts the filesystem read-only.
	ReadOnly bool
}

// MountSSHFS mounts the VM filesystem at opts.MountPoint using sshfs.
func MountSSHFS(opts SSHFSOptions) error {
	if opts.MountPoint == "" {
		return fmt.Errorf("--mountpoint is required for the sshfs backend")
	}

	sshfsBin, err := findSSHFS()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(opts.MountPoint, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", opts.MountPoint, err)
	}

	// sshfs [user@]host:[path] mountpoint [options]
	remote := fmt.Sprintf("%s@127.0.0.1:%s", opts.User, vmSSHFSPath)

	args := []string{
		remote,
		opts.MountPoint,
		"-p", fmt.Sprintf("%d", opts.SSHPort),
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "reconnect",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
	}
	if opts.KeyPath != "" {
		args = append(args, "-o", "IdentityFile="+opts.KeyPath)
	}
	if opts.ReadOnly {
		args = append(args, "-o", "ro")
	}
	// macOS macFUSE needs allow_other to be visible outside the mounting process.
	if runtime.GOOS == "darwin" {
		args = append(args, "-o", "volname=linuxfs")
	}

	cmd := exec.Command(sshfsBin, args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("sshfs: %w\n%s", err, out)
	}
	return nil
}

// UnmountSSHFS unmounts an sshfs mount point.
func UnmountSSHFS(mountPoint string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		// macFUSE uses diskutil or umount.
		cmd = exec.Command("diskutil", "unmount", mountPoint)
	case "windows":
		cmd = exec.Command("net", "use", mountPoint, "/delete")
	default:
		// Linux: fusermount -u or umount
		if path, err := exec.LookPath("fusermount"); err == nil {
			cmd = exec.Command(path, "-u", mountPoint)
		} else {
			cmd = exec.Command("umount", mountPoint)
		}
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("unmount sshfs %s: %w\n%s", mountPoint, err, out)
	}
	return nil
}

// SSHFSAvailable returns true if sshfs is installed on the host.
func SSHFSAvailable() bool {
	_, err := findSSHFS()
	return err == nil
}

func findSSHFS() (string, error) {
	candidates := []string{"sshfs"}
	if runtime.GOOS == "windows" {
		// SSHFS-Win installs as sshfs.exe or via the net use wrapper.
		candidates = append(candidates, `C:\Program Files\SSHFS-Win\bin\sshfs.exe`)
	}
	for _, name := range candidates {
		if path, err := exec.LookPath(name); err == nil {
			return path, nil
		}
	}
	return "", fmt.Errorf(
		"sshfs not found; install it:\n" +
			"  macOS:   brew install macfuse && brew install gromgit/fuse/sshfs-mac\n" +
			"  Linux:   apt install sshfs  (or: dnf install fuse-sshfs)\n" +
			"  Windows: https://github.com/winfsp/sshfs-win",
	)
}
