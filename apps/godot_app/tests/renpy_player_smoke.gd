extends SceneTree

class RenpyApp:
    extends "res://scripts/main.gd"
    var marked: Array[String] = []
    var play_seconds := 0
    var messages: Array[String] = []
    func _ready() -> void:
        ui_motion.reduced_motion = true
        add_child(ui_motion)
        _apply_ui_font()
        _build_ui()
    func _process(_delta: float) -> void:
        pass
    func _refresh_games() -> void:
        pass
    func _mark_game_played(path: String) -> Dictionary:
        marked.append(path)
        return {}
    func _add_play_duration(_path: String, seconds: int) -> void:
        play_seconds += seconds
    func _show_message(text: String) -> void:
        messages.append(text)

var app: RenpyApp
var failures := 0
var original: String

func _initialize() -> void:
    call_deferred("_run")

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _wait(condition: Callable, message: String) -> bool:
    for _attempt in range(400):
        if condition.call():
            return true
        if not app.messages.is_empty():
            break
        await create_timer(0.05).timeout
    _expect(false, message + ": " + str(app.messages) + "; state=" + str(app.renpy_view.state if app._is_renpy_active() else {}))
    return false

func _variables() -> Dictionary:
    return app.renpy_view.state.get("variables", {}) if app._is_renpy_active() else {}

func _dialogue() -> String:
    return String(app.renpy_view.state.get("dialogue", "")) if app._is_renpy_active() else ""

func _command(action: String, values: Dictionary = {}) -> void:
    var sequence: int = app.renpy_view.send_command(action, values)
    await _wait(func(): return app._is_renpy_active() and int(app.renpy_view.state.get("ack", 0)) >= sequence, "The SDK acknowledges " + action)
    _expect(String(app.renpy_view.state.get("command_error", "")).is_empty(), "Native command succeeds")

func _key(name: String) -> void:
    await _command("key_tap", {"key": name})

func _launch() -> bool:
    app.selected_game = app._game_info_from_path(original)
    _expect(app.selected_game.engine == "renpy", "The imported game is classified as Ren'Py")
    app._start_selected_game_after_iap()
    _expect(app._is_renpy_active() and not app.shell_root.visible and not app.game_running,
        "Normal library launch opens the native host without entering the KiriKiri dispatcher")
    if not await _wait(func(): return app._is_renpy_active() and app.renpy_view.ready_received, "The SDK opens a real GPU window"):
        return false
    _expect(not app.renpy_view.controls_visible and not bool(app.renpy_view.state.get("controls", true)), "Virtual keys start disabled")
    _expect(String(app.renpy_view.state.get("renderer", {}).get("renderer", "")) in ["gl2", "angle2"], "Ren'Py owns its native model renderer")
    await _command("inspect", {"names": ["aether_probe_step", "aether_probe_route"]})
    return await _wait(func(): return app._is_renpy_active() and bool(app.renpy_view.state.get("main_menu", false)), "The original main menu renders")

func _run() -> void:
    original = OS.get_environment("AETHER_RENPY_TEST_GAME")
    if original.is_empty() or OS.get_environment("AETHER_RENPY_SDK").is_empty():
        push_error("Prepared AETHER_RENPY_TEST_GAME and AETHER_RENPY_SDK are required")
        quit(2)
        return
    root.size = Vector2i(1280, 720)
    root.gui_embed_subwindows = true
    app = RenpyApp.new()
    root.add_child(app)
    if not await _launch():
        app.queue_free()
        quit(1)
        return
    _expect(app.marked == [original], "Last-played changes after the native window is ready")
    var session: String = app.renpy_view.session_directory
    var first_process: int = app.renpy_view.process_id
    await _key("enter")
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 1 and _dialogue().contains("第一句"), "The Chinese scenario starts through native SDL input")
    app.renpy_view.set_virtual_controls(true)
    await _wait(func(): return bool(app.renpy_view.state.get("controls", false)), "Optional in-game virtual keys appear")
    await _key("enter")
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 2, "Virtual Enter reaches the Chinese choices")
    await _key("enter")
    await _wait(func(): return _variables().get("aether_probe_route", "") == "A" and _dialogue().contains("已选择 A"), "The actual choice executes its route")
    app.renpy_view.set_virtual_controls(false)
    await _wait(func(): return not bool(app.renpy_view.state.get("controls", true)), "Virtual keys can be hidden again")
    await _command("screenshot")
    _expect(FileAccess.file_exists(session.path_join("screenshot.png")), "The native renderer produces a real screenshot")
    await _key("f5")
    var saves: String = app.RenpyPlayerView.storage_path(original)
    await _wait(func():
        var directory := DirAccess.open(saves)
        if directory == null:
            return false
        for file in directory.get_files():
            if file.ends_with(".save"):
                return true
        return false,
        "The game saves into Aether's per-game directory")
    await _key("enter")
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 4, "The scenario advances beyond the saved scene")
    await _key("f9")
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 3 and _dialogue().contains("已选择 A"), "Loading restores the route and the rendered Chinese scene")
    app._handle_go_back_request()
    await _wait(func(): return not app._is_renpy_active(), "Back gracefully exits the SDK process")
    _expect(not OS.is_process_running(first_process) and app.shell_root.visible, "Returning reaps the child and restores the library")
    _expect(app.play_seconds > 0 and app.active_game_started_msec == 0, "Returning finalizes play time")
    if not await _launch():
        app.queue_free()
        quit(1)
        return
    _expect(app.renpy_view.process_id != first_process, "Reopening creates a fresh Python VM")
    await _key("enter")
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 1, "The fresh VM starts the scenario")
    await _key("f9")
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 3 and _dialogue().contains("已选择 A"), "The save survives complete VM recreation")
    _expect(app.marked.size() == 2, "Each successful launch creates one play session")
    app.renpy_view.send_command("quit")
    await _wait(func(): return not app._is_renpy_active(), "Quitting inside Ren'Py also returns to the library")
    _expect(app.messages.is_empty(), "No runtime error was reported: " + str(app.messages))
    var result := {"passed": failures == 0, "screenshot": session.path_join("screenshot.png"), "saves": saves}
    var report := OS.get_environment("AETHER_RENPY_TEST_RESULT")
    if not report.is_empty():
        var file := FileAccess.open(report, FileAccess.WRITE)
        file.store_string(JSON.stringify(result, "  "))
    app.queue_free()
    await process_frame
    print("RENPY_PLAYER_SMOKE_OK" if failures == 0 else "RENPY_PLAYER_SMOKE_FAILED")
    quit(0 if failures == 0 else 1)
