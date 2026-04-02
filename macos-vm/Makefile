# SPDX-License-Identifier: GPL-3.0-or-later
# macos-kvm — top-level Makefile

SHELL := /usr/bin/env bash
REPO_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

FIRMWARE_DIR := $(REPO_ROOT)firmware
DISK_IMAGE   := $(REPO_ROOT)mac_hdd.qcow2
DISK_SIZE    ?= 128G
VERSION      ?= sonoma

.PHONY: all firmware opencore disk fetch boot headless incus-launch incus-start incus-stop incus-status clean help

all: help

help:
	@echo "macos-kvm targets:"
	@echo "  make firmware        Download OVMF firmware blobs"
	@echo "  make opencore        Download OpenCore bootloader qcow2"
	@echo "  make disk            Create a blank macOS HDD image (DISK_SIZE=$(DISK_SIZE))"
	@echo "  make fetch           Download macOS recovery image and convert to .img (VERSION=$(VERSION))"
	@echo "  make boot            Start macOS VM (GUI, bare QEMU)"
	@echo "  make headless        Start macOS VM (VNC on :5900, bare QEMU)"
	@echo "  make incus-launch    Create and launch macOS VM in Incus"
	@echo "  make incus-start     Start an existing Incus VM"
	@echo "  make incus-stop      Stop a running Incus VM"
	@echo "  make incus-status    Show Incus VM status"
	@echo "  make clean           Remove generated files"

firmware:
	@echo "Downloading OVMF firmware ..."
	@mkdir -p $(FIRMWARE_DIR)
	@if ! command -v wget &>/dev/null; then echo "ERROR: wget required"; exit 1; fi
	wget -q -nc -P $(FIRMWARE_DIR) \
	  https://github.com/kholia/OSX-KVM/raw/master/OVMF_CODE_4M.fd \
	  https://github.com/kholia/OSX-KVM/raw/master/OVMF_VARS-1920x1080.fd \
	  https://github.com/kholia/OSX-KVM/raw/master/OVMF_VARS-1024x768.fd
	@echo "Firmware ready in $(FIRMWARE_DIR)"

opencore:
	@echo "Downloading OpenCore bootloader ..."
	@mkdir -p $(REPO_ROOT)boot/OpenCore
	@if ! command -v wget &>/dev/null; then echo "ERROR: wget required"; exit 1; fi
	@# Fetch the latest OpenCore release from kholia/OSX-KVM (pre-built qcow2)
	wget -q -nc -O $(REPO_ROOT)boot/OpenCore/OpenCore.qcow2 \
	  https://github.com/kholia/OSX-KVM/raw/master/OpenCore/OpenCore.qcow2
	@echo "OpenCore ready at boot/OpenCore/OpenCore.qcow2"

disk:
	@if [[ -f "$(DISK_IMAGE)" ]]; then \
	  echo "$(DISK_IMAGE) already exists. Delete it first to recreate."; \
	else \
	  echo "Creating $(DISK_IMAGE) ($(DISK_SIZE)) ..."; \
	  qemu-img create -f qcow2 $(DISK_IMAGE) $(DISK_SIZE); \
	  echo "Done."; \
	fi

fetch:
	@echo "Fetching macOS $(VERSION) recovery image ..."
	python3 fetch/fetch-macos.py --version $(VERSION) --outdir fetch/
	@echo "Converting BaseSystem.dmg → BaseSystem.img ..."
	@if [[ -f fetch/BaseSystem.dmg ]]; then \
	  bash fetch/convert-image.sh fetch/BaseSystem.dmg fetch/BaseSystem.img; \
	elif [[ -f fetch/RecoveryImage.dmg ]]; then \
	  bash fetch/convert-image.sh fetch/RecoveryImage.dmg fetch/BaseSystem.img; \
	else \
	  echo "WARNING: No .dmg found in fetch/ — conversion skipped."; \
	fi

boot: firmware opencore disk
	bash boot/boot.sh

headless: firmware opencore disk
	HEADLESS=1 bash boot/boot.sh

incus-launch:
	bash incus/setup.sh launch

incus-start:
	bash incus/setup.sh start

incus-stop:
	bash incus/setup.sh stop

incus-status:
	bash incus/setup.sh status

clean:
	rm -f fetch/BaseSystem.img fetch/BaseSystem.dmg fetch/*.chunklist
	@echo "Disk image and firmware preserved. Remove manually if needed."
