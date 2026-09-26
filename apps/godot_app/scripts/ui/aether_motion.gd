extends Node

# Aurora motion engine. A fixed-step spring integrator drives every
# interactive property (scale, position, size, rotation, colour, floats) and
# keeps velocity across retargets, so interrupted gestures never snap. Tween
# choreography builds on top for entrances, route changes, modals, ripples,
# count-ups and idle breathing loops.

const AetherShaders = preload("res://scripts/ui/aether_shaders.gd")

const PRESS_SCALE := Vector2(0.950, 0.950)
const TACTILE_PRESS_SCALE := Vector2(0.935, 0.935)
const HOVER_SCALE := Vector2(1.022, 1.022)
const REST_SCALE := Vector2.ONE
const ENTER_OFFSET := Vector2(0, 14)
const ENTER_DURATION := 0.34
const ROUTE_EXIT_DURATION := 0.20
const ROUTE_ENTER_DELAY := 0.06
const PRESS_RESPONSE := 0.10
const RELEASE_RESPONSE := 0.26
const HOVER_RESPONSE := 0.22
const SPRING_STEP := 1.0 / 120.0
const HERO_DURATION := 0.46
const HERO_MIN_ARC := 24.0
const HERO_MAX_ARC := 84.0
const RISE_START_SCALE := Vector2(0.94, 0.86)
const RISE_START_ROTATION := -0.035

var reduced_motion := false
var active_tweens: Dictionary = {}
var active_springs: Dictionary = {}

func _init() -> void:
    var value := OS.get_environment("AETHERKIRI_REDUCED_MOTION").strip_edges().to_lower()
    reduced_motion = value in ["1", "true", "yes", "on"]
    set_process(false)

func _process(delta: float) -> void:
    if active_springs.is_empty():
        set_process(false)
        return
    var clamped_delta := minf(delta, 1.0 / 30.0)
    var step_count := maxi(1, ceili(clamped_delta / SPRING_STEP))
    var step_delta := clamped_delta / float(step_count)
    var completed: Array[String] = []
    var callbacks: Array[Callable] = []
    for key_variant in active_springs.keys():
        var key := String(key_variant)
        var state: Dictionary = active_springs[key]
        # Keep the stored reference untyped until validity is checked. GDScript
        # raises when assigning a freed Object to a typed local before the
        # is_instance_valid guard can run.
        var owner = state.get("owner")
        if owner == null or not is_instance_valid(owner):
            completed.append(key)
            continue
        var property: NodePath = state.get("property")
        var current = owner.get_indexed(property)
        var target = state.get("target")
        var velocity = state.get("velocity")
        var response: float = state.get("response", 0.32)
        var damping_ratio: float = state.get("damping", 1.0)
        var omega := TAU / maxf(0.06, response)
        var stiffness := omega * omega
        var damping := 2.0 * damping_ratio * omega
        for _step in range(step_count):
            velocity += ((target - current) * stiffness - velocity * damping) * step_delta
            current += velocity * step_delta
        owner.set_indexed(property, current)
        state["velocity"] = velocity
        active_springs[key] = state
        var epsilon: float = state.get("epsilon", 0.001)
        if _value_length(target - current) <= epsilon and _value_length(velocity) <= epsilon * 4.0:
            owner.set_indexed(property, target)
            completed.append(key)
            var callback: Callable = state.get("finished", Callable())
            if callback.is_valid():
                callbacks.append(callback)
    for key in completed:
        active_springs.erase(key)
    for callback in callbacks:
        callback.call()
    if active_springs.is_empty():
        set_process(false)

func spring_property(
    owner: Object,
    property: StringName,
    target,
    response: float = 0.32,
    damping: float = 1.0,
    finished: Callable = Callable()
) -> void:
    if owner == null or not is_instance_valid(owner):
        if finished.is_valid():
            finished.call()
        return
    var key := _motion_key(owner, property)
    var path := NodePath(String(property))
    if reduced_motion:
        active_springs.erase(key)
        owner.set_indexed(path, target)
        if finished.is_valid():
            finished.call()
        return
    var current = owner.get_indexed(path)
    var velocity = _zero_like(current)
    if active_springs.has(key):
        velocity = active_springs[key].get("velocity", velocity)
    active_springs[key] = {
        "owner": owner,
        "property": path,
        "target": target,
        "velocity": velocity,
        "response": response,
        "damping": damping,
        "epsilon": 0.0008 if (current is float or current is Color) else 0.04,
        "finished": finished,
    }
    set_process(true)

func stop_spring(owner: Object, property: StringName) -> void:
    if owner != null:
        active_springs.erase(_motion_key(owner, property))

# Quick stretch along one axis followed by a wobbly settle: the signature
# "jelly" used by nav pills, segmented indicators and select triggers.
func jelly(control: Control, stretch: Vector2, settle_response: float = 0.30, settle_damping: float = 0.52) -> void:
    if control == null or not is_instance_valid(control) or reduced_motion:
        return
    _update_pivot(control)
    spring_property(control, "scale", stretch, 0.12, 0.72)
    _after(control, 0.09, func(current: Control):
        spring_property(current, "scale", REST_SCALE, settle_response, settle_damping)
    )

func bind_pressable(control: Control) -> void:
    if control == null or control.has_meta("aether_motion_bound"):
        return
    control.set_meta("aether_motion_bound", true)
    _update_pivot(control)
    control.resized.connect(func(): _update_pivot(control))
    if control is BaseButton:
        var button := control as BaseButton
        button.button_down.connect(func(): _press_in(button))
        button.button_up.connect(func(): _press_out(button))
        button.mouse_exited.connect(func():
            if not button.button_pressed:
                _press_out(button)
        )
        button.visibility_changed.connect(func():
            if not button.is_visible_in_tree():
                cancel_press(button)
        )

func bind_tactile(control: Control) -> void:
    if control == null:
        return
    control.set_meta("aether_press_scale", TACTILE_PRESS_SCALE)
    control.set_meta("aether_release_damping", 0.66)
    bind_pressable(control)

func cancel_press(control: Control) -> void:
    if control == null or not is_instance_valid(control):
        return
    active_springs.erase(_motion_key(control, "scale"))
    control.scale = REST_SCALE

func bind_lift(control: Control, highlight: CanvasItem = null, rest_alpha: float = 0.0, hover_alpha: float = 1.0) -> void:
    if control == null or control.has_meta("aether_lift_bound"):
        return
    control.set_meta("aether_lift_bound", true)
    control.set_meta("aether_hovered", false)
    _update_pivot(control)
    control.resized.connect(func(): _update_pivot(control))
    if highlight != null:
        highlight.modulate.a = rest_alpha
    control.mouse_entered.connect(func(): _set_lift_hover(control, highlight, true, rest_alpha, hover_alpha))
    control.mouse_exited.connect(func(): _set_lift_hover(control, highlight, false, rest_alpha, hover_alpha))
    control.focus_entered.connect(func(): _set_lift_hover(control, highlight, true, rest_alpha, hover_alpha))
    control.focus_exited.connect(func():
        if not control.get_global_rect().has_point(control.get_global_mouse_position()):
            _set_lift_hover(control, highlight, false, rest_alpha, hover_alpha)
    )
    if control is BaseButton:
        var button := control as BaseButton
        button.button_down.connect(func(): _press_in(button))
        button.button_up.connect(func():
            var hovered := bool(button.get_meta("aether_hovered", false))
            _animate_scale(button, HOVER_SCALE if hovered else REST_SCALE, RELEASE_RESPONSE, 0.58)
        )

# Pointer-follow tilt: the control leans a fraction of a degree toward the
# pointer and springs back when it leaves. Rotation never touches layout.
func bind_tilt(control: Control, max_angle: float = 0.018) -> void:
    if control == null or control.has_meta("aether_tilt_bound"):
        return
    control.set_meta("aether_tilt_bound", true)
    control.gui_input.connect(func(event: InputEvent):
        if reduced_motion or not event is InputEventMouseMotion or control.size.x <= 0.0:
            return
        var nx := clampf((event.position.x / control.size.x) * 2.0 - 1.0, -1.0, 1.0)
        spring_property(control, "rotation", nx * max_angle, 0.30, 0.8)
    )
    control.mouse_exited.connect(func():
        spring_property(control, "rotation", 0.0, 0.42, 0.55)
    )

func enter(control: Control, offset: Vector2 = ENTER_OFFSET, delay: float = 0.0) -> void:
    if control == null or not is_instance_valid(control):
        return
    _stop_tweens(control)
    var target_position := control.position
    control.modulate.a = 0.0
    if not reduced_motion:
        control.position = target_position + offset
    var enter_key := _tween_key(control, "enter")
    var tween := control.create_tween().set_parallel(true)
    active_tweens[enter_key] = tween
    var duration := 0.12 if reduced_motion else ENTER_DURATION
    tween.tween_property(control, "modulate:a", 1.0, duration * 0.8).set_delay(delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    if not reduced_motion:
        tween.tween_property(control, "position", target_position, duration).set_delay(delay).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
    tween.chain().tween_callback(func(): _finish_tween_key(enter_key))

func route_in(control: Control, direction: float = 1.0) -> void:
    enter(control, Vector2(0.0, 12.0 * (1.0 if direction >= 0.0 else -1.0)))

# Page change: the outgoing page recedes (fade, shrink, drift up) while the
# incoming page rises from below with a slight zoom. The two overlap so the
# content area never flashes empty.
func route_transition(
    outgoing: Control,
    incoming: Control,
    lift: bool = true,
    horizontal: bool = false,
    direction: float = 1.0,
    finished: Callable = Callable()
) -> void:
    if incoming == null or not is_instance_valid(incoming):
        if finished.is_valid():
            finished.call()
        return
    _stop_tweens(incoming)
    active_springs.erase(_motion_key(incoming, "scale"))
    if outgoing != null and is_instance_valid(outgoing) and outgoing != incoming:
        _stop_tweens(outgoing)
        active_springs.erase(_motion_key(outgoing, "scale"))
    var incoming_rest: Vector2 = incoming.get_meta("aether_route_rest_position", incoming.position)
    incoming.set_meta("aether_route_rest_position", incoming_rest)
    incoming.visible = true
    incoming.modulate.a = 0.0
    _update_pivot(incoming)
    var enter_offset := Vector2(72.0 * direction, 0.0) if horizontal else Vector2(0.0, 34.0)
    var exit_offset := Vector2(-56.0 * direction, 0.0) if horizontal else Vector2(0.0, -18.0)
    var animate_geometry := lift and not reduced_motion
    incoming.position = incoming_rest + enter_offset if animate_geometry else incoming_rest
    incoming.scale = Vector2(0.975, 0.975) if animate_geometry else REST_SCALE
    var outgoing_rest := Vector2.ZERO
    var has_outgoing := outgoing != null and is_instance_valid(outgoing) and outgoing != incoming
    if has_outgoing:
        outgoing_rest = outgoing.get_meta("aether_route_rest_position", outgoing.position)
        outgoing.set_meta("aether_route_rest_position", outgoing_rest)
        outgoing.visible = true
        _update_pivot(outgoing)
    var incoming_ref: WeakRef = weakref(incoming)
    var incoming_key := _tween_key(incoming, "route")
    var outgoing_ref: Variant = weakref(outgoing) if has_outgoing else null
    var outgoing_key := _tween_key(outgoing, "route") if has_outgoing else ""
    var tween := incoming.create_tween().set_parallel(true)
    active_tweens[incoming_key] = tween
    if has_outgoing:
        active_tweens[outgoing_key] = tween
        tween.tween_property(outgoing, "modulate:a", 0.0, ROUTE_EXIT_DURATION).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
        if animate_geometry:
            tween.tween_property(outgoing, "position", outgoing_rest + exit_offset, ROUTE_EXIT_DURATION).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
            tween.tween_property(outgoing, "scale", Vector2(0.965, 0.965), ROUTE_EXIT_DURATION).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    var enter_duration := 0.14 if reduced_motion else 0.42
    var enter_delay := 0.0 if reduced_motion else ROUTE_ENTER_DELAY
    tween.tween_property(incoming, "modulate:a", 1.0, enter_duration * 0.7).set_delay(enter_delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    if animate_geometry:
        tween.tween_property(incoming, "position", incoming_rest, enter_duration).set_delay(enter_delay).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
        tween.tween_property(incoming, "scale", REST_SCALE, enter_duration).set_delay(enter_delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
    tween.chain().tween_callback(func():
        var incoming_control: Variant = incoming_ref.get_ref()
        if incoming_control != null and is_instance_valid(incoming_control):
            incoming_control.position = incoming_rest
            incoming_control.modulate.a = 1.0
            incoming_control.scale = REST_SCALE
        _finish_tween_key(incoming_key)
        var outgoing_control: Variant = outgoing_ref.get_ref() if outgoing_ref != null else null
        if outgoing_control != null and is_instance_valid(outgoing_control):
            outgoing_control.position = outgoing_rest
            outgoing_control.modulate.a = 1.0
            outgoing_control.scale = REST_SCALE
            outgoing_control.visible = false
            _finish_tween_key(outgoing_key)
        if finished.is_valid():
            finished.call()
    )

func settle_route(control: Control, show: bool) -> void:
    if control == null or not is_instance_valid(control):
        return
    _stop_tweens(control)
    active_springs.erase(_motion_key(control, "scale"))
    control.position = control.get_meta("aether_route_rest_position", control.position)
    control.modulate.a = 1.0
    control.scale = REST_SCALE
    control.visible = show

func hero_rect(control: Control, target_rect: Rect2, finished: Callable = Callable()) -> void:
    if control == null or not is_instance_valid(control):
        if finished.is_valid():
            finished.call()
        return
    if reduced_motion:
        control.position = target_rect.position
        control.size = target_rect.size
        if finished.is_valid():
            finished.call()
        return
    active_springs.erase(_motion_key(control, "position"))
    active_springs.erase(_motion_key(control, "size"))
    _stop_tweens(control)
    var start_rect := Rect2(control.position, control.size)
    var bank := 0.035 * (1.0 if target_rect.get_center().x >= start_rect.get_center().x else -1.0)
    var control_ref: WeakRef = weakref(control)
    var hero_key := _tween_key(control, "hero")
    var tween := control.create_tween()
    active_tweens[hero_key] = tween
    tween.tween_method(
        func(progress: float):
            var current_control: Variant = control_ref.get_ref()
            if current_control != null and is_instance_valid(current_control):
                var frame := hero_arc_rect(start_rect, target_rect, progress)
                current_control.position = frame.position
                current_control.size = frame.size
                # A gentle bank into the arc and back out makes the flight
                # read as a physical object instead of a rect lerp.
                current_control.pivot_offset = frame.size * 0.5
                current_control.rotation = sin(progress * PI) * bank,
        0.0,
        1.0,
        HERO_DURATION
    ).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN_OUT)
    tween.tween_callback(func():
        var current_control: Variant = control_ref.get_ref()
        if current_control != null and is_instance_valid(current_control):
            current_control.position = target_rect.position
            current_control.size = target_rect.size
            current_control.rotation = 0.0
        _finish_tween_key(hero_key)
        if finished.is_valid():
            finished.call()
    )

func hero_arc_rect(start_rect: Rect2, target_rect: Rect2, progress: float) -> Rect2:
    var t := clampf(progress, 0.0, 1.0)
    var start_center := start_rect.get_center()
    var target_center := target_rect.get_center()
    var delta := target_center - start_center
    var distance := delta.length()
    if distance < 0.001:
        return Rect2(start_rect.position.lerp(target_rect.position, t), start_rect.size.lerp(target_rect.size, t))
    var arc_height := clampf(distance * 0.14, HERO_MIN_ARC, HERO_MAX_ARC)
    var control := (start_center + target_center) * 0.5
    if absf(delta.x) >= absf(delta.y):
        control.y = minf(start_center.y, target_center.y) - arc_height
    else:
        control.x = maxf(start_center.x, target_center.x) + arc_height
    var one_minus_t := 1.0 - t
    var center := one_minus_t * one_minus_t * start_center \
        + 2.0 * one_minus_t * t * control \
        + t * t * target_center
    var size := start_rect.size.lerp(target_rect.size, t)
    return Rect2(center - size * 0.5, size)

func modal_in(scrim: CanvasItem, dialog: Control, background: Control = null) -> void:
    if scrim == null or dialog == null:
        return
    _stop_tweens(scrim)
    _stop_tweens(dialog)
    scrim.modulate.a = 0.0
    dialog.modulate.a = 0.0
    _update_pivot(dialog)
    var rest_position := dialog.position
    dialog.set_meta("aether_modal_rest_position", rest_position)
    if not reduced_motion:
        dialog.position = rest_position + Vector2(0, 28)
        dialog.scale = Vector2(0.90, 0.90)
        dialog.rotation = -0.02
        spring_property(dialog, "position", rest_position, 0.40, 0.72)
        spring_property(dialog, "scale", REST_SCALE, 0.36, 0.60)
        spring_property(dialog, "rotation", 0.0, 0.42, 0.62)
    else:
        dialog.scale = REST_SCALE
    _fade(scrim, 1.0, 0.24 if not reduced_motion else 0.12, "modal")
    _fade(dialog, 1.0, 0.18 if not reduced_motion else 0.12, "modal")
    if background != null and is_instance_valid(background):
        _update_pivot(background)
        spring_property(background, "scale", Vector2(0.975, 0.975), 0.42, 1.0)
        _fade(background, 0.86, 0.24, "modal_background")

func modal_out(scrim: CanvasItem, dialog: Control, background: Control = null, finished: Callable = Callable()) -> void:
    if scrim == null or dialog == null:
        if finished.is_valid():
            finished.call()
        return
    var rest_position: Vector2 = dialog.get_meta("aether_modal_rest_position", dialog.position)
    if not reduced_motion:
        spring_property(dialog, "position", rest_position + Vector2(0, 16), 0.22, 1.0)
        spring_property(dialog, "scale", Vector2(0.94, 0.94), 0.22, 1.0)
    _fade(scrim, 0.0, 0.18 if not reduced_motion else 0.10, "modal")
    _fade(dialog, 0.0, 0.15 if not reduced_motion else 0.10, "modal", finished)
    if background != null and is_instance_valid(background):
        spring_property(background, "scale", REST_SCALE, 0.36, 0.9)
        _fade(background, 1.0, 0.18, "modal_background")

func loading_in(panel: Control, card: Control, immediate: bool = false) -> void:
    if panel == null or card == null:
        return
    _stop_tweens(panel)
    if immediate:
        active_springs.erase(_motion_key(card, "scale"))
        panel.visible = true
        panel.modulate.a = 1.0
        card.scale = REST_SCALE
        return
    panel.visible = true
    panel.modulate.a = 0.0
    _update_pivot(card)
    if not reduced_motion:
        card.scale = Vector2(0.88, 0.88)
        spring_property(card, "scale", REST_SCALE, 0.38, 0.62)
    _fade(panel, 1.0, 0.22 if not reduced_motion else 0.12, "loading")

func loading_out(panel: Control, card: Control, finished: Callable = Callable()) -> void:
    if panel == null or not is_instance_valid(panel):
        if finished.is_valid():
            finished.call()
        return
    if card != null and is_instance_valid(card) and not reduced_motion:
        spring_property(card, "scale", Vector2(1.04, 1.04), 0.22, 1.0)
    var panel_ref: WeakRef = weakref(panel)
    var card_ref: Variant = weakref(card) if card != null and is_instance_valid(card) else null
    _fade(panel, 0.0, 0.18 if not reduced_motion else 0.10, "loading", func():
        var panel_control: Variant = panel_ref.get_ref()
        if panel_control != null and is_instance_valid(panel_control):
            panel_control.visible = false
            panel_control.modulate.a = 1.0
        var card_control: Variant = card_ref.get_ref() if card_ref != null else null
        if card_control != null and is_instance_valid(card_control):
            card_control.scale = REST_SCALE
        if finished.is_valid():
            finished.call()
    )

func reveal(control: Control, delay: float = 0.0) -> void:
    if control == null or not is_instance_valid(control):
        return
    _stop_tweens(control)
    _update_pivot(control)
    control.modulate.a = 0.0
    control.scale = REST_SCALE if reduced_motion else Vector2(0.97, 0.97)
    var reveal_key := _tween_key(control, "reveal")
    var tween := control.create_tween().set_parallel(true)
    active_tweens[reveal_key] = tween
    var duration := 0.12 if reduced_motion else 0.30
    tween.tween_property(control, "modulate:a", 1.0, duration * 0.8).set_delay(delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    if not reduced_motion:
        tween.tween_property(control, "scale", REST_SCALE, duration).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
    tween.chain().tween_callback(func(): _finish_tween_key(reveal_key))

func spring_reveal(control: Control, delay: float = 0.0) -> void:
    # Livelier cascade step: fade paired with an under-damped scale spring so
    # each row pops past rest and wobbles back into place.
    if control == null or not is_instance_valid(control):
        return
    _stop_tweens(control)
    active_springs.erase(_motion_key(control, "scale"))
    _update_pivot(control)
    control.modulate.a = 0.0
    control.scale = REST_SCALE if reduced_motion else Vector2(0.92, 0.92)
    var reveal_key := _tween_key(control, "reveal")
    var tween := control.create_tween()
    active_tweens[reveal_key] = tween
    var duration := 0.10 if reduced_motion else 0.18
    tween.tween_property(control, "modulate:a", 1.0, duration).set_delay(delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    tween.tween_callback(func(): _finish_tween_key(reveal_key))
    if reduced_motion:
        control.scale = REST_SCALE
        return
    _after(control, delay, func(current: Control):
        spring_property(current, "scale", REST_SCALE, 0.36, 0.56)
    )

# Rise-in used for card grids and section rows. Containers own `position`, so
# the rise is expressed through a bottom-anchored squash, a slight counter
# rotation and a fade: properties layout never overwrites.
func rise(control: Control, delay: float = 0.0) -> void:
    if control == null or not is_instance_valid(control):
        return
    _stop_tweens(control)
    active_springs.erase(_motion_key(control, "scale"))
    active_springs.erase(_motion_key(control, "rotation"))
    control.modulate.a = 0.0
    if reduced_motion:
        control.scale = REST_SCALE
        control.rotation = 0.0
        _fade(control, 1.0, 0.12, "reveal")
        return
    control.pivot_offset = Vector2(control.size.x * 0.5, control.size.y)
    control.scale = RISE_START_SCALE
    control.rotation = RISE_START_ROTATION
    var fade_key := _tween_key(control, "reveal")
    var tween := control.create_tween()
    active_tweens[fade_key] = tween
    tween.tween_property(control, "modulate:a", 1.0, 0.26).set_delay(delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    tween.tween_callback(func(): _finish_tween_key(fade_key))
    _after(control, delay, func(current: Control):
        spring_property(current, "scale", REST_SCALE, 0.44, 0.58, func():
            if is_instance_valid(current):
                _update_pivot(current)
        )
        spring_property(current, "rotation", 0.0, 0.50, 0.55)
    )

func cascade_children(parent: Node, step: float = 0.045, base_delay: float = 0.0, max_items: int = 14) -> void:
    if parent == null or not is_instance_valid(parent):
        return
    var index := 0
    for child in parent.get_children():
        if index >= max_items:
            break
        if child is Control and is_instance_valid(child) and not child.is_queued_for_deletion() and child.visible:
            rise(child, base_delay + step * float(index))
            index += 1

# Staggered pop with a springy overshoot, for small decorative items.
func pop_in(control: Control, delay: float = 0.0, from_scale: float = 0.6) -> void:
    if control == null or not is_instance_valid(control):
        return
    _update_pivot(control)
    control.modulate.a = 0.0
    if reduced_motion:
        control.scale = REST_SCALE
        _fade(control, 1.0, 0.12, "pop")
        return
    control.scale = Vector2(from_scale, from_scale)
    var tween := control.create_tween()
    tween.tween_property(control, "modulate:a", 1.0, 0.18).set_delay(delay)
    _after(control, delay, func(current: Control):
        spring_property(current, "scale", REST_SCALE, 0.40, 0.45)
    )

# Typewriter-style reveal for headings: characters stream in left to right.
func type_in(label: Label, delay: float = 0.0, duration: float = 0.42) -> void:
    if label == null or not is_instance_valid(label):
        return
    if reduced_motion or label.text.length() <= 1:
        label.visible_ratio = 1.0
        return
    label.visible_ratio = 0.0
    var tween := label.create_tween()
    tween.tween_property(label, "visible_ratio", 1.0, duration).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

# Animated number: counts `label` from `from_value` to `to_value` using the
# provided formatter callable (int -> String).
func count_up(label: Label, from_value: int, to_value: int, formatter: Callable, duration: float = 0.6) -> void:
    if label == null or not is_instance_valid(label):
        return
    var key := _tween_key(label, "count")
    _stop_tween_key(key)
    if reduced_motion or from_value == to_value:
        label.text = formatter.call(to_value)
        return
    var tween := label.create_tween()
    active_tweens[key] = tween
    tween.tween_method(
        func(value: float):
            if is_instance_valid(label):
                label.text = formatter.call(int(round(value))),
        float(from_value),
        float(to_value),
        duration
    ).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
    tween.tween_callback(func(): _finish_tween_key(key))

# Ripple from a local point, clipped to the control's rounded shape. The
# ripple rect frees itself once the wave has faded.
func ripple(control: Control, local_point: Vector2, tint: Color, radius: float = 14.0) -> void:
    if control == null or not is_instance_valid(control) or reduced_motion or control.size.x <= 0.0:
        return
    var wave := ColorRect.new()
    wave.mouse_filter = Control.MOUSE_FILTER_IGNORE
    wave.set_anchors_preset(Control.PRESET_FULL_RECT)
    var mat := AetherShaders.material(AetherShaders.ripple())
    mat.set_shader_parameter("rect_size", control.size)
    mat.set_shader_parameter("radius", radius)
    mat.set_shader_parameter("center", local_point)
    var far := maxf(
        maxf(local_point.length(), (local_point - Vector2(control.size.x, 0)).length()),
        maxf((local_point - Vector2(0, control.size.y)).length(), (local_point - control.size).length())
    )
    mat.set_shader_parameter("reach", far + 8.0)
    mat.set_shader_parameter("tint", tint)
    mat.set_shader_parameter("progress", 0.0)
    wave.material = mat
    control.add_child(wave)
    var tween := wave.create_tween()
    tween.tween_property(mat, "shader_parameter/progress", 1.0, 0.62).set_trans(Tween.TRANS_LINEAR)
    tween.tween_callback(wave.queue_free)

func bind_ripple(button: BaseButton, tint: Color, radius: float = 14.0) -> void:
    if button == null or button.has_meta("aether_ripple_bound"):
        return
    button.set_meta("aether_ripple_bound", true)
    button.gui_input.connect(func(event: InputEvent):
        if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
            ripple(button, event.position, tint, radius)
        elif event is InputEventScreenTouch and event.pressed:
            ripple(button, event.position, tint, radius)
    )

# Continuous gentle breathing: idle hero icons and the loading orb.
func breathe(control: Control, amount: float = 0.05, period: float = 2.6) -> Tween:
    if control == null or not is_instance_valid(control) or reduced_motion:
        return null
    _update_pivot(control)
    var key := _tween_key(control, "breathe")
    _stop_tween_key(key)
    var tween := control.create_tween().set_loops()
    active_tweens[key] = tween
    tween.tween_property(control, "scale", Vector2.ONE * (1.0 + amount), period * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    tween.tween_property(control, "scale", REST_SCALE, period * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    return tween

func float_idle(control: Control, amplitude: float = 0.05, period: float = 4.2) -> Tween:
    if control == null or not is_instance_valid(control) or reduced_motion:
        return null
    _update_pivot(control)
    var key := _tween_key(control, "float")
    _stop_tween_key(key)
    var tween := control.create_tween().set_loops()
    active_tweens[key] = tween
    tween.tween_property(control, "rotation", amplitude, period * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    tween.tween_property(control, "rotation", -amplitude, period * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    return tween

# Horizontal error shake with decaying amplitude.
func shake(control: Control, strength: float = 10.0) -> void:
    if control == null or not is_instance_valid(control) or reduced_motion:
        return
    var rest: Vector2 = control.get_meta("aether_shake_rest", control.position)
    control.set_meta("aether_shake_rest", rest)
    var key := _tween_key(control, "shake")
    _stop_tween_key(key)
    var tween := control.create_tween()
    active_tweens[key] = tween
    for i in range(6):
        var amount := strength * (1.0 - float(i) / 6.0) * (1.0 if i % 2 == 0 else -1.0)
        tween.tween_property(control, "position", rest + Vector2(amount, 0), 0.045).set_trans(Tween.TRANS_SINE)
    tween.tween_property(control, "position", rest, 0.05)
    tween.tween_callback(func():
        if is_instance_valid(control):
            control.remove_meta("aether_shake_rest")
        _finish_tween_key(key)
    )

func set_visible(control: Control, show: bool) -> void:
    if control == null or not is_instance_valid(control):
        return
    _update_pivot(control)
    if show:
        control.visible = true
        if control.modulate.a >= 0.99:
            control.modulate.a = 0.0
            control.scale = REST_SCALE if reduced_motion else Vector2(0.97, 0.94)
    if not reduced_motion:
        spring_property(control, "scale", REST_SCALE if show else Vector2(0.97, 0.94), 0.32 if show else 0.22, 0.62 if show else 1.0)
    var control_ref: WeakRef = weakref(control)
    _fade(control, 1.0 if show else 0.0, 0.22 if show else 0.14, "visibility", func():
        var current_control: Variant = control_ref.get_ref()
        if not show and current_control != null and is_instance_valid(current_control):
            current_control.visible = false
            current_control.modulate.a = 1.0
            current_control.scale = REST_SCALE
    )

func _after(control: Control, delay: float, callback: Callable) -> void:
    if delay <= 0.0 or not control.is_inside_tree():
        callback.call(control)
        return
    var ref: WeakRef = weakref(control)
    control.get_tree().create_timer(delay).timeout.connect(
        func():
            var current: Variant = ref.get_ref()
            if current != null and is_instance_valid(current):
                callback.call(current),
        CONNECT_ONE_SHOT
    )

func _press_in(control: Control) -> void:
    if reduced_motion:
        return
    var target: Vector2 = control.get_meta("aether_press_scale", PRESS_SCALE)
    _animate_scale(control, target, PRESS_RESPONSE)

func _press_out(control: Control) -> void:
    if reduced_motion:
        control.scale = REST_SCALE
        return
    var damping := float(control.get_meta("aether_release_damping", 1.0))
    _animate_scale(control, REST_SCALE, RELEASE_RESPONSE, damping)

func _set_lift_hover(control: Control, highlight: CanvasItem, active: bool, rest_alpha: float, hover_alpha: float) -> void:
    if control == null or not is_instance_valid(control):
        return
    control.set_meta("aether_hovered", active)
    _animate_scale(control, HOVER_SCALE if active else REST_SCALE, HOVER_RESPONSE, 0.68 if active else 0.9)
    if highlight == null or not is_instance_valid(highlight):
        return
    if reduced_motion:
        highlight.modulate.a = hover_alpha if active else rest_alpha
        return
    _fade(highlight, hover_alpha if active else rest_alpha, 0.18, "hover")

func _animate_scale(control: Control, target: Vector2, response: float, damping: float = 1.0) -> void:
    if control == null or not is_instance_valid(control):
        return
    _update_pivot(control)
    spring_property(control, "scale", target, response, damping)

func _fade(item: CanvasItem, target: float, duration: float, channel: String, finished: Callable = Callable()) -> void:
    if item == null or not is_instance_valid(item):
        if finished.is_valid():
            finished.call()
        return
    var key := _tween_key(item, channel)
    _stop_tween_key(key)
    var tween := item.create_tween()
    active_tweens[key] = tween
    tween.tween_property(item, "modulate:a", target, duration).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    tween.tween_callback(func():
        active_tweens.erase(key)
        if finished.is_valid():
            finished.call()
    )

func _update_pivot(control: Control) -> void:
    if control != null and is_instance_valid(control):
        control.pivot_offset = control.size * 0.5

func _stop_tweens(owner: Object) -> void:
    if owner == null or not is_instance_valid(owner):
        return
    var prefix := "%d:" % owner.get_instance_id()
    for key_variant in active_tweens.keys():
        var key := String(key_variant)
        if key.begins_with(prefix):
            _stop_tween_key(key)

func _stop_tween_key(key: String) -> void:
    var tween = active_tweens.get(key)
    if tween is Tween and tween.is_valid():
        tween.kill()
    active_tweens.erase(key)

func _finish_tween_key(key: String) -> void:
    active_tweens.erase(key)

func _finish_tween(owner: Object, channel: String) -> void:
    if owner != null and is_instance_valid(owner):
        active_tweens.erase(_tween_key(owner, channel))

func _motion_key(owner: Object, property: StringName) -> String:
    return "%d:%s" % [owner.get_instance_id(), String(property)]

func _tween_key(owner: Object, channel: String) -> String:
    return "%d:%s" % [owner.get_instance_id(), channel]

func _zero_like(value):
    if value is Vector2:
        return Vector2.ZERO
    if value is Color:
        return Color(0, 0, 0, 0)
    return 0.0

func _value_length(value) -> float:
    if value is Vector2:
        return value.length()
    if value is Color:
        return Vector4(value.r, value.g, value.b, value.a).length()
    return absf(float(value))
