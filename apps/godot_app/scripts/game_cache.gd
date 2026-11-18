extends RefCounted

const Storage := preload("res://scripts/game_library_storage.gd")

static func directory(base: String, game_root: String) -> String:
    return base.path_join("cache/games").path_join(game_root.simplify_path().trim_suffix("/").sha256_text())

static func paths(base: String, game_root: String, engine: String) -> PackedStringArray:
    var root := game_root.simplify_path().trim_suffix("/")
    if root.is_empty():
        return PackedStringArray()
    var result := PackedStringArray([directory(base, root)])
    # Previous versions placed these disposable banks outside the common cache.
    match engine:
        "yuris":
            result.append(base.path_join("yuris").path_join(root.sha256_text()).path_join("cache"))
        "systemc":
            result.append(base.path_join("systemc_games").path_join(root.sha256_text().left(24)).path_join("cache"))
        "escude":
            result.append(base.path_join("cache/escude").path_join(root.sha256_text()))
        "tyranoscript":
            # ASAR preparation keys its output by the source archive, not by title.
            for relative in ["resources/app.asar", "app.asar"]:
                result.append(base.path_join("tyrano_cache").path_join(root.path_join(relative).sha256_text()))
    return result

static func _size(path: String) -> Dictionary:
    var parent := DirAccess.open(path.get_base_dir())
    if parent == null or parent.is_link(path.get_file()):
        return {"bytes": 0, "error": OK}
    if FileAccess.file_exists(path):
        var file := FileAccess.open(path, FileAccess.READ)
        return {"bytes": file.get_length() if file != null else 0, "error": OK if file != null else FileAccess.get_open_error()}
    if not DirAccess.dir_exists_absolute(path):
        return {"bytes": 0, "error": OK}
    var dir := DirAccess.open(path)
    if dir == null:
        return {"bytes": 0, "error": DirAccess.get_open_error()}
    dir.include_hidden = true
    var total := 0
    var error := dir.list_dir_begin()
    if error != OK:
        return {"bytes": 0, "error": error}
    var name := dir.get_next()
    while not name.is_empty():
        if name not in [".", ".."]:
            var child := _size(path.path_join(name))
            total += int(child.bytes)
            if int(child.error) != OK:
                error = int(child.error)
        name = dir.get_next()
    dir.list_dir_end()
    return {"bytes": total, "error": error}

static func measure(locations: PackedStringArray) -> Dictionary:
    var total := 0
    var error := OK
    for path in locations:
        var value := _size(path)
        total += int(value.bytes)
        if int(value.error) != OK:
            error = int(value.error)
    return {"bytes": total, "error": error}

static func clear(locations: PackedStringArray) -> Dictionary:
    for path in locations:
        var error := Storage._remove_entry(path) if DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path) else OK
        if error != OK:
            return {"error": error}
    return {"error": OK, "bytes": 0}

static func delete_with_cache(path: String, library_root: String, locations: PackedStringArray) -> Error:
    var result := int(clear(locations).error)
    return Storage.delete_game(path, library_root) if result == OK else result
