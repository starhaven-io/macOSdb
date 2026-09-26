#!/usr/bin/env python3
"""Resolve a published release on trusted main into rescan inputs."""

from __future__ import annotations

import argparse
import json
import re
import stat
import sys
from datetime import date
from pathlib import Path

VERSION_RE = re.compile(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?")
BUILD_RE = re.compile(r"[0-9]+[A-Z][0-9]+[a-z]?")
PREFIXES = {"macos": ("macOS", "ipsw", "ipswURL"), "xcode": ("Xcode", "xip", "xipURL")}


class ResolutionError(Exception):
    """The dispatch does not name exactly one reproducible published release."""


def read_json(path: Path) -> object:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ResolutionError(f"{path} is not a regular file")
    return json.loads(path.read_text(encoding="utf-8"))


def optional_number(release: dict, field: str) -> str:
    value = release.get(field)
    if value is None:
        return ""
    if type(value) is not int or value < 1:
        raise ResolutionError(f"published {field} is not a positive integer")
    return str(value)


def resolve(root: Path, product: str, version: str, build: str) -> dict[str, str]:
    if product not in PREFIXES:
        raise ResolutionError("product must be macos or xcode")
    if not VERSION_RE.fullmatch(version) or not BUILD_RE.fullmatch(build):
        raise ResolutionError("version or build number is not canonical")
    prefix, extension, url_field = PREFIXES[product]
    major = version.split(".", 1)[0]
    data_file = f"releases/{major}/{prefix}-{version}-{build}.json"

    index = read_json(root / "data" / product / "releases.json")
    matches = [
        entry
        for entry in index
        if isinstance(entry, dict) and entry.get("osVersion") == version and entry.get("buildNumber") == build
    ]
    if len(matches) != 1 or matches[0].get("dataFile") != data_file:
        raise ResolutionError(f"trusted main does not index exactly one {prefix} {version} ({build})")
    release = read_json(root / "data" / product / data_file)
    if not isinstance(release, dict) or (
        release.get("productType"),
        release.get("osVersion"),
        release.get("buildNumber"),
    ) != (prefix, version, build):
        raise ResolutionError("published detail identity does not match its index entry")

    release_date = release.get("releaseDate")
    source_url = release.get(url_field)
    if not isinstance(release_date, str) or date.fromisoformat(release_date).isoformat() != release_date:
        raise ResolutionError("published releaseDate is not a canonical date")
    if not isinstance(source_url, str) or not re.fullmatch(r"https://[\x21-\x7e]+", source_url):
        raise ResolutionError(f"published {url_field} is not a single-line HTTPS URL")
    is_beta = release.get("isBeta") is True
    is_rc = release.get("isRC") is True
    # The scanner infers macOS betas from a lowercase build suffix and has no flag to
    # unset that, so a rescan could not reproduce a release published otherwise.
    if product == "macos" and not is_rc and is_beta != bool(re.search(r"[a-z]$", build)):
        raise ResolutionError("published beta flag differs from what a rescan would infer")

    return {
        "data_file": f"data/{product}/{data_file}",
        "archive_path": f"{prefix}/{major}/{prefix}-{version}-{build}.{extension}",
        "major": major,
        "release_date": release_date,
        "source_url": source_url,
        "is_beta": str(is_beta).lower(),
        "beta_number": optional_number(release, "betaNumber"),
        "beta_revision": optional_number(release, "betaRevision"),
        "is_rc": str(is_rc).lower(),
        "rc_number": optional_number(release, "rcNumber"),
        "device_specific": str(release.get("isDeviceSpecific") is True).lower(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--github-output", required=True)
    args = parser.parse_args()

    try:
        outputs = resolve(Path.cwd(), args.product, args.version, args.build)
    except (OSError, ValueError, ResolutionError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    with Path(args.github_output).open("a", encoding="utf-8") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
