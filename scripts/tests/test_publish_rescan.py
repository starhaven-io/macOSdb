import copy
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / "publish-rescan.py"
SPEC = importlib.util.spec_from_file_location("publish_rescan", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

REPOSITORY = "starhaven-io/macOSdb"
BRANCH = "fix/data-rescan-macOS-12.3-21E230-123"
BASE = "a" * 40
HEAD = "b" * 40
TREE = "c" * 40
ADDITIONS = [{"path": "data/macos/releases.json", "contents": "W10="}]


class GitHub:
    def __init__(self):
        self.head = None
        self.pr = None
        self.commit = {
            "parents": [{"sha": BASE}], "tree": {"sha": TREE},
            "verification": {"verified": True},
        }
        self.writes = []
        self.interrupt_after = None
        self.query_error = None

    def __call__(self, endpoint, payload=None):
        if self.query_error is not None:
            raise self.query_error
        prefix = f"repos/{REPOSITORY}"
        if endpoint.startswith(f"{prefix}/pulls?"):
            return [copy.deepcopy(self.pr)] if self.pr else []
        if endpoint.startswith(f"{prefix}/git/matching-refs/heads/"):
            return [{"ref": f"refs/heads/{BRANCH}", "object": {"type": "commit", "sha": self.head}}] if self.head else []
        if endpoint == f"{prefix}/git/commits/{HEAD}":
            return copy.deepcopy(self.commit)
        if endpoint == f"{prefix}/git/refs":
            assert payload == {"ref": f"refs/heads/{BRANCH}", "sha": BASE}
            assert self.head is None
            self.head = BASE
            result = {}
        elif endpoint == "graphql":
            request = payload["variables"]["input"]
            assert request["expectedHeadOid"] == self.head == BASE
            assert request["fileChanges"] == {"additions": ADDITIONS}
            self.head = HEAD
            result = {"data": {"createCommitOnBranch": {"commit": {"oid": HEAD}}}}
        elif endpoint == f"{prefix}/pulls":
            assert self.pr is None
            assert payload["head"] == BRANCH and payload["base"] == "main"
            self.pr = {
                "number": 42, "state": "open", "merged_at": None,
                "html_url": f"https://github.com/{REPOSITORY}/pull/42",
                "head": {"sha": HEAD, "ref": BRANCH, "repo": {"full_name": REPOSITORY}},
                "base": {"ref": "main", "repo": {"full_name": REPOSITORY}},
            }
            result = copy.deepcopy(self.pr)
        else:
            raise AssertionError(f"unexpected API request: {endpoint}")
        self.writes.append(endpoint)
        if len(self.writes) == self.interrupt_after:
            raise OSError("interrupted after remote mutation")
        return result


class PublishRescanTests(unittest.TestCase):
    def publish(self, github):
        with patch.object(MODULE, "api", side_effect=github):
            return MODULE.publish(REPOSITORY, BRANCH, BASE, TREE, "rescan", "signed off", "body", ADDITIONS)

    def test_new_publication_creates_one_signed_commit_and_pr(self):
        github = GitHub()
        result = self.publish(github)
        self.assertEqual(result["number"], 42)
        self.assertEqual(github.head, HEAD)
        self.assertEqual(len(github.writes), 3)

    def test_retry_recovers_after_each_remote_mutation_without_duplicates(self):
        for step in (1, 2, 3):
            with self.subTest(step=step):
                github = GitHub()
                github.interrupt_after = step
                with self.assertRaisesRegex(OSError, "interrupted"):
                    self.publish(github)
                github.interrupt_after = None
                self.assertEqual(self.publish(github)["number"], 42)
                self.assertEqual(len(github.writes), 3)

    def test_retry_after_merge_does_not_recreate_deleted_branch(self):
        github = GitHub()
        self.publish(github)
        github.pr.update(state="closed", merged_at="2026-09-25T01:00:00Z")
        github.head = None
        self.assertEqual(self.publish(github)["number"], 42)
        self.assertEqual(len(github.writes), 3)
        self.assertIsNone(github.head)

    def test_unexpected_or_unsigned_commit_stops_before_pr_creation(self):
        mutations = [
            {"tree": {"sha": "d" * 40}},
            {"parents": [{"sha": "d" * 40}]},
            {"parents": [{"sha": BASE}, {"sha": "d" * 40}]},
            {"verification": {"verified": False}},
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                github = GitHub()
                github.head = HEAD
                github.commit.update(mutation)
                with self.assertRaisesRegex(MODULE.PublicationError, "recorded base and verified tree"):
                    self.publish(github)
                self.assertEqual(github.writes, [])

    def test_closed_unmerged_pr_requires_new_dispatch(self):
        github = GitHub()
        self.publish(github)
        github.pr["state"] = "closed"
        with self.assertRaisesRegex(MODULE.PublicationError, "closed without merging"):
            self.publish(github)
        self.assertEqual(len(github.writes), 3)

    def test_pull_request_identity_and_head_are_bound(self):
        for change in ("repository", "branch", "base", "head"):
            with self.subTest(change=change):
                github = GitHub()
                self.publish(github)
                if change == "repository":
                    github.pr["head"]["repo"]["full_name"] = "other/macOSdb"
                elif change == "branch":
                    github.pr["head"]["ref"] = "other"
                elif change == "base":
                    github.pr["base"]["ref"] = "other"
                else:
                    github.head = BASE
                with self.assertRaises(MODULE.PublicationError):
                    if change == "head":
                        github.pr["head"]["sha"] = "d" * 40
                        with patch.object(MODULE, "verify_commit"):
                            self.publish(github)
                    else:
                        self.publish(github)
                self.assertEqual(len(github.writes), 3)

    def test_failed_github_read_never_creates_or_overwrites_state(self):
        github = GitHub()
        github.query_error = OSError("GitHub unavailable")
        with self.assertRaisesRegex(OSError, "unavailable"):
            self.publish(github)
        self.assertEqual(github.writes, [])

    def test_workflow_separates_dispatches_but_keeps_retry_identity(self):
        workflow = (SCRIPT.parents[1] / ".github/workflows/rescan.yml").read_text()
        self.assertIn('BRANCH="fix/data-rescan-${BASENAME}-${GITHUB_RUN_ID}"', workflow)
        self.assertNotIn("GITHUB_RUN_ATTEMPT", workflow)
        self.assertIn("python3 scripts/publish-rescan.py", workflow)
        self.assertIn('TREE_SHA=$(git write-tree)', workflow)
        self.assertLess(workflow.index("--replace"), workflow.index("- name: Mint bot token"))


if __name__ == "__main__":
    unittest.main()
