// SPDX-License-Identifier: GPL-3.0-or-later

package cmd

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/linuxfs-mac/linuxfs-mac/vm"
)

func runUpdateImages(args []string) {
	fs := flag.NewFlagSet("update-images", flag.ExitOnError)
	distro := fs.String("distro", "", "Update only this distro (default: all)")
	check := fs.Bool("check", false, "Check for updates without downloading")

	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: linuxfs update-images [--distro <name>] [--check]

Check for newer VM images and download them if available.
Old images are removed after a successful download.

Supported distros: alpine, debian, ubuntu, fedora

Flags:
`)
		fs.PrintDefaults()
	}

	if err := fs.Parse(args); err != nil {
		os.Exit(1)
	}

	arch := vm.HostArch()

	var providers []vm.Provider
	if *distro != "" {
		p, err := vm.ProviderByName(*distro)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
			os.Exit(1)
		}
		providers = []vm.Provider{p}
	} else {
		providers = []vm.Provider{
			vm.AlpineProvider{},
			vm.DebianProvider{},
			vm.UbuntuProvider{},
			vm.FedoraProvider{},
		}
	}

	cacheD := flagDataDir
	if cacheD == "" {
		base, err := os.UserCacheDir()
		if err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
			os.Exit(1)
		}
		cacheD = filepath.Join(base, "linuxfs")
	}

	anyUpdated := false
	for _, p := range providers {
		updated, err := checkAndUpdate(p, arch, cacheD, *check)
		if err != nil {
			fmt.Fprintf(os.Stderr, "WARNING [%s]: %v\n", p.Name(), err)
		}
		if updated {
			anyUpdated = true
		}
	}

	if !anyUpdated && !*check {
		fmt.Println("All images are up to date.")
	}
}

// checkAndUpdate checks whether a newer image is available for p and
// downloads it if so. Returns true if an update was downloaded.
func checkAndUpdate(p vm.Provider, arch vm.Arch, cacheD string, checkOnly bool) (bool, error) {
	url := p.ImageURL(arch)
	imageName := filepath.Base(url)
	providerDir := filepath.Join(cacheD, p.Name())
	imagePath := filepath.Join(providerDir, imageName)

	// Check if the current cached file matches what the provider URL points to.
	// The URL encodes the version (e.g. alpine-virt-3.21.3.x86_64.qcow2), so
	// a URL change means a new version is available.
	currentFiles, _ := filepath.Glob(filepath.Join(providerDir, "*.qcow2"))
	currentFiles2, _ := filepath.Glob(filepath.Join(providerDir, "*.img"))
	currentFiles = append(currentFiles, currentFiles2...)

	// Check if the exact filename already exists (already up to date).
	if _, err := os.Stat(imagePath); err == nil {
		// Verify the remote file is still reachable (HEAD request).
		if remoteExists(url) {
			fmt.Printf("[%s] Up to date: %s\n", p.Name(), imageName)
			return false, nil
		}
		fmt.Printf("[%s] WARNING: remote URL unreachable: %s\n", p.Name(), url)
		return false, nil
	}

	// A different (newer) filename exists — new version available.
	fmt.Printf("[%s] Update available: %s\n", p.Name(), imageName)
	if checkOnly {
		fmt.Printf("[%s]   URL: %s\n", p.Name(), url)
		return true, nil
	}

	// Download the new image.
	fmt.Printf("[%s] Downloading ...\n", p.Name())
	if err := os.MkdirAll(providerDir, 0o700); err != nil {
		return false, fmt.Errorf("mkdir: %w", err)
	}
	if err := vm.DownloadFile(url, imagePath, p.ImageSHA256(arch)); err != nil {
		return false, fmt.Errorf("download: %w", err)
	}

	// Remove old images for this provider.
	for _, old := range currentFiles {
		if old == imagePath {
			continue
		}
		if strings.HasSuffix(old, ".tmp") {
			continue
		}
		fmt.Printf("[%s] Removing old image: %s\n", p.Name(), filepath.Base(old))
		_ = os.Remove(old)
	}

	fmt.Printf("[%s] Updated to %s\n", p.Name(), imageName)
	return true, nil
}

// remoteExists does a HEAD request to check if a URL is reachable.
func remoteExists(url string) bool {
	resp, err := http.Head(url) //nolint:gosec,noctx
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
