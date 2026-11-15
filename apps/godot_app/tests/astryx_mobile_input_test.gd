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

func _touch_at(position: Vector2, pressed: bool, cancelled: bool = false) -> void:
    var event := InputEventScreenTouch.new()
    event.index = 0
    event.position = position
    event.pressed = pressed
    event.canceled = cancelled
    Input.parse_input_event(event)
    Input.flush_buffered_events()
    await _frames(3)

func _move_touch(from: Vector2, to: Vector2) -> void:
    var event := InputEventScreenDrag.new()
    event.index = 0
    event.position = to
    event.relative = to - from
    Input.parse_input_event(event)
    Input.flush_buffered_events()
    await _frames(3)

func _center(name_value: String) -> Vector2:
    return host.find_child(name_value, true, false).get_global_rect().get_center()

func _check_leave_button(name_value: String) -> void:
    var button := host.find_child(name_value, true, false) as Button
    var normal := button.get_theme_stylebox("normal")
    var route_before: String = host.shell_route
    var section_before: String = controller.view.section
    var start := button.get_global_rect().get_center()
    # Move vertically out of the original icon, then release outside the group.
    var outside := Vector2(start.x, button.get_parent().get_global_rect().position.y - 24)
    await _touch_at(start, true)
    await _move_touch(start, outside)
    _expect(button.get_theme_stylebox("normal") == normal and not button.is_hovered(),
        name_value + ": leaving the original button clears its highlight before release")
    await _touch_at(outside, false)
    _expect(not button.is_hovered() and not button.has_focus() and button.get_draw_mode() == BaseButton.DRAW_NORMAL,
        name_value + ": outside release clears all native pressed/hover/focus state")
    _expect(host.shell_route == route_before and controller.view.section == section_before,
        name_value + ": outside release does not activate the original button")

func _check_partial_card_drag() -> void:
    var scroll: ScrollContainer = controller.view.scroll
    scroll.scroll_vertical = 0
    await _frames()
    var clip := scroll.get_global_rect()
    var card: Button
    for child in controller.view.find_child("AstryxLibraryGrid", true, false).get_children():
        var rect: Rect2 = child.get_global_rect()
        if rect.position.y < clip.end.y - 24 and rect.end.y > clip.end.y + 16:
            card = child
            break
    _expect(card != null, "The library fixture has a partially visible bottom card")
    if card == null:
        return
    var start := Vector2(card.get_global_rect().get_center().x, clip.end.y - 20)
    var offset := scroll.scroll_vertical
    await _touch_at(start, true)
    _expect(scroll.scroll_vertical == offset, "Pressing a clipped bottom card never snaps its description into view")
    _expect(card.get_draw_mode() in [BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED],
        "A card shows its pressed feedback while the finger stays down")
    var feedback := card.find_child("AstryxCardFeedback", true, false) as Control
    _expect(feedback != null and feedback.get_global_rect().is_equal_approx(card.get_global_rect()),
        "Card feedback covers the image, title and history together")
    var finish := start - Vector2(0, 72)
    await _move_touch(start, finish)
    await _touch_at(finish, false)
    _expect(host.shell_route == "library", "Dragging a partial card never opens it on release")
    _expect(scroll.scroll_vertical > offset, "The partial card follows the drag normally")
    _expect(not card.is_hovered() and not card.has_focus(), "The original scrolling card leaves no touch feedback")
    await create_timer(0.4).timeout

func _check_navigation_release() -> void:
    await _check_leave_button("AstryxNav_library")
    await _check_leave_button("AstryxNav_settings")
    var start := _center("AstryxNav_library")
    var videos := _center("AstryxNav_videos")
    var settings := _center("AstryxNav_settings")
    var original: String = host.shell_route
    await _touch_at(start, true)
    _expect(host.shell_route == original, "Holding navigation does not activate on touch-down")
    await _move_touch(start, settings)
    await _move_touch(settings, videos)
    _expect(host.shell_route == original, "Sliding across navigation only previews the final target")
    await _touch_at(videos, false)
    await _frames()
    _expect(host.shell_route == "videos", "Releasing a navigation slide selects the final icon exactly once")
    for id in ["library", "videos", "flash", "settings"]:
        var button := host.find_child("AstryxNav_" + id, true, false) as Button
        _expect(not button.is_hovered() and not button.has_focus(), "Touch navigation leaves no hover/focus residue: " + id)
    start = _center("AstryxNav_library")
    var outside := Vector2(controller.view.get_global_rect().get_center().x, 200)
    await _touch_at(start, true)
    await _move_touch(start, outside)
    await _touch_at(outside, false)
    _expect(host.shell_route == "videos", "Releasing outside navigation does not activate content beneath the finger")
    await _touch_at(start, true)
    await _touch_at(start, false, true)
    _expect(host.shell_route == "videos", "System-cancelled touches never navigate")
    await _tap("AstryxNav_library")
    # Real mouse input on a mobile host still owns a hover and activates normally.
    var motion := InputEventMouseMotion.new()
    motion.position = _center("AstryxNav_settings")
    Input.parse_input_event(motion)
    Input.flush_buffered_events()
    await _frames()
    _expect(host.find_child("AstryxNav_settings", true, false).is_hovered(), "An attached mouse retains ordinary hover")

func _check_settings_release() -> void:
    await _tap("AstryxNav_settings")
    await _check_leave_button("AstryxSection_interface")
    var start := _center("AstryxSection_interface")
    var target := _center("AstryxSection_about")
    var before: String = controller.view.section
    await _touch_at(start, true)
    await _move_touch(start, target)
    _expect(controller.view.section == before, "Settings categories do not change while the finger moves")
    await _touch_at(target, false)
    await _frames()
    _expect(controller.view.section == "about", "A non-scrolling settings menu selects its release target")
    for id in ["interface", "render", "compatibility", "diagnostics", "about"]:
        var button := host.find_child("AstryxSection_" + id, true, false) as Button
        _expect(not button.is_hovered() and not button.has_focus(), "Settings touch leaves no hover/focus residue: " + id)
    await _tap("AstryxNav_library")

func _tap(name_value: String, drift: Vector2 = Vector2.ZERO) -> void:
    var button := host.find_child(name_value, true, false) as BaseButton
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
    if not drift.is_zero_approx():
        var drag := InputEventScreenDrag.new()
        drag.index = 0
        position += drift
        drag.position = position
        drag.relative = drift
        Input.parse_input_event(drag)
        Input.flush_buffered_events()
        await _frames(2)
    touch = InputEventScreenTouch.new()
    touch.index = 0
    touch.position = position
    touch.pressed = false
    Input.parse_input_event(touch)
    Input.flush_buffered_events()
    await create_timer(0.2).timeout
    await _frames()

func _drag_button(name_value: String, distance: float) -> void:
    var button := host.find_child(name_value, true, false) as BaseButton
    _expect(button != null, "Missing drag target: " + name_value)
    if button == null:
        return
    var scroll := host._nearest_scroll_container(button)
    scroll.ensure_control_visible(button)
    await _frames()
    var rect := button.get_global_rect().intersection(scroll.get_global_rect())
    var position := Vector2(rect.get_center().x, rect.end.y - 5)
    var initial_offset := scroll.scroll_vertical
    var initial_route := host.shell_route
    var initial_toggle := button.button_pressed
    var activations := [0]
    button.pressed.connect(func(): activations[0] += 1)
    var touch := InputEventScreenTouch.new()
    touch.index = 0
    touch.position = position
    touch.pressed = true
    Input.parse_input_event(touch)
    Input.flush_buffered_events()
    await _frames(3)
    for _step in range(6):
        var drag := InputEventScreenDrag.new()
        drag.index = 0
        drag.relative = Vector2(0, -distance / 6.0)
        position += drag.relative
        drag.position = position
        Input.parse_input_event(drag)
        Input.flush_buffered_events()
        await _frames(2)
    _expect(scroll.scroll_vertical > initial_offset + 1,
        name_value + ": dragging over a button scrolls before release")
    _expect(scroll.get_v_scroll_bar().modulate.a > 0.9, "Scrollbar appears during a drag")
    if name_value in ["AstryxGameCard", "AstryxGameRow"]:
        var under_finger := host._nearest_base_button(host._control_at_pointer(position))
        _expect(under_finger != null, "A scroll can end over a game entry without becoming a click")
    touch = InputEventScreenTouch.new()
    touch.index = 0
    touch.position = position
    touch.pressed = false
    Input.parse_input_event(touch)
    Input.flush_buffered_events()
    await create_timer(0.2).timeout
    await _frames()
    _expect(activations[0] == 0, name_value + ": dragging cancels the button action")
    _expect(host.shell_route == initial_route, name_value + ": dragging preserves the page")
    if is_instance_valid(button) and button.toggle_mode:
        _expect(button.button_pressed == initial_toggle, "Dragging does not change a switch")
    if is_instance_valid(button) and button is OptionButton:
        _expect(not button.get_popup().visible, "Dragging does not open a selector")

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
    await _drag_button("AstryxGameCard", 80.0)
    if host.shell_route != "library":
        await _tap("AstryxNav_library")
    await _tap("AstryxGameCard", Vector2(0, -4))
    _expect(host.shell_route == "detail", name_value + ": touch opens game details")
    if host.shell_route != "detail":
        return
    host.launched = false
    await _drag_button("AstryxLaunchGame", 24.0)
    _expect(not host.launched, name_value + ": scrolling from Start does not launch a game")
    await _tap("AstryxLaunchGame")
    _expect(host.launched, name_value + ": touch invokes game launch")
    await _tap("AstryxDetailBack")
    _expect(host.shell_route == "library", name_value + ": touch returns from game details")
    await _tap("AstryxDisplay_list")
    await _drag_button("AstryxGameRow", 24.0)
    if host.shell_route != "library":
        await _tap("AstryxNav_library")
    await _tap("AstryxGameRow")
    _expect(host.shell_route == "detail", "List rows still open on a normal tap")
    await _tap("AstryxDetailBack")
    await _tap("AstryxDisplay_cards")
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

func _check_settings_drags() -> void:
    await _tap("AstryxNav_settings")
    await _tap("AstryxSection_interface")
    await _drag_button("AstryxSetting_game_virtual_menu_enabled", 24.0)
    var toggle := host.find_child("AstryxSetting_game_virtual_menu_enabled", true, false) as BaseButton
    var original := toggle.button_pressed
    await _tap("AstryxSetting_game_virtual_menu_enabled")
    _expect(toggle.button_pressed != original, "Switches still toggle on a normal tap")
    await _tap("AstryxSetting_game_virtual_menu_enabled")
    await _tap("AstryxEdit_language")
    await _drag_button("AstryxSetting_language", 24.0)
    await _tap("AstryxSetting_language")
    var select := host.find_child("AstryxSetting_language", true, false) as OptionButton
    _expect(select.get_popup().visible, "Selectors still open on a normal tap")
    select.get_popup().hide()
    await _tap("AstryxNav_library")

func _check_scrollbar_visibility() -> void:
    var scroll: ScrollContainer = controller.view.scroll
    var bar := scroll.get_v_scroll_bar()
    var rect := bar.get_global_rect()
    scroll.scroll_vertical = 120
    await _frames()
    _expect(bar.modulate.a > 0.9, "Scrolling reveals the scrollbar")
    await create_timer(1.0).timeout
    _expect(bar.modulate.a < 0.01, "Idle scrollbar fades out")
    _expect(bar.get_global_rect().is_equal_approx(rect), "Fading keeps the scrollbar hit area stable")
    var motion := InputEventMouseMotion.new()
    motion.position = rect.get_center()
    Input.parse_input_event(motion)
    Input.flush_buffered_events()
    await create_timer(1.0).timeout
    _expect(bar.modulate.a > 0.9, "Hovering the hidden scrollbar reveals and keeps it visible")
    motion = InputEventMouseMotion.new()
    motion.position = Vector2.ZERO
    Input.parse_input_event(motion)
    Input.flush_buffered_events()
    await create_timer(1.0).timeout
    _expect(bar.modulate.a < 0.01, "Scrollbar fades again after the pointer leaves")
    var touch := InputEventScreenTouch.new()
    touch.index = 0
    touch.position = rect.get_center()
    touch.pressed = true
    Input.parse_input_event(touch)
    Input.flush_buffered_events()
    await create_timer(1.0).timeout
    _expect(bar.modulate.a > 0.9, "Holding the scrollbar keeps it visible")
    touch = InputEventScreenTouch.new()
    touch.index = 0
    touch.position = rect.get_center()
    touch.pressed = false
    Input.parse_input_event(touch)
    Input.flush_buffered_events()
    await create_timer(1.0).timeout
    _expect(bar.modulate.a < 0.01, "Scrollbar fades after touch release")

func _check_mobile_frame_pacing() -> void:
    var previous_cap := Engine.max_fps
    var previous_override := OS.get_environment("AETHERKIRI_HOST_MAX_FPS")
    OS.unset_environment("AETHERKIRI_HOST_MAX_FPS")
    host._apply_host_frame_rate_limit()
    _expect(Engine.max_fps == 0, "The mobile shell follows display VSync without a 60 FPS cap")
    host._set_game_runtime_frame_pacing(true)
    _expect(Engine.max_fps == 60, "Entering a game keeps the existing mobile host cap")
    host._set_game_runtime_frame_pacing(false)
    _expect(Engine.max_fps == 0, "Leaving a game restores the high-refresh shell")
    OS.set_environment("AETHERKIRI_HOST_MAX_FPS", "90")
    host._set_game_runtime_frame_pacing(true)
    _expect(Engine.max_fps == 90, "Explicit host caps remain effective in games")
    host._set_game_runtime_frame_pacing(false)
    _expect(Engine.max_fps == 90, "Explicit host caps remain effective in the shell")
    if previous_override.is_empty():
        OS.unset_environment("AETHERKIRI_HOST_MAX_FPS")
    else:
        OS.set_environment("AETHERKIRI_HOST_MAX_FPS", previous_override)
    Engine.max_fps = previous_cap

func _run() -> void:
    create_timer(90).timeout.connect(func():
        push_error("Astryx mobile input test timed out")
        quit(1))
    Input.emulate_mouse_from_touch = true
    # Enable native ScrollContainer touch behavior on the headless display.
    Input.emulate_touch_from_mouse = true
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
    var cover := Image.create(32, 48, false, Image.FORMAT_RGB8)
    cover.fill(Color.DARK_CYAN)
    var cover_path := base.path_join("cover.png")
    cover.save_png(cover_path)
    for index in range(18):
        var path := game_path.path_join(str(index))
        DirAccess.make_dir_recursive_absolute(path)
        host.known_games.append({"name": "Mobile input fixture %02d" % index,
            "path": path, "type": "Directory", "coverPath": cover_path})
    host.video_library = Library.new(base.path_join("videos.json"), base.path_join("hidden.json"))
    host.flash_library = Library.new(base.path_join("flash.json"), base.path_join("flash-hidden.json"), ["swf"])
    controller = Suite.TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = base.path_join("interface.cfg")
    host.add_child(controller)
    root.add_child(host)
    await _frames()
    await _exercise("Android portrait", Vector2i(393, 852), Vector4.ZERO)
    await _exercise("Android portrait cutout", Vector2i(393, 852), Vector4(0, 40, 0, 16))
    await _exercise("Android landscape cutout", Vector2i(852, 393), Vector4(40, 0, 0, 16))
    await _exercise("iPhone portrait", Vector2i(393, 852), Vector4(0, 59, 0, 34))
    await _exercise("iPhone landscape", Vector2i(852, 393), Vector4(59, 0, 59, 21))
    await _exercise("iPad landscape", Vector2i(1194, 834), Vector4(0, 24, 0, 20))
    await _check_settings_release()
    await _rotate_active(Vector2i(1194, 393), Vector4.ZERO)
    await _tap("AstryxNav_settings")
    var section_before_scroll: String = controller.view.section
    await _drag_button("AstryxSection_interface", 24.0)
    _expect(controller.view.section == section_before_scroll, "Scrolling an overflowing settings menu never changes category on release")
    await _tap("AstryxNav_library")
    await _rotate_active(Vector2i(393, 852), Vector4(0, 59, 0, 34))
    await _check_partial_card_drag()
    await _check_navigation_release()
    await _check_settings_drags()
    await _check_scrollbar_visibility()
    await _rotate_active(Vector2i(852, 393), Vector4(59, 0, 59, 21))
    _check_mobile_frame_pacing()
    _expect(host.received_touches > 0 and host.received_emulated_mouse > 0,
        "Touch tests pass through Godot input dispatch and mouse emulation")
    host.queue_free()
    await _frames()
    print("Astryx mobile input failures: ", failures)
    quit(0 if failures == 0 else 1)
