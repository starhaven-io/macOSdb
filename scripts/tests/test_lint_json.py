"""Tests for scripts/lint-json.py."""

import contextlib
import functools
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "scripts"
VECTORS = REPO_ROOT / "Tests" / "macOSdbCoreTests" / "Fixtures" / "ordering-vectors.json"

spec = importlib.util.spec_from_file_location("lint_json", SCRIPTS_DIR / "lint-json.py")
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)


class GoldenVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vectors = json.loads(VECTORS.read_text())

    def test_os_version_vectors(self):
        for vector in self.vectors["osVersions"]:
            lhs = lint.parse_version(vector["lhs"])
            rhs = lint.parse_version(vector["rhs"])
            self.assertIsNotNone(lhs, vector["lhs"])
            self.assertIsNotNone(rhs, vector["rhs"])
            label = f"{vector['lhs']} vs {vector['rhs']}"
            if vector["expected"] == "lt":
                self.assertLess(lhs, rhs, label)
            elif vector["expected"] == "gt":
                self.assertGreater(lhs, rhs, label)
            else:
                self.assertEqual(lhs, rhs, label)

    def test_build_vectors(self):
        for vector in self.vectors["builds"]:
            lhs = lint.parse_build(vector["lhs"])
            rhs = lint.parse_build(vector["rhs"])
            label = f"{vector['lhs']} vs {vector['rhs']}"
            if vector["expected"] == "lt":
                self.assertLess(lhs, rhs, label)
            elif vector["expected"] == "gt":
                self.assertGreater(lhs, rhs, label)
            else:
                self.assertEqual(lhs, rhs, label)


class ParserTests(unittest.TestCase):
    def test_parse_version_rejects_garbage(self):
        self.assertIsNone(lint.parse_version("abc"))
        self.assertIsNone(lint.parse_version(None))
        self.assertIsNone(lint.parse_version("15.x"))

    def test_parse_build_matches_swift_shape(self):
        self.assertEqual(lint.parse_build("24D2082"), (24, "D", 2082, ""))
        self.assertEqual(lint.parse_build("24A5331b"), (24, "A", 5331, "b"))
        self.assertEqual(lint.parse_build("24B"), (24, "B", 0, ""))
        self.assertEqual(lint.parse_build(None), (0, "", 0, ""))


class StrictJSONTests(unittest.TestCase):
    def test_duplicate_keys_and_nonfinite_numbers_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.json"
            for source in ['{"field": 1, "field": 2}', '{"field": NaN}']:
                with self.subTest(source=source):
                    path.write_text(source)
                    with self.assertRaises(ValueError):
                        lint.read_json(path, 1_024)

    def test_size_limit_is_enforced_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.json"
            path.write_text('{"field": "too large"}')
            with self.assertRaisesRegex(ValueError, "size limit"):
                lint.read_json(path, 4)


class IndexOrderTests(unittest.TestCase):
    def _sort(self, entries):
        return [
            entry["buildNumber"]
            for entry in sorted(entries, key=functools.cmp_to_key(lint._desc_build_cmp))
        ]

    def test_newest_version_first_and_ga_over_prerelease(self):
        entries = [
            {"osVersion": "15.1", "buildNumber": "24B83", "isBeta": False, "isRC": False},
            {"osVersion": "15.1.1", "buildNumber": "24B91", "isBeta": False, "isRC": False},
            {"osVersion": "15.1", "buildNumber": "24B5077d", "isBeta": True, "isRC": False},
            {"osVersion": "15.1", "buildNumber": "24B82", "isBeta": False, "isRC": True},
        ]
        self.assertEqual(self._sort(entries), ["24B91", "24B83", "24B82", "24B5077d"])

    def test_rerelease_build_orders_numerically(self):
        entries = [
            {"osVersion": "15.1", "buildNumber": "24B83", "isBeta": False, "isRC": False},
            {"osVersion": "15.1", "buildNumber": "24B2083", "isBeta": False, "isRC": False},
        ]
        self.assertEqual(self._sort(entries), ["24B2083", "24B83"])


class DownloadURLTests(unittest.TestCase):
    def _errors_for(self, url):
        lint.errors = 0
        with contextlib.redirect_stderr(io.StringIO()):
            lint.validate_download_url(url, "ipswURL", "test")
        count = lint.errors
        lint.errors = 0
        return count

    def test_apple_https_hosts_pass(self):
        self.assertEqual(self._errors_for("https://updates.cdn-apple.com/a/b.ipsw"), 0)
        self.assertEqual(self._errors_for("https://download.developer.apple.com/a.xip"), 0)

    def test_non_apple_or_non_https_fail(self):
        self.assertEqual(self._errors_for("http://updates.cdn-apple.com/a.ipsw"), 1)
        self.assertEqual(self._errors_for("javascript:alert(1)"), 1)
        self.assertEqual(self._errors_for("https://evil.example.com/a.ipsw"), 1)
        self.assertEqual(self._errors_for("https://apple.com.evil.example/a.ipsw"), 1)

    def test_download_filenames_are_parsed_from_paths_and_wrapper_queries(self):
        self.assertEqual(
            lint.download_filename(
                "https://updates.cdn-apple.com/a/UniversalMac_26.1_25B78_Restore.ipsw?token=one"
            ),
            "UniversalMac_26.1_25B78_Restore.ipsw",
        )
        self.assertEqual(
            lint.download_filename(
                "https://developer.apple.com/services-account/download?"
                "path=/Developer_Tools/Xcode_26.1/Xcode_26.1_Release_Candidate.xip",
                query_parameter="path",
            ),
            "Xcode_26.1_Release_Candidate.xip",
        )

    def test_identifier_regexes_use_ascii_digits(self):
        self.assertIsNone(lint.VERSION_RE.fullmatch("٢٦.١"))
        self.assertIsNone(lint.BUILD_IDENTIFIER_RE.fullmatch("٢٥B78"))

    def test_major_only_xcode_archive_versions_normalize_to_dot_zero(self):
        self.assertEqual(lint.xcode_file_version("Xcode_26_Universal.xip"), "26.0")
        self.assertEqual(lint.xcode_file_version("Xcode_26.1_beta.xip"), "26.1")
        self.assertIsNone(lint.xcode_file_version("not-xcode.xip"))


class IndexPointerTests(unittest.TestCase):
    def setUp(self):
        lint.errors = 0

    def tearDown(self):
        lint.errors = 0

    def _product(self, root):
        return {
            "name": "macOS",
            "prefix": "macOS",
            "data": root / "releases",
            "index": root / "releases.json",
            "index_required": lint.MACOS_INDEX_REQUIRED,
            "parity_fields": lint.MACOS_PARITY_FIELDS,
            "bool_fields": lint.MACOS_BOOL_FIELDS,
        }

    def _entry(self, data_file):
        return {
            "buildNumber": "24A335",
            "osVersion": "15.0",
            "releaseName": "Sequoia",
            "releaseDate": "2024-09-16",
            "isBeta": False,
            "isRC": False,
            "isDeviceSpecific": False,
            "productType": "macOS",
            "dataFile": data_file,
        }

    def test_index_rejects_swapped_or_traversing_data_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected = root / "releases/15/macOS-15.0-24A335.json"
            expected.parent.mkdir(parents=True)
            expected.write_text("{}")
            catalog = {"24A335": {"path": expected, "data": self._entry("unused")}}

            for pointer in ["releases/15/macOS-15.1-24B83.json", "../outside.json"]:
                (root / "releases.json").write_text(json.dumps([self._entry(pointer)]))
                lint.errors = 0
                with contextlib.redirect_stderr(io.StringIO()):
                    lint.validate_index(self._product(root), catalog)
                self.assertGreater(lint.errors, 0, pointer)

    def test_index_accepts_canonical_data_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected = root / "releases/15/macOS-15.0-24A335.json"
            expected.parent.mkdir(parents=True)
            release = self._entry("unused")
            expected.write_text(json.dumps(release))
            pointer = "releases/15/macOS-15.0-24A335.json"
            (root / "releases.json").write_text(json.dumps([self._entry(pointer)]))
            catalog = {"24A335": {"path": expected, "data": release}}

            with contextlib.redirect_stderr(io.StringIO()):
                lint.validate_index(self._product(root), catalog)
            self.assertEqual(lint.errors, 0)


if __name__ == "__main__":
    unittest.main()
