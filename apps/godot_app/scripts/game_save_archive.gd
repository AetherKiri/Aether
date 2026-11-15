extends RefCounted
## Portable, game-scoped save banks. Archive paths never supply destination paths.

const MANIFEST := "aether-save.json"
const MAX_FILE := 128 * 1024 * 1024
const MAX_TOTAL := 1024 * 1024 * 1024
const MAX_FILES := 10000
const CHUNK := 1024 * 1024
const IGNORED := [".DS_Store", "Thumbs.db", "desktop.ini", "krkr.console.log"]

static func identity(name: String) -> String:
    return name.strip_edges()

static func folder_name(name: String) -> String:
    var title := identity(name)
    var safe := ""
    for character in title:
        safe += "_" if character in '/\\:*?"<>|\n\r\t' or character.unicode_at(0) < 32 else character
    safe = safe.strip_edges().trim_suffix(".").left(60)
    return (safe if not safe.is_empty() else "Game") + "-" + title.sha256_text().left(16)

static func _error(message: String) -> Dictionary:
    return {"ok": false, "error": message}

static func safe_relative(path: String) -> bool:
    if path.is_empty() or path.is_absolute_path() or path.contains("\\") or path.contains(":"):
        return false
    for index in path.length():
        if path.unicode_at(index) == 0:
            return false
    for component in path.split("/"):
        if component in ["", ".", ".."]:
            return false
    return true

static func safe_target(root: String, relative: String) -> bool:
    if not safe_relative(relative) or not root.is_absolute_path():
        return false
    var parent := DirAccess.open(root.get_base_dir())
    if parent != null and parent.is_link(root.get_file()):
        return false
    # The root is selected by the host, never by archive metadata. Check every
    # destination component; OS aliases above that root (e.g. macOS /var) work.
    var current := root
    for component in relative.split("/"):
        var directory := DirAccess.open(current)
        if directory != null and directory.is_link(component):
            return false
        current = current.path_join(component)
    return true

static func allowed(location: Dictionary, relative: String) -> bool:
    if not safe_relative(relative):
        return false
    var first := relative.get_slice("/", 0)
    if first in location.get("exclude", []) or relative.get_file() in IGNORED:
        return false
    var files: Array = location.get("files", [])
    return files.is_empty() or relative in files

static func _collect(location: Dictionary, relative: String, files: Array) -> String:
    var root := String(location.path)
    var path := root if relative.is_empty() else root.path_join(relative)
    if not DirAccess.dir_exists_absolute(path):
        return ""
    if not safe_target(root.get_base_dir(), root.get_file()):
        return "unsafe_path"
    var selected: Array = location.get("files", [])
    if relative.is_empty() and not selected.is_empty():
        # Root-level saves share a directory with game assets. Inspect only
        # the engine's allowlist, without traversing unrelated asset folders.
        for entry: String in selected:
            if not allowed(location, entry) or not safe_target(root, entry):
                return "unsafe_path"
            if FileAccess.file_exists(root.path_join(entry)):
                files.append(entry)
        return "too_large" if files.size() > MAX_FILES else ""
    var directory := DirAccess.open(path)
    if directory == null:
        return "read_failed"
    directory.include_hidden = true
    for name in directory.get_files():
        var entry := name if relative.is_empty() else relative.path_join(name)
        if not allowed(location, entry):
            continue
        if directory.is_link(name):
            return "unsafe_path"
        files.append(entry)
        if files.size() > MAX_FILES:
            return "too_large"
    for name in directory.get_directories():
        var entry := name if relative.is_empty() else relative.path_join(name)
        if entry.get_slice("/", 0) in location.get("exclude", []):
            continue
        if directory.is_link(name):
            return "unsafe_path"
        var failure := _collect(location, entry, files)
        if not failure.is_empty():
            return failure
    return ""

static func export_zip(name: String, engine: String, locations: Dictionary, destination: String) -> Dictionary:
    if identity(name).is_empty():
        return _error("missing_name")
    var entries: Array = []
    var total := 0
    for key: String in locations:
        var location: Dictionary = locations[key]
        var paths: Array = []
        var failure := _collect(location, "", paths)
        if not failure.is_empty():
            return _error(failure)
        paths.sort()
        for relative: String in paths:
            var source := String(location.path).path_join(relative)
            var file := FileAccess.open(source, FileAccess.READ)
            if file == null:
                return _error("read_failed")
            var length := file.get_length()
            file.close()
            total += length
            if length > MAX_FILE or total > MAX_TOTAL or entries.size() >= MAX_FILES:
                return _error("too_large")
            entries.append({"path": key.path_join(relative), "size": length, "source": source})
    if entries.is_empty():
        return _error("no_saves")
    if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
        return _error("write_failed")
    var zip := ZIPPacker.new()
    var temporary := destination + ".partial"
    if zip.open(temporary) != OK:
        return _error("write_failed")
    var manifest_files: Array = []
    var failure := ""
    for entry: Dictionary in entries:
        var input := FileAccess.open(entry.source, FileAccess.READ)
        if input == null or input.get_length() != entry.size or zip.start_file(entry.path) != OK:
            failure = "read_failed"
            break
        var digest := HashingContext.new()
        digest.start(HashingContext.HASH_SHA256)
        var remaining := int(entry.size)
        while remaining > 0:
            var bytes := input.get_buffer(mini(CHUNK, remaining))
            if bytes.is_empty() or zip.write_file(bytes) != OK:
                failure = "write_failed"
                break
            digest.update(bytes)
            remaining -= bytes.size()
        input.close()
        if zip.close_file() != OK:
            failure = "write_failed"
        if not failure.is_empty():
            break
        manifest_files.append({"path": entry.path, "size": entry.size, "sha256": digest.finish().hex_encode()})
    if failure.is_empty():
        var metadata := {"format": "aether-saves", "version": 1, "game_name": identity(name), "engine": engine,
            "created_at": Time.get_datetime_string_from_system(true), "files": manifest_files}
        if zip.start_file(MANIFEST) != OK or zip.write_file(JSON.stringify(metadata).to_utf8_buffer()) != OK or zip.close_file() != OK:
            failure = "write_failed"
    if zip.close() != OK:
        failure = "write_failed"
    if failure.is_empty() and DirAccess.rename_absolute(temporary, destination) != OK:
        failure = "write_failed"
    if not failure.is_empty():
        DirAccess.remove_absolute(temporary)
        return _error(failure)
    return {"ok": true, "path": destination, "count": entries.size(), "bytes": total}

static func _bounded_zip(path: String) -> bool:
    # Inspect central-directory sizes BEFORE ZIPReader allocates decompressed data.
    # ZIP64/encrypted/symlink archives are not produced by this exporter.
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or file.get_length() < 22 or file.get_length() > MAX_TOTAL:
        return false
    var start := maxi(0, file.get_length() - 65557)
    file.seek(start)
    var tail := file.get_buffer(file.get_length() - start)
    var eocd := -1
    for index in range(tail.size() - 22, -1, -1):
        if tail.decode_u32(index) == 0x06054b50 and index + 22 + tail.decode_u16(index + 20) == tail.size():
            eocd = index
            break
    if eocd < 0 or tail.decode_u16(eocd + 4) != 0 or tail.decode_u16(eocd + 6) != 0:
        return false
    var count := tail.decode_u16(eocd + 10)
    var offset := tail.decode_u32(eocd + 16)
    if count < 2 or count > MAX_FILES * 2 + 1 or tail.decode_u16(eocd + 8) != count or offset >= start + eocd:
        return false
    file.seek(offset)
    var total := 0
    var names := {}
    for index in range(count):
        var header := file.get_buffer(46)
        if header.size() != 46 or header.decode_u32(0) != 0x02014b50 or (header.decode_u16(8) & 1) != 0:
            return false
        var length := header.decode_u32(24)
        total += length
        if length > MAX_FILE or total > MAX_TOTAL or (header.decode_u32(38) >> 16 & 0xf000) == 0xa000:
            return false
        var encoded := file.get_buffer(header.decode_u16(28))
        # Godot 4.7's ZIP writer includes a terminating NUL in file names.
        if not encoded.is_empty() and encoded[-1] == 0:
            encoded.resize(encoded.size() - 1)
        if encoded.has(0):
            return false
        var name := encoded.get_string_from_utf8()
        var directory := name.ends_with("/")
        if not safe_relative(name.trim_suffix("/")) or names.has(name.to_lower()) or (directory and length != 0) or (name == MANIFEST and length > 4 * 1024 * 1024):
            return false
        names[name.to_lower()] = true
        file.seek(file.get_position() + header.decode_u16(30) + header.decode_u16(32))
        if file.get_position() > start + eocd:
            return false
    return file.get_position() == offset + tail.decode_u32(eocd + 12) and names.has(MANIFEST)

static func import_zip(name: String, engine: String, locations: Dictionary, archive: String, backup: String) -> Dictionary:
    if not _bounded_zip(archive):
        return _error("invalid_archive")
    var zip := ZIPReader.new()
    if zip.open(archive) != OK:
        return _error("invalid_archive")
    var manifest = JSON.parse_string(zip.read_file(MANIFEST).get_string_from_utf8())
    if not manifest is Dictionary or manifest.get("format") != "aether-saves" or manifest.get("version") != 1:
        return _error("invalid_archive")
    if manifest.get("game_name") != identity(name) or manifest.get("engine") != engine:
        return _error("different_game")
    var entries = manifest.get("files")
    var archive_files := 0
    for path in zip.get_files():
        if not path.ends_with("/"):
            archive_files += 1
    if not entries is Array or entries.is_empty() or entries.size() + 1 != archive_files:
        return _error("invalid_archive")
    var stage := DirAccess.create_temp("aether-save-restore")
    if stage == null:
        return _error("write_failed")
    var writes: Array = []
    var seen := {}
    for entry in entries:
        if not entry is Dictionary:
            return _error("invalid_archive")
        var path := String(entry.get("path", ""))
        var key := path.get_slice("/", 0)
        var relative := path.substr(key.length() + 1)
        if not safe_relative(path) or seen.has(path.to_lower()) or not locations.has(key) or not zip.file_exists(path):
            return _error("invalid_archive")
        seen[path.to_lower()] = true
        var location: Dictionary = locations[key]
        if not allowed(location, relative) or not safe_target(location.path, relative):
            return _error("unsafe_path")
        var bytes := zip.read_file(path)
        var hash := HashingContext.new()
        hash.start(HashingContext.HASH_SHA256)
        hash.update(bytes)
        if bytes.size() != entry.get("size", -1) or hash.finish().hex_encode() != entry.get("sha256", ""):
            return _error("invalid_archive")
        var staged := stage.get_current_dir().path_join(str(writes.size()))
        var output := FileAccess.open(staged, FileAccess.WRITE)
        if output == null:
            return _error("write_failed")
        output.store_buffer(bytes)
        output.flush()
        if output.get_error() != OK:
            return _error("write_failed")
        output.close()
        writes.append({"source": staged, "target": String(location.path).path_join(relative), "root": location.path, "relative": relative})
    zip.close()
    # Validate everything before touching local saves. Retain a portable backup.
    var saved := export_zip(name, engine, locations, backup)
    if not saved.ok and saved.error != "no_saves":
        return saved
    var changed: Array = []
    var failure := ""
    for entry: Dictionary in writes:
        var target := String(entry.target)
        if not safe_target(entry.root, entry.relative) or DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
            failure = "write_failed"
            break
        var previous := target + ".aether-restore-old"
        var next := target + ".aether-restore-new"
        if FileAccess.file_exists(previous) or FileAccess.file_exists(next) or DirAccess.dir_exists_absolute(target):
            failure = "write_failed"
            break
        var existed := FileAccess.file_exists(target)
        if DirAccess.copy_absolute(entry.source, next) != OK:
            DirAccess.remove_absolute(next)
            failure = "write_failed"
            break
        if existed and DirAccess.rename_absolute(target, previous) != OK:
            DirAccess.remove_absolute(next)
            failure = "write_failed"
            break
        changed.append({"target": target, "previous": previous, "existed": existed})
        if DirAccess.rename_absolute(next, target) != OK:
            DirAccess.remove_absolute(next)
            failure = "write_failed"
            break
    if not failure.is_empty():
        changed.reverse()
        var rollback_failed := false
        for entry: Dictionary in changed:
            if FileAccess.file_exists(entry.target):
                rollback_failed = DirAccess.remove_absolute(entry.target) != OK or rollback_failed
            if entry.existed and DirAccess.rename_absolute(entry.previous, entry.target) != OK:
                rollback_failed = true
        return _error("rollback_failed" if rollback_failed else failure)
    for entry: Dictionary in changed:
        if entry.existed:
            DirAccess.remove_absolute(entry.previous)
    return {"ok": true, "count": writes.size(), "backup": backup if saved.ok else ""}
