extends SceneTree

const Probe = preload("res://scripts/runtime_regression_probe.gd")

class FakePlayer:
    extends RefCounted
    var queries := 0
    var initialized := true

    func is_initialized() -> bool:
        return initialized

    func get_plugin_debug_info() -> String:
        queries += 1
        return '{"vm_status":4}'

    func get_frame_source_size() -> Vector2i:
        return Vector2i(1280, 720)

class FakeHost:
    extends Node
    var player := FakePlayer.new()
    var shell_root := Control.new()
    var home_view := Control.new()
    var game_view := Control.new()
    var viewport := TextureRect.new()
    var shell_route := "library"
    var home_library_mode := "game"
    var game_running := false
    var cached_startup_state := 2
    var active_runtime_kind := "rfvp"
    var render_errors := 0
    var selected_backend := ""
    var selected_game: Dictionary = {}
    var production_launches := 0
    var eager_initializations := 0

    func _prepare_cli_probe_view(_config: Dictionary) -> void:
        game_running = false

    func _game_info_from_path(path: String) -> Dictionary:
        return {"path": path, "name": "fixture"}

    func _start_selected_game_after_entitlements() -> void:
        production_launches += 1
        player.initialized = true
        game_running = true

    func _probe_wait_startup(_config: Dictionary) -> bool:
        return true

    func _ensure_player_initialized() -> bool:
        eager_initializations += 1
        return true

func _initialize() -> void:
    var saved := {"before": {"dialogue_key": "original", "navigation": {"restore_pending": false}}}
    assert(not Probe.conditions_match({"dialogue_key": "wrong"}, [{"field": "dialogue_key", "same_as": "before.dialogue_key"}], saved))
    assert(Probe.conditions_match({"dialogue_key": "original"}, [{"field": "dialogue_key", "same_as": "before.dialogue_key"}], saved))
    assert(not Probe.conditions_match({}, [{"field": "dialogue_key", "same_as": "missing.dialogue_key"}], saved))
    assert(not Probe.conditions_match({"dialogue_key": "original"}, [{"field": "dialogue_key"}]))
    assert(not Probe.conditions_match({}, [{"field": "dialogue_key", "equals": null}]))
    assert(Probe.conditions_match({"buttons": [{"g": 1, "id": 7, "v": 1, "e": 0}]}, [{"field": "buttons", "contains": {"id": 7, "e": 0}}]))
    assert(not Probe.conditions_match({"buttons": []}, [{"field": "buttons", "contains": {"id": 7}}]))
    assert(Probe.conditions_match({"layers": []}, [{"field": "layers", "not_contains": {"id": 7}}]))
    assert(Probe.conditions_match({"layers": [{"id": 8}]}, [{"field": "layers", "not_contains": {"id": 7}}]))
    assert(not Probe.conditions_match({"layers": [{"id": 7}]}, [{"field": "layers", "not_contains": {"id": 7}}]))
    assert(not Probe.conditions_match({}, [{"field": "layers", "not_contains": {"id": 7}}]))
    assert(not Probe.conditions_match({"layers": "invalid"}, [{"field": "layers", "not_contains": {"id": 7}}]))
    assert(Probe.writable_root({"writable_root": "user://regressions/test-1"}).ends_with("/regressions/test-1"))
    assert(Probe.writable_root({"writable_root": "user://regressions/../../SoftPal"}).is_empty())
    assert(Probe.writable_root({"writable_root": "user://"}).is_empty())
    assert(Probe.writable_root({}).is_empty())
    # A halted VM alone is not a successful exit: the actual library must be
    # visible and the runtime view hidden before the probe accepts teardown.
    var host := FakeHost.new()
    host.shell_root.visible = false
    var probe := Probe.new(host)
    var active: Dictionary = probe.state()
    assert(active.vm_status == 4)
    assert(not active.host.library_visible)
    assert(host.player.queries == 1)
    host.shell_root.visible = true
    host.game_view.visible = false
    host.viewport.visible = false
    host.player.initialized = false
    var exited: Dictionary = probe.state()
    assert(exited.host.library_visible)
    assert(exited.host.route == "library")
    assert(exited.host.library_mode == "game")
    assert(exited.host.frame_texture_cleared)
    assert(not exited.host.engine_initialized)
    assert(exited.host.player_instance_id == active.host.player_instance_id)
    assert(not exited.has("vm_status"))
    assert(host.player.queries == 1) # Never query the destroyed engine.
    probe.config = {"library_game": {"rfvpEncoding": "gbk", "path": "wrong"}}
    assert(await probe.launch_from_library("fixture-root"))
    assert(host.production_launches == 1)
    assert(host.eager_initializations == 0) # Never mask the production bug.
    assert(host.selected_game.path == "fixture-root")
    assert(host.selected_game.rfvpEncoding == "gbk")
    assert(probe.host_state().configured_launch_file == "")
    host.selected_game.launchFile = "Selected.hcb"
    assert(probe.host_state().configured_launch_file == "Selected.hcb")
    host.shell_root.free()
    host.home_view.free()
    host.game_view.free()
    host.viewport.free()
    probe = null
    host.free()
    print("Runtime regression probe semantic assertions and save isolation passed")
    quit(0)
