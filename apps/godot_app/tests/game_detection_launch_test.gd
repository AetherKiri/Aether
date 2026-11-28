extends SceneTree

const ShellInterface = preload("res://scripts/ui/astryx/shell_interface.gd")

class TestApp extends "res://scripts/main.gd":
    var captured_path := ""

    func _configure_runtime_diagnostics() -> void:
        diagnostic_profile = "off"
        super._configure_runtime_diagnostics()

    func _next_required_legal_document(_platform_name: String = "") -> String:
        return ""

    func _offer_scrape_after_add(_game: Dictionary) -> void:
        pass

    func _start_vndb_cover_lookup(_game: Dictionary, _force: bool = false) -> void:
        pass

    func _maybe_show_notice() -> void:
        pass

    func _show_detail(_game: Dictionary, _source: Control = null) -> void:
        pass

    func _on_open_game() -> void:
        captured_path = game_path.text
        super._on_open_game()

var failures := 0


func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var args := OS.get_cmdline_user_args()
    if args.size() != 4 or not args[0].is_valid_filename() \
            or args[1] not in ["native", "legacy"] or args[2] not in TestApp.GAME_DETECTION_OVERRIDES:
        printerr("Pass a disposable user directory ID, expected mode, next override and ONS game root")
        quit(2)
        return
    var data_name := "%s/%s" % ["aether-detection-tests", args[0]]
    var user_dir_setting := "application/config/custom_user_dir_name"
    ProjectSettings.set_setting(user_dir_setting, data_name)
    ProjectSettings.set_setting(user_dir_setting + "." + OS.get_name().to_lower(), data_name)
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://"))

    var app := TestApp.new()
    app.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var shell = ShellInterface.new()
    shell.name = "ShellInterface"
    app.add_child(shell)
    root.add_child(app)
    await process_frame
    await process_frame
    _expect(app._game_detection_mode() == args[1], "Read the selected detection mode after process startup")
    _expect(app._uses_native_game_detection() == (args[1] == "native"), "Use the requested detector")

    var game := args[3]
    _expect(app._add_game_path(game), "Import through the production library entry point")
    var entry: Dictionary = {}
    for item in app._load_game_list():
        if item.path == game:
            entry = item
    _expect(entry.get("engine") == "onscripter", "Persist the detected ONS runtime")
    _expect(entry.get("launchFile") == "", "Directory runtime retains automatic entry")
    if not entry.is_empty():
        app.selected_game = entry
        app._start_selected_game_after_iap()
        _expect(await _started_and_presented(app, "onscripter"), "The existing ONS player starts and presents a frame")
        _expect(app.captured_path == game, "The directory route opens the selected game root")
        app._exit_game_for_go_back()
        await process_frame

    # Exercise the file-picker callback and the actual KiriKiri player using
    # the bundled, redistributable KAG3 archive.
    var archive_root := ProjectSettings.globalize_path("user://choice-" + args[1])
    DirAccess.make_dir_recursive_absolute(archive_root)
    var kag_demo := ProjectSettings.globalize_path("res://builtin_demos/aetherkiri-kag3/data.xp3")
    for file_name in ["data.xp3", "chapter.xp3"]:
        _expect(DirAccess.copy_absolute(kag_demo, archive_root.path_join(file_name)) == OK, "Stage the KAG3 fixture")
    _expect(app._add_game_path(archive_root), "Import the file-based game")
    var selection: Dictionary = {}
    for item in app._load_game_list():
        if item.path == archive_root:
            selection = item
    _expect(selection.get("launchFile") == "data.xp3", "Store the automatic XP3 hint at import")
    if not selection.is_empty():
        var hand_picked := archive_root.path_join("chapter.xp3")
        app.selected_game = selection
        app._apply_selected_launch_file(archive_root, hand_picked)
        app._start_selected_game_after_iap()
        _expect(await _started_and_presented(app, "kirikiri"), "The existing KiriKiri player starts and presents a frame")
        _expect(app.captured_path == hand_picked, "Honor the user's chosen file at the existing player handoff")
        app._exit_game_for_go_back()
        await process_frame

    var backend_before: String = app.selected_backend
    app._begin_settings_edit()
    var segment = app._game_detection_segment()
    app.add_child(segment)
    segment.item_selected.emit(app.GAME_DETECTION_OVERRIDES.find(args[2]))
    app._save_settings_draft()
    _expect(app.game_detection_override == args[2], "Apply the compatibility setting")
    _expect(app.selected_backend == backend_before, "Keep Render Pipeline selection independent")
    var settings := ConfigFile.new()
    _expect(settings.load("user://aetherkiri_settings.cfg") == OK, "Write compatibility settings")
    _expect(settings.get_value("compatibility", "game_detection_override", "auto") == args[2], "Persist only an explicit choice")

    app.player.destroy_engine()
    app.queue_free()
    await process_frame
    print("game_detection_launch_test: %s -> %s, %d failures" % [args[1], args[2], failures])
    quit(0 if failures == 0 else 1)


func _started_and_presented(app, runtime: String) -> bool:
    var deadline := Time.get_ticks_msec() + 8000
    while Time.get_ticks_msec() < deadline and app.game_running:
        if app.cached_startup_state == app.STARTUP_SUCCEEDED and app.player.get_frame_source_size().x > 0:
            return app.current_player_runtime_kind == runtime
        await process_frame
    return false


func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        printerr(message)
