extends Control

const Ripple = preload("res://scripts/ui/aether_pointer_ripple.gd")

var tokens
var motion
var target_position := Vector2.ZERO
var pointer_color := Color("ff8a66")
var snapped := false

func setup(design_tokens, motion_system) -> void:
    tokens = design_tokens
    motion = motion_system
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    z_index = 5
    if tokens != null:
        pointer_color = tokens.accent
    size = Vector2(26.0, 26.0)
    queue_redraw()

func set_target(next_position: Vector2) -> void:
    target_position = next_position
    # The displayed hotspot and the dispatched click must always coincide.
    position = next_position
    queue_redraw()

func click_pulse() -> void:
    if is_inside_tree() and (motion == null or not motion.reduced_motion):
        Ripple.spawn(get_parent(), position + size * 0.5)

func _draw() -> void:
    var center := size * 0.5
    draw_circle(center, 8.5, Color(0, 0, 0, 0.35))
    draw_circle(center, 6.5, Color.WHITE)
    draw_circle(center, 4.5, pointer_color)
    if snapped:
        draw_arc(center, 11.0, 0.0, TAU, 48, pointer_color, 1.5, true)
