extends CanvasLayer

signal key_event_requested(pressed: bool, key_code: int, modifiers: int)
signal pointer_move_requested(screen_position: Vector2, screen_delta: Vector2)
signal pointer_button_requested(
    pressed: bool,
    button: int,
    modifiers: int,
    screen_position: Vector2
)
signal pointer_scroll_requested(delta_y: float, screen_position: Vector2)
signal keyboard_requested
signal virtual_controls_requested
signal input_mode_changed(mode: String)
signal menu_open_changed(open: bool)

const VK_RETURN := 0x0D
const VK_CONTROL := 0x11
const VK_ESCAPE := 0x1B
const VK_SPACE := 0x20
const VK_1 := 0x31
const VK_2 := 0x32
const VK_3 := 0x33
const VK_4 := 0x34
const VK_A := 0x41
const VK_D := 0x44
const VK_S := 0x53
const VK_W := 0x57
const MOD_CONTROL := 0x04
const POINTER_MOD_RIGHT := 0x10
const OVERLAY_LAYER := 120
const AetherOrb = preload("res://scripts/ui/aether_orb.gd")
const AetherGlass = preload("res://scripts/ui/aether_glass.gd")
const BUTTON_MIN_SIZE := 44.0
const BUTTON_MAX_SIZE := 68.0
const MENU_BUTTON_SIZE := Vector2(52.0, 52.0)
const MENU_EDGE_INSET := 6.0
const CURSOR_SIZE := 44.0
const CURSOR_HOTSPOT := Vector2(15.0, 10.0)
const CURSOR_TAP_DRAG_THRESHOLD := 10.0
const CURSOR_TWO_FINGER_TAP_WINDOW_MSEC := 220
const MENU_DRAG_THRESHOLD := 6.0
const SCROLL_HOLD_DELAY_MSEC := 360
const SCROLL_HOLD_REPEAT_MSEC := 90
const SCROLL_HOLD_MAX_CATCH_UP_STEPS := 4
const DPAD_DEAD_ZONE_RATIO := 0.18
const DPAD_DIRECTION_AXIS_THRESHOLD := 0.382683
const INPUT_DEVICE_ID_EMULATION := -1
const INPUT_MODE_MOUSE := "mouse"
const INPUT_MODE_TOUCH := "touch"
const INPUT_MODES := [INPUT_MODE_MOUSE, INPUT_MODE_TOUCH]
const KEYBOARD_CONTROLS_OPACITY_MIN := 0.2
const KEYBOARD_CONTROLS_OPACITY_MAX := 1.0

const REFERENCE_FILL := Color(0.30, 0.31, 0.33, 0.58)
const REFERENCE_FILL_HOVER := Color(0.36, 0.37, 0.39, 0.72)
const REFERENCE_BORDER := Color(0.82, 0.84, 0.88, 0.72)
const REFERENCE_TEXT := Color(0.94, 0.95, 0.97, 0.84)
const COMPUTER_USE_CURSOR_FILL := Color(0.08, 0.12, 0.15, 0.82)
const COMPUTER_USE_CURSOR_OUTLINE := Color(0.68, 0.78, 0.84, 0.96)

var menu_button: Button
var keyboard_button: Button
var virtual_controls_button: Button
var input_mode_button: Button
var escape_button: Button
var control_button: Button
var w_button: Button
var a_button: Button
var s_button: Button
var d_button: Button
var digit_buttons: Array[Button] = []
var enter_button: Button
var space_button: Button
var mouse_left_button: Button
var mouse_right_button: Button
var scroll_up_button: Button
var scroll_down_button: Button
var cursor_handle: Control
var dpad_backdrop: Panel
var dpad_center: Panel

var _root: Control
var _tokens
var _enabled := false
var _menu_button_enabled := true
var _keyboard_controls_opacity := 1.0
var _panel_open := false
var _panel_shown := false
var _pad_frame: Panel
var _orb: Control
var _dpad_knob_target := Vector2.ZERO
var _menu_open := false
var _menu_visible := false
var _safe_rect := Rect2()
var _held_keys := {}
var _held_mouse_buttons := {}
var _panel_controls: Array[Control] = []
var _interactive_controls: Array[Control] = []
var _cursor_touch_index := -1
var _cursor_mouse_dragging := false
var _cursor_initialized := false
var _cursor_drag_has_position := false
var _cursor_drag_last_screen_position := Vector2.ZERO
var _cursor_touch_start_screen_position := Vector2.ZERO
var _cursor_touch_down_msec := 0
var _cursor_touch_tap_candidate := false
var _cursor_touch_released := false
var _cursor_secondary_touch_index := -1
var _cursor_secondary_touch_start_screen_position := Vector2.ZERO
var _cursor_secondary_touch_released := false
var _cursor_two_finger_tap_candidate := false
var _menu_touch_index := -1
var _menu_mouse_dragging := false
var _menu_drag_start_pointer_y := 0.0
var _menu_drag_grab_offset_y := 0.0
var _menu_drag_moved := false
var _menu_y_ratio := 0.0
var _input_mode := INPUT_MODE_MOUSE
var _mouse_mode_blocked_touch_indices := {}
var _held_scroll_direction := 0.0
var _scroll_next_repeat_msec := 0
var _dpad_touch_index := -1
var _dpad_mouse_dragging := false
var _dpad_home_position := Vector2.ZERO
var _dpad_travel_radius := 0.0
var _dpad_vector := Vector2.ZERO
var _dpad_held_keys := {}

func setup(tokens) -> void:
    if _root != null:
        return
    name = "GameVirtualControls"
    layer = OVERLAY_LAYER
    _tokens = tokens

    _root = Control.new()
    _root.name = "Root"
    _root.set_anchors_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    _pad_frame = _create_pad_frame()
    _root.add_child(_pad_frame)

    menu_button = _create_action_button("MenuButton", "Menu")
    keyboard_button = _create_action_button("KeyboardButton", "Keyboard")
    virtual_controls_button = _create_action_button(
        "VirtualControlsButton", "Control Pad"
    )
    menu_button.pressed.connect(_toggle_menu)
    keyboard_button.pressed.connect(_request_keyboard)
    virtual_controls_button.pressed.connect(show_virtual_controls)
    _root.add_child(menu_button)
    _root.add_child(keyboard_button)
    _root.add_child(virtual_controls_button)

    _apply_edge_menu_style(menu_button)
    _attach_edge_menu_icon(menu_button)
    _apply_menu_option_style(keyboard_button)
    _apply_menu_option_style(virtual_controls_button)

    input_mode_button = _create_action_button("InputModeButton", "")
    input_mode_button.pressed.connect(_toggle_input_mode)
    _root.add_child(input_mode_button)
    _panel_controls.append(input_mode_button)
    _interactive_controls.append(input_mode_button)
    _apply_input_mode_style(input_mode_button)
    _sync_input_mode_presentation()

    dpad_backdrop = _create_decorative_panel(
        "DpadBackdrop",
        _dpad_backdrop_style()
    )
    dpad_backdrop.z_index = -2
    _attach_dpad_decoration(dpad_backdrop)
    _root.add_child(dpad_backdrop)
    _panel_controls.append(dpad_backdrop)

    dpad_center = _create_decorative_panel(
        "DpadCenter",
        _dpad_knob_style()
    )
    dpad_center.z_index = -1
    var knob_glass = _attach_glass(dpad_center)
    knob_glass.tint = Color(0.16, 0.17, 0.21, 0.42)
    knob_glass.selected_amount = 0.38
    _root.add_child(dpad_center)
    _panel_controls.append(dpad_center)

    escape_button = _add_key_button("EscapeButton", "Esc", VK_ESCAPE)
    control_button = _add_key_button("ControlButton", "Ctrl", VK_CONTROL)
    w_button = _add_key_button("WButton", "W", VK_W)
    a_button = _add_key_button("AButton", "A", VK_A)
    s_button = _add_key_button("SButton", "S", VK_S)
    d_button = _add_key_button("DButton", "D", VK_D)
    for direction_button in [w_button, a_button, s_button, d_button]:
        _apply_dpad_button_style(direction_button)
        # The whole disc is an eight-way joystick. Direction labels are only
        # visual targets; letting their individual Buttons handle input would
        # prevent a drag from holding two keys on a diagonal.
        direction_button.toggle_mode = true
        direction_button.set_pressed_no_signal(false)
        direction_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
        _interactive_controls.erase(direction_button)
    for index in range(4):
        var digit := _add_key_button(
            "Digit%dButton" % (index + 1),
            str(index + 1),
            VK_1 + index
        )
        digit_buttons.append(digit)
    enter_button = _add_key_button("EnterButton", "Enter", VK_RETURN, true)
    space_button = _add_key_button("SpaceButton", "Space", VK_SPACE, true)

    mouse_left_button = _add_mouse_button("MouseLeftButton", "", 0, 0)
    mouse_right_button = _add_mouse_button(
        "MouseRightButton", "", 1, POINTER_MOD_RIGHT
    )
    _attach_mouse_icon(mouse_left_button, true)
    _attach_mouse_icon(mouse_right_button, false)

    scroll_up_button = _add_scroll_button("ScrollUpButton", "▲", 1.0)
    scroll_down_button = _add_scroll_button("ScrollDownButton", "▼", -1.0)
    scroll_up_button.tooltip_text = "Scroll up (hold to repeat)"
    scroll_down_button.tooltip_text = "Scroll down (hold to repeat)"

    cursor_handle = Control.new()
    cursor_handle.name = "MouseCursor"
    cursor_handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _attach_pointer_visual(cursor_handle)
    _root.add_child(cursor_handle)
    _panel_controls.append(cursor_handle)

    _interactive_controls.append(menu_button)
    _interactive_controls.append(keyboard_button)
    _interactive_controls.append(virtual_controls_button)
    _apply_keyboard_controls_opacity()
    set_enabled(false)

func set_enabled(enabled: bool) -> void:
    if _enabled == enabled:
        visible = enabled and _menu_button_enabled
        _sync_visibility()
        return
    _enabled = enabled
    if not enabled:
        release_all()
        _panel_open = false
        _menu_open = false
        _reset_cursor_touch_gesture()
        _cursor_mouse_dragging = false
        _reset_cursor_drag_position()
        _menu_touch_index = -1
        _menu_mouse_dragging = false
        _menu_drag_moved = false
        _dpad_touch_index = -1
        _dpad_mouse_dragging = false
        _mouse_mode_blocked_touch_indices.clear()
    visible = enabled and _menu_button_enabled
    _sync_visibility()

func set_menu_button_enabled(enabled: bool) -> void:
    if _menu_button_enabled == enabled:
        visible = _enabled and enabled
        _sync_visibility()
        return
    _menu_button_enabled = enabled
    if not enabled:
        release_all()
        _panel_open = false
        _menu_open = false
        _reset_cursor_touch_gesture()
        _cursor_mouse_dragging = false
        _reset_cursor_drag_position()
        _mouse_mode_blocked_touch_indices.clear()
        _menu_touch_index = -1
        _menu_mouse_dragging = false
        _menu_drag_moved = false
    visible = _enabled and enabled
    _sync_visibility()

func is_menu_button_enabled() -> bool:
    return _menu_button_enabled

func set_keyboard_controls_opacity(opacity: float) -> void:
    _keyboard_controls_opacity = clampf(
        opacity,
        KEYBOARD_CONTROLS_OPACITY_MIN,
        KEYBOARD_CONTROLS_OPACITY_MAX
    )
    _apply_keyboard_controls_opacity()

func keyboard_controls_opacity() -> float:
    return _keyboard_controls_opacity

func is_panel_open() -> bool:
    return _panel_open

func is_menu_open() -> bool:
    return _menu_open

func input_mode() -> String:
    return _input_mode

func is_touch_mode() -> bool:
    return _input_mode == INPUT_MODE_TOUCH

func set_input_mode(mode: String, notify: bool = false) -> void:
    var normalized := mode if mode in INPUT_MODES else INPUT_MODE_MOUSE
    if _input_mode == normalized:
        _sync_input_mode_presentation()
        _sync_visibility()
        return
    release_all()
    _reset_cursor_touch_gesture()
    _cursor_mouse_dragging = false
    _reset_cursor_drag_position()
    _mouse_mode_blocked_touch_indices.clear()
    _input_mode = normalized
    _sync_input_mode_presentation()
    _sync_visibility()
    if notify:
        input_mode_changed.emit(_input_mode)

func show_virtual_controls() -> void:
    if not _enabled or not _menu_button_enabled:
        return
    _menu_open = false
    _panel_open = true
    _sync_visibility()
    virtual_controls_requested.emit()

func hide_virtual_controls() -> void:
    release_all()
    _menu_open = false
    _panel_open = false
    _sync_visibility()

func set_gamepad_navigation_enabled(enabled: bool) -> void:
    for control in _interactive_controls:
        if control is BaseButton:
            control.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE

func release_all() -> void:
    _cancel_scroll_hold()
    _reset_dpad()
    for key_variant in _held_keys.keys().duplicate():
        _release_key(int(key_variant))
    for mouse_variant in _held_mouse_buttons.keys().duplicate():
        var state: Dictionary = _held_mouse_buttons[mouse_variant]
        _release_mouse_button(
            int(state.get("button", 0)),
            int(state.get("modifiers", 0))
        )

func layout(_window_size: Vector2, safe_rect: Rect2) -> void:
    if _root == null:
        return
    _safe_rect = safe_rect
    var short_edge := minf(safe_rect.size.x, safe_rect.size.y)
    var diameter := clampf(short_edge * 0.13, BUTTON_MIN_SIZE, BUTTON_MAX_SIZE)
    var gap := clampf(diameter * 0.13, 6.0, 9.0)
    var margin := clampf(diameter * 0.2, 9.0, 14.0)
    var safe_end := safe_rect.end
    var key_size := Vector2(diameter, diameter)

    # Keep the edge affordance close to the 40 px standard-button token from
    # DESIGN.md instead of scaling it up with the larger virtual key caps.
    var menu_size := MENU_BUTTON_SIZE
    var menu_y_range := maxf(0.0, safe_rect.size.y - menu_size.y)
    menu_button.position = Vector2(
        safe_end.x - menu_size.x - MENU_EDGE_INSET,
        safe_rect.position.y + menu_y_range * _menu_y_ratio
    )
    menu_button.size = menu_size
    _layout_edge_menu_icon()

    _layout_menu_options(diameter, gap)
    _pad_frame.position = safe_rect.position + Vector2.ONE * 3.0
    _pad_frame.size = safe_rect.size - Vector2.ONE * 6.0

    escape_button.position = safe_rect.position + Vector2(margin, margin)
    escape_button.size = key_size

    var mode_size := Vector2(
        clampf(safe_rect.size.x * 0.22, 132.0, 168.0),
        clampf(diameter * 0.72, 40.0, 48.0)
    )
    input_mode_button.position = Vector2(
        safe_rect.get_center().x - mode_size.x * 0.5,
        safe_rect.position.y + margin
    )
    input_mode_button.size = mode_size

    var dpad_diameter := clampf(short_edge * 0.36, 118.0, 210.0)
    var dpad_origin := Vector2(
        safe_rect.position.x + margin,
        safe_end.y - margin - dpad_diameter
    )
    dpad_backdrop.position = dpad_origin
    dpad_backdrop.size = Vector2.ONE * dpad_diameter

    var dpad_center_position := dpad_origin + Vector2.ONE * dpad_diameter * 0.5
    var direction_size := Vector2.ONE * dpad_diameter * 0.36
    var direction_offset := dpad_diameter * 0.30
    w_button.position = dpad_center_position + Vector2(0, -direction_offset) \
        - direction_size * 0.5
    a_button.position = dpad_center_position + Vector2(-direction_offset, 0) \
        - direction_size * 0.5
    s_button.position = dpad_center_position + Vector2(0, direction_offset) \
        - direction_size * 0.5
    d_button.position = dpad_center_position + Vector2(direction_offset, 0) \
        - direction_size * 0.5
    for button in [w_button, a_button, s_button, d_button]:
        button.size = direction_size

    var center_size := dpad_diameter * 0.34
    dpad_center.size = Vector2.ONE * center_size
    _dpad_home_position = (
        dpad_center_position - Vector2.ONE * center_size * 0.5
    )
    _dpad_travel_radius = (dpad_diameter - center_size) * 0.5
    _position_dpad_center(true)

    var digit_x := menu_button.position.x - diameter - gap
    var digit_top := safe_rect.position.y + margin + diameter * 0.24
    for index in range(digit_buttons.size()):
        digit_buttons[index].position = Vector2(
            digit_x,
            digit_top + index * (diameter + gap)
        )
        digit_buttons[index].size = key_size

    var bottom_y := safe_end.y - margin - diameter
    control_button.position = Vector2(
        dpad_origin.x + dpad_diameter + gap,
        bottom_y
    )
    control_button.size = key_size

    var action_diameter := diameter * 1.12
    var action_size := Vector2.ONE * action_diameter
    var action_left := digit_x - action_diameter * 2.0 - gap * 2.0
    var mouse_y := bottom_y - action_diameter - gap
    mouse_left_button.position = Vector2(action_left, mouse_y)
    mouse_right_button.position = Vector2(action_left + action_diameter + gap, mouse_y)
    space_button.position = Vector2(action_left, bottom_y)
    enter_button.position = Vector2(action_left + action_diameter + gap, bottom_y)
    for action_button in [
        mouse_left_button,
        mouse_right_button,
        space_button,
        enter_button,
    ]:
        action_button.size = action_size
    _layout_mouse_icon(mouse_left_button)
    _layout_mouse_icon(mouse_right_button)

    var scroll_stack_height := diameter * 2.0 + gap
    var desired_scroll_top := (
        safe_rect.position.y
        + (safe_rect.size.y - scroll_stack_height) * 0.46
    )
    var scroll_min_y := escape_button.get_rect().end.y + gap
    var scroll_max_y := dpad_origin.y - gap - scroll_stack_height
    var scroll_top := clampf(
        desired_scroll_top,
        scroll_min_y,
        maxf(scroll_min_y, scroll_max_y)
    )
    var scroll_x := safe_rect.position.x + margin
    scroll_up_button.position = Vector2(scroll_x, scroll_top)
    scroll_up_button.size = key_size
    scroll_down_button.position = Vector2(scroll_x, scroll_top + diameter + gap)
    scroll_down_button.size = key_size

    if not _cursor_initialized:
        cursor_handle.position = safe_rect.get_center() - CURSOR_HOTSPOT
        _cursor_initialized = true
    cursor_handle.size = Vector2.ONE * CURSOR_SIZE
    # Preserve the pointer across repeated safe-area layouts. Rect2.has_point()
    # excludes its right and bottom edges, so using it here used to recenter a
    # cursor whose image origin was correctly clamped exactly onto either edge.
    _clamp_cursor()

func owns_viewport_pointer(event: InputEvent) -> bool:
    if not _enabled or not _panel_open or is_touch_mode():
        return false
    return (
        event is InputEventScreenTouch
        or event is InputEventScreenDrag
        or event is InputEventMouseButton
        or event is InputEventMouseMotion
    )

func routes_pointer(event: InputEvent) -> bool:
    if not _enabled or _root == null:
        return false

    if event is InputEventScreenTouch:
        var touch := event as InputEventScreenTouch
        if touch.index == _dpad_touch_index:
            if touch.pressed:
                _update_dpad(touch.position)
            else:
                _dpad_touch_index = -1
                _reset_dpad()
            return true
        if (
            touch.pressed
            and _panel_open
            and _dpad_contains_point(touch.position)
        ):
            _cancel_cursor_tap_for_additional_touch(touch.index)
            if _dpad_touch_index == -1:
                _dpad_touch_index = touch.index
                # iOS may synthesize a mouse press before exposing the same
                # contact as ScreenTouch. The real touch owns the joystick.
                _dpad_mouse_dragging = false
                _update_dpad(touch.position)
            return true
        if _mouse_mode_blocked_touch_indices.has(touch.index):
            if not touch.pressed:
                _mouse_mode_blocked_touch_indices.erase(touch.index)
            return true
        if touch.index == _cursor_secondary_touch_index:
            if not touch.pressed:
                _finish_cursor_secondary_touch()
            return true
        if touch.pressed and _visible_interactive_control_at(touch.position):
            _cancel_cursor_tap_for_additional_touch(touch.index)
        if (
            touch.pressed
            and menu_button.visible
            and menu_button.get_global_rect().has_point(touch.position)
        ):
            _begin_menu_drag(touch.position.y)
            _menu_touch_index = touch.index
            return true
        if touch.index == _menu_touch_index:
            if not touch.pressed:
                _menu_touch_index = -1
                _finish_menu_drag()
            return true
        if (
            touch.pressed
            and _panel_open
            and not is_touch_mode()
            and not _visible_interactive_control_at(touch.position)
        ):
            if _cursor_touch_index == -1:
                if _cursor_two_finger_tap_candidate:
                    _cancel_cursor_two_finger_tap()
                    _mouse_mode_blocked_touch_indices[touch.index] = true
                    return true
                # iOS can deliver the same finger as both a mouse track and a
                # ScreenTouch track. Their positions are not guaranteed to be
                # in the same coordinate space, so the real touch must always
                # take ownership before its first ScreenDrag.
                if _cursor_mouse_dragging:
                    _cursor_mouse_dragging = false
                _begin_cursor_touch(touch.index, touch.position)
            elif _cursor_touch_index != touch.index:
                _begin_cursor_secondary_touch(touch.index, touch.position)
            return true
        if touch.index == _cursor_touch_index:
            if not touch.pressed:
                _finish_cursor_primary_touch()
            return true
    elif event is InputEventScreenDrag:
        var drag := event as InputEventScreenDrag
        if drag.index == _dpad_touch_index:
            _update_dpad(drag.position)
            return true
        if _mouse_mode_blocked_touch_indices.has(drag.index):
            return true
        if drag.index == _cursor_secondary_touch_index:
            _update_cursor_secondary_touch(drag.position)
            return true
        if drag.index == _menu_touch_index:
            _drag_menu_to(drag.position.y)
            return true
        if drag.index == _cursor_touch_index:
            _update_cursor_primary_touch(drag.position)
            return true
    elif event is InputEventMouseButton:
        var mouse_button := event as InputEventMouseButton
        if mouse_button.button_index == MOUSE_BUTTON_LEFT:
            if (
                mouse_button.pressed
                and _panel_open
                and _dpad_contains_point(mouse_button.position)
            ):
                if _dpad_touch_index == -1:
                    _dpad_mouse_dragging = true
                    _update_dpad(mouse_button.position)
                return true
            if _dpad_mouse_dragging:
                if not mouse_button.pressed:
                    _dpad_mouse_dragging = false
                    _reset_dpad()
                return true
            if (
                mouse_button.device != INPUT_DEVICE_ID_EMULATION
                and
                mouse_button.pressed
                and menu_button.visible
                and menu_button.get_global_rect().has_point(mouse_button.position)
            ):
                _begin_menu_drag(mouse_button.position.y)
                _menu_mouse_dragging = true
                return true
            if _menu_mouse_dragging:
                if not mouse_button.pressed:
                    _menu_mouse_dragging = false
                    _finish_menu_drag()
                return true
            if (
                mouse_button.pressed
                and _panel_open
                and not is_touch_mode()
                and not _visible_interactive_control_at(mouse_button.position)
            ):
                # Ignore a mouse press synthesized after the real touch. A
                # physical mouse remains supported because it has no active
                # ScreenTouch track.
                if _cursor_touch_index != -1:
                    return true
                _cursor_mouse_dragging = true
                _begin_cursor_drag(mouse_button.position)
                _spawn_touch_ripple(mouse_button.position)
                return true
            if _cursor_mouse_dragging:
                if not mouse_button.pressed:
                    _cursor_mouse_dragging = false
                    _finish_cursor_drag_if_inactive()
                return true
    elif event is InputEventMouseMotion:
        var motion := event as InputEventMouseMotion
        if _dpad_mouse_dragging:
            _update_dpad(motion.position)
            return true
        if (
            motion.device != INPUT_DEVICE_ID_EMULATION
            and _menu_mouse_dragging
        ):
            _drag_menu_to(motion.position.y)
            return true
        if _cursor_mouse_dragging:
            _drag_cursor_to(motion.position)
            return true

    if not _held_keys.is_empty() or not _held_mouse_buttons.is_empty():
        return event is InputEventScreenTouch \
            or event is InputEventScreenDrag \
            or event is InputEventMouseButton \
            or event is InputEventMouseMotion

    var position := _event_position(event)
    if position.x < 0.0 or position.y < 0.0:
        return false
    if _visible_interactive_control_at(position):
        return true
    if (
        _panel_open
        and not is_touch_mode()
        and cursor_handle.get_global_rect().has_point(position)
    ):
        return true
    if _panel_open and not is_touch_mode():
        return (
            event is InputEventScreenTouch
            or event is InputEventScreenDrag
            or event is InputEventMouseButton
            or event is InputEventMouseMotion
        )
    return false

# Native game surfaces use these regions to hand input to this same Control
# tree. Layout, gestures and actions remain owned by GameVirtualControls.
func pointer_regions() -> Array[Rect2]:
    var regions: Array[Rect2] = []
    if not _enabled or not _menu_button_enabled:
        return regions
    if _panel_open and not is_touch_mode():
        regions.append(_safe_rect)
        return regions
    for control in _interactive_controls:
        if control.visible:
            regions.append(control.get_global_rect())
    if _panel_open:
        regions.append(dpad_backdrop.get_global_rect())
    return regions

func hide_virtual_controls() -> void:
    release_all()
    _panel_open = false
    _menu_open = false
    _reset_cursor_touch_gesture()
    _cursor_mouse_dragging = false
    _reset_cursor_drag_position()
    _mouse_mode_blocked_touch_indices.clear()
    _sync_visibility()

func cursor_screen_position() -> Vector2:
    if cursor_handle == null:
        return Vector2.ZERO
    return cursor_handle.get_global_rect().position + CURSOR_HOTSPOT

func _add_key_button(
    node_name: String,
    label: String,
    key_code: int,
    wide: bool = false
) -> Button:
    var button := _create_control_button(node_name, label, wide)
    button.button_down.connect(_press_key.bind(key_code))
    button.button_up.connect(_release_key.bind(key_code))
    _root.add_child(button)
    _panel_controls.append(button)
    _interactive_controls.append(button)
    return button

func _add_mouse_button(
    node_name: String,
    label: String,
    button_code: int,
    modifiers: int
) -> Button:
    var button := _create_control_button(node_name, label, true)
    button.button_down.connect(_press_mouse_button.bind(button_code, modifiers))
    button.button_up.connect(_release_mouse_button.bind(button_code, modifiers))
    _root.add_child(button)
    _panel_controls.append(button)
    _interactive_controls.append(button)
    return button

func _add_scroll_button(node_name: String, label: String, delta_y: float) -> Button:
    var button := _create_control_button(node_name, label, true)
    button.set_meta("scroll_delta_y", delta_y)
    button.button_down.connect(_press_scroll.bind(delta_y))
    button.button_up.connect(_release_scroll.bind(delta_y))
    button.add_theme_font_size_override("font_size", 18)
    _root.add_child(button)
    _panel_controls.append(button)
    _interactive_controls.append(button)
    return button

func _create_control_button(node_name: String, label: String, wide: bool) -> Button:
    var button := Button.new()
    button.name = node_name
    button.text = label
    button.focus_mode = Control.FOCUS_NONE
    button.mouse_filter = Control.MOUSE_FILTER_STOP
    button.keep_pressed_outside = true
    button.add_theme_font_size_override("font_size", 14 if wide else 17)
    button.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.90))
    button.add_theme_color_override("font_hover_color", Color.WHITE)
    button.add_theme_color_override("font_pressed_color", Color.WHITE)
    button.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.30))
    button.add_theme_constant_override("outline_size", 1)
    var empty := StyleBoxEmpty.new()
    for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
        button.add_theme_stylebox_override(state, empty)
    _attach_glass(button)
    return button

func _attach_glass(control: Control, radius: float = 999.0):
    var glass = control.get_node_or_null("Glass")
    if glass != null:
        return glass
    glass = AetherGlass.new()
    glass.radius = radius
    glass.accent = _tokens.accent
    control.add_child(glass)
    control.move_child(glass, 0)
    if control is BaseButton:
        glass.bind(control as BaseButton)
    return glass

func _detach_glass(control: Control) -> void:
    var glass = control.get_node_or_null("Glass")
    if glass != null:
        control.remove_child(glass)
        glass.queue_free()

func _dpad_backdrop_style() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.draw_center = false
    style.bg_color = Color.TRANSPARENT
    return style

func _dpad_knob_style() -> StyleBoxFlat:
    return _dpad_backdrop_style()

func _create_pad_frame() -> Panel:
    var frame := Panel.new()
    frame.name = "PadFrame"
    frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var style := StyleBoxFlat.new()
    style.draw_center = false
    style.border_color = Color(1.0, 1.0, 1.0, 0.16)
    style.set_border_width_all(1)
    style.set_corner_radius_all(22)
    style.anti_aliasing = true
    frame.add_theme_stylebox_override("panel", style)
    frame.visible = false
    return frame

func _attach_dpad_decoration(backdrop: Panel) -> void:
    var glass = _attach_glass(backdrop)
    glass.tint = Color(0.08, 0.09, 0.12, 0.30)
    var deco := Control.new()
    deco.name = "Decoration"
    deco.mouse_filter = Control.MOUSE_FILTER_IGNORE
    deco.set_anchors_preset(Control.PRESET_FULL_RECT)
    deco.draw.connect(_draw_dpad_decoration.bind(deco))
    backdrop.add_child(deco)
    backdrop.resized.connect(deco.queue_redraw)

func _draw_dpad_decoration(deco: Control) -> void:
    var c := deco.size * 0.5
    var r := minf(deco.size.x, deco.size.y) * 0.5
    if r <= 4.0:
        return
    deco.draw_arc(c, r * 0.66, 0.0, TAU, 72, Color(1, 1, 1, 0.07), 1.0, true)

func _fresh_tween(owner: Control, channel: String) -> Tween:
    var key := "_tw_" + channel
    if owner.has_meta(key):
        var previous = owner.get_meta(key)
        if previous is Tween and (previous as Tween).is_valid():
            (previous as Tween).kill()
    var tween := owner.create_tween()
    owner.set_meta(key, tween)
    return tween

func _create_action_button(node_name: String, label: String) -> Button:
    var button := _create_control_button(node_name, label, true)
    button.add_theme_font_size_override("font_size", 14)
    return button

func _create_decorative_panel(node_name: String, style: StyleBoxFlat) -> Panel:
    var panel := Panel.new()
    panel.name = node_name
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    panel.add_theme_stylebox_override("panel", style)
    return panel

func _apply_dpad_button_style(button: Button) -> void:
    _detach_glass(button)
    var empty := StyleBoxEmpty.new()
    button.add_theme_stylebox_override("normal", empty)
    button.add_theme_stylebox_override("hover", empty)
    var lit := StyleBoxFlat.new()
    lit.bg_color = Color(1.0, 1.0, 1.0, 0.10)
    lit.set_corner_radius_all(999)
    lit.anti_aliasing = true
    button.add_theme_stylebox_override("pressed", lit)
    button.add_theme_stylebox_override("hover_pressed", lit)
    button.add_theme_color_override("font_color", Color(1, 1, 1, 0.62))
    button.add_theme_font_size_override("font_size", 20)

func _dpad_contains_point(screen_position: Vector2) -> bool:
    if dpad_backdrop == null or not dpad_backdrop.is_visible_in_tree():
        return false
    var backdrop_rect := dpad_backdrop.get_global_rect()
    return screen_position.distance_to(backdrop_rect.get_center()) \
        <= minf(backdrop_rect.size.x, backdrop_rect.size.y) * 0.5

func _update_dpad(screen_position: Vector2) -> void:
    if _dpad_travel_radius <= 0.0:
        return
    var offset := screen_position - dpad_backdrop.get_global_rect().get_center()
    if offset.length() > _dpad_travel_radius:
        offset = offset.normalized() * _dpad_travel_radius
    _dpad_vector = offset / _dpad_travel_radius
    _position_dpad_center()
    _set_dpad_keys(_dpad_vector)

func _position_dpad_center(snap: bool = false) -> void:
    if dpad_center == null:
        return
    _dpad_knob_target = (
        _dpad_home_position + _dpad_vector * _dpad_travel_radius
    )
    if snap:
        dpad_center.position = _dpad_knob_target
    var glass = dpad_center.get_node_or_null("Glass")
    if glass != null:
        var active := _dpad_touch_index != -1 or _dpad_mouse_dragging
        if glass.selected != active:
            glass.set_selected(active)

func _set_dpad_keys(direction_vector: Vector2) -> void:
    var desired := {}
    if direction_vector.length() >= DPAD_DEAD_ZONE_RATIO:
        var direction := direction_vector.normalized()
        if direction.y <= -DPAD_DIRECTION_AXIS_THRESHOLD:
            desired[VK_W] = true
        if direction.x <= -DPAD_DIRECTION_AXIS_THRESHOLD:
            desired[VK_A] = true
        if direction.y >= DPAD_DIRECTION_AXIS_THRESHOLD:
            desired[VK_S] = true
        if direction.x >= DPAD_DIRECTION_AXIS_THRESHOLD:
            desired[VK_D] = true

    for key_variant in _dpad_held_keys.keys().duplicate():
        var key_code := int(key_variant)
        if not desired.has(key_code):
            _dpad_held_keys.erase(key_code)
            _release_key(key_code)
    for key_variant in desired.keys():
        var key_code := int(key_variant)
        if not _dpad_held_keys.has(key_code):
            _dpad_held_keys[key_code] = true
            _press_key(key_code)
    _sync_dpad_button_highlights(desired)

func _sync_dpad_button_highlights(desired: Dictionary) -> void:
    if w_button != null:
        w_button.set_pressed_no_signal(desired.has(VK_W))
    if a_button != null:
        a_button.set_pressed_no_signal(desired.has(VK_A))
    if s_button != null:
        s_button.set_pressed_no_signal(desired.has(VK_S))
    if d_button != null:
        d_button.set_pressed_no_signal(desired.has(VK_D))

func _reset_dpad() -> void:
    _set_dpad_keys(Vector2.ZERO)
    _dpad_vector = Vector2.ZERO
    _position_dpad_center()

func _apply_edge_menu_style(button: Button) -> void:
    button.text = ""
    button.tooltip_text = "Menu"
    _detach_glass(button)
    button.mouse_entered.connect(_set_orb_hovered.bind(true))
    button.mouse_exited.connect(_set_orb_hovered.bind(false))
    button.button_down.connect(_set_orb_pressed.bind(true))
    button.button_up.connect(_set_orb_pressed.bind(false))

func _set_orb_hovered(value: bool) -> void:
    if _orb != null:
        _orb.hovered = value

func _set_orb_pressed(value: bool) -> void:
    if _orb == null:
        return
    _orb.pressed = value
    if value:
        _orb.press_at(_orb.get_local_mouse_position())
    else:
        _orb.release()

func _attach_edge_menu_icon(button: Button) -> void:
    _orb = AetherOrb.new()
    _orb.setup(_tokens.accent, _tokens.accent_2)
    button.add_child(_orb)

func _layout_edge_menu_icon() -> void:
    if _orb == null:
        return
    _orb.position = Vector2.ZERO
    _orb.size = menu_button.size
    _orb.pivot_offset = menu_button.size * 0.5

func _layout_menu_options(diameter: float, gap: float) -> void:
    var option_size := Vector2(maxf(108.0, diameter * 2.15), menu_button.size.y)
    var option_x := menu_button.position.x - option_size.x - gap
    var options_height := option_size.y * 2.0 + gap
    var options_top := clampf(
        menu_button.position.y,
        _safe_rect.position.y,
        _safe_rect.end.y - options_height
    )
    keyboard_button.position = Vector2(option_x, options_top)
    keyboard_button.size = option_size
    virtual_controls_button.position = Vector2(
        option_x,
        options_top + option_size.y + gap
    )
    virtual_controls_button.size = option_size

func _apply_menu_option_style(button: Button) -> void:
    button.add_theme_font_size_override("font_size", 13)
    button.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
    button.add_theme_constant_override("outline_size", 0)
    var glass = _attach_glass(button)
    glass.tint = Color(0.09, 0.10, 0.13, 0.46)

func _apply_input_mode_style(button: Button) -> void:
    button.add_theme_font_size_override("font_size", 13)
    button.add_theme_constant_override("outline_size", 0)
    var glass = _attach_glass(button)
    glass.selected_amount = 0.26
    if glass.selected != is_touch_mode():
        glass.set_selected(is_touch_mode())

func _attach_mouse_icon(button: Button, highlights_left: bool) -> void:
    var icon := Control.new()
    icon.name = "MouseIcon"
    icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
    icon.set_meta("highlights_left", highlights_left)
    button.add_child(icon)

    var base := Panel.new()
    base.name = "Base"
    base.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var base_style := StyleBoxFlat.new()
    base_style.bg_color = Color(0.84, 0.85, 0.87, 0.82)
    base_style.corner_radius_top_left = 12
    base_style.corner_radius_top_right = 12
    base_style.corner_radius_bottom_left = 7
    base_style.corner_radius_bottom_right = 7
    base.add_theme_stylebox_override("panel", base_style)
    icon.add_child(base)

    var highlight := Panel.new()
    highlight.name = "Highlight"
    highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var highlight_style := StyleBoxFlat.new()
    highlight_style.bg_color = Color(0.31, 0.60, 1.0, 0.95)
    highlight.add_theme_stylebox_override("panel", highlight_style)
    icon.add_child(highlight)

    var shell := Panel.new()
    shell.name = "Shell"
    shell.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var shell_style := StyleBoxFlat.new()
    shell_style.bg_color = Color.TRANSPARENT
    shell_style.border_color = Color(0.22, 0.23, 0.25, 0.92)
    shell_style.set_border_width_all(2)
    shell_style.corner_radius_top_left = 12
    shell_style.corner_radius_top_right = 12
    shell_style.corner_radius_bottom_left = 7
    shell_style.corner_radius_bottom_right = 7
    shell.add_theme_stylebox_override("panel", shell_style)
    icon.add_child(shell)

    var divider := ColorRect.new()
    divider.name = "Divider"
    divider.color = Color(0.22, 0.23, 0.25, 0.9)
    divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
    icon.add_child(divider)

    var wheel := Panel.new()
    wheel.name = "Wheel"
    wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    wheel.add_theme_stylebox_override(
        "panel",
        _button_style(
            Color(0.72, 0.74, 0.77, 1.0),
            Color(0.22, 0.23, 0.25, 0.9),
            true,
            1
        )
    )
    icon.add_child(wheel)

func _layout_mouse_icon(button: Button) -> void:
    var icon := button.get_node_or_null("MouseIcon") as Control
    if icon == null:
        return
    var icon_size := Vector2(button.size.x * 0.46, button.size.y * 0.60)
    icon.position = (button.size - icon_size) * 0.5
    icon.size = icon_size

    var highlight := icon.get_node("Highlight") as Panel
    var base := icon.get_node("Base") as Panel
    var shell := icon.get_node("Shell") as Panel
    var divider := icon.get_node("Divider") as ColorRect
    var wheel := icon.get_node("Wheel") as Panel
    var highlights_left := bool(icon.get_meta("highlights_left", true))
    var top_height := icon_size.y * 0.46
    base.position = Vector2.ZERO
    base.size = icon_size
    highlight.position = Vector2(
        2 if highlights_left else icon_size.x * 0.5,
        2
    )
    highlight.size = Vector2(icon_size.x * 0.5 - 2, top_height - 2)
    shell.position = Vector2.ZERO
    shell.size = icon_size
    divider.position = Vector2(icon_size.x * 0.5 - 0.75, 1)
    divider.size = Vector2(1.5, top_height)
    wheel.position = Vector2(icon_size.x * 0.5 - 2.0, icon_size.y * 0.1)
    wheel.size = Vector2(4.0, icon_size.y * 0.22)

func _attach_pointer_visual(pointer: Control) -> void:
    pointer.set_meta("visual_style", "glass_arrow")
    pointer.set_meta("hotspot", CURSOR_HOTSPOT)

    # Click marker centred exactly on the hotspot.
    var halo := Panel.new()
    halo.name = "Halo"
    halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var halo_style := StyleBoxFlat.new()
    halo_style.bg_color = Color(1.0, 1.0, 1.0, 0.12)
    halo_style.border_color = Color(1.0, 1.0, 1.0, 0.42)
    halo_style.set_border_width_all(1)
    halo_style.set_corner_radius_all(999)
    halo_style.anti_aliasing = true
    halo.add_theme_stylebox_override("panel", halo_style)
    halo.size = Vector2.ONE * 24.0
    halo.pivot_offset = halo.size * 0.5
    halo.position = CURSOR_HOTSPOT - halo.size * 0.5
    halo.modulate.a = 0.6
    pointer.add_child(halo)

    # Slim arrow whose tip sits exactly on CURSOR_HOTSPOT.
    var shape := PackedVector2Array([
        Vector2(0.0, 0.0),
        Vector2(0.0, 17.5),
        Vector2(4.4, 13.6),
        Vector2(7.3, 20.2),
        Vector2(10.0, 19.0),
        Vector2(7.2, 12.6),
        Vector2(12.8, 12.6),
    ])
    var points := PackedVector2Array()
    for point in shape:
        points.append(CURSOR_HOTSPOT + point)
    var shadow_points := PackedVector2Array()
    for point in points:
        shadow_points.append(point + Vector2(0.6, 1.4))
    var shadow := Polygon2D.new()
    shadow.name = "Shadow"
    shadow.polygon = shadow_points
    shadow.color = Color(0.0, 0.0, 0.0, 0.28)
    shadow.antialiased = true
    pointer.add_child(shadow)
    var arrow := Polygon2D.new()
    arrow.name = "Arrow"
    arrow.polygon = points
    arrow.color = Color(0.98, 0.98, 0.99, 0.98)
    arrow.antialiased = true
    pointer.add_child(arrow)
    var outline := Line2D.new()
    outline.name = "Outline"
    outline.points = points
    outline.closed = true
    outline.width = 1.25
    outline.antialiased = true
    outline.joint_mode = Line2D.LINE_JOINT_ROUND
    outline.default_color = Color(0.06, 0.07, 0.09, 0.88)
    pointer.add_child(outline)

func _button_style(
    fill: Color,
    border: Color,
    circular: bool,
    border_width: int = 2
) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = fill
    style.border_color = border
    style.set_border_width_all(border_width)
    style.set_corner_radius_all(999 if circular else 12)
    return style

func _begin_menu_drag(pointer_y: float) -> void:
    _menu_drag_start_pointer_y = pointer_y
    _menu_drag_grab_offset_y = pointer_y - menu_button.position.y
    _menu_drag_moved = false

func _drag_menu_to(pointer_y: float) -> void:
    if not _menu_drag_moved:
        _menu_drag_moved = absf(
            pointer_y - _menu_drag_start_pointer_y
        ) >= MENU_DRAG_THRESHOLD
    if not _menu_drag_moved:
        return
    var min_y := _safe_rect.position.y
    var max_y := _safe_rect.end.y - menu_button.size.y
    menu_button.position.y = clampf(
        pointer_y - _menu_drag_grab_offset_y,
        min_y,
        max_y
    )
    menu_button.position.x = (
        _safe_rect.end.x - menu_button.size.x - MENU_EDGE_INSET
    )
    var menu_y_range := maxf(0.0, max_y - min_y)
    _menu_y_ratio = (
        (menu_button.position.y - min_y) / menu_y_range
        if menu_y_range > 0.0
        else 0.0
    )
    var diameter := clampf(
        minf(_safe_rect.size.x, _safe_rect.size.y) * 0.13,
        BUTTON_MIN_SIZE,
        BUTTON_MAX_SIZE
    )
    var gap := clampf(diameter * 0.13, 6.0, 9.0)
    _layout_menu_options(diameter, gap)

func _finish_menu_drag() -> void:
    if _menu_drag_moved:
        call_deferred("_clear_menu_drag_flag")

func _clear_menu_drag_flag() -> void:
    if _menu_touch_index == -1 and not _menu_mouse_dragging:
        _menu_drag_moved = false

func _toggle_menu() -> void:
    if not _enabled or not _menu_button_enabled:
        return
    if _menu_drag_moved:
        _menu_drag_moved = false
        return
    if _panel_open:
        release_all()
        _reset_cursor_touch_gesture()
        _mouse_mode_blocked_touch_indices.clear()
        _panel_open = false
        _menu_open = true
    else:
        _menu_open = not _menu_open
    _sync_visibility()

func _request_keyboard() -> void:
    if not _enabled or not _menu_button_enabled:
        return
    release_all()
    _reset_cursor_touch_gesture()
    _mouse_mode_blocked_touch_indices.clear()
    _menu_open = false
    _panel_open = false
    _sync_visibility()
    keyboard_requested.emit()

func _toggle_input_mode() -> void:
    if not _enabled or not _panel_open:
        return
    set_input_mode(
        INPUT_MODE_TOUCH if _input_mode == INPUT_MODE_MOUSE else INPUT_MODE_MOUSE,
        true
    )

func _sync_input_mode_presentation() -> void:
    if input_mode_button == null:
        return
    var touch_mode := is_touch_mode()
    input_mode_button.text = "Mode: Touch" if touch_mode else "Mode: Mouse"
    input_mode_button.tooltip_text = (
        "Direct touch mode" if touch_mode else "Virtual mouse mode"
    )
    input_mode_button.set_meta("input_mode", _input_mode)
    _apply_input_mode_style(input_mode_button)

func _sync_visibility() -> void:
    if menu_button == null:
        return
    var controls_visible := _enabled and _menu_button_enabled
    var options_were_visible := keyboard_button.visible
    menu_button.visible = controls_visible
    keyboard_button.visible = controls_visible and _menu_open
    virtual_controls_button.visible = controls_visible and _menu_open
    var panel_shown := controls_visible and _panel_open
    for control in _panel_controls:
        control.visible = panel_shown
    var show_virtual_mouse := controls_visible and _panel_open and not is_touch_mode()
    mouse_left_button.visible = show_virtual_mouse
    mouse_right_button.visible = show_virtual_mouse
    cursor_handle.visible = show_virtual_mouse
    var frame_was_visible := _pad_frame.visible
    _pad_frame.visible = show_virtual_mouse
    if show_virtual_mouse and not frame_was_visible:
        _start_pad_frame_pulse()
    elif not show_virtual_mouse and frame_was_visible:
        _stop_pad_frame_pulse()
    if keyboard_button.visible and not options_were_visible:
        _animate_menu_options()
    if panel_shown and not _panel_shown:
        _animate_panel_in()
    _panel_shown = panel_shown
    if _orb != null:
        _orb.open = controls_visible and (_menu_open or _panel_open)
    var menu_visible := controls_visible and _menu_open
    if menu_visible != _menu_visible:
        _menu_visible = menu_visible
        menu_open_changed.emit(menu_visible)

func _animate_menu_options() -> void:
    if not is_inside_tree():
        return
    var index := 0
    for option in [keyboard_button, virtual_controls_button]:
        var target_x: float = option.position.x
        var delay := index * 0.04
        option.modulate.a = 0.0
        option.position.x = target_x + 14.0
        var tween := _fresh_tween(option, "enter")
        tween.set_parallel(true)
        tween.tween_property(option, "modulate:a", 1.0, 0.22).set_delay(delay)
        tween.tween_property(option, "position:x", target_x, 0.32) \
            .set_delay(delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
        index += 1

func _animate_panel_in() -> void:
    if not is_inside_tree():
        return
    var origin := menu_button.position + menu_button.size * 0.5
    var reach := maxf(_safe_rect.size.length(), 1.0)
    for control in _panel_controls:
        if not control.visible:
            continue
        var center := control.position + control.size * 0.5
        var delay := clampf(origin.distance_to(center) / reach, 0.0, 1.0) * 0.12
        control.pivot_offset = (
            CURSOR_HOTSPOT if control == cursor_handle else control.size * 0.5
        )
        control.modulate.a = 0.0
        control.scale = Vector2.ONE * 0.94
        var tween := _fresh_tween(control, "enter")
        tween.set_parallel(true)
        tween.tween_property(control, "modulate:a", 1.0, 0.24).set_delay(delay)
        tween.tween_property(control, "scale", Vector2.ONE, 0.32) \
            .set_delay(delay).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)

func _start_pad_frame_pulse() -> void:
    if not is_inside_tree():
        return
    var tween := _fresh_tween(_pad_frame, "enter")
    _pad_frame.modulate.a = 0.0
    tween.tween_property(_pad_frame, "modulate:a", 1.0, 0.4)

func _stop_pad_frame_pulse() -> void:
    if _pad_frame.has_meta("_tw_enter"):
        var previous = _pad_frame.get_meta("_tw_enter")
        if previous is Tween and (previous as Tween).is_valid():
            (previous as Tween).kill()

func _spawn_touch_ripple(screen_position: Vector2) -> void:
    if _root == null or not is_inside_tree():
        return
    var ring := Panel.new()
    ring.name = "TouchRipple"
    ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var style := StyleBoxFlat.new()
    style.bg_color = Color(1.0, 1.0, 1.0, 0.06)
    style.border_color = Color(1.0, 1.0, 1.0, 0.50)
    style.set_border_width_all(1)
    style.set_corner_radius_all(999)
    style.anti_aliasing = true
    ring.add_theme_stylebox_override("panel", style)
    ring.size = Vector2.ONE * 56.0
    ring.pivot_offset = ring.size * 0.5
    ring.position = screen_position - ring.size * 0.5
    ring.scale = Vector2.ONE * 0.35
    _root.add_child(ring)
    var tween := ring.create_tween()
    tween.set_parallel(true)
    tween.tween_property(ring, "scale", Vector2.ONE, 0.45) \
        .set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    tween.tween_property(ring, "modulate:a", 0.0, 0.45) \
        .set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
    tween.chain().tween_callback(ring.queue_free)

func _pulse_cursor() -> void:
    if cursor_handle == null or not is_inside_tree():
        return
    var halo := cursor_handle.get_node_or_null("Halo") as Control
    if halo == null:
        return
    halo.scale = Vector2.ONE * 0.55
    halo.modulate.a = 1.0
    var tween := _fresh_tween(halo, "pulse")
    tween.set_parallel(true)
    tween.tween_property(halo, "scale", Vector2.ONE, 0.36) \
        .set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    tween.tween_property(halo, "modulate:a", 0.6, 0.36) \
        .set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _apply_keyboard_controls_opacity() -> void:
    for control in _panel_controls:
        # The pointer must remain precise even when the surrounding virtual
        # key caps are intentionally subdued.
        var opacity := 1.0 if control == cursor_handle else _keyboard_controls_opacity
        control.self_modulate = Color(1.0, 1.0, 1.0, opacity)
        for child_name in ["Glass", "Decoration"]:
            var child := control.get_node_or_null(child_name) as CanvasItem
            if child != null:
                child.self_modulate = Color(1.0, 1.0, 1.0, opacity)

func _press_key(key_code: int) -> void:
    if not _enabled or not _panel_open or _held_keys.has(key_code):
        return
    _held_keys[key_code] = true
    key_event_requested.emit(
        true,
        key_code,
        MOD_CONTROL if key_code == VK_CONTROL else 0
    )

func _release_key(key_code: int) -> void:
    if not _held_keys.erase(key_code):
        return
    key_event_requested.emit(false, key_code, 0)

func _press_mouse_button(button: int, modifiers: int) -> void:
    if not _enabled or not _panel_open or _held_mouse_buttons.has(modifiers):
        return
    _held_mouse_buttons[modifiers] = {"button": button, "modifiers": modifiers}
    _pulse_cursor()
    pointer_button_requested.emit(
        true, button, modifiers, cursor_screen_position()
    )

func _release_mouse_button(button: int, modifiers: int) -> void:
    if not _held_mouse_buttons.erase(modifiers):
        return
    pointer_button_requested.emit(
        false, button, modifiers, cursor_screen_position()
    )

func _scroll(delta_y: float) -> void:
    if not _enabled or not _panel_open:
        return
    pointer_scroll_requested.emit(delta_y, cursor_screen_position())

func _press_scroll(delta_y: float) -> void:
    if (
        not _enabled
        or not _panel_open
        or not is_zero_approx(_held_scroll_direction)
    ):
        return
    _held_scroll_direction = delta_y
    _scroll(delta_y)
    _scroll_next_repeat_msec = (
        Time.get_ticks_msec() + SCROLL_HOLD_DELAY_MSEC
    )

func _release_scroll(delta_y: float) -> void:
    if not is_equal_approx(_held_scroll_direction, delta_y):
        return
    _cancel_scroll_hold()

func _cancel_scroll_hold() -> void:
    _held_scroll_direction = 0.0
    _scroll_next_repeat_msec = 0

func _process(delta: float) -> void:
    _advance_scroll_hold(Time.get_ticks_msec())
    if dpad_center != null and dpad_center.visible:
        var gap := _dpad_knob_target - dpad_center.position
        if gap.length_squared() > 0.01:
            var dragging := _dpad_touch_index != -1 or _dpad_mouse_dragging
            var rate := 34.0 if dragging else 16.0
            dpad_center.position += gap * (1.0 - exp(-rate * delta))
        else:
            dpad_center.position = _dpad_knob_target

func _advance_scroll_hold(now_msec: int) -> void:
    if (
        is_zero_approx(_held_scroll_direction)
        or now_msec < _scroll_next_repeat_msec
    ):
        return
    var emitted := 0
    while (
        now_msec >= _scroll_next_repeat_msec
        and emitted < SCROLL_HOLD_MAX_CATCH_UP_STEPS
    ):
        _scroll(_held_scroll_direction)
        _scroll_next_repeat_msec += SCROLL_HOLD_REPEAT_MSEC
        emitted += 1
    if now_msec >= _scroll_next_repeat_msec:
        _scroll_next_repeat_msec = now_msec + SCROLL_HOLD_REPEAT_MSEC

func _move_cursor_by(screen_delta: Vector2) -> void:
    var previous := cursor_screen_position()
    cursor_handle.position += screen_delta
    _clamp_cursor()
    var current := cursor_screen_position()
    var delta := current - previous
    if not delta.is_zero_approx():
        pointer_move_requested.emit(current, delta)

func _begin_cursor_touch(index: int, screen_position: Vector2) -> void:
    _cursor_touch_index = index
    _cursor_touch_start_screen_position = screen_position
    _cursor_touch_down_msec = Time.get_ticks_msec()
    _cursor_touch_tap_candidate = true
    _cursor_touch_released = false
    _cursor_secondary_touch_index = -1
    _cursor_secondary_touch_start_screen_position = Vector2.ZERO
    _cursor_secondary_touch_released = false
    _cursor_two_finger_tap_candidate = false
    _begin_cursor_drag(screen_position)
    _spawn_touch_ripple(screen_position)

func _begin_cursor_secondary_touch(index: int, screen_position: Vector2) -> void:
    if _cursor_secondary_touch_index != -1:
        _cancel_cursor_two_finger_tap()
        _mouse_mode_blocked_touch_indices[index] = true
        return
    var age_msec := Time.get_ticks_msec() - _cursor_touch_down_msec
    if (
        not _cursor_touch_tap_candidate
        or age_msec > CURSOR_TWO_FINGER_TAP_WINDOW_MSEC
    ):
        _cursor_touch_tap_candidate = false
        _mouse_mode_blocked_touch_indices[index] = true
        return
    _cursor_touch_tap_candidate = false
    _cursor_secondary_touch_index = index
    _cursor_secondary_touch_start_screen_position = screen_position
    _cursor_secondary_touch_released = false
    _cursor_two_finger_tap_candidate = true

func _update_cursor_primary_touch(screen_position: Vector2) -> void:
    var moved_distance := screen_position.distance_to(
        _cursor_touch_start_screen_position
    )
    if _cursor_two_finger_tap_candidate:
        if moved_distance >= CURSOR_TAP_DRAG_THRESHOLD:
            _cancel_cursor_two_finger_tap()
            _drag_cursor_to(screen_position)
        return
    if moved_distance >= CURSOR_TAP_DRAG_THRESHOLD:
        _cursor_touch_tap_candidate = false
    _drag_cursor_to(screen_position)

func _update_cursor_secondary_touch(screen_position: Vector2) -> void:
    if (
        _cursor_two_finger_tap_candidate
        and screen_position.distance_to(
            _cursor_secondary_touch_start_screen_position
        ) >= CURSOR_TAP_DRAG_THRESHOLD
    ):
        _cancel_cursor_two_finger_tap()

func _finish_cursor_primary_touch() -> void:
    _cursor_touch_index = -1
    _cursor_touch_released = true
    _finish_cursor_drag_if_inactive()
    if _cursor_two_finger_tap_candidate:
        _finish_cursor_two_finger_tap_if_ready()
        return
    var should_click := _cursor_touch_tap_candidate
    _reset_cursor_touch_gesture()
    if should_click:
        _click_cursor_button(0, 0)

func _finish_cursor_secondary_touch() -> void:
    _cursor_secondary_touch_index = -1
    _cursor_secondary_touch_released = true
    _finish_cursor_two_finger_tap_if_ready()

func _finish_cursor_two_finger_tap_if_ready() -> void:
    if (
        not _cursor_two_finger_tap_candidate
        or not _cursor_touch_released
        or not _cursor_secondary_touch_released
    ):
        return
    _reset_cursor_touch_gesture()
    _click_cursor_button(1, POINTER_MOD_RIGHT)

func _cancel_cursor_two_finger_tap() -> void:
    _cursor_two_finger_tap_candidate = false
    _cursor_touch_tap_candidate = false
    if _cursor_secondary_touch_index != -1:
        _mouse_mode_blocked_touch_indices[_cursor_secondary_touch_index] = true
    _cursor_secondary_touch_index = -1
    _cursor_secondary_touch_released = false
    _cursor_secondary_touch_start_screen_position = Vector2.ZERO
    if _cursor_touch_released:
        _reset_cursor_touch_gesture()

func _cancel_cursor_tap_for_additional_touch(index: int) -> void:
    if index == _cursor_touch_index or index == _cursor_secondary_touch_index:
        return
    if _cursor_two_finger_tap_candidate:
        _cancel_cursor_two_finger_tap()
    elif _cursor_touch_index != -1:
        _cursor_touch_tap_candidate = false

func _reset_cursor_touch_gesture() -> void:
    _cursor_touch_index = -1
    _cursor_touch_start_screen_position = Vector2.ZERO
    _cursor_touch_down_msec = 0
    _cursor_touch_tap_candidate = false
    _cursor_touch_released = false
    _cursor_secondary_touch_index = -1
    _cursor_secondary_touch_start_screen_position = Vector2.ZERO
    _cursor_secondary_touch_released = false
    _cursor_two_finger_tap_candidate = false
    if not _cursor_mouse_dragging:
        _reset_cursor_drag_position()

func _click_cursor_button(button: int, modifiers: int) -> void:
    if (
        not _enabled
        or not _panel_open
        or is_touch_mode()
        or _held_mouse_buttons.has(modifiers)
    ):
        return
    _press_mouse_button(button, modifiers)
    _release_mouse_button(button, modifiers)

func _begin_cursor_drag(screen_position: Vector2) -> void:
    _cursor_drag_last_screen_position = screen_position
    _cursor_drag_has_position = true

func _drag_cursor_to(screen_position: Vector2) -> void:
    if not _cursor_drag_has_position:
        _begin_cursor_drag(screen_position)
        return
    var screen_delta := screen_position - _cursor_drag_last_screen_position
    _cursor_drag_last_screen_position = screen_position
    _move_cursor_by(screen_delta)

func _finish_cursor_drag_if_inactive() -> void:
    if _cursor_touch_index == -1 and not _cursor_mouse_dragging:
        _reset_cursor_drag_position()

func _reset_cursor_drag_position() -> void:
    _cursor_drag_has_position = false
    _cursor_drag_last_screen_position = Vector2.ZERO

func _clamp_cursor() -> void:
    if cursor_handle == null or _safe_rect.size == Vector2.ZERO:
        return
    cursor_handle.position.x = clampf(
        cursor_handle.position.x,
        _safe_rect.position.x - CURSOR_HOTSPOT.x,
        _safe_rect.end.x - CURSOR_HOTSPOT.x
    )
    cursor_handle.position.y = clampf(
        cursor_handle.position.y,
        _safe_rect.position.y,
        _safe_rect.end.y
    )

func _event_position(event: InputEvent) -> Vector2:
    if event is InputEventScreenTouch:
        return (event as InputEventScreenTouch).position
    if event is InputEventScreenDrag:
        return (event as InputEventScreenDrag).position
    if event is InputEventMouseButton:
        return (event as InputEventMouseButton).position
    if event is InputEventMouseMotion:
        return (event as InputEventMouseMotion).position
    return Vector2(-1.0, -1.0)

func _visible_interactive_control_at(screen_position: Vector2) -> bool:
    for control in _interactive_controls:
        if (
            control.is_visible_in_tree()
            and control.get_global_rect().has_point(screen_position)
        ):
            return true
    return false
