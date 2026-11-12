extends RefCounted

# Host frame intervals include tick, upload, rendering and the frame wait.
# They are not the reciprocal of CPU work time, nor a count of unique movie frames.
static func summarize(intervals_ms: Array, target_fps: float = 30.0) -> Dictionary:
    if intervals_ms.is_empty():
        return {"frames": 0, "meets_frame_budget": false}
    var sorted := intervals_ms.duplicate()
    sorted.sort()
    var total := 0.0
    var over_budget := 0
    var window_ms := 0.0
    var window_start := 0
    var min_window_fps := INF
    var budget_ms := 1000.0 / target_fps
    for i in range(intervals_ms.size()):
        var elapsed := float(intervals_ms[i])
        total += elapsed
        window_ms += elapsed
        if elapsed > budget_ms:
            over_budget += 1
        while window_start < i and window_ms - float(intervals_ms[window_start]) >= 1000.0:
            window_ms -= float(intervals_ms[window_start])
            window_start += 1
        if window_ms >= 1000.0:
            min_window_fps = minf(min_window_fps, (i - window_start + 1) * 1000.0 / window_ms)
    var slow_count := maxi(1, ceili(sorted.size() * 0.01))
    var slow_total := 0.0
    for i in range(sorted.size() - slow_count, sorted.size()):
        slow_total += float(sorted[i])
    return {
        "frames": intervals_ms.size(), "target_fps": target_fps,
        "average_fps": intervals_ms.size() * 1000.0 / total,
        "minimum_frame_fps": 1000.0 / float(sorted[-1]),
        "minimum_rolling_1s_fps": null if is_inf(min_window_fps) else min_window_fps,
        "one_percent_low_fps": slow_count * 1000.0 / slow_total,
        "p95_frame_ms": sorted[ceili(sorted.size() * 0.95) - 1],
        "p99_frame_ms": sorted[ceili(sorted.size() * 0.99) - 1],
        "maximum_frame_ms": sorted[-1], "frames_over_budget": over_budget,
        "meets_frame_budget": over_budget == 0,
    }
