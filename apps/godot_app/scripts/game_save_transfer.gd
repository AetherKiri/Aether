extends Node

const Archive := preload("res://scripts/game_save_archive.gd")
const Locations := preload("res://scripts/game_save_locations.gd")
var host
var busy := false
var worker: Thread
var operation := ""
var phase := ""
var game_name := ""
var game_engine := ""
var banks: Dictionary
var archive_path := ""
var snapshot: Dictionary

func _storage_path(relative: String) -> String:
    return ProjectSettings.globalize_path("user://".path_join(relative))

func _platform_name() -> String:
    return OS.get_name()

func _prune_exports(root: String) -> void:
    var directory := DirAccess.open(root)
    if directory == null:
        return
    var cutoff := int(Time.get_unix_time_from_system()) - 86400
    for name in directory.get_directories():
        if directory.is_link(name):
            continue
        var folder := directory.get_current_dir().path_join(name)
        var contents := DirAccess.open(folder)
        if contents == null:
            continue
        for file in contents.get_files():
            var path := folder.path_join(file)
            if not contents.is_link(file) and file.ends_with(".zip") and FileAccess.get_modified_time(path) < cutoff:
                DirAccess.remove_absolute(path)
        DirAccess.remove_absolute(folder) # Only succeeds when empty.

func _ready() -> void:
    host = get_parent()
    set_process(false)

func _text(zh: String, en: String, ja: String, es: String = "") -> String:
    if not es.is_empty() and str(host.get("active_language")) == "es":
        return es
    var shell = host.get_node_or_null("ShellInterface")
    return shell.text(zh, en, ja) if shell != null else en

func _notice(message: String) -> void:
    var shell = host.get_node_or_null("ShellInterface")
    if shell != null and is_instance_valid(shell.view) and shell.enabled:
        shell.view.show_notice(message)
    else:
        host._show_message(message)

func _refresh() -> void:
    var shell = host.get_node_or_null("ShellInterface")
    if shell != null and is_instance_valid(shell.view) and shell.enabled and shell.view.route == "detail":
        shell.view.rebuild(true)

func start(action: String, game: Dictionary) -> void:
    if busy or host.game_running:
        return
    if action not in ["share", "upload", "download"]:
        return
    archive_path = ""
    snapshot = game.duplicate(true)
    game_name = host._game_display_title(snapshot)
    var root: String = host._game_runtime_root(String(snapshot.get("path", "")))
    game_engine = String(snapshot.get("engine", ""))
    if game_engine.is_empty():
        game_engine = host._game_runtime_kind(String(snapshot.get("path", "")))
    banks = Locations.resolve(root, game_engine, snapshot)
    if banks.is_empty():
        _notice(_text("无法确定此游戏的独立存档目录，未读取其他游戏的存档。", "This game's separate save folder could not be identified.", "このゲーム専用のセーブフォルダーを特定できませんでした。", "No se ha podido identificar la carpeta de partidas guardadas propia de este juego."))
        return
    operation = action
    var exports := _storage_path("save_exports")
    _prune_exports(exports)
    var folder := exports.path_join(str(Time.get_unix_time_from_system()).replace(".", "-"))
    if DirAccess.make_dir_recursive_absolute(folder) != OK:
        _fail("write_failed")
        return
    archive_path = folder.path_join(Archive.folder_name(game_name) + ".zip")
    busy = true
    set_process(true)
    _refresh()
    if action == "download":
        _native()
    else:
        phase = "pack"
        worker = Thread.new()
        if worker.start(Archive.export_zip.bind(game_name, game_engine, banks, archive_path)) != OK:
            worker = null
            _fail("write_failed")

func _native() -> void:
    phase = "native"
    var player = host.player
    var title := _text("选择 iCloud Drive 存档文件夹", "Choose an iCloud Drive saves folder", "iCloud Drive のセーブフォルダーを選択", "Elige una carpeta de partidas guardadas de iCloud Drive")
    if operation == "share":
        title = game_name + " · " + _text("存档", "Saves", "セーブデータ", "Partidas guardadas")
    if _platform_name() not in ["macOS", "iOS", "Android"] and operation == "share":
        _save_to_file()
        return
    if player == null or not player.has_method("native_save_transfer_begin") \
        or not player.native_save_transfer_begin(operation, archive_path, Archive.folder_name(game_name), title):
        _fail("cloud_failed" if operation != "share" else "unavailable")

func _save_to_file() -> void:
    var dialog := FileDialog.new()
    dialog.access = FileDialog.ACCESS_FILESYSTEM
    dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
    dialog.use_native_dialog = true
    dialog.filters = PackedStringArray(["*.zip ; ZIP"])
    dialog.current_file = archive_path.get_file()
    dialog.file_selected.connect(func(path: String):
        var error := DirAccess.copy_absolute(archive_path, path)
        dialog.queue_free()
        if error != OK:
            _fail("write_failed")
        else:
            _finish(_text("存档已导出。", "Saves exported.", "セーブデータを書き出しました。", "Partidas guardadas exportadas."))
    )
    dialog.canceled.connect(func():
        dialog.queue_free()
        _finish("")
    )
    add_child(dialog)
    dialog.popup_centered_ratio(0.7)
    phase = "file_dialog"

func _process(_delta: float) -> void:
    if worker != null:
        if worker.is_alive():
            return
        var result: Dictionary = worker.wait_to_finish()
        worker = null
        if not result.ok:
            _fail(String(result.error))
        elif phase == "pack":
            _native()
        else:
            if String(result.get("backup", "")).is_empty():
                _finish(_text("当前游戏的存档已同步。", "This game's saves are synced.", "このゲームのセーブデータを同期しました。", "Las partidas guardadas de este juego están sincronizadas."))
            else:
                _finish(_text("当前游戏的存档已同步，本地旧存档已备份。", "This game's saves are synced. Previous local saves were backed up.", "このゲームのセーブデータを同期しました。以前のデータはバックアップ済みです。", "Las partidas guardadas de este juego están sincronizadas. Se ha hecho una copia de seguridad de las partidas guardadas locales anteriores."))
        return
    if phase != "native" or host.player == null:
        return
    var value := String(host.player.native_save_transfer_take_result())
    if value.is_empty():
        return
    var result = JSON.parse_string(value)
    if not result is Dictionary:
        _fail("invalid_archive")
        return
    match result.get("status", "error"):
        "downloaded":
            # The snapshot is captured before any async work; never substitute
            # whatever game happens to be selected when the download completes.
            phase = "restore"
            var backup := _storage_path("save_backups").path_join(Archive.folder_name(game_name)).path_join(archive_path.get_base_dir().get_file() + ".zip")
            worker = Thread.new()
            if worker.start(Archive.import_zip.bind(game_name, game_engine, banks, archive_path, backup)) != OK:
                worker = null
                _fail("write_failed")
        "uploaded":
            _finish(_text("已保存至 iCloud Drive，系统将继续上传。", "Saved to iCloud Drive. The system will finish uploading.", "iCloud Drive に保存しました。アップロードはシステムが続行します。", "Guardado en iCloud Drive. El sistema terminará la subida."))
        "shared", "presented", "cancelled":
            _finish("")
        "not_icloud":
            _fail("not_icloud")
        "not_found":
            _fail("not_found")
        _:
            _fail("cloud_failed" if operation != "share" else "unavailable")

func _fail(reason: String) -> void:
    var messages := {
        "no_saves": _text("当前游戏还没有可导出的存档。", "This game has no saves to export yet.", "このゲームには書き出せるセーブデータがありません。", "Este juego aún no tiene partidas guardadas que exportar."),
        "different_game": _text("存档的游戏名或引擎不匹配，未修改本地存档。", "The game name or engine does not match. Local saves were not changed.", "ゲーム名またはエンジンが一致しません。ローカルデータは変更していません。", "El nombre del juego o el motor no coinciden. No se han modificado las partidas guardadas locales."),
        "invalid_archive": _text("存档压缩包无效或已损坏，未修改本地存档。", "The save archive is invalid or damaged. Local saves were not changed.", "セーブの圧縮ファイルが無効または破損しています。", "El archivo de partidas guardadas no es válido o está dañado. No se han modificado las partidas guardadas locales."),
        "unsafe_path": _text("存档路径异常，操作已停止。", "An unsafe save path was detected. The operation was stopped.", "セーブのパスに問題があるため中止しました。", "Se ha detectado una ruta de partidas guardadas no segura. Se ha detenido la operación."),
        "too_large": _text("存档过大，无法打包。", "The save bank is too large to package.", "セーブデータが大きすぎます。", "Las partidas guardadas ocupan demasiado para empaquetarlas."),
        "not_icloud": _text("请选择 iCloud Drive 中的文件夹，两台设备需选择同一个文件夹。", "Choose a folder in iCloud Drive. Select the same folder on both devices.", "iCloud Drive 内の同じフォルダーを両方の端末で選択してください。", "Elige una carpeta de iCloud Drive. Selecciona la misma carpeta en ambos dispositivos."),
        "not_found": _text("iCloud 中没有找到当前游戏的存档，请先在另一台设备上传。", "No iCloud saves were found for this game. Upload them from your other device first.", "このゲームの iCloud セーブがありません。別の端末から先にアップロードしてください。", "No se han encontrado partidas guardadas de este juego en iCloud. Súbelas antes desde tu otro dispositivo."),
        "cloud_failed": _text("iCloud 操作未完成，请检查网络和文件夹访问权限后重试。", "iCloud could not complete the operation. Check your connection and folder access, then retry.", "iCloud 操作を完了できませんでした。通信とフォルダーへのアクセスを確認してください。", "iCloud no ha podido completar la operación. Comprueba la conexión y el acceso a la carpeta y vuelve a intentarlo."),
        "unavailable": _text("系统分享暂时无法打开，请稍后重试。", "System sharing is unavailable. Please try again.", "システムの共有を開けませんでした。", "La función de compartir del sistema no está disponible. Vuelve a intentarlo."),
        "rollback_failed": _text("存档恢复未完成，自动回滚失败。原存档备份保留在 save_backups 中，请勿继续游戏。", "Restore and rollback did not complete. The original backup is in save_backups; do not resume the game yet.", "復元とロールバックに失敗しました。元のデータは save_backups にあります。ゲームを再開しないでください。", "No se han completado la restauración ni la reversión. La copia de seguridad original está en save_backups; no reanudes el juego todavía."),
    }
    _finish(String(messages.get(reason, _text("存档读写失败，未能完成操作。", "Could not read or write the saves.", "セーブデータを読み書きできませんでした。", "No se han podido leer ni escribir las partidas guardadas."))))

func _finish(message: String) -> void:
    busy = false
    set_process(false)
    _refresh()
    if not message.is_empty():
        _notice(message)
    # Cloud archives have no external readers. Share copies remain available
    # for receiving apps; subsequent exports prune only files older than a day.
    if not archive_path.is_empty():
        if operation != "share" and FileAccess.file_exists(archive_path):
            DirAccess.remove_absolute(archive_path)
        DirAccess.remove_absolute(archive_path.get_base_dir())

func _exit_tree() -> void:
    if worker != null and worker.is_started():
        worker.wait_to_finish()
