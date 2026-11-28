extends RefCounted

# iOS imports live directly below Documents/Games. A launch entry may point
# inside a game; deleting it removes its enclosing library folder, never Games.
static func deletion_target(path: String, library_root: String, owned_relative: String = "") -> String:
    var root := ProjectSettings.globalize_path(library_root).simplify_path().trim_suffix("/")
    var candidate := ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
    if root.is_empty() or root == "/" or not candidate.begins_with(root + "/"):
        return ""
    var relative := candidate.substr(root.length() + 1)
    if not owned_relative.is_empty():
        if owned_relative.is_absolute_path() or owned_relative.simplify_path() != owned_relative or owned_relative.split("/").has(".."):
            return ""
        if relative != owned_relative and not relative.begins_with(owned_relative + "/"):
            return ""
        if owned_relative in [".", ".."] or owned_relative.ends_with("/"):
            return ""
        return root.path_join(owned_relative)
    var entry := relative.get_slice("/", 0)
    if entry.is_empty() or entry in [".", ".."]:
        return ""
    return root.path_join(entry)

static func delete_game(path: String, library_root: String, owned_relative: String = "") -> Error:
    var target := deletion_target(path, library_root, owned_relative)
    if target.is_empty():
        return ERR_INVALID_PARAMETER
    var root := ProjectSettings.globalize_path(library_root).simplify_path().trim_suffix("/")
    var ancestor := target.get_base_dir()
    while ancestor == root or ancestor.begins_with(root + "/"):
        var parent := DirAccess.open(ancestor.get_base_dir())
        if parent == null:
            return DirAccess.get_open_error()
        if parent.is_link(ancestor.get_file()):
            return ERR_INVALID_PARAMETER
        ancestor = ancestor.get_base_dir()
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
