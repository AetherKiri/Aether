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


@unittest.skipUnless(shutil.which("bash"), "requires bash")
class IOSSDLArchiveTests(unittest.TestCase):
    def stage(self, root, build_type, triplet):
        # Run the production staging and isolation functions, recording the
        # source passed to the LLVM wrapper without needing Apple tools.
        script = (REPO / "scripts/build_ios.sh").read_text()
        start = script.index("\nios_vcpkg_library_dir() {")
        end = script.index("\ncombine_ios_static_extension() {", start)
        stage_start = script.index("\nstage_force_load_plugin_archives() {")
        stage_end = script.index("\nverify_exported_simulator_template_arch() {", stage_start)
        invocation = r"""
set -euo pipefail
PROJECT_ROOT="$1"
CMAKE_BUILD_DIR="$2"
BUILD_TYPE_LOWER="$3"
VCPKG_TRIPLET_DIR="$4"
FORCE_LOAD_PLUGIN_SOURCES=("absent-optional-plugin.a")
llvm-objcopy() { :; }
python3() { printf '%s\n' "$@"; }
"""
        return subprocess.run(
            ["bash", "-c", invocation + script[start:end] + script[stage_start:stage_end] + """
IOS_SDL2_ARCHIVE="$(resolve_ios_sdl2_archive "$VCPKG_TRIPLET_DIR")"
stage_force_load_plugin_archives "$CMAKE_BUILD_DIR/staged"
isolate_ios_runtime_sdl "$CMAKE_BUILD_DIR/staged"
""", "ios-sdl-test", str(REPO), str(root), build_type, triplet],
            capture_output=True, text=True,
        )

    def test_staging_and_isolation_use_same_sdl2_source(self):
        for build_type, triplet, debug_archives, selected in [
            ("debug", "arm64-ios", ("libSDL2d.a",), "debug/lib/libSDL2d.a"),
            ("debug", "arm64-ios-simulator", ("libSDL2.a",), "debug/lib/libSDL2.a"),
            ("debug", "x64-ios-simulator", (), "lib/libSDL2.a"),
            ("release", "arm64-ios", ("libSDL2d.a",), "lib/libSDL2.a"),
        ]:
            with self.subTest(build_type=build_type, triplet=triplet), \
                    tempfile.TemporaryDirectory(prefix="aether ios sdl ") as temporary:
                root = Path(temporary)
                installed = root / "vcpkg_installed" / triplet
                names = ["lib/libSDL2.a", *(f"debug/lib/{name}" for name in debug_archives)]
                for name in names:
                    archive = installed / name
                    archive.parent.mkdir(parents=True, exist_ok=True)
                    archive.write_text(name)
                result = self.stage(root, build_type, triplet)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                staged = root / "staged"
                self.assertEqual(list(staged.iterdir()), [staged / "libSDL2.a"])
                self.assertEqual((staged / "libSDL2.a").read_text(), selected)
                self.assertEqual(result.stdout.splitlines(), [
                    str(REPO / "tools/isolate_ios_sdl.py"),
                    "--sdl-archive", str(installed / selected),
                    "--directory", str(staged),
                ])

    def test_missing_sdl2_reports_selected_library_directory(self):
        with tempfile.TemporaryDirectory(prefix="aether ios sdl ") as temporary:
            root = Path(temporary)
            lib_dir = root / "vcpkg_installed/arm64-ios/debug/lib"
            lib_dir.mkdir(parents=True)
            (lib_dir / "libSDL2maind.a").touch()
            release_dir = lib_dir.parent.parent / "lib"
            release_dir.mkdir()
            (release_dir / "libSDL2.a").touch()
            result = self.stage(root, "debug", "arm64-ios")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("missing SDL2 static archive", result.stderr)
            self.assertIn(str(lib_dir), result.stderr)
            self.assertFalse((root / "staged").exists())


if __name__ == "__main__":
    unittest.main()
