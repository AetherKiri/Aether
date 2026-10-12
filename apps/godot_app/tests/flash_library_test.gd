extends SceneTree

const Library := preload("res://scripts/video_library.gd")
const FlashView := preload("res://scripts/flash_player_view.gd")

class LibraryApp:
    extends "res://scripts/main.gd"

    var opened_flash := ""
    var last_file_dialog: FileDialog

    func _ready() -> void:
        ui_motion.reduced_motion = true
        add_child(ui_motion)
        _apply_ui_font()
        _build_ui()
        _refresh_file_library()

    func _process(_delta: float) -> void:
        pass

    func _open_flash_player(entry: Dictionary) -> void:
        opened_flash = String(entry.path)

    func _create_file_dialog(title_text: String, mode: int, filters: PackedStringArray = PackedStringArray()) -> FileDialog:
        last_file_dialog = FileDialog.new()
        last_file_dialog.title = title_text
        last_file_dialog.file_mode = mode
        last_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
        last_file_dialog.filters = filters
        return last_file_dialog

class InputPlayer:
    extends Node
    var events: Array[Dictionary] = []
    var paused := false
    var did_close := false

    func send_input(kind: int, x: float, y: float, code: int, unicode: int) -> bool:
        events.append({"kind": kind, "point": Vector2(x, y), "code": code, "unicode": unicode})
        return true

    func set_paused(value: bool) -> void:
        paused = value

    func close() -> void:
        did_close = true

var failures := 0
var fixture: DirAccess
var app: LibraryApp

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _write(path: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string("isolated catalog fixture")

func _card(title: String) -> Button:
    for node in app.video_list.find_children("*", "Button", true, false):
        if node.accessibility_name == title:
            return node as Button
    _expect(false, "Card exists: " + title)
    return null

func _settle() -> void:
    for _frame in range(5):
        await process_frame

func _capture(name: String) -> void:
    var output := OS.get_environment("AETHERKIRI_FLASH_CAPTURE_DIR")
    if output.is_empty() or DisplayServer.get_name() == "headless":
        return
    await _settle()
    await RenderingServer.frame_post_draw
    DirAccess.make_dir_recursive_absolute(output)
    root.get_texture().get_image().save_png(output.path_join(name + ".png"))

func _choose_import(key: String) -> void:
    app._show_video_import_picker()
    await _settle()
    for button in app.active_modal_dialog.find_children("*", "Button", true, false):
        if button.text == app._t(key):
            button.pressed.emit()
            await create_timer(0.2).timeout
            return
    _expect(false, "Flash import picker offers " + key)

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    root.size = Vector2i(1280, 720)
    root.gui_embed_subwindows = true
    fixture = DirAccess.create_temp("aether-flash-library")
    var base := fixture.get_current_dir()
    var collection := base.path_join("Flash")
    var nested := collection.path_join("小游戏/益智")
    var game := nested.path_join("游戏.SWF")
    var video := nested.path_join("预告.mp4")
    var loose := base.path_join("独立动画.swf")
    _write(game)
    _write(video)
    _write(loose)

    var automatic := Library.new(base.path_join("unused.json"), base.path_join("ios-hidden.json"), ["swf"])
    automatic.refresh(collection)
    _expect(automatic.entries.size() == 1 and Library.is_directory(automatic.entries[0]), "iOS Flash root lists nested folders")
    _expect(automatic.videos.size() == 1 and automatic.videos[0].path == game, "Flash recognizes uppercase SWF and excludes video files")
    _expect(automatic.enter_directory(collection.path_join("小游戏")) and automatic.enter_directory(nested), "iOS nested directories can be browsed")
    _expect(automatic.entries.size() == 1 and automatic.entries[0].path == game, "Nested Flash folder lists only SWF files")
    _expect(automatic.go_up() and automatic.go_up() and not automatic.go_up(), "iOS parent navigation stops at Flash root")
    _expect(not automatic.enter_directory(base), "iOS browsing cannot leave Flash root")

    app = LibraryApp.new()
    app.flash_library = Library.new(base.path_join("flash.json"), base.path_join("flash-hidden.json"), ["swf"])
    app.video_library = Library.new(base.path_join("videos.json"), base.path_join("videos-hidden.json"))
    _expect(not app.flash_library.add_source(video), "Flash file import rejects video files")
    _expect(not app.video_library.add_source(game), "Video file import rejects SWF files")
    app.home_library_mode = "flash"
    app.shell_route = "flash"
    app.active_language = app.LANG_ZH_HANS
    root.add_child(app)
    await _settle()
    _expect(app.home_title_label.text == app._t("nav.flash"), "Flash has its own navigation category")
    _expect(app.home_search_input.placeholder_text == app._t("flash.search_placeholder"), "Flash search has its own label")
    _expect(app.video_empty_state.visible and app.video_empty_title_label.text == app._t("flash.empty_title"), "An empty Flash catalog initially shows the Flash empty state")
    app._show_video_library()
    _expect(app.video_empty_title_label.text == app._t("video.empty_title"), "The empty video catalog keeps its video label")
    _expect(app.video_empty_icon.texture == app._load_ui_icon(app.ICON_VIDEO), "The empty video catalog uses the video icon")
    app._show_flash_library()
    _expect(app.video_empty_icon.texture == app._load_ui_icon(app.ICON_FLASH), "The empty Flash catalog uses the Flash icon after switching categories")
    for language in [app.LANG_ZH_HANS, app.LANG_ZH_HANT, app.LANG_EN, app.LANG_JA, app.LANG_KO]:
        app.active_language = language
        app._refresh_language_texts()
        _expect(app.video_empty_title_label.text == app._t("flash.empty_title"), "Language refresh retains the Flash empty title: " + language)
    app.active_language = app.LANG_ZH_HANS
    app._refresh_language_texts()
    await _capture("empty-flash-library")
    app._on_home_search_text_changed("不存在的文件")
    _expect(app.video_empty_title_label.text == app._t("search.no_results_title"), "Empty Flash search results use the search label")
    app._on_home_search_text_changed("")
    _expect(app.video_empty_title_label.text == app._t("flash.empty_title"), "Clearing Flash search restores its empty title")
    var empty_folder := collection.path_join("空文件夹")
    DirAccess.make_dir_recursive_absolute(empty_folder)
    app.flash_library.add_source(collection)
    app.video_library.add_source(video)
    app._refresh_file_library()
    _card("Flash").pressed.emit()
    _card("空文件夹").pressed.emit()
    _expect(app.video_empty_state.visible, "An empty Flash subfolder displays the empty state")
    for language in [app.LANG_ZH_HANS, app.LANG_ZH_HANT, app.LANG_EN, app.LANG_JA, app.LANG_KO]:
        app.active_language = language
        app._refresh_language_texts()
        _expect(app.video_empty_title_label.text == app._t("flash.empty_folder_title"), "Empty Flash folders retain their localized label: " + language)
    app.active_language = app.LANG_ZH_HANS
    app._refresh_language_texts()
    app._handle_go_back_request()
    _card("小游戏").pressed.emit()
    _card("益智").pressed.emit()
    _card("游戏").pressed.emit()
    _expect(app.opened_flash == game, "SWF card launches Flash playback")
    await _capture("desktop-flash-folder")
    app._show_video_library()
    _expect(app.video_list.get_child_count() == 1 and _card("预告") != null, "Switching to videos retains an independent catalog")
    app._show_flash_library()
    _expect(app.flash_library.current_directory == nested, "Returning to Flash preserves the browsed folder")
    app._handle_go_back_request()
    _expect(app.flash_library.current_directory == collection.path_join("小游戏"), "System back returns to the Flash parent folder")
    app._go_to_video_library_root()
    app._on_home_search_text_changed("游戏")
    _expect(app.video_list.get_child_count() == 1, "Flash search finds a nested game")
    _card("游戏").pressed.emit()
    _expect(app.opened_flash == game, "Flash search results use the correct player")
    app._on_home_search_text_changed("")

    await _choose_import("flash.import_file")
    _expect(app.last_file_dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE and app.last_file_dialog.filters == PackedStringArray(["*.swf;Flash files"]), "Flash file picker filters SWF")
    app.last_file_dialog.file_selected.emit(loose)
    app.last_file_dialog.hide()
    app.last_file_dialog.queue_free()
    await _choose_import("flash.import_folder")
    _expect(app.last_file_dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR, "Flash supports importing a directory")
    app.last_file_dialog.dir_selected.emit(collection)
    app.last_file_dialog.hide()
    app.last_file_dialog.queue_free()
    _expect(app.flash_library.sources.size() == 2 and app.flash_library.videos.size() == 2, "Both imports persist without duplicates")
    app._remove_video(loose)
    _expect(FileAccess.file_exists(loose) and app.flash_library.videos.size() == 1, "Removing Flash from the library preserves its original file")
    _expect(app.video_library.videos.size() == 1, "Flash removal does not alter the video catalog")
    for language in [app.LANG_ZH_HANS, app.LANG_ZH_HANT, app.LANG_EN, app.LANG_JA, app.LANG_KO]:
        for key in ["nav.flash", "flash.import_file", "flash.import_folder", "flash.guide_body_ios", "flash.open_failed", "flash.refresh"]:
            _expect(app.UI_TEXT[language].has(key), "Flash string exists for " + language + ": " + key)

    root.size = Vector2i(390, 844)
    app._fit_full_rects()
    await _settle()
    _expect(app.home_compact_layout, "Flash uses the compact layout on mobile")
    for button in [app.shell_compact_dashboard_button, app.shell_compact_library_button, app.shell_compact_video_button, app.shell_compact_flash_button, app.shell_compact_settings_button]:
        _expect(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(button.get_global_rect()), "All five mobile categories fit within the viewport")
    await _capture("compact-flash-library")

    var view := FlashView.new()
    app.add_child(view)
    view.setup(app)
    var native := InputPlayer.new()
    view.add_child(native)
    view.native = native
    var image := Image.create(640, 480, false, Image.FORMAT_RGBA8)
    image.fill(Color(0.15, 0.3, 0.5))
    view.surface.texture = ImageTexture.create_from_image(image)
    view.controls.set_enabled(true)
    _expect(not view.header.visible, "Flash starts without a visible header")
    _expect(view.surface.get_rect() == app._ui_safe_rect(view.size), "Flash fills the safe area without reserving header space")
    var content_rect: Rect2 = view._content_rect()
    _expect(view.toolbar.get_child_count() == 3 and view.refresh_button.tooltip_text == app._t("flash.refresh"), "The header contains only Back, title and Refresh")
    view.controls.menu_button.pressed.emit()
    _expect(view.header.visible and view.controls.is_menu_open(), "Opening the virtual menu reveals the header")
    view.controls.virtual_controls_button.pressed.emit()
    _expect(not view.header.visible and view.controls.is_panel_open(), "Opening virtual keys hides the header")
    view.controls.menu_button.pressed.emit()
    _expect(view.header.visible and view.controls.is_menu_open(), "Reopening the menu from virtual keys reveals the header")
    view.controls.menu_button.pressed.emit()
    _expect(not view.header.visible, "Collapsing the virtual menu hides the header")
    _expect(view._content_rect() == content_rect, "Opening and closing the header does not move or resize the movie")
    view.controls.show_virtual_controls()
    view.controls.space_button.button_down.emit()
    view.controls.space_button.button_up.emit()
    _expect(native.events.size() == 3 and native.events[0].kind == 1 and native.events[0].code == 32 and native.events[1].kind == 7 and native.events[2].kind == 2, "Virtual Space forwards key down, text and key up to Flash")
    native.events.clear()
    view.controls.w_button.button_down.emit()
    view.controls.w_button.button_up.emit()
    _expect(native.events.size() == 2 and native.events[0].code == 38 and native.events[1].code == 38, "Flash joystick defaults to arrow keys")
    native.events.clear()
    var center: Vector2 = view._content_rect().get_center()
    view.controls.pointer_move_requested.emit(center, Vector2.ZERO)
    view.controls.pointer_button_requested.emit(true, 1, 0, center)
    view.controls.pointer_button_requested.emit(false, 1, 0, center)
    _expect(native.events.size() == 3 and native.events[0].point.is_equal_approx(Vector2(320, 240)), "Virtual cursor maps through the letterboxed image")
    _expect(native.events[1].kind == 4 and native.events[1].code == 1 and native.events[2].kind == 5, "Virtual right mouse button forwards both transitions")
    var minus := InputEventKey.new()
    minus.pressed = true
    minus.keycode = KEY_MINUS
    minus.unicode = 45
    view._input(minus)
    _expect(native.events[native.events.size() - 2].code == 189, "Printable punctuation uses Flash VK codes rather than navigation keys")
    minus.pressed = false
    minus.unicode = 0
    view._input(minus)
    view.controls.enter_button.button_down.emit()
    view.set_paused(true)
    _expect(native.paused and native.events.back().kind == 2, "Pausing releases held virtual keys before pausing the runtime")
    _expect(not view.header.visible, "Disabling controls also hides the Flash header")
    var count := native.events.size()
    view._send(1, Vector2.ZERO, 32, 32)
    _expect(native.events.size() == count, "Paused Flash ignores input")
    view.set_paused(false)
    view._notification(Control.NOTIFICATION_APPLICATION_FOCUS_OUT)
    _expect(native.paused, "Backgrounding pauses Flash")
    view._notification(Control.NOTIFICATION_APPLICATION_FOCUS_IN)
    _expect(not native.paused, "Foregrounding resumes an unpaused movie")
    view.controls.show_virtual_controls()
    await _capture("compact-flash-controls")
    view.close()
    _expect(native.did_close, "Closing Flash releases the native player")

    app.queue_free()
    await process_frame
    print("FLASH_LIBRARY_OK" if failures == 0 else "FLASH_LIBRARY_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
