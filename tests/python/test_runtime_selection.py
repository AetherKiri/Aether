from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
CMAKE = shutil.which("cmake")


@unittest.skipUnless(CMAKE, "CMake is required")
class RuntimeSelectionTests(unittest.TestCase):
    def check_runtime(self, runtime, enabled, *definitions):
        with tempfile.TemporaryDirectory(prefix="aether-runtime-selection-") as directory:
            script = Path(directory) / "check.cmake"
            script.write_text(
                'cmake_minimum_required(VERSION 3.28)\n'
                f'include("{(REPO / "cmake/AetherKiriRuntimes.cmake").as_posix()}")\n'
                f'if(NOT DEFINED AETHERKIRI_ENABLE_{runtime})\n'
                f'  message(FATAL_ERROR "{runtime} selection option is missing")\n'
                'endif()\n'
                f'message(STATUS "SELECTED=${{AETHERKIRI_ENABLE_{runtime}}}")\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                [CMAKE, *definitions, "-P", str(script)],
                capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"SELECTED={'ON' if enabled else 'OFF'}", result.stdout)
        inventory = next(
            line.split("Enabled runtimes: ", 1)[1]
            for line in result.stdout.splitlines() if "Enabled runtimes: " in line
        )
        self.assertEqual(runtime in inventory.split(";"), enabled)

    def test_cmvs_enabled_by_default_on_product_platforms(self):
        for platform in ["Darwin", "iOS", "Android", "Linux"]:
            with self.subTest(platform=platform):
                self.check_runtime("CMVS", True, f"-DCMAKE_SYSTEM_NAME={platform}")

    def test_exhibit_selection(self):
        for platform in ("Darwin", "iOS", "Android", "Linux", "Windows", "Emscripten"):
            with self.subTest(platform=platform):
                self.check_runtime("EXHIBIT", True, f"-DCMAKE_SYSTEM_NAME={platform}")
        self.check_runtime("EXHIBIT", False, "-DAETHERKIRI_ENABLE_EXHIBIT=OFF")
        self.check_runtime("EXHIBIT", False, "-DAETHERKIRI_RUNTIMES_DEFAULT=OFF")
        self.check_runtime("EXHIBIT", True, "-DAETHERKIRI_RUNTIMES_DEFAULT=OFF",
                           "-DAETHERKIRI_ENABLE_EXHIBIT=ON")

    def test_systemnnn_selection(self):
        self.check_runtime("SYSTEMNNN", True)
        for platform in ("WEB", "EMSCRIPTEN"):
            with self.subTest(platform=platform):
                self.check_runtime("SYSTEMNNN", False, f"-D{platform}=ON")
        self.check_runtime("SYSTEMNNN", False, "-DAETHERKIRI_ENABLE_SYSTEMNNN=OFF")
        self.check_runtime("SYSTEMNNN", False, "-DAETHERKIRI_RUNTIMES_DEFAULT=OFF")
        self.check_runtime("SYSTEMNNN", True, "-DAETHERKIRI_RUNTIMES_DEFAULT=OFF",
                           "-DAETHERKIRI_ENABLE_SYSTEMNNN=ON")

    def test_explicit_disable_is_preserved(self):
        self.check_runtime("CMVS", False, "-DAETHERKIRI_ENABLE_CMVS=OFF")

    def test_selective_build_can_disable_all_runtimes(self):
        self.check_runtime("CMVS", False, "-DAETHERKIRI_RUNTIMES_DEFAULT=OFF")

    def test_selective_build_can_enable_cmvs(self):
        self.check_runtime("CMVS", True, "-DAETHERKIRI_RUNTIMES_DEFAULT=OFF",
                        "-DAETHERKIRI_ENABLE_CMVS=ON")


if __name__ == "__main__":
    unittest.main()
