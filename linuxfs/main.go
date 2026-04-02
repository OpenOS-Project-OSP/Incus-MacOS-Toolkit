// SPDX-License-Identifier: GPL-3.0-or-later
//
// linuxfs-mac — access Linux-native filesystems on macOS and Windows.
//
// Unified from:
//   - AlexSSD7/linsk  (Go core, QEMU VM, SMB/AFP/FTP backends)
//   - nohajc/anylinuxfs (libkrun microVM, NFS backend, Apple Silicon)

package main

import (
	"github.com/linuxfs-mac/linuxfs-mac/cmd"
)

func main() {
	cmd.Execute()
}
