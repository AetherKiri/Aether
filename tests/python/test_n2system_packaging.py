import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "stage_n2system", Path(__file__).resolve().parents[2] / "tools/stage_n2system_runtime.py")
STAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGE)


class N2SystemPackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "publish"
        (self.source / "Fonts").mkdir(parents=True)
        (self.source / "Fonts/LICENSE_J.mplus").write_bytes(b"font license")
        (self.source / "Fonts/font.ttf").write_bytes(b"font data")
        (self.source / "aether_n2system.dylib").write_bytes(b"native host")
        (self.source / "debug.pdb").write_bytes(b"debug symbols")
        self.app = self.root / "Aether.app"
        self.native = self.app / "Contents/Frameworks/n2system-runtime"
        self.resources = self.app / "Contents/Resources/n2system-runtime"

    def test_macos_resources_keep_library_relative_lookup_after_bundle_moves(self):
        for _ in range(2):
            STAGE.stage(self.source, self.native, macos_bundle=True)
        self.assertTrue((self.native / "Fonts").is_symlink())
        self.assertFalse((self.native / "debug.pdb").exists())
        self.assertEqual((self.native / "aether_n2system.dylib").read_bytes(), b"native host")
        self.assertEqual((self.resources / "Fonts/LICENSE_J.mplus").read_bytes(), b"font license")
        moved = self.root / "installed/Aether.app"
        shutil.copytree(self.app, moved, symlinks=True)
        shutil.rmtree(self.app)
        self.assertEqual((moved / "Contents/Frameworks/n2system-runtime/Fonts/font.ttf").read_bytes(), b"font data")

    def test_disabled_runtime_removes_both_generated_trees(self):
        STAGE.stage(self.source, self.native, macos_bundle=True)
        STAGE.stage(None, self.native, macos_bundle=True)
        self.assertFalse(self.native.exists())
        self.assertFalse(self.resources.exists())

    def test_editor_and_other_platforms_keep_fonts_beside_host(self):
        destination = self.root / "editor/n2system-runtime"
        STAGE.stage(self.source, destination)
        self.assertFalse((destination / "Fonts").is_symlink())
        self.assertEqual((destination / "Fonts/font.ttf").read_bytes(), b"font data")

    def test_invalid_publish_path_preserves_previous_export(self):
        STAGE.stage(self.source, self.native, macos_bundle=True)
        with self.assertRaises(ValueError):
            STAGE.stage(self.root / "missing", self.native, macos_bundle=True)
        self.assertEqual((self.native / "Fonts/font.ttf").read_bytes(), b"font data")


if __name__ == "__main__":
    unittest.main()
