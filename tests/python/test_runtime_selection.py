import subprocess
import tempfile
from pathlib import Path
import unittest


REPO = Path(__file__).resolve().parents[2]


class RuntimeSelectionTests(unittest.TestCase):
    def _select(self, *definitions):
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "select.cmake"
            script.write_text(
                f'include("{(REPO / "cmake/AetherKiriRuntimes.cmake").as_posix()}")\n'
                'if(AETHERKIRI_ENABLE_SYSTEMNNN)\n'
                '  message(STATUS "SYSTEMNNN_SELECTED=ON")\n'
                'else()\n'
                '  message(STATUS "SYSTEMNNN_SELECTED=OFF")\n'
                'endif()\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                ["cmake", *definitions, "-P", str(script)],
                check=True, capture_output=True, text=True,
            )
            return result.stdout

    def test_native_default_enables_systemnnn(self):
        self.assertIn("SYSTEMNNN_SELECTED=ON", self._select())

    def test_web_default_disables_systemnnn(self):
        for platform in ("WEB", "EMSCRIPTEN"):
            with self.subTest(platform=platform):
                self.assertIn("SYSTEMNNN_SELECTED=OFF", self._select(f"-D{platform}=ON"))

    def test_selective_build_omits_systemnnn_unless_requested(self):
        self.assertIn("SYSTEMNNN_SELECTED=OFF", self._select("-DAETHERKIRI_RUNTIMES_DEFAULT=OFF"))
        selected = self._select("-DAETHERKIRI_RUNTIMES_DEFAULT=OFF", "-DAETHERKIRI_ENABLE_SYSTEMNNN=ON")
        self.assertIn("Enabled runtimes: SYSTEMNNN", selected)
        self.assertIn("SYSTEMNNN_SELECTED=ON", selected)

    def test_explicit_disable_overrides_native_default(self):
        self.assertIn("SYSTEMNNN_SELECTED=OFF", self._select("-DAETHERKIRI_ENABLE_SYSTEMNNN=OFF"))


if __name__ == "__main__":
    unittest.main()
