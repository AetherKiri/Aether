extends SceneTree

const Probe = preload("res://scripts/runtime_regression_probe.gd")

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
    print("Runtime regression probe semantic assertions and save isolation passed")
    quit(0)
