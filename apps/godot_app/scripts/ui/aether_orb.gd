extends Control
## Liquid-glass launcher button for the in-game controls.
##
## Purely visual (ignores input); parent it to the Button that owns input.
## Static at rest. Interaction only changes the glass lighting, a slight
## critically damped scale (no overshoot, the parent hit rect never moves)
## and a keyboard -> close icon morph when the menu is open.

const AetherGlass = preload("res://scripts/ui/aether_glass.gd")

var hovered := false:
    set(value):
        hovered = value
        if _glass != null:
            _glass.hovered = value
            _glass._wake()
        _wake()
var pressed := false:
    set(value):
        pressed = value
        _wake()
var open := false:
    set(value):
        open = value
        if _glass != null:
            _glass.set_selected(value)
        _wake()

var _glass
var _scale := 1.0
var _open_t := 0.0
var _hover_t := 0.0
var _animating := true

func _init() -> void:
    name = "Orb"
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    _glass = AetherGlass.new()
    _glass.radius = 999.0
    _glass.tint = Color(0.09, 0.10, 0.13, 0.30)
    _glass.selected_amount = 0.22
    add_child(_glass)

func setup(accent_color: Color, _accent_2_color: Color) -> void:
    _glass.accent = accent_color
    queue_redraw()

func ripple() -> void:
    pass

func press_at(local_position: Vector2) -> void:
    _glass.press_at(local_position)

func release() -> void:
    _glass.pressed = false
    _glass._wake()

func _wake() -> void:
    _animating = true
    set_process(true)

func _notification(what: int) -> void:
    if what == NOTIFICATION_RESIZED:
        pivot_offset = size * 0.5
        queue_redraw()

func _process(delta: float) -> void:
    if not _animating:
        set_process(false)
        return
    var target_scale := 0.93 if pressed else (1.03 if hovered else 1.0)
    _scale = AetherGlass.approach(_scale, target_scale, 24.0 if pressed else 13.0, delta)
    _open_t = AetherGlass.approach(_open_t, 1.0 if open else 0.0, 12.0, delta)
    _hover_t = AetherGlass.approach(_hover_t, 1.0 if hovered else 0.0, 14.0, delta)
    scale = Vector2.ONE * _scale
    queue_redraw()
    _animating = not (
        _scale == target_scale
        and _open_t == (1.0 if open else 0.0)
        and _hover_t == (1.0 if hovered else 0.0)
    )

func _draw() -> void:
    var c := size * 0.5
    var r := minf(size.x, size.y) * 0.5
    if r <= 4.0:
        return
    var t := _open_t * _open_t * (3.0 - 2.0 * _open_t)
    var ink := Color(1.0, 1.0, 1.0, 0.92 + 0.08 * _hover_t)

    # Keyboard glyph: fades and turns away as the menu opens.
    var k_alpha := 1.0 - t
    if k_alpha > 0.01:
        draw_set_transform(c, -t * PI * 0.25, Vector2.ONE * (1.0 - 0.25 * t))
        var w := r * 0.92
        var h := r * 0.60
        var body := StyleBoxFlat.new()
        body.draw_center = false
        body.border_color = Color(ink.r, ink.g, ink.b, ink.a * k_alpha)
        body.set_border_width_all(2)
        body.set_corner_radius_all(int(round(r * 0.14)))
        body.anti_aliasing = true
        draw_style_box(body, Rect2(Vector2(-w, -h) * 0.5, Vector2(w, h)))
        var key_col := Color(ink.r, ink.g, ink.b, ink.a * k_alpha)
        var step := w / 5.0
        for col in range(4):
            var x := -w * 0.5 + step * (col + 1)
            draw_circle(Vector2(x, -h * 0.17), 1.35, key_col)
        var space_half := w * 0.22
        draw_line(
            Vector2(-space_half, h * 0.17), Vector2(space_half, h * 0.17),
            key_col, 2.0, true
        )
        draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

    # Close glyph: rotates into place.
    if t > 0.01:
        draw_set_transform(c, (1.0 - t) * PI * 0.5, Vector2.ONE * (0.75 + 0.25 * t))
        var arm := r * 0.26
        var x_col := Color(ink.r, ink.g, ink.b, ink.a * t)
        draw_line(Vector2(-arm, -arm), Vector2(arm, arm), x_col, 2.2, true)
        draw_line(Vector2(-arm, arm), Vector2(arm, -arm), x_col, 2.2, true)
        draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
