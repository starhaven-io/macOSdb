"""Tests for scripts/lint-json.py."""

import contextlib
import functools
import importlib.util
import io
import json
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


if __name__ == "__main__":
    unittest.main()
