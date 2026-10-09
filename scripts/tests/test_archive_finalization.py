import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_workflow_inputs import IPSW_WORKFLOW, XIP_WORKFLOW, workflow_run_block


class ArchiveFinalizationTests(unittest.TestCase):
    def run_workflow(self, *, product, existing=False, failure="", cached=True):
        is_xip = product == "xcode"
        path = XIP_WORKFLOW if is_xip else IPSW_WORKFLOW
        workflow = path.read_text().split("\n  publish:\n", 1)[0]
        shell_match = re.search(r"^defaults:\n  run:\n    shell: (.+)$", workflow, re.MULTILINE)
        self.assertIsNotNone(shell_match, "The workflow must declare its default shell")
        shell = shlex.split(shell_match[1])
        self.assertEqual(shell[0], "bash")
        self.assertEqual(shell.count("{0}"), 1)
        scan_job = workflow.split("\n  scan:\n", 1)[1].split("\n    steps:\n", 1)[0]
        self.assertNotRegex(scan_job, r"(?m)^    defaults:", "The scan job must inherit the workflow shell")
        product_type = "Xcode" if is_xip else "macOS"
        extension = "xip" if is_xip else "ipsw"
        steps = {
            "Verify existing SHA-256 sidecar" if is_xip else "Download IPSW",
            "Scan XIP" if is_xip else "Scan IPSW",
            "Lint JSON",
            "Package release JSON",
            "Create or verify SHA-256 sidecar" if is_xip else "Generate SHA-256 sidecar",
            "Lock archive files",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / f"{product_type}-27.1-27A9275.{extension}"
            if cached:
                archive.write_text("archive fixture")
            sidecar = Path(f"{archive}.sha256")
            if existing:
                sidecar.write_text("existing checksum")
            events = root / "events"
            events.touch()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            cli = root / ".build/release/macosdb"
            cli.parent.mkdir(parents=True)
            cli.write_text("""#!/bin/bash
set -euo pipefail
case "$1" in
  scan)
    echo scan >> "$EVENTS"
    [[ "$FAILURE" != scan ]] || exit 1
    mkdir -p "data/$PRODUCT/releases/27"
    build=27A9275
    [[ "$FAILURE" != metadata ]] || build=27A9276
    printf '{"osVersion":"27.1","buildNumber":"%s","productType":"%s"}\\n' "$build" "$PRODUCT_TYPE" > "$DETAIL"
    if [[ "$PRODUCT" == macos ]]; then echo pem > "$IPSW_FILE.pem"; fi
    ;;
  identity)
    echo identity >> "$EVENTS"
    [[ "$FAILURE" != source ]] || exit 1
    ;;
  validate)
    if [[ -f "$2.sha256" ]]; then
      echo verify >> "$EVENTS"
      [[ "$FAILURE" != checksum ]] || exit 1
    else
      echo hash >> "$EVENTS"
      [[ "$FAILURE" != hash ]] || exit 1
      echo 'new checksum' > "$2.sha256"
    fi
    ;;
  *) exit 2 ;;
esac
""")
            cli.chmod(0o755)
            stubs = {
                "python3": 'echo lint >> "$EVENTS"\n[[ "$FAILURE" != lint ]]',
                "git": 'if [[ "$FAILURE" == identity ]]; then echo data/xcode/releases/27/wrong.json; else echo "$DETAIL"; fi',
                "stat": "exit 0",
                "chflags": 'echo "lock${2#${ARCHIVE_FILE}}" >> "$EVENTS"',
                "tar": '[[ "$FAILURE" != package ]]',
                "curl": 'out=""; while (($#)); do [[ "$1" != -o ]] || out="$2"; shift; done; '
                '[[ -z "$out" ]] || echo "archive fixture" > "$out"',
                "sleep": "exit 0",
            }
            for name, script in stubs.items():
                stub = bin_dir / name
                stub.write_text(f"#!/bin/bash\nset -euo pipefail\n{script}\n")
                stub.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "XIP_FILE": str(archive),
                "IPSW_FILE": str(archive),
                "ARCHIVE_FILE": str(archive),
                "IPSW_URL": "https://updates.cdn-apple.com/fixture.ipsw",
                "PRODUCT": product,
                "PRODUCT_TYPE": product_type,
                "IS_DEVICE_SPECIFIC": "false",
                "RELEASE_DATE": "2026-10-05",
                "PUBLIC_URL": "https://developer.apple.com/services-account/download?path=/Xcode_27.1.xip",
                "EXPECTED_VERSION": "27.1",
                "EXPECTED_BUILD": "27A9275",
                "IS_BETA": "false", "BETA_NUMBER": "", "BETA_REVISION": "",
                "IS_RC": "false", "RC_NUMBER": "",
                "GITHUB_OUTPUT": str(root / "output"),
                "RUNNER_TEMP": directory,
                "EVENTS": str(events),
                "FAILURE": failure,
                "DETAIL": f"data/{product}/releases/27/{product_type}-27.1-27A9275.json",
            }
            executed = set()
            for name in re.findall(r"^      - name: (.+)$", workflow, re.MULTILINE):
                if name not in steps:
                    continue
                executed.add(name)
                step = workflow.split(f"      - name: {name}\n", 1)[1].split("\n      - ", 1)[0]
                self.assertIsNone(
                    re.search(r"^        (if|continue-on-error|shell):", step, re.MULTILINE),
                    f"{name} must retain default success gating, failure propagation, and shell",
                )
                if "        run: |\n" in step:
                    script = workflow_run_block(workflow, name)
                else:
                    script = re.search(r"^        run: (.+)$", step, re.MULTILINE)[1]
                # Stub the absolute macOS tar path while exercising the real identity checks.
                script = script.replace("/usr/bin/tar ", "tar ")
                script_path = root / "step.sh"
                script_path.write_text(script)
                result = subprocess.run(
                    [str(script_path) if argument == "{0}" else argument for argument in shell],
                    cwd=root, env=env, capture_output=True, text=True, check=False,
                )
                if result.returncode:
                    break
            if not failure:
                self.assertEqual(executed, steps)
            self.archive_exists = archive.exists()
            self.partial_exists = Path(f"{archive}.part").exists()
            return result, events.read_text().splitlines(), sidecar.read_text() if sidecar.exists() else None

    def source_check(self, product):
        return ["identity"] if product == "macos" else []

    def expected_locks(self, product):
        return ["lock", "lock.pem", "lock.sha256"] if product == "macos" else ["lock", "lock.sha256"]

    def test_new_archive_is_hashed_and_locked_only_after_scan_and_validation(self):
        for product in ("macos", "xcode"):
            with self.subTest(product=product):
                result, events, checksum = self.run_workflow(product=product)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    events, [*self.source_check(product), "scan", "lint", "hash", *self.expected_locks(product)]
                )
                self.assertEqual(checksum, "new checksum\n")

    def test_failed_scan_or_output_validation_never_creates_a_checksum_or_locks(self):
        for product in ("macos", "xcode"):
            for failure in ("scan", "lint", "identity", "metadata", "package"):
                with self.subTest(product=product, failure=failure):
                    result, events, checksum = self.run_workflow(product=product, failure=failure)
                    self.assertNotEqual(result.returncode, 0)
                    expected = ["scan"] if failure == "scan" else ["scan", "lint"]
                    self.assertEqual(events, [*self.source_check(product), *expected])
                    self.assertIsNone(checksum)

    def test_existing_checksum_mismatch_stops_before_scan_and_preserves_sidecar(self):
        for product in ("macos", "xcode"):
            with self.subTest(product=product):
                result, events, checksum = self.run_workflow(product=product, existing=True, failure="checksum")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, ["verify"])
                self.assertEqual(checksum, "existing checksum")

    def test_valid_cached_archive_is_verified_before_scanning(self):
        for product in ("macos", "xcode"):
            with self.subTest(product=product):
                result, events, checksum = self.run_workflow(product=product, existing=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(events, ["verify", "scan", "lint", "verify", *self.expected_locks(product)])
                self.assertEqual(checksum, "existing checksum")

    def test_hash_failure_does_not_lock_archive(self):
        for product in ("macos", "xcode"):
            with self.subTest(product=product):
                result, events, checksum = self.run_workflow(product=product, failure="hash")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, [*self.source_check(product), "scan", "lint", "hash"])
                self.assertIsNone(checksum)

    def test_unchecksummed_cached_ipsw_with_another_identity_is_preserved_before_scan(self):
        result, events, checksum = self.run_workflow(product="macos", failure="source")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["identity"])
        self.assertIsNone(checksum)
        self.assertTrue(self.archive_exists)
        self.assertIn("Preserving it for investigation", result.stdout)

    def test_fresh_ipsw_download_is_promoted_only_after_its_identity_matches(self):
        result, events, checksum = self.run_workflow(product="macos", cached=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["identity", "scan", "lint", "hash", *self.expected_locks("macos")])
        self.assertEqual(checksum, "new checksum\n")
        self.assertTrue(self.archive_exists)
        self.assertFalse(self.partial_exists)

    def test_fresh_ipsw_download_with_another_identity_is_removed(self):
        result, events, checksum = self.run_workflow(product="macos", cached=False, failure="source")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["identity"])
        self.assertIsNone(checksum)
        self.assertFalse(self.archive_exists)
        self.assertFalse(self.partial_exists)


if __name__ == "__main__":
    unittest.main()
