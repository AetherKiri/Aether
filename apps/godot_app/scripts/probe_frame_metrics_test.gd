extends SceneTree

const Metrics = preload("res://scripts/probe_frame_metrics.gd")

func _initialize() -> void:
    var steady: Array = []
    steady.resize(120)
    steady.fill(1000.0 / 60.0)
    var result: Dictionary = Metrics.summarize(steady)
    assert(is_equal_approx(result.average_fps, 60.0))
    assert(is_equal_approx(result.minimum_rolling_1s_fps, 60.0))
    assert(result.meets_frame_budget)
    steady[60] = 100.0
    result = Metrics.summarize(steady)
    assert(result.frames_over_budget == 1)
    assert(result.minimum_frame_fps == 10.0)
    assert(result.minimum_rolling_1s_fps < 60.0)
    assert(is_equal_approx(result.one_percent_low_fps, 2000.0 / (100.0 + 1000.0 / 60.0)))
    assert(not result.meets_frame_budget)
    result = Metrics.summarize([10.0, 20.0])
    assert(result.minimum_rolling_1s_fps == null)
    result = Metrics.summarize([1200.0])
    assert(result.minimum_rolling_1s_fps < 1.0)
    assert(not Metrics.summarize([]).meets_frame_budget)
    print("probe frame metrics tests passed")
    quit(0)
