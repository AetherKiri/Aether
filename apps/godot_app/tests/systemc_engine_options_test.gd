extends SceneTree

const Options = preload("res://scripts/systemc_engine_options.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
const Mapping = preload("res://scripts/game_input_mapping.gd")

func _init() -> void:
    assert(Options.script_encoding({}) == "AUTO")
    var game := {Options.SCRIPT_ENCODING_FIELD: "GBK"}
    assert(Options.script_encoding(game) == "GBK")
    assert(Options.script_encoding(game, " cp932 ") == "CP932")
    assert(Options.script_encoding(game, "invalid") == "GBK")
    assert(Options.script_encoding({Options.SCRIPT_ENCODING_FIELD: "invalid"}) == "AUTO")
    var first := Options.user_directory("/host", "/games/first")
    assert(first == Options.user_directory("/host", "/games/other/../first"))
    assert(first != Options.user_directory("/host", "/games/second"))
    assert(Options.cache_directory("/host", "/games/first") == first.path_join("cache"))
    assert(Launch.runtime_uses_directory("systemc"))
    assert(Launch.resolve_for_runtime({"path": "/games/first", "launchFile": "game.exe"}, "systemc") == "/games/first")
    assert(Mapping.input_surface_size("systemc", Vector2(800, 600), Vector2(1920, 1080)) == Vector2(800, 600))
    print("SYSTEMC_OPTIONS_OK")
    quit()
