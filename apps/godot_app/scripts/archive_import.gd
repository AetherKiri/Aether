extends Node

signal changed
signal entries_changed
signal extracted(destination: String)

const INDEX := "user://archive_import.cfg"
const GAMES := "user://Games"
const IDLE := {"phase": "idle", "path": "", "name": "", "format": "", "destination": "", "progress": -1.0, "message": ""}

var state := IDLE.duplicate()
var entries: Array[Dictionary] = []
var hide_extracted := true
var layout := "smart"
var conflict := "keep"
var destination_dir := ""
var last_destination := ""
const LAYOUTS := ["smart", "direct", "folder", "strip"]
const CONFLICTS := ["keep", "skip", "stop", "replace"]
var _index := ConfigFile.new()
var _paths := PackedStringArray()
var _root := ""
var _reader: RefCounted
var _thread: Thread
var _cleanup_thread: Thread
var _cleaner: RefCounted
var _operation := ""
var _passphrase := ""
var _cancel_pending := false

func _ready() -> void:
    set_process(false)
    if not available():
        return
    _root = ProjectSettings.globalize_path(GAMES)
    DirAccess.make_dir_recursive_absolute(_root)
    _index.load(INDEX)
    var saved := String(_index.get_value("settings", "last_destination", ""))
    last_destination = ProjectSettings.globalize_path(saved) if not saved.is_empty() else ""
    _paths = _index.get_value("library", "paths", PackedStringArray())
    hide_extracted = bool(_index.get_value("settings", "hide_extracted", true))
    _cleaner = ClassDB.instantiate("AetherArchiveReader")
    # An interrupted extraction may contain gigabytes; remove it off the UI thread.
    _cleanup_thread = Thread.new()
    var roots := PackedStringArray([_root])
    var interrupted := String(_index.get_value("recovery", "destination", ""))
    if not interrupted.is_empty():
        var previous := ProjectSettings.globalize_path(interrupted)
        if not roots.has(previous):
            roots.append(previous)
    var cleaner := _cleaner
    if _cleanup_thread.start(func():
        for dir in roots:
            cleaner.clean_interrupted(dir)
    ) != OK:
        _cleanup_thread = null
        _cleaner = null
    refresh()

func available() -> bool:
    return ClassDB.class_exists("AetherArchiveReader")

func set_hide_extracted(value: bool) -> void:
    hide_extracted = value
    _index.set_value("settings", "hide_extracted", value)
    _index.save(INDEX)
    refresh()
    changed.emit()

func import_file(path: String) -> bool:
    if not available():
        return false
    if OS.get_name() == "Android" and path.begins_with("content://"):
        var local: String = get_parent()._android_launch_file_path(path)
        if not local.begins_with("content://") and FileAccess.open(local, FileAccess.READ) != null:
            # Native extractors can also discover adjacent volumes on this path.
            var old := _paths.find(path)
            if old >= 0:
                _paths.remove_at(old)
            return _register_file(local)
        if _thread != null:
            return false
        var filename := _android_document_name(path)
        state = IDLE.duplicate()
        state.merge({"phase": "importing", "name": filename, "path": path}, true)
        _reader = ClassDB.instantiate("AetherArchiveReader")
        _import_notice("import.progress", [filename, "…"], 2200)
        _start("copy", _reader.copy_provider_file.bind(path, _root, filename))
        return _thread != null
    return _register_file(path)

func _android_document_name(path: String) -> String:
    var name_hint := path.get_file().uri_file_decode().get_file()
    var runtime := Engine.get_singleton("AndroidRuntime")
    if runtime != null:
        var uri = JavaClassWrapper.wrap("android.net.Uri").parse(path)
        var resolver = runtime.getActivity().getContentResolver()
        var cursor = resolver.query(uri, PackedStringArray(["_display_name"]), "", PackedStringArray(), "", null)
        if cursor != null:
            var column: int = cursor.getColumnIndex("_display_name")
            if column >= 0 and cursor.moveToFirst():
                name_hint = str(cursor.getString(column))
            cursor.close()
    return name_hint.get_file() if not name_hint.is_empty() else "Archive"

func _register_file(path: String) -> bool:
    if not FileAccess.file_exists(path):
        return false
    path = path.simplify_path()
    if not _paths.has(path):
        _paths.append(path)
    _index.set_value("library", "paths", _paths)
    # Explicitly reimporting a source also makes its row available again.
    if _index.has_section(path):
        _index.erase_section(path)
    if _index.has_section(_index_path(path)):
        _index.erase_section(_index_path(path))
    _index.save(INDEX)
    refresh()
    return true

func refresh() -> void:
    if not available():
        return
    var paths := _paths.duplicate()
    if OS.get_name() == "iOS":
        for file in DirAccess.get_files_at(_root):
            var path := _root.path_join(file)
            if not file.begins_with(".") and not paths.has(path) and not _index.get_value(_index_path(path), "game_entry", _index.get_value(path, "game_entry", false)):
                paths.append(path)
    var next: Array[Dictionary] = []
    for path in paths:
        if not FileAccess.file_exists(path):
            continue
        var size := FileAccess.get_size(path)
        var key := _index_path(path) if _index.has_section(_index_path(path)) else path
        var stored := String(_index.get_value(key, "destination", ""))
        var destination := ProjectSettings.globalize_path(stored) if not stored.is_empty() else ""
        if hide_extracted and not destination.is_empty() and (DirAccess.dir_exists_absolute(destination) or FileAccess.file_exists(destination)) \
                and int(_index.get_value(key, "size", -1)) == size \
                and int(_index.get_value(key, "modified", -1)) == FileAccess.get_modified_time(path):
            continue
        next.append({"path": path, "name": path.get_file(), "size": size})
    if next != entries:
        entries = next
        entries_changed.emit()

func games_folder() -> String:
    return _root if not _root.is_empty() else ProjectSettings.globalize_path(GAMES)

func _index_path(path: String) -> String:
    # The absolute iOS Documents path may change when the app is updated.
    var base := games_folder()
    if path == base or path.begins_with(base + "/"):
        return GAMES + path.substr(base.length())
    return path

func _writable(path: String) -> bool:
    return path.is_absolute_path() and bool(ClassDB.class_call_static("AetherArchiveReader", "is_writable_directory", path))

func choose_destination(path: String) -> bool:
    if path.is_empty():
        return false
    var resolved := path
    if OS.get_name() == "Android" and path.begins_with("content://"):
        resolved = get_parent()._android_external_storage_path_from_tree_uri(path)
    resolved = ProjectSettings.globalize_path(resolved).simplify_path()
    var games := games_folder()
    if not _writable(resolved):
        return false
    if OS.get_name() == "iOS" and resolved != games and not resolved.begins_with(games + "/"):
        return false
    destination_dir = resolved
    changed.emit()
    return true

func set_layout(value: String) -> void:
    if value in LAYOUTS and (value != "strip" or state.get("placement", {}).get("can_strip", false)):
        layout = value
        changed.emit()

func set_conflict(value: String) -> void:
    if value in CONFLICTS:
        conflict = value
        changed.emit()

func location_options() -> Dictionary:
    var base := games_folder()
    var current := destination_dir if not destination_dir.is_empty() else base
    var choices := {base: get_parent()._t("archive.games")}
    var source := String(state.get("path", "")).get_base_dir()
    for item in [[source, "source"], [OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS), "documents"], [last_destination, "last"]]:
        var dir := String(item[0])
        if dir.is_empty() or choices.has(dir) or not _writable(dir):
            continue
        if OS.get_name() == "iOS" and not dir.begins_with(base + "/"):
            continue
        choices[dir] = get_parent()._t("archive." + item[1])
    if not choices.has(current):
        choices[current] = current.get_file()
    choices["@choose"] = get_parent()._t("archive.choose")
    return choices

func pick_folder(selected: Callable) -> FileDialog:
    var host = get_parent()
    var picker: FileDialog = host._create_file_dialog(host._t("archive.choose"), FileDialog.FILE_MODE_OPEN_DIR)
    if OS.get_name() == "iOS":
        picker.use_native_dialog = false
        picker.root_subfolder = games_folder()
    picker.current_dir = destination_dir if not destination_dir.is_empty() else games_folder()
    picker.dir_selected.connect(selected)
    host.add_child(picker)
    picker.popup_centered_clamped(Vector2i(760, 530), 0.88)
    return picker

func output_preview() -> String:
    var base := destination_dir if not destination_dir.is_empty() else games_folder()
    var placement: Dictionary = state.get("placement", {})
    var common := String(placement.get("common_directory", ""))
    var archive_name := String(placement.get("archive_name", state.get("name", "").get_basename()))
    var single := String(placement.get("single_file", ""))
    var leaf := ""
    var numbered := false
    match layout:
        "smart":
            if placement.is_empty() or placement.get("inner_archive", false):
                return base
            var subdir := String(placement.get("smart_subdir", ""))
            if not single.is_empty() and not placement.get("has_launcher", false):
                leaf = single
            else:
                leaf = subdir.get_file() if not subdir.is_empty() else archive_name
                if leaf.begins_with("."):
                    leaf = archive_name
                numbered = true
        "direct": leaf = common if not common.is_empty() else single
        "folder":
            leaf = archive_name
            numbered = true
    if leaf.is_empty():
        return base
    var path := base.path_join(leaf)
    if numbered or (leaf == single and conflict == "keep"):
        var n := 2
        while (FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)) and n <= 10000:
            var name := "%s (%d)" % [leaf if numbered else leaf.get_basename(), n]
            if not numbered and not leaf.get_extension().is_empty():
                name += "." + leaf.get_extension()
            path = base.path_join(name)
            n += 1
    return path

func inspect(path: String) -> void:
    if not available() or _thread != null:
        return
    if String(state.path) != path:
        destination_dir = games_folder()
        layout = "smart"
        conflict = "keep"
        _passphrase = ""
    state = IDLE.duplicate()
    state.merge({"phase": "inspecting", "path": path, "name": path.get_file(), "destination": _root}, true)
    _reader = ClassDB.instantiate("AetherArchiveReader")
    _start("inspect", _reader.inspect.bind(path))

func extract(password: String) -> void:
    if _thread != null or state.phase not in ["ready", "password", "error"]:
        return
    _reader = ClassDB.instantiate("AetherArchiveReader")
    state.progress = -1.0
    state.message = ""
    if state.get("locked_catalog", false):
        _passphrase = password
        state.phase = "inspecting"
        _start("unlock", _reader.inspect.bind(state.path, password))
        return
    state.phase = "extracting"
    _index.set_value("recovery", "destination", _index_path(destination_dir))
    _index.save(INDEX)
    var value := password if not password.is_empty() else _passphrase
    _start("extract", _reader.extract_to.bind(state.path, destination_dir, value, layout, conflict, games_folder()))

func cancel() -> void:
    _passphrase = ""
    if _reader != null and _thread != null:
        _cancel_pending = true
        _reader.cancel()
    else:
        dismiss()

func dismiss() -> void:
    _passphrase = ""
    if _thread != null:
        cancel()
        return
    state = IDLE.duplicate()
    changed.emit()

func _start(operation: String, work: Callable) -> void:
    _cancel_pending = false
    _operation = operation
    _thread = Thread.new()
    if _thread.start(work) == OK:
        set_process(true)
    else:
        _thread = null
        state.phase = "error"
        state.message = error_string(ERR_CANT_CREATE)
    changed.emit()

func _process(_delta: float) -> void:
    if _thread.is_alive():
        if _operation in ["extract", "copy"]:
            var fraction := float(_reader.get_progress())
            if fraction != state.progress:
                state.progress = fraction
                if _operation == "copy":
                    _import_notice("import.progress", [state.name, "%d%%" % roundi(fraction * 100)], 0)
                changed.emit()
        return
    var result: Variant = _thread.wait_to_finish()
    _thread = null
    set_process(false)
    var status := int(result.status)
    if _operation == "extract" and _index.has_section("recovery"):
        _index.erase_section("recovery")
        _index.save(INDEX)
    if _operation == "copy":
        if status == OK:
            _register_file(result.destination)
            _import_notice("import.complete", [state.name], 2200)
        else:
            _import_notice("import.failed", [result.message], 4000)
        _reader = null
        state = IDLE.duplicate()
        changed.emit()
        return
    if _operation in ["inspect", "unlock"]:
        state.locked_catalog = status in [-12, -13]
        state.placement = result.placement
        if status == OK and layout == "strip" and not result.placement.can_strip:
            layout = "smart"
    if not String(result.format).is_empty():
        state.format = result.format
    var key: String = {-2: "archive.io", -13: "archive.bad_password", -4: "archive.unknown", -5: "archive.damaged",
        -11: "archive.missing", -16: "archive.no_space", -10: "archive.conflict"}.get(status, "")
    state.message = get_parent()._t(key) if not key.is_empty() else result.message
    if status == -12:
        state.message = ""
    state.entries = result.entries
    state.bytes = result.bytes
    if status == -9 or (_cancel_pending and not (_operation == "extract" and status == OK)):
        state = IDLE.duplicate()
    elif status in [-12, -13] or (_operation == "inspect" and status == OK and result.encrypted):
        _passphrase = ""
        state.phase = "password"
    elif status != OK:
        state.phase = "error"
    elif _operation in ["inspect", "unlock"]:
        state.phase = "ready"
    else:
        _passphrase = ""
        state.phase = "done"
        state.progress = 1.0
        state.destination = result.destination
        state.owned_root = result.destination if layout in ["smart", "folder"] else result.game_root
        var members := PackedStringArray(result.get("members", []))
        if members.is_empty():
            members.append(state.path)
        for path in members:
            _index.set_value(_index_path(path), "destination", _index_path(result.destination))
            _index.set_value(_index_path(path), "size", FileAccess.get_size(path))
            _index.set_value(_index_path(path), "modified", FileAccess.get_modified_time(path))
        last_destination = destination_dir
        _index.set_value("settings", "last_destination", _index_path(last_destination))
        if not String(result.game_root).is_empty() and FileAccess.file_exists(String(result.game_root)):
            _index.set_value(_index_path(String(result.game_root)), "game_entry", true)
        _index.save(INDEX)
        extracted.emit(String(result.game_root))
        refresh()
    _reader = null
    changed.emit()

func _import_notice(key: String, args: Array, duration: int) -> void:
    var host := get_parent()
    host._show_game_import_notice(host._t(key, args), duration)

func _exit_tree() -> void:
    if _reader != null:
        _reader.cancel()
    if _thread != null:
        _thread.wait_to_finish()
    if _cleanup_thread != null:
        _cleanup_thread.wait_to_finish()
