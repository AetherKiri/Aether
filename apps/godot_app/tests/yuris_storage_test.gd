extends SceneTree

const Options := preload("res://scripts/yuris_engine_options.gd")

class StoragePlayer:
    extends RefCounted

    var initialized := false
    var opens: Array[Dictionary] = []
    var destroys := 0

    func is_initialized() -> bool:
        return initialized

    func initialize_engine(user_dir: String, cache_dir: String) -> bool:
        opens.append({"user": user_dir, "cache": cache_dir})
        initialized = true
        return true

    func destroy_engine() -> void:
        destroys += 1
        initialized = false

    func set_engine_option(_key: String, _value: String) -> int:
        return 0

class StorageApp:
    extends "res://scripts/main.gd"

    func _append_log(_message: String) -> void:
        pass

    func _resolve_game_path(path: String) -> String:
        return path

var failures := 0
var fixture: DirAccess

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _write(path: String, value: String) -> void:
    _expect(DirAccess.make_dir_recursive_absolute(path.get_base_dir()) == OK, "Create fixture directory")
    var file := FileAccess.open(path, FileAccess.WRITE)
    _expect(file != null, "Create fixture file")
    if file != null:
        file.store_string(value)

func _initialize() -> void:
    fixture = DirAccess.create_temp("aether-yuris-storage")
    _expect(fixture != null, "Create isolated storage fixture")
    if fixture == null:
        quit(1)
        return
    var base := fixture.get_current_dir()
    _check_migration(base)
    _check_existing_local_store(base)
    _check_fallback_and_retry(base)
    _check_player_paths(base)
    fixture = null
    if failures == 0:
        print("YURIS_STORAGE_OK")
    quit(1 if failures else 0)

func _check_migration(base: String) -> void:
    var game := base.path_join("games/日本語 中文")
    var host := base.path_join("host")
    DirAccess.make_dir_recursive_absolute(game)
    var legacy: String = Options.legacy_user_directory(host, game)
    var other: String = Options.legacy_user_directory(host, game + "-other")
    var contents := {
        "save00001.sd": "saved container",
        "save00001.sd.yuris.1": "saved segment",
        "save00001.sd.ysv": "saved scene",
        "thumbnail.png": "saved thumbnail",
        "gsd.sd": "global settings",
        "flash/shared/data.bin": "Flash user state",
    }
    for name: String in contents:
        _write(legacy.path_join(name), contents[name])
    _write(legacy.path_join("cache/extracted.bin"), "disposable cache")
    _write(other.path_join("save00002.sd"), "different game")
    _write(game.path_join("save/gsd.sd"), "original Windows data")
    _write(game.path_join("savedata/krkr.console.log"), "old import log")
    _write(game.path_join("savedata/.DS_Store"), "Finder metadata")
    var result: String = Options.user_directory(host, game)
    _expect(result == game.path_join("savedata"), "Prefer saves beside the game")
    for name: String in contents:
        _expect(FileAccess.get_file_as_string(result.path_join(name)) == contents[name], "Preserve migrated bytes: " + name)
        _expect(FileAccess.get_file_as_string(legacy.path_join(name)) == contents[name], "Retain original backup: " + name)
    _expect(not FileAccess.file_exists(result.path_join("save00002.sd")), "Never import another game's slots")
    _expect(not DirAccess.dir_exists_absolute(result.path_join("cache")), "Never migrate extracted resources")
    _expect(FileAccess.get_file_as_string(game.path_join("save/gsd.sd")) == "original Windows data", "Keep Windows saves intact")
    _expect(Options.cache_directory(host, game) == legacy.path_join("cache"), "Cache stays in application storage")
    _expect(Options.user_directory(host, game + "/") == result, "Normalize trailing separator")
    _expect(Options.user_directory(host, game + "/../日本語 中文") == result, "Normalize relative path segments")
    DirAccess.remove_absolute(result.path_join("save00001.sd"))
    _expect(Options.user_directory(host, game) == result, "Reuse migrated store")
    _expect(not FileAccess.file_exists(result.path_join("save00001.sd")), "Do not resurrect a deleted slot from backups")
    var relocated := base.path_join("games/relocated")
    _expect(DirAccess.rename_absolute(game, relocated) == OK, "Move the game with its saves")
    var moved: String = Options.user_directory(host, relocated)
    _expect(moved == relocated.path_join("savedata"), "Game move does not change the save store identity")
    _expect(FileAccess.get_file_as_string(moved.path_join("gsd.sd")) == "global settings", "Saves travel with the game folder")

func _check_existing_local_store(base: String) -> void:
    var game := base.path_join("games/local-wins")
    var host := base.path_join("host")
    var local := game.path_join("savedata")
    _write(local.path_join("save00001.sd"), "new local container")
    var legacy: String = Options.legacy_user_directory(host, game)
    _write(legacy.path_join("save00001.sd"), "old container")
    _write(legacy.path_join("save00001.sd.yuris.1"), "old sidecar")
    _expect(Options.user_directory(host, game) == local, "Existing local store stays authoritative")
    _expect(FileAccess.get_file_as_string(local.path_join("save00001.sd")) == "new local container", "Do not overwrite a local slot")
    _expect(not FileAccess.file_exists(local.path_join("save00001.sd.yuris.1")), "Do not mix old sidecars into a local slot")

func _check_fallback_and_retry(base: String) -> void:
    var host := base.path_join("host")
    var game := base.path_join("games/blocked")
    _write(game.path_join("savedata"), "file blocks save directory")
    var fallback: String = Options.legacy_user_directory(host, game)
    _expect(Options.user_directory(host, game) == fallback, "Unwritable local storage uses per-game fallback")
    _expect(Options.user_directory(host, "") == host, "Empty root retains host storage")
    var missing := base.path_join("games/missing")
    _expect(Options.user_directory(host, missing) == Options.legacy_user_directory(host, missing), "Missing game uses isolated fallback")
    _expect(not DirAccess.dir_exists_absolute(missing), "Do not create a missing game root")
    var retry := base.path_join("games/retry")
    var local := retry.path_join("savedata")
    var legacy: String = Options.legacy_user_directory(host, retry)
    _write(legacy.path_join("save00001.sd"), "complete legacy slot")
    # Force the last migration step to fail after files have been copied.
    DirAccess.make_dir_recursive_absolute(local.path_join(Options.MIGRATION_MARKER))
    _expect(Options.user_directory(host, retry) == legacy, "Failed migration keeps the original store usable")
    _expect(not FileAccess.file_exists(local.path_join("save00001.sd")), "Roll back partial migration")
    _expect(FileAccess.get_file_as_string(legacy.path_join("save00001.sd")) == "complete legacy slot", "Migration failure retains original data")
    DirAccess.remove_absolute(local.path_join(Options.MIGRATION_MARKER))
    _expect(Options.user_directory(host, retry) == local, "Retry migration after the obstruction is removed")
    _expect(FileAccess.get_file_as_string(local.path_join("save00001.sd")) == "complete legacy slot", "Retry recovers the complete slot")

func _check_player_paths(base: String) -> void:
    var app := StorageApp.new()
    var player := StoragePlayer.new()
    app.player = player
    app.current_player_runtime_kind = app.RUNTIME_YURIS
    var first := base.path_join("player/first")
    var second := base.path_join("player/second")
    var probe_game := base.path_join("player/probe")
    for game in [first, second, probe_game]:
        _write(game.path_join("game.exe"), "launcher")
    var host := OS.get_user_data_dir()
    var created: Array[String] = []
    for game in [first, second]:
        var legacy: String = Options.legacy_user_directory(host, game)
        _expect(not DirAccess.dir_exists_absolute(legacy), "Unique player fixture cannot touch an existing store")
        created.append(legacy)
    app.selected_game = {"path": first.path_join("game.exe")}
    _expect(app._ensure_player_initialized(), "Normal executable launch initializes")
    _expect(player.opens.back().user == first.path_join("savedata"), "Pass game-local saves to the actual player")
    _expect(player.opens.back().cache == Options.cache_directory(host, first), "Pass separate application cache to the player")
    _expect(app._ensure_player_initialized() and player.opens.size() == 1, "Reuse the same game's initialized engine")
    app.selected_game = {"path": second}
    _expect(app._ensure_player_initialized(), "Switch to second game")
    _expect(player.destroys == 1 and player.opens.back().user == second.path_join("savedata"), "Reinitialize storage when switching games")
    # Probe launches must still use only their explicit sandbox, never import
    # or overwrite a live game's save bank.
    var old_inline := OS.get_environment("AETHERKIRI_TEST_CONFIG_JSON")
    var had_inline := OS.has_environment("AETHERKIRI_TEST_CONFIG_JSON")
    var old_user := OS.get_environment("AETHERKIRI_USER_DIR")
    var had_user := OS.has_environment("AETHERKIRI_USER_DIR")
    var probe_user := base.path_join("probe-user")
    OS.set_environment("AETHERKIRI_TEST_CONFIG_JSON", JSON.stringify({"user_dir": probe_user}))
    OS.unset_environment("AETHERKIRI_USER_DIR")
    app.cli_probe_script = "res://scripts/gui_render_probe.gd"
    app.selected_game = {"path": probe_game}
    _expect(app._ensure_player_initialized(), "Initialize isolated JSON probe")
    _expect(player.opens.back().user == probe_user and player.opens.back().cache == probe_user.path_join("cache"), "Honor explicit probe storage")
    _expect(not DirAccess.dir_exists_absolute(probe_game.path_join("savedata")), "Probe does not create real game saves")
    # The regression probe has a stricter sandbox contract than step probes.
    # Keep both engine directories inside it, even if user_dir is also set.
    var regression_relative := "user://regressions/yuris-storage-%d" % Time.get_ticks_usec()
    var regression_root := ProjectSettings.globalize_path(regression_relative)
    var had_regressions := DirAccess.dir_exists_absolute(regression_root.get_base_dir())
    _expect(not DirAccess.dir_exists_absolute(regression_root), "Unique regression sandbox")
    OS.set_environment("AETHERKIRI_TEST_CONFIG_JSON", JSON.stringify({
        "writable_root": regression_relative, "user_dir": probe_user,
    }))
    app.cli_probe_script = "res://scripts/runtime_regression_probe.gd"
    _expect(app._ensure_player_initialized(), "Initialize isolated regression probe")
    _expect(player.opens.back().user == regression_root, "Regression saves use the validated writable root")
    _expect(player.opens.back().cache == regression_root.path_join("cache"), "Regression cache uses the same sandbox")
    var opens_before := player.opens.size()
    _expect(app._ensure_player_initialized() and player.opens.size() == opens_before, "Reuse an unchanged regression sandbox")
    OS.set_environment("AETHERKIRI_TEST_CONFIG_JSON", JSON.stringify({"writable_root": "user://regressions/../../invalid"}))
    _expect(not app._ensure_player_initialized(), "Reject a regression root outside its sandbox")
    _expect(player.opens.size() == opens_before, "Invalid regression config never falls back to live saves")
    if had_inline:
        OS.set_environment("AETHERKIRI_TEST_CONFIG_JSON", old_inline)
    else:
        OS.unset_environment("AETHERKIRI_TEST_CONFIG_JSON")
    if had_user:
        OS.set_environment("AETHERKIRI_USER_DIR", old_user)
    app.cli_probe_script = ""
    app.current_player_runtime_kind = app.RUNTIME_ONSCRIPTER
    var default_cache := host.path_join("cache")
    var had_default_cache := DirAccess.dir_exists_absolute(default_cache)
    _expect(app._ensure_player_initialized(), "Switch out of YU-RIS")
    _expect(player.opens.back().user == host, "Other runtimes must not inherit YU-RIS storage")
    if not had_default_cache:
        DirAccess.remove_absolute(default_cache)
    DirAccess.remove_absolute(regression_root.path_join("cache"))
    DirAccess.remove_absolute(regression_root)
    if not had_regressions:
        DirAccess.remove_absolute(regression_root.get_base_dir())
    for directory in created:
        DirAccess.remove_absolute(directory.path_join("cache"))
        DirAccess.remove_absolute(directory)
    app.player = null
    app.ui_motion.free()
    app.free()
