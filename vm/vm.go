// SPDX-License-Identifier: GPL-3.0-or-later
//
// vm package manages the lifecycle of the Alpine Linux microVM used to mount
// Linux filesystems. It wraps QEMU (cross-platform) and optionally libkrun
// (Apple Silicon) as hypervisor backends.
//
// Derived from AlexSSD7/linsk (vm/vm.go) and nohajc/anylinuxfs.

package vm

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"runtime"
	"time"
)

// Backend selects the hypervisor used to run the Alpine VM.
type Backend int

const (
	// BackendQEMU uses qemu-system-x86_64 / qemu-system-aarch64.
	// Works on Linux (KVM), macOS (HVF), and Windows (WHPX/TCG).
	BackendQEMU Backend = iota

	// BackendLibkrun uses libkrun (Apple Silicon only).
	// Lower overhead than QEMU; used by anylinuxfs on M-series Macs.
	BackendLibkrun
)

// Config holds parameters for a single VM instance.
type Config struct {
	// MemMiB is the RAM allocated to the VM in MiB.
	MemMiB uint32

	// DevicePath is the host block device or image file to pass through.
	DevicePath string

	// ReadOnly mounts the device read-only inside the VM.
	ReadOnly bool

	// Debug enables verbose QEMU/VM output.
	Debug bool

	// SSHPort is the host port forwarded to the VM's SSH daemon.
	// 0 = auto-select a free port.
	SSHPort uint16

	// Backend selects the hypervisor.
	Backend Backend

	// DataDir overrides the default cache directory for VM images.
	DataDir string
}

// VM represents a running Alpine Linux microVM instance.
type VM struct {
	cfg    Config
	logger *slog.Logger
	cmd    *exec.Cmd
	ctx    context.Context
	cancel context.CancelFunc

	// SSHPort is the resolved host port (set after Start).
	SSHPort uint16
}

// New creates a VM instance. Call Start to launch it.
func New(ctx context.Context, cfg Config, logger *slog.Logger) (*VM, error) {
	if cfg.MemMiB == 0 {
		cfg.MemMiB = 512
	}
	if cfg.Backend == BackendLibkrun && runtime.GOOS != "darwin" {
		return nil, fmt.Errorf("libkrun backend is only supported on macOS")
	}
	ctx, cancel := context.WithCancel(ctx)
	return &VM{
		cfg:    cfg,
		logger: logger,
		ctx:    ctx,
		cancel: cancel,
	}, nil
}

// Start launches the Alpine VM and waits for SSH to become available.
func (v *VM) Start() error {
	switch v.cfg.Backend {
	case BackendQEMU:
		return v.startQEMU()
	case BackendLibkrun:
		return v.startLibkrun()
	default:
		return fmt.Errorf("unknown backend: %d", v.cfg.Backend)
	}
}

// Stop shuts down the VM gracefully.
func (v *VM) Stop() error {
	v.cancel()
	if v.cmd != nil && v.cmd.Process != nil {
		return v.cmd.Process.Kill()
	}
	return nil
}

// accelFlag returns the correct QEMU acceleration flag for the current OS.
// Linux uses KVM, macOS uses Apple's Hypervisor.framework (HVF),
// Windows uses WHPX (falls back to TCG if unavailable).
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

func (v *VM) startQEMU() error {
	binary := "qemu-system-x86_64"
	if runtime.GOARCH == "arm64" {
		binary = "qemu-system-aarch64"
	}

	if _, err := exec.LookPath(binary); err != nil {
		return fmt.Errorf("%s not found: install QEMU first", binary)
	}

	alpineImage, err := ensureAlpineImage(v.cfg)
	if err != nil {
		return fmt.Errorf("alpine image: %w", err)
	}

	// Ensure cloud-init seed ISO exists (injects SSH key + user into Alpine).
	cacheD := v.cfg.DataDir
	if cacheD == "" {
		cacheD, err = cacheDir()
		if err != nil {
			return fmt.Errorf("cache dir: %w", err)
		}
	}
	seedISO, err := EnsureCloudInitSeed(cacheD)
	if err != nil {
		return fmt.Errorf("cloud-init seed: %w", err)
	}

	sshPort := v.cfg.SSHPort
	if sshPort == 0 {
		sshPort = 10022
	}
	v.SSHPort = sshPort

	accel := accelFlag()

	args := []string{
		"-accel", accel,
		"-m", fmt.Sprintf("%d", v.cfg.MemMiB),
		"-nographic",
		"-serial", "mon:stdio",
		// Alpine root disk
		"-drive", fmt.Sprintf("if=virtio,format=qcow2,file=%s", alpineImage),
		// cloud-init seed ISO (provides SSH key + user on first boot)
		"-drive", fmt.Sprintf("if=virtio,format=raw,file=%s,readonly=on", seedISO),
		// Target block device / image to mount
		"-drive", fmt.Sprintf("if=virtio,format=raw,file=%s,readonly=%s",
			v.cfg.DevicePath, boolToOnOff(v.cfg.ReadOnly)),
		"-netdev", fmt.Sprintf("user,id=net0,hostfwd=tcp::%d-:22", sshPort),
		"-device", "virtio-net-pci,netdev=net0",
	}

	v.logger.Info("Starting QEMU Alpine VM",
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

	// Wait for SSH to become available (up to 120 seconds).
	return v.waitForSSH(120 * time.Second)
}

// waitForSSH polls the SSH port until it accepts connections or the timeout expires.
func (v *VM) waitForSSH(timeout time.Duration) error {
	addr := fmt.Sprintf("127.0.0.1:%d", v.SSHPort)
	deadline := time.Now().Add(timeout)

	v.logger.Info("Waiting for Alpine VM SSH", "addr", addr, "timeout", timeout)

	for time.Now().Before(deadline) {
		// Check if the QEMU process died unexpectedly.
		if v.cmd.ProcessState != nil && v.cmd.ProcessState.Exited() {
			return fmt.Errorf("QEMU process exited unexpectedly")
		}

		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err == nil {
			conn.Close()
			v.logger.Info("Alpine VM SSH ready", "addr", addr)
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("timed out waiting for Alpine VM SSH on %s after %s", addr, timeout)
}

func (v *VM) startLibkrun() error {
	// libkrun provides a lighter-weight hypervisor using Apple's Hypervisor.framework.
	// It requires CGo bindings to libkrun.dylib — see docs/libkrun.md.
	// Use QEMU backend (with -accel hvf) as a fully functional alternative on macOS.
	return fmt.Errorf(
		"libkrun backend requires CGo bindings not yet compiled.\n" +
			"Use the default QEMU backend instead (works on Apple Silicon via -accel hvf).\n" +
			"See docs/libkrun.md for build instructions.",
	)
}

func boolToOnOff(b bool) string {
	if b {
		return "on"
	}
	return "off"
}
