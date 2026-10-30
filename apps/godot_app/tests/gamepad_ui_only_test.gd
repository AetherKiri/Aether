extends SceneTree

# Build the production UI, but never read/write the user's library/settings or
# construct a native runtime. Input goes through the real controller adapter.
class UiApp:
    extends "res://scripts/main.gd"

    func _ready() -> void:
        add_child(ui_motion)
        ui_motion.reduced_motion = true
        _apply_ui_font()
        _build_ui()
        ui_test_mode = true

    func _process(_delta: float) -> void:
        pass

    func _refresh_games() -> void:
        _rebuild_game_cards(false)

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _press(button: int) -> void:
    var event := InputEventJoypadButton.new()
    event.device = 9
    event.button_index = button
    event.pressed = true
    root.push_input(event)
    event = event.duplicate()
    event.pressed = false
    root.push_input(event)

func _settle() -> void:
    await create_timer(0.2).timeout
    for _frame in range(5):
        await process_frame

func _capture(name: String) -> void:
    var directory := OS.get_environment("AETHERKIRI_GAMEPAD_CAPTURE_DIR")
    if directory.is_empty() or DisplayServer.get_name() == "headless":
        return
    await RenderingServer.frame_post_draw
    DirAccess.make_dir_recursive_absolute(directory)
    root.get_texture().get_image().save_png(directory.path_join(name + ".png"))

func _run() -> void:
    root.size = Vector2i(1280, 720)
    var app := UiApp.new()
    root.add_child(app)
    current_scene = app
    app.gamepad_controller.set_process(false)
    await _settle()
    _expect(app.player == null, "UI-only test must not construct a native player")
    app.advanced_tool_expanded = true
    app._show_settings()
    await _settle()
    var launch := app.settings_view.find_child("UiTestModeLaunch", true, false) as Button
    _expect(launch != null, "production settings contain the UI-only entry")
    if launch == null:
        app.free()
        quit(1)
        return
    app.settings_view.ensure_control_visible(launch)
    await _settle()
    await _capture("gamepad-settings")
    launch.grab_focus()
    _press(JOY_BUTTON_A)
    _expect(app.ui_test_loading and app.loading_panel.visible, "A enters the shared loading screen")
    _expect(app.player == null, "UI-only launch remains engine-free")
    _press(JOY_BUTTON_A)
    _expect(app.ui_test_event_count == 1, "loading blocks underlying UI activations")
    app._process_ui_test_mode(app.UI_TEST_LOADING_DURATION + 0.1)
    await _settle()
    _expect(app.ui_test_game_active and app.ui_test_game_overlay.visible, "loading enters the empty game scene")
    await _capture("gamepad-ui-only-scene")
    app._sync_game_virtual_controls()
    _expect(app._gamepad_focus_root() == app.ui_test_game_overlay, "closed virtual menu cannot steal empty-scene focus")
    var toggle := app.ui_test_game_overlay.find_child("UiTestOverlayToggle", true, false) as Button
    toggle.grab_focus()
    var was_on := toggle.button_pressed
    _press(JOY_BUTTON_A)
    _expect(toggle.button_pressed != was_on, "A toggles a real production widget")
    var slider := app.ui_test_game_overlay.find_child("UiTestOpacity", true, false) as HSlider
    slider.grab_focus()
    var before := slider.value
    app._on_gamepad_navigation(Vector2.LEFT)
    _expect(slider.value < before, "left stick adjusts the shared slider")
    var select = app.ui_test_game_overlay.find_child("UiTestInputMode", true, false)
    select.grab_focus()
    _press(JOY_BUTTON_A)
    await _settle()
    _expect(select.overlay != null, "A opens the real scene dropdown")
    _press(JOY_BUTTON_B)
    await _settle()
    _expect(select.overlay == null and app.ui_test_game_active, "B closes dropdown before leaving the game")
    _press(JOY_BUTTON_START)
    _expect(app.game_virtual_controls.is_panel_open(), "Start opens shared virtual controls in UI-only mode")
    _expect(app._gamepad_focus_root() == app.game_virtual_controls, "open virtual controls own focus")
    _press(JOY_BUTTON_B)
    _expect(not app.game_virtual_controls.is_panel_open() and app.ui_test_game_active, "B closes virtual controls first")
    var reload := app.ui_test_game_overlay.find_child("UiTestReloadButton", true, false) as Button
    reload.grab_focus()
    _press(JOY_BUTTON_A)
    _expect(app.ui_test_loading and app.ui_test_event_count == 2, "A reloads through the same loading path")
    app._process_ui_test_mode(app.UI_TEST_LOADING_DURATION + 0.1)
    await _settle()
    _press(JOY_BUTTON_B)
    await _settle()
    _expect(app.shell_root.visible and not app.ui_test_game_active and not app.game_view.visible, "B returns through production cleanup")
    _expect(app.player == null, "entire UI-only roundtrip uses no runtime")
    await _capture("gamepad-return-library")
    app._start_ui_test_mode()
    _press(JOY_BUTTON_B)
    _expect(not app.ui_test_loading and app.shell_root.visible, "B also cancels a loading UI-only scene")
    app.free()
    await _settle()
    print("gamepad_ui_only_test: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
    quit(0 if failures == 0 else 1)
