extends Button
## A 44 pt touch target with Astryx's compact switch track.
var design: RefCounted
var progress := 0.0
var motion: Tween
var reduced_motion := false

func configure(value: bool, palette: RefCounted, reduce_motion: bool) -> void:
    design = palette
    reduced_motion = reduce_motion
    toggle_mode = true
    button_pressed = value
    progress = 1.0 if value else 0.0
    custom_minimum_size = Vector2(48, 44)
    size_flags_horizontal = Control.SIZE_SHRINK_END
    size_flags_vertical = Control.SIZE_SHRINK_CENTER
    mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    for key in ["normal", "hover", "pressed", "disabled"]:
        add_theme_stylebox_override(key, StyleBoxEmpty.new())
    add_theme_stylebox_override("focus", design.focus_box(14))
    toggled.connect(_change)

func _change(value: bool) -> void:
    if motion != null:
        motion.kill()
    if reduced_motion:
        progress = 1.0 if value else 0.0
        queue_redraw()
        return
    motion = create_tween()
    motion.tween_method(func(v: float):
        progress = v
        queue_redraw()
    , progress, 1.0 if value else 0.0, design.metric("fast_seconds")).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _draw() -> void:
    if design == null:
        return
    var track := StyleBoxFlat.new()
    track.bg_color = design.color("input_border").lerp(design.color("accent"), progress)
    track.set_corner_radius_all(13)
    var origin := (size - Vector2(44, 26)) * 0.5
    draw_style_box(track, Rect2(origin, Vector2(44, 26)))
    draw_circle(origin + Vector2(13 + 18 * progress, 13), 10, design.color("surface").lerp(design.color("on_accent"), progress), true, -1.0, true)
