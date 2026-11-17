#!/usr/bin/env python3
"""Prepare a fresh graphical test project using only independently authored data.

SPT word/table encoding mirrors tests/systemnnn_native/provider.cpp; no original
or compiled commercial game files are read. Python 3.9+; standard library only.
"""
import argparse
import json
from pathlib import Path
import shutil
import struct

CONTROL, COMMAND, FUNCTION = 0x66660002, 0x66660006, 0x66660007


class Script:
    def __init__(self):
        self.code = []
        self.selection_adjust = []
        self.messages = ["First independent line.", "Second independent line.", "Selected route."]
        self.strings = ["Amber route", "Azure route"]

    def add(self, words):
        at = 32 + len(self.code)
        self.code.extend(words)
        return at

    def number(self, op, args):
        self.add([4 + len(args), COMMAND if op == 0x22220004 else FUNCTION, op, len(args)] + args)

    def color(self, red, green, blue):
        self.number(0x33330013, [0, 54, 0, red, green, blue])

    def draw(self):
        self.number(0x22220004, [1])

    def message(self, serial, index):
        self.add([6, COMMAND, 0x22220001, index, serial, 0])

    def encode(self):
        words = [0] * 32
        words[:3] = [32, 0x66660001, 0x55550001]
        words[12:16] = [0x48545053, 0x45444145, 0x20203052, 0x00202020]
        words.extend(self.code)

        def table(kind, field, payload, record=False):
            words[field] = len(words) + (0 if record else 4)
            words.extend([4 + len(payload), 0x66660001, 0x55550002, kind] + payload)

        def strings(kind, field, values):
            payload = [0] * len(values)
            base = len(words) + 4
            for i, value in enumerate(values):
                data = value.encode("ascii") + b"\0"
                data += b"\0" * (-len(data) % 4)
                payload[i] = base + len(payload)
                payload.extend(struct.unpack("<" + "I" * (len(data) // 4), data))
            table(kind, field, payload)

        table(0x44440003, 9, [])
        table(0x44440003, 16, [], True)
        table(0x44440003, 17, [], True)
        words[4] = len(self.messages)
        strings(0x44440002, 5, self.messages)
        words[6] = len(self.strings)
        strings(0x44440001, 7, self.strings)
        for kind, field, payload in [(0x44440004, 18, []), (0x44440005, 20, []),
                                     (0x44440006, 21, self.selection_adjust),
                                     (0x44440007, 22, []), (0x44440008, 23, [])]:
            table(kind, field, payload)
        return struct.pack("<" + "I" * len(words), *(word ^ 0xFFFFFFFF for word in words))


def story():
    script = Script()
    script.color(180, 30, 60)
    script.draw()
    script.message(1, 0)
    script.message(2, 1)
    script.selection_adjust.append(script.add([7, COMMAND, 0x22220006, 2, 0, 1, 0]))
    for choice, color, serial in [(1, (230, 140, 10), 3), (2, (10, 80, 220), 4)]:
        script.add([4, CONTROL, 0x55560008, choice])
        block = script.add([4, CONTROL, 0xA000007B, 0])
        script.color(*color)
        script.draw()
        script.message(serial, 2)
        script.add([3, CONTROL, 0x5556000B])  # EXIT, rather than foreground END/restart.
        script.add([3, CONTROL, 0xA000007D])
        script.code[block - 32 + 3] = 32 + len(script.code) - block
    return script.encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Absent directory to create; never overwrites")
    parser.add_argument("--library", type=Path, required=True, help="Existing staged production libaether_kiri_godot.so")
    args = parser.parse_args()
    library = args.library.resolve(strict=True)
    if not library.is_file():
        parser.error("--library must be a regular file")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixture = output / "fixture" / "日本語 Game"
    (fixture / "SpT").mkdir(parents=True)
    (fixture / "init").mkdir()
    (fixture / "SpT" / "SyS.SpT").write_bytes(story())
    settings = {
        "game.xtx": "frameTime 20\nextSaveDataNumber 0\n",
        "printmessage.xtx": "nameFlag 0\n",
        "nothing.xtx": "nextMode title\n",
        "title.xtx": "enterFadeType 0\n",
        "emberfall-system.cfg": "emberfall_system 4\nfile_layer_records 32\nfile_message_width 1024\nfile_status_bytes 7088\nfile_okikae 1\nfile_system_save_version 1\nexe_analyzed 0\nsystem_save_version 1\nsystem_save_trial 0\nsystem_save_source game_files\next_start_code 100\next_block_count 1\next_block_size 6400 engine\n",
    }
    for name, text in settings.items():
        (fixture / "init" / name).write_text(text, encoding="utf-8")
    (output / "project.godot").write_text('[application]\nconfig/name="SystemNNN production graphical test"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding="utf-8")
    # JSON quoting also provides a valid Godot quoted string, including path escapes.
    descriptor = '[configuration]\nentry_symbol="aether_kiri_library_init"\ncompatibility_minimum="4.7"\n[libraries]\nlinux.x86_64=' + json.dumps(str(library), ensure_ascii=False) + '\n'
    (output / "production.gdextension").write_text(descriptor, encoding="utf-8")
    shutil.copyfile(Path(__file__).with_name("runtime_exercise.gd"), output / "runtime_exercise.gd")
    print(output)


if __name__ == "__main__":
    main()
