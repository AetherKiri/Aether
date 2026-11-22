from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
CMAKE = shutil.which("cmake")


@unittest.skipUnless(CMAKE, "CMake is required")
class LinuxVcpkgCacheMigrationTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="aether linux cache ")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name).resolve()
        self.linux_output = self.root / "out/linux"
        self.build = self.linux_output / "debug"
        self.shared = self.linux_output / "vcpkg_installed"
        self.old_debug = self.build / "vcpkg_installed"
        self.old_release = self.linux_output / "release/vcpkg_installed"
        helper = REPO / "cmake/MigrateLinuxVcpkgCache.cmake"
        (self.root / "CMakeLists.txt").write_text(
            f"""cmake_minimum_required(VERSION 3.28)
include("{helper.as_posix()}")
aetherkiri_migrate_linux_vcpkg_cache()
project(cache_migration NONE)
set(AETHERKIRI_XSYSTEM4_DIR "${{CMAKE_SOURCE_DIR}}/bundled" CACHE PATH "")
""",
            encoding="utf-8",
        )

    def configure(self, *definitions):
        result = subprocess.run(
            [CMAKE, "-S", str(self.root), "-B", str(self.build), *definitions],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return (self.build / "CMakeCache.txt").read_text(encoding="utf-8")

    def test_migrates_only_stale_dependency_results(self):
        checkout = self.root / "local engines/System 4"
        checkout_override = f"AETHERKIRI_XSYSTEM4_DIR:PATH={checkout}"
        preset_install = f"-DVCPKG_INSTALLED_DIR:PATH={self.shared}"
        self.configure(
            f"-D{checkout_override}",
            f"-DVCPKG_INSTALLED_DIR:PATH={self.old_debug}",
            f"-D_VCPKG_INSTALLED_DIR:PATH={self.old_debug}",
            f"-DJPEG_LIBRARY_RELEASE:FILEPATH={self.old_release}/lib/libjpeg.so",
            f"-DFFMPEG_LIBRARIES:STRING=m;{self.old_debug}/lib/libavutil.so",
            "-D__pkg_config_checked_ass:INTERNAL=1",
            "-DAETHERKIRI_ENABLE_MAGES:BOOL=OFF",
        )
        cache = self.configure(preset_install)
        self.assertIn(checkout_override, cache)
        self.assertIn("AETHERKIRI_ENABLE_MAGES:BOOL=OFF", cache)
        self.assertIn(f"VCPKG_INSTALLED_DIR:PATH={self.shared}", cache)
        for entry in ("_VCPKG_INSTALLED_DIR", "JPEG_LIBRARY_RELEASE",
                      "FFMPEG_LIBRARIES", "__pkg_config_checked_ass"):
            self.assertNotIn(f"\n{entry}:", cache)

        library = f"JPEG_LIBRARY_RELEASE:FILEPATH={self.shared}/lib/libjpeg.so"
        cache = self.configure(preset_install, f"-D{library}",
                               "-D__pkg_config_checked_ass:INTERNAL=1")
        self.assertIn(library, cache)
        self.assertIn("__pkg_config_checked_ass:INTERNAL=1", cache)
        self.assertIn(checkout_override, cache)

    def test_explicit_install_root_is_not_migrated(self):
        library = f"JPEG_LIBRARY_RELEASE:FILEPATH={self.old_debug}/lib/libjpeg.so"
        custom_install = self.root / "custom-vcpkg"
        self.configure(f"-DVCPKG_INSTALLED_DIR:PATH={custom_install}", f"-D{library}")
        cache = self.configure()
        self.assertIn(f"VCPKG_INSTALLED_DIR:PATH={custom_install}", cache)
        self.assertIn(library, cache)


if __name__ == "__main__":
    unittest.main()
