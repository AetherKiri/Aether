extends HSlider

# Lumen slider: a hairline-thin rail that swells under a fixed square-ish
# knob while hovered or scrubbed. During a scrub a value tag floats above
# the knob; the control itself never scales (that would distort the knob).

const CONTROL_SIZE := Vector2(260.0, 40.0)
const KNOB_SIZE := 20
const TRACK_THIN := 3.0
const TRACK_THICK := 7.0
const THICKNESS_DURATION := 0.24

var tokens
var track_style: StyleBoxFlat
var fill_style: StyleBoxFlat
var fill_highlight_style: StyleBoxFlat
var thickness_tween: Tween
var scrubbing := false
var bubble_formatter: Callable
var bubble: PanelContainer
var bubble_label: Label

func setup(design_tokens, initial_value: float) -> void:
    tokens = design_tokens
    custom_minimum_size = CONTROL_SIZE
    size_flags_horizontal = Control.SIZE_EXPAND_FILL
    size_flags_vertical = Control.SIZE_SHRINK_CENTER
    focus_mode = Control.FOCUS_ALL
    mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    mouse_filter = Control.MOUSE_FILTER_STOP
    mouse_force_pass_scroll_events = false
    value = clampf(initial_value, min_value, max_value)

    track_style = _track_style(tokens.surface_hover if not tokens.is_dark() else tokens.tint(tokens.text_primary, 0.14))
    fill_style = _track_style(tokens.accent)
    fill_highlight_style = _track_style(tokens.accent.lightened(0.08))
    add_theme_stylebox_override("slider", track_style)
    add_theme_stylebox_override("grabber_area", fill_style)
    add_theme_stylebox_override("grabber_area_highlight", fill_highlight_style)
    add_theme_stylebox_override("focus", tokens.focus_style(8))
    add_theme_icon_override("grabber", _knob_texture(Color.WHITE, tokens.accent))
    add_theme_icon_override("grabber_highlight", _knob_texture(Color.WHITE, tokens.accent.lightened(0.1)))
    add_theme_icon_override("grabber_disabled", _knob_texture(tokens.text_tertiary, tokens.separator))

    drag_started.connect(func():
        scrubbing = true
        _animate_thickness(1.0)
        _show_bubble(true)
    )
    drag_ended.connect(func(_value_changed: bool):
        scrubbing = false
        _animate_thickness(0.0)
        _show_bubble(false)
    )
    mouse_entered.connect(func(): _animate_thickness(0.5))
    mouse_exited.connect(func():
        if not scrubbing:
            _animate_thickness(0.0)
    )
    # Touch: the rail thickens as soon as a finger lands, not only on drag.
    gui_input.connect(func(event: InputEvent):
        if event is InputEventScreenTouch:
            if event.pressed:
                _animate_thickness(1.0)
            elif not scrubbing:
                _animate_thickness(0.0)
    )
    value_changed.connect(func(_v: float): _sync_bubble())
    resized.connect(_sync_bubble)
    gui_input.connect(_on_slider_gui_input)

func _on_slider_gui_input(event: InputEvent) -> void:
    # Own the whole rail including both end caps so the settings scroller
    # never steals a tap at 0% or 100%.
    var pointer := Vector2.ZERO
    var pressed := false
    if event is InputEventMouseButton:
        var mouse := event as InputEventMouseButton
        if mouse.button_index != MOUSE_BUTTON_LEFT:
            return
        pointer = mouse.position
        pressed = mouse.pressed
    elif event is InputEventScreenTouch:
        var touch := event as InputEventScreenTouch
        pointer = touch.position
        pressed = touch.pressed
    elif event is InputEventScreenDrag:
        pointer = (event as InputEventScreenDrag).position
        pressed = true
    else:
        return
    if not pressed and not scrubbing:
        return
    var usable := maxf(1.0, size.x - float(KNOB_SIZE))
    var ratio := clampf(pointer.x - float(KNOB_SIZE) * 0.5, 0.0, usable) / usable
    set_value_no_signal(lerpf(min_value, max_value, ratio))
    value_changed.emit(value)
    scrubbing = pressed
    accept_event()

func _knob_center() -> Vector2:
    var ratio := clampf((value - min_value) / maxf(0.0001, max_value - min_value), 0.0, 1.0)
    return Vector2(float(KNOB_SIZE) * 0.5 + maxf(0.0, size.x - float(KNOB_SIZE)) * ratio, size.y * 0.5)

func _sync_bubble() -> void:
    if bubble == null or not is_instance_valid(bubble):
        return
    if bubble_formatter.is_valid():
        bubble_label.text = String(bubble_formatter.call(value))
    bubble.reset_size()
    var center := _knob_center()
    bubble.position = Vector2(center.x - bubble.size.x * 0.5, -bubble.size.y - 4.0)
    bubble.pivot_offset = Vector2(bubble.size.x * 0.5, bubble.size.y)

func _show_bubble(show: bool) -> void:
    if not bubble_formatter.is_valid():
        return
    if bubble == null or not is_instance_valid(bubble):
        bubble = PanelContainer.new()
        bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var style: StyleBoxFlat = tokens.panel(tokens.text_primary, 6)
        style.content_margin_left = 8
        style.content_margin_right = 8
        style.content_margin_top = 3
        style.content_margin_bottom = 3
        bubble.add_theme_stylebox_override("panel", style)
        bubble_label = Label.new()
        bubble_label.add_theme_font_size_override("font_size", 11)
        bubble_label.add_theme_color_override("font_color", tokens.background)
        bubble.add_child(bubble_label)
        bubble.modulate.a = 0.0
        add_child(bubble)
    _sync_bubble()
    var tween := bubble.create_tween().set_parallel(true)
    if show:
        bubble.scale = Vector2(0.5, 0.5)
        tween.tween_property(bubble, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
    tween.tween_property(bubble, "modulate:a", 1.0 if show else 0.0, 0.14)

func _animate_thickness(target: float) -> void:
    if thickness_tween != null and thickness_tween.is_valid():
        thickness_tween.kill()
    thickness_tween = create_tween()
    thickness_tween.tween_method(
        _set_track_thickness,
        _current_thickness(),
        clampf(target, 0.0, 1.0),
        THICKNESS_DURATION
    ).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _current_thickness() -> float:
    if track_style == null:
        return 0.0
    return clampf((track_style.content_margin_top - TRACK_THIN) / (TRACK_THICK - TRACK_THIN), 0.0, 1.0)

func _set_track_thickness(amount: float) -> void:
    var margin := lerpf(TRACK_THIN, TRACK_THICK, clampf(amount, 0.0, 1.0))
    for style in [track_style, fill_style, fill_highlight_style]:
        if style != null:
            style.content_margin_top = margin
            style.content_margin_bottom = margin

func _track_style(fill: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = fill
    style.set_corner_radius_all(4)
    style.anti_aliasing = true
    style.content_margin_top = TRACK_THIN
    style.content_margin_bottom = TRACK_THIN
    return style

# Rounded-square knob with a signal-coloured core.
func _knob_texture(fill: Color, core: Color) -> Texture2D:
    var image := Image.create(KNOB_SIZE, KNOB_SIZE, false, Image.FORMAT_RGBA8)
    image.fill(Color.TRANSPARENT)
    var half := float(KNOB_SIZE) * 0.5
    var corner := 6.0
    for y in range(KNOB_SIZE):
        for x in range(KNOB_SIZE):
            var p := Vector2(float(x) + 0.5 - half, float(y) + 0.5 - half)
            var q := p.abs() - Vector2(half - 0.5, half - 0.5) + Vector2(corner, corner)
            var d := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - corner
            var edge := clampf(0.5 - d, 0.0, 1.0)
            if edge <= 0.0:
                continue
            var core_mask := clampf(4.5 - p.length(), 0.0, 1.0)
            var color := fill.lerp(core, core_mask)
            color.a *= edge
            image.set_pixel(x, y, color)
    return ImageTexture.create_from_image(image)
