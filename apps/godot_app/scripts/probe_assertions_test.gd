extends SceneTree
const Assertions = preload("res://scripts/probe_assertions.gd")
func _initialize() -> void:
    var state := {"runtime": "fixture", "error": "", "count": 12}
    var cases := [
        [state, [{"key": "runtime", "equals": "fixture"}, {"key": "count", "min": 10, "max": 15}], true],
        [state, [{"key": "runtime", "equals": "wrong"}], false],
        [state, [{"key": "typo", "min": 0}], false],
        [state, [{"key": "error", "min": 0}], false],
        [state, [{"key": "count", "min": "10"}], false],
        [state, [{"key": "count", "max": 3}], false],
        [state, [{"key": "count"}], false],
        [state, [], false], [null, [], false], [state, [null], false],
    ]
    for test in cases:
        if Assertions.runtime(test[0], test[1]).is_empty() != test[2]:
            printerr("probe assertion regression: %s" % [test])
            quit(1)
            return
    print("probe assertions PASS (%d cases)" % cases.size())
    quit(0)
