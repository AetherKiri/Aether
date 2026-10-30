extends RefCounted

const FlashView = preload("res://scripts/flash_player_view.gd")
const RenpyView = preload("res://scripts/renpy_player_view.gd")

# Adapt the existing standalone player views; no native runtime is constructed.
# Positions are viewport coordinates until they reach each player's own mapper.
static func active_view(app):
    for view in [app.renpy_view, app.tyrano_view, app.flash_view]:
        if is_instance_valid(view) and view.is_visible_in_tree():
            return view
    return null

static func ready(view) -> bool:
    if view == null or not is_instance_valid(view.native) or view.lifecycle_paused:
        return false
    if view is FlashView:
        return not view.paused and view.surface.texture != null
    return view.ready_received and not view.closing

static func bounds(view) -> Rect2:
    if view is FlashView:
        return view._content_rect()
    var safe: Rect2 = view.host._ui_safe_rect(view.size)
    return Rect2(view.global_position + safe.position + Vector2(0, 56),
        Vector2(safe.size.x, maxf(1.0, safe.size.y - 56.0)))

static func key(view, pressed: bool, code: int) -> void:
    if not ready(view):
        return
    if view is FlashView:
        view._send(1 if pressed else 2, Vector2.ZERO, code)
    elif view is RenpyView:
        var names := {13: "return", 17: "ctrl", 27: "escape", 32: "space",
            33: "pageup", 34: "pagedown", 37: "left", 38: "up", 39: "right", 40: "down"}
        view.native.send_input({"type": "key", "key": names.get(code, ""),
            "pressed": pressed, "repeat": false, "text": "", "mod": 0})
    else:
        view.native.evaluate_script("window.AetherTyranoHost?.key(%d,%s)" % [code, "true" if pressed else "false"])

static func pointer(view, kind: String, position: Vector2, wheel: int = 0) -> void:
    if not ready(view):
        return
    if view is FlashView:
        var point: Vector2 = view._map(position)
        match kind:
            "move": view._send(3, point)
            "click":
                view._send(3, point)
                view._send(4, point)
                view._send(5, point)
            "scroll": view._send(6, Vector2(0, -wheel))
    elif view is RenpyView:
        var rect := bounds(view)
        var point: Vector2 = ((position - rect.position) / rect.size).clamp(Vector2.ZERO, Vector2.ONE)
        view.native.send_input({"type": "move", "x": point.x, "y": point.y})
        if kind in ["click", "scroll"]:
            var button := 1 if kind == "click" else (4 if wheel < 0 else 5)
            view.native.send_input({"type": "button", "button": button, "pressed": true, "x": point.x, "y": point.y})
            view.native.send_input({"type": "button", "button": button, "pressed": false, "x": point.x, "y": point.y})
    else:
        # Tyrano already exposes virtual key dispatch in its host integration.
        # Use those supported actions rather than inventing DOM mouse semantics.
        if kind == "click":
            key(view, true, 13)
            key(view, false, 13)
        elif kind == "scroll":
            var code := 33 if wheel < 0 else 34
            key(view, true, code)
            key(view, false, code)
