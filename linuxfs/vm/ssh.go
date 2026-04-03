// SPDX-License-Identifier: GPL-3.0-or-later
//
// ssh.go — SSH helpers for running commands inside the microVM.
//
// All communication with the VM after boot goes through the forwarded SSH
// port on 127.0.0.1. We shell out to the system `ssh` binary rather than
// linking a Go SSH library so the binary stays dependency-free.

package vm

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// SSHOptions holds connection parameters for a VM SSH session.
type SSHOptions struct {
	// Port is the host-side forwarded port (v.SSHPort after Start).
	Port uint16
	// User is the login user inside the VM (provider.DefaultUser()).
	User string
	// KeyPath is the path to the private key. Empty = use ssh-agent / default keys.
	KeyPath string
}

// sshArgs builds the base ssh argument list (no command yet).
func (o SSHOptions) sshArgs() []string {
	args := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		"-o", "BatchMode=yes",
		"-o", "LogLevel=ERROR",
		"-T", // no pseudo-terminal; suppresses MOTD/banner output
		"-p", fmt.Sprintf("%d", o.Port),
	}
	if o.KeyPath != "" {
		args = append(args, "-i", o.KeyPath)
	}
	args = append(args, fmt.Sprintf("%s@127.0.0.1", o.User))
	return args
}

// Run executes a shell command inside the VM and returns combined output.
// The command runs as the VM user; prefix with "sudo" for root operations.
func (v *VM) Run(command string) (string, error) {
	opts := v.sshOpts()
	args := append(opts.sshArgs(), command)
	cmd := exec.Command("ssh", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("ssh %q: %w\n%s", command, err, out)
	}
	return string(out), nil
}

// RunScript uploads a shell script to the VM via stdin and executes it.
// Useful for multi-line setup sequences that would be unwieldy as a single
// command string.
func (v *VM) RunScript(script string) (string, error) {
	opts := v.sshOpts()
	// Pipe the script through `sh -s` so we don't need to copy a file first.
	args := append(opts.sshArgs(), "sudo", "sh", "-s")
	cmd := exec.Command("ssh", args...)
	cmd.Stdin = strings.NewReader(script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("ssh script: %w\n%s", err, out)
	}
	return string(out), nil
}

// WaitForPort polls host:port inside the VM (via SSH) until it accepts
// connections or the timeout expires. Used to wait for share servers.
// Uses ss (iproute2) which is present on all supported distros; falls back
// to nc if ss is unavailable (e.g. Alpine without iproute2).
func (v *VM) WaitForPort(port uint16, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	// ss -tlnp checks for a TCP listener on the given port without needing
	// to make a connection. nc -z is the fallback for Alpine/minimal images.
	check := fmt.Sprintf(
		"ss -tlnp 2>/dev/null | grep -q ':%d ' || nc -z 127.0.0.1 %d 2>/dev/null",
		port, port,
	)
	for time.Now().Before(deadline) {
		if _, err := v.Run(check); err == nil {
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("timed out waiting for port %d inside VM after %s", port, timeout)
}

// sshOpts builds SSHOptions from the running VM's state.
func (v *VM) sshOpts() SSHOptions {
	opts := SSHOptions{
		Port: v.SSHPort,
		User: v.provider.DefaultUser(),
	}
	// Use the generated key if it exists in the data dir.
	cacheD := v.cfg.DataDir
	if cacheD == "" {
		if d, err := cacheDir(); err == nil {
			cacheD = d
		}
	}
	if cacheD != "" {
		keyPath := filepath.Join(cacheD, "vm_id_ed25519")
		if _, err := os.Stat(keyPath); err == nil {
			opts.KeyPath = keyPath
		}
	}
	return opts
}

// CopyFile copies a local file into the VM at remotePath using scp.
func (v *VM) CopyFile(localPath, remotePath string) error {
	opts := v.sshOpts()
	scpArgs := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		"-P", fmt.Sprintf("%d", opts.Port),
	}
	if opts.KeyPath != "" {
		scpArgs = append(scpArgs, "-i", opts.KeyPath)
	}
	dest := fmt.Sprintf("%s@127.0.0.1:%s", opts.User, remotePath)
	scpArgs = append(scpArgs, localPath, dest)
	cmd := exec.Command("scp", scpArgs...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("scp %s → %s: %w\n%s", localPath, remotePath, err, out)
	}
	return nil
}


