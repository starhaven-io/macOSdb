# macOSdb — Claude Project Context

macOSdb is a native macOS app and CLI that catalogs which versions of open-source components (curl, OpenSSH, SQLite, etc.) ship with each macOS and Xcode release. It scans Apple's IPSW firmware files and Xcode `.xip` archives, extracts version strings from binaries, the dyld shared cache, and SDK headers, and stores the results as JSON. The app lets you browse releases, compare component versions across releases, and see which chip families and devices each release supports.

## Project overview

- **Platform:** macOS 15.0+ (Apple Silicon only)
- **Language:** Swift 6.2, SwiftUI (100%)
- **Architecture:** MVVM using `@Observable` and SwiftUI Environment injection
- **Structure:** Xcode project (app + bundled CLI) + Swift Package (library, standalone CLI, tests)
- **Bundle ID:** `io.linnane.macosdb`
- **License:** AGPL-3.0-only (code), CC-BY-4.0 (data)
- **Dependencies:** swift-argument-parser (CLI), ZIPFoundation (IPSW extraction), Sparkle (app auto-update, Xcode project only)
- **Website:** https://macosdb.com (Astro site on Cloudflare Workers — static pages + SSR API)

## Repository structure

```
macOSdb/
├── macOSdb.xcodeproj/                     # Xcode project (builds app target with bundled CLI)
├── Package.swift                          # SPM: macOSdbKit lib + standalone macosdb CLI
├── Sources/
│   ├── macOSdbKit/                        # Shared library (consumed by CLI and app)
│   │   ├── Models/                        # ChipFamily, Component, DeviceRegistry, KernelInfo, ProductType, Release, SDKInfo, VersionComparison
│   │   ├── Scanner/                       # IPSW/Xcode scanning pipeline (see Architecture)
│   │   ├── DataProvider.swift             # Actor: fetch release JSON from HTTPS or local files
│   │   └── VersionComparer.swift          # Diff components across releases
│   └── macosdb/                           # CLI (swift-argument-parser): Cleanup, Compare, Completions,
│                                          #   List, Scan, Show, Validate + Utilities, MacOSdb (@main)
├── macOSdbApp/                            # SwiftUI app sources (built by the Xcode project)
│   ├── Bootstrap/EntryPoint.swift         # @main — dispatches to app or CLI by ProcessInfo.processName
│   ├── macOSdbApp.swift                   # App struct (no @main — entry point is in Bootstrap/)
│   ├── Models/AppState.swift              # @Observable @MainActor state container
│   ├── Views/                             # ContentView, SidebarView, ReleaseDetailView,
│   │                                      #   ComponentDetailView, CompareView, ChipSupportView, SDKDetailView
│   ├── Info.plist                         # SUFeedURL, hardened-runtime, category
│   └── Resources/Assets.xcassets/         # App icon, accent color
├── site/                                  # Astro site (macosdb.com)
│   ├── src/
│   │   ├── pages/                         # index, {macos,xcode}/release/[slug], compare, components,
│   │   │   │                              #   component/[name], sdk/[version], og/[slug].png, robots, security.txt
│   │   │   └── api/v1/{macos,xcode}/      # JSON API endpoints (releases, components, compare)
│   │   ├── components/                    # Badge, ChipGrid, ComparePage, ComponentTable, KernelInfo,
│   │   │   │                              #   ProductCompare, ProductComponentDetail, ProductComponents,
│   │   │   │                              #   ProductIndex, ProductReleases, ReleaseHeader, StructuredData
│   │   ├── layouts/Base.astro
│   │   ├── lib/                           # api.ts, deviceNames.ts, products.ts, utils.ts
│   │   ├── middleware.ts                  # Re-applies _headers security headers to SSR responses
│   │   ├── content.config.ts             # Zod-validated content collections
│   │   └── styles/global.css
│   ├── public/_headers                    # Cloudflare static-asset headers (CSP etc.)
│   ├── astro.config.mjs · wrangler.jsonc · package.json
├── Tests/
│   ├── macOSdbKitTests/                   # Swift Testing — library (+ Fixtures/ sample JSON)
│   └── macosdbTests/                      # Swift Testing — CLI (parsing + subprocess smoke tests)
├── data/                                  # Pre-built JSON (committed, CC-BY-4.0) — see "do not touch"
│   ├── LICENSE                            # CC-BY-4.0
│   ├── macos/  └ releases.json + releases/{major}/macOS-{version}-{build}.json
│   └── xcode/  └ releases.json + releases/{major}/Xcode-{version}-{build}.json
├── scripts/                              # format-release-notes.py, lint-json.py, xcresult-to-junit.py
├── justfile                             # Task runner (see "Common commands")
├── .github/
│   ├── workflows/                        # ci, codeql, zizmor, pinprick-audit, scan-ipsw, scan-xip,
│   │                                     #   link-check, deploy-site, release
│   ├── appcast-template.xml              # Sparkle appcast template
│   ├── dependabot.yml                    # github-actions + npm (site) + swift, grouped, 7-day cooldown
│   └── FUNDING.yml
├── LICENSE                              # AGPL-3.0-only
├── .swiftlint.yml · .periphery.yml · _typos.toml · lychee.toml · .mcp.json · .gitignore
```

## Architecture details

### macOSdbKit (shared library)

**Models:** `ChipFamily`, `Component`, `ComponentChange`, `DeviceRegistry`, `KernelInfo`, `ProductType`, `Release`, `SDKInfo`, `VersionComparison`

**DataProvider:** Actor that fetches release data from HTTPS (`macosdb.com/api/v1/`) or a local `data/` directory. Configurable base URL for dev/testing; per-release fetch failures are isolated so one bad file doesn't sink the whole load.

**VersionComparer:** Static methods to diff components between two releases (parses versions into `[Int]`, so `15.10 > 15.2`).

**Scanner pipeline** (IPSW, 6 phases):
1. Extract IPSW (ZIP) → temp directory with kernelcaches and DMG files
2. Parse kernelcaches → `[KernelInfo]` with BuildManifest device mapping and per-device chip resolution
3. Decrypt AEA images if needed (macOS 15+, fetches keys from Apple WKMS)
4. Mount system DMG → extract filesystem components (version strings from binaries)
5. Mount cryptex DMG (macOS 13+) or use system DMG → extract dyld cache components
6. Assemble and return `Release` with resolved name and auto-detected beta status

**Scanner components:**
- `IPSWScanner` — IPSW pipeline orchestrator (public actor)
- `XcodeScanner` — `.xip` pipeline; expands via `/usr/bin/xip`, scans toolchain/framework/SDK
- `IPSWExtractor` — ZIP extraction, BuildManifest/Restore.plist parsing
- `KernelParser` — kernelcache parsing → KernelInfo
- `AEADecryptor` — AEA decryption (fetches HPKE key from Apple WKMS, shells out to `/usr/bin/aea`)
- `IM4PDecoder` — IM4P container decoding (LZFSE/LZMA decompression, 128 MB cap)
- `DMGMounter` — DMG mount/unmount via `hdiutil`
- `DyldCacheExtractor` — extract dylibs from dyld_shared_cache (handles split subcaches)
- `ComponentExtractor` — version extraction (regex or integer-decode strategy)
- `BinaryStringScanner` — raw printable-string scan (Swift `Regex`, falls back to `NSRegularExpression` for lookbehind)
- `SDKMetadataParser` — parse SDK headers, `.tbd` files, and metadata
- `ScannerConfig` — component definitions (filesystem, dyld cache, toolchain, framework, SDK)
- `ScannerError` — scanner error types

### Tracked components (ground truth: `ScannerConfig.swift` / `XcodeScanner.swift`)

- **macOS filesystem:** curl, httpd, LibreSSL, OpenSSH, Ruby, sudo, SQLite, vim, zsh
- **macOS dyld cache:** libbz2, libcurl, libexpat, libncurses, libpcap, libsqlite3, libssl, libxml2
- **Xcode toolchain/frameworks:** Apple Clang, cctools, Git, ld, lldb, Python, Swift
- **Xcode SDK:** bzip2, expat, libcurl, libexslt, libffi, libxml2, libxslt, ncurses, sqlite3, zlib

### CLI (macosdb)

Built with swift-argument-parser. Subcommands:
- `list [--major N] [--product macos|xcode] [--json]` — list known releases
- `show <version> [--component name] [--detailed] [--product] [--json]` — show a release's components
- `compare <v1> <v2> [--changed] [--product] [--json]` — diff components between releases
- `scan <archive> [--output dir] [--release-name] [--release-date] [--beta|--beta-number N] [--rc|--rc-number N] [--device-specific] [--ipsw-url|--xip-url URL] [--save-aea-key] [--aea-key path] [--key-only] [--update-index] [--verbose]` — scan an IPSW or `.xip` → release JSON
- `validate <paths...> [--dir path] [--rehash]` — create SHA-256 sidecars, or verify against existing ones
- `cleanup [--force]` — unmount stale scan DMGs and delete leftover temp dirs (dry-run by default)
- `completions <zsh|bash|fish>` — emit shell completions

**Two build modes:**
- **Standalone** (`swift build`): `Sources/macosdb/MacOSdb.swift` carries `@main`.
- **Bundled in app** (Xcode): CLI sources compile into the app target; `EntryPoint.swift` dispatches on `ProcessInfo.processName`; a `macosdb-tool` symlink in `Contents/MacOS/` invokes CLI mode. The subcommand list is declared in **both** `MacOSdb.swift` (SPM) and `EntryPoint.swift` (app) — keep them in sync.

### App (macOSdbApp)

SwiftUI `NavigationSplitView` app:
- Sidebar: product + mode (Releases / Components / SDKs) pickers, collapsible major-version groups, pre-release and device-specific toggles.
- Detail: sortable component table, kernel info, chip/device support; side-by-side compare with color-coded changes.
- `AppState` (`@Observable @MainActor`): in **DEBUG** builds prefers the repo's local `data/` dir (via `#filePath`); release builds always use `macosdb.com/api/v1/`.
- Distribution: Developer ID signed + notarized, Sparkle auto-updates (appcast on the `appcast` branch, `SUFeedURL` in `Info.plist`), not sandboxed (needs filesystem access to scan).

### Site (site/)

Astro site at [macosdb.com](https://macosdb.com), deployed to Cloudflare Workers via `deploy-site.yml` (`@astrojs/cloudflare` + `wrangler deploy`). Most pages are prerendered from `data/` via Zod-validated content collections; the compare pages and compare API are SSR (`prerender = false`). `src/middleware.ts` re-applies the `public/_headers` security headers to SSR responses (static assets get them from `_headers` directly). The `/api/v1/` endpoints mirror the `data/` layout for both products.

### Data format

- `data/{product}/releases.json` — index of all releases, sorted newest first.
- `data/{product}/releases/{major}/{Prefix}-{version}-{build}.json` — per-release data.
- Product dirs: `macos`, `xcode`. File prefixes: `macOS`, `Xcode`.
- macOS release names: 11=Big Sur, 12=Monterey, 13=Ventura, 14=Sonoma, 15=Sequoia, 26=Tahoe, 27=Golden Gate.

## Common commands

```
just build / just test          # swift build / swift test (library + CLI)
just lint                       # swiftlint --strict
just lint-json                  # python3 scripts/lint-json.py (data schema validation)
just typos                      # typos
just audit                      # zizmor --persona auditor .github/workflows/
just periphery                  # unused-code scan (local only; not in CI)
just build-app / just test-xcode# xcodebuild app build / tests (matches CI)
just check                      # lint, lint-json, typos, audit, periphery, swift test, site format + build
just site-dev / site-build      # Astro dev server / production build (in site/)
just lychee                     # broken-link check on the built site
```

Run `just check` (or at minimum `just lint && just test`) before pushing — CI is not a substitute. The app target only builds via `xcodebuild`/`just build-app`, not `swift build`.

## Code style and conventions

- SwiftLint with ~55 opt-in rules (`.swiftlint.yml`); line length warn 150 / error 200; function body warn 60 / error 100; type body 300.
- Swift 6 approachable concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- Logging via `OSLog` (`Logger(subsystem: "io.linnane.macosdb", category: ...)`).
- Errors are `LocalizedError` with descriptive messages.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`/`#require`). CI runs them under Thread + Address sanitizers.

## Build settings (Xcode target)

- Apple Silicon only (`ARCHS = arm64`, `EXCLUDED_ARCHS = x86_64`).
- Hardened runtime enabled; all runtime exceptions explicitly denied.
- Dead-code stripping enabled. `ENABLE_APP_SANDBOX = NO` (needs filesystem access for scanning).

## CI workflows (.github/workflows/)

- **ci.yml** — unified PR checks via a dynamic matrix keyed on changed paths: Conventional Commits, SwiftLint + typos, TSan + ASan tests (+ Codecov), CodeQL, lint-json, site format-check + build, zizmor.
- **codeql.yml** — scheduled CodeQL analysis (Swift).
- **zizmor.yml** — scheduled GitHub Actions security audit (SARIF → Security tab).
- **pinprick-audit.yml** — scheduled dependency/supply-chain audit.
- **scan-ipsw.yml / scan-xip.yml** — self-hosted, dispatch-only scanners; download an archive, scan it, open + auto-merge a `data/` PR with a signed commit.
- **link-check.yml** — scheduled lychee broken-link check.
- **deploy-site.yml** — build + deploy the Astro site to Cloudflare Workers.
- **release.yml** — manual dispatch: build, sign (Developer ID), notarize, GitHub release with formatted notes, Sparkle appcast update, Homebrew cask bump.

Baseline security posture is intentional: top-level `permissions: {}`, SHA-pinned actions, `persist-credentials: false`, scoped GitHub App tokens, signed GraphQL commits. Keep it that way.

## Gotchas / do-not-touch

- **`data/` is generated** by the scan workflows, not hand-edited. Don't manually add/edit release JSON; `data/LICENSE` is CC-BY-4.0 (different from the AGPL code). `just lint-json` validates the schema.
- **CLI symlink** is `macosdb-tool`, not `macosdb` — APFS is case-insensitive, so `macosdb`/`macOSdb` would collide.
- **Subcommand list is duplicated** in `MacOSdb.swift` and `EntryPoint.swift`; add new subcommands to both.
- **Scanner inputs are untrusted binaries.** Parsers in `Scanner/` (esp. `DyldCacheExtractor`) bounds-check every offset/length read from the archive; preserve those guards when editing.
- **AEA WKMS 404s have no retry by design** — manual re-dispatch is the chosen fallback.
- The `appcast.xml` lives on the `appcast` branch (orphan), not `main`.

## Commit conventions

- Conventional Commits: `type(scope): description` (types: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `style`).
- Sign off every commit with `git commit -s` for DCO (enforced by the `.githooks/commit-msg` hook — run `just install-hooks` once per clone to enable it).
- Add a `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer when authored with Claude, placed after `Signed-off-by`. Bump the model version as newer ones ship.

## Git workflow

- Never commit directly to `main` — branch and open a PR.
- Version bumps: bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.pbxproj`, commit as `chore: bump version to X.Y.Z (build N)`, open a PR.
- Releases: trigger the Release workflow dispatch after the bump PR merges; it reads `MARKETING_VERSION` and creates the tag automatically.

## PR conventions

- PR descriptions are a summary of the changes only — no test-plan sections, no bot attribution, no "Generated with Claude Code" footers.
