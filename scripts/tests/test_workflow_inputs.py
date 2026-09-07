import json
import os
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate-xcode-build.sh"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
IPSW_WORKFLOW = ROOT / ".github" / "workflows" / "scan-ipsw.yml"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
XIP_WORKFLOW = ROOT / ".github" / "workflows" / "scan-xip.yml"


def workflow_run_block(workflow, step_name, *, strip_comments=True):
    step_marker = f"      - name: {step_name}\n"
    step_start = workflow.index(step_marker) + len(step_marker)
    next_step = re.search(r"^      - ", workflow[step_start:], re.MULTILINE)
    step_end = step_start + next_step.start() if next_step else len(workflow)
    step = workflow[step_start:step_end]
    run_marker = "        run: |\n"
    run_start = step.index(run_marker) + len(run_marker)
    run_lines = step[run_start:].splitlines()
    return "\n".join(
        line[10:] if line.startswith("          ") else line
        for line in run_lines
        if not strip_comments or not line.lstrip().startswith("#")
    )


class XcodeBuildInputTests(unittest.TestCase):
    def validate(self, value):
        return subprocess.run(
            ["/bin/bash", str(VALIDATOR), value],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_every_published_xcode_build_is_accepted(self):
        entries = json.loads((ROOT / "data" / "xcode" / "releases.json").read_text())
        for entry in entries:
            with self.subTest(build=entry["buildNumber"]):
                self.assertEqual(self.validate(entry["buildNumber"]).returncode, 0)

    def test_untrusted_build_syntax_is_rejected(self):
        invalid = [
            "",
            "17E5170d\nXIP_FILE=/tmp/other.xip",
            "17E5170d\rXIP_FILE=/tmp/other.xip",
            "17E5170d/../../other",
            r"17E5170d\other",
            "17E5170d ",
            "17e5170d",
            "17E5170dd",
            "１７E5170d",
        ]
        for value in invalid:
            with self.subTest(value=repr(value)):
                result = self.validate(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")


class WorkflowSafetyContractTests(unittest.TestCase):
    def test_site_dispatch_cannot_cancel_main_deployment(self):
        workflow = (ROOT / ".github/workflows/deploy-site.yml").read_text()
        self.assertIn(
            "group: ${{ github.ref == 'refs/heads/main' && 'deploy-site' "
            "|| format('rejected-deploy-{0}', github.run_id) }}",
            workflow,
        )
        push = workflow.split("  workflow_dispatch:", 1)[0]
        for path in [".github/workflows/deploy-site.yml", "scripts/check-npm-install-policy.mjs", "scripts/lint-json.py"]:
            self.assertIn(f"      - '{path}'", push)
        script = workflow_run_block(workflow.split("\n  deploy:", 1)[0], "Validate deployment ref")
        for ref, accepted in [("refs/heads/main", True), ("refs/heads/topic", False), ("refs/tags/main", False)]:
            with self.subTest(ref=ref):
                result = subprocess.run(
                    ["/bin/bash", "-euo", "pipefail", "-c", script],
                    env={**os.environ, "GITHUB_REF": ref, "REF_NAME": ref.rsplit("/", 1)[-1]},
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode == 0, accepted)

    def test_scanner_dispatch_requires_main_before_checkout(self):
        for path in [IPSW_WORKFLOW, XIP_WORKFLOW]:
            workflow = path.read_text()
            self.assertLess(workflow.index("- name: Require main branch"), workflow.index("- uses: actions/checkout@"))
            script = workflow_run_block(workflow, "Require main branch")
            for ref, accepted in [("refs/heads/main", True), ("refs/heads/topic", False), ("refs/tags/main", False)]:
                with self.subTest(workflow=path.name, ref=ref):
                    result = subprocess.run(
                        ["/bin/bash", "-euo", "pipefail", "-c", script],
                        env={**os.environ, "GITHUB_REF": ref},
                        capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode == 0, accepted)

    def test_release_verifies_cli_notarization_without_spctl(self):
        workflow = RELEASE_WORKFLOW.read_text()
        notarize_script = workflow_run_block(workflow, "Notarize binary")
        expected_check = (
            "if codesign --verify --strict -R='notarized' "
            '--check-notarization --verbose=4 "${BINARY}"; then'
        )
        notarization_checks = [
            line.strip()
            for line in notarize_script.splitlines()
            if "--check-notarization" in line
        ]
        self.assertEqual(notarization_checks, [expected_check])
        self.assertIn("for attempt in 1 2 3", notarize_script)
        self.assertIn("if (( status != 3 || attempt == 3 ))", notarize_script)
        self.assertIn("sleep 10", notarize_script)
        self.assertNotIn("spctl --assess", notarize_script)

    def test_workflow_changes_run_script_contract_tests(self):
        workflow = CI_WORKFLOW.read_text()
        matrix_script = workflow_run_block(workflow, "Generate CI matrix")
        self.assertIn("matches_changed_path '^\\.github/workflows/|^scripts/", matrix_script)

    def test_coverage_upload_is_isolated_and_uses_oidc_for_dependabot(self):
        workflow = CI_WORKFLOW.read_text()
        upload = workflow.split("  codecov:\n", 1)[1].split("\n  zizmor:\n", 1)[0]
        self.assertIn("id-token: write", upload)
        self.assertIn("python3 -I codecov-uploader/scripts/upload-codecov.py", upload)
        self.assertIn("github.event.pull_request.base.sha || github.sha", upload)
        self.assertNotIn("dependabot[bot]", upload)
        self.assertNotIn("CODECOV_TOKEN", workflow)
        self.assertNotIn("continue-on-error", upload)

    def test_xip_integrity_is_established_before_scanning(self):
        workflow = XIP_WORKFLOW.read_text()
        checksum_step = workflow.index("- name: Create or verify SHA-256 sidecar")
        scan_step = workflow.index("- name: Scan XIP")
        self.assertLess(checksum_step, scan_step)
        self.assertIn(
            '.build/release/macosdb validate "${XIP_FILE}"',
            workflow[checksum_step:scan_step],
        )

        cache_start = workflow.index('if [[ -f "${XIP_FILE}" ]]')
        cache_end = workflow.index('if [[ -z "${ADC_DOWNLOAD_AUTH}" ]]', cache_start)
        cached_file_handling = workflow[cache_start:cache_end]
        self.assertIn("Preserving it for investigation", cached_file_handling)
        self.assertNotIn('rm -f "${XIP_FILE}"', cached_file_handling)

        validation_start = workflow.index("- name: Validate XIP")
        validation_end = workflow.index("- name: Set or verify XIP modification time")
        validation = workflow[validation_start:validation_end]
        self.assertIn("steps.download-xip.outputs.downloaded", validation)
        self.assertIn('if [[ "${DOWNLOADED}" == "true" ]]', validation)
        self.assertIn("Preserving the invalid preexisting cache entry", validation)

    def test_process_runner_reopens_stdin_after_capture_file_actions(self):
        source = (ROOT / "Sources/macOSdbCore/Scanner/ProcessRunner.swift").read_text()
        stderr_action = source.index("try configure(stderr, as: STDERR_FILENO")
        stdin_action = source.index(
            "posix_spawn_file_actions_addopen(\n"
            "            &actions,\n"
            "            STDIN_FILENO"
        )
        self.assertLess(stderr_action, stdin_action)

    def test_ipsw_cache_filename_requires_a_canonical_build_number(self):
        workflow = IPSW_WORKFLOW.read_text()
        self.assertIn(
            "^UniversalMac_[0-9]+(\\.[0-9]+){1,2}_"
            "[0-9]+[A-Z][0-9]+[a-z]?_Restore\\.ipsw$",
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
