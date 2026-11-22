extends RefCounted

const SaveStorage := preload("res://scripts/game_save_storage.gd")

# A stock ERIS effect pass must finish in one host frame. Smaller slices
# break WA(1)'s queued-load ordering and publish camera motion intermittently.
const DEFAULT_WORKER_STEP_BUDGET := 65536
const SCRIPT_ENCODING_FIELD := "yurisScriptEncoding"
const SCRIPT_ENCODINGS := ["AUTO"] + preload("res://scripts/game_text_config.gd").BYTE_ENCODINGS
const MIGRATION_MARKER := ".aether-yuris-migrated"

static func user_directory(base: String, project_root: String) -> String:
    return SaveStorage.prefer_local(project_root, legacy_user_directory(base, project_root), MIGRATION_MARKER, ["cache"])

static func legacy_user_directory(base: String, project_root: String) -> String:
    var identity := project_root.strip_edges().simplify_path().trim_suffix("/")
    if identity.is_empty():
        return base
    # ERIS uses the same gsd.sd/save00001.sd names in unrelated games.
    return base.path_join("yuris").path_join(identity.sha256_text())

static func cache_directory(base: String, project_root: String) -> String:
    # Extracted resources are disposable and must not travel with game saves.
    return legacy_user_directory(base, project_root).path_join("cache")

static func script_encoding(game: Dictionary, override: String = "") -> String:
    var requested := normalize_encoding(override)
    if not requested.is_empty():
        return requested
    var saved := normalize_encoding(String(game.get(SCRIPT_ENCODING_FIELD, "")))
    return "AUTO" if saved.is_empty() else saved

static func normalize_encoding(value: String) -> String:
    var encoding := value.strip_edges().to_upper().replace("_", "-")
    if encoding in SCRIPT_ENCODINGS:
        return encoding
    match encoding:
        "SJIS", "SHIFT-JIS", "SHIFTJIS": return "CP932"
        "CP936": return "GBK"
        "UHC", "WINDOWS-949": return "CP949"
        "BIG-5", "CP950": return "BIG5"
        "UTF8": return "UTF-8"
    return ""

static func worker_step_budget(override: String = "") -> int:
    var value := override.strip_edges()
    if not value.is_valid_int():
        return DEFAULT_WORKER_STEP_BUDGET
    return clampi(value.to_int(), 256, DEFAULT_WORKER_STEP_BUDGET)
