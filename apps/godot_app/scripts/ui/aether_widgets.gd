extends RefCounted

# Aurora widget factory: turns plain Godot controls into the app's glass and
# gradient components. Primary actions get a GPU gradient surface with glow,
# hover sheen and a click ripple; secondary actions are frosted glass with a
# rim that warms to the accent on hover.

const AetherSurface = preload("res://scripts/ui/aether_surface.gd")

const CONTROL_HEIGHT := 44.0
const ICON_BUTTON_SIZE := 44.0
const SURFACE_NAME := "AetherSurface"

var tokens
var motion

func _init(design_tokens, motion_system) -> void:
    tokens = design_tokens
    motion = motion_system

func primary_button(button: Button) -> Button:
    return _gradient_button(button, tokens.accent, tokens.accent_2, Color(1, 1, 1, 0.26))

func destructive_button(button: Button) -> Button:
    return _gradient_button(button, tokens.danger, tokens.accent_3, Color(1, 1, 1, 0.22))

func secondary_button(button: Button, destructive: bool = false) -> Button:
    _prepare_button(button, 15)
    var foreground: Color = tokens.danger if destructive else tokens.text_primary
    _set_font_colors(button, foreground, foreground, tokens.tint(foreground, 0.38))
    var tint: Color = tokens.danger if destructive else tokens.accent
    _set_button_boxes(
        button,
        _glass_box(tokens.glass_material, tokens.rim),
        _glass_box(tokens.tint(tint, 0.12), tokens.tint(tint, 0.55)),
        _glass_box(tokens.tint(tint, 0.20), tokens.tint(tint, 0.75)),
        _focus_box(16),
        _glass_box(tokens.tint(tokens.surface_raised, 0.30), tokens.separator)
    )
    motion.bind_ripple(button, tokens.tint(tint, 0.22), 16.0)
    return button

func toolbar_button(button: Button, selected: bool = false) -> Button:
    _prepare_button(button, 14)
    button.custom_minimum_size = Vector2(ICON_BUTTON_SIZE, ICON_BUTTON_SIZE)
    var foreground: Color = tokens.accent if selected else tokens.text_secondary
    var hover_foreground: Color = tokens.accent if selected else tokens.text_primary
    button.add_theme_color_override("font_color", foreground)
    button.add_theme_color_override("font_hover_color", hover_foreground)
    button.add_theme_color_override("font_pressed_color", tokens.accent)
    button.add_theme_color_override("font_focus_color", foreground)
    button.add_theme_color_override("font_disabled_color", tokens.text_tertiary)
    button.add_theme_color_override("icon_normal_color", foreground)
    button.add_theme_color_override("icon_hover_color", hover_foreground)
    button.add_theme_color_override("icon_pressed_color", tokens.accent)
    button.add_theme_color_override("icon_focus_color", foreground)
    button.add_theme_color_override("icon_disabled_color", tokens.text_tertiary)
    _set_button_boxes(
        button,
        _round_box(tokens.accent_fill if selected else Color.TRANSPARENT, 14),
        _round_box(tokens.tint(tokens.text_primary, 0.08), 14, tokens.rim),
        _round_box(tokens.accent_fill, 14),
        _focus_box(14),
        _round_box(Color.TRANSPARENT, 14)
    )
    motion.bind_ripple(button, tokens.tint(tokens.accent, 0.25), 14.0)
    return button

func floating_action_button(button: Button) -> Button:
    _prepare_button(button, 14)
    button.custom_minimum_size = Vector2(56, 56)
    button.clip_contents = true
    button.add_theme_font_size_override("font_size", 28)
    _set_font_colors(button, Color.WHITE, Color.WHITE, Color(1, 1, 1, 0.5))
    for state in ["normal", "hover", "pressed", "focus"]:
        button.add_theme_color_override("icon_%s_color" % state, Color.WHITE)
    var normal := _fab_box(tokens.accent)
    var hover := _fab_box(tokens.accent.lightened(0.06))
    var pressed := _fab_box(tokens.accent.darkened(0.12))
    var disabled := _fab_box(tokens.tint(tokens.surface_raised, 0.70))
    _set_button_boxes(button, normal, hover, pressed, normal, disabled)
    return button

func navigation_button(button: Button, selected: bool = false) -> Button:
    _prepare_button(button, 15)
    button.custom_minimum_size.y = 46.0
    _set_nav_colors(button, selected)
    _set_button_boxes(
        button,
        tokens.button_style(Color.TRANSPARENT, Color.TRANSPARENT, 16),
        tokens.button_style(tokens.tint(tokens.text_primary, 0.07), Color.TRANSPARENT, 16),
        tokens.button_style(tokens.tint(tokens.text_primary, 0.12), Color.TRANSPARENT, 16),
        _focus_box(16),
        tokens.button_style(Color.TRANSPARENT, Color.TRANSPARENT, 16)
    )
    return button

func ghost_nav_button(button: Button, selected: bool = false) -> Button:
    # Rail navigation: rows carry no chrome; the sliding glass pill behind
    # them is the only selection surface. Content margins keep the icon and
    # label inset so the pill fully wraps them on every side.
    _prepare_button(button, 15)
    _set_nav_colors(button, selected)
    for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
        var row: StyleBoxFlat = tokens.panel(Color.TRANSPARENT, 14)
        row.content_margin_left = 14
        row.content_margin_right = 14
        button.add_theme_stylebox_override(state, row)
    return button

func disclosure_button(button: Button) -> Button:
    _prepare_button(button, 15)
    _set_font_colors(button, tokens.text_primary, tokens.text_primary, tokens.text_tertiary)
    var normal := _round_box(Color.TRANSPARENT, 14)
    var hover := _round_box(tokens.tint(tokens.text_primary, 0.05), 14)
    var pressed := _round_box(tokens.accent_fill, 14)
    var focus := _focus_box(14)
    var disabled := _round_box(Color.TRANSPARENT, 14)
    for style in [normal, hover, pressed, focus, disabled]:
        style.content_margin_left = 14
        style.content_margin_right = 44
    _set_button_boxes(button, normal, hover, pressed, focus, disabled)
    return button

func line_edit(input: LineEdit) -> LineEdit:
    input.custom_minimum_size.y = CONTROL_HEIGHT
    input.add_theme_font_size_override("font_size", 15)
    input.add_theme_color_override("font_color", tokens.text_primary)
    input.add_theme_color_override("font_placeholder_color", tokens.text_tertiary)
    input.add_theme_color_override("caret_color", tokens.accent)
    input.add_theme_color_override("selection_color", tokens.tint(tokens.accent, 0.32))
    input.add_theme_constant_override("minimum_character_width", 12)
    input.add_theme_constant_override("caret_width", 2)
    input.add_theme_stylebox_override("normal", _field_box(false))
    input.add_theme_stylebox_override("focus", _field_box(true))
    input.add_theme_stylebox_override("read_only", _disabled_field_box())
    input.caret_blink = true
    return input

# Glass card chrome for arbitrary containers: fill + rim + optional glow.
# Containers lay out every child, so the surface is attached as an internal
# child (outside the container's layout) and follows the host's size.
func glass_surface(host: Control, radius: float = 22.0, elevated: bool = false) -> Control:
    var surface = AetherSurface.new()
    surface.name = SURFACE_NAME
    surface.show_behind_parent = true
    surface.configure(tokens.glass_material, tokens.tint(tokens.glass_material, tokens.glass_material.a * 0.7), radius, PI * 0.5)
    surface.rim(tokens.rim, 1.0, 0.7)
    if elevated:
        surface.glow(tokens.tint(tokens.shadow, tokens.shadow.a * 0.8), 22.0)
    host.add_child(surface, false, Node.INTERNAL_MODE_FRONT)
    var follow := func():
        if is_instance_valid(surface):
            surface.position = Vector2.ZERO
            surface.size = host.size
    host.resized.connect(follow)
    follow.call()
    return surface

func _gradient_button(button: Button, from: Color, to: Color, ripple_tint: Color) -> Button:
    _prepare_button(button, 15)
    var fg: Color = tokens.text_on_accent
    _set_font_colors(button, fg, fg, tokens.text_tertiary)
    for state in ["normal", "hover", "pressed", "focus"]:
        button.add_theme_color_override("icon_%s_color" % state, fg)
    var clear := _gradient_box()
    _set_button_boxes(
        button,
        clear,
        _gradient_box(),
        _gradient_box(),
        _focus_box(8),
        _glass_box(tokens.tint(tokens.surface_raised, 0.46), tokens.separator)
    )
    var surface = button.get_node_or_null(SURFACE_NAME)
    if surface == null:
        surface = AetherSurface.new()
        surface.name = SURFACE_NAME
        surface.show_behind_parent = true
        button.add_child(surface, false, Node.INTERNAL_MODE_FRONT)
        button.mouse_entered.connect(func(): _gradient_hover(button, true))
        button.mouse_exited.connect(func(): _gradient_hover(button, false))
        button.button_down.connect(func():
            if is_instance_valid(surface):
                surface.set_param("brightness", -0.06)
        )
        button.button_up.connect(func():
            if is_instance_valid(surface):
                surface.set_param("brightness", 0.0)
        )
        # Disabled is a plain property with no signal. The button redraws
        # whenever it changes, so follow the draw notification (deferred so
        # the child is never toggled mid-draw).
        button.draw.connect(func():
            if is_instance_valid(surface) and surface.visible == button.disabled:
                surface.set_deferred("visible", not button.disabled)
        )
    surface.configure(from, to, 16.0, 0.35)
    surface.rim(Color(1, 1, 1, 0.34 if tokens.is_dark() else 0.45), 1.0, 1.0)
    surface.set_param("highlight", 1.0)
    surface.glow(tokens.tint(from, 0.0), 18.0)
    surface.visible = not button.disabled
    motion.bind_ripple(button, ripple_tint, 16.0)
    return button

func _gradient_hover(button: Button, active: bool) -> void:
    var surface = button.get_node_or_null(SURFACE_NAME)
    if surface == null or button.disabled:
        return
    var glow_color: Color = surface.get_param("color_a")
    surface.tween_param("glow_color", tokens.tint(glow_color, 0.42 if active else 0.0), 0.26)
    surface.tween_param("brightness", 0.04 if active else 0.0, 0.2)
    if active and not motion.reduced_motion:
        surface.sweep(0.7, 0.22)

func _set_nav_colors(button: Button, selected: bool) -> void:
    var foreground: Color = tokens.text_primary if selected else tokens.text_secondary
    var icon_color: Color = tokens.accent if selected else tokens.text_secondary
    button.add_theme_color_override("font_color", foreground)
    button.add_theme_color_override("font_hover_color", tokens.text_primary)
    button.add_theme_color_override("font_pressed_color", tokens.text_primary)
    button.add_theme_color_override("font_focus_color", foreground)
    button.add_theme_color_override("icon_normal_color", icon_color)
    button.add_theme_color_override("icon_hover_color", tokens.accent if selected else tokens.text_primary)
    button.add_theme_color_override("icon_pressed_color", tokens.accent)
    button.add_theme_color_override("icon_focus_color", icon_color)

func _set_font_colors(button: Button, normal: Color, active: Color, disabled: Color) -> void:
    button.add_theme_color_override("font_color", normal)
    button.add_theme_color_override("font_hover_color", active)
    button.add_theme_color_override("font_pressed_color", active)
    button.add_theme_color_override("font_focus_color", normal)
    button.add_theme_color_override("font_hover_pressed_color", active)
    button.add_theme_color_override("font_disabled_color", disabled)

func _prepare_button(button: Button, font_size: int) -> void:
    button.focus_mode = Control.FOCUS_ALL
    button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, CONTROL_HEIGHT)
    button.add_theme_font_size_override("font_size", font_size)
    button.add_theme_constant_override("h_separation", 8)
    motion.bind_tactile(button)

func _fab_box(fill: Color) -> StyleBoxFlat:
    var style: StyleBoxFlat = tokens.panel(fill, 999)
    style.content_margin_left = 0
    style.content_margin_top = 0
    style.content_margin_right = 0
    style.content_margin_bottom = 0
    return style

func _set_button_boxes(button: Button, normal: StyleBox, hover: StyleBox, pressed: StyleBox, focus: StyleBox, disabled: StyleBox) -> void:
    button.add_theme_stylebox_override("normal", normal)
    button.add_theme_stylebox_override("hover", hover)
    button.add_theme_stylebox_override("pressed", pressed)
    button.add_theme_stylebox_override("hover_pressed", pressed)
    button.add_theme_stylebox_override("focus", focus)
    button.add_theme_stylebox_override("disabled", disabled)

func _gradient_box() -> StyleBoxFlat:
    # The gradient surface child paints the fill; this box only carries the
    # content margins and corner radius used for focus/hit feedback.
    var style: StyleBoxFlat = tokens.button_style(Color.TRANSPARENT, Color.TRANSPARENT, 16)
    style.content_margin_left = 18
    style.content_margin_right = 18
    return style

func _glass_box(fill: Color, border: Color) -> StyleBoxFlat:
    var style: StyleBoxFlat = tokens.button_style(fill, border, 16)
    style.shadow_size = 0
    return style

func _round_box(fill: Color, radius: int, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
    var style: StyleBoxFlat = tokens.button_style(fill, border, radius)
    style.content_margin_left = 10
    style.content_margin_right = 10
    return style

func _field_box(focused: bool) -> StyleBoxFlat:
    var style: StyleBoxFlat = tokens.panel(
        tokens.tint(tokens.background_raised, 0.72 if tokens.is_dark() else 0.9),
        14,
        tokens.accent if focused else tokens.rim,
        2 if focused else 1
    )
    style.content_margin_left = 16
    style.content_margin_top = 10
    style.content_margin_right = 16
    style.content_margin_bottom = 10
    if focused:
        style.shadow_color = tokens.tint(tokens.accent, 0.28)
        style.shadow_size = 10
    return style

func _disabled_field_box() -> StyleBoxFlat:
    return _glass_box(tokens.tint(tokens.surface_raised, 0.34), tokens.separator)

func _focus_box(_radius: int) -> StyleBoxFlat:
    return tokens.focus_style(16)
