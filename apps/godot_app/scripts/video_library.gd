extends RefCounted

const EXTENSIONS := ["mp4", "mkv", "mov", "m4v", "avi", "webm", "flv", "ts", "m2ts", "mpeg", "mpg", "wmv"]

var sources: Array[Dictionary] = []
var videos: Array[Dictionary] = []
var entries: Array[Dictionary] = []
var current_directory := ""
var navigation_root := ""
var automatic_root := ""
var _list_path: String
var _hidden_path: String

func _init(list_path: String, hidden_path: String) -> void:
    _list_path = list_path
    _hidden_path = hidden_path

func refresh(root: String = "") -> void:
    automatic_root = normalize_path(root) if not root.is_empty() else ""
    if automatic_root.is_empty():
        sources = _load_sources()
    else:
        DirAccess.make_dir_recursive_absolute(automatic_root)
        sources = list_directory(automatic_root)

    # Keep a single flat catalog for playback authorization. Folder cards never
    # count as videos, and importing overlapping folders cannot duplicate it.
    var found := {}
    var visited := {}
    var pending := sources.duplicate()
    while not pending.is_empty():
        var entry: Dictionary = pending.pop_back()
        var path := String(entry["path"])
        if is_directory(entry):
            if not visited.has(path):
                visited[path] = true
                pending.append_array(list_directory(path))
        else:
            found[path] = entry
    var hidden := _load_hidden()
    var retained_hidden := {}
    videos.clear()
    for path in found:
        var entry: Dictionary = found[path]
        var modified := int(entry.get("modified", 0))
        if int(hidden.get(path, -1)) == modified:
            retained_hidden[path] = modified
        else:
            videos.append(entry)
    if hidden != retained_hidden:
        _save_hidden(retained_hidden)
    videos.sort_custom(_entry_less)
    _resolve_location()
    _update_entries()

func add_source(path: String) -> bool:
    var normalized := normalize_path(path)
    var entry := entry_info(normalized)
    if entry.is_empty():
        return false
    var next := _load_sources()
    for index in range(next.size() - 1, -1, -1):
        if String(next[index]["path"]) == normalized:
            next.remove_at(index)
    next.append(entry)
    _save_sources(next)
    # Explicitly importing again restores videos previously removed here.
    var hidden := _load_hidden()
    for hidden_path in hidden.keys():
        if hidden_path == normalized or (is_directory(entry) and contains_path(normalized, hidden_path)):
            hidden.erase(hidden_path)
    _save_hidden(hidden)
    return true

func remove_entry(path: String) -> void:
    var normalized := normalize_path(path)
    if automatic_root.is_empty():
        var next := _load_sources()
        for index in range(next.size() - 1, -1, -1):
            if String(next[index]["path"]) == normalized:
                next.remove_at(index)
        _save_sources(next)
    if FileAccess.file_exists(normalized):
        # Imported folders and the iOS Video directory are scanned again on
        # refresh. Remember removed files without deleting anything on disk.
        var hidden := _load_hidden()
        hidden[normalized] = int(FileAccess.get_modified_time(normalized))
        _save_hidden(hidden)

func enter_directory(path: String) -> bool:
    var normalized := normalize_path(path)
    if not DirAccess.dir_exists_absolute(normalized):
        return false
    if current_directory.is_empty():
        var imported := false
        for source in sources:
            if is_directory(source) and String(source["path"]) == normalized:
                imported = true
                break
        if not imported:
            return false
        navigation_root = normalized
    elif not contains_path(navigation_root, normalized):
        return false
    current_directory = normalized
    refresh(automatic_root)
    return true

func can_go_up() -> bool:
    return not current_directory.is_empty() and current_directory != automatic_root

func go_up() -> bool:
    if not can_go_up():
        return false
    if current_directory == navigation_root:
        current_directory = ""
        navigation_root = ""
    else:
        current_directory = current_directory.get_base_dir()
    refresh(automatic_root)
    return true

func go_to_library() -> void:
    current_directory = automatic_root
    navigation_root = automatic_root
    refresh(automatic_root)

func location_label() -> String:
    if current_directory.is_empty():
        return ""
    var root_name := navigation_root.get_file()
    if root_name.is_empty():
        root_name = navigation_root
    return root_name + current_directory.trim_prefix(navigation_root)

func can_remove(entry: Dictionary) -> bool:
    return not is_directory(entry) or (automatic_root.is_empty() and current_directory.is_empty())

func search_entries() -> Array[Dictionary]:
    # Retain the old recursive video search, scoped to the folder being
    # browsed. Empty queries use entries and keep the directory hierarchy.
    var result: Array[Dictionary] = []
    for entry in entries:
        if is_directory(entry):
            result.append(entry)
    for video in videos:
        if current_directory.is_empty() or contains_path(current_directory, String(video["path"])):
            result.append(video)
    result.sort_custom(_entry_less)
    return result

func _resolve_location() -> void:
    if not automatic_root.is_empty():
        navigation_root = automatic_root
    elif not navigation_root.is_empty():
        var imported := false
        for source in sources:
            if is_directory(source) and String(source["path"]) == navigation_root:
                imported = true
                break
        if not imported:
            navigation_root = ""
            current_directory = ""
    if navigation_root.is_empty():
        current_directory = ""
        return
    if not contains_path(navigation_root, current_directory):
        current_directory = navigation_root
    while current_directory != navigation_root and not DirAccess.dir_exists_absolute(current_directory):
        current_directory = current_directory.get_base_dir()

func _update_entries() -> void:
    var candidates := sources if current_directory.is_empty() else list_directory(current_directory)
    var visible_paths := {}
    for video in videos:
        visible_paths[video["path"]] = true
    entries.clear()
    for entry in candidates:
        if is_directory(entry) or visible_paths.has(entry["path"]):
            entries.append(entry)
    entries.sort_custom(_entry_less)

func _load_sources() -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var file := FileAccess.open(_list_path, FileAccess.READ)
    if file == null:
        return result
    var parsed = JSON.parse_string(file.get_as_text())
    if not parsed is Array:
        return result
    var seen := {}
    for item in parsed:
        if not item is Dictionary or not item.get("path", "") is String:
            continue
        var path := String(item.get("path", ""))
        if path.is_empty():
            continue
        var entry := entry_info(normalize_path(path))
        if not entry.is_empty() and not seen.has(entry["path"]):
            result.append(entry)
            seen[entry["path"]] = true
    return result

func _save_sources(items: Array[Dictionary]) -> void:
    var file := FileAccess.open(_list_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(items))

func _load_hidden() -> Dictionary:
    var file := FileAccess.open(_hidden_path, FileAccess.READ)
    if file == null:
        return {}
    var parsed = JSON.parse_string(file.get_as_text())
    return parsed if parsed is Dictionary else {}

func _save_hidden(hidden: Dictionary) -> void:
    var file := FileAccess.open(_hidden_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(hidden))

static func normalize_path(path: String) -> String:
    var normalized := ProjectSettings.globalize_path(path).simplify_path()
    if normalized.length() > 1 and not normalized.ends_with(":/"):
        normalized = normalized.trim_suffix("/")
    return normalized

static func is_directory(entry: Dictionary) -> bool:
    return bool(entry.get("isDirectory", false))

static func contains_path(root: String, path: String) -> bool:
    return not root.is_empty() and (path == root or path.begins_with(root.trim_suffix("/") + "/"))

static func entry_info(path: String) -> Dictionary:
    if DirAccess.dir_exists_absolute(path):
        var name := path.get_file() if not path.get_file().is_empty() else path
        return {"path": path, "name": name, "fileName": name, "isDirectory": true}
    if not FileAccess.file_exists(path) or not path.get_extension().to_lower() in EXTENSIONS:
        return {}
    return {
        "path": path,
        "name": path.get_file().get_basename(),
        "fileName": path.get_file(),
        "modified": FileAccess.get_modified_time(path),
    }

static func list_directory(root: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var dir := DirAccess.open(root)
    if dir == null:
        return result
    dir.list_dir_begin()
    var name := dir.get_next()
    while not name.is_empty():
        if not name.begins_with("."):
            # Directory symlinks can lead back into a parent during catalog
            # scanning. Ordinary directories keep their original hierarchy.
            if not dir.current_is_dir() or not dir.is_link(name):
                var entry := entry_info(root.path_join(name))
                if not entry.is_empty():
                    result.append(entry)
        name = dir.get_next()
    dir.list_dir_end()
    result.sort_custom(_entry_less)
    return result

static func _entry_less(a: Dictionary, b: Dictionary) -> bool:
    if is_directory(a) != is_directory(b):
        return is_directory(a)
    var comparison := String(a.get("name", "")).naturalnocasecmp_to(String(b.get("name", "")))
    if comparison == 0:
        return String(a["path"]).naturalnocasecmp_to(String(b["path"])) < 0
    return comparison < 0
