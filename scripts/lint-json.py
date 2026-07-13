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
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Product configurations
# ---------------------------------------------------------------------------

SHARED_REQUIRED = [
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "productType", "components",
]

MACOS_REQUIRED = SHARED_REQUIRED + ["isDeviceSpecific", "ipswFile", "ipswURL", "kernels"]
XCODE_REQUIRED = SHARED_REQUIRED + ["xipFile", "xipURL", "minimumOSVersion", "sdks"]

MACOS_ALLOWED = {
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "productType", "isBeta", "isRC", "isDeviceSpecific",
    "ipswFile", "ipswURL", "betaNumber", "betaRevision", "rcNumber",
    "components", "kernels",
}
XCODE_ALLOWED = {
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "productType", "isBeta", "isRC",
    "xipFile", "xipURL", "minimumOSVersion", "sdks",
    "betaNumber", "betaRevision", "rcNumber", "components",
}

INDEX_SHARED_REQUIRED = [
    "buildNumber", "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "productType", "dataFile",
]

MACOS_INDEX_REQUIRED = INDEX_SHARED_REQUIRED + ["isDeviceSpecific"]
XCODE_INDEX_REQUIRED = INDEX_SHARED_REQUIRED

PARITY_FIELDS = [
    "osVersion", "releaseDate", "releaseName",
    "isBeta", "isRC", "productType",
    "betaNumber", "betaRevision", "rcNumber",
]

MACOS_PARITY_FIELDS = PARITY_FIELDS + ["isDeviceSpecific"]

MACOS_BOOL_FIELDS = ["isBeta", "isRC", "isDeviceSpecific"]
XCODE_BOOL_FIELDS = ["isBeta", "isRC"]
COMPONENT_REQUIRED = ["name", "version", "path", "source"]

IPSW_FILE_RE = re.compile(r"UniversalMac_([\d.]+)_([A-Za-z0-9]+)_Restore\.ipsw$")
VERSION_RE = re.compile(r"^\d+\.\d+(\.\d+)?$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TODAY = date.today()

# IPSW/XIP download URLs are rendered as <a href> links on the site, so restrict
# them to Apple's https endpoints — a javascript:/http:/foreign value must never
# reach the published data. Apple serves these from *.apple.com and *.cdn-apple.com.
APPLE_DOWNLOAD_HOST_SUFFIXES = (".apple.com", ".cdn-apple.com")

PRODUCTS = [
    {
        "name": "macOS",
        "prefix": "macOS",
        "data": Path("data/macos/releases"),
        "index": Path("data/macos/releases.json"),
        "required": MACOS_REQUIRED,
        "allowed": MACOS_ALLOWED,
        "index_required": MACOS_INDEX_REQUIRED,
        "parity_fields": MACOS_PARITY_FIELDS,
        "bool_fields": MACOS_BOOL_FIELDS,
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
        "index_required": XCODE_INDEX_REQUIRED,
        "parity_fields": PARITY_FIELDS,
        "bool_fields": XCODE_BOOL_FIELDS,
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
    if not isinstance(value, str) or not value:
        error(f"{build}: {field} is empty or not a string")
        return
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


def validate_download_url(url, field, name):
    """Require an Apple https URL. These values are published verbatim as download
    links, so a non-https scheme (javascript:, data:, http:) or a foreign host is an
    error, not a warning."""
    if not isinstance(url, str) or not url:
        error(f"{name}: {field} is empty or not a string")
        return
    parsed = urlparse(url)
    if parsed.scheme != "https":
        error(f"{name}: {field} must use https, got '{parsed.scheme or url[:16]}'")
        return
    host = parsed.hostname or ""
    if host != "apple.com" and not host.endswith(APPLE_DOWNLOAD_HOST_SUFFIXES):
        error(f"{name}: {field} host '{host}' is not an Apple download domain")


def parse_version(version_str):
    if not isinstance(version_str, str):
        return None
    parts = version_str.split(".")
    try:
        major = int(parts[0])
        minor = int(parts[1]) if len(parts) > 1 else 0
        patch = int(parts[2]) if len(parts) > 2 else 0
        return (major, minor, patch)
    except (ValueError, IndexError):
        return None


BUILD_RE = re.compile(r"(\d*)([A-Za-z]*)(\d*)(.*)")


def parse_build(build):
    """Split e.g. '24D2082' → (24, 'D', 2082, '') so re-release variants compare
    numerically (24D81 < 24D2082) rather than lexically. Mirrors BuildNumber.parse
    in Sources/macOSdbCore/Models/Release.swift."""
    if not isinstance(build, str):
        return (0, "", 0, "")
    m = BUILD_RE.match(build)
    if not m:
        return (0, "", 0, "")
    cycle = int(m.group(1)) if m.group(1) else 0
    train = m.group(2)
    num = int(m.group(3)) if m.group(3) else 0
    return (cycle, train, num, m.group(4))


def release_sort_key_desc(entry):
    v = parse_version(entry.get("osVersion", "0.0"))
    if v is None:
        v = (0, 0, 0)
    if entry.get("isBeta") is True:
        rank = 0
    elif entry.get("isRC") is True:
        rank = 1
    else:
        rank = 2
    build = parse_build(entry.get("buildNumber", ""))
    return (-v[0], -v[1], -v[2], -rank, build)


def _desc_build_cmp(a, b):
    ka = release_sort_key_desc(a)
    kb = release_sort_key_desc(b)
    if ka[:4] != kb[:4]:
        return -1 if ka[:4] < kb[:4] else 1
    if ka[4] != kb[4]:
        return -1 if ka[4] > kb[4] else 1
    return 0


def require_string(obj, field, context):
    value = obj.get(field)
    if not isinstance(value, str) or not value:
        error(f"{context}: {field} is empty or not a string")
        return None
    return value


def validate_product_type(value, expected, context):
    if value is not None and value != expected:
        error(f"{context}: productType '{value}' should be '{expected}'")


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

        if build in catalog:
            error(f"{f.name}: duplicate buildNumber '{build}' "
                  f"(already defined in {catalog[build]['path'].name})")
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

        build_number = require_string(d, "buildNumber", f.name)
        os_version = require_string(d, "osVersion", f.name)
        release_date = require_string(d, "releaseDate", f.name)
        require_string(d, "releaseName", f.name)
        product_type = require_string(d, "productType", f.name)
        validate_product_type(product_type, product["name"], f.name)

        # Filename consistency
        if build_number is not None and build_number != build:
            error(f"{f.name}: buildNumber '{build_number}' doesn't match filename '{build}'")

        if os_version is not None and not VERSION_RE.match(os_version):
            error(f"{f.name}: osVersion '{os_version}' is not a valid version (X.Y or X.Y.Z)")

        if os_version is not None and os_version != filename_version:
            error(f"{f.name}: osVersion '{os_version}' doesn't match filename '{filename_version}'")

        # Boolean fields
        for field in product["bool_fields"]:
            if not isinstance(d[field], bool):
                error(f"{f.name}: {field} should be bool, got {type(d[field]).__name__}")

        # Beta/RC mutual exclusivity and number consistency
        is_beta = d["isBeta"]
        is_rc = d["isRC"]
        if isinstance(is_beta, bool) and isinstance(is_rc, bool):
            if is_beta and is_rc:
                error(f"{f.name}: isBeta and isRC are both true")

            if is_beta:
                bn = d.get("betaNumber")
                if bn is None:
                    warn(f"{f.name}: isBeta is true but betaNumber is missing")
                elif not isinstance(bn, int) or bn < 1:
                    error(f"{f.name}: betaNumber should be a positive integer, got {bn!r}")

                revision = d.get("betaRevision")
                if revision is not None:
                    if bn is None:
                        error(f"{f.name}: betaRevision requires betaNumber")
                    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 2:
                        error(f"{f.name}: betaRevision should be an integer of 2 or greater, got {revision!r}")
            elif d.get("betaNumber") is not None:
                error(f"{f.name}: betaNumber set but isBeta is false")
            elif d.get("betaRevision") is not None:
                error(f"{f.name}: betaRevision set but isBeta is false")

            if is_rc:
                rn = d.get("rcNumber")
                if rn is not None and (not isinstance(rn, int) or rn < 1):
                    error(f"{f.name}: rcNumber should be a positive integer, got {rn!r}")
            elif d.get("rcNumber") is not None:
                error(f"{f.name}: rcNumber set but isRC is false")

        # Date validation
        if release_date is not None:
            validate_date(release_date, "releaseDate", build)

        # macOS-specific: IPSW file/URL validation
        if prefix == "macOS":
            url = d["ipswURL"]
            ipswfile = d["ipswFile"]

            validate_download_url(url, "ipswURL", f.name)
            if not isinstance(ipswfile, str) or not ipswfile:
                error(f"{f.name}: ipswFile is empty or not a string")

            if isinstance(url, str) and isinstance(ipswfile, str) and url and ipswfile:
                url_file = url.split("/")[-1]
                if ipswfile != url_file:
                    error(f"{f.name}: ipswFile '{ipswfile}' doesn't match URL filename '{url_file}'")

            if isinstance(url, str) and url:
                m = IPSW_FILE_RE.search(url)
                if m:
                    url_version, url_build = m.group(1), m.group(2)
                    if url_build != build:
                        error(f"{f.name}: build in ipswURL '{url_build}' doesn't match '{build}'")
                    if os_version is not None and url_version != os_version:
                        error(f"{f.name}: version in ipswURL '{url_version}' doesn't match '{os_version}'")

        # Xcode-specific: xipFile/xipURL parity, minimumOSVersion, sdks
        if prefix == "Xcode":
            xip_file = d.get("xipFile", "")
            if not isinstance(xip_file, str) or not xip_file:
                error(f"{f.name}: xipFile is empty or not a string")

            xip_url = d.get("xipURL", "")
            validate_download_url(xip_url, "xipURL", f.name)
            if isinstance(xip_url, str) and isinstance(xip_file, str) and xip_url and xip_file:
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
                if not isinstance(comp, dict):
                    error(f"{f.name}: components[{ci}] should be object, got {type(comp).__name__}")
                    continue
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
                if not isinstance(source, str) or source not in valid_sources:
                    error(f"{f.name}: component '{name}' has invalid source '{source}' "
                          f"(expected: {', '.join(sorted(valid_sources))})")

        # Kernels validation
        kernels = d.get("kernels", [])
        if expect_kernels:
            if not isinstance(kernels, list) or len(kernels) == 0:
                warn(f"{f.name}: kernels array is empty")
            else:
                kernel_required = ["arch", "chip", "darwinVersion", "xnuVersion", "file", "devices"]
                for ki, kern in enumerate(kernels):
                    if not isinstance(kern, dict):
                        error(f"{f.name}: kernels[{ki}] should be object, got {type(kern).__name__}")
                        continue
                    for field in kernel_required:
                        if field not in kern:
                            error(f"{f.name}: kernels[{ki}] missing field '{field}'")

                    for sfield in ["arch", "chip", "file"]:
                        val = kern.get(sfield, "")
                        if not val or not isinstance(val, str):
                            error(f"{f.name}: kernels[{ki}] {sfield} is empty or not a string")

                    devices = kern.get("devices", [])
                    chip = kern.get("chip", "")
                    is_dtk = chip == "A12Z (DTK)"
                    is_early_vm = chip == "Virtual Mac" and build in {
                        "21A5268h", "21A5284e", "21A5294g",
                    }
                    if not isinstance(devices, list) or len(devices) == 0:
                        if not is_dtk and not is_early_vm:
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
    if not isinstance(index_entries, list):
        error(f"{index_path.name}: top-level value should be array, got {type(index_entries).__name__}")
        return

    index_builds = {}
    valid_entries = []
    for i, entry in enumerate(index_entries):
        if not isinstance(entry, dict):
            error(f"{prefix} index[{i}]: should be object, got {type(entry).__name__}")
            continue

        build_number = entry.get("buildNumber", "")
        b = build_number if isinstance(build_number, str) and build_number else f"entry {i}"
        context = f"{prefix} index/{b}"

        missing = [field for field in product["index_required"] if field not in entry]
        if missing:
            error(f"{context}: missing fields: {', '.join(missing)}")
            continue

        build_number = require_string(entry, "buildNumber", context)
        os_version = require_string(entry, "osVersion", context)
        release_date = require_string(entry, "releaseDate", context)
        require_string(entry, "releaseName", context)
        product_type = require_string(entry, "productType", context)
        data_file = require_string(entry, "dataFile", context)
        validate_product_type(product_type, product["name"], context)

        for field in product["bool_fields"]:
            if field in entry and not isinstance(entry[field], bool):
                error(f"{context}: {field} should be bool, got {type(entry[field]).__name__}")

        if os_version is not None and not VERSION_RE.match(os_version):
            error(f"{context}: osVersion '{os_version}' is not a valid version (X.Y or X.Y.Z)")
        if release_date is not None:
            validate_date(release_date, "releaseDate", context)

        if build_number is None:
            continue
        if build_number in index_builds:
            error(f"{prefix} index: duplicate buildNumber '{b}'")
        index_builds[build_number] = entry
        valid_entries.append(entry)

        if data_file is not None and not (product["data"].parent / data_file).exists():
            error(f"{context}: dataFile '{data_file}' does not exist")

    catalog_builds = set(catalog.keys())
    index_build_set = set(index_builds.keys())

    for build in sorted(catalog_builds - index_build_set):
        error(f"{build}: in {product['data']} but missing from {index_path.name}")
    for build in sorted(index_build_set - catalog_builds):
        error(f"{build}: in {index_path.name} but no matching JSON file")

    for build in catalog_builds & index_build_set:
        release = catalog[build]["data"]
        idx = index_builds[build]
        for field in product["parity_fields"]:
            if idx.get(field) != release.get(field):
                error(f"{prefix} index/{build}: {field} mismatch — "
                      f"index={idx.get(field)!r}, file={release.get(field)!r}")

    # Sort order validation
    if len(valid_entries) > 1:
        expected_order = sorted(valid_entries, key=functools.cmp_to_key(_desc_build_cmp))
        expected_builds = [e["buildNumber"] for e in expected_order]
        actual_builds = [e["buildNumber"] for e in valid_entries]
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
