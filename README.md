[update-readmes]   Mode: rewrite — migrating to template structure...
# Incus-MacOS-Toolkit

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/OpenOS-Project-OSP/Incus-MacOS-Toolkit) [![KDE Eco](https://img.shields.io/badge/KDE%20Eco-certified-brightgreen?logo=kde&logoColor=white&style=flat-square)](https://eco.kde.org/) [![Blue Angel](https://img.shields.io/badge/Blue%20Angel-DE--UZ%20215-0055a4?style=flat-square)](https://www.blauer-engel.de/en/certification/criteria) [![Energy](https://api.green-coding.io/v1/ci/badge/get?repo=OpenOS-Project-OSP%2FIncus-MacOS-Toolkit&branch=main&workflow=eco-audit.yml)](https://metrics.green-coding.io/ci-index.html)


<!-- AI:start:what-it-does -->
This project provides a unified toolkit for macOS users to address cross-platform compatibility and virtualization needs. It enables macOS KVM virtualization using QEMU, facilitates access to Linux filesystems on macOS and Windows, offers compatibility tools for macOS and Linux interoperability, and implements a hybrid BTRFS+DwarFS storage framework. It is designed for developers and system administrators working in mixed macOS and Linux environments.
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
The project consists of four main components, each addressing specific functionality:

1. **macos-vm/**: Implements macOS virtualization using KVM via QEMU and Incus.
2. **linuxfs/**: Provides Linux filesystem access on macOS and Windows through a Go-based CLI.
3. **compat/**: Offers compatibility tools for macOS and Linux, including utilities like `linuxify`, `mlsblk`, and `bsdcoreutils`.
4. **btrfs-dwarfs/**: Combines BTRFS and DwarFS into a hybrid filesystem framework, including a kernel module and userspace tools.

The components interact through shared build targets and dependencies defined in the `Makefile`. The `Makefile` provides common targets for building, testing, formatting, and installing the components. It also includes per-component targets for granular control. The `PREFIX` variable specifies the installation path, while `KDIR` points to the kernel build tree for the BTRFS+DwarFS module.

Directory structure:
```plaintext
.
├── .github/             # GitHub workflows and actions
├── btrfs-devel/         # Read-only BTRFS source reference
├── btrfs-dwarfs/        # Hybrid filesystem framework
├── compat/              # Compatibility tools
├── linuxfs/             # Linux filesystem access CLI
├── macos-vm/            # macOS virtualization tools
├── Makefile             # Build and installation rules
├── README.md            # Project documentation
└── LICENSE              # Licensing information
```
<!-- AI:end:architecture -->

## Install

<!-- Add installation instructions here. This section is yours — the AI will not modify it. -->

```bash
git clone https://github.com/Interested-Deving-1896/Incus-MacOS-Toolkit.git
cd Incus-MacOS-Toolkit
```

## Usage

<!-- Add usage examples here. This section is yours — the AI will not modify it. -->

## Configuration

<!-- Document configuration options here. This section is yours — the AI will not modify it. -->

## CI

<!-- AI:start:ci -->
The repository includes the following GitHub Actions workflows for Continuous Integration:

1. **`btrfs-devel-sync.yml`**  
   - **Purpose**: Syncs the `btrfs-devel` directory with the upstream `kdave/btrfs-devel` repository to keep the source reference up to date.  
   - **Triggers**: Scheduled daily at midnight UTC.  
   - **Required Secrets**:  
     - `UPSTREAM_REPO`: URL of the upstream repository.  
     - `GITHUB_TOKEN`: Automatically provided by GitHub for authentication.  

2. **`mirror-osp-to-ooc.yaml`**  
   - **Purpose**: Mirrors the repository from the open-source project (OSP) namespace to an out-of-core (OOC) namespace for external distribution.  
   - **Triggers**: Push events to the `main` branch.  
   - **Required Secrets**:  
     - `OOC_REPO_URL`: URL of the target repository for mirroring.  
     - `GITHUB_TOKEN`: Automatically provided by GitHub for authentication.  

Ensure the required secrets are configured in the repository settings for workflows to execute successfully.
<!-- AI:end:ci -->

## Mirror chain

<!-- AI:start:mirror-chain -->
This repo is maintained in [`Interested-Deving-1896/Incus-MacOS-Toolkit`](https://github.com/Interested-Deving-1896/Incus-MacOS-Toolkit) and mirrored through:

```
Interested-Deving-1896/Incus-MacOS-Toolkit  ──►  OpenOS-Project-OSP/Incus-MacOS-Toolkit  ──►  OpenOS-Project-Ecosystem-OOC/Incus-MacOS-Toolkit
```

Changes flow downstream automatically via the hourly mirror chain in
[`fork-sync-all`](https://github.com/Interested-Deving-1896/fork-sync-all).
Direct commits to OSP or OOC are detected and opened as PRs back to `Interested-Deving-1896`.
<!-- AI:end:mirror-chain -->

## Contributors

<!-- AI:start:contributors -->
[@Interested-Deving-1896](https://github.com/Interested-Deving-1896): 46 commits  
[@ona-agent](https://github.com/ona-agent): 2 commits  

*Note: This repository is a mirror. Please refer to the upstream source for the original project.*
<!-- AI:end:contributors -->

## Origins

<!-- AI:start:origins -->

Original project — unified toolkit for macOS KVM virtualisation and Linux filesystem access on macOS via Incus.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [lxc/incus](https://github.com/lxc/incus) | GitHub | ✅ |
<!-- AI:end:origins -->

## Resources

<!-- AI:start:resources -->
| File | Description |
|---|---|
| [dep-graph/origins.md](https://github.com/Interested-Deving-1896/Incus-MacOS-Toolkit/blob/main/dep-graph/origins.md) | Dependency graph (Markdown table) |
<!-- AI:end:resources -->

## License

<!-- AI:start:license -->
[GPL-3.0](https://github.com/Interested-Deving-1896/Incus-MacOS-Toolkit/blob/main/LICENSE) © 2026 [Interested-Deving-1896](https://github.com/Interested-Deving-1896)
<!-- AI:end:license -->
