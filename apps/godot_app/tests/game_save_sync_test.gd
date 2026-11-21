extends SceneTree

class Player extends Node:
    var result := ""
    var calls: Array = []
    func native_cloud_save_sync_begin(action: String, path: String, game: String) -> bool:
        calls.append([action, path, game])
        return true
    func native_cloud_save_sync_take_result() -> String:
        var value := result
        result = ""
        return value

class Host extends Node:
    const STARTUP_RUNNING := 1
    var game_running := false
    var game_storage_busy := false
    var cached_startup_state := 0
    var tyrano := false
    var launches := 0
    var detected_engines := {}
    var startup_overrides := {}
    var player := Player.new()
    func _game_runtime_root(path: String) -> String:
        return path
    func _game_runtime_kind(path: String) -> String:
        return String(detected_engines.get(path, "kirikiri"))
    func _game_runtime_kind_for_launch(path: String, startup_script: String) -> String:
        if not startup_script.is_empty() and startup_script == startup_overrides.get(path):
            return "qlie"
        return _game_runtime_kind(path)
    func _is_tyrano_active() -> bool:
        return tyrano
    func _is_renpy_active() -> bool:
        return false
    func launch() -> void:
        launches += 1
        game_running = true

class Service extends "res://scripts/game_save_sync.gd":
    var notices: Array[String] = []
    func supported() -> bool:
        return true
    func _refresh() -> void:
        pass
    func _notice(message: String) -> void:
        notices.append(message)

func _initialize() -> void:
    call_deferred("run")

func run() -> void:
    var fixture := DirAccess.create_temp("aether-save-sync")
    var path := fixture.get_current_dir()
    var game := {"name": "Display name", "path": path.path_join("游戏一")}
    var other := {"name": "Other", "engine": "qlie", "path": path.path_join("游戏二")}
    DirAccess.make_dir_recursive_absolute(game.path)
    var qlie_saves := String(other.path).path_join("SaveData")
    DirAccess.make_dir_recursive_absolute(qlie_saves)
    var host := Host.new()
    host.detected_engines[other.path] = "qlie"
    host.add_child(host.player)
    root.add_child(host)
    var service := Service.new()
    host.add_child(service)
    assert(not service.enabled(game))
    service.set_enabled(game, true)
    assert(service.busy and not service.enabled(game))
    assert(host.player.calls.back() == ["enable", String(game.path).path_join("savedata"), "游戏一"])
    host.player.result = JSON.stringify({"status": "error", "error": "Offline"})
    service._process(0)
    assert(not service.busy and not service.enabled(game))
    service.set_enabled(game, true)
    host.player.result = JSON.stringify({"status": "ready"})
    service._process(0)
    assert(service.enabled(game) and not service.enabled(other))
    service.prepare_start(game, host.launch)
    assert(host.launches == 0)
    service.prepare_start(other, host.launch)
    assert(host.launches == 0) # cannot bypass a pending download
    host.player.result = JSON.stringify({"status": "ready"})
    service._process(0)
    assert(host.launches == 1 and service.tracking)
    service._process(0)
    service.flush()
    assert(host.player.calls.back()[0] == "flush")
    host.game_running = false
    service._process(0)
    assert(not service.tracking and host.player.calls.back()[0] == "stop")
    # Web runtimes also keep the watcher alive and flush on close.
    service.tracking = true
    service.was_running = false
    host.tyrano = true
    service._process(0)
    assert(service.was_running)
    host.tyrano = false
    service._process(0)
    assert(not service.tracking)
    service.set_enabled(game, false)
    assert(not service.enabled(game))
    for entry: Dictionary in [other, {"path": other.path, "engine": "kirikiri"}, {"path": other.path}]:
        service.set_enabled(entry, true)
        assert(host.player.calls.back() == ["enable", qlie_saves, "游戏二"])
        host.player.result = JSON.stringify({"status": "ready"})
        service._process(0)
        service.prepare_start(entry, host.launch)
        assert(host.player.calls.back() == ["start", qlie_saves, "游戏二"])
        host.player.result = JSON.stringify({"status": "ready"})
        service._process(0)
        assert(service.tracking)
        service.stop()
        host.game_running = false
        service.set_enabled(entry, false)
        assert(host.player.calls.back() == ["disable", "", ""])
    host.detected_engines.erase(other.path)
    var override_game := {"path": other.path, "engine": "kirikiri", "startupScript": "Script/alternate.s"}
    host.startup_overrides[other.path] = override_game.startupScript
    service.set_enabled(override_game, true)
    assert(host.player.calls.back() == ["enable", qlie_saves, "游戏二"])
    host.player.result = JSON.stringify({"status": "ready"})
    service._process(0)
    service.prepare_start(override_game, host.launch)
    assert(host.player.calls.back() == ["start", qlie_saves, "游戏二"])
    host.player.result = JSON.stringify({"status": "ready"})
    service._process(0)
    service.stop()
    host.free()
    preload("res://scripts/game_library_storage.gd")._remove_entry(path)
    print("GAME_SAVE_SYNC_OK: defaults, failed download, persistence, launch gate, lifecycle, game isolation, QLIE save paths")
    quit()
