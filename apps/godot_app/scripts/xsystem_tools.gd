extends Node
## Local MOD operations run off the UI thread. The native transaction owns
## backups and recovery; this node owns worker lifetime and launch exclusion.

signal changed(game_root: String)
var host
var busy := false
var active_root := ""
var results: Dictionary = {}
var _worker: Thread
var _completion: Callable
var _native_worker
var _owns_native_worker := false

static func supports(runtime: String) -> bool:
    return runtime in ["xsystem4", "xsystem35"]

func setup(owner_host) -> void:
    host = owner_host

func request(game_root: String, operation: String = "list", argument: String = "", completion: Callable = Callable()) -> bool:
    if busy or host.game_running:
        return false
    if host.player == null or not host.player.has_method("manage_xsystem_mods"):
        results[game_root] = {"ok": false, "error": "unsupported_platform"}
        changed.emit(game_root)
        return false
    busy = true
    active_root = game_root
    _completion = completion
    _worker = Thread.new()
    # Keep the native receiver alive even if the launcher is closed while an
    # installation is finishing. Scene children may otherwise be freed first.
    _owns_native_worker = host.player.is_class("AetherRuntimePlayer")
    _native_worker = ClassDB.instantiate("AetherRuntimePlayer") if _owns_native_worker else host.player
    var native_player = _native_worker
    var error := _worker.start(func():
        return native_player.manage_xsystem_mods(game_root, operation, argument)
    )
    if error != OK:
        busy = false
        _worker = null
        _release_native_worker()
        results[game_root] = {"ok": false, "error": "io_failed"}
    changed.emit(game_root)
    return error == OK

func _process(_delta: float) -> void:
    if _worker == null or _worker.is_alive():
        return
    var raw: String = _worker.wait_to_finish()
    _worker = null
    _release_native_worker()
    var result = JSON.parse_string(raw)
    if result is Dictionary and not result.get("ok", false):
        result["mods"] = results.get(active_root, {}).get("mods", [])
    results[active_root] = result if result is Dictionary else {"ok": false, "error": "io_failed"}
    busy = false
    var done := _completion
    _completion = Callable()
    changed.emit(active_root)
    if done.is_valid():
        done.call(results[active_root])

func _exit_tree() -> void:
    if _worker != null and _worker.is_started():
        _worker.wait_to_finish()
        _worker = null
    _release_native_worker()

func _release_native_worker() -> void:
    if _owns_native_worker and is_instance_valid(_native_worker):
        _native_worker.free()
    _native_worker = null
    _owns_native_worker = false

static func text(owner_host, zh: String, en: String) -> String:
    var locale := String(owner_host.active_language) if "active_language" in owner_host else TranslationServer.get_locale()
    return zh if locale.begins_with("zh") else en

static func error_text(owner_host, code: String) -> String:
    match code:
        "source_overlaps_game": return text(owner_host, "请选择游戏目录以外的 MOD 文件或文件夹。", "Select a MOD outside the game folder.")
        "no_assets": return text(owner_host, "所选内容没有可安装的游戏资源。", "No installable game assets were found.")
        "unsafe_path": return text(owner_host, "此 MOD 含有不安全的路径或文件链接，未安装。", "The MOD contains unsafe paths or file links.")
        "invalid_archive": return text(owner_host, "无法打开压缩包，请先解压后选择文件夹。", "Cannot open this archive. Extract it and choose the folder.")
        "invalid_manifest", "recovery_failed": return text(owner_host, "MOD 备份记录无法读取或恢复，请保留 .aether-mods 目录。", "MOD backups could not be read or restored. Keep the .aether-mods folder.")
        "file_conflict": return text(owner_host, "MOD 中存在重复文件或目录冲突。", "The MOD contains duplicate files or a folder conflict.")
        "unsupported_platform": return text(owner_host, "当前构建不支持 MOD 安装。", "This build does not support MOD installation.")
        "invalid_source": return text(owner_host, "无法读取所选文件，请重新选择。", "Cannot read the selected file. Please select it again.")
        "too_large": return text(owner_host, "MOD 文件数量或解压大小超过限制。", "The MOD exceeds the file count or extraction size limit.")
        _: return text(owner_host, "操作未完成，请检查可用空间和目录读写权限。", "Operation failed. Check free space and folder permissions.")
