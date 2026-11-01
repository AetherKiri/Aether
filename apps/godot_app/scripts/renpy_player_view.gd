extends "res://scripts/tyrano_player_view.gd"

const SaveStorage := preload("res://scripts/renpy_save_storage.gd")

var session_directory := ""
var state: Dictionary = {}
var sequence := 0
var commands: Array[Dictionary] = []
var poll_elapsed := 0.0
var closing_elapsed := 0.0
var error_reported := false
var active_touch := -1
var restart_requested := false
var ime_active := false
var mouse_buttons: Dictionary = {}
var overlay_event_sequence := 0

func setup(app) -> void:
    super.setup(app)
    name = "RenpyPlayerView"

static func storage_path(root: String) -> String:
    return SaveStorage.storage_path(root)

static func runtime_root() -> String:
    var configured := OS.get_environment("AETHER_RENPY_SDK").strip_edges()
    if not configured.is_empty():
        return configured.simplify_path()
    var executable_root := OS.get_executable_path().get_base_dir()
    for candidate in [executable_root.path_join("../Resources/renpy-runtime"), executable_root.path_join("renpy-runtime"), ProjectSettings.globalize_path("user://RenPy/runtime")]:
        if FileAccess.file_exists(candidate.path_join("renpy.py")):
            return candidate.simplify_path()
    return ""

func _probe_enabled() -> bool:
    return OS.is_debug_build()

func open_entry(value: Dictionary) -> String:
    state = {}
    commands.clear()
    sequence = 0
    poll_elapsed = 0.0
    closing_elapsed = 0.0
    error_reported = false
    ready_received = false
    startup_elapsed = 0.0
    closing = false
    active_touch = -1
    mouse_buttons.clear()
    controls_visible = false
    controls_viewport.set_enabled(false)
    overlay_event_sequence = 0
    entry = value.duplicate(true)
    var root := ProjectSettings.globalize_path(host._game_runtime_root(String(entry.get("path", ""))))
    var relative := Metadata.renpy_game_directory(root)
    if relative.is_empty():
        return host._t("renpy.invalid_project")
    if not ClassDB.class_exists("AetherRenpyNativePlayer"):
        return host._t("renpy.unavailable")
    native = ClassDB.instantiate("AetherRenpyNativePlayer")
    add_child(native)
    if not native.is_supported():
        return host._t("renpy.unavailable")
    native.failed.connect(_fail)
    var sdk := runtime_root()
    if sdk.is_empty():
        sdk = native.prepare_runtime()
    var greenlet := OS.get_environment("AETHER_RENPY_GREENLET").strip_edges()
    if greenlet.is_empty():
        greenlet = sdk.path_join("lib/python3.12/site-packages")
    if sdk.is_empty() or not FileAccess.file_exists(sdk.path_join("renpy.py")) or not FileAccess.file_exists(greenlet.path_join("greenlet/__init__.py")):
        return host._t("renpy.runtime_missing")
    session_directory = ProjectSettings.globalize_path("user://renpy_sessions").path_join("%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
    if DirAccess.make_dir_recursive_absolute(session_directory) != OK:
        return host._t("renpy.session_failed")
    for file_name in ["host.py", "overlay.rpy", "embedded.py"]:
        var file := FileAccess.open(session_directory.path_join(file_name), FileAccess.WRITE)
        if file == null:
            return host._t("renpy.session_failed")
        file.store_buffer(FileAccess.get_file_as_bytes("res://renpy_runtime/" + file_name))
        file.close()
    if host.runtime_default_font_path.is_empty():
        host._stage_runtime_fonts()
    var manifest := {"sdk": sdk, "root": root, "game": root.path_join(relative), "saves": storage_path(root), "ui_font": host.runtime_default_font_path,
        "embedded": true, "forward_input": OS.get_name() in ["macOS", "iOS"], "parent_pid": OS.get_process_id(), "debug": _probe_enabled()}
    var path := session_directory.path_join("manifest.json")
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return host._t("renpy.session_failed")
    file.store_string(JSON.stringify(manifest))
    file.close()
    if not native.open(sdk, path, session_directory.path_join("embedded.py"), greenlet):
        return host._t("renpy.failed", [native.get_error(), session_directory.path_join("runtime.log")])
    _layout()
    return ""

func send_command(action: String, values: Dictionary = {}) -> int:
    sequence += 1
    var command := values.duplicate(true)
    command.action = action
    command.seq = sequence
    commands.append(command)
    return sequence

func _present_controls(frame: Dictionary) -> void:
    controls_visible = controls.is_panel_open()
    if native != null and ready_received and not frame.is_empty():
        var value := frame.duplicate()
        value.type = "controls_frame"
        native.send_input(value)

func _send_engine_input(value: Dictionary) -> void:
    if native == null or not ready_received or closing or lifecycle_paused:
        return
    if value.type == "key":
        var names := {13: "enter", 17: "ctrl", 27: "esc", 32: "space",
            33: "pgup", 34: "pgdn", 37: "left", 38: "up", 39: "right", 40: "down"}
        value.key = names.get(int(value.code), String.chr(int(value.code)).to_lower())
        value.mod = 192 if int(value.get("modifiers", 0)) & 4 else 0
    elif value.type == "scroll":
        value.type = "button"
        value.button = 4 if float(value.delta) > 0 else 5
        value.pressed = true
        native.send_input(value)
        value.pressed = false
    elif value.type == "button":
        value.button = {MOUSE_BUTTON_RIGHT: 3, MOUSE_BUTTON_MIDDLE: 2}.get(int(value.button), int(value.button))
    native.send_input(value)

func _game_input(event: InputEvent) -> void:
    if native == null or not ready_received or closing or lifecycle_paused:
        return
    if not OS.get_name() in ["macOS", "iOS"] and not (OS.get_name() == "Linux" and event is InputEventKey):
        return
    var value: Dictionary = {}
    if event is InputEventKey:
        var key := event as InputEventKey
        value = {"type": "key", "key": OS.get_keycode_string(key.keycode).to_lower(), "pressed": key.pressed,
            "repeat": key.echo, "text": String.chr(key.unicode) if key.unicode > 0 else "",
            "mod": (3 if key.shift_pressed else 0) | (192 if key.ctrl_pressed else 0) | (768 if key.alt_pressed else 0) | (3072 if key.meta_pressed else 0)}
    else:
        var rect := _content_rect()
        var point := Vector2.ZERO
        if event is InputEventMouseMotion:
            if event.device == -1:
                return
            point = event.position
            value = {"type": "move"}
        elif event is InputEventMouseButton:
            if event.device == -1:
                return
            point = event.position
            if event.pressed and rect.has_point(point):
                mouse_buttons[event.button_index] = true
            elif not event.pressed and not mouse_buttons.has(event.button_index):
                return
            value = {"type": "button", "button": {MOUSE_BUTTON_RIGHT: 3, MOUSE_BUTTON_MIDDLE: 2}.get(event.button_index, event.button_index), "pressed": event.pressed}
        elif event is InputEventScreenTouch:
            if event.pressed and active_touch < 0 and rect.has_point(event.position):
                active_touch = event.index
            if event.index != active_touch:
                return
            point = event.position
            value = {"type": "button", "button": 1, "pressed": event.pressed, "touch": true}
            if not event.pressed:
                active_touch = -1
        elif event is InputEventScreenDrag and event.index == active_touch:
            point = event.position
            value = {"type": "move", "touch": true}
        else:
            return
        if not rect.has_point(point) and not (event is InputEventScreenTouch or event is InputEventScreenDrag) and mouse_buttons.is_empty():
            return
        if event is InputEventMouseButton and not event.pressed:
            mouse_buttons.erase(event.button_index)
        value.x = (point.x - rect.position.x) / rect.size.x
        value.y = (point.y - rect.position.y) / rect.size.y
    native.send_input(value)
    get_viewport().set_input_as_handled()

func _flush_command() -> void:
    while not commands.is_empty() and int(commands[0].seq) <= int(state.get("ack", 0)):
        commands.pop_front()
    if commands.is_empty():
        return
    var temporary := session_directory.path_join("command.tmp")
    var file := FileAccess.open(temporary, FileAccess.WRITE)
    if file == null:
        _fail(host._t("renpy.session_failed"))
        return
    file.store_string(JSON.stringify(commands[0]))
    file.close()
    if DirAccess.rename_absolute(temporary, session_directory.path_join("command.json")) != OK:
        _fail(host._t("renpy.session_failed"))

func _process(delta: float) -> void:
    _layout()
    if native == null:
        return
    poll_elapsed += delta
    if closing:
        closing_elapsed += delta
    elif not ready_received:
        startup_elapsed += delta
    if poll_elapsed < 0.02:
        return
    poll_elapsed = 0.0
    var path := session_directory.path_join("state.json")
    if FileAccess.file_exists(path):
        var value = JSON.parse_string(FileAccess.get_file_as_string(path))
        if value is Dictionary:
            state = value
            for event in state.get("controls_events", []):
                if int(event.get("seq", 0)) > overlay_event_sequence:
                    overlay_event_sequence = int(event.seq)
                    controls_viewport.pointer_input(event)
                    controls_visible = controls.is_panel_open()
    if OS.get_name() in ["macOS", "Linux"]:
        var active := state.get("ime") is Array
        if active != ime_active:
            ime_active = active
            DisplayServer.window_set_ime_active(active)
        if active:
            var rect := _content_rect()
            var point := rect.position + rect.size * Vector2(float(state.ime[0]), float(state.ime[1]))
            DisplayServer.window_set_ime_position(Vector2i(point))
    if String(state.get("phase", "")) == "error":
        _fail(String(state.get("error", "Ren'Py error")))
    if not closing and not ready_received and String(state.get("phase", "")) == "ready":
        if not native.is_embedded():
            _fail("The native view could not attach to Aether")
            return
        ready_received = true
        _controls_ready()
        game_ready.emit()
    _flush_command()
    if String(state.get("phase", "")) == "exited":
        restart_requested = restart_requested or bool(state.get("restart", false))
        _finish()
    elif closing and closing_elapsed > 5.0:
        _finish()
    elif not ready_received and startup_elapsed > 60.0:
        _fail(host._t("renpy.startup_timeout"))

func _fail(message: String) -> void:
    if error_reported:
        return
    error_reported = true
    closing = true
    restart_requested = false
    set_process(false)
    call_deferred("_abort_session", message)

func _abort_session(message: String) -> void:
    _finish()
    host._show_message(host._t("renpy.failed", [message, session_directory.path_join("runtime.log")]))

func close() -> void:
    if closing:
        return
    controls_viewport.set_enabled(false)
    closing = true
    closing_elapsed = 0.0
    commands.clear()
    send_command("quit")
    if native == null or not ready_received:
        _finish()
    else:
        native.set_paused(false)
        _flush_command()

func _finish() -> void:
    if ime_active:
        DisplayServer.window_set_ime_active(false)
        ime_active = false
    if restart_requested:
        restart_requested = false
        if native != null:
            native.close()
            native.queue_free()
            native = null
        call_deferred("_reopen")
        return
    closing = false
    super.close()

func _restart() -> void:
    if closing:
        return
    restart_requested = true
    close()

func _reopen() -> void:
    var message := open_entry(entry)
    if not message.is_empty():
        _fail(message)

func _notification(what: int) -> void:
    super._notification(what)
    if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
        active_touch = -1
        mouse_buttons.clear()
    if what == NOTIFICATION_OS_IME_UPDATE and ime_active and native != null:
        var selection := DisplayServer.ime_get_selection()
        native.send_input({"type": "composition", "text": DisplayServer.ime_get_text(), "start": selection.x, "length": selection.y})
