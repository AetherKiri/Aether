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

    _test_qlie_touch(shell, recorder, point)

    shell.free()
    print("game_touch_input_test: %s (%d checks, %d failures)" % [
        "PASS" if failures == 0 else "FAIL", checks, failures])
    quit(0 if failures == 0 else 1)

func _test_qlie_touch(shell: TouchShell, recorder: RecordingPlayer, point: Vector2) -> void:
    _reset(shell, recorder)
    shell.active_runtime_kind = "qlie"
    var finger := 7
    var pointer_id := shell._touch_engine_pointer_id(finger)
    var jitter := Vector2(2, 1)
    var far_point := point + Vector2(100, 30)
    _touch(shell, finger, point, true)
    shell.pending_touch_down_msec -= shell.TOUCH_SINGLE_TAP_DELAY_MS
    shell._flush_pending_touch_press_if_ready()
    _drag(shell, finger, point + jitter, jitter)
    _check(recorder.events.is_empty(), "QLIE tap sent pointer events before release")
    _touch(shell, finger, point + jitter, false)
    _touch(shell, finger, point + jitter, false)
    _release_pending(shell)
    _check(recorder.events == [
        [shell.POINTER_MOVE, pointer_id, point, Vector2.ZERO, 0, 0],
        [shell.POINTER_DOWN, pointer_id, point, Vector2.ZERO, 0, 0],
        [shell.POINTER_UP, pointer_id, point, Vector2.ZERO, 0, 0],
    ], "QLIE tap must position the cursor and activate exactly once after release")

    _reset(shell, recorder)
    _touch(shell, finger, point, true)
    shell.pending_touch_down_msec -= shell.QLIE_TOUCH_TAP_MAX_MS
    shell._flush_pending_touch_press_if_ready()
    _check(recorder.events.is_empty(), "QLIE hold activated before release")
    _touch(shell, finger, point, false)
    _release_pending(shell)
    _check(recorder.events.is_empty(), "QLIE hold activated on release")

    _reset(shell, recorder)
    _touch(shell, finger, point, true)
    _drag(shell, finger, far_point, far_point - point)
    _drag(shell, finger, point, point - far_point)
    _touch(shell, finger, point, false)
    _release_pending(shell)
    _check(recorder.events == [
        [shell.POINTER_MOVE, pointer_id, point, Vector2.ZERO, 0, 0],
        [shell.POINTER_MOVE, pointer_id, far_point, far_point - point, 0, 0],
        [shell.POINTER_MOVE, pointer_id, point, point - far_point, 0, 0],
    ], "QLIE drag must only move the cursor, including when it returns to its origin")

    _reset(shell, recorder)
    _touch(shell, finger, point, true)
    _touch(shell, finger, far_point, false)
    _release_pending(shell)
    _check(recorder.events.is_empty(), "QLIE release outside tap tolerance activated without a drag event")

    _reset(shell, recorder)
    _touch(shell, finger, point, true)
    _touch(shell, finger, point, false, true)
    _release_pending(shell)
    _check(recorder.events.is_empty(), "QLIE cancelled tap activated")

    _reset(shell, recorder)
    var frame_size := Vector2i(480, 240)
    shell.last_source_texture_size = frame_size
    shell.current_surface_size = frame_size
    shell.viewport.texture = ImageTexture.create_from_image(
        Image.create_empty(frame_size.x, frame_size.y, false, Image.FORMAT_RGBA8)
    )
    shell.viewport.size = Vector2(frame_size)
    var edge_point := Vector2(2, 120)
    var outside_point := Vector2(-2, 120)
    _touch(shell, finger, edge_point, true)
    _touch(shell, finger, outside_point, false)
    _check(recorder.events.is_empty(), "QLIE tap released outside the game activated")
    _touch(shell, finger, edge_point, true)
    _drag(shell, finger, outside_point, outside_point - edge_point)
    _touch(shell, finger, edge_point, false)
    _release_pending(shell)
    _check(recorder.events == [[shell.POINTER_MOVE, pointer_id, edge_point, Vector2.ZERO, 0, 0]],
        "QLIE drag outside the frame and back must stay cursor-only")
    _check(shell.active_touch_points.is_empty() and shell.pending_touch_index == -1,
        "QLIE touch gestures left a captured finger")

func _touch(shell: Node, id: int, point: Vector2, pressed: bool, canceled: bool = false) -> void:
    var event := InputEventScreenTouch.new()
    event.index = id
    event.position = point
    event.pressed = pressed
    event.canceled = canceled
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
