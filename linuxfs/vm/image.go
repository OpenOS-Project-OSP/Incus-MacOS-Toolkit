// SPDX-License-Identifier: GPL-3.0-or-later
//
// image.go — VM image download and caching.
//
// Images are stored in the OS cache directory under "linuxfs/<provider-name>/".
// The provider supplies the URL and optional SHA-256 checksum; this file
// handles the HTTP download, progress reporting, and atomic rename.

package vm

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

// cacheDir returns the OS-appropriate cache directory for linuxfs.
func cacheDir() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("user cache dir: %w", err)
	}
	dir := filepath.Join(base, "linuxfs")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create cache dir: %w", err)
	}
	return dir, nil
}

// ensureImage returns the path to a cached VM image for the given provider
// and host architecture, downloading it if not present.
func ensureImage(p Provider, arch Arch, dataDir string) (string, error) {
	dir := dataDir
	if dir == "" {
		var err error
		dir, err = cacheDir()
		if err != nil {
			return "", err
		}
	}

	// Store each provider's image in its own subdirectory.
	providerDir := filepath.Join(dir, p.Name())
	if err := os.MkdirAll(providerDir, 0o700); err != nil {
		return "", fmt.Errorf("create provider dir: %w", err)
	}

	url := p.ImageURL(arch)
	imageName := filepath.Base(url)
	imagePath := filepath.Join(providerDir, imageName)

	if _, err := os.Stat(imagePath); err == nil {
		return imagePath, nil // already cached
	}

	fmt.Printf("Downloading %s VM image (%s) ...\n", p.Name(), arch)
	fmt.Printf("  %s\n", url)

	if err := downloadFile(url, imagePath, p.ImageSHA256(arch)); err != nil {
		return "", fmt.Errorf("download %s image: %w", p.Name(), err)
	}

	fmt.Printf("  Saved to %s\n", imagePath)
	return imagePath, nil
}

// downloadFile downloads url to dest atomically, printing progress.
// If wantSHA256 is non-empty the download is verified against it.
func downloadFile(url, dest, wantSHA256 string) error {
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

	var writeErr error
	defer func() {
		f.Close()
		if writeErr != nil {
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
			if _, e := f.Write(buf[:n]); e != nil {
				writeErr = fmt.Errorf("write: %w", e)
				return writeErr
			}
			hash.Write(buf[:n])
			downloaded += int64(n)
			if total > 0 {
				fmt.Printf("\r  %3d%%  %d / %d MiB",
					downloaded*100/total, downloaded>>20, total>>20)
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			writeErr = fmt.Errorf("read: %w", readErr)
			return writeErr
		}
	}
	fmt.Println()

	if err = f.Close(); err != nil {
		return fmt.Errorf("close: %w", err)
	}

	gotSHA256 := hex.EncodeToString(hash.Sum(nil))
	fmt.Printf("  SHA-256: %s\n", gotSHA256)

	if wantSHA256 != "" && gotSHA256 != wantSHA256 {
		os.Remove(tmp)
		return fmt.Errorf("SHA-256 mismatch: got %s, want %s", gotSHA256, wantSHA256)
	}

	if err = os.Rename(tmp, dest); err != nil {
		return fmt.Errorf("rename: %w", err)
	}
	return nil
}
