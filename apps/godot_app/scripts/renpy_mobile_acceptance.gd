extends Node

# A debug-device observer, driven exclusively by OS input. It never manufactures
# game progress, sends a scripted click, or falls back to a viewport screenshot.
const GameInputMapping = preload("res://scripts/game_input_mapping.gd")
const POINTER_DOWN := 1
const POINTER_MOVE := 2
const POINTER_UP := 3
const TOUCH_POINTER_ID_OFFSET := 100000

var player
var rect: TextureRect
var config: Dictionary = {}
var evidence_dir := ""
var game_dir := ""
var run_id := ""
var started := false
var finished := false
var paused := false
var keyboard_active := false
var keyboard_visible := false
var resumed_capture_pending := false
var paused_frame_serial := 0
var checkpoint_count := 0
var suppress_mouse_until := 0
var deadline := 0

func start(request: Dictionary, runtime_player: Object) -> void:
    config = request
    player = runtime_player
    if not OS.is_debug_build() or OS.get_name() not in ["Android", "iOS"]:
        _fail("This observer requires a debug mobile app on a cloud device.")
        return
    run_id = String(config.get("run_id", ""))
    game_dir = String(config.get("game_path", "")).path_join("game")
    evidence_dir = ProjectSettings.globalize_path("user://renpy-device-evidence")
    DirAccess.make_dir_recursive_absolute(evidence_dir)
    if run_id.is_empty() or not FileAccess.file_exists(game_dir.path_join("aether-device-request.json")):
        _fail("The staged real Ren'Py device project/request is missing.")
        return
    deadline = Time.get_ticks_msec() + int(config.get("timeout_seconds", 180)) * 1000
    rect = TextureRect.new()
    rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    add_child(rect)
    # Use the provider's original pixels for the native/OS image comparison,
    # independently of any saved cloud debug-app enhancement preference.
    player.set_frame_enhancement_enabled(false)
    var result: int = player.set_render_backend("Godot Native")
    if result == 0:
        result = player.set_engine_option("runtime", "renpy")
    if result == 0:
        result = player.open_game(String(config.get("game_path", "")), true)
    if result != 0:
        _fail("Opening the real Ren'Py provider failed: %s" % player.get_last_error())
        return
    _record({"kind": "opening", "platform": OS.get_name(), "debug_build": true})

func _process(delta: float) -> void:
    if finished or player == null:
        return
    if Time.get_ticks_msec() > deadline:
        _fail("Device gameplay timed out; no automatic success or skipped result.")
        return
    if not started:
        var state: int = player.get_startup_state()
        if state == 3:
            _fail("Ren'Py startup failed: %s" % player.get_last_error())
            return
        if state != 2:
            return
        started = true
        _record({"kind": "startup", "provider_debug": _provider_debug()})
    if paused:
        return
    var result: int = player.tick(clampf(delta, 0.001, 0.1))
    # Normal exit must be observed in native provider state, independently of
    # the script's quit_requested checkpoint. A successful tick alone is not exit.
    var native_state := _provider_debug()
    if bool(native_state.get("exited", false)):
        if not _has_game_checkpoint("quit_requested"):
            _fail("Native provider exited before the game's explicit Quit action.")
            return
        _finish(native_state)
        return
    if result != 0:
        _fail("Ren'Py tick failed: %s" % player.get_last_error())
        return
    var texture: Texture2D = player.update_frame_texture()
    if texture != null:
        rect.texture = texture
    if resumed_capture_pending:
        resumed_capture_pending = false
        _capture_provider("resumed_ready")
    _sync_keyboard()
    _observe_game_checkpoints()

func _notification(what: int) -> void:
    if not started or finished or player == null:
        return
    if what == NOTIFICATION_APPLICATION_PAUSED and not paused:
        var result: int = player.pause()
        paused = result == 0
        paused_frame_serial = int(_provider_debug().get("frame_serial", 0))
        _record({"kind": "lifecycle", "phase": "paused", "result": result,
            "provider_debug": _provider_debug()})
        if result != 0:
            _fail("Native pause failed: %s" % player.get_last_error())
    elif what == NOTIFICATION_APPLICATION_RESUMED and paused:
        var result: int = player.resume()
        paused = false
        resumed_capture_pending = result == 0
        _record({"kind": "lifecycle", "phase": "resumed", "result": result,
            "provider_debug": _provider_debug()})
        if result != 0:
            _fail("Native resume failed: %s" % player.get_last_error())

func _input(event: InputEvent) -> void:
    if not started or paused or finished or player == null or rect.texture == null:
        return
    var result := 0
    if event is InputEventScreenTouch:
        var touch := event as InputEventScreenTouch
        suppress_mouse_until = Time.get_ticks_msec() + 700
        var point := _map_point(touch.position)
        if point.x < 0:
            return
        var action := POINTER_DOWN if touch.pressed else POINTER_UP
        result = player.send_pointer_event(action, TOUCH_POINTER_ID_OFFSET + touch.index,
            point.x, point.y, 0.0, 0.0, 0)
        _record({"kind": "os_touch", "action": action, "pointer_id": touch.index,
            "position": [point.x, point.y], "result": result})
    elif event is InputEventScreenDrag:
        var drag := event as InputEventScreenDrag
        suppress_mouse_until = Time.get_ticks_msec() + 700
        var point := _map_point(drag.position)
        var relative := GameInputMapping.map_delta(drag.relative, rect.size, rect.texture.get_size())
        result = player.send_pointer_event(POINTER_MOVE, TOUCH_POINTER_ID_OFFSET + drag.index,
            point.x, point.y, relative.x, relative.y, 0)
    elif event is InputEventMouseButton:
        if event.device == -1 or Time.get_ticks_msec() < suppress_mouse_until:
            return
        var button := event as InputEventMouseButton
        var point := _map_point(button.position)
        if point.x < 0:
            return
        result = player.send_pointer_event(POINTER_DOWN if button.pressed else POINTER_UP,
            0, point.x, point.y, 0.0, 0.0, 0)
        _record({"kind": "os_mouse", "pressed": button.pressed, "result": result})
    elif event is InputEventKey:
        var key := event as InputEventKey
        var code := int(key.keycode)
        if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
            code = 13
        elif key.keycode == KEY_BACKSPACE:
            code = 8
        elif key.keycode == KEY_ESCAPE:
            code = 27
        elif key.keycode == KEY_DELETE:
            code = 46
        elif key.keycode == KEY_LEFT:
            code = 37
        elif key.keycode == KEY_RIGHT:
            code = 39
        result = player.send_key_event(key.pressed, code, 0, key.unicode)
        _record({"kind": "os_key", "pressed": key.pressed, "code": code,
            "unicode": key.unicode, "result": result})
    else:
        return
    get_viewport().set_input_as_handled()
    if result != 0:
        _fail("The real OS input was rejected: %s" % player.get_last_error())

func _map_point(point: Vector2) -> Vector2:
    return GameInputMapping.map_point(point, rect.get_global_rect(), rect.texture.get_size())

func _sync_keyboard() -> void:
    var state: Dictionary = player.get_text_input_state()
    var active := bool(state.get("available", false)) and bool(state.get("ime_active", false))
    var available := DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD)
    if active != keyboard_active:
        keyboard_active = active
        if active and available:
            DisplayServer.virtual_keyboard_show(String(state.get("text", "")), Rect2(0, 0, 1, 1))
        elif available:
            DisplayServer.virtual_keyboard_hide()
        _record({"kind": "soft_keyboard", "active": active, "feature_available": available,
            "source": "native-text-input-state", "state": state})
    # Showing/hiding the Android keyboard is asynchronous. Its actual height,
    # rather than the native request alone, proves OS visibility and dismissal.
    var height := DisplayServer.virtual_keyboard_get_height() if available else 0
    var visible := height > 0
    if visible != keyboard_visible:
        keyboard_visible = visible
        _record({"kind": "soft_keyboard_visibility", "visible": visible, "height": height,
            "source": "os-virtual-keyboard-height"})

func _game_checkpoints() -> Array:
    var rows: Array = []
    var file := FileAccess.open(game_dir.path_join("aether-device-checkpoints.jsonl"), FileAccess.READ)
    if file == null:
        return rows
    while not file.eof_reached():
        var parsed = JSON.parse_string(file.get_line())
        if parsed is Dictionary and String(parsed.get("run_id", "")) == run_id:
            rows.append(parsed)
    return rows

func _has_game_checkpoint(stage: String) -> bool:
    for row in _game_checkpoints():
        if String(row.get("stage", "")) == stage:
            return true
    return false

func _observe_game_checkpoints() -> void:
    var rows := _game_checkpoints()
    while checkpoint_count < rows.size():
        var row: Dictionary = rows[checkpoint_count]
        checkpoint_count += 1
        _record({"kind": "checkpoint_seen", "checkpoint": row})
        if String(row.get("stage", "")) in ["start_ready", "post_text_ready", "quit_ready"]:
            _capture_provider(String(row.get("stage", "")))

func _capture_provider(stage: String) -> void:
    # Let the interaction settle, then wait for keyboard animation and a fresh
    # native redraw after resume. Old pre-pause pixels cannot prove recovery.
    var expires := mini(deadline, Time.get_ticks_msec() + 15000)
    while Time.get_ticks_msec() < expires:
        if finished or player == null:
            return
        var keyboard_height := DisplayServer.virtual_keyboard_get_height()
        var fresh := stage != "resumed_ready" or int(_provider_debug().get("frame_serial", 0)) > paused_frame_serial
        if not paused and not keyboard_active and keyboard_height <= 0 and fresh:
            break
        await get_tree().process_frame
    if Time.get_ticks_msec() >= expires:
        _fail("Native presentation did not settle for %s after keyboard/lifecycle change." % stage)
        return
    for _frame in range(3):
        await get_tree().process_frame
    # This is the real renderer's completed draw, not a fabricated screenshot.
    await RenderingServer.frame_post_draw
    if finished or player == null:
        return
    var frame: Dictionary = player.read_frame_rgba()
    var width := int(frame.get("width", 0))
    var height := int(frame.get("height", 0))
    var stride := int(frame.get("stride_bytes", 0))
    var rgba: PackedByteArray = frame.get("rgba", PackedByteArray())
    if width <= 0 or height <= 0 or stride < width * 4 or rgba.size() < stride * height:
        _fail("Native provider did not supply a complete real RGBA frame.")
        return
    var packed_rgba := rgba
    if stride != width * 4:
        packed_rgba = PackedByteArray()
        for y in range(height):
            packed_rgba.append_array(rgba.slice(y * stride, y * stride + width * 4))
    var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, packed_rgba)
    var path := evidence_dir.path_join("provider-%s.png" % stage)
    if image.save_png(path) != OK:
        _fail("Could not save native provider image.")
        return
    var box := rect.get_global_rect()
    var scale := minf(box.size.x / width, box.size.y / height)
    var drawn_size := Vector2(width, height) * scale
    var origin := box.position + (box.size - drawn_size) * 0.5
    var viewport_size := get_viewport().get_visible_rect().size
    _record({"kind": "provider_frame", "stage": stage, "source": "native-provider-rgba",
        "path": path, "width": width, "height": height, "rgba_bytes": rgba.size(),
        "native_stride_bytes": stride, "frame_serial": int(frame.get("frame_serial", 0)),
        "drawn_box": [origin.x, origin.y, drawn_size.x, drawn_size.y],
        "viewport_size": [viewport_size.x, viewport_size.y], "provider_debug": _provider_debug()})

func _provider_debug() -> Dictionary:
    var raw := String(player.get_plugin_debug_info())
    var parsed = JSON.parse_string(raw)
    return parsed if parsed is Dictionary else {"unparsed": raw}

func _record(row: Dictionary) -> void:
    row["run_id"] = run_id
    row["host_ticks_msec"] = Time.get_ticks_msec()
    print("renpy_device_observer %s" % JSON.stringify(row))
    if evidence_dir.is_empty():
        return
    var path := evidence_dir.path_join("observer.jsonl")
    var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
    if file != null:
        file.seek_end()
        file.store_line(JSON.stringify(row))
        file.flush()

func _finish(native_state: Dictionary) -> void:
    finished = true
    rect.texture = null
    player.release_frame_texture()
    player.destroy_engine()
    _record({"kind": "normal_exit", "provider_debug": native_state,
        "engine_destroyed": not player.is_initialized()})
    get_tree().quit(0)

func _fail(message: String) -> void:
    if finished:
        return
    finished = true
    _record({"kind": "failure", "message": message})
    printerr("renpy_device_acceptance failed: %s" % message)
    if player != null:
        if rect != null:
            rect.texture = null
        player.release_frame_texture()
        player.destroy_engine()
    get_tree().quit(1)
