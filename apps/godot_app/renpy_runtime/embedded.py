"""Cooperative native loop; all entry points stay on one Python owner thread."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
from greenlet import greenlet, getcurrent
import renpy.pygame as pygame

_root = getcurrent()
_runner = None
_deadline = 0.0
_poll = pygame.event.poll
_input = []


def input_events(events):
    _input.extend(events[:256])


def _drain_input():
    host = sys.modules.get("aether_renpy_host")
    if host is None or not host._ready:
        _input.clear()
        return
    events, _input[:] = _input[:], []
    for event in events:
        host.input_event(event)


def _yield():
    _root.switch()


def _poll_event():
    if time.monotonic() >= _deadline:
        _yield()
    _drain_input()
    return _poll()


def _wait_event():
    while True:
        _drain_input()
        event = _poll()
        if event.type != pygame.NOEVENT:
            return event
        _yield()


pygame.event.poll = _poll_event
pygame.event.wait = _wait_event


def open_session(manifest):
    global _runner
    _input.clear()
    if _runner is not None and not _runner.dead:
        raise RuntimeError("A Ren'Py game is already running")
    import renpy
    if _runner is not None and hasattr(renpy.backup, "objects_pickle"):
        # bootstrap's finally block already released the renderer on exit.
        renpy.session["_keep_renderer"] = True
        renpy.display.draw = None
        try:
            renpy.reload_all()
        finally:
            renpy.session.pop("_keep_renderer", None)
        # import_all establishes the module backup once per interpreter.
        # Bootstrap calls it again; keep the restored baseline instead of
        # copying late-loaded third-party module objects into a new backup.
        original_import = renpy.import_all
        def imported():
            renpy.import_all = original_import
        renpy.import_all = imported
    path = Path(manifest).parent / "host.py"
    spec = importlib.util.spec_from_file_location("aether_renpy_host", path)
    host = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = host
    spec.loader.exec_module(host)
    sys.argv = [str(path), "--manifest", manifest]
    _runner = greenlet(host.main)


def step():
    global _deadline
    if _runner is not None and not _runner.dead:
        _deadline = time.monotonic() + 0.006
        _runner.switch()


def close_session():
    if _runner is not None and not _runner.dead:
        try:
            _runner.throw(SystemExit(0))
        except SystemExit:
            # A not-yet-started greenlet has not entered host.main's handler.
            # Never let SystemExit reach the embedding CPython entry point.
            pass
    pygame.display.destroy()


def pause(value):
    import renpy
    if hasattr(renpy, "audio"):
        (renpy.audio.audio.pause_all if value else renpy.audio.audio.unpause_all)()
    host = sys.modules.get("aether_renpy_host")
    if host is not None and host._ready:
        host.release_keys()
        host.release_pointer()
