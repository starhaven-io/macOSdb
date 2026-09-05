# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately by emailing
[security@macosdb.com](mailto:security@macosdb.com) or using
[GitHub's private vulnerability reporting](https://github.com/starhaven-io/macOSdb/security/advisories/new).
Do not open a public issue for an undisclosed vulnerability.

Include the affected component, version, or commit; reproduction steps; potential impact; and any suggested mitigation. Avoid sending archive credentials, signing material, private Apple downloads, or unrelated personal data. We will acknowledge the report, investigate it, and coordinate disclosure with you.

## Supported versions

The latest released CLI, the deployed website and API, and the current `main` branch are supported. Older CLI versions and third-party deployments are not maintained with security fixes.

## Scope

Security-sensitive areas include untrusted archive parsing, filesystem and process boundaries, generated release data, the public API, GitHub Actions, signing and notarization, and supply-chain configuration. Vulnerabilities in Apple, GitHub, Cloudflare, or other upstream services should normally be reported to that provider unless macOSdb's integration creates the exposure.

Public release data is not confidential. Incorrect data that does not create a security impact can be reported through a normal GitHub issue.
