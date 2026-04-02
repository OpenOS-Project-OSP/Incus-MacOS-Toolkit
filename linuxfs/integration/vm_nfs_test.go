// SPDX-License-Identifier: GPL-3.0-or-later
//
// Integration test: boot Alpine VM, mount ext4, verify NFS share.
//
// Requirements (all satisfied on ubuntu-latest GitHub Actions runners):
//   - qemu-system-x86_64
//   - nfs-common (mount.nfs)
//   - sshfs (optional, tested separately)
//
// Run with:
//
//	go test -v -tags integration -timeout 10m ./integration/
//
// The test is skipped automatically when QEMU is not found in PATH.

//go:build integration

package integration

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/linuxfs-mac/linuxfs-mac/mount"
	"github.com/linuxfs-mac/linuxfs-mac/vm"
)

const (
	// testMemMiB is the RAM given to the test VM. 1 GiB speeds up first-boot
	// cloud-init package installation on the generic_alpine image.
	testMemMiB = 1024

	// testSSHPort is the host-side SSH port for the test VM.
	// Use a non-default port to avoid colliding with other tests.
	testSSHPort = 10122

	// testNFSPort is the host-side NFS port forwarded from the VM.
	testNFSPort = 12049

	// testSentinel is written inside the ext4 image and verified via NFS.
	testSentinel = "linuxfs-integration-ok\n"
)

// TestVMBootMountNFS:
//  1. Creates a small ext4 image on the host.
//  2. Writes a sentinel file into it via a loop mount.
//  3. Boots an Alpine VM with the image as the pass-through device.
//  4. Runs the NFS setup script inside the VM.
//  5. Mounts the NFS share on the host.
//  6. Verifies the sentinel file is visible.
func TestVMBootMountNFS(t *testing.T) {
	requireBinary(t, "qemu-system-x86_64")
	requireBinary(t, "mount")
	requireRoot(t) // NFS client mount requires root on Linux

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()

	// ── 1. Create ext4 image ─────────────────────────────────────────────────
	tmpDir := t.TempDir()
	imgPath := filepath.Join(tmpDir, "test.img")
	mntPath := filepath.Join(tmpDir, "loop-mnt")
	nfsMnt := filepath.Join(tmpDir, "nfs-mnt")

	t.Log("Creating 32 MiB ext4 image")
	mustRun(t, "dd", "if=/dev/zero", "of="+imgPath, "bs=1M", "count=32")
	mustRun(t, "mkfs.ext4", "-F", imgPath)

	// ── 2. Write sentinel via loop mount ─────────────────────────────────────
	t.Log("Writing sentinel file into ext4 image")
	if err := os.MkdirAll(mntPath, 0o755); err != nil {
		t.Fatalf("mkdir loop-mnt: %v", err)
	}
	mustRun(t, "mount", "-o", "loop", imgPath, mntPath)
	sentinelPath := filepath.Join(mntPath, "sentinel.txt")
	if err := os.WriteFile(sentinelPath, []byte(testSentinel), 0o644); err != nil {
		mustRun(t, "umount", mntPath)
		t.Fatalf("write sentinel: %v", err)
	}
	mustRun(t, "umount", mntPath)

	// ── 3. Boot Alpine VM ────────────────────────────────────────────────────
	t.Log("Booting Alpine VM")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))

	// Forward NFS data port and mountd only.
	// Port 111 (rpcbind) is skipped: it's a privileged port already bound
	// by the host's rpcbind daemon, causing QEMU hostfwd to fail.
	// The NFS v3 mount uses explicit port= and mountport= options so
	// rpcbind is not consulted.
	remapped := []string{
		fmt.Sprintf("tcp::%d-:2049", testNFSPort),
		"tcp::20048-:20048",
	}

	v, err := vm.New(ctx, vm.Config{
		Provider:      minimalDebianProvider{},
		MemMiB:        testMemMiB,
		DevicePath:    imgPath,
		SSHPort:       uint16(testSSHPort),
		ExtraHostFwds: remapped,
	}, logger)
	if err != nil {
		t.Fatalf("vm.New: %v", err)
	}

	if err := v.Start(); err != nil {
		t.Fatalf("vm.Start: %v", err)
	}
	t.Cleanup(func() {
		t.Log("Stopping VM")
		_ = v.Stop()
	})

	// ── 4. Run NFS setup inside VM ───────────────────────────────────────────
	t.Log("Running NFS setup inside VM")
	opts := mount.MountOptions{
		InVMDevice: "/dev/vdc",
		FSType:     "ext4",
		Backend:    mount.BackendNFS,
	}
	shareURL, err := mount.Setup(v, opts)
	if err != nil {
		t.Fatalf("mount.Setup: %v", err)
	}
	t.Logf("Share URL: %s", shareURL)

	// ── 5. Wait for NFS port on host ─────────────────────────────────────────
	t.Logf("Waiting for NFS port %d on host", testNFSPort)
	if err := waitForTCPPort("127.0.0.1", testNFSPort, 30*time.Second); err != nil {
		t.Fatalf("NFS port not reachable: %v", err)
	}

	// ── 6. Mount NFS on host and verify sentinel ──────────────────────────────
	t.Log("Mounting NFS share on host")
	if err := os.MkdirAll(nfsMnt, 0o755); err != nil {
		t.Fatalf("mkdir nfs-mnt: %v", err)
	}
	t.Cleanup(func() {
		_ = exec.Command("umount", "-l", nfsMnt).Run()
	})

	// NFS v3 over TCP; fsid=0 means the export root is /mnt/linuxfs inside VM.
	mountArgs := []string{
		"-t", "nfs",
		"-o", fmt.Sprintf("port=%d,mountport=20048,nfsvers=3,tcp,nolock,soft,timeo=30", testNFSPort),
		"127.0.0.1:/", nfsMnt,
	}
	if out, err := exec.CommandContext(ctx, "mount", mountArgs...).CombinedOutput(); err != nil {
		t.Fatalf("mount NFS: %v\n%s", err, out)
	}

	got, err := os.ReadFile(filepath.Join(nfsMnt, "sentinel.txt"))
	if err != nil {
		t.Fatalf("read sentinel via NFS: %v", err)
	}
	if string(got) != testSentinel {
		t.Fatalf("sentinel mismatch: got %q, want %q", got, testSentinel)
	}
	t.Log("NFS integration test passed")
}

// ── test provider ─────────────────────────────────────────────────────────────

// minimalDebianProvider wraps DebianProvider but installs no packages on first
// boot so SSH starts immediately without waiting for apt to finish.
// nfs-kernel-server and e2fsprogs are pre-installed in the Debian genericcloud
// base image, so the test doesn't need to install anything extra.
type minimalDebianProvider struct{ vm.DebianProvider }

func (minimalDebianProvider) CloudInitPackages() []string { return nil }
func (minimalDebianProvider) CloudInitRuncmds() []string {
	return []string{
		"systemctl enable ssh",
		"systemctl start ssh",
	}
}

// ── helpers ──────────────────────────────────────────────────────────────────

func requireBinary(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		t.Skipf("%s not found in PATH — skipping integration test", name)
	}
}

func requireRoot(t *testing.T) {
	t.Helper()
	if os.Getuid() != 0 {
		t.Skip("NFS client mount requires root — skipping integration test")
	}
}

func mustRun(t *testing.T, name string, args ...string) {
	t.Helper()
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v: %v\n%s", name, args, err, out)
	}
}

func waitForTCPPort(host string, port int, timeout time.Duration) error {
	addr := fmt.Sprintf("%s:%d", host, port)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("timed out waiting for %s after %s", addr, timeout)
}
