extends RefCounted

# A stock ERIS effect pass must finish in one host frame. Smaller slices
# break WA(1)'s queued-load ordering and publish camera motion intermittently.
const DEFAULT_WORKER_STEP_BUDGET := 65536
const SCRIPT_ENCODING_FIELD := "yurisScriptEncoding"
const SCRIPT_ENCODINGS := ["CP932", "GBK", "UTF-8"]
const SAVE_DIRECTORY := "savedata"
const MIGRATION_MARKER := ".aether-yuris-migrated"
const NON_SAVE_FILES := [MIGRATION_MARKER, ".DS_Store", "Thumbs.db", "desktop.ini", "krkr.console.log"]

static func user_directory(base: String, project_root: String) -> String:
    var legacy := legacy_user_directory(base, project_root)
    var root := project_root.strip_edges().simplify_path().trim_suffix("/")
    if root.is_empty() or not DirAccess.dir_exists_absolute(root):
        return legacy
    var local := root.path_join(SAVE_DIRECTORY)
    if not _directory_is_writable(local):
        return legacy
    if not _migrate_legacy_files(legacy, local):
        # Never open a partially imported save bank. Originals remain usable.
        return legacy
    return local

static func legacy_user_directory(base: String, project_root: String) -> String:
    var identity := project_root.strip_edges().simplify_path().trim_suffix("/")
    if identity.is_empty():
        return base
    # ERIS uses the same gsd.sd/save00001.sd names in unrelated games.
    return base.path_join("yuris").path_join(identity.sha256_text())

static func cache_directory(base: String, project_root: String) -> String:
    # Extracted resources are disposable and must not travel with game saves.
    return legacy_user_directory(base, project_root).path_join("cache")

static func _directory_is_writable(directory: String) -> bool:
    if DirAccess.make_dir_recursive_absolute(directory) != OK:
        return false
    var path := directory.path_join(".aether-yuris-write-%d.tmp" % Time.get_ticks_usec())
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return false
    file.close()
    return DirAccess.remove_absolute(path) == OK

static func _migrate_legacy_files(source: String, destination: String) -> bool:
    var marker := destination.path_join(MIGRATION_MARKER)
    if FileAccess.file_exists(marker):
        return true
    var copied: Array[String] = []
    var complete := true
    # A populated local store wins as a whole: mixing old sidecars with newer
    # containers can corrupt a slot even without overwriting any single file.
    if DirAccess.dir_exists_absolute(source) and not _has_save_files(destination):
        complete = _copy_save_tree(source, destination, copied)
    if complete:
        var file := FileAccess.open(marker, FileAccess.WRITE)
        if file != null:
            file.store_string("YU-RIS save migration 1\n")
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

static func _has_save_files(path: String, top_level: bool = true) -> bool:
    var directory := DirAccess.open(path)
    if directory == null:
        return false
    directory.include_hidden = true
    for name in directory.get_files():
        if not directory.is_link(name) and name not in NON_SAVE_FILES:
            return true
    for name in directory.get_directories():
        if not (top_level and name == "cache") and not directory.is_link(name) \
            and _has_save_files(path.path_join(name), false):
            return true
    return false

static func _copy_save_tree(
    source: String, destination: String, copied: Array[String], top_level: bool = true
) -> bool:
    var directory := DirAccess.open(source)
    if directory == null:
        return false
    if DirAccess.make_dir_recursive_absolute(destination) != OK:
        return false
    directory.include_hidden = true
    for name in directory.get_files():
        if directory.is_link(name) or name in NON_SAVE_FILES:
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
        if directory.is_link(name) or (top_level and name == "cache"):
            continue
        if not _copy_save_tree(source.path_join(name), destination.path_join(name), copied, false):
            return false
    return true

static func script_encoding(game: Dictionary, override: String = "") -> String:
    var requested := normalize_encoding(override)
    if not requested.is_empty():
        return requested
    var saved := normalize_encoding(String(game.get(SCRIPT_ENCODING_FIELD, "")))
    return "CP932" if saved.is_empty() else saved

static func normalize_encoding(value: String) -> String:
    match value.strip_edges().to_upper().replace("_", "-"):
        "CP932", "SJIS", "SHIFT-JIS", "SHIFTJIS":
            return "CP932"
        "GBK", "CP936":
            return "GBK"
        "UTF8", "UTF-8":
            return "UTF-8"
    return ""

static func worker_step_budget(override: String = "") -> int:
    var value := override.strip_edges()
    if not value.is_valid_int():
        return DEFAULT_WORKER_STEP_BUDGET
    return clampi(value.to_int(), 256, DEFAULT_WORKER_STEP_BUDGET)
