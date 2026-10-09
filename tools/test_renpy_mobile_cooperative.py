#!/usr/bin/env python3
"""Exercise real greenlet stack switching with a synthetic Ren'Py boundary.

This verifies cooperative ownership/input/frame contracts. It does not execute
Ren'Py's engine, GL, SDL or a game and is not gameplay acceptance.
"""
import argparse
import ast
import importlib.util
from pathlib import Path
import sys
import tempfile
import textwrap
import threading
import types

parser = argparse.ArgumentParser()
parser.add_argument("--renpy-src", required=True, type=Path)
args = parser.parse_args()
try:
    import greenlet
except ImportError:
    raise SystemExit("Install target-matching greenlet 3.2.4 to run cooperative behavior checks")
assert greenlet.__version__ == "3.2.4", greenlet.__version__
sys.modules["_aether_greenlet"] = greenlet
renpy = types.ModuleType("renpy")
renpy.__path__ = []
sys.modules["renpy"] = renpy
spec = importlib.util.spec_from_file_location("renpy.aether_mobile", args.renpy_src / "renpy/aether_mobile.py")
mobile = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mobile
spec.loader.exec_module(mobile)
renpy.aether_mobile = mobile

class QuitException(Exception):
    pass

renpy.game = types.ModuleType("renpy.game")
renpy.game.QuitException = QuitException
sys.modules["renpy.game"] = renpy.game
log = []
events = []
binds = []
teardown = []
window = types.SimpleNamespace(get_size=lambda: (800, 600),
                               get_sdl_window_pointer=lambda: types.SimpleNamespace(value=17))
pygame = types.ModuleType("renpy.pygame")
for name, number in {"KEYDOWN": 1, "KEYUP": 2, "TEXTINPUT": 3, "MOUSEBUTTONDOWN": 4,
                     "MOUSEBUTTONUP": 5, "MOUSEMOTION": 6, "MOUSEWHEEL": 7,
                     "K_ESCAPE": 27}.items():
    setattr(pygame, name, number)
pygame.event = types.SimpleNamespace(post=events.append, Event=lambda event_type, **values: dict(type=event_type, **values),
                                    get_mousewheel_buttons=lambda: True)
pygame.display = types.SimpleNamespace(get_window=lambda: window)
pygame.display.prepare_mobile_shutdown = lambda: teardown.append("protect_host_display")
pygame.display.get_init = lambda: True
pygame.display.quit = lambda: teardown.append("delete_owned_window")
pygame.time = types.SimpleNamespace(set_timer=lambda event_type, interval: teardown.append((event_type, interval)))
pygame.event.clear = lambda event_types: teardown.append(("clear_timers", event_types))
core = types.ModuleType("renpy.display.core")
core.PERIODIC, core.REDRAW, core.TIMEEVENT = 50, 51, 52
core.PERIODIC_INTERVAL = 50
sys.modules[core.__name__] = core
shader = types.ModuleType("renpy.gl2.gl2shader")
shader.retire_mobile_programs = lambda: teardown.append("retire_programs")
sys.modules[shader.__name__] = shader
pygame.key = types.SimpleNamespace(text_input=True)
renpy.pygame = pygame
sys.modules["renpy.pygame"] = pygame
sys.modules["_aether_host"] = types.SimpleNamespace(bind_window=lambda pointer: binds.append(pointer) or 0)
surface = types.SimpleNamespace(get_bytesize=lambda: 4, get_size=lambda: (2, 1),
                                aether_copy_pixels=lambda: b"\x01\x02\x03\xff\x04\x05\x06\xff")
interface = types.SimpleNamespace(started=True, mobile_save=lambda: log.append("save"), force_redraw=False,
                                 pushed_event=None, kill_textures=lambda: teardown.append("clear_render_caches"))
renpy.config = types.SimpleNamespace(screen_width=800, screen_height=600)
renpy.display = types.SimpleNamespace(interface=interface, draw=types.SimpleNamespace(
    screenshot=lambda tree: surface, untranslate_point=lambda x, y: (round(x), round(y))))
renpy.display.core = core
renpy.audio = types.SimpleNamespace(audio=types.SimpleNamespace(pause_all=lambda: log.append("pause"),
                                                               unpause_all=lambda: log.append("resume")))

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    entry = root / "renpy.py"
    entry.write_text("def main():\n    pass\n")
    def nested_game(game_root, argv0):
        local_state = {"counter": 41}
        try:
            log.append("entered")
            mobile.cooperative_checkpoint(force=True)
            local_state["counter"] += 1
            log.append(local_state["counter"])
            mobile.cooperative_capture("real-render-tree-boundary")
            mobile.cooperative_checkpoint(force=True)
        except QuitException:
            pass
        finally:
            log.append("cleanup")
    mobile._run = nested_game
    mobile.cooperative_start(str(root), str(entry))
    assert log == [], "start ran game before tick deadline was established"
    mobile.cooperative_set_surface_size(800, 600)
    assert mobile.cooperative_surface_size() == (800, 600)
    assert mobile.cooperative_tick(1) == "yield"
    assert log == ["entered"], "yield unwound active game stack"
    for event in [dict(type=2, value=1, code=1, x=0.25, y=0.5),
                  dict(type=2, value=2, code=1, x=0.5, y=0.75),
                  dict(type=2, value=3, code=1, x=0.5, y=0.75),
                  dict(type=1, value=5, code=97, modifiers=2, repeat=True),
                  dict(type=1, value=6, code=97), dict(type=3, value=0, text="你好、日本語 🐾"),
                  dict(type=2, value=4, code=0, x=0.5, y=0.75, delta_y=1)]:
        mobile.cooperative_input(event)
    assert mobile.cooperative_tick(1) == "yield"
    assert log == ["entered", 42], "stack local values were lost or cleanup ran early"
    assert [event["type"] for event in events] == [4, 6, 5, 1, 2, 3, 4, 5]
    assert events[0]["pos"] == (200, 300)
    assert events[1]["buttons"] == (True, False, False)
    assert events[5]["text"] == "你好、日本語 🐾"
    assert events[-2]["button"] == events[-1]["button"] == 4
    assert mobile.cooperative_mouse_pos() == (400, 450)
    assert mobile.cooperative_mouse_pressed() == (False, False, False)
    assert not mobile.cooperative_key_pressed(97)
    renpy.config.screen_width = 600
    renpy.display.draw.untranslate_point = lambda x, y: (round(x + 100), round(y))
    mobile.cooperative_input(dict(type=2, value=1, code=1, x=0, y=0))
    mobile._dispatch_input()
    assert events[-1]["pos"] == (100, 0), "input ignored the game viewport letterbox"
    assert mobile.cooperative_frame() == (surface.aether_copy_pixels(), 2, 1, 1)
    assert binds == [17]
    mobile.cooperative_pause()
    assert mobile.cooperative_tick(1) == "yield" and "cleanup" not in log
    assert teardown == [(50, 0), (51, 0), (52, 0), ("clear_timers", (50, 51, 52))]
    before_pause = (list(log), list(teardown))
    mobile.cooperative_pause()
    assert (log, teardown) == before_pause, "repeated pause saved or stopped timers twice"
    mobile.cooperative_resume()
    assert log[-3:] == ["save", "pause", "resume"] and interface.force_redraw
    assert teardown[-2:] == [("clear_timers", (50, 51, 52)), (50, 50)]
    assert mobile.cooperative_timer_generation() == 1 and events[-1]["type"] == core.PERIODIC
    before_resume = (list(log), list(teardown), list(events))
    mobile.cooperative_resume()
    assert (log, teardown, events) == before_resume, "repeated resume restarted timers or posted extra events"
    assert mobile.cooperative_text_input_state()
    errors = []
    def other_thread():
        try:
            mobile.cooperative_tick(1)
        except RuntimeError as error:
            errors.append(str(error))
    thread = threading.Thread(target=other_thread)
    thread.start(); thread.join()
    assert errors and "original host thread" in errors[0]
    teardown.clear()
    mobile.cooperative_stop()
    assert log.count("cleanup") == 1 and not mobile.cooperative_active()
    assert mobile.cooperative_tick(1) == "not_started"
    assert teardown == ["retire_programs", "protect_host_display", "clear_render_caches",
                        (50, 0), (51, 0), (52, 0), ("clear_timers", (50, 51, 52)), "delete_owned_window"]
    before = list(teardown)
    mobile.cooperative_stop()
    assert teardown == before, "repeated stop ran GPU/window teardown twice"

    # Validate official-entry dispatch and SystemExit handling independently.
    entry.write_text("def main():\n    import sys\n    import renpy\n    renpy.entry_argv = list(sys.argv)\n    raise SystemExit(0)\n")
    del sys.modules["renpy.aether_mobile"]
    spec.loader.exec_module(mobile)
    sys.modules["renpy.aether_mobile"] = mobile
    mobile.cooperative_start(str(root), str(entry))
    assert mobile.cooperative_tick(10) == "finished"
    assert renpy.entry_argv == [str(entry), str(root)]
    mobile.cooperative_stop()

    def fresh_mobile():
        spec.loader.exec_module(mobile)
        renpy.display.draw = types.SimpleNamespace(
            shader_cache=types.SimpleNamespace(clear=lambda: teardown.append("clear_shader_cache")),
            texture_loader=types.SimpleNamespace(retire_mobile=lambda: teardown.append("retire_loader")),
            window=window)
        teardown.clear()
        return mobile

    # A real newborn greenlet is false and must not receive QuitException.
    fresh_mobile()
    mobile.cooperative_start(str(root), str(entry))
    assert not mobile._game and not mobile._game.dead
    mobile.cooperative_stop()
    assert not mobile.cooperative_active()
    assert teardown.index("retire_programs") < teardown.index("retire_loader") < teardown.index("clear_shader_cache")
    assert teardown[-1] == "delete_owned_window"

    # Paused destruction must still unwind the active game exactly once.
    fresh_mobile()
    def paused_game(*_):
        try:
            mobile.cooperative_checkpoint(force=True)
        except QuitException:
            pass
        finally:
            log.append("paused_finally")
    mobile._run = paused_game
    mobile.cooperative_start(str(root), str(entry))
    mobile.cooperative_tick(1)
    mobile.cooperative_pause()
    mobile.cooperative_stop()
    assert log.count("paused_finally") == 1 and teardown[-1] == "delete_owned_window"

    # Startup errors return through _run; stop must release any partial display.
    fresh_mobile()
    entry.write_text("def main():\n    raise RuntimeError('bootstrap failed')\n")
    mobile.cooperative_start(str(root), str(entry))
    try:
        mobile.cooperative_tick(1)
        raise AssertionError("startup failure disappeared")
    except RuntimeError as error:
        assert "bootstrap failed" in str(error)
    mobile.cooperative_stop()
    assert teardown[-1] == "delete_owned_window" and not mobile.cooperative_active()

    # A failing teardown must remain observable and retryable, not clear owner.
    fresh_mobile()
    mobile.cooperative_start(str(root), str(entry))
    saved_quit = pygame.display.quit
    def failed_quit():
        raise RuntimeError("owned display teardown failed")
    pygame.display.quit = failed_quit
    try:
        mobile.cooperative_stop()
        raise AssertionError("cleanup failure disappeared")
    except RuntimeError as error:
        assert "owned display teardown failed" in str(error)
    assert mobile.cooperative_active() and not mobile._terminal_cleanup_done
    pygame.display.quit = saved_quit
    mobile.cooperative_stop()
    assert not mobile.cooperative_active()

    # No renderer/display imports are added when startup never loaded them.
    fresh_mobile()
    mobile.cooperative_start(str(root), str(entry))
    del sys.modules["renpy.pygame"]
    del sys.modules["renpy.gl2.gl2shader"]
    mobile.cooperative_stop()
    assert "renpy.pygame" not in sys.modules and "renpy.gl2.gl2shader" not in sys.modules
    assert teardown == []
    sys.modules["renpy.pygame"] = pygame
    sys.modules[shader.__name__] = shader

    # Run the patched Interface.event_wait and timer scheduling source with a
    # controlled SDL timer queue. The greenlet is real; the clock/SDL events
    # remain fixtures, so this is not renderer or gameplay acceptance.
    source = (args.renpy_src / "renpy/display/core.py").read_text()
    interface_ast = next(node for node in ast.parse(source).body
                         if isinstance(node, ast.ClassDef) and node.name == "Interface")
    event_wait_ast = next(node for node in interface_ast.body
                          if isinstance(node, ast.FunctionDef) and node.name == "event_wait")
    wait_globals = {"aether_mobile": mobile, "pygame": pygame,
                    "renpy": types.SimpleNamespace(emscripten=False)}
    exec(compile(ast.Module(body=[event_wait_ast], type_ignores=[]), str(args.renpy_src / "renpy/display/core.py"), "exec"),
         wait_globals)
    checkpoint_start = source.index("                aether_mobile.cooperative_checkpoint()")
    checkpoint_end = source.index('                renpy.plog(1, "start of interact while loop")', checkpoint_start)
    checkpoint_source = compile(textwrap.dedent(source[checkpoint_start:checkpoint_end]), "interact_core resume boundary", "exec")
    schedule_start = source.index("                # Compute the redraw time and set the redraw timer.")
    schedule_end = source.index("                # Process the invoke queue.", schedule_start)
    schedule_source = compile(textwrap.dedent(source[schedule_start:schedule_end]), "interact_core SDL timer scheduling", "exec")

    class TimerQueue:
        def __init__(self):
            self.now = 0
            self.timers = {}
            self.queue = []
            self.calls = []

        def set_timer(self, event_type, interval, once=False):
            self.calls.append((event_type, interval, once))
            self.timers.pop(event_type, None)
            if interval:
                self.timers[event_type] = (interval, self.now + interval, once)

        def advance(self, milliseconds):
            self.now += milliseconds
            for event_type, (interval, due, once) in list(self.timers.items()):
                while due <= self.now:
                    self.post(dict(type=event_type))
                    if once:
                        self.timers.pop(event_type)
                        break
                    due += interval
                else:
                    self.timers[event_type] = (interval, due, once)

        def clear(self, event_types):
            self.queue[:] = [event for event in self.queue if event["type"] not in event_types]

        def post(self, event):
            self.queue.append(event)

        def poll(self):
            return types.SimpleNamespace(**self.queue.pop(0)) if self.queue else types.SimpleNamespace(type=pygame.NOEVENT)

    timers = TimerQueue()
    pygame.NOEVENT = 0
    pygame.time = types.SimpleNamespace(set_timer=timers.set_timer)
    pygame.event = types.SimpleNamespace(Event=lambda event_type, **values: dict(type=event_type, **values),
                                         post=timers.post, poll=timers.poll, clear=timers.clear)
    fresh_mobile()
    wait_interface = types.SimpleNamespace(pushed_event=None, last_event=None,
        check_background_screenshot=lambda: None, timeout_time=2000.0,
        post_time_event=lambda: timers.post(dict(type=core.TIMEEVENT)),
        redraw_event=dict(type=core.REDRAW))
    interface.pushed_event = None
    boundary = {"aether_mobile": mobile, "pygame": pygame, "self": wait_interface,
        "PERIODIC": core.PERIODIC, "REDRAW": core.REDRAW, "TIMEEVENT": core.TIMEEVENT,
        "get_time": lambda: timers.now / 1000.0, "redraw_time": 1000.0,
        "old_redraw_time": None, "old_timeout_time": None,
        "aether_timer_generation": mobile.cooperative_timer_generation()}
    resumed_waits = []
    def timer_wait_game(*_):
        stack_token = object()
        try:
            exec(schedule_source, boundary)
            for _ in range(2):
                event = wait_globals["event_wait"](wait_interface)
                exec(checkpoint_source, boundary)
                exec(schedule_source, boundary)
                resumed_waits.append((stack_token, event.type))
                mobile.cooperative_checkpoint(force=True)
        except QuitException:
            pass

    mobile._run = timer_wait_game
    mobile.cooperative_start(str(root), str(entry))
    timers.set_timer(core.PERIODIC, core.PERIODIC_INTERVAL)
    assert mobile.cooperative_tick(1000) == "yield" and resumed_waits == []
    assert boundary["old_redraw_time"] == 1000.0 and boundary["old_timeout_time"] == 2000.0
    timers.advance(500)
    assert len(timers.queue) == 10, "fixture did not reproduce periodic backlog"
    timers.post(dict(type=pygame.TEXTINPUT, text="retained input"))
    interface.pushed_event = types.SimpleNamespace(type=core.PERIODIC)
    mobile.cooperative_pause()
    assert timers.timers == {} and interface.pushed_event is None
    assert timers.queue == [dict(type=pygame.TEXTINPUT, text="retained input")]
    timers.advance(50000)
    assert len(timers.queue) == 1 and mobile.cooperative_tick(1000) == "yield"
    assert resumed_waits == [], "paused Tick resumed the saved event_wait"
    # Model an SDL callback already in flight at removal; resume clears it.
    timers.post(dict(type=core.TIMEEVENT))
    mobile.cooperative_resume()
    assert [event["type"] for event in timers.queue] == [pygame.TEXTINPUT, core.PERIODIC]
    assert mobile.cooperative_tick(1000) == "yield"
    assert resumed_waits[0][1] == pygame.TEXTINPUT
    assert boundary["old_timeout_time"] == wait_interface.timeout_time == 2000.0
    assert timers.timers[core.REDRAW][0] == 1000
    assert timers.timers[core.TIMEEVENT][0] == int((2000.0 - timers.now / 1000.0) * 1000 + 1)
    assert not any(event["type"] == core.TIMEEVENT for event in timers.queue), "resume fired a future wait early"
    # A second pause passes the existing deadline. Actual scheduler source
    # posts it once on resume instead of retaining a canceled timer forever.
    mobile.cooperative_pause()
    timers.advance(2000000)
    assert timers.queue == [] and timers.timers == {}
    mobile.cooperative_resume()
    assert mobile.cooperative_tick(1000) == "yield"
    assert resumed_waits[1][0] is resumed_waits[0][0], "resume rebuilt the interaction stack"
    assert resumed_waits[1][1] == core.PERIODIC
    assert wait_interface.timeout_time is None
    assert sum(event["type"] == core.TIMEEVENT for event in timers.queue) == 1
    mobile.cooperative_stop()
    assert timers.timers == {} and timers.queue == []

    # A pause before display startup must neither import it nor arm timers.
    fresh_mobile()
    interface.started = False
    mobile.cooperative_start(str(root), str(entry))
    before = len(timers.calls)
    saved_pygame = sys.modules.pop("renpy.pygame")
    saved_core = sys.modules.pop("renpy.display.core")
    mobile.cooperative_pause()
    mobile.cooperative_resume()
    assert len(timers.calls) == before and mobile.cooperative_timer_generation() == 0
    assert "renpy.pygame" not in sys.modules and "renpy.display.core" not in sys.modules
    sys.modules["renpy.pygame"] = saved_pygame
    sys.modules["renpy.display.core"] = saved_core
    mobile.cooperative_stop()
    interface.started = True

renderer_source = (args.renpy_src / "renpy/gl2/gl2draw.pyx").read_text()
start = renderer_source.index("        gles = self.gles")
end = renderer_source.index("        # Select the GL attributes and hints.", start)
size_selection = textwrap.dedent(renderer_source[start:end])
for platform in ("android", "ios"):
    for enabled in (False, True):
        context = {
            "self": types.SimpleNamespace(gles=False), "pwidth": 1600, "pheight": 900,
            "renpy": types.SimpleNamespace(android=platform == "android", ios=platform == "ios",
                aether_mobile=types.SimpleNamespace(cooperative_active=lambda: enabled),
                config=types.SimpleNamespace(gl2_modify_window_flags=None)),
            "pygame": types.SimpleNamespace(OPENGL=1, DOUBLEBUF=2, WINDOW_ALLOW_HIGHDPI=4, RESIZABLE=8),
        }
        exec(size_selection, context)
        assert (context["pwidth"], context["pheight"]) == ((1600, 900) if enabled else (0, 0))
        assert context["gles"]
        if platform == "ios":
            assert context["window_flags"] & 12 == 12

print("Cooperative checks passed: real greenlet ownership, input/frame contracts, paused timer queue and resumed waits, natural/paused/newborn/failed startup shutdown, terminal cleanup order, retry errors and idempotence")
print("Synthetic engine boundaries only; Ren'Py/SDL/GL/device gameplay was not run")
