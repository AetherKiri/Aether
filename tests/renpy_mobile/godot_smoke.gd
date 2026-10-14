extends Control

# Runs the production player, including its toolbar, input and refresh path.
const Player = preload("res://scripts/renpy_player_view.gd")
class Widgets:
    func toolbar_button(_button: Button) -> void:
        pass
var ui_widgets := Widgets.new()
var runtime_default_font_path := ""
var view
var failure := ""
var original := ""

func _ui_safe_rect(value: Vector2) -> Rect2:
    return Rect2(Vector2.ZERO, value)
func _game_runtime_root(value: String) -> String:
    return value
func _t(key: String, values: Array = []) -> String:
    return key + (": " + str(values) if not values.is_empty() else "")
func _stage_runtime_fonts() -> void:
    runtime_default_font_path = original.path_join("game/probe.ttf")
func _show_message(message: String) -> void:
    failure = message
    push_error(message)

func _copy(source: String, destination: String) -> void:
    DirAccess.make_dir_recursive_absolute(destination)
    var directory := DirAccess.open(source)
    for file in directory.get_files():
        var target := FileAccess.open(destination.path_join(file), FileAccess.WRITE)
        target.store_buffer(FileAccess.get_file_as_bytes(source.path_join(file)))
    for folder in directory.get_directories():
        _copy(source.path_join(folder), destination.path_join(folder))

func _wait(condition: Callable, message: String) -> void:
    for _attempt in range(1200):
        if condition.call():
            return
        if not failure.is_empty():
            break
        await get_tree().create_timer(0.05).timeout
    if failure.is_empty():
        failure = message + "; " + str(view.state if is_instance_valid(view) else {})
    _report(false)

func _report(passed: bool) -> void:
    passed = passed and failure.is_empty()
    var file := FileAccess.open("user://renpy-native-result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"passed":passed, "platform":OS.get_name(), "error":failure}))
    file.close()
    print("RENPY_NATIVE_GODOT_OK" if passed else "RENPY_NATIVE_GODOT_FAILED: " + failure)
    get_tree().quit(0 if passed else 1)

func _command(action: String, values: Dictionary = {}) -> void:
    var sequence: int = view.send_command(action, values)
    await _wait(func(): return int(view.state.get("ack", 0)) >= sequence, "Command not acknowledged: " + action)
    if not String(view.state.get("command_error", "")).is_empty():
        failure = str(view.state.command_error)
        _report(false)

func _key(key: String) -> void:
    await _command("key_tap", {"key":key})
func _step() -> int:
    return int(view.state.get("variables", {}).get("aether_probe_step", 0))
func _has_save() -> bool:
    for file in DirAccess.get_files_at(Player.storage_path(original)):
        if file.ends_with(".save"):
            return true
    return false

func _launch() -> void:
    view = Player.new()
    add_child(view)
    view.setup(self)
    var message: String = view.open_entry({"path":original, "name":"Ren'Py native smoke"})
    if not message.is_empty():
        failure = message
        _report(false)
        return
    await _wait(func(): return view.ready_received and bool(view.state.get("main_menu", false)), "Native main menu did not start")
    if not view.native.is_embedded() or int(view.state.get("pid", 0)) != OS.get_process_id() or view.controls_visible:
        failure = "The renderer must share Aether's window/process and start without virtual keys"
        _report(false)
    print("RENPY_NATIVE_READY: ", view.state)
    await _command("inspect", {"names":["aether_probe_step", "aether_probe_route"]})

func _ready() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    original = ProjectSettings.globalize_path("user://fixture")
    _copy("res://fixture", original)
    await _launch()
    await _key("enter")
    await _wait(func(): return _step() == 1 and String(view.state.get("dialogue", "")).contains("第一句"), "Chinese dialogue missing")
    view.set_virtual_controls(true)
    await _wait(func(): return bool(view.state.get("controls", false)), "Virtual controls failed to appear")
    await _key("enter")
    await _wait(func(): return _step() == 2, "Chinese choices missing")
    await _key("enter")
    await _wait(func(): return _step() == 3 and String(view.state.get("dialogue", "")).contains("已选择 A"), "Choice did not execute")
    view.set_virtual_controls(false)
    await _command("screenshot")
    if not FileAccess.file_exists(view.session_directory.path_join("screenshot.png")):
        failure = "Native screenshot missing"
        _report(false)
    await _key("f5")
    await _wait(_has_save, "Native save missing")
    await _key("enter")
    await _wait(func(): return _step() == 4, "Scenario did not advance")
    await _key("f9")
    await _wait(func(): return _step() == 3, "Save failed to load")
    view.native.set_paused(true)
    view.native.set_paused(false)
    var before: String = view.session_directory
    view._restart()
    await _wait(func(): return view.session_directory != before and view.ready_received and bool(view.state.get("main_menu", false)), "Refresh failed")
    await _command("inspect", {"names":["aether_probe_step", "aether_probe_route"]})
    await _key("enter")
    await _wait(func(): return _step() == 1, "Reopened scenario did not start")
    await _key("f9")
    await _wait(func(): return _step() == 3, "Save failed after refresh")
    view.close()
    await _wait(func(): return not is_instance_valid(view), "Return to library failed")
    await _launch()
    view.close()
    await _wait(func(): return not is_instance_valid(view), "Second close failed")
    _report(true)
