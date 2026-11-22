import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "stage_ios_runtime_frameworks", Path(__file__).resolve().parents[2] / "tools/stage_ios_runtime_frameworks.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IOSRuntimeFrameworkTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aether ios frameworks ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.extension = self.project / "runtime.gdextension"
        self.extension.write_text('[libraries]\nios.debug = "res://host.a"\n'
                                  '[dependencies]\nandroid.debug.arm64 = {"res://host.so": ""}\n')
        self.framework = self.root / "build" / "AetherEntisGLS.framework"
        self.framework.mkdir(parents=True)
        (self.framework / "AetherEntisGLS").write_bytes(b"framework executable")
        (self.framework / "Info.plist").write_bytes(b"bundle metadata")
        self.manifest = self.root / "frameworks.txt"
        self.manifest.write_text(str(self.framework) + "\n")

    def stage(self):
        return module.stage(self.manifest, self.project, "debug", self.extension)

    def test_stages_complete_bundle_and_preserves_other_platforms(self):
        target, = self.stage()
        self.assertEqual((target / "Info.plist").read_bytes(), b"bundle metadata")
        self.assertEqual((target / "AetherEntisGLS").read_bytes(), b"framework executable")
        text = self.extension.read_text()
        self.assertIn('ios.debug = "res://host.a"', text)
        self.assertIn('android.debug.arm64 = {"res://host.so": ""}', text)
        self.assertIn('"res://bin/ios/debug/AetherEntisGLS.framework": ""', text)

    def test_rebuild_replaces_bundle_and_disabled_provider_is_not_exported(self):
        target, = self.stage()
        (target / "obsolete").write_bytes(b"old object")
        (self.framework / "AetherEntisGLS").write_bytes(b"new binary")
        self.stage()
        self.assertFalse((target / "obsolete").exists())
        self.assertEqual((target / "AetherEntisGLS").read_bytes(), b"new binary")
        self.assertEqual(self.extension.read_text().count('ios.debug = {'), 1)
        self.manifest.write_text("")
        self.stage()
        self.assertNotIn(".framework", self.extension.read_text())

    def test_missing_framework_fails_before_modifying_export(self):
        before = self.extension.read_text()
        (self.framework / "AetherEntisGLS").unlink()
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual(self.extension.read_text(), before)

    def test_preserves_other_ios_dependencies_and_other_configuration(self):
        with self.extension.open("a") as output:
            output.write('ios.debug = {"res://plugins/Other.framework": "",}\n'
                         'ios.release = {"res://plugins/Release.framework": ""}\n')
        self.stage()
        self.manifest.write_text("")
        self.stage()
        text = self.extension.read_text()
        self.assertIn('"res://plugins/Other.framework": ""', text)
        self.assertIn('ios.release = {"res://plugins/Release.framework": ""}', text)
        self.assertNotIn("AetherEntisGLS.framework", text)

    @unittest.skipUnless(shutil.which("bash"), "requires bash")
    def test_export_restores_configuration_after_success_and_failure(self):
        repo = Path(__file__).resolve().parents[2]
        script = (repo / "scripts/build_ios.sh").read_text()
        function = "with_ios_only_gdextension() (" + script.split(
            "with_ios_only_gdextension() (", 1)[1].split('\necho "==> Building native engine', 1)[0]
        original = self.extension.read_text().replace(
            '[libraries]\n', '[libraries]\nmacos.debug = "res://host.dylib"\n')
        self.extension = self.project / "aether_kiri.gdextension"
        self.extension.write_text(original)
        (self.root / "runtime-frameworks-debug.txt").write_text(self.manifest.read_text())
        godot = self.root / "fake-godot"
        godot.write_text('''#!/usr/bin/env python3
import os
import sys
from pathlib import Path
assert '--recovery-mode' in sys.argv[1:]
text = (Path(os.environ["GODOT_APP_DIR"]) / "aether_kiri.gdextension").read_text()
assert 'res://bin/ios/debug/AetherEntisGLS.framework' in text
assert 'macos.debug' not in text
Path(os.environ["EXPORT_REACHED"]).touch()
raise SystemExit(int(os.environ["EXPORT_RESULT"]))
''')
        godot.chmod(0o755)
        marker = self.root / "export-reached"
        env = dict(os.environ, PROJECT_ROOT=str(repo), GODOT_APP_DIR=str(self.project),
                   CMAKE_BUILD_DIR=str(self.root), BUILD_TYPE_LOWER="debug", GODOT_BIN=str(godot),
                   EXPORT_MODE="--export-debug", EXPORT_PRESET="iOS Debug", EXPORT_REACHED=str(marker))
        for exit_code in (0, 23):
            with self.subTest(exit_code=exit_code):
                marker.unlink(missing_ok=True)
                result = subprocess.run(
                    ["bash", "-c", "set -euo pipefail\n" + function + "\nwith_ios_only_gdextension"],
                    env=dict(env, EXPORT_RESULT=str(exit_code)), capture_output=True, text=True)
                self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
                self.assertTrue(marker.exists(), "exporter must see the staged framework")
                self.assertEqual(self.extension.read_text(), original)


if __name__ == "__main__":
    unittest.main()
