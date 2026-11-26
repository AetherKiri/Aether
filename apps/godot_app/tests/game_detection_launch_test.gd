extends SceneTree

const ShellInterface = preload("res://scripts/ui/astryx/shell_interface.gd")

class TestApp extends "res://scripts/main.gd":
    var captured_path := ""
    var fail_runtime_switch := false
    var play_clock_msec := 1000
    var launch_message := ""

    func _play_session_now_msec() -> int:
        return play_clock_msec

    func _switch_runtime_player(runtime_kind: String, route: Dictionary = {}) -> bool:
        if fail_runtime_switch:
            return false
        return super._switch_runtime_player(runtime_kind, route)

    func _show_message(message: String) -> void:
        launch_message = message

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

    func _show_system_alert(message: String, _title: String = "Aether") -> void:
        printerr(message)

    func _on_open_game(route: Dictionary = {}) -> void:
        captured_path = game_path.text
        super._on_open_game(route)

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
        app.fail_runtime_switch = true
        app._start_selected_game_after_save_sync()
        app.fail_runtime_switch = false
        _expect(not app.game_running, "A synchronous runtime switch failure leaves the game closed")
        _expect_unplayed(app, game, "Synchronous startup failure")

        app._start_selected_game_after_save_sync()
        _expect(app.game_running, "The cancellable ONS startup request is accepted")
        app._exit_game_for_go_back()
        await process_frame
        _expect_unplayed(app, game, "Canceling before startup completes")

        app._start_selected_game_after_save_sync()
        _expect(app.game_running, "The ONS startup request is accepted")
        _expect(app.active_game_path.is_empty(), "A queued startup does not start the play timer")
        app.play_clock_msec += 5000
        _expect(await _started_and_presented(app, "onscripter"), "The existing ONS player starts and presents a frame")
        _expect(app.active_game_path == game, "A successful ONS launch starts a play session")
        _expect(app.active_game_started_msec == app.play_clock_msec, "The play clock starts after loading")
        _expect(int(_game_record(app, game).get("lastPlayed", 0)) > 0, "Successful startup marks the game played")
        _expect(app.captured_path == game, "The directory route opens the selected game root")
        var expected_host := OS.get_environment("AETHERKIRI_EXPECT_ONS_HOST")
        if not expected_host.is_empty():
            _expect(app.player.get_engine_host() == expected_host, "ONS uses the requested host")
        app.play_clock_msec += 2500
        app._exit_game_for_go_back()
        await process_frame
        _expect(int(_game_record(app, game).get("playDurationSeconds", 0)) == 2,
            "Exit records play time without counting the loading interval")
        app.selected_game = entry
        app._start_selected_game_after_iap()
        _expect(await _started_and_presented(app, "onscripter"), "ONS reopens after returning to the library")
        if not expected_host.is_empty():
            _expect(app.player.get_engine_host() == expected_host, "Reopening retains the routed host")
        _expect(app.active_game_started_msec == app.play_clock_msec, "Reopening starts a fresh play session")
        app.play_clock_msec += 1000
        app._exit_game_for_go_back()
        await process_frame
        _expect(int(_game_record(app, game).get("playDurationSeconds", 0)) == 3, "Reopening adds only the new play time")

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

    if OS.get_environment("AETHERKIRI_EXPECT_SYSTEM3") == "1":
        await _check_system3_route(app, args[1])

    if OS.get_environment("AETHERKIRI_EXPECT_XSYSTEM35") == "1":
        await _check_xsystem35_route(app, args[1])

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


func _check_system3_route(app, mode: String) -> void:
    var game_root := ProjectSettings.globalize_path("user://system3-" + mode)
    DirAccess.make_dir_recursive_absolute(game_root)
    # Same synthetic DRI layout as the System3 native provider contract.
    var archive := PackedByteArray()
    archive.resize(768)
    archive[0] = 2
    archive[2] = 3
    archive[4] = 4
    archive[256] = 1
    archive[257] = 1
    # L 1 loads the prior slot and resumes after Q 1; on a fresh run Q writes it.
    var page := PackedByteArray([2, 0, 0x4c, 0x41, 0x7f, 0x51, 0x41, 0x7f])
    page.append_array(("'Router 中文 " + mode + "'A@").to_utf8_buffer())
    page.append_array(PackedByteArray([2, 0]))
    for i in page.size():
        archive[512 + i] = page[i]
    var archive_file := FileAccess.open(game_root.path_join("ADISK.DAT"), FileAccess.WRITE)
    _expect(archive_file != null, "Create the synthetic System3 archive")
    if archive_file == null:
        return
    archive_file.store_string("invalid DRI archive")
    archive_file.close()
    _expect(FileAccess.open(game_root.path_join("ACG.DAT"), FileAccess.WRITE) != null, "Stage the graphics marker")
    var config := FileAccess.open(game_root.path_join("system3.ini"), FileAccess.WRITE)
    _expect(config != null, "Stage the System3 variant configuration")
    if config == null:
        return
    config.store_string("[config]\ngame=system3_generic\nencoding=utf8\n")
    config.close()

    _expect(app._add_game_path(game_root), "Import the System3 fixture")
    for item in app._load_game_list():
        if item.path != game_root:
            continue
        app.selected_game = item
        var route: Dictionary = app._resolve_launch(item)
        _expect(route.get("provider_status") == "registered", "System3 is registered in this build")
        _expect(route.get("engine_option") == "system3", "Route System3 to its explicit Provider")
        _expect(route.get("entry") == game_root, "Use the System3 directory entry")
        var expected_host := OS.get_environment("AETHERKIRI_EXPECT_ONS_HOST")
        _expect(route.get("host") == expected_host, "System3 follows the selected host")
        app._start_selected_game_after_save_sync()
        _expect(app.game_running, "The malformed System3 archive reaches asynchronous startup")
        var deadline := Time.get_ticks_msec() + 8000
        while app.game_running and Time.get_ticks_msec() < deadline:
            await process_frame
        _expect(not app.game_running and app.launch_message.begins_with("Startup failed:"),
            "Asynchronous failure returns to the library")
        _expect_unplayed(app, game_root, "Asynchronous startup failure")

        archive_file = FileAccess.open(game_root.path_join("ADISK.DAT"), FileAccess.WRITE)
        _expect(archive_file != null, "Replace the malformed archive with the playable fixture")
        if archive_file == null:
            return
        archive_file.store_buffer(archive)
        archive_file.close()
        app.selected_game = item
        app._start_selected_game_after_iap()
        _expect(await _started_and_presented(app, "system3"), "The System3 Provider opens and presents a frame")
        _expect(app.player.get_engine_host() == expected_host, "System3 uses the routed host")
        if app.game_running:
            app._exit_game_for_go_back()
            await process_frame

        var saves_root := game_root.path_join("savedata/system3")
        var saved_slot := ""
        for bank in DirAccess.get_directories_at(saves_root):
            var candidate := saves_root.path_join(bank).path_join("ASLEEP_A.DAT")
            var bytes := FileAccess.get_file_as_bytes(candidate)
            if bytes.size() > 112 and bytes[0] == 0x54:
                saved_slot = candidate
                # The loader skips the descriptive header. Mark the slot to
                # distinguish loading it from running Q again and overwriting it.
                var slot := FileAccess.open(candidate, FileAccess.READ_WRITE)
                if slot != null:
                    slot.store_8(0x58)
                    slot.close()
                    break
        _expect(not saved_slot.is_empty(), "System3 writes its normal save slot")

        var initial_backend: String = app.selected_backend
        var native_selected := expected_host == "native"
        app.selected_backend = app.PlaybackBackend.GODOT if native_selected else app.PlaybackBackend.NATIVE
        app.selected_game = item
        app._start_selected_game_after_iap()
        _expect(await _started_and_presented(app, "system3"), "System3 reopens on the other host")
        _expect(app.player.get_engine_host() == ("legacy" if native_selected else "native"), "Use the other host")
        if app.game_running:
            app._exit_game_for_go_back()
            await process_frame
        app.selected_backend = initial_backend
        var reloaded_slot := FileAccess.get_file_as_bytes(saved_slot)
        _expect(not reloaded_slot.is_empty() and reloaded_slot[0] == 0x58,
            "The other host loads the same slot rather than rewriting it")
        return
    _expect(false, "Find the imported System3 game")


func _check_xsystem35_route(app, mode: String) -> void:
    var game_root := ProjectSettings.globalize_path("user://xsystem35-" + mode)
    DirAccess.make_dir_recursive_absolute(game_root)
    # Minimal ALD page: set up a 640x480 world, load slot 1 (LD), write it on
    # the first launch (QD), then enter the fixture's wait loop.
    var archive := PackedByteArray()
    archive.resize(1024)
    archive[0] = 1
    archive[3] = 2
    archive[6] = 2
    archive[256] = 1
    archive[257] = 2
    archive[512] = 16
    var page := "53333530100000002e00000000000000575702807f01e07f587f4c44417f5144417f59437f417f4022000000".hex_decode()
    archive[516] = page.size()
    for i in page.size():
        archive[528 + i] = page[i]
    var file := FileAccess.open(game_root.path_join("ADISK.ALD"), FileAccess.WRITE)
    _expect(file != null, "Create the synthetic XSystem35 archive")
    if file == null:
        return
    file.store_buffer(archive)
    file.close()

    _expect(app._add_game_path(game_root), "Import the XSystem35 fixture")
    var fixture := _game_record(app, game_root)
    _expect(not fixture.is_empty(), "Find the imported XSystem35 game")
    if fixture.is_empty():
        return
    app.selected_game = fixture
    var route: Dictionary = app._resolve_launch(fixture)
    var expected_host := OS.get_environment("AETHERKIRI_EXPECT_ONS_HOST")
    _expect(route.get("engine_option") == "xsystem35", "Route XSystem35 to its existing Provider")
    _expect(route.get("host") == expected_host, "Route XSystem35 to the selected host")
    app._start_selected_game_after_iap()
    _expect(await _started_and_presented(app, "xsystem35"), "XSystem35 opens and presents a frame")
    _expect(app.player.get_engine_host() == expected_host, "XSystem35 uses the routed host")
    if app.game_running:
        app._exit_game_for_go_back()
        await process_frame

    var saves_root := game_root.path_join("savedata/xsystem35")
    var saved_slot := ""
    for bank in DirAccess.get_directories_at(saves_root):
        var bank_path := saves_root.path_join(bank)
        for name in DirAccess.get_files_at(bank_path):
            if name.get_extension().to_lower() == "asd":
                saved_slot = bank_path.path_join(name)
                break
        if not saved_slot.is_empty():
            break
    _expect(not saved_slot.is_empty(), "XSystem35 writes its normal save slot")
    if saved_slot.is_empty():
        return
    var slot := FileAccess.open(saved_slot, FileAccess.READ_WRITE)
    _expect(slot != null, "Mark the existing XSystem35 slot")
    if slot == null:
        return
    # The loader reads the stored fields and ignores bytes past the end of
    # the save. A trailing byte distinguishes loading from a fresh write.
    slot.seek_end()
    slot.store_8(0x58)
    slot.close()
    var saved_data := FileAccess.get_file_as_bytes(saved_slot)

    var initial_backend: String = app.selected_backend
    var native_selected := expected_host == "native"
    app.selected_backend = app.PlaybackBackend.GODOT if native_selected else app.PlaybackBackend.NATIVE
    app.selected_game = fixture
    app._start_selected_game_after_iap()
    _expect(await _started_and_presented(app, "xsystem35"), "XSystem35 reopens on the other host")
    _expect(app.player.get_engine_host() == ("legacy" if native_selected else "native"), "Use the other host")
    if app.game_running:
        app._exit_game_for_go_back()
        await process_frame
    app.selected_backend = initial_backend
    _expect(FileAccess.get_file_as_bytes(saved_slot) == saved_data,
        "The other XSystem35 host loads the same save without rewriting it")


func _game_record(app, path: String) -> Dictionary:
    for item in app._load_game_list():
        if item.path == path:
            return item
    return {}


func _expect_unplayed(app, path: String, context: String) -> void:
    _expect(app.active_game_path.is_empty() and app.active_game_started_msec == 0,
        context + " leaves no active play session")
    app.play_clock_msec += 31000
    app._process_active_game_session(31.0)
    var record := _game_record(app, path)
    _expect(not record.is_empty() and int(record.get("lastPlayed", 0)) == 0
        and int(record.get("playDurationSeconds", 0)) == 0,
        context + " does not update the library after waiting")


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
