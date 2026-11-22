extends RefCounted

const SCRIPT_ENCODING_FIELD := "systemcScriptEncoding"
const SCRIPT_ENCODINGS := ["AUTO"] + preload("res://scripts/game_text_config.gd").BYTE_ENCODINGS

static func script_encoding(game: Dictionary, override: String = "") -> String:
    var requested := override.strip_edges().to_upper()
    if requested in SCRIPT_ENCODINGS:
        return requested
    var saved := String(game.get(SCRIPT_ENCODING_FIELD, "AUTO")).to_upper()
    return saved if saved in SCRIPT_ENCODINGS else "AUTO"

static func user_directory(base: String, game_root: String) -> String:
    return base.path_join("systemc_games").path_join(game_root.simplify_path().sha256_text().substr(0, 24))

static func cache_directory(base: String, game_root: String) -> String:
    return preload("res://scripts/game_cache.gd").directory(base, game_root)
