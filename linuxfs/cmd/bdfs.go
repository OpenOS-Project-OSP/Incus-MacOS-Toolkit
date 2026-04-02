// SPDX-License-Identifier: GPL-3.0-or-later
//
// bdfs.go — proxy for btrfs-dwarfs-framework CLI commands.
//
// `linuxfs bdfs <subcommand> [args...]` starts the microVM (or connects to a
// running one), then executes `bdfs <subcommand> [args...]` inside it via SSH
// and streams stdout/stderr back to the host.
//
// The bdfs kernel module and daemon must already be installed inside the VM
// image. The cloud-init setup in vm/provider_*.go installs btrfs-progs; the
// bdfs module itself is built from btrfs-dwarfs/ and installed separately.
//
// Usage examples:
//   linuxfs bdfs status
//   linuxfs bdfs partition add --type btrfs-backed --device /dev/vdb --label data
//   linuxfs bdfs export --partition <uuid> --subvol-id 256 --btrfs-mount /mnt/data
//   linuxfs bdfs blend mount --btrfs-uuid <uuid> --dwarfs-uuid <uuid> --mountpoint /mnt/blend

package cmd

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"

	"github.com/linuxfs-mac/linuxfs-mac/vm"
)

func runBdfs(args []string) {
	fs := flag.NewFlagSet("bdfs", flag.ExitOnError)
	device := fs.String("device", "", "Block device or image to pass through to the VM")

	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: linuxfs bdfs [--device <path>] <bdfs-subcommand> [args...]

Proxy for the btrfs-dwarfs-framework bdfs CLI running inside the microVM.
All arguments after the subcommand are forwarded verbatim to bdfs inside the VM.

The bdfs kernel module and daemon must be installed in the VM image.
See btrfs-dwarfs/ for build and installation instructions.

Examples:
  linuxfs bdfs status
  linuxfs bdfs partition add --type btrfs-backed --device /dev/vdb --label data
  linuxfs bdfs export --partition <uuid> --subvol-id 256 --btrfs-mount /mnt/data
  linuxfs bdfs blend mount --btrfs-uuid <u1> --dwarfs-uuid <u2> --mountpoint /mnt/blend
  linuxfs bdfs snapshot --partition <uuid> --image-id 1 --name snap_$(date +%%Y%%m%%d)

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

	// Everything after the flags is the bdfs subcommand + its own args.
	bdfsArgs := fs.Args()

	logger := slog.Default()
	if flagDebug {
		logger = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}

	provider, err := vm.ProviderByName(flagDistro)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	devicePath := *device
	if devicePath == "" {
		// No real device needed — use /dev/null as a placeholder so QEMU
		// starts without a data disk. bdfs operates on devices registered
		// with the daemon, not the pass-through device.
		devicePath = "/dev/null"
	}

	vmCfg := vm.Config{
		Provider:   provider,
		MemMiB:     uint32(flagVMMemMiB), //nolint:gosec
		DevicePath: devicePath,
		Debug:      flagDebug,
		DataDir:    flagDataDir,
	}

	v, err := vm.New(context.Background(), vmCfg, logger)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Starting %s VM for bdfs proxy ...\n", provider.Name())
	if err := v.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR starting VM: %v\n", err)
		os.Exit(1)
	}
	defer func() { _ = v.Stop() }()

	// Build the remote command: `sudo bdfs <subcommand> [args...]`
	// bdfs requires root to issue ioctls to /dev/bdfs_ctl.
	remoteCmd := "sudo bdfs " + shellJoin(bdfsArgs)

	sshArgs := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-p", fmt.Sprintf("%d", v.SSHPort),
		fmt.Sprintf("%s@127.0.0.1", v.User()),
		remoteCmd,
	}

	if flagDebug {
		fmt.Printf("SSH: ssh %s\n", strings.Join(sshArgs, " "))
	}

	sshCmd := exec.Command("ssh", sshArgs...)
	sshCmd.Stdin = os.Stdin
	sshCmd.Stdout = os.Stdout
	sshCmd.Stderr = os.Stderr
	if err := sshCmd.Run(); err != nil {
		// ssh exits with the remote command's exit code — propagate it.
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "SSH error: %v\n", err)
		os.Exit(1)
	}
}

// shellJoin quotes and joins args for safe inclusion in a remote shell command.
// Single-quotes each argument and escapes any embedded single quotes.
func shellJoin(args []string) string {
	quoted := make([]string, len(args))
	for i, a := range args {
		// Replace ' with '\'' (end quote, literal quote, reopen quote).
		escaped := strings.ReplaceAll(a, "'", `'\''`)
		quoted[i] = "'" + escaped + "'"
	}
	return strings.Join(quoted, " ")
}
