#!/usr/bin/env python3
"""Validate macOSdb JSON data files for schema correctness.

Checks per-release JSON files for required fields, type correctness,
filename consistency, and file/URL parity. Validates releases.json
index completeness, field parity, and sort order.

Supports both macOS and Xcode data.

Usage:
    python3 scripts/lint-json.py
"""

import functools
import json
import re
import sys
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# Product configurations
# ---------------------------------------------------------------------------

SHARED_REQUIRED = [
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "isDeviceSpecific", "productType", "components",
]

MACOS_REQUIRED = SHARED_REQUIRED + ["ipswFile", "ipswURL", "kernels"]
XCODE_REQUIRED = SHARED_REQUIRED + ["xipFile", "minimumOSVersion", "sdks", "kernels"]

MACOS_ALLOWED = {
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "productType", "isBeta", "isRC", "isDeviceSpecific",
    "ipswFile", "ipswURL", "betaNumber", "rcNumber",
    "components", "kernels",
}
XCODE_ALLOWED = {
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "productType", "isBeta", "isRC", "isDeviceSpecific",
    "xipFile", "xipURL", "minimumOSVersion", "sdks",
    "betaNumber", "rcNumber", "components", "kernels",
}

INDEX_REQUIRED = [
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "isDeviceSpecific", "productType", "dataFile",
]

PARITY_FIELDS = [
    "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "isDeviceSpecific", "productType",
    "betaNumber", "rcNumber",
]

BOOL_FIELDS = ["isBeta", "isRC", "isDeviceSpecific"]
COMPONENT_REQUIRED = ["name", "version", "path", "source"]

IPSW_FILE_RE = re.compile(r"UniversalMac_([\d.]+)_([A-Za-z0-9]+)_Restore\.ipsw$")
VERSION_RE = re.compile(r"^\d+\.\d+(\.\d+)?$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TODAY = date.today()

PRODUCTS = [
    {
        "name": "macOS",
        "prefix": "macOS",
        "data": Path("data/macos/releases"),
        "index": Path("data/macos/releases.json"),
        "required": MACOS_REQUIRED,
        "allowed": MACOS_ALLOWED,
        "component_sources": {"filesystem", "dyldCache"},
        "expect_kernels": True,
    },
    {
        "name": "Xcode",
        "prefix": "Xcode",
        "data": Path("data/xcode/releases"),
        "index": Path("data/xcode/releases.json"),
        "required": XCODE_REQUIRED,
        "allowed": XCODE_ALLOWED,
        "component_sources": {"filesystem", "sdk"},
        "expect_kernels": False,
    },
]

errors = 0
warnings = 0


def error(msg):
    global errors
    errors += 1
    print(f"  ERROR: {msg}", file=sys.stderr)


def warn(msg):
    global warnings
    warnings += 1
    print(f"  WARNING: {msg}", file=sys.stderr)


def validate_date(value, field, build):
    if not DATE_RE.match(value):
        error(f"{build}: {field} '{value}' is not ISO 8601 (YYYY-MM-DD)")
        return
    try:
        d = datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        error(f"{build}: {field} '{value}' is not a valid date")
        return
    if d > TODAY:
        warn(f"{build}: {field} {value} is in the future")
    if d.year < 2001:
        warn(f"{build}: {field} {value} is before 2001")


def parse_version(version_str):
    parts = version_str.split(".")
    try:
        major = int(parts[0])
        minor = int(parts[1]) if len(parts) > 1 else 0
        patch = int(parts[2]) if len(parts) > 2 else 0
        return (major, minor, patch)
    except (ValueError, IndexError):
        return None


def release_sort_key_desc(entry):
    v = parse_version(entry.get("osVersion", "0.0"))
    if v is None:
        v = (0, 0, 0)
    if entry.get("isBeta"):
        rank = 0
    elif entry.get("isRC"):
        rank = 1
    else:
        rank = 2
    build = entry.get("buildNumber", "")
    return (-v[0], -v[1], -v[2], -rank, build)


def _desc_build_cmp(a, b):
    ka = release_sort_key_desc(a)
    kb = release_sort_key_desc(b)
    if ka[:4] != kb[:4]:
        return -1 if ka[:4] < kb[:4] else 1
    if ka[4] != kb[4]:
        return -1 if ka[4] > kb[4] else 1
    return 0


# ---------------------------------------------------------------------------
# Per-release validation
# ---------------------------------------------------------------------------

def validate_releases(product, catalog):
    """Validate individual release JSON files for a product."""
    data_dir = product["data"]
    prefix = product["prefix"]
    required = product["required"]
    allowed = product["allowed"]
    valid_sources = product["component_sources"]
    expect_kernels = product["expect_kernels"]

    all_component_names = defaultdict(int)

    for f in sorted(data_dir.rglob("*.json")):
        parts = f.stem.split("-")
        if len(parts) < 3 or parts[0] != prefix:
            continue

        build = parts[-1]
        filename_version = "-".join(parts[1:-1])

        try:
            d = json.loads(f.read_text())
        except json.JSONDecodeError as e:
            error(f"{f.name}: invalid JSON — {e}")
            continue

        catalog[build] = {"path": f, "data": d}

        # Required fields
        missing = [field for field in required if field not in d]
        if missing:
            error(f"{f.name}: missing fields: {', '.join(missing)}")
            continue

        # Unexpected fields
        unexpected = set(d.keys()) - allowed
        if unexpected:
            warn(f"{f.name}: unexpected fields: {', '.join(sorted(unexpected))}")

        # Filename consistency
        if d["buildNumber"] != build:
            error(f"{f.name}: buildNumber '{d['buildNumber']}' doesn't match filename '{build}'")

        if not VERSION_RE.match(d["osVersion"]):
            error(f"{f.name}: osVersion '{d['osVersion']}' is not a valid version (X.Y or X.Y.Z)")

        if d["osVersion"] != filename_version:
            error(f"{f.name}: osVersion '{d['osVersion']}' doesn't match filename '{filename_version}'")

        # Boolean fields
        for field in BOOL_FIELDS:
            if not isinstance(d[field], bool):
                error(f"{f.name}: {field} should be bool, got {type(d[field]).__name__}")

        # Beta/RC mutual exclusivity and number consistency
        if d["isBeta"] and d["isRC"]:
            error(f"{f.name}: isBeta and isRC are both true")

        if d["isBeta"]:
            bn = d.get("betaNumber")
            if bn is None:
                warn(f"{f.name}: isBeta is true but betaNumber is missing")
            elif not isinstance(bn, int) or bn < 1:
                error(f"{f.name}: betaNumber should be a positive integer, got {bn!r}")
        else:
            if d.get("betaNumber") is not None:
                error(f"{f.name}: betaNumber set but isBeta is false")

        if d["isRC"]:
            rn = d.get("rcNumber")
            if rn is not None and (not isinstance(rn, int) or rn < 1):
                error(f"{f.name}: rcNumber should be a positive integer, got {rn!r}")
        else:
            if d.get("rcNumber") is not None:
                error(f"{f.name}: rcNumber set but isRC is false")

        # Date validation
        validate_date(d["releaseDate"], "releaseDate", build)

        # macOS-specific: IPSW file/URL validation
        if prefix == "macOS":
            url = d["ipswURL"]
            ipswfile = d["ipswFile"]

            if not isinstance(url, str) or not url:
                error(f"{f.name}: ipswURL is empty or not a string")
            if not isinstance(ipswfile, str) or not ipswfile:
                error(f"{f.name}: ipswFile is empty or not a string")

            if url and ipswfile:
                url_file = url.split("/")[-1]
                if ipswfile != url_file:
                    error(f"{f.name}: ipswFile '{ipswfile}' doesn't match URL filename '{url_file}'")

            if url:
                m = IPSW_FILE_RE.search(url)
                if m:
                    url_version, url_build = m.group(1), m.group(2)
                    if url_build != build:
                        error(f"{f.name}: build in ipswURL '{url_build}' doesn't match '{build}'")
                    if url_version != d["osVersion"]:
                        error(f"{f.name}: version in ipswURL '{url_version}' doesn't match '{d['osVersion']}'")

        # Xcode-specific: xipFile/xipURL parity, minimumOSVersion, sdks
        if prefix == "Xcode":
            xip_file = d.get("xipFile", "")
            if not isinstance(xip_file, str) or not xip_file:
                error(f"{f.name}: xipFile is empty or not a string")

            xip_url = d.get("xipURL", "")
            if xip_url and xip_file:
                url_file = xip_url.split("/")[-1]
                if xip_file != url_file:
                    error(f"{f.name}: xipFile '{xip_file}' doesn't match URL filename '{url_file}'")

            min_os = d.get("minimumOSVersion", "")
            if not isinstance(min_os, str) or not min_os:
                error(f"{f.name}: minimumOSVersion is empty or not a string")

            sdks = d.get("sdks", [])
            if not isinstance(sdks, list) or len(sdks) == 0:
                warn(f"{f.name}: sdks array is empty")

        # Components validation
        components = d["components"]
        if not isinstance(components, list) or len(components) == 0:
            warn(f"{f.name}: components array is empty")
        else:
            seen_names = set()
            for ci, comp in enumerate(components):
                for field in COMPONENT_REQUIRED:
                    if field not in comp:
                        error(f"{f.name}: components[{ci}] missing field '{field}'")

                name = comp.get("name", "")
                if not name or not isinstance(name, str):
                    error(f"{f.name}: components[{ci}] has empty or non-string name")
                elif name in seen_names:
                    error(f"{f.name}: duplicate component name '{name}'")
                else:
                    seen_names.add(name)
                    all_component_names[name] += 1

                version = comp.get("version", "")
                if not version or not isinstance(version, str):
                    error(f"{f.name}: component '{name}' has empty or non-string version")

                path = comp.get("path", "")
                if not path or not isinstance(path, str):
                    error(f"{f.name}: component '{name}' has empty or non-string path")

                source = comp.get("source", "")
                if source not in valid_sources:
                    error(f"{f.name}: component '{name}' has invalid source '{source}' "
                          f"(expected: {', '.join(sorted(valid_sources))})")

        # Kernels validation
        kernels = d["kernels"]
        if expect_kernels:
            if not isinstance(kernels, list) or len(kernels) == 0:
                warn(f"{f.name}: kernels array is empty")
            else:
                kernel_required = ["arch", "chip", "darwinVersion", "xnuVersion", "file", "devices"]
                for ki, kern in enumerate(kernels):
                    for field in kernel_required:
                        if field not in kern:
                            error(f"{f.name}: kernels[{ki}] missing field '{field}'")

                    for sfield in ["arch", "chip", "file"]:
                        val = kern.get(sfield, "")
                        if not val or not isinstance(val, str):
                            error(f"{f.name}: kernels[{ki}] {sfield} is empty or not a string")

                    devices = kern.get("devices", [])
                    if not isinstance(devices, list) or len(devices) == 0:
                        warn(f"{f.name}: kernels[{ki}] devices is empty")
                    elif not all(isinstance(d_item, str) for d_item in devices):
                        error(f"{f.name}: kernels[{ki}] devices contains non-string entries")

    # Rare component name check (possible typos)
    total_releases = len(catalog)
    if total_releases > 10:
        rare_names = {name: count for name, count in all_component_names.items()
                      if count < 3}
        for name, count in sorted(rare_names.items()):
            warn(f"{prefix}: component '{name}' only appears in {count} release(s) — possible typo")


# ---------------------------------------------------------------------------
# Index validation
# ---------------------------------------------------------------------------

def validate_index(product, catalog):
    """Validate releases.json index against individual release files."""
    index_path = product["index"]
    prefix = product["prefix"]

    if not index_path.exists():
        error(f"{index_path} not found")
        return

    try:
        index_entries = json.loads(index_path.read_text())
    except json.JSONDecodeError as e:
        error(f"{index_path.name}: invalid JSON — {e}")
        return

    index_builds = {}
    for entry in index_entries:
        b = entry.get("buildNumber", "")
        index_builds[b] = entry

        missing = [field for field in INDEX_REQUIRED if field not in entry]
        if missing:
            error(f"{prefix} index/{b}: missing fields: {', '.join(missing)}")

        data_file = entry.get("dataFile", "")
        if data_file and not (product["data"].parent / data_file).exists():
            error(f"{prefix} index/{b}: dataFile '{data_file}' does not exist")

    catalog_builds = set(catalog.keys())
    index_build_set = set(index_builds.keys())

    for build in sorted(catalog_builds - index_build_set):
        error(f"{build}: in {product['data']} but missing from {index_path.name}")
    for build in sorted(index_build_set - catalog_builds):
        error(f"{build}: in {index_path.name} but no matching JSON file")

    for build in catalog_builds & index_build_set:
        release = catalog[build]["data"]
        idx = index_builds[build]
        for field in PARITY_FIELDS:
            if idx.get(field) != release.get(field):
                error(f"{prefix} index/{build}: {field} mismatch — "
                      f"index={idx.get(field)!r}, file={release.get(field)!r}")

    # Sort order validation
    if len(index_entries) > 1:
        expected_order = sorted(index_entries, key=functools.cmp_to_key(_desc_build_cmp))
        expected_builds = [e["buildNumber"] for e in expected_order]
        actual_builds = [e["buildNumber"] for e in index_entries]
        if actual_builds != expected_builds:
            for i, (actual, expected) in enumerate(zip(actual_builds, expected_builds)):
                if actual != expected:
                    error(f"{prefix} {index_path.name} sort order: "
                          f"position {i} has {actual}, expected {expected}")
                    break


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    results = []

    for product in PRODUCTS:
        if not product["data"].exists():
            print(f"WARNING: {product['data']} not found, skipping {product['name']}.",
                  file=sys.stderr)
            continue

        catalog = {}
        validate_releases(product, catalog)
        validate_index(product, catalog)
        results.append((product["name"], len(catalog)))

    if errors:
        summary = ", ".join(f"{count} {name}" for name, count in results)
        print(f"\n{errors} error(s) in {summary} release files", file=sys.stderr)
        sys.exit(1)
    else:
        parts = [f"{count} {name}" for name, count in results]
        print(f"OK: {' + '.join(parts)} release files validated")


if __name__ == "__main__":
    main()
