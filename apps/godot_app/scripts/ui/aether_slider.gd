extends HSlider

# Aurora slider: accent track that thickens under a fixed round knob while
# hovered or scrubbed, plus a soft halo that follows the knob and an optional
# value bubble that pops above it during a scrub.

const CONTROL_SIZE := Vector2(260.0, 42.0)
const KNOB_SIZE := 22
const TRACK_THIN := 5.0
const TRACK_THICK := 8.0
const THICKNESS_DURATION := 0.22

var tokens
var track_style: StyleBoxFlat
var fill_style: StyleBoxFlat
var fill_highlight_style: StyleBoxFlat
var thickness_tween: Tween
var scrubbing := false
var bubble_formatter: Callable
var halo: TextureRect
var bubble: PanelContainer
var bubble_label: Label
var halo_tween: Tween

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

    track_style = _track_style(tokens.tint(tokens.text_primary, 0.12 if tokens.is_dark() else 0.10))
    fill_style = _track_style(tokens.accent)
    fill_highlight_style = _track_style(tokens.accent.lerp(tokens.accent_2, 0.35))
    add_theme_stylebox_override("slider", track_style)
    add_theme_stylebox_override("grabber_area", fill_style)
    add_theme_stylebox_override("grabber_area_highlight", fill_highlight_style)
    add_theme_stylebox_override("focus", tokens.focus_style(8))
    add_theme_icon_override("grabber", _knob_texture(Color.WHITE, tokens.accent))
    add_theme_icon_override("grabber_highlight", _knob_texture(Color.WHITE, tokens.accent_2))
    add_theme_icon_override("grabber_disabled", _knob_texture(tokens.text_tertiary, tokens.separator))

    halo = TextureRect.new()
    halo.texture = tokens.radial_glow_texture(tokens.tint(tokens.accent, 0.55), 64)
    halo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
    halo.size = Vector2(48, 48)
    halo.pivot_offset = halo.size * 0.5
    halo.show_behind_parent = true
    halo.modulate.a = 0.0
    add_child(halo)

    # The control itself never scales while touched: scaling distorts the round
    # grabber into an ellipse. The track thickens under the fixed knob instead.
    drag_started.connect(func():
        scrubbing = true
        _animate_thickness(1.0)
        _show_halo(1.0)
        _show_bubble(true)
    )
    drag_ended.connect(func(_value_changed: bool):
        scrubbing = false
        _animate_thickness(0.0)
        _show_halo(0.0)
        _show_bubble(false)
    )
    mouse_entered.connect(func():
        _animate_thickness(0.6)
        _show_halo(0.55)
    )
    mouse_exited.connect(func():
        if not scrubbing:
            _animate_thickness(0.0)
            _show_halo(0.0)
    )
    value_changed.connect(func(_v: float): _sync_overlays())
    resized.connect(_sync_overlays)
    gui_input.connect(_on_slider_gui_input)
    call_deferred("_sync_overlays")

func _on_slider_gui_input(event: InputEvent) -> void:
    # Own the complete rail, including both end caps. This prevents the
    # settings ScrollContainer from stealing a tap at 0% or 100%.
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
    var usable_width := maxf(1.0, size.x - float(KNOB_SIZE))
    var local_x := clampf(pointer.x - float(KNOB_SIZE) * 0.5, 0.0, usable_width)
    var ratio := local_x / usable_width
    set_value_no_signal(lerpf(min_value, max_value, ratio))
    value_changed.emit(value)
    scrubbing = pressed
    accept_event()

func _knob_center() -> Vector2:
    var span := maxf(0.0001, max_value - min_value)
    var ratio := clampf((value - min_value) / span, 0.0, 1.0)
    var usable_width := maxf(0.0, size.x - float(KNOB_SIZE))
    return Vector2(float(KNOB_SIZE) * 0.5 + usable_width * ratio, size.y * 0.5)

func _sync_overlays() -> void:
    if halo == null:
        return
    var center := _knob_center()
    halo.position = center - halo.size * 0.5
    if bubble != null and is_instance_valid(bubble):
        if bubble_formatter.is_valid():
            bubble_label.text = String(bubble_formatter.call(value))
        bubble.reset_size()
        bubble.position = Vector2(center.x - bubble.size.x * 0.5, -bubble.size.y - 6.0)
        bubble.pivot_offset = Vector2(bubble.size.x * 0.5, bubble.size.y)

func _show_halo(target: float) -> void:
    if halo == null:
        return
    if halo_tween != null and halo_tween.is_valid():
        halo_tween.kill()
    halo_tween = create_tween().set_parallel(true)
    halo_tween.tween_property(halo, "modulate:a", target, 0.24).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    halo_tween.tween_property(halo, "scale", Vector2.ONE * (0.6 + target * 0.5), 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _show_bubble(show: bool) -> void:
    if not bubble_formatter.is_valid():
        return
    if bubble == null or not is_instance_valid(bubble):
        bubble = PanelContainer.new()
        bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var style: StyleBoxFlat = tokens.panel(tokens.popover, 10, tokens.rim, 1)
        style.content_margin_left = 10
        style.content_margin_right = 10
        style.content_margin_top = 4
        style.content_margin_bottom = 4
        style.shadow_color = tokens.shadow
        style.shadow_size = 8
        bubble.add_theme_stylebox_override("panel", style)
        bubble_label = Label.new()
        bubble_label.add_theme_font_size_override("font_size", 12)
        bubble_label.add_theme_color_override("font_color", tokens.text_primary)
        bubble.add_child(bubble_label)
        bubble.modulate.a = 0.0
        add_child(bubble)
    _sync_overlays()
    var tween := bubble.create_tween().set_parallel(true)
    if show:
        bubble.scale = Vector2(0.6, 0.6)
        tween.tween_property(bubble, "scale", Vector2.ONE, 0.26).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
    tween.tween_property(bubble, "modulate:a", 1.0 if show else 0.0, 0.16)

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
    return clampf(
        (track_style.content_margin_top - TRACK_THIN) / (TRACK_THICK - TRACK_THIN),
        0.0,
        1.0
    )

func _set_track_thickness(amount: float) -> void:
    var margin := lerpf(TRACK_THIN, TRACK_THICK, clampf(amount, 0.0, 1.0))
    for style in [track_style, fill_style, fill_highlight_style]:
        if style != null:
            style.content_margin_top = margin
            style.content_margin_bottom = margin

func _track_style(fill: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = fill
    style.set_corner_radius_all(6)
    style.anti_aliasing = true
    style.content_margin_top = TRACK_THIN
    style.content_margin_bottom = TRACK_THIN
    return style

func _knob_texture(fill: Color, outline: Color) -> Texture2D:
    var image := Image.create(KNOB_SIZE, KNOB_SIZE, false, Image.FORMAT_RGBA8)
    image.fill(Color.TRANSPARENT)
    var center := Vector2.ONE * (float(KNOB_SIZE) - 1.0) * 0.5
    var outer_radius := float(KNOB_SIZE) * 0.5 - 0.5
    var inner_radius := outer_radius - 3.0
    for y in range(KNOB_SIZE):
        for x in range(KNOB_SIZE):
            var distance := Vector2(float(x), float(y)).distance_to(center)
            var edge_alpha := clampf(outer_radius + 0.5 - distance, 0.0, 1.0)
            if edge_alpha <= 0.0:
                continue
            var ring := clampf(distance - inner_radius + 0.5, 0.0, 1.0)
            var color := fill.lerp(outline, ring)
            color.a *= edge_alpha
            image.set_pixel(x, y, color)
    return ImageTexture.create_from_image(image)
