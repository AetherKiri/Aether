"""Generator-only safety checks; no Godot, native library loading, or game data."""

from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import runpy
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch


PREPARE = Path(__file__).resolve().parents[1] / "systemnnn_godot" / "prepare.py"


class GodotFixturePreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.library = self.root / '日本語 "mock" library.so'
        self.library.write_bytes(b"not a native library; never loaded")
        self.output = self.root / "generated project"

    def prepare(self):
        stdout = io.StringIO()
        with patch.object(sys, "argv", [str(PREPARE), "--output", str(self.output),
                                        "--library", str(self.library)]), redirect_stdout(stdout):
            runpy.run_path(str(PREPARE), run_name="__main__")
        return stdout.getvalue()

    def snapshot(self):
        return {
            str(path.relative_to(self.output)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in self.output.rglob("*") if path.is_file()
        }

    def test_new_project_has_unicode_mixed_case_authored_spt_and_library_descriptor(self):
        self.assertEqual(self.prepare().strip(), str(self.output.resolve()))
        story = self.output / "fixture" / "日本語 Game" / "SpT" / "SyS.SpT"
        encoded = story.read_bytes()
        self.assertEqual(len(encoded) % 4, 0)
        words = tuple(word ^ 0xFFFFFFFF for word in
                      struct.unpack("<" + "I" * (len(encoded) // 4), encoded))
        self.assertEqual(words[:3], (32, 0x66660001, 0x55550001))
        self.assertEqual(words[12:16], (0x48545053, 0x45444145, 0x20203052, 0x00202020))
        self.assertEqual(words[4], 3)
        self.assertEqual(words[6], 2)
        decoded = struct.pack("<" + "I" * len(words), *words)

        def table_strings(field, count):
            pointers = words[words[field]:words[field] + count]
            return [decoded[pointer * 4:].split(b"\0", 1)[0] for pointer in pointers]

        self.assertEqual(table_strings(5, 3), [
            b"First independent line.", b"Second independent line.", b"Selected route.",
        ])
        self.assertEqual(table_strings(7, 2), [b"Amber route", b"Azure route"])
        # Authored dialogue and selection instructions, not just embedded text.
        self.assertIn((6, 0x66660006, 0x22220001, 0, 1, 0),
                      [words[index:index + 6] for index in range(32, len(words))])
        self.assertIn((7, 0x66660006, 0x22220006, 2, 0, 1, 0),
                      [words[index:index + 7] for index in range(32, len(words))])
        descriptor = (self.output / "production.gdextension").read_text(encoding="utf-8")
        library_line = next(line for line in descriptor.splitlines()
                            if line.startswith("linux.x86_64="))
        self.assertEqual(json.loads(library_line.split("=", 1)[1]), str(self.library.resolve()))
        self.assertIn('entry_symbol="aether_kiri_library_init"', descriptor)
        self.assertTrue((self.output / "project.godot").is_file())
        self.assertEqual((self.output / "runtime_exercise.gd").read_bytes(),
                         PREPARE.with_name("runtime_exercise.gd").read_bytes())
        self.assertEqual(self.library.read_bytes(), b"not a native library; never loaded")

    def test_second_run_refuses_existing_output_without_changing_hashes(self):
        self.prepare()
        before = self.snapshot()
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(self.snapshot(), before)

    def test_missing_library_refused_before_output_creation(self):
        self.library = self.root / "missing-library.so"
        with self.assertRaises(FileNotFoundError):
            self.prepare()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
