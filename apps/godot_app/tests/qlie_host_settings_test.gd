extends SceneTree

class RecordingPlayer extends Node:
    var replies: Array[Array] = []

    func submit_platform_response(operation: String, argument: String) -> void:
        replies.append([operation, argument])

class Host extends "res://scripts/main.gd":
    func _ready() -> void:
        pass

    func _process(_delta: float) -> void:
        pass

    func _layout_game_viewport(_size: Vector2) -> void:
        pass

    func _create_file_dialog(title: String, file_mode: int, filters: PackedStringArray = PackedStringArray()) -> FileDialog:
        var dialog := super._create_file_dialog(title, file_mode, filters)
        # Use the Godot dialog so the test can drive its signals without a desktop portal.
        dialog.use_native_dialog = false
        return dialog

const FONT_REQUEST := "qlie_font_chooser"
const FONT_PATH := "res://assets/fonts/Figtree-Regular.ttf"
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _run() -> void:
    var host := Host.new()
    root.add_child(host)
    host.add_child(host.ui_motion)
    var player := RecordingPlayer.new()
    host.add_child(player)
    host.player = player
    host.game_render_root = ProjectSettings.globalize_path("res://assets/fonts")

    host._on_runtime_platform_request(FONT_REQUEST, "")
    if DisplayServer.get_name() == "headless":
        _expect(player.replies == [[FONT_REQUEST, ""]], "Headless host cancels the request immediately")
        _expect(not host.qlie_font_request_pending, "Headless cancellation clears the request")
    else:
        var original_mode := root.mode
        host._on_runtime_platform_request("runtime_window_mode", "fullscreen")
        _expect(root.mode == Window.MODE_FULLSCREEN, "Authored fullscreen changes the Godot window mode")
        host._on_runtime_platform_request("runtime_window_mode", "windowed")
        _expect(root.mode == Window.MODE_WINDOWED, "Authored windowed mode leaves fullscreen")
        host.runtime_display_state.reset(root)
        _expect(root.mode == original_mode, "Runtime cleanup restores the original shell mode")

        var dialog: FileDialog = host.qlie_font_dialog
        if dialog == null:
            _expect(false, "Font request opens a file picker")
        else:
            _expect(dialog.visible and dialog.current_dir == host.game_render_root, "Picker opens in the game directory")
            host._on_runtime_platform_request(FONT_REQUEST, "")
            _expect(host.qlie_font_dialog == dialog, "Duplicate request cannot open a second picker")
            dialog.file_selected.emit(FONT_PATH)
            dialog.canceled.emit()
            _expect(player.replies == [[FONT_REQUEST, ProjectSettings.globalize_path(FONT_PATH)]], "Selection returns a readable absolute path exactly once")
            await process_frame

            host._on_runtime_platform_request(FONT_REQUEST, "")
            host.qlie_font_dialog.canceled.emit()
            _expect(player.replies.back() == [FONT_REQUEST, ""], "Dismissal cancels the request")
            await process_frame

            host._on_runtime_platform_request(FONT_REQUEST, "")
            host.qlie_font_dialog.file_selected.emit("res://project.godot")
            _expect(player.replies.back() == [FONT_REQUEST, ""], "Unusable font selection cancels the request")
            await process_frame

            host._on_runtime_platform_request(FONT_REQUEST, "")
            dialog = host.qlie_font_dialog
            host._cleanup_runtime_platform_ui()
            dialog.file_selected.emit(FONT_PATH)
            _expect(player.replies.size() == 3, "Closing a session discards its late picker response")

    host.free()
    if failures == 0:
        print("QLIE_HOST_SETTINGS_OK")
    quit(0 if failures == 0 else 1)
