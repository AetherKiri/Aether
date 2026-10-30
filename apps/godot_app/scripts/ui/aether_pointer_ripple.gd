extends RefCounted

## Shared touch/gamepad click feedback from the liquid-glass controls.
static func spawn(parent: Node, center: Vector2) -> void:
    var ring := Panel.new()
    ring.name = "TouchRipple"
    ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var style := StyleBoxFlat.new()
    style.bg_color = Color(1.0, 1.0, 1.0, 0.06)
    style.border_color = Color(1.0, 1.0, 1.0, 0.50)
    style.set_border_width_all(1)
    style.set_corner_radius_all(999)
    style.anti_aliasing = true
    ring.add_theme_stylebox_override("panel", style)
    ring.size = Vector2.ONE * 56.0
    ring.pivot_offset = ring.size * 0.5
    ring.position = center - ring.size * 0.5
    ring.scale = Vector2.ONE * 0.35
    parent.add_child(ring)
    var tween := ring.create_tween().set_parallel(true)
    tween.tween_property(ring, "scale", Vector2.ONE, 0.45) \
        .set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    tween.tween_property(ring, "modulate:a", 0.0, 0.45) \
        .set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
    tween.chain().tween_callback(ring.queue_free)
