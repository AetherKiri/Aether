extends SceneTree

class RuntimePlayer:
    extends RefCounted

    var initialized := false
    var initialization_succeeds := true
    var initializations := 0
    var options: Dictionary = {}

    func is_initialized() -> bool:
        return initialized

    func initialize_engine(_user_dir: String, _cache_dir: String) -> bool:
        initializations += 1
        initialized = initialization_succeeds
        return initialized

    func destroy_engine() -> void:
        initialized = false
        options.clear()

    func set_engine_option(key: String, value: String) -> int:
        if not initialized:
            return -2
        options[key] = value
        return 0

    func get_last_result() -> String:
        return "INVALID_STATE"

    func get_last_error() -> String:
        return "engine is not initialized"

class RuntimeApp:
    extends "res://scripts/main.gd"

    var backend_applications := 0
    var option_applications := 0
    var enhancement_applications := 0

    func _append_log(_message: String) -> void:
        pass

    func _cleanup_softpal_platform_ui() -> void:
        pass

    func _apply_backend(_log_selection: bool) -> void:
        backend_applications += 1

    func _apply_engine_options() -> void:
        option_applications += 1

    func _apply_frame_enhancement_settings() -> void:
        enhancement_applications += 1

var failures := 0

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _initialize() -> void:
    var fixture := DirAccess.create_temp("aether-runtime-reopen")
    if fixture == null:
        push_error("Create isolated runtime fixture")
        quit(1)
        return
    var had_config := OS.has_environment("AETHERKIRI_TEST_CONFIG_JSON")
    var old_config := OS.get_environment("AETHERKIRI_TEST_CONFIG_JSON")
    var had_user := OS.has_environment("AETHERKIRI_USER_DIR")
    var old_user := OS.get_environment("AETHERKIRI_USER_DIR")
    OS.set_environment("AETHERKIRI_TEST_CONFIG_JSON", JSON.stringify({
        "user_dir": fixture.get_current_dir(),
    }))
    OS.unset_environment("AETHERKIRI_USER_DIR")
    for runtime_kind in ["rfvp", "onscripter"]:
        _check_reopen(runtime_kind)
    if had_config:
        OS.set_environment("AETHERKIRI_TEST_CONFIG_JSON", old_config)
    else:
        OS.unset_environment("AETHERKIRI_TEST_CONFIG_JSON")
    if had_user:
        OS.set_environment("AETHERKIRI_USER_DIR", old_user)
    DirAccess.remove_absolute(fixture.get_current_dir().path_join("cache"))
    fixture = null
    if failures == 0:
        print("RUNTIME_PLAYER_REOPEN_OK")
    quit(1 if failures else 0)

func _check_reopen(runtime_kind: String) -> void:
    var app := RuntimeApp.new()
    var player := RuntimePlayer.new()
    app.player = player
    app.cli_probe_script = "res://scripts/gui_render_probe.gd"
    app.current_player_runtime_kind = (
        app.RUNTIME_KIRIKIRI if runtime_kind == "rfvp" else runtime_kind
    )
    _expect(app._ensure_player_initialized(), "Initialize the app's first engine")
    _expect(app._switch_runtime_player(runtime_kind), "Reuse the initialized engine")
    _expect(player.initializations == 1, "An initialized engine is reused")
    _expect(app.backend_applications == 0, "Reuse preserves the active renderer")

    # Returning to the library destroys the handle while retaining the player
    # Node and runtime kind. RFVP sets its encoding before _on_open_game().
    for launch in range(3):
        player.destroy_engine()
        _expect(app._switch_runtime_player(runtime_kind), "Reopen after returning to the library")
        _expect(player.is_initialized(), "Recreate the handle before launch options")
        _expect(player.initializations == launch + 2, "Initialize once per reopened session")
        _expect(player.options.get("runtime", "") == (
            "auto" if runtime_kind == "rfvp" else runtime_kind
        ), "Restore runtime selection after recreation")
        _expect(player.set_engine_option("rfvp_encoding", "gbk") == 0, "Pre-open options have an initialized engine")
        _expect(app.backend_applications == launch + 1, "Restore the renderer after recreation")
        _expect(app.option_applications == launch + 1, "Restore engine options after recreation")
        _expect(app.enhancement_applications == launch + 1, "Restore frame effects after recreation")

    player.destroy_engine()
    player.initialization_succeeds = false
    _expect(not app._switch_runtime_player(runtime_kind), "Report reinitialization failure before launch")
    _expect(not player.is_initialized(), "A failed initialization stays unavailable")
    _expect(app.backend_applications == 3, "Do not configure a failed engine")
    player.initialization_succeeds = true
    _expect(app._switch_runtime_player(runtime_kind), "Allow retry after reinitialization failure")
    _expect(player.is_initialized(), "Retry recreates the engine")
    app.player = null
    app.ui_motion.free()
    app.free()
