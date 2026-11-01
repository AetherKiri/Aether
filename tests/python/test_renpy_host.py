import importlib.util
import io
import pickle
from pathlib import Path
import sys
import tempfile
import struct
import unittest
from types import SimpleNamespace
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("renpy_host_tests", REPO / "apps/godot_app/renpy_runtime/host.py")
HOST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOST)


def rpa_fixture(resources, reversed_index=False):
    """Original payloads and an SDK-decoded index; no game assets or pickles."""
    stream = io.BytesIO(b" " * 34)
    stream.seek(34)
    index = {}
    for name, payload in resources.items():
        offset = stream.tell()
        stream.write(payload)
        fields = (len(payload), offset) if reversed_index else (offset, len(payload))
        index[name] = [(*fields, b"")]
    end = stream.tell()
    stream.write(b"index already decoded by the SDK")
    stream.seek(0)
    stream.write(f"RPA-3.0 {end:016x} 00000000\n".encode("ascii"))
    stream.seek(0, 2)
    return stream, index


class RenpyArchiveTests(unittest.TestCase):
    def setUp(self):
        self.resources = {
            "tl/None/common.rpymc": b"RENPY RPC2" + b"script data" * 20,
            "images/背景.png": b"\x89PNG\r\n\x1a\n" + b"image data" * 30,
            "audio/voice.ogg": b"OggS\x00" + b"audio data" * 40,
        }

    def test_python2_archive_prefixes_remain_binary_and_names_remain_unicode(self):
        class LegacyPickler(pickle._Pickler):
            dispatch = pickle._Pickler.dispatch.copy()
            def save_bytes(self, value):
                self.write(pickle.BINSTRING + struct.pack("<I", len(value)) + value)
                self.memoize(value)
            dispatch[bytes] = save_bytes
        for prefix in (b"", b"ASCII", b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"\xc3\xa9", b"\xe2\x82\xac"):
            with self.subTest(prefix=prefix):
                stream = io.BytesIO()
                LegacyPickler(stream, protocol=2).dump({"背景.png".encode("utf-8"): [(34, 500, prefix)],
                                                       "unicode.rpyc": [(1000, 20)]})
                decoded = HOST.load_archive_index(stream.getvalue())
                self.assertEqual(decoded, {"背景.png": [(34, 500, prefix)], "unicode.rpyc": [(1000, 20)]})
        modern = {"背景.png": [(34, 500, b"\x89PNG")], "legacy-unicode.png": [(50, 100, "\xff")]}
        self.assertEqual(HOST.load_archive_index(pickle.dumps(modern, protocol=2)), modern)

    def test_standard_archive_keeps_its_index_and_file_position(self):
        stream, index = rpa_fixture(self.resources)
        position = stream.tell()
        self.assertIs(HOST.normalize_rpa3_index(stream, index), index)
        self.assertEqual(stream.tell(), position)

    def test_reversed_archive_reads_the_original_resources(self):
        stream, index = rpa_fixture(self.resources, reversed_index=True)
        position = stream.tell()
        normalized = HOST.normalize_rpa3_index(stream, index)
        self.assertEqual(stream.tell(), position)
        for name, payload in self.resources.items():
            offset, length, prefix = normalized[name][0]
            stream.seek(offset)
            self.assertEqual(prefix + stream.read(length), payload)
            self.assertEqual(index[name][0][:2], (length, offset), "Do not mutate the SDK index")

    def test_resource_only_archives_are_detected_independently(self):
        for name, magic in [("image.webp", b"RIFFxxxxWEBP"), ("sound.wav", b"RIFFxxxxWAVE"),
                            ("font.ttf", b"\x00\x01\x00\x00"), ("font.otf", b"OTTO"),
                            ("movie.webm", b"\x1aE\xdf\xa3")]:
            for reversed_index in (True, False, True):
                with self.subTest(name=name, reversed_index=reversed_index):
                    payload = magic + b"original resource" * 20
                    stream, index = rpa_fixture({name: payload}, reversed_index)
                    normalized = HOST.normalize_rpa3_index(stream, index)
                    offset, length, _ = normalized[name][0]
                    stream.seek(offset)
                    self.assertEqual(stream.read(length), payload)

    def test_two_field_records_chunks_and_inline_prefixes_are_preserved(self):
        resources = dict(self.resources, **{"unknown.bin": b"body" * 50})
        stream, index = rpa_fixture(resources, reversed_index=True)
        name = "tl/None/common.rpymc"
        length, offset, _ = index[name][0]
        index[name] = [(64, offset), (length - 64, offset + 64)]
        index["unknown.bin"][0] = (*index["unknown.bin"][0][:2], b"inline prefix")
        normalized = HOST.normalize_rpa3_index(stream, index)
        body = b""
        for offset, length in normalized[name]:
            stream.seek(offset)
            body += stream.read(length)
        self.assertEqual(body, resources[name])
        self.assertEqual(normalized["unknown.bin"][0][2], b"inline prefix")

    def test_inline_magic_alone_cannot_identify_a_variant(self):
        stream, index = rpa_fixture({"story.rpyc": b"body" * 50}, reversed_index=True)
        index["story.rpyc"][0] = (*index["story.rpyc"][0][:2], b"RENPY RPC2")
        self.assertIs(HOST.normalize_rpa3_index(stream, index), index)

    def test_ambiguous_or_unknown_payloads_keep_standard_interpretation(self):
        stream, index = rpa_fixture({"story.rpyc": b"RENPY RPC2" + b"." * 191}, reversed_index=True)
        stream.seek(index["story.rpyc"][0][0])
        stream.write(b"RENPY RPC2")
        self.assertIs(HOST.normalize_rpa3_index(stream, index), index)
        for name in ("unknown.bin", "story.rpyc"):
            stream, index = rpa_fixture({name: b"unknown format" * 20}, reversed_index=True)
            self.assertIs(HOST.normalize_rpa3_index(stream, index), index)

    def test_invalid_unsampled_record_prevents_archive_wide_swap(self):
        for record in [(10, 1), (100, 10**9), (-1, 34), ("bad", 34), (1,)]:
            stream, index = rpa_fixture(self.resources, reversed_index=True)
            index["unknown.bin"] = [record]
            with self.subTest(record=record):
                self.assertIs(HOST.normalize_rpa3_index(stream, index), index)

    def test_partial_signature_evidence_is_not_enough_to_swap(self):
        resources = dict(self.resources, **{"other.rpyc": b"unrecognized script format" * 20})
        stream, index = rpa_fixture(resources, reversed_index=True)
        self.assertIs(HOST.normalize_rpa3_index(stream, index), index)

    def test_probe_reads_are_bounded(self):
        stream, index = rpa_fixture({f"{i}.rpyc": b"RENPY RPC2" + b"." * 200 for i in range(100)}, True)
        with patch.object(stream, "read", wraps=stream.read) as read:
            normalized = HOST.normalize_rpa3_index(stream, index)
            self.assertIsNot(normalized, index)
            self.assertLessEqual(read.call_count, 65)
            self.assertTrue(all(call.args[0] <= 34 for call in read.call_args_list))

    def test_hook_runs_after_import_and_is_restored_on_exit_or_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            (sdk / "renpy.py").write_text('''def main():
    import renpy
    renpy.import_all()
    renpy.seen = renpy.loader.RPAv3ArchiveHandler.read_index(renpy.archive)
    renpy.loads_seen = renpy.loader.loads
    renpy.callbacks_seen = list(renpy.loader.file_open_callbacks)
    renpy.config_seen = vars(renpy.config).copy()
    if renpy.fail:
        raise RuntimeError("game failed")
''')
            for fail in (False, True):
                with self.subTest(fail=fail):
                    stream, index = rpa_fixture(self.resources, True)
                    original_reader = lambda _stream: index
                    original_loads = lambda data: index
                    original_open = lambda name: None
                    class Handler:
                        read_index = staticmethod(original_reader)
                    def imported():
                        self.assertIs(renpy.import_all, imported, "The engine backup must see the original import function")
                    renpy = SimpleNamespace(import_all=imported, loader=SimpleNamespace(RPAv3ArchiveHandler=Handler, loads=original_loads,
                                            load_from_archive=original_open, file_open_callbacks=[original_open]),
                                            config=SimpleNamespace(), archive=stream, fail=fail)
                    previous_main = sys.modules["__main__"]
                    with patch.dict(sys.modules, {"renpy": renpy}), patch.object(HOST, "_manifest", {"saves": directory}):
                        if fail:
                            with self.assertRaisesRegex(RuntimeError, "game failed"):
                                HOST.run_engine(sdk)
                        else:
                            HOST.run_engine(sdk)
                    self.assertIsNot(renpy.seen, index)
                    self.assertIs(Handler.read_index, original_reader)
                    self.assertIs(renpy.loads_seen, HOST.load_archive_index)
                    self.assertIs(renpy.loader.loads, original_loads)
                    self.assertEqual(renpy.callbacks_seen, [HOST.load_inline_archive, original_open])
                    self.assertEqual(renpy.loader.file_open_callbacks, [original_open])
                    self.assertIs(renpy.import_all, imported)
                    self.assertIs(sys.modules["__main__"], previous_main)
                    self.assertEqual(renpy.config_seen, {"fixed_resolution": None, "fixed_resolution_filter": "linear"})
                    self.assertEqual(vars(renpy.config), {}, "Compatibility settings must not leak into another game")


class RenpyHostTests(unittest.TestCase):
    def test_declared_patch_paths_are_literal_ordered_and_game_local(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for name in ("translated/中文", "second", "unlisted"):
                (root / name).mkdir(parents=True)
            marker = root / "must-not-execute"
            (root / "environment.txt").write_text(
                f'open({str(marker)!r}, "w").write("executed")\n'
                'LCHH_RENPY_PATCH_SEARCHPATH="translated\\\\中文::second::translated/中文"\n', encoding="utf-8-sig")
            self.assertEqual(HOST.patch_directories(root), [root / "translated/中文", root / "second"])
            self.assertFalse(marker.exists(), "Never execute the distributor's environment script")
            (root / "environment.txt").write_text('OTHER_VARIABLE="unlisted"\n')
            self.assertEqual(HOST.patch_directories(root), [], "Do not guess patches from directory names")
            (root / "environment.txt").unlink()
            self.assertEqual(HOST.patch_directories(root), [])

    def test_patch_paths_cannot_escape_or_execute_expressions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "game-root"
            root.mkdir()
            (root.parent / "outside").mkdir()
            (root / "link").symlink_to(root.parent / "outside", target_is_directory=True)
            for value in ('"../outside"', '"link"', '"."', '"missing"', '42', 'str("outside")'):
                with self.subTest(value=value):
                    (root / "environment.txt").write_text("LCHH_RENPY_PATCH_SEARCHPATH=" + value)
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        HOST.patch_directories(root)

    def test_patch_mirrors_keep_loose_resources_and_compiled_ids_across_reopen(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "original"
            patch_dir = root / "translation"
            patch_dir.mkdir(parents=True)
            (root / "environment.txt").write_text('LCHH_RENPY_PATCH_SEARCHPATH="translation"\n')
            (patch_dir / "story.rpy").write_text('label start:\n    "中文"\n')
            (patch_dir / "opening.webm").write_bytes(b"translated movie")
            cache = Path(directory) / "cache"
            first, compiled = HOST.stage_patches(root, Path(directory) / "first", cache)[0]
            self.assertEqual((first / "opening.webm").read_bytes(), b"translated movie")
            (first / "story.rpyc").write_bytes(b"stable translated statement ids")
            HOST.persist_compiled(first, compiled)
            second, second_cache = HOST.stage_patches(root, Path(directory) / "second", cache)[0]
            self.assertEqual(second_cache, compiled)
            self.assertEqual((second / "story.rpyc").read_bytes(), b"stable translated statement ids")
            self.assertFalse((patch_dir / "story.rpyc").exists(), "Never compile into the supplied patch")

    def test_patch_search_and_archive_order_are_restored_after_each_game(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            (sdk / "renpy.py").write_text('''def predefined_searchpath(common):
    return ["original game", common]
def main():
    import renpy
    renpy.import_all()
    renpy.paths_seen = predefined_searchpath("common")
    renpy.loader.index_archives()
    renpy.archives_seen = list(renpy.loader.archives)
    if renpy.fail:
        raise RuntimeError("game failed")
''')
            patches = [sdk / "patches/0", sdk / "patches/1"]
            stock = [(str(sdk / "game/z-original.rpa"), {}),
                     (str(patches[1] / "z-patch.rpa"), {}),
                     (str(patches[0] / "b-patch.rpa"), {}),
                     (str(patches[0] / "a-patch.rpa"), {})]
            for fail in (False, True):
                with self.subTest(fail=fail):
                    class Handler:
                        read_index = staticmethod(lambda stream: {})
                    def index_archives():
                        loader.archives[:] = stock
                    original_open = lambda name: None
                    loader = SimpleNamespace(RPAv3ArchiveHandler=Handler, archives=[], index_archives=index_archives, loads=pickle.loads,
                                             load_from_archive=original_open, file_open_callbacks=[original_open])
                    renpy = SimpleNamespace(import_all=lambda: None, loader=loader, config=SimpleNamespace(), fail=fail)
                    with patch.dict(sys.modules, {"renpy": renpy}), patch.object(HOST, "_manifest", {"saves": directory}):
                        if fail:
                            with self.assertRaisesRegex(RuntimeError, "game failed"):
                                HOST.run_engine(sdk, patches)
                        else:
                            HOST.run_engine(sdk, patches)
                    self.assertEqual(renpy.paths_seen, [str(p) for p in patches] + ["original game", "common"])
                    self.assertEqual(renpy.archives_seen, stock[2:] + [stock[1], stock[0]])
                    self.assertIs(loader.index_archives, index_archives, "A game's patch hook must not leak into the next game")
                    loader.index_archives()
                    self.assertEqual(loader.archives, stock)

    def test_text_input_preserves_modifiers_and_releases_held_keys_on_pause(self):
        events = []
        names = ["KEYDOWN", "KEYUP", "TEXTINPUT", "TEXTEDITING", "K_ESCAPE", "K_RETURN", "K_SPACE",
                 "K_LCTRL", "K_UP", "K_DOWN", "K_LEFT", "K_RIGHT", "K_PAGEUP", "K_PAGEDOWN", "K_F5", "K_F9"]
        pygame = SimpleNamespace(**{name:index + 1 for index,name in enumerate(names)},
            KMOD_CTRL=192, KMOD_ALT=768, KMOD_GUI=3072,
            event=SimpleNamespace(post=events.append, Event=lambda kind, **fields: {"type":kind, **fields}))
        HOST._keys_down.clear(); HOST._raw_keys_down.clear()
        with patch.object(HOST, "_pygame", return_value=pygame):
            HOST.input_event({"type":"key", "key":"space", "pressed":True, "mod":3, "repeat":True, "text":" "})
            self.assertEqual(events[0]["mod"], 3)
            self.assertTrue(events[0]["repeat"])
            self.assertEqual(events[1], {"type":pygame.TEXTINPUT, "text":" "})
            events.clear()
            HOST.input_event({"type":"key", "key":"a", "pressed":True, "mod":192, "text":"a"})
            self.assertEqual(len(events), 1, "Ctrl shortcuts must not insert text")
            HOST.release_keys()
            self.assertTrue(any(event["type"] == pygame.KEYUP and event["key"] == ord("a") for event in events))
            self.assertFalse(HOST._raw_keys_down)
            events.clear()
            HOST.input_event({"type":"key", "key":"", "pressed":True, "text":"汉"})
            self.assertEqual(events, [{"type":pygame.TEXTINPUT, "text":"汉"}])
            HOST.input_event({"type":"composition", "text":"汉字", "start":1, "length":1})
            self.assertEqual(events[-1], {"type":pygame.TEXTEDITING, "text":"汉字", "start":1, "length":1})

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
