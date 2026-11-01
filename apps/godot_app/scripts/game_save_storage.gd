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
