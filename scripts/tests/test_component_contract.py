import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_linter():
    path = ROOT / "scripts" / "lint-json.py"
    spec = importlib.util.spec_from_file_location("macosdb_lint_json", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def names_between(source, start, end):
    section = source.split(start, 1)[1].split(end, 1)[0]
    return set(re.findall(r'\bname:\s*"([^"]+)"', section))


class ComponentContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.linter = load_linter()
        cls.source = (ROOT / "Sources" / "macOSdbCore" / "Scanner" / "ScannerConfig.swift").read_text()

    def test_macos_linter_contract_matches_scanner_configuration(self):
        filesystem = names_between(
            self.source,
            "let filesystemComponents:",
            "// MARK: - dyld shared cache component definitions",
        )
        dyld = names_between(
            self.source,
            "let dyldCacheComponents:",
            "// MARK: - Toolchain component definitions",
        )
        self.assertEqual(filesystem | dyld, self.linter.MACOS_EXPECTED_COMPONENTS)

    def test_xcode_linter_contract_matches_scanner_configuration(self):
        toolchain = names_between(
            self.source,
            "let toolchainComponents:",
            "// MARK: - SDK component definitions",
        )
        sdk = names_between(self.source, "return [", "\n    ]\n}")
        self.assertEqual(toolchain | sdk | {"Python"}, self.linter.XCODE_EXPECTED_COMPONENTS)


if __name__ == "__main__":
    unittest.main()
