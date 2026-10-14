"""Per-game native Ren'Py host, using Aether-owned sessions and save folders.

The embedded loop and allowlisted JSON probe share the same interpreter.
The command-line entry point also supports isolated SDK diagnostics.
"""
import argparse
import ctypes
import json
import importlib.util
import math
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import threading
import time
import traceback


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
_compiled_cache = None
_log = None
controls_visible = False
menu_visible = False


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
             "command_error": _command_error}
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
    pygame = _pygame()
    kind = event.get("type")
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
        rel=(_mouse_position[0] - previous[0], _mouse_position[1] - previous[1]), buttons=tuple(_mouse_buttons), touch=bool(event.get("touch"))))
    if kind == "button":
        button = int(event.get("button", 1))
        pressed = bool(event.get("pressed"))
        if 1 <= button <= 3:
            _mouse_buttons[button - 1] = pressed
        if 1 <= button <= 7:
            pygame.event.post(pygame.event.Event(pygame.MOUSEBUTTONDOWN if pressed else pygame.MOUSEBUTTONUP,
                button=button, pos=_mouse_position, touch=bool(event.get("touch"))))


def toggle_controls():
    global controls_visible
    import renpy
    controls_visible = not controls_visible
    if not controls_visible:
        release_keys()
    renpy.exports.restart_interaction()


def toggle_menu():
    global menu_visible
    import renpy
    menu_visible = not menu_visible
    renpy.exports.restart_interaction()


def text(name):
    return _manifest.get("labels", {}).get(name, name)


def quit_game():
    import renpy
    release_keys()
    release_pointer()
    renpy.exports.quit(relaunch=False, status=0)


def _dispatch(command):
    global controls_visible, _inspect_names
    import renpy

    action = command.get("action", "")
    if action == "quit":
        quit_game()
    elif action == "key_tap":
        tap_key(command["key"])
    elif action == "key":
        key(command["key"], bool(command["pressed"]))
    elif action == "controls":
        controls_visible = bool(command["visible"])
        if not controls_visible:
            release_keys()
        renpy.exports.restart_interaction()
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
    persist_compiled(_session / "project/game", _compiled_cache)
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
    if "_aether_renpy_overlay" not in renpy.config.overlay_screens:
        renpy.config.overlay_screens.append("_aether_renpy_overlay")
    if _manifest.get("embedded"):
        renpy.config.quit_on_mobile_background = False


def run_engine(sdk):
    # These are distributor hooks in the original launcher. Mobile launchers
    # choose a shared Documents/private directory before processing --savedir;
    # supply Aether's per-game namespace before any persistent data is read.
    spec = importlib.util.spec_from_file_location("_aether_renpy_entry", sdk / "renpy.py")
    entry = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = entry
    spec.loader.exec_module(entry)
    entry.path_to_saves = lambda *_args, **_kwargs: _manifest["saves"]
    previous_main = sys.modules.get("__main__")
    entry.__name__ = "__main__"
    sys.modules["__main__"] = entry
    try:
        entry.main()
    finally:
        sys.modules["__main__"] = previous_main


def main():
    global _manifest, _session, _compiled_cache, _log
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
    project = _session / "project"
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
            _compiled_cache = Path(_manifest["saves"]) / "_engine" / "compiled"
            restore_compiled(project / "game", _compiled_cache)
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
            run_engine(sdk)
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
                    if _compiled_cache is not None and (project / "game").exists():
                        persist_compiled(project / "game", _compiled_cache)
                    _publish("exited", exit_code=exit_code)
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
