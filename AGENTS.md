# Agent Instructions for macOSdb

These instructions apply to the whole repository. macOSdb scans Apple IPSW and
XIP archives into a generated component catalog, exposes it through a Swift CLI,
and publishes an Astro/Cloudflare site and API.

## Start here

- Inspect the branch, status, and existing diff before editing. Preserve unrelated work.
- Read [Architecture](docs/architecture.md) for the data flow and trust boundaries,
  [Data schema](docs/data-schema.md) for publication invariants, and
  [Operations](docs/operations.md) for scanner, release, and recovery procedures.
- `Sources/macOSdbCore/` owns models, data loading, comparison, and scanning;
  `Sources/macosdb/` owns CLI presentation and output transactions. `site/` owns
  Astro components, API routes, schemas, deployment configuration, and site tests.
- The estate fleet owns rendered whole files and `fleet:block` fragments.
  Change their canonical source in `dot_github/fleet`, then use its release/sync
  process. Preserve consumer content byte-for-byte until that process updates it.
  `CLAUDE.md` remains exactly `@AGENTS.md`.

## Development and checks

Native scanner development requires Apple silicon, macOS 15 or newer, and the
Swift 6.2 toolchain. The site uses Node.js 26. Python 3 and the lint/analysis tools
listed in [Contributing](CONTRIBUTING.md) are required by the complete gate.

Use focused recipes in `justfile` while iterating, then run `just check` on the
stable patch. It includes Swift tests and analysis, generated-data and Python
script tests, site dependency policy, formatting, type checking, unit
tests, build, deployment dry-run, and link checks. Missing tools fail the gate;
report them as unverified. Run `git diff --check` and inspect the final status.
Do not repeat expensive checks when the relevant source and evidence are unchanged.

- Swift uses Swift Testing, strict SwiftLint, structured concurrency, and OSLog.
  Preserve actor isolation and propagate cancellation through cleanup scopes.
- Keep the numeric/alphabetic comparison and release ordering contracts aligned
  across Swift, TypeScript, and Python using the shared ordering fixtures.
- Keep device identities in the Swift registry and site map aligned. Retain
  explicit chip-family grouping decisions and cover changed mappings with tests.
- Site install-script decisions belong in `site/package.json`; the fleet owns
  the checker and fenced recipe. Keep the lock and policy aligned, use
  `npm ci --strict-allow-scripts`, and avoid unrelated dependency churn.
- `just check` is local evidence. Real Apple archive scans, hosted sanitizer and
  CodeQL jobs, signing/notarization, and live deployment checks need separate
  evidence when relevant; do not imply they ran from local unit tests.

## Data and scanner boundaries

- `data/` release JSON and indexes are generated. Fix the scanner or validation
  source, then use the scanner workflow to regenerate data. Do not hand-edit the
  corpus. Code is AGPL-3.0-only; release data is CC-BY-4.0.
- `ScannerConfig.swift` and Xcode extraction code define tracked components.
  Changes to the required set require a coordinated corpus migration and updates
  to the Python linter, Swift validator, Astro schema, tests, and documentation.
- Preserve historical test fixtures that exercise compatibility with older data;
  removing an obsolete emitted field does not require deleting that evidence.
- Treat archives, binaries, plists, JSON, and workflow inputs as untrusted.
  Preserve bounded reads, offset checks, path confinement, descriptor identity,
  trusted system-tool paths, subprocess timeouts, and output limits. Never execute
  a binary extracted from an archive to discover its version.
- Cleanup may affect only recognized stale workspaces and mounts. Preserve the
  live-process marker and repeated ownership checks; never broaden it to arbitrary
  temporary directories.
- `scan --update-index` requires the canonical product `releases` output directory
  and complete source metadata. Local experiments should use a temporary output
  directory and omit `--update-index` unless testing a complete product catalog.
- Keep archives, AEA keys, download cookies, signing material, and local environment
  files out of Git and logs. AEA WKMS 404s intentionally require a fresh dispatch.

## Automation and publication

Scanner, release, and production deployment dispatches run from `main`.
Self-hosted scanner jobs must remain isolated from pull-request execution;
verify the runner group's allowed workflow/ref restriction in GitHub. A shell
branch guard is an early error check, not protection against modified workflow
code. Hosted environment branch restrictions and least-privilege credentials
provide the privilege boundary without requiring another human approver.

Keep top-level workflow permissions empty, actions SHA-pinned, and checkout
credentials nonpersistent. Scanner publication must keep its separate hosted
prepare and publisher jobs, exact artifact layout, dispatch/source identity
checks, recorded base commit, and token minting after validation. Preserve the
always-reporting `conclusion` job required for pull requests.

Release version ownership and retry rules are in [Operations](docs/operations.md).
Preserve signing, online notarization verification, immutable tags, checksum and
provenance checks, and the separate Homebrew cask-bump delivery step. Never
publish, dispatch, deploy, commit, push, or change hosted controls unless the
user has authorized that action.

<!-- fleet:block commit-and-pr-conventions -->

## Commit and PR conventions

- Conventional Commits: `type(scope): description`. Valid types: `feat`,
  `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`.
  Mark a breaking change with `!` before the colon (`feat!:`,
  `feat(scope)!:`).
- Commits require DCO sign-off. Make all commits with `git commit -s` (enforced
  by the `.githooks/commit-msg` hook; run `just install-hooks` once per clone).
- Do not identify an AI tool or model as an author, co-author, committer, or
  signatory of a commit. Do not name an AI tool or model in `Co-authored-by`,
  `Assisted-by`, `Co-developed-by`, `Generated-by`, or similar trailers. Human
  `Co-authored-by` trailers are allowed.
- Never commit directly to `main`; create a feature branch and open a PR.
- PR descriptions should contain a concise summary of changes. Do not add a
  standalone test-plan section or checklists.
- When AI/LLM was used to generate or assist with a pull request, the initial
  PR description must end with exactly one unformatted line as the last line of
  the PR body: `AI disclosure: <model> with <how the output was verified>.`
  This is PR body text, not a commit trailer. Omit the line when no AI/LLM was
  used.
- Name the model as its vendor names it, for example `Claude Opus 5`. Do not
  also name a tool or harness unless the harness is the only identifier. Do not
  describe what the AI did.
- Do not format the disclosure as a heading, bullet, bold label, or horizontal
  rule, and do not add a promotional "generated with" footer.
- Keep each prose paragraph in a PR description on one source line. Do not
  hard-wrap PR body prose like a commit message; preserve intentional Markdown
  line breaks in lists, code blocks, and other structured content.
- Comments must earn their keep: a comment states a constraint or rationale the
  code cannot express. Never add comments that narrate what the code does,
  restate names, or explain a change to its reviewer.

<!-- fleet:end -->
