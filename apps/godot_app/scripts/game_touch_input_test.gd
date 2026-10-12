extends SceneTree

# Exercise the shell's real touch callbacks with a recording runtime. No game
# assets, platform emulation settings, or wall-clock sleeps are required.
class TouchShell extends "res://scripts/main.gd":
    func _ready() -> void:
        pass

    func _is_touch_platform() -> bool:
        return true

class RecordingPlayer extends RefCounted:
    var events: Array = []

    func send_pointer_event(type: int, id: int, x: float, y: float,
            dx: float, dy: float, button: int, modifiers: int) -> int:
        events.append([type, id, Vector2(x, y), Vector2(dx, dy), button, modifiers])
        return 0

    func get_renderer_info() -> String:
        return "runtime=bgi"

var checks := 0
var failures := 0

func _initialize() -> void:
    var shell := TouchShell.new()
    var recorder := RecordingPlayer.new()
    shell.player = recorder
    shell.active_runtime_kind = "bgi"
    shell.viewport = TextureRect.new()
    shell.add_child(shell.viewport)
    shell.add_child(shell.ui_motion)
    var point := Vector2(440, 220)

    # A tap positions the pointer before generating exactly one left click.
    _touch(shell, 0, point, true)
    _check(recorder.events.is_empty(), "touch down activated before gesture classification")
    shell.pending_touch_down_msec -= 100
    shell._flush_pending_touch_press_if_ready()
    _check(recorder.events.is_empty(), "holding a finger generated a left press")
    _touch(shell, 0, point + Vector2(2, 1), false)
    _check(recorder.events.size() == 2, "tap must send MOVE then DOWN")
    _check(recorder.events[0][0] == shell.POINTER_MOVE and recorder.events[0][2] == point,
        "tap did not position the cursor at the stable touch point")
    _check(recorder.events[1][0] == shell.POINTER_DOWN and recorder.events[1][4] == 0,
        "tap did not generate a left press")
    _release_pending(shell)
    _check(recorder.events.size() == 3 and recorder.events[2][0] == shell.POINTER_UP,
        "tap did not release its left press")

    # Holding and moving is cursor motion, including its final release.
    _reset(shell, recorder)
    _touch(shell, 0, point, true)
    _drag(shell, 0, point + Vector2(100, 30), Vector2(100, 30))
    _drag(shell, 0, point + Vector2(150, 60), Vector2(50, 30))
    _touch(shell, 0, point + Vector2(150, 60), false)
    _check(not recorder.events.is_empty(), "drag never positioned the cursor")
    for event in recorder.events:
        _check(event[0] == shell.POINTER_MOVE and event[5] == 0,
            "cursor drag generated a click or a held-left modifier")
    _check(shell.delayed_touch_releases.is_empty(), "cursor drag queued a trailing click")
    _check(shell.active_touch_points.is_empty() and shell.pending_touch_index == -1,
        "cursor drag left a captured finger")

    # Two fingers generate only right click, even after the primary timeout.
    for lead_ms in [0, 100, 170]:
        _reset(shell, recorder)
        _touch(shell, 0, point - Vector2(12, 0), true)
        shell.pending_touch_down_msec -= lead_ms
        shell._flush_pending_touch_press_if_ready()
        _touch(shell, 1, point + Vector2(12, 0), true)
        _touch(shell, 1, point + Vector2(12, 0), false)
        _touch(shell, 0, point - Vector2(12, 0), false)
        _check(recorder.events.size() == 3, "two-finger tap generated extra events")
        _check(recorder.events[0][0] == shell.POINTER_MOVE and recorder.events[0][2] == point,
            "two-finger tap did not position its right click")
        _check(recorder.events[1][0] == shell.POINTER_DOWN and recorder.events[1][4] == 1,
            "two-finger tap did not press right")
        _check(recorder.events[2][0] == shell.POINTER_UP and recorder.events[2][4] == 1,
            "two-finger tap did not release right")
        _check(shell.active_touch_points.is_empty() and shell.suppressed_touch_points.is_empty(),
            "two-finger release left captured fingers")

    # Reclassifying an already moving cursor must never invent a left UP.
    _reset(shell, recorder)
    _touch(shell, 0, point, true)
    _drag(shell, 0, point + Vector2(50, 0), Vector2(50, 0))
    _touch(shell, 1, point + Vector2(70, 0), true)
    _touch(shell, 0, point + Vector2(50, 0), false)
    _touch(shell, 1, point + Vector2(70, 0), false)
    for event in recorder.events:
        _check(event[0] == shell.POINTER_MOVE or event[4] == 1,
            "secondary gesture cancelled a left press that never existed")

    # Other runtime families retain their existing held-button route.
    for runtime_kind in ["kirikiri", "catsystem2", "onscripter"]:
        _reset(shell, recorder)
        shell.active_runtime_kind = runtime_kind
        _touch(shell, 0, point, true)
        _check(shell._flush_pending_touch_press(true), "existing touch hold did not flush")
        _check(recorder.events.size() == 2 and recorder.events[1][0] == shell.POINTER_DOWN,
            "%s lost its held left press" % runtime_kind)
        _drag(shell, 0, point + Vector2(100, 0), Vector2(100, 0))
        _touch(shell, 0, point + Vector2(100, 0), false)
        _check(recorder.events.back()[0] == shell.POINTER_UP,
            "%s lost its held-button release" % runtime_kind)

    shell.free()
    print("game_touch_input_test: %s (%d checks, %d failures)" % [
        "PASS" if failures == 0 else "FAIL", checks, failures])
    quit(0 if failures == 0 else 1)

func _touch(shell: Node, id: int, point: Vector2, pressed: bool) -> void:
    var event := InputEventScreenTouch.new()
    event.index = id
    event.position = point
    event.pressed = pressed
    _check(shell._handle_game_pointer_event(event), "touch event was not handled")

func _drag(shell: Node, id: int, point: Vector2, relative: Vector2) -> void:
    var event := InputEventScreenDrag.new()
    event.index = id
    event.position = point
    event.relative = relative
    _check(shell._handle_game_pointer_event(event), "drag event was not handled")

func _release_pending(shell: Node) -> void:
    for id in shell.delayed_touch_releases:
        shell.delayed_touch_releases[id]["due_msec"] = 0
    shell._flush_delayed_touch_releases()

func _reset(shell: Node, recorder: RecordingPlayer) -> void:
    _release_pending(shell)
    recorder.events.clear()
    shell.last_forwarded_touch_down_msec = 0
    shell.last_forwarded_touch_up_msec = 0
    shell.touch_input_busy_until_msec = 0
    shell.touch_secondary_quarantine_until_msec = 0

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("game_touch_input_test: " + message)
