extends RefCounted

# On macOS Metal, adaptive/mailbox also enable CAMetalLayer display sync.
# Pace supported runtimes independently of the next drawable deadline.
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
        max_fps: int, refresh_hz: float, runtime_limit: int = 0) -> Dictionary:
    if not saved.is_empty() or runtime not in ["yuris", "bgi", "systemc", "exhibit", "advhd"] or platform != "macOS" or driver != "metal":
        return {}
    if vsync == DisplayServer.VSYNC_DISABLED:
        return {}
    saved = {"vsync": vsync, "max_fps": max_fps}
    return {"vsync": DisplayServer.VSYNC_DISABLED, "max_fps": frame_limit(runtime, refresh_hz, runtime_limit)}

func frame_limit(runtime: String, refresh_hz: float, runtime_limit: int) -> int:
    var host_limit := int(saved.get("max_fps", 0))
    var cap := 60
    if runtime == "advhd":
        if runtime_limit > 0:
            cap = runtime_limit
        elif host_limit > 0:
            cap = host_limit
    if refresh_hz > 0.0:
        cap = mini(cap, maxi(1, roundi(refresh_hz)))
    return mini(cap, host_limit) if host_limit > 0 else cap

func leave() -> Dictionary:
    var previous := saved
    saved = {}
    return previous
