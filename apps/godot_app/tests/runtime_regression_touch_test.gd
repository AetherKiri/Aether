extends SceneTree

const Probe = preload("res://scripts/runtime_regression_probe.gd")

class RecordingPlayer:
    extends Node
    var events: Array[Dictionary] = []
    func get_frame_source_size() -> Vector2i:
        return Vector2i(1280, 720)
    func get_renderer_info() -> String:
        return ""
    func get_plugin_debug_info() -> String:
        return "{}"
    func send_pointer_event(kind: int, pointer: int, x: float, y: float, _dx: float, _dy: float, button: int, _modifiers: int = 0) -> int:
        events.append({"kind": kind, "pointer": pointer, "position": Vector2(x, y), "button": button, "time": Time.get_ticks_msec()})
        return 0

class TouchApp:
    extends "res://scripts/main.gd"
    var force_busy := false
    func _ready() -> void:
        pass
    func _process(_delta: float) -> void:
        pass
    func _is_touch_platform() -> bool:
        return true
    func _is_touch_input_busy() -> bool:
        return force_busy
    func _write_probe_marker(_line: String) -> void:
        pass
    func _probe_advance(frames: int) -> bool:
        for _frame in frames:
            _flush_delayed_touch_releases()
            _flush_pending_touch_press_if_ready()
            await get_tree().process_frame
        return true

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var app := TouchApp.new()
    root.add_child(app)
    var player := RecordingPlayer.new()
    app.add_child(player)
    app.player = player
    var surface := TextureRect.new()
    surface.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    surface.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    var texture := PlaceholderTexture2D.new()
    texture.size = Vector2(1920, 1080)
    surface.texture = texture
    app.add_child(surface)
    surface.position = Vector2(40, 30)
    surface.size = Vector2(800, 600)
    app.viewport = surface
    app.active_runtime_kind = "softpal"
    app.current_surface_size = Vector2i(1920, 1080)
    app.last_texture_size = Vector2i(1920, 1080)
    app.last_source_texture_size = Vector2i(1280, 720)
    var directory := "user://regressions/touch-test-%d" % Time.get_ticks_usec()
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
    var probe = Probe.new(app, {"writable_root": directory})

    # An enhanced texture and letterboxing must still hit the native frame's
    # right-side control, and a short tap must retain its mobile press pulse.
    assert(await probe.tap({"x": 1200, "y": 300}, "short-touch"))
    _check_edges(player.events, app, 100000)
    assert(player.events[2].time - player.events[1].time >= app.TOUCH_CLICK_HOLD_MS)
    assert(app.delayed_touch_releases.is_empty())

    # A stationary hold is dispatched before release; it must not be turned
    # into a second tap or leave the native button held afterwards.
    player.events.clear()
    assert(await probe.tap({"x": 1200, "y": 300, "hold_frames": 40, "touch_index": 1}, "held-touch"))
    _check_edges(player.events, app, 100001)
    assert(player.events[2].time - player.events[1].time > 0)
    assert(app.active_touch_points.is_empty())

    player.events.clear()
    assert(probe.two_finger_tap({"x": 1200, "y": 300}, "two-finger-return"))
    _check_edges(player.events, app, app.TOUCH_SECONDARY_POINTER_ID)
    assert(player.events[1].button == 1 and player.events[2].button == 1)
    assert(app.active_touch_points.is_empty())
    assert(app.suppressed_touch_points.is_empty())
    assert(app.pending_touch_index == -1)

    # A consumed gesture cannot be reported as a successful button click.
    player.events.clear()
    app.touch_secondary_quarantine_until_msec = Time.get_ticks_msec() + 1000
    assert(not await probe.tap({"x": 1200, "y": 300}, "suppressed-touch"))
    assert(player.events.is_empty())
    assert(probe.report.back().reason == "touch not forwarded")
    player.events.clear()
    app.force_busy = true
    assert(not probe.two_finger_tap({"x": 1200, "y": 300}, "suppressed-gesture"))
    assert(player.events.is_empty())
    assert(probe.report.back().reason == "gesture not forwarded")

    DirAccess.remove_absolute(ProjectSettings.globalize_path(directory.path_join("regression-result.json")))
    DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))
    app.ui_motion.free()
    app.free()
    print("Runtime regression touch mapping, mobile release and suppression checks passed")
    quit(0)

func _check_edges(events: Array[Dictionary], app: Node, pointer: int) -> void:
    assert(events.size() == 3)
    assert(events[0].kind == app.POINTER_MOVE)
    assert(events[1].kind == app.POINTER_DOWN)
    assert(events[2].kind == app.POINTER_UP)
    for event in events:
        assert(event.pointer == pointer)
        assert(event.position.is_equal_approx(Vector2(1200, 300)))
