extends RefCounted

# Electron ASAR is a Pickle JSON index followed by uncompressed file data.
# Keep discovery bounded; stream payloads only when the player is opened.
const MAX_HEADER := 16 * 1024 * 1024
const MAX_FILES := 100000
const MAX_BYTES := 32 * 1024 * 1024 * 1024
const MARKERS := ["index.html", "tyrano/tyrano.js", "tyrano/plugins/kag/kag.js", "data/system/Config.tjs"]
var error := ""
var source := ""
var entries: Dictionary = {}
var payload := 0
var archive_size := 0
var header_hash := ""
var index_size := 0
var total_size := 0
var cancel_mutex := Mutex.new()
var cancelled := false

func open(path: String) -> bool:
    source = path
    entries.clear()
    total_size = 0
    error = ""
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or file.get_length() < 16:
        return _fail("Cannot read the ASAR header")
    archive_size = file.get_length()
    if file.get_32() != 4:
        return _fail("Invalid ASAR Pickle header")
    var header_size := file.get_32()
    var pickle_size := file.get_32()
    var json_size := file.get_32()
    index_size = json_size
    payload = 8 + header_size
    if header_size < 8 or header_size > MAX_HEADER or payload > archive_size \
            or pickle_size != header_size - 4 or json_size < 2 or json_size > header_size - 8 \
            or header_size - 8 - json_size > 3 or header_size % 4 != 0:
        return _fail("Invalid ASAR index size")
    var bytes := file.get_buffer(json_size)
    header_hash = bytes.hex_encode().sha256_text()
    var json := JSON.new()
    if json.parse(bytes.get_string_from_utf8()) != OK or not json.data is Dictionary:
        return _fail("Invalid ASAR JSON index")
    return _index(json.data, "", 0)

func _index(node: Dictionary, prefix: String, depth: int) -> bool:
    if depth > 64 or not node.get("files") is Dictionary:
        return _fail("Invalid ASAR directory")
    for name in node.files:
        if not name is String or name.is_empty() or name in [".", ".."] \
                or name.contains("/") or name.contains("\\") or name.contains(":") or name.to_utf8_buffer().has(0):
            return _fail("Unsafe ASAR file name")
        var item = node.files[name]
        if not item is Dictionary or item.has("link"):
            return _fail("ASAR links are not supported")
        var relative: String = prefix + name
        if item.has("files"):
            if not _index(item, relative + "/", depth + 1):
                return false
            continue
        if entries.size() >= MAX_FILES:
            return _fail("Too many ASAR files")
        var size := _integer(item.get("size"))
        if size < 0 or size > MAX_BYTES or total_size > MAX_BYTES - size:
            return _fail("Invalid ASAR file size")
        var unpacked: bool = item.get("unpacked", false) == true
        var offset := 0 if unpacked else _integer(item.get("offset"))
        if offset < 0 or (not unpacked and (offset > archive_size - payload or size > archive_size - payload - offset)):
            return _fail("ASAR file extends beyond the archive")
        entries[relative] = {"size": size, "offset": offset, "unpacked": unpacked}
        total_size += size
    return true

func is_tyrano_project() -> bool:
    for marker in MARKERS:
        if not entries.has(marker):
            return false
    return true

func read_text(relative: String, limit: int = 1024 * 1024) -> String:
    if not entries.has(relative) or int(entries[relative].size) > limit:
        return ""
    var input := _input(relative)
    if input == null:
        return ""
    return input.get_buffer(entries[relative].size).get_string_from_utf8()

func cancel() -> void:
    cancel_mutex.lock()
    cancelled = true
    cancel_mutex.unlock()

func _is_cancelled() -> bool:
    cancel_mutex.lock()
    var value := cancelled
    cancel_mutex.unlock()
    return value

# Called on the player's worker thread. Completion is published only after all
# files are copied, so an interrupted extraction can never become a cache hit.
func prepare(cache_root: String) -> Dictionary:
    var input := FileAccess.open(source, FileAccess.READ)
    if input == null or input.get_length() != archive_size:
        return {"error": "ASAR archive changed before preparation"}
    input.seek(16)
    if input.get_buffer(index_size).hex_encode().sha256_text() != header_hash:
        return {"error": "ASAR index changed before preparation"}
    # Content hashes also invalidate same-size updates within the filesystem's
    # timestamp resolution. Hash on the worker, with cancellation between chunks.
    var fingerprint := "asar-v1:" + _digest(input)
    if not error.is_empty():
        return {"error": error}
    for relative in entries:
        if entries[relative].unpacked:
            var external := _input(relative)
            if external == null:
                return {"error": error}
            fingerprint += ":%s:%s" % [relative, _digest(external)]
            if not error.is_empty():
                return {"error": error}
    var parent := cache_root.path_join(source.sha256_text())
    var destination := parent.path_join(fingerprint.sha256_text())
    var project := destination.path_join("project")
    if FileAccess.file_exists(destination.path_join("complete")):
        var complete := true
        for relative in entries:
            if _is_cancelled():
                return {"error": "ASAR preparation cancelled"}
            var cached := FileAccess.open(project.path_join(relative), FileAccess.READ)
            if cached == null or cached.get_length() != int(entries[relative].size):
                complete = false
                break
        if complete:
            return {"entry": project.path_join("index.html")}
        _remove(destination)
    var staging := destination + ".partial-%s-%s" % [OS.get_process_id(), Time.get_ticks_usec()]
    var output_root := staging.path_join("project")
    if DirAccess.make_dir_recursive_absolute(output_root) != OK:
        return {"error": "Cannot create the TyranoScript cache"}
    for relative in entries:
        if not error.is_empty() or _is_cancelled():
            break
        var item: Dictionary = entries[relative]
        var external: FileAccess
        var reader := input
        if item.unpacked:
            external = _input(relative)
            reader = external
        else:
            input.seek(payload + int(item.offset))
        if reader == null:
            _fail("Cannot read ASAR file: " + relative)
            break
        var target := output_root.path_join(relative)
        if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
            _fail("Cannot create the TyranoScript resource directory")
            break
        var output := FileAccess.open(target, FileAccess.WRITE)
        if output == null:
            _fail("Cannot write the TyranoScript cache")
            break
        var remaining: int = item.size
        while remaining > 0 and not _is_cancelled():
            var chunk := reader.get_buffer(mini(remaining, 256 * 1024))
            if chunk.is_empty():
                _fail("ASAR file changed while reading: " + relative)
                break
            output.store_buffer(chunk)
            if output.get_error() != OK:
                _fail("Cannot write the TyranoScript cache (check available space)")
                break
            remaining -= chunk.size()
        output.close()
    if _is_cancelled() or not error.is_empty():
        _remove(staging)
        return {"error": error if not error.is_empty() else "ASAR preparation cancelled"}
    var marker := FileAccess.open(staging.path_join("complete"), FileAccess.WRITE)
    if marker == null:
        _remove(staging)
        return {"error": "Cannot finish the TyranoScript cache"}
    marker.store_string(fingerprint)
    marker.close()
    if DirAccess.rename_absolute(staging, destination) != OK:
        _remove(staging)
        return {"error": "Cannot publish the TyranoScript cache"}
    return {"entry": project.path_join("index.html")}

func _digest(file: FileAccess) -> String:
    var hash := HashingContext.new()
    hash.start(HashingContext.HASH_SHA256)
    file.seek(0)
    var remaining := file.get_length()
    while remaining > 0:
        if _is_cancelled():
            _fail("ASAR preparation cancelled")
            return ""
        var chunk := file.get_buffer(mini(remaining, 1024 * 1024))
        if chunk.is_empty():
            _fail("ASAR resource changed while hashing")
            return ""
        hash.update(chunk)
        remaining -= chunk.size()
    return hash.finish().hex_encode()

func _input(relative: String) -> FileAccess:
    var item: Dictionary = entries[relative]
    var path := _external_path(relative) if item.unpacked else source
    if path.is_empty():
        return null
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or (item.unpacked and file.get_length() != int(item.size)):
        _fail("Missing or changed ASAR resource: " + relative)
        return null
    if not item.unpacked:
        file.seek(payload + int(item.offset))
    return file

func _external_path(relative: String) -> String:
    var path := source.get_base_dir()
    for part in (source.get_file() + ".unpacked/" + relative).split("/"):
        # Check each component; a nested symlink must not escape app.asar.unpacked.
        var directory := DirAccess.open(path)
        if directory == null or directory.is_link(part):
            _fail("Missing or unsafe unpacked ASAR resource: " + relative)
            return ""
        path = path.path_join(part)
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or file.get_length() != int(entries[relative].size):
        _fail("Missing or changed unpacked ASAR resource: " + relative)
        return ""
    return path

static func _integer(value: Variant) -> int:
    if value is String:
        if value.is_empty():
            return -1
        for byte in value.to_utf8_buffer():
            if byte < 48 or byte > 57:
                return -1
        if value.length() > 16:
            return -1
        return value.to_int()
    if (value is float or value is int) and value >= 0 and value <= MAX_BYTES and value == floor(value):
        return int(value)
    return -1

func _fail(message: String) -> bool:
    error = message
    return false

static func _remove(path: String) -> void:
    var directory := DirAccess.open(path)
    if directory == null:
        return
    for name in directory.get_files():
        DirAccess.remove_absolute(path.path_join(name))
    for name in directory.get_directories():
        if directory.is_link(name):
            DirAccess.remove_absolute(path.path_join(name))
        else:
            _remove(path.path_join(name))
    DirAccess.remove_absolute(path)
