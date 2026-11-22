extends SceneTree

# Run with a QLIE-enabled native GDExtension:
# godot --headless --path apps/godot_app --script res://tests/qlie_import_root_test.gd
# Set AETHERELIQ_PROVIDER_TESTS to the absolute aethereliq-provider-tests path to include Tsuki.
const Main := preload("res://scripts/main.gd")
const LaunchEntry := preload("res://scripts/game_launch_entry.gd")
const SaveLocations := preload("res://scripts/game_save_locations.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _run() -> void:
    if not ClassDB.class_exists("AetherRuntimePlayer"):
        push_error("The native AetherRuntimePlayer is required")
        quit(1)
        return
    var test_root := OS.get_temp_dir().path_join("aether-qlie-import-%s-%s" % [OS.get_process_id(), Time.get_ticks_usec()])
    var games := test_root.path_join("Documents/Games")
    var wrapper := games.path_join("Shared download")
    var child := wrapper.path_join("近月")
    var direct := games.path_join("Direct")
    var ambiguous := games.path_join("Ambiguous")
    var deep := games.path_join("Too deep")
    var partial := games.path_join("Alternate only")
    var other_engine := games.path_join("Other engine")
    var mixed := games.path_join("Mixed startup")
    var game_data_only := games.path_join("GameData only")
    var in_progress := games.path_join("Import with marker")
    var delayed := games.path_join("近月延迟到齐")
    for path in [child, direct, direct.path_join("Nested"), ambiguous.path_join("A"), ambiguous.path_join("B"),
            deep.path_join("Intermediate/Leaf"), other_engine.path_join("Child"), mixed.path_join("Complete"),
            in_progress.path_join("Payload")]:
        _write_game(path, "startup.s")
    _write_game(partial.path_join("Child"), "Script/alternate.s")
    _write_game(mixed.path_join("Partial"), "Script/alternate.s")
    DirAccess.make_dir_recursive_absolute(game_data_only)
    _write_pack(game_data_only.path_join("data0.pack"), "startup.s")
    _write_file(other_engine.path_join("0.txt"), PackedByteArray())
    _write_file(in_progress.path_join("aether-import-in-progress.json"), PackedByteArray())

    var app := Main.new()
    app.player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(app.player)
    var previous: Array[Dictionary] = [{"path": wrapper, "engine": "kirikiri", "title": "Saved title",
        "lastPlayed": 123, "launchFile": "Config.exe"}]
    var scanned: Array[Dictionary] = app._scan_ios_games_dir(previous, games)
    var by_entry: Dictionary = app._games_by_library_entry(scanned, games)
    var imported: Dictionary = by_entry.get(wrapper.get_file(), {})
    _expect(imported.get("path") == child and imported.get("engine") == "qlie", "A unique verified child becomes the library root")
    _expect(imported.get("title") == "Saved title" and imported.get("lastPlayed") == 123, "Migrating a wrapper retains library metadata")
    _expect(imported.get("launchFile") == "", "The directory provider clears a legacy EXE launch entry")
    _expect(by_entry.get(direct.get_file(), {}).get("path") == direct, "A playable top-level root takes precedence over its child")
    for untouched in [ambiguous, deep, partial, other_engine, mixed, game_data_only]:
        _expect(by_entry.get(untouched.get_file(), {}).get("path") == untouched, "Preserve unresolved root: " + untouched.get_file())
    _expect(by_entry.get(other_engine.get_file(), {}).get("engine") == "onscripter", "A recognized top-level engine retains its library entry")
    _expect(not by_entry.has(in_progress.get_file()), "An in-progress import stays out of the library")
    var fresh_by_entry: Dictionary = app._games_by_library_entry(app._scan_ios_games_dir([], games), games)
    _expect(fresh_by_entry.get(wrapper.get_file(), {}).get("path") == child, "A new import resolves the same wrapper")

    var rescanned: Array[Dictionary] = app._scan_ios_games_dir(scanned, games)
    _expect(app._games_by_library_entry(rescanned, games).get(wrapper.get_file(), {}) == imported, "Rescanning retains the same nested record")
    _write_game(wrapper.path_join("Second game"), "startup.s")
    var now_ambiguous: Array[Dictionary] = app._scan_ios_games_dir(rescanned, games)
    _expect(app._games_by_library_entry(now_ambiguous, games).get(wrapper.get_file(), {}).get("path") == wrapper,
        "A wrapper that becomes ambiguous is no longer collapsed")

    # Files can expose a folder before a manual copy has finished. The library
    # may already have saved the fallback engine and a Windows config utility.
    DirAccess.make_dir_recursive_absolute(delayed)
    _write_file(delayed.path_join("Config.exe"), "MZ".to_ascii_buffer())
    var incomplete := app._scan_ios_games_dir([], games)
    var incomplete_record: Dictionary = app._games_by_library_entry(incomplete, games)[delayed.get_file()]
    _expect(incomplete_record.get("engine") == "kirikiri", "An incomplete copy starts with fallback engine metadata")
    incomplete_record["title"] = "用户标题"
    incomplete_record["lastPlayed"] = 321
    _write_game(delayed, "startup.s")
    var recovered: Dictionary = app._games_by_library_entry(app._scan_ios_games_dir(incomplete, games), games)[delayed.get_file()]
    _expect(recovered.get("path") == delayed and recovered.get("engine") == "qlie", "A complete direct copy repairs the cached fallback engine")
    _expect(recovered.get("launchFile") == "", "A recovered direct QLIE entry uses its directory")
    _expect(recovered.get("title") == "用户标题" and recovered.get("lastPlayed") == 321,
        "Repairing the inferred engine preserves user metadata")

    var startup := String(imported.get("startupScript", ""))
    var runtime: String = app._game_runtime_kind_for_launch(String(imported.get("path", "")), startup)
    var launch_path := LaunchEntry.resolve_for_runtime(imported, runtime)
    _expect(runtime == "qlie" and launch_path == child, "The normal launch resolver uses the verified child")
    if runtime == "qlie" and launch_path == child:
        _expect(app.player.initialize_engine(test_root, test_root.path_join("cache")), "Initialize native player")
        _expect(app.player.set_engine_option("runtime", runtime) == OK, "Select the real QLIE provider")
        var save_dir := SaveLocations.qlie_save_dir(launch_path, test_root)
        _expect(save_dir == child.path_join("SaveData"), "Saves resolve below the same child")
        _expect(app.player.set_engine_option("qlie.save_directory", save_dir) == OK, "Pass save path to the native provider")
        var script := LaunchEntry.resolve_startup_script(runtime, launch_path, startup)
        var result := int(app.player.open_game(launch_path, false, script))
        _expect(result == OK and app.player.is_game_open(), "Native provider opens the discovered game: " + String(app.player.get_last_error()))

    var fixture_generator := OS.get_environment("AETHERELIQ_PROVIDER_TESTS")
    if not fixture_generator.is_empty():
        _test_tsuki_import(app, test_root, fixture_generator)

    app.player.free()
    app.player = null
    app.ui_motion.free()
    app.free()
    _remove_tree(test_root)
    if failures == 0:
        print("qlie_import_root_test: PASS")
    quit(int(failures != 0))

func _test_tsuki_import(app: Main, test_root: String, fixture_generator: String) -> void:
    var games := test_root.path_join("Tsuki/Documents/Games")
    _expect(DirAccess.make_dir_recursive_absolute(games) == OK, "Create isolated Tsuki library")
    var variable := "AETHERELIQ_TSUKI_IMPORT_FIXTURE_DIR"
    var previous_value := OS.get_environment(variable)
    var had_value := OS.has_environment(variable)
    OS.set_environment(variable, games)
    var output: Array = []
    var status := OS.execute(fixture_generator, ["[.tsuki-import-fixture]"], output, true)
    if had_value:
        OS.set_environment(variable, previous_value)
    else:
        OS.unset_environment(variable)
    _expect(status == 0, "Generate native Tsuki fixtures: " + str(output))
    if status != 0:
        return

    var scanned: Array[Dictionary] = app._scan_ios_games_dir([], games)
    var by_entry: Dictionary = app._games_by_library_entry(scanned, games)
    var starting_failures := failures
    for wrapper in ["Wrapped Tsuki", "Wrapped Tsuki Bad Overlay"]:
        var imported: Dictionary = by_entry.get(wrapper, {})
        var child := games.path_join(wrapper).path_join("近月")
        var path := String(imported.get("path", ""))
        var runtime: String = app._game_runtime_kind_for_launch(path, "")
        var launch_path := LaunchEntry.resolve_for_runtime(imported, runtime)
        _expect(runtime == "qlie" and launch_path == child, "Resolve scanned Tsuki child: " + wrapper)
        if runtime != "qlie" or launch_path != child:
            continue
        app.player.destroy_engine()
        _expect(app.player.initialize_engine(test_root, test_root.path_join("cache")), "Initialize Tsuki player")
        _expect(app.player.set_engine_option("runtime", runtime) == OK, "Select native Tsuki provider")
        _expect(app._configure_qlie_save_directory(runtime, launch_path), "Resolve Tsuki save directory")
        var startup := LaunchEntry.resolve_startup_script(runtime, launch_path, "")
        var result := int(app.player.open_game(launch_path, false, startup))
        _expect(result == OK and app.player.is_game_open(), "Open scanned Tsuki: " + String(app.player.get_last_error()))
        if result != OK:
            continue
        _expect(app.player.tick(0.016) == OK, "Tick native Tsuki provider")
        var logs := String(app.player.drain_startup_logs())
        var should_mount: bool = wrapper == "Wrapped Tsuki"
        _expect(logs.contains("Tsuki translation mounted: 7 resources") == should_mount, "Assert Tsuki overlay mount: " + logs)
        if not should_mount:
            _expect(logs.contains("Tsuki translation skipped:") and logs.contains("index checksum"), "Corrupt Tsuki overlay logs its rejection")
        var original_save := launch_path.path_join("SaveData/Original.svd")
        _expect(FileAccess.file_exists(original_save) == not should_mount, "Only the original startup writes Original.svd")
    app.player.destroy_engine()
    # Reproduce a pre-existing fallback record using the complete native
    # Tsuki fixture after the resource files arrive in the direct import.
    var delayed := games.path_join("近月 Direct Import")
    _expect(DirAccess.make_dir_recursive_absolute(delayed) == OK, "Create direct import before files arrive")
    var incomplete := app._scan_ios_games_dir([], games)
    var earlier: Dictionary = app._games_by_library_entry(incomplete, games).get(delayed.get_file(), {})
    _expect(earlier.get("engine") == "kirikiri", "Tsuki direct import initially has fallback metadata")
    var source := games.path_join("Wrapped Tsuki/近月")
    var source_dir := DirAccess.open(source)
    _expect(source_dir != null, "Open complete native Tsuki fixture")
    if source_dir == null:
        return
    for name in source_dir.get_files() + source_dir.get_directories():
        _expect(DirAccess.rename_absolute(source.path_join(name), delayed.path_join(name)) == OK,
            "Complete direct import with " + name)
    var recovered: Dictionary = app._games_by_library_entry(app._scan_ios_games_dir(incomplete, games), games).get(delayed.get_file(), {})
    _expect(recovered.get("engine") == "qlie", "Refresh recovers the Tsuki provider for the completed direct import")
    var launch_path := LaunchEntry.resolve_for_runtime(recovered, String(recovered.get("engine", "")))
    _expect(launch_path == delayed, "Launch the direct Tsuki import from its directory")
    _expect(app.player.initialize_engine(test_root, test_root.path_join("cache")), "Initialize Tsuki player after rescan")
    _expect(app.player.set_engine_option("runtime", "qlie") == OK, "Select the repaired game's provider")
    _expect(app._configure_qlie_save_directory("qlie", launch_path), "Set the repaired game's save path")
    if launch_path == delayed:
        _expect(app.player.open_game(launch_path, false, "") == OK, "Open the completed direct Tsuki import")
        _expect(app.player.tick(0.016) == OK, "Tick the translated script")
        _expect(String(app.player.drain_startup_logs()).contains("Tsuki translation mounted: 7 resources"),
            "The recovered direct import mounts its translation")
        _expect(not FileAccess.file_exists(launch_path.path_join("SaveData/Original.svd")),
            "The recovered direct import runs translated startup")
    app.player.destroy_engine()
    if launch_path != delayed:
        return
    var patch := delayed.path_join("任意 修改版.EXE")
    var held_patch := test_root.path_join("patch-on-hold.EXE")
    _expect(DirAccess.rename_absolute(patch, held_patch) == OK, "Temporarily remove the synthetic translation EXE")
    _test_tsuki_fallback(app, test_root, delayed, "no compatible translation EXE found")
    _expect(DirAccess.rename_absolute(held_patch, patch) == OK, "Restore the synthetic translation EXE")
    var pack := delayed.path_join("gAMeDaTa/DATA4.PACK")
    _expect(DirAccess.rename_absolute(pack, test_root.path_join("missing-pack.bin")) == OK,
        "Simulate a missing original pack while leaving startup available")
    _test_tsuki_fallback(app, test_root, delayed, "required original game resources are missing")
    if failures == starting_failures:
        print("qlie_tsuki_import_test: PASS")

func _test_tsuki_fallback(app: Main, test_root: String, launch_path: String, reason: String) -> void:
    var save_dir := test_root.path_join("fallback-save")
    var marker := save_dir.path_join("Original.svd")
    if FileAccess.file_exists(marker):
        _expect(DirAccess.remove_absolute(marker) == OK, "Clear previous synthetic save marker")
    _expect(app.player.initialize_engine(test_root, test_root.path_join("cache")), "Initialize fallback provider")
    _expect(app.player.set_engine_option("runtime", "qlie") == OK, "Select fallback QLIE runtime")
    _expect(app.player.set_engine_option("qlie.save_directory", save_dir) == OK, "Set isolated fallback save directory")
    if int(app.player.open_game(launch_path, false, "")) == OK:
        _expect(app.player.tick(0.016) == OK, "Tick original startup")
        var logs := String(app.player.drain_startup_logs())
        _expect(logs.contains(reason) and not logs.contains("Tsuki translation mounted"), "Explain fallback: " + logs)
        _expect(FileAccess.file_exists(marker), "Original startup writes its save marker")
    else:
        _expect(false, "Fallback should open the remaining startup: " + String(app.player.get_last_error()))
    app.player.destroy_engine()

func _write_game(path: String, startup: String) -> void:
    var packs := path.path_join("gAMeDaTa")
    DirAccess.make_dir_recursive_absolute(packs)
    _write_file(path.path_join("key.fkey"), PackedByteArray())
    # Minimal Delphi form containing the 256-byte game key used by PackVfs.
    var exe := "MZTPF0".to_ascii_buffer()
    for field in ["TForm1", "Form1", "", "TImage", "IconKeyImage", "Picture.Data"]:
        exe.append(field.length())
        exe.append_array(field.to_ascii_buffer())
    exe.append_array(PackedByteArray([10, 6, 1, 0, 0, 5]))
    exe.append_array("TIcon".to_ascii_buffer())
    exe.resize(exe.size() + 259)
    _write_file(path.path_join("Base.EXE"), exe)
    _write_pack(packs.path_join("Data0.Pack"), startup)

func _write_pack(path: String, logical_name: String) -> void:
    var body := PackedByteArray([92, 115, 116, 111, 112, 10]) # \stop followed by LF.
    var file := FileAccess.open(path, FileAccess.WRITE)
    _expect(file != null, "Create synthetic pack: " + path)
    if file == null:
        return
    file.store_buffer(body)
    var name := logical_name.to_ascii_buffer()
    var key := name.size() + 0x3e
    for index in name.size():
        var sequence := index + 1
        name[index] = name[index] ^ (((sequence ^ key) + sequence) & 0xff)
    file.store_16(name.size())
    file.store_buffer(name)
    file.store_64(0)
    file.store_32(body.size())
    file.store_32(body.size())
    file.store_32(0)
    file.store_32(0)
    file.store_32(0) # No complete 8-byte block in the payload.
    var padding := PackedByteArray()
    padding.resize(0x400)
    file.store_buffer(padding)
    file.store_buffer("FilePackVer3.0".to_ascii_buffer())
    file.store_16(0)
    file.store_32(1)
    file.store_64(body.size())
    file.close()

func _write_file(path: String, bytes: PackedByteArray) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    _expect(file != null, "Create fixture file: " + path)
    if file != null:
        file.store_buffer(bytes)
        file.close()

func _remove_tree(path: String) -> void:
    var directory := DirAccess.open(path)
    if directory == null:
        return
    for name in directory.get_files():
        directory.remove(name)
    for name in directory.get_directories():
        _remove_tree(path.path_join(name))
    DirAccess.remove_absolute(path)
