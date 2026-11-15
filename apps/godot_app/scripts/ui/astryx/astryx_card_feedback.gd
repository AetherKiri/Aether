extends Control
## ClickableCard feedback paints above the complete card, including its text.
## Astryx Neutral uses 0D/1A alpha for hover/press, with no border on this surface.
const HOVER_ALPHA := 13.0 / 255.0
const PRESS_ALPHA := 26.0 / 255.0
var button: Button
var ink: Color
var duration := 0.125
var reduced_motion := false
var touch_input := false
var keyboard_focus := false
var target_alpha := 0.0
var paint := StyleBoxFlat.new()
var fade: Tween

func configure(target: Button, design: RefCounted, reduce_motion: bool, touch_platform: bool) -> void:
    button = target
    ink = design.color("text")
    duration = design.metric("fast_seconds")
    reduced_motion = reduce_motion
    touch_input = touch_platform
    paint.bg_color = Color(ink, 0.0)
    paint.set_corner_radius_all(12)
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    button.draw.connect(_sync_feedback)
    visibility_changed.connect(_reset_hidden)

func _input(event: InputEvent) -> void:
    if not is_visible_in_tree():
        return
    var was_keyboard := keyboard_focus
    if event is InputEventKey and event.pressed:
        keyboard_focus = true
    elif event is InputEventScreenTouch and event.pressed:
        keyboard_focus = false
        touch_input = true
    elif (event is InputEventMouseMotion or event is InputEventMouseButton) and event.device != -1:
        keyboard_focus = false
        touch_input = false
    if was_keyboard != keyboard_focus and button.has_focus():
        _sync_feedback()

func _reset_hidden() -> void:
    if is_visible_in_tree():
        return
    if fade != null:
        fade.kill()
    target_alpha = 0.0
    _paint_alpha(0.0)

func _sync_feedback() -> void:
    if not is_instance_valid(button) or not is_visible_in_tree():
        return
    var state := button.get_draw_mode()
    var pressed := state in [BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED]
    var hovered := state == BaseButton.DRAW_HOVER or (keyboard_focus and button.has_focus())
    var alpha := 0.0 if button.disabled else (PRESS_ALPHA if pressed else (HOVER_ALPHA if hovered else 0.0))
    if is_equal_approx(alpha, target_alpha):
        return
    target_alpha = alpha
    if fade != null:
        fade.kill()
    # Touch-down paints immediately; release fades without owning the gesture.
    if reduced_motion or (touch_input and pressed):
        _paint_alpha(alpha)
        return
    fade = create_tween()
    fade.tween_method(_paint_alpha, paint.bg_color.a, alpha, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN if touch_input and alpha == 0.0 else Tween.EASE_OUT)

func _paint_alpha(alpha: float) -> void:
    paint.bg_color = Color(ink, alpha)
    queue_redraw()

func _draw() -> void:
    draw_style_box(paint, Rect2(Vector2.ZERO, size))
