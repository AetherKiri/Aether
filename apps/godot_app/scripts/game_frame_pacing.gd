extends RefCounted

# Pace CPU-rendered game sessions while the native game window is active. On
# macOS Metal, adaptive/mailbox also enable CAMetalLayer display sync; a
# missed drawable deadline can otherwise halve the input/update cadence.
var saved: Dictionary = {}
var last_draw_count := -1
var last_tick_drew := true
var idle := false

# Low-processor mode skips buffer swaps on a static screen. Without VSync
# those ticks can run faster than the display. Keep polling input at 60 Hz
# while idle and resume the configured cadence on consecutive presentations.
func polling_delay_usec(draw_count: int, active_usec: int) -> int:
    var drew := draw_count != last_draw_count
    if drew == last_tick_drew:
        idle = not drew
    last_draw_count = draw_count
    last_tick_drew = drew
    return maxi(active_usec, 16667) if idle else active_usec

func enter(runtime: String, platform: String, driver: String, vsync: int,
        max_fps: int, refresh_hz: float) -> Dictionary:
    if not saved.is_empty() or runtime not in ["yuris", "bgi", "systemc", "exhibit"] or platform != "macOS" or driver != "metal":
        return {}
    if vsync == DisplayServer.VSYNC_DISABLED:
        return {}
    saved = {"vsync": vsync, "max_fps": max_fps}
    var cap := mini(60, roundi(refresh_hz)) if refresh_hz > 0.0 else 60
    cap = maxi(1, cap)
    if max_fps > 0:
        cap = mini(cap, max_fps)
    return {"vsync": DisplayServer.VSYNC_DISABLED, "max_fps": cap}

func leave() -> Dictionary:
    var previous := saved
    saved = {}
    return previous
