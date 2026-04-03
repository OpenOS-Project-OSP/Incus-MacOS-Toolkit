// SPDX-License-Identifier: GPL-3.0-or-later

package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// MountRecord persists state about an active mount so 'list' and 'unmount' work.
type MountRecord struct {
	Device     string `json:"device"`
	ShareURL   string `json:"share_url"`
	MountPoint string `json:"mount_point,omitempty"`
	Backend    string `json:"backend"`
	VMPid      int    `json:"vm_pid"`
	SSHPort    uint16 `json:"ssh_port"`
	// VMUser is the SSH login user inside the VM (provider.DefaultUser()).
	// Needed by runUnmount to SSH in and run the in-VM teardown script.
	VMUser string `json:"vm_user,omitempty"`
	// LUKS is the in-VM device opened as a LUKS container, if any.
	// Persisted so runUnmount can close it during teardown.
	LUKS string `json:"luks,omitempty"`
	// LVM is the "vgname/lvname" activated for this mount, if any.
	// Persisted so runUnmount can deactivate the volume group during teardown.
	LVM string `json:"lvm,omitempty"`
}

func stateFile() (string, error) {
	dir := flagDataDir
	if dir == "" {
		base, err := os.UserCacheDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(base, "linuxfs")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return filepath.Join(dir, "mounts.json"), nil
}

func loadMounts() ([]MountRecord, error) {
	path, err := stateFile()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var records []MountRecord
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, err
	}
	return records, nil
}

func saveMounts(records []MountRecord) error {
	path, err := stateFile()
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func runList(_ []string) {
	records, err := loadMounts()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR reading state: %v\n", err)
		os.Exit(1)
	}
	if len(records) == 0 {
		fmt.Println("No active mounts.")
		return
	}
	fmt.Printf("%-30s %-8s %-40s %s\n", "DEVICE", "BACKEND", "SHARE URL", "MOUNTPOINT")
	for _, r := range records {
		mp := r.MountPoint
		if mp == "" {
			mp = "-"
		}
		fmt.Printf("%-30s %-8s %-40s %s\n", r.Device, r.Backend, r.ShareURL, mp)
	}
}
