# SPDX-License-Identifier: GPL-2.0-or-later
#
# Top-level Makefile for the BTRFS+DwarFS framework.
#
# Targets:
#   all              Build kernel module + userspace (daemon + CLI)
#   kernel           Build only the kernel module
#   userspace        Build only the userspace tools
#   install          Install everything (requires root for kernel module)
#   clean            Remove all build artefacts
#   test             Run integration tests
#   check            Run unit tests (requires cmake -DBUILD_TESTS=ON)
#   fmt              Format C sources with clang-format
#
# Variables:
#   KDIR             Kernel source tree (default: running kernel headers).
#                    Set to ../btrfs-devel to build against the in-tree
#                    kdave/btrfs-devel source included in this repository:
#                      make kernel KDIR=../btrfs-devel
#   PREFIX           Install prefix for userspace (default: /usr/local)
#   BUILD_DIR        CMake build directory (default: build/userspace)

KDIR      ?= /lib/modules/$(shell uname -r)/build
PREFIX    ?= /usr/local
BUILD_DIR ?= build/userspace

# Convenience alias: `make kernel-devel` builds against the bundled btrfs-devel tree.
BTRFS_DEVEL_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))../btrfs-devel

# VM provisioning parameters (override on command line as needed).
VM_SSH_PORT ?= 10022
VM_USER     ?= alpine
VM_SSH_KEY  ?=
VM_SSH_OPTS  = -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -p $(VM_SSH_PORT) \
               $(if $(VM_SSH_KEY),-i $(VM_SSH_KEY),)

.PHONY: all kernel kernel-devel userspace install install-kernel install-userspace \
        install-post clean clean-kernel clean-userspace test check fmt \
        bdfs-vm-install bdfs-vm-provision

all: kernel userspace

# ── Kernel module ────────────────────────────────────────────────────────────

kernel:
	$(MAKE) -C kernel KDIR=$(KDIR)

# Build the kernel module against the bundled kdave/btrfs-devel source tree.
# Requires a full kernel build tree at ../btrfs-devel (run `make -C ../btrfs-devel` first).
kernel-devel:
	$(MAKE) -C kernel KDIR=$(BTRFS_DEVEL_DIR)

clean-kernel:
	$(MAKE) -C kernel clean

install-kernel: kernel
	$(MAKE) -C kernel install

# ── Userspace ────────────────────────────────────────────────────────────────

$(BUILD_DIR)/Makefile:
	cmake -S userspace -B $(BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(PREFIX) \
		-DBUILD_DAEMON=ON \
		-DBUILD_CLI=ON

userspace: $(BUILD_DIR)/Makefile
	cmake --build $(BUILD_DIR) --parallel

clean-userspace:
	rm -rf $(BUILD_DIR)

install-userspace: userspace
	cmake --install $(BUILD_DIR)

# ── Combined ─────────────────────────────────────────────────────────────────

install: install-kernel install-userspace install-post

# Post-install: refresh module dependencies, man page index, and systemd units.
# Each step is best-effort (|| true) so install succeeds on minimal systems
# that lack mandb or a running systemd.
install-post:
	depmod -a 2>/dev/null || true
	mandb -q 2>/dev/null || true
	@if command -v systemctl >/dev/null 2>&1 && \
	    systemctl is-system-running >/dev/null 2>&1; then \
	    systemctl daemon-reload; \
	    echo "systemd units reloaded"; \
	fi

clean: clean-kernel clean-userspace

# ── Tests ────────────────────────────────────────────────────────────────────

test: userspace
	@echo "Running integration tests..."
	bash tests/integration/run_all.sh

check:
	cmake -S userspace -B build/tests \
		-DCMAKE_BUILD_TYPE=Debug \
		-DBUILD_TESTS=ON \
		-DENABLE_ASAN=ON
	cmake --build build/tests --parallel
	cd build/tests && ctest --output-on-failure

# ── VM provisioning ──────────────────────────────────────────────────────────
#
# bdfs-vm-install uploads the source tree to a running microVM and builds +
# installs the kernel module, daemon, and CLI inside it.
#
# Prerequisites:
#   - A microVM must be running with SSH forwarded to localhost:$(VM_SSH_PORT).
#     Start one with: linuxfs --distro alpine shell /dev/null
#   - The VM user must have passwordless sudo (cloud-init sets this up).
#
# Usage:
#   make bdfs-vm-install                          # Alpine default (port 10022)
#   make bdfs-vm-install VM_SSH_PORT=10023        # custom port
#   make bdfs-vm-install VM_USER=debian VM_SSH_PORT=10022
#   make bdfs-vm-install VM_SSH_KEY=~/.cache/linuxfs/vm_id_ed25519

bdfs-vm-install:
	@echo "Uploading btrfs-dwarfs source to VM ($(VM_USER)@127.0.0.1:$(VM_SSH_PORT)) ..."
	ssh $(VM_SSH_OPTS) $(VM_USER)@127.0.0.1 "sudo mkdir -p /opt/bdfs-src && sudo chown $(VM_USER) /opt/bdfs-src"
	rsync -az --delete \
	    --exclude='.git' \
	    --exclude='build/' \
	    --exclude='*.o' \
	    --exclude='*.ko' \
	    -e "ssh $(VM_SSH_OPTS)" \
	    . $(VM_USER)@127.0.0.1:/opt/bdfs-src/
	@echo "Running vm-install.sh inside VM ..."
	ssh $(VM_SSH_OPTS) $(VM_USER)@127.0.0.1 \
	    "sudo sh /opt/bdfs-src/scripts/vm-install.sh"
	@echo "bdfs-vm-install complete."

# Start a throwaway VM, install bdfs, then shut it down.
# This is a convenience wrapper for CI or first-time setup.
# The VM image is the linuxfs cache image for the selected distro.
#
# Usage:
#   make bdfs-vm-provision                          # Alpine, port 10022
#   make bdfs-vm-provision VM_DISTRO=debian
#   make bdfs-vm-provision VM_DISTRO=ubuntu VM_SSH_PORT=10023
#
# Requires: linuxfs binary on PATH (built with `make linuxfs` from repo root)

VM_DISTRO   ?= alpine
VM_DATA_DIR ?=

# Default SSH user matches the distro's cloud-init default user.
# Override with VM_USER=<user> if needed.
_VM_USER_alpine  = alpine
_VM_USER_debian  = debian
_VM_USER_ubuntu  = ubuntu
_VM_USER_fedora  = fedora
# Use explicit VM_USER if set, otherwise derive from VM_DISTRO.
_EFFECTIVE_VM_USER = $(if $(filter-out alpine,$(VM_USER)),$(VM_USER),$(or $(_VM_USER_$(VM_DISTRO)),alpine))

bdfs-vm-provision:
	@echo "Starting $(VM_DISTRO) VM for bdfs provisioning ..."
	@# Run linuxfs in the foreground with a subshell so we can wait for SSH
	@# readiness before proceeding. linuxfs shell blocks until the VM exits,
	@# so we start it in the background and poll SSH ourselves.
	linuxfs --distro $(VM_DISTRO) \
	    $(if $(VM_DATA_DIR),--data-dir $(VM_DATA_DIR),) \
	    --ssh-port $(VM_SSH_PORT) \
	    shell /dev/null &
	@echo "Waiting for VM SSH on port $(VM_SSH_PORT) ..."
	@for i in $$(seq 1 60); do \
	    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	        -o ConnectTimeout=2 -o BatchMode=yes \
	        $(if $(VM_SSH_KEY),-i $(VM_SSH_KEY),) \
	        -p $(VM_SSH_PORT) $(_EFFECTIVE_VM_USER)@127.0.0.1 true 2>/dev/null \
	        && break; \
	    sleep 2; \
	done
	@echo "VM ready. Running bdfs-vm-install ..."
	$(MAKE) bdfs-vm-install VM_SSH_PORT=$(VM_SSH_PORT) \
	    VM_USER=$(_EFFECTIVE_VM_USER) \
	    $(if $(VM_SSH_KEY),VM_SSH_KEY=$(VM_SSH_KEY),)
	@echo "Stopping VM ..."
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    -o ConnectTimeout=5 -o BatchMode=yes \
	    $(if $(VM_SSH_KEY),-i $(VM_SSH_KEY),) \
	    -p $(VM_SSH_PORT) $(_EFFECTIVE_VM_USER)@127.0.0.1 \
	    "sudo poweroff" 2>/dev/null || true
	@wait 2>/dev/null || true
	@echo "bdfs-vm-provision complete."

# ── Formatting ───────────────────────────────────────────────────────────────

fmt:
	find kernel userspace include -name '*.c' -o -name '*.h' | \
		xargs clang-format -i --style=file 2>/dev/null || \
		find kernel userspace include -name '*.c' -o -name '*.h' | \
		xargs clang-format -i --style="{BasedOnStyle: Linux, IndentWidth: 8}"
