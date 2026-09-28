extends Control

# Lumen segmented control: a recessed track holding a raised "key" that slides
# between segments. The key carries a short signal-coloured bar along its
# bottom edge that stretches while the key travels.

signal item_selected(index: int)

const TRACK_INSET := 4.0
const CONTROL_HEIGHT := 42.0

var tokens
var motion
var buttons: Array[Button] = []
var selected_index := 0
var indicator: PanelContainer
var indicator_bar: Panel
var drag_active := false
var drag_x := -1.0

func setup(design_tokens, motion_system, labels: PackedStringArray, initial_index: int = 0) -> void:
    tokens = design_tokens
    motion = motion_system
    selected_index = clampi(initial_index, 0, maxi(0, labels.size() - 1))
    custom_minimum_size = Vector2(300, CONTROL_HEIGHT)
    mouse_filter = Control.MOUSE_FILTER_STOP
    focus_mode = Control.FOCUS_ALL
    mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

    var track := PanelContainer.new()
    track.mouse_filter = Control.MOUSE_FILTER_IGNORE
    track.set_anchors_preset(Control.PRESET_FULL_RECT)
    track.add_theme_stylebox_override("panel", tokens.panel(tokens.surface_hover, 12))
    add_child(track)

    indicator = PanelContainer.new()
    indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
    indicator.add_theme_stylebox_override("panel", tokens.panel(tokens.surface_raised if tokens.is_dark() else tokens.surface, 9))
    add_child(indicator)
    var bar_host := Control.new()
    bar_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
    indicator.add_child(bar_host)
    indicator_bar = Panel.new()
    indicator_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
    indicator_bar.add_theme_stylebox_override("panel", tokens.panel(tokens.accent, 2))
    indicator_bar.anchor_left = 0.5
    indicator_bar.anchor_right = 0.5
    indicator_bar.anchor_top = 1.0
    indicator_bar.anchor_bottom = 1.0
    indicator_bar.offset_left = -10
    indicator_bar.offset_right = 10
    indicator_bar.offset_top = -5
    indicator_bar.offset_bottom = -2
    bar_host.add_child(indicator_bar)
    bar_host.resized.connect(func(): indicator_bar.pivot_offset = indicator_bar.size * 0.5)

    var row := HBoxContainer.new()
    row.set_anchors_preset(Control.PRESET_FULL_RECT)
    row.offset_left = TRACK_INSET
    row.offset_top = TRACK_INSET
    row.offset_right = -TRACK_INSET
    row.offset_bottom = -TRACK_INSET
    row.add_theme_constant_override("separation", 0)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(row)

    for index in range(labels.size()):
        var button := Button.new()
        button.text = labels[index]
        button.focus_mode = Control.FOCUS_NONE
        button.mouse_filter = Control.MOUSE_FILTER_IGNORE
        button.clip_text = true
        button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        button.add_theme_font_size_override("font_size", 13)
        for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
            button.add_theme_stylebox_override(state, tokens.panel(Color.TRANSPARENT, 6))
        buttons.append(button)
        row.add_child(button)

    resized.connect(_layout_indicator.bind(false))
    call_deferred("_layout_indicator", false)
    _sync_button_colors()

func _gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
        if event.pressed:
            drag_active = true
            accept_event()
            _drag_to(event.position.x)
            var pressed_index := _index_at_x(event.position.x)
            if pressed_index >= 0 and pressed_index != selected_index:
                _select(pressed_index, true)
        elif drag_active:
            drag_active = false
            var release_index := _index_at_x(drag_x if drag_x >= 0.0 else event.position.x)
            _end_drag()
            if release_index >= 0 and release_index != selected_index:
                _select(release_index, true)
            else:
                _layout_indicator(true)
            accept_event()
    elif event is InputEventScreenTouch:
        var touch := event as InputEventScreenTouch
        if touch.pressed:
            drag_active = true
            accept_event()
            _drag_to(touch.position.x)
            _select(_index_at_x(touch.position.x), true)
        elif drag_active:
            drag_active = false
            _select(_index_at_x(touch.position.x), true)
            _end_drag()
            accept_event()
    elif event is InputEventScreenDrag and drag_active:
        _drag_to((event as InputEventScreenDrag).position.x)
        _select(_index_at_x((event as InputEventScreenDrag).position.x), false)
        accept_event()
    elif event is InputEventMouseMotion and drag_active:
        _drag_to(event.position.x)
        accept_event()
    elif event.is_action_pressed("ui_left"):
        _select(maxi(0, selected_index - 1), true)
        accept_event()
    elif event.is_action_pressed("ui_right"):
        _select(mini(buttons.size() - 1, selected_index + 1), true)
        accept_event()

func _segment_width() -> float:
    return maxf(0.0, size.x - TRACK_INSET * 2.0) / float(maxi(1, buttons.size()))

func _index_at_x(x: float) -> int:
    if buttons.is_empty() or size.x <= 0.0:
        return -1
    var segment := _segment_width()
    if segment <= 0.0:
        return -1
    # Count the rounded end caps as part of the first/last segment.
    return clampi(int(floor((clampf(x, 0.0, size.x) - TRACK_INSET) / segment)), 0, buttons.size() - 1)

func _drag_to(x: float) -> void:
    if buttons.is_empty() or size.x <= 0.0:
        return
    var segment := _segment_width()
    var target_size := Vector2(segment, maxf(0.0, size.y - TRACK_INSET * 2.0))
    drag_x = clampf(x - segment * 0.5, TRACK_INSET, size.x - TRACK_INSET - segment)
    indicator.size = target_size
    indicator.pivot_offset = target_size * 0.5
    if motion.reduced_motion:
        indicator.position = Vector2(drag_x, TRACK_INSET)
        return
    motion.spring_property(indicator, "position", Vector2(drag_x, TRACK_INSET), 0.07, 1.0)
    motion.spring_property(indicator_bar, "scale", Vector2(2.2, 1.0), 0.12, 0.9)

func _end_drag() -> void:
    drag_x = -1.0
    if not motion.reduced_motion:
        motion.spring_property(indicator_bar, "scale", Vector2.ONE, 0.30, 0.5)

func _select(index: int, animate: bool) -> void:
    if index < 0 or index >= buttons.size():
        return
    var changed := index != selected_index
    selected_index = index
    _sync_button_colors()
    _layout_indicator(animate)
    if changed:
        item_selected.emit(selected_index)

func _sync_button_colors() -> void:
    for index in range(buttons.size()):
        var button := buttons[index]
        var active := index == selected_index
        var color: Color = tokens.text_primary if active else tokens.text_secondary
        button.add_theme_color_override("font_color", color)
        button.add_theme_color_override("font_pressed_color", color)
        button.add_theme_color_override("font_focus_color", color)
        button.add_theme_color_override("font_hover_color", tokens.text_primary)

func _layout_indicator(animate: bool = false) -> void:
    if indicator == null or buttons.is_empty() or size.x <= 0.0:
        return
    var segment := _segment_width()
    var target_position := Vector2(TRACK_INSET + segment * float(selected_index), TRACK_INSET)
    var target_size := Vector2(segment, maxf(0.0, size.y - TRACK_INSET * 2.0))
    indicator.pivot_offset = target_size * 0.5
    if not animate or motion.reduced_motion:
        indicator.position = target_position
        indicator.size = target_size
        indicator.scale = Vector2.ONE
        return
    motion.spring_property(indicator, "position", target_position, 0.34, 0.62)
    motion.spring_property(indicator, "size", target_size, 0.30, 1.0)
    # The accent bar stretches with the travel and snaps back on landing.
    motion.spring_property(indicator_bar, "scale", Vector2(2.4, 1.0), 0.10, 1.0)
    var tree := get_tree()
    if tree != null:
        tree.create_timer(0.10).timeout.connect(
            func():
                if indicator_bar != null and is_instance_valid(indicator_bar):
                    motion.spring_property(indicator_bar, "scale", Vector2.ONE, 0.32, 0.45),
            CONNECT_ONE_SHOT
        )
