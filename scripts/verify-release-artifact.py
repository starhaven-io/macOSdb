#!/usr/bin/env python3
"""Verify a scanner artifact against trusted dispatch inputs before overlaying it."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tarfile
import tempfile
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote, urlsplit
from zoneinfo import ZoneInfo

MAX_MEMBER_SIZE = 32 * 1024 * 1024
MAX_TOTAL_SIZE = 64 * 1024 * 1024
XCODE_PATH_RE = re.compile(r"^/[A-Za-z0-9._~%/+-]+\.xip$")
XCODE_FILE_RE = re.compile(r"^Xcode_([0-9]+(?:\.[0-9]+)*)(?:_[A-Za-z0-9._~%+-]+)?\.xip$")
IPSW_FILE_RE = re.compile(
    r"^UniversalMac_([0-9]+(?:\.[0-9]+){1,2})_([0-9]+[A-Z][0-9]+[a-z]?)_Restore\.ipsw$"
)
MACOS_RELEASE_NAMES = {
    "11": "Big Sur",
    "12": "Monterey",
    "13": "Ventura",
    "14": "Sonoma",
    "15": "Sequoia",
    "26": "Tahoe",
    "27": "Golden Gate",
}


class VerificationError(Exception):
    """The artifact is not bound to the trusted workflow inputs."""


def load_json_strict(data: bytes, label: str) -> object:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise VerificationError(f"{label} contains duplicate JSON key {key!r}")
            result[key] = value
        return result

    def reject_constant(value: str) -> None:
        raise VerificationError(f"{label} contains non-finite JSON number {value}")

    try:
        return json.loads(
            data,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"{label} JSON is malformed") from error


def parse_bool(value: str, name: str) -> bool:
    if value not in {"true", "false"}:
        raise VerificationError(f"{name} must be true or false")
    return value == "true"


def parse_optional_int(value: str, name: str, minimum: int = 1) -> int | None:
    if value == "":
        return None
    if not re.fullmatch(r"[0-9]+", value) or int(value) < minimum:
        raise VerificationError(f"{name} must be an integer of at least {minimum}")
    return int(value)


def resolve_release_date(input_date: str, run_started_at: str) -> str:
    if input_date:
        try:
            parsed = datetime.strptime(input_date, "%Y-%m-%d")
        except ValueError as error:
            raise VerificationError("release_date must be a real YYYY-MM-DD date") from error
        if parsed.strftime("%Y-%m-%d") != input_date:
            raise VerificationError("release_date must use canonical YYYY-MM-DD syntax")
        return input_date

    try:
        started = datetime.fromisoformat(run_started_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise VerificationError("run_started_at is not an ISO-8601 timestamp") from error
    return started.astimezone(ZoneInfo("America/Los_Angeles")).date().isoformat()


def expected_source(product: str, supplied_url: str, build_number: str) -> dict[str, str]:
    if any(character in supplied_url for character in "\r\n"):
        raise VerificationError("source URL contains a line break")

    if product == "xcode":
        matches = re.findall(r"[?&]path=([^&]*)", supplied_url)
        xip_path = matches[-1] if matches else supplied_url
        if not XCODE_PATH_RE.fullmatch(xip_path):
            raise VerificationError("Xcode source does not contain a clean absolute .xip path")
        lowered = xip_path.lower()
        if "//" in xip_path or any(part in {".", ".."} for part in xip_path.split("/")):
            raise VerificationError("Xcode source path contains an ambiguous path segment")
        if re.search(r"%(?:00|0a|0d|2f|5c)", lowered):
            raise VerificationError("Xcode source path contains an encoded separator")
        encoded_name = xip_path.rsplit("/", 1)[-1]
        match = XCODE_FILE_RE.fullmatch(encoded_name)
        if match is None:
            raise VerificationError("Xcode source filename is not canonical")
        if not re.fullmatch(r"[0-9]+[A-Z][0-9]+[a-z]?", build_number):
            raise VerificationError("Xcode build number is not canonical")
        version = match.group(1)
        if "." not in version:
            version += ".0"
        return {
            "version": version,
            "build": build_number,
            "file": unquote(encoded_name),
            "url": f"https://developer.apple.com/services-account/download?path={xip_path}",
        }

    parsed = urlsplit(supplied_url)
    if parsed.scheme != "https" or parsed.hostname != "updates.cdn-apple.com" or parsed.username is not None:
        raise VerificationError("IPSW source must be an updates.cdn-apple.com HTTPS URL")
    filename = unquote(parsed.path.rsplit("/", 1)[-1])
    match = IPSW_FILE_RE.fullmatch(filename)
    if match is None:
        raise VerificationError("IPSW source filename is not canonical")
    return {
        "version": match.group(1),
        "build": match.group(2),
        "file": filename,
        "url": supplied_url,
    }


def expected_prerelease(args: argparse.Namespace, build: str) -> dict[str, object | None]:
    beta = parse_bool(args.beta, "beta")
    rc = parse_bool(args.rc, "rc")
    beta_number = parse_optional_int(args.beta_number, "beta_number")
    beta_revision = parse_optional_int(args.beta_revision, "beta_revision", minimum=2)
    rc_number = parse_optional_int(args.rc_number, "rc_number")
    if beta_revision is not None and beta_number is None:
        raise VerificationError("beta_revision requires beta_number")
    if (beta or beta_number is not None) and (rc or rc_number is not None):
        raise VerificationError("a release cannot be both beta and RC")

    is_rc = rc or rc_number is not None
    explicit_beta = beta or beta_number is not None
    is_beta = False if is_rc else explicit_beta
    if args.product == "macos" and not is_rc and not explicit_beta:
        is_beta = bool(re.fullmatch(r"[0-9]+[A-Z][0-9]+[a-z]", build))

    return {
        "isBeta": is_beta,
        "betaNumber": beta_number if is_beta else None,
        "betaRevision": beta_revision if is_beta else None,
        "isRC": is_rc,
        "rcNumber": rc_number if is_rc else None,
    }


def read_artifact(artifact: Path, expected_index: str, expected_release: str) -> tuple[bytes, bytes]:
    if not artifact.is_file():
        raise VerificationError(f"missing release artifact at {artifact}")

    contents: dict[str, bytes] = {}
    total_size = 0
    member_count = 0
    with tarfile.open(artifact, "r:gz") as archive:
        for member in archive:
            member_count += 1
            if member_count > 2:
                raise VerificationError("artifact must contain exactly two entries")
            if member.name.startswith("/") or ".." in Path(member.name).parts:
                raise VerificationError(f"unsafe artifact path: {member.name}")
            if not member.isfile():
                raise VerificationError(f"artifact entry is not a regular file: {member.name}")
            if member.name not in {expected_index, expected_release} or member.name in contents:
                raise VerificationError(f"unexpected or duplicate artifact entry: {member.name}")
            if member.size > MAX_MEMBER_SIZE:
                raise VerificationError(f"artifact entry is too large: {member.name}")
            total_size += member.size
            if total_size > MAX_TOTAL_SIZE:
                raise VerificationError("artifact expands beyond the allowed size")
            source = archive.extractfile(member)
            if source is None:
                raise VerificationError(f"could not read artifact entry: {member.name}")
            data = source.read(MAX_MEMBER_SIZE + 1)
            if len(data) != member.size or len(data) > MAX_MEMBER_SIZE:
                raise VerificationError(f"artifact entry size changed while reading: {member.name}")
            contents[member.name] = data

    if set(contents) != {expected_index, expected_release}:
        raise VerificationError("artifact must contain exactly one index and one expected release")
    return contents[expected_index], contents[expected_release]


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(data)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary_name, path)
    except Exception:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def verify_and_overlay(args: argparse.Namespace) -> tuple[str, str, str]:
    source = expected_source(args.product, args.source_url, args.build_number)
    release_date = resolve_release_date(args.release_date, args.run_started_at)
    prerelease = expected_prerelease(args, source["build"])
    prefix = "Xcode" if args.product == "xcode" else "macOS"
    product_type = prefix
    major = source["version"].split(".", 1)[0]
    data_file = f"releases/{major}/{prefix}-{source['version']}-{source['build']}.json"
    index_name = f"data/{args.product}/releases.json"
    release_name = f"data/{args.product}/{data_file}"
    index_bytes, release_bytes = read_artifact(Path(args.artifact), index_name, release_name)

    artifact_index = load_json_strict(index_bytes, "artifact index")
    release = load_json_strict(release_bytes, "release detail")
    if not isinstance(artifact_index, list) or not isinstance(release, dict):
        raise VerificationError("artifact JSON has an invalid top-level type")

    expected_fields: dict[str, object | None] = {
        "productType": product_type,
        "osVersion": source["version"],
        "buildNumber": source["build"],
        "releaseDate": release_date,
        "isBeta": prerelease["isBeta"],
        "betaNumber": prerelease["betaNumber"],
        "betaRevision": prerelease["betaRevision"],
        "isRC": prerelease["isRC"],
        "rcNumber": prerelease["rcNumber"],
    }
    if args.product == "xcode":
        expected_fields.update({"xipFile": source["file"], "xipURL": source["url"]})
        if release.get("releaseName") != f"Xcode {source['version']}":
            raise VerificationError("Xcode release name does not match the dispatched version")
    else:
        expected_fields.update(
            {
                "ipswFile": source["file"],
                "ipswURL": source["url"],
                "isDeviceSpecific": parse_bool(args.device_specific, "device_specific"),
            }
        )
        expected_name = MACOS_RELEASE_NAMES.get(major, f"macOS {major}")
        if release.get("releaseName") != expected_name:
            raise VerificationError("macOS release name does not match the dispatched version")
    for field, expected in expected_fields.items():
        if release.get(field) != expected:
            raise VerificationError(f"release field {field} is not bound to the dispatch input")

    current_index_path = Path(index_name)
    release_path = Path(release_name)
    if release_path.exists():
        raise VerificationError(f"release already exists on the trusted base: {release_name}")
    try:
        current_index = load_json_strict(current_index_path.read_bytes(), "trusted index")
    except OSError as error:
        raise VerificationError(f"could not read trusted index {index_name}") from error
    if not isinstance(current_index, list):
        raise VerificationError("trusted release index is not an array")

    matches = [
        entry
        for entry in artifact_index
        if isinstance(entry, dict)
        and entry.get("osVersion") == source["version"]
        and entry.get("buildNumber") == source["build"]
    ]
    if len(matches) != 1:
        raise VerificationError("artifact index must contain exactly one dispatched release")
    expected_entry = {
        field: release[field]
        for field in (
            "productType",
            "osVersion",
            "buildNumber",
            "releaseName",
            "releaseDate",
            "isBeta",
            "betaNumber",
            "betaRevision",
            "isRC",
            "rcNumber",
            "isDeviceSpecific",
        )
        if field in release and (field != "isDeviceSpecific" or args.product == "macos")
    }
    expected_entry["dataFile"] = data_file
    if matches[0] != expected_entry:
        raise VerificationError("artifact index metadata does not exactly match its release detail")

    without_release = [entry for entry in artifact_index if entry is not matches[0]]
    if without_release != current_index:
        raise VerificationError("artifact index is not a one-release addition to the trusted main index")

    atomic_write(release_path, release_bytes)
    try:
        atomic_write(current_index_path, index_bytes)
    except Exception:
        release_path.unlink(missing_ok=True)
        raise

    basename = f"{prefix}-{source['version']}-{source['build']}"
    return basename, source["url"], release_date


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--product", choices=("macos", "xcode"), required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--build-number", default="")
    parser.add_argument("--release-date", default="")
    parser.add_argument("--run-started-at", default="")
    parser.add_argument("--beta", choices=("true", "false"), required=True)
    parser.add_argument("--beta-number", default="")
    parser.add_argument("--beta-revision", default="")
    parser.add_argument("--rc", choices=("true", "false"), required=True)
    parser.add_argument("--rc-number", default="")
    parser.add_argument("--device-specific", choices=("true", "false"), default="false")
    parser.add_argument("--github-output")
    args = parser.parse_args()

    try:
        basename, source_url, release_date = verify_and_overlay(args)
    except (OSError, tarfile.TarError, VerificationError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    if args.github_output:
        with Path(args.github_output).open("a", encoding="utf-8") as output:
            output.write(f"basename={basename}\n")
            output.write(f"source_url={source_url}\n")
            output.write(f"release_date={release_date}\n")
    print(f"Verified {basename} as an exact one-release addition to trusted main.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
