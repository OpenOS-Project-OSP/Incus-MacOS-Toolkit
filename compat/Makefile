# SPDX-License-Identifier: GPL-3.0-or-later
# mac-linux-compat — top-level Makefile

SHELL := /usr/bin/env bash

.PHONY: all mlsblk install-mlsblk install-linuxify bsdcoreutils install-bsdcoreutils clean help

all: help

help:
	@echo "mac-linux-compat targets:"
	@echo "  make mlsblk              Build mlsblk (macOS only)"
	@echo "  make install-mlsblk      Build and install mlsblk to /usr/local/bin"
	@echo "  make install-linuxify    Install GNU tools on macOS via Homebrew"
	@echo "  make bsdcoreutils        Build BSD coreutils (inits submodule if needed)"
	@echo "  make install-bsdcoreutils Build and install BSD coreutils"
	@echo "  make clean               Remove build artifacts"

mlsblk:
	$(MAKE) -C mlsblk mlsblk

install-mlsblk:
	$(MAKE) -C mlsblk install

install-linuxify:
	bash linuxify/linuxify install

bsdcoreutils:
	@if [[ ! -d bsdcoreutils/upstream/.git ]]; then \
	  echo "Initialising bsdcoreutils submodule ..."; \
	  git submodule update --init bsdcoreutils/upstream; \
	fi
	mkdir -p bsdcoreutils/build
	cmake -S bsdcoreutils/upstream -B bsdcoreutils/build -DCMAKE_BUILD_TYPE=Release
	$(MAKE) -C bsdcoreutils/build -j$$(nproc 2>/dev/null || sysctl -n hw.ncpu)

install-bsdcoreutils: bsdcoreutils
	sudo $(MAKE) -C bsdcoreutils/build install
	@echo "BSD coreutils installed (tools prefixed with 'b': bcat, bls, bcp, ...)"

clean:
	$(MAKE) -C mlsblk clean
	rm -rf bsdcoreutils/build
