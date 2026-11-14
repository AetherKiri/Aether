extends SceneTree
## Repeated tab navigation must not rescan or rebuild an unchanged game library.
const Suite = preload("res://tests/astryx_shell_test.gd")
const Library = preload("res://scripts/video_library.gd")

class NavigationHost extends Suite.TestHost:
    var refreshes := 0
    var classic_cards := 0
    var cover_loads := 0
    var classic_details := 0
    var runtime_probes := 0
    var ios_library := false
    var media_refreshes := 0

    func _mobile_runtime() -> bool:
        return true

    func _quit_app_for_go_back() -> void:
        push_error("Unexpected app exit while navigating within the shell")
        get_tree().quit(1)

    func _library_uses_refresh_action() -> bool:
        return ios_library

    func _refresh_file_library() -> void:
        media_refreshes += 1
        super._refresh_file_library()

    func _rebuild_detail_contents(game: Dictionary, hero: bool, content: bool) -> void:
        classic_details += 1
        super._rebuild_detail_contents(game, hero, content)

    func _game_runtime_kind(path: String) -> String:
        runtime_probes += 1
        return super._game_runtime_kind(path)

    func _refresh_games() -> void:
        refreshes += 1
        super._refresh_games()

    func _process(_delta: float) -> void:
        _fit_full_rects()

    func _game_card(game: Dictionary) -> Button:
        classic_cards += 1
        return super._game_card(game)

    func _load_cover_texture(game: Dictionary, target_size: Vector2i = Vector2i.ZERO, radius: int = 0) -> Texture2D:
        cover_loads += 1
        return super._load_cover_texture(game, target_size, radius)

var host: NavigationHost
var controller: Suite.TestController
var fixture: DirAccess
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)

func _settle() -> void:
    await create_timer(0.22).timeout
    for _frame in range(4):
        await process_frame

func _first_game() -> Node:
    return controller.view.find_child("AstryxGameCard", true, false)

func _check_return() -> void:
    var first_id := _first_game().get_instance_id()
    controller.view.scroll.scroll_vertical = 160
    await _settle()
    var offset: int = controller.view.scroll.scroll_vertical
    var before := [host.refreshes, host.classic_cards, host.cover_loads]
    controller.view.navigate("videos")
    await _settle()
    var start := Time.get_ticks_usec()
    controller.view.navigate("library")
    print("Astryx return with ", host.known_games.size(), " games: ", (Time.get_ticks_usec() - start) / 1000.0, " ms")
    await _settle()
    _expect(host.refreshes == before[0], "Tab navigation does not reload the game library")
    _expect(host.classic_cards == before[1], "Tab navigation does not rebuild hidden classic cards")
    _expect(host.cover_loads == before[2], "Returning to an unchanged library does not reload covers")
    _expect(_first_game().get_instance_id() == first_id, "Returning reuses the existing game controls, including after the state poll")
    _expect(controller.view.scroll.scroll_vertical == offset, "Returning preserves the library scroll position")

func _check_updates() -> void:
    controller.view.navigate("flash")
    await _settle()
    var before := host.classic_cards
    host.known_games[0]["name"] = "Updated library title"
    host._refresh_games()
    _expect(host.classic_cards == before, "Data refresh does not build the hidden classic library")
    controller.view.navigate("library")
    await _settle()
    _expect(_first_game().accessibility_name == "Updated library title", "Changes made while away invalidate the cached library")
    await _check_return()
    var first_id := _first_game().get_instance_id()
    controller.view.navigate("videos")
    await _settle()
    # An explicit refresh also picks up disk-only changes (e.g. a replaced
    # cover) even when the library metadata has not changed.
    host._refresh_games()
    controller.view.navigate("library")
    await _settle()
    _expect(_first_game().get_instance_id() != first_id, "Explicit refresh invalidates unchanged metadata")
    controller.view.navigate("videos")
    host.known_games.pop_back()
    host._refresh_games()
    controller.view.navigate("library")
    await _settle()
    _expect(controller.view.find_child("AstryxLibraryGrid", true, false).get_child_count() == host.known_games.size(),
        "Removed entries do not survive in the cached library")
    controller.set_library_display("list")
    await _settle()
    var row := controller.view.find_child("AstryxGameRow", true, false)
    _expect(row != null, "Changing display mode replaces cached cards with rows")
    var row_id: int = row.get_instance_id()
    controller.view.navigate("videos")
    await _settle()
    controller.view.navigate("library")
    await _settle()
    _expect(controller.view.find_child("AstryxGameRow", true, false).get_instance_id() == row_id,
        "The list display is also reused")
    controller.view.navigate("videos")
    root.size = Vector2i(1194, 834)
    controller.draft_theme = "dark"
    await _settle()
    controller.view.navigate("library")
    await _settle()
    _expect(not controller.view.phone, "Returning after rotation uses the current layout")
    _expect(controller.view.find_child("AstryxGameRow", true, false).get_instance_id() != row_id,
        "Layout/theme changes invalidate retained controls")

func _check_modal_first_frame() -> void:
    # The first frame must not depend on the presenter's 150 ms state poll.
    controller.set_process(false)
    for mode in ["game", "video", "flash"]:
        host.home_library_mode = mode
        if mode == "game":
            host._show_import_picker()
        else:
            host._show_video_import_picker()
        await process_frame
        var dialog := host.active_modal_dialog
        var surface := dialog.get_theme_stylebox("panel") as StyleBoxFlat
        _expect(surface.bg_color.is_equal_approx(controller.view.design.color("surface")),
            mode + " import uses Astryx on its first frame")
        for button in dialog.find_children("*", "Button", true, false):
            _expect(button.get_theme_font("font") == controller.view.design.bold,
                mode + " import buttons have their final font before drawing")
        host._dismiss_modal()
        await _settle()
    controller.set_process(true)

func _button(name_value: String) -> Button:
    return controller.view.layout_root.find_child(name_value, true, false) as Button

func _check_detail_entry() -> void:
    var library_id := _first_game().get_instance_id()
    host.text_runtime = "yuris"
    var previous := [host.classic_details, host.runtime_probes]
    controller.set_process(false)
    host._open_game_detail_with_iap(host.known_games[0])
    _expect(controller.view.route == "detail", "Opening details updates the presenter without waiting for its state poll")
    _expect(host.classic_details == previous[0], "Opening Astryx details does not build a hidden classic page")
    _expect(host.runtime_probes - previous[1] == 1, "Text and launch fields share one runtime detection")
    var launch := _button("AstryxLaunchGame")
    var launch_id := launch.get_instance_id() if launch != null else 0
    _expect(launch_id != 0, "Detail actions are available immediately")
    controller.set_process(true)
    await _settle()
    _expect(_button("AstryxLaunchGame").get_instance_id() == launch_id, "The next poll does not rebuild the detail actions")
    host._handle_go_back_request()
    await _settle()
    _expect(host.shell_route == "library" and _first_game().get_instance_id() == library_id,
        "System Back from details restores the cached library")
    host._show_detail(host.known_games[0])
    controller.set_enabled(false, false)
    _expect(host.detail_view.is_visible_in_tree() and host.detail_scroll.get_child_count() > 0,
        "Switching to classic builds and shows its detail page on demand")
    controller.set_enabled(true, false)
    controller.view.navigate("library")
    host.text_runtime = ""
    await _settle()

func _swipe_back() -> void:
    var touch := InputEventScreenTouch.new()
    touch.index = 3
    touch.position = Vector2(8, 300)
    touch.pressed = true
    _expect(host._handle_mobile_edge_back_input(touch), "The edge gesture starts inside the settings subpage")
    var drag := InputEventScreenDrag.new()
    drag.index = 3
    drag.position = Vector2(158, 305)
    drag.relative = Vector2(150, 5)
    host._handle_mobile_edge_back_input(drag)
    touch = InputEventScreenTouch.new()
    touch.index = 3
    touch.position = drag.position
    host._handle_mobile_edge_back_input(touch)

func _check_settings_back() -> void:
    for narrow in [[Vector2i(393, 852), false], [Vector2i(834, 1194), true]]:
        root.size = narrow[0]
        controller.view.sidebar_expanded = narrow[1]
        controller.view.navigate("settings")
        await _settle()
        _button("AstryxSection_render").pressed.emit()
        host._handle_go_back_request()
        _expect(host.shell_route == "settings" and not controller.view.settings_detail,
            "System Back returns from Display to the settings list")
        _button("AstryxSection_render").pressed.emit()
        var resolution := "original" if host.settings_draft.output_resolution != "original" else "1080p"
        controller.view._set_value("output_resolution", resolution)
        _swipe_back()
        _expect(host.shell_route == "settings" and not controller.view.settings_detail,
            "Edge swipe returns one settings level")
        _expect(host.dirty_settings and host.settings_draft.output_resolution == resolution,
            "Returning to the settings list preserves unsaved changes")
        host._handle_go_back_request()
        _expect(host.shell_route == "settings" and host.modal_layer.visible,
            "Leaving the settings root still asks about unsaved changes")
        host._handle_go_back_request()
        await _settle()
        _expect(not host.modal_layer.visible and host.shell_route == "settings",
            "Back dismisses the modal before navigating the page")
        controller.discard_settings()
        controller.view.navigate("library")
        await _settle()
    root.size = Vector2i(1194, 834)
    controller.view.sidebar_expanded = false
    controller.view.navigate("settings")
    await _settle()
    host._handle_go_back_request()
    await _settle()
    _expect(host.shell_route == "library", "Wide settings already show the list, so Back leaves settings")

func _check_ios_library_actions() -> void:
    var games := host.known_games.duplicate()
    host.known_games.clear()
    host._refresh_games()
    host.ios_library = true
    root.size = Vector2i(393, 852)
    for destination in ["library", "videos", "flash"]:
        controller.view.navigate(destination)
        controller.view.rebuild()
        await _settle()
        _expect(_button("AstryxImport") == null, "iOS does not offer import: " + destination)
        var refresh := _button("AstryxRefresh")
        var empty := _button("AstryxEmptyLibraryAction")
        _expect(refresh != null and refresh.text == "刷新", "iOS header offers Refresh: " + destination)
        _expect(empty != null and empty.text == "刷新", "iOS empty state offers Refresh: " + destination)
        var before := host.refreshes if destination == "library" else host.media_refreshes
        if refresh != null:
            refresh.pressed.emit()
        # The first refresh may replace an empty-state control.
        empty = _button("AstryxEmptyLibraryAction")
        if empty != null:
            empty.pressed.emit()
        var after := host.refreshes if destination == "library" else host.media_refreshes
        _expect(after == before + 2 and not host.modal_layer.visible,
            "Both iOS actions refresh without opening a picker: " + destination)
    host.ios_library = false
    host.known_games.assign(games)
    host._refresh_games()
    controller.view.navigate("library")
    await _settle()
    _expect(_button("AstryxImport") != null, "Other platforms retain Import")
    _button("AstryxImport").pressed.emit()
    _expect(host.modal_layer.visible, "Import still opens the picker on other platforms")
    host._dismiss_modal()

func _check_background_effects() -> void:
    host.ui_motion.reduced_motion = false
    controller.view.rebuild()
    await _settle()
    var field: Control = controller.view.background_effect
    var field_id := field.get_instance_id()
    _expect(field.is_visible_in_tree() and field.is_processing(), "The background animates when the shell is visible")
    _expect(field.mouse_filter == Control.MOUSE_FILTER_IGNORE, "The background never intercepts library touches")
    controller.view.navigate("settings")
    await _settle()
    _button("AstryxSection_interface").pressed.emit()
    await _settle()
    _button("AstryxSetting_background_effects").button_pressed = false
    _expect(controller.is_dirty() and not field.visible and not field.is_processing(), "Turning effects off previews immediately and stops animation")
    controller.discard_settings()
    _expect(not controller.is_dirty() and field.visible, "Cancel restores the saved background preference")
    _button("AstryxSetting_background_effects").button_pressed = false
    _expect(controller.save_settings(), "The background preference can be saved")
    var reloaded := Suite.TestController.new()
    reloaded.preference_path = controller.preference_path
    reloaded.load_preferences()
    _expect(not reloaded.background_effects and not reloaded.draft_background_effects, "Disabling effects survives a fresh preference load")
    reloaded.free()
    _button("AstryxSetting_background_effects").button_pressed = true
    controller.discard_settings()
    _expect(not field.visible, "Canceling an enabled preview restores the saved disabled state")
    _button("AstryxSetting_background_effects").button_pressed = true
    _expect(controller.save_settings(), "Effects can be re-enabled")
    controller.view.navigate("library")
    await _settle()
    controller.view.navigate("videos")
    controller.view.navigate("library")
    await _settle()
    _expect(controller.view.background_effect.get_instance_id() == field_id,
        "Settings rebuilds and cached-library navigation reuse one background")
    _expect(controller.view.find_children("AstryxBackgroundEffect", "Control", true, false).size() == 1,
        "Cached pages do not leave duplicate background renderers")
    host.shell_root.hide()
    _expect(not field.is_processing(), "Hiding the shell for gameplay stops background work")
    host.shell_root.show()
    _expect(field.is_processing(), "Returning to the shell resumes background work")
    field.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
    _expect(not field.is_processing(), "Leaving the foreground suspends background work")
    field.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
    _expect(field.is_processing(), "Returning to the foreground resumes background work")
    host.ui_motion.reduced_motion = true
    controller.view.rebuild()
    _expect(not field.visible and not field.is_processing(), "Reduced motion disables decorative animation")

func _run() -> void:
    create_timer(60).timeout.connect(func(): quit(1))
    root.size = Vector2i(393, 852)
    root.content_scale_size = Vector2i.ZERO
    fixture = DirAccess.create_temp("aether-astryx-navigation")
    var base := fixture.get_current_dir()
    host = NavigationHost.new()
    host.active_language = host.LANG_ZH_HANS
    var cover := Image.create(24, 36, false, Image.FORMAT_RGB8)
    cover.fill(Color.DARK_CYAN)
    var path := base.path_join("cover.png")
    cover.save_png(path)
    for index in range(200):
        var game_path := base.path_join(str(index))
        DirAccess.make_dir_recursive_absolute(game_path)
        host.known_games.append({"name": "Navigation fixture %03d" % index, "path": game_path, "type": "Directory", "coverPath": path})
    host.video_library = Library.new(base.path_join("videos.json"), base.path_join("hidden.json"))
    host.flash_library = Library.new(base.path_join("flash.json"), base.path_join("flash-hidden.json"), ["swf"])
    controller = Suite.TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = base.path_join("interface.cfg")
    host.add_child(controller)
    root.add_child(host)
    controller.set_enabled(true, false)
    await _settle()
    await _check_detail_entry()
    await _check_settings_back()
    await _check_ios_library_actions()
    await _check_return()
    await _check_updates()
    await _check_modal_first_frame()
    await _check_background_effects()
    controller.set_enabled(false, false)
    _expect(host.game_list.get_child_count() == host.known_games.size(), "Switching to classic restores its current library")
    var title_visible := false
    for label in host.game_list.get_child(0).find_children("*", "Label", true, false):
        title_visible = title_visible or label.text == "Updated library title"
    _expect(title_visible, "Classic cards reflect changes made in Astryx")
    host.queue_free()
    await process_frame
    print("Astryx navigation failures: ", failures)
    quit(0 if failures == 0 else 1)
