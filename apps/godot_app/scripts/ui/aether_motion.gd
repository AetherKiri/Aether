extends Node

# Lumen motion engine. A fixed-step spring integrator drives interactive
# properties (scale, position, size, rotation, colour, floats) and preserves
# velocity across retargets so interrupted gestures never snap. Tween
# choreography on top handles page changes, sheets, cascades and counters.

const PRESS_SCALE := Vector2(0.955, 0.955)
const TACTILE_PRESS_SCALE := Vector2(0.94, 0.94)
const REST_SCALE := Vector2.ONE
const PRESS_RESPONSE := 0.09
const RELEASE_RESPONSE := 0.28
const HOVER_RESPONSE := 0.24
const SPRING_STEP := 1.0 / 120.0
const ROUTE_EXIT_DURATION := 0.18
const ROUTE_ENTER_DURATION := 0.46
const ROUTE_ENTER_DELAY := 0.05
const ROUTE_LIFT := 40.0
const HERO_DURATION := 0.50
const HERO_MIN_ARC := 24.0
const HERO_MAX_ARC := 96.0
const CASCADE_OFFSET := 26.0

var reduced_motion := false
# Touch platforms have no hover: hover-driven effects run on press instead.
var touch_input := false
var active_tweens: Dictionary = {}
var active_springs: Dictionary = {}

func _init() -> void:
    var value := OS.get_environment("AETHERKIRI_REDUCED_MOTION").strip_edges().to_lower()
    reduced_motion = value in ["1", "true", "yes", "on"]
    var touch_env := OS.get_environment("AETHERKIRI_TOUCH_UI").strip_edges().to_lower()
    touch_input = OS.get_name() in ["iOS", "Android"] or touch_env in ["1", "true", "yes", "on"]
    set_process(false)

# ---------------------------------------------------------------------------
# Spring core
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
    if active_springs.is_empty():
        set_process(false)
        return
    var clamped := minf(delta, 1.0 / 30.0)
    var steps := maxi(1, ceili(clamped / SPRING_STEP))
    var step_delta := clamped / float(steps)
    var completed: Array[String] = []
    var callbacks: Array[Callable] = []
    for key_variant in active_springs.keys():
        var key := String(key_variant)
        var state: Dictionary = active_springs[key]
        # Untyped until validated: assigning a freed Object to a typed local
        # raises before is_instance_valid can run.
        var owner = state.get("owner")
        if owner == null or not is_instance_valid(owner):
            completed.append(key)
            continue
        var property: NodePath = state["property"]
        var current = owner.get_indexed(property)
        var target = state["target"]
        var velocity = state["velocity"]
        var omega := TAU / maxf(0.06, float(state["response"]))
        var stiffness := omega * omega
        var damping := 2.0 * float(state["damping"]) * omega
        for _i in range(steps):
            velocity += ((target - current) * stiffness - velocity * damping) * step_delta
            current += velocity * step_delta
        owner.set_indexed(property, current)
        state["velocity"] = velocity
        var epsilon: float = state["epsilon"]
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

# Stretch along one axis, then wobble back to rest.
func jelly(control: Control, stretch: Vector2, settle_response: float = 0.30, settle_damping: float = 0.50) -> void:
    if control == null or not is_instance_valid(control) or reduced_motion:
        return
    _update_pivot(control)
    spring_property(control, "scale", stretch, 0.11, 0.75)
    _after(control, 0.08, func(current: Control):
        spring_property(current, "scale", REST_SCALE, settle_response, settle_damping)
    )

# ---------------------------------------------------------------------------
# Interaction bindings
# ---------------------------------------------------------------------------

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

# Pointer hover grows the control a touch; release returns to the hovered
# size instead of rest so the press → hover chain stays continuous.
func bind_hover_lift(control: Control, hover_scale: float = 1.02) -> void:
    if control == null or control.has_meta("aether_hover_lift"):
        return
    control.set_meta("aether_hover_lift", hover_scale)
    if touch_input:
        # No pointer to hover with: the release blooms past the hover size.
        return
    control.mouse_entered.connect(func():
        control.set_meta("aether_hovered", true)
        if control is BaseButton and (control as BaseButton).disabled:
            return
        _animate_scale(control, Vector2.ONE * hover_scale, HOVER_RESPONSE, 0.62)
    )
    control.mouse_exited.connect(func():
        control.set_meta("aether_hovered", false)
        _animate_scale(control, REST_SCALE, HOVER_RESPONSE, 0.9)
    )

# Hover state that also works on touch: the finger acts as the pointer while
# it is down, and the state lingers briefly after lift so the effect reads.
func bind_hover(control: Control, callback: Callable, linger: float = 0.22) -> void:
    if control == null or not callback.is_valid():
        return
    if not touch_input:
        control.mouse_entered.connect(func(): callback.call(true))
        control.mouse_exited.connect(func(): callback.call(false))
        return
    var serial := [0]
    var press := func(active: bool):
        serial[0] += 1
        if active:
            # A short hold before lighting up keeps scroll swipes from
            # flashing every card the finger passes over.
            var armed: int = serial[0]
            _after(control, 0.08, func(_current: Control):
                if serial[0] == armed:
                    callback.call(true)
            )
            return
        var token: int = serial[0]
        _after(control, linger, func(_current: Control):
            if serial[0] == token:
                callback.call(false)
        )
    if control is BaseButton:
        (control as BaseButton).button_down.connect(func(): press.call(true))
        (control as BaseButton).button_up.connect(func(): press.call(false))
    else:
        control.gui_input.connect(func(event: InputEvent):
            if event is InputEventScreenTouch:
                press.call(event.pressed)
            elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
                press.call(event.pressed)
        )
    control.mouse_exited.connect(func(): press.call(false))
    control.set_meta("aether_hover_cancel", func():
        serial[0] += 1
        callback.call(false)
    )
    control.visibility_changed.connect(func():
        if not control.is_visible_in_tree():
            serial[0] += 1
            callback.call(false)
    )

func cancel_press(control: Control) -> void:
    if control == null or not is_instance_valid(control):
        return
    var cancel_hover: Variant = control.get_meta("aether_hover_cancel") if control.has_meta("aether_hover_cancel") else null
    if cancel_hover is Callable and (cancel_hover as Callable).is_valid():
        (cancel_hover as Callable).call()
    active_springs.erase(_motion_key(control, "scale"))
    control.scale = REST_SCALE

# Magnetic drift: the control leans a few pixels toward the pointer.
func bind_magnet(control: Control, target: CanvasItem, strength: float = 6.0) -> void:
    if control == null or target == null or control.has_meta("aether_magnet"):
        return
    control.set_meta("aether_magnet", true)
    control.gui_input.connect(func(event: InputEvent):
        if reduced_motion or control.size.x <= 0.0:
            return
        if event is InputEventScreenTouch and not event.pressed:
            spring_property(target, "position", Vector2.ZERO, 0.45, 0.6)
            return
        var tracked: bool = event is InputEventMouseMotion or event is InputEventScreenDrag
        tracked = tracked or (event is InputEventScreenTouch and event.pressed)
        if not tracked:
            return
        var n: Vector2 = (event.position / control.size) * 2.0 - Vector2.ONE
        spring_property(target, "position", n.clamp(-Vector2.ONE, Vector2.ONE) * strength, 0.34, 0.8)
    )
    control.mouse_exited.connect(func(): spring_property(target, "position", Vector2.ZERO, 0.45, 0.6))

# ---------------------------------------------------------------------------
# Page choreography
# ---------------------------------------------------------------------------

func enter(control: Control, offset: Vector2 = Vector2(0, 18), delay: float = 0.0) -> void:
    if control == null or not is_instance_valid(control):
        return
    _stop_tweens(control)
    var rest := control.position
    control.modulate.a = 0.0
    if not reduced_motion:
        control.position = rest + offset
    var key := _tween_key(control, "enter")
    var tween := control.create_tween().set_parallel(true)
    active_tweens[key] = tween
    var duration := 0.12 if reduced_motion else 0.42
    tween.tween_property(control, "modulate:a", 1.0, duration * 0.7).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
    if not reduced_motion:
        tween.tween_property(control, "position", rest, duration).set_delay(delay).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
    tween.chain().tween_callback(func(): _finish_tween_key(key))

func route_in(control: Control, direction: float = 1.0) -> void:
    enter(control, Vector2(0.0, 16.0 * (1.0 if direction >= 0.0 else -1.0)))

# Page change: the outgoing page sinks back and fades while the incoming page
# rises into place from below, slightly zoomed out. They overlap so the
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
    var has_outgoing := outgoing != null and is_instance_valid(outgoing) and outgoing != incoming
    if has_outgoing:
        _stop_tweens(outgoing)
        active_springs.erase(_motion_key(outgoing, "scale"))
    var incoming_rest: Vector2 = incoming.get_meta("aether_route_rest_position", incoming.position)
    incoming.set_meta("aether_route_rest_position", incoming_rest)
    incoming.visible = true
    incoming.modulate.a = 0.0
    _update_pivot(incoming)
    var geometry := lift and not reduced_motion
    var enter_offset := Vector2(64.0 * direction, 0.0) if horizontal else Vector2(0.0, ROUTE_LIFT)
    var exit_offset := Vector2(-48.0 * direction, 0.0) if horizontal else Vector2(0.0, -12.0)
    incoming.position = incoming_rest + enter_offset if geometry else incoming_rest
    incoming.scale = Vector2(0.985, 0.985) if geometry else REST_SCALE
    var outgoing_rest := Vector2.ZERO
    if has_outgoing:
        outgoing_rest = outgoing.get_meta("aether_route_rest_position", outgoing.position)
        outgoing.set_meta("aether_route_rest_position", outgoing_rest)
        outgoing.visible = true
        _update_pivot(outgoing)
    var incoming_ref: WeakRef = weakref(incoming)
    var outgoing_ref: Variant = weakref(outgoing) if has_outgoing else null
    var incoming_key := _tween_key(incoming, "route")
    var outgoing_key := _tween_key(outgoing, "route") if has_outgoing else ""
    var tween := incoming.create_tween().set_parallel(true)
    active_tweens[incoming_key] = tween
    if has_outgoing:
        active_tweens[outgoing_key] = tween
        tween.tween_property(outgoing, "modulate:a", 0.0, ROUTE_EXIT_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
        if geometry:
            tween.tween_property(outgoing, "position", outgoing_rest + exit_offset, ROUTE_EXIT_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
            tween.tween_property(outgoing, "scale", Vector2(0.97, 0.97), ROUTE_EXIT_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
    var duration := 0.14 if reduced_motion else ROUTE_ENTER_DURATION
    var delay := 0.0 if reduced_motion else ROUTE_ENTER_DELAY
    tween.tween_property(incoming, "modulate:a", 1.0, duration * 0.6).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
    if geometry:
        tween.tween_property(incoming, "position", incoming_rest, duration).set_delay(delay).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
        tween.tween_property(incoming, "scale", REST_SCALE, duration).set_delay(delay).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
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

# Shared-element flight along a shallow arc.
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
    var control_ref: WeakRef = weakref(control)
    var key := _tween_key(control, "hero")
    var tween := control.create_tween()
    active_tweens[key] = tween
    tween.tween_method(
        func(progress: float):
            var current: Variant = control_ref.get_ref()
            if current != null and is_instance_valid(current):
                var frame := hero_arc_rect(start_rect, target_rect, progress)
                current.position = frame.position
                current.size = frame.size,
        0.0,
        1.0,
        HERO_DURATION
    ).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN_OUT)
    tween.tween_callback(func():
        var current: Variant = control_ref.get_ref()
        if current != null and is_instance_valid(current):
            current.position = target_rect.position
            current.size = target_rect.size
        _finish_tween_key(key)
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
    var arc := clampf(distance * 0.16, HERO_MIN_ARC, HERO_MAX_ARC)
    var control := (start_center + target_center) * 0.5
    if absf(delta.x) >= absf(delta.y):
        control.y = minf(start_center.y, target_center.y) - arc
    else:
        control.x = maxf(start_center.x, target_center.x) + arc
    var u := 1.0 - t
    var center := u * u * start_center + 2.0 * u * t * control + t * t * target_center
    var size := start_rect.size.lerp(target_rect.size, t)
    return Rect2(center - size * 0.5, size)

# Sheet entrance: the dialog rises from below on a soft spring while the page
# behind it recedes.
func modal_in(scrim: CanvasItem, dialog: Control, background: Control = null) -> void:
    if scrim == null or dialog == null:
        return
    _stop_tweens(scrim)
    _stop_tweens(dialog)
    scrim.modulate.a = 0.0
    dialog.modulate.a = 0.0
    _update_pivot(dialog)
    var rest := dialog.position
    dialog.set_meta("aether_modal_rest_position", rest)
    if reduced_motion:
        dialog.scale = REST_SCALE
    else:
        dialog.position = rest + Vector2(0, 56)
        dialog.scale = Vector2(0.96, 0.96)
        spring_property(dialog, "position", rest, 0.42, 0.78)
        spring_property(dialog, "scale", REST_SCALE, 0.40, 0.70)
    _fade(scrim, 1.0, 0.26 if not reduced_motion else 0.12, "modal")
    _fade(dialog, 1.0, 0.20 if not reduced_motion else 0.12, "modal")
    if background != null and is_instance_valid(background):
        _update_pivot(background)
        spring_property(background, "scale", Vector2(0.965, 0.965), 0.46, 1.0)

func modal_out(scrim: CanvasItem, dialog: Control, background: Control = null, finished: Callable = Callable()) -> void:
    if scrim == null or dialog == null:
        if finished.is_valid():
            finished.call()
        return
    var rest: Vector2 = dialog.get_meta("aether_modal_rest_position", dialog.position)
    if not reduced_motion:
        spring_property(dialog, "position", rest + Vector2(0, 32), 0.24, 1.0)
        spring_property(dialog, "scale", Vector2(0.97, 0.97), 0.24, 1.0)
    _fade(scrim, 0.0, 0.18 if not reduced_motion else 0.10, "modal")
    _fade(dialog, 0.0, 0.16 if not reduced_motion else 0.10, "modal", finished)
    if background != null and is_instance_valid(background):
        spring_property(background, "scale", REST_SCALE, 0.38, 0.9)

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
        card.scale = Vector2(0.92, 0.92)
        spring_property(card, "scale", REST_SCALE, 0.40, 0.66)
    _fade(panel, 1.0, 0.22 if not reduced_motion else 0.12, "loading")

func loading_out(panel: Control, card: Control, finished: Callable = Callable()) -> void:
    if panel == null or not is_instance_valid(panel):
        if finished.is_valid():
            finished.call()
        return
    if card != null and is_instance_valid(card) and not reduced_motion:
        spring_property(card, "scale", Vector2(0.96, 0.96), 0.22, 1.0)
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

# ---------------------------------------------------------------------------
# Content reveals
# ---------------------------------------------------------------------------

func reveal(control: Control, delay: float = 0.0) -> void:
    if control == null or not is_instance_valid(control):
        return
    _stop_tweens(control)
    control.modulate.a = 0.0
    var key := _tween_key(control, "reveal")
    var tween := control.create_tween()
    active_tweens[key] = tween
    tween.tween_property(control, "modulate:a", 1.0, 0.12 if reduced_motion else 0.32).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
    tween.tween_callback(func(): _finish_tween_key(key))

# Cascade step for container children. Containers own `position`, so the
# rise is carried by a child-local transform: a vertical squash from the
# bottom edge plus a fade, both properties layout never overwrites.
func rise(control: Control, delay: float = 0.0) -> void:
    if control == null or not is_instance_valid(control):
        return
    _stop_tweens(control)
    active_springs.erase(_motion_key(control, "scale"))
    control.modulate.a = 0.0
    if reduced_motion:
        control.scale = REST_SCALE
        _fade(control, 1.0, 0.12, "reveal")
        return
    control.pivot_offset = Vector2(control.size.x * 0.5, control.size.y + CASCADE_OFFSET)
    control.scale = Vector2(0.94, 0.94)
    var key := _tween_key(control, "reveal")
    var tween := control.create_tween()
    active_tweens[key] = tween
    tween.tween_property(control, "modulate:a", 1.0, 0.30).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
    tween.tween_callback(func(): _finish_tween_key(key))
    _after(control, delay, func(current: Control):
        spring_property(current, "scale", REST_SCALE, 0.46, 0.72, func():
            if is_instance_valid(current):
                _update_pivot(current)
        )
    )

func cascade_children(parent: Node, step: float = 0.04, base_delay: float = 0.0, max_items: int = 16) -> void:
    if parent == null or not is_instance_valid(parent):
        return
    var index := 0
    for child in parent.get_children():
        if index >= max_items:
            break
        if child is Control and is_instance_valid(child) and not child.is_queued_for_deletion() and child.visible:
            rise(child, base_delay + step * float(index))
            index += 1

# Grid cascade that ripples diagonally from the top-left cell.
func cascade_grid(grid: GridContainer, step: float = 0.045, max_items: int = 30) -> void:
    if grid == null or not is_instance_valid(grid):
        return
    var columns := maxi(1, grid.columns)
    var index := 0
    for child in grid.get_children():
        if not child is Control or child.is_queued_for_deletion():
            continue
        if index < max_items:
            var wave := float(index / columns) + float(index % columns) * 0.7
            rise(child, 0.02 + wave * step)
        index += 1

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
    tween.tween_property(control, "modulate:a", 1.0, 0.16).set_delay(delay)
    _after(control, delay, func(current: Control):
        spring_property(current, "scale", REST_SCALE, 0.38, 0.48)
    )

# Heading reveal: the text wipes in from the left while sliding up a little.
func wipe_in(label: Label, delay: float = 0.0, duration: float = 0.5) -> void:
    if label == null or not is_instance_valid(label):
        return
    if reduced_motion or label.text.length() <= 1:
        label.visible_ratio = 1.0
        return
    label.visible_ratio = 0.0
    var tween := label.create_tween()
    tween.tween_property(label, "visible_ratio", 1.0, duration).set_delay(delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)

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

# Endless opacity pulse for status dots and live indicators.
func pulse(item: CanvasItem, low: float = 0.35, period: float = 2.0) -> Tween:
    if item == null or not is_instance_valid(item) or reduced_motion:
        return null
    var key := _tween_key(item, "pulse")
    _stop_tween_key(key)
    var tween := item.create_tween().set_loops()
    active_tweens[key] = tween
    tween.tween_property(item, "modulate:a", low, period * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    tween.tween_property(item, "modulate:a", 1.0, period * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    return tween

func breathe(control: Control, amount: float = 0.04, period: float = 2.8) -> Tween:
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
            control.scale = REST_SCALE if reduced_motion else Vector2(1.0, 0.94)
    if not reduced_motion:
        spring_property(control, "scale", REST_SCALE if show else Vector2(1.0, 0.94), 0.30 if show else 0.20, 0.7 if show else 1.0)
    var control_ref: WeakRef = weakref(control)
    _fade(control, 1.0 if show else 0.0, 0.22 if show else 0.14, "visibility", func():
        var current: Variant = control_ref.get_ref()
        if not show and current != null and is_instance_valid(current):
            current.visible = false
            current.modulate.a = 1.0
            current.scale = REST_SCALE
    )

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

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
    _animate_scale(control, control.get_meta("aether_press_scale", PRESS_SCALE), PRESS_RESPONSE)

func _press_out(control: Control) -> void:
    if reduced_motion:
        control.scale = REST_SCALE
        return
    var hovered := bool(control.get_meta("aether_hovered", false))
    var rest := Vector2.ONE * float(control.get_meta("aether_hover_lift", 1.0)) if hovered else REST_SCALE
    if touch_input and control.has_meta("aether_hover_lift"):
        var bloom := Vector2.ONE * (1.0 + (float(control.get_meta("aether_hover_lift")) - 1.0) * 2.0)
        _animate_scale(control, bloom, 0.12, 0.7)
        _after(control, 0.1, func(current: Control):
            _animate_scale(current, REST_SCALE, RELEASE_RESPONSE, float(current.get_meta("aether_release_damping", 1.0)))
        )
        return
    _animate_scale(control, rest, RELEASE_RESPONSE, float(control.get_meta("aether_release_damping", 1.0)))

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
    tween.tween_property(item, "modulate:a", target, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
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
