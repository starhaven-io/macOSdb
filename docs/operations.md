# Operations

## Scanner publication

The `Scan IPSW` and `Scan XIP` workflows are manual, self-hosted operations. A run validates dispatch metadata, downloads or reuses the archive, verifies its format, scans it, validates the complete corpus, and packages exactly one detail file plus the updated index. A separate hosted job accepts only that artifact layout, validates it again, then mints a short-lived GitHub App token and opens a signed data pull request.

The XIP archive cache is persistent and immutable after validation. A cached file whose date, format, checksum, or identity disagrees with the dispatch is an error, not an automatic replacement. AEA WKMS 404 responses intentionally require a fresh dispatch.

Dispatch only from `main`, after verifying the Apple source URL, product version, build number, release date, and prerelease flags. Auto-merge relies on the independent hosted artifact validation and required CI checks. Inspect the resulting data diff and completed run when investigating unexpected catalog changes.

### Accepted archive download risk

The repository maintainer accepts the two LOW Pinprick runtime-fetch findings in the `Download IPSW` and `Download XIP` steps, reviewed on 2026-09-10. Fleet canon in [`fleet/repos/macOSdb.yml`](https://github.com/starhaven-io/.github/blob/main/fleet/repos/macOSdb.yml) owns the complete generated `.pinprick.toml`; changes require hub review and release/sync. The required fleet guard rejects consumer edits to this policy. `.pinprick.toml` binds each acceptance to its exact logical curl command, finding identity, and complete workflow SHA-256. This is an explicit risk acceptance, not a claim that IPSW or XIP archives cannot contain executable code. Any workflow change invalidates the acceptance and requires review before updating its digest. Reassess after changes to runner isolation, Apple URL validation, archive paths, download options, archive validation, or scanner execution behavior; remove the acceptance if independently anchored publisher verification becomes available and can be enforced.

The scanner needs runtime-selected Apple releases and persistent per-version `.part` paths for resumable downloads. IPSW input validation restricts the source to HTTPS on `updates.cdn-apple.com` and a version/build filename; redirects remain HTTPS but are not host-restricted. XIP derives its CDN URL from a validated path under `adcdownload.apple.com`, does not follow redirects, and sends its ADC cookie only to that source. Both workflows reject archive-path symlinks, wait for curl to succeed before renaming the partial file, check archive size and format, and pass archives to the scanner as untrusted input. The scanner does not execute extracted binaries to discover their versions; XIP expansion uses Apple's system `xip` tool and propagates failure.

Residual risks include trusting Apple's delivery service and TLS, archive-parser defects, and the integrity of the self-hosted scanner environment. Locally created SHA-256 sidecars detect later cache changes; they do not independently authenticate the original download. Repository code does not prove hosted runner-group or environment protections. No global host, extension, action, severity, or rule exemption is used, and incomplete audit coverage remains fatal.

CI, scheduled, and local link checks resolve this site's production origin against the built site, because new data PRs create pages that do not exist in production yet. The 404 route resolves to its generated HTML file; missing built pages still fail. External online links retain their existing checks.

## CLI release

1. Change `MacosdbVersion.current` in `Sources/macosdb/Version.swift` on a feature branch.
2. Open and merge a signed `chore: bump version to X.Y.Z` pull request.
3. Dispatch the Release workflow from `main`.

The workflow builds before loading signing credentials, imports the Developer ID certificate into an isolated keychain, signs and notarizes the binary, verifies its signature and notarization ticket online, creates a tarball and SHA-256 sidecar, and generates build provenance. It creates an immutable version tag, creates or resumes the GitHub release, and opens a Homebrew cask bump.

The cask publisher adds the commit author's DCO sign-off before Git creates the commit, without disabling existing hooks. If hook preparation stops the bump, inspect the preexisting `prepare-commit-msg` hook or inherited `core.hooksPath`; the workflow preserves both and refuses hook locations outside the fresh tap checkout.

A retry is safe only when the existing tag points to the dispatched commit. Existing archive and checksum assets are reused only as a complete pair after checksum and build-provenance verification. A tag at any other commit or a partial asset pair requires investigation; do not delete or move published release state.

## Website deployment

Changes under `site/` or `data/`, or to the deployment workflow and its validation scripts, deploy from `main` to Cloudflare Workers. Manual production dispatches fail outside `main`. Rejected dispatches use separate concurrency groups so they cannot cancel production work. CI checks the install-script policy before a clean dependency install, then runs formatting and type checks, unit tests, production build, and deployment dry-run. The production workflow revalidates the release corpus, repeats the clean install and build, and verifies the live security headers after publishing.

Dependency vulnerability monitoring runs through Dependabot alerts and security updates. Full-tree vulnerability audits are kept out of CI and deployment gates so new advisories cannot block publishing an unchanged lockfile. Run `npm --prefix site run audit` when investigating dependency findings.

Repository automation assumes that GitHub environments restrict scanner, release, and Cloudflare secrets to the `main` branch; self-hosted scanner runners are isolated, patched, and restricted to the scanner workflows at `refs/heads/main`; `main` requires the aggregate CI conclusion; and tag/release mutation is limited to the release workflow. These are control-plane settings and should be audited in GitHub and Cloudflare after changing administrators, apps, runner groups, or environments.

## Local recovery

`macosdb cleanup` lists recognized stale scanner mounts and workspaces. Inspect the dry-run, then use `macosdb cleanup --force`. Unrecognized directories and live markers are deliberately preserved. Cleanup stops if mount discovery fails or a scanner mount cannot be detached; removal failures return a nonzero exit status. Never substitute a broad manual `rm -rf` over the system temporary directory.
