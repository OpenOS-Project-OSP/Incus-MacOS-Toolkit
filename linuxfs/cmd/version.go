// SPDX-License-Identifier: GPL-3.0-or-later

package cmd

import "fmt"

// Version is set at build time via -ldflags.
var Version = "0.1.0"

func runVersion() {
	fmt.Printf("linuxfs-mac %s\n", Version)
	fmt.Println("Upstream projects: AlexSSD7/linsk, nohajc/anylinuxfs")
}
