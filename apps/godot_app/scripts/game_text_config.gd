extends RefCounted
## Per-game text settings, shared by the detail editor and native startup.
const Config = preload("res://scripts/game_render_config.gd")
const ENGINES := ["onscripter", "yuris", "systemc", "rfvp", "bgi", "advhd", "escude", "softpal", "catsystem2", "entisgls"]
const FONT_LIMIT := 32 * 1024 * 1024
const FONT_DIRECTORY := "aether_fonts"

static func encodings(runtime: String) -> Array:
    if runtime == "entisgls" or runtime not in ENGINES:
        return [""]
    if runtime in ["onscripter", "rfvp"]:
        return ["", "CP932", "GBK", "UTF-8"]
    return ["", "CP932", "GBK", "GB18030", "BIG5", "UTF-8"]

static func legacy_encoding(game: Dictionary, runtime: String) -> String:
    var value := ""
    match runtime:
        "yuris": value = String(game.get("yurisScriptEncoding", ""))
        "systemc": value = String(game.get("systemcScriptEncoding", ""))
        "rfvp": value = String(game.get("rfvpEncoding", ""))
    match value.to_upper():
        "SJIS", "SHIFT-JIS", "CP932": return "CP932"
        "UTF8", "UTF-8": return "UTF-8"
        "GBK", "CP936": return "GBK"
        "GB18030": return "GB18030"
        "BIG5", "CP950": return "BIG5"
    return ""

static func valid_font_path(relative: String) -> bool:
    if relative.is_empty():
        return true
    if relative.is_absolute_path() or ":" in relative or "\\" in relative or relative.to_utf8_buffer().has(0):
        return false
    if ".." in relative.split("/"):
        return false
    return relative.get_extension().to_lower() in ["ttf", "otf"]

static func read(root: String, runtime: String, game: Dictionary = {}) -> Dictionary:
    var loaded := Config.read(root)
    loaded["text"] = {"encoding": legacy_encoding(game, runtime), "font_file": ""}
    if loaded.error != OK:
        return loaded
    var raw = loaded.document.get("text", {})
    if not raw is Dictionary:
        loaded.error = ERR_PARSE_ERROR
        return loaded
    for key in ["encoding", "font_file"]:
        if raw.has(key):
            if not raw[key] is String:
                loaded.error = ERR_PARSE_ERROR
                return loaded
            loaded.text[key] = raw[key]
    if loaded.text.encoding not in encodings(runtime) or not valid_font_path(loaded.text.font_file):
        loaded.error = ERR_INVALID_DATA
    return loaded

static func font_path(root: String, relative: String) -> String:
    if relative.is_empty() or not valid_font_path(relative):
        return ""
    var parent := root
    for part in relative.split("/", false):
        var directory := DirAccess.open(parent)
        if directory == null or directory.is_link(part):
            return ""
        parent = parent.path_join(part)
    return parent if FileAccess.file_exists(parent) else ""

static func load_font(path: String) -> Dictionary:
    var result := {"error": ERR_FILE_UNRECOGNIZED, "font": null, "data": PackedByteArray(), "extension": path.get_extension().to_lower(), "name": path.get_file()}
    if result.extension not in ["ttf", "otf"]:
        return result
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        result.error = FileAccess.get_open_error()
        return result
    if file.get_length() < 12 or file.get_length() > FONT_LIMIT:
        return result
    if file.get_buffer(4).hex_encode() not in ["00010000", "4f54544f", "74727565"]:
        return result
    var font := FontFile.new()
    var error := font.load_dynamic_font(path)
    if error != OK or font.get_supported_chars().is_empty():
        return result
    result.error = OK
    result.font = font
    result.data = font.data
    return result

static func save(root: String, runtime: String, game: Dictionary, patch: Dictionary, imported: Dictionary = {}) -> Error:
    if runtime not in ENGINES or not DirAccess.dir_exists_absolute(root):
        return ERR_INVALID_PARAMETER
    var loaded := read(root, runtime, game)
    if loaded.error != OK:
        return loaded.error
    var text_settings: Dictionary = loaded.document.get("text", {}).duplicate(true)
    for key in ["encoding", "font_file"]:
        if not text_settings.has(key):
            text_settings[key] = loaded.text[key]
    for key in patch:
        if key not in ["encoding", "font_file"] or not patch[key] is String:
            return ERR_INVALID_PARAMETER
        text_settings[key] = patch[key]
    if text_settings.encoding not in encodings(runtime) or not valid_font_path(text_settings.font_file):
        return ERR_INVALID_PARAMETER
    var created := ""
    if not imported.is_empty():
        if not patch.has("font_file") or imported.get("error", FAILED) != OK or not imported.get("data") is PackedByteArray:
            return ERR_INVALID_DATA
        var bytes: PackedByteArray = imported.data
        if bytes.is_empty() or bytes.size() > FONT_LIMIT or imported.get("extension", "") not in ["ttf", "otf"]:
            return ERR_INVALID_DATA
        var hash := HashingContext.new()
        hash.start(HashingContext.HASH_SHA256)
        hash.update(bytes)
        var name := String(imported.get("name", ""))
        if name.is_empty() or "/" in name or not valid_font_path(name):
            return ERR_INVALID_DATA
        # Keep the original filename readable; the content hash separates
        # different fonts with the same name and makes repeated imports stable.
        var subdirectory := FONT_DIRECTORY.path_join(hash.finish().hex_encode())
        var relative := subdirectory.path_join(name)
        var directory := DirAccess.open(root)
        if directory.is_link(FONT_DIRECTORY):
            return ERR_FILE_BAD_PATH
        if DirAccess.dir_exists_absolute(root.path_join(FONT_DIRECTORY)) and DirAccess.open(root.path_join(FONT_DIRECTORY)).is_link(subdirectory.get_file()):
            return ERR_FILE_BAD_PATH
        var error := DirAccess.make_dir_recursive_absolute(root.path_join(subdirectory))
        if error != OK:
            return error
        var destination := root.path_join(relative)
        if DirAccess.open(root.path_join(subdirectory)).is_link(name):
            return ERR_FILE_BAD_PATH
        if FileAccess.file_exists(destination):
            if font_path(root, relative).is_empty() or FileAccess.get_file_as_bytes(destination) != bytes:
                return ERR_FILE_CORRUPT
        else:
            var file := FileAccess.open(destination, FileAccess.WRITE)
            if file == null:
                return FileAccess.get_open_error()
            file.store_buffer(bytes)
            file.flush()
            error = file.get_error()
            file.close()
            if error != OK:
                DirAccess.remove_absolute(destination)
                return error
            created = destination
        text_settings.font_file = relative
    elif not text_settings.font_file.is_empty() and font_path(root, text_settings.font_file).is_empty():
        return ERR_FILE_NOT_FOUND
    loaded.document["text"] = text_settings
    var saved := Config.write_document(loaded.path, loaded.document)
    if saved != OK and not created.is_empty():
        DirAccess.remove_absolute(created)
    return saved
