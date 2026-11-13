extends SceneTree
const Config = preload("res://scripts/game_text_config.gd")
const Render = preload("res://scripts/game_render_config.gd")

class RecordingPlayer extends Node:
    var options: Dictionary = {}
    func is_initialized() -> bool:
        return true
    func set_engine_option(key: String, value: String) -> void:
        options[key] = value

class Host extends "res://scripts/main.gd":
    func _ready() -> void:
        pass
    func _process(_delta: float) -> void:
        pass
    func _apply_diagnostic_profile_environment(_profile: String) -> void:
        pass

var failures := 0
func _initialize() -> void:
    call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)

func _write(path: String, text: String) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(text)
    file.close()

func _run() -> void:
    create_timer(45).timeout.connect(func():
        push_error("Game text config test timed out")
        quit(1)
    )
    var fixture := DirAccess.create_temp("aether-game-text")
    var root_a := fixture.get_current_dir().path_join("游戏 A")
    var root_b := fixture.get_current_dir().path_join("游戏 B")
    DirAccess.make_dir_recursive_absolute(root_a)
    DirAccess.make_dir_recursive_absolute(root_b)
    var path := root_a.path_join("aether_config.json")
    var legacy := {"path": root_a, "yurisScriptEncoding": "GBK", "rfvpEncoding": "utf8"}
    _expect(Config.read(root_a, "yuris", legacy).text.encoding == "GBK", "Existing library encoding remains available until explicitly reset")
    _expect(not FileAccess.file_exists(path), "Read does not create config files")
    var imported := Config.load_font("res://assets/fonts/Figtree-Regular.ttf")
    _expect(imported.error == OK and imported.font != null and not imported.data.is_empty(), "Validate real font bytes before import")
    _expect(not DirAccess.dir_exists_absolute(root_a.path_join("aether_fonts")), "Choosing a font does not write into the game")
    _write(path, JSON.stringify({"custom": 42, "rendering": {"output_resolution": "4k", "frame_enhancement_kind": "preset", "frame_enhancement_mode": "chain_light", "frame_enhancement_custom_chain": ["fxaa"]}, "text": {"future_option": "keep"}}))
    _expect(Config.save(root_a, "yuris", legacy, {"font_file": ""}, imported) == OK, "Import a validated TTF on Save")
    var saved := Config.read(root_a, "yuris", legacy)
    var relative: String = saved.text.font_file
    var actual := Config.font_path(root_a, relative)
    _expect(relative.begins_with("aether_fonts/") and relative.get_file() == "Figtree-Regular.ttf", "Font uses a portable relative path and retains its filename")
    _expect(FileAccess.get_file_as_bytes(actual) == imported.data, "Imported font bytes are unchanged")
    _expect(saved.text.encoding == "GBK" and saved.document.text.future_option == "keep" and saved.document.custom == 42, "Font save migrates legacy encoding and preserves unrelated fields")
    _expect(saved.document.rendering.output_resolution == "4k", "Font save preserves per-game rendering")
    _expect(saved.document.rendering.frame_enhancement_mode == "chain_light" and not saved.document.rendering.has("frame_enhancement_custom_chain"), "Font save removes stale custom steps from preset configuration")
    _expect(Config.save(root_a, "yuris", legacy, {"font_file": relative}, imported) == OK, "Repeated font import reuses identical content")
    _expect(Config.read(root_a, "yuris").text.font_file == relative, "Repeated import retains the same path")
    _expect(Render.save(root_a, {"upscale_algorithm": "nearest"}) == OK, "Rendering can be saved after text settings")
    _expect(Config.read(root_a, "yuris").text.font_file == relative, "Rendering save preserves text settings")
    _expect(Config.save(root_a, "yuris", legacy, {"encoding": ""}) == OK, "Explicit automatic selection saves an empty string")
    _expect(Config.read(root_a, "yuris", legacy).text.encoding == "", "Explicit empty encoding supersedes legacy metadata")
    for engine in Config.ENGINES:
        _write(path, "{}")
        for encoding in Config.encodings(engine):
            _expect(Config.save(root_a, engine, {}, {"encoding": encoding}) == OK, engine + " supports " + encoding)
            _expect(Config.read(root_a, engine).text.encoding == encoding, "Selected encoding survives reload")
    _expect(Config.encodings("entisgls") == [""], "EntisGLS keeps its native Unicode encoding")
    _expect(Config.save(root_a, "entisgls", {}, {"encoding": "GBK"}) == ERR_INVALID_PARAMETER, "EntisGLS cannot corrupt native text with a byte decoder")
    _expect(Config.save(root_a, "entisgls", {}, {"font_file": ""}, imported) == OK, "EntisGLS supports a font override")
    _expect(Config.read(root_b, "entisgls").text == {"encoding": "", "font_file": ""}, "A second game inherits independently")
    _expect(Config.save(root_a, "entisgls", {}, {"font_file": ""}) == OK, "Restore the engine's default font")
    _expect(FileAccess.file_exists(actual), "Reset never deletes a previously imported font")
    _write(path, '{"text":{"font_file":"missing.ttf"}}')
    _expect(Config.save(root_a, "bgi", {}, {"font_file": ""}) == OK, "A missing font can be cleared in the UI")
    for bad_path in ["../outside.ttf", "/tmp/font.ttf", "C:/font.ttf", "folder\\font.ttf", "font.png"]:
        _expect(Config.save(root_a, "bgi", {}, {"font_file": bad_path}) == ERR_INVALID_PARAMETER, "Reject nonportable font path: " + bad_path)
    _write(root_b.path_join("fake.ttf"), "this is not a font")
    _expect(Config.load_font(root_b.path_join("fake.ttf")).error != OK, "Reject invalid font bytes")
    for malformed in ["{broken", "[]", '{"text":[]}', '{"text":{"encoding":true}}']:
        _write(path, malformed)
        _expect(Config.save(root_a, "bgi", {}, {"encoding": "GBK"}) != OK, "Invalid existing config is not overwritten")
        _expect(FileAccess.get_file_as_string(path) == malformed, "Preserve invalid file for correction")
    _write(path, "{}")
    _expect(Config.save(root_a, "kirikiri", {}, {"font_file": ""}) == ERR_INVALID_PARAMETER, "Only the selected engines expose these settings")
    var failed_root := fixture.get_current_dir().path_join("failed-save")
    DirAccess.make_dir_recursive_absolute(failed_root.path_join("aether_config.json"))
    _expect(Config.save(failed_root, "bgi", {}, {"font_file": ""}, imported) != OK, "An unwritable JSON destination reports failure")
    _expect(not FileAccess.file_exists(failed_root.path_join(relative)), "A failed JSON write removes the newly imported font")
    _expect(DirAccess.dir_exists_absolute(failed_root.path_join("aether_config.json")), "Failed save preserves the existing destination")

    var host := Host.new()
    var player := RecordingPlayer.new()
    host.player = player
    host.add_child(player)
    host.add_child(host.ui_motion)
    root.add_child(host)
    host.runtime_default_font_path = "/app/default.ttf"
    host.runtime_font_dir_path = "/app/fonts"
    host.current_player_runtime_kind = "rfvp"
    host.selected_game = legacy
    _expect(Config.save(root_a, "rfvp", legacy, {"encoding": "GBK"}) == OK, "RFVP explicit encoding fixture")
    host._apply_engine_options()
    _expect(player.options.rfvp_encoding == "gbk" and player.options.rfvp_config_root == root_a, "RFVP startup receives selected library root and encoding")
    _expect(player.options.default_font == "/app/default.ttf", "Startup receives the base font fallback")
    host.game_running = true
    player.options.clear()
    host._apply_engine_options()
    _expect(not player.options.has("default_font") and not player.options.has("font_dir"), "Applying live settings cannot overwrite native per-game fonts")
    host.game_running = false
    host.game_render_root = root_b
    host._apply_engine_options()
    _expect(player.options.rfvp_encoding == "sjis" and player.options.rfvp_config_root == root_b, "A direct launch ignores metadata from a different selected game")
    host.selected_game = {"path": root_b}
    host._apply_engine_options()
    _expect(player.options.rfvp_encoding == "sjis" and player.options.rfvp_config_root == root_b, "Next game's default encoding and root replace prior launch options")
    host.queue_free()
    await process_frame
    fixture = null
    print("GAME_TEXT_CONFIG_OK" if failures == 0 else "GAME_TEXT_CONFIG_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
