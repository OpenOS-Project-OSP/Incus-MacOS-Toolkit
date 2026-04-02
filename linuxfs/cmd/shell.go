// SPDX-License-Identifier: GPL-3.0-or-later

package cmd

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/exec"

	"github.com/linuxfs-mac/linuxfs-mac/vm"
)

func runShell(args []string) {
	fs := flag.NewFlagSet("shell", flag.ExitOnError)
	if err := fs.Parse(args); err != nil {
		os.Exit(1)
	}
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "Usage: linuxfs-mac shell <device>")
		os.Exit(1)
	}

	device := fs.Arg(0)
	logger := slog.Default()

	provider, err := vm.ProviderByName(flagDistro)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	vmCfg := vm.Config{
		Provider:   provider,
		MemMiB:     uint32(flagVMMemMiB), //nolint:gosec
		DevicePath: device,
		Debug:      flagDebug,
		DataDir:    flagDataDir,
	}

	v, err := vm.New(context.Background(), vmCfg, logger)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Starting %s VM for %s ...\n", provider.Name(), device)
	if err := v.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR starting VM: %v\n", err)
		os.Exit(1)
	}
	defer func() { _ = v.Stop() }()

	// Open an interactive SSH session into the VM.
	sshArgs := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-p", fmt.Sprintf("%d", v.SSHPort),
		fmt.Sprintf("%s@127.0.0.1", v.User()),
	}
	fmt.Printf("Connecting: ssh %v\n", sshArgs)

	sshCmd := exec.Command("ssh", sshArgs...)
	sshCmd.Stdin = os.Stdin
	sshCmd.Stdout = os.Stdout
	sshCmd.Stderr = os.Stderr
	if err := sshCmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "SSH session ended: %v\n", err)
	}
}
