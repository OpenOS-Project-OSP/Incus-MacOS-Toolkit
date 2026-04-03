// SPDX-License-Identifier: GPL-3.0-or-later

package cmd

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/linuxfs-mac/linuxfs-mac/mount"
	"github.com/linuxfs-mac/linuxfs-mac/vm"
)

func runMount(args []string) {
	fs := flag.NewFlagSet("mount", flag.ExitOnError)
	mountPoint := fs.String("mountpoint", "", "Host mount point (default: auto-generated)")
	readOnly   := fs.Bool("read-only", false, "Mount read-only")
	luks       := fs.String("luks", "", "In-VM device for LUKS container (e.g. /dev/sda1)")
	lvm        := fs.String("lvm", "", "LVM volume group/logical volume (e.g. vg0/home)")
	fstype     := fs.String("fstype", "", "Filesystem type hint (ext4, btrfs, xfs, zfs, ...)")
	mountOpts  := fs.String("mount-opts", "", "Extra mount options passed inside the VM")
	netShare   := fs.Bool("network-share", false, "Expose share on the local network")

	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: linuxfs mount [flags] <device>

Mount a block device or disk image containing a Linux filesystem.
The device is passed through to a Linux microVM which mounts it natively.
The mounted filesystem is then exposed to the host via a network share.

Examples:
  linuxfs mount /dev/disk2s1
  linuxfs mount /dev/disk2s1 --luks /dev/sda1
  linuxfs mount /dev/disk2s1 --lvm vg0/home
  linuxfs mount /dev/disk2s1 --read-only
  linuxfs mount /path/to/disk.img
  linuxfs mount /dev/disk2s1 --fstype btrfs --mount-opts subvol=@home

Flags:
`)
		fs.PrintDefaults()
	}

	if err := fs.Parse(args); err != nil {
		os.Exit(1)
	}
	if fs.NArg() < 1 {
		fs.Usage()
		os.Exit(1)
	}

	device := fs.Arg(0)

	backend := mount.Backend(flagBackend)
	if backend == "" {
		backend = mount.DefaultBackend()
	}

	listenIP := flagListenIP
	if *netShare {
		listenIP = "0.0.0.0"
	}

	backendCfg := mount.Config{
		Backend:      backend,
		ListenIP:     listenIP,
		NetworkShare: *netShare,
	}
	if err := backendCfg.Validate(); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Mounting %s via %s backend ...\n", device, backend)
	fmt.Printf("  VM memory:  %d MiB\n", flagVMMemMiB)
	fmt.Printf("  Read-only:  %v\n", *readOnly)
	if *luks != "" {
		fmt.Printf("  LUKS:       %s\n", *luks)
	}
	if *lvm != "" {
		fmt.Printf("  LVM:        %s\n", *lvm)
	}
	if *fstype != "" {
		fmt.Printf("  FS type:    %s\n", *fstype)
	}
	if *mountOpts != "" {
		fmt.Printf("  Mount opts: %s\n", *mountOpts)
	}

	logger := slog.Default()
	if flagDebug {
		logger = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}

	provider, err := vm.ProviderByName(flagDistro)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	vmCfg := vm.Config{
		Provider:      provider,
		MemMiB:        uint32(flagVMMemMiB), //nolint:gosec
		DevicePath:    device,
		ReadOnly:      *readOnly,
		Debug:         flagDebug,
		DataDir:       flagDataDir,
		ExtraHostFwds: mount.HostFwds(backend),
		SSHPort:       uint16(flagSSHPort), //nolint:gosec
	}

	v, err := vm.New(context.Background(), vmCfg, logger)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Starting %s VM ...\n", provider.Name())
	if err := v.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR starting VM: %v\n", err)
		os.Exit(1)
	}
	defer func() {
		fmt.Printf("Stopping %s VM ...\n", provider.Name())
		_ = v.Stop()
	}()

	// ── In-VM mount + share server (or sshfs) ────────────────────────────
	mountOpts_ := mount.MountOptions{
		// The pass-through device is always the third virtio disk in the VM.
		InVMDevice: "/dev/vdc",
		LUKS:       *luks,
		LVM:        *lvm,
		FSType:     *fstype,
		MountOpts:  *mountOpts,
		ReadOnly:   *readOnly,
		Backend:    backend,
		ListenIP:   listenIP,
	}

	var shareURL string

	if backend == mount.BackendSSHFS {
		// SSHFS: mount the VM filesystem directly over the SSH tunnel.
		// No share server needed — just mount /mnt/linuxfs inside the VM
		// first, then sshfs it to the host mountpoint.
		fmt.Println("Mounting filesystem inside VM ...")
		if out, err := v.RunScript(mount.InVMMountScript(mountOpts_)); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: in-VM mount: %v\nOutput:\n%s\n", err, out)
			os.Exit(1)
		}
		mp := *mountPoint
		if mp == "" {
			mp = "/tmp/linuxfs-" + sanitize(device)
		}
		fmt.Printf("Mounting via sshfs at %s ...\n", mp)
		sshfsOpts := mount.SSHFSOptions{
			SSHPort:    v.SSHPort,
			User:       v.User(),
			KeyPath:    v.KeyPath(),
			MountPoint: mp,
			ReadOnly:   *readOnly,
		}
		if err := mount.MountSSHFS(sshfsOpts); err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: sshfs: %v\n", err)
			os.Exit(1)
		}
		shareURL = "sshfs://" + mp
		*mountPoint = mp
	} else {
		fmt.Println("Setting up filesystem and share server inside VM ...")
		var err error
		shareURL, err = mount.Setup(v, mountOpts_)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
			os.Exit(1)
		}

		if *mountPoint != "" {
			fmt.Printf("Auto-mounting at %s ...\n", *mountPoint)
			if err := mount.AutoMount(shareURL, *mountPoint); err != nil {
				fmt.Fprintf(os.Stderr, "WARNING: auto-mount failed: %v\n", err)
				fmt.Printf("Connect manually: open %s\n", shareURL)
			}
		} else if runtime.GOOS == "darwin" {
			fmt.Printf("Opening share in Finder: %s\n", shareURL)
			if err := mount.AutoMount(shareURL, ""); err != nil {
				fmt.Fprintf(os.Stderr, "WARNING: %v\n", err)
			}
		} else {
			fmt.Printf("Connect to: %s\n", shareURL)
		}
	}

	// ── Persist state for 'list', 'unmount', and 'clean' ─────────────────
	records, _ := loadMounts()
	records = append(records, MountRecord{
		Device:     device,
		ShareURL:   shareURL,
		MountPoint: *mountPoint,
		Backend:    string(backend),
		VMPid:      v.Pid(),
		SSHPort:    v.SSHPort,
	})
	if err := saveMounts(records); err != nil {
		fmt.Fprintf(os.Stderr, "WARNING: could not save mount state: %v\n", err)
	}

	fmt.Printf("\nMounted: %s\n", shareURL)
	fmt.Println("Press Ctrl+C to unmount and stop the VM.")

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	fmt.Println("\nShutting down ...")

	// ── Teardown ──────────────────────────────────────────────────────────
	if backend == mount.BackendSSHFS {
		if err := mount.UnmountSSHFS(*mountPoint); err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: sshfs unmount: %v\n", err)
		}
		if out, err := v.RunScript(mount.InVMUnmountScript(mountOpts_)); err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: in-VM unmount: %v\nOutput:\n%s\n", err, out)
		}
	} else {
		if *mountPoint != "" {
			if err := mount.AutoUnmount(*mountPoint); err != nil {
				fmt.Fprintf(os.Stderr, "WARNING: host unmount: %v\n", err)
			}
		}
		if err := mount.Teardown(v, mountOpts_); err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: in-VM teardown: %v\n", err)
		}
	}

	// Remove from state file.
	if records, err := loadMounts(); err == nil {
		var updated []MountRecord
		for _, r := range records {
			if r.Device != device {
				updated = append(updated, r)
			}
		}
		_ = saveMounts(updated)
	}
}

// sanitize converts a device path to a safe filename component.
func sanitize(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			out = append(out, c)
		} else {
			out = append(out, '-')
		}
	}
	return string(out)
}

func runUnmount(args []string) {
	fs := flag.NewFlagSet("unmount", flag.ExitOnError)
	noStopVM := fs.Bool("no-stop-vm", false, "Unmount the share but leave the VM running")

	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: linuxfs unmount <mountpoint|device>

Unmount a share and stop the associated VM.

The argument may be either the host mountpoint (e.g. /Volumes/linuxfs)
or the original device path (e.g. /dev/disk2s1).

Flags:
`)
		fs.PrintDefaults()
	}

	if err := fs.Parse(args); err != nil {
		os.Exit(1)
	}
	if fs.NArg() < 1 {
		fs.Usage()
		os.Exit(1)
	}
	target := fs.Arg(0)

	// Look up the mount record so we can stop the VM.
	records, _ := loadMounts()
	var rec *MountRecord
	for i := range records {
		if records[i].MountPoint == target || records[i].Device == target {
			rec = &records[i]
			break
		}
	}

	// Unmount the host share.
	if rec != nil && rec.Backend == string(mount.BackendSSHFS) {
		// Use the recorded mountpoint, not the user-supplied target which
		// may be a device path (e.g. /dev/disk2s1) rather than the sshfs
		// mountpoint (e.g. /tmp/linuxfs-dev-disk2s1).
		sshfsMnt := target
		if rec.MountPoint != "" {
			sshfsMnt = rec.MountPoint
		}
		fmt.Printf("Unmounting sshfs %s ...\n", sshfsMnt)
		if err := mount.UnmountSSHFS(sshfsMnt); err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: %v\n", err)
		}
	} else {
		mp := target
		if rec != nil && rec.MountPoint != "" {
			mp = rec.MountPoint
		}
		if mp != "" {
			fmt.Printf("Unmounting %s ...\n", mp)
			if err := mount.AutoUnmount(mp); err != nil {
				fmt.Fprintf(os.Stderr, "WARNING: %v\n", err)
			}
		}
	}

	// Stop the VM process.
	if !*noStopVM && rec != nil && rec.VMPid > 0 {
		fmt.Printf("Stopping VM (pid %d) ...\n", rec.VMPid)
		if err := stopProcess(rec.VMPid); err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: could not stop VM: %v\n", err)
		}
	}

	// Remove from state file.
	if rec != nil {
		var updated []MountRecord
		for _, r := range records {
			if r.Device != rec.Device {
				updated = append(updated, r)
			}
		}
		_ = saveMounts(updated)
	}

	fmt.Println("Done.")
}

// stopProcess sends SIGTERM to pid, waits up to 5 s, then SIGKILL.
func stopProcess(pid int) error {
	proc, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	if err := proc.Signal(syscall.SIGTERM); err != nil {
		return err
	}
	// Poll for up to 5 seconds.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if err := proc.Signal(syscall.Signal(0)); err != nil {
			return nil // process gone
		}
		time.Sleep(200 * time.Millisecond)
	}
	// Still alive — force kill.
	return proc.Kill()
}
