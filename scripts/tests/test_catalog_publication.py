import copy
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_workflow_inputs import workflow_run_block


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check-catalog-publication.py"
REPOSITORY = "starhaven-io/macOSdb"
WORKFLOWS = ("scan-ipsw.yml", "scan-xip.yml", "rescan.yml")


def publication(branch="feat/data-macOS-27.0", number=123):
    return {"number": number, "state": "open", "base": {"ref": "main"},
            "user": {"login": "starhaven-bot[bot]"},
            "head": {"ref": branch, "repo": {"full_name": REPOSITORY}}}


class CatalogPublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text("""#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
Path(os.environ['GH_ARGS']).write_text(json.dumps(sys.argv[1:]))
if os.environ.get('MERGE_SOURCE'):
    source = Path(os.environ['MERGE_SOURCE'])
    (source / 'index').write_text('previous catalog PR merged')
    subprocess.run(['git', '-C', str(source), 'commit', '-qam', 'Merge previous catalog'], check=True)
print(os.environ['GH_RESPONSE'])
sys.exit(int(os.environ.get('GH_EXIT', '0')))
""")
        gh.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "GH_ARGS": str(self.root / "args"), "GH_RESPONSE": "[[]]",
                    "GITHUB_REPOSITORY": REPOSITORY}

    def run_guard(self, pages, **env):
        return subprocess.run(
            ["python3", "-B", str(SCRIPT), "--repository", REPOSITORY],
            env={**self.env, "GH_RESPONSE": json.dumps(pages), **env},
            capture_output=True, text=True,
        )

    def test_each_catalog_branch_blocks_even_on_a_later_page(self):
        for branch in ("feat/data-macOS-27.0", "feat/data-Xcode-27", "fix/data-rescan-macos-27"):
            with self.subTest(branch=branch):
                result = self.run_guard([[], [publication(branch)]])
                self.assertEqual(result.returncode, 1)
                self.assertIn("#123", result.stderr)
                self.assertIn("fresh scanner dispatch", result.stderr)
        self.assertEqual(json.loads((self.root / "args").read_text()),
                         ["api", "--paginate", "--slurp",
                          f"repos/{REPOSITORY}/pulls?state=open&base=main&per_page=100"])

    def test_empty_inventory_and_unrelated_prs_do_not_block(self):
        self.assertEqual(self.run_guard([[]]).returncode, 0)
        cases = []
        for field, value in (("state", "closed"), ("number", 124)):
            pr = publication()
            pr[field] = value
            if field == "number":
                pr["head"]["ref"] = "fleet-sync-v2026.10.6"
            cases.append(pr)
        for path, value in ((("base", "ref"), "topic"), (("user", "login"), "contributor"),
                            (("head", "repo", "full_name"), "contributor/macOSdb")):
            pr = publication()
            target = pr
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            cases.append(pr)
        result = self.run_guard([cases])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unknown_inventory_fails_closed(self):
        malformed = [None, [], {}, [None], [[{}]], [[None]]]
        for path in (("head", "repo"), ("head", "ref"), ("user",), ("number",)):
            pr = copy.deepcopy(publication())
            target = pr
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = None
            malformed.append([[pr]])
        for pages in malformed:
            with self.subTest(pages=pages):
                result = self.run_guard(pages)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Could not verify", result.stderr)
        result = self.run_guard([[]], GH_EXIT="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Could not verify", result.stderr)
        result = self.run_guard([[]], GH_RESPONSE="truncated JSON")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Could not verify", result.stderr)

    def git(self, path, *args):
        return subprocess.run(["git", "-C", str(path), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_workflows_stop_before_scanning_and_refresh_a_pr_merged_during_the_query(self):
        for name in WORKFLOWS:
            with self.subTest(workflow=name):
                source = self.root / name
                source.mkdir()
                self.git(source, "init", "-b", "main")
                self.git(source, "config", "user.name", "Fixture")
                self.git(source, "config", "user.email", "fixture@example.invalid")
                self.git(source, "config", "commit.gpgsign", "false")
                self.git(source, "config", "core.hooksPath", "/dev/null")
                (source / "index").write_text("old catalog")
                self.git(source, "add", "index")
                self.git(source, "commit", "-m", "Base")
                checkout = self.root / f"checkout-{name}"
                self.git(self.root, "clone", str(source), str(checkout))
                (checkout / "scripts").mkdir()
                shutil.copyfile(SCRIPT, checkout / "scripts/check-catalog-publication.py")
                old_head = self.git(checkout, "rev-parse", "HEAD")
                workflow = (ROOT / ".github/workflows" / name).read_text()
                prepare = workflow.split("\n  scan:\n", 1)[0]
                self.assertIn("      pull-requests: read #", prepare)
                self.assertIn("          GH_TOKEN: ${{ github.token }}\n", prepare)
                self.assertIn("    needs: prepare\n", workflow.split("\n  scan:\n", 1)[1])
                step = "Require previous catalog publication to finish"
                self.assertLess(prepare.index(step), prepare.index('echo "base_sha='))
                script = workflow_run_block(prepare, step)
                blocked = subprocess.run(
                    ["/bin/bash", "-euo", "pipefail", "-c", script], cwd=checkout,
                    env={**self.env, "GH_RESPONSE": json.dumps([[publication()]])},
                    capture_output=True, text=True,
                )
                self.assertNotEqual(blocked.returncode, 0, blocked.stderr)
                self.assertEqual(self.git(checkout, "rev-parse", "HEAD"), old_head)
                merged = subprocess.run(
                    ["/bin/bash", "-euo", "pipefail", "-c", script], cwd=checkout,
                    env={**self.env, "MERGE_SOURCE": str(source)},
                    capture_output=True, text=True,
                )
                self.assertEqual(merged.returncode, 0, merged.stderr)
                self.assertNotEqual(self.git(checkout, "rev-parse", "HEAD"), old_head)
                self.assertEqual(self.git(checkout, "rev-parse", "HEAD"),
                                 self.git(source, "rev-parse", "HEAD"))
                self.assertEqual((checkout / "index").read_text(), "previous catalog PR merged")


if __name__ == "__main__":
    unittest.main()
