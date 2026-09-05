# Architecture

macOSdb has four publication layers: the Swift scanner, the committed JSON corpus, the Swift CLI data provider, and the Astro/Cloudflare website. The JSON schema and release identity are the contract between them.

## Swift package

`macOSdbCore` contains models, comparison logic, data loading, and scanners. The `macosdb` executable target contains argument parsing, terminal presentation, output transactions, archive validation, and cleanup commands.

An IPSW scan proceeds through archive classification, bounded metadata and kernel extraction, AEA decryption when required, read-only DMG mounts, filesystem extraction, dyld-cache extraction, and release assembly. An XIP scan expands the signed archive with `/usr/bin/xip`, reads Xcode metadata, scans toolchain and framework binaries, parses SDK metadata and headers, and assembles an Xcode release.

Scanner workspaces have exact UUID-based names and a versioned live-process marker. Cleanup only acts on a recognized, stale workspace and rechecks it before an operation. Missing or malformed ownership evidence fails closed.

## Data contract

Each product has a `releases.json` index and one detail file per release. The index pointer is not a generic path: it is derived from product, version, and build, confined to the product directory, and bound to the same identity inside the detail JSON. The Python linter, Swift local data provider, and Astro loaders enforce the same rule.

The configured component set is complete for every published release. Empty or partial component collections, missing SDKs, and missing macOS kernels are publication errors. The limited device-map exceptions for early virtual-machine and Developer Transition Kit kernels are explicit in the linter.

See [Data schema](data-schema.md) for the public fields and invariants.

## Website and API

Astro prerenders release, component, and SDK pages from Zod-validated content collections. Compare pages and compare APIs execute in the Cloudflare Worker. Static responses receive headers from `site/public/_headers`; middleware applies the same security policy to Worker responses. A build-time drift check keeps those definitions synchronized.

The `/api/v1/` interface is public and unauthenticated. Release detail routes resolve only indexed canonical files and verify their internal identity before serving them.

## Trust boundaries

- Apple archives are untrusted parser input even when downloaded from an Apple host. Archive counts, metadata sizes, binary offsets, process duration, and captured output are bounded.
- Workflow-dispatch strings are untrusted. Values are validated before they become paths, environment-file records, or command arguments.
- AEA keys, download cookies, signing certificates, notarization passwords, and GitHub App keys are secrets. They are scoped to the smallest job, excluded from command tracing and logs, and removed after use unless an operator explicitly requests an AEA key sidecar.
- Generated artifacts are untrusted when crossing jobs. A hosted prepare job records the main-branch base and canonical release date; the hosted publisher accepts an exact regular-file layout, independently binds its identity and source metadata to the dispatch, reruns the data linter, and mints a write token only after verification.
- Hosted repository rules, environment approvals, runner isolation, DNS/TLS, Cloudflare configuration, Apple services, and GitHub permissions are external controls. Repository tests can verify their expected inputs and live deployment headers, but cannot prove the control-plane configuration.

## Failure and recovery

Release JSON and its index are prepared and written as one logical update. If the index write fails, the detail write is rolled back. Scanner publication uses the base commit recorded by the hosted prepare job. Release tags are immutable: a resumed release may reuse a tag only when it already points to the dispatched commit, and existing release assets must verify against their checksum and GitHub build provenance.

Operational runbooks are in [Operations](operations.md).
