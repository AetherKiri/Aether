extends SceneTree

const Layouts := preload("res://scripts/virtual_button_layout.gd")
const ShellTest := preload("res://tests/astryx_shell_test.gd")
const Controls := preload("res://scripts/game_virtual_controls.gd")
const DesignTokens := preload("res://scripts/ui/aether_design_tokens.gd")


class Host:
    extends ShellTest.TestHost
    var fixture_path := ""
    var orientation := DisplayServer.SCREEN_SENSOR_PORTRAIT

    func _virtual_button_global_path() -> String:
        return fixture_path

    func _begin_virtual_button_orientation() -> int:
        var previous := orientation
        orientation = DisplayServer.SCREEN_SENSOR_LANDSCAPE
        return previous

    func _restore_virtual_button_orientation(previous: int) -> void:
        orientation = previous


var app: Host
var controller
var fixture: DirAccess
var failures := 0


func _initialize() -> void:
    _run.call_deferred()


func check(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)


func settle() -> void:
    await create_timer(0.26).timeout
    controller._process(0.2)
    await process_frame
    await process_frame


func editor():
    return app.active_modal_dialog


func click(parent: Node, id: String) -> void:
    var button := parent.find_child(id, true, false) as Button
    check(button != null and button.is_visible_in_tree() and not button.disabled, "Missing enabled action " + id)
    if button != null:
        button.pressed.emit()


func choose(picker: OptionButton, value: String) -> void:
    for i in picker.item_count:
        if picker.get_item_metadata(i) == value:
            picker.select(i)
            picker.item_selected.emit(i)
            return
    check(false, "Missing option " + value)


func touch(index: int, point: Vector2, down: bool) -> InputEventScreenTouch:
    var event := InputEventScreenTouch.new()
    event.index = index
    event.position = point
    event.pressed = down
    return event


func drag(index: int, point: Vector2) -> InputEventScreenDrag:
    var event := InputEventScreenDrag.new()
    event.index = index
    event.position = point
    return event


func capture(name_value: String) -> void:
    var out := OS.get_environment("AETHERKIRI_LAYOUT_CAPTURE")
    if not out.is_empty() and DisplayServer.get_name() != "headless":
        await RenderingServer.frame_post_draw
        root.get_texture().get_image().save_png(out.path_join(name_value + ".png"))


func _run() -> void:
    create_timer(45).timeout.connect(
        func():
            push_error("Virtual button editor timed out")
            quit(1)
    )
    root.size = Vector2i(852, 393)
    root.content_scale_size = Vector2i.ZERO
    root.gui_embed_subwindows = true
    fixture = DirAccess.create_temp("aether-button-layout")
    var folder := fixture.get_current_dir()
    var game := {"name": "Example", "path": folder.path_join("game"), "type": "Directory"}
    DirAccess.make_dir_recursive_absolute(game.path)
    Layouts.CONFIG.write_document(game.path.path_join(Layouts.CONFIG.FILE_NAME), {"keep": 42})
    app = Host.new()
    app.fixture_path = folder.path_join("global.json")
    app.active_language = app.LANG_ZH_HANS
    app.known_games = [game]
    controller = ShellTest.TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = folder.path_join("shell.cfg")
    app.add_child(controller)
    root.add_child(app)
    app._show_settings()
    await settle()
    if controller.view.settings_narrow and not controller.view.settings_detail:
        click(controller.view, "AstryxSection_interface")
        await settle()
    click(controller.view, "AstryxEditVirtualButtons")
    await settle()
    var e = editor()
    check(e != null and e.name == "AstryxVirtualButtonEditor", "Global settings open the editor")
    if e == null:
        quit(1)
        return
    check(app.orientation == DisplayServer.SCREEN_SENSOR_LANDSCAPE, "Opening the editor requests landscape")
    check(
        e.board.profile.id == "mouse" and e.board.profile.buttons.size() == Layouts.mouse().buttons.size(),
        "Fresh layout uses the Mouse controls"
    )
    var viewport_rect: Rect2 = e.get_global_rect()
    check(e.board.get_global_rect().is_equal_approx(viewport_rect), "The editable playfield covers the entire safe area")
    check(not e.board.mode_button.visible and not e.board.resize_visual.visible, "Handles stay hidden until selection")
    check(
        e.floating.size.y <= 70 and e.floating.size.x < viewport_rect.size.x * 0.8, "The idle tools float in one compact row"
    )
    var original_pad: Rect2 = e.board.rect_for("pad")
    click(e, "PadOptions")
    await settle()
    check(e.board.rect_for("pad").is_equal_approx(original_pad), "Opening options leaves the game controls in place")
    click(e, "PadFold")
    await settle()
    check(
        e.floating.size.x < 70 and e.board.get_global_rect().is_equal_approx(viewport_rect),
        "Collapsed tools leave the full playfield interactive"
    )
    click(e, "PadUnfold")
    click(e, "PadOptions")
    click(e, "PadAdd")
    await settle()
    var cap_id: String = e.selected
    var board: Control = e.board
    var center: Vector2 = board.rect_for(cap_id).get_center()
    check(center.distance_to(board.size * 0.5) < 1, "New button starts in the middle")
    var desired := center + Vector2(70, -25)
    board._gui_input(touch(0, center, true))
    board._gui_input(drag(0, desired))
    board._gui_input(touch(0, desired, false))
    var moved: Rect2 = board.rect_for(cap_id)
    check(moved.get_center().distance_to(desired) < 1, "Dragging moves a selected button")
    var grip: Vector2 = board._grip(moved).get_center()
    board._gui_input(touch(1, grip, true))
    board._gui_input(drag(1, grip + Vector2(22, 22)))
    board._gui_input(touch(1, grip + Vector2(22, 22), false))
    var larger: Rect2 = board.rect_for(cap_id)
    check(
        larger.size.x > moved.size.x + 15 and larger.position.distance_to(moved.position) < 1,
        "Grip resizes about the opposite corner"
    )
    choose(e.find_child("PadBinding", true, false), "Shift")
    click(e, "PadOptions")
    await settle()
    var field: LineEdit = e.find_child("PadProfileName", true, false)
    field.text = "Keyboard"
    field.text_changed.emit(field.text)
    click(e, "PadOptions")
    var pad: Rect2 = board.rect_for("pad")
    board._gui_input(touch(2, pad.get_center(), true))
    board._gui_input(touch(2, pad.get_center(), false))
    check(
        board.mode_button.visible and board.mode_button.size == board.resize_visual.size,
        "The selected D-pad has a mode handle the same size as resize"
    )
    var handle_point: Vector2 = board.mode_button.get_global_rect().get_center()
    for pressed in [true, false]:
        var click_event := InputEventMouseButton.new()
        click_event.position = handle_point
        click_event.global_position = handle_point
        click_event.button_index = MOUSE_BUTTON_LEFT
        click_event.pressed = pressed
        root.push_input(click_event, true)
    check(e.board.profile.pad_mode == "arrows", "Clicking the floating handle toggles the pad in place")
    var touch_mode_point: Vector2 = board.mode_button.get_global_rect().get_center()
    for pressed in [true, false]:
        Input.parse_input_event(touch(0, touch_mode_point, pressed))
        await process_frame
    check(e.board.profile.pad_mode == "wasd", "A mobile touch toggles the mode exactly once")
    board.mode_button.pressed.emit()
    var pad_grip: Vector2 = board._grip(pad).get_center()
    board._gui_input(touch(1, pad_grip, true))
    board._gui_input(drag(1, pad_grip - Vector2(12, 12)))
    board._gui_input(touch(1, pad_grip - Vector2(12, 12), false))
    check(board.rect_for("pad").size.x < pad.size.x - 8, "Direction pad resizes as a single control")
    await settle()
    await capture("virtual-buttons-phone")
    click(e, "PadDone")
    await settle()
    check(app.orientation == DisplayServer.SCREEN_SENSOR_PORTRAIT, "Done restores the entry orientation")
    var shared: Dictionary = Layouts.load_global(app.fixture_path).book
    var global_profile := Layouts.effective(shared)
    check(
        (
            global_profile.name == "Keyboard"
            and global_profile.pad_mode == "arrows"
            and global_profile.buttons.back().action == "Shift"
        ),
        "Global changes survive reopening"
    )

    root.size = Vector2i(1194, 834)
    app._show_detail(game)
    await settle()
    click(controller.view, "AstryxDetailSection_virtual_buttons")
    await settle()
    click(controller.view, "AstryxEditVirtualButtons")
    await settle()
    e = editor()
    check(e.book.active == "" and e.board.profile.id == global_profile.id, "Game starts with the active global layout")
    click(e, "PadOptions")
    click(e, "PadNew")
    click(e, "PadNew")
    check(
        e.book.profiles.size() == 2 and e.book.profiles[0].id != e.book.profiles[1].id,
        "Games can own multiple independent named profiles"
    )
    var local_id: String = e.book.profiles[0].id
    choose(e.find_child("PadProfiles", true, false), local_id)
    click(e, "PadReset")
    click(e, "PadAdd")
    choose(e.find_child("PadBinding", true, false), "mouse_right")
    click(e, "PadOptions")
    await settle()
    check(app.active_modal_scrim.size.is_equal_approx(Vector2(root.size)), "The tablet backdrop covers the full viewport")
    await capture("virtual-buttons-tablet")
    click(e, "PadDone")
    await settle()
    check(
        app._virtual_button_profile(game.path).id == local_id and app._virtual_button_profile().id == global_profile.id,
        "Only this game activates its local layout"
    )
    var contents: Dictionary = Layouts.CONFIG.read(game.path).document
    check(
        contents.keep == 42 and contents.virtual_buttons.profiles.size() == 2,
        "Game configuration retains other fields and both local profiles"
    )
    click(controller.view, "AstryxEditVirtualButtons")
    await settle()
    click(editor(), "PadAdd")
    click(editor(), "PadCancel")
    await settle()
    check(
        Layouts.CONFIG.read(game.path).document == contents and app.orientation == DisplayServer.SCREEN_SENSOR_PORTRAIT,
        "Cancel discards changes and restores portrait"
    )
    click(controller.view, "AstryxEditVirtualButtons")
    await settle()
    app._handle_go_back_request()
    await settle()
    check(
        app.shell_route == "detail" and app.orientation == DisplayServer.SCREEN_SENSOR_PORTRAIT,
        "System Back dismisses only the editor and restores orientation"
    )
    click(controller.view, "AstryxEditVirtualButtons")
    await settle()
    click(editor(), "PadOptions")
    choose(editor().find_child("PadProfiles", true, false), "")
    click(editor(), "PadDone")
    await settle()
    check(app._virtual_button_profile(game.path) == global_profile, "Selecting Follow global resumes inheritance")
    _game_input(global_profile)
    _mouse_binding(contents.virtual_buttons.profiles[0])
    app.queue_free()
    await process_frame
    fixture = null
    print("Virtual button editor failures: %d" % failures)
    quit(0 if failures == 0 else 1)


func _game_input(profile: Dictionary) -> void:
    var pad := Controls.new()
    root.add_child(pad)
    pad.setup(DesignTokens.new())
    pad.set_layout_profile(profile)
    pad.layout(Vector2(844, 390), Rect2(0, 0, 844, 390))
    pad.set_enabled(true)
    pad.show_virtual_controls()
    var events := []
    pad.key_event_requested.connect(func(down, code, mods): events.append([down, code, mods]))
    var stick := pad.dpad_backdrop.get_global_rect()
    var north_west := stick.get_center() - stick.size * 0.22
    pad.routes_pointer(touch(2, north_west, true))
    pad.routes_pointer(touch(2, north_west, false))
    check(
        events == [[true, 38, 0], [true, 37, 0], [false, 38, 0], [false, 37, 0]],
        "The saved arrow setting delivers arrow keys to the game"
    )
    check(not pad._caps.has("direction_mode"), "The mode handle is exclusive to the editor")
    var wasd := profile.duplicate(true)
    wasd.pad_mode = "wasd"
    pad.set_layout_profile(wasd)
    events.clear()
    var mapped := (pad._caps[profile.buttons.back().id] as Button).get_global_rect().get_center()
    pad.routes_pointer(touch(1, mapped, true))
    pad.routes_pointer(touch(2, north_west, true))
    pad.set_enabled(false)
    check(
        events.size() == 6 and events[0] == [true, 16, 1] and events[1] == [true, 87, 1] and pad._held_keys.is_empty(),
        "A bound Shift works with the joystick and all keys release on close"
    )
    check(
        Layouts.key_name(16) == "Shift" and Layouts.key_name(112) == "F1", "Native player key names match their VK bindings"
    )
    pad.queue_free()


func _mouse_binding(profile: Dictionary) -> void:
    var pad := Controls.new()
    root.add_child(pad)
    pad.setup(DesignTokens.new())
    pad.set_layout_profile(profile)
    pad.layout(Vector2(844, 390), Rect2(0, 0, 844, 390))
    pad.set_enabled(true)
    pad.show_virtual_controls()
    var caps := [pad.mouse_left_button, pad.mouse_right_button, pad._caps[profile.buttons.back().id]]
    var actions := ["mouse_left", "mouse_right", "mouse_right"]
    for i in caps.size():
        var cap: Button = caps[i]
        var icon := cap.get_node("MouseIcon") as TextureRect
        check(
            cap.text.is_empty() and icon.is_visible_in_tree() and icon.texture == Layouts.MOUSE_ICONS[actions[i]],
            "Default and remapped mouse buttons display their corresponding mouse pictogram"
        )
    var clicks := []
    pad.pointer_button_requested.connect(func(down, index, _mods, _position): clicks.append([down, index]))
    var point: Vector2 = caps.back().get_global_rect().get_center()
    pad.routes_pointer(touch(0, point, true))
    pad.routes_pointer(touch(0, point, false))
    check(clicks == [[true, 1], [false, 1]], "The remapped right mouse icon sends a right click")
    pad.queue_free()
