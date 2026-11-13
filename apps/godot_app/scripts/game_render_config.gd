extends RefCounted
## Per-game rendering overrides; an empty primary value inherits the app setting.

const FILE_NAME := "aether_config.json"
const UPSCALE_ALGORITHMS := ["smooth", "linear", "nearest", "bicubic", "lanczos", "metalfx_spatial"]
const OUTPUT_RESOLUTION_DEFAULT := "1080p"
const OUTPUT_RESOLUTION_MODES := ["original", "1080p", "2k", "4k"]
const FRAME_ENHANCEMENT_KINDS := ["off", "preset", "custom"]
const FRAME_ENHANCEMENT_MODE_DEFAULT := "chain_soft"
const FRAME_ENHANCEMENT_MODES := [
    "chain_4k_max", "chain_lossless", "chain_ultra", "chain_detail",
    "chain_balanced", "chain_soft", "chain_light", "chain_basic",
]
const FRAME_ENHANCEMENT_PRESET_MODES := [
    "chain_4k_max", "chain_lossless", "chain_ultra", "chain_detail",
    "chain_balanced", "chain_soft", "chain_light", "chain_basic",
]
const FRAME_ENHANCEMENT_ALGORITHMS := [
    "anime4k_upscale_s", "anime4k_upscale_l", "anime4k_upscale_vl",
    "anime4k_restore_s", "anime4k_restore_soft_s", "anime4k_restore_soft_m",
    "anime4k_restore_l", "anime4k_restore_vl",
    "fsr1_easu", "fsr1_rcas", "bicubic", "lanczos", "fxaa",
    "ravu_lite_r2", "cunny_2x4c", "nnedi3_nns16",
]
const FRAME_ENHANCEMENT_ALGORITHM_LABELS := {
    "anime4k_upscale_s": "Anime4K Upscale S",
    "anime4k_upscale_l": "Anime4K Upscale L",
    "anime4k_upscale_vl": "Anime4K Upscale VL",
    "anime4k_restore_s": "Anime4K Restore S",
    "anime4k_restore_soft_s": "Anime4K Restore Soft S",
    "anime4k_restore_soft_m": "Anime4K Restore Soft M",
    "anime4k_restore_l": "Anime4K Restore L",
    "anime4k_restore_vl": "Anime4K Restore VL",
    "fsr1_easu": "FSR1 EASU",
    "fsr1_rcas": "FSR1 RCAS",
    "bicubic": "Bicubic",
    "lanczos": "Lanczos",
    "fxaa": "FXAA",
    "ravu_lite_r2": "RAVU-Lite R2",
    "cunny_2x4c": "CuNNy 2x4C",
    "nnedi3_nns16": "NNEDI3 nns16",
}
const FRAME_ENHANCEMENT_CUSTOM_DEFAULT := [
    "anime4k_upscale_s", "bicubic", "anime4k_restore_soft_s",
]
const FRAME_ENHANCEMENT_CUSTOM_MAX_STEPS := 32

const PRIMARY_OPTIONS := {
    "upscale_algorithm": UPSCALE_ALGORITHMS,
    "output_resolution": OUTPUT_RESOLUTION_MODES,
    "frame_enhancement_kind": FRAME_ENHANCEMENT_KINDS,
}

static func normalized(raw: Dictionary) -> Dictionary:
    var result := {}
    for key in PRIMARY_OPTIONS:
        var value = raw.get(key, "")
        result[key] = value if value is String and value in PRIMARY_OPTIONS[key] else ""
    var mode = raw.get("frame_enhancement_mode", FRAME_ENHANCEMENT_MODE_DEFAULT)
    result.frame_enhancement_mode = mode if mode is String and mode in FRAME_ENHANCEMENT_PRESET_MODES else FRAME_ENHANCEMENT_MODE_DEFAULT
    var chain = raw.get("frame_enhancement_custom_chain", FRAME_ENHANCEMENT_CUSTOM_DEFAULT)
    result.frame_enhancement_custom_chain = Array(chain) if valid_chain(chain) else FRAME_ENHANCEMENT_CUSTOM_DEFAULT.duplicate()
    return result

static func valid_chain(value) -> bool:
    if not (value is Array or value is PackedStringArray) or value.size() > FRAME_ENHANCEMENT_CUSTOM_MAX_STEPS:
        return false
    for algorithm in value:
        if not algorithm is String or algorithm not in FRAME_ENHANCEMENT_ALGORITHMS:
            return false
    return true

static func read(game_root: String) -> Dictionary:
    var path := game_root.path_join(FILE_NAME) if not game_root.is_empty() else ""
    var result := {"path": path, "error": OK, "document": {}, "rendering": normalized({})}
    if path.is_empty() or not FileAccess.file_exists(path):
        return result
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        result.error = FileAccess.get_open_error()
        return result
    if file.get_length() > 1024 * 1024:
        result.error = ERR_INVALID_DATA
        return result
    var json := JSON.new()
    var error := json.parse(file.get_as_text())
    if error != OK or not json.data is Dictionary:
        result.error = ERR_PARSE_ERROR
        return result
    result.document = json.data
    var rendering = json.data.get("rendering", {})
    if not rendering is Dictionary:
        result.error = ERR_PARSE_ERROR
        return result
    result.rendering = normalized(rendering)
    return result

static func save(game_root: String, patch: Dictionary) -> Error:
    if game_root.is_empty() or not DirAccess.dir_exists_absolute(game_root):
        return ERR_FILE_BAD_PATH
    var loaded := read(game_root)
    if loaded.error != OK:
        # Never destroy an unreadable or malformed user-authored configuration.
        return loaded.error
    var document: Dictionary = loaded.document
    var rendering: Dictionary = document.get("rendering", {}).duplicate(true)
    for key in patch:
        var value = patch[key]
        if key in PRIMARY_OPTIONS:
            if not value is String or (not value.is_empty() and value not in PRIMARY_OPTIONS[key]):
                return ERR_INVALID_PARAMETER
        elif key == "frame_enhancement_mode":
            if not value is String or value not in FRAME_ENHANCEMENT_PRESET_MODES:
                return ERR_INVALID_PARAMETER
        elif key == "frame_enhancement_custom_chain":
            if not valid_chain(value):
                return ERR_INVALID_PARAMETER
            value = Array(value)
        else:
            return ERR_INVALID_PARAMETER
        rendering[key] = value
    for key in PRIMARY_OPTIONS:
        if not rendering.has(key):
            rendering[key] = ""
    # Persist the displayed defaults when explicitly opting into an effect.
    # Inherited effects ignore these values but retain them for later reuse.
    var settings := normalized(rendering)
    if patch.get("frame_enhancement_kind") == "preset":
        rendering.frame_enhancement_mode = settings.frame_enhancement_mode
    elif patch.get("frame_enhancement_kind") == "custom":
        rendering.frame_enhancement_custom_chain = settings.frame_enhancement_custom_chain
    document["rendering"] = rendering
    return write_document(loaded.path, document)

static func write_document(path: String, document: Dictionary) -> Error:
    var temporary := "%s.%d.%d.tmp" % [path, OS.get_process_id(), Time.get_ticks_usec()]
    var file := FileAccess.open(temporary, FileAccess.WRITE)
    if file == null:
        return FileAccess.get_open_error()
    file.store_string(JSON.stringify(document, "  ") + "\n")
    file.flush()
    var error := file.get_error()
    file.close()
    if error == OK:
        error = DirAccess.rename_absolute(temporary, path)
    if error != OK:
        DirAccess.remove_absolute(temporary)
    return error
