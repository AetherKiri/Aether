extends SceneTree

const Library := preload("res://scripts/video_library.gd")

class LibraryApp:
    extends "res://scripts/main.gd"

    var opened_video := ""
    var last_file_dialog: FileDialog

    func _ready() -> void:
        ui_motion.reduced_motion = true
        add_child(ui_motion)
        _apply_ui_font()
        _build_ui()
        _refresh_videos()

    func _process(_delta: float) -> void:
        pass

    func _open_video_player(video: Dictionary) -> void:
        opened_video = String(video["path"])

    func _create_file_dialog(title_text: String, mode: int, filters: PackedStringArray = PackedStringArray()) -> FileDialog:
        last_file_dialog = FileDialog.new()
        last_file_dialog.title = title_text
        last_file_dialog.file_mode = mode
        last_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
        last_file_dialog.filters = filters
        return last_file_dialog

var failures := 0
var fixture: DirAccess
var app: LibraryApp

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _write(path: String, content: String = "video fixture") -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(content)

func _card_button(title: String) -> Button:
    for node in app.video_list.find_children("*", "Button", true, false):
        if node.accessibility_name == title:
            return node as Button
    _expect(false, "Card is reachable by its accessible name: " + title)
    return null

func _settle() -> void:
    for _frame in range(5):
        await process_frame

func _capture(name: String) -> void:
    var output := OS.get_environment("AETHERKIRI_VIDEO_LIBRARY_CAPTURE_DIR")
    if output.is_empty() or DisplayServer.get_name() == "headless":
        return
    await _settle()
    await RenderingServer.frame_post_draw
    DirAccess.make_dir_recursive_absolute(output)
    root.get_texture().get_image().save_png(output.path_join(name + ".png"))

func _choose_import(key: String) -> void:
    app._show_video_import_picker()
    await _settle()
    if key == "video.import_folder":
        await _capture("desktop-import")
    var choice: Button
    for button in app.active_modal_dialog.find_children("*", "Button", true, false):
        if button.text == app._t(key):
            choice = button
            break
    _expect(choice != null, "Import picker offers " + key)
    if choice != null:
        choice.pressed.emit()
    await create_timer(0.2).timeout

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    root.size = Vector2i(1280, 720)
    root.gui_embed_subwindows = true
    fixture = DirAccess.create_temp("aether-video-ui")
    var base := fixture.get_current_dir()
    var collection := base.path_join("影片合集")
    var season := collection.path_join("第一季")
    var empty := collection.path_join("待添加")
    var video := season.path_join("第02集.MP4")
    var subtitle := season.path_join("第02集.srt")
    var loose := base.path_join("独立视频.webm")
    _write(video)
    _write(subtitle, "1\n00:00:00,000 --> 00:00:03,000\nNested subtitle\n")
    _write(collection.path_join("预告片.mp4"))
    _write(loose)
    DirAccess.make_dir_recursive_absolute(empty)
    app = LibraryApp.new()
    app.video_library = Library.new(base.path_join("library.json"), base.path_join("hidden.json"))
    app.video_library.add_source(collection)
    app.video_progress_data = {video: {"position": 42.0, "duration": 84.0}}
    app.home_library_mode = "video"
    app.shell_route = "videos"
    app.active_language = app.LANG_ZH_HANS
    root.add_child(app)
    await _settle()

    _expect(app.video_list.get_child_count() == 1, "Imported folder is visible even though no root video was imported")
    _expect(app.video_folder_navigation.visible and app.video_folder_back_button.disabled, "Library root has a disabled parent action")
    await _capture("desktop-root")
    app._on_home_search_text_changed("第02集")
    _expect(app.video_list.get_child_count() == 1, "Library search still finds nested videos without opening each folder")
    _card_button("第02集").pressed.emit()
    _expect(app.opened_video == video, "Recursive search result launches the nested file")
    app._on_home_search_text_changed("")
    _card_button("影片合集").pressed.emit()
    await _settle()
    _expect(app.video_list.get_child_count() == 3 and app.video_folder_path_label.text == "影片合集", "Folder click opens its own children")
    _expect(app.video_folder_back_button.disabled == false, "Imported folder can return to the library")
    await _capture("desktop-folder")
    app._on_home_search_text_changed("第一季")
    _expect(app.video_list.get_child_count() == 1, "Search finds the folder by name")
    _card_button("第一季").pressed.emit()
    await _settle()
    _expect(app.home_search_input.text.is_empty() and app.video_list.get_child_count() == 1, "Opening a search result clears the old query")
    _card_button("第02集").pressed.emit()
    _expect(app.opened_video == video, "Video card opens the real nested file path")
    var progress := _card_button("第02集").find_child("PlaybackProgressFill", true, false) as ColorRect
    _expect(progress != null and is_equal_approx(progress.anchor_right, 0.5), "Nested video card retains its playback progress")
    app._load_video_subtitle_tracks(video)
    _expect(app.active_subtitle_tracks.size() == 1 and app.active_subtitle_tracks[0]["path"] == subtitle, "Nested video automatically finds its matching sidecar subtitle")
    _expect(app.active_subtitle_cues.size() == 1 and app.active_subtitle_cues[0]["text"] == "Nested subtitle", "Nested subtitle track can be parsed and selected")
    app._show_video_library()
    await _settle()
    _expect(app.video_library.current_directory == season, "Returning to the library preserves the playback folder")
    app._handle_go_back_request()
    _expect(app.video_library.current_directory == collection, "Android/system back returns one folder level")
    _card_button("待添加").pressed.emit()
    _expect(app.video_empty_state.visible and not app.video_scroll.visible, "Empty folder displays its empty state")
    _expect(app.video_empty_title_label.text == app._t("video.empty_folder_title"), "Empty folder gets appropriate guidance")
    _expect(app._perform_mobile_shell_back() and app.video_library.current_directory == collection, "Mobile edge-back action leaves an empty folder")
    _card_button("第一季").pressed.emit()
    var escape := InputEventKey.new()
    escape.keycode = KEY_ESCAPE
    escape.pressed = true
    app._input(escape)
    _expect(app.video_library.current_directory == collection, "Escape returns to the parent directory")
    app.video_folder_root_button.pressed.emit()
    _expect(app.video_library.current_directory.is_empty(), "Root button returns to the video library")

    await _choose_import("video.import_folder")
    _expect(app.last_file_dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR, "Folder import uses the directory picker")
    app.last_file_dialog.dir_selected.emit(collection)
    app.last_file_dialog.hide()
    app.last_file_dialog.queue_free()
    await _choose_import("video.import_file")
    _expect(app.last_file_dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE and not app.last_file_dialog.filters.is_empty(), "Single-file import still has video filters")
    app.last_file_dialog.file_selected.emit(loose)
    app.last_file_dialog.hide()
    app.last_file_dialog.queue_free()
    _expect(app.video_library.sources.size() == 2 and app.video_list.get_child_count() == 2, "Both picker selections reach the persisted library")

    for language in [app.LANG_ZH_HANS, app.LANG_ZH_HANT, app.LANG_EN, app.LANG_JA, app.LANG_KO]:
        app.active_language = language
        for key in ["video.folder", "video.import_folder", "video.parent_folder", "video.empty_folder_title", "video.remove_folder_body", "video.item_count"]:
            _expect(app.UI_TEXT[language].has(key), "Folder UI string exists for " + language + ": " + key)
    app.active_language = app.LANG_ZH_HANS
    root.size = Vector2i(390, 844)
    app._fit_full_rects()
    await _settle()
    _expect(app.home_compact_layout, "Narrow screens use compact cards")
    _card_button("影片合集").pressed.emit()
    await _settle()
    _expect(app.video_folder_path_label.size.x > 100, "Folder path retains space on a narrow screen")
    _expect(app.video_folder_navigation.get_global_rect().end.x <= app.size.x, "Folder navigation stays within the viewport")
    await _capture("compact-folder")
    _card_button("第一季").pressed.emit()
    await _settle()
    await _capture("compact-video")

    app.queue_free()
    await process_frame
    print("VIDEO_LIBRARY_UI_OK" if failures == 0 else "VIDEO_LIBRARY_UI_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
