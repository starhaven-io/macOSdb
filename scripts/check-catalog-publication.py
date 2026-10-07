#!/usr/bin/env python3
"""Stop a scanner dispatch while a previous catalog publication is unresolved."""

import argparse
import json
import re
import subprocess
import sys


def pending_publications(pages, repository):
    if not isinstance(pages, list) or not pages:
        raise ValueError("missing pull-request pages")
    pending = []
    for page in pages:
        if not isinstance(page, list):
            raise ValueError("invalid pull-request page")
        for pr in page:
            if not isinstance(pr, dict):
                raise ValueError("invalid pull-request record")
            state = pr["state"]
            base = pr["base"]["ref"]
            author = pr["user"]["login"]
            branch = pr["head"]["ref"]
            if not all(isinstance(value, str) and value for value in (state, base, author, branch)):
                raise ValueError("incomplete pull-request metadata")
            if state != "open" or base != "main" or author != "starhaven-bot[bot]":
                continue
            if not branch.startswith(("feat/data-", "fix/data-rescan-")):
                continue
            head_repo = pr["head"]["repo"]["full_name"]
            if not isinstance(head_repo, str) or not head_repo:
                raise ValueError("missing publication repository")
            if head_repo.casefold() != repository.casefold():
                continue
            number = pr["number"]
            if type(number) is not int or number <= 0:
                raise ValueError("invalid publication PR number")
            pending.append(number)
    return sorted(set(pending))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("repository must be owner/name")
    try:
        result = subprocess.run(
            ["gh", "api", "--paginate", "--slurp",
             f"repos/{args.repository}/pulls?state=open&base=main&per_page=100"],
            check=True, capture_output=True, text=True, timeout=60,
        )
        pending = pending_publications(json.loads(result.stdout), args.repository)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        print("::error::Could not verify pending catalog publications; refusing to scan.", file=sys.stderr)
        return 1
    if pending:
        numbers = ", ".join(f"#{number}" for number in pending)
        print(f"::error::Catalog publication still open: {numbers}. "
              "Merge or close it, then start a fresh scanner dispatch.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
