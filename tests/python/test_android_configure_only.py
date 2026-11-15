"""Run the Android entry point with a toolchain probe instead of compiling an APK."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class AndroidConfigureOnlyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy(ROOT / "build.sh", self.root / "build.sh")
        shutil.copy(ROOT / "scripts/build_android.sh", self.root / "scripts/build_android.sh")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.log = self.root / "tool-commands"
        self.tool("cargo", "exit 0")
        self.tool("ninja", "exit 0")
        self.tool("cmake", 'printf "%s\\n" "$*" >> "$PROBE_LOG"\n'
                  'test "$1" = --preset\nexit "${PROBE_CONFIGURE_EXIT:-0}"')
        vcpkg = self.root / ".devtools/vcpkg"
        vcpkg.mkdir(parents=True)
        (vcpkg / ".vcpkg-root").touch()
        (vcpkg / "vcpkg").write_text("#!/bin/sh\nexit 0\n")
        (vcpkg / "vcpkg").chmod(0o755)
        ndk = self.root / "sdk/ndk/test"
        (ndk / "build/cmake").mkdir(parents=True)
        (ndk / "build/cmake/android.toolchain.cmake").touch()
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                        CARGO=str(self.tools / "cargo"), ANDROID_HOME=str(self.root / "sdk"),
                        ANDROID_NDK_HOME=str(ndk), PROBE_LOG=str(self.log),
                        AETHERKIRI_ENABLE_INTERNAL="OFF", AETHERKIRI_ENABLE_SOFTPAL_RUNTIME="OFF")
        for name in ("SKIP_ANDROID_VCPKG_INSTALL", "CMAKE_MAKE_PROGRAM",
                     "AETHERKIRI_WITH_INTERNAL", "AETHERKIRI_ENABLE_WA2",
                     "AETHERKIRI_LEAFTTT_DIR"):
            self.env.pop(name, None)

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_configure(self, configuration):
        return subprocess.run(["bash", "build.sh", "android", configuration,
                               "--configure-only", "--jobs=4"], cwd=self.root,
                              env=self.env, text=True, capture_output=True)

    def test_both_presets_prepare_dependencies_without_export_or_build(self):
        for configuration in ("release", "debug"):
            result = self.run_configure(configuration)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("configuration and dependencies are ready", result.stdout)
        calls = self.log.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertIn("Android arm64 Release Config", calls[0])
        self.assertIn("Android arm64 Debug Config", calls[1])
        self.assertFalse((self.root / "apps").exists())
        self.assertFalse((self.root / "out").exists())

    def test_dependency_failure_is_not_reported_as_ready(self):
        self.env["PROBE_CONFIGURE_EXIT"] = "17"
        result = self.run_configure("release")
        self.assertEqual(result.returncode, 17)
        self.assertNotIn("dependencies are ready", result.stdout)

    def test_public_build_disables_wa2_even_with_a_local_provider(self):
        package = self.root / "packages/AetherLeafTtt/cmake"
        package.mkdir(parents=True)
        (package / "AetherLeafTttConfig.cmake").touch()
        self.env["AETHERKIRI_WITH_INTERNAL"] = "false"
        result = self.run_configure("release")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("AETHERKIRI_ENABLE_WA2=OFF", self.log.read_text())

    def test_trusted_build_enables_wa2(self):
        self.env["AETHERKIRI_WITH_INTERNAL"] = "true"
        result = self.run_configure("release")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("AETHERKIRI_ENABLE_WA2=ON", self.log.read_text())

    def test_local_build_detects_provider_and_forwards_custom_directory(self):
        result = self.run_configure("release")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("AETHERKIRI_ENABLE_WA2=OFF", self.log.read_text())
        self.log.unlink()

        provider = self.root / "custom provider"
        (provider / "cmake").mkdir(parents=True)
        (provider / "cmake/AetherLeafTttConfig.cmake").touch()
        self.env["AETHERKIRI_LEAFTTT_DIR"] = str(provider)
        result = self.run_configure("release")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("AETHERKIRI_ENABLE_WA2=ON", self.log.read_text())
        self.assertIn(f"AETHERKIRI_LEAFTTT_DIR={provider}", self.log.read_text())

    def test_explicit_wa2_setting_overrides_ci_mode(self):
        for mode, setting, expected in (("true", "off", "OFF"), ("false", "yes", "ON")):
            with self.subTest(mode=mode, setting=setting):
                self.env["AETHERKIRI_WITH_INTERNAL"] = mode
                self.env["AETHERKIRI_ENABLE_WA2"] = setting
                result = self.run_configure("release")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"AETHERKIRI_ENABLE_WA2={expected}", self.log.read_text())
                self.log.unlink()

    def test_invalid_wa2_setting_fails_before_configure(self):
        self.env["AETHERKIRI_ENABLE_WA2"] = "invalid"
        result = self.run_configure("release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AETHERKIRI_ENABLE_WA2 must be ON/OFF or true/false", result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
