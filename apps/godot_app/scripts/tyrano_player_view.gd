extends Control

signal closed
signal game_ready

const NativeControls = preload("res://scripts/native_game_controls.gd")
const Metadata = preload("res://scripts/game_metadata.gd")
const TyranoAsar = preload("res://scripts/tyrano_asar.gd")
var host
var native
var controls_viewport
var controls
var entry: Dictionary
var controls_visible := false
var ready_received := false
var startup_elapsed := 0.0
var closing := false
var lifecycle_paused := false
var preparation: Thread
var archive: RefCounted

func setup(app) -> void:
    host = app
    name = "TyranoPlayerView"
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var background := ColorRect.new()
    background.color = Color.BLACK
    background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(background)
    controls_viewport = NativeControls.new()
    add_child(controls_viewport)
    controls_viewport.setup(host)
    controls = controls_viewport.controls
    controls_viewport.frame_ready.connect(_present_controls)
    controls.key_event_requested.connect(_virtual_key)
    controls.pointer_move_requested.connect(func(point: Vector2, _delta: Vector2):
        _virtual_pointer("move", point))
    controls.pointer_button_requested.connect(func(pressed: bool, button: int, _modifiers: int, point: Vector2):
        _virtual_pointer("button", point, {"pressed": pressed, "button": MOUSE_BUTTON_LEFT if button == 0 else MOUSE_BUTTON_RIGHT}))
    controls.pointer_scroll_requested.connect(func(delta: float, point: Vector2):
        _virtual_pointer("scroll", point, {"delta": delta}))
    controls.keyboard_requested.connect(func():
        if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
            DisplayServer.virtual_keyboard_show("")
        elif DisplayServer.has_feature(DisplayServer.FEATURE_IME):
            DisplayServer.window_set_ime_active(true))
    resized.connect(_layout)
    _layout()

func set_virtual_controls(value: bool) -> void:
    controls_visible = value
    controls_viewport.set_virtual_controls(value)

func _present_controls(frame: Dictionary) -> void:
    controls_visible = controls.is_panel_open()
    if native != null and ready_received and frame.has("image"):
        native.set_controls_frame(frame)

func _controls_ready() -> void:
    controls_viewport.set_enabled(not lifecycle_paused)

func _virtual_key(pressed: bool, code: int, modifiers: int) -> void:
    _send_engine_input({"type": "key", "code": code, "pressed": pressed, "modifiers": modifiers})

func _virtual_pointer(kind: String, point: Vector2, values: Dictionary = {}) -> void:
    var normalized: Vector2 = point / controls_viewport.view_size
    var value := {"type": kind, "x": normalized.x, "y": normalized.y}
    value.merge(values)
    _send_engine_input(value)

func _send_engine_input(value: Dictionary) -> void:
    if native != null and ready_received and not closing and not lifecycle_paused:
        native.send_input(value)

func _input(event: InputEvent) -> void:
    if native == null or not ready_received or closing or lifecycle_paused:
        return
    var pointer := event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag
    if pointer:
        var local := event.duplicate() as InputEvent
        local.position -= _content_rect().position
        if controls_viewport.route_input(local):
            get_viewport().set_input_as_handled()
            return
    _game_input(event)

func _game_input(event: InputEvent) -> void:
    if event is InputEventKey:
        _virtual_key(event.pressed, host._kirikiri_virtual_key(event), 4 if event.ctrl_pressed else 0)
    elif event is InputEventMouseMotion:
        _virtual_pointer("move", event.position - _content_rect().position)
    elif event is InputEventMouseButton:
        if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
            if event.pressed:
                _virtual_pointer("scroll", event.position - _content_rect().position,
                    {"delta": 1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1})
        else:
            _virtual_pointer("button", event.position - _content_rect().position,
                {"button": event.button_index, "pressed": event.pressed})

func _content_rect() -> Rect2:
    var safe: Rect2 = host._ui_safe_rect(size)
    return Rect2(global_position + safe.position, safe.size)

func _layout() -> void:
    if controls_viewport != null:
        controls_viewport.layout(_content_rect(), get_viewport_rect().size)
    if native != null:
        native.set_rect(_content_rect(), get_viewport_rect().size)

static func storage_path(root: String) -> String:
    var identity := root.simplify_path()
    var user_root := ProjectSettings.globalize_path("user://").trim_suffix("/")
    if identity.begins_with(user_root + "/"):
        identity = "user://" + identity.substr(user_root.length() + 1)
    return ProjectSettings.globalize_path("user://tyrano_saves").path_join(identity.sha256_text()).path_join("local_storage.json")

func open_entry(value: Dictionary) -> String:
    entry = value.duplicate(true)
    var root := ProjectSettings.globalize_path(host._game_runtime_root(String(entry.get("path", ""))))
    var launch := Metadata.tyrano_entry_file(root)
    if launch.is_empty():
        return host._t("tyrano.invalid_project")
    if not ClassDB.class_exists("AetherTyranoPlayer"):
        return host._t("tyrano.unavailable")
    native = ClassDB.instantiate("AetherTyranoPlayer")
    add_child(native)
    if not native.is_supported():
        return host._t("tyrano.unavailable")
    native.event_received.connect(_event)
    ready_received = false
    startup_elapsed = 0.0
    if launch.ends_with(".asar"):
        archive = TyranoAsar.new()
        if not archive.open(root.path_join(launch)):
            return host._t("tyrano.open_failed", [archive.error])
        preparation = Thread.new()
        var cache := ProjectSettings.globalize_path("user://tyrano_cache")
        if preparation.start(archive.prepare.bind(cache)) != OK:
            preparation = null
            archive = null
            return host._t("tyrano.open_failed", ["Cannot start ASAR preparation"])
        return ""
    return _open_html(root.path_join(launch))

func _open_html(path: String) -> String:
    var root := ProjectSettings.globalize_path(host._game_runtime_root(String(entry.get("path", ""))))
    if not native.open(path, storage_path(root)):
        return host._t("tyrano.open_failed", [native.get_error()])
    _layout()
    return ""

func _stop_preparation() -> void:
    if preparation != null:
        archive.cancel()
        preparation.wait_to_finish()
        preparation = null
        archive = null

func _event(event: Dictionary) -> void:
    match String(event.get("type", "")):
        "ready":
            native.set_paused(lifecycle_paused)
            if ready_received:
                return
            ready_received = true
            _controls_ready()
            game_ready.emit()
        "controls_input":
            var value = JSON.parse_string(String(event.get("value", "")))
            if value is Dictionary:
                controls_viewport.pointer_input(value)
                controls_visible = controls.is_panel_open()
        "error":
            var message: String = host._t("tyrano.open_failed", [String(event.get("value", ""))])
            close()
            host._show_message(message)
        "close":
            close()
        "log":
            host._append_log("TyranoScript: " + String(event.get("value", "")))

func _restart() -> void:
    controls_visible = false
    controls_viewport.set_enabled(false)
    _stop_preparation()
    if native != null:
        native.close()
        native.queue_free()
        native = null
    var message := open_entry(entry)
    if not message.is_empty():
        close()
        host._show_message(message)

func close() -> void:
    if closing:
        return
    closing = true
    controls_viewport.set_enabled(false)
    _stop_preparation()
    if native != null:
        native.close()
        native.queue_free()
        native = null
    hide()
    closed.emit()
    queue_free()

func _process(delta: float) -> void:
    _layout()
    if preparation != null:
        if preparation.is_alive():
            return
        var result: Dictionary = preparation.wait_to_finish()
        preparation = null
        archive = null
        var message: String = host._t("tyrano.open_failed", [result.error]) if result.has("error") else _open_html(result.entry)
        if not message.is_empty():
            close()
            host._show_message(message)
        return
    if native != null and not ready_received:
        startup_elapsed += delta
        if startup_elapsed > 30.0:
            close()
            host._show_message(host._t("tyrano.startup_timeout"))

func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE:
        _stop_preparation()
    if not is_instance_valid(native):
        return
    if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
        lifecycle_paused = true
        controls_viewport.set_enabled(false)
        native.set_paused(true)
    elif what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN]:
        lifecycle_paused = false
        native.set_paused(false)
        if ready_received:
            _controls_ready()
    elif what == NOTIFICATION_PREDELETE:
        native.close()
