"""Per-game native Ren'Py host, using Aether-owned sessions and save folders.

The embedded loop and allowlisted JSON probe share the same interpreter.
The command-line entry point also supports isolated SDK diagnostics.
"""
import argparse
import ast
import base64
import ctypes
from collections import deque
import hashlib
import io
import json
import importlib.util
import math
import os
from pathlib import Path
import pickle
import re
import shutil
import stat
import sys
import threading
import time
import traceback
import types


_manifest = {}
_session = None
_ack = 0
_ready = False
_last_publish = 0.0
_inspect_names = []
_command_error = ""
_keys_down = set()
_raw_keys_down = set()
_mouse_position = (0, 0)
_mouse_buttons = [False, False, False]
_compiled_projects = []
_log = None
controls_visible = False
menu_visible = False
restart_requested = False
_controls_frame = {}
_controls_image = None
_controls_events = deque(maxlen=128)
_controls_sequence = 0
_controls_captured = False
_controls_hovered = False


class SessionLog:
    """Mobile Ren'Py snapshots its log sinks; keep the open file out of saves."""
    encoding = "utf-8"

    def write(self, value):
        log = sys.modules["aether_renpy_host"]._log
        return log.write(value) if log is not None and not log.closed else len(value)

    def flush(self):
        log = sys.modules["aether_renpy_host"]._log
        if log is not None and not log.closed:
            log.flush()

    def isatty(self):
        return False


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, path)


def copy_file(source, destination):
    """Use APFS copy-on-write where available; never link writable game files."""
    cloned = False
    if sys.platform == "darwin":
        library = ctypes.CDLL(None, use_errno=True)
        clone = library.clonefile
        clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        clone.restype = ctypes.c_int
        cloned = clone(os.fsencode(source), os.fsencode(destination), 0) == 0
    if not cloned:
        shutil.copy2(source, destination)
    destination.chmod(stat.S_IMODE(source.stat().st_mode) | stat.S_IWUSR)


def mirror_game(source, destination):
    """Stage a writable game tree; keep saves and engine caches separate."""
    source = source.resolve(strict=True)
    destination.mkdir(parents=True, exist_ok=False)
    for root, directories, files in os.walk(source, followlinks=False):
        root = Path(root)
        excluded = {"__pycache__", ".git"} | ({"saves", "savedata", "cache"} if root == source else set())
        directories[:] = [name for name in directories if name not in excluded]
        for name in directories:
            if (root / name).is_symlink():
                raise ValueError(f"Symlinked game directories are not supported: {root / name}")
            (destination / (root / name).relative_to(source)).mkdir()
        for name in files:
            path = root / name
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(source) or not resolved.is_file():
                raise ValueError(f"Game resource escapes its directory: {path}")
            copy_file(resolved, destination / path.relative_to(source))


def patch_directories(root):
    """Read the translation launcher's declared paths without executing it."""
    root = root.resolve(strict=True)
    environment = root / "environment.txt"
    if not environment.is_file():
        return []
    value = ""
    for statement in ast.parse(environment.read_text(encoding="utf-8-sig"), str(environment)).body:
        if not isinstance(statement, ast.Assign) or not any(
                isinstance(target, ast.Name) and target.id == "LCHH_RENPY_PATCH_SEARCHPATH"
                for target in statement.targets):
            continue
        value = ast.literal_eval(statement.value)
        if not isinstance(value, str):
            raise ValueError("LCHH_RENPY_PATCH_SEARCHPATH must be a literal string")
    result = []
    for name in value.split("::"):
        if not name.strip():
            continue
        path = (root / name.strip().replace("\\", "/")).resolve(strict=True)
        if not path.is_relative_to(root) or path == root:
            raise ValueError(f"Translation patch escapes its game directory: {name}")
        if not path.is_dir():
            raise ValueError(f"Translation patch is not a directory: {name}")
        if path not in result:
            result.append(path)
    return result


def stage_patches(root, project, cache):
    result = []
    for index, source in enumerate(patch_directories(root)):
        destination = project / "patches" / str(index)
        mirror_game(source, destination)
        identity = source.relative_to(root.resolve()).as_posix()
        compiled = cache / "patches" / hashlib.sha256(identity.encode("utf-8")).hexdigest()
        restore_compiled(destination, compiled)
        result.append((destination, compiled))
        print("[Aether] Translation patch:", identity)
    return result


def archive_priority(filename, patches):
    path = Path(filename).resolve()
    for index, patch in enumerate(patches):
        if path.is_relative_to(Path(patch).resolve()):
            return index
    return len(patches)


def load_archive_index(data):
    # Python 2 RPA indexes store inline binary resource headers as str. The
    # SDK's general-purpose unpickler decodes those as UTF-8, then its RPA3
    # reader encodes them as Latin-1. Keep binary fields as bytes and decode
    # only filenames, so both old byte strings and modern Unicode keys work.
    index = pickle.loads(data, encoding="bytes")
    return {name.decode("utf-8", "surrogateescape") if isinstance(name, bytes) else name: records
            for name, records in index.items()}


def load_inline_archive(name):
    # The pinned SDK creates a split stream for inline prefixes but omits its
    # return, falling through to lower-priority archives. Use the same SDK
    # stream implementation for that case; leave all other entries to it.
    import renpy.loader
    for filename, index in renpy.loader.archives:
        if name not in index:
            continue
        records = index[name]
        if len(records) == 1 and len(records[0]) == 3 and records[0][2]:
            offset, length, prefix = records[0]
            stream = renpy.loader.RWopsIO
            header = stream.from_buffer(prefix, name=name)
            # RPA length includes the inline bytes, which are not on disk.
            body = stream(filename, "rb", base=offset, length=length - len(prefix))
            return io.BufferedReader(stream.from_split(header, body, name=name))
        return None
    return None


def restore_compiled(game, cache):
    if not cache.exists():
        return
    for compiled in cache.rglob("*.rpyc"):
        target = game / compiled.relative_to(cache)
        if not target.exists() and target.with_suffix(".rpy").is_file():
            copy_file(compiled, target)


def persist_compiled(game, cache):
    for compiled in game.rglob("*.rpyc"):
        if compiled.name == "_aether_host_overlay.rpyc" or not compiled.with_suffix(".rpy").is_file():
            continue
        target = cache / compiled.relative_to(game)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".tmp")
        copy_file(compiled, temporary)
        os.replace(temporary, target)


def normalize_rpa3_index(infile, index):
    """Recognize reversed (length, offset) records without changing the archive.

    Both orders can be in bounds, so require every sampled resource signature
    at the swapped offsets and none at the standard offsets. Ambiguous archives
    keep the SDK's interpretation. Read only a bounded number of small headers.
    """
    signatures = {
        ".rpyc": ((0, b"RENPY RPC2"),), ".rpymc": ((0, b"RENPY RPC2"),),
        ".png": ((0, b"\x89PNG\r\n\x1a\n"),),
        ".jpg": ((0, b"\xff\xd8\xff"),), ".jpeg": ((0, b"\xff\xd8\xff"),),
        ".webp": ((0, b"RIFF"), (8, b"WEBP")),
        ".ogg": ((0, b"OggS\x00"),), ".opus": ((0, b"OggS\x00"),),
        ".wav": ((0, b"RIFF"), (8, b"WAVE")),
        ".flac": ((0, b"fLaC"),),
        ".ttf": ((0, b"\x00\x01\x00\x00"),), ".otf": ((0, b"OTTO"),),
        ".ttc": ((0, b"ttcf"),),
        ".webm": ((0, b"\x1aE\xdf\xa3"),), ".mkv": ((0, b"\x1aE\xdf\xa3"),),
        ".mp4": ((4, b"ftyp"),),
    }
    position = infile.tell()
    try:
        infile.seek(0)
        header = infile.read(34)
        if not header.startswith(b"RPA-3.0 ") or not isinstance(index, dict):
            return index
        data_end = int(header[8:24], 16)
        if not 34 <= data_end <= infile.seek(0, os.SEEK_END):
            return index
        # A format choice applies to the entire archive, including unknown
        # resource types and continuation chunks, not just the sampled files.
        for records in index.values():
            if not isinstance(records, (list, tuple)) or not records:
                return index
            for record in records:
                if not isinstance(record, (list, tuple)) or len(record) not in (2, 3):
                    return index
                length, offset = record[:2]
                if type(offset) is not int or type(length) is not int:
                    return index
                if offset < 34 or length < 0 or offset + length > data_end:
                    return index

        matches = 0
        probes = 0
        for name, records in index.items():
            expected = signatures.get(Path(name).suffix.lower()) if isinstance(name, str) else None
            if expected is None:
                continue
            record = records[0]
            # An inline prefix is shared by both interpretations and cannot
            # establish which on-disk offset is correct.
            if len(record) == 3 and record[2]:
                continue
            size = max(offset + len(magic) for offset, magic in expected)

            def matches_at(offset, length):
                if offset < 34 or length < size or offset + length > data_end:
                    return False
                infile.seek(offset)
                data = infile.read(size)
                return all(data[start:start + len(magic)] == magic for start, magic in expected)

            if matches_at(record[0], record[1]):
                return index
            matches += matches_at(record[1], record[0])
            probes += 1
            if probes == 32:
                break
        if not matches or matches != probes:
            return index
        return {name: [(record[1], record[0], *record[2:]) for record in records]
                for name, records in index.items()}
    finally:
        infile.seek(position)


def inspect_value(value, depth=0):
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else str(value)
    if isinstance(value, str):
        return value[:2048]
    if depth < 2:
        if isinstance(value, (list, tuple)):
            return [inspect_value(item, depth + 1) for item in value[:16]]
        if isinstance(value, dict):
            return {name: inspect_value(item, depth + 1) for name, item in list(value.items())[:16] if isinstance(name, str)}
    return {"type": type(value).__name__}


def _publish(phase="ready", **extra):
    renpy = sys.modules.get("renpy")

    value = {"phase": phase, "ack": _ack, "pid": os.getpid(),
             "version": getattr(renpy, "version_only", ""), "controls": controls_visible,
             "menu": menu_visible, "controls_events": list(_controls_events), "command_error": _command_error}
    if _ready and phase == "ready":
        value["renderer"] = dict(renpy.exports.get_renderer_info())
        value["size"] = list(renpy.exports.get_physical_size())
        rect = renpy.display.interface.old_text_rect
        if rect is not None:
            x, y, w, h = rect
            point = renpy.display.draw.untranslate_point(x, y + h)
            width, height = value["size"]
            value["ime"] = [point[0] / max(1, width), point[1] / max(1, height)]
        if _manifest.get("debug"):
            # Read the already substituted Text; never evaluate the game's
            # interpolation expressions a second time from the probe.
            screen = renpy.exports.get_screen("say")
            what = screen.widgets.get("what") if screen is not None else None
            value["dialogue"] = "".join(part for part in (what.text or []) if isinstance(part, str)) if isinstance(what, renpy.text.text.Text) else ""
            value["main_menu"] = renpy.exports.get_screen("main_menu") is not None
            value["variables"] = {name: inspect_value(getattr(renpy.store, name, None)) for name in _inspect_names}
    value.update(extra)
    atomic_json(_session / "state.json", value)


def _pygame():
    import renpy
    return renpy.display.core.pygame


def key(name, pressed, modifier=None, repeat=False, text=None):
    pygame = _pygame()
    keys = {"esc": pygame.K_ESCAPE, "enter": pygame.K_RETURN, "space": pygame.K_SPACE,
            "ctrl": pygame.K_LCTRL, "up": pygame.K_UP, "down": pygame.K_DOWN,
            "left": pygame.K_LEFT, "right": pygame.K_RIGHT,
            "pgup": pygame.K_PAGEUP, "pgdn": pygame.K_PAGEDOWN,
            "f5": pygame.K_F5, "f9": pygame.K_F9}
    code = keys[name]
    if pressed:
        _keys_down.add(name)
    else:
        _keys_down.discard(name)
    if modifier is None:
        modifier = pygame.KMOD_CTRL if "ctrl" in _keys_down else 0
    pygame.event.post(pygame.event.Event(pygame.KEYDOWN if pressed else pygame.KEYUP,
        key=code, unicode=text if text is not None else "\r" if name == "enter" else " " if name == "space" else "", mod=modifier, repeat=repeat))


def tap_key(name):
    key(name, True)
    key(name, False)


def release_keys():
    for name in tuple(_keys_down):
        key(name, False)
    pygame = _pygame()
    for code in _raw_keys_down:
        pygame.event.post(pygame.event.Event(pygame.KEYUP, key=code, unicode="", mod=0, repeat=False))
    _raw_keys_down.clear()


def release_pointer():
    pygame = _pygame()
    for index, pressed in enumerate(_mouse_buttons):
        if pressed:
            pygame.event.post(pygame.event.Event(pygame.MOUSEBUTTONUP, button=index + 1, pos=_mouse_position))
    _mouse_buttons[:] = [False, False, False]


def input_event(event):
    """Translate Aether input at a safe point in the native SDL event loop."""
    global _mouse_position
    kind = event.get("type")
    if kind == "controls_frame":
        set_controls_frame(event)
        return
    pygame = _pygame()
    if kind == "composition":
        pygame.event.post(pygame.event.Event(pygame.TEXTEDITING, text=event.get("text", ""),
            start=int(event.get("start", 0)), length=int(event.get("length", 0))))
        return
    if kind == "key":
        name = event.get("key", "")
        text_input = event.get("text", "")
        def commit_text():
            if event.get("pressed") and isinstance(text_input, str) and text_input.isprintable() and not int(event.get("mod", 0)) & (pygame.KMOD_CTRL | pygame.KMOD_ALT | pygame.KMOD_GUI):
                pygame.event.post(pygame.event.Event(pygame.TEXTINPUT, text=text_input))
        aliases = {"escape": "esc", "return": "enter", "pageup": "pgup", "pagedown": "pgdn", "control": "ctrl"}
        name = aliases.get(name, name)
        if name in {"esc", "enter", "space", "ctrl", "up", "down", "left", "right", "pgup", "pgdn", "f5", "f9"}:
            key(name, bool(event.get("pressed")), event.get("mod"), bool(event.get("repeat")), text_input)
            commit_text()
            return
        special = {"shift": "LSHIFT", "alt": "LALT", "meta": "LGUI", "backspace": "BACKSPACE", "tab": "TAB",
                   "delete": "DELETE", "insert": "INSERT", "home": "HOME", "end": "END"}
        symbol = special.get(name, name.upper() if re.fullmatch(r"f(?:[1-9]|1[0-2])", name) else name)
        code = getattr(pygame, "K_" + symbol, None)
        if code is None and len(name) == 1:
            code = ord(name)
        if code is not None:
            if event.get("pressed"):
                _raw_keys_down.add(code)
            else:
                _raw_keys_down.discard(code)
            pygame.event.post(pygame.event.Event(pygame.KEYDOWN if event.get("pressed") else pygame.KEYUP,
                key=code, unicode=event.get("text", ""), mod=int(event.get("mod", 0)), repeat=bool(event.get("repeat"))))
        commit_text()
        return
    if kind not in {"move", "button"}:
        return
    width, height = pygame.display.get_size()
    previous = _mouse_position
    _mouse_position = (int(float(event.get("x", 0)) * width), int(float(event.get("y", 0)) * height))
    pygame.event.post(pygame.event.Event(pygame.MOUSEMOTION, pos=_mouse_position,
        rel=(_mouse_position[0] - previous[0], _mouse_position[1] - previous[1]), buttons=tuple(_mouse_buttons), touch=bool(event.get("touch")), aether_input=True))
    if kind == "button":
        button = int(event.get("button", 1))
        pressed = bool(event.get("pressed"))
        if 1 <= button <= 3:
            _mouse_buttons[button - 1] = pressed
        if 1 <= button <= 7:
            pygame.event.post(pygame.event.Event(pygame.MOUSEBUTTONDOWN if pressed else pygame.MOUSEBUTTONUP,
                button=button, pos=_mouse_position, touch=bool(event.get("touch")), aether_input=True))


def set_controls_frame(frame):
    """Present the original Godot controls; the engine owns no menu widgets."""
    global _controls_frame, _controls_image, controls_visible, menu_visible
    import renpy
    _controls_frame = frame
    controls_visible = bool(frame.get("controls"))
    menu_visible = bool(frame.get("menu"))
    if frame.get("image"):
        _controls_image = renpy.display.im.Data(base64.b64decode(frame["image"]), "_aether_controls.png")
        renpy.exports.restart_interaction()
    _publish()


def controls_pointer(ev, x, y, width, height):
    """Return native pointer events to the shared Godot Control tree."""
    global _controls_captured, _controls_hovered, _controls_sequence
    pygame = _pygame()
    if getattr(ev, "aether_input", False) or ev.type not in (pygame.MOUSEMOTION, pygame.MOUSEBUTTONDOWN, pygame.MOUSEBUTTONUP):
        return False
    x, y = x / max(1, width), y / max(1, height)
    hit = any(rx <= x < rx + rw and ry <= y < ry + rh
              for rx, ry, rw, rh in _controls_frame.get("regions", []))
    routed = hit or _controls_captured
    if ev.type == pygame.MOUSEBUTTONDOWN and hit:
        _controls_captured = True
    if routed or (ev.type == pygame.MOUSEMOTION and _controls_hovered):
        _controls_sequence += 1
        event = {"seq": _controls_sequence, "x": x, "y": y,
                 "type": "move" if ev.type == pygame.MOUSEMOTION else "button"}
        if ev.type != pygame.MOUSEMOTION:
            event.update(button={2: 3, 3: 2}.get(ev.button, ev.button), pressed=ev.type == pygame.MOUSEBUTTONDOWN)
        _controls_events.append(event)
        _publish()
    _controls_hovered = hit
    if ev.type == pygame.MOUSEBUTTONUP:
        _controls_captured = False
    return routed


def restart_game():
    global restart_requested
    restart_requested = True
    quit_game()


def quit_game():
    import renpy
    release_keys()
    release_pointer()
    renpy.exports.quit(relaunch=False, status=0)


def _dispatch(command):
    global _inspect_names
    import renpy

    action = command.get("action", "")
    if action == "quit":
        quit_game()
    elif action == "key_tap":
        tap_key(command["key"])
    elif action == "key":
        key(command["key"], bool(command["pressed"]))
    elif action == "inspect" and _manifest.get("debug"):
        names = command.get("names", [])
        if not isinstance(names, list) or len(names) > 16 or any(not isinstance(name, str) or not re.fullmatch(r"[A-Za-z_]\w*", name) for name in names):
            raise ValueError("Invalid debug variable names")
        _inspect_names = names
    elif action == "screenshot" and _manifest.get("debug"):
        renpy.exports.screenshot(str(_session / "screenshot.png"))
    else:
        raise ValueError(f"Unsupported Ren'Py host command: {action}")


def _periodic():
    global _ack, _last_publish, _command_error
    if not _manifest.get("embedded") and os.getppid() != int(_manifest["parent_pid"]):
        quit_game()
    path = _session / "command.json"
    if path.exists():
        command = json.loads(path.read_text(encoding="utf-8"))
        sequence = int(command.get("seq", 0))
        if sequence > _ack:
            _ack = sequence
            _command_error = ""
            # Context changes from Quit/Load/Restart must reach Ren'Py's loop.
            try:
                _dispatch(command)
            except (KeyError, ValueError, TypeError) as error:
                _command_error = str(error)
    now = time.monotonic()
    if _ready and now - _last_publish >= 0.1:
        _publish()
        _last_publish = now


def _display_started():
    global _ready
    for game, cache in _compiled_projects:
        persist_compiled(game, cache)
    _ready = True
    _publish()


def _watch_parent():
    while os.getppid() == int(_manifest["parent_pid"]):
        time.sleep(0.5)
    # The main-thread periodic callback normally performs the graceful quit.
    # Bound orphan lifetime even if a game blocks startup or its event loop.
    time.sleep(5)
    os._exit(0)


def install():
    import renpy
    if _manifest.get("embedded") and _manifest.get("forward_input", True):
        pygame = _pygame()
        pygame.mouse.get_pos = lambda: _mouse_position
        pygame.mouse.get_pressed = lambda: tuple(_mouse_buttons)
    if _periodic not in renpy.config.periodic_callbacks:
        renpy.config.periodic_callbacks.append(_periodic)
    if _display_started not in renpy.config.display_start_callbacks:
        renpy.config.display_start_callbacks.append(_display_started)
    if "_aether_renpy_overlay" not in renpy.config.always_shown_screens:
        renpy.config.always_shown_screens.append("_aether_renpy_overlay")
    if _manifest.get("embedded"):
        renpy.config.quit_on_mobile_background = False


def engine_bindings():
    """Keep original callables by identity, before a game installs its hooks.

    The SDK backup pickles functions by module/name, so unpickling a replaced
    function resolves to the game's replacement. It also keeps classes by
    identity and cannot undo their patched methods on its own.
    """
    bindings = []
    seen = set()
    for name, module in list(sys.modules.items()):
        if not (name == "renpy" or name.startswith("renpy.")) or not isinstance(module, types.ModuleType):
            continue
        targets = [module] + [value for value in list(vars(module).values())
                              if isinstance(value, type) and value.__module__.startswith("renpy.")]
        for target in targets:
            if id(target) in seen:
                continue
            seen.add(id(target))
            for key, value in vars(target).copy().items():
                if callable(value) or isinstance(value, (staticmethod, classmethod, property)):
                    bindings.append((target, key, value))
    return bindings


def restore_engine_bindings(bindings):
    for target, key, value in bindings:
        if vars(target).get(key) is not value:
            setattr(target, key, value)


def unload_game_modules(game_root):
    """Reload game Python, including archive modules, in the next session."""
    import renpy
    importer = getattr(getattr(renpy, "importer", None), "RenpyImporter", ())
    root = str(Path(game_root).resolve()) + os.sep if game_root else ""
    for name, module in reversed(list(sys.modules.items())):
        if not isinstance(module, types.ModuleType) or name == "renpy" or name.startswith("renpy."):
            continue
        filename = str(vars(module).get("__file__") or "")
        if not (isinstance(vars(module).get("__loader__"), importer) or filename.startswith("$game/")
                or (root and filename.startswith(root))):
            continue
        sys.modules.pop(name, None)
        parent, _, child = name.rpartition(".")
        parent_module = sys.modules.get(parent)
        if parent_module is not None and vars(parent_module).get(child) is module:
            delattr(parent_module, child)


def run_engine(sdk, patches=()):
    import renpy

    # These are distributor hooks in the original launcher. Mobile launchers
    # choose a shared Documents/private directory before processing --savedir;
    # supply Aether's per-game namespace before any persistent data is read.
    spec = importlib.util.spec_from_file_location("_aether_renpy_entry", sdk / "renpy.py")
    entry = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = entry
    spec.loader.exec_module(entry)
    entry.path_to_saves = lambda *_args, **_kwargs: _manifest["saves"]
    if patches:
        original_searchpath = entry.predefined_searchpath
        entry.predefined_searchpath = lambda common: [str(path) for path in patches] + original_searchpath(common)
    previous_main = sys.modules.get("__main__")
    entry.__name__ = "__main__"
    sys.modules["__main__"] = entry
    original_import = renpy.import_all
    archive_handler = None
    original_reader = None
    original_index = None
    original_archive_loads = None
    archive_callbacks = None
    added_config = []
    bindings = []

    def import_with_archive_compat():
        nonlocal archive_handler, original_reader, original_index, original_archive_loads, archive_callbacks, bindings
        # Keep the SDK's interpreter backup free of session-local closures.
        # Embedded reopen supplies its own one-shot import hook; call it too.
        renpy.import_all = original_import
        original_import()
        bindings = engine_bindings()
        # Some ports declare preferences for a custom fixed-resolution FBO.
        # Accept these advisory settings with the upstream renderer, which
        # continues rendering at the native viewport size. Do not replace a
        # future SDK's own implementation or relax validation of other names.
        for name, default in (("fixed_resolution", None), ("fixed_resolution_filter", "linear")):
            if not hasattr(renpy.config, name):
                setattr(renpy.config, name, default)
                added_config.append(name)
        archive_handler = renpy.loader.RPAv3ArchiveHandler
        original_reader = archive_handler.read_index
        original_archive_loads = renpy.loader.loads
        renpy.loader.loads = load_archive_index
        archive_callbacks = renpy.loader.file_open_callbacks
        archive_callbacks.insert(archive_callbacks.index(renpy.loader.load_from_archive), load_inline_archive)

        def read_index(infile):
            index = original_reader(infile)
            normalized = normalize_rpa3_index(infile, index)
            if normalized is not index:
                print("[Aether] Reversed RPA-3.0 index:", getattr(infile, "name", "<archive>"))
            return normalized

        archive_handler.read_index = staticmethod(read_index)
        if patches:
            original_index = renpy.loader.index_archives

            def index_archives():
                original_index()
                # The SDK sorts RPA names in reverse order, independently of
                # searchpath. Keep that order within each directory, but put
                # declared patch archives ahead of the original game's RPAs.
                renpy.loader.archives.sort(key=lambda item: archive_priority(item[0], patches))

            renpy.loader.index_archives = index_archives

    renpy.import_all = import_with_archive_compat
    try:
        entry.main()
    finally:
        if renpy.import_all is import_with_archive_compat:
            renpy.import_all = original_import
        if archive_handler is not None:
            archive_handler.read_index = staticmethod(original_reader)
        if original_archive_loads is not None:
            renpy.loader.loads = original_archive_loads
        if archive_callbacks is not None and load_inline_archive in archive_callbacks:
            archive_callbacks.remove(load_inline_archive)
        if original_index is not None:
            renpy.loader.index_archives = original_index
        for name in added_config:
            vars(renpy.config).pop(name, None)
        restore_engine_bindings(bindings)
        unload_game_modules(getattr(renpy.config, "gamedir", None))
        sys.modules["__main__"] = previous_main


def main():
    global _manifest, _session, _compiled_projects, _log
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    _session = args.manifest.resolve().parent
    os.chmod(_session, 0o700)
    _manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if not _manifest.get("embedded"):
        threading.Thread(target=_watch_parent, daemon=True).start()
    sdk = Path(_manifest["sdk"]).resolve(strict=True)
    source = Path(_manifest["game"]).resolve(strict=True)
    game_root = Path(_manifest.get("root", source.parent)).resolve(strict=True)
    project = _session / "project"
    _compiled_projects = []
    exit_code = 1
    failed = False
    previous_cwd = Path.cwd()
    previous_argv = sys.argv[:]
    with (_session / "runtime.log").open("w", encoding="utf-8", buffering=1) as log:
        if not _manifest.get("embedded"):
            os.dup2(log.fileno(), 1)
            os.dup2(log.fileno(), 2)
        _log = log
        sys.stdout = sys.stderr = SessionLog()
        sys.path.insert(0, str(sdk))
        sys.modules["aether_renpy_host"] = sys.modules[__name__]
        os.environ["RENPY_LOG_BASE"] = str(_session)
        os.environ.pop("RENPY_SEARCHPATH", None)
        os.environ["RENPY_PATH_TO_SAVES"] = str(Path(_manifest["saves"]) / "_engine")
        try:
            import renpy
            if renpy.version_tuple[0] != 8:
                raise ValueError("The prototype requires a Ren'Py 8 SDK; Ren'Py 7/Python 2 is not supported")
            _publish("starting")
            mirror_game(source, project / "game")
            cache = Path(_manifest["saves"]) / "_engine"
            restore_compiled(project / "game", cache / "compiled")
            patches = stage_patches(game_root, project, cache)
            _compiled_projects = [(project / "game", cache / "compiled")] + patches
            overlay = Path(__file__).with_name("overlay.rpy")
            overlay_path = project / "game/_aether_host_overlay.rpy"
            if overlay_path.exists() or overlay_path.with_suffix(".rpyc").exists():
                raise ValueError("The game uses Aether's reserved host-overlay filename")
            shutil.copy2(overlay, overlay_path)
            font_path = project / "game/_aether_ui_font.otf"
            if font_path.exists():
                raise ValueError("The game uses Aether's reserved host-font filename")
            copy_file(Path(_manifest["ui_font"]), font_path)
            Path(_manifest["saves"]).mkdir(parents=True, exist_ok=True)
            sys.argv = [str(sdk / "renpy.py"), str(project), "run", "--savedir", _manifest["saves"]]
            os.chdir(project)
            run_engine(sdk, [path for path, _cache in patches])
            exit_code = 0
        except SystemExit as error:
            exit_code = int(error.code or 0)
            if exit_code:
                failed = True
                _publish("error", error=f"Ren'Py exited with status {exit_code}")
        except BaseException as error:
            failed = True
            traceback.print_exc()
            _publish("error", error=str(error))
        finally:
            try:
                if not failed:
                    # Preserve statement identities across VMs, including
                    # scripts loaded after startup, outside the original game.
                    for game, cache in _compiled_projects:
                        if game.exists():
                            persist_compiled(game, cache)
                    _publish("exited", exit_code=exit_code, restart=restart_requested)
            except Exception as error:
                exit_code = 1
                traceback.print_exc()
                _publish("error", error=str(error))
            os.chdir(previous_cwd)
            sys.argv = previous_argv
            if project.exists():
                shutil.rmtree(project)
    sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__
    return exit_code


if __name__ == "__main__":
    # Screen actions and callbacks are pickled into Ren'Py saves. Give them a
    # stable importable module name while renpy.py temporarily owns __main__.
    import importlib.util
    spec = importlib.util.spec_from_file_location("aether_renpy_host", __file__)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    raise SystemExit(module.main())
