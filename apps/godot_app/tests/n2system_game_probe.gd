extends SceneTree

# A local game probe; game paths and assets are supplied outside the repository.
func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var game_dir := OS.get_environment("AETHERKIRI_N2SYSTEM_GAME")
    if game_dir.is_empty() or not DirAccess.dir_exists_absolute(game_dir):
        printerr("Set AETHERKIRI_N2SYSTEM_GAME to an existing game directory")
        quit(2)
        return
    var writable := DirAccess.create_temp("aether-n2system-game-probe")
    if writable == null or not ClassDB.class_exists("AetherRuntimePlayer"):
        printerr("N2System runtime extension or isolated writable directory is unavailable")
        quit(2)
        return
    var player: Object = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(player as Node)
    var result := {"game": game_dir.get_file(), "probe": int(player.probe_runtime("n2system", game_dir))}
    var user_dir := writable.get_current_dir()
    if not player.initialize_engine(user_dir, user_dir.path_join("cache")):
        result["error"] = player.get_last_error()
    elif player.set_engine_option("runtime", "n2system") != 0:
        result["error"] = player.get_last_error()
    elif player.open_game(game_dir, true) != 0:
        result["error"] = player.get_last_error()
    else:
        for frame in range(1800):
            if player.get_startup_state() in [2, 3]:
                break
            await process_frame
        result["startup_state"] = player.get_startup_state()
        result["error"] = player.get_last_error()
        if result.startup_state == 2:
            for frame in range(60):
                if player.tick(1.0 / 60.0) != 0:
                    result["error"] = player.get_last_error()
                    break
                await process_frame
            var image: Dictionary = player.read_frame_rgba()
            result["frame_width"] = image.get("width", 0)
            result["frame_height"] = image.get("height", 0)
    player.destroy_engine()
    result["cleanup_complete"] = not player.is_initialized()
    player.free()
    writable = null
    print("N2SYSTEM_GAME_PROBE " + JSON.stringify(result))
    quit(0 if result.get("startup_state", 0) == 2 and result.get("error", "").is_empty() else 1)
