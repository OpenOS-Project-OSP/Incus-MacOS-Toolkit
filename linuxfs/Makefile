# SPDX-License-Identifier: GPL-3.0-or-later
# linuxfs-mac — top-level Makefile

BINARY   := linuxfs-mac
VERSION  := 0.1.0
LDFLAGS  := -ldflags "-X github.com/linuxfs-mac/linuxfs-mac/cmd.Version=$(VERSION)"

.PHONY: all build test lint clean install help

all: build

help:
	@echo "linuxfs-mac targets:"
	@echo "  make build    Build the binary"
	@echo "  make test     Run tests"
	@echo "  make lint     Run golangci-lint"
	@echo "  make install  Install to /usr/local/bin"
	@echo "  make clean    Remove build artifacts"

build:
	go build $(LDFLAGS) -o $(BINARY) .

test:
	go test ./...

lint:
	@if command -v golangci-lint &>/dev/null; then \
	  golangci-lint run ./...; \
	else \
	  echo "golangci-lint not found — run: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest"; \
	fi

install: build
	install -m 755 $(BINARY) /usr/local/bin/$(BINARY)

clean:
	rm -f $(BINARY)
