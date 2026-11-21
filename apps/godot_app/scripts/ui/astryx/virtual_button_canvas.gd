extends Control
## Edits only the profile draft. No game input is generated on this canvas.
signal picked(id: String)
signal adjusted(id: String, patch: Dictionary)
signal direction_mode_changed

const Layouts := preload("res://scripts/virtual_button_layout.gd")
const IDLE := -3
const MOUSE := -2
const HANDLE_SIZE := 32
const RuntimeControls := preload("res://scripts/game_virtual_controls.gd")
var preview: RuntimeControls
var mode_button: Button
var resize_visual: Panel

var design
var profile: Dictionary
var selected := ""
var default_opacity := 1.0
var contact := IDLE
var resizing := false
var start := Vector2.ZERO
var original := Rect2()
var base_diameter := 0.0


func setup(preview_parent: Control, tokens, opacity: float) -> void:
    preview = RuntimeControls.new()
    add_child(preview)
    preview.setup(tokens, preview_parent)
    preview.set_keyboard_controls_opacity(opacity)
    preview.set_enabled(true)
    preview.show_virtual_controls()
    preview.set_process(false)
    default_opacity = opacity
    clip_contents = true
    mouse_filter = Control.MOUSE_FILTER_STOP
    var handle_style: StyleBoxFlat = design.box("focus", 9, "", 2)
    handle_style.border_color = Color.WHITE
    handle_style.set_border_width_all(2)
    resize_visual = Panel.new()
    resize_visual.name = "PadResizeHandle"
    resize_visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
    resize_visual.add_theme_stylebox_override("panel", handle_style)
    add_child(resize_visual)
    _handle_glyph(resize_visual, false)
    mode_button = Button.new()
    mode_button.name = "PadDirectionMode"
    mode_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    for state in ["normal", "hover", "pressed"]:
        mode_button.add_theme_stylebox_override(state, handle_style)
    mode_button.add_theme_stylebox_override("focus", design.focus_box(9))
    mode_button.pressed.connect(func(): direction_mode_changed.emit())
    add_child(mode_button)
    _handle_glyph(mode_button, true)
    resized.connect(
        func():
            contact = IDLE
            refresh(false)
    )


func _handle_glyph(parent: Control, mode: bool) -> void:
    var ink := Control.new()
    ink.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parent.add_child(ink)
    ink.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    ink.draw.connect(
        func():
            var center := ink.size * 0.5
            if mode:
                for sign_value: int in [-1, 1]:
                    var end := center + Vector2(7, -4) * sign_value
                    ink.draw_line(end - Vector2(14, 0) * sign_value, end, Color.WHITE, 2, true)
                    ink.draw_polyline(
                        PackedVector2Array([end - Vector2(4, 4) * sign_value, end, end - Vector2(4, -4) * sign_value]),
                        Color.WHITE,
                        2,
                        true
                    )
            else:
                ink.draw_line(center - Vector2.ONE * 6, center + Vector2.ONE * 6, Color.WHITE, 2, true)
                for sign_value: int in [-1, 1]:
                    var end := center + Vector2.ONE * 6 * sign_value
                    ink.draw_polyline(
                        PackedVector2Array([end - Vector2(5, 0) * sign_value, end, end - Vector2(0, 5) * sign_value]),
                        Color.WHITE,
                        2,
                        true
                    )
    )


func refresh(rebind: bool) -> void:
    if preview == null or profile.is_empty() or not size.x or not size.y:
        return
    if rebind:
        preview.set_layout_profile(profile)
    preview.layout(size, Rect2(Vector2.ZERO, size), profile)
    var selection := rect_for(selected)
    resize_visual.visible = selection.has_area()
    mode_button.visible = selected == "pad" and selection.has_area()
    if selection.has_area():
        var grip := _grip(selection)
        resize_visual.position = grip.position
        resize_visual.size = grip.size
        if mode_button.visible:
            var center := Vector2(
                grip.get_center().x, clampf(selection.position.y - 8, HANDLE_SIZE * 0.5, size.y - HANDLE_SIZE * 0.5)
            )
            mode_button.position = center - grip.size * 0.5
            mode_button.size = grip.size
    queue_redraw()


func rect_for(id: String) -> Rect2:
    if id == "pad" and preview != null:
        return preview.dpad_backdrop.get_rect()
    var cap: Button = preview._caps.get(id) if preview != null else null
    return cap.get_rect() if cap != null and cap.visible else Rect2()


func _grip(rect: Rect2) -> Rect2:
    var half := Vector2.ONE * HANDLE_SIZE * 0.5
    var center := (rect.end + Vector2(8, 8)).clamp(half, size - half)
    if Rect2(center - half, 2 * half).grow(2).has_point(rect.get_center()):
        center.y = maxf(half.y, rect.position.y - 8)
    return Rect2(center - half, 2 * half)


func _draw() -> void:
    var rect := rect_for(selected)
    if rect.has_area():
        draw_arc(rect.get_center(), rect.size.x * 0.5 + 2, 0, TAU, 96, design.color("focus"), 3, true)


func _begin(index: int, point: Vector2) -> void:
    if contact != IDLE:
        return
    var previous := rect_for(selected)
    resizing = previous.has_area() and _grip(previous).has_point(point)
    var hit := selected if resizing else ""
    if not resizing:
        if previous.has_area() and point.distance_to(previous.get_center()) <= previous.size.x * 0.5:
            hit = selected
        else:
            for i in range(profile.buttons.size() - 1, -1, -1):
                var cap: Dictionary = profile.buttons[i]
                var rect := rect_for(cap.id)
                if point.distance_to(rect.get_center()) <= rect.size.x * 0.5:
                    hit = cap.id
                    break
    selected = hit
    if not hit.is_empty():
        contact = index
        start = point
        original = rect_for(hit)
        base_diameter = Layouts.button_rect({"id": hit}, size, Layouts.mouse_geometry(size)).size.x
    picked.emit(hit)
    queue_redraw()


func _move(point: Vector2) -> void:
    var delta := point - start
    if delta.length() < 3:
        return
    var d := original.size.x
    var center := original.get_center() + delta
    var patch := {}
    if resizing:
        var factor := clampf((d + (delta.x + delta.y) * 0.5) / base_diameter, Layouts.MIN_SCALE, Layouts.MAX_SCALE)
        d = minf(minf(size.x, size.y), base_diameter * factor)
        center = original.position + Vector2.ONE * d * 0.5
        patch.scale = factor
    var half := Vector2.ONE * d * 0.5
    center = center.clamp(half, size - half) / size
    patch.x = center.x
    patch.y = center.y
    adjusted.emit(selected, patch)


func _gui_input(event: InputEvent) -> void:
    if event is InputEventMouse and event.device == -1:
        return
    if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
        var index := int(event.index) if event is InputEventScreenTouch else MOUSE
        if event.pressed and not event.canceled:
            _begin(index, event.position)
        elif index == contact:
            contact = IDLE
        accept_event()
    elif (event is InputEventScreenDrag and event.index == contact) or (event is InputEventMouseMotion and contact == MOUSE):
        _move(event.position)
        accept_event()
