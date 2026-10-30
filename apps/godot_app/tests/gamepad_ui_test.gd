extends SceneTree

const Main = preload("res://scripts/main.gd")
const Cursor = preload("res://scripts/gamepad_cursor.gd")
const Controller = preload("res://scripts/gamepad_controller.gd")
const VirtualControls = preload("res://scripts/game_virtual_controls.gd")

class FakePlayer extends RefCounted:
    var pointers: Array = []
    var keys: Array = []

    func send_pointer_event(event_type: int, pointer_id: int, x: float, y: float, _dx: float, _dy: float, _button: int, _mods: int) -> int:
        pointers.append([event_type, pointer_id, Vector2(x, y)])
        return 0

    func get_renderer_info() -> String:
        return "test"

    func send_key_event(pressed: bool, code: int, _modifiers: int, _unicode: int) -> int:
        keys.append([pressed, code])
        return 0

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    root.size = Vector2i(1000, 700)
    # Attach the script after entering the tree to exercise its UI helpers
    # without launching the native runtime or loading persisted user settings.
    var app = Control.new()
    root.add_child(app)
    current_scene = app
    app.set_script(Main)
    app.set_process(false)
    app.set_process_input(false)
    app.set_process_unhandled_input(false)
    app.add_child(app.ui_motion)
    app.ui_motion.reduced_motion = true
    app.size = Vector2(1000, 700)
    app.shell_root = Control.new()
    app.add_child(app.shell_root)
    var background_button := Button.new()
    app.shell_root.add_child(background_button)
    background_button.grab_focus()
    app.modal_layer = Control.new()
    app.add_child(app.modal_layer)
    var toggle := CheckButton.new()
    app.modal_layer.add_child(toggle)
    var toggles: Array = []
    toggle.toggled.connect(func(value: bool): toggles.append(value))
    app._on_gamepad_confirm()
    assert(root.gui_get_focus_owner() == toggle)
    assert(toggle.button_pressed and toggles == [true])
    toggle.disabled = true
    app._on_gamepad_confirm()
    assert(toggles == [true], "disabled modal controls must not fall through to the page")
    app.modal_layer.hide()

    var snapshot: Dictionary = app._current_settings_snapshot()
    for key in ["gamepad_enabled", "gamepad_dead_zone", "gamepad_sensitivity", "gamepad_cursor_speed"]:
        assert(snapshot.has(key) and key in app.SETTINGS_DRAFT_KEYS, "controller preferences participate in settings snapshots")
    app._begin_settings_edit()
    app._on_setting_toggle("gamepad_enabled", false)
    assert(not app.settings_draft.gamepad_enabled and app.gamepad_enabled, "settings edits remain a draft until applied")
    var dead_zone_control: Control = app._gamepad_dead_zone_control()
    app.shell_root.add_child(dead_zone_control)
    var dead_zone_slider := dead_zone_control.find_child("GamepadDeadZoneSlider", true, false) as HSlider
    dead_zone_slider.value = 0.25
    assert(is_equal_approx(float(app.settings_draft.gamepad_dead_zone), 0.25))
    dead_zone_control.free()
    app._discard_settings_draft()

    var select = app._apple_select()
    select.add_item("One")
    select.add_item("Two")
    app.shell_root.add_child(select)
    select.grab_focus()
    app._on_gamepad_confirm()
    await process_frame
    assert(app._gamepad_focus_root() == select.overlay)
    var second := select.popup_menu.get_child(1) as Button
    second.grab_focus()
    app._on_gamepad_confirm()
    assert(select.selected_index == 1)
    await create_timer(0.2).timeout
    app._on_gamepad_confirm()
    await process_frame
    app._on_gamepad_cancel()
    await create_timer(0.2).timeout
    assert(select.overlay == null)

    var ui_test_overlay := Control.new()
    var ui_test_button := Button.new()
    var ui_test_activations: Array = []
    ui_test_button.pressed.connect(func(): ui_test_activations.append(true))
    ui_test_button.focus_mode = Control.FOCUS_ALL
    ui_test_overlay.add_child(ui_test_button)
    app.ui_test_game_overlay = ui_test_overlay
    app.ui_test_game_active = true
    app.add_child(ui_test_overlay)
    ui_test_overlay.show()
    assert(app._gamepad_focus_root() == ui_test_overlay)
    app._ensure_gamepad_focus()
    assert(root.gui_get_focus_owner() == ui_test_button)
    app._on_gamepad_confirm()
    assert(ui_test_activations == [true], "UI-only controls use the same confirm handler")
    app.ui_test_game_active = false
    app.ui_test_game_overlay = null
    ui_test_overlay.queue_free()

    var slider := HSlider.new()
    slider.min_value = 0.0
    slider.max_value = 1.0
    slider.step = 0.1
    app.shell_root.add_child(slider)
    slider.grab_focus()
    app._on_gamepad_navigation(Vector2.RIGHT)
    assert(is_equal_approx(slider.value, 0.1))

    var option := OptionButton.new()
    option.add_item("First")
    option.add_item("Disabled")
    option.add_item("Third")
    option.set_item_disabled(1, true)
    app.shell_root.add_child(option)
    option.grab_focus()
    app._on_gamepad_confirm()
    await process_frame
    assert(option.get_popup().visible, "A opens a native OptionButton")
    option.get_popup().set_focused_item(0)
    app._on_gamepad_navigation(Vector2.DOWN)
    assert(option.get_popup().get_focused_item() == 2, "native dropdown navigation skips disabled items")
    app._on_gamepad_confirm()
    assert(option.selected == 2 and not option.get_popup().visible)
    option.grab_focus()
    app._on_gamepad_confirm()
    await process_frame
    app._on_gamepad_cancel()
    assert(not option.get_popup().visible, "B closes native dropdowns before the page")

    var controller := Controller.new()
    app.add_child(controller)
    controller.set_process(false)
    controller.confirm_pressed.connect(app._on_gamepad_confirm)
    var activations: Array = []
    select.pressed.connect(func(): activations.append(true))
    select.grab_focus()
    var confirm := InputEventJoypadButton.new()
    confirm.button_index = JOY_BUTTON_A
    confirm.pressed = true
    root.push_input(confirm)
    await process_frame
    assert(activations.size() == 1, "A must activate its focused Control exactly once")
    assert(select.overlay != null, "A must open the dropdown exactly once")
    app._on_gamepad_cancel()
    await create_timer(0.2).timeout
    controller.enabled = false
    root.push_input(confirm)
    confirm.pressed = false
    root.push_input(confirm)
    await process_frame
    assert(activations.size() == 1, "disabled controller must suppress default Godot joypad actions")

    app.shell_root.hide()
    app.game_view = Control.new()
    app.game_view.position = Vector2(20, 30)
    app.game_view.scale = Vector2(1.2, 1.2)
    app.add_child(app.game_view)
    app.viewport = TextureRect.new()
    app.viewport.position = Vector2(100, 100)
    app.viewport.size = Vector2(800, 500)
    var image := Image.create(800, 600, false, Image.FORMAT_RGBA8)
    app.viewport.texture = ImageTexture.create_from_image(image)
    app.viewport.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    app.add_child(app.viewport)
    app.last_source_texture_size = Vector2i(800, 600)
    app.current_surface_size = Vector2i(800, 600)
    app.gamepad_cursor = Cursor.new()
    app.gamepad_cursor.setup(app.ui_tokens, app.ui_motion)
    app.gamepad_cursor.hide()
    app.game_view.add_child(app.gamepad_cursor)
    app.player = FakePlayer.new()
    app.game_running = true
    app.cached_startup_state = app.STARTUP_SUCCEEDED
    app._sync_gamepad_cursor_position()
    var visual_center: Vector2 = app.game_view.get_global_transform() * (app.gamepad_cursor.position + app.gamepad_cursor.size * 0.5)
    assert(visual_center.is_equal_approx(app.viewport.get_global_rect().get_center()))
    app._on_gamepad_confirm()
    assert(app.player.pointers.size() == 2)
    assert(app.player.pointers[0][2].is_equal_approx(Vector2(400, 300)))

    app._on_gamepad_pointer_vector(Vector2(100, 100))
    var bounds: Rect2 = app._gamepad_pointer_bounds()
    assert(bounds.has_point(app.gamepad_cursor_screen_position), "pointer must stay inside the drawn frame")

    app._on_gamepad_navigation(Vector2.LEFT)
    app._on_gamepad_cancel()
    app._on_gamepad_button_changed(JOY_BUTTON_Y, true)
    assert(app.player.keys == [[true, 0x25], [false, 0x25], [true, 0x1B], [false, 0x1B], [true, 0x20], [false, 0x20]])
    app._on_gamepad_page(-1)
    assert(app.player.pointers.back()[0] == app.POINTER_SCROLL)
    app._on_gamepad_button_changed(JOY_BUTTON_X, true)
    assert(app.gamepad_skip_held and app.player.keys.back() == [true, 0x11])
    app._on_gamepad_device_changed(0, false, "test")
    assert(not app.gamepad_skip_held and app.player.keys.back() == [false, 0x11])

    app.loading_panel = PanelContainer.new()
    app.add_child(app.loading_panel)
    var blocked_count: int = app.player.pointers.size()
    app._on_gamepad_confirm()
    app._on_gamepad_pointer_vector(Vector2.ONE)
    app._on_gamepad_navigation(Vector2.UP)
    assert(app.player.pointers.size() == blocked_count, "loading must block gamepad input")
    assert(app._gamepad_focus_root() == app.loading_panel)
    app.loading_panel.hide()

    app.game_virtual_controls = VirtualControls.new()
    app.game_virtual_controls.setup(app.ui_tokens)
    app.add_child(app.game_virtual_controls)
    app.game_virtual_controls.set_enabled(true)
    app.game_virtual_controls.set_gamepad_navigation_enabled(true)
    app._on_gamepad_menu()
    assert(app.game_virtual_controls.is_panel_open())
    assert(app._gamepad_focus_root() == app.game_virtual_controls)
    var forwarded: int = app.player.pointers.size()
    app._on_gamepad_pointer_vector(Vector2.ONE)
    assert(app.player.pointers.size() == forwarded)
    var keys: Array = []
    app.game_virtual_controls.key_event_requested.connect(func(pressed: bool, code: int, _mods: int): keys.append([pressed, code]))
    app.game_virtual_controls.enter_button.grab_focus()
    app.gamepad_ui_pointer_active = false
    app._on_gamepad_confirm()
    assert(keys == [[true, VirtualControls.VK_RETURN], [false, VirtualControls.VK_RETURN]])
    app._on_gamepad_cancel()
    assert(not app.game_virtual_controls.is_panel_open())
    app._reset_gamepad_cursor()
    assert(not app.gamepad_cursor.visible and not app.gamepad_cursor_initialized)

    app.game_running = false
    app.game_view.hide()
    app.shell_root.show()
    for child in app.shell_root.get_children():
        child.queue_free()
    await process_frame
    var snap_button := Button.new()
    snap_button.position = Vector2(400, 240)
    snap_button.size = Vector2(120, 64)
    app.shell_root.add_child(snap_button)
    var clicks: Array = []
    snap_button.pressed.connect(func(): clicks.append(true))
    app.gamepad_cursor_free_screen_position = Vector2(380, 272)
    app.gamepad_cursor_initialized = true
    app._on_gamepad_ui_pointer_vector(Vector2.ZERO)
    assert(app.gamepad_cursor.visible and app.gamepad_cursor_snap_target == snap_button)
    assert(app.gamepad_cursor_screen_position.is_equal_approx(snap_button.get_global_rect().get_center()))
    app._on_gamepad_confirm()
    assert(clicks == [true], "A activates the magnetically selected shell control once")
    app._on_gamepad_ui_pointer_vector(Vector2(0.6, 0))
    assert(app.gamepad_cursor_snap_target == null, "continuous motion escapes attraction")
    app._on_gamepad_confirm()
    assert(clicks.size() == 1, "empty space must not activate stale focus")
    snap_button.disabled = true
    app.gamepad_cursor_free_screen_position = Vector2(460, 272)
    app._on_gamepad_ui_pointer_vector(Vector2.ZERO)
    assert(app.gamepad_cursor_snap_target == null, "disabled controls cannot attract")
    snap_button.disabled = false
    app._on_gamepad_ui_pointer_vector(Vector2.ZERO)
    app.modal_layer.show()
    app._on_gamepad_ui_pointer_vector(Vector2.ZERO)
    assert(app.gamepad_cursor_snap_target != snap_button, "a modal invalidates the background target")
    app.modal_layer.hide()
    snap_button.queue_free()
    await process_frame
    app._on_gamepad_ui_pointer_vector(Vector2.ZERO)
    assert(app.gamepad_cursor_snap_target == null, "deleted targets are safe")

    var rail := HSlider.new()
    rail.position = Vector2(300, 200)
    rail.size = Vector2(200, 40)
    rail.max_value = 100
    app.shell_root.add_child(rail)
    app.gamepad_cursor_free_screen_position = Vector2(450, 220)
    app._on_gamepad_ui_pointer_vector(Vector2.ZERO)
    app._on_gamepad_confirm()
    assert(is_equal_approx(rail.value, 75), "pointer can choose a position along a slider")
    rail.hide()
    var clip := Control.new()
    clip.position = Vector2(300, 200)
    clip.size = Vector2(100, 100)
    clip.clip_contents = true
    app.shell_root.add_child(clip)
    var clipped_button := Button.new()
    clipped_button.position = Vector2(0, 200)
    clipped_button.size = Vector2(100, 40)
    clip.add_child(clipped_button)
    app.gamepad_cursor_free_screen_position = Vector2(350, 420)
    app._on_gamepad_ui_pointer_vector(Vector2.ZERO)
    assert(app.gamepad_cursor_snap_target == null, "clipped offscreen controls cannot attract the pointer")

    app.free()
    print("gamepad_ui_test: PASS")
    quit(0)
