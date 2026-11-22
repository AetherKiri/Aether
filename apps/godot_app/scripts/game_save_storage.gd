extends RefCounted

const NON_SAVE_FILES := [".DS_Store", "Thumbs.db", "desktop.ini", "krkr.console.log"]

static func prefer_local(
    project_root: String, legacy: String, migration_marker: String, excluded_directories: Array[String] = []
) -> String:
    var root := project_root.strip_edges().simplify_path().trim_suffix("/")
    if root.is_empty() or not DirAccess.dir_exists_absolute(root):
        return legacy
    var local := root.path_join("savedata")
    if not _directory_is_writable(local):
        return legacy
    if not _migrate_legacy_files(legacy, local, migration_marker, excluded_directories):
        # Never open a partially imported save bank. Originals remain usable.
        return legacy
    return local

static func _directory_is_writable(directory: String) -> bool:
    if DirAccess.make_dir_recursive_absolute(directory) != OK:
        return false
    var path := directory.path_join(".aether-save-write-%d.tmp" % Time.get_ticks_usec())
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return false
    file.close()
    return DirAccess.remove_absolute(path) == OK

static func _migrate_legacy_files(
    source: String, destination: String, migration_marker: String, excluded_directories: Array[String]
) -> bool:
    var marker := destination.path_join(migration_marker)
    if FileAccess.file_exists(marker):
        return true
    var copied: Array[String] = []
    var complete := true
    # A populated local store wins as a whole: mixing old sidecars with newer
    # containers can corrupt a slot even without overwriting any single file.
    if DirAccess.dir_exists_absolute(source) and not _has_save_files(destination, migration_marker, excluded_directories):
        complete = _copy_save_tree(source, destination, copied, migration_marker, excluded_directories)
    if complete:
        var file := FileAccess.open(marker, FileAccess.WRITE)
        if file != null:
            file.store_string("Aether save migration 1\n")
            file.flush()
            complete = file.get_error() == OK
            file.close()
        else:
            complete = false
    if not complete:
        # Remove only this attempt's copies, never pre-existing local saves.
        for path in copied:
            DirAccess.remove_absolute(path)
        if FileAccess.file_exists(marker):
            DirAccess.remove_absolute(marker)
    return complete

static func _has_save_files(
    path: String, migration_marker: String, excluded_directories: Array[String], top_level: bool = true
) -> bool:
    var directory := DirAccess.open(path)
    if directory == null:
        return false
    directory.include_hidden = true
    for name in directory.get_files():
        if not directory.is_link(name) and name != migration_marker and name not in NON_SAVE_FILES:
            return true
    for name in directory.get_directories():
        if not (top_level and name in excluded_directories) and not directory.is_link(name) \
            and _has_save_files(path.path_join(name), migration_marker, excluded_directories, false):
            return true
    return false

static func _copy_save_tree(
    source: String, destination: String, copied: Array[String], migration_marker: String,
    excluded_directories: Array[String], top_level: bool = true
) -> bool:
    var directory := DirAccess.open(source)
    if directory == null:
        return false
    if DirAccess.make_dir_recursive_absolute(destination) != OK:
        return false
    directory.include_hidden = true
    for name in directory.get_files():
        if directory.is_link(name) or name == migration_marker or name in NON_SAVE_FILES:
            continue
        var target := destination.path_join(name)
        if FileAccess.file_exists(target):
            continue
        if DirAccess.dir_exists_absolute(target):
            return false
        var error := DirAccess.copy_absolute(source.path_join(name), target)
        if error != OK:
            if FileAccess.file_exists(target):
                DirAccess.remove_absolute(target)
            return false
        copied.append(target)
    for name in directory.get_directories():
        if directory.is_link(name) or (top_level and name in excluded_directories):
            continue
        if not _copy_save_tree(
            source.path_join(name), destination.path_join(name), copied, migration_marker, excluded_directories, false
        ):
            return false
    return true


const LOCAL_BANK_MARKER := ".aether-local-bank-v1"

# Unlike prefer_local(), this contract never returns the legacy location for
# writing. Only a complete bank is published; the source is left untouched.
# selected maps a destination filename to its legacy filenames in priority order.
static func require_local_bank(
    game_root: String, relative_bank: String, legacy: String = "", selected: Dictionary = {},
    excluded_directories: Array[String] = [], require_empty: bool = false
) -> Dictionary:
    var parent := ProjectSettings.globalize_path(game_root).simplify_path().trim_suffix("/")
    if game_root.is_empty() or not parent.is_absolute_path() or not DirAccess.dir_exists_absolute(parent):
        return _local_bank_error(parent, ERR_FILE_NOT_FOUND)
    var parts := relative_bank.split("/")
    for part in parts:
        if not _bank_component(part):
            return _local_bank_error(relative_bank, ERR_INVALID_PARAMETER)
    for i in range(parts.size() - 1):
        var folder := DirAccess.open(parent)
        if folder == null or folder.is_link(parts[i]):
            return _local_bank_error(parent.path_join(parts[i]), ERR_CANT_OPEN)
        parent = parent.path_join(parts[i])
        if not DirAccess.dir_exists_absolute(parent):
            var error := DirAccess.make_dir_absolute(parent)
            if error != OK and error != ERR_ALREADY_EXISTS:
                return _local_bank_error(parent, error)
    var folder := DirAccess.open(parent)
    var leaf := parts[parts.size() - 1]
    var bank := parent.path_join(leaf)
    if folder == null or folder.is_link(leaf) or folder.file_exists(leaf):
        return _local_bank_error(bank, ERR_CANT_OPEN)
    var already_exists := folder.dir_exists(leaf)
    if already_exists:
        var existing := DirAccess.open(bank)
        if existing == null or not _safe_local_bank(bank) or not _directory_is_writable(bank):
            return _local_bank_error(bank, ERR_CANT_OPEN)
        existing.include_hidden = true
        # A local bank (including one with all saves deleted) is authoritative.
        if not existing.get_files().is_empty() or not existing.get_directories().is_empty():
            return _local_bank_error(bank, ERR_ALREADY_EXISTS) if require_empty else {"path": bank, "error": ""}

    # No automatic source: keep a new bank empty so explicit recovery can be
    # requested later, until the game actually creates its first save.
    if legacy.is_empty():
        if not already_exists:
            var create_error := DirAccess.make_dir_absolute(bank)
            if create_error != OK:
                return _local_bank_error(bank, create_error)
        if not _directory_is_writable(bank):
            return _local_bank_error(bank, ERR_CANT_OPEN)
        return {"path": bank, "error": ""}

    # A sibling directory ensures the commit is a rename on the same volume.
    var stage := parent.path_join(".aether-save-stage-" + Crypto.new().generate_random_bytes(12).hex_encode())
    var error := DirAccess.make_dir_absolute(stage)
    if error != OK:
        return _local_bank_error(bank, error)
    if not legacy.is_empty():
        var legacy_parent := DirAccess.open(legacy.get_base_dir())
        if legacy_parent != null and legacy_parent.is_link(legacy.get_file()):
            error = ERR_CANT_OPEN
        elif DirAccess.dir_exists_absolute(legacy):
            if selected.is_empty():
                var copied: Array[String] = []
                if not _copy_save_tree(legacy, stage, copied, LOCAL_BANK_MARKER, excluded_directories):
                    error = ERR_CANT_CREATE
            else:
                error = _copy_selected_save_files(legacy, stage, selected)
    if error == OK:
        var marker := FileAccess.open(stage.path_join(LOCAL_BANK_MARKER), FileAccess.WRITE)
        if marker == null:
            error = FileAccess.get_open_error()
        else:
            marker.store_string("Aether game-local save bank 1\n")
            marker.flush()
            error = marker.get_error()
            marker.close()
    if error == OK and already_exists:
        # This succeeds only if the pre-existing bank is still empty.
        error = DirAccess.remove_absolute(bank)
    if error == OK:
        error = DirAccess.rename_absolute(stage, bank)
    if error != OK:
        _remove_save_stage(stage)
        return _local_bank_error(bank, error)
    return {"path": bank, "error": ""}

static func _bank_component(part: String) -> bool:
    return not part.is_empty() and part not in [".", ".."] and not part.contains("/") \
        and not part.contains("\\") and not part.contains(":")

static func _local_bank_error(path: String, error: int) -> Dictionary:
    return {"path": "", "error": "%s: %s" % [path, error_string(error)]}

static func is_existing_local_bank(game_root: String, bank: String) -> bool:
    var root := ProjectSettings.globalize_path(game_root).simplify_path().trim_suffix("/")
    if root.is_empty() or not bank.begins_with(root + "/"):
        return false
    var current := root
    for part in bank.substr(root.length() + 1).split("/"):
        var directory := DirAccess.open(current)
        if not _bank_component(part) or directory == null or directory.is_link(part) or not directory.dir_exists(part):
            return false
        current = current.path_join(part)
    return _safe_local_bank(current)

static func _safe_local_bank(path: String) -> bool:
    var pending: Array[String] = [path]
    while not pending.is_empty():
        var directory := DirAccess.open(pending.pop_back())
        if directory == null:
            return false
        directory.include_hidden = true
        if directory.list_dir_begin() != OK:
            return false
        var name := directory.get_next()
        while not name.is_empty():
            if directory.is_link(name):
                return false
            if directory.current_is_dir():
                pending.append(directory.get_current_dir().path_join(name))
            name = directory.get_next()
    return true

static func _copy_selected_save_files(source: String, destination: String, selected: Dictionary) -> int:
    var directory := DirAccess.open(source)
    if directory == null:
        return DirAccess.get_open_error()
    for target: String in selected:
        if not _bank_component(target) or target == LOCAL_BANK_MARKER:
            return ERR_INVALID_PARAMETER
        var candidates = selected[target]
        if candidates is Dictionary:
            if directory.is_link(target):
                return ERR_CANT_OPEN
            if not directory.dir_exists(target):
                continue
            var child := destination.path_join(target)
            var error := DirAccess.make_dir_absolute(child)
            if error != OK:
                return error
            error = _copy_selected_save_files(source.path_join(target), child, candidates)
            if error != OK:
                return error
            continue
        for name: String in candidates:
            if not _bank_component(name):
                return ERR_INVALID_PARAMETER
            if directory.is_link(name) or not directory.file_exists(name):
                continue
            var error := DirAccess.copy_absolute(source.path_join(name), destination.path_join(target))
            if error != OK:
                return error
            break
    return OK

static func _remove_save_stage(path: String) -> void:
    var directory := DirAccess.open(path)
    if directory == null:
        return
    directory.include_hidden = true
    for name in directory.get_files():
        DirAccess.remove_absolute(path.path_join(name))
    for name in directory.get_directories():
        var child := path.path_join(name)
        if directory.is_link(name):
            DirAccess.remove_absolute(child)
        else:
            _remove_save_stage(child)
    DirAccess.remove_absolute(path)
