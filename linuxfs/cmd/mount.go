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
		fmt.Fprintf(os.Stderr, `Usage: linuxfs-mac mount [flags] <device>

Mount a block device or disk image containing a Linux filesystem.
The device is passed through to a Linux microVM which mounts it natively.
The mounted filesystem is then exposed to the host via a network share.

Examples:
  linuxfs-mac mount /dev/disk2s1
  linuxfs-mac mount /dev/disk2s1 --luks /dev/sda1
  linuxfs-mac mount /dev/disk2s1 --lvm vg0/home
  linuxfs-mac mount /dev/disk2s1 --read-only
  linuxfs-mac mount /path/to/disk.img
  linuxfs-mac mount /dev/disk2s1 --fstype btrfs --mount-opts subvol=@home

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
		Provider:   provider,
		MemMiB:     uint32(flagVMMemMiB), //nolint:gosec
		DevicePath: device,
		ReadOnly:   *readOnly,
		Debug:      flagDebug,
		DataDir:    flagDataDir,
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

	// TODO: SSH into VM, run mount commands (with LUKS/LVM/fstype/opts),
	// start share server inside VM, then auto-mount on host.
	shareURL := backendCfg.MountURL("linuxfs")
	fmt.Printf("\nVM is running. Share URL: %s\n", shareURL)

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

	fmt.Println("\nPress Ctrl+C to unmount and stop the VM.")
	// Block until SIGINT or SIGTERM.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	fmt.Println("\nShutting down ...")
}

func runUnmount(args []string) {
	fs := flag.NewFlagSet("unmount", flag.ExitOnError)
	if err := fs.Parse(args); err != nil {
		os.Exit(1)
	}
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "Usage: linuxfs-mac unmount <mountpoint>")
		os.Exit(1)
	}
	target := fs.Arg(0)
	fmt.Printf("Unmounting %s ...\n", target)
	if err := mount.AutoUnmount(target); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("Done.")
}


