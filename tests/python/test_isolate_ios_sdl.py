"""Exercise SDL2 isolation at the actual object/archive/link boundary."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "isolate_ios_sdl", ROOT / "tools/isolate_ios_sdl.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SdlIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cc = shutil.which("cc")
        cls.ar = shutil.which("ar")
        try:
            cls.nm = MODULE.find_tool("llvm-nm")
            cls.objcopy = MODULE.find_tool("llvm-objcopy")
        except RuntimeError as error:
            raise unittest.SkipTest(str(error))
        if not cls.cc or not cls.ar:
            raise unittest.SkipTest("A native C compiler and archiver are required")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / "stage"
        self.stage.mkdir()
        self.sdl = self.archive("sdl2", """
            static unsigned initialized;
            int SDL_InitSubSystem(unsigned flags) { initialized |= flags; return 0; }
            unsigned SDL_WasInit(unsigned flags) { return initialized & flags; }
        """)
        shutil.copyfile(self.sdl, self.stage / "libSDL2.a")
        self.archive("native", """
            extern int SDL_InitSubSystem(unsigned);
            extern unsigned SDL_WasInit(unsigned);
            int native_start(void) {
                return SDL_InitSubSystem(16) == 0 ? (int) SDL_WasInit(16) : -1;
            }
        """, self.stage / "libnative.a")
        self.godot = self.archive("godot", """
            int SDL_InitSubSystem(unsigned flags) { return 1; }
            unsigned SDL_WasInit(unsigned flags) { return 0; }
        """)

    def archive(self, name, source, destination=None):
        src = self.root / (name + ".c")
        obj = self.root / (name + ".o")
        lib = destination or self.root / (name + ".a")
        src.write_text(source)
        subprocess.run([self.cc, "-c", str(src), "-o", str(obj)], check=True,
                       capture_output=True)
        subprocess.run([self.ar, "rcs", str(lib), str(obj)], check=True,
                       capture_output=True)
        return lib

    def run_app(self, name):
        main = self.root / "main.c"
        app = self.root / name
        main.write_text("""
            extern int SDL_InitSubSystem(unsigned);
            extern int native_start(void);
            int main(void) {
                return SDL_InitSubSystem(16) == 1 && native_start() == 16 ? 0 : 1;
            }
        """)
        subprocess.run([self.cc, str(main), str(self.godot),
                        str(self.stage / "libnative.a"),
                        str(self.stage / "libSDL2.a"), "-o", str(app)],
                       check=True, capture_output=True)
        return subprocess.run([str(app)]).returncode

    def test_keeps_godot_and_runtime_initialization_independent(self):
        self.assertEqual(self.run_app("before"), 1)
        self.assertEqual(MODULE.isolate(self.sdl, self.stage), 2)
        self.assertEqual(self.run_app("after"), 0)
        for archive in self.stage.glob("*.a"):
            self.assertFalse(MODULE.sdl_symbols(self.nm, archive))

    def test_repeated_staging_does_not_rewrite_isolated_archives(self):
        MODULE.isolate(self.sdl, self.stage)
        before = {p.name: p.read_bytes() for p in self.stage.glob("*.a")}
        self.assertEqual(MODULE.isolate(self.sdl, self.stage), 0)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.stage.glob("*.a")})

    def test_godot_sdk_fallbacks_are_left_in_godot_namespace(self):
        fallback = self.archive("fallback", "int SDL_NewerGodotApi(void) { return 1; }",
                                self.stage / "libios_sdk_compat_symbols.a")
        before = fallback.read_bytes()
        self.assertEqual(MODULE.isolate(self.sdl, self.stage), 2)
        self.assertEqual(before, fallback.read_bytes())
        self.assertTrue(MODULE.sdl_symbols(self.nm, fallback))

    def test_unknown_sdl_api_fails_before_changing_any_archive(self):
        self.archive("unknown", """
            extern int SDL_NotInThisVersion(void);
            int call_unknown(void) { return SDL_NotInThisVersion(); }
        """, self.stage / "libunknown.a")
        before = {p.name: p.read_bytes() for p in self.stage.glob("*.a")}
        with self.assertRaisesRegex(RuntimeError, "absent from the SDL2 archive"):
            MODULE.isolate(self.sdl, self.stage)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.stage.glob("*.a")})

    def test_wrong_source_archive_cannot_silently_skip_isolation(self):
        other = self.archive("other", "int another_library(void) { return 1; }")
        with self.assertRaisesRegex(RuntimeError, "no SDL symbols"):
            MODULE.isolate(other, self.stage)


if __name__ == "__main__":
    unittest.main()
