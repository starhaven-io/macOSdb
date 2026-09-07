import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_workflow_inputs import IPSW_WORKFLOW, RELEASE_WORKFLOW, XIP_WORKFLOW, workflow_run_block


class ScannerCacheTests(unittest.TestCase):
    def test_distinct_scans_and_releases_are_retained(self):
        for path, group in ((IPSW_WORKFLOW, "scan"), (XIP_WORKFLOW, "scan"), (RELEASE_WORKFLOW, "release")):
            concurrency = path.read_text().split("concurrency:\n", 1)[1].split("\n\n", 1)[0]
            self.assertEqual(dict(line.strip().split(": ", 1) for line in concurrency.splitlines()), {
                "group": group, "cancel-in-progress": "false", "queue": "max",
            })

    def identity(self, script, **overrides):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            shims = """
swift() { test "${FAIL_SWIFT}" = false || return 1; printf '%s\\n' "${SWIFT_VERSION_FIXTURE}"; }
xcrun() {
  test "${FAIL_SDK}" = false || return 1
  case "$3" in
    --show-sdk-build-version) printf '%s\\n' "${SDK_BUILD_FIXTURE}" ;;
    --show-sdk-path) printf '%s\\n' "${SDK_PATH_FIXTURE}" ;;
    *) return 2 ;;
  esac
}
"""
            result = subprocess.run(
                ["/bin/bash", "-euo", "pipefail", "-c", shims + script],
                env={
                    **os.environ,
                    "GITHUB_OUTPUT": str(output),
                    "SWIFT_VERSION_FIXTURE": "Swift fixture 1\nTarget: arm64-apple-macos",
                    "SDK_BUILD_FIXTURE": "fixture-build-1",
                    "SDK_PATH_FIXTURE": "/Applications/Xcode Fixture.app/SDK",
                    "FAIL_SWIFT": "false",
                    "FAIL_SDK": "false",
                    **overrides,
                },
                capture_output=True,
                text=True,
                check=False,
            )
            return result, output.read_text() if output.exists() else ""

    def test_scanner_keys_share_compiler_sdk_platform_and_source_identity(self):
        scripts = []
        keys = []
        for path in (IPSW_WORKFLOW, XIP_WORKFLOW):
            workflow = path.read_text()
            scripts.append(workflow_run_block(workflow, "Identify Swift build environment"))
            workflow_keys = [line.strip() for line in workflow.splitlines() if "key: macosdb-cli-" in line]
            self.assertEqual(len(workflow_keys), 2)
            self.assertEqual(workflow_keys[0], workflow_keys[1])
            keys.extend(workflow_keys)
        self.assertEqual(scripts[0], scripts[1])
        self.assertEqual(len(set(keys)), 1)
        for component in (
            "runner.os", "runner.arch", "steps.swift-build-environment.outputs.digest",
            "hashFiles('Sources/**/*.swift', 'Package.swift', 'Package.resolved')",
        ):
            self.assertIn(component, keys[0])

    def test_compiler_and_sdk_changes_invalidate_the_identity(self):
        script = workflow_run_block(IPSW_WORKFLOW.read_text(), "Identify Swift build environment")
        result, baseline = self.identity(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(baseline, r"^digest=[0-9a-f]{64}\n$")
        self.assertEqual(self.identity(script)[1], baseline)
        for name, value in (
            ("SWIFT_VERSION_FIXTURE", "Swift fixture 2\nTarget: arm64-apple-macos"),
            ("SDK_BUILD_FIXTURE", "fixture-build-2"),
            ("SDK_PATH_FIXTURE", "/Applications/Other Xcode.app/SDK"),
        ):
            with self.subTest(component=name):
                result, changed = self.identity(script, **{name: value})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(changed, baseline)

    def test_missing_compiler_or_sdk_cannot_create_a_cache_identity(self):
        script = workflow_run_block(IPSW_WORKFLOW.read_text(), "Identify Swift build environment")
        for name in ("FAIL_SWIFT", "FAIL_SDK"):
            with self.subTest(component=name):
                result, output = self.identity(script, **{name: "true"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()
