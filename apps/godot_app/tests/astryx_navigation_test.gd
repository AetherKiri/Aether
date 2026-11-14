extends SceneTree
## Repeated tab navigation must not rescan or rebuild an unchanged game library.
const Suite = preload("res://tests/astryx_shell_test.gd")
const Library = preload("res://scripts/video_library.gd")

class NavigationHost extends Suite.TestHost:
    var refreshes := 0
    var classic_cards := 0
    var cover_loads := 0

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
    await _check_return()
    await _check_updates()
    await _check_modal_first_frame()
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
