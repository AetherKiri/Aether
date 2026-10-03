extends RefCounted

# Lumen widget factory. Buttons are solid, flat-edged blocks: the primary
# action is the signal colour with a tinted drop shadow, secondary actions sit
# on the surface tone with a hairline, and quiet/toolbar actions only reveal a
# fill under the pointer. Motion (press squash, hover lift) comes from the
# shared motion engine.

const CONTROL_HEIGHT := 44.0
const ICON_BUTTON_SIZE := 44.0
const RADIUS := 12
const PILL := 999

var tokens
var motion

func _init(design_tokens, motion_system) -> void:
    tokens = design_tokens
    motion = motion_system

func primary_button(button: Button) -> Button:
    return _solid_button(button, tokens.accent, tokens.text_on_accent)

func destructive_button(button: Button) -> Button:
    return _solid_button(button, tokens.danger, Color.WHITE)

func secondary_button(button: Button, destructive: bool = false) -> Button:
    _prepare_button(button, 14)
    var foreground: Color = tokens.danger if destructive else tokens.text_primary
    _set_font_colors(button, foreground, foreground, tokens.text_tertiary)
    var hover_edge: Color = tokens.tint(tokens.danger, 0.55) if destructive else tokens.outline_strong
    _set_button_boxes(
        button,
        _box(tokens.surface_raised, tokens.outline, PILL),
        _box(tokens.surface_hover, hover_edge, PILL),
        _box(tokens.tint(foreground, 0.10), hover_edge, PILL),
        tokens.focus_style(PILL),
        _box(tokens.tint(tokens.surface_hover, 0.5), tokens.separator, PILL)
    )
    motion.bind_hover_lift(button, 1.02)
    return button

# Tinted action: the signal colour at low strength with a hairline of the
# same hue; hover deepens the tint and lifts a soft coloured glow.
func soft_button(button: Button) -> Button:
    _prepare_button(button, 14)
    var tone: Color = tokens.accent_text
    _set_font_colors(button, tone, tone, tokens.text_tertiary)
    for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
        button.add_theme_color_override("icon_%s_color" % state, tone)
    button.add_theme_color_override("icon_disabled_color", tokens.text_tertiary)
    var normal := _box(tokens.tint(tokens.accent, 0.10), tokens.tint(tokens.accent, 0.24), PILL)
    var hover := _box(tokens.tint(tokens.accent, 0.17), tokens.tint(tokens.accent, 0.46), PILL)
    hover.shadow_color = tokens.tint(tokens.accent, 0.20)
    hover.shadow_size = 14
    hover.shadow_offset = Vector2(0, 4)
    var pressed := _box(tokens.tint(tokens.accent, 0.25), tokens.tint(tokens.accent, 0.55), PILL)
    var focus := _box(tokens.tint(tokens.accent, 0.12), tokens.tint(tokens.accent, 0.75), PILL, 18, 2)
    _set_button_boxes(button, normal, hover, pressed, focus, _box(tokens.tint(tokens.surface_hover, 0.5), tokens.separator, PILL))
    motion.bind_hover_lift(button, 1.03)
    return button

func quiet_button(button: Button) -> Button:
    _prepare_button(button, 14)
    _set_font_colors(button, tokens.text_secondary, tokens.text_primary, tokens.text_tertiary)
    _set_button_boxes(
        button,
        _box(Color.TRANSPARENT),
        _box(tokens.surface_hover),
        _box(tokens.tint(tokens.text_primary, 0.10)),
        tokens.focus_style(RADIUS),
        _box(Color.TRANSPARENT)
    )
    return button

func toolbar_button(button: Button, selected: bool = false) -> Button:
    _prepare_button(button, 14)
    button.custom_minimum_size = Vector2(ICON_BUTTON_SIZE, ICON_BUTTON_SIZE)
    var foreground: Color = tokens.accent_text if selected else tokens.text_secondary
    var active: Color = tokens.accent_text if selected else tokens.text_primary
    for state in ["normal", "focus"]:
        button.add_theme_color_override("font_%s_color" % state if state != "normal" else "font_color", foreground)
        button.add_theme_color_override("icon_%s_color" % state, foreground)
    for state in ["hover", "pressed", "hover_pressed"]:
        button.add_theme_color_override("font_%s_color" % state, active)
        button.add_theme_color_override("icon_%s_color" % state, active)
    button.add_theme_color_override("font_disabled_color", tokens.text_tertiary)
    button.add_theme_color_override("icon_disabled_color", tokens.text_tertiary)
    _set_button_boxes(
        button,
        _box(tokens.accent_fill if selected else Color.TRANSPARENT, Color.TRANSPARENT, 10, 10),
        _box(tokens.surface_hover, Color.TRANSPARENT, 10, 10),
        _box(tokens.tint(tokens.text_primary, 0.12), Color.TRANSPARENT, 10, 10),
        tokens.focus_style(10),
        _box(Color.TRANSPARENT, Color.TRANSPARENT, 10, 10)
    )
    return button

func floating_action_button(button: Button) -> Button:
    _prepare_button(button, 14)
    button.custom_minimum_size = Vector2(56, 56)
    button.clip_contents = true
    button.add_theme_font_size_override("font_size", 26)
    _set_font_colors(button, tokens.text_on_accent, tokens.text_on_accent, tokens.text_tertiary)
    for state in ["normal", "hover", "pressed", "focus"]:
        button.add_theme_color_override("icon_%s_color" % state, tokens.text_on_accent)
    var normal := _round(tokens.accent)
    _set_button_boxes(
        button,
        normal,
        _round(tokens.accent.lightened(0.08)),
        _round(tokens.accent.darkened(0.10)),
        normal,
        _round(tokens.surface_hover)
    )
    return button

# Top bar route tab: plain text; the sliding underline is the selection mark.
func tab_button(button: Button, selected: bool = false) -> Button:
    _prepare_button(button, 15)
    button.custom_minimum_size = Vector2(0, 44)
    var foreground: Color = tokens.text_primary if selected else tokens.text_secondary
    _set_font_colors(button, foreground, tokens.text_primary, tokens.text_tertiary)
    for state in ["normal", "focus"]:
        button.add_theme_color_override("icon_%s_color" % state, tokens.accent_text if selected else tokens.text_secondary)
    for state in ["hover", "pressed", "hover_pressed"]:
        button.add_theme_color_override("icon_%s_color" % state, tokens.accent_text if selected else tokens.text_primary)
    var rest := _box(Color.TRANSPARENT, Color.TRANSPARENT, 10, 14)
    _set_button_boxes(
        button,
        rest,
        _box(tokens.tint(tokens.text_primary, 0.05), Color.TRANSPARENT, 10, 14),
        _box(tokens.tint(tokens.text_primary, 0.09), Color.TRANSPARENT, 10, 14),
        tokens.focus_style(10),
        rest
    )
    return button

# Compact dock item: icon above a small caption.
func dock_button(button: Button, selected: bool = false) -> Button:
    _prepare_button(button, 11)
    button.custom_minimum_size = Vector2(64, 56)
    button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
    var foreground: Color = tokens.accent_text if selected else tokens.text_tertiary
    _set_font_colors(button, foreground, tokens.text_primary if not selected else foreground, tokens.text_tertiary)
    for state in ["normal", "focus", "hover", "pressed", "hover_pressed"]:
        button.add_theme_color_override("icon_%s_color" % state, foreground if state in ["normal", "focus"] or selected else tokens.text_primary)
    var rest := _box(Color.TRANSPARENT, Color.TRANSPARENT, 14, 4)
    rest.content_margin_top = 6
    rest.content_margin_bottom = 4
    _set_button_boxes(button, rest, rest, rest, rest, rest)
    return button

func disclosure_button(button: Button) -> Button:
    _prepare_button(button, 15)
    _set_font_colors(button, tokens.text_primary, tokens.text_primary, tokens.text_tertiary)
    var boxes := []
    for fill in [Color.TRANSPARENT, tokens.tint(tokens.text_primary, 0.04), tokens.tint(tokens.text_primary, 0.08)]:
        var style := _box(fill, Color.TRANSPARENT, 10, 12)
        style.content_margin_right = 48
        boxes.append(style)
    var focus: StyleBoxFlat = tokens.focus_style(10)
    focus.content_margin_left = 12
    focus.content_margin_right = 48
    _set_button_boxes(button, boxes[0], boxes[1], boxes[2], focus, boxes[0])
    return button

func line_edit(input: LineEdit) -> LineEdit:
    input.custom_minimum_size.y = CONTROL_HEIGHT
    input.add_theme_font_size_override("font_size", 15)
    input.add_theme_color_override("font_color", tokens.text_primary)
    input.add_theme_color_override("font_placeholder_color", tokens.text_tertiary)
    input.add_theme_color_override("caret_color", tokens.accent)
    input.add_theme_color_override("selection_color", tokens.tint(tokens.accent, 0.28))
    input.add_theme_constant_override("minimum_character_width", 12)
    input.add_theme_constant_override("caret_width", 2)
    input.add_theme_stylebox_override("normal", field_box(false))
    input.add_theme_stylebox_override("focus", field_box(true))
    input.add_theme_stylebox_override("read_only", _box(tokens.surface_hover, tokens.separator))
    input.caret_blink = true
    return input

func field_box(focused: bool) -> StyleBoxFlat:
    var style: StyleBoxFlat = tokens.panel(
        tokens.background_raised,
        RADIUS,
        tokens.accent if focused else tokens.outline,
        2 if focused else 1
    )
    style.content_margin_left = 14
    style.content_margin_top = 10
    style.content_margin_right = 14
    style.content_margin_bottom = 10
    if focused:
        style.shadow_color = tokens.tint(tokens.accent, 0.18)
        style.shadow_size = 6
    return style

func _solid_button(button: Button, fill: Color, foreground: Color) -> Button:
    _prepare_button(button, 15)
    _set_font_colors(button, foreground, foreground, tokens.text_tertiary)
    for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
        button.add_theme_color_override("icon_%s_color" % state, foreground)
    var normal := _sheen(_box(fill, Color.TRANSPARENT, PILL), fill)
    normal.shadow_color = tokens.tint(fill, 0.30 if tokens.is_dark() else 0.26)
    normal.shadow_size = 10
    normal.shadow_offset = Vector2(0, 4)
    var hover := _sheen(_box(fill.lightened(0.08), Color.TRANSPARENT, PILL), fill.lightened(0.08))
    hover.shadow_color = tokens.tint(fill, 0.42 if tokens.is_dark() else 0.34)
    hover.shadow_size = 18
    hover.shadow_offset = Vector2(0, 6)
    var pressed := _box(fill.darkened(0.10), Color.TRANSPARENT, PILL)
    pressed.shadow_color = tokens.tint(fill, 0.24)
    pressed.shadow_size = 4
    pressed.shadow_offset = Vector2(0, 1)
    var focus := _box(fill.lightened(0.04), tokens.tint(foreground, 0.55), PILL, 18, 2)
    _set_button_boxes(button, normal, hover, pressed, focus, _box(tokens.surface_hover, tokens.separator, PILL))
    motion.bind_hover_lift(button, 1.025)
    return button

func _prepare_button(button: Button, font_size: int) -> void:
    button.focus_mode = Control.FOCUS_ALL
    button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, CONTROL_HEIGHT)
    button.add_theme_font_size_override("font_size", font_size)
    button.add_theme_constant_override("h_separation", 8)
    motion.bind_tactile(button)

func _set_font_colors(button: Button, normal: Color, active: Color, disabled: Color) -> void:
    button.add_theme_color_override("font_color", normal)
    button.add_theme_color_override("font_hover_color", active)
    button.add_theme_color_override("font_pressed_color", active)
    button.add_theme_color_override("font_focus_color", normal)
    button.add_theme_color_override("font_hover_pressed_color", active)
    button.add_theme_color_override("font_disabled_color", disabled)

func _set_button_boxes(button: Button, normal: StyleBox, hover: StyleBox, pressed: StyleBox, focus: StyleBox, disabled: StyleBox) -> void:
    button.add_theme_stylebox_override("normal", normal)
    button.add_theme_stylebox_override("hover", hover)
    button.add_theme_stylebox_override("pressed", pressed)
    button.add_theme_stylebox_override("hover_pressed", pressed)
    button.add_theme_stylebox_override("focus", focus)
    button.add_theme_stylebox_override("disabled", disabled)

func _box(fill: Color, border: Color = Color.TRANSPARENT, radius: int = RADIUS, horizontal: int = 18, border_width: int = 1) -> StyleBoxFlat:
    var style: StyleBoxFlat = tokens.panel(fill, radius, border, border_width if border.a > 0.0 else 0)
    style.content_margin_left = horizontal
    style.content_margin_right = horizontal
    style.content_margin_top = 8
    style.content_margin_bottom = 8
    return style

func _round(fill: Color) -> StyleBoxFlat:
    var style: StyleBoxFlat = tokens.panel(fill, 999)
    style.content_margin_left = 0
    style.content_margin_top = 0
    style.content_margin_right = 0
    style.content_margin_bottom = 0
    return style

# A lighter hairline along the top edge reads as light catching the button.
func _sheen(style: StyleBoxFlat, fill: Color) -> StyleBoxFlat:
    style.border_color = fill.lightened(0.28)
    style.border_width_top = 1
    style.border_blend = true
    return style
