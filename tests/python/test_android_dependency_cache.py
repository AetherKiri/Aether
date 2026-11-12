"""Exercise cache configuration without NuGet credentials or an Android SDK."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/configure-android-vcpkg-cache.py"
WORKFLOW = ROOT / ".github/workflows/build.yml"


def android_bootstrap_command():
    android_job = WORKFLOW.read_text().split("  android:\n", 1)[1]
    step = android_job.split("      - name: Bootstrap vcpkg\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


class AndroidVcpkgBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name) / "workspace with spaces"
        self.checkout = self.workspace / ".devtools/vcpkg"
        (self.checkout / ".git").mkdir(parents=True)
        self.downloads = self.workspace / ".aetherkiri-cache/android/vcpkg-downloads"
        self.binaries = self.workspace / ".aetherkiri-cache/android/vcpkg-binaries"
        self.env_file = self.workspace / "github-env"
        self.env = dict(os.environ, GITHUB_WORKSPACE=str(self.workspace),
                        GITHUB_ENV=str(self.env_file), VCPKG_DOWNLOADS=str(self.downloads),
                        VCPKG_DEFAULT_BINARY_CACHE=str(self.binaries))
        # Exercise the real workflow step with vcpkg's bootstrap precondition.
        # Cache configuration needs an already bootstrapped executable, so
        # testing configure-android-vcpkg-cache.py alone misses this earlier bug.
        bootstrap = self.checkout / "bootstrap-vcpkg.sh"
        bootstrap.write_text(textwrap.dedent("""\
            #!/bin/sh
            set -eu
            if [ ! -d "$VCPKG_DOWNLOADS" ]; then
              echo "VCPKG_DOWNLOADS was set, but that was not a directory." >&2
              exit 1
            fi
            test "$1" = -disableMetrics
            printf 'bootstrapped\\n' >> bootstrap-count
            printf '#!/bin/sh\\nexit 0\\n' > vcpkg
            chmod +x vcpkg
            """))
        bootstrap.chmod(0o755)

    def run_bootstrap(self):
        result = subprocess.run(["bash", "-euo", "pipefail", "-c",
                                 android_bootstrap_command()], cwd=self.workspace,
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.downloads.is_dir())
        self.assertTrue(self.binaries.is_dir())
        self.assertIn(f"VCPKG_ROOT={self.checkout}\n", self.env_file.read_text())

    def test_cache_miss_creates_directories_before_bootstrap(self):
        self.assertFalse(self.downloads.parent.exists())
        self.run_bootstrap()
        self.assertTrue(os.access(self.checkout / "vcpkg", os.X_OK))

    def test_cache_hit_preserves_downloads_and_binaries(self):
        self.downloads.mkdir(parents=True)
        self.binaries.mkdir(parents=True)
        source = self.downloads / "source.tar.gz"
        binary = self.binaries / "dependency.zip"
        source.write_bytes(b"cached source")
        binary.write_bytes(b"cached binary")
        self.run_bootstrap()
        self.assertEqual(source.read_bytes(), b"cached source")
        self.assertEqual(binary.read_bytes(), b"cached binary")

    def test_existing_tool_still_prepares_cache_directories(self):
        self.run_bootstrap()
        self.downloads.rmdir()
        self.binaries.rmdir()
        self.run_bootstrap()
        self.assertEqual((self.checkout / "bootstrap-count").read_text(), "bootstrapped\n")


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
