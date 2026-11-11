"""Exercise cache configuration without NuGet credentials or an Android SDK."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/configure-android-vcpkg-cache.py"


class AndroidDependencyCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.vcpkg = self.tools / "vcpkg"
        self.vcpkg.write_bytes(b"vcpkg version 1")
        self.ndk = self.root / "ndk"
        self.ndk.mkdir()
        (self.ndk / "source.properties").write_text("Pkg.Revision = 28.1.13356709\n")
        for tool in ("cc", "c++", "cmake", "ninja", "git"):
            self.set_tool(tool, "tool version 1")
        self.env_file = self.root / "github-env"
        self.output_file = self.root / "github-output"
        self.cache = self.root / "binary cache"
        self.downloads = self.root / "downloads"
        self.env = dict(os.environ, PATH=str(self.tools),
                        VCPKG_DEFAULT_BINARY_CACHE=str(self.cache),
                        VCPKG_DOWNLOADS=str(self.downloads),
                        ANDROID_NDK_HOME=str(self.ndk), GITHUB_ENV=str(self.env_file),
                        GITHUB_OUTPUT=str(self.output_file))
        self.env.pop("VCPKG_PACKAGES_TOKEN", None)

    def set_tool(self, name, version):
        tool = self.tools / name
        tool.write_text(f"#!/bin/sh\nprintf '%s\\n' '{version}'\n")
        tool.chmod(0o755)

    def run_configure(self):
        self.env_file.write_text("EXISTING_SETTING=retained\n")
        self.output_file.write_text("existing-output=retained\n")
        return subprocess.run([sys.executable, str(SCRIPT), str(self.vcpkg)],
                              env=self.env, capture_output=True, text=True)

    def key(self):
        result = self.run_configure()
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.output_file.read_text().split("toolchain-key=")[1].strip()

    def test_replaces_broken_remote_with_reusable_local_cache_without_credentials(self):
        self.env["VCPKG_BINARY_SOURCES"] = "clear;nuget,https://invalid.example,readwrite"
        for trusted in ("true", "false"):
            with self.subTest(trusted=trusted):
                self.env["AETHERKIRI_VCPKG_CACHE_WRITE"] = trusted
                self.key()
                self.assertEqual(self.env_file.read_text(),
                                 "EXISTING_SETTING=retained\n"
                                 f"VCPKG_BINARY_SOURCES=clear;files,{self.cache},readwrite\n")
                self.assertTrue(self.cache.is_dir())
                self.assertTrue(self.downloads.is_dir())
                self.assertTrue(self.output_file.read_text().startswith("existing-output=retained\n"))

    def test_key_is_stable_across_runs_and_build_configurations(self):
        self.env["GITHUB_RUN_ID"] = "100"
        self.env["CMAKE_BUILD_TYPE"] = "Release"
        first = self.key()
        self.env["GITHUB_RUN_ID"] = "101"
        self.env["CMAKE_BUILD_TYPE"] = "Debug"
        self.assertEqual(first, self.key())
        self.assertRegex(first, r"^[0-9a-f]{64}$")

    def test_toolchain_changes_invalidate_the_key(self):
        previous = self.key()
        mutations = [lambda: self.vcpkg.write_bytes(b"vcpkg version 2"),
                     lambda: (self.ndk / "source.properties").write_text("Pkg.Revision = 29\n"),
                     lambda: self.set_tool("cc", "compiler version 2"),
                     lambda: self.set_tool("c++", "compiler version 2"),
                     lambda: self.set_tool("cmake", "cmake version 2"),
                     lambda: self.set_tool("ninja", "ninja version 2"),
                     lambda: self.set_tool("git", "new vcpkg checkout")]
        for mutate in mutations:
            mutate()
            current = self.key()
            self.assertNotEqual(previous, current)
            previous = current

    def test_provider_separators_in_paths_are_escaped(self):
        self.env["VCPKG_DEFAULT_BINARY_CACHE"] = str(self.root / "cache,semi;tick`")
        self.key()
        self.assertIn("cache`,semi`;tick``,readwrite\n", self.env_file.read_text())

    def test_missing_toolchain_does_not_publish_partial_configuration(self):
        (self.ndk / "source.properties").unlink()
        result = self.run_configure()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.env_file.read_text(), "EXISTING_SETTING=retained\n")
        self.assertEqual(self.output_file.read_text(), "existing-output=retained\n")
        self.assertFalse(self.cache.exists())

    def test_newline_in_path_cannot_inject_github_environment(self):
        self.env["VCPKG_DEFAULT_BINARY_CACHE"] = str(self.root / "cache\nINJECTED=value")
        result = self.run_configure()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.env_file.read_text(), "EXISTING_SETTING=retained\n")


if __name__ == "__main__":
    unittest.main()
