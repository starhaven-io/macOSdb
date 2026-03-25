# macOSdb — Claude Project Context

macOSdb is a native macOS app and CLI that catalogs which versions of open-source components (curl, OpenSSH, SQLite, etc.) ship with each macOS release. It scans Apple's IPSW firmware files, extracts version strings from binaries and the dyld shared cache, and stores the results as JSON. The app lets you browse releases, compare component versions across releases, and see which chip families and devices each release supports.

## Project overview

- **Platform:** macOS 15.0+ (Apple Silicon only)
- **Language:** Swift 6.0, SwiftUI (100%)
- **Architecture:** MVVM using `@Observable` and SwiftUI Environment injection
- **Structure:** Xcode project (app + bundled CLI) + Swift Package (library, standalone CLI, tests)
- **Bundle ID:** `io.linnane.macosdb`
- **License:** GPL-3.0-only (code), CC-BY-4.0 (data)
- **Dependencies:** swift-argument-parser (CLI), ZIPFoundation (IPSW extraction)

## Repository structure

```
macOSdb/
├── macOSdb.xcodeproj/                     # Xcode project (builds app target with bundled CLI)
├── Package.swift                          # SPM: macOSdbKit lib + standalone macosdb CLI
├── Sources/
│   ├── macOSdbKit/                        # Shared library (19 files)
│   │   ├── Models/                        # Release, Component, KernelInfo, ChipFamily, DeviceRegistry, VersionComparison
│   │   ├── Scanner/                       # IPSW scanning pipeline (11 files)
│   │   ├── DataProvider.swift             # Fetch JSON from HTTPS (GitHub raw) or local files
│   │   └── VersionComparer.swift          # Diff components across releases
│   └── macosdb/                           # CLI executable (swift-argument-parser, 6 files)
├── macOSdbApp/                            # SwiftUI app sources (built by Xcode project)
│   ├── Bootstrap/
│   │   └── EntryPoint.swift               # @main — dispatches to app or CLI based on process name
│   ├── macOSdbApp.swift                   # App struct (no @main — entry point is in Bootstrap/)
│   ├── Models/
│   │   └── AppState.swift                 # @Observable @MainActor state container
│   ├── Views/
│   │   ├── ContentView.swift              # NavigationSplitView root
│   │   ├── SidebarView.swift              # Collapsible release groups, pre-release toggle
│   │   ├── ReleaseDetailView.swift        # Component table, kernel info, chips
│   │   ├── CompareView.swift              # Side-by-side diff with color-coded changes
│   │   └── ChipSupportView.swift          # Chip/device support grouped by generation
│   └── Resources/
│       └── Assets.xcassets/               # App icon, accent color
├── site/                                  # Astro static site (browse data on the web)
│   ├── src/
│   │   ├── pages/                         # index, release/[slug], compare
│   │   ├── layouts/                       # Base.astro
│   │   └── styles/                        # global.css
│   ├── astro.config.mjs
│   └── package.json
├── Tests/
│   └── macOSdbKitTests/                   # Swift Testing (6 test files, 94 tests)
│       └── Fixtures/                      # Test data (sample release JSON)
├── data/                                  # Pre-built JSON (committed, CC-BY-4.0)
│   ├── LICENSE                            # CC-BY-4.0 license for data
│   ├── releases.json                      # Index file (sorted newest first)
│   └── releases/{major}/                  # Per-release JSON (macOS-{version}-{build}.json)
├── justfile                               # Task runner (just clean/build/test/lint/check and more)
├── .github/
│   ├── workflows/                         # CI: build, check, conventional-commits, codeql, zizmor, scan-ipsw, deploy-site, release
│   ├── format-release-notes.py            # Formats GitHub auto-generated notes by Conventional Commits type
│   ├── appcast-template.xml               # Sparkle appcast template for auto-updates
│   ├── dependabot.yml                     # Dependabot for GitHub Actions
│   └── FUNDING.yml                        # GitHub Sponsors
├── LICENSE                                # GPL-3.0-only
├── .swiftlint.yml
└── .gitignore
```

## Architecture details

### macOSdbKit (shared library)

The core library consumed by both the CLI and app.

**Models:** `Release`, `Component`, `KernelInfo`, `ChipFamily`, `DeviceRegistry`, `VersionComparison`, `ComponentChange`

**DataProvider:** Actor that fetches release data from HTTPS (GitHub raw URLs) or local `data/` directory. Configurable base URL for dev/testing.

**VersionComparer:** Static methods to diff components between two releases.

**Scanner pipeline** (6 phases):
1. Extract IPSW (ZIP) → temp directory with kernelcaches and DMG files
2. Parse kernelcaches → `[KernelInfo]` with BuildManifest device mapping and per-device chip resolution
3. Decrypt AEA images if needed (macOS 15+, fetches keys from Apple)
4. Mount system DMG → extract filesystem components (version strings from binaries)
5. Mount cryptex DMG (macOS 13+) or use system DMG → extract dyld cache components
6. Assemble and return `Release` with resolved name and auto-detected beta status

**Scanner components:**
- `IPSWScanner` — pipeline orchestrator (public actor)
- `IPSWExtractor` — ZIP extraction, BuildManifest/Restore.plist parsing
- `KernelParser` — kernelcache parsing → KernelInfo
- `AEADecryptor` — AEA decryption (macOS 15+, fetches keys from Apple WKMS)
- `IM4PDecoder` — IM4P container decoding (LZFSE decompression)
- `DMGMounter` — DMG mount/unmount via hdiutil
- `DyldCacheExtractor` — extract dylibs from dyld_shared_cache (supports split subcaches)
- `ComponentExtractor` — version string extraction from binaries
- `BinaryStringScanner` — raw binary string scanning
- `ScannerConfig` — component definitions (filesystem + dyld cache)
- `ScannerError` — scanner error types

### CLI (macosdb)

Built with swift-argument-parser. Commands:
- `macosdb list [--major N]` — list known releases
- `macosdb show <version> [--component name]` — show components for a release
- `macosdb compare <v1> <v2> [--changed]` — diff components between releases
- `macosdb scan <ipsw> [--output dir] [--release-name name] [--release-date date] [--beta] [--beta-number N] [--update-index] [--verbose]` — scan an IPSW and produce release JSON

**Two build modes:**
- **Standalone** (`swift build`): uses `Sources/macosdb/MacOSdb.swift` with its own `@main`
- **Bundled in app** (Xcode): CLI sources are compiled into the app target; `EntryPoint.swift` dispatches based on `ProcessInfo.processName`; a `macosdb-tool` symlink in `Contents/MacOS/` invokes CLI mode

Note: the symlink is `macosdb-tool` (not `macosdb`) because macOS APFS is case-insensitive, so `macosdb` and `macOSdb` would collide.

### App (macOSdbApp)

SwiftUI app with NavigationSplitView (default window 1000×700):
- Sidebar: collapsible DisclosureGroup sections by major version (descending), beta badges, show/hide pre-releases toggle
- Detail: sortable component table, kernel info, chip/device support grouped by generation
- Compare view: side-by-side diff with color-coded summary badges
- AppState: uses `#filePath` to find local `data/` directory, falls back to GitHub raw URLs
- App is built by `macOSdb.xcodeproj`; macOSdbKit is added as a local SPM dependency
- Distribution: Developer ID signed and notarized, not sandboxed
- Category: Utilities (`public.app-category.utilities`)

### Site (site/)

Astro static site that presents release data on the web. Reads JSON from `data/` at build time. Pages: release index with pre-release filter toggle, per-release detail (`release/[slug]`), and compare view. Deployed to GitHub Pages via `deploy-site.yml`.

### Data format

- `data/releases.json` — index listing all releases with metadata, sorted newest first
- `data/releases/{major}/macOS-{version}-{build}.json` — per-release data with kernels and components arrays

macOS release names: 11=Big Sur, 12=Monterey, 13=Ventura, 14=Sonoma, 15=Sequoia, 26=Tahoe

## Code style and conventions

- SwiftLint with 60 opt-in rules (see `.swiftlint.yml`)
- Line length: warning at 150, error at 200
- Function body length: warning at 60, error at 100
- Swift 6 approachable concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `@MainActor` isolation on AppState (explicit for clarity)
- Structured concurrency: `async let` for parallel fetches
- Logging via `OSLog` (`Logger(subsystem: "io.linnane.macosdb", category: ...)`)
- Errors are `LocalizedError` with descriptive messages
- Swift Testing framework (`@Suite`, `@Test` macros)

## Build settings (Xcode target)

- Apple Silicon only (`ARCHS = arm64`, `EXCLUDED_ARCHS = x86_64`)
- Hardened runtime enabled, all runtime exceptions explicitly denied
- Dead code stripping enabled
- `ENABLE_APP_SANDBOX = NO` (requires filesystem access for IPSW scanning)

## CI workflows (.github/workflows/)

- **build.yml** — Test on PR with Thread Sanitizer and Address Sanitizer (parallel jobs, xcodebuild)
- **check.yml** — Unified PR checks: runs `just check` (lint, lint-json, test, audit, site format check, site build)
- **conventional-commits.yml** — Validate PR titles and commit messages match Conventional Commits format
- **codeql.yml** — CodeQL security analysis for Swift
- **zizmor.yml** — GitHub Actions security audit (SARIF output, uploaded to Security tab)
- **scan-ipsw.yml** — Self-hosted IPSW scanning workflow
- **deploy-site.yml** — Build and deploy Astro site to GitHub Pages
- **release.yml** — Manual dispatch: build, sign (Developer ID), notarize, create GitHub release with formatted notes and Sparkle appcast update

## Commit conventions

Conventional Commits format: `type(scope): description`

Common types: `feat`, `fix`, `refactor`, `docs`, `ci`, `chore`

All commits must:
- Use `git commit -s` for DCO sign-off
- Include a `Co-authored-by: Claude Opus 4.6 <noreply@anthropic.com>` trailer when authored with Claude

## Git workflow

- Never commit directly to main — always create a feature branch and open a PR
- Version bumps follow the pattern: bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.pbxproj`, commit as `chore: bump version to X.Y.Z (build N)`, open a PR
- Releases are cut by triggering the Release workflow dispatch after the version bump PR is merged — the workflow reads `MARKETING_VERSION` from the Xcode project and creates the tag automatically

## PR conventions

- PR descriptions should contain only a summary of the changes — no test plan sections, no bot attribution, no "Generated with Claude Code" footers
