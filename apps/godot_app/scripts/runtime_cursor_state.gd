extends RefCounted

# A game's cursor request belongs to its play surface. It must not hide the
# cursor over the launcher, a host dialog, or another application.
var active := false
var requested_visible := true

func request(visible: bool) -> void:
    active = true
    requested_visible = visible

func mouse_mode(game_has_pointer: bool) -> int:
    return Input.MOUSE_MODE_HIDDEN if active and not requested_visible and game_has_pointer else Input.MOUSE_MODE_VISIBLE

func reset() -> void:
    active = false
    requested_visible = true
