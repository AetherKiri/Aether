extends Node

const Config := preload("res://scripts/game_render_config.gd")
const Locations := preload("res://scripts/game_save_locations.gd")
var host
var busy := false
var pending: Dictionary = {}
var continuation: Callable
var tracking := false
var was_running := false
var action := ""
var launch_started_msec := 0

func _ready() -> void:
    host = get_parent()

func supported() -> bool:
    return OS.get_name() == "iOS"

func _root(game: Dictionary) -> String:
    return String(host._game_runtime_root(String(game.get("path", "")))).trim_suffix("/")

func enabled(game: Dictionary) -> bool:
    var loaded := Config.read(_root(game))
    var saves = loaded.document.get("saves", {})
    return loaded.error == OK and saves is Dictionary and saves.get("icloud_auto_sync", false) == true

func _persist(game: Dictionary, value: bool) -> Error:
    var loaded := Config.read(_root(game))
    if loaded.error != OK:
        return loaded.error
    var document: Dictionary = loaded.document
    var saves = document.get("saves", {})
    if not saves is Dictionary:
        return ERR_PARSE_ERROR
    saves["icloud_auto_sync"] = value
    document["saves"] = saves
    return Config.write_document(loaded.path, document)

func _refresh() -> void:
    var shell = host.get_node_or_null("ShellInterface")
    if shell != null and is_instance_valid(shell.view) and shell.enabled and shell.view.route == "detail":
        shell.view.rebuild(true)

func _notice(message: String) -> void:
    var shell = host.get_node_or_null("ShellInterface")
    if shell != null and is_instance_valid(shell.view) and shell.enabled:
        shell.view.show_notice(message)
    else:
        host._show_message(message)

func _native(operation: String, game: Dictionary = {}) -> bool:
    var player = host.player
    if player == null or not player.has_method("native_cloud_save_sync_begin"):
        return false
    if game.is_empty():
        return player.native_cloud_save_sync_begin(operation, "", "")
    var root := _root(game)
    var engine := Locations.save_engine(host, game)
    var saves := Locations.qlie_save_dir(root) if engine == "qlie" else Locations.game_root_save_dir(root, engine)
    return not saves.is_empty() and player.native_cloud_save_sync_begin(operation, saves, root.get_file())

func set_enabled(game: Dictionary, value: bool) -> void:
    if busy or _running() or host.game_storage_busy or not supported():
        return
    var transfer = host.get_node_or_null("GameSaveTransfer")
    if transfer != null and transfer.busy:
        return
    if not value:
        var error := _persist(game, false)
        if error == OK:
            _native("disable")
            tracking = false
        else:
            _notice(error_string(error))
        _refresh()
        return
    _begin("enable", game)

func prepare_start(game: Dictionary, after_sync: Callable) -> void:
    if busy:
        return
    if not supported() or not enabled(game):
        after_sync.call()
        return
    continuation = after_sync
    _begin("start", game)

func _begin(operation: String, game: Dictionary) -> void:
    pending = game.duplicate(true)
    action = operation
    if not _native(operation, pending):
        continuation = Callable()
        _notice("iCloud Drive unavailable")
        return
    busy = true
    _refresh()

func flush() -> void:
    if tracking:
        _native("flush")

func stop() -> void:
    if tracking:
        _native("stop")
        tracking = false
        was_running = false

func _running() -> bool:
    return host.game_running or host._is_tyrano_active() or host._is_renpy_active()

func cancel_for_storage() -> void:
    if not supported():
        return
    continuation = Callable()
    tracking = false
    was_running = false
    if not _native("disable"):
        busy = false
        return
    action = "disable"
    busy = true
    while busy:
        await get_tree().process_frame

func _process(_delta: float) -> void:
    if not supported():
        return
    if tracking:
        if _running():
            was_running = true
        elif was_running or (Time.get_ticks_msec() - launch_started_msec > 1000 and host.cached_startup_state != host.STARTUP_RUNNING):
            # One frame after teardown also catches saves written on shutdown.
            stop()
    if host.player == null or not host.player.has_method("native_cloud_save_sync_take_result"):
        return
    var text := String(host.player.native_cloud_save_sync_take_result())
    if text.is_empty():
        return
    var result = JSON.parse_string(text)
    if not result is Dictionary:
        return
    if action == "disable":
        if result.get("status") == "disabled":
            busy = false
            action = ""
        return
    if result.get("status") == "sync_error":
        _notice("iCloud: " + String(result.get("error", "")))
        return
    if not busy:
        return
    busy = false
    if result.get("status") != "ready":
        continuation = Callable()
        _notice("iCloud: " + String(result.get("error", "")))
        _refresh()
        return
    if action == "enable":
        var error := _persist(pending, true)
        if error != OK:
            _native("disable")
            _notice(error_string(error))
    else:
        tracking = true
        was_running = false
        launch_started_msec = Time.get_ticks_msec()
        if continuation.is_valid():
            var resume := continuation
            continuation = Callable()
            resume.call()
    _refresh()
