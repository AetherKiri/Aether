extends Button

# Disclosure row: a chevron inside a small glass orb that spins open with a
# spring, while the orb warms to the accent when expanded.

signal expanded_changed(expanded: bool)

var tokens
var motion
var expanded := false
var chevron: TextureRect
var orb: PanelContainer

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

    orb = PanelContainer.new()
    orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
    orb.anchor_left = 1.0
    orb.anchor_top = 0.5
    orb.anchor_right = 1.0
    orb.anchor_bottom = 0.5
    orb.offset_left = -38
    orb.offset_top = -14
    orb.offset_right = -10
    orb.offset_bottom = 14
    orb.pivot_offset = Vector2(14, 14)
    add_child(orb)

    chevron = TextureRect.new()
    chevron.mouse_filter = Control.MOUSE_FILTER_IGNORE
    chevron.texture = chevron_texture
    chevron.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    chevron.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    chevron.anchor_left = 1.0
    chevron.anchor_top = 0.5
    chevron.anchor_right = 1.0
    chevron.anchor_bottom = 0.5
    chevron.offset_left = -31
    chevron.offset_top = -8
    chevron.offset_right = -15
    chevron.offset_bottom = 8
    chevron.pivot_offset = Vector2(8, 8)
    chevron.rotation = PI * 0.5 if expanded else 0.0
    add_child(chevron)
    _sync_orb()
    pressed.connect(func(): set_expanded(not expanded, true))

func set_expanded(value: bool, animate: bool) -> void:
    if value == expanded:
        return
    expanded = value
    var target := PI * 0.5 if expanded else 0.0
    _sync_orb()
    if not animate or motion.reduced_motion:
        chevron.rotation = target
    else:
        motion.spring_property(chevron, "rotation", target, 0.30, 0.62)
        motion.jelly(orb, Vector2(1.18, 1.18), 0.32, 0.5)
    expanded_changed.emit(expanded)

func _sync_orb() -> void:
    if orb == null:
        return
    var fill: Color = tokens.accent_fill if expanded else tokens.tint(tokens.text_primary, 0.06)
    orb.add_theme_stylebox_override("panel", tokens.panel(fill, 14, tokens.rim if not expanded else tokens.tint(tokens.accent, 0.4), 1))
    chevron.modulate = tokens.accent if expanded else tokens.text_secondary
