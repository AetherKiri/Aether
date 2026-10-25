import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tools/check_ctest_inventory.py"


class CTestInventoryTests(unittest.TestCase):
    def check_inventory(self, tests):
        with tempfile.TemporaryDirectory() as directory:
            inventory = Path(directory) / "inventory.json"
            inventory.write_text(json.dumps({"tests": tests}))
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(inventory),
                 "--require-executable", "runtime-core-tests",
                 "--require-executable", "runtime-provider-tests"],
                capture_output=True, text=True,
            )

    def test_all_required_suites_are_discovered(self):
        result = self.check_inventory([
            {"name": "core case", "command": ["/build/runtime-core-tests", "core case"]},
            {"name": "provider case", "command": ["/build/runtime-provider-tests", "provider case"]},
            {"name": "other case", "command": ["/build/runtime-core-tests", "other case"]},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runtime-core-tests: 2", result.stdout)

    def test_other_suites_cannot_hide_an_omitted_runtime(self):
        result = self.check_inventory([
            {"name": "core case", "command": ["/build/runtime-core-tests"]},
            {"name": "another engine", "command": ["/build/other-engine-tests"]},
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime-provider-tests", result.stderr)

    def test_empty_or_unbuilt_discovery_is_rejected(self):
        for tests in [[], [{"name": "runtime-provider-tests"}]]:
            with self.subTest(tests=tests):
                result = self.check_inventory(tests)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("runtime-core-tests", result.stderr)


if __name__ == "__main__":
    unittest.main()
