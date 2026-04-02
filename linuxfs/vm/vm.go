// SPDX-License-Identifier: GPL-3.0-or-later
//
// vm package manages the lifecycle of the Linux microVM used to mount
// Linux filesystems. It wraps QEMU as the hypervisor backend and supports
// any cloud-init-compatible Linux distro via the Provider interface.

package vm

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
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

	// DataDir overrides the default cache directory for VM images.
	DataDir string
}

// VM represents a running Linux microVM instance.
type VM struct {
	cfg      Config
	provider Provider
	arch     Arch
	logger   *slog.Logger
	cmd      *exec.Cmd
	ctx      context.Context
	cancel   context.CancelFunc

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
	if v.cmd != nil && v.cmd.Process != nil {
		return v.cmd.Process.Kill()
	}
	return nil
}

// User returns the SSH username for the running VM's distro.
func (v *VM) User() string {
	return v.provider.DefaultUser()
}

func (v *VM) startQEMU() error {
	binary := v.arch.QEMUBinary()

	if _, err := exec.LookPath(binary); err != nil {
		return fmt.Errorf("%s not found: install QEMU first", binary)
	}

	vmImage, err := ensureImage(v.provider, v.arch, v.cfg.DataDir)
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

	args := []string{
		"-accel", accel,
		"-m", fmt.Sprintf("%d", v.cfg.MemMiB),
		"-nographic",
		"-serial", "mon:stdio",
		// VM root disk
		"-drive", fmt.Sprintf("if=virtio,format=%s,file=%s", format, vmImage),
		// cloud-init seed ISO
		"-drive", fmt.Sprintf("if=virtio,format=raw,file=%s,readonly=on", seedISO),
		// Target block device / image to mount
		"-drive", fmt.Sprintf("if=virtio,format=raw,file=%s,readonly=%s",
			v.cfg.DevicePath, boolToOnOff(v.cfg.ReadOnly)),
		"-netdev", fmt.Sprintf("user,id=net0,hostfwd=tcp::%d-:22", sshPort),
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
	if v.cfg.Debug {
		v.cmd.Stdout = os.Stdout
		v.cmd.Stderr = os.Stderr
	}
	if err := v.cmd.Start(); err != nil {
		return fmt.Errorf("qemu start: %w", err)
	}

	return v.waitForSSH(120 * time.Second)
}

// waitForSSH polls the SSH port until it accepts connections or timeout expires.
func (v *VM) waitForSSH(timeout time.Duration) error {
	addr := fmt.Sprintf("127.0.0.1:%d", v.SSHPort)
	deadline := time.Now().Add(timeout)

	v.logger.Info("Waiting for VM SSH", "addr", addr, "timeout", timeout)

	for time.Now().Before(deadline) {
		if v.cmd.ProcessState != nil && v.cmd.ProcessState.Exited() {
			return fmt.Errorf("QEMU process exited unexpectedly")
		}
		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err == nil {
			conn.Close()
			v.logger.Info("VM SSH ready", "addr", addr)
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("timed out waiting for VM SSH on %s after %s", addr, timeout)
}

func boolToOnOff(b bool) string {
	if b {
		return "on"
	}
	return "off"
}
