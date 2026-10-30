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

func _start_scenario() -> void:
    if OS.get_environment("AETHER_RENPY_TEST_RESIZE").is_empty():
        await _key("enter")
        return
    # The fixture requests 1280x720, then places Start away from the center.
    # Click its visible position through the production frontend, accounting
    # for the fixture's 16:9 letterbox in Aether's full viewport.
    var content: Vector2 = app.renpy_view.size
    var fitted := Vector2(960, 540) * minf(content.x / 960.0, content.y / 540.0)
    var point: Vector2 = app.renpy_view.global_position + (content - fitted) / 2 + fitted * Vector2(0.75, 0.65)
    await _click_at(point)

func _click_at(point: Vector2) -> void:
    var move := InputEventMouseMotion.new()
    move.position = point
    app.renpy_view._input(move)
    for pressed in [true, false]:
        var button := InputEventMouseButton.new()
        button.position = point
        button.button_index = MOUSE_BUTTON_LEFT
        button.pressed = pressed
        app.renpy_view._input(button)
        await process_frame

func _click_control(control: Control) -> void:
    await _click_at(app.renpy_view._content_rect().position + control.get_global_rect().get_center())

func _open_control_pad() -> void:
    await _click_control(app.renpy_view.controls.menu_button)
    await _wait(func(): return app.renpy_view.controls.is_menu_open(), "The original edge menu opens")
    await _click_control(app.renpy_view.controls.virtual_controls_button)

func _check_shared_button() -> void:
    var view = app.renpy_view
    _expect(view.controls.get_script() == load("res://scripts/game_virtual_controls.gd"), "The native player instantiates the original KiriKiri controls")
    var point: Vector2 = view._content_rect().position + view.controls.menu_button.get_global_rect().get_center()
    var down := InputEventMouseButton.new()
    down.position = point
    down.button_index = MOUSE_BUTTON_LEFT
    down.pressed = true
    view._input(down)
    var drag := InputEventMouseMotion.new()
    drag.position = point + Vector2(0, 120)
    drag.button_mask = MOUSE_BUTTON_MASK_LEFT
    view._input(drag)
    down.position = drag.position
    down.pressed = false
    view._input(down)
    await process_frame
    _expect(view.controls.menu_button.position.y > 100 and not view.controls.is_menu_open(), "Dragging the original button moves it along the right edge without opening the menu")

func _check_title_texture() -> void:
    await _command("screenshot")
    var picture := Image.load_from_file(app.renpy_view.session_directory.path_join("screenshot.png"))
    var colors := [Color("cc3344"), Color("33bb66"), Color("3366cc")]
    for index in range(colors.size()):
        var pixel := picture.get_pixel(int((80 + 80 * index) * picture.get_width() / 960.0), int(80 * picture.get_height() / 540.0))
        _expect(absf(pixel.r - colors[index].r) < 0.03 and absf(pixel.g - colors[index].g) < 0.03 and absf(pixel.b - colors[index].b) < 0.03,
            "Title image textures survive renderer recreation (patch %d: %s)" % [index, str(pixel)])

func _launch() -> bool:
    app.selected_game = app._game_info_from_path(original)
    _expect(app.selected_game.engine == "renpy", "The imported game is classified as Ren'Py")
    app._start_selected_game_after_iap()
    _expect(app._is_renpy_active() and not app.shell_root.visible and not app.game_running,
        "Normal library launch opens the native host without entering the KiriKiri dispatcher")
    if not await _wait(func(): return app._is_renpy_active() and app.renpy_view.ready_received, "The native renderer starts inside Aether"):
        return false
    _expect(not app.renpy_view.controls_visible and not bool(app.renpy_view.state.get("controls", true)), "Virtual keys start disabled")
    _expect(String(app.renpy_view.state.get("renderer", {}).get("renderer", "")) in ["gl2", "angle2"], "Ren'Py owns its native model renderer")
    await _command("inspect", {"names": ["aether_probe_step", "aether_probe_route", "aether_probe_hooks_fresh"]})
    _expect(bool(_variables().get("aether_probe_hooks_fresh", false)), "Every launch imports fresh game modules with the original engine hooks")
    if not await _wait(func(): return app._is_renpy_active() and bool(app.renpy_view.state.get("main_menu", false)), "The original main menu renders"):
        return false
    await _check_title_texture()
    return true

func _run() -> void:
    original = OS.get_environment("AETHER_RENPY_TEST_GAME")
    if original.is_empty() or OS.get_environment("AETHER_RENPY_SDK").is_empty():
        push_error("Prepared AETHER_RENPY_TEST_GAME and AETHER_RENPY_SDK are required")
        quit(2)
        return
    root.size = Vector2i(1280, 720)
    root.content_scale_factor = 1.5
    root.gui_embed_subwindows = true
    app = RenpyApp.new()
    root.add_child(app)
    app.selected_game = app._game_info_from_path(original)
    app._start_selected_game_after_iap()
    app._handle_go_back_request()
    await process_frame
    _expect(not app._is_renpy_active() and app.marked.is_empty(), "Closing before the first Python tick leaves the library and interpreter usable")
    if not await _launch():
        app.queue_free()
        quit(1)
        return
    _expect(app.marked == [original], "Last-played changes after the native renderer is ready")
    var session: String = app.renpy_view.session_directory
    var first_process: int = int(app.renpy_view.state.get("pid", 0))
    _expect(first_process == OS.get_process_id(), "Ren’Py executes in Aether’s process")
    if OS.get_name() == "macOS":
        await _check_shared_button()
        await _command("screenshot")
        var title_image := Image.load_from_file(session.path_join("screenshot.png"))
        await _open_control_pad()
        await _wait(func(): return bool(app.renpy_view.state.get("controls", false)), "The title-screen edge menu toggles virtual keys")
        _expect(bool(app.renpy_view.state.get("main_menu", false)), "The menu click does not start the game")
        await _command("screenshot")
        var controls_image := Image.load_from_file(session.path_join("screenshot.png"))
        var sample := Vector2i(title_image.get_width() / 2, title_image.get_height() / 4)
        _expect(title_image.get_pixelv(sample).is_equal_approx(controls_image.get_pixelv(sample)),
            "Virtual-key panels leave the central game canvas uncovered")
        app.renpy_view.set_virtual_controls(false)
        await _wait(func(): return not bool(app.renpy_view.state.get("controls", true)), "Virtual keys can be hidden before starting")
    await _start_scenario()
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 1 and _dialogue().contains("第一句"), "The Chinese scenario starts through native SDL input")
    app.renpy_view.set_virtual_controls(true)
    await _wait(func(): return bool(app.renpy_view.state.get("controls", false)), "Optional in-game virtual keys appear")
    if OS.get_name() == "macOS":
        await _click_control(app.renpy_view.controls.enter_button)
    else:
        await _key("enter")
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 2, "Virtual Enter reaches the Chinese choices")
    # Shared controls consume their pointer events before SDL; the fixture
    # keeps its default first-choice focus for the next keyboard activation.
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
    app.renpy_view.set_virtual_controls(true)
    await _wait(func(): return bool(app.renpy_view.state.get("controls", false)), "Controls can be enabled before refresh")
    var played_since := app.active_game_started_msec
    var before_refresh: String = app.renpy_view.session_directory
    app.renpy_view._restart()
    await _wait(func(): return app._is_renpy_active() and app.renpy_view.session_directory != before_refresh and app.renpy_view.ready_received and bool(app.renpy_view.state.get("main_menu", false)), "Refresh restarts inside the same window")
    await _command("inspect", {"names": ["aether_probe_hooks_fresh"]})
    _expect(bool(_variables().get("aether_probe_hooks_fresh", false)), "Refresh restores module functions and class methods before reinstalling game hooks")
    await _check_title_texture()
    _expect(not app.renpy_view.controls_visible, "Refresh resets the virtual-keys menu")
    _expect(app.active_game_started_msec == played_since and app.marked.size() == 1, "Refresh retains the existing play session")
    app._handle_go_back_request()
    await _wait(func(): return not app._is_renpy_active(), "Back gracefully closes the embedded game")
    _expect(OS.is_process_running(first_process) and app.shell_root.visible, "Returning retains Aether and restores the library")
    _expect(app.play_seconds > 0 and app.active_game_started_msec == 0, "Returning finalizes play time")
    if not await _launch():
        app.queue_free()
        quit(1)
        return
    _expect(int(app.renpy_view.state.get("pid", 0)) == first_process, "Reopening uses the embedded Python runtime")
    await _start_scenario()
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 1, "The reopened game starts the scenario")
    await _key("f9")
    await _wait(func(): return int(_variables().get("aether_probe_step", 0)) == 3 and _dialogue().contains("已选择 A"), "The save survives complete game recreation")
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
