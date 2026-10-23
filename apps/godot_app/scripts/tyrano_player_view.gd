extends Control

signal closed
signal game_ready

const Metadata = preload("res://scripts/game_metadata.gd")
const TyranoAsar = preload("res://scripts/tyrano_asar.gd")
var host
var native
var header: PanelContainer
var title: Label
var entry: Dictionary
var controls_visible := false
var keys_button: Button
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
    header = PanelContainer.new()
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.025, 0.025, 0.03)
    style.content_margin_left = 12
    style.content_margin_right = 12
    style.content_margin_top = 4
    style.content_margin_bottom = 4
    header.add_theme_stylebox_override("panel", style)
    add_child(header)
    var toolbar := HBoxContainer.new()
    toolbar.add_theme_constant_override("separation", 12)
    header.add_child(toolbar)
    var back := _button(toolbar, "‹", host._t("flash.back"))
    back.pressed.connect(close)
    title = Label.new()
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    title.add_theme_color_override("font_color", Color.WHITE)
    toolbar.add_child(title)
    keys_button = _button(toolbar, "⌨", host._t("settings.virtual_control_menu"))
    keys_button.toggle_mode = true
    keys_button.button_pressed = controls_visible
    keys_button.toggled.connect(set_virtual_controls)
    var refresh := _button(toolbar, "↻", host._t("flash.refresh"))
    refresh.pressed.connect(_restart)
    resized.connect(_layout)
    _layout()

func set_virtual_controls(value: bool) -> void:
    controls_visible = value
    keys_button.set_pressed_no_signal(value)
    if native != null:
        native.set_virtual_controls(value)

func _button(toolbar: HBoxContainer, text: String, tooltip: String) -> Button:
    var button := Button.new()
    button.text = text
    button.tooltip_text = tooltip
    button.accessibility_name = tooltip
    button.custom_minimum_size = Vector2(44, 44)
    host.ui_widgets.toolbar_button(button)
    button.add_theme_color_override("font_color", Color.WHITE)
    toolbar.add_child(button)
    return button

func _layout() -> void:
    if header == null:
        return
    var safe: Rect2 = host._ui_safe_rect(size)
    header.position = safe.position
    header.size = Vector2(safe.size.x, 56)
    if native != null:
        var rect := Rect2(global_position + safe.position + Vector2(0, 56), Vector2(safe.size.x, maxf(0, safe.size.y - 56)))
        native.set_rect(rect, get_viewport_rect().size)

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
    title.text = String(entry.get("name", "TyranoScript")) + " · " + host._t("tyrano.loading")
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
            native.set_virtual_controls(controls_visible)
            native.set_paused(lifecycle_paused)
            if ready_received:
                return
            ready_received = true
            title.text = String(entry.get("name", "TyranoScript"))
            game_ready.emit()
        "error":
            var message: String = host._t("tyrano.open_failed", [String(event.get("value", ""))])
            close()
            host._show_message(message)
        "close":
            close()
        "log":
            host._append_log("TyranoScript: " + String(event.get("value", "")))

func _restart() -> void:
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
        native.set_paused(true)
    elif what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN]:
        lifecycle_paused = false
        native.set_paused(false)
    elif what == NOTIFICATION_PREDELETE:
        native.close()
