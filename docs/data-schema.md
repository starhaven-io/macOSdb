# Data schema

The committed corpus lives under `data/{macos,xcode}` and is licensed under CC-BY-4.0. JSON is the stable interchange format for the CLI, website, and `/api/v1/` endpoints.

## Release index

`data/{product}/releases.json` is an array sorted newest first. Every entry contains:

- `productType`: `macOS` or `Xcode`
- `osVersion`: `major.minor` or `major.minor.patch`
- `buildNumber`: the Apple build identifier
- `releaseName` and ISO `releaseDate`
- boolean `isBeta` and `isRC`
- `dataFile`: the canonical detail pointer

macOS entries also contain `isDeviceSpecific`. Prereleases may contain `betaNumber`, `betaRevision`, or `rcNumber` when applicable.

The pointer must be exactly `releases/{major}/{macOS|Xcode}-{osVersion}-{buildNumber}.json`. It must resolve to a regular file inside the same product directory, and that file must carry the same product, version, and build. Aliases, traversal, escaping symlinks, pointer swaps, and duplicate builds are invalid.

## Release detail

Every detail object repeats the index identity and flags and contains a non-empty `components` array. Each component has non-empty `name`, `version`, `path`, and `source` fields. macOS sources are `filesystem` or `dyldCache`; Xcode sources are `filesystem` or `sdk`.

macOS details also require:

- `isDeviceSpecific`
- `ipswFile` and an Apple HTTPS `ipswURL`
- a non-empty `kernels` array with `file`, `arch`, `chip`, `darwinVersion`, `xnuVersion`, and `devices`

Xcode details also require:

- `xipFile` and an Apple HTTPS `xipURL`
- `minimumOSVersion`
- a non-empty `sdks` array whose entries contain `sdkVersion` and `buildVersion`

The authoritative field and completeness checks are implemented in `scripts/lint-json.py`; Astro applies an additional Zod schema when building the site.

## Compatibility

Adding an optional field is backward-compatible. Removing or renaming a field, changing its type, changing component names, or making an optional field required changes the public contract and requires coordinated CLI, linter, website, API documentation, and corpus updates. Such a breaking API change belongs in a new API version rather than silently changing `/api/v1/`.

Generated files are not edited by hand. See [Contributing](../CONTRIBUTING.md#release-data) and [Operations](operations.md) for the publication flow.
