import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).parents[2]
SCRIPT = REPO_ROOT / "scripts" / "resolve-rescan.py"
SPEC = importlib.util.spec_from_file_location("resolve_rescan", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ResolveRescanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def publish(self, **overrides):
        detail = {
            "productType": "macOS",
            "osVersion": "12.3",
            "buildNumber": "21E230",
            "releaseDate": "2022-03-14",
            "isBeta": False,
            "isRC": False,
            "isDeviceSpecific": False,
            "ipswURL": "https://updates.cdn-apple.com/2022/UniversalMac_12.3_21E230_Restore.ipsw",
        }
        detail.update(overrides)
        release = self.root / "data/macos/releases/12/macOS-12.3-21E230.json"
        release.parent.mkdir(parents=True, exist_ok=True)
        release.write_text(json.dumps(detail), encoding="utf-8")
        entry = {"osVersion": "12.3", "buildNumber": "21E230", "dataFile": "releases/12/macOS-12.3-21E230.json"}
        (self.root / "data/macos/releases.json").write_text(json.dumps([entry]), encoding="utf-8")

    def test_published_metadata_becomes_rescan_inputs(self):
        self.publish(isRC=True, rcNumber=2)

        outputs = MODULE.resolve(self.root, "macos", "12.3", "21E230")

        self.assertEqual(outputs["data_file"], "data/macos/releases/12/macOS-12.3-21E230.json")
        self.assertEqual(outputs["archive_path"], "macOS/12/macOS-12.3-21E230.ipsw")
        self.assertEqual(outputs["release_date"], "2022-03-14")
        self.assertEqual((outputs["is_rc"], outputs["rc_number"]), ("true", "2"))
        self.assertEqual((outputs["is_beta"], outputs["beta_number"]), ("false", ""))

    def test_rejects_inputs_that_are_not_one_canonical_published_release(self):
        self.publish()
        for version, build in [("12.3", "21E231"), ("12.3/..", "21E230"), ("12.3", "21E230\n")]:
            with self.subTest(version=version, build=build), self.assertRaises(MODULE.ResolutionError):
                MODULE.resolve(self.root, "macos", version, build)

    def test_rejects_a_noncanonical_index_pointer(self):
        self.publish()
        entry = {"osVersion": "12.3", "buildNumber": "21E230", "dataFile": "releases/12/alias.json"}
        (self.root / "data/macos/releases.json").write_text(json.dumps([entry]), encoding="utf-8")

        with self.assertRaises(MODULE.ResolutionError):
            MODULE.resolve(self.root, "macos", "12.3", "21E230")

    def test_rejects_releases_a_rescan_cannot_reproduce(self):
        for overrides in [
            {"buildNumber": "21E231"},
            {"ipswURL": "https://updates.cdn-apple.com/x.ipsw\nnext=value"},
            {"isBeta": True},
        ]:
            with self.subTest(overrides=overrides):
                self.publish(**overrides)
                with self.assertRaises(MODULE.ResolutionError):
                    MODULE.resolve(self.root, "macos", "12.3", "21E230")

    def test_every_published_release_resolves(self):
        for product in ("macos", "xcode"):
            for entry in json.loads((REPO_ROOT / "data" / product / "releases.json").read_text()):
                with self.subTest(product=product, build=entry["buildNumber"]):
                    MODULE.resolve(REPO_ROOT, product, entry["osVersion"], entry["buildNumber"])


if __name__ == "__main__":
    unittest.main()
