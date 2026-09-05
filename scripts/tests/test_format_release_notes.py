"""Tests for scripts/format-release-notes.py."""

import importlib.util
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1]

spec = importlib.util.spec_from_file_location(
    "format_release_notes", SCRIPTS_DIR / "format-release-notes.py"
)
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseNoteTests(unittest.TestCase):
    def test_breaking_conventional_commits_keep_their_section(self):
        parsed, _ = notes.parse_notes(
            "* feat!: add a new schema by @dev in https://example.test/1\n"
            "* fix(scanner)!: reject malformed input by @dev in https://example.test/2"
        )

        self.assertEqual(parsed["What's New"], ["add a new schema"])
        self.assertEqual(parsed["Fixes"], ["reject malformed input"])

    def test_skipped_types_and_changelog(self):
        parsed, changelog = notes.parse_notes(
            "* chore!: internal maintenance by @dev in https://example.test/1\n"
            "**Full Changelog**: https://example.test/compare"
        )

        self.assertEqual(parsed, {})
        self.assertEqual(changelog, "https://example.test/compare")


if __name__ == "__main__":
    unittest.main()
