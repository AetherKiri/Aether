extends Button

# Lumen toggle: a solid track that floods with the signal colour from the
# knob's side, and a knob that stretches while it travels and lands with a
# small wobble. An inner pip on the knob picks up the accent when on.

const TRACK_SIZE := Vector2(52, 30)
const KNOB_SIZE := Vector2(24, 24)
const TRACK_INSET := 3.0

var tokens
var motion
var knob: PanelContainer
var pip: Panel
var flood: Panel

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
    clip_contents = true
    add_theme_stylebox_override("focus", tokens.focus_style(15))
    var track: StyleBoxFlat = tokens.panel(tokens.surface_hover, 15, tokens.outline, 1)
    add_theme_stylebox_override("normal", track)
    add_theme_stylebox_override("hover", _track_variant(track, 0.03))
    add_theme_stylebox_override("pressed", track)
    add_theme_stylebox_override("hover_pressed", _track_variant(track, 0.03))
    var disabled_track := _track_variant(track, 0.0)
    disabled_track.bg_color = tokens.tint(tokens.surface_hover, 0.5)
    add_theme_stylebox_override("disabled", disabled_track)

    # The accent flood grows out from the left edge underneath the knob.
    flood = Panel.new()
    flood.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flood.add_theme_stylebox_override("panel", tokens.panel(tokens.accent, 15))
    flood.position = Vector2.ZERO
    flood.size = TRACK_SIZE
    flood.pivot_offset = Vector2(0, TRACK_SIZE.y * 0.5)
    add_child(flood)

    knob = PanelContainer.new()
    knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
    knob.size = KNOB_SIZE
    knob.pivot_offset = KNOB_SIZE * 0.5
    var knob_style: StyleBoxFlat = tokens.panel(Color.WHITE, 12)
    # One geometry for every palette; only the hairline adapts: a faint dark
    # edge on light tracks, a light top edge on dark ones.
    knob_style.border_color = Color(1, 1, 1, 0.6) if tokens.is_dark() else Color(0, 0, 0, 0.08)
    knob_style.border_width_top = 1
    knob_style.shadow_color = Color(0, 0, 0, 0.30 if tokens.is_dark() else 0.16)
    knob_style.shadow_size = 4
    knob_style.shadow_offset = Vector2(0, 1)
    knob.add_theme_stylebox_override("panel", knob_style)
    add_child(knob)

    pip = Panel.new()
    pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
    pip.add_theme_stylebox_override("panel", tokens.panel(tokens.accent, 4))
    pip.custom_minimum_size = Vector2(8, 8)
    pip.size = Vector2(8, 8)
    pip.pivot_offset = Vector2(4, 4)
    var pip_holder := CenterContainer.new()
    pip_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
    pip_holder.add_child(pip)
    knob.add_child(pip_holder)

    button_down.connect(_press_in)
    button_up.connect(_press_out)
    mouse_exited.connect(_press_out)
    motion.bind_hover(self, func(active: bool): _hover(active))
    toggled.connect(func(value: bool): _sync(value, true))
    _sync(initial_value, false)

func _sync(enabled: bool, animate: bool) -> void:
    var target := Vector2(TRACK_SIZE.x - TRACK_INSET - KNOB_SIZE.x, TRACK_INSET) if enabled else Vector2(TRACK_INSET, TRACK_INSET)
    var flood_scale := Vector2.ONE if enabled else Vector2(TRACK_SIZE.y / TRACK_SIZE.x, 1.0)
    var on_alpha := 1.0 if enabled else 0.0
    var pip_scale := Vector2.ONE if enabled else Vector2(0.2, 0.2)
    if not animate or motion.reduced_motion:
        knob.position = target
        flood.scale = flood_scale
        flood.modulate.a = on_alpha
        pip.scale = pip_scale
        pip.modulate.a = on_alpha
        return
    motion.spring_property(knob, "position", target, 0.30, 0.70)
    motion.spring_property(flood, "scale", flood_scale, 0.30, 0.85)
    motion.spring_property(flood, "modulate:a", on_alpha, 0.20, 1.0)
    motion.spring_property(pip, "scale", pip_scale, 0.26, 0.5)
    motion.spring_property(pip, "modulate:a", on_alpha, 0.18, 1.0)
    # Elastic travel: stretch along the track, then wobble back round.
    motion.spring_property(knob, "scale", Vector2(1.3, 0.84), 0.09, 1.0)
    var tree := get_tree()
    if tree != null:
        tree.create_timer(0.08).timeout.connect(
            func():
                if is_instance_valid(knob):
                    motion.spring_property(knob, "scale", Vector2.ONE, 0.30, 0.46),
            CONNECT_ONE_SHOT
        )

func _track_variant(base: StyleBoxFlat, lighten: float) -> StyleBoxFlat:
    var style: StyleBoxFlat = base.duplicate()
    style.bg_color = base.bg_color.lightened(lighten) if tokens.is_dark() else base.bg_color.darkened(lighten)
    return style

func _hover(active: bool) -> void:
    if knob == null or motion.reduced_motion or disabled:
        return
    motion.spring_property(knob, "scale", Vector2(1.08, 1.08) if active else Vector2.ONE, 0.22, 1.0)

func _press_in() -> void:
    if motion.reduced_motion:
        return
    motion.spring_property(knob, "scale", Vector2(1.18, 0.9), 0.14, 1.0)

func _press_out() -> void:
    if knob == null:
        return
    if motion.reduced_motion:
        knob.scale = Vector2.ONE
        return
    motion.spring_property(knob, "scale", Vector2.ONE, 0.24, 1.0)
