extends SceneTree
## Native callbacks may arrive after the user has navigated to another game.
const Archive := preload("res://scripts/game_save_archive.gd")

class FakePlayer extends Node:
    var result := ""
    var path := ""
    var action := ""
    func native_save_transfer_begin(value: String, archive: String, _folder: String, _title: String) -> bool:
        action = value
        path = archive
        return true
    func native_save_transfer_take_result() -> String:
        var value := result
        result = ""
        return value

class Host extends Node:
    var game_running := false
    var player := FakePlayer.new()
    var selected_game := {}
    var detected_engines := {}
    func _game_display_title(game: Dictionary) -> String:
        return game.name
    func _game_runtime_root(path: String) -> String:
        return path
    func _game_runtime_kind(path: String) -> String:
        return String(detected_engines.get(path, "kirikiri"))

class Service extends "res://scripts/game_save_transfer.gd":
    var storage := ""
    var platform := "macOS"
    var file_dialog_opened := false
    var notices: Array[String] = []
    func _storage_path(relative: String) -> String:
        return storage.path_join(relative)
    func _platform_name() -> String:
        return platform
    func _save_to_file() -> void:
        # Route desktop exports without opening a system picker in headless CI.
        file_dialog_opened = true
        phase = "file_dialog"
    func _notice(message: String) -> void:
        notices.append(message)
    func _refresh() -> void:
        pass

var failures := 0
var fixture: DirAccess
var service: Service
var host: Host

func check(value: bool, message: String) -> void:
    if not value:
        failures += 1
        printerr("FAIL: " + message)

func put(path: String, content: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(content)
    file.close()

func settle(expected_phase: String) -> bool:
    var deadline := Time.get_ticks_msec() + 5000
    while Time.get_ticks_msec() < deadline:
        if (expected_phase.is_empty() and not service.busy) or (not expected_phase.is_empty() and service.phase == expected_phase):
            return true
        await create_timer(0.01).timeout
    check(false, "Transfer completed before timeout: %s (actual: %s, notices: %s)" % [expected_phase, service.phase, service.notices])
    return false

func finish() -> void:
    host.queue_free()
    await process_frame
    print("Save transfer failures: %d" % failures)
    quit(0 if failures == 0 else 1)

func _initialize() -> void:
    call_deferred("run")

func run() -> void:
    fixture = DirAccess.create_temp("aether-transfer-test")
    var path := fixture.get_current_dir()
    host = Host.new()
    host.add_child(host.player)
    root.add_child(host)
    service = Service.new()
    service.storage = path.path_join("storage")
    host.add_child(service)
    var game := {"name": "Game A", "engine": "catsystem2", "path": path.path_join("A")}
    var other := {"name": "Game B", "engine": "catsystem2", "path": path.path_join("B")}
    var save := String(game.path).path_join("savedata/slot.dat")
    var other_save := String(other.path).path_join("savedata/slot.dat")
    put(save, "cloud state")
    put(other_save, "other game")
    service.start("share", game)
    host.selected_game = other
    game.name = "Changed after export began"
    if not await settle("native"):
        await finish()
        return
    var zip := ZIPReader.new()
    var opened := zip.open(host.player.path) == OK
    check(opened, "Share receives a real completed ZIP")
    if not opened:
        await finish()
        return
    var manifest = JSON.parse_string(zip.read_file(Archive.MANIFEST).get_string_from_utf8())
    check(manifest is Dictionary and manifest.get("game_name") == "Game A", "Export snapshots the game before asynchronous work")
    zip.close()
    var exported := host.player.path
    host.player.result = '{"status":"presented"}'
    if not await settle(""):
        await finish()
        return
    check(FileAccess.file_exists(exported), "Shared ZIP remains readable by the receiving app")
    put(save, "local state before sync")
    game.name = "Game A"
    service.start("download", game)
    host.selected_game = other
    service.start("download", other)
    check(service.game_name == "Game A", "A second transfer cannot replace an active operation")
    check(DirAccess.copy_absolute(exported, host.player.path) == OK, "Fake cloud supplies the selected archive")
    host.player.result = '{"status":"downloaded"}'
    if not await settle(""):
        await finish()
        return
    check(FileAccess.get_file_as_string(save) == "cloud state", "Downloaded saves restore the original game despite navigation")
    check(FileAccess.get_file_as_string(other_save) == "other game", "Navigation never redirects restore into another game")
    var backups := DirAccess.open(path.path_join("storage/save_backups").path_join(Archive.folder_name("Game A")))
    check(backups != null and backups.get_files().size() == 1, "Sync retains an automatic local backup")
    check(not FileAccess.file_exists(host.player.path), "Cloud temporary archive is removed after restore")
    service.start("download", other)
    host.player.result = '{"status":"cancelled"}'
    if not await settle(""):
        await finish()
        return
    check(not service.busy and FileAccess.get_file_as_string(other_save) == "other game", "Cancelling the cloud picker does not modify saves")
    host.game_running = true
    var before := host.player.path
    service.start("share", game)
    check(not service.busy and host.player.path == before, "A running game cannot be exported or overwritten")
    host.game_running = false
    # Every runner exercises both platform branches, regardless of its own OS.
    for platform: String in ["macOS", "iOS", "Android", "Linux", "Windows"]:
        service.platform = platform
        service.file_dialog_opened = false
        host.player.path = ""
        host.player.action = ""
        service.start("share", game)
        var native_share := platform in ["macOS", "iOS", "Android"]
        if not await settle("native" if native_share else "file_dialog"):
            await finish()
            return
        if native_share:
            check(host.player.action == "share" and FileAccess.file_exists(host.player.path), platform + " shares the completed ZIP through the native bridge")
            check(not service.file_dialog_opened, platform + " does not open the desktop save picker")
            host.player.result = '{"status":"cancelled"}'
            if not await settle(""):
                await finish()
                return
        else:
            check(service.file_dialog_opened and FileAccess.file_exists(service.archive_path), platform + " offers the completed ZIP through a save picker")
            check(host.player.action.is_empty(), platform + " does not call the unsupported native share bridge")
            service._finish("")
    service.platform = "iOS"
    var qlie_root := path.path_join("QLIE")
    var qlie := {"name": "QLIE", "engine": "kirikiri", "path": qlie_root}
    host.detected_engines[qlie_root] = "qlie"
    put(qlie_root.path_join("SaveData/story.svd"), "native save")
    service.start("share", qlie)
    if await settle("native"):
        var qlie_zip := ZIPReader.new()
        var qlie_opened := qlie_zip.open(host.player.path) == OK
        check(qlie_opened, "Legacy QLIE library entries reach the share bridge")
        if qlie_opened:
            check(qlie_zip.read_file("main/story.svd").get_string_from_utf8() == "native save", "Share uses the QLIE save directory identified by the runtime probe")
            var qlie_manifest = JSON.parse_string(qlie_zip.read_file(Archive.MANIFEST).get_string_from_utf8())
            check(qlie_manifest is Dictionary and qlie_manifest.get("engine") == "qlie", "Legacy library entries produce portable archives with the QLIE engine")
            qlie_zip.close()
        host.player.result = '{"status":"presented"}'
        await settle("")
    await finish()
