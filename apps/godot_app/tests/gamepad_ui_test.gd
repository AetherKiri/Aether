extends SceneTree

const Main = preload("res://scripts/main.gd")
const Cursor = preload("res://scripts/gamepad_cursor.gd")
const Controller = preload("res://scripts/gamepad_controller.gd")
const VirtualControls = preload("res://scripts/game_virtual_controls.gd")

class FakePlayer extends RefCounted:
    var pointers: Array = []

    func send_pointer_event(event_type: int, pointer_id: int, x: float, y: float, _dx: float, _dy: float, _button: int, _mods: int) -> int:
        pointers.append([event_type, pointer_id, Vector2(x, y)])
        return 0

    func get_renderer_info() -> String:
        return "test"

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
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

    var slider := HSlider.new()
    slider.min_value = 0.0
    slider.max_value = 1.0
    slider.step = 0.1
    app.shell_root.add_child(slider)
    slider.grab_focus()
    app._on_gamepad_navigation(Vector2.RIGHT)
    assert(is_equal_approx(slider.value, 0.1))

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
    app._on_gamepad_confirm()
    assert(keys == [[true, VirtualControls.VK_RETURN], [false, VirtualControls.VK_RETURN]])
    app._on_gamepad_cancel()
    assert(not app.game_virtual_controls.is_panel_open())
    app._reset_gamepad_cursor()
    assert(not app.gamepad_cursor.visible and not app.gamepad_cursor_initialized)

    app.free()
    print("gamepad_ui_test: PASS")
    quit(0)
