extends RefCounted
## Portable, explicitly selected covers live beside the game's configuration.
const Config = preload("res://scripts/game_render_config.gd")

static func read(root: String) -> Dictionary:
    var loaded := Config.read(root)
    var result := {"error": loaded.error, "configured": false, "path": "", "document": loaded.document}
    if loaded.error != OK or not loaded.document.has("cover"):
        return result
    var cover = loaded.document.cover
    if not cover is Dictionary or not cover.get("path") is String:
        result.error = ERR_INVALID_DATA
        return result
    var relative: String = cover.path
    if not relative.is_empty() and (relative.is_absolute_path() or relative.contains(":") or relative.contains("\\") or ".." in relative.split("/")):
        result.error = ERR_INVALID_DATA
        return result
    result.configured = true
    result.path = root.path_join(relative).simplify_path() if not relative.is_empty() else ""
    return result

static func save_image(root: String, image: Image, source: String, vndb_id: String = "") -> Dictionary:
    var result := {"error": OK, "path": ""}
    if root.is_empty() or not DirAccess.dir_exists_absolute(root):
        result.error = ERR_FILE_BAD_PATH
        return result
    if image == null or image.is_empty():
        result.error = ERR_INVALID_DATA
        return result
    var loaded := read(root)
    if loaded.error != OK:
        result.error = loaded.error
        return result
    var bytes := image.save_png_to_buffer()
    if bytes.is_empty():
        result.error = ERR_INVALID_DATA
        return result
    var hash := HashingContext.new()
    hash.start(HashingContext.HASH_SHA256)
    hash.update(bytes)
    var relative := "aether-cover-%s.png" % hash.finish().hex_encode().substr(0, 16)
    var destination := root.path_join(relative)
    var created := not FileAccess.file_exists(destination)
    if created:
        var temporary := "%s.%d.tmp" % [destination, Time.get_ticks_usec()]
        var file := FileAccess.open(temporary, FileAccess.WRITE)
        if file == null:
            result.error = FileAccess.get_open_error()
            return result
        file.store_buffer(bytes)
        file.flush()
        result.error = file.get_error()
        file.close()
        if result.error == OK:
            result.error = DirAccess.rename_absolute(temporary, destination)
        if result.error != OK:
            DirAccess.remove_absolute(temporary)
            return result
    elif FileAccess.get_file_as_bytes(destination) != bytes:
        # Never overwrite a user's file that happens to have the same name.
        result.error = ERR_ALREADY_EXISTS
        return result
    var document: Dictionary = loaded.document
    var cover: Dictionary = document.get("cover", {}).duplicate(true)
    cover.merge({"path": relative, "source": source, "vndb_id": vndb_id}, true)
    document.cover = cover
    result.error = Config.write_document(root.path_join(Config.FILE_NAME), document)
    if result.error != OK:
        if created:
            DirAccess.remove_absolute(destination)
        return result
    result.path = destination
    return result

static func clear(root: String) -> Error:
    var loaded := read(root)
    if loaded.error != OK:
        return loaded.error
    if not loaded.configured:
        return OK
    var document: Dictionary = loaded.document
    document.cover.merge({"path": "", "source": "", "vndb_id": ""}, true)
    return Config.write_document(root.path_join(Config.FILE_NAME), document)
