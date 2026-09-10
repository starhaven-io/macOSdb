import os
import subprocess
import unittest

from test_workflow_inputs import CI_WORKFLOW, workflow_run_block


class CIConclusionTests(unittest.TestCase):
    def setUp(self):
        self.script = workflow_run_block(CI_WORKFLOW.read_text(), "Result")
        self.environment = {
            "GITHUB_EVENT_NAME": "pull_request",
            "GENERATE_MATRIX_RESULT": "success",
            "COMMITS_RESULT": "success",
            "CHECK_RESULT": "success",
            "CODEQL_RESULT": "success",
            "CODEQL_INTERPRETED_RESULT": "success",
            "ZIZMOR_RESULT": "success",
            "PINPRICK_RESULT": "success",
            "LINKS_RESULT": "success",
            "CODECOV_RESULT": "success",
            "MATRIX": '[{"check":"test-tsan"}]',
            "RUN_CODEQL": "true",
            "RUN_CODEQL_INTERPRETED": "true",
            "RUN_ZIZMOR": "true",
            "RUN_LINKS": "true",
            "RUN_CODECOV": "true",
            "UPLOAD_ALLOWED": "true",
        }

    def conclude(self, **overrides):
        return subprocess.run(
            ["/bin/bash", "-euo", "pipefail", "-c", self.script],
            env={**os.environ, **self.environment, **overrides},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_required_results_cannot_be_skipped_or_unsuccessful(self):
        self.assertEqual(self.conclude().returncode, 0)
        for name in self.environment:
            if not name.endswith("_RESULT"):
                continue
            for result in ("skipped", "failure", "cancelled", "timed_out", ""):
                with self.subTest(job=name, result=result):
                    self.assertNotEqual(self.conclude(**{name: result}).returncode, 0)

    def test_only_unselected_routes_may_be_skipped(self):
        for route, results in (
            ("RUN_CODEQL", ("CODEQL_RESULT",)),
            ("RUN_CODEQL_INTERPRETED", ("CODEQL_INTERPRETED_RESULT",)),
            ("RUN_ZIZMOR", ("ZIZMOR_RESULT", "PINPRICK_RESULT")),
            ("RUN_LINKS", ("LINKS_RESULT",)),
            ("RUN_CODECOV", ("CODECOV_RESULT",)),
        ):
            with self.subTest(route=route):
                skipped = {result: "skipped" for result in results}
                self.assertEqual(self.conclude(**{route: "false", **skipped}).returncode, 0)
                for result in results:
                    self.assertNotEqual(
                        self.conclude(**{route: "false", **skipped, result: "failure"}).returncode,
                        0,
                    )
                self.assertNotEqual(self.conclude(**{route: ""}).returncode, 0)
        self.assertEqual(self.conclude(MATRIX="[]", CHECK_RESULT="skipped").returncode, 0)
        self.assertNotEqual(self.conclude(MATRIX="").returncode, 0)

    def test_push_and_fork_upload_exceptions_preserve_source_requirements(self):
        self.assertEqual(self.conclude(GITHUB_EVENT_NAME="push", COMMITS_RESULT="skipped").returncode, 0)
        self.assertEqual(self.conclude(UPLOAD_ALLOWED="false", CODECOV_RESULT="skipped").returncode, 0)
        self.assertNotEqual(
            self.conclude(UPLOAD_ALLOWED="false", CODECOV_RESULT="skipped", CHECK_RESULT="skipped").returncode,
            0,
        )
        self.assertNotEqual(self.conclude(UPLOAD_ALLOWED="").returncode, 0)
        self.assertNotEqual(self.conclude(GITHUB_EVENT_NAME="workflow_dispatch").returncode, 0)


if __name__ == "__main__":
    unittest.main()
