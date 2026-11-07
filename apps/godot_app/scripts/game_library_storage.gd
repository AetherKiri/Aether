extends RefCounted

# iOS imports live directly below Documents/Games. A launch entry may point
# inside a game; deleting it removes its enclosing library folder, never Games.
static func deletion_target(path: String, library_root: String) -> String:
    var root := ProjectSettings.globalize_path(library_root).simplify_path().trim_suffix("/")
    var candidate := ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
    if root.is_empty() or root == "/" or not candidate.begins_with(root + "/"):
        return ""
    var relative := candidate.substr(root.length() + 1)
    var entry := relative.get_slice("/", 0)
    if entry.is_empty() or entry in [".", ".."]:
        return ""
    return root.path_join(entry)

static func delete_game(path: String, library_root: String) -> Error:
    var target := deletion_target(path, library_root)
    if target.is_empty():
        return ERR_INVALID_PARAMETER
    var root := target.get_base_dir()
    var parent := DirAccess.open(root.get_base_dir())
    if parent == null:
        return DirAccess.get_open_error()
    if parent.is_link(root.get_file()):
        return ERR_INVALID_PARAMETER
    return _remove_entry(target)

static func _remove_entry(path: String) -> Error:
    var parent := DirAccess.open(path.get_base_dir())
    if parent == null:
        return DirAccess.get_open_error()
    # Unlink aliases instead of traversing them into another game or directory.
    if parent.is_link(path.get_file()):
        return DirAccess.remove_absolute(path)
    if not DirAccess.dir_exists_absolute(path):
        return DirAccess.remove_absolute(path) if FileAccess.file_exists(path) else OK
    var directory := DirAccess.open(path)
    if directory == null:
        return DirAccess.get_open_error()
    directory.include_hidden = true
    directory.include_navigational = false
    var result := directory.list_dir_begin()
    if result != OK:
        return result
    var entry := directory.get_next()
    while not entry.is_empty():
        result = _remove_entry(path.path_join(entry))
        if result != OK:
            directory.list_dir_end()
            return result
        entry = directory.get_next()
    directory.list_dir_end()
    return DirAccess.remove_absolute(path)
