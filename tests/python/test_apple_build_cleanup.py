from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / ".github/scripts/clean-apple-build-intermediates.py"


class AppleBuildCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def write(self, relative):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")
        return path

    def run_cleanup(self, stage):
        return subprocess.run([sys.executable, str(SCRIPT), stage], cwd=self.root,
                              capture_output=True, text=True)

    def test_release_cleanup_preserves_exports_sources_and_other_builds(self):
        for platform, artifact in (("ios", "Aether-Release-Unsigned.ipa"),
                                   ("macos", "Aether.app/Contents/MacOS/Aether")):
            with self.subTest(platform=platform):
                retained = [self.write(path) for path in (
                    f"out/godot/{platform}/release/{artifact}",
                    f"out/godot/{platform}/release/Aether.xcodeproj/project.pbxproj",
                    f"out/{platform}/debug/object.o",
                    f"out/{platform}/release/vcpkg_installed/include/dependency.h",
                    f"out/{platform}/release/vcpkg_installed/lib/dependency.a",
                    f"apps/godot_app/bin/{platform}/release/runtime.a",
                    ".devtools/vcpkg/downloads/source.tar.gz",
                    ".devtools/vcpkg/installed/lib/dependency.a",
                    "packages/runtime/source.cpp",
                )]
                discarded = [self.write(path) for path in (
                    f"out/{platform}/release/bridge/runtime.a",
                    ".devtools/vcpkg/buildtrees/library/object.o",
                    ".devtools/vcpkg/packages/library/package.a",
                )]
                for _ in range(2):
                    result = self.run_cleanup(f"{platform}-release")
                    self.assertEqual(result.returncode, 0, result.stderr)
                for path in retained:
                    self.assertEqual(path.read_bytes(), b"fixture")
                for path in discarded:
                    self.assertFalse(path.exists())

    def test_macos_debug_retains_dependencies_for_fresh_test_build(self):
        artifact = self.write("out/godot/macos/debug/Aether.app/Contents/MacOS/Aether")
        installed = self.write(".devtools/vcpkg/installed/lib/dependency.a")
        intermediate = self.write("out/macos/debug/bridge/runtime.a")
        cache = self.write("out/macos/debug/CMakeCache.txt")
        dependencies = self.root / "out/macos/debug/vcpkg_installed"
        dependencies.symlink_to(installed.parents[1], target_is_directory=True)
        result = self.run_cleanup("macos-debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(dependencies.is_symlink())
        self.assertEqual((dependencies / "lib/dependency.a").read_bytes(), b"fixture")
        self.assertEqual(artifact.read_bytes(), b"fixture")
        self.assertFalse(intermediate.exists())
        self.assertFalse(cache.exists())

    def test_missing_export_prevents_any_cleanup(self):
        intermediate = self.write("out/ios/release/bridge/runtime.a")
        cache = self.write(".devtools/vcpkg/buildtrees/library/object.o")
        result = self.run_cleanup("ios-release")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(intermediate.read_bytes(), b"fixture")
        self.assertEqual(cache.read_bytes(), b"fixture")

    def test_macos_debug_retains_regular_dependency_install(self):
        self.write("out/godot/macos/debug/Aether.app/Contents/MacOS/Aether")
        installed = self.write("out/macos/debug/vcpkg_installed/lib/dependency.a")
        intermediate = self.write("out/macos/debug/bridge/runtime.a")
        result = self.run_cleanup("macos-debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(installed.read_bytes(), b"fixture")
        self.assertFalse(intermediate.exists())

    def test_redirected_cache_prevents_partial_cleanup(self):
        self.write("out/godot/ios/release/Aether-Release-Unsigned.ipa")
        intermediate = self.write("out/ios/release/bridge/runtime.a")
        protected = self.write("protected/object.o")
        cache = self.root / ".devtools/vcpkg/buildtrees"
        cache.parent.mkdir(parents=True)
        cache.symlink_to(protected.parent, target_is_directory=True)
        result = self.run_cleanup("ios-release")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(intermediate.read_bytes(), b"fixture")
        self.assertEqual(protected.read_bytes(), b"fixture")


if __name__ == "__main__":
    unittest.main()
