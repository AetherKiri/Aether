import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "Requires a macOS SDK")
class MacOSSDKTests(unittest.TestCase):
    def test_presets_compile_standard_headers_with_sdk_iconv(self):
        # Exercise the real presets without building or downloading the app.
        # SDKROOT must not hide a missing SDK selection in a preset.
        env = os.environ.copy()
        env.pop("SDKROOT", None)
        sdk = Path(subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
            env=env, text=True).strip()).resolve()
        with tempfile.TemporaryDirectory(prefix="aether-macos-sdk-") as directory:
            source = Path(directory)
            (source / "CMakePresets.json").write_text(
                (ROOT / "CMakePresets.json").read_text())
            (source / "CMakeLists.txt").write_text("""
cmake_minimum_required(VERSION 3.28)
project(MacOSSDKProbe LANGUAGES C CXX)
find_package(Iconv REQUIRED)
add_executable(sdk_probe probe.cpp)
target_compile_features(sdk_probe PRIVATE cxx_std_17)
target_link_libraries(sdk_probe PRIVATE Iconv::Iconv)
file(WRITE "${CMAKE_BINARY_DIR}/sdk.txt" "${CMAKE_OSX_SYSROOT}")
""")
            (source / "probe.cpp").write_text("""
#include <cstddef>
#include <cstring>
#include <cmath>
#include <string>
#include <iconv.h>
int main() {
    const auto converter = iconv_open("UTF-8", "UTF-8");
    if (converter == (iconv_t)-1) return 1;
    return iconv_close(converter);
}
""")
            for arch in ("", " x64"):
                for mode in ("Debug", "Release"):
                    name = f"MacOS{arch} {mode}"
                    with self.subTest(preset=name):
                        for command in (
                            ["cmake", "--preset", f"{name} Config"],
                            ["cmake", "--build", "--preset", f"{name} Build"],
                        ):
                            result = subprocess.run(command, cwd=source, env=env,
                                                    capture_output=True, text=True)
                            self.assertEqual(result.returncode, 0,
                                             result.stdout + result.stderr)
                        platform = "macos-x64" if arch else "macos"
                        build = source / "out" / platform / mode.lower()
                        # Check the resolved toolchain, not the preset's spelling.
                        self.assertEqual(Path((build / "sdk.txt").read_text()).resolve(), sdk)
                        commands = json.loads((build / "compile_commands.json").read_text())
                        self.assertIn("-isysroot", commands[0]["command"])


if __name__ == "__main__":
    unittest.main()
