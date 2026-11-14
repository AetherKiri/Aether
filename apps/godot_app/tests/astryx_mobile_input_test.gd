extends SceneTree
## Keep the production per-frame layout active while touch presses span frames.
const Suite = preload("res://tests/astryx_shell_test.gd")
const Library = preload("res://scripts/video_library.gd")

class MobileHost extends Suite.TestHost:
    var safe_insets := Vector4.ZERO
    var received_touches := 0
    var received_emulated_mouse := 0

    func _ui_safe_rect(viewport_size: Vector2) -> Rect2:
        return Rect2(Vector2(safe_insets.x, safe_insets.y),
            viewport_size - Vector2(safe_insets.x + safe_insets.z, safe_insets.y + safe_insets.w))

    func _is_touch_platform() -> bool:
        return true

    func _process(_delta: float) -> void:
        _fit_full_rects()

    func _input(event: InputEvent) -> void:
        if event is InputEventScreenTouch:
            received_touches += 1
        if event is InputEventMouseButton and event.device == INPUT_DEVICE_ID_EMULATION:
            received_emulated_mouse += 1
        super._input(event)

var host: MobileHost
var controller
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)

func _frames(count: int = 12) -> void:
    for _frame in range(count):
        await process_frame

func _tap(name_value: String) -> void:
    var button := host.find_child(name_value, true, false) as Button
    _expect(button != null, "Missing touch target: " + name_value)
    if button == null:
        return
    var scroll := host._nearest_scroll_container(button)
    if scroll != null:
        scroll.ensure_control_visible(button)
        await _frames()
    var visible_rect := button.get_global_rect()
    if scroll != null:
        visible_rect = visible_rect.intersection(scroll.get_global_rect())
    _expect(visible_rect.has_area(), "Touch target is visible: " + name_value)
    if not visible_rect.has_area():
        return
    var position := visible_rect.get_center()
    var touch := InputEventScreenTouch.new()
    touch.index = 0
    touch.position = position
    touch.pressed = true
    Input.parse_input_event(touch)
    Input.flush_buffered_events()
    # A real tap takes multiple rendered frames, unlike emitting pressed or
    # pushing down/up in one frame, which hides recreated-button regressions.
    await _frames(8)
    touch = InputEventScreenTouch.new()
    touch.index = 0
    touch.position = position
    touch.pressed = false
    Input.parse_input_event(touch)
    Input.flush_buffered_events()
    await create_timer(0.2).timeout
    await _frames()

func _exercise(name_value: String, viewport_size: Vector2i, insets: Vector4) -> void:
    controller.set_enabled(false, false)
    host.safe_insets = insets
    root.size = viewport_size
    host._show_settings()
    controller.set_enabled(true, false)
    await _frames(24)
    var nav := host.find_child("AstryxNav_library", true, false)
    _expect(nav != null, name_value + ": library navigation exists")
    if nav == null:
        return
    var previous_id := nav.get_instance_id()
    await _frames()
    nav = host.find_child("AstryxNav_library", true, false)
    _expect(nav.get_instance_id() == previous_id, name_value + ": unchanged layout preserves button instances")
    _expect(controller.view.get_global_rect().is_equal_approx(host._ui_safe_rect(Vector2(viewport_size))),
        name_value + ": presenter fits the final safe area")
    await _tap("AstryxNav_library")
    _expect(host.shell_route == "library", name_value + ": touch navigates to the game library")
    if host.shell_route != "library":
        return
    await _tap("AstryxGameCard")
    _expect(host.shell_route == "detail", name_value + ": touch opens game details")
    if host.shell_route != "detail":
        return
    host.launched = false
    await _tap("AstryxLaunchGame")
    _expect(host.launched, name_value + ": touch invokes game launch")
    await _tap("AstryxDetailBack")
    _expect(host.shell_route == "library", name_value + ": touch returns from game details")
    print("Mobile touch scenario checked: ", name_value)

func _rotate_active(viewport_size: Vector2i, insets: Vector4) -> void:
    host.safe_insets = insets
    root.size = viewport_size
    await _frames(24)
    _expect(controller.view.get_global_rect().is_equal_approx(host._ui_safe_rect(Vector2(viewport_size))),
        "Rotation reapplies the safe area without switching UI modes")
    _expect(controller.view.phone == (viewport_size.x < 700),
        "Rotation switches between bottom and sidebar navigation")
    await _tap("AstryxNav_settings")
    _expect(host.shell_route == "settings", "Touch opens settings after rotation")
    await _tap("AstryxNav_library")
    _expect(host.shell_route == "library", "Touch returns to the library after rotation")

func _run() -> void:
    create_timer(45).timeout.connect(func():
        push_error("Astryx mobile input test timed out")
        quit(1))
    Input.emulate_mouse_from_touch = true
    Input.use_accumulated_input = false
    root.content_scale_size = Vector2i.ZERO
    root.gui_embed_subwindows = true
    var fixture := DirAccess.create_temp("aether-astryx-mobile-input")
    var base := fixture.get_current_dir()
    var game_path := base.path_join("game")
    DirAccess.make_dir_recursive_absolute(game_path)
    host = MobileHost.new()
    host.active_language = host.LANG_ZH_HANS
    host.language_mode = host.LANG_ZH_HANS
    host.known_games = [{"name": "Mobile input fixture", "path": game_path, "type": "Directory"}]
    host.video_library = Library.new(base.path_join("videos.json"), base.path_join("hidden.json"))
    host.flash_library = Library.new(base.path_join("flash.json"), base.path_join("flash-hidden.json"), ["swf"])
    controller = Suite.TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = base.path_join("interface.cfg")
    host.add_child(controller)
    root.add_child(host)
    await _frames()
    await _exercise("Android portrait", Vector2i(393, 852), Vector4.ZERO)
    await _exercise("iPhone portrait", Vector2i(393, 852), Vector4(0, 59, 0, 34))
    await _exercise("iPhone landscape", Vector2i(852, 393), Vector4(59, 0, 59, 21))
    await _exercise("iPad landscape", Vector2i(1194, 834), Vector4(0, 24, 0, 20))
    await _rotate_active(Vector2i(393, 852), Vector4(0, 59, 0, 34))
    await _rotate_active(Vector2i(852, 393), Vector4(59, 0, 59, 21))
    _expect(host.received_touches > 0 and host.received_emulated_mouse > 0,
        "Touch tests pass through Godot input dispatch and mouse emulation")
    host.queue_free()
    await _frames()
    print("Astryx mobile input failures: ", failures)
    quit(0 if failures == 0 else 1)
