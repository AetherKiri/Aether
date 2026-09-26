extends Button

# Glass toggle: the off track is frosted glass, the on track fills with the
# accent gradient from the knob outward. The knob stretches while it travels
# and lands with a jelly wobble; a soft halo breathes out on every flip.

const AetherSurface = preload("res://scripts/ui/aether_surface.gd")

const TRACK_SIZE := Vector2(58, 34)
const KNOB_SIZE := Vector2(26, 26)
const TRACK_INSET := 4.0

var tokens
var motion
var knob: PanelContainer
var fill_surface: Control
var halo: Control

func setup(design_tokens, motion_system, initial_value: bool) -> void:
    tokens = design_tokens
    motion = motion_system
    text = ""
    toggle_mode = true
    button_pressed = initial_value
    focus_mode = Control.FOCUS_ALL
    mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    custom_minimum_size = TRACK_SIZE
    size_flags_horizontal = Control.SIZE_SHRINK_END
    size_flags_vertical = Control.SIZE_SHRINK_CENTER
    add_theme_stylebox_override("focus", tokens.focus_style(17))

    var dark: bool = tokens.is_dark()
    fill_surface = AetherSurface.new()
    fill_surface.show_behind_parent = true
    fill_surface.configure(tokens.accent, tokens.accent_2, 17.0, 0.0)
    fill_surface.rim(Color(1, 1, 1, 0.30), 1.0, 1.0)
    fill_surface.set_param("highlight", 1.0)
    fill_surface.glow(tokens.tint(tokens.accent, 0.35), 8.0)
    add_child(fill_surface)

    halo = Control.new()
    halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(halo)
    var halo_rect := TextureRect.new()
    halo_rect.texture = tokens.radial_glow_texture(tokens.tint(tokens.accent, 0.55), 64)
    halo_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    halo_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    halo_rect.size = Vector2(56, 56)
    halo_rect.position = Vector2(-28, -28)
    halo.add_child(halo_rect)
    halo.modulate.a = 0.0

    knob = PanelContainer.new()
    knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
    knob.size = KNOB_SIZE
    knob.pivot_offset = KNOB_SIZE * 0.5
    var knob_style: StyleBoxFlat = tokens.panel(Color.WHITE, 13)
    # Light themes need a hairline that darkens toward the track; dark themes
    # get a top light edge. Either way the geometry stays identical, so every
    # switch in every section reads as the same control.
    knob_style.border_color = Color(1, 1, 1, 0.56) if dark else Color(0, 0, 0, 0.10)
    knob_style.border_width_top = 1
    knob_style.shadow_color = Color(0, 0, 0, 0.32 if dark else 0.18)
    knob_style.shadow_size = 6 if dark else 4
    knob_style.shadow_offset = Vector2(0, 2)
    knob.add_theme_stylebox_override("panel", knob_style)
    add_child(knob)

    button_down.connect(_press_in)
    button_up.connect(_press_out)
    mouse_exited.connect(_press_out)
    mouse_entered.connect(func(): _hover(true))
    mouse_exited.connect(func(): _hover(false))
    toggled.connect(func(value: bool): _sync(value, true))
    _sync(initial_value, false)

func _sync(enabled: bool, animate: bool) -> void:
    var dark: bool = tokens.is_dark()
    # Off: a frosted glass pill with a hairline rim. On: the gradient surface
    # fades in underneath and the glass fill drops away.
    var off_fill := Color(
        tokens.text_primary.r,
        tokens.text_primary.g,
        tokens.text_primary.b,
        0.10 if dark else 0.12
    )
    var track_fill: Color = Color.TRANSPARENT if enabled else off_fill
    var track_border: Color = Color.TRANSPARENT if enabled else tokens.tint(tokens.rim, 0.9)
    var style: StyleBoxFlat = tokens.panel(track_fill, 17, track_border, 1)
    style.shadow_color = tokens.tint(tokens.shadow, 0.10)
    style.shadow_size = 3
    style.shadow_offset = Vector2(0, 2)
    add_theme_stylebox_override("normal", style)
    add_theme_stylebox_override("hover", _track_variant_box(style, 0.04))
    add_theme_stylebox_override("pressed", _track_variant_box(style, -0.05))
    add_theme_stylebox_override("hover_pressed", _track_variant_box(style, 0.04))
    add_theme_stylebox_override("disabled", _track_variant_box(style, -0.38))
    var target := Vector2(TRACK_SIZE.x - TRACK_INSET - KNOB_SIZE.x, TRACK_INSET) if enabled else Vector2(TRACK_INSET, TRACK_INSET)
    if not animate or motion.reduced_motion:
        knob.position = target
        fill_surface.modulate.a = 1.0 if enabled else 0.0
        return
    motion.spring_property(knob, "position", target, 0.30, 0.72)
    motion.spring_property(fill_surface, "modulate:a", 1.0 if enabled else 0.0, 0.22, 1.0)
    _stretch_knob()
    _pulse_halo(target + KNOB_SIZE * 0.5)

func _track_variant_box(base: StyleBoxFlat, lighten: float) -> StyleBoxFlat:
    var style: StyleBoxFlat = base.duplicate()
    style.bg_color = base.bg_color.lightened(lighten)
    return style

func _stretch_knob() -> void:
    if motion.reduced_motion:
        return
    # Elastic deformation: horizontal stretch while sliding, then a jelly
    # settle back to a round knob.
    _animate_knob_scale(Vector2(1.28, 0.82), 0.10)
    var tree := get_tree()
    if tree != null:
        tree.create_timer(0.09).timeout.connect(
            func(): motion.spring_property(knob, "scale", Vector2.ONE, 0.30, 0.48),
            CONNECT_ONE_SHOT
        )

func _pulse_halo(center: Vector2) -> void:
    if halo == null:
        return
    halo.position = center
    halo.scale = Vector2(0.4, 0.4)
    halo.modulate.a = 0.9
    var tween := halo.create_tween().set_parallel(true)
    tween.tween_property(halo, "scale", Vector2(1.5, 1.5), 0.5).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
    tween.tween_property(halo, "modulate:a", 0.0, 0.5).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)

func _hover(active: bool) -> void:
    if knob == null or motion.reduced_motion or disabled:
        return
    _animate_knob_scale(Vector2(1.06, 1.06) if active else Vector2.ONE, 0.22)

func _press_in() -> void:
    if motion.reduced_motion:
        return
    _animate_knob_scale(Vector2(1.16, 0.92), 0.16)

func _press_out() -> void:
    if knob == null:
        return
    if motion.reduced_motion:
        knob.scale = Vector2.ONE
        return
    _animate_knob_scale(Vector2.ONE, 0.24)

func _animate_knob_scale(target: Vector2, response: float) -> void:
    motion.spring_property(knob, "scale", target, response, 1.0)

func _track_box(_fill: Color) -> StyleBoxFlat:
    # Retained for compatibility; the rounded pill built in _sync is the
    # canonical track style now.
    var style: StyleBoxFlat = tokens.panel(tokens.accent, 17, tokens.separator, 1)
    style.shadow_offset = Vector2(0, 2)
    return style
