// SPDX-License-Identifier: GPL-3.0-or-later
//
// Alpine Linux VM image management.
// Downloads and caches a minimal Alpine qcow2 image on first use,
// then injects an SSH authorized key via a cloud-init seed ISO.

package vm

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
)

const alpineVersion = "3.19.1"

// alpineArch returns the Alpine CPU architecture string for the current host.
func alpineArch() string {
	if runtime.GOARCH == "arm64" {
		return "aarch64"
	}
	return "x86_64"
}

// alpineImageURL returns the download URL for the Alpine virtual disk image.
func alpineImageURL() string {
	return fmt.Sprintf(
		"https://dl-cdn.alpinelinux.org/alpine/v%s/releases/cloud/alpine-virt-%s-%s.qcow2",
		alpineVersion[:4], alpineVersion, alpineArch(),
	)
}

// cacheDir returns the OS-appropriate cache directory for linuxfs-mac.
func cacheDir() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("user cache dir: %w", err)
	}
	dir := filepath.Join(base, "linuxfs-mac")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create cache dir: %w", err)
	}
	return dir, nil
}

// ensureAlpineImage returns the path to a cached Alpine qcow2 image,
// downloading it if not present.
func ensureAlpineImage(cfg Config) (string, error) {
	dir := cfg.DataDir
	if dir == "" {
		var err error
		dir, err = cacheDir()
		if err != nil {
			return "", err
		}
	}

	imageName := fmt.Sprintf("alpine-virt-%s-%s.qcow2", alpineVersion, alpineArch())
	imagePath := filepath.Join(dir, imageName)

	if _, err := os.Stat(imagePath); err == nil {
		return imagePath, nil // already cached
	}

	url := alpineImageURL()
	fmt.Printf("Downloading Alpine Linux VM image (%s) ...\n", alpineVersion)
	fmt.Printf("  %s\n", url)

	if err := downloadFile(url, imagePath); err != nil {
		return "", fmt.Errorf("download alpine image: %w", err)
	}

	fmt.Printf("  Saved to %s\n", imagePath)
	return imagePath, nil
}

// downloadFile downloads url to dest, printing a progress indicator.
func downloadFile(url, dest string) error {
	tmp := dest + ".tmp"

	resp, err := http.Get(url) //nolint:gosec,noctx
	if err != nil {
		return fmt.Errorf("GET %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: HTTP %d", url, resp.StatusCode)
	}

	f, err := os.Create(tmp)
	if err != nil {
		return fmt.Errorf("create %s: %w", tmp, err)
	}
	defer func() {
		f.Close()
		if err != nil {
			os.Remove(tmp)
		}
	}()

	total := resp.ContentLength
	var downloaded int64
	hash := sha256.New()
	buf := make([]byte, 1<<20) // 1 MiB chunks

	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, writeErr := f.Write(buf[:n]); writeErr != nil {
				err = fmt.Errorf("write: %w", writeErr)
				return err
			}
			hash.Write(buf[:n])
			downloaded += int64(n)
			if total > 0 {
				pct := downloaded * 100 / total
				fmt.Printf("\r  %3d%%  %d / %d MiB",
					pct, downloaded>>20, total>>20)
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			err = fmt.Errorf("read: %w", readErr)
			return err
		}
	}
	fmt.Println()

	if err = f.Close(); err != nil {
		return fmt.Errorf("close: %w", err)
	}

	if err = os.Rename(tmp, dest); err != nil {
		return fmt.Errorf("rename: %w", err)
	}

	fmt.Printf("  SHA-256: %s\n", hex.EncodeToString(hash.Sum(nil)))
	return nil
}
