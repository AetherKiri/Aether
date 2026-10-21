extends RefCounted

const FIELD := "launchFile"
const SUPPORTED_EXTENSIONS := ["exe", "xp3", "hcb"]
const DIRECTORY_RUNTIME_KINDS := [
    "advhd",
    "renpy",
    "artemis",
    "bgi",
    "catsystem2",
    "mages",
    "minori",
    "onscripter",
    "yuris",
    "siglus",
    "softpal",
    "tyranoscript",
    "wa2",
    "xsystem4",
]
const YURIS_USER_STARTUP_CANDIDATES := [
    # The stock YU-RIS package enters through this script. It owns the
    # vendor logo/fade and title screen; start.txt is the fallback for older
    # projects that expose only their feature menu.
    "data/script/UserScript/SCENARIO_START.txt",
    "data/script/UserScript/SCENARIO_START.yst",
    "data/script/userscript/SCENARIO_START.txt",
    "data/script/userscript/SCENARIO_START.yst",
    "data/script/UserScript/start.txt",
    "data/script/UserScript/start.yst",
    "data/script/userscript/start.txt",
    "data/script/userscript/start.yst",
]
const RFVP_ENCODING_FIELD := "rfvpEncoding"
const RFVP_ENCODINGS := ["sjis", "gbk", "utf8"]


static func rfvp_encoding(game: Dictionary, override_value: String = "") -> String:
    var override_encoding := override_value.strip_edges().to_lower()
    if RFVP_ENCODINGS.has(override_encoding):
        return override_encoding
    var saved := String(game.get(RFVP_ENCODING_FIELD, "sjis")).strip_edges().to_lower()
    return saved if RFVP_ENCODINGS.has(saved) else "sjis"


static func backfill(game: Dictionary, metadata: Dictionary) -> bool:
    var changed := false
    if not game.has(FIELD) and metadata.has(FIELD):
        game[FIELD] = metadata[FIELD]
        changed = true
    # Keep the encoding paired with the selected script. Existing keys,
    # including an empty automatic choice, belong to the user.
    if not game.has(RFVP_ENCODING_FIELD) and metadata.has(RFVP_ENCODING_FIELD):
        if String(game.get(FIELD, "")).is_empty() or game.get(FIELD) == metadata.get(FIELD):
            game[RFVP_ENCODING_FIELD] = metadata[RFVP_ENCODING_FIELD]
            changed = true
    return changed


static func configured_relative_path(game: Dictionary) -> String:
    var relative_path := _normalize_path(String(game.get(FIELD, "")))
    if relative_path.strip_edges().is_empty() or relative_path.is_absolute_path():
        return ""
    relative_path = relative_path.simplify_path()
    if relative_path == "." or relative_path == ".." or relative_path.begins_with("../"):
        return ""
    if not is_supported_file(relative_path):
        return ""
    return relative_path


static func resolve(game: Dictionary) -> String:
    # Whitespace is legal at either end of a POSIX path.  Library paths come
    # from the native picker and must remain byte-for-byte intact.
    var game_path := _normalize_path(String(game.get("path", "")))
    var relative_path := configured_relative_path(game)
    if game_path.is_empty() or relative_path.is_empty():
        return game_path
    return game_path.path_join(relative_path).simplify_path()


static func resolve_for_runtime(
    game: Dictionary, runtime_kind: String, requires_game_root: bool = false
) -> String:
    # Runtime providers and directory-based runtimes consume the game root. A
    # selected EXE/XP3 is only a legacy KiriKiri entry point and must not
    # replace the root passed to a provider probe/open pair.
    if requires_game_root or runtime_uses_directory(runtime_kind):
        # Preserve valid trailing spaces from native file-picker paths.
        return _normalize_path(String(game.get("path", "")))
    return resolve(game)


static func runtime_uses_directory(runtime_kind: String) -> bool:
    return DIRECTORY_RUNTIME_KINDS.has(runtime_kind.to_lower())


static func default_yuris_startup_script(game_root: String) -> String:
    # YU-RIS projects conventionally expose their first interactive screen as
    # data/script/UserScript/start.txt.  The native engine's SYSTEM_START
    # bootstrap is useful for authored games, but the stock system demo is
    # entered through this UserScript menu.  Keep this discovery here so the
    # headful launcher and probes share the same path convention without
    # hard-coding a particular package.
    var root := _normalize_path(game_root)
    if root.is_empty():
        return ""
    for relative_path in YURIS_USER_STARTUP_CANDIDATES:
        var candidate := root.path_join(relative_path)
        if FileAccess.file_exists(candidate):
            return candidate
    return ""


static func is_supported_file(path: String) -> bool:
    return SUPPORTED_EXTENSIONS.has(path.get_extension().to_lower())


static func relative_path_for_selection(game_path: String, selected_path: String) -> String:
    var root := _normalize_path(game_path).simplify_path().trim_suffix("/")
    var selected := _normalize_path(selected_path).simplify_path()
    if root.strip_edges().is_empty() or selected.strip_edges().is_empty() or not is_supported_file(selected):
        return ""
    var root_prefix := root + "/"
    if not selected.begins_with(root_prefix):
        return ""
    var relative_path := selected.substr(root_prefix.length())
    if relative_path.is_empty() or relative_path == ".." or relative_path.begins_with("../"):
        return ""
    return relative_path


static func _normalize_path(path: String) -> String:
    return path.replace("\\", "/")
