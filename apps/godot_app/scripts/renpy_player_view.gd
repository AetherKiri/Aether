extends Control

signal closed
signal game_ready

const Metadata = preload("res://scripts/game_metadata.gd")
var host
var process_id := 0
var session_directory := ""
var state: Dictionary = {}
var ready_received := false
var controls_visible := false
var controls_sequence := 0
var closing := false
var elapsed := 0.0
var close_elapsed := 0.0
var poll_elapsed := 0.0
var sequence := 0
var commands: Array[Dictionary] = []
var status_label: Label
var keys_button: Button
var error_reported := false

func setup(app) -> void:
    host = app
    name = "RenpyPlayerView"
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var background := ColorRect.new()
    background.color = Color(0.025, 0.025, 0.03)
    background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(background)
    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(center)
    var content := VBoxContainer.new()
    content.add_theme_constant_override("separation", 20)
    center.add_child(content)
    status_label = Label.new()
    status_label.text = host._t("renpy.loading")
    status_label.add_theme_color_override("font_color", Color.WHITE)
    status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    content.add_child(status_label)
    var hint := Label.new()
    hint.text = host._t("renpy.window_hint")
    hint.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
    hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hint.custom_minimum_size.x = minf(520, get_viewport_rect().size.x - 48)
    content.add_child(hint)
    keys_button = Button.new()
    keys_button.text = host._t("renpy.keys")
    keys_button.toggle_mode = true
    keys_button.button_pressed = false
    keys_button.toggled.connect(set_virtual_controls)
    content.add_child(keys_button)
    var back := Button.new()
    back.text = host._t("flash.back")
    back.pressed.connect(close)
    content.add_child(back)

static func storage_path(root: String) -> String:
    var identity := root.simplify_path()
    var user_root := ProjectSettings.globalize_path("user://").trim_suffix("/")
    if identity.begins_with(user_root + "/"):
        identity = "user://" + identity.substr(user_root.length() + 1)
    return ProjectSettings.globalize_path("user://renpy_saves").path_join(identity.sha256_text())

static func runtime_root() -> String:
    var configured := OS.get_environment("AETHER_RENPY_SDK").strip_edges()
    if not configured.is_empty():
        return configured.simplify_path()
    var executable_root := OS.get_executable_path().get_base_dir()
    for candidate in [executable_root.path_join("../Resources/renpy-runtime"), executable_root.path_join("renpy-runtime"), ProjectSettings.globalize_path("user://RenPy/runtime")]:
        if FileAccess.file_exists(candidate.path_join("renpy.py")):
            return candidate.simplify_path()
    return ""

func open_entry(entry: Dictionary) -> String:
    if OS.get_name() not in ["macOS", "Linux"]:
        return host._t("renpy.unavailable")
    var root := ProjectSettings.globalize_path(host._game_runtime_root(String(entry.get("path", ""))))
    var relative := Metadata.renpy_game_directory(root)
    if relative.is_empty():
        return host._t("renpy.invalid_project")
    var sdk := runtime_root()
    var platform := "mac-universal" if OS.get_name() == "macOS" else "linux-aarch64" if OS.has_feature("arm64") else "linux-x86_64"
    var python := sdk.path_join("lib/py3-" + platform + "/python")
    if sdk.is_empty() or not FileAccess.file_exists(sdk.path_join("renpy.py")) or not FileAccess.file_exists(python):
        return host._t("renpy.runtime_missing")
    session_directory = ProjectSettings.globalize_path("user://renpy_sessions").path_join("%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
    if DirAccess.make_dir_recursive_absolute(session_directory) != OK:
        return host._t("renpy.session_failed")
    for file_name in ["host.py", "overlay.rpy"]:
        var source := FileAccess.get_file_as_bytes("res://renpy_runtime/" + file_name)
        var file := FileAccess.open(session_directory.path_join(file_name), FileAccess.WRITE)
        if source.is_empty() or file == null:
            return host._t("renpy.session_failed")
        file.store_buffer(source)
        file.close()
    if host.runtime_default_font_path.is_empty():
        host._stage_runtime_fonts()
    if host.runtime_default_font_path.is_empty():
        return host._t("renpy.session_failed")
    var manifest := {"sdk": sdk, "game": root.path_join(relative), "saves": storage_path(root), "ui_font": host.runtime_default_font_path, "parent_pid": OS.get_process_id(), "debug": OS.is_debug_build(), "labels": {"menu": host._t("renpy.menu"), "keys": host._t("renpy.keys"), "back": host._t("flash.back")}}
    var manifest_path := session_directory.path_join("manifest.json")
    var file := FileAccess.open(manifest_path, FileAccess.WRITE)
    if file == null:
        return host._t("renpy.session_failed")
    file.store_string(JSON.stringify(manifest))
    file.close()
    process_id = OS.create_process(python, [session_directory.path_join("host.py"), "--manifest", manifest_path])
    if process_id <= 0:
        return host._t("renpy.session_failed")
    return ""

func send_command(action: String, values: Dictionary = {}) -> int:
    sequence += 1
    var command := values.duplicate(true)
    command.action = action
    command.seq = sequence
    commands.append(command)
    return sequence

func set_virtual_controls(value: bool) -> void:
    controls_visible = value
    controls_sequence = send_command("controls", {"visible": value})

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
    if process_id <= 0:
        return
    elapsed += delta
    poll_elapsed += delta
    if closing:
        close_elapsed += delta
    if poll_elapsed < 0.1:
        return
    poll_elapsed = 0.0
    var path := session_directory.path_join("state.json")
    if FileAccess.file_exists(path):
        var value = JSON.parse_string(FileAccess.get_file_as_string(path))
        if value is Dictionary:
            state = value
    if String(state.get("phase", "")) == "error":
        _fail(String(state.get("error", "Ren'Py error")))
    if int(state.get("ack", 0)) >= controls_sequence:
        controls_visible = bool(state.get("controls", false))
        keys_button.set_pressed_no_signal(controls_visible)
    if not closing and not ready_received and String(state.get("phase", "")) == "ready":
        ready_received = true
        status_label.text = "Ren'Py " + String(state.get("version", ""))
        game_ready.emit()
    _flush_command()
    if not OS.is_process_running(process_id):
        if not ready_received and not closing:
            _fail(host._t("renpy.session_failed"))
        _finish()
    elif closing and close_elapsed > 5.0:
        OS.kill(process_id)
        _finish()
    elif not ready_received and elapsed > 60.0:
        _fail(host._t("renpy.startup_timeout"))

func _fail(message: String) -> void:
    if not error_reported:
        error_reported = true
        host._show_message(host._t("renpy.failed", [message, session_directory.path_join("runtime.log")]))
    close()

func close() -> void:
    if closing:
        return
    closing = true
    commands.clear()
    send_command("quit")
    if process_id <= 0:
        _finish()
    else:
        _flush_command()

func _finish() -> void:
    process_id = 0
    hide()
    closed.emit()
    queue_free()

func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE and process_id > 0:
        commands.clear()
        send_command("quit")
        _flush_command()
