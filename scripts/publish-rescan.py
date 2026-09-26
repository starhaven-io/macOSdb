#!/usr/bin/env python3
"""Resume publication only when the remote commit matches the verified overlay."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote, urlencode


class PublicationError(Exception):
    """Existing publication state does not match this rescan."""


def api(endpoint: str, payload: dict | None = None):
    command = ["gh", "api", endpoint]
    if payload is not None:
        command += ["--method", "POST", "--input", "-"]
    result = subprocess.run(
        command, input=json.dumps(payload) if payload is not None else None,
        check=True, capture_output=True, text=True,
    )
    response = json.loads(result.stdout)
    if isinstance(response, dict) and response.get("errors"):
        raise PublicationError("GitHub rejected the publication request")
    return response


def verify_commit(repository: str, head: str, base: str, tree: str) -> None:
    commit = api(f"repos/{repository}/git/commits/{head}")
    if (
        [parent["sha"] for parent in commit["parents"]] != [base]
        or commit["tree"]["sha"] != tree
        or commit["verification"]["verified"] is not True
    ):
        raise PublicationError("publication commit must be signed and match the recorded base and verified tree")


def publish(repository: str, branch: str, base: str, tree: str, title: str,
            commit_body: str, pr_body: str, additions: list[dict]) -> dict:
    query = urlencode({"state": "all", "head": f"{repository.split('/')[0]}:{branch}",
                       "base": "main", "per_page": 100})
    pull_requests = api(f"repos/{repository}/pulls?{query}")
    if len(pull_requests) > 1:
        raise PublicationError("multiple pull requests exist for this rescan run")
    existing = pull_requests[0] if pull_requests else None
    if existing is not None:
        if (
            existing["head"]["repo"]["full_name"] != repository
            or existing["head"]["ref"] != branch
            or existing["base"]["repo"]["full_name"] != repository
            or existing["base"]["ref"] != "main"
        ):
            raise PublicationError("pull request identity does not match this rescan")
        verify_commit(repository, existing["head"]["sha"], base, tree)
        if existing["merged_at"] is not None:
            return existing
        if existing["state"] != "open":
            raise PublicationError("rescan pull request was closed without merging; use a fresh dispatch")

    reference = f"refs/heads/{branch}"
    refs = api(f"repos/{repository}/git/matching-refs/heads/{quote(branch, safe='/')}")
    matches = [ref for ref in refs if ref["ref"] == reference]
    if len(matches) > 1:
        raise PublicationError("ambiguous publication branch")
    if matches:
        if matches[0]["object"]["type"] != "commit":
            raise PublicationError("publication branch does not refer to a commit")
        head = matches[0]["object"]["sha"]
    else:
        if existing is not None:
            raise PublicationError("open rescan pull request has lost its branch")
        api(f"repos/{repository}/git/refs", {"ref": reference, "sha": base})
        head = base

    if existing is not None and existing["head"]["sha"] != head:
        raise PublicationError("publication branch no longer matches its pull request")

    if head == base:
        response = api("graphql", {
            "query": "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
            "variables": {"input": {
                "branch": {"repositoryNameWithOwner": repository, "branchName": branch},
                "message": {"headline": title, "body": commit_body},
                "fileChanges": {"additions": additions},
                "expectedHeadOid": base,
            }},
        })
        head = response["data"]["createCommitOnBranch"]["commit"]["oid"]
    verify_commit(repository, head, base, tree)

    if existing is None:
        existing = api(f"repos/{repository}/pulls", {
            "base": "main", "head": branch, "title": title, "body": pr_body,
        })
    if existing["head"]["sha"] != head:
        raise PublicationError("pull request head changed during publication")
    return existing


def main() -> int:
    parser = argparse.ArgumentParser()
    for name in ("repository", "branch", "base", "tree", "title", "commit-body", "pr-body", "additions", "github-output"):
        parser.add_argument(f"--{name}", required=True)
    args = parser.parse_args()
    try:
        result = publish(
            args.repository, args.branch, args.base, args.tree, args.title,
            args.commit_body, args.pr_body, json.loads(Path(args.additions).read_text()),
        )
        number = result["number"]
        if type(number) is not int or number < 1:
            raise PublicationError("GitHub returned an invalid pull request number")
        with Path(args.github_output).open("a") as output:
            output.write(f"pr_number={number}\n")
        if result["merged_at"] is None:
            subprocess.run([
                "gh", "pr", "merge", str(number), "--repo", args.repository,
                "--squash", "--auto", "--match-head-commit", result["head"]["sha"],
                "--delete-branch", "--body", args.commit_body,
            ], check=True)
        print(f"Rescan publication: {result['html_url']}")
    except (PublicationError, subprocess.CalledProcessError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"::error::Could not publish rescan: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
