// SPDX-License-Identifier: GPL-3.0-or-later
//
// setup.go — in-VM filesystem mount and share-server lifecycle.
//
// After the microVM boots, Setup:
//   1. Optionally opens a LUKS container on the pass-through device.
//   2. Optionally activates an LVM volume group.
//   3. Mounts the target filesystem at /mnt/linuxfs inside the VM.
//   4. Starts the appropriate share server (NFS, SMB, AFP, or FTP).
//   5. Returns the host-side share URL and the in-VM share port so the
//      caller can wait for it and then auto-mount on the host.
//
// Teardown stops the share server and unmounts the filesystem cleanly.

package mount

import (
	"fmt"
	"strings"
	"time"
)

const (
	// vmMountPoint is where the target filesystem is mounted inside the VM.
	vmMountPoint = "/mnt/linuxfs"

	// In-VM ports for each share server.
	portNFS = uint16(2049)
	portSMB = uint16(445)
	portAFP = uint16(548)
	portFTP = uint16(2121)

	// shareName is the exported share / NFS path name.
	shareName = "linuxfs"
)

// VMRunner is the subset of vm.VM used by this package, allowing the mount
// package to avoid a circular import on the vm package.
type VMRunner interface {
	Run(command string) (string, error)
	RunScript(script string) (string, error)
	WaitForPort(port uint16, timeout time.Duration) error
}

// HostFwds returns the QEMU hostfwd rules needed to expose the share server
// for the given backend to the host. Each entry is in the form
// "tcp::HOST_PORT-:GUEST_PORT" and should be passed as
// vm.Config.ExtraHostFwds before starting the VM.
func HostFwds(backend Backend) []string {
	switch backend {
	case BackendNFS:
		// NFS data port + mountd (pinned to 20048 via systemd drop-in).
		// Port 111 (rpcbind) is intentionally omitted: it is a privileged
		// port already bound by the host's rpcbind daemon, so QEMU cannot
		// bind a hostfwd for it. The NFS v3 mount uses explicit port= and
		// mountport= options so rpcbind is never consulted.
		return []string{
			fmt.Sprintf("tcp::%d-:%d", portNFS, portNFS),
			"tcp::20048-:20048",
		}
	case BackendSMB:
		return []string{fmt.Sprintf("tcp::%d-:%d", portSMB, portSMB)}
	case BackendAFP:
		return []string{fmt.Sprintf("tcp::%d-:%d", portAFP, portAFP)}
	case BackendFTP:
		// FTP control port + passive data range (40000–40004, 5 ports).
		// Must match pasv_min_port/pasv_max_port in the vsftpd config below.
		return []string{
			fmt.Sprintf("tcp::%d-:%d", portFTP, portFTP),
			"tcp::40000-:40000",
			"tcp::40001-:40001",
			"tcp::40002-:40002",
			"tcp::40003-:40003",
			"tcp::40004-:40004",
		}
	case BackendSSHFS:
		// SSHFS uses the existing SSH tunnel — no extra ports needed.
		return nil
	default:
		return nil
	}
}

// MountOptions carries the parameters for an in-VM mount operation.
type MountOptions struct {
	// InVMDevice is the block device inside the VM (e.g. /dev/vdc).
	// The pass-through device always appears as the third virtio disk.
	InVMDevice string

	// LUKS is the device to open as a LUKS container before mounting.
	// Empty = no LUKS.
	LUKS string

	// LVM is "vgname/lvname" to activate and mount. Empty = no LVM.
	LVM string

	// FSType is an optional filesystem type hint passed to mount -t.
	FSType string

	// MountOpts are extra options passed to mount -o.
	MountOpts string

	// ReadOnly mounts the filesystem read-only.
	ReadOnly bool

	// Backend is the share protocol to start inside the VM.
	Backend Backend

	// ListenIP is the IP the share server binds to (from Config.ListenIP).
	ListenIP string
}

// Setup mounts the filesystem and starts the share server inside the VM.
// Returns the host-side share URL.
func Setup(v VMRunner, opts MountOptions) (shareURL string, err error) {
	if opts.InVMDevice == "" {
		opts.InVMDevice = "/dev/vdc"
	}

	script, sharePort := buildSetupScript(opts)
	if out, err := v.RunScript(script); err != nil {
		return "", fmt.Errorf("in-VM setup: %w\nOutput:\n%s", err, out)
	}

	// Wait for the share server port to open inside the VM (skip for sshfs/mount-only).
	if sharePort != 0 {
		if err := v.WaitForPort(sharePort, 30*time.Second); err != nil {
			return "", fmt.Errorf("share server did not start: %w", err)
		}
	}

	cfg := Config{
		Backend:  opts.Backend,
		ListenIP: opts.ListenIP,
	}
	if opts.Backend == BackendFTP {
		cfg.ListenPort = portFTP
	}
	return cfg.MountURL(shareName), nil
}

// Teardown stops the share server and unmounts the filesystem inside the VM.
func Teardown(v VMRunner, opts MountOptions) error {
	script := buildTeardownScript(opts)
	out, err := v.RunScript(script)
	if err != nil {
		return fmt.Errorf("in-VM teardown: %w\nOutput:\n%s", err, out)
	}
	return nil
}

// buildSetupScript returns the shell script that runs inside the VM and the
// port number the share server will listen on.
func buildSetupScript(opts MountOptions) (string, uint16) {
	var b strings.Builder
	b.WriteString("set -e\n")

	// ── Step 1: LUKS ────────────────────────────────────────────────────────
	if opts.LUKS != "" {
		fmt.Fprintf(&b, `
# Open LUKS container
if ! cryptsetup status linuxfs-luks >/dev/null 2>&1; then
    cryptsetup luksOpen %s linuxfs-luks
fi
MOUNT_DEV=/dev/mapper/linuxfs-luks
`, opts.LUKS)
	} else {
		fmt.Fprintf(&b, "MOUNT_DEV=%s\n", opts.InVMDevice)
	}

	// ── Step 2: LVM ─────────────────────────────────────────────────────────
	if opts.LVM != "" {
		parts := strings.SplitN(opts.LVM, "/", 2)
		vg, lv := parts[0], ""
		if len(parts) == 2 {
			lv = parts[1]
		}
		fmt.Fprintf(&b, `
# Activate LVM volume group
vgchange -ay %s
`, vg)
		if lv != "" {
			fmt.Fprintf(&b, "MOUNT_DEV=/dev/%s/%s\n", vg, lv)
		} else {
			// No LV specified — use the first active LV in the VG.
			fmt.Fprintf(&b, `MOUNT_DEV=$(lvs --noheadings -o lv_path %s | awk '{print $1}' | head -1)
`, vg)
		}
	}

	// ── Step 3: Mount ───────────────────────────────────────────────────────
	fmt.Fprintf(&b, "mkdir -p %s\n", vmMountPoint)

	// ZFS: import the pool from the block device, then mount by pool name.
	// `mount -t zfs` requires a dataset name, not a block device path.
	// We query the pool name from `zpool import` dry-run output, then
	// import and mount by name.
	if opts.FSType == "zfs" {
		fmt.Fprintf(&b, `ZFS_POOL=$(zpool import -d "$MOUNT_DEV" 2>/dev/null | awk '/pool:/{print $2}' | head -1)
if [ -z "$ZFS_POOL" ]; then
    echo "ERROR: no ZFS pool found on $MOUNT_DEV" >&2; exit 1
fi
zpool import -d "$MOUNT_DEV" -f "$ZFS_POOL" 2>/dev/null || true
mount -t zfs "$ZFS_POOL" %s
`, vmMountPoint)
	} else {
		mountCmd := "mount"
		if opts.FSType != "" {
			mountCmd += fmt.Sprintf(" -t %s", opts.FSType)
		}
		var mountOptsAll []string
		if opts.ReadOnly {
			mountOptsAll = append(mountOptsAll, "ro")
		}
		if opts.MountOpts != "" {
			mountOptsAll = append(mountOptsAll, opts.MountOpts)
		}
		if len(mountOptsAll) > 0 {
			mountCmd += fmt.Sprintf(" -o %s", strings.Join(mountOptsAll, ","))
		}
		mountCmd += fmt.Sprintf(` "$MOUNT_DEV" %s`, vmMountPoint)
		fmt.Fprintf(&b, "%s\n", mountCmd)
	}

	// ── Step 4: Share server ─────────────────────────────────────────────────
	// Empty backend means mount-only (used by sshfs path) — skip share server.
	var sharePort uint16
	switch opts.Backend {
	case BackendNFS:
		sharePort = portNFS
		b.WriteString(buildNFSSetup(opts))
	case BackendSMB:
		sharePort = portSMB
		b.WriteString(buildSMBSetup(opts))
	case BackendAFP:
		// AFP (netatalk) — macOS default. Falls back to NFS if netatalk unavailable.
		sharePort = portAFP
		b.WriteString(buildAFPSetup(opts))
	case BackendFTP:
		sharePort = portFTP
		b.WriteString(buildFTPSetup(opts))
	case BackendSSHFS, "":
		// sshfs or mount-only: no share server needed inside the VM.
		sharePort = 0
	default:
		// Unknown backend — default to NFS.
		sharePort = portNFS
		b.WriteString(buildNFSSetup(opts))
	}

	return b.String(), sharePort
}

func buildNFSSetup(opts MountOptions) string {
	var b strings.Builder
	b.WriteString(`
# NFS share setup
# Install nfs-kernel-server if not present (distro-agnostic).
if ! command -v exportfs >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache nfs-utils
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends nfs-kernel-server
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nfs-utils
    fi
fi

# Pin mountd to port 20048 so QEMU hostfwd rules match deterministically.
# Write a systemd drop-in that overrides the ExecStart for nfs-mountd,
# passing -p 20048 explicitly. This works regardless of what the distro's
# default config file contains.
if command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system/nfs-mountd.service.d
    cat > /etc/systemd/system/nfs-mountd.service.d/port.conf <<'DROPIN'
[Service]
ExecStart=
ExecStart=/usr/sbin/rpc.mountd --manage-gids -p 20048
DROPIN
    systemctl daemon-reload
elif [ -f /etc/conf.d/nfs ]; then
    # Alpine OpenRC
    grep -q 'MOUNTD_PORT' /etc/conf.d/nfs 2>/dev/null || \
        echo 'MOUNTD_PORT=20048' >> /etc/conf.d/nfs
fi
`)
	// listenIP restricts which client IP the NFS export allows.
	// Empty or 0.0.0.0 means allow all (0.0.0.0/0 CIDR).
	listenIP := opts.ListenIP
	if listenIP == "" || listenIP == "0.0.0.0" {
		listenIP = "0.0.0.0/0"
	}
	roFlag := ""
	if opts.ReadOnly {
		roFlag = ",ro"
	}
	fmt.Fprintf(&b, `
# Export the mount point.
# fsid=0 makes /mnt/linuxfs the NFS root so the client mounts path /.
# Always include 127.0.0.1 and 10.0.2.2 (QEMU gateway) because the
# source IP seen by mountd for QEMU hostfwd connections is unpredictable.
# Also export to the configured listen IP (default: 0.0.0.0/0).
EXPORT_PATH='%s'
EXPORT_OPTS='rw,sync,no_subtree_check,no_root_squash,insecure,fsid=0%s'
LISTEN_IP='%s'
grep -v "^${EXPORT_PATH}" /etc/exports > /tmp/exports.tmp 2>/dev/null || true
printf "${EXPORT_PATH} 127.0.0.1(${EXPORT_OPTS})\n" >> /tmp/exports.tmp
printf "${EXPORT_PATH} 10.0.2.2(${EXPORT_OPTS})\n" >> /tmp/exports.tmp
printf "${EXPORT_PATH} ${LISTEN_IP}(${EXPORT_OPTS})\n" >> /tmp/exports.tmp
cp /tmp/exports.tmp /etc/exports

# Allow all NFS-related RPC services through TCP wrappers (if present).
# Without this, rpc.mountd compiled with libwrap may deny connections
# from 127.0.0.1 if /etc/hosts.deny has a restrictive default.
if [ -f /etc/hosts.allow ]; then
    grep -q 'mountd\|rpcbind\|ALL' /etc/hosts.allow 2>/dev/null || \
        printf 'rpcbind: ALL\nmountd: ALL\n' >> /etc/hosts.allow
fi

# Load nfsd kernel module explicitly (required on cloud kernels).
modprobe nfsd 2>/dev/null || true
modprobe nfs  2>/dev/null || true

# Start / reload NFS server.
if command -v rc-service >/dev/null 2>&1; then
    rc-service rpcbind start 2>/dev/null || true
    rc-service nfs start 2>/dev/null || rc-service nfs restart 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now rpcbind 2>/dev/null || true
    # Restart mountd first so it picks up the new port from nfs.conf,
    # then restart the full nfs-kernel-server stack.
    systemctl restart nfs-mountd 2>/dev/null || true
    systemctl restart nfs-kernel-server 2>/dev/null || \
        systemctl restart nfs-server 2>/dev/null || true
fi
exportfs -ra
# Brief pause so NFSD registers the new export before clients connect.
sleep 1
# Verify both NFS data port and mountd are listening.
ss -tlnp 2>/dev/null | grep -E ':2049|:20048' || true
`, vmMountPoint, roFlag, listenIP)
	return b.String()
}

func buildSMBSetup(opts MountOptions) string {
	var b strings.Builder
	b.WriteString(`
# SMB/CIFS share setup
if ! command -v smbd >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache samba
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends samba
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y samba
    fi
fi
`)
	roFlag := "no"
	if opts.ReadOnly {
		roFlag = "yes"
	}
	fmt.Fprintf(&b, `
# Write a minimal smb.conf if the share section is missing.
if ! grep -qF '[%s]' /etc/samba/smb.conf 2>/dev/null; then
    cat >> /etc/samba/smb.conf <<'SMBEOF'
[%s]
    path = %s
    browseable = yes
    read only = %s
    guest ok = yes
    force user = root
SMBEOF
fi

if command -v rc-service >/dev/null 2>&1; then
    rc-service samba start 2>/dev/null || rc-service samba restart 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now smbd 2>/dev/null || true
fi
`, shareName, shareName, vmMountPoint, roFlag)
	return b.String()
}

func buildAFPSetup(opts MountOptions) string {
	var b strings.Builder
	b.WriteString(`
# AFP share setup via netatalk.
# netatalk is not available on all distros; fall back to NFS if absent.
if ! command -v afpd >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache netatalk 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends netatalk 2>/dev/null || true
    fi
fi

if command -v afpd >/dev/null 2>&1; then
`)
	roFlag := ""
	if opts.ReadOnly {
		roFlag = " options:ro"
	}
	fmt.Fprintf(&b, `    grep -qF '%s' /etc/netatalk/AppleVolumes.default 2>/dev/null || \
        echo '%s "%s"%s' >> /etc/netatalk/AppleVolumes.default
    if command -v rc-service >/dev/null 2>&1; then
        rc-service netatalk start 2>/dev/null || rc-service netatalk restart 2>/dev/null || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now netatalk 2>/dev/null || true
    fi
else
    # netatalk unavailable — fall back to NFS.
    echo "netatalk not available, falling back to NFS" >&2
`, vmMountPoint, vmMountPoint, shareName, roFlag)
	b.WriteString(buildNFSSetup(opts))
	b.WriteString("fi\n")
	return b.String()
}

func buildFTPSetup(opts MountOptions) string {
	var b strings.Builder
	b.WriteString(`
# FTP share setup via vsftpd.
if ! command -v vsftpd >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache vsftpd
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends vsftpd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y vsftpd
    fi
fi
`)
	writeFlag := "NO"
	if !opts.ReadOnly {
		writeFlag = "YES"
	}
	fmt.Fprintf(&b, `
cat > /etc/vsftpd.conf <<'FTPEOF'
anonymous_enable=YES
local_enable=NO
write_enable=%s
anon_root=%s
listen=YES
listen_port=%d
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40004
FTPEOF

if command -v rc-service >/dev/null 2>&1; then
    rc-service vsftpd start 2>/dev/null || rc-service vsftpd restart 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now vsftpd 2>/dev/null || true
fi
`, writeFlag, vmMountPoint, portFTP)
	return b.String()
}

// InVMMountScript returns a shell script that mounts the device inside the VM
// without starting any share server. Used by the sshfs backend.
func InVMMountScript(opts MountOptions) string {
	// Reuse the first three steps of buildSetupScript (LUKS, LVM, mount)
	// but stop before the share server section.
	script, _ := buildSetupScript(MountOptions{
		InVMDevice: opts.InVMDevice,
		LUKS:       opts.LUKS,
		LVM:        opts.LVM,
		FSType:     opts.FSType,
		MountOpts:  opts.MountOpts,
		ReadOnly:   opts.ReadOnly,
		// Backend left empty so buildSetupScript skips the share server block.
		Backend: "",
	})
	return script
}

// InVMUnmountScript returns a shell script that unmounts the device inside
// the VM without touching any share server. Used by the sshfs backend.
func InVMUnmountScript(opts MountOptions) string {
	return buildTeardownScript(MountOptions{
		LUKS:    opts.LUKS,
		LVM:     opts.LVM,
		Backend: "", // no share server to stop
	})
}

// buildTeardownScript returns the shell script that stops the share server
// and unmounts the filesystem inside the VM.
func buildTeardownScript(opts MountOptions) string {
	var b strings.Builder
	b.WriteString("set -e\n")

	// Stop share server.
	switch opts.Backend {
	case BackendNFS:
		b.WriteString(`
if command -v rc-service >/dev/null 2>&1; then
    rc-service nfs stop 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl stop nfs-kernel-server 2>/dev/null || systemctl stop nfs-server 2>/dev/null || true
fi
exportfs -ua 2>/dev/null || true
`)
	case BackendSMB:
		b.WriteString(`
if command -v rc-service >/dev/null 2>&1; then
    rc-service samba stop 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl stop smbd 2>/dev/null || true
fi
`)
	case BackendAFP:
		b.WriteString(`
if command -v rc-service >/dev/null 2>&1; then
    rc-service netatalk stop 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl stop netatalk 2>/dev/null || true
fi
`)
	case BackendFTP:
		b.WriteString(`
if command -v rc-service >/dev/null 2>&1; then
    rc-service vsftpd stop 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl stop vsftpd 2>/dev/null || true
fi
`)
	}

	// Unmount filesystem.
	fmt.Fprintf(&b, `
umount -l %s 2>/dev/null || true
`, vmMountPoint)

	// Close LUKS if opened.
	if opts.LUKS != "" {
		b.WriteString(`
cryptsetup luksClose linuxfs-luks 2>/dev/null || true
`)
	}

	// Deactivate LVM if activated.
	if opts.LVM != "" {
		parts := strings.SplitN(opts.LVM, "/", 2)
		fmt.Fprintf(&b, "vgchange -an %s 2>/dev/null || true\n", parts[0])
	}

	return b.String()
}
