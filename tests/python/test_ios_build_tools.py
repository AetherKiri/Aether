import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("bash") and shutil.which("unzip"), "requires bash and unzip")
class IOSBuildToolsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aether ios tools ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        with zipfile.ZipFile(self.fixtures / "editor.zip", "w") as archive:
            archive.writestr("Godot.app/Contents/MacOS/Godot", "#!/bin/sh\nexit 0\n")
        ios = io.BytesIO()
        with zipfile.ZipFile(ios, "w") as archive:
            archive.writestr("libgodot.ios.debug.xcframework/library.a", b"iOS template")
        self.ios = ios.getvalue()
        self.write_templates(self.ios)
        tools = self.root / "tools"
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text("""#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
source = 'templates.tpz' if 'export_templates' in args[-1] else 'editor.zip'
shutil.copyfile(pathlib.Path(os.environ['GODOT_TEST_FIXTURES']) / source,
                args[args.index('-o') + 1])
""")
        curl.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        RUNNER_TEMP=str(self.downloads), GITHUB_WORKSPACE=str(self.root),
                        GITHUB_ENV=str(self.root / "github-env"), GODOT_RELEASE="4.7.2-stable",
                        GODOT_TEMPLATE_VERSION="4.7.2.stable", GODOT_TEST_HOME=str(self.root),
                        GODOT_TEST_FIXTURES=str(self.fixtures))
        self.installed = self.root / "Library/Application Support/Godot/export_templates/4.7.2.stable"

    def write_templates(self, ios):
        with zipfile.ZipFile(self.fixtures / "templates.tpz", "w") as archive:
            archive.writestr("templates/linux_debug.x86_64", b"unused Linux template")
            archive.writestr("templates/android_debug.apk", b"unused Android template")
            archive.writestr("templates/macos.zip", b"unused macOS template")
            if ios is not None:
                archive.writestr("templates/ios.zip", ios)

    def install(self):
        workflow = (REPO / ".github/workflows/build.yml").read_text()
        ios_job = workflow.split("  ios:\n", 1)[1].split("\n  macos:", 1)[0]
        step = ios_job.split("      - name: Install Godot export tools\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        # Execute the production step, redirecting only its install location.
        script = script.replace("${HOME}", "${GODOT_TEST_HOME}")
        return subprocess.run(["bash", "-c", script], cwd=self.root, env=self.env,
                              capture_output=True, text=True)

    def test_installs_only_ios_and_removes_downloads_before_native_build(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([path.name for path in self.installed.iterdir()], ["ios.zip"])
        self.assertEqual((self.installed / "ios.zip").read_bytes(), self.ios)
        self.assertEqual(list(self.downloads.iterdir()), [])
        self.assertTrue(os.access(self.root / ".godot/Godot.app/Contents/MacOS/Godot", os.X_OK))
        self.assertIn(f"GODOT_EXPORT_TEMPLATE={self.installed}/ios.zip\n",
                      (self.root / "github-env").read_text())

    def test_missing_ios_template_stops_installation(self):
        self.write_templates(None)
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "github-env").exists())

    def test_corrupt_ios_template_stops_installation(self):
        self.write_templates(b"not a zip archive")
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "github-env").exists())


if __name__ == "__main__":
    unittest.main()
