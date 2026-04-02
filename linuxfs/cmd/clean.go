// SPDX-License-Identifier: GPL-3.0-or-later

package cmd

import (
	"flag"
	"fmt"
	"os"
	"syscall"
)

func runClean(args []string) {
	fs := flag.NewFlagSet("clean", flag.ExitOnError)
	dryRun := fs.Bool("dry-run", false, "Print stale entries without removing them")

	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: linuxfs clean [--dry-run]

Remove stale entries from the mount state file (mounts.json).
An entry is stale when its VM process is no longer running.

This is safe to run at any time. Active mounts are not affected.

Flags:
`)
		fs.PrintDefaults()
	}

	if err := fs.Parse(args); err != nil {
		os.Exit(1)
	}

	records, err := loadMounts()
	if err != nil {
		// No state file — nothing to clean.
		fmt.Println("No mount state found.")
		return
	}

	var live, stale []MountRecord
	for _, r := range records {
		if isProcessAlive(r.VMPid) {
			live = append(live, r)
		} else {
			stale = append(stale, r)
		}
	}

	if len(stale) == 0 {
		fmt.Printf("No stale entries found (%d active).\n", len(live))
		return
	}

	fmt.Printf("Stale entries (%d):\n", len(stale))
	for _, r := range stale {
		fmt.Printf("  %-20s  %-8s  pid=%-6d  %s\n",
			r.Device, r.Backend, r.VMPid, r.ShareURL)
	}

	if *dryRun {
		fmt.Println("(dry-run — not removed)")
		return
	}

	if err := saveMounts(live); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: could not save mount state: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Removed %d stale entr%s.\n", len(stale), pluralY(len(stale)))
}

// isProcessAlive returns true if a process with the given PID exists and is
// running. PID 0 is treated as dead (unset).
func isProcessAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	// On Unix, FindProcess always succeeds; send signal 0 to test liveness.
	err = proc.Signal(syscall.Signal(0))
	return err == nil
}

func pluralY(n int) string {
	if n == 1 {
		return "y"
	}
	return "ies"
}
