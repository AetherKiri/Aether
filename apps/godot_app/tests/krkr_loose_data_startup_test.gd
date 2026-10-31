extends SceneTree

# Each layout boots in a separate process:
# Godot --headless --path apps/godot_app --script \
#   res://tests/krkr_loose_data_startup_test.gd -- --layout=nested
# Repeat with --layout=root to check that a root startup keeps precedence.
var player

func _initialize() -> void:
    OS.set_environment("AETHERKIRI_SUPPRESS_NATIVE_ALERTS", "1")
    call_deferred("_run")

func _write(path: String, content: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    assert(file != null)
    file.store_string(content)

func _run() -> void:
    var layout := "nested"
    for argument in OS.get_cmdline_user_args():
        if argument.begins_with("--layout="):
            layout = argument.trim_prefix("--layout=")
    assert(layout in ["nested", "root"])
    var base := OS.get_user_data_dir().path_join("krkr-loose-data-%d" % Time.get_ticks_usec())
    var game := base.path_join("game")
    var user := base.path_join("user")
    DirAccess.make_dir_recursive_absolute(user.path_join("cache"))
    _write(game.path_join("adjacent.txt"), "outer game directory")
    var startup := 'Scripts.execStorage("tjs/payload.tjs");\n'
    startup += 'if(!Storages.isExistentStorage(System.exePath+"adjacent.txt")) throw new Exception("LOST_GAME_ROOT");\n'
    startup += 'if(Storages.getFullPath(System.dataPath)!=Storages.getFullPath(System.exePath+"savedata/")) throw new Exception("MOVED_SAVEDATA");\n'
    startup += '[global.fixtureMarker].save(System.exePath+"trace.txt");\n'
    _write(game.path_join("data/startup.tjs"), startup)
    _write(game.path_join("data/tjs/payload.tjs"), 'global.fixtureMarker="nested";')
    if layout == "root":
        _write(game.path_join("startup.tjs"), startup)
        _write(game.path_join("tjs/payload.tjs"), 'global.fixtureMarker="root";')

    player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(player as Node)
    if not player.initialize_engine(user, user.path_join("cache")):
        _fail("initialization failed")
        return
    player.set_engine_option("mock_enabled", "0")
    player.set_engine_option("plugin_load_mode", "krkrsdl3")
    if player.open_game(game, true) != 0:
        _fail("open failed")
        return
    var deadline := Time.get_ticks_msec() + 20000
    while Time.get_ticks_msec() < deadline:
        var state: int = player.get_startup_state()
        if state == 2:
            player.destroy_engine()
            var actual := FileAccess.get_file_as_bytes(game.path_join("trace.txt")).get_string_from_utf16().trim_prefix("\ufeff").strip_edges()
            if actual != layout:
                _fail("wrong startup or script directory: " + actual)
                return
            print("KRKR_LOOSE_DATA_STARTUP_OK layout=", layout)
            quit(0)
            return
        if state == 3:
            _fail("startup failed")
            return
        await process_frame
    _fail("startup timed out")

func _fail(message: String) -> void:
    printerr(message, ": ", player.get_last_error(), " logs=", player.drain_startup_logs())
    player.destroy_engine()
    quit(1)
