// SPDX-License-Identifier: GPL-3.0-or-later
//
// vm package manages the lifecycle of the Linux microVM used to mount
// Linux filesystems. It wraps QEMU as the hypervisor backend and supports
// any cloud-init-compatible Linux distro via the Provider interface.

package vm

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Config holds parameters for a single VM instance.
type Config struct {
	// Provider selects the Linux distro. Defaults to AlpineProvider if nil.
	Provider Provider

	// MemMiB is the RAM allocated to the VM in MiB.
	MemMiB uint32

	// DevicePath is the host block device or image file to pass through.
	DevicePath string

	// ReadOnly mounts the device read-only inside the VM.
	ReadOnly bool

	// Debug enables verbose QEMU output.
	Debug bool

	// SSHPort is the host port forwarded to the VM's SSH daemon.
	// 0 = use 10022.
	SSHPort uint16

	// ExtraHostFwds is a list of additional QEMU hostfwd rules in the form
	// "tcp::HOST_PORT-:GUEST_PORT", appended to the -netdev user option.
	// Used to forward share server ports (NFS, SMB, AFP, FTP) to the host.
	ExtraHostFwds []string

	// DataDir overrides the default cache directory for VM images.
	DataDir string
}

// VM represents a running Linux microVM instance.
type VM struct {
	cfg         Config
	provider    Provider
	arch        Arch
	logger      *slog.Logger
	cmd         *exec.Cmd
	ctx         context.Context
	cancel      context.CancelFunc
	qemuStderr  bytes.Buffer // captures QEMU stderr when Debug is false
	overlayPath string       // ephemeral qcow2 overlay; deleted on Stop

	// SSHPort is the resolved host port (set after Start).
	SSHPort uint16
}

// New creates a VM instance. Call Start to launch it.
func New(ctx context.Context, cfg Config, logger *slog.Logger) (*VM, error) {
	if cfg.MemMiB == 0 {
		cfg.MemMiB = 512
	}
	p := cfg.Provider
	if p == nil {
		p = AlpineProvider{}
	}
	ctx, cancel := context.WithCancel(ctx)
	return &VM{
		cfg:      cfg,
		provider: p,
		arch:     HostArch(),
		logger:   logger,
		ctx:      ctx,
		cancel:   cancel,
	}, nil
}

// Start launches the VM and waits for SSH to become available.
func (v *VM) Start() error {
	return v.startQEMU()
}

// Stop shuts down the VM.
func (v *VM) Stop() error {
	v.cancel()
	var err error
	if v.cmd != nil && v.cmd.Process != nil {
		err = v.cmd.Process.Kill()
	}
	if v.overlayPath != "" {
		_ = os.Remove(v.overlayPath)
	}
	return err
}

// User returns the SSH username for the running VM's distro.
func (v *VM) User() string {
	return v.provider.DefaultUser()
}

// Pid returns the QEMU process PID, or 0 if the VM has not been started.
func (v *VM) Pid() int {
	if v.cmd != nil && v.cmd.Process != nil {
		return v.cmd.Process.Pid
	}
	return 0
}

// KeyPath returns the path to the SSH private key used to connect to the VM,
// or "" if the default SSH agent / key is used.
func (v *VM) KeyPath() string {
	return v.sshOpts().KeyPath
}

func (v *VM) startQEMU() error {
	binary := v.arch.QEMUBinary()

	if _, err := exec.LookPath(binary); err != nil {
		return fmt.Errorf("%s not found: install QEMU first", binary)
	}

	baseImage, err := ensureImage(v.provider, v.arch, v.cfg.DataDir)
	if err != nil {
		return fmt.Errorf("vm image: %w", err)
	}

	cacheD := v.cfg.DataDir
	if cacheD == "" {
		cacheD, err = cacheDir()
		if err != nil {
			return fmt.Errorf("cache dir: %w", err)
		}
	}

	// Seed ISO is keyed per-provider so each distro gets its own user-data.
	seedISO, err := EnsureCloudInitSeed(cacheD, v.provider)
	if err != nil {
		return fmt.Errorf("cloud-init seed: %w", err)
	}

	sshPort := v.cfg.SSHPort
	if sshPort == 0 {
		sshPort = 10022
	}
	v.SSHPort = sshPort

	accel := accelFlag()
	format := v.provider.ImageFormat()

	// Create a throwaway overlay so the base image is never modified.
	// Include the PID in the filename so concurrent VM instances don't
	// collide — two mounts of the same distro would otherwise share the
	// same overlay path and the second Start would delete the first VM's
	// running disk.
	vmImage := fmt.Sprintf("%s.overlay.%d.qcow2", baseImage, os.Getpid())
	_ = os.Remove(vmImage) // remove any leftover from a previous run
	if out, err := exec.Command("qemu-img", "create",
		"-f", "qcow2",
		"-b", baseImage,
		"-F", format,
		vmImage,
	).CombinedOutput(); err != nil {
		return fmt.Errorf("qemu-img create overlay: %w\n%s", err, out)
	}
	v.overlayPath = vmImage

	serialDev := "null"
	if v.cfg.Debug {
		// chardev:serial0 writes to stderr so it doesn't interfere with
		// the Go test runner capturing stdout.
		serialDev = "file:/dev/stderr"
	}
	args := []string{
		"-accel", accel,
		"-m", fmt.Sprintf("%d", v.cfg.MemMiB),
		"-nographic",
		"-serial", serialDev,
		// Always disable the QEMU monitor: with -nographic the monitor
		// defaults to stdio, and reading EOF from /dev/null causes QEMU
		// to exit immediately.
		"-monitor", "none",
		// Boot explicitly from the first virtio disk (the VM root image).
		"-boot", "order=c,strict=on",
		// VM root disk — bootindex=1 ensures SeaBIOS boots this first.
		"-drive", fmt.Sprintf("if=none,id=rootdisk,format=%s,file=%s", format, vmImage),
		"-device", "virtio-blk-pci,drive=rootdisk,bootindex=1",
		// cloud-init seed ISO — NoCloud datasource reads this on first boot.
		"-drive", fmt.Sprintf("if=none,id=seeddisk,format=raw,file=%s,readonly=on", seedISO),
		"-device", "virtio-blk-pci,drive=seeddisk",
		// Target block device / image to expose inside the VM as /dev/vdc.
		"-drive", fmt.Sprintf("if=none,id=targetdisk,format=raw,file=%s,readonly=%s",
			v.cfg.DevicePath, boolToOnOff(v.cfg.ReadOnly)),
		"-device", "virtio-blk-pci,drive=targetdisk",
		"-netdev", v.buildNetdev(sshPort),
		"-device", "virtio-net-pci,netdev=net0",
	}

	v.logger.Info("Starting VM",
		"distro", v.provider.Name(),
		"arch", v.arch,
		"binary", binary,
		"accel", accel,
		"mem_mib", v.cfg.MemMiB,
		"device", v.cfg.DevicePath,
		"ssh_port", sshPort,
	)

	v.cmd = exec.CommandContext(v.ctx, binary, args...)
	// Always redirect stdin from /dev/null so QEMU's -serial mon:stdio
	// does not block waiting for input when running non-interactively.
	if f, err := os.Open(os.DevNull); err == nil {
		v.cmd.Stdin = f
	}
	if v.cfg.Debug {
		v.cmd.Stdout = os.Stdout
		v.cmd.Stderr = os.Stderr
	} else {
		// Capture both stdout and stderr: QEMU writes errors to stdout
		// when -nographic is active, and to stderr otherwise.
		v.qemuStderr.Reset()
		v.cmd.Stdout = &v.qemuStderr
		v.cmd.Stderr = &v.qemuStderr
	}
	if err := v.cmd.Start(); err != nil {
		return fmt.Errorf("qemu start: %w", err)
	}

	// Reap the process in the background so ProcessState is populated
	// promptly when QEMU exits, allowing waitForSSH to detect early exits.
	go func() { _ = v.cmd.Wait() }()

	if err := v.waitForSSH(300 * time.Second); err != nil {
		return err
	}
	// Allow up to 10 minutes for cloud-init runcmd to complete.
	// apt-get update + package install on a cold CI runner can take 3-4 min.
	return v.waitForCloudInit(600 * time.Second)
}

// waitForSSH polls the SSH port until it accepts connections or timeout expires.
func (v *VM) waitForSSH(timeout time.Duration) error {
	addr := fmt.Sprintf("127.0.0.1:%d", v.SSHPort)
	deadline := time.Now().Add(timeout)

	v.logger.Info("Waiting for VM SSH", "addr", addr, "timeout", timeout)

	// Give QEMU a moment to fail fast (e.g. missing file, bad args)
	// and for the Wait goroutine to populate ProcessState and flush output.
	time.Sleep(2 * time.Second)
	if v.cmd.ProcessState != nil && v.cmd.ProcessState.Exited() {
		return fmt.Errorf("QEMU process exited immediately (exit code %d)\nOutput:\n%s",
			v.cmd.ProcessState.ExitCode(), v.qemuStderr.String())
	}

	for time.Now().Before(deadline) {
		if v.cmd.ProcessState != nil && v.cmd.ProcessState.Exited() {
			return fmt.Errorf("QEMU process exited unexpectedly (exit code %d)\n%s",
				v.cmd.ProcessState.ExitCode(), v.qemuStderr.String())
		}
		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err == nil {
			conn.Close()
			// TCP port is open; wait for the SSH daemon to complete its
			// banner exchange before returning.
			if sshErr := v.waitForSSHBanner(addr, deadline); sshErr == nil {
				v.logger.Info("VM SSH ready", "addr", addr)
				return nil
			}
			// Banner not ready yet — keep polling.
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("timed out waiting for VM SSH on %s after %s\nQEMU stderr: %s",
		addr, timeout, v.qemuStderr.String())
}

// waitForCloudInit waits for cloud-init to fully complete, including runcmd.
//
// Strategy (in order):
//  1. If the provider writes a sentinel file (/run/cloud-init-custom-done),
//     wait for it — it is written as the last runcmd entry and lives on
//     /run (tmpfs) so it cannot be a stale leftover from a previous boot.
//  2. Otherwise poll `cloud-init status` until it reports "done" or "error".
//     This works on every distro that ships cloud-init without requiring any
//     provider-specific runcmd entry.
func (v *VM) waitForCloudInit(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	v.logger.Info("Waiting for cloud-init", "timeout", timeout)
	for time.Now().Before(deadline) {
		out, err := v.Run(
			// Check sentinel first (fast path for providers that write it).
			// Fall back to `cloud-init status` which exits 0 when done/error.
			"if test -f /run/cloud-init-custom-done; then echo DONE; " +
				"elif cloud-init status 2>/dev/null | grep -qE 'done|error'; then echo DONE; " +
				"else echo PENDING; fi",
		)
		if err == nil && strings.Contains(out, "DONE") {
			v.logger.Info("cloud-init ready")
			return nil
		}
		time.Sleep(5 * time.Second)
	}
	return fmt.Errorf("timed out waiting for cloud-init after %s", timeout)
}

// waitForSSHBanner connects to addr and reads the SSH protocol banner line.
// Returns nil only when the server sends a valid "SSH-" banner before deadline.
func (v *VM) waitForSSHBanner(addr string, deadline time.Time) error {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return fmt.Errorf("deadline exceeded")
	}
	timeout := remaining
	if timeout > 5*time.Second {
		timeout = 5 * time.Second
	}
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))
	buf := make([]byte, 64)
	n, err := conn.Read(buf)
	if err != nil {
		return err
	}
	if n < 4 || string(buf[:4]) != "SSH-" {
		return fmt.Errorf("unexpected banner: %q", buf[:n])
	}
	return nil
}

// buildNetdev constructs the QEMU -netdev user argument string, including
// the SSH port forward and any extra host forwards from Config.ExtraHostFwds.
func (v *VM) buildNetdev(sshPort uint16) string {
	s := fmt.Sprintf("user,id=net0,hostfwd=tcp::%d-:22", sshPort)
	for _, fwd := range v.cfg.ExtraHostFwds {
		s += ",hostfwd=" + fwd
	}
	return s
}

func boolToOnOff(b bool) string {
	if b {
		return "on"
	}
	return "off"
}
