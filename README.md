# macOSdb

A native macOS app and CLI that catalogs which versions of open-source components ship with each macOS release.

macOSdb scans Apple's IPSW firmware files, extracts version strings from system binaries and the dyld shared cache, and records what ships where. Browse releases, compare component versions across updates, and see which chip families and devices each release supports.

## Tracked components

bash, curl, httpd, LibreSSL, OpenSSH, rsync, Ruby, SQLite, vim, zip, zsh — plus dyld shared cache libraries like libcurl, libexpat, libncurses, libpcap, libsqlite3, libssl, libxml2, libbz2, and more.

## Installation

Requires macOS 15.0+ and Apple Silicon.

### Homebrew

```bash
brew install p-linnane/tap/macosdb
```

### App

Download the latest release from [GitHub Releases](https://github.com/p-linnane/macOSdb/releases), unzip, and move to `/Applications`.

The CLI is bundled inside the app at `macOSdb.app/Contents/MacOS/macosdb-tool`:

```bash
# Symlink for easy access
ln -s /Applications/macOSdb.app/Contents/MacOS/macosdb-tool /usr/local/bin/macosdb
```

### Build from source

```bash
# Build the CLI
swift build -c release

# Build the app
xcodebuild build -scheme macOSdb -configuration Release
```

## CLI usage

```bash
# List all known macOS releases
macosdb list
macosdb list --major 15

# Show components for a release
macosdb show 15.2
macosdb show 15.2 --component curl

# Compare components between releases
macosdb compare 15.1 15.2
macosdb compare 15.1 15.2 --changed

# Scan an IPSW to produce release JSON
macosdb scan ~/Downloads/UniversalMac_15.2_24C101_Restore.ipsw \
  --output data/releases --release-date 2024-12-11 --update-index --verbose
```

## How scanning works

The scanner extracts component versions from Apple's IPSW firmware images through a multi-phase pipeline:

1. **Extract IPSW** — unzip the `.ipsw` file (it's a ZIP archive)
2. **Parse kernelcaches** — extract Darwin/XNU versions and chip family mappings from each kernelcache, using BuildManifest.plist for device identification
3. **Decrypt AEA** — macOS 15+ uses Apple Encrypted Archives; the scanner fetches decryption keys from Apple's servers
4. **Mount system DMG** — mount the root filesystem image and scan binaries for version strings (e.g., `curl --version` output embedded in the binary)
5. **Extract from dyld shared cache** — many libraries live in the shared cache rather than as standalone files; the scanner parses the cache format to extract individual dylib data
6. **Assemble results** — combine kernel info, filesystem components, and dyld cache components into a structured `Release` JSON file

## Data format

Release data is stored as JSON files in `data/`:

- `data/releases.json` — index of all releases with version, build number, name, and date
- `data/releases/{major}/macOS-{version}-{build}.json` — full release data including kernels and components

Data is fetched at runtime via HTTPS from GitHub raw URLs, so the app and CLI work without a local clone.

## Project structure

```
Sources/macOSdbKit/     Shared library — models, data provider, scanner pipeline
Sources/macosdb/        CLI executable (swift-argument-parser)
macOSdbApp/             SwiftUI app (NavigationSplitView, MVVM with @Observable)
  Bootstrap/            Entry point with CLI symlink dispatch
  Resources/            Asset catalog (app icon)
site/                   Astro static site (browse data on the web)
Tests/                  Swift Testing (94 tests)
data/                   Pre-built release JSON (CC-BY-4.0)
```

## Building

A [justfile](https://github.com/casey/just) provides common tasks:

```bash
just build          # Build the Swift package
just test           # Run Swift tests
just lint           # Run SwiftLint (--strict)
just lint-json      # Validate JSON data files
just audit          # Audit GitHub Actions workflows
just build-app      # Build the app with xcodebuild
just test-xcode     # Run tests with xcodebuild (matches CI)
just check          # Run all checks (lint, lint-json, test, audit, site format check, site build)
```

Or run commands directly:

```bash
swift build
swift test
xcodebuild build -scheme macOSdb -configuration Debug
swiftlint
```

### Site

The `site/` directory contains an [Astro](https://astro.build) static site:

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

Thanks to [Guilherme Rambo](https://github.com/insidegui) for the [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) project.

Release data is extracted from Apple's publicly available [IPSW firmware images](https://support.apple.com/en-us/102662). Device identification data sourced from [EveryMac](https://everymac.com), [The Apple Wiki](https://theapplewiki.com), and [Apple Support](https://support.apple.com/en-us/102869).

Apple, macOS, and related trademarks are property of Apple Inc.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE) (`GPL-3.0-only`).

The release data in `data/` is licensed separately under [CC-BY-4.0](data/LICENSE).

Copyright (C) 2026 Patrick Linnane
