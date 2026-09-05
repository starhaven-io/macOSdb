# Operations

## Scanner publication

The `Scan IPSW` and `Scan XIP` workflows are manual, self-hosted operations. A run validates dispatch metadata, downloads or reuses the archive, verifies its format, scans it, validates the complete corpus, and packages exactly one detail file plus the updated index. A separate hosted job accepts only that artifact layout, validates it again, then mints a short-lived GitHub App token and opens a signed data pull request.

The XIP archive cache is persistent and immutable after validation. A cached file whose date, format, checksum, or identity disagrees with the dispatch is an error, not an automatic replacement. AEA WKMS 404 responses intentionally require a fresh dispatch.

Before dispatching, verify the Apple source URL, product version, build number, release date, and prerelease flags. Review the generated pull request and CI result even when auto-merge is enabled.

## CLI release

1. Change `MacosdbVersion.current` in `Sources/macosdb/Version.swift` on a feature branch.
2. Open and merge a signed `chore: bump version to X.Y.Z` pull request.
3. Dispatch the Release workflow from `main`.

The workflow builds before loading signing credentials, imports the Developer ID certificate into an isolated keychain, signs and notarizes the binary, verifies its signature and notarization ticket online, creates a tarball and SHA-256 sidecar, and generates build provenance. It creates an immutable version tag, creates or resumes the GitHub release, and opens a Homebrew cask bump.

A retry is safe only when the existing tag points to the dispatched commit. Existing archive and checksum assets are reused only as a complete pair after checksum and build-provenance verification. A tag at any other commit or a partial asset pair requires investigation; do not delete or move published release state.

## Website deployment

Changes under `site/` or `data/` deploy from `main` to Cloudflare Workers. Manual production dispatches also fail outside `main`. CI first performs a clean dependency install, install-script policy check, vulnerability audit, formatting and type checks, unit tests, production build, and deployment dry-run. The production workflow revalidates the release corpus, repeats the clean install and build, and verifies the live security headers after publishing.

Repository automation assumes that GitHub environments protect scanner, release, and Cloudflare secrets; self-hosted scanner runners are isolated and patched; `main` requires the aggregate CI conclusion; and tag/release mutation is limited to the release workflow. These are control-plane settings and should be audited in GitHub and Cloudflare after changing administrators, apps, runner groups, or environments.

## Local recovery

`macosdb cleanup` lists recognized stale scanner mounts and workspaces. Inspect the dry-run, then use `macosdb cleanup --force`. Unrecognized directories and live markers are deliberately preserved. Never substitute a broad manual `rm -rf` over the system temporary directory.
