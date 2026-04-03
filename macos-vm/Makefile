# SPDX-License-Identifier: GPL-3.0-or-later
# macos-vm — Incus-backed macOS VM toolkit

SHELL    := /usr/bin/env bash
IMT_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

VERSION  ?= sonoma
NAME     ?= macos-$(VERSION)

.PHONY: all firmware opencore fetch image vm-create vm-start vm-stop \
        vm-status vm-console vm-shell vm-snapshot vm-delete \
        optimize-guest doctor install clean help

all: help

help:
	@echo "imt (Incus macOS Toolkit) targets:"
	@echo ""
	@echo "  Setup:"
	@echo "    make firmware          Download OVMF firmware blobs"
	@echo "    make opencore          Download OpenCore bootloader qcow2"
	@echo "    make fetch             Fetch macOS recovery image (VERSION=$(VERSION))"
	@echo "    make image             Create QCOW2 disk image (calls image-pipeline)"
	@echo "    make doctor            Check all prerequisites"
	@echo "    make install           Install imt CLI to /usr/local/bin"
	@echo ""
	@echo "  VM lifecycle (all via Incus):"
	@echo "    make vm-create         Create and launch the macOS VM in Incus"
	@echo "    make vm-start          Start a stopped VM"
	@echo "    make vm-stop           Stop a running VM"
	@echo "    make vm-status         Show VM info"
	@echo "    make vm-console        Attach to VM console"
	@echo "    make vm-shell          Open a shell inside the VM"
	@echo "    make vm-snapshot       Create a snapshot"
	@echo "    make vm-delete         Delete the VM and its storage"
	@echo ""
	@echo "  Guest:"
	@echo "    make optimize-guest    Push and run guest optimizations"
	@echo ""
	@echo "  Options (override on command line):"
	@echo "    VERSION=$(VERSION)   macOS version (sonoma, ventura, monterey, ...)"
	@echo "    NAME=$(NAME)         Incus instance name"

# ── Setup targets ─────────────────────────────────────────────────────────────

firmware:
	@echo "Downloading OVMF firmware ..."
	@mkdir -p $(IMT_ROOT)firmware
	@command -v wget &>/dev/null || { echo "ERROR: wget required"; exit 1; }
	wget -q -nc -P $(IMT_ROOT)firmware \
	  https://github.com/kholia/OSX-KVM/raw/master/OVMF_CODE_4M.fd \
	  https://github.com/kholia/OSX-KVM/raw/master/OVMF_VARS-1920x1080.fd \
	  https://github.com/kholia/OSX-KVM/raw/master/OVMF_VARS-1024x768.fd
	@echo "Firmware ready in $(IMT_ROOT)firmware"

opencore:
	@echo "Downloading OpenCore bootloader ..."
	@mkdir -p $(IMT_ROOT)image-pipeline/OpenCore
	@command -v wget &>/dev/null || { echo "ERROR: wget required"; exit 1; }
	wget -q -nc -O $(IMT_ROOT)image-pipeline/OpenCore/OpenCore.qcow2 \
	  https://github.com/kholia/OSX-KVM/raw/master/OpenCore/OpenCore.qcow2
	@echo "OpenCore ready at image-pipeline/OpenCore/OpenCore.qcow2"

fetch:
	@echo "Fetching macOS $(VERSION) recovery image ..."
	python3 $(IMT_ROOT)image-pipeline/fetch-macos.py --version $(VERSION) \
	    --outdir $(IMT_ROOT)image-pipeline/
	@echo "Converting BaseSystem.dmg → BaseSystem.img ..."
	@if [[ -f $(IMT_ROOT)image-pipeline/BaseSystem.dmg ]]; then \
	  bash $(IMT_ROOT)image-pipeline/convert-image.sh \
	    $(IMT_ROOT)image-pipeline/BaseSystem.dmg \
	    $(IMT_ROOT)image-pipeline/BaseSystem.img; \
	elif [[ -f $(IMT_ROOT)image-pipeline/RecoveryImage.dmg ]]; then \
	  bash $(IMT_ROOT)image-pipeline/convert-image.sh \
	    $(IMT_ROOT)image-pipeline/RecoveryImage.dmg \
	    $(IMT_ROOT)image-pipeline/BaseSystem.img; \
	else \
	  echo "WARNING: No .dmg found — conversion skipped."; \
	fi

image: firmware opencore fetch
	bash $(IMT_ROOT)image-pipeline/build-image.sh \
	    --version $(VERSION) \
	    --firmware-dir $(IMT_ROOT)firmware \
	    --opencore $(IMT_ROOT)image-pipeline/OpenCore/OpenCore.qcow2 \
	    --installer $(IMT_ROOT)image-pipeline/BaseSystem.img

doctor:
	@bash $(IMT_ROOT)cli/imt.sh doctor

install:
	@echo "Installing imt to /usr/local/bin ..."
	sudo install -m 0755 $(IMT_ROOT)cli/imt.sh /usr/local/bin/imt
	sudo mkdir -p /usr/local/share/imt
	sudo cp -r $(IMT_ROOT)cli /usr/local/share/imt/
	sudo cp -r $(IMT_ROOT)image-pipeline /usr/local/share/imt/
	sudo cp -r $(IMT_ROOT)incus /usr/local/share/imt/
	sudo cp -r $(IMT_ROOT)guest-tools /usr/local/share/imt/
	@echo "Installed. Run: imt help"

# ── VM lifecycle targets (thin wrappers over imt CLI) ─────────────────────────

vm-create:
	bash $(IMT_ROOT)cli/imt.sh vm create --version $(VERSION) --name $(NAME)

vm-start:
	bash $(IMT_ROOT)cli/imt.sh vm start --name $(NAME)

vm-stop:
	bash $(IMT_ROOT)cli/imt.sh vm stop --name $(NAME)

vm-status:
	bash $(IMT_ROOT)cli/imt.sh vm status --name $(NAME)

vm-console:
	bash $(IMT_ROOT)cli/imt.sh vm console --name $(NAME)

vm-shell:
	bash $(IMT_ROOT)cli/imt.sh vm shell --name $(NAME)

vm-snapshot:
	bash $(IMT_ROOT)cli/imt.sh vm snapshot --name $(NAME)

vm-delete:
	bash $(IMT_ROOT)cli/imt.sh vm delete --name $(NAME)

# ── Guest ─────────────────────────────────────────────────────────────────────

optimize-guest:
	bash $(IMT_ROOT)incus/optimize-guest.sh $(NAME) --all

# ── Housekeeping ──────────────────────────────────────────────────────────────

clean:
	rm -f $(IMT_ROOT)image-pipeline/BaseSystem.img \
	      $(IMT_ROOT)image-pipeline/BaseSystem.dmg \
	      $(IMT_ROOT)image-pipeline/*.chunklist \
	      $(IMT_ROOT)image-pipeline/mac_hdd.qcow2
	@echo "Firmware and OpenCore preserved. Remove manually if needed."
