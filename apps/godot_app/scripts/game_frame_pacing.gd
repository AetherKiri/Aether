extends RefCounted

# Keep the host policy local to a running CPU-rendered YU-RIS session. On
# macOS Metal, adaptive/mailbox also enable CAMetalLayer display sync; a
# missed drawable deadline can otherwise halve the input/update cadence.
var saved: Dictionary = {}

func enter(runtime: String, platform: String, driver: String, vsync: int,
        max_fps: int, refresh_hz: float) -> Dictionary:
    if not saved.is_empty() or runtime != "yuris" or platform != "macOS" or driver != "metal":
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
