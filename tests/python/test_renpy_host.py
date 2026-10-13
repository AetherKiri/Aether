import importlib.util
from pathlib import Path
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("renpy_host_tests", REPO / "apps/godot_app/renpy_runtime/host.py")
HOST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOST)


class RenpyHostTests(unittest.TestCase):
    def test_writable_copy_does_not_modify_original_or_import_saves(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "original"
            source.mkdir()
            (source / "story.rpy").write_text('label start:\n    "original"\n')
            (source / "images").mkdir()
            (source / "images/scene.bin").write_bytes(b"original image")
            (source / "images/cache").mkdir()
            (source / "images/cache/asset").write_text("game asset, not engine cache")
            (source / "saves").mkdir()
            (source / "saves/persistent").write_text("user's persistent data")
            (source / "cache").mkdir()
            (source / "cache/compiled").write_text("old cache")
            target = root / "staged"
            HOST.mirror_game(source, target)
            (target / "story.rpy").write_text("new compiled source")
            (target / "images/scene.bin").write_bytes(b"changed image")
            self.assertIn('"original"', (source / "story.rpy").read_text())
            self.assertEqual((source / "images/scene.bin").read_bytes(), b"original image")
            self.assertFalse((target / "saves").exists())
            self.assertFalse((target / "cache").exists())
            self.assertTrue((target / "images/cache/asset").is_file())

    def test_external_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "original"
            source.mkdir()
            (root / "outside").write_text("outside resource")
            (source / "asset").symlink_to(root / "outside")
            with self.assertRaisesRegex(ValueError, "escapes"):
                HOST.mirror_game(source, root / "staged")

    def test_internal_file_symlink_becomes_an_independent_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "original"
            source.mkdir()
            (source / "asset").write_bytes(b"original")
            (source / "alias").symlink_to(source / "asset")
            HOST.mirror_game(source, root / "staged")
            alias = root / "staged/alias"
            self.assertFalse(alias.is_symlink())
            alias.write_bytes(b"modified")
            self.assertEqual((source / "asset").read_bytes(), b"original")

    def test_symlinked_directories_cannot_form_a_recursive_mirror(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "original"
            source.mkdir()
            (source / "loop").symlink_to(source, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "Symlinked game directories"):
                HOST.mirror_game(source, root / "staged")

    def test_compiled_statement_ids_survive_workspace_recreation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first"
            first.mkdir()
            (first / "story.rpy").write_text("source")
            compiled = b"RENPY RPC2 preserved statement identities"
            (first / "story.rpyc").write_bytes(compiled)
            (first / "_aether_host_overlay.rpy").write_text("overlay")
            (first / "_aether_host_overlay.rpyc").write_bytes(b"overlay cache")
            cache = root / "cache"
            HOST.persist_compiled(first, cache)
            second = root / "second"
            second.mkdir()
            (second / "story.rpy").write_text("source")
            HOST.restore_compiled(second, cache)
            self.assertEqual((second / "story.rpyc").read_bytes(), compiled)
            self.assertFalse((cache / "_aether_host_overlay.rpyc").exists())
            (second / "story.rpyc").write_bytes(b"author's newer compilation")
            HOST.restore_compiled(second, cache)
            self.assertEqual((second / "story.rpyc").read_bytes(), b"author's newer compilation")

    def test_atomic_status_replaces_the_previous_document(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            HOST.atomic_json(path, {"phase": "starting"})
            HOST.atomic_json(path, {"phase": "ready", "title": "中文"})
            self.assertIn("中文", path.read_text())
            self.assertFalse(path.with_suffix(".tmp").exists())

    def test_inspecting_objects_or_nonfinite_numbers_remains_valid_json(self):
        import json
        result = HOST.inspect_value({"actor": object(), "nan": float("nan"), "items": list(range(100))})
        json.dumps(result, allow_nan=False)
        self.assertEqual(result["actor"], {"type": "object"})
        self.assertEqual(len(result["items"]), 16)


if __name__ == "__main__":
    unittest.main()
