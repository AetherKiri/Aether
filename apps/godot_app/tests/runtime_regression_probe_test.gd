extends SceneTree

const Probe = preload("res://scripts/runtime_regression_probe.gd")

class FakePlayer:
    extends RefCounted
    var queries := 0

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
    var exited: Dictionary = probe.state()
    assert(exited.host.library_visible)
    assert(exited.host.route == "library")
    assert(exited.host.library_mode == "game")
    assert(exited.host.frame_texture_cleared)
    assert(not exited.has("vm_status"))
    assert(host.player.queries == 1) # Never query the destroyed engine.
    host.shell_root.free()
    host.home_view.free()
    host.game_view.free()
    host.viewport.free()
    probe = null
    host.free()
    print("Runtime regression probe semantic assertions and save isolation passed")
    quit(0)
