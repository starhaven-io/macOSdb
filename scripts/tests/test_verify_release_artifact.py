import argparse
import importlib.util
import io
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "verify-release-artifact.py"
SPEC = importlib.util.spec_from_file_location("verify_release_artifact", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class VerifyReleaseArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.previous_directory = Path.cwd()
        os.chdir(self.root)
        (self.root / "data/xcode").mkdir(parents=True)
        self.base_entry = {
            "productType": "Xcode",
            "osVersion": "26.0",
            "buildNumber": "17A1",
            "releaseName": "Xcode 26.0",
            "releaseDate": "2025-09-01",
            "isBeta": False,
            "isRC": False,
            "dataFile": "releases/26/Xcode-26.0-17A1.json",
        }
        (self.root / "data/xcode/releases.json").write_text(
            json.dumps([self.base_entry]), encoding="utf-8"
        )

    def tearDown(self):
        os.chdir(self.previous_directory)
        self.temporary.cleanup()

    def arguments(self, **overrides):
        values = {
            "artifact": str(self.root / "release-json.tgz"),
            "product": "xcode",
            "source_url": (
                "https://developer.apple.com/services-account/download?"
                "path=/Developer_Tools/Xcode_26.1/Xcode_26.1.xip"
            ),
            "build_number": "17B54",
            "release_date": "2025-11-03",
            "run_started_at": "2025-11-04T01:00:00Z",
            "beta": "false",
            "beta_number": "",
            "beta_revision": "",
            "rc": "false",
            "rc_number": "",
            "device_specific": "false",
            "github_output": None,
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def write_artifact(self, *, release_overrides=None, base_index=None):
        detail = {
            "productType": "Xcode",
            "osVersion": "26.1",
            "buildNumber": "17B54",
            "releaseName": "Xcode 26.1",
            "releaseDate": "2025-11-03",
            "isBeta": False,
            "isRC": False,
            "xipFile": "Xcode_26.1.xip",
            "xipURL": (
                "https://developer.apple.com/services-account/download?"
                "path=/Developer_Tools/Xcode_26.1/Xcode_26.1.xip"
            ),
            "components": [],
            "sdks": [],
            "minimumOSVersion": "15.6",
        }
        detail.update(release_overrides or {})
        entry = {
            key: value
            for key, value in detail.items()
            if key
            in {
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
            }
        }
        entry["dataFile"] = "releases/26/Xcode-26.1-17B54.json"
        index = [entry, *(base_index if base_index is not None else [self.base_entry])]
        members = {
            "data/xcode/releases.json": json.dumps(index).encode(),
            "data/xcode/releases/26/Xcode-26.1-17B54.json": json.dumps(detail).encode(),
        }
        with tarfile.open(self.root / "release-json.tgz", "w:gz") as archive:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))

    def test_exact_one_release_addition_is_overlaid(self):
        self.write_artifact()

        basename, source_url, release_date = MODULE.verify_and_overlay(self.arguments())

        self.assertEqual(basename, "Xcode-26.1-17B54")
        self.assertIn("Xcode_26.1.xip", source_url)
        self.assertEqual(release_date, "2025-11-03")
        self.assertTrue((self.root / "data/xcode/releases/26/Xcode-26.1-17B54.json").is_file())

    def test_artifact_cannot_replace_the_trusted_base_index(self):
        self.write_artifact(base_index=[])

        with self.assertRaisesRegex(MODULE.VerificationError, "one-release addition"):
            MODULE.verify_and_overlay(self.arguments())

    def test_detail_must_match_dispatch_prerelease_fields(self):
        self.write_artifact(release_overrides={"isBeta": True, "betaNumber": 2})

        with self.assertRaisesRegex(MODULE.VerificationError, "isBeta"):
            MODULE.verify_and_overlay(self.arguments())

    def test_artifact_rejects_entries_beyond_the_exact_pair(self):
        self.write_artifact()
        artifact = self.root / "release-json.tgz"
        with tarfile.open(artifact, "r:gz") as archive:
            existing = {
                member.name: archive.extractfile(member).read()
                for member in archive
            }
        existing["unexpected.txt"] = b"unexpected"
        with tarfile.open(artifact, "w:gz") as archive:
            for name, data in existing.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))

        with self.assertRaisesRegex(MODULE.VerificationError, "exactly two entries"):
            MODULE.verify_and_overlay(self.arguments())

    def test_default_date_is_bound_to_trusted_run_start(self):
        resolved = MODULE.resolve_release_date("", "2025-11-04T07:30:00Z")
        self.assertEqual(resolved, "2025-11-03")

    def test_major_only_xcode_filenames_normalize_to_dot_zero(self):
        source = MODULE.expected_source(
            "xcode",
            "https://developer.apple.com/services-account/download?path="
            "/Developer_Tools/Xcode_26/Xcode_26_Universal.xip",
            "17A324",
        )
        self.assertEqual(source["version"], "26.0")

    def test_artifact_json_rejects_duplicate_keys_and_nonfinite_numbers(self):
        with self.assertRaisesRegex(MODULE.VerificationError, "duplicate JSON key"):
            MODULE.load_json_strict(b'{"field": 1, "field": 2}', "fixture")
        with self.assertRaisesRegex(MODULE.VerificationError, "non-finite JSON number"):
            MODULE.load_json_strict(b'{"field": NaN}', "fixture")


class VerifyMacOSReleaseArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.previous_directory = Path.cwd()
        os.chdir(self.root)
        (self.root / "data/macos").mkdir(parents=True)
        self.base_entry = {
            "productType": "macOS",
            "osVersion": "26.0",
            "buildNumber": "25A354",
            "releaseName": "Tahoe",
            "releaseDate": "2025-09-15",
            "isBeta": False,
            "isRC": False,
            "isDeviceSpecific": False,
            "dataFile": "releases/26/macOS-26.0-25A354.json",
        }
        (self.root / "data/macos/releases.json").write_text(
            json.dumps([self.base_entry]), encoding="utf-8"
        )

    def tearDown(self):
        os.chdir(self.previous_directory)
        self.temporary.cleanup()

    @property
    def source_url(self):
        return (
            "https://updates.cdn-apple.com/2025FallFCS/fullrestores/"
            "UniversalMac_26.1_25B78_Restore.ipsw"
        )

    def arguments(self, **overrides):
        values = {
            "artifact": str(self.root / "release-json.tgz"),
            "product": "macos",
            "source_url": self.source_url,
            "build_number": "",
            "release_date": "2025-11-03",
            "run_started_at": "",
            "beta": "false",
            "beta_number": "",
            "beta_revision": "",
            "rc": "false",
            "rc_number": "",
            "device_specific": "false",
            "github_output": None,
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def write_artifact(self, **release_overrides):
        detail = {
            "productType": "macOS",
            "osVersion": "26.1",
            "buildNumber": "25B78",
            "releaseName": "Tahoe",
            "releaseDate": "2025-11-03",
            "isBeta": False,
            "isRC": False,
            "isDeviceSpecific": False,
            "ipswFile": "UniversalMac_26.1_25B78_Restore.ipsw",
            "ipswURL": self.source_url,
            "components": [],
            "kernels": [],
        }
        detail.update(release_overrides)
        entry = {
            key: detail[key]
            for key in (
                "productType",
                "osVersion",
                "buildNumber",
                "releaseName",
                "releaseDate",
                "isBeta",
                "isRC",
                "isDeviceSpecific",
            )
        }
        entry["dataFile"] = "releases/26/macOS-26.1-25B78.json"
        members = {
            "data/macos/releases.json": json.dumps([entry, self.base_entry]).encode(),
            "data/macos/releases/26/macOS-26.1-25B78.json": json.dumps(detail).encode(),
        }
        with tarfile.open(self.root / "release-json.tgz", "w:gz") as archive:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))

    def test_exact_macos_addition_is_bound_and_overlaid(self):
        self.write_artifact()

        basename, source_url, release_date = MODULE.verify_and_overlay(self.arguments())

        self.assertEqual(basename, "macOS-26.1-25B78")
        self.assertEqual(source_url, self.source_url)
        self.assertEqual(release_date, "2025-11-03")

    def test_macos_source_and_device_flag_must_match_dispatch(self):
        self.write_artifact(ipswURL=self.source_url + "?changed=true")
        with self.assertRaisesRegex(MODULE.VerificationError, "ipswURL"):
            MODULE.verify_and_overlay(self.arguments())

        self.write_artifact(isDeviceSpecific=True)
        with self.assertRaisesRegex(MODULE.VerificationError, "isDeviceSpecific"):
            MODULE.verify_and_overlay(self.arguments())

    def test_macos_release_name_is_derived_from_the_dispatched_version(self):
        self.write_artifact(releaseName="Not Tahoe")
        with self.assertRaisesRegex(MODULE.VerificationError, "release name"):
            MODULE.verify_and_overlay(self.arguments())


if __name__ == "__main__":
    unittest.main()
