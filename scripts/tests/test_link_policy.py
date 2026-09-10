import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class LinkPolicyTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("lychee"), "link-checker integration requires lychee; just check requires this tool")
    def test_release_links_resolve_to_built_files_and_missing_pages_fail(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        links = workflow.split("  links:\n", 1)[1].split("\n  conclusion:", 1)[0]
        args = json.loads(re.search(r'args: ("[^\n]+")', links).group(1))
        with tempfile.TemporaryDirectory(prefix="macosdb-link-policy-") as directory:
            path = Path(directory)
            for name in ("README.md", "SECURITY.md", "CONTRIBUTING.md", "docs/test.md"):
                (path / name).parent.mkdir(parents=True, exist_ok=True)
                (path / name).write_text("fixture\n")
            (path / "lychee.toml").write_bytes((ROOT / "lychee.toml").read_bytes())
            for product in ("macos", "xcode"):
                target = path / "site/dist/client" / product / "release/99.0-99A1/index.html"
                target.parent.mkdir(parents=True)
                target.write_text(f'<a href="https://macosdb.com/{product}/release/99.0-99A1/">release</a>')
            command = 'eval "set -- ${LYCHEE_ARGS}"; lychee --offline --no-progress --format json "$@"'
            environment = {**os.environ, "GITHUB_WORKSPACE": str(path), "LYCHEE_ARGS": args}
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", command], cwd=path, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            report = json.loads(result.stdout)
            self.assertEqual(report["successful"], 2)
            self.assertEqual(report["total"], 2)
            target.unlink()
            (path / "site/dist/client/index.html").write_text('<a href="https://macosdb.com/xcode/release/99.0-99A1/index.html">missing</a>')
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", command], cwd=path, env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
