extends SceneTree
const Cover = preload("res://scripts/game_cover_config.gd")
const Config = preload("res://scripts/game_render_config.gd")
const Host = preload("res://scripts/main.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)

func _run() -> void:
    var fixture := DirAccess.create_temp("aether-cover-config")
    var root := fixture.get_current_dir().path_join("游戏")
    DirAccess.make_dir_recursive_absolute(root)
    var document := {"rendering": {"output_resolution": "4k"}, "text": {"encoding": "GBK"}, "custom": {"keep": true}}
    var config_path := root.path_join("aether_config.json")
    Config.write_document(config_path, document)
    var image := Image.create(32, 48, false, Image.FORMAT_RGB8)
    image.fill(Color.CORNFLOWER_BLUE)
    var saved := Cover.save_image(root, image, "vndb", "v34")
    _expect(saved.error == OK and saved.path.get_base_dir() == root, "Cover is written inside the game folder")
    var loaded := Cover.read(root)
    _expect(loaded.configured and loaded.path == saved.path and Image.load_from_file(saved.path) != null, "Cover path and image round trip")
    _expect(not loaded.document.cover.path.is_absolute_path() and loaded.document.cover.vndb_id == "v34", "Config stores a portable path and the selected VNDB entry")
    for key in document:
        _expect(loaded.document[key] == document[key], "Saving a cover preserves " + key)
    var count := DirAccess.get_files_at(root).size()
    _expect(Cover.save_image(root, image, "vndb", "v34").error == OK and DirAccess.get_files_at(root).size() == count, "Selecting the same cover reuses its file")
    var moved := fixture.get_current_dir().path_join("移动后的游戏")
    DirAccess.rename_absolute(root, moved)
    var host = Host.new()
    var game := {"path": moved, "coverPath": "/old/container/missing.png", "_autoCoverScanned": true}
    var path: String = host._resolve_cover_path(game)
    _expect(path.get_base_dir() == moved and FileAccess.file_exists(path), "Moving the game folder keeps the configured cover resolvable")
    _expect(host._discover_default_cover_path(moved) == path, "Importing again reads the game's cover configuration")
    var games: Array[Dictionary] = [game]
    _expect(host._backfill_default_game_covers(games) and String(games[0].coverPath).begins_with("game://"), "Library metadata adopts the per-game cover")
    _expect(Cover.clear(moved) == OK and host._resolve_cover_path(game).is_empty(), "Clear persists an explicit empty cover")
    _expect(FileAccess.file_exists(path) and host._discover_default_cover_path(moved).is_empty(), "Clear keeps source images and does not rediscover the old cover")
    _expect(Cover.read(moved).document.text == document.text, "Clear preserves unrelated configuration")
    host._start_vndb_cover_lookup(game, true)
    _expect(host.vndb_cover_queue.is_empty(), "Explicit cover choices, including Clear, suppress automatic lookup")
    config_path = moved.path_join("aether_config.json")
    var file := FileAccess.open(config_path, FileAccess.WRITE)
    file.store_string("{invalid")
    file.close()
    image.fill(Color.CORAL)
    _expect(Cover.save_image(moved, image, "local").error != OK, "Invalid configuration refuses the save")
    _expect(FileAccess.get_file_as_string(config_path) == "{invalid" and DirAccess.get_files_at(moved).size() == count, "Failed save preserves configuration and creates no cover")
    var unwritable := fixture.get_current_dir().path_join("blocked-config")
    DirAccess.make_dir_recursive_absolute(unwritable.path_join("aether_config.json"))
    _expect(Cover.save_image(unwritable, image, "photos").error != OK and DirAccess.get_files_at(unwritable).is_empty(), "A failed config replacement rolls back the new image")
    Config.write_document(config_path, {"cover": {"path": "../outside.png"}})
    _expect(not Cover.read(moved).configured and Cover.read(moved).error != OK, "Configured paths cannot escape the game directory")
    host.ui_motion.free()
    host.free()
    fixture = null
    print("GAME_COVER_CONFIG_OK" if failures == 0 else "GAME_COVER_CONFIG_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
