extends Control

## A small controller pointer for game frames. It follows a spring target,
## squashes on motion, and blooms briefly on click without obscuring text.

var tokens
var motion
var target_position := Vector2.ZERO
var velocity := Vector2.ZERO
var pointer_color := Color("ff8a66")
var _pulse := 0.0

func setup(design_tokens, motion_system) -> void:
    tokens = design_tokens
    motion = motion_system
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    z_index = 5
    if tokens != null:
        pointer_color = tokens.accent
    custom_minimum_size = Vector2(26.0, 26.0)
    size = Vector2(26.0, 26.0)
    pivot_offset = size * 0.5
    queue_redraw()

func set_target(next_position: Vector2) -> void:
    target_position = next_position
    if not visible:
        position = next_position
        velocity = Vector2.ZERO

func click_pulse() -> void:
    _pulse = 1.0
    if motion != null:
        motion.spring_property(self, "scale", Vector2(1.38, 0.78), 0.08, 0.72, func():
            motion.spring_property(self, "scale", Vector2.ONE, 0.22, 0.62)
        )
    queue_redraw()

func _process(delta: float) -> void:
    if not is_visible_in_tree():
        return
    if motion != null and motion.reduced_motion:
        position = target_position
        velocity = Vector2.ZERO
        _pulse = 0.0
        queue_redraw()
        return
    var offset := target_position - position
    velocity += offset * minf(delta, 0.033) * 34.0
    velocity *= pow(0.0008, minf(delta, 0.033))
    position += velocity * minf(delta, 0.033)
    _pulse = move_toward(_pulse, 0.0, delta * 5.0)
    queue_redraw()

func _draw() -> void:
    var stretch := Vector2(1.0 + _pulse * 0.34, 1.0 - _pulse * 0.18)
    var radius := 9.0 + _pulse * 4.0
    draw_set_transform(size * 0.5, 0.0, stretch)
    draw_circle(Vector2.ZERO, radius + 6.0, Color(0.0, 0.0, 0.0, 0.22))
    draw_circle(Vector2.ZERO, radius, Color(pointer_color.r, pointer_color.g, pointer_color.b, 0.96))
    var core: Color = tokens.text_primary if tokens != null else Color.WHITE
    draw_circle(Vector2.ZERO, radius - 3.0, Color(core.r, core.g, core.b, 0.92))
    draw_circle(Vector2.ZERO, radius - 6.0, Color(pointer_color.r, pointer_color.g, pointer_color.b, 0.96))
    draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
