# macOSdb

[![CI](https://github.com/starhaven-io/macOSdb/actions/workflows/ci.yml/badge.svg)](https://github.com/starhaven-io/macOSdb/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](LICENSE)
[![Data: CC-BY-4.0](https://img.shields.io/badge/Data-CC--BY--4.0-green.svg)](data/LICENSE)

A native macOS app and CLI that catalogs which versions of open-source components ship with each macOS and Xcode release.

macOSdb scans Apple's IPSW firmware files and Xcode `.xip` archives, extracts version strings from system binaries, the dyld shared cache, and SDK headers, and records what ships where. Browse releases, compare component versions across updates, and see which chip families and devices each release supports.

**Website:** [macosdb.com](https://macosdb.com)

## Tracked components

**Filesystem binaries:** curl, httpd, LibreSSL, OpenSSH, Ruby, SQLite, vim, zsh

**Dyld shared cache:** libbz2, libcurl, libexpat, libncurses, libpcap, libsqlite3, libssl, libxml2

**Xcode toolchain:** Apple Clang, cctools, Git, ld, lldb, Swift

**SDK libraries:** bzip2, expat, libcurl, libedit, libexslt, libffi, libxml2, libxslt, ncurses, sqlite3, zlib

## Installation

Requires macOS 15.0+ and Apple Silicon. Building from source requires Xcode 26+.

### Homebrew

```bash
brew install starhaven-io/tap/macosdb
```

### App

Download the latest release from [GitHub Releases](https://github.com/starhaven-io/macOSdb/releases), unzip, and move to `/Applications`. The app includes Sparkle for automatic updates.

### Build from source

```bash
# Build the CLI
swift build -c release

# Build the app
xcodebuild build -scheme macOSdb -configuration Release
```

## CLI usage

All commands default to macOS. Use `--product xcode` for Xcode releases. Use `--json` for machine-readable output.

```bash
# List releases
macosdb list
macosdb list --major 15
macosdb list --product xcode

# Show components for a release
macosdb show 15.2
macosdb show 15.2 --component curl
macosdb show 15.2 --detailed
macosdb show 16.2 --product xcode

# Compare components between releases
macosdb compare 15.1 15.2
macosdb compare 15.1 15.2 --changed
macosdb compare 16.1 16.2 --product xcode

# Scan an IPSW to produce release JSON
macosdb scan ~/Downloads/UniversalMac_15.2_24C101_Restore.ipsw \
  --output data/macos/releases --release-date 2024-12-11 --update-index --verbose

# Scan an Xcode .xip to produce release JSON
macosdb scan ~/Downloads/Xcode_26.4_Apple_silicon.xip \
  --output data/xcode/releases --release-date 2026-03-24 --update-index --verbose

# Validate archives and create SHA-256 sidecar hashes
macosdb validate ~/Downloads/UniversalMac_15.2_24C101_Restore.ipsw
macosdb validate --dir /path/to/archive
```

## How scanning works

The scanner extracts component versions from Apple's IPSW firmware images through a multi-phase pipeline:

1. **Extract IPSW** — unzip the `.ipsw` file (it's a ZIP archive)
2. **Parse kernelcaches** — extract Darwin/XNU versions and chip family mappings from each kernelcache, using BuildManifest.plist for device identification
3. **Decrypt AEA** — macOS 15+ uses Apple Encrypted Archives; the scanner fetches decryption keys from Apple's servers
4. **Mount system DMG** — mount the root filesystem image and scan binaries for version strings (e.g., `curl --version` output embedded in the binary)
5. **Extract from dyld shared cache** — many libraries live in the shared cache rather than as standalone files; the scanner parses the cache format to extract individual dylib data
6. **Assemble results** — combine kernel info, filesystem components, and dyld cache components into a structured `Release` JSON file

## Data

Release data is stored as JSON files in `data/`, organized by product type:

- `data/macos/releases.json` — index of all macOS releases (sorted newest first)
- `data/macos/releases/{major}/macOS-{version}-{build}.json` — full release data including kernels and components
- `data/xcode/` — same structure for Xcode releases

Data is also served as a REST API at [macosdb.com/api/v1/](https://macosdb.com/api/v1/macos/releases.json).

## Project structure

```
Sources/macOSdbKit/     Shared library — models, data provider, scanner pipeline
Sources/macosdb/        CLI executable (swift-argument-parser)
macOSdbApp/             SwiftUI app (NavigationSplitView, MVVM with @Observable)
site/                   Astro static site — release browser, compare view, component
                        pages, JSON API, OG image generation, full-text search
Tests/                  Swift Testing
data/                   Pre-built release JSON (CC-BY-4.0)
scripts/                JSON linting, release note formatting
.github/workflows/      CI (build, lint, test), CodeQL, deploy site, release pipeline
justfile                Task runner for common operations
```

## Building

A [justfile](https://github.com/casey/just) provides common tasks:

```bash
just build          # Build the Swift package
just clean          # Clean Swift build artifacts
just test           # Run Swift tests
just lint           # Run SwiftLint (--strict)
just lint-json      # Validate JSON data files
just typos          # Check for typos
just audit          # Audit GitHub Actions workflows
just build-app      # Build the app with xcodebuild
just test-xcode     # Run tests with xcodebuild (matches CI)
just check          # Run all checks (lint, lint-json, test, audit, site format, site build)
```

### Site

The `site/` directory contains an [Astro](https://astro.build) static site deployed to [macosdb.com](https://macosdb.com):

```bash
just site-install       # Install npm dependencies
just site-dev           # Start dev server
just site-build         # Production build
just site-preview       # Preview the built site
just site-format        # Format site files with Prettier
just site-format-check  # Check site formatting
```

## Contributing

Commits must follow [Conventional Commits](https://www.conventionalcommits.org/) format and include a DCO sign-off (`git commit -s`).

## Acknowledgements

Built with [Claude Code](https://claude.ai/code).

Thanks to [Guilherme Rambo](https://github.com/insidegui) for [VirtualBuddy](https://github.com/insidegui/VirtualBuddy), where contributing to the macOS catalog first sparked my interest in IPSW cataloging.

Thanks to [Bo Anderson](https://github.com/Bo98) for guidance on macOS and SDK internals.

macOS release data is extracted from Apple's publicly available [IPSW firmware images](https://support.apple.com/en-us/102662). Xcode release metadata sourced from [Xcode Releases](https://xcodereleases.com).

Device identification and release metadata sourced from [Apple Support](https://support.apple.com/en-us/102869), [AppleDB](https://appledb.dev), [EveryMac](https://everymac.com), and [The Apple Wiki](https://theapplewiki.com).

Apple, macOS, and related trademarks are property of Apple Inc.

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE) (`AGPL-3.0-only`).

The release data in `data/` is licensed separately under [CC-BY-4.0](data/LICENSE).

Copyright (C) 2026 Patrick Linnane
