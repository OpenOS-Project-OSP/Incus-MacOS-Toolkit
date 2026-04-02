# SPDX-License-Identifier: GPL-3.0-or-later
#
# Incus-MacOS-Toolkit — unified build entry point.
#
# Components:
#   macos-vm/     macOS KVM virtualization via QEMU + Incus
#   linuxfs/      Linux filesystem access on macOS/Windows (Go CLI)
#   compat/       macOS–Linux compatibility tools (linuxify, mlsblk, bsdcoreutils)
#   btrfs-dwarfs/ BTRFS+DwarFS hybrid filesystem framework (kernel module + userspace)
#   btrfs-devel/  kdave/btrfs-devel fs/btrfs/ source reference (read-only)
#
# Common targets:
#   all            Build everything that can be built on the current host
#   clean          Remove all build artefacts
#   install        Install all components (may require root for kernel module)
#   test           Run all test suites
#   fmt            Format all source files
#
# Per-component targets (prefix with component name):
#   linuxfs        Build the linuxfs Go CLI
#   compat         Build mlsblk and bsdcoreutils
#   btrfs-dwarfs   Build the btrfs-dwarfs kernel module + userspace
#
# Variables:
#   PREFIX         Install prefix (default: /usr/local)
#   KDIR           Kernel build tree for btrfs-dwarfs (default: running kernel)
#   GOFLAGS        Extra flags passed to `go build`

PREFIX  ?= /usr/local
KDIR    ?= /lib/modules/$(shell uname -r)/build
GOOS    ?= $(shell go env GOOS 2>/dev/null || echo linux)
GOARCH  ?= $(shell go env GOARCH 2>/dev/null || echo amd64)

# Detect OS for host-only targets
UNAME_S := $(shell uname -s 2>/dev/null || echo Linux)

.PHONY: all clean install test fmt \
        linuxfs linuxfs-clean linuxfs-install linuxfs-test \
        compat compat-clean compat-install \
        btrfs-dwarfs btrfs-dwarfs-clean btrfs-dwarfs-install btrfs-dwarfs-test \
        btrfs-devel-sync \
        macos-vm-firmware macos-vm-opencore macos-vm-disk

# ── Top-level ────────────────────────────────────────────────────────────────

all: linuxfs compat btrfs-dwarfs

clean: linuxfs-clean compat-clean btrfs-dwarfs-clean

install: linuxfs-install compat-install btrfs-dwarfs-install

test: linuxfs-test btrfs-dwarfs-test

fmt: linuxfs-fmt btrfs-dwarfs-fmt

# ── linuxfs ──────────────────────────────────────────────────────────────────

linuxfs:
	cd linuxfs && go build -o bin/linuxfs $(GOFLAGS) .

linuxfs-clean:
	rm -rf linuxfs/bin/

linuxfs-install: linuxfs
	install -Dm755 linuxfs/bin/linuxfs $(DESTDIR)$(PREFIX)/bin/linuxfs

linuxfs-test:
	cd linuxfs && go test ./...

linuxfs-fmt:
	cd linuxfs && gofmt -w .

# Cross-compile for common targets (useful for distribution)
linuxfs-cross:
	cd linuxfs && \
	  GOOS=darwin  GOARCH=amd64 go build -o bin/linuxfs-darwin-amd64  . && \
	  GOOS=darwin  GOARCH=arm64 go build -o bin/linuxfs-darwin-arm64  . && \
	  GOOS=linux   GOARCH=amd64 go build -o bin/linuxfs-linux-amd64   . && \
	  GOOS=linux   GOARCH=arm64 go build -o bin/linuxfs-linux-arm64   . && \
	  GOOS=windows GOARCH=amd64 go build -o bin/linuxfs-windows-amd64.exe .

# ── compat ───────────────────────────────────────────────────────────────────

compat:
ifeq ($(UNAME_S),Darwin)
	$(MAKE) -C compat mlsblk bsdcoreutils
else
	@echo "compat: mlsblk and bsdcoreutils require macOS — skipping on $(UNAME_S)"
endif

compat-clean:
	$(MAKE) -C compat clean 2>/dev/null || true

compat-install:
ifeq ($(UNAME_S),Darwin)
	$(MAKE) -C compat install-mlsblk install-bsdcoreutils PREFIX=$(PREFIX)
else
	@echo "compat: install skipped on $(UNAME_S)"
endif

# ── btrfs-dwarfs ─────────────────────────────────────────────────────────────

btrfs-dwarfs:
	$(MAKE) -C btrfs-dwarfs all KDIR=$(KDIR)

# Build the kernel module against the bundled btrfs-devel source tree.
btrfs-dwarfs-devel:
	$(MAKE) -C btrfs-dwarfs kernel-devel

btrfs-dwarfs-clean:
	$(MAKE) -C btrfs-dwarfs clean

btrfs-dwarfs-install:
	$(MAKE) -C btrfs-dwarfs install KDIR=$(KDIR) PREFIX=$(PREFIX)

btrfs-dwarfs-test:
	$(MAKE) -C btrfs-dwarfs test

btrfs-dwarfs-check:
	$(MAKE) -C btrfs-dwarfs check

btrfs-dwarfs-fmt:
	$(MAKE) -C btrfs-dwarfs fmt

# ── btrfs-devel sync ─────────────────────────────────────────────────────────

# Pull the latest fs/btrfs/ from kdave/btrfs-devel and commit it.
btrfs-devel-sync:
	git fetch btrfs-devel master
	$(eval BTRFS_TREE := $(shell git ls-tree btrfs-devel/master fs/btrfs | awk '{print $$3}'))
	git read-tree --prefix=btrfs-devel/ -u $(BTRFS_TREE)
	git commit -m "btrfs-devel: sync with kdave/btrfs-devel $$(date +%Y-%m-%d)"

# ── macos-vm helpers ─────────────────────────────────────────────────────────

macos-vm-firmware:
	$(MAKE) -C macos-vm firmware

macos-vm-opencore:
	$(MAKE) -C macos-vm opencore

macos-vm-disk:
	$(MAKE) -C macos-vm disk

macos-vm-fetch:
	$(MAKE) -C macos-vm fetch

macos-vm-boot:
	$(MAKE) -C macos-vm boot

macos-vm-headless:
	$(MAKE) -C macos-vm headless
