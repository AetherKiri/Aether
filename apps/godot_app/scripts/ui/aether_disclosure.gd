extends Button

# Disclosure row: the label on the left and a round badge on the right whose
# chevron springs a quarter turn open while the badge floods with the accent.

signal expanded_changed(expanded: bool)

var tokens
var motion
var expanded := false
var chevron: TextureRect
var badge: Panel

func setup(design_tokens, motion_system, label: String, chevron_texture: Texture2D, initial_value: bool) -> void:
    tokens = design_tokens
    motion = motion_system
    text = label
    expanded = initial_value
    alignment = HORIZONTAL_ALIGNMENT_LEFT
    clip_text = true
    focus_mode = Control.FOCUS_ALL
    mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    custom_minimum_size.y = 52

    badge = Panel.new()
    badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
    badge.anchor_left = 1.0
    badge.anchor_top = 0.5
    badge.anchor_right = 1.0
    badge.anchor_bottom = 0.5
    badge.offset_left = -40
    badge.offset_top = -14
    badge.offset_right = -12
    badge.offset_bottom = 14
    badge.pivot_offset = Vector2(14, 14)
    add_child(badge)

    chevron = TextureRect.new()
    chevron.mouse_filter = Control.MOUSE_FILTER_IGNORE
    chevron.texture = chevron_texture
    chevron.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    chevron.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    chevron.anchor_left = 1.0
    chevron.anchor_top = 0.5
    chevron.anchor_right = 1.0
    chevron.anchor_bottom = 0.5
    chevron.offset_left = -33
    chevron.offset_top = -7
    chevron.offset_right = -19
    chevron.offset_bottom = 7
    chevron.pivot_offset = Vector2(7, 7)
    chevron.rotation = PI * 0.5 if expanded else 0.0
    add_child(chevron)
    _sync_badge()
    pressed.connect(func(): set_expanded(not expanded, true))

func set_expanded(value: bool, animate: bool) -> void:
    if value == expanded:
        return
    expanded = value
    var target := PI * 0.5 if expanded else 0.0
    _sync_badge()
    if not animate or motion.reduced_motion:
        chevron.rotation = target
    else:
        motion.spring_property(chevron, "rotation", target, 0.30, 0.60)
        motion.jelly(badge, Vector2(1.22, 1.22), 0.30, 0.48)
    expanded_changed.emit(expanded)

func _sync_badge() -> void:
    if badge == null:
        return
    var fill: Color = tokens.accent if expanded else tokens.surface_hover
    badge.add_theme_stylebox_override("panel", tokens.panel(fill, 14))
    chevron.modulate = tokens.text_on_accent if expanded else tokens.text_secondary
