// SPDX-License-Identifier: GPL-3.0-or-later
//
// cloudinit.go — cloud-init seed ISO generation.
//
// All supported providers use cloud-init for first-boot configuration.
// The seed ISO injects an SSH authorized key and installs filesystem tools.
// Package lists and runcmds come from the Provider so this file stays
// distro-agnostic.

package vm

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// cloudInitSeedVersion is incremented whenever the user-data template changes
// in a way that requires existing cached seed ISOs to be regenerated.
const cloudInitSeedVersion = 9

// EnsureCloudInitSeed creates a cloud-init seed ISO in dir if it doesn't
// already exist. The ISO is named after the provider to avoid collisions
// when switching distros. Returns the path to the ISO.
func EnsureCloudInitSeed(dir string, p Provider) (string, error) {
	seedPath := filepath.Join(dir, fmt.Sprintf("cloud-init-seed-%s-v%d.iso", p.Name(), cloudInitSeedVersion))
	if _, err := os.Stat(seedPath); err == nil {
		return seedPath, nil
	}

	seedDir := filepath.Join(dir, fmt.Sprintf("cloud-init-seed-%s-v%d", p.Name(), cloudInitSeedVersion))
	if err := os.MkdirAll(seedDir, 0o700); err != nil {
		return "", fmt.Errorf("create seed dir: %w", err)
	}

	sshPubKey, err := readHostSSHPubKey()
	if err != nil {
		sshPubKey, err = generateSSHKey(dir)
		if err != nil {
			return "", fmt.Errorf("SSH key: %w", err)
		}
	}

	userData := buildUserData(p, sshPubKey)
	metaData := fmt.Sprintf("instance-id: linuxfs-%s-vm\nlocal-hostname: linuxfs-vm\n", p.Name())

	if err := os.WriteFile(filepath.Join(seedDir, "user-data"), []byte(userData), 0o600); err != nil {
		return "", fmt.Errorf("write user-data: %w", err)
	}
	if err := os.WriteFile(filepath.Join(seedDir, "meta-data"), []byte(metaData), 0o600); err != nil {
		return "", fmt.Errorf("write meta-data: %w", err)
	}

	if err := buildSeedISO(seedDir, seedPath); err != nil {
		return "", fmt.Errorf("build seed ISO: %w", err)
	}
	return seedPath, nil
}

// buildUserData renders the cloud-init user-data for the given provider.
func buildUserData(p Provider, sshPubKey string) string {
	// Build YAML package list.
	var pkgLines strings.Builder
	for _, pkg := range p.CloudInitPackages() {
		pkgLines.WriteString(fmt.Sprintf("  - %s\n", pkg))
	}

	var runcmdLines strings.Builder
	for _, cmd := range p.CloudInitRuncmds() {
		runcmdLines.WriteString(fmt.Sprintf("  - %s\n", cmd))
	}

	// Only include packages/runcmd sections when non-empty to avoid
	// cloud-init schema warnings on empty lists.
	var pkgSection, runcmdSection string
	if pkgLines.Len() > 0 {
		pkgSection = "packages:\n" + pkgLines.String()
	}
	if runcmdLines.Len() > 0 {
		runcmdSection = "runcmd:\n" + runcmdLines.String()
	}

	return fmt.Sprintf(`#cloud-config
users:
  - name: %s
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: %s
    lock_passwd: true
    ssh_authorized_keys:
      - %s

ssh_pwauth: false
disable_root: false

%s
%s`,
		p.DefaultUser(),
		p.DefaultShell(),
		sshPubKey,
		pkgSection,
		runcmdSection,
	)
}

// readHostSSHPubKey returns the first available SSH public key from ~/.ssh/.
func readHostSSHPubKey() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	for _, name := range []string{"id_ed25519.pub", "id_rsa.pub", "id_ecdsa.pub"} {
		data, err := os.ReadFile(filepath.Join(home, ".ssh", name))
		if err == nil {
			return strings.TrimRight(string(data), "\n"), nil
		}
	}
	return "", fmt.Errorf("no SSH public key found in ~/.ssh/")
}

// generateSSHKey generates a new ed25519 key pair in dir and returns the public key.
func generateSSHKey(dir string) (string, error) {
	privPath := filepath.Join(dir, "vm_id_ed25519")
	pubPath := privPath + ".pub"

	if data, err := os.ReadFile(pubPath); err == nil {
		return strings.TrimRight(string(data), "\n"), nil
	}

	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		return "", fmt.Errorf("ssh-keygen not found; install OpenSSH")
	}

	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "", "-f", privPath, "-C", "linuxfs-vm")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("ssh-keygen: %w", err)
	}

	data, err := os.ReadFile(pubPath)
	if err != nil {
		return "", fmt.Errorf("read generated pub key: %w", err)
	}
	fmt.Printf("Generated SSH key pair at %s\n", privPath)
	return strings.TrimRight(string(data), "\n"), nil
}

// buildSeedISO creates a cloud-init seed ISO from the files in seedDir.
func buildSeedISO(seedDir, destISO string) error {
	if path, err := exec.LookPath("cloud-localds"); err == nil {
		cmd := exec.Command(path, destISO,
			filepath.Join(seedDir, "user-data"),
			filepath.Join(seedDir, "meta-data"))
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}

	for _, tool := range []string{"genisoimage", "mkisofs"} {
		if path, err := exec.LookPath(tool); err == nil {
			cmd := exec.Command(path,
				"-output", destISO,
				"-volid", "cidata",
				"-joliet", "-rock",
				filepath.Join(seedDir, "user-data"),
				filepath.Join(seedDir, "meta-data"))
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			return cmd.Run()
		}
	}

	return fmt.Errorf(
		"no ISO builder found; install cloud-image-utils (cloud-localds) or genisoimage:\n" +
			"  apt install cloud-image-utils\n" +
			"  brew install cloud-utils",
	)
}
