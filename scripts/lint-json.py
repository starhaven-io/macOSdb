#!/usr/bin/env python3
"""Validate macOSdb JSON data files for schema correctness.

Checks per-release JSON files for required fields, filename consistency,
and ipswFile/ipswURL parity. Validates releases.json index completeness
and field parity with individual release files.

Usage:
    python3 scripts/lint-json.py
"""

import json
import re
import sys
from pathlib import Path

DATA = Path("data/macos/releases")
INDEX = Path("data/macos/releases.json")

REQUIRED_FIELDS = [
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "isDeviceSpecific", "ipswFile", "ipswURL",
    "components", "kernels",
]

INDEX_REQUIRED = [
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "isDeviceSpecific", "dataFile",
]

PARITY_FIELDS = [
    "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "isDeviceSpecific", "betaNumber", "rcNumber",
]

IPSW_FILE_RE = re.compile(r"UniversalMac_([\d.]+)_([A-Za-z0-9]+)_Restore\.ipsw$")

errors = 0


def error(msg):
    global errors
    errors += 1
    print(f"  ERROR: {msg}", file=sys.stderr)


def validate_releases(catalog):
    """Validate individual release JSON files."""
    for f in sorted(DATA.rglob("*.json")):
        parts = f.stem.split("-")
        if len(parts) < 3 or parts[0] != "macOS":
            continue

        build = parts[-1]
        filename_version = "-".join(parts[1:-1])

        try:
            d = json.loads(f.read_text())
        except json.JSONDecodeError as e:
            error(f"{f.name}: invalid JSON — {e}")
            continue

        catalog[build] = {"path": f, "data": d}

        missing = [field for field in REQUIRED_FIELDS if field not in d]
        if missing:
            error(f"{f.name}: missing fields: {', '.join(missing)}")
            continue

        if d["buildNumber"] != build:
            error(f"{f.name}: buildNumber '{d['buildNumber']}' doesn't match filename '{build}'")

        if d["osVersion"] != filename_version:
            error(f"{f.name}: osVersion '{d['osVersion']}' doesn't match filename '{filename_version}'")

        url = d["ipswURL"]
        if url:
            url_file = url.split("/")[-1]
            if d["ipswFile"] != url_file:
                error(f"{f.name}: ipswFile '{d['ipswFile']}' doesn't match URL filename '{url_file}'")

            m = IPSW_FILE_RE.search(url)
            if m:
                url_version, url_build = m.group(1), m.group(2)
                if url_build != build:
                    error(f"{f.name}: build in ipswURL '{url_build}' doesn't match '{build}'")
                if url_version != d["osVersion"]:
                    error(f"{f.name}: version in ipswURL '{url_version}' doesn't match '{d['osVersion']}'")


def validate_index(catalog):
    """Validate releases.json index against individual release files."""
    if not INDEX.exists():
        error(f"{INDEX} not found")
        return

    try:
        index_entries = json.loads(INDEX.read_text())
    except json.JSONDecodeError as e:
        error(f"releases.json: invalid JSON — {e}")
        return

    index_builds = {}
    for entry in index_entries:
        b = entry.get("buildNumber", "")
        index_builds[b] = entry

        missing = [field for field in INDEX_REQUIRED if field not in entry]
        if missing:
            error(f"index/{b}: missing fields: {', '.join(missing)}")

        data_file = entry.get("dataFile", "")
        if data_file and not (DATA.parent / data_file).exists():
            error(f"index/{b}: dataFile '{data_file}' does not exist")

    catalog_builds = set(catalog.keys())
    index_build_set = set(index_builds.keys())

    for build in sorted(catalog_builds - index_build_set):
        error(f"{build}: in {DATA} but missing from releases.json")
    for build in sorted(index_build_set - catalog_builds):
        error(f"{build}: in releases.json but no matching JSON file")

    for build in catalog_builds & index_build_set:
        release = catalog[build]["data"]
        idx = index_builds[build]
        for field in PARITY_FIELDS:
            if idx.get(field) != release.get(field):
                error(f"index/{build}: {field} mismatch — "
                      f"index={idx.get(field)!r}, file={release.get(field)!r}")


def main():
    if not DATA.exists():
        print(f"ERROR: {DATA} not found. Run from repo root.", file=sys.stderr)
        sys.exit(1)

    catalog = {}
    validate_releases(catalog)
    validate_index(catalog)

    total = len(catalog)
    if errors:
        print(f"\n{errors} error(s) in {total} release files", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"OK: {total} release files validated")


if __name__ == "__main__":
    main()
