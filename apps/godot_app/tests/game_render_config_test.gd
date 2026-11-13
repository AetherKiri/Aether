extends SceneTree
## Disk round trips and the real launch path, with a recording runtime boundary.
const Config = preload("res://scripts/game_render_config.gd")

class RecordingPlayer extends Node:
    var algorithm := ""
    var native_output := false
    var mode := ""
    var enabled := false
    var chain := PackedStringArray()
    var surface := Vector2i.ZERO
    var opened: Array[Dictionary] = []
    var open_result := 0
    func set_frame_upscale_algorithm(value: String) -> void:
        algorithm = value
    func get_frame_upscale_status() -> Dictionary:
        return {"active": false}
    func set_frame_native_output_enabled(value: bool) -> void:
        native_output = value
    func set_frame_enhancement_mode(value: String) -> void:
        mode = value
    func set_frame_enhancement_enabled(value: bool) -> void:
        enabled = value
    func set_frame_enhancement_custom_chain(value: PackedStringArray) -> void:
        chain = value
    func set_surface_size(width: int, height: int) -> int:
        surface = Vector2i(width, height)
        return 0
    func open_game(path: String, _async: bool, _startup: String) -> int:
        opened.append({"path": path, "algorithm": algorithm, "native": native_output,
            "mode": mode, "enabled": enabled, "chain": chain.duplicate(), "surface": surface})
        return open_result
    func get_last_result() -> String:
        return "recorded failure"
    func get_last_error() -> String:
        return "recorded failure"

class LaunchHost:
    extends "res://scripts/main.gd"
    var switch_ok := true
    var initialize_ok := true
    func _ready() -> void:
        pass
    func _process(_delta: float) -> void:
        pass
    func _require_legal_documents_for_media() -> bool:
        return true
    func _game_runtime_kind(_path: String) -> String:
        return RUNTIME_KIRIKIRI
    func _switch_runtime_player(_kind: String) -> bool:
        return switch_ok
    func _ensure_player_initialized() -> bool:
        return initialize_ok
    func _load_button_position_memory(_path: String) -> void:
        pass
    func _apply_backend(_log_selection: bool) -> void:
        pass
    func _apply_engine_options() -> void:
        pass
    func _set_game_runtime_frame_pacing(_active: bool) -> void:
        pass
    func _clear_game_input_capture() -> void:
        pass
    func _write_probe_marker(_line: String) -> void:
        pass
    func _append_log(line: String) -> void:
        log_lines.append(line)

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _write(path: String, value: String) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(value)
    file.close()

func _run() -> void:
    var fixture := DirAccess.create_temp("aether-game-render")
    var base := fixture.get_current_dir()
    var game_a := base.path_join("游戏 A")
    var game_b := base.path_join("游戏 B")
    DirAccess.make_dir_recursive_absolute(game_a.path_join("data"))
    DirAccess.make_dir_recursive_absolute(game_b)
    var path := game_a.path_join(Config.FILE_NAME)
    var entry := game_a.path_join("data/start.xp3")
    _write(entry, "launch fixture")
    var defaults := Config.read(game_a)
    _expect(defaults.error == OK and defaults.rendering.upscale_algorithm == "", "Missing file inherits settings")
    _expect(not FileAccess.file_exists(path), "Reading does not create a game config")
    _expect(Config.save(base.path_join("missing"), {"output_resolution": "4k"}) == ERR_FILE_BAD_PATH, "Saving never creates missing game directories")
    _write(path, JSON.stringify({"name": "保留", "rendering": {"future_option": 7}}))
    _expect(Config.save(game_a, {"upscale_algorithm": "nearest"}) == OK, "Save a partial override")
    var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
    _expect(document.name == "保留" and document.rendering.future_option == 7, "Preserve unrelated user keys")
    _expect(document.rendering.output_resolution == "" and document.rendering.frame_enhancement_kind == "", "Unspecified fields serialize as empty strings")
    var original := FileAccess.get_file_as_string(path)
    _expect(Config.save(game_a, {"upscale_algorithm": "unknown"}) == ERR_INVALID_PARAMETER, "Reject unsupported writes")
    _expect(Config.save(game_a, {"output_resolution": 42}) == ERR_INVALID_PARAMETER, "Reject wrongly typed writes")
    _expect(FileAccess.get_file_as_string(path) == original, "Invalid writes leave the file intact")
    _expect(Config.save(game_a, {"frame_enhancement_kind": "custom"}) == OK, "Select custom enhancement")
    document = JSON.parse_string(FileAccess.get_file_as_string(path))
    _expect(document.rendering.frame_enhancement_custom_chain == Config.FRAME_ENHANCEMENT_CUSTOM_DEFAULT, "Displayed custom defaults are persisted")
    _expect(Config.save(game_a, {"frame_enhancement_custom_chain": []}) == OK, "An explicitly empty custom chain is valid")
    _expect(Config.read(game_a).rendering.frame_enhancement_custom_chain.is_empty(), "Empty chain survives reload")
    _expect(Config.save(game_a, {"frame_enhancement_kind": "preset", "frame_enhancement_mode": "chain_light"}) == OK, "Preset selection round trips")
    document = JSON.parse_string(FileAccess.get_file_as_string(path))
    _expect(document.rendering.frame_enhancement_mode == "chain_light" and not document.rendering.has("frame_enhancement_custom_chain"), "Switching Custom to Preset stores only the preset selection")
    _expect(Config.save(game_a, {"frame_enhancement_kind": "preset", "frame_enhancement_custom_chain": ["fxaa"]}) == OK, "Accept a preset with an inactive custom draft")
    document = JSON.parse_string(FileAccess.get_file_as_string(path))
    _expect(not document.rendering.has("frame_enhancement_custom_chain"), "Inactive custom drafts never reach a preset file")
    document.rendering.frame_enhancement_custom_chain = ["lanczos"]
    _write(path, JSON.stringify(document))
    var legacy_preset := FileAccess.get_file_as_string(path)
    Config.read(game_a)
    _expect(FileAccess.get_file_as_string(path) == legacy_preset, "Reading an old preset does not silently rewrite user files")
    _expect(Config.save(game_a, {"output_resolution": "2k"}) == OK, "Save another setting in an old preset file")
    document = JSON.parse_string(FileAccess.get_file_as_string(path))
    _expect(not document.rendering.has("frame_enhancement_custom_chain") and document.rendering.frame_enhancement_mode == "chain_light", "Any successful save removes a stale preset chain and retains its preset")
    _expect(document.name == "保留" and document.rendering.future_option == 7, "Preset cleanup preserves unrelated values")
    for invalid in ["{broken", "[]", "{\"rendering\": []}"]:
        _write(path, invalid)
        _expect(Config.read(game_a).error == ERR_PARSE_ERROR, "Report malformed configuration")
        _expect(Config.save(game_a, {"output_resolution": "4k"}) == ERR_PARSE_ERROR, "Do not overwrite malformed configuration")
        _expect(FileAccess.get_file_as_string(path) == invalid, "Malformed content is preserved verbatim")
    _write(path, JSON.stringify({"rendering": {"upscale_algorithm": 1, "output_resolution": "8k", "frame_enhancement_kind": null,
        "frame_enhancement_mode": "unsupported", "frame_enhancement_custom_chain": ["invalid"]}}))
    var normalized := Config.read(game_a).rendering as Dictionary
    _expect(normalized.upscale_algorithm == "" and normalized.output_resolution == "" and normalized.frame_enhancement_kind == "", "Invalid primary fields inherit independently")
    _expect(normalized.frame_enhancement_mode == "chain_soft" and normalized.frame_enhancement_custom_chain == Config.FRAME_ENHANCEMENT_CUSTOM_DEFAULT, "Invalid enhancement detail has a safe local default")
    _write(path, "{}")

    var host := LaunchHost.new()
    var player := RecordingPlayer.new()
    host.player = player
    host.add_child(player)
    host.game_path = LineEdit.new()
    host.add_child(host.game_path)
    host.restart_notice = Label.new()
    host.add_child(host.restart_notice)
    host.viewport = TextureRect.new()
    host.add_child(host.viewport)
    host.add_child(host.ui_motion)
    host.upscale_algorithm = "bicubic"
    host.output_resolution = "1080p"
    host.frame_enhancement_kind = "preset"
    host.frame_enhancement_mode = "chain_balanced"
    host.frame_enhancement_enabled = true
    host.render_surface_base_size = Vector2i(1280, 720)
    root.add_child(host)
    var global_snapshot: Dictionary = host._current_settings_snapshot()
    host.selected_game = {"path": game_a}
    host.game_path.text = entry
    _expect(Config.save(game_a, {"upscale_algorithm": "nearest", "output_resolution": "4k", "frame_enhancement_kind": "off"}) == OK, "Write game A overrides")
    # A nested entry must read the library root, not data/aether_config.json.
    host._on_open_game()
    _expect(host.game_render_root == game_a, "Configured nested launch files use their library game root")
    _expect(player.opened.size() == 1, "Real launch path reaches open_game")
    _expect(player.opened[-1].surface == Vector2i(3840, 2160) and not player.opened[-1].enabled, "Output and enhancement apply before open_game")
    _expect(host.viewport.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST and host.viewport.material == null, "Game scaling controls actual presentation sampling")
    host.last_source_texture_size = Vector2i(1024, 768)
    _expect(host._frame_enhancement_target_size() == Vector2i(2880, 2160), "Override controls later frame targets without stretching aspect ratio")
    _expect(host._current_settings_snapshot() == global_snapshot, "Launching never writes overrides into global settings")
    host._finalize_active_game_session()
    _expect(host.game_render_overrides.is_empty(), "Session teardown clears overrides even without a library session timer")
    host.game_running = false
    host.selected_game = {"path": game_b}
    host.game_path.text = game_b
    host._on_open_game()
    _expect(player.opened[-1].surface == Vector2i(1920, 1080) and player.opened[-1].enabled and player.opened[-1].mode == "chain_balanced", "Next game inherits global settings, not game A")
    _expect(host.viewport.material == host._resampling_frame_material("bicubic"), "Next game restores global sampling")
    _expect(not FileAccess.file_exists(game_b.path_join(Config.FILE_NAME)), "Starting an unconfigured game does not create a config")

    host.selected_game = {"path": game_a}
    host.game_path.text = entry
    _expect(Config.save(game_a, {"upscale_algorithm": "metalfx_spatial", "output_resolution": "original", "frame_enhancement_kind": "custom", "frame_enhancement_custom_chain": ["fxaa", "lanczos"]}) == OK, "Write native scaling and custom chain")
    host._on_open_game()
    _expect(player.opened[-1].algorithm == "metalfx_spatial" and player.opened[-1].native and player.opened[-1].surface == Vector2i(1280, 720), "Native scaling and original output reach runtime before launch")
    _expect(player.opened[-1].enabled and player.opened[-1].mode == "custom" and player.opened[-1].chain == PackedStringArray(["fxaa", "lanczos"]), "Runtime receives the ordered per-game chain")
    _expect(Config.save(game_a, {"output_resolution": "", "frame_enhancement_kind": "preset", "frame_enhancement_mode": "chain_light"}) == OK, "Choose an independent preset with inherited resolution")
    host._on_open_game()
    _expect(player.opened[-1].surface == Vector2i(1920, 1080) and player.opened[-1].mode == "chain_light", "Each primary setting overrides independently")
    _expect(Config.save(game_a, {"upscale_algorithm": "", "output_resolution": "", "frame_enhancement_kind": ""}) == OK, "Reset selections to inheritance")
    document = JSON.parse_string(FileAccess.get_file_as_string(path))
    _expect(document.rendering.upscale_algorithm == "" and document.rendering.frame_enhancement_kind == "", "Follow app serializes as empty strings")
    host.frame_enhancement_kind = "custom"
    host.frame_enhancement_custom_chain = PackedStringArray(["fsr1_rcas"])
    host.output_resolution = "2k"
    host._on_open_game()
    _expect(player.opened[-1].surface == Vector2i(2560, 1440) and player.opened[-1].chain == PackedStringArray(["fsr1_rcas"]), "Inheritance observes newly changed globals and ignores retained local enhancement details")

    _write(path, "broken")
    host._on_open_game()
    _expect(player.opened[-1].surface == Vector2i(2560, 1440), "Malformed config falls back to global settings without preventing launch")
    _write(path, "{}")
    Config.save(game_a, {"output_resolution": "4k", "frame_enhancement_kind": "off"})
    host.game_running = false
    player.open_result = 1
    host._on_open_game()
    _expect(host.game_render_overrides.is_empty() and not host.game_running, "Failed launch discards the game override")
    _expect(player.enabled and player.mode == "custom", "Failed launch restores global rendering configuration")
    player.open_result = 0
    host.switch_ok = false
    host._on_open_game()
    _expect(host.game_render_overrides.is_empty(), "Runtime selection failure discards overrides")
    host.switch_ok = true
    host.initialize_ok = false
    host._on_open_game()
    _expect(host.game_render_overrides.is_empty(), "Engine initialization failure discards overrides")
    host.initialize_ok = true
    host.selected_game = {}
    host.game_path.text = entry
    _write(game_a.path_join("data/aether_config.json"), "{\"rendering\": {\"output_resolution\": \"original\"}}")
    host._on_open_game()
    _expect(host.game_render_root == entry.get_base_dir() and player.opened[-1].native, "Standalone file launch uses its containing directory")
    for filename in DirAccess.get_files_at(game_a):
        _expect(not filename.ends_with(".tmp"), "Atomic saves leave no temporary files")
    host.free()
    fixture = null
    if failures == 0:
        print("GAME_RENDER_CONFIG_OK")
    quit(0 if failures == 0 else 1)
