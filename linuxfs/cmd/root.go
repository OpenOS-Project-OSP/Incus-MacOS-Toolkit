// SPDX-License-Identifier: GPL-3.0-or-later

package cmd

import (
	"flag"
	"fmt"
	"os"
)

// Global flags shared across subcommands.
var (
	flagVMMemMiB uint
	flagDebug    bool
	flagDataDir  string
	flagBackend  string
	flagListenIP string
	flagDistro   string
)

// Execute parses global flags then dispatches to the appropriate subcommand.
func Execute() {
	// Define global flags on the default FlagSet.
	flag.UintVar(&flagVMMemMiB, "vm-mem", 512,
		"RAM allocated to the VM in MiB (use >=2048 for LUKS)")
	flag.BoolVar(&flagDebug, "debug", false,
		"Enable verbose VM and QEMU output")
	flag.StringVar(&flagDataDir, "data-dir", "",
		"Directory for VM image and state (default: OS cache dir)")
	flag.StringVar(&flagBackend, "backend", "",
		"File share backend: smb, afp, nfs, ftp (auto-detected by OS if empty)")
	flag.StringVar(&flagListenIP, "listen-ip", "127.0.0.1",
		"IP address the share server listens on")
	flag.StringVar(&flagDistro, "distro", "alpine",
		"Linux distro for the microVM: alpine (default), debian, ubuntu, fedora")

	flag.Usage = usage

	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	// Detect subcommand: first non-flag argument.
	sub := os.Args[1]
	if sub == "-h" || sub == "--help" || sub == "help" {
		usage()
		return
	}

	// Parse global flags that appear before the subcommand.
	// e.g.: linuxfs-mac --vm-mem 2048 mount /dev/disk2s1
	// Also handle subcommand-first style: linuxfs-mac mount --vm-mem 2048 /dev/disk2s1
	// We do a best-effort parse: stop at the first non-flag token.
	_ = flag.CommandLine.Parse(os.Args[1:]) //nolint:errcheck

	// After parsing, flag.Args() contains the remaining non-flag args.
	// The first of those is the subcommand.
	args := flag.Args()
	if len(args) == 0 {
		usage()
		os.Exit(1)
	}

	sub = args[0]
	rest := args[1:]

	switch sub {
	case "mount":
		runMount(rest)
	case "unmount":
		runUnmount(rest)
	case "list":
		runList(rest)
	case "shell":
		runShell(rest)
	case "bdfs":
		runBdfs(rest)
	case "version":
		runVersion()
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %q\n\n", sub)
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `linuxfs-mac — access Linux-native filesystems on macOS and Windows.

Usage:
  linuxfs-mac [global flags] <subcommand> [flags] [args]

Subcommands:
  mount     Mount a Linux filesystem and expose it as a network share
  unmount   Unmount a previously mounted filesystem
  list      List currently mounted filesystems
  shell     Open a shell inside the VM for a device
  bdfs      Proxy btrfs-dwarfs-framework CLI commands into the VM
  version   Print version information

Global flags:
`)
	flag.PrintDefaults()
}
