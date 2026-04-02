// SPDX-License-Identifier: GPL-3.0-or-later
//
// cloud-init seed ISO generation for the Alpine VM.
//
// Alpine cloud images support cloud-init. We generate a minimal seed ISO
// (user-data + meta-data) that sets a known password and injects the host's
// SSH public key so the tool can SSH in after boot.

package vm

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	// VMUser is the user created inside the Alpine VM.
	// Exported so cmd/shell.go can reference it for SSH connections.
	VMUser = "linuxfs"
	// vmPassword is used as a fallback; SSH key auth is preferred.
	vmPassword = "linuxfs-mac"
)

// EnsureCloudInitSeed creates a cloud-init seed ISO in dir if it doesn't
// already exist. Returns the path to the ISO.
func EnsureCloudInitSeed(dir string) (string, error) {
	seedPath := filepath.Join(dir, "cloud-init-seed.iso")
	if _, err := os.Stat(seedPath); err == nil {
		return seedPath, nil
	}

	seedDir := filepath.Join(dir, "cloud-init-seed")
	if err := os.MkdirAll(seedDir, 0o700); err != nil {
		return "", fmt.Errorf("create seed dir: %w", err)
	}

	// Read host SSH public key (prefer ed25519, fall back to rsa).
	sshPubKey, err := readHostSSHPubKey()
	if err != nil {
		// No SSH key found — generate one.
		sshPubKey, err = generateSSHKey(dir)
		if err != nil {
			return "", fmt.Errorf("SSH key: %w", err)
		}
	}

	userData := fmt.Sprintf(`#cloud-config
users:
  - name: %s
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/ash
    lock_passwd: false
    passwd: %s
    ssh_authorized_keys:
      - %s

ssh_pwauth: true
disable_root: false
`, VMUser, vmPassword, sshPubKey)

	metaData := "instance-id: linuxfs-mac-vm\nlocal-hostname: linuxfs-mac\n"

	if err := os.WriteFile(filepath.Join(seedDir, "user-data"), []byte(userData), 0o600); err != nil {
		return "", fmt.Errorf("write user-data: %w", err)
	}
	if err := os.WriteFile(filepath.Join(seedDir, "meta-data"), []byte(metaData), 0o600); err != nil {
		return "", fmt.Errorf("write meta-data: %w", err)
	}

	// Build the seed ISO using cloud-localds or genisoimage/mkisofs.
	if err := buildSeedISO(seedDir, seedPath); err != nil {
		return "", fmt.Errorf("build seed ISO: %w", err)
	}

	return seedPath, nil
}

// readHostSSHPubKey returns the first available SSH public key from ~/.ssh/.
func readHostSSHPubKey() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	for _, name := range []string{"id_ed25519.pub", "id_rsa.pub", "id_ecdsa.pub"} {
		path := filepath.Join(home, ".ssh", name)
		data, err := os.ReadFile(path)
		if err == nil {
			return string(data[:len(data)-1]), nil // trim trailing newline
		}
	}
	return "", fmt.Errorf("no SSH public key found in ~/.ssh/")
}

// generateSSHKey generates a new ed25519 key pair in dir and returns the public key.
func generateSSHKey(dir string) (string, error) {
	privPath := filepath.Join(dir, "vm_id_ed25519")
	pubPath := privPath + ".pub"

	if _, err := os.Stat(pubPath); err == nil {
		data, err := os.ReadFile(pubPath)
		if err == nil {
			return string(data), nil
		}
	}

	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		return "", fmt.Errorf("ssh-keygen not found; install OpenSSH")
	}

	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "", "-f", privPath, "-C", "linuxfs-mac-vm")
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
	return string(data), nil
}

// buildSeedISO creates a cloud-init seed ISO from the files in seedDir.
func buildSeedISO(seedDir, destISO string) error {
	// Prefer cloud-localds (cloud-image-utils package).
	if path, err := exec.LookPath("cloud-localds"); err == nil {
		cmd := exec.Command(path, destISO,
			filepath.Join(seedDir, "user-data"),
			filepath.Join(seedDir, "meta-data"))
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}

	// Fall back to genisoimage / mkisofs.
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
		"no ISO builder found; install cloud-image-utils (cloud-localds) " +
			"or genisoimage:\n  apt install cloud-image-utils\n  brew install cloud-utils",
	)
}
