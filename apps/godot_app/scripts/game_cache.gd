extends RefCounted

const Storage := preload("res://scripts/game_library_storage.gd")

static func directory(base: String, game_root: String) -> String:
    var root := game_root.simplify_path().trim_suffix("/")
    if root.is_empty():
        return ""
    var home_path := base.simplify_path().trim_suffix("/")
    # iOS changes the container UUID on updates. Keep app-owned game identities
    # relative to Documents; external games retain their full path for isolation.
    var identity := "user://" + root.substr(home_path.length() + 1) if root.begins_with(home_path + "/") else root
    var title := root.get_file().validate_filename().trim_prefix(".").left(48)
    if title.is_empty():
        title = "Game"
    while title.begins_with("."):
        title = title.trim_prefix(".")
    return base.path_join("cache/games").path_join(title + "--" + identity.sha256_text().left(16))

static func paths(base: String, game_root: String, engine: String, previous_roots := PackedStringArray()) -> PackedStringArray:
    var root := game_root.simplify_path().trim_suffix("/")
    if root.is_empty():
        return PackedStringArray()
    var result := PackedStringArray()
    var current := directory(base, root)
    if _safe_parents(base, current):
        result.append(current)
    var roots := PackedStringArray([root])
    for previous in previous_roots:
        if not previous.is_empty() and previous not in roots:
            roots.append(previous.simplify_path().trim_suffix("/"))
    for previous in roots:
        for location in _legacy_paths(base, previous, engine):
            if _safe_parents(base, location):
                result.append(location)
    if engine in ["artemis", "kirikiri"] and not _is_link(root.path_join("savedata")):
        result.append(root.path_join("savedata/.artemis-emote-cache"))
    return _distinct_paths(result)

static func _legacy_paths(base: String, root: String, engine: String) -> PackedStringArray:
    var result := PackedStringArray([base.path_join("cache/games").path_join(root.sha256_text())])
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
        "renpy":
            var sessions := DirAccess.open(base.path_join("renpy_sessions"))
            if sessions != null:
                for name in sessions.get_directories():
                    if sessions.is_link(name):
                        continue
                    var session := base.path_join("renpy_sessions").path_join(name)
                    var manifest = JSON.parse_string(FileAccess.get_file_as_string(session.path_join("manifest.json")))
                    if manifest is Dictionary and String(manifest.get("root", "")).simplify_path().trim_suffix("/") == root:
                        result.append(session)
    return result

static func prepare(base: String, game_root: String, engine: String, previous_roots := PackedStringArray()) -> Dictionary:
    var destination := directory(base, game_root)
    if destination.is_empty() or not _safe_parents(base, destination) or _is_link(destination):
        return {"error": ERR_INVALID_PARAMETER, "path": destination}
    var locations := paths(base, game_root, engine, previous_roots)
    if locations.is_empty():
        return {"error": ERR_INVALID_PARAMETER, "path": ""}
    if not DirAccess.dir_exists_absolute(destination):
        # Move an existing bank on the same volume instead of copying it. Other
        # historical banks remain included in both measurement and clearing.
        for old in locations.slice(1):
            if engine in ["tyranoscript", "renpy"] or not old.begins_with(base + "/") or not DirAccess.dir_exists_absolute(old) or _is_link(old):
                continue
            var error := DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
            if error == OK:
                error = DirAccess.rename_absolute(old, destination)
            if error != OK:
                return {"error": error, "path": destination}
            break
    return {"error": DirAccess.make_dir_recursive_absolute(destination), "path": destination}

static func all_paths(base: String) -> PackedStringArray:
    # These roots contain only regenerable resources. Legacy save banks contain
    # both saves and cache: enumerate their cache child, never the bank itself.
    var result := PackedStringArray([base.path_join("cache"), base.path_join("tyrano_cache"), base.path_join("renpy_sessions"), base.path_join(".artemis-emote-cache")])
    for legacy in ["yuris", "systemc_games"]:
        var parent_path := base.path_join(legacy)
        if _is_link(parent_path):
            continue
        var parent := DirAccess.open(parent_path)
        if parent == null:
            continue
        for bank in parent.get_directories():
            if not parent.is_link(bank):
                result.append(parent_path.path_join(bank).path_join("cache"))
    return result

static func _distinct_paths(locations: PackedStringArray) -> PackedStringArray:
    var result := PackedStringArray()
    for path in locations:
        var normalized := path.simplify_path().trim_suffix("/")
        if normalized.is_empty() or normalized in result:
            continue
        var contained := false
        for other in locations:
            var parent := other.simplify_path().trim_suffix("/")
            if not parent.is_empty() and normalized.begins_with(parent + "/"):
                contained = true
                break
        if not contained:
            result.append(normalized)
    return result

static func _is_link(path: String) -> bool:
    var parent := DirAccess.open(path.get_base_dir())
    return parent != null and parent.is_link(path.get_file())

static func _safe_parents(base: String, path: String) -> bool:
    var parent := path.get_base_dir()
    while parent.length() > base.length() and parent.begins_with(base + "/"):
        if _is_link(parent):
            return false
        parent = parent.get_base_dir()
    return true

static func _size(path: String) -> Dictionary:
    var parent := DirAccess.open(path.get_base_dir())
    if parent == null:
        return {"bytes": 0, "error": DirAccess.get_open_error() if DirAccess.dir_exists_absolute(path.get_base_dir()) else OK}
    if parent.is_link(path.get_file()):
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
    for path in _distinct_paths(locations):
        var value := _size(path)
        total += int(value.bytes)
        if int(value.error) != OK:
            error = int(value.error)
    return {"bytes": total, "error": error}

static func clear(locations: PackedStringArray) -> Dictionary:
    for path in _distinct_paths(locations):
        var error := Storage._remove_entry(path) if DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path) else OK
        if error != OK:
            return {"error": error, "bytes": int(measure(locations).bytes)}
    return measure(locations)

static func delete_with_cache(path: String, library_root: String, locations: PackedStringArray, owned_relative: String = "") -> Error:
    var result := int(clear(locations).error)
    return Storage.delete_game(path, library_root, owned_relative) if result == OK else result
